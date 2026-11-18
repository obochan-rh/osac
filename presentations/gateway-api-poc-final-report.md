# OSAC-7243 — Gateway API POC: Final Report

Cluster: `test-infra-cluster-dev` (OCP 4.22.14 SNO), host `10.6.78.169`,
`KUBECONFIG=/root/.kube/dev.kubeconfig`. Date: 2026-11-17. Path exercised:
**migration/cutover** of an existing Envoy-based OSAC to the CIO-managed Gateway
API (not greenfield). Evidence files on host: `/root/gw-poc/` (`phase2-evidence.txt`,
`integration-result.log`, `baseline/`, route/gateway YAML).

## 1. Executive summary

The migration is **feasible and was taken end-to-end**: CIO installed its embedded
Istio/Envoy from a GatewayClass (no Service Mesh Operator); an all-HTTPRoute +
BackendTLSPolicy config was accepted; live traffic (external Route + in-cluster
Services) was cut over to the gateway with the old Envoy **left running but orphaned**
(traffic diverted via the selectorless/EndpointSlice bridge — `replicas=1` but 0
gateway-log refs and no data Service selects it; see §7); REST, public gRPC,
TLS, ALPN, auth, public/private isolation, CORS (app-side) and WS-console routing
all work through the gateway.

**All functional bugs are now resolved.** Both migration bugs (D5 stream timeout,
ISSUE-2 console Connect misrouting) were root-caused to one behavioral difference and
**fixed in route config and validated**; only config/ops/productization items remain.

