# OSAC-7243: Edge-04 Gateway API cutover POC (plan, rev 2)

Status: internal draft, not filed. Companion to
`gateway-api-migration-plan-draft.md` (rev 3).
Date: 2026-11-16. Owner: Ofer Bochan.
Rev 2: incorporates external review (2026-11-16). Changes from rev 1:
CIO-managed install path instead of OLM/Sail; cutover design treated as
open (namespace/named-port/in-cluster-caller problem); Envoy kept up
through the switch; cleanup separated into baseline inventory vs
POC-created manifest; restore uses captured values, not hardcoded ones;
cert recovery and Helm revision pinning made explicit; VM create moved
out of the read-only phase; capacity measured, not assumed.

## Goal

Run the OSAC ingress path on the CIO-managed Gateway API implementation
on the edge-04 hub **instead of** the `fulfillment-ingress-proxy` Envoy
deployment. Envoy is **shut down, not removed** — and only after the
gateway has independently served the full test campaign. Roll back to
Envoy in minutes, from rehearsed restore actions.

## Non-goals

- No deletion of any chart-managed object (Envoy deployment, configmap,
  cert secret, Routes).
- No Helm operations on the OSAC release during the POC — the release
  history stays clean as the ultimate safety net.
- No mesh: ingress gateway only, no sidecar or ambient injection on any
  existing OSAC pod.
- No changes to backends (grpc-server, rest-gateway, console-proxy).
- Do not install unsupported CRDs (e.g. for gateway-side CORS). CORS
  stays application-side per the migration plan rev 3.

## Current topology (what the POC replaces)

```text
OpenShift Routes (termination: passthrough — verified in chart route.yaml)
  └─ Service fulfillment-api (8000) ─────────┐
  └─ Service fulfillment-internal-api (8001)─┤
                                             ▼
                 Deployment fulfillment-ingress-proxy (Envoy)
                   ├─ public listener    :8000 (TLS, CORS)
                   ├─ internal listener  :8001 (TLS)
                   └─ upstream TLS 1.3 → grpc-server / rest-gateway /
                                          console-proxy / event-publisher
```

Chart facts (verified against
`fulfillment-service/charts/service/templates/ingress-proxy/service.yaml`
and `route.yaml` at the current checkout):

- **Both** API Services select `app: fulfillment-ingress-proxy`.
- Service ports use **named targetPorts** `external-api` (8000) and
  `internal-api` (8001); the Routes also target those names. Any
  replacement endpoint must preserve the name→port mapping or the
  Services/Routes must be edited to match.
- Route termination is **passthrough**: TLS is terminated at the proxy
  (Envoy today, the Gateway in the POC) with the existing cert secret,
  and upstream is HTTPS to the backends — i.e. the POC path is
  *passthrough Route → TLS-terminating Gateway → TLS upstream*, not
  edge or reencrypt. Any future topology change must state which of the
  three it is, because edge forwards HTTP to the backend and changes
  the upstream-TLS evidence entirely.

In-cluster callers also target the two Services directly (not only via
Routes) — the cutover design must move those callers too, or leave the
Services serving.

Envoy's route table (verified against
`fulfillment-service/charts/service/templates/ingress-proxy/_config.yaml.tpl:105-299`),
six ordered route classes per listener:

| Route class | Match | Request timeout | Idle timeout |
|---|---|---|---|
| Console | exact path | 0s | 1800s |
| JWKS | path | 10s | default |
| Public REST | `/api/(fulfillment\|events)(/.*)?` | 300s | default |
| Public Watch | `/(osac\.public\..*)/Watch` | 0s | 0s |
| ConsoleProxy/Connect | regex | 0s | 1800s |
| Public gRPC | `/(osac\.public\.\|grpc\.(reflection\|health)\.).*` | default | default |

Internal listener (8001): `/api` prefix and all-Watch `^.*/Watch$`,
no CORS. CORS stays app-side (`internal/network/cors.go`); the POC
verifies that gate (allowed/denied origins, credentials, required
exposed headers) — it does not re-litigate it and does not assume an
Istio/EnvoyFilter CORS implementation.

## Phases

### Phase 0 — Discovery and baseline (read-only, no changes, no writes)

**0a. Cluster facts (read-only):**

