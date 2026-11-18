#!/usr/bin/env bash
# ISSUE-2 fix: route ConsoleProxy/Connect by Exact match (beats the broad grpc regex deterministically).
set -uo pipefail
export KUBECONFIG=/root/.kube/dev.kubeconfig
VIP=192.168.160.240
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
GWSEL=gateway.networking.k8s.io/gateway-name=osac-gateway
TOK=$(oc create token admin -n osac)
cd /root/gw-poc/issue2
ts(){ date -u +%FT%TZ; }
PATCH='[{"op":"replace","path":"/spec/rules/4/matches/0","value":{"path":{"type":"Exact","value":"/osac.public.v1.ConsoleProxy/Connect"}}}]'

echo "[$(ts)] current rule[4] match (both routes), BEFORE:"
for r in osac-ext osac-int; do echo -n "  $r rule4: "; oc get httproute $r -n osac -o jsonpath='{.spec.rules[4].matches[0].path}'; echo; done

echo "[$(ts)] === APPLY: Connect -> Exact ==="
oc patch httproute osac-ext -n osac --type=json -p "$PATCH"
oc patch httproute osac-int -n osac --type=json -p "$PATCH"

echo "[$(ts)] rule[4] match AFTER:"
for r in osac-ext osac-int; do echo -n "  $r rule4: "; oc get httproute $r -n osac -o jsonpath='{.spec.rules[4].matches[0].path}'; echo; done
echo "[$(ts)] route Accepted/ResolvedRefs:"
oc get httproute osac-ext osac-int -n osac -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.parents[0].conditions[*].type}{"="}{.status.parents[0].conditions[*].status}{"\n"}{end}'

echo "[$(ts)] waiting 8s for istio to reprogram..."; sleep 8

echo "[$(ts)] === AFTER: Connect probe (expect NOT Unimplemented) ==="
timeout 12 grpcurl -insecure -servername "$EXT" -H "authorization: Bearer $TOK" -d "{}" "$VIP:443" osac.public.v1.ConsoleProxy/Connect 2>&1 | head -5 | tee connect-after.txt

echo "[$(ts)] === AFTER: access-log for ConsoleProxy/Connect (expect fulfillment-console-proxy) ==="
oc logs -n openshift-ingress -l "$GWSEL" --tail=300 2>/dev/null | grep "ConsoleProxy/Connect" | tail -2 | tee aclog-after.txt

echo "[$(ts)] === REGRESSION sanity ==="
for H in "$EXT" "$INT"; do
  c=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "$H:443:$VIP" -H "authorization: Bearer $TOK" "https://$H/api/fulfillment/v1/compute_instances")
  echo "  REST $H -> $c"
done
echo "  Watch quiet 20s hold (124=held OK):"
timeout 20 grpcurl -insecure -servername "$EXT" -H "authorization: Bearer $TOK" -d "{}" "$VIP:443" osac.public.v1.Events/Watch >/dev/null 2>&1; echo "    rc=$?"

echo "[$(ts)] === VERDICT ==="
if grep -qi Unimplemented connect-after.txt; then
  echo "  FAIL: still Unimplemented -> inspect aclog-after.txt (check backend) + route status"
elif grep -qi "console-proxy" aclog-after.txt; then
  echo "  PASS: Connect now routed to fulfillment-console-proxy (no longer Unimplemented)"
else
  echo "  LIKELY PASS: Connect no longer Unimplemented; confirm backend in aclog-after.txt"
fi
echo "  rollback: oc apply -f /root/gw-poc/issue2/routes-before.yaml"
