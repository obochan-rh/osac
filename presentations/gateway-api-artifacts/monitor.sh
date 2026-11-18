#!/bin/bash
export KUBECONFIG=/root/.kube/dev.kubeconfig
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
INT=fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
GWIP=192.168.160.240; LOG=/root/gw-poc/soak.log; K=/home/cluster-tool/flavors/sno-4-22/crypto/cluster-tool.key
dur=${1:-16200}; endt=$(( $(date +%s)+dur ))
echo "=== MONITOR START $(date -u) dur=${dur}s (10-min samples, 30s watch probe) ===" >> $LOG
i=0
while [ $(date +%s) -lt $endt ]; do
  i=$((i+1)); ts=$(date -u +%H:%M:%S); T=$(oc create token admin -n osac --duration=15m 2>/dev/null)
  r=$(curl -sk --resolve $EXT:443:$GWIP -H "authorization: Bearer $T" --max-time 8 https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}" 2>/dev/null)
  ir=$(curl -sk --resolve $INT:443:$GWIP -H "authorization: Bearer $T" --max-time 8 https://$INT/api/fulfillment/v1/compute_instances -o /dev/null -w "%{http_code}" 2>/dev/null)
  timeout 32 grpcurl -insecure -authority $EXT -H "authorization: Bearer $T" -d "{}" $GWIP:443 osac.public.v1.Events.Watch >/dev/null 2>&1; wrc=$?
  [ "$wrc" = 124 ] && ws=OK30 || ws="rc$wrc"
  nr=$(oc get pods -n osac --no-headers 2>/dev/null | grep -vcE "Running|Completed")
  rst=$(oc get pods -n osac --no-headers 2>/dev/null | awk "{s+=\$4}END{print s+0}")
  var=$(ssh -i $K -o StrictHostKeyChecking=no -o ConnectTimeout=8 core@192.168.160.10 "df -h /var|tail -1|awk \"{print \\\$5}\"" 2>/dev/null)
  fxx=$(oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=osac-gateway --since=11m 2>/dev/null | grep -E "\" 5[0-9][0-9] ")
  gw5=$(echo "$fxx" | grep -c .)
  no5=$(echo "$fxx" | grep -vcE "cluster_templates|baremetal_instance_templates|add_on_operators|/clusters")
  echo "mon$i $ts REST=$r/$ir watch=$ws nonrun=$nr restarts=$rst var=$var gw5xx11m=$gw5 nonCaaS5xx=$no5" >> $LOG
  sleep 600
done
echo "=== MONITOR END $(date -u) ===" >> $LOG
