#!/bin/bash
export KUBECONFIG=/root/.kube/dev.kubeconfig
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
GWIP=192.168.160.240
TOK=$(oc create token admin -n osac --duration=30m 2>/dev/null)
P=0; F=0
ok(){ echo "  PASS: $1"; P=$((P+1)); }
no(){ echo "  FAIL: $1"; F=$((F+1)); }
echo "=== ingress-separation + API battery vs gateway ($(date -u +%T)) ==="
# 1 public gRPC ext
o=$(grpcurl -insecure -authority $EXT -H "authorization: Bearer $TOK" -max-time 8 -d "{}" $GWIP:443 osac.public.v1.ComputeInstances/List 2>&1|grep -v Warning|head -1); case "$o" in *"{"*) ok "public gRPC via external";; *) no "public gRPC ext -> $o";; esac
# 2 public gRPC int
o=$(grpcurl -insecure -authority $INT -H "authorization: Bearer $TOK" -max-time 8 -d "{}" $GWIP:443 osac.public.v1.ComputeInstances/List 2>&1|grep -v Warning|head -1); case "$o" in *"{"*) ok "public gRPC via internal";; *) no "public gRPC int -> $o";; esac
# 3 private gRPC ext -> denied (Unimplemented)
o=$(grpcurl -insecure -authority $EXT -H "authorization: Bearer $TOK" -max-time 8 -d "{}" $GWIP:443 osac.private.v1.Hubs/List 2>&1|grep -v Warning|head -2|tr "\n" " "); case "$o" in *Unimplemented*|*"ERROR"*) ok "private gRPC DENIED via external";; *) no "private gRPC ext not denied -> $o";; esac
# 4 private gRPC int -> served
o=$(grpcurl -insecure -authority $INT -H "authorization: Bearer $TOK" -max-time 8 -d "{}" $GWIP:443 osac.private.v1.Hubs/List 2>&1|grep -v Warning|head -1); case "$o" in *"{"*) ok "private gRPC served via internal";; *) no "private gRPC int -> $o";; esac
# 5 public REST ext -> 200
c=$(curl -sk --resolve $EXT:443:$GWIP -H "authorization: Bearer $TOK" --max-time 8 https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}"); [ "$c" = 200 ] && ok "public REST via external (200)" || no "public REST ext -> $c"
# 6 public REST int -> 200
c=$(curl -sk --resolve $INT:443:$GWIP -H "authorization: Bearer $TOK" --max-time 8 https://$INT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}"); [ "$c" = 200 ] && ok "public REST via internal (200)" || no "public REST int -> $c"
# 7 auth negative -> 401
c=$(curl -sk --resolve $EXT:443:$GWIP -H "authorization: Bearer bad" --max-time 8 https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}"); [ "$c" = 401 ] && ok "bad-token rejected (401)" || no "bad-token -> $c"
# 8 console gRPC Connect ext -> routed to console-proxy (Unauthenticated)
o=$(grpcurl -insecure -authority $EXT -H "authorization: Bearer $TOK" -max-time 8 $GWIP:443 osac.public.v1.ConsoleProxy/Connect 2>&1|grep -v Warning|head -2|tr "\n" " "); case "$o" in *Unauthenticated*|*Unavailable*|*Unimplemented*) ok "console gRPC routed ext ($o)";; *) no "console gRPC ext -> $o";; esac
# 9 console WS route ext -> 426 upgrade
c=$(curl -sk --resolve $EXT:443:$GWIP -H "authorization: Bearer $TOK" --max-time 8 https://$EXT/api/fulfillment/v1/console_sessions/connect -o /dev/null -w "%{http_code}"); [ "$c" = 426 ] && ok "console WS routed ext (426 Upgrade)" || no "console WS ext -> $c"
# 10 ALPN h2
a=$(echo | openssl s_client -connect $GWIP:443 -servername $EXT -alpn h2 2>/dev/null | grep -i "ALPN protocol"); case "$a" in *h2*) ok "ALPN negotiates h2";; *) no "ALPN -> $a";; esac
echo "=== RESULT: $P passed, $F failed ==="
