# OSAC — External Services Runbook (edge-04 lab)

> **Purpose:** Complete runbook for running OSAC's four backing services
> (PostgreSQL, OpenBao, Keycloak, Kafka) **outside** the OpenShift cluster as
> podman containers on the edge-04 KVM host. It captures everything that was
> changed, patched, and scripted to make and keep the lab running on
> externals: container run commands exactly as deployed, systemd units,
> TLS/certificate handling, cluster wiring, Helm values, backup/restore,
> verification, rollback, and every gotcha hit live.
>
> **Environment:** `edge-04.ecosys.eng.rdu2.dc.redhat.com` (RHEL host),
> SNO hub `osac-hub-master-0` (node `52-54-00-f7-c6-83`, VM `192.168.127.19`),
> all externals published on the libvirt bridge IP **`192.168.127.1`**.
> Installer chart pin `fc7a09f` (`/root/workspace/git/osac/osac-installer` on
> edge-04); Helm releases `osac` (ns `osac`), `osac-infra` (ns `osac-infra`),
> `osac-deps` (ns `osac-deps`).
>
> **Execution history:** Phase 1 PostgreSQL 2026-10-14 · Phase 2 OpenBao
> 2026-10-19/20 · Phase 3 Keycloak 2026-10-20 · Phase 5 Kafka 2026-10-21/22.
>
> **Credential policy:** this guide deliberately contains **no credentials**.
> Wherever a secret is involved it uses `<PLACEHOLDER>` markers and names the
> root-only file or cluster Secret that holds the real value
> (`/root/osac-kafka-external/credentials.env`, `/root/openbao-init.json`,
> cluster Secrets `external-kafka-credentials` / `osac-metering`, …). Unlike
> its sibling [`keycloak-edge04-setup.md`](keycloak-edge04-setup.md), this file
> is safe to share or upstream once reviewed.
>
> **See also:**
> [`docs/guides/installation/external-services-support-guide.md`](../docs/guides/installation/external-services-support-guide.md) —
> the general-use guide distilled from this deployment (same procedures, all
> site specifics removed) ·
> [`deploy-osac-external-services.md`](deploy-osac-external-services.md) — the
> generic external-services procedure (Keycloak/OpenBao/Kafka background and
> rationale) · [`keycloak-edge04-setup.md`](keycloak-edge04-setup.md) — the
> Keycloak + LDAP experiment history (contains lab passwords, untracked) ·
> upstream [`docs/guides/installation/kafka-configuration.md`](https://github.com/osac-project/osac/blob/main/docs/guides/installation/kafka-configuration.md)
> — the external-Kafka contract this lab implements (OSAC-4760) ·
> [`../../EDGE-04-DEPLOYMENT.md`](../../EDGE-04-DEPLOYMENT.md) — the full lab
> deployment history this guide is distilled from.

---

## Table of Contents

1. [Architecture and inventory](#1-architecture-and-inventory)
2. [Host prerequisites](#2-host-prerequisites)
3. [PostgreSQL (Phase 1)](#3-postgresql-phase-1)
4. [OpenBao (Phase 2)](#4-openbao-phase-2)
5. [Keycloak (Phase 3)](#5-keycloak-phase-3)
6. [Kafka (Phase 5)](#6-kafka-phase-5)
7. [Helm values reference](#7-helm-values-reference)
8. [The reapply script — mandatory after every `helm upgrade`](#8-the-reapply-script--mandatory-after-every-helm-upgrade)
9. [Verification battery](#9-verification-battery)
10. [Backups overview](#10-backups-overview)
11. [Gotchas compendium](#11-gotchas-compendium)
12. [Rollback matrix](#12-rollback-matrix)

---

## 1. Architecture and inventory

```
                    workstation
                        │ ssh (FQDN only — bare "edge-04" does not resolve)
                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ edge-04 host (10.6.141.78 / bridge 192.168.127.1)                       │
│                                                                         │
│  osac-postgres   192.168.127.1:5432   TLS + client-cert auth            │
│  osac-openbao    192.168.127.1:8200   TLS, file storage, auto-unseal    │
│                 (192.168.127.1:8201   cluster port, unused single-node) │
│  keycloak-lab    192.168.127.1:8443   TLS (route cert, hostname preserved) │
│  osac-kafka      192.168.127.1:9092   SASL_SSL SCRAM-SHA-512, KRaft     │
│                                                                         │
│  SNO hub VM 192.168.127.19 (osac-hub-master-0) — pods reach 192.168.127.1 │
│  directly (same subnet; edge-04 is the gateway)                         │
└─────────────────────────────────────────────────────────────────────────┘
```

| Service | Container (podman) | Port | systemd unit | Data on host | Nightly backup | Cluster wiring |
|---|---|---|---|---|---|---|
| PostgreSQL | `osac-postgres` (sclorg `postgresql-18-c10s`) | 5432 | `container-osac-postgres.service` (old-style) | `/var/lib/osac/postgres` | 02:17 → `/var/lib/osac/backups` | selectorless svc `postgres` + Endpoints (ns `osac-infra`) |
| OpenBao | `osac-openbao` (`ghcr.io/openbao/openbao:2.6.2`) | 8200/8201 | `container-osac-openbao.service` (`--new`-style + unseal drop-in) | `/root/bao-data` | 02:30 → `/root/bao-backup` | values: `service.vault.endpoint` |
| Keycloak | `keycloak-lab` (`quay.io/keycloak/keycloak:26.6.4`) | 8443 | `container-keycloak-lab.service` (old-style) | `/root/kc-data` (H2) | 02:00 → `/root/kc-backup` | selectorless svc `keycloak` + Endpoints (ns `keycloak`), passthrough route unchanged |
| Kafka | `osac-kafka` (`docker.io/apache/kafka:4.2.0`) | 9092 | `container-osac-kafka.service` (oneshot) | `/var/lib/osac/kafka/data` | — (event log, retention 7 d) | values: `kafka.enabled: false` + `service.kafka.connection` + `metering.kafka.*` |

**Three distinct wiring patterns were used — know which is which:**

1. **Selectorless Service + manual Endpoints** (PostgreSQL, Keycloak): the
   chart-owned in-cluster Service keeps its name/ClusterIP, its
   `spec.selector` is removed, and a manual `Endpoints` object points at the
   host IP. Nothing inside the cluster changes — same DNS name, same port,
   same TLS, same credentials. The trade-off: every `helm upgrade` re-creates
   the selector, so the cutover must be **re-applied after every upgrade**
   (section [8]).
2. **Supported chart-values path** (OpenBao): `bundledVault.enabled: false` in
   `osac-infra` + `service.vault.endpoint: https://192.168.127.1:8200` in the
   `osac` release. Survives upgrades by design.
3. **Supported chart-values path** (Kafka): exactly the upstream
   [external-Kafka contract](https://github.com/osac-project/osac/blob/main/docs/guides/installation/kafka-configuration.md) —
   `kafka.enabled: false` + `service.kafka.connection` (ConfigMap/Secret
   sources) + `metering.kafka.*` (the metering part is a lab extension, see
   §6.3). Survives upgrades by design.

**What is deliberately NOT externalized:** the AAP stack (`osac-aap-*`
deployments), CNV/KubeVirt, LVMS, cert-manager, trust-manager, MetalLB —
these still run in-cluster. The bundled Keycloak *database*
(`keycloak-database-0`) is kept scaled-to-0 as a rollback point.

---

## 2. Host prerequisites

### 2.1 Access and network

```bash
# from the workstation — ALWAYS the FQDN (bare "edge-04" does not resolve)
ssh -i /home/obochan/.ssh/id_ed25519 root@edge-04.ecosys.eng.rdu2.dc.redhat.com

# on edge-04: the hub kubeconfig
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

# hub VM shell (from edge-04)
ssh core@192.168.127.19
```

The SNO node (`192.168.127.19`) and the host bridge (`192.168.127.1`) share
the `192.168.127.0/24` libvirt network — edge-04 is its gateway — so **pods
reach the externals directly**, and every external publishes only on the
bridge IP (`-p 192.168.127.1:<port>:<port>`), never on all interfaces. The
workstation cannot route to `192.168.127.1`; run verification from edge-04 or
the hub VM (or forward, see [`keycloak-edge04-setup.md`](keycloak-edge04-setup.md) Part 4).

### 2.2 Podman storage and SELinux

podman's graphroot is non-standard (`/home/containers/storage`). File-context
rules were added once so containers run with **normal** SELinux labels:

```bash
semanage fcontext -a -e /var/lib/containers /home/containers
restorecon -R /home/containers
```

Consequences per container:

- `osac-postgres` runs **without** `--security-opt label=disable` — do not add
  it; the bind mounts work with normal labels and the fcontext rules above.
- `osac-openbao`, `keycloak-lab`, `osac-kafka` all run **with**
  `--security-opt label=disable` (OpenBao/KC fail without it on RHEL —
  `libc.so.6: cannot apply additional memory protection`; Kafka's JVM hits
  the same class of denial).

### 2.3 Clock synchronization

JWT tokens carry `iat`; if the host and the OCP node diverge by more than
~30 s, auth fails with `token issue time is in the future`. Diagnose with
`podman exec keycloak-lab date -u` vs `oc -n osac exec deploy/fulfillment-grpc-server -- date -u`.
Fix with `chronyc -a makestep` (or `date -u -s` after stopping chronyd) —
the hub node has a known chrony drift, flagged in `oc get co machine-config`.

### 2.4 Certificate trust

The hub's trust root is the cert-manager `ClusterIssuer` **`default-ca`**,
distributed via trust-manager into the `ca-bundle` ConfigMap (every
namespace). Two exploitation strategies were used:

- **Kafka**: broker cert **issued by** `default-ca` (a cert-manager
  `Certificate` CR in ns `osac`, IP SAN `192.168.127.1`) → the existing
  `ca-bundle` already trusts it; **zero trust changes**.
- **OpenBao**: self-signed host cert added as a new source to the
  `Bundle.trust.cert-manager.io ca-bundle` CR (see §4.3).
- **Keycloak**: the external instance serves the **route cert** (issued by
  `default-ca`, extracted from the in-cluster Secret `keycloak-tls-cert`) →
  hostname preservation, zero trust changes (§5).
- **PostgreSQL**: same server/client certs as the bundled instance, extracted
  before cutover (§3.1) → zero trust changes.

> Never edit the `ca-bundle` ConfigMap directly — trust-manager reverts it
> within seconds. Always patch the `Bundle` CR.

---

## 3. PostgreSQL (Phase 1)

**Approach:** run the *same* image with the *same* TLS material and HBA rules
as the bundled instance, migrate data with `pg_dumpall`, then flip the
Service to selectorless + manual Endpoints. Because the server cert's SANs
still say `postgres.osac-infra.svc.cluster.local` and client certs still say
`CN=service` / `CN=metering`, **no application, Secret, or Helm value changes
at all** — `osac-db-config` (URL `postgres.osac-infra.svc:5432`) and the
client-cert Secrets keep working verbatim.

### 3.1 Run the container

Config and TLS material live in `/etc/osac/postgres/` (all files owned by
`26:26`, the image's `postgres` uid):

```
/etc/osac/postgres/
├── server.conf      # ssl=on, points at the three files below
├── access.conf      # HBA: local peer; hostssl … cert (client-certificate auth)
├── ca-bundle.pem    # CA that signs the client certs
├── tls.crt / tls.key         # server cert (SANs cover postgres.osac-infra.svc…)
└── client-service.crt/.key, client-metering.crt/.key   # extracted client certs
```

```ini
# /etc/osac/postgres/server.conf
ssl = on
ssl_ca_file = '/config/ca/bundle.pem'
ssl_cert_file = '/secrets/cert/tls.crt'
ssl_key_file = '/secrets/cert/tls.key'
hba_file = '/config/access/access.conf'
```

```ini
# /etc/osac/postgres/access.conf
local all all peer
hostssl all all 0.0.0.0/0 cert
hostssl all all ::0/0 cert
```

The TLS material was extracted from the in-cluster instance's Secrets before
cutover (server cert + CA + both client certs) — that is what makes
"cert-auth unchanged" true. The container itself:

```bash
podman run -d --name osac-postgres \
  -p 192.168.127.1:5432:5432 \
  -v /etc/osac/postgres/server.conf:/opt/app-root/src/postgresql-cfg/server.conf:ro \
  -v /etc/osac/postgres/access.conf:/config/access/access.conf:ro \
  -v /etc/osac/postgres/ca-bundle.pem:/config/ca/bundle.pem:ro \
  -v /etc/osac/postgres/tls.crt:/secrets/cert/tls.crt:ro \
  -v /etc/osac/postgres/tls.key:/secrets/cert/tls.key:ro \
  -v /var/lib/osac/postgres:/var/lib/pgsql \
  -e POSTGRESQL_USER=service \
  -e POSTGRESQL_DATABASE=service \
  -e POSTGRESQL_PASSWORD=<POSTGRES_SUPERUSER_PASSWORD> \
  quay.io/sclorg/postgresql-18-c10s@sha256:6be2c9d855f06fb665257a6b0911676a38d740be7022cc61acee1c99a832b1b2

# make it survive reboots (old-style unit: container persists, unit just starts it)
podman generate systemd --name osac-postgres --restart-policy=on-failure \
  > /etc/systemd/system/container-osac-postgres.service
systemctl daemon-reload && systemctl enable --now container-osac-postgres.service
```

Notes:

- **Durability:** the bundled chart ran `fsync=off` / `full_page_writes=off`
  (dev profile). This container sets neither → PostgreSQL defaults (`on`)
  apply. Do not "optimize" them back off.
- The unit is the **old style** (`ExecStart=/usr/bin/podman start
  osac-postgres`, `Type=forking`): the container is a persistent object,
  `podman stop/start` works directly and systemd does not fight you. This
  matters — see the systemd patterns table in §11.
- The workload databases are `osac_service` and `osac_metering`, roles
  `service` and `metering` (client-cert CNs), created during data migration.

### 3.2 Migrate the data

```bash
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

# 1. quiesce the workload deployments (keep a record for scaling back!)
oc -n osac get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas \
  | awk 'NR>1 && $2>0 {print "deployment/"$1, $2}' > /root/osac-pg-migration/scaled.txt
while read -r kind name ns r; do oc -n osac scale $kind/$name --replicas=0; done < <(…)

# 2. dump everything from the bundled instance
oc -n osac-infra exec deploy/postgres -- pg_dumpall -U postgres \
  > /root/osac-pg-migration/dumpall.sql

# 3. restore into the external instance
podman exec -i osac-postgres psql -U postgres < /root/osac-pg-migration/dumpall.sql

# 4. verify per-table row counts are identical (116 tables in osac_service,
#    2 in osac_metering at migration time)
```

### 3.3 Cutover — selectorless Service + Endpoints

The chart still owns svc `postgres` in `osac-infra`. The cutover removes its
selector and writes a manual Endpoints object; the EndpointSlice mirroring
controller then re-creates the slice from the Endpoints (a stale slice from
the pod era must be deleted first). The full script, exactly as run:

```bash
#!/bin/bash
# Phase 1 cutover completion - idempotent. Safe to re-run.
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig
MIG=/root/osac-pg-migration

echo "=== [1] rewire Service postgres -> 192.168.127.1:5432 ($(date +%H:%M:%S))"
oc -n osac-infra patch svc postgres --type=json -p '[{"op":"remove","path":"/spec/selector"}]' >/dev/null 2>&1 || true
oc -n osac-infra patch endpoints postgres --type=merge -p '{"subsets":[{"addresses":[{"ip":"192.168.127.1"}],"ports":[{"name":"postgres","port":5432,"protocol":"TCP"}]}]}' >/dev/null 2>&1 || true
echo "  selector: $(oc -n osac-infra get svc postgres -o jsonpath='{.spec.selector}')"
echo "  endpoints: $(oc -n osac-infra get endpoints postgres -o jsonpath='{.subsets[0].addresses[0].ip}'):$(oc -n osac-infra get endpoints postgres -o jsonpath='{.subsets[0].ports[0].port}')"

echo "=== [2] endpointslice state"
oc -n osac-infra get endpointslice -l kubernetes.io/service-name=postgres -o json 2>/dev/null | python3 -c "
import json,sys
try:
    sl=json.load(sys.stdin).get('items',[])
    if not sl: print('  none present')
    for s in sl: print(' ', s['metadata']['name'], '->', [a for e in s.get('endpoints',[]) for a in e.get('addresses',[])])
except Exception: print('  none present')"
STALE=$(oc -n osac-infra get endpointslice -l kubernetes.io/service-name=postgres -o json 2>/dev/null | python3 -c "
import json,sys
try:
    sl=json.load(sys.stdin).get('items',[])
    print('yes' if any(a!='192.168.127.1' for s in sl for e in s.get('endpoints',[]) for a in e.get('addresses',[])) or not sl else 'no')
except Exception: print('no')")
if [ "$STALE" = "yes" ]; then
  echo "  stale/missing slices -> deleting for re-mirror"
  oc -n osac-infra delete endpointslice -l kubernetes.io/service-name=postgres >/dev/null 2>&1 || true
  sleep 10
  LEFT=$(oc -n osac-infra get endpointslice -l kubernetes.io/service-name=postgres --no-headers 2>/dev/null | wc -l)
  if [ "$LEFT" = "0" ]; then
    echo "  mirroring controller did not recreate - creating manual slice"
    oc apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: postgres-external
  namespace: osac-infra
  labels:
    kubernetes.io/service-name: postgres
addressType: IPv4
endpoints:
- addresses: ["192.168.127.1"]
ports:
- name: postgres
  port: 5432
  protocol: TCP
EOF
  fi
  oc -n osac-infra get endpointslice -l kubernetes.io/service-name=postgres -o json 2>/dev/null | python3 -c "
import json,sys
for s in json.load(sys.stdin).get('items',[]): print('  now:', s['metadata']['name'], '->', [a for e in s.get('endpoints',[]) for a in e.get('addresses',[])])" 2>/dev/null || true
fi

echo "=== [3] sanity: tenants on external"
echo "  tenants: $(podman exec osac-postgres psql -U postgres -d osac_service -Atc 'select count(*) from tenants' 2>/dev/null)"

echo "=== [4] scale workloads back up ($(date +%H:%M:%S))"
while read -r kind name ns r; do oc -n $ns scale $kind/$name --replicas=$r >/dev/null 2>&1; done < $MIG/scaled.txt
deadline=$((SECONDS+280)); bad="start"
while [ $SECONDS -lt $deadline ] && [ -n "$bad" ]; do
  bad=$(oc -n osac get deploy,sts -o json 2>/dev/null | python3 -c "
import json,sys
bad=[]
for d in json.load(sys.stdin)['items']:
    w=d['spec'].get('replicas') or 0
    c=d['status'].get('replicas') or 0
    av=[x.get('status') for x in d['status'].get('conditions',[]) if x.get('type')=='Available']
    if w>0 and (c<w or not av or av[0]!='True'): bad.append(d['metadata']['name'])
print(' '.join(bad))")
  [ -z "$bad" ] && break
  sleep 6
done
echo "  not-yet-available: ${bad:-none} (at $(date +%H:%M:%S))"

echo "=== [5] DATA PATH PROOF"
sleep 8
echo "  external PG app connections: $(podman exec osac-postgres psql -U postgres -Atc "select count(*) from pg_stat_activity where usename in ('service','metering')" 2>/dev/null)"
echo "  bundled PG app connections: $(oc -n osac-infra exec deploy/postgres -- psql -U postgres -Atc "select count(*) from pg_stat_activity where usename in ('service','metering')" 2>/dev/null)"
echo "=== [6] final pod status"
oc -n osac get pods -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase --no-headers 2>/dev/null | head -20
```

The three wiring commands at its heart (these are what the reapply script
re-runs after every `helm upgrade` of `osac-infra`):

```bash
oc -n osac-infra patch svc postgres --type=json -p '[{"op":"remove","path":"/spec/selector"}]'
oc -n osac-infra patch endpoints postgres --type=merge -p '{"subsets":[{"addresses":[{"ip":"192.168.127.1"}],"ports":[{"name":"postgres","port":5432,"protocol":"TCP"}]}]}'
oc -n osac-infra delete endpointslice -l kubernetes.io/service-name=postgres   # re-mirrors from Endpoints
```

Then flip the chart toggle so the bundled pod never comes back:

```bash
cd /root/workspace/git/osac/osac-installer
helm upgrade osac-infra charts/osac-infra -n osac-infra --reuse-values --set bundledPostgres.enabled=false
```

> **The supported alternative (not taken here):** the chart natively supports
> an external DB via `dbInit.host` + the `osac-db-config` / `osac-db-client-cert`
> Secrets + `bundledPostgres.enabled: false`. The lab kept the default
> `dbInit.host` and uses the selectorless Service instead — functionally
> identical, but it is why reapply section [1] exists. Converging to
> `dbInit.host` at a future upgrade would retire that section.

### 3.4 OAuth fix for operator + metering

The Oct-13 chart revision predates the OAuth wiring that consumes
`fulfillment-controller-credentials`, so after the PG cutover the operator
and metering deployments crashlooped (they could not get tokens to talk to
the API). The surgical fix — patched into the live deployments, and re-applied
by reapply sections [2]/[3] after every `helm upgrade` until the chart is
upgraded past the gap:

```bash
#!/bin/bash
# Surgical fix: wire fulfillment-controller-credentials into operator + metering
# (chart wiring for this landed upstream after the deployed Oct-13 release)
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

echo "=== [1] operator: check CA flag, add client id/secret env"
ARGS=$(oc -n osac get deploy osac-operator -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
if echo "$ARGS" | grep -q fulfillment-ca-file; then echo "  --fulfillment-ca-file already set"; else
  echo "  --fulfillment-ca-file MISSING, adding"
  if [ -z "$ARGS" ]; then
    oc -n osac patch deploy osac-operator --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--fulfillment-ca-file=/etc/ca-bundle/bundle.pem"]}]' >/dev/null
  else
    oc -n osac patch deploy osac-operator --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--fulfillment-ca-file=/etc/ca-bundle/bundle.pem"}]' >/dev/null
  fi
fi
oc -n osac patch deploy osac-operator --type=json -p '[
 {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OSAC_FULFILLMENT_CLIENT_ID","valueFrom":{"secretKeyRef":{"name":"fulfillment-controller-credentials","key":"client-id"}}}},
 {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OSAC_FULFILLMENT_CLIENT_SECRET","valueFrom":{"secretKeyRef":{"name":"fulfillment-controller-credentials","key":"client-secret"}}}}]' >/dev/null && echo "  operator env patched"

echo "=== [2] metering: add credentials volume + issuer env"
oc -n osac patch deploy osac-metering --type=json -p '[
 {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"fulfillment-credentials","secret":{"secretName":"fulfillment-controller-credentials","items":[{"key":"client-id","path":"client-id"},{"key":"client-secret","path":"client-secret"}]}}},
 {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"fulfillment-credentials","mountPath":"/etc/fulfillment-credentials","readOnly":true}},
 {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_ISSUER_URL","valueFrom":{"configMapKeyRef":{"name":"osac-fulfillment-config","key":"OSAC_FULFILLMENT_ISSUER_URL"}}}},
 {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_CLIENT_ID_FILE","value":"/etc/fulfillment-credentials/client-id"}},
 {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_CLIENT_SECRET_FILE","value":"/etc/fulfillment-credentials/client-secret"}}]' >/dev/null && echo "  metering patched"

echo "=== [3] rollout"
oc -n osac rollout status deploy/osac-operator --timeout=240s 2>&1 | tail -1
oc -n osac rollout status deploy/osac-metering --timeout=240s 2>&1 | tail -1

echo "=== [4] logs"
echo "--- operator:"; oc -n osac logs deploy/osac-operator --tail=8 2>&1 | tail -8
echo "--- metering:"; oc -n osac logs deploy/osac-metering --tail=8 2>&1 | tail -8

echo "=== [5] external PG connections (metering should appear = write path live)"
sleep 5
podman exec osac-postgres psql -U postgres -Atc "select usename || ' x' || count(*) from pg_stat_activity where usename in ('service','metering') group by 1" 2>/dev/null || echo "  (none yet)"

echo "=== [6] REST API proof: list tenants through the external DB"
TOK=$(oc -n osac create token client --duration=5m 2>/dev/null) || TOK=""
if [ -n "$TOK" ]; then
  CODE=$(curl -sk -o /tmp/tenants.json -w "%{http_code}" --max-time 20 -H "Authorization: Bearer $TOK" https://fulfillment-api-osac.apps.osac-hub.redhat.com/api/fulfillment/v1/tenants)
  echo "  GET /api/fulfillment/v1/tenants -> http=$CODE"
  python3 -c "
import json
try:
    d=json.load(open('/tmp/tenants.json'))
    items=d if isinstance(d,list) else d.get('tenants') or d.get('items') or []
    print('  tenants in response:', len(items), [t.get('name') or t.get('id') for t in items][:6])
except Exception as e: print('  parse:', e)" 2>/dev/null
else echo "  (could not create SA token)"; fi
sleep 2
echo "=== [7] external PG connections after API call"
podman exec osac-postgres psql -U postgres -Atc "select usename || ' x' || count(*) from pg_stat_activity where usename in ('service','metering') group by 1" 2>/dev/null || echo "  (none)"
```

### 3.5 Prove the write path

```bash
#!/bin/bash
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig
echo "=== baseline xact_commit on EXTERNAL ($(date +%H:%M:%S))"
podman exec osac-postgres psql -U postgres -Atc "select datname || ': ' || xact_commit from pg_stat_database where datname in ('osac_service','osac_metering') order by 1"
echo "=== metering row counts before:"
podman exec osac-postgres psql -U postgres -d osac_metering -Atc "select 'metering_resource_state=' || count(*) from metering_resource_state union all select 'meter_state=' || count(*) from metering_resource_meter_state" 2>/dev/null
echo "=== tenant CRs (for reconcile trigger):"
oc api-resources 2>/dev/null | grep -i "tenant" | head -3
oc get tenants -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | head -6
echo "=== waiting 70s through a metering heartbeat cycle..."
sleep 70
echo "=== xact_commit after ($(date +%H:%M:%S))"
podman exec osac-postgres psql -U postgres -Atc "select datname || ': ' || xact_commit from pg_stat_database where datname in ('osac_service','osac_metering') order by 1"
echo "=== live connections snapshot:"
podman exec osac-postgres psql -U postgres -Atc "select usename || ' -> ' || datname from pg_stat_activity where usename in ('service','metering')" 2>/dev/null || echo "  (none at this instant)"
echo "=== metering row counts after:"
podman exec osac-postgres psql -U postgres -d osac_metering -Atc "select 'metering_resource_state=' || count(*) from metering_resource_state union all select 'meter_state=' || count(*) from metering_resource_meter_state" 2>/dev/null
```

Expected: `xact_commit` on both databases rises over a 70 s window on the
**external** instance only; metering heartbeats keep inserting rows.

### 3.6 Backup and restore

```cron
# /etc/cron.d/osac-pg-backup
17 2 * * * root /usr/local/sbin/osac-pg-backup.sh
```

```bash
#!/bin/bash
# Nightly OSAC PostgreSQL backup (external podman PG on edge-04)
set -euo pipefail
BACKUP_DIR=/var/lib/osac/backups
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
podman exec osac-postgres pg_isready -q -U postgres
podman exec osac-postgres pg_dumpall -U postgres | gzip > "$BACKUP_DIR/osac-pg-$STAMP.sql.gz"
# rotation: keep newest 14
ls -1t "$BACKUP_DIR"/osac-pg-*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
```

Restore (into the external instance):

```bash
gunzip -c /var/lib/osac/backups/osac-pg-<stamp>.sql.gz | podman exec -i osac-postgres psql -U postgres
```

### 3.7 Day-2 commands

```bash
systemctl status container-osac-postgres     # unit health
podman logs osac-postgres                    # server log
podman exec -it osac-postgres psql -U postgres   # superuser (local peer auth)
podman exec osac-postgres psql -U postgres -Atc \
  "select usename, count(*) from pg_stat_activity where usename in ('service','metering') group by 1"
```

---

## 4. OpenBao (Phase 2)

**Approach:** the in-cluster OpenBao was already converted from chart dev
mode to a persistent file-storage server. The externalization moved that data
directory **wholesale** to the host, so the unseal key, root token, `osac`
namespace, JWT auth config, `lifecycle` policy and role all carried over —
**no re-bootstrap**. The endpoint moved via **supported chart values**
(`bundledVault.enabled: false` + `service.vault.endpoint`), not patches.

### 4.1 Run the container

```bash
# TLS cert (self-signed, IP SAN = bridge IP)
openssl req -x509 -newkey rsa:2048 \
  -keyout /root/bao-key.pem -out /root/bao-cert.pem \
  -days 365 -nodes -subj "/CN=192.168.127.1" \
  -addext "subjectAltName=IP:192.168.127.1"
chmod 644 /root/bao-cert.pem /root/bao-key.pem

mkdir -p /root/bao-data /root/bao-config
# /root/bao-config/bao.hcl:
```

```hcl
ui            = true
disable_mlock = true
api_addr      = "https://192.168.127.1:8200"
cluster_addr  = "https://192.168.127.1:8201"

storage "file" { path = "/bao/data" }

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/bao/tls/tls.crt"
  tls_key_file    = "/bao/tls/tls.key"
}
```

The systemd unit is `--new`-style (podman re-creates the container on every
start). Live unit, verbatim:

```ini
# /etc/systemd/system/container-osac-openbao.service
[Unit]
Description=Podman container-osac-openbao.service
Documentation=man:podman-generate-systemd(1)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=always
TimeoutStopSec=70
ExecStartPre=/bin/rm -f %t/%n.ctr-id
ExecStart=/usr/bin/podman run --cidfile=%t/%n.ctr-id --cgroups=no-conmon --rm --sdnotify=conmon --replace -d --name osac-openbao -p 192.168.127.1:8200:8200 -p 192.168.127.1:8201:8201 --security-opt label=disable -v /root/bao-cert.pem:/bao/tls/tls.crt:z -v /root/bao-key.pem:/bao/tls/tls.key:z -v /root/bao-data:/bao/data:z -v /root/bao-config:/bao/config:z -e HOME=/tmp ghcr.io/openbao/openbao:2.6.2 server -config=/bao/config/bao.hcl
ExecStop=/usr/bin/podman stop --ignore --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
```

**Auto-unseal** — a drop-in runs an unseal helper after every start (polls
the health endpoint, PUTs the unseal key from `/root/openbao-init.json`,
never prints it):

```ini
[Service]
# Auto-unseal the podman OpenBao after (re)start. Leading "-" ignores script
# failure so a sealed-but-running server is not restarted in a loop; errors
# are logged to /var/log/osac-openbao-unseal.log by the script itself.
ExecStartPost=-/usr/local/sbin/osac-openbao-unseal.sh
```

```bash
#!/bin/bash
# Auto-unseal for the external podman OpenBao (edge-04, Phase 2, 2026-10-20).
# Runs as ExecStartPost of container-osac-openbao.service; supersedes the
# 2026-10-15 cron watcher that targeted the deleted in-cluster pod.
set -u
BASE=https://192.168.127.1:8200
LOG=/var/log/osac-openbao-unseal.log

KEY=$(python3 -c 'import json;print(json.load(open("/root/openbao-init.json"))["unseal_keys_b64"][0])')

for _ in $(seq 1 30); do
  HEALTH=$(curl -sk --max-time 3 "$BASE/v1/sys/health" 2>/dev/null) || { sleep 2; continue; }
  SEALED=$(printf "%s" "$HEALTH" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sealed"))' 2>/dev/null) || { sleep 2; continue; }
  if [ "$SEALED" = "False" ]; then
    exit 0
  fi
  if [ "$SEALED" = "True" ]; then
    RESP=$(curl -sk --max-time 5 -X PUT -d "{\"key\":\"$KEY\"}" "$BASE/v1/sys/unseal" 2>/dev/null) || RESP=""
    if printf "%s" "$RESP" | grep -q '"sealed":false'; then
      echo "$(date -u +%FT%TZ) unsealed podman osac-openbao (ExecStartPost)" >> "$LOG"
      exit 0
    fi
  fi
  sleep 2
done
echo "$(date -u +%FT%TZ) ERROR: osac-openbao not healthy/unsealable after 60s" >> "$LOG"
exit 1
```

> ⚠️ **The `--new`-style trap (bit us 2026-10-25):** a bare
> `podman stop osac-openbao` makes the unit exit, systemd re-runs `ExecStart`
> within ~100 ms (racing anything you tried to do during the stop), and the
> `--rm` container from the previous start is already gone. **`systemctl
> stop` is the only stop systemd will not undo.** This is why the backup
> script below goes through `systemctl`, never bare podman. (PostgreSQL and
> Keycloak use old-style units where bare `podman stop/start` is safe; Kafka
> is oneshot — see §11.)

### 4.2 Migrate the data

Both sides used file storage, so migration was a copy:

```bash
# 1. stop the in-cluster server (it ran as a manually-converted deployment)
oc -n osac-infra scale deploy/openbao --replicas=0
# 2. copy the PVC contents out (pre-migration state tarballed to
#    /root/phase2-vault-migration/ first, as the rollback point)
oc -n osac-infra exec <openbao-pod> -- tar cf - -C /vault/data . | tar xf - -C /root/bao-data
# 3. start the host container; unseal with the SAME key (init state moved with the data)
systemctl start container-osac-openbao.service
curl -sk https://192.168.127.1:8200/v1/sys/health   # 200 = unsealed, active, initialized
```

Because the init state moved, the `osac` namespace, `auth/jwt` (trusts the
Keycloak issuer URL — unchanged, hostname preservation means the issuer URL
never changed), `lifecycle` policy and role needed **no** re-creation. For a
from-scratch bootstrap (fresh init, namespace, KV/transit mounts, JWT auth,
policy) use §4.3 of
[`deploy-osac-external-services.md`](deploy-osac-external-services.md) — the
lab did not need it.

### 4.3 Wire the cluster to it

Supported path, all in Helm values (survives upgrades):

```yaml
# osac-infra release: stop the bundled instance
bundledVault:
  enabled: false

# osac release: point the service at the host endpoint
service:
  vault:
    endpoint: https://192.168.127.1:8200
    caBundle:
      configMap: ca-bundle          # host cert added to this bundle (below)
    keycloakIssuerUrl: https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac
    keycloakClientId: osac-controller
    keycloakAudience: osac-api
    namespace: osac
    kvMountPath: secret
    lifecycleMountPath: jwt
    lifecycleRole: lifecycle
```

Trust the self-signed host cert via the trust-manager `Bundle` CR (never the
ConfigMap directly):

```bash
kubectl create secret generic bao-host-cert -n cert-manager \
  --from-file=ca.crt=/root/bao-cert.pem --dry-run=client -o yaml | kubectl apply -f -
kubectl patch bundle.trust.cert-manager.io ca-bundle --type=json -p='[
  {"op":"add","path":"/spec/sources/-",
   "value":{"secret":{"name":"bao-host-cert","namespace":"cert-manager","key":"ca.crt"}}}
]'
# verify the cert count increased by 1
kubectl -n osac get configmap ca-bundle -o jsonpath='{.data.bundle\.pem}' | grep -c BEGIN
```

### 4.4 Verify the write path end-to-end

Create a throwaway tenant and watch the controller provision its vault
namespace (namespace + KV mount + transit + JWT auth + policy + role +
break-glass secret), then read the secret back with a front-door tenant
token. The lab used tenant `phase2-verify`; the full evidence chain is in
`EDGE-04-DEPLOYMENT.md` → *External-services migration — Phase 2*. Quick
probes:

```bash
curl -sk https://192.168.127.1:8200/v1/sys/health        # 200
curl -sk https://192.168.127.1:8200/v1/sys/seal-status   # "sealed": false
```

### 4.5 Backup and restore

```cron
# /etc/cron.d/openbao-backup
30 2 * * * root /bin/bash /root/bao-backup/backup-openbao.sh >> /root/bao-backup/backup.log 2>&1
```

File-storage Bao has no snapshot API — the backup stops the unit, tars
`/root/bao-data` (contents are encrypted at rest), restarts, and verifies
unsealed + healthy. Costs a ~4 s Bao blip nightly at 02:30:

```bash
#!/bin/bash
# backup-openbao.sh — nightly OpenBao backup for the Edge-04 lab (cron 02:30).
# File-storage Bao has no snapshot API: stop the systemd unit, tar /root/bao-data
# (contents encrypted at rest), start the unit, verify unsealed + healthy,
# prune >14 d.
#
# 2026-10-25 gotcha (why this goes through systemctl, never bare podman):
# container-osac-openbao.service is `podman generate systemd --new` style —
# ExecStart `podman run --rm`, Restart=always, RestartSec=100ms. A bare
# `podman stop osac-openbao` makes the unit exit, systemd re-runs ExecStart
# within 100 ms (racing the tar), and the --rm container is gone, so the
# script's own `podman start` then fails with "no such container".
# `systemctl stop` is the only stop systemd will not undo. (keycloak-lab has
# no systemd unit, which is why backup-keycloak.sh can use bare podman.)
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
D=/root/bao-backup
TS=$(date +%Y%m%d-%H%M%S)
UNIT=container-osac-openbao.service
CONTAINER=osac-openbao
URL=https://192.168.127.1:8200
mkdir -p "$D"

# running-state verify: never start a container that an incident already stopped
systemctl is-active --quiet "$UNIT" || { echo "$(date -u +%FT%TZ) ERROR: $UNIT not active — NOT touching it, no backup taken"; exit 1; }
podman ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { echo "$(date -u +%FT%TZ) ERROR: $CONTAINER not running — NOT touching it, no backup taken"; exit 1; }

echo "$(date -u +%FT%TZ) stop $UNIT"
systemctl stop "$UNIT"

# belt and braces: nothing may be touching bao-data while we tar it
if podman ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$(date -u +%FT%TZ) ERROR: $CONTAINER still running after systemctl stop — no backup taken"
  exit 1
fi

echo "$(date -u +%FT%TZ) tar bao-data"
tar -czf "$D/bao-data-$TS.tar.gz" -C /root bao-data

echo "$(date -u +%FT%TZ) start $UNIT"
systemctl start "$UNIT"
for i in $(seq 1 15); do systemctl is-active --quiet "$UNIT" && break; sleep 2; done
systemctl is-active --quiet "$UNIT" || { echo "$(date -u +%FT%TZ) ERROR: $UNIT failed to start after backup — Bao IS DOWN, investigate now"; exit 1; }

# wait for the API, then unseal. systemctl start already fires the unit's
# ExecStartPost auto-unseal (unseal.conf drop-in); the manual unseal below is
# only a fallback and a harmless no-op on an already-unsealed server. The
# unseal key is read from /root/openbao-init.json — never printed, never logged.
for i in $(seq 1 30); do
  curl -sk -o /dev/null "$URL/v1/sys/seal-status" && break
  sleep 2
done
KEY=$(python3 -c "import json;d=json.load(open('/root/openbao-init.json'));k=d.get('unseal_keys_b64') or d.get('unseal_keys') or d.get('unseal_keys_shamir');print(k[0])") \
  || { echo "$(date -u +%FT%TZ) ERROR: cannot read unseal key — Bao LEFT SEALED, unseal manually"; exit 1; }
curl -sk -X PUT -d "{\"key\":\"$KEY\"}" "$URL/v1/sys/unseal" >/dev/null 2>&1 || true
unset KEY

# verify: unsealed + healthy (200 = unsealed, active, initialized)
SEALED=yes
for i in $(seq 1 15); do
  S=$(curl -sk "$URL/v1/sys/seal-status" | grep -o '"sealed": *[a-z]*' | grep -o 'true\|false' || true)
  [ "$S" = "false" ] && SEALED=no && break
  sleep 2
done
if [ "$SEALED" != "no" ]; then
  echo "$(date -u +%FT%TZ) ERROR: Bao still sealed after unseal attempt — check $URL/v1/sys/seal-status"
  exit 1
fi
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" "$URL/v1/sys/health")
[ "$HTTP" = "200" ] || { echo "$(date -u +%FT%TZ) ERROR: health HTTP $HTTP (200 expected; 501/503 = sealed/not-active)"; exit 1; }

# verify backup integrity + sane size before calling it a night
tar -tzf "$D/bao-data-$TS.tar.gz" >/dev/null || { echo "$(date -u +%FT%TZ) ERROR: backup tar unreadable"; exit 1; }
SIZE=$(stat -c%s "$D/bao-data-$TS.tar.gz")
[ "$SIZE" -gt 10000 ] || { echo "$(date -u +%FT%TZ) ERROR: backup suspiciously small ($SIZE bytes)"; exit 1; }

find "$D" -name "bao-data-*.tar.gz" -mtime +14 -delete
echo "$(date -u +%FT%TZ) OK bao-data-$TS.tar.gz ($SIZE bytes); Bao unsealed + healthy; pruned >14d"
```

Restore:

```bash
systemctl stop container-osac-openbao.service
mv /root/bao-data /root/bao-data.broken-$(date +%s)
tar -xzf /root/bao-backup/bao-data-<stamp>.tar.gz -C /root
systemctl start container-osac-openbao.service   # drop-in auto-unseals; :z relabels
curl -sk https://192.168.127.1:8200/v1/sys/health   # 200
```

---

## 5. Keycloak (Phase 3)

**Approach — hostname preservation.** The external Keycloak answers on the
**same hostname, same cert, same realm keys** as the bundled one: the
existing passthrough route `keycloak-keycloak.apps.osac-hub.redhat.com` keeps
serving, now backed by a selectorless svc `keycloak` + manual Endpoints →
`192.168.127.1:8443`. Because the issuer URL (`https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac`)
never changed, **nothing in the cluster was re-pointed** — no deployment
flags, no OpenBao JWT re-config, no trust Bundle changes, no Helm values.
(The alternative — re-pointing `--auth-issuer-url` etc. at the host — is
documented in Part 3 of
[`keycloak-edge04-setup.md`](keycloak-edge04-setup.md) and was deliberately
**not** used.)

### 5.1 Run the container

Two things differ from a generic external Keycloak, both essential to
hostname preservation:

1. It mounts the **route cert** (`/root/kc-route-cert.pem` — the in-cluster
   KC's `default-ca`-issued cert, extracted from Secret `keycloak-tls-cert`,
   SANs include the route hostname), not a fresh self-signed cert.
2. `KC_HOSTNAME` is set to the **route hostname**, and the port is published
   only on the bridge IP.

```bash
# cert/key must be readable by the image's uid 1000:
chown 1000:0 /root/kc-route-cert.pem /root/kc-route-key.pem
chmod 644 /root/kc-route-cert.pem; chmod 400 /root/kc-route-key.pem

mkdir -p /root/kc-data && chown -R 1000:0 /root/kc-data   # H2 lives here

podman run -d --name keycloak-lab \
  -p 192.168.127.1:8443:8443 \
  --security-opt label=disable \
  -v /root/kc-route-cert.pem:/etc/x509/https/tls.crt \
  -v /root/kc-route-key.pem:/etc/x509/https/tls.key \
  -v /root/kc-data:/opt/keycloak/data \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD=<KC_ADMIN_PASSWORD> \
  -e KC_HTTPS_CERTIFICATE_FILE=/etc/x509/https/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/etc/x509/https/tls.key \
  -e KC_HOSTNAME=keycloak-keycloak.apps.osac-hub.redhat.com \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HTTP_ENABLED=false \
  quay.io/keycloak/keycloak:26.6.4 start

# persistence across reboots (old-style unit — container persists)
podman generate systemd --name keycloak-lab --restart-policy=always \
  > /etc/systemd/system/container-keycloak-lab.service
systemctl daemon-reload && systemctl enable container-keycloak-lab.service
```

> A root-owned or `600` `tls.key` aborts startup with
> `Failed to load 'https-*' material: AccessDeniedException` — hence the
> chown/chmod above. `--security-opt label=disable` is required on RHEL.
> The container runs `start` (production mode) so JWT issuer URLs may use
> HTTPS; the H2 database lives in the bind-mounted `/root/kc-data`.

### 5.2 Import the realm

The realm was **not** built from the chart's `realm.json` — it is a **full
export** of the live in-cluster realm, so users (with credential hashes), the
5 organizations with members, and the `osac-ui` client fixups carried over,
and the realm keys stayed identical (tokens issued before cutover remained
valid):

```bash
# export from the bundled instance (image has no tar → oc cp fails; use exec+cat)
oc -n keycloak exec <kc-pod> -- /opt/keycloak/bin/kc.sh export \
  --realm=osac --file=/tmp/osac-realm-export.json
oc -n keycloak exec <kc-pod> -- cat /tmp/osac-realm-export.json \
  > /root/kc-incluster-full-export.json

# import into the external instance (admin token first)
KC="https://192.168.127.1:8443"
TOKEN=$(curl -sk -d "client_id=admin-cli&username=admin&password=<KC_ADMIN_PASSWORD>&grant_type=password" \
  "${KC}/realms/master/protocol/openid-connect/token" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -sk -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d @/root/kc-incluster-full-export.json "${KC}/admin/realms"
```

On top of the export, the **LDAP federations and organization enrollment were
replayed** (they do not survive `kc.sh export`): both tenant LDAPs
(`192.168.122.33` acme-corp, `192.168.122.165` globex), the orgs
`tenant1`/`tenant2` (names must match the fulfillment tenants — the platform
maps the token's `organization` claim to a tenant by name), full LDAP sync,
org membership, and the `tenant-admin` role for alice. The exact commands are
in [`keycloak-edge04-setup.md`](keycloak-edge04-setup.md) §2.2 — they contain
lab passwords, which is why they are not duplicated here.

> From-scratch alternative (fresh install, no in-cluster realm to export):
> import the chart's `realm.json` with its `__OSAC_*__` placeholders resolved
> from the `keycloak-client-secrets` Secret — procedure and the six-placeholder
> gotcha in [`deploy-osac-external-services.md`](deploy-osac-external-services.md) §3.3.

### 5.3 Cutover — selectorless Service + Endpoints

The bundled `keycloak-service` is scaled to 0 **last**, only after
verification. `keycloak-database-0` is kept (also scaled to 0) as the
rollback point.

```bash
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

# 1. rewire the Service (chart-owned; this is what reapply section [7] re-runs)
oc -n keycloak patch svc keycloak --type=json -p '[{"op":"remove","path":"/spec/selector"}]'
oc -n keycloak patch endpoints keycloak --type=merge -p '{"subsets":[{"addresses":[{"ip":"192.168.127.1"}],"ports":[{"name":"https","port":8443,"protocol":"TCP"}]}]}'
oc -n keycloak delete endpointslice -l kubernetes.io/service-name=keycloak

# 2. verify through the route (from the hub VM; 401/200 = chain intact)
curl -sk https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac | head -c 120

# 3. only now scale the bundled instance down
oc -n keycloak scale deploy keycloak-service --replicas=0
oc -n keycloak scale sts keycloak-database --replicas=0
```

`keycloak.enabled` stays `true` in `osac-infra` (the chart still owns the
Service and route — that ownership is what preserves the hostname); reapply
section [7] re-points the endpoints after every `helm upgrade`.

### 5.4 Verify

```bash
# realm reachable through the preserved route + hostname
curl -sk https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['realm'])"   # osac

# a break-glass ROPC login (tenant users work; some break-glass users carry a
# pending UPDATE_PASSWORD action and prompt in the browser instead)
curl -sk -d "client_id=admin-cli&username=<user>&password=<password>&grant_type=password" \
  https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac/protocol/openid-connect/token

# UI login (browser): https://osac-ui-osac.apps.osac-hub.redhat.com — full OIDC PKCE flow
```

The `osac-ui` client is a public PKCE client with no direct access grants —
ROPC against it is impossible by design; use the browser flow or `admin-cli`.

### 5.5 Rollback

```bash
#!/bin/bash
# Rollback the external-Keycloak cutover: restore in-cluster KC as the
# route backing. Run on edge-04. (Phase 3, 2026-10-20.)
set -euo pipefail
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig
oc -n keycloak scale deploy keycloak-service --replicas=1
oc -n keycloak wait --for=condition=available deploy/keycloak-service --timeout=180s
oc -n keycloak patch svc keycloak --type=json -p '[{"op":"add","path":"/spec/selector","value":{"app":"keycloak-service"}}]' >/dev/null
oc -n keycloak patch svc keycloak --type=merge -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":8001,"protocol":"TCP"}]}}' >/dev/null
oc -n keycloak delete endpoints keycloak >/dev/null 2>&1 || true
oc -n keycloak delete endpointslice -l kubernetes.io/service-name=keycloak >/dev/null 2>&1 || true
sleep 5
echo "rolled back: $(oc -n keycloak get endpoints keycloak -o jsonpath='{.subsets[0].addresses[0].ip}') should be a pod IP"
```

### 5.6 Backup and restore

```cron
# /etc/cron.d/keycloak-backup
0 2 * * * root /bin/bash /root/kc-backup/backup-keycloak.sh >> /root/kc-backup/backup.log 2>&1
```

Partial-export (realm structure) + users + orgs + org-members + LDAP configs
+ a `kc-data` tarball with a brief container stop. Includes the CNI
stale-lease self-heal (the first automated run hung on a stale lease because
cron's minimal PATH lacked `/usr/sbin` — hence the explicit PATH export):

```bash
#!/bin/bash
# Daily Keycloak lab backup (Phase 3). Runbook Step B, extended with org
# members; master token taken from the container env (not hardcoded).
# Logs to /root/kc-backup/backup.log via cron. python3.6-compatible.
set -euo pipefail
# cron runs with a minimal PATH lacking /usr/sbin (iptables); podman's CNI
# teardown needs it or the stopped container keeps a stale IP lease
# (incident 2026-10-21: first 02:00 run left keycloak-lab down ~1h).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
KC="https://192.168.127.1:8443"
BACKUP_DIR=/root/kc-backup
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "${BACKUP_DIR}"

KC_PASS=$(podman inspect keycloak-lab --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^KEYCLOAK_ADMIN_PASSWORD=' | cut -d= -f2-)
TOKEN=$(curl -sk -d "client_id=admin-cli&username=admin&password=${KC_PASS}&grant_type=password" \
  "${KC}/realms/master/protocol/openid-connect/token" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')
unset KC_PASS
export KC_TOKEN="${TOKEN}"

# Realm structure (clients, roles, groups)
curl -sk -X POST -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/osac/partial-export?exportGroupsAndRoles=true&exportClients=true" \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))' \
  > "${BACKUP_DIR}/realm-osac-${TS}.json"

# Users (not included in partial-export)
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/osac/users?max=1000&briefRepresentation=false" \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))' \
  > "${BACKUP_DIR}/users-osac-${TS}.json"

# Organizations + memberships
curl -sk -H "Authorization: Bearer ${TOKEN}" "${KC}/admin/realms/osac/organizations?max=100" \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))' \
  > "${BACKUP_DIR}/orgs-osac-${TS}.json"
python3 - "${BACKUP_DIR}/org-members-osac-${TS}.json" <<'PYMEM'
import json, subprocess, os, sys
KC = "https://192.168.127.1:8443"
out_path = sys.argv[1]
orgs_path = out_path.replace("org-members-", "orgs-")
orgs = json.load(open(orgs_path))
out = {}
for o in orgs:
    p = subprocess.Popen(["curl", "-sk", "-H", "Authorization: Bearer " + os.environ["KC_TOKEN"],
        "%s/admin/realms/osac/organizations/%s/members" % (KC, o["id"])],
        stdout=subprocess.PIPE)
    m = p.communicate()[0].decode()
    out[o["name"]] = [u["username"] for u in json.loads(m)]
json.dump(out, open(out_path, "w"), indent=2)
PYMEM

# LDAP federations
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${KC}/admin/realms/osac/components?type=org.keycloak.storage.UserStorageProvider" \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))' \
  > "${BACKUP_DIR}/ldap-osac-${TS}.json"

# Verify counts
python3 - "${BACKUP_DIR}" "${TS}" <<'PYCOUNT'
import json, sys
bd, ts = sys.argv[1], sys.argv[2]
r = json.load(open("%s/realm-osac-%s.json" % (bd, ts)))
u = json.load(open("%s/users-osac-%s.json" % (bd, ts)))
o = json.load(open("%s/orgs-osac-%s.json" % (bd, ts)))
print("  clients: %d  users: %d  orgs: %d" % (len(r.get("clients", [])), len(u), len(o)))
PYCOUNT

# Data directory snapshot (brief container stop for consistency)
podman stop keycloak-lab >/dev/null
tar -czf "${BACKUP_DIR}/kc-data-${TS}.tar.gz" -C /root kc-data
if ! podman start keycloak-lab >/dev/null; then
  echo "[${TS}] WARN: first start attempt failed (stale CNI state) - retrying"
  CTID=$(podman inspect keycloak-lab --format '{{.Id}}')
  for f in $(grep -l "${CTID}" /var/lib/cni/networks/podman/* 2>/dev/null || true); do
    echo "[${TS}] removing stale lease: ${f}"; rm -f "${f}"
  done
  sleep 5
  podman start keycloak-lab >/dev/null
fi
podman inspect -f '{{.State.Running}}' keycloak-lab | grep -q true || { echo "[${TS}] ERROR: keycloak-lab NOT running after backup"; exit 1; }
for i in $(seq 1 60); do
  curl -sk --max-time 3 "${KC}/realms/master" >/dev/null 2>&1 && break
  sleep 3
done

# Retain last 7 realm/users/orgs exports and last 3 data snapshots
ls -t "${BACKUP_DIR}"/realm-osac-*.json        | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/users-osac-*.json        | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/orgs-osac-*.json         | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/org-members-osac-*.json  | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/ldap-osac-*.json         | tail -n +8 | xargs -r rm
ls -t "${BACKUP_DIR}"/kc-data-*.tar.gz         | tail -n +4 | xargs -r rm

echo "[${TS}] Done: ${BACKUP_DIR}/ (kc ready again)"
```

Restore scenarios (container lost / data corrupted / total loss) are in
[`keycloak-edge04-setup.md`](keycloak-edge04-setup.md) → *Backup and Restore,
Step C*.

---

## 6. Kafka (Phase 5)

**Approach:** implement the upstream
[external-Kafka contract](https://github.com/osac-project/osac/blob/main/docs/guides/installation/kafka-configuration.md)
with a single-node KRaft broker in podman on the host, then cut the hub over
via chart values, then tear down the in-cluster Strimzi cluster. Executed in
three stages: **A** build + verify broker → **B** hub cutover → **C** Strimzi
teardown.

The upstream contract this implements:

| Requirement | Lab implementation |
|---|---|
| Bootstrap reachable from pods, `host:port`, no scheme | `192.168.127.1:9092` |
| SASL SCRAM-SHA-512 over TLS (`SASL_SSL`) | yes (only mechanism enabled) |
| CA chain trusted, cert matches broker address, TLS ≥ 1.2 | cert-manager `Certificate` from `default-ca`, IP SAN `192.168.127.1`, 5 y |
| Topic ACL `osac.events.` prefix: Create/Write/Read/Describe | granted to `fulfillment-service` |
| Group ACL `osac.system.` prefix: Read/Describe | granted to `fulfillment-service` |
| Cluster `IdempotentWrite` | granted to both users |
| `auto.create.topics.enable: true` | yes (event topics `osac.events.<tenant>` are broker-auto-created) |

Deliberate lab deviations from the upstream guide: single broker (RF=1 — no
replication; the guide's metering topic defaults of RF 3 do not fit),
`StandardAuthorizer` instead of Strimzi `simple`, and metering pointed at the
external broker through a values hack (§6.3) because the metering chart has
no values-only external path.

### 6.1 Stage A — build and verify the broker

Everything below is done by one idempotent script (passwords generated once
into root-only `credentials.env` and never printed; certs fetched from
cert-manager; KRaft storage formatted once; systemd unit written; SCRAM
users, ACLs, metering topics created; a produce/consume self-test runs as
`fulfillment-service`; reachability from the hub VM and a hub pod checked):

```bash
#!/bin/bash
# setup-osac-kafka-external.sh — Phase 5 Stage A (run on edge-04 as root)
# Single-node KRaft Kafka for the OSAC hub, per
# docs/guides/installation/kafka-configuration.md (OSAC-4760).
# SASL_SSL SCRAM-SHA-512 on 192.168.127.1:9092, cert from hub default-ca,
# data /var/lib/osac/kafka, config+creds /root/osac-kafka-external (never commit).
# Passwords are generated once into credentials.env (root-only) and never printed.
set -euo pipefail

KROOT=/root/osac-kafka-external
DATA=/var/lib/osac/kafka
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

mkdir -p "$KROOT/tls" "$DATA/data"
chmod 700 "$KROOT"

# --- image (no registry.redhat.io auth on this host; fall back to strimzi) ---
IMAGE=docker.io/apache/kafka:4.2.0
if ! podman pull "$IMAGE" >/dev/null 2>&1; then
  IMAGE=quay.io/strimzi/kafka:latest-kafka-4.2.0
  echo "apache/kafka pull failed, falling back to $IMAGE"
  podman pull "$IMAGE" >/dev/null
fi
echo "image: $IMAGE"

# --- 1. SCRAM credentials (generate once; never printed) ---
if [ ! -f "$KROOT/credentials.env" ]; then
  umask 077
  {
    echo "KAFKA_ADMIN_PASSWORD=$(openssl rand -base64 24)"
    echo "KAFKA_FULFILLMENT_PASSWORD=$(openssl rand -base64 24)"
    echo "KAFKA_METERING_PASSWORD=$(openssl rand -base64 24)"
  } > "$KROOT/credentials.env"
  echo "generated new SCRAM passwords -> $KROOT/credentials.env (root-only)"
else
  echo "using existing credentials.env"
fi
# shellcheck disable=SC1090
. "$KROOT/credentials.env"

# --- 2. TLS via cert-manager: default-ca already trusted by the hub ca-bundle ---
cat <<'EOF' | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: osac-external-kafka
  namespace: osac
  labels:
    app.kubernetes.io/part-of: osac
    app.kubernetes.io/component: external-kafka
spec:
  secretName: osac-external-kafka-tls
  issuerRef:
    kind: ClusterIssuer
    name: default-ca
  duration: 43800h
  renewBefore: 720h
  privateKey:
    encoding: PKCS8
    rotationPolicy: Always
  ipAddresses:
    - 192.168.127.1
  dnsNames:
    - localhost
EOF

echo "waiting for secret osac-external-kafka-tls ..."
ok=0
for i in $(seq 1 60); do
  if oc -n osac get secret osac-external-kafka-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$KROOT/tls/tls.crt" && [ -s "$KROOT/tls/tls.crt" ]; then
    ok=1; break
  fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "ERROR: certificate secret never became ready"; exit 1; }
oc -n osac get secret osac-external-kafka-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$KROOT/tls/tls.key"
oc -n osac get secret osac-external-kafka-tls -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$KROOT/tls/ca.crt" || true
chmod 600 "$KROOT"/tls/*
echo "cert issued:"
openssl x509 -in "$KROOT/tls/tls.crt" -noout -subject -issuer -dates
# CA for the client truststore: secret ca.crt, else the whole hub ca-bundle
if [ ! -s "$KROOT/tls/ca.crt" ]; then
  oc -n osac get cm ca-bundle -o go-template='{{index .data "bundle.pem"}}' > "$KROOT/tls/ca.crt"
  chmod 600 "$KROOT/tls/ca.crt"
fi
# trust check against the exact bundle the hub clients use
oc -n osac get cm ca-bundle -o go-template='{{index .data "bundle.pem"}}' > /tmp/ca-bundle-check.pem
openssl verify -CAfile /tmp/ca-bundle-check.pem "$KROOT/tls/tls.crt"

# --- 3. client properties helper (SASL_SSL + SCRAM + PEM truststore) ---
make_client_props() { # $1=file $2=user $3=password
  {
    echo 'security.protocol=SASL_SSL'
    echo 'sasl.mechanism=SCRAM-SHA-512'
    echo "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"$2\" password=\"$3\";"
    echo 'ssl.truststore.type=PEM'
    printf 'ssl.truststore.certificates='
    awk '{printf "%s\\n", $0}' "$KROOT/tls/ca.crt"
    echo
  } > "$1"
  chmod 600 "$1"
}
make_client_props "$KROOT/client-admin.properties" admin "$KAFKA_ADMIN_PASSWORD"
make_client_props "$KROOT/client-fulfillment.properties" fulfillment-service "$KAFKA_FULFILLMENT_PASSWORD"

# --- 4. server.properties (KRaft combined mode, inline PEM keystore) ---
{
  cat <<'EOF'
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@127.0.0.1:9093
listeners=sasl_ssl://0.0.0.0:9092,CONTROLLER://127.0.0.1:9093
advertised.listeners=sasl_ssl://192.168.127.1:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,sasl_ssl:SASL_SSL
inter.broker.listener.name=sasl_ssl
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
# admin is the bootstrapped super-user (kafka-storage --add-scram);
# ANONYMOUS covers the CONTROLLER listener, which is PLAINTEXT bound to the
# container's own loopback only (not published, unreachable off-host)
super.users=User:admin;User:ANONYMOUS
num.partitions=3
default.replication.factor=1
min.insync.replicas=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
auto.create.topics.enable=true
log.dirs=/var/lib/kafka/data
log.retention.hours=168
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
ssl.keystore.type=PEM
ssl.client.auth=none
ssl.enabled.protocols=TLSv1.2,TLSv1.3
EOF
  # Strimzi-style listener config (verified against the working osac-kafka
  # broker, same Kafka 4.2.0): listener names are lowercase so the
  # listener.name.* prefixes match; server-side SCRAM JAAS is credential-free
  # (validation uses metadata-stored credentials, no secret in this file);
  # the listener truststore is required for the SASL channel-builder
  # self-test (client-mode SSLEngine must trust our default-ca cert)
  echo 'listener.name.sasl_ssl.sasl.enabled.mechanisms=SCRAM-SHA-512'
  echo 'listener.name.sasl_ssl.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;'
  echo 'listener.name.sasl_ssl.ssl.truststore.type=PEM'
  printf 'listener.name.sasl_ssl.ssl.truststore.certificates='
  awk '{printf "%s\\n", $0}' "$KROOT/tls/ca.crt"
  echo
  printf 'ssl.keystore.certificate.chain='
  awk '{printf "%s\\n", $0}' "$KROOT/tls/tls.crt"
  echo
  printf 'ssl.keystore.key='
  awk '{printf "%s\\n", $0}' "$KROOT/tls/tls.key"
  echo
} > "$KROOT/server.properties"
chmod 600 "$KROOT/server.properties"
echo "server.properties written"

# --- 5. KRaft storage format (first run only) + bootstrap admin user ---
if [ ! -f "$DATA/data/meta.properties" ]; then
  if [ ! -f "$KROOT/cluster-id" ]; then
    podman run --rm --entrypoint /bin/bash "$IMAGE" -c '/opt/kafka/bin/kafka-storage.sh random-uuid' > "$KROOT/cluster-id"
  fi
  CLUSTER_ID=$(cat "$KROOT/cluster-id")
  echo "formatting KRaft storage (cluster id $CLUSTER_ID, bootstrap admin user)"
  podman run --rm --security-opt label=disable --user 0:0 \
    -v "$KROOT/server.properties:/etc/kafka/server.properties:ro" \
    -v "$DATA/data:/var/lib/kafka/data" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "/opt/kafka/bin/kafka-storage.sh format -t $CLUSTER_ID -c /etc/kafka/server.properties --add-scram 'SCRAM-SHA-512=[name=admin,password=${KAFKA_ADMIN_PASSWORD}]'"
else
  echo "KRaft storage already formatted"
fi

# --- 6. systemd unit (mirrors container-osac-openbao.service conventions) ---
# NOTE: like the openbao unit there is deliberately NO ExecStop/ExecStopPost:
# with `podman run -d` the main process exits immediately and systemd would
# run ExecStop during deactivation, killing the container ~60s after start
# (reproduced live). systemd therefore shows the unit inactive while the
# container runs; manage the container with `podman stop/start osac-kafka`
# (same as keycloak-lab in the backup script). --replace makes
# `systemctl restart` re-create the container cleanly.
cat > /etc/systemd/system/container-osac-kafka.service <<EOF
[Unit]
Description=OSAC external Kafka (single-node KRaft, SASL_SSL 192.168.127.1:9092)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
ExecStartPre=/bin/sh -c 'rm -f %t/%n.ctr-id'
ExecStart=/usr/bin/podman run --cidfile=%t/%n.ctr-id --cgroups=no-conmon --rm --sdnotify=conmon --replace -d --name osac-kafka -p 192.168.127.1:9092:9092 --security-opt label=disable --user 0:0 -v $KROOT/server.properties:/etc/kafka/server.properties:ro -v $KROOT/tls:/etc/kafka/tls:ro -v $DATA/data:/var/lib/kafka/data -e 'KAFKA_HEAP_OPTS=-Xmx1G -Xms512M' --entrypoint /bin/bash $IMAGE -c 'exec /opt/kafka/bin/kafka-server-start.sh /etc/kafka/server.properties'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable container-osac-kafka.service >/dev/null
systemctl restart container-osac-kafka.service
echo "service started (unit is Type=oneshot/RemainAfterExit; container keeps running detached)"

# --- 7. CLI helper + readiness wait ---
krun() { # krun <tool> [args...] — as admin, host network (root: props files are 600)
  local tool=$1; shift
  podman run --rm --security-opt label=disable --user 0:0 --network host \
    -v "$KROOT/client-admin.properties:/etc/kafka/client.properties:ro" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "/opt/kafka/bin/$tool --bootstrap-server 192.168.127.1:9092 --command-config /etc/kafka/client.properties $*"
}
krun_as() { # krun_as <propsfile> <tool> [args...]
  local props=$1 tool=$2; shift 2
  podman run --rm --security-opt label=disable --user 0:0 --network host \
    -v "$props:/etc/kafka/client.properties:ro" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "/opt/kafka/bin/$tool --bootstrap-server 192.168.127.1:9092 --command-config /etc/kafka/client.properties $*"
}

echo "waiting for broker readiness on 192.168.127.1:9092 ..."
ok=0
for i in $(seq 1 60); do
  if krun kafka-broker-api-versions.sh >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
if [ "$ok" != 1 ]; then
  echo "ERROR: broker not ready; last journal lines:"
  journalctl -u container-osac-kafka --no-pager -n 40 || podman logs osac-kafka --tail 40 || true
  exit 1
fi
echo "broker ready (attempt $i)"

# --- 8. SCRAM users (kafka-configs syntax: no name= inside brackets —
# the name comes from --entity-name; only name= is invalid here, unlike
# kafka-storage.sh --add-scram which requires it) ---
krun kafka-configs.sh --alter --entity-type users --entity-name fulfillment-service \
  --add-config "SCRAM-SHA-512=[password=${KAFKA_FULFILLMENT_PASSWORD}]"
krun kafka-configs.sh --alter --entity-type users --entity-name osac-metering \
  --add-config "SCRAM-SHA-512=[password=${KAFKA_METERING_PASSWORD}]"
echo "SCRAM users created: fulfillment-service, osac-metering"

# --- 9. ACLs per docs/guides/installation/kafka-configuration.md ---
krun kafka-acls.sh --add --allow-principal User:fulfillment-service \
  --operation Create --operation Write --operation Read --operation Describe \
  --topic osac.events. --resource-pattern-type prefixed
krun kafka-acls.sh --add --allow-principal User:fulfillment-service \
  --operation Read --operation Describe \
  --group osac.system. --resource-pattern-type prefixed
krun kafka-acls.sh --add --allow-principal User:fulfillment-service \
  --operation IdempotentWrite --cluster
krun kafka-acls.sh --add --allow-principal User:osac-metering \
  --operation Write --operation Describe \
  --topic osac.metering. --resource-pattern-type prefixed
krun kafka-acls.sh --add --allow-principal User:osac-metering \
  --operation IdempotentWrite --cluster
echo "ACLs applied"

# --- 10. metering topics (create if absent) ---
mk_topic() { # name partitions retention_ms
  if krun kafka-topics.sh --describe --topic "$1" >/dev/null 2>&1; then
    echo "topic exists: $1"
  else
    krun kafka-topics.sh --create --topic "$1" --partitions "$2" \
      --replication-factor 1 --config "retention.ms=$3" --config min.insync.replicas=1
  fi
}
mk_topic osac.metering.lifecycle   3 2592000000
mk_topic osac.metering.heartbeat   3 2592000000
mk_topic osac.metering.inference   3 2592000000
mk_topic osac.metering.corrections 3 2592000000
mk_topic osac.metering.dlq         6 7776000000

# --- 11. self-test as fulfillment-service (auto-create + produce + consume + group) ---
# start clean so --max-messages 1 sees exactly our token (produce re-creates it)
krun kafka-topics.sh --delete --topic osac.events.selftest >/dev/null 2>&1 || true
TOKEN="phase5-selftest-$(date +%s)"
echo "selftest: producing '$TOKEN' to osac.events.selftest as fulfillment-service"
# NOTE: podman run needs -i for stdin to reach the producer — without it the
# producer reads EMPTY stdin, sends nothing, and still exits 0 (reproduced
# live). --command-config is the modern unified flag for producer and consumer
# alike; --producer.config and --consumer-property are deprecated and their
# warning prints on stdout, polluting captured output. The comparison greps
# for the token line so stray stdout warnings cannot fail it.
echo "$TOKEN" | podman run --rm -i --security-opt label=disable --user 0:0 --network host \
  -v "$KROOT/client-fulfillment.properties:/etc/kafka/client.properties:ro" \
  --entrypoint /bin/bash "$IMAGE" \
  -c "/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server 192.168.127.1:9092 --command-config /etc/kafka/client.properties --topic osac.events.selftest"
GOT=$(krun_as "$KROOT/client-fulfillment.properties" kafka-console-consumer.sh \
  --topic osac.events.selftest --group osac.system.selftest \
  --from-beginning --command-property auto.offset.reset=earliest \
  --max-messages 1 --timeout-ms 20000 2>/dev/null || true)
if printf '%s\n' "$GOT" | grep -qxF "$TOKEN"; then
  echo "selftest PASSED: consumed back the produced message under group osac.system.selftest"
else
  echo "selftest FAILED: expected '$TOKEN', got '${GOT:-<nothing>}'"
  exit 1
fi
krun kafka-consumer-groups.sh --describe --group osac.system.selftest || true
krun kafka-topics.sh --delete --topic osac.events.selftest
krun kafka-consumer-groups.sh --delete --group osac.system.selftest || true
echo "selftest artifacts cleaned up"

# --- 12. reachability from the hub VM and from a hub pod ---
echo "hub VM (192.168.127.19) TCP check:"
ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new core@192.168.127.19 \
  "timeout 5 bash -c 'echo > /dev/tcp/192.168.127.1/9092' && echo HUB_VM_TCP_OK" || echo "HUB_VM_TCP_FAIL"
echo "hub pod TLS check (exit 56/52 = reached kafka and got reset after TLS; 7/28/35 = broken):"
oc -n osac run kafka-reach-test --rm -i --restart=Never \
  --image=quay.io/openshift/origin-cli:4.20.0 --command -- \
  bash -c 'curl -sk --connect-timeout 5 https://192.168.127.1:9092 -o /dev/null; echo curl_exit=$?' || true

# --- summary ---
echo "=== summary ==="
echo "listening:"
ss -ltn | grep 9092 || true
echo "topics:"
krun kafka-topics.sh --list
echo "ACLs:"
krun kafka-acls.sh --list
cat > "$KROOT/README.md" <<EOF
# OSAC external Kafka (Phase 5)

Single-node KRaft broker for the OSAC hub, replacing in-cluster Strimzi.
See EDGE-04-DEPLOYMENT.md Step 7.4 (Phase 5).

- service:  systemctl status container-osac-kafka (unit /etc/systemd/system/)
- endpoint: 192.168.127.1:9092 SASL_SSL SCRAM-SHA-512
- users:    admin (super), fulfillment-service, osac-metering
            (passwords in credentials.env, root-only, never commit)
- cert:     hub cert-manager Certificate osac-external-kafka (ns osac,
            ClusterIssuer default-ca, IP SAN 192.168.127.1) -> tls/ here.
            Renewal is NOT synced: if cert-manager renews the secret, copy
            tls.crt/tls.key out again and restart the service.
- data:     /var/lib/osac/kafka/data
- re-run:   bash $KROOT/setup-kafka.sh (idempotent; passwords/certs kept)
EOF
echo "DONE"
```

What it builds:

- **Config + credentials** in `/root/osac-kafka-external/` (mode 700):
  `credentials.env` (three SCRAM passwords), `client-admin.properties` /
  `client-fulfillment.properties` (SASL_SSL + SCRAM + PEM truststore),
  `cluster-id`, `server.properties`, `tls/` (cert/key/CA).
- **TLS**: a cert-manager `Certificate` (`osac-external-kafka`, ns `osac`,
  ClusterIssuer `default-ca`, IP SAN `192.168.127.1`, PKCS#8, 5 y) — the
  hub's existing `ca-bundle` already trusts `default-ca`, so **no trust
  changes anywhere**. The generated `server.properties` embeds the PEM
  keystore inline (`ssl.keystore.type=PEM` + `ssl.keystore.certificate.chain`
  / `ssl.keystore.key`) — do not hand-edit or copy that file around
  casually; it contains the private key (mode 600).
- **systemd unit** `container-osac-kafka.service` (also below) — note it is
  `Type=oneshot` + `RemainAfterExit=yes` with **no ExecStop/ExecStopPost**,
  because with `podman run -d` the main process exits after ~1 s and any
  ExecStop would kill the healthy container ~60 s after every start
  (reproduced live). The container is managed with plain
  `podman stop/start osac-kafka`; `systemctl restart` re-creates it cleanly
  via `--replace`.

```ini
# /etc/systemd/system/container-osac-kafka.service (as written by setup-kafka.sh)
[Unit]
Description=OSAC external Kafka (single-node KRaft, SASL_SSL 192.168.127.1:9092)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
ExecStartPre=/bin/sh -c 'rm -f %t/%n.ctr-id'
ExecStart=/usr/bin/podman run --cidfile=%t/%n.ctr-id --cgroups=no-conmon --rm --sdnotify=conmon --replace -d --name osac-kafka -p 192.168.127.1:9092:9092 --security-opt label=disable --user 0:0 -v /root/osac-kafka-external/server.properties:/etc/kafka/server.properties:ro -v /root/osac-kafka-external/tls:/etc/kafka/tls:ro -v /var/lib/osac/kafka/data:/var/lib/kafka/data -e 'KAFKA_HEAP_OPTS=-Xmx1G -Xms512M' --entrypoint /bin/bash docker.io/apache/kafka:4.2.0 -c 'exec /opt/kafka/bin/kafka-server-start.sh /etc/kafka/server.properties'

[Install]
WantedBy=multi-user.target
```

- **SCRAM users**: `admin` (super-user, bootstrapped via
  `kafka-storage.sh format --add-scram`), `fulfillment-service`,
  `osac-metering`.
- **Metering topics**: `osac.metering.{lifecycle,heartbeat,inference,corrections}`
  (3 partitions, 30 d retention) and `osac.metering.dlq` (6 partitions, 90 d).
  Event topics are **not** pre-created — auto-create handles them, and event
  history was not migrated.
- `finish-kafka.sh` (same directory) runs only the post-start pipeline
  (sections 7–12) against an already-running broker.

### 6.2 Kafka gotchas hit live (all reproduced and fixed)

(a) **Listener names are case-sensitive in `listener.name.*` keys** — a
listener named `SASL_SSL` will not pick up `listener.name.sasl_ssl.*` keys;
the broker dies with `Could not find a 'KafkaServer' or 'sasl_ssl.KafkaServer'
entry in the JAAS configuration`. Use a lowercase listener name, like Strimzi.
(b) The server-side SCRAM JAAS entry is **credential-free** —
`…ScramLoginModule required;` with no username/password (validation uses the
SCRAM credentials stored in KRaft metadata). (c) The SASL channel-builder
self-test needs a listener truststore — without
`listener.name.sasl_ssl.ssl.truststore.type=PEM` +
`…ssl.truststore.certificates=<default-ca PEM>` the broker dies at startup
with `PKIX path building failed … A client SSLEngine created with the provided
settings can't connect to a server SSLEngine`. (d) `podman run` forwards
stdin **only with `-i`** — piping into `kafka-console-producer.sh` without
`-i` silently produces nothing while the producer exits 0. (e)
`--producer.config` / `--consumer-property` are deprecated in Kafka 4.2 in
favor of `--command-config` / `--command-property`, and the deprecation
warning prints on **stdout** — compare captured output by grepping for the
expected token, never by string equality. (f) `kafka.tools.GetOffsetShell` no
longer exists — use `kafka-get-offsets.sh`.

### 6.3 Stage B — cut the hub over

Connection objects first (ConfigMap with `brokers`/`user`, Secrets with the
SCRAM passwords — the metering one is named `osac-metering` because the
metering chart's `fetch-kafka-secrets` initContainer just does
`oc get secret osac-metering -n <clusterNamespace>`; pointing
`metering.kafka.clusterNamespace` at `osac` makes it fetch our external
password unchanged — **this is the lab hack**; the upstream doc offers no
values-only external metering path), then one surgical `helm upgrade` with
the values file, then the reapply script, then verification:

```bash
#!/bin/bash
# cutover-osac-kafka-external.sh — Phase 5 Stage B (run on edge-04 as root)
# Point the OSAC hub at the external podman Kafka per
# docs/guides/installation/kafka-configuration.md:
#   kafka.enabled: false + service.kafka.connection + metering.kafka.*
# Pre-creates CM external-kafka + Secrets external-kafka-credentials and
# osac-metering (fetch-kafka-secrets reads the latter from clusterNamespace),
# then one surgical helm upgrade with --reuse-values, then the reapply
# script, then verifies (rollouts, wiring, heartbeat canary).
# Rollback: helm rollback osac <PREV_REV> (see EDGE-04-DEPLOYMENT.md 7.4).
set -euo pipefail

KROOT=/root/osac-kafka-external
CHARTS=/root/workspace/git/osac/osac-installer
IMAGE=docker.io/apache/kafka:4.2.0
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig
# shellcheck disable=SC1090
. "$KROOT/credentials.env"

krun() { # krun <tool> [args...] — admin client, host network
  local tool=$1; shift
  podman run --rm --security-opt label=disable --user 0:0 --network host \
    -v "$KROOT/client-admin.properties:/etc/kafka/client.properties:ro" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "/opt/kafka/bin/$tool --bootstrap-server 192.168.127.1:9092 --command-config /etc/kafka/client.properties $*"
}

# --- 0. pre-checks ---
echo "=== pre-checks ==="
krun kafka-broker-api-versions.sh >/dev/null && echo "broker reachable"
if oc -n osac get secret osac-metering >/dev/null 2>&1; then
  echo "ERROR: secret osac-metering already exists in ns osac — inspect first"; exit 1
fi
PREV_REV=$(helm status osac -n osac | awk '/^REVISION:/{print $2}')
echo "osac release revision before cutover: $PREV_REV"

# --- 1. connection objects in ns osac (idempotent; passwords via stdin) ---
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: external-kafka
  namespace: osac
  labels:
    app.kubernetes.io/part-of: osac
    app.kubernetes.io/component: external-kafka
data:
  brokers: 192.168.127.1:9092
  user: fulfillment-service
EOF
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: external-kafka-credentials
  namespace: osac
  labels:
    app.kubernetes.io/part-of: osac
    app.kubernetes.io/component: external-kafka
type: Opaque
stringData:
  password: $KAFKA_FULFILLMENT_PASSWORD
EOF
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: osac-metering
  namespace: osac
  labels:
    app.kubernetes.io/part-of: osac
    app.kubernetes.io/component: external-kafka
type: Opaque
stringData:
  password: $KAFKA_METERING_PASSWORD
EOF
echo "connection objects created"

# --- 2. cutover values file ---
cat > "$CHARTS/values/edge-04/kafka-external.yaml" <<'EOF'
# Phase 5: external Kafka on edge-04 (podman single-node KRaft, 192.168.127.1:9092)
# Per docs/guides/installation/kafka-configuration.md (OSAC-4760).
# CM external-kafka + Secrets external-kafka-credentials and osac-metering are
# created out-of-band on the hub by /root/osac-kafka-external/ scripts.
# Applied once with -f; --reuse-values carries it into later surgical upgrades.
kafka:
  enabled: false
service:
  kafka:
    connection:
    - configMap:
        name: external-kafka
        items:
        - key: brokers
          param: brokers
        - key: user
          param: user
    - secret:
        name: external-kafka-credentials
        items:
        - key: password
          param: password
metering:
  kafka:
    brokers: "192.168.127.1:9092"
    clusterName: "osac-kafka"
    clusterNamespace: "osac"
EOF
echo "values file written: $CHARTS/values/edge-04/kafka-external.yaml"

# --- 3. surgical helm upgrade (AAP bootstrap hook needs the 20m timeout) ---
cd "$CHARTS"
helm upgrade osac charts/osac -n osac --reuse-values --timeout 20m \
  -f values/edge-04/kafka-external.yaml
echo "helm upgrade done (expected rev $((PREV_REV + 1)))"

# --- 4. re-apply manual patches (mandatory after every upgrade) ---
bash /root/osac-pg-migration/reapply-after-helm-upgrade.sh
echo "reapply script done"

# --- 5. verify ---
echo "=== rollouts ==="
oc -n osac rollout status deploy/fulfillment-event-publisher --timeout=300s
oc -n osac rollout status deploy/fulfillment-grpc-server --timeout=300s
oc -n osac rollout status deploy/osac-metering --timeout=600s

echo "=== wiring ==="
echo "event-publisher kafka volume sources:"
oc -n osac get deploy fulfillment-event-publisher \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="kafka")].projected.sources}'; echo
echo "metering KAFKA_BROKERS:"
oc -n osac get deploy osac-metering \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_BROKERS")].value}'; echo
echo "metering initContainer SOURCE_NS:"
oc -n osac get deploy osac-metering \
  -o jsonpath='{.spec.template.spec.initContainers[0].env[?(@.name=="SOURCE_NS")].value}'; echo
echo "fulfillment-service-kafka secret:"
oc -n osac get secret fulfillment-service-kafka >/dev/null 2>&1 \
  && echo "STILL PRESENT (unexpected)" || echo "deleted (expected)"

echo "=== canary: metering heartbeat on the new broker ==="
echo "heartbeat offsets (t0):"
krun kafka-get-offsets.sh --topic osac.metering.heartbeat
echo "metering logs (last 15):"
oc -n osac logs deploy/osac-metering --tail=15
echo "event-publisher logs (last 10):"
oc -n osac logs deploy/fulfillment-event-publisher --tail=10
echo "waiting 100s (metering publishes 1 heartbeat/min)..."
sleep 100
echo "heartbeat offsets (t0+100s):"
krun kafka-get-offsets.sh --topic osac.metering.heartbeat
echo "consumer groups:"
krun kafka-consumer-groups.sh --list
for g in $(krun kafka-consumer-groups.sh --list | grep '^osac.system' || true); do
  krun kafka-consumer-groups.sh --describe --group "$g" || true
done
echo "metering logs (last 10):"
oc -n osac logs deploy/osac-metering --tail=10
echo "CUTOVER DONE — review above; then Stage C (Strimzi teardown)"
```

The values file it writes (kept at
`values/edge-04/kafka-external.yaml`; applied once with `-f`, carried
forward by `--reuse-values`):

```yaml
# Phase 5: external Kafka on edge-04 (podman single-node KRaft, 192.168.127.1:9092)
# Per docs/guides/installation/kafka-configuration.md (OSAC-4760).
# CM external-kafka + Secrets external-kafka-credentials and osac-metering are
# created out-of-band on the hub by /root/osac-kafka-external/ scripts.
# Applied once with -f; --reuse-values carries it into later surgical upgrades.
kafka:
  enabled: false
service:
  kafka:
    connection:
    - configMap:
        name: external-kafka
        items:
        - key: brokers
          param: brokers
        - key: user
          param: user
    - secret:
        name: external-kafka-credentials
        items:
        - key: password
          param: password
metering:
  kafka:
    brokers: "192.168.127.1:9092"
    clusterName: "osac-kafka"
    clusterNamespace: "osac"
```

Verification evidence from the live cutover: event-publisher's `kafka`
projected volume sources = external CM+Secret; metering
`KAFKA_BROKERS=192.168.127.1:9092`, initContainer `SOURCE_NS=osac`; the old
`fulfillment-service-kafka` Secret deleted by helm; heartbeat offsets 7→9 in
100 s (exactly 1/min); all 23 `osac.system.*` consumer groups live on the new
broker across the auto-created `osac.events.*` topics with **lag 0**;
event-publisher drained its backlog.

### 6.4 Stage C — tear down Strimzi

Removes the in-cluster Kafka and frees 3 × 100 Gi on `lvms-vg1`. Order
matters: back up all 10 strimzi CRDs + objects first, delete the
KafkaNodePool then the Kafka CR **while the operator still runs** (it
processes the finalizers), delete the 3 broker PVCs, flip `kafka.enabled:
false` in `osac-infra` first (listener Certificate deletes while the ns
lives) then `osac-deps` (OLM deletes the CSV/operator, ns `osac-kafka`
terminates), re-apply CRDs if OLM GC'd them — the `osac` release renders
`KafkaTopic`/`KafkaUser` kinds ungated (metering subchart), so future
`helm upgrade osac` needs the CRDs to exist — then run the reapply script:

```bash
#!/bin/bash
# teardown-strimzi.sh — Phase 5 Stage C: remove the in-cluster Strimzi Kafka
# (run on edge-04 as root). Prereq: Stage B done — the hub consumes the
# external podman broker at 192.168.127.1:9092 (helm osac rev 13).
#
# Order (EDGE-04-DEPLOYMENT.md Step 7.4):
#  1. backup all 10 strimzi CRDs + Kafka/KafkaNodePool/topic/user objects
#  2. delete KafkaNodePool dual-role, then Kafka osac-kafka — while the
#     operator still runs (it processes the finalizers)
#  3. delete the 3 broker PVCs (deleteClaim:false leaves them behind) ->
#     frees 3x100Gi on lvms-vg1 (PVs are reclaim=Delete)
#  4. helm upgrade osac-infra --set kafka.enabled=false (removes config CM,
#     listener Certificate, configure-kafka hook; pure removal, proven by
#     offline render diff)
#  5. helm upgrade osac-deps --set kafka.enabled=false (removes ns osac-kafka
#     + OperatorGroup + Subscription -> OLM GCs the amq-streams CSV)
#  6. wait for ns termination, let OLM CRD GC settle, re-apply CRDs if GC'd —
#     the osac release renders KafkaTopic/KafkaUser ungated (metering
#     subchart), so future `helm upgrade osac` needs the kinds to exist
#  7. run the reapply script (infra upgrade reverts keycloak endpoints [7])
#  8. verify: no strimzi pods, PVs freed, heartbeat canary, zero lag,
#     deployments, releases
# Rollback: helm rollback osac-deps / osac-infra <rev printed at start>.
# Strimzi data is NOT preserved (PVCs deleted) — the external broker is the
# live system; an in-cluster Kafka rollback means re-seeding from scratch.
set -euo pipefail

KROOT=/root/osac-kafka-external
BACKUP=$KROOT/crd-backup
CHARTS=/root/workspace/git/osac/osac-installer
IMAGE=docker.io/apache/kafka:4.2.0
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

krun() { # krun <tool> [args...] — admin client, host network
  local tool=$1; shift
  podman run --rm --security-opt label=disable --user 0:0 --network host \
    -v "$KROOT/client-admin.properties:/etc/kafka/client.properties:ro" \
    --entrypoint /bin/bash "$IMAGE" \
    -c "/opt/kafka/bin/$tool --bootstrap-server 192.168.127.1:9092 --command-config /etc/kafka/client.properties $*"
}

wait_gone() { # wait_gone "<oc get args>" <timeout-s> <label> — named objects only
  # deadline on its OWN local line: bash expands every argument of a single
  # local statement before any assignment lands, so referencing t in the same
  # statement died with "t: unbound variable" under set -u (hit us once).
  local args=$1 t=$2 label=$3
  local deadline=$(( $(date +%s) + t ))
  while oc get $args >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "TIMEOUT: $label still present after ${t}s"; return 1; fi
    sleep 15
  done
  echo "gone: $label"
}

# --- 0. pre-checks ---
echo "=== pre-checks ==="
krun kafka-broker-api-versions.sh >/dev/null || { echo "FAIL: external broker unreachable"; exit 1; }
echo "external broker reachable"
oc -n osac get cm external-kafka >/dev/null 2>&1 && oc -n osac get secret external-kafka-credentials >/dev/null 2>&1 \
  || { echo "FAIL: Stage B connection objects missing"; exit 1; }
echo "Stage B connection objects present"
OSAC_REV=$(helm status osac -n osac | awk '/^REVISION:/{print $2}')
DEPS_REV=$(helm status osac-deps -n osac-deps | awk '/^REVISION:/{print $2}')
INFRA_REV=$(helm status osac-infra -n osac-infra | awk '/^REVISION:/{print $2}')
echo "revisions before: osac=$OSAC_REV deps=$DEPS_REV infra=$INFRA_REV"
oc -n osac-kafka get kafka osac-kafka >/dev/null 2>&1 || { echo "FAIL: Kafka CR osac-kafka not found"; exit 1; }
oc -n osac-kafka get pods --no-headers | grep -q "amq-streams-cluster-operator.*Running" \
  || { echo "FAIL: strimzi operator not Running"; exit 1; }
echo "Kafka CR present, strimzi operator Running"
NGROUPS=$(krun kafka-consumer-groups.sh --list 2>/dev/null | grep -c "^osac.system" || true)
echo "osac.system consumer groups on external broker: $NGROUPS"
[ "$NGROUPS" -ge 20 ] || { echo "FAIL: too few groups on external broker — Stage B not in effect?"; exit 1; }
REFS=$(oc -n osac get deploy -o yaml 2>/dev/null | grep -c "osac-kafka-kafka-bootstrap" || true)
[ "$REFS" -eq 0 ] || { echo "FAIL: $REFS deploy refs still point at in-cluster bootstrap"; exit 1; }
echo "no ns-osac deployment references the in-cluster bootstrap"
mkdir -p "$BACKUP"
ssh -o BatchMode=yes -o ConnectTimeout=10 core@192.168.127.19 'sudo lvs --noheadings -o lv_name,lv_size' > "$BACKUP/lvs-before.txt" 2>/dev/null || true
echo "hub VM LV count before teardown: $(wc -l < "$BACKUP/lvs-before.txt" 2>/dev/null || echo 0)"

# --- 1. backup CRDs + objects ---
echo "=== backup CRDs and objects -> $BACKUP ==="
mkdir -p "$BACKUP"
NCRD=0
for crd in $(oc get crd -o name | grep strimzi); do
  oc get "$crd" -o yaml > "$BACKUP/$(basename "$crd").yaml"
  NCRD=$((NCRD+1))
done
echo "backed up $NCRD strimzi CRDs"
# object backups tolerate already-deleted objects (idempotent re-runs)
oc -n osac-kafka get kafka osac-kafka -o yaml > "$BACKUP/objects-kafka-osac-kafka.yaml" 2>/dev/null \
  || echo "kafka CR already gone — nothing to back up"
oc -n osac-kafka get kafkanodepool dual-role -o yaml > "$BACKUP/objects-kafkanodepool-dual-role.yaml" 2>/dev/null \
  || echo "kafkanodepool dual-role already gone — nothing to back up"
oc -n osac get kafkatopic -o yaml > "$BACKUP/objects-kafkatopics-ns-osac.yaml" 2>/dev/null || true
oc -n osac get kafkauser -o yaml > "$BACKUP/objects-kafkausers-ns-osac.yaml" 2>/dev/null || true
echo "objects backed up"
CRD_COUNT_BEFORE=$(oc get crd 2>/dev/null | grep -c strimzi || true)

# --- 2. delete node pool then Kafka CR (operator must stay up for finalizers) ---
echo "=== delete stray KafkaTopics/KafkaUsers in osac-kafka (if any) ==="
oc -n osac-kafka delete kafkatopic --all --ignore-not-found --wait=false 2>/dev/null || true
oc -n osac-kafka delete kafkauser --all --ignore-not-found --wait=false 2>/dev/null || true
for i in $(seq 1 20); do
  C=$(oc -n osac-kafka get kafkatopic,kafkauser --no-headers 2>/dev/null | wc -l)
  [ "$C" -eq 0 ] && break
  sleep 10
done
echo "stray topic/user CRs in osac-kafka: $C"
echo "=== delete KafkaNodePool dual-role ==="
oc -n osac-kafka delete kafkanodepool dual-role --wait=false --ignore-not-found
wait_gone "-n osac-kafka kafkanodepool dual-role" 900 "kafkanodepool dual-role"
echo "=== delete Kafka osac-kafka ==="
oc -n osac-kafka delete kafka osac-kafka --wait=false --ignore-not-found
wait_gone "-n osac-kafka kafka osac-kafka" 600 "kafka osac-kafka"
oc -n osac-kafka get pods --no-headers 2>/dev/null | awk '{print "remaining pod:", $1, $3}' || true
echo "cluster CRs deleted (operator processes finalizers)"

# --- 3. delete broker PVCs ---
echo "=== delete broker PVCs (3 x 100Gi, lvms-vg1, PVs reclaim=Delete) ==="
oc -n osac-kafka delete pvc data-osac-kafka-dual-role-0 data-osac-kafka-dual-role-1 data-osac-kafka-dual-role-2 --wait=false --ignore-not-found
for p in pvc-46ebfcb0-bcb0-4680-9352-1d6dac66eb25 pvc-c0675c44-c561-4dc2-ab13-1618f72e5817 pvc-22f88d7a-459b-4a70-bc80-9e0a474d28fa; do
  wait_gone "pv $p" 300 "pv $p"
done
echo "3 broker PVs gone — lvms-vg1 space freed"

# --- 4. infra upgrade: kafka.enabled=false ---
echo "=== helm upgrade osac-infra (kafka.enabled=false) ==="
cd "$CHARTS"
helm upgrade osac-infra charts/osac-infra -n osac-infra --reuse-values --set kafka.enabled=false --timeout 15m
echo "osac-infra upgraded (expected rev $((INFRA_REV+1)))"

# --- 5. deps upgrade: kafka.enabled=false (deletes ns osac-kafka) ---
echo "=== helm upgrade osac-deps (kafka.enabled=false) ==="
helm upgrade osac-deps charts/osac-deps -n osac-deps --reuse-values --set kafka.enabled=false --timeout 15m
echo "osac-deps upgraded (expected rev $((DEPS_REV+1)))"

# --- 6. ns termination + CRD GC settle + re-apply ---
echo "=== wait for ns osac-kafka termination ==="
NS_HUNG=0
NS_DEADLINE=$(( $(date +%s) + 600 ))
while oc get ns osac-kafka >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$NS_DEADLINE" ]; then NS_HUNG=1; break; fi
  sleep 15
done
if [ "$NS_HUNG" -eq 0 ]; then
  echo "gone: ns osac-kafka"
else
  echo "WARN: ns osac-kafka still Terminating after 600s (known packagemanifests issue)"
  echo "WARN: if force-finalized later, re-check 'oc get crd | grep strimzi' and re-apply from $BACKUP"
fi

echo "=== wait for OLM CRD GC to settle (60s stable) ==="
STABLE=0; LAST=$CRD_COUNT_BEFORE
SETTLE_DEADLINE=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$SETTLE_DEADLINE" ]; do
  NOW=$(oc get crd 2>/dev/null | grep -c strimzi || true)
  if [ "$NOW" -eq "$LAST" ]; then STABLE=$((STABLE+1)); else STABLE=0; LAST=$NOW; fi
  [ "$STABLE" -ge 4 ] && break
  sleep 15
done
echo "strimzi CRDs now: $LAST (was $CRD_COUNT_BEFORE)"
echo "=== re-apply CRDs if OLM GC'd them ==="
REAPLIED=0
for f in "$BACKUP"/*.strimzi.io.yaml; do
  n=$(basename "$f" .yaml)
  if ! oc get crd "$n" >/dev/null 2>&1; then
    oc apply -f "$f" >/dev/null && REAPPLIED=$((REAPLIED+1)) && echo "re-applied CRD $n"
  fi
done
echo "re-applied $REAPLIED CRDs"
if [ "$REAPLIED" -gt 0 ]; then
  sleep 10
  for i in $(seq 1 24); do
    MISS=0
    for f in "$BACKUP"/*.strimzi.io.yaml; do
      n=$(basename "$f" .yaml)
      S=$(oc get crd "$n" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)
      [ "$S" = "True" ] || MISS=1
    done
    [ "$MISS" -eq 0 ] && break
    sleep 5
  done
  echo "re-applied CRDs Established"
fi

# --- 7. reapply script ---
echo "=== reapply script (keycloak endpoints [7] etc.) ==="
bash /root/osac-pg-migration/reapply-after-helm-upgrade.sh
echo "reapply script done"

# --- 8. verify ---
echo "=== verify: strimzi leftovers ==="
oc get pods -A --no-headers 2>/dev/null | grep -iE "strimzi|osac-kafka" || echo "no strimzi/osac-kafka pods anywhere"
oc get csv -A 2>/dev/null | grep -i amq || echo "no amq CSV"
oc get crd 2>/dev/null | grep strimzi || echo "no strimzi CRDs present (unexpected)"
echo "=== verify: osac deployments ==="
oc -n osac get deploy --no-headers | awk -F"[ /]+" '{print $1, $2"/"$4}'
NOTRDY=$(oc -n osac get deploy --no-headers | awk -F"[ /]+" '$2 != $4 {print $1}' || true)
if [ -z "$NOTRDY" ]; then echo "all osac deployments ready"; else echo "NOT READY: $NOTRDY"; fi
echo "=== verify: keycloak endpoints (reapply [7]) ==="
echo -n "keycloak endpoints: "
oc -n osac get endpoints keycloak -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}'; echo " (expect 192.168.127.1:8443)"
echo "=== verify: node + cluster operators ==="
oc get nodes --no-headers | awk '{print "node:", $1, $2}'
oc get co --no-headers | awk '$3 != "True" || $4 == "True" || $5 == "True" {print "CO flag:", $1, $3, $4, $5}'
echo "(machine-config Degraded = known chrony drift)"
echo "=== verify: heartbeat canary on external broker ==="
echo "offsets (t0):"
krun kafka-get-offsets.sh --topic osac.metering.heartbeat
sleep 100
echo "offsets (t0+100s):"
krun kafka-get-offsets.sh --topic osac.metering.heartbeat
echo "=== verify: consumer lag (all groups) ==="
LAG=$(krun kafka-consumer-groups.sh --describe --all-groups 2>/dev/null | awk '$6 ~ /^[0-9]+$/ && $6+0 > 0' || true)
if [ -z "$LAG" ]; then echo "zero lag across all groups"; else echo "LAG DETECTED:"; echo "$LAG"; fi
echo "metering logs (last 5):"
oc -n osac logs deploy/osac-metering --tail=5 || true
echo "=== verify: hub VM LVs ==="
ssh -o BatchMode=yes -o ConnectTimeout=10 core@192.168.127.19 'sudo lvs --noheadings -o lv_name,lv_size' > "$BACKUP/lvs-after.txt" 2>/dev/null || true
echo "LV count: before=$(wc -l < "$BACKUP/lvs-before.txt" 2>/dev/null || echo 0) after=$(wc -l < "$BACKUP/lvs-after.txt" 2>/dev/null || echo 0)"
echo "LVs removed (diff before vs after):"
diff "$BACKUP/lvs-before.txt" "$BACKUP/lvs-after.txt" 2>/dev/null | grep "^<" || echo "(no LV lines removed — check manually if unexpected)"
echo "=== verify: helm releases ==="
helm list -A | grep -E "^osac" || true
echo "STAGE C DONE — review above; then Stage D (doc finalize)"
```

(`start-teardown.sh` next to it just launches this detached with a log file.)

Live outcome: OLM **kept** the 10 CRDs (re-applied 0), so the 5 KafkaTopics +
KafkaUser the osac metering subchart renders in ns `osac` stay a valid
release; hub VM `lvs` 11→8; ns terminated cleanly; heartbeat canary and zero
lag verified after.

### 6.5 Day-2: canary, restarts, cert renewal

```bash
# heartbeat canary — the alarm for a dead broker (metering publishes 1/min)
podman run --rm --security-opt label=disable --user 0:0 --network host \
  -v /root/osac-kafka-external/client-admin.properties:/etc/kafka/client.properties:ro \
  --entrypoint /bin/bash docker.io/apache/kafka:4.2.0 \
  -c "/opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server 192.168.127.1:9092 \
      --command-config /etc/kafka/client.properties --topic osac.metering.heartbeat --time -1"
# run twice ~100 s apart; offsets must advance by ~1-2 per partition

# consumer-group lag (all osac.system.* groups should sit at lag 0)
podman run --rm --security-opt label=disable --user 0:0 --network host \
  -v /root/osac-kafka-external/client-admin.properties:/etc/kafka/client.properties:ro \
  --entrypoint /bin/bash docker.io/apache/kafka:4.2.0 \
  -c "/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 192.168.127.1:9092 \
      --command-config /etc/kafka/client.properties --list"

# restart the broker
podman stop osac-kafka && podman start osac-kafka    # or systemctl restart container-osac-kafka
```

> **Certificate renewal is NOT synced**: cert-manager may renew the
> `osac-external-kafka-tls` Secret in the cluster; the copy in
> `/root/osac-kafka-external/tls/` will not follow. If the cert renews,
> re-copy `tls.crt`/`tls.key`/`ca.crt` out of the Secret and restart the
> service (setup-kafka.sh does this copy on re-run). Current cert expires
> 2031-10-20.

---

## 7. Helm values reference

Live user-supplied values of the three releases (excerpted to the
external-services-relevant keys; `helm get values <release> -n <ns>` for the
full set). The chart pin is `fc7a09f`; the working tree on edge-04 carries
the `values/edge-04/` overlay (untracked) with `values.yaml` (base install),
`instance.yaml`, and `kafka-external.yaml` (§6.3).

```yaml
# ── release osac (ns osac) ─────────────────────────────────────────────
kafka:
  enabled: false                    # skip installer-managed KafkaUser + credential-copy job
service:
  auth:                             # issuer URLs unchanged — Keycloak hostname preserved
    controllerCredentials: […]      # from secret fulfillment-controller-credentials
  certs:
    caBundle: { configMap: ca-bundle }
  database:
    connection: […]                 # secrets osac-db-config (url) + osac-db-client-cert
                                     # (tls.crt/tls.key/ca.crt) — unchanged by externalization
  externalHostname: fulfillment-api-osac.apps.osac-hub.redhat.com
  idp: { provider: keycloak, credentials: […] }
  images:
    service:                        # digest pins (anti image-drift, see §11)
      repository: ghcr.io/osac-project/fulfillment-service
      tag: latest@sha256:dc919fe26fb8f4535ba3e6f13c0047f35a8196c9d9d12cece9f2c3aa21b8388a
  kafka:
    connection:                     # external broker (Phase 5)
    - configMap: { name: external-kafka, items: [{key: brokers, param: brokers},
                                                  {key: user, param: user}] }
    - secret:    { name: external-kafka-credentials, items: [{key: password, param: password}] }
  vault:                            # external OpenBao (Phase 2)
    endpoint: https://192.168.127.1:8200
    caBundle: { configMap: ca-bundle }
    keycloakIssuerUrl: https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac
    keycloakClientId: osac-controller
    keycloakAudience: osac-api
    namespace: osac
    kvMountPath: secret
    lifecycleMountPath: jwt
    lifecycleRole: lifecycle
metering:
  enabled: true
  database: { connection: […] }     # secrets osac-db-metering-config + osac-db-metering-client-cert
  kafka:                            # external broker (Phase 5, lab hack — §6.3)
    brokers: 192.168.127.1:9092
    clusterName: osac-kafka
    clusterNamespace: osac
operator:
  image:
    repository: ghcr.io/osac-project/osac-operator
    tag: latest@sha256:8c5a212ec96bd812f41166329e68b5f99ff275e32ea8794c23a80f4115aa8c51

# ── release osac-infra (ns osac-infra) ─────────────────────────────────
bundledPostgres:
  enabled: false                    # Phase 1: no bundled postgres pod since rev 2
  database: { name: service, user: service }
bundledVault:
  enabled: false                    # Phase 2: no bundled openbao since rev 2
kafka:
  enabled: false                    # Phase 5 Stage C: listener Certificate + hook CM removed
keycloak:
  enabled: true                     # chart still owns svc+route (hostname preservation)
  hostname: https://keycloak-keycloak.apps.osac-hub.redhat.com
  route: { hostname: keycloak-keycloak.apps.osac-hub.redhat.com }

# ── release osac-deps (ns osac-deps) ───────────────────────────────────
kafka:
  enabled: false                    # Phase 5 Stage C: ns osac-kafka + OLM subscription removed
# (bundledPostgres/bundledVault stay true here — the deps layer does not run
#  them in this profile; the infra layer's false is what counts)
```

**Schema gotcha:** `charts/osac/values.schema.json` sets
`additionalProperties: false` at the root. Allowed root keys include
`service`, `metering`, `kafka`, `operator`, `global`, … — but **not**
`images`. The image tags live under `service.images.*`, so a digest pin must
be `--set service.images.service.tag=<digest>`, not
`--set images.service.tag=…` (the latter fails validation with
`additional properties 'images' not allowed` — harmlessly, before any
revision is created).

**Upgrade procedure** (surgical, reuses values, carries the externals
forward):

```bash
cd /root/workspace/git/osac/osac-installer
set -o pipefail   # BEFORE the pipeline — so reapply only runs on helm success
helm upgrade osac charts/osac -n osac --reuse-values --timeout 20m \
  [--set service.images.service.tag=<digest>] 2>&1 | tail -8 \
  && bash /root/osac-pg-migration/reapply-after-helm-upgrade.sh
```

The 20 m timeout is not optional: the AAP bootstrap post-install hook alone
takes ~7 min, longer than helm's 5-min default. AAP hook jobs re-run on
every upgrade — that is idempotent by design.

---

## 8. The reapply script — mandatory after every `helm upgrade`

Everything wired imperatively (selectorless Services, OAuth env patches,
operator resources/RBAC, envoy ALPN) is reverted when its chart re-renders.
One script re-applies all of it, check-first/idempotent, and verifies:

```bash
#!/bin/bash
# Re-apply manual patches after any helm upgrade of osac-infra or osac releases.
# Idempotent - safe to run at any time. See EDGE-04-DEPLOYMENT.md Known Issues.
#
# v2 adds [2b] operator resources, [2c] fabricdomain RBAC, rewrites [4] to
# enforce full ALPN state, and adds [5]-wide rollouts + [6] post-checks.
# [2b], [2c], [4] are check-first and SELF-RETIRING once their upstream fixes
# land in the chart pin:
#  - [2b] patches only the known-bad 128Mi parent-chart override; no-op once
#    the parent chart stops overriding operator.resources (upstream PR).
#  - [2c] adds fabricdomain RBAC only while the operator SA lacks it; no-op
#    once the chart pin includes the post-#1270 ClusterRole rules.
#  - [4] normalizes envoy ALPN to [h2, http/1.1] only when it differs; no-op
#    once the chart pin includes PR 1796. RFC 7301: the TLS server picks the
#    negotiated protocol by its own list order - http/1.1 first pins every
#    dual-offering client (Go net/http ForceAttemptHTTP2, browsers) to
#    HTTP/1.1, which cannot carry gRPC trailers (missing Grpc-Status).
export KUBECONFIG=/root/.kube/osac-hub.kubeconfig

echo "== [1] PostgreSQL Service -> external host (192.168.127.1:5432)"
oc -n osac-infra patch svc postgres --type=json -p '[{"op":"remove","path":"/spec/selector"}]' >/dev/null 2>&1
oc -n osac-infra patch endpoints postgres --type=merge -p '{"subsets":[{"addresses":[{"ip":"192.168.127.1"}],"ports":[{"name":"postgres","port":5432,"protocol":"TCP"}]}]}' >/dev/null
oc -n osac-infra delete endpointslice -l kubernetes.io/service-name=postgres >/dev/null 2>&1
sleep 5
echo "   endpoints: $(oc -n osac-infra get endpoints postgres -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null) (slice re-mirrored)"

echo "== [2] osac-operator OAuth env (from fulfillment-controller-credentials)"
if ! oc -n osac get deploy osac-operator -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx OSAC_FULFILLMENT_CLIENT_ID; then
  oc -n osac patch deploy osac-operator --type=json -p '[
   {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OSAC_FULFILLMENT_CLIENT_ID","valueFrom":{"secretKeyRef":{"name":"fulfillment-controller-credentials","key":"client-id"}}}},
   {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"OSAC_FULFILLMENT_CLIENT_SECRET","valueFrom":{"secretKeyRef":{"name":"fulfillment-controller-credentials","key":"client-secret"}}}}]' >/dev/null && echo "   operator patched"
else echo "   operator already patched"; fi

echo "== [2b] osac-operator resources (parent chart overrides subchart 512Mi -> 128Mi)"
cur=$(oc -n osac get deploy osac-operator -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)
if [ "$cur" = "128Mi" ]; then
  oc -n osac patch deploy osac-operator --type=json -p '[
   {"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"10m","memory":"256Mi"}}}]' >/dev/null && echo "   operator resources patched 128Mi -> 512Mi"
elif [ -n "$cur" ]; then
  echo "   operator limits.memory = $cur (not the 128Mi override; leaving as-is)"
else
  echo "   WARNING: could not read operator resources"
fi

echo "== [2c] fabricdomain RBAC (chart pin predates the rules; operator :latest has the controller)"
if oc auth can-i list fabricdomains.osac.openshift.io -A --as=system:serviceaccount:osac:osac-operator >/dev/null 2>&1; then
  echo "   operator SA can list fabricdomains (rules present)"
elif oc get clusterrole osac-operator-manager >/dev/null 2>&1; then
  oc patch clusterrole osac-operator-manager --type=json -p '[
   {"op":"add","path":"/rules/-","value":{"apiGroups":["osac.openshift.io"],"resources":["fabricdomains"],"verbs":["get","list","patch","update","watch"]}},
   {"op":"add","path":"/rules/-","value":{"apiGroups":["osac.openshift.io"],"resources":["fabricdomains/finalizers"],"verbs":["update"]}},
   {"op":"add","path":"/rules/-","value":{"apiGroups":["osac.openshift.io"],"resources":["fabricdomains/status"],"verbs":["get","patch","update"]}}]' >/dev/null && echo "   fabricdomain rules added to osac-operator-manager"
  # clear CrashLoopBackOff backoff so the operator recovers immediately
  oc -n osac rollout restart deploy/osac-operator >/dev/null && echo "   operator restarted (clears crash backoff)"
  if oc auth can-i list fabricdomains.osac.openshift.io -A --as=system:serviceaccount:osac:osac-operator >/dev/null 2>&1; then
    echo "   verified: operator SA can list fabricdomains"
  else
    echo "   WARNING: rules added but can-i still denies - check role bindings"
  fi
else
  echo "   WARNING: clusterrole osac-operator-manager not found"
fi

echo "== [3] osac-metering OAuth env + credentials volume"
if ! oc -n osac get deploy osac-metering -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx FULFILLMENT_ISSUER_URL; then
  oc -n osac patch deploy osac-metering --type=json -p '[
   {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"fulfillment-credentials","secret":{"secretName":"fulfillment-controller-credentials","items":[{"key":"client-id","path":"client-id"},{"key":"client-secret","path":"client-secret"}]}}},
   {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"fulfillment-credentials","mountPath":"/etc/fulfillment-credentials","readOnly":true}},
   {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_ISSUER_URL","valueFrom":{"configMapKeyRef":{"name":"osac-fulfillment-config","key":"OSAC_FULFILLMENT_ISSUER_URL"}}}},
   {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_CLIENT_ID_FILE","value":"/etc/fulfillment-credentials/client-id"}},
   {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"FULFILLMENT_CLIENT_SECRET_FILE","value":"/etc/fulfillment-credentials/client-secret"}}]' >/dev/null && echo "   metering patched"
else echo "   metering already patched"; fi

echo "== [4] envoy ALPN (valid http/1.1 id + h2-first order; both listeners)"
oc -n osac get cm fulfillment-ingress-proxy -o json > /tmp/envoy-cm-reapply.json 2>/dev/null
python3 - /tmp/envoy-cm-reapply.json <<'PYEOF'
import json, re, sys
cm = json.load(open(sys.argv[1]))
data = cm['data'].get('envoy.yaml', '')
block_re = re.compile(r"(?P<ind>[ ]*)alpn_protocols:\n(?:(?P=ind)- [^\n]+\n)+")
allowed = {"http1.1", "http/1.1", "h2"}
def repl(m):
    ind = m.group('ind')
    items = [ln.strip()[2:] for ln in m.group(0).splitlines()[1:]]
    if not set(items) <= allowed:
        return m.group(0)  # unknown ALPN ids present - do not touch
    return "%salpn_protocols:\n%s- h2\n%s- http/1.1\n" % (ind, ind, ind)
blocks = block_re.findall(data)
new = block_re.sub(repl, data)
if not blocks:
    print("   WARNING: no alpn_protocols blocks found in envoy configmap")
    sys.exit(0)
if new == data:
    print("   envoy ALPN already correct ([h2, http/1.1]) on %d listener(s)" % len(blocks))
    sys.exit(0)
json.dump({"data": {"envoy.yaml": new}}, open('/tmp/envoy-alpn-patch.json', 'w'))
open('/tmp/envoy-alpn-changed', 'w').write('1')
print("   envoy ALPN normalized to [h2, http/1.1] on %d listener(s)" % len(blocks))
PYEOF
if [ -f /tmp/envoy-alpn-changed ]; then
  rm -f /tmp/envoy-alpn-changed
  oc -n osac patch cm fulfillment-ingress-proxy --type=merge -p "$(cat /tmp/envoy-alpn-patch.json)" >/dev/null && echo "   envoy configmap patched"
  rm -f /tmp/envoy-alpn-patch.json
  oc -n osac rollout restart deploy/fulfillment-ingress-proxy >/dev/null && echo "   envoy restarted"
fi
rm -f /tmp/envoy-cm-reapply.json

echo "== [5] rollout status"
for d in osac-operator osac-metering fulfillment-ingress-proxy osac-ui fulfillment-grpc-server fulfillment-rest-gateway fulfillment-console-proxy fulfillment-controller fulfillment-event-publisher; do
  printf "   %-32s %s\n" "$d" "$(oc -n osac rollout status deploy/$d --timeout=240s 2>&1 | tail -1)"
done

echo "== [6] post-checks"
printf "   fabricdomain RBAC (can-i list): %s\n" "$(oc auth can-i list fabricdomains.osac.openshift.io -A --as=system:serviceaccount:osac:osac-operator 2>/dev/null)"
printf "   envoy ALPN h2-first blocks:     %s (expect 2)\n" "$(oc -n osac get cm fulfillment-ingress-proxy -o jsonpath='{.data.envoy\.yaml}' 2>/dev/null | grep -cE '^[[:space:]]*- h2$')"
printf "   operator limits.memory:         %s\n" "$(oc -n osac get deploy osac-operator -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
echo
oc -n osac get pods
echo "done."

echo "== [7] external Keycloak endpoints (Phase 3 cutover, 2026-10-20)"
oc -n keycloak scale deploy keycloak-service --replicas=0 >/dev/null 2>&1
oc -n keycloak patch svc keycloak --type=json -p '[{"op":"remove","path":"/spec/selector"}]' >/dev/null 2>&1
oc -n keycloak patch svc keycloak --type=merge -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":8443,"protocol":"TCP"}]}}' >/dev/null
oc -n keycloak patch endpoints keycloak --type=merge -p '{"subsets":[{"addresses":[{"ip":"192.168.127.1"}],"ports":[{"name":"https","port":8443,"protocol":"TCP"}]}]}' >/dev/null
oc -n keycloak delete endpointslice -l kubernetes.io/service-name=keycloak >/dev/null 2>&1
sleep 5
echo "   keycloak endpoints: $(oc -n keycloak get endpoints keycloak -o jsonpath='{.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}')"

echo "== [8] edge-16 remote-cluster kubeconfig (Phase 4 VMaaS wiring)"
if oc -n osac get secret osac-remote-kubeconfig >/dev/null 2>&1; then
  oc -n osac patch deployment osac-operator --type=strategic -p '{
    "spec": {"template": {"spec": {
      "volumes": [{"name": "remote-kubeconfig", "secret": {"secretName": "osac-remote-kubeconfig"}}],
      "containers": [{"name": "manager",
        "volumeMounts": [{"name": "remote-kubeconfig", "mountPath": "/var/run/secrets/remote", "readOnly": true}],
        "env": [{"name": "OSAC_REMOTE_CLUSTER_KUBECONFIG", "value": "/var/run/secrets/remote/kubeconfig"}]
      }]
    }}}
  }' >/dev/null
  oc -n osac patch secret config-as-code-ig --type=strategic -p '{
    "stringData": {
      "REMOTE_CLUSTER_KUBECONFIG_SECRET_NAME": "osac-remote-kubeconfig",
      "REMOTE_CLUSTER_KUBECONFIG_SECRET_KEY": "kubeconfig"
    }
  }' >/dev/null
  echo "   operator OSAC_REMOTE_CLUSTER_KUBECONFIG: $(oc -n osac get deploy osac-operator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OSAC_REMOTE_CLUSTER_KUBECONFIG")].value}')"
  echo "   config-as-code-ig REMOTE_CLUSTER_KUBECONFIG_SECRET_NAME: $(oc -n osac get secret config-as-code-ig -o jsonpath='{.data.REMOTE_CLUSTER_KUBECONFIG_SECRET_NAME}' | base64 -d)"
  echo "   NOTE: re-run AAP job osac-config-as-code to re-render the instance groups"
else
  echo "   skipped (secret osac-remote-kubeconfig absent - edge-16 not wired yet)"
fi
```

| Section | What it re-applies | Retires when |
|---|---|---|
| [1] | PG selectorless svc + Endpoints + EndpointSlice re-mirror | `dbInit.host` converged to the supported external-DB path |
| [2] | operator OAuth env (`fulfillment-controller-credentials`) | chart ≥ the Oct-14 OAuth wiring (already on origin/main) |
| [2b] | operator memory 128Mi → 512Mi | parent-chart `operator.resources` override lands |
| [2c] | fabricdomain RBAC in `osac-operator-manager` ClusterRole | chart carries the rules |
| [3] | metering OAuth env + credentials volume | same as [2] |
| [4] | envoy ALPN `[h2, http/1.1]` on both listeners | upstream PR 1796 merges into a release |
| [5] | rollout status of all osac deployments | — (verification) |
| [6] | post-checks (can-i list fabricdomains, ALPN count, limits) | — (verification) |
| [7] | keycloak selectorless svc + Endpoints (Phase 3) | chart grows an external-keycloak mode |
| [8] | remote-cluster kubeconfig wiring for edge-16 (VMaaS) | chart-native wiring |

---

## 9. Verification battery

Run from edge-04 (`export KUBECONFIG=/root/.kube/osac-hub.kubeconfig`).
This is the full green-state check the lab settles at after any change:

```bash
# cluster health
oc get co                             # every column Available=True, not progressing, not degraded
oc get nodes                          # Ready (machine-config may flag known chrony drift)
oc -n osac get pods                   # all Running/Completed; no CrashLoopBackOff

# MCE / workload cluster
oc get managedclusters                # local-cluster + edge-16 True/True
oc -n osac get vm                     # vm-wrb9t Running, 10.200.0.7 (demo artifact)

# external wiring intact
oc -n osac-infra get endpoints postgres \
  -o jsonpath='{.subsets[0].addresses[0].ip}'        # 192.168.127.1
oc -n keycloak get endpoints keycloak \
  -o jsonpath='{.subsets[0].addresses[0].ip}'        # 192.168.127.1

# HTTP health of the externals
curl -sk -o /dev/null -w '%{http_code}\n' https://osac-ui-osac.apps.osac-hub.redhat.com/                       # 200
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.127.1:8200/v1/sys/health                             # 200
curl -sk https://keycloak-keycloak.apps.osac-hub.redhat.com/realms/osac | python3 -c "import sys,json;print(json.load(sys.stdin)['realm'])"

# REST chain probe (auth chain intact; 401 on a dummy token is the GREEN result)
curl -sk -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer dummy' \
  https://fulfillment-api-osac.apps.osac-hub.redhat.com/api/fulfillment/v1/tenants   # 401
# (on the hub VM the route needs SNI help: --resolve <route-host>:443:127.0.0.1)

# Kafka canary (§6.5): heartbeat offsets advance; consumer lag 0
```

Note the REST paths are **snake_case**
(`/api/fulfillment/v1/compute_instances/{id}`, not camelCase — camelCase
404s).

---

## 10. Backups overview

All nightly, host-local (cron entries in `/etc/cron.d/`), staggered so
nothing overlaps; each script verifies its own output.

| Time | Service | Script | Output | Retention | Cost |
|---|---|---|---|---|---|
| 02:00 | Keycloak | `/root/kc-backup/backup-keycloak.sh` | realm/users/orgs/members/LDAP JSON + `kc-data` tar | 7 JSON / 3 tars | ~40 s KC blip (stop/start) |
| 02:17 | PostgreSQL | `/usr/local/sbin/osac-pg-backup.sh` | `pg_dumpall` gzip | 14 | none (online dump) |
| 02:30 | OpenBao | `/root/bao-backup/backup-openbao.sh` | `bao-data` tar | 14 | ~4 s Bao blip (systemctl stop/start) |

Full listings: §3.6 (PG), §4.5 (OpenBao), §5.6 (Keycloak). Restore procedures
sit next to each listing. Kafka has no backup — it is an event log with 7 d
retention; the canary (§6.5) is its health alarm.

---

## 11. Gotchas compendium

**systemd unit shapes — the one table to internalize:**

| Container | Unit style | Bare `podman stop` | How to stop/start safely |
|---|---|---|---|
| `osac-openbao` | `--new` (`podman run --rm`, `Restart=always`, ~100 ms) | **undone in ~100 ms** — systemd re-creates the container; the old one is already `--rm`'d away | `systemctl stop/start container-osac-openbao` ONLY |
| `osac-postgres` | old (`podman start`, `Type=forking`) | sticks (systemd doesn't watch) | `podman stop/start` or systemctl — both fine |
| `keycloak-lab` | old (`podman start`, `Restart=always`) | sticks | `podman stop/start` (backup script relies on this) |
| `osac-kafka` | `Type=oneshot` + `RemainAfterExit`, no ExecStop | sticks; unit shows inactive while container runs | `podman stop/start osac-kafka`; `systemctl restart` re-creates via `--replace` |

**Everything else, in the order it bites:**

1. **Envoy ALPN** — chart renders `[http1.1, h2]`: invalid token (RFC 7301
   wants `http/1.1`) and wrong order (Envoy-as-server follows list order;
   dual-ALPN clients pinned to HTTP/1.1, which drops gRPC trailers → UI
   login spinner). Fixed live + reapply [4]; upstream PR 1796.
2. **Helm upgrade reverts imperative patches** — that is what the reapply
   script is for (§8). `--reuse-values` carries the values-file changes
   (kafka-external.yaml etc.) forward; only `--set` changes need re-passing.
3. **AAP hook timeout** — `--timeout 20m` or the bootstrap hook kills the
   upgrade.
4. **`set -o pipefail`** before any `helm … | tail` pipeline, or the reapply
   runs after a *failed* helm (harmless but misleading).
5. **values.schema.json** — root `additionalProperties: false`; image tags
   live at `service.images.service.tag`, not `images.service.tag`.
6. **Image drift** — `:latest` tags moved through three digests in one day;
   both `service.images.service.tag` and `operator.image.tag` are digest-
   pinned in release values. Re-check `helm get values` after upgrades.
7. **REST paths are snake_case**; camelCase 404s.
8. **Passthrough routes from the hub VM** need `curl --resolve
   <route-host>:443:127.0.0.1` (SNI) — plain curl hits the wrong vhost.
9. **Kafka listener-name casing / credential-free JAAS / listener
   truststore** — §6.2 (a)–(c).
10. **Kafka console CLI** — stdin needs `-i`; deprecated flags print
    warnings on stdout; `GetOffsetShell` is gone (§6.2 (d)–(f)).
11. **EndpointSlice re-mirror** — after rewriting Endpoints, delete the
    label-matched slices and let the mirroring controller recreate them
    (or apply a manual slice if it doesn't; the cutover script handles both).
12. **trust-manager owns `ca-bundle`** — patch the `Bundle` CR, never the
    ConfigMap.
13. **Clock skew** breaks JWT validation (§2.3).
14. **cron PATH** — cron's minimal PATH lacks `/usr/sbin` (iptables);
    backup scripts export a full PATH or they die mid-stop leaving a stale
    CNI lease (Keycloak backup, first automated run).
15. **OpenBao file-storage backup** must go through `systemctl` (§4.5) —
    the `--new`-unit trap.
16. **Keycloak image runs as uid 1000** — root-owned TLS key files abort
    startup (`AccessDeniedException`); chown 1000:0.
17. **`podman generate systemd` is deprecated** (podman ≥ 4, Quadlet is the
    successor) — the generated units still work and are what runs here.

---

## 12. Rollback matrix

| Service | Rollback | Data caveat |
|---|---|---|
| PostgreSQL | `helm upgrade osac-infra … --set bundledPostgres.enabled=true` (chart restores deploy + Service selector), restore a dump into it, restart ns `osac` deployments | loses everything written to the external instance after cutover |
| OpenBao | `helm upgrade osac-infra … --set bundledVault.enabled=true` + `service.vault.endpoint` back to the in-cluster URL; restore `/root/bao-data` from the pre-migration tarball if needed | secrets written after cutover exist only in `/root/bao-data` |
| Keycloak | `bash /root/kc-migration/rollback-keycloak-cutover.sh` (§5.5) — restores the selector, re-points the Service at the bundled pod, scales it up | users/orgs created after cutover exist only in `/root/kc-data` |
| Kafka | `helm rollback osac <rev-before-cutover>` + `--set kafka.enabled=true` in `osac-deps`/`osac-infra` (Strimzi re-installs from scratch) | events on the external broker are **not** migrated back |

General rule: the rollback point is a Helm revision — record
`helm status <release> -n <ns> | awk '/^REVISION:/{print $2}'` before any
cutover (the cutover scripts do this themselves).
