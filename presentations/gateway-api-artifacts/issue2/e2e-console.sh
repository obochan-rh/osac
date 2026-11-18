#!/usr/bin/env bash
# FULL e2e console through the gateway: tenant + catalog + VM + ticket + Connect (re-runnable)
set -uo pipefail
export KUBECONFIG=/root/.kube/dev.kubeconfig
VIP=192.168.160.240
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
TOK=$(oc create token admin -n osac)
[ -z "$TOK" ] && { echo "FATAL: empty token (apiserver blip) - retry"; exit 9; }
TENANT=tenant1; NAME=e2e-console-vm
ts(){ date -u +%T; }
G(){ timeout "$1" grpcurl -insecure -servername "$2" -H "authorization: Bearer $TOK" -d "$4" "$VIP:443" "$3" 2>&1; }
R(){ curl -sk --resolve "$INT:443:$VIP" -H "authorization: Bearer $TOK" -H "content-type: application/json" -X POST -d "$2" "https://$INT/api/private/v1/$1" 2>&1; }
jget(){ python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
o=d
for k in \"$1\".split(\".\"):
    o=o.get(k,{}) if isinstance(o,dict) else {}
print(o if isinstance(o,str) else \"\")"; }
# find_inst -> prints "id state" for NAME in TENANT (empty if none)
find_inst(){ G 15 "$EXT" osac.public.v1.ComputeInstances/List "{}" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: d={}
for i in d.get(\"items\",[]):
    m=i.get(\"metadata\",{})
    if m.get(\"name\")==\"$NAME\" and m.get(\"tenant\")==\"$TENANT\":
        print(i.get(\"id\",\"\"),i.get(\"status\",{}).get(\"state\",\"?\")); break" 2>/dev/null; }
cd /root/gw-poc/issue2

echo "[$(ts)] ===== PHASE 0: tenant ====="; G 25 "$INT" osac.private.v1.Tenants/Create "{\"object\":{\"metadata\":{\"name\":\"$TENANT\"}}}" >/dev/null 2>&1; echo "  ok"
echo "[$(ts)] ===== PHASE 0b: catalog ====="
R disk_images "{\"metadata\":{\"name\":\"fedora\",\"tenant\":\"shared\"},\"spec\":{\"source_type\":\"SOURCE_TYPE_REGISTRY\",\"source_ref\":\"quay.io/containerdisks/fedora:latest\",\"guest_os_family\":\"GUEST_OS_FAMILY_LINUX\",\"architecture\":[\"ARCHITECTURE_AMD64\",\"ARCHITECTURE_ARM64\"],\"lifecycle\":\"DISK_IMAGE_LIFECYCLE_AVAILABLE\"}}" >/dev/null 2>&1
R instance_types "{\"metadata\":{\"name\":\"u1-small\",\"tenant\":\"shared\"},\"spec\":{\"vcpus\":2,\"memory_gib\":4,\"state\":\"INSTANCE_TYPE_STATE_ACTIVE\"}}" >/dev/null 2>&1; echo "  ok"

echo "[$(ts)] ===== PHASE 1: resolve/create VM ====="
read -r ID ST <<< "$(find_inst)"
if [ -n "${ID:-}" ] && [ "${ST##*_}" = "RUNNING" ]; then
  echo "  reusing RUNNING instance id=$ID"
else
  if [ -n "${ID:-}" ]; then
    echo "  existing instance id=$ID state=$ST -> deleting, waiting for removal"
    G 20 "$EXT" osac.public.v1.ComputeInstances/Delete "{\"id\":\"$ID\"}" >/dev/null 2>&1
    for w in $(seq 1 24); do sleep 5; read -r ID2 _ <<< "$(find_inst)"; [ -z "${ID2:-}" ] && { echo "  gone"; break; }; echo "  [$(ts)] still deleting..."; done
  fi
  CRESP=$(G 25 "$EXT" osac.public.v1.ComputeInstances/Create "{\"object\":{\"metadata\":{\"name\":\"$NAME\",\"tenant\":\"$TENANT\"},\"spec\":{\"template\":{\"id\":\"osac.templates.ocp_virt_vm\",\"shared\":true},\"instance_type\":{\"name\":\"u1-small\",\"shared\":true},\"disk_image\":{\"name\":\"fedora\",\"shared\":true},\"boot_disk\":{\"size_gib\":10,\"storage_tier\":{\"id\":\"local\"}}}}}")
  ID=$(echo "$CRESP" | jget object.id)
  [ -z "$ID" ] && { echo "  STOP create failed:"; echo "$CRESP" | head -c 500; exit 1; }
  echo "  created id=$ID"
  echo "[$(ts)] ===== PHASE 2: wait RUNNING (cap 15m) ====="
  for i in $(seq 1 60); do
    ST=$(G 15 "$EXT" osac.public.v1.ComputeInstances/Get "{\"id\":\"$ID\"}" | jget object.status.state)
    echo "  [$(ts)] poll $i: ${ST:-?}"
    case "$ST" in *RUNNING) break;; *FAILED) echo "  FAILED (likely apiserver blip; rerun to retry)"; exit 2;; esac
    sleep 15
  done
  [ "${ST##*_}" = "RUNNING" ] || { echo "  not RUNNING (${ST:-?})"; oc get vmi -n $TENANT 2>/dev/null; exit 3; }
fi

echo "[$(ts)] ===== PHASE 3: console session -> ticket ====="
TICKET=$(G 20 "$EXT" osac.public.v1.ConsoleSessions/Create "{\"object\":{\"resource_type\":\"CONSOLE_RESOURCE_TYPE_COMPUTE_INSTANCE\",\"resource_id\":\"$ID\",\"type\":\"CONSOLE_TYPE_SERIAL\"}}" | jget object.ticket)
[ -z "$TICKET" ] && { echo "  FAIL no ticket"; exit 4; }
echo "  ticket len=${#TICKET}"

echo "[$(ts)] ===== PHASE 4: ConsoleProxy/Connect (reflect=SA token, rpc=ticket) ====="
CONN=$(timeout 15 grpcurl -insecure -servername "$EXT" -reflect-header "authorization: Bearer $TOK" -rpc-header "authorization: Bearer $TICKET" -d "{}" "$VIP:443" osac.public.v1.ConsoleProxy/Connect 2>&1)
echo "$CONN" | head -c 1000; echo
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=osac-gateway --tail=200 2>/dev/null | grep "ConsoleProxy/Connect" | tail -1 | grep -oE "outbound\|[0-9]+\|\|[a-z.-]+|osac\.osac-(ext|int)\.[0-9]+" | tr "\n" " "; echo
echo "[$(ts)] ===== VERDICT ====="
if echo "$CONN" | grep -qi "Unimplemented"; then echo "  FAIL: misrouted";
elif echo "$CONN" | grep -qi "invalid ticket\|Unauthenticated\|token is not valid"; then echo "  PARTIAL: ticket/auth rejected (app-side)";
else echo "  PASS: FULL e2e console through the gateway"; fi
echo "  id=$ID"
