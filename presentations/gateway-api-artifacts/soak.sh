#!/bin/bash
export KUBECONFIG=/root/.kube/dev.kubeconfig
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
GWIP=192.168.160.240; LOG=/root/gw-poc/soak.log; K=/home/cluster-tool/flavors/sno-4-22/crypto/cluster-tool.key
dur=${1:-3300}; endt=$(( $(date +%s) + dur ))
WTOK=$(oc create token admin -n osac --duration=60m 2>/dev/null)
( grpcurl -insecure -authority $EXT -H "authorization: Bearer $WTOK" -d "{}" $GWIP:443 osac.public.v1.Events.Watch > /root/gw-poc/soak-watch.out 2>&1; echo "WATCH-STREAM ENDED $(date -u +%T) rc=$?" >> $LOG ) &
WPID=$!
echo "=== SOAK START $(date -u) dur=${dur}s (continuous Watch pid=$WPID) ===" >> $LOG
i=0
while [ $(date +%s) -lt $endt ]; do
  i=$((i+1)); ts=$(date -u +%H:%M:%S); T=$(oc create token admin -n osac --duration=15m 2>/dev/null)
  r=$(curl -sk --resolve $EXT:443:$GWIP -H "authorization: Bearer $T" --max-time 8 https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}" 2>/dev/null)
  ir=$(curl -sk --resolve $INT:443:$GWIP -H "authorization: Bearer $T" --max-time 8 https://$INT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}" 2>/dev/null)
  nr=$(oc get pods -n osac --no-headers 2>/dev/null | grep -vcE "Running|Completed")
  rst=$(oc get pods -n osac --no-headers 2>/dev/null | awk "{s+=\$4}END{print s+0}")
  var=$(ssh -i $K -o StrictHostKeyChecking=no -o ConnectTimeout=8 core@192.168.160.10 "df -h /var|tail -1|awk \"{print \\\$5}\"" 2>/dev/null)
  fxx=$(oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=osac-gateway --since=6m 2>/dev/null | grep -E "\" 5[0-9][0-9] ")
  gw5=$(echo "$fxx" | grep -c .)
  [ "${gw5:-0}" -gt 0 ] && { echo "=== 5xx @cyc$i $ts ==="; echo "$fxx" | sort -u | tail -6; } >> /root/gw-poc/soak-5xx.log
  kill -0 $WPID 2>/dev/null && w=UP || w=DOWN
  echo "cyc$i $ts REST=$r/$ir nonrun=$nr restarts=$rst var=$var gw5xx6m=$gw5 watch=$w" >> $LOG
  sleep 300
done
kill $WPID 2>/dev/null
echo "=== SOAK END $(date -u) ===" >> $LOG
