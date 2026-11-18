# OSAC-7243: Gateway API cutover — step-by-step note (rev 2)

Runbook for swapping OSAC's standalone Envoy for the OpenShift CIO-managed
Gateway API, on `test-infra-cluster-dev` (OCP 4.22.14). Companion to
`gateway-api-migration-plan-draft.md` (rev 3) and
`gateway-api-cutover-procedure.md` (YAML).

Rev 2 of this note folds in the document review (2026-11-17): all-HTTPRoute
baseline (GRPCRoute ruled out), EndpointSlice + TLS-identity bridge for the
cutover, explicit trust/namespace prereqs, endpoint-aware rollback, and gate
wording. **Gate 2 and Gate 3 are HELD until the items marked [R] are resolved.**
Cluster facts below were verified read-only on test-infra-dev 2026-11-17.

## POC RESULTS (2026-11-17, test-infra-cluster-dev, OCP 4.22.14)

Executed on a real CIO-managed 4.22 cluster with the old Envoy serving untouched.

- **Phase 0 DONE (Gate 0):** restore contract + Helm rev 1 pinned; served schema captured
  (Gateway API v1; `RegularExpression` supported); GatewayClass absent; baseline smoke green;
  D5 anchor established (quiet `Events.Watch` held indefinitely on Envoy).
- **Phase 1 DONE (Gate 1):** `GatewayClass openshift-default` (controllerName
  `openshift.io/gateway-controller/v1`) → CIO installed `istiod-openshift-gateway` in
  `openshift-ingress`, **no Service Mesh Operator**. `Gateway osac-gateway` Programmed; Envoy
  gateway pod 1/1; MetalLB LB `192.168.160.240:443`. Zero traffic change.
- **Phase 2 DONE except D5 (Gate 2 held on D5):** dedicated `ca.crt` CM + 3 BackendTLSPolicies +
  all-HTTPRoute (ext/int, RegEx) all `Accepted`/`ResolvedRefs=True`. Parallel validation vs the
  gateway (Envoy still serving): REST both listeners 200, jwks 200, **ALPN h2**, gRPC reflection +
  public unary, **public/private isolation** (private→Unimplemented/404 on ext, allowed on int),
  upstream TLS1.3+SAN — all PASS.