Root theme: OSAC's Envoy relied on **ordered first-match**; the Gateway API resolves
overlapping routes by **precedence** where only `Exact`/`Prefix` ordering is guaranteed
and **RegEx-vs-RegEx order is implementation-specific** (confirmed against the Gateway
API spec: criteria are Exact → longest Prefix → method → headers → query, then
first-rule-in-list-order, with a carve-out "the precedence of RegularExpression path
matches are implementation-specific"). That single difference (R-1) caused both the
Watch timeout (fixed via uniform `0s`) and the Connect misrouting (fixed via `Exact`
match — a defined-precedence type that deterministically beats the broad grpc regex).

## 2. Tests run — results + evidence

| # | Test | Result | Evidence |
|---|---|---|---|
| Gateway enablement | GatewayClass → CIO istiod, no SM Operator; Gateway Programmed; Envoy pod Ready; MetalLB `192.168.160.240:443` | PASS | Phase-1 conditions `Accepted/ControllerInstalled/CRDsReady`; `istiod-openshift-gateway` 1/1 |
| Config acceptance | HTTPRoutes + 3 BackendTLSPolicy `Accepted/ResolvedRefs`; listeners `attached=1` | PASS | Phase-2 conditions |
| REST (ext+int, auth) | 200 / 200 | PASS | `integration-result.log` |
| Auth negative | no/bad token → 401 | PASS | battery |
| Public gRPC (ext+int) | served | PASS | battery |
| Public/private isolation | private gRPC → Unimplemented ext, served int; private REST 404 ext | PASS | battery; access log |
| TLS negatives | untrusted CA + unknown SNI rejected | PASS | §4 phase2 |
| TLS version | 1.2 **and** 1.3 accepted downstream | NOTE (ISSUE-4) | `openssl s_client` |
| ALPN | `h2` (independent openssl) | PASS | battery |
| CORS | configured origin → ACAO; others denied; Envoy allow-all gone | PASS + ISSUE-3 | `-X OPTIONS` tests |
| WS console route | 426 Upgrade (routed to console-proxy) | PASS | battery |
| **gRPC console Connect** | **routed to console-proxy → FIXED** (`Exact` match); app returns `Unauthenticated: invalid ticket` (reached the real handler) not `Unimplemented` | RESOLVED (ISSUE-2) | before: access log `…grpc-server … osac-ext.5` + `Unimplemented`; after: `…fulfillment-console-proxy … osac-ext.4` + `Unauthenticated: invalid ticket` |
| **FULL e2e console** | onboarded tenant+catalog, booted a real Fedora VM, minted a real console ticket, opened `ConsoleProxy/Connect` with it → stream `CONNECTING`→`CONNECTED` through the gateway | **PASS** | `/root/gw-poc/issue2/e2e-console.sh`; Connect responses `CONSOLE_CONNECTION_STATE_CONNECTED "Connected"` |
| Cutover | Services→gateway, clean gateway-only, smoke 200, operator 1/1 | PASS | endpointslices; access log `via_upstream` |
| In-cluster SNI bridge | bare-name listeners accepted; `fulfillment-api`/`-internal-api` SNI → 200 | PASS | listener conditions |
| **D5 stream timeout** | quiet Watch cut at 300s → **FIXED** (gRPC `request:0s`), quiet Watch survived **400s** on stock image | RESOLVED (ISSUE-1) | access log `300001 … osac-ext.5`; soak `held 400s rc=124` |
| Envoy A/B | same Watch held 360s through old Envoy → gateway-only | PASS | A/B `held 360s rc=124` |
| System health | node Ready, all COs healthy, OpenBao 2/2, 0 restarts, `/var` 29%, logs/events clean | PASS | health sweep |

## 2a. Soak / endurance (overnight, read-only)

Continuous quiet Watch + per-5-min health/API/resource sampling, chained ~hourly.
Log: `/root/gw-poc/soak.log`.
- **Cycle 1 (21:14–22:10 UTC, 11 samples): all green.** REST ext/int = 200 every
  sample; a **continuous quiet Watch stayed open the full ~55 min** (no reset) →
  long-term stream stability confirmed with the route fix (beyond the 400s point
  test). No drift: `/var` steady 31%, restarts steady 3 (install-time, not growing),
  non-running steady 3 (stale `aap-bootstrap` history).
- **Cycles 2–3 (through 00:04 UTC): all green, 0 stream resets** (3× continuous ~55-min
  Watches held with no reset — long-term stream stability well beyond the 400s point test).
- **Recurring ~3 gw5xx explained (benign):** captured lines show **AAP (`ansible-httpget`)
  periodically GETs `/api/private/v1/{cluster_templates,baremetal_instance_templates,add_on_operators}`
  → 503** because CaaS/BMaaS are disabled in `vmaas-ci` (same as `clusters`→503). The gateway
  routes them correctly (`osac-int.2` → rest-gateway); it's app/profile behavior, **not a
  gateway/migration issue**. Evidence: `/root/gw-poc/soak-5xx.log`.
- **Cycles 4+ (through ~03:30 UTC, ~7.5h total): API/Watch all green, 0 stream resets.**
  REST ext/int = 200 every sample across the whole night; continuous quiet Watches held
  with no reset. `/var` crept 31% → 33% (~4GB over the night, overlay `du` inflated;
  real `/dev/sda4` 66G/200G — not a concern at this rate).
- **Operator restarts 3 → 8 overnight — ROOT-CAUSED, benign, NOT migration-related.**
  The `+5` is all `osac-operator` (`manager` container); `osac-ui`'s 3 are the known
  install-time race, unchanged. Crash cause (previous-container log, 03:20:55Z):
  `leaderelection … error retrieving resource lock … dial tcp 10.128.0.1:443: connect:
  connection refused` → `leader election lost` → `problem running manager`. The operator
  lost its lease because the **kube-apiserver was briefly unreachable** (single-node
  control-plane blip); controller-runtime correctly exits on lost leadership and the pod
  restarted cleanly (healthy since 03:21:52Z, reconciling the `system` Tenant). **Leader
  election talks directly to the kube-apiserver (`10.128.0.1`), NOT through the gateway**,
  and REST/Watch stayed green throughout → independent of the Envoy→Gateway cutover.
  Evidence: `oc logs deploy/osac-operator -n osac --previous`.
- (Longer monitor cycles continue overnight; end-of-night summary appended.)

## 3. Bugs / issues to address

### ISSUE-1 — D5: long-lived gRPC streams cut at 300s  [RESOLVED, config]
- **Symptom:** quiet `Events.Watch` reset at ~300s (`UR upstream_reset`, duration `300001`).
- **Root cause (R-1):** the Watch matched the broad gRPC rule (`osac-ext.5`,
  `request:300s`) not the specific Watch rule (`0s`). `_config.yaml.tpl` Watch route
  is `timeout:0s` (L147-154) declared before the unary `300s` route (L169-176) and
  depends on order ("must be matched before", L115); Envoy honors order, Gateway API
  leaves RegEx precedence implementation-specific.
- **Not idle:** a 60s keepalive fired but the stream still died at 300s → request-duration cap.
- **Fix (applied + validated):** set ALL gRPC HTTPRoute rules to `request:0s`
  (Watch/Connect/unary), keep REST `300s`. Quiet Watch then survived 400s on the
  **stock** image (no keepalive) → route fix alone, no code change. Envoy A/B held 360s.
- **Productize:** chart must render gRPC stream routes with non-order-dependent `0s`.

### ISSUE-2 — console gRPC `ConsoleProxy/Connect` misrouted to the wrong backend  [RESOLVED, config]
- **Symptom (was):** `ConsoleProxy/Connect` returned `Unimplemented` on the gateway.
- **Evidence (before):** access log `POST /osac.public.v1.ConsoleProxy/Connect …
  outbound|8000||`**`fulfillment-grpc-server`**`.osac.svc… … osac.osac-ext.5` — it hit the
  broad unary rule (→ grpc-server, rule 5) instead of rule 4 (→ `fulfillment-console-proxy`),
  and grpc-server does not implement ConsoleProxy.
- **Root cause (R-1):** same precedence problem as ISSUE-1, but here it changes the
  **backend**, so the uniform-timeout fix did NOT help. Both the Connect rule and the
  broad unary rule were `RegularExpression`; the Gateway API spec leaves RegEx-vs-RegEx
  order implementation-specific, and Istio ordered the broad `/(osac\.public\.|…).*`
  ahead of the specific `…ConsoleProxy/Connect`.
- **Fix (applied 2026-11-18 + validated):** change the Connect rule from
  `RegularExpression` to **`Exact: /osac.public.v1.ConsoleProxy/Connect`** (both
  `osac-ext` and `osac-int`, backend `fulfillment-console-proxy:8000`, `request:0s`
  unchanged). `Exact` is the #1 Gateway API precedence criterion, so it deterministically
  beats the broad grpc regex — no reliance on RegEx ordering. The redundant Watch RegEx
  rule can also be dropped (same backend+timeout as the fallback) but was left as-is.
- **Validation:** after the patch, Connect returns `Unauthenticated: invalid ticket`
  (console-proxy's own handler — proves it reached the right backend), access log shows
  `…fulfillment-console-proxy.osac.svc… osac.osac-ext.4`, and REST/Watch regression
  stayed green (200/200, quiet Watch held). Script + evidence: `/root/gw-poc/issue2/`
  (`fix-issue2.sh`, `connect-before.txt`, `aclog-after.txt`, `routes-before.yaml`).
- **Rejected alternatives:** GRPCRoute (method-level precedence) can't share a hostname
  with the REST HTTPRoute on v1.4.1 and has no `timeouts.request` → would reintroduce
  D5; RE2 has no negative lookahead; separate hostname/path is overkill. `Exact` is the
  minimal, spec-guaranteed fix.
- **Note:** validated END-TO-END 2026-11-18 — onboarded `tenant1` + catalog (fedora disk
  image, `u1-small` type), booted a real Fedora VM, minted a real console ticket, and
  opened `ConsoleProxy/Connect` with it through the gateway: the stream went
  `CONNECTING`→`CONNECTED` (console-proxy accepted the ticket and reached the VM serial
  console). grpcurl needs split auth here: `-reflect-header` = SA token (reflection),
  `-rpc-header` = the ticket (the Connect RPC). Script: `e2e-console.sh`.
- **Productize:** the chart's gatewayapi driver must render the Connect route as `Exact`,
  not a regex (same lesson as the D5 `0s` fix — specificity-driven, not order-driven).

### ISSUE-3 — CORS allowlist must be configured  [CONFIG]
- The gateway drops Envoy's allow-all (`.*`) CORS filter; CORS is now only the app's
  `--http-cors-allowed-origins` (chart `httpCorsAllowedOrigins`, defaults to the API's
  own host). Cross-origin callers (e.g. the UI) must be added or browser calls regress.
- Evidence: configured origin → full ACAO; UI/other origin → no ACAO.

### ISSUE-4 — downstream TLS 1.2 accepted  [HARDENING]
- Gateway accepts TLS 1.2 and 1.3 downstream (same as old Envoy). If TLS-1.3-min at the
  edge is required, add an explicit min-TLS policy.

### ISSUE-5 — gateway/istiod HPAs cannot read CPU metrics  [OPS]
- Events: `FailedGetResourceMetric` on `istiod`/`osac-gateway` HPAs → no autoscaling.
  Benign on the lab; verify in production.

### ISSUE-6 — cutover mechanics / EndpointSlice bridge lifecycle  [PRODUCTIZE]
- A selectorless-Service cutover must: (1) delete the controller-created EndpointSlices,
  and (2) delete the legacy `Endpoints` object (re-mirrored by
  `endpointslicemirroring-controller` → else ~50/50 split with Envoy). The manual
  bridge pins the gateway **pod IP**; it must be updated if that pod is replaced — needs
  a controller or chart-managed Service wiring for production.

## 4. Done since / still outstanding

**Done 2026-11-18 (via operator `!`):**
- **ISSUE-2 fix** applied + verified (Connect `Exact` match).
- **Full tenant onboarding + VM + e2e console** — `tenant1` + catalog (fedora image,
  `u1-small` type) + real Fedora VM (`STARTING`→`RUNNING` in ~75s) + real console ticket +
  `ConsoleProxy/Connect` → `CONNECTED` through the gateway. All scripts in
  `/root/gw-poc/issue2/`.

**Still outstanding (not gateway-blocking):**
- **Real Go `it` suite in-cluster** (targets `*.osac.svc.cluster.local:8443`, needs Go +
  an in-cluster runner + `*.svc` gateway listeners + 8443↔8000/8001 reconciliation —
  belongs on a Kind cluster in gateway mode, not this migrated cluster).
- Lab note: the single-node kube-apiserver periodically rolls a revision; during the
  ~90s window API calls get `connection refused` (caused the overnight operator restarts,
  a token `EOF`, and one transient ComputeInstance `FAILED`). Benign/transient — retry.
Staged helpers live in `/root/gw-poc/` where applicable.

## 5. Recommendations / next steps

1. **ISSUE-2 is fixed** (Connect via `Exact` match) and **validated end-to-end** (real VM
   console reached `CONNECTED` through the gateway). No functional gateway work remains.
2. Productize ISSUE-1 (stream `0s` timeouts), ISSUE-2 (Connect as `Exact`, not regex) and
   ISSUE-6 (bridge) in the chart; add the greenfield `ingress.driver=gatewayapi` toggle.
   Rule of thumb for the chart: any route whose backend is **not** the grpc-server
   fallback must use `Exact`/`Prefix` (defined precedence), never a regex that competes
   with the broad grpc rule.
3. Set `httpCorsAllowedOrigins` (ISSUE-3); decide min-TLS (ISSUE-4).
4. Run the real `it`/e2e suites on a **Kind** cluster in gateway mode for CI coverage.
5. Report R-1 (both forms) to OSAC-7243 / the reviewer as the core migration finding.

## 6. Where to verify

- Host evidence: `/root/gw-poc/phase2-evidence.txt`, `integration-result.log`,
  `integration-test.sh`, `baseline/`, `gateway.yaml`, `httproutes-*.yaml`.
- Gateway access log: `oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=osac-gateway`.
- Companion notes: `gateway-api-cutover-steps.md`, `gateway-api-greenfield-install.md`,
  `gateway-api-migration-plan-draft.md`, `gateway-api-cutover-procedure.md`.

## 7. As-deployed state — reverse-engineered & verified 2026-11-18

Live cluster state captured and validated against §§1–6 and the companion notes. Full
match except the two items flagged below. This is the authoritative snapshot for moving
to implementation.

| Object | As-deployed |
|---|---|
| GatewayClass | `openshift-default`, ctrl `openshift.io/gateway-controller/v1`; Accepted/ControllerInstalled/CRDsReady=True; **no** Service Mesh Operator sub |
| Control plane | `istiod-openshift-gateway` + `osac-gateway-openshift-default` Running in `openshift-ingress`; Gateway API CRD bundle **v1.4.1** |
| Gateway | `openshift-ingress/osac-gateway`, class `openshift-default`, Programmed=True, addr `192.168.160.240` (MetalLB LB svc `osac-gateway-openshift-default`) |
| Listeners (4) | `external`→`fulfillment-api-osac.apps…`, `internal`→`fulfillment-internal-api-osac.apps…`, `ext-svc`→`fulfillment-api`, `int-svc`→`fulfillment-internal-api`; all 443/Terminate, cert `fulfillment-api-tls`, allowedRoutes Selector `kubernetes.io/metadata.name=osac`, each `attached=1` |
| Frontend cert | `fulfillment-api-tls` present in **both** `osac` and `openshift-ingress` |
| BackendTLSPolicy (3) | `btls-grpc-server`/`btls-rest-gateway`/`btls-console-proxy` → matching Services; CA ConfigMap `osac-backend-ca` (key **`ca.crt`**); hostname `fulfillment-<svc>.osac.svc.cluster.local`; Accepted/ResolvedRefs=True |
| HTTPRoute `osac-ext` (6 rules) | [0] Exact `/api/fulfillment/v1/console_sessions/connect`→console-proxy:8090 `0s`; [1] Exact `/.well-known/jwks.json`→rest-gateway:8000 `10s`; [2] PathPrefix `/api/fulfillment`+`/api/events`→rest-gateway:8000 `300s`; [3] RegEx `/osac\.public\..*/Watch`→grpc-server:8000 `0s`; [4] **Exact** `/osac.public.v1.ConsoleProxy/Connect`→console-proxy:8000 `0s`; [5] RegEx `/(osac\.public\.\|grpc\.(reflection\|health)\.).*`→grpc-server:8000 `0s`. Accepted/ResolvedRefs=True |
| HTTPRoute `osac-int` (6 rules) | [0]/[1] same; [2] PathPrefix `/api`→rest-gateway `300s`; [3] RegEx `^.*/Watch$`→grpc-server `0s`; [4] **Exact** Connect→console-proxy:8000 `0s`; [5] PathPrefix `/`→grpc-server `0s`. Accepted/ResolvedRefs=True |
| Services | `fulfillment-api` (selectorless, `external-api:8000`) + `fulfillment-internal-api` (selectorless, `internal-api:8001`) |
| EndpointSlice bridge | `fulfillment-api-gw-poc` + `fulfillment-internal-api-gw-poc` → gateway pod IP `172.30.26.235:443` |
| Legacy Endpoints | deleted (not re-mirrored) |
| External Routes | `fulfillment-api`/`fulfillment-internal-api` Routes → the selectorless Services → gateway |

**Two deltas vs. the greenfield/cutover notes (documented, not faults):**
1. **Old Envoy `fulfillment-ingress-proxy` is still running (`replicas=1`), orphaned** — no
   data Service selects it (only `fulfillment-ingress-proxy-metrics` does, for Prometheus),
   0 refs in the gateway access log. The migration **diverted traffic** via the selectorless
   bridge rather than scaling Envoy to `0`. Productization decision: scale to `0`
   (migration) or don't deploy it (`ingress.driver=gatewayapi`, greenfield).
2. **Route config retains the Watch RegEx rule** (`[3]`). It's redundant now (same backend +
   `0s` as the catch-all) and safe to drop as a chart simplification; the deployed POC keeps
   it. No functional effect.
