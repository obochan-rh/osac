#!/usr/bin/env bash
set -uo pipefail
export KUBECONFIG=/root/.kube/dev.kubeconfig
VIP=192.168.160.240
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
GWSEL=gateway.networking.k8s.io/gateway-name=osac-gateway
TOK=$(oc create token admin -n osac)
gp(){ timeout 12 grpcurl -insecure -servername "$1" -H "authorization: Bearer $TOK" -d "$3" "$VIP:443" "$2" 2>&1; }
showlog(){ grep -oE "^\[[^]]+\]|outbound\|[0-9]+\|\|[a-z.-]+|osac\.osac-(ext|int)\.[0-9]+" <<<"$1" | tr "\n" " "; echo; }

echo "########## 1. ROUTE CONFIG ##########"
for r in osac-ext osac-int; do
  echo -n "  $r rule[4]: "; oc get httproute $r -n osac -o jsonpath="{.spec.rules[4].matches[0].path}"; echo
  echo -n "  $r status : "; oc get httproute $r -n osac -o jsonpath="{range .status.parents[0].conditions[*]}{.type}={.status} {end}"; echo
done

echo "########## 2. CONNECT ROUTING (expect Unauthenticated=console-proxy, NOT Unimplemented) ##########"
for i in 1 2 3; do echo "  ext #$i:"; gp "$EXT" osac.public.v1.ConsoleProxy/Connect "{}" | grep -E "Code:|Message:" | sed "s/^/    /"; done
echo "  int  :"; gp "$INT" osac.public.v1.ConsoleProxy/Connect "{}" | grep -E "Code:|Message:" | sed "s/^/    /"

echo "########## 3. NEGATIVE CONTROL — unary VirtualNetworks/List (must still reach grpc-server) ##########"
gp "$EXT" osac.public.v1.VirtualNetworks/List "{}" | head -4 | sed "s/^/    /"

echo "########## 4. ACCESS-LOG CORRELATION ##########"
sleep 2
echo "  -- Connect (expect fulfillment-console-proxy + osac-*.4):"
oc logs -n openshift-ingress -l "$GWSEL" --tail=1200 2>/dev/null | grep "ConsoleProxy/Connect" | tail -4 | while IFS= read -r L; do echo -n "    "; showlog "$L"; done
echo "  -- unary List (expect fulfillment-grpc-server + .5):"
oc logs -n openshift-ingress -l "$GWSEL" --tail=1200 2>/dev/null | grep "VirtualNetworks/List" | tail -3 | while IFS= read -r L; do echo -n "    "; showlog "$L"; done

echo "########## 5. REGRESSION BATTERY ##########"
for H in "$EXT" "$INT"; do
  c=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "$H:443:$VIP" -H "authorization: Bearer $TOK" "https://$H/api/fulfillment/v1/compute_instances"); echo "  REST $H -> $c"
done
jc=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "$EXT:443:$VIP" "https://$EXT/.well-known/jwks.json"); echo "  jwks -> $jc"
echo -n "  reflection services via gateway: "; timeout 10 grpcurl -insecure -servername "$EXT" -H "authorization: Bearer $TOK" "$VIP:443" list 2>&1 | tr "\n" " " | head -c 260; echo
echo -n "  quiet Watch 25s hold (124=held OK): rc="; timeout 25 grpcurl -insecure -servername "$EXT" -H "authorization: Bearer $TOK" -d "{}" "$VIP:443" osac.public.v1.Events/Watch >/dev/null 2>&1; echo $?