- **D5 verdict (the make-or-break):** `timeouts.request:0s` cleared the 15s request-timeout trap
  (120s survived), but the gateway cut a quiet stream at **~301s** (Istio default
  `stream_idle_timeout` 5min; idle has NO Gateway API field). **Console is fine** (30s WS ping
  < 300s). **Watch is the real regression** (`events_server.go` has no stream heartbeat → quiet
  Watch dies at 300s). **Recommended supported fix: add a <300s heartbeat Send to `Events.Watch`**
  (mirrors console's 30s ping) — small `fulfillment-service` change, **no EnvoyFilter**, clears
  supportability/FIPS. **Migration FEASIBLE.**
- **Phase 3 cutover DONE (bounded experiment):** R-2 bridge validated — Istio/CIO ACCEPTS
  bare-label SNI listeners (`ext-svc`=`fulfillment-api`, `int-svc`=`fulfillment-internal-api`),
  both programmed + attached; in-cluster SNI test `fulfillment-api`/`fulfillment-internal-api`→200.
  Cutover = Services made selectorless + EndpointSlice → gateway pod `:443`. Live OSAC traffic
  (external Route + in-cluster Services) now flows through the CIO gateway; old Envoy out of path
  (still running, restorable via `baseline/services.yaml`). 5x smoke 200, operator 1/1.
  **TWO CUTOVER FINDINGS (runbook):** (1) removing a Service selector does NOT delete the
  controller-created EndpointSlices; (2) the legacy `Endpoints` object is re-mirrored into fresh
  slices by `endpointslicemirroring-controller.k8s.io`, so the cutover must delete the
  `Endpoints` object too (not just the slices) — else traffic splits ~50/50 Envoy/gateway.
- **Validation battery (2026-11-17, post-cutover, all via the gateway):** REST auth
  +/- on both listeners (200/200, 401/401); gRPC public unary both listeners; TLS
  negatives (untrusted CA + unknown SNI rejected); console-ws route → 426; ALPN h2;
  public/private isolation (private → Unimplemented/404 ext, served int). **CORS:**
  app-side allowlist works through the gateway — configured origin → full
  ACAO/credentials/headers, others denied. Envoy's allow-all (`.*`) filter is gone
  (intended hardening) → `httpCorsAllowedOrigins` must list any cross-origin caller
  (e.g. the UI) or it regresses. **Logs/events clean:** 0 restarts; gateway access
  log shows `200 … via_upstream … fulfillment-rest-gateway`; only benign startup
  warnings (istiod boot 503; HPA can't read CPU metrics → no autoscale; MetalLB
  dual-stack cosmetic). Access logging IS on by default. Downstream accepts TLS 1.2
  (same as old Envoy; add min-TLS policy to harden).
- **D5 heartbeat IMPLEMENTED + DEPLOYED (2026-11-17):** `fulfillment-service`
  `events_server.go` `run()` now emits an empty `EventsWatchResponse` every 60s (a
  `keepalive` ticker alongside the existing refresh ticker). CLI clients already
  `continue` on a nil-event response, so it is contract-safe. Built in-container via
  the UBI Containerfile (`podman build -f fulfillment-service/Containerfile .` from
  the monorepo root — no host Go needed), loaded onto the SNO node
  (`podman save | ssh core@node sudo podman load`; crio shares
  `/var/lib/containers/storage`), and `fulfillment-grpc-server` patched to
  `localhost/fulfillment-service:gw-hb` with `imagePullPolicy: Never` (dev build;
  production comes via CI). New pod serves (REST 200, gRPC OK) and the keepalive
  fires — a 70s Watch received 1 `{}` message at ~60s.
- **D5 FINAL ROOT CAUSE — CORRECTED 2026-11-17: it is a REQUEST-timeout ROUTING
  issue (R-1), NOT idle, and GATEWAY-ONLY (not a bug — a behavioral difference).**
  The quiet Watch is cut at exactly 300s because it matches the broad gRPC rule
  (`osac-ext.5`, `request:300s`), not the specific Watch rule (`0s`). Access-log
  proof: `POST /osac.public.v1.Events/Watch … 300001 … UR upstream_reset … osac.osac-ext.5`.
  Code proof: `_config.yaml.tpl` sets the Watch route `timeout:0s` (L147-154) and
  the unary route `timeout:300s` (L169-176), and depends on ORDER ("this route must
  be matched before … catches all" L115) — Envoy = ordered first-match, so Watch
  (0s) wins. Gateway API leaves RegEx precedence **implementation-specific**
  (`oc explain …path.type`), so order is NOT honored → Watch falls through to 300s.
  The earlier "idle timeout / heartbeat" framing was WRONG: the keepalive fired
  (stream active) yet the stream still died at 300s → it's a request-duration cap.
  **The heartbeat is redundant → revert it.** Envoy A/B (Watch straight through the
  idle old Envoy pod) confirms Envoy holds >300s = gateway-only.
- **FIX (applied to route files; apply + re-validate pending):** set ALL gRPC rules
  to `request: 0s` (Watch, Connect, and the broad unary), keep REST `300s`. Whichever
  rule precedence picks, gRPC gets no request timeout; unary relies on client
  deadlines (same as any gRPC). This removes the dependence on RegEx order entirely.
  **Framing for the writeup:** "Gateway API requirement — stream routes need a
  non-order-dependent timeout; Envoy's implicit ordering guarantee does not exist."
- **D5 CLOSED 2026-11-17 (route fix alone, config-only).** With all gRPC rules at
  `request:0s` and the STOCK grpc-server (heartbeat reverted), a truly quiet Watch
  (0 messages, no keepalive) survived **400s** through the gateway (`rc=124`,
  wrapper-killed). Proves: the route fix is the complete fix; there is NO idle
  timeout; **no `fulfillment-service` code change needed** (heartbeat was a detour,
  reverted). Envoy A/B held 360s = gateway-only. Net D5 fix = one ingress-config
  change (gRPC `request:0s`, REST stays 300s).
- **ISSUE-2 CLOSED 2026-11-18 (console Connect misrouting — the deeper form of R-1).**
  The `request:0s` fix solves the stream *timeout* because Watch and the unary share the
  SAME backend (grpc-server). Connect does NOT: its backend is **console-proxy**, so when
  Istio's RegEx ordering put the broad unary rule (→grpc-server) ahead of the specific
  Connect regex, Connect hit grpc-server → `Unimplemented: unknown service
  osac.public.v1.ConsoleProxy`. Timeout uniformity can't help a wrong *backend*.
  **Fix: change the Connect rule from RegularExpression to `Exact:
  /osac.public.v1.ConsoleProxy/Connect`** (both ext+int). `Exact` is the #1 Gateway API
  precedence criterion → deterministically beats the broad grpc regex, no RegEx-order
  dependence. (GRPCRoute rejected: can't share hostname with the REST HTTPRoute on v1.4.1
  + no `timeouts.request`.) **Validated:** Connect now returns `Unauthenticated: invalid
  ticket` (console-proxy's own handler — right backend reached, not Unimplemented); access
  log `fulfillment-console-proxy + osac-ext.4/osac-int.4`; unary List still →grpc-server/.5;
  REST 200/200, jwks 200, Watch held 25s. Scripts+evidence `/root/gw-poc/issue2/`.
  **General rule for the chart:** any route whose backend != the grpc-server fallback MUST
  use `Exact`/`Prefix` (defined precedence), never a regex that competes with the broad
  grpc rule. The redundant Watch RegEx rule may be dropped (same backend+`0s` as fallback).
- **FULL e2e console PASS 2026-11-18:** onboarded `tenant1`+catalog, booted a real Fedora
  VM, minted a real console ticket, and ran `ConsoleProxy/Connect` through the gateway →
  stream `CONNECTING`→`CONNECTED` (console-proxy accepted the ticket + reached the VM
  serial console). Confirms the ISSUE-2 `Exact` fix works for the real console feature,
  not just the handshake. Script `/root/gw-poc/issue2/e2e-console.sh`.
- **Still to do:** `it_ingress_separation` + `SUITE=fulfillment` vs the gateway;
  real >5-min console session (needs a VM); optional Envoy→0, CORS allowlist,
  min-TLS; productize the stream route-timeout in the chart. Evidence:
  `/root/gw-poc/phase2-evidence.txt`.

## Architecture in one line

Today: Route (passthrough) -> Service -> **OSAC's own Envoy** (`fulfillment-ingress-proxy`) -> backends.
After: Route/Service -> **CIO-managed Istio *Envoy* gateway pods in `openshift-ingress`** (created from the Gateway object, programmed from our HTTPRoutes + BackendTLSPolicy) -> backends.
OSAC stops running/configuring Envoy; the platform does. CORS stays in the app;
idle timeouts have no Gateway API field (the D5 open risk).

## Access / constants (verified 2026-11-17)

- Host: `ssh root@10.6.78.169` ; `export KUBECONFIG=/root/.kube/dev.kubeconfig`
- App ns: `osac` ; gateway ns: `openshift-ingress`
- Services: `fulfillment-api` (8000, port name `external-api`), `fulfillment-internal-api` (8001, `internal-api`); both select `app: fulfillment-ingress-proxy`; Routes passthrough.
- Frontend cert Secret: `fulfillment-api-tls` in ns `osac`. SANs cover both external hosts AND the aliases `fulfillment-api` / `fulfillment-internal-api` (+ .osac/.svc) — so the SNI bridge has cert coverage (necessary, not sufficient).
- Backend CA: existing ConfigMap `ca-bundle` key = **`bundle.pem`** (NOT `ca.crt`) -> BackendTLSPolicy needs a dedicated `ca.crt` ConfigMap. [R-3]
- Backends: `fulfillment-rest-gateway:8000` (h2), `fulfillment-grpc-server:8000` (h2), `fulfillment-console-proxy:8000` (h2) and `:8090` (ws/h1)
- Hosts: `fulfillment-api-osac` / `fulfillment-internal-api-osac` `.apps.test-infra-cluster-dev.redhat.com`
- GatewayClass `openshift-default`: absent on this cluster -> we CREATE it here (ledgered). Reuse-if-present applies elsewhere.
- HTTPRoute path match types available: `Exact`, `PathPrefix`; `RegularExpression` support unconfirmed [R-1].

---

## PHASE 0 — Baseline (read-only, no cluster changes)

1. `mkdir -p /root/gw-poc/baseline && cd /root/gw-poc`
2. Capture the restore contract (full specs):
   - `oc -n osac get svc fulfillment-api fulfillment-internal-api -o yaml > baseline/services.yaml`
   - `oc -n osac get route fulfillment-api fulfillment-internal-api -o yaml > baseline/routes.yaml`
   - `oc -n osac get deploy fulfillment-ingress-proxy -o yaml > baseline/ingress-proxy.yaml`
   - `oc -n osac get cm fulfillment-ingress-proxy ca-bundle -o yaml > baseline/configmaps.yaml`
   - `oc -n osac get secret fulfillment-api-tls -o yaml > baseline/cert-secret.yaml` (protect — TLS private key)
   - `oc -n osac get endpointslice -l kubernetes.io/service-name in (fulfillment-api,fulfillment-internal-api) -o yaml > baseline/endpointslices.yaml`
3. Pin Helm revision: `helm history osac -n osac --max 1 > baseline/helm-revision.txt` (record the NUMBER).
4. Record served schema + existing objects, to resolve [R-1] and the GatewayClass-reuse question:
   - `oc api-resources --api-group=gateway.networking.k8s.io > baseline/gwapi.txt`
   - `oc explain httproute.spec.rules.matches.path.type > baseline/pathtypes.txt` (confirm RegularExpression)
   - `oc get gatewayclass,gateway -A > baseline/existing-gw.txt`
   - `oc get subscription,csv -A > baseline/operator-inventory.txt` (baseline to diff against, not "must be empty")
5. Smoke baseline (Envoy up, read-only): JWT login, `osac get projects`, console fetch, 60s Watch. Save as comparison set.
6. Start two ledgers: `poc-created.txt` (new objects) and `poc-modified.txt` (pre-existing objects we edit). Cleanup/rollback treat them differently.

**GATE 0:** smoke green; ledgers started; Helm revision number recorded; schema + path-match support recorded; GatewayClass presence known.

---

## PHASE 1 — Enable the CIO Gateway API (no traffic impact)

7. GatewayClass `openshift-default`, `controllerName: openshift.io/gateway-controller/v1` (exact). On THIS cluster it is absent -> create and append to `poc-created.txt`. (Where it pre-exists: verify ownership/generation and REUSE it; do not ledger it for deletion.)
8. `oc wait gatewayclass/openshift-default --for=condition=Accepted --timeout=300s`; then check `ControllerInstalled` and `CRDsReady` on the CURRENT generation, with their reason/ownership.
9. Operator inventory check: diff `oc get subscription,csv -A` against `baseline/operator-inventory.txt`. Expect NO new `servicemeshoperator3` Subscription; do not require any pre-existing operator to disappear.
10. Verify istiod/gateway controller healthy in `openshift-ingress`.
11. Frontend cert prereq [R-3]: a Gateway in `openshift-ingress` needs a valid cert reference THERE. `fulfillment-api-tls` lives in `osac`; either publish/copy an equivalent Secret into `openshift-ingress`, or set up a supported cross-namespace reference. Name reuse alone is insufficient. Record the method in `poc-created.txt`.
12. Create the Gateway in `openshift-ingress`: two HTTPS listeners (by hostname), `tls.mode: Terminate`, `certificateRefs` -> the cert from step 11, and **`allowedRoutes` restricted to the `osac` namespace via Selector** (namespace label), NOT `from: All` [R-3]. Append to `poc-created.txt`.
13. Wait `Programmed=True`; confirm the **Envoy gateway pods** appear in `openshift-ingress`.
14. Routes still -> Envoy: re-run step-5 smoke; expect zero change.
15. Measure capacity (`oc adm top node`, `oc describe node`) with Envoy + gateway both up.

**GATE 1:** GatewayClass conditions green on current generation; operator inventory diff clean (no new SM Operator); Envoy gateway pods healthy in `openshift-ingress`; cert reference in `openshift-ingress` valid; route attachment restricted to `osac`; zero traffic change; capacity recorded; cutover design written (Phase 3).

---

## PHASE 2 — Build Gateway API config (parallel, no cutover)  [held until R-1, R-3]

16. **Dedicated backend CA ConfigMap** [R-3]: create a rotation-safe ConfigMap keyed `ca.crt` with the backend-signing CA PEM (do NOT reuse `ca-bundle`/`bundle.pem`). Append to `poc-created.txt`.
17. **BackendTLSPolicy** per backend (`fulfillment-rest-gateway`, `fulfillment-grpc-server`, `fulfillment-console-proxy`): `caCertificateRefs` -> the step-16 ConfigMap; `validation.hostname` -> backend cert SAN; per-port targeting for console-proxy (8000 vs 8090).
18. **ALL-HTTPRoute baseline** [R-1] — GRPCRoute is ruled OUT on this surface because: (a) HTTPRoute+GRPCRoute with overlapping hostnames on the same listener are NOT merged (only one kind is accepted), and (b) GRPCRouteRule has no `timeouts.request`. So reproduce every class as HTTPRoute rules on the existing hostnames, using `spec.rules[].timeouts`:
    - EXTERNAL host (public, restricted): console-ws (Exact `/api/fulfillment/v1/console_sessions/connect` -> console-proxy:8090, `request:0s`); jwks (Exact `/.well-known/jwks.json` -> rest-gateway:8000, `request:10s`); REST (PathPrefix `/api/fulfillment` + `/api/events` -> rest-gateway:8000, `request:300s`); Watch/Connect/unary gRPC classes -> grpc-server:8000 / console-proxy:8000 with their `request` timeouts.
    - INTERNAL host (private, broad): console-ws/jwks same; REST PathPrefix `/api`; gRPC catch-all.
    - The gRPC stream-vs-unary timeout split (Watch/Connect `request:0s` vs unary `300s`) needs method-suffix matching, which requires `RegularExpression` path matches (implementation-specific; confirm via Phase-0 `pathtypes.txt`) OR a hostname/listener redesign that separates streams from unary. Decide at this step; do not assume Envoy's first-match order — Gateway API precedence is by specificity + creation time.
    - CORS stays app-side; do NOT add gateway CORS or unsupported CRDs.
19. Validate IN PARALLEL against the gateway while Envoy still serves (no Routes/Services touched): route `Accepted`/`ResolvedRefs` + ready endpoints; path routing; TLS negatives (wrong CA, wrong hostname, TLS 1.2 reject); **public/private isolation** (private REST+gRPC DENIED on external host with a VALID privileged token, ALLOWED on internal); a Watch held open; **independent HTTP/2 + ALPN verification** [R-G2] (e.g. `openssl s_client -alpn h2`) — the OSAC gRPC client disables ALPN enforcement, so CLI success alone does NOT prove ALPN.

**GATE 2 [HELD]:** release only when R-1 (route-API/path-match design confirmed against served schema) and R-3 (dedicated CA, cross-ns cert, restricted attachment) are done AND all parallel probes pass incl. isolation denial and independent ALPN.

---

## PHASE 3 — Cutover (only traffic-affecting step)  [design = R-2, held]

Cutover design is option B as a POC-ONLY bridge [R-2], not yet a complete design:
20. Keep Service names; drop selector; create a **dedicated POC EndpointSlice** (not legacy Endpoints, not `oc ... apply` of raw Endpoints) for each Service:
    - Destination = gateway **Pod IPs** (an EndpointSlice address may NOT be another Service's ClusterIP). Define WHO updates these when gateway Pods are replaced/unready (no controller does it for selectorless Services) — this is the open lifecycle gap.
    - Ports: record the ACTUAL NUMERIC gateway destination port per Service port; map `external-api`(8000)/`internal-api`(8001) -> those numbers. Names are not the full mapping.
    - Distinct POC slice names + management labels; record in `poc-created.txt`; record the Service edits in `poc-modified.txt`.
21. **TLS-identity bridge** [R-2] — prove the whole chain, not just DNS+ports:
    `caller address -> SNI/authority -> Service port -> EndpointSlice IP:port -> Gateway listener -> route`.
    Callers without a host override use the address hostname as SNI/authority. Gate 2 must prove that `fulfillment-api:8000` reaches the PUBLIC listener and `fulfillment-internal-api:8001` the INTERNAL one. Test this bridge in parallel BEFORE editing the live Services; direct-to-gateway probes do not exercise it.
22. Apply the bridge; smoke the Gate-0 set + real WebSocket + CLI console.
23. Prove Envoy is out of the serving path, then sleep it: `oc -n osac scale deploy/fulfillment-ingress-proxy --replicas=0`.
24. **Rollback drill (once, before relying on it):** execute L1 end-to-end incl. endpoint-bridge teardown, confirm recovery, then return to gateway mode.
25. Test gateway **Pod replacement** (delete a gateway pod) — not only backend restart — and confirm the bridge recovers or the abort action fires.

**GATE 3 [HELD]:** smoke green admits a BOUNDED, EXPERIMENTAL campaign with rollback available — it is NOT production migration approval while D5 or the endpoint-bridge lifecycle is unresolved.

---

## PHASE 4 — Campaign + D5 evidence

26. Functional (writes OK, disposable tenant, own cleanup): auth; login/project/membership; VM provision + console + Watch e2e; gRPC + REST surfaces.
27. **D5 idle/stream** (make-or-break): quiet fixtures; attribute expiry to a hop; for console distinguish the 1800s idle timer from the app's ABSOLUTE deadline. Fill the evidence matrix (Envoy baseline vs gateway) per class.
28. If idle fires: app-level keepalive is a **workaround / contract change**, NOT proof that quiet-stream idle parity was preserved; a supported platform knob is preferred; EnvoyFilter only as a lab-only, support-flagged patch (test whether it even takes effect on the CIO-managed istiod).
29. Operational: gateway metrics/logging parity; backend-pod-restart behavior.

---

## PHASE 5 — Report + decision

30. Fill the matrix; rank gaps (idle-timeout first); recommend; record rollback-or-stay. Note cluster drift (ledgers + envoy replicas=0); Level 2 removes it.

---

## ROLLBACK (from Phase 0 captured values; track created vs modified separately)

- **L1 (<5 min):**
  1. `oc -n osac scale deploy/fulfillment-ingress-proxy --replicas=<captured>` ; `oc rollout status ... --timeout=120s`.
  2. Undo the endpoint bridge [R-4]: delete the POC EndpointSlice(s) AND revert the Service edits from `poc-modified.txt` (`oc apply -f baseline/services.yaml`) in rehearsed order; WAIT for normal controller-managed EndpointSlice discovery to recover.
  3. Verify ONLY Envoy's intended targets remain: `oc -n osac get endpointslice` for both Services shows the Envoy pod IPs and no stale gateway addresses; then run the 4 smoke probes + real API calls.
  Leave the Gateway idle for a retry.
- **L2 (drift cleanup):** scale Envoy back; reassert chart state with a PINNED release/chart/values + hook policy (not a bare `--reuse-values`) OR keep Helm out of immediate rollback entirely; then delete ONLY `poc-created.txt` objects (ns + ownership checked one by one); revert `poc-modified.txt`.
- **L3 (worst case):** `oc apply -f baseline/{routes,services,ingress-proxy}.yaml` (+ `endpointslices.yaml`). Cert key recovery = reissue via cert-manager or restore protected `cert-secret.yaml` (a ConfigMap CA cannot recover the private key). Ultimate: `helm rollback osac <PINNED_REVISION> -n osac` (revision is POSITIONAL, not `--revision`).

## Rules that keep rollback working

1. POC never deletes chart-managed objects. 2. No Helm ops during the POC.
3. Every manual change reverts by re-applying the Phase 0 capture; created vs
modified objects tracked in separate ledgers. 4. On rollback, Envoy is ready AND
the endpoint bridge is torn down and re-discovered BEFORE declaring success.
5. Rollback (incl. endpoint teardown) rehearsed in Phase 3.

## Open review items [R] — gating

- [R-1] Route API: all-HTTPRoute confirmed; path-match design (RegularExpression vs hostname split) confirmed against Phase-0 served schema. (Gate 2)
- [R-2] Option B completed as an EndpointSlice design with destination/port/lifecycle + TLS-identity bridge, labeled POC-only. (Gate 2/3)
- [R-3] Dedicated `ca.crt` CA ConfigMap; cross-ns frontend cert in `openshift-ingress`; route attachment restricted to `osac`. (Gate 2)
- [R-4] L1 tears down and re-discovers the endpoint bridge; created/modified ledgers separate. (rollback)
- [R-G2] Independent HTTP/2/ALPN verification (client disables ALPN enforcement). (Gate 2)

## System health check (reusable, read-only)

Run after any change (cutover, image deploy, rollback) before proceeding. Access:
`ssh root@10.6.78.169`; `export KUBECONFIG=/root/.kube/dev.kubeconfig`. Node shell:
`ssh -i /home/cluster-tool/flavors/sno-4-22/crypto/cluster-tool.key core@192.168.160.10`.
Each check prints only problems — empty output means healthy.

```bash
export KUBECONFIG=/root/.kube/dev.kubeconfig
# 1. node + cluster operators (expect Ready; no CO printed)
oc get nodes
oc get co --no-headers | awk '$3!="True"||$4!="False"||$5!="False"{print $1,$3,$4,$5}'
# 2. OSAC pods: non-running + restart counts
oc get pods -n osac --no-headers | grep -vE "Running|Completed"
oc get pods -n osac --no-headers | awk '$4+0>0{print $1" restarts="$4}'
# 3. infra core (openbao/postgres/kafka) + keycloak
oc get pods -n osac-infra | grep -iE "openbao|postgres|kafka"
oc get pods -n keycloak
# 4. gateway listeners (attachedRoutes) + data-plane pods
oc get gateway osac-gateway -n openshift-ingress \
  -o jsonpath='{range .status.listeners[*]}{.name}=a{.attachedRoutes} {end}{"\n"}'
oc get pods -n openshift-ingress | grep -E "osac-gateway|istiod"
# 5. cutover intact: Services -> gateway pod IP
oc get endpointslice -n osac -l 'kubernetes.io/service-name in (fulfillment-api,fulfillment-internal-api)' \
  -o jsonpath='{range .items[*]}{.metadata.name}:{.endpoints[*].addresses}{"\n"}{end}'
# 6. deployments Available (expect all 1/1)
oc get deploy -n osac | grep -E 'fulfillment|osac-'
# 7. node /var disk
ssh -i /home/cluster-tool/flavors/sno-4-22/crypto/cluster-tool.key -o StrictHostKeyChecking=no \
  core@192.168.160.10 'df -h /var | tail -1'
# 8. recent warnings/errors
oc get events -n osac --sort-by=.lastTimestamp | grep -iE 'warning|error|backoff|unhealthy'
```

Functional smoke through the gateway (read-only):
```bash
EXT=fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com ; GWIP=192.168.160.240
TOK=$(oc create token admin -n osac --duration=15m)
curl -sk -H "authorization: Bearer $TOK" https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w 'REST %{http_code}\n'      # 200
curl -sk https://$EXT/.well-known/jwks.json -o /dev/null -w 'jwks %{http_code}\n'                                                     # 200
curl -sk -H 'authorization: Bearer bad' https://$EXT/api/fulfillment/v1/compute_instances -o /dev/null -w 'bad-token %{http_code}\n'  # 401
grpcurl -insecure -authority $EXT -H "authorization: Bearer $TOK" -d '{}' $GWIP:443 osac.public.v1.ComputeInstances/List              # {}
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=osac-gateway --tail=5   # 200 ... via_upstream ... rest-gateway
```

Healthy baseline (verified 2026-11-17): node Ready; 0 unhealthy COs; all osac /
osac-infra pods Running; OpenBao 2/2; gateway 4 listeners `a1`; Services → gateway
`172.30.26.235`; all deploys `1/1`; `/var` 29%; REST 200 / bad-token 401; gateway
access log shows `200 … via_upstream … fulfillment-rest-gateway`. Known-cosmetic:
stale `osac-aap-bootstrap-*` Error pods (install-time job history); the old
grpc-server pod's terminating readiness blip during a rollout.

## Review status

Rev-3 migration plan is the latest OSAC-7243 comment (Ofer, 12 Nov), out to
Michael Hrivnak; no reviewer reply yet; framed as a pre-spike gate. Phase 0 is
read-only (safe anytime); Phase 1+ is the spike. Gate 2/Gate 3 held per the
[R] items above.