1. Record the actual OpenShift release (`oc get clusterversion`) and the
   served Gateway API group/versions (`oc api-resources` +
   `oc explain httproute.spec --api-version=gateway.networking.k8s.io/v1`).
   These decide which install path Phase 1 uses and which schema
   features (timeouts, BackendTLSPolicy, filter enums) actually exist.
2. Record whether any Gateway API CRDs or Gateway objects already exist
   on the cluster (e.g. Envoy Gateway's from kind profiles) — the
   CRD-succession admin gate applies.

**0b. Baseline capture (read-only):**

3. Save the objects the cutover touches, in full, to
   `/root/obochan/workspace/gw-poc-restore/` on the bastion:
   `fulfillment-ingress-proxy` Deployment, both Services (full spec —
   selector map, named ports, targetPorts), all Routes, the rendered
   Envoy configmap. These YAMLs are the contract the restore applies
   back. **Two separate inventories from here on:**
   - `baseline/` — read-only capture of pre-existing state (never
     deleted from).
   - `poc-created.txt` — explicit list of every object the POC creates,
     appended at creation time, with namespace and kind. Cleanup deletes
     **only** from this list, after checking namespace and ownership.
     Never `oc get -A ... > file; oc delete -f file`.
4. Record the pre-POC Helm revision explicitly
   (`helm history osac -n osac --max 1`) and write it into the restore
   plan. A bare "helm rollback to some revision" is not a restore step.
5. Run the smoke baseline **with Envoy up, read-only probes only**:
   JWT login, `osac get projects`, console proxy fetch, one Watch
   stream held open 60s. Same probes are the post-cutover comparison
   set.
6. Measure capacity for running both paths in parallel: actual requests
   and usage on the hub nodes (`oc describe node`, `oc adm top`) with
   Envoy up, plus the istiod + gateway footprint once Phase 1 lands —
   and the headroom with both running. The ~1 vCPU / 1 GiB figure is a
   prior, not a measurement; Gate 1 records the measured numbers.

**Gate 0:** baseline green, both inventories started, cluster release
and served APIs recorded, Helm revision pinned.

Phase 0 is strictly read-only. The VM create and other functional
writes belong to the Phase 4 campaign (disposable tenant, own cleanup)
— not to the baseline.

### Phase 1 — Enable the CIO-managed Gateway API (no traffic impact)

1. Create the GatewayClass with
   `spec.controllerName: openshift.io/gateway-controller/v1` (exact
   value; anything else and the CIO ignores it). The Cluster Ingress
   Operator provisions the embedded Sail/Istio control plane in
   `openshift-ingress` — **no OLM Subscription, no Service Mesh
   Operator, no manually installed Sail operator**. This matches the
   HLD and migration plan rev 3.
2. Wait for GatewayClass conditions Accepted / ControllerInstalled /
   CRDsReady; confirm no SM Operator Subscription appeared.
3. Gateway with listener ports 8000/8001 (namespace question below).
4. Verify istiod and gateway pods healthy. Routes still → Envoy.

If the lab's OpenShift release cannot exercise the CIO-managed path,
stop and report — do **not** silently substitute a standalone
Sail/Istio install. A standalone-Istio experiment, if run at all, is
labeled separately and closes no CIO compatibility gate.

**Open design blocker (resolve before Gate 2): where does the Gateway
live and how do the two Services reach it?**

- The CIO-managed control plane puts gateways in `openshift-ingress`.
- A Service selector only selects Pods in the Service's own namespace —
  the OSAC-namespace Services **cannot** be repointed at
  `openshift-ingress` gateway pods by a label edit. Rev 1's "two
  selector edits" cutover is withdrawn.
- Candidate designs to evaluate against the recorded cluster release:
  a. Repoint the Routes at the gateway Service in `openshift-ingress`
     (cross-namespace Route targeting — verify OCP support and the
     passthrough/TLS contract). Leaves in-cluster callers of the two
     Services on Envoy — they must be inventoried and moved, or the
     Services must keep serving.
  b. Selectorless Services + manual Endpoints in the OSAC namespace
     pointing at the gateway (the lab's proven Keycloak-cutover
     pattern). Named targetPort mapping must be reconciled.
  c. A Gateway in the OSAC namespace, if the CIO path permits it on
     this release.
- The chosen design must state: namespace, Service/Route edits, named
  port mapping, certificate references, and the internal-client
  (in-cluster caller) endpoint contract. Every additional object or
  caller setting it touches goes into the change ledger and the restore
  plan.

**Gate 1:** CIO control plane healthy via GatewayClass conditions, zero
traffic change, measured capacity recorded, cutover design written down.

### Phase 2 — Build the Gateway API config (parallel, no cutover)

1. `HTTPRoute`s mirroring each Envoy route class, attached to the
   backends with `BackendTLSPolicy` for upstream TLS + validation
   (CA refs are ConfigMaps with a PEM bundle, not Secrets).
2. Timeouts per class:
   - Field path is `HTTPRoute.spec.rules[].timeouts.request` and
     `.backendRequest` (per-rule, not a top-level `spec.timeouts`).
   - Explicit values: 10s JWKS, 300s REST (request and backend budgets
     separated, reusing v0.2's full Watch regex/inventory contract).
   - Watch/streams: request timeout disabled (`request: 0s`). Verify
     Istio's effective default is disabled — Envoy's 15s default is
     the trap.
   - Idle timeouts (1800s console, 0s Watch) have no portable Gateway
     API equivalent. An `EnvoyFilter` is a **hypothesis to test, not an
     accepted solution** — if used, it is reported as a lab-only patch
     with its support boundary for the CIO-managed runtime stated.
3. Validate in parallel: curl/gRPCurl directly against the gateway
   while Envoy still serves real traffic. No Routes touched. Probes
   include current Gateway/route/policy conditions and ready endpoints
   **before** functional traffic — a console page fetch alone is not
   path proof; run real WebSocket and CLI console sessions through the
   new path.

**Gate 2:** all parallel probes pass — conditions/ready endpoints,
path routing, TLS (including negative tests: wrong CA, wrong hostname,
TLS 1.2 rejection), gRPC/HTTP2, timeout behavior, Watch stream held
open through the probe window, public/private isolation (private REST
and gRPC **denied externally with a valid privileged token**, allowed
internally — role-permission tests are not a substitute).

### Phase 3 — Cutover (only traffic-affecting step)

Envoy stays up throughout the switch; it is stopped only after the
gateway has proven itself, and it is made ready again **before**
traffic returns during rollback.

1. Apply the chosen cutover design (from the Phase 1 blocker), per the
   change ledger.
2. Smoke: the Gate 0 probe set, plus real WebSocket and CLI console
   sessions.
3. **Prove independence**: with all traffic on the gateway, verify
   Envoy is no longer in the serving path, then
   `oc scale deployment/fulfillment-ingress-proxy --replicas=0`.
   Campaign then runs gateway-only.
4. **Rollback drill**: rehearse the Level-1 restore once (Envoy scaled
   back up, ready, traffic returned, smoke green) before the campaign
   depends on it.

**Gate 3:** smoke green → campaign. Any red → Level-1 rollback
(Envoy ready first), diagnose in parallel mode.

### Phase 4 — Test campaign

**A. Functional (writes allowed here, disposable tenant, own cleanup):**
JWT auth smoke set; lifecycle flows (login, project visibility,
membership); VM provision + console proxy + Watch-stream e2e (the VM
create lives here, not in Phase 0); gRPC and REST surfaces.

**B. OSAC-7243 evidence matrix, per route class:**

| Probe | Envoy baseline | Gateway result |
|---|---|---|
| JWKS request timeout | 10s | ? |
| Public REST timeout | 300s | ? |
| Console idle timeout | 1800s | ? (D5) |
| Watch stream idle-hold | 0s/0s | ? |
| ConsoleProxy/Connect long-idle | 1800s | ? |
| CORS verification gate | app-side policy | ? |
| Upstream TLS validation | TLS 1.3 + SAN | BackendTLSPolicy ? |

Duration evidence discipline: a 5–10 minute quiet Watch is an early
screen (longer than the 300s fallback budget), not proof of unlimited
lifetime. Use controlled delayed/streaming fixtures to attribute timer
expiry to a specific hop; console expiry at 30 minutes alone cannot
distinguish the application deadline from a proxy idle timer.

**C. Operational:** gateway metrics/logging parity, backend-pod-restart
behavior.

### Phase 5 — Report + decision

Filled evidence matrix, ranked gaps (idle-timeout first), recommendation
for the migration plan, rollback-or-stay decision. The cluster carries
documented drift from the Helm release during the POC (whatever the
cutover ledger lists, envoy replicas=0); Level 2 removes it.

## Restore plan

### Level 1 — Immediate rollback (target: under 5 minutes)

Trigger: Gate 3 smoke fails, any Phase 4 test breaks, or the lab is
needed back now.

Restore from the **Phase 0 captured values** — full selector map, named
ports/targetPorts, replica count — never hardcoded assumptions:

```bash
# 1. Make Envoy ready BEFORE returning traffic
oc scale deployment/fulfillment-ingress-proxy -n $NS \
   --replicas=$(captured_replica_count)   # from baseline/deployment.yaml
oc rollout status deployment/fulfillment-ingress-proxy -n $NS --timeout=120s

# 2. Return traffic: re-apply the captured Services (selector + ports)
oc apply -f baseline/svc-fulfillment-api.yaml \
         -f baseline/svc-fulfillment-internal-api.yaml
# (plus any Route/endpoint edits the cutover design made, reverted per
#  the change ledger, in reverse order)

# 3. Verify ready endpoints, then the four smoke probes
oc get endpoints -n $NS fulfillment-api fulfillment-internal-api
```

The chart uses `app: fulfillment-ingress-proxy` for both Services
(verified) — but the restore applies the captured selector map, not
this sentence. Verify ready endpoints and real API calls, not just
rollout status.

Leave the Gateway running (idle, measured footprint) for a retry
without redoing Phase 2.

### Level 2 — Chart-consistent restore (drift cleanup)

Trigger: POC finished, cluster back to exactly what Helm manages.

```bash
oc scale deployment/fulfillment-ingress-proxy -n $NS \
   --replicas=$(captured_replica_count)
helm upgrade osac charts/osac -n osac --reuse-values   # reasserts selectors
# Delete ONLY poc-created.txt objects — explicit list, namespace and
# ownership checked one by one. Never delete from the baseline export.
```

Verify: smoke set + `oc get svc -o yaml` matches the Phase 0 capture;
Routes unchanged.

### Level 3 — Worst case

Trigger: Level 1 did not restore service (Route modified, cert secret
touched).

```bash
oc apply -f baseline/routes.yaml -f baseline/svc-fulfillment-api.yaml \
         -f baseline/svc-fulfillment-internal-api.yaml \
         -f baseline/envoy-deployment.yaml
```

**Certificate recovery:** the cert secret holds the TLS private key; a
ConfigMap CA bundle cannot recover it. If the secret is lost, recovery
is reissuance via cert-manager (the lab's issuer) or restore from the
protected Phase 0 secret backup — the plan must not assume the
ConfigMap path. Document where the protected key backup lives before
the cutover.

Ultimate fallback: `helm rollback osac -n osac --revision
<pre-POC revision recorded at Gate 0>` — viable because the POC
performs no Helm operations.

### Rules that make restore work

1. The POC never deletes chart-managed objects. Blast radius = exactly
   the cutover ledger (which must stay minimal and is written down
   before Gate 3).
2. No Helm operations during the POC.
3. Every manual change is reversible by applying the Phase 0 capture;
   restores use captured values, not hardcoded ones.
4. Baseline inventory and POC-created manifest are separate; cleanup
   touches only the latter.
5. During rollback, Envoy is ready before traffic returns.
6. The rollback is rehearsed in Phase 3 before the campaign depends on
   it.

## Key risks

1. **Cutover design unresolved** (namespace / named ports / in-cluster
   callers) — first blocker; no selector-edit shortcut exists
   cross-namespace.
2. Watch-stream idle/timeout behavior — no portable Gateway API
   equivalent to Envoy's explicit 0s/0s; the POC's most important
   evidence item (D5).
3. Request-timeout defaults — if Istio applies a default route timeout
   where Envoy expects 0s, streams die silently; probed at Gate 2.
4. CORS — app-side policy, verification gate only.
5. Route termination is passthrough — any topology change must state
   passthrough/edge/reencrypt explicitly and re-do the upstream-TLS
   evidence if it changes.
6. The hub serves the whole lab — the cutover window is visible to
   anyone mid-operation on edge-04; agree a shared-lab window first.
