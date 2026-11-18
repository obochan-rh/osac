# OSAC-7243: Gateway API cutover — executable procedure

Target cluster: `test-infra-cluster-dev` (OCP 4.22.14 SNO, host 10.6.78.169,
`KUBECONFIG=/root/.kube/dev.kubeconfig`). Companion to
`gateway-api-migration-plan-draft.md` (rev 3) and
`gateway-api-edge04-cutover-poc-plan.md` (rev 2). Status: draft, not filed.

This cluster is the viable POC target because it is 4.22 (edge-04 is 4.17 and
cannot run the CIO-managed Gateway API). Gateway API v1 CRDs are already served:
gatewayclasses, gateways, httproutes, grpcroutes, backendtlspolicies,
referencegrants(v1beta1).

> CORRECTIONS (document review 2026-11-17) — these OVERRIDE the snippets below;
> the authoritative runbook is `gateway-api-cutover-steps.md` (rev 2):
> - Route API: use **all-HTTPRoute** on the existing hostnames with
>   `spec.rules[].timeouts`. GRPCRoute is RULED OUT: on v1.4.1 an HTTPRoute and a
>   GRPCRoute on the same hostname/listener are NOT merged (only one kind is
>   accepted), and GRPCRouteRule has no `timeouts.request`. The gRPC
>   stream-vs-unary timeout split needs RegularExpression path matches
>   (implementation-specific — confirm against Phase-0 schema) or a hostname/
>   listener redesign. Ignore the GRPCRoute block below.
> - Backend CA: `ca-bundle` key is `bundle.pem`, but BackendTLSPolicy needs
>   `ca.crt`. Create a dedicated, rotation-safe `ca.crt` ConfigMap; do NOT
>   reference `ca-bundle` as written below.
> - Gateway: `allowedRoutes` must be a **Selector restricted to ns `osac`**, not
>   `from: All`. Frontend cert (`fulfillment-api-tls`, ns `osac`) needs a valid
>   reference IN `openshift-ingress` (copy/publish or supported cross-ns ref);
>   name reuse alone is insufficient. (Verified: its SANs do cover both external
>   hosts + the `fulfillment-api`/`fulfillment-internal-api` aliases.)
> - Cutover (option B) = POC-only bridge: use a dedicated **EndpointSlice**
>   (not legacy Endpoints), destination = gateway Pod IPs (NOT a ClusterIP),
>   record numeric gateway ports, define who updates slices on Pod replacement,
>   and prove the TLS-identity bridge
>   `caller addr -> SNI/authority -> svc port -> slice IP:port -> listener -> route`
>   in parallel before editing live Services.
> - Rollback: L1 must also tear down + re-discover the endpoint bridge (track
>   created vs modified objects separately). `helm rollback` takes the revision
>   POSITIONALLY: `helm rollback osac <REV> -n osac` (not `--revision`).
> - Gate 1 verifies ControllerInstalled/CRDsReady on the current generation and
>   diffs operator inventory vs baseline (reuse a pre-existing GatewayClass; here
>   it is absent so we create it). Gate 2 adds original-Service-name callers,
>   SNI/authority routing, and INDEPENDENT ALPN checks (the OSAC gRPC client
>   disables ALPN enforcement). Gate 3 = bounded experimental campaign, not
>   production approval, while D5 / endpoint lifecycle are open.

## 1. Verified current topology (source of truth)

- Downstream TLS cert: Secret `fulfillment-api-tls` (tls.crt/tls.key/ca.crt),
  mounted at /etc/envoy/tls. CA also published as ConfigMap `ca-bundle` (ns osac).
- Services (both select `app: fulfillment-ingress-proxy`):
  - `fulfillment-api`: port 8000, name `external-api`, targetPort `external-api`.
  - `fulfillment-internal-api`: port 8001, name `internal-api`, targetPort `internal-api`.
- Routes (passthrough): `fulfillment-api` -> svc fulfillment-api (targetPort external-api);
  `fulfillment-internal-api` -> svc fulfillment-internal-api (targetPort internal-api).
  Hosts: fulfillment-api-osac / fulfillment-internal-api-osac .apps.test-infra-cluster-dev.redhat.com.
- ingress-proxy Deployment ports: 8000 external-api, 8001 internal-api, 8002 metrics.

Route table (from _config.yaml.tpl, first-match ordered per listener):

| # | Class | External (:8000) match | Internal (:8001) match | Backend:port proto | req | idle |
|---|---|---|---|---|---|---|
| 1 | console-ws | Exact `/api/fulfillment/v1/console_sessions/connect` | same | fulfillment-console-proxy:8090 h1/ws | 0s | 1800s |
| 2 | jwks | Exact `/.well-known/jwks.json` | same | fulfillment-rest-gateway:8000 h2 | 10s | - |
| 3 | REST | regex `/api/(fulfillment\|events)(/.*)?` | prefix `/api` | fulfillment-rest-gateway:8000 h2 | 300s | - |
| 4 | Watch | regex `/osac\.public\..*/Watch` | regex `^.*/Watch$` | fulfillment-grpc-server:8000 h2 | 0s | 0s |
| 5 | Connect | regex `/osac\.public\..*ConsoleProxy/Connect` | same | fulfillment-console-proxy:8000 h2 | 0s | 1800s |
| 6 | gRPC unary | regex `/(osac\.public\.\|grpc\.(reflection\|health)\.).*` | prefix `/` | fulfillment-grpc-server:8000 h2 | 300s | - |

Upstreams: all TLS 1.3 only, CA-validated (ca.crt). Downstream ALPN h2 + http/1.1,
websocket upgrade enabled, http2 keepalive 15s/10s.

PUBLIC/PRIVATE BOUNDARY (must preserve + test): external restricts REST to
/api/(fulfillment|events) and gRPC to osac.public.* + reflection/health, NO
catch-all. Internal has /api prefix and / catch-all (private APIs). Test:
private REST+gRPC denied on the external host with a valid privileged token,
allowed on the internal host.

## 2. Target Gateway API objects

### GatewayClass
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1   # exact; else CIO ignores it
```
Creating this makes the Cluster Ingress Operator install an embedded Sail/Istio
control plane in openshift-ingress. NO OLM Subscription / Service Mesh Operator.
Wait for conditions Accepted / ControllerInstalled / CRDsReady. Confirm no
servicemeshoperator3 Subscription appeared.

### Gateway (two HTTPS listeners by hostname = the isolation split)
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: osac-gateway
  namespace: openshift-ingress        # CIO-managed placement (confirm in Phase 1)
spec:
  gatewayClassName: openshift-default
  listeners:
  - name: external
    protocol: HTTPS
    port: 443
    hostname: fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: fulfillment-api-tls     # verify SAN covers BOTH hostnames
    allowedRoutes: { namespaces: { from: All } }   # tighten to Selector in prod
  - name: internal
    protocol: HTTPS
    port: 443
    hostname: fulfillment-internal-api-osac.apps.test-infra-cluster-dev.redhat.com
    tls: { mode: Terminate, certificateRefs: [ { kind: Secret, name: fulfillment-api-tls } ] }
    allowedRoutes: { namespaces: { from: All } }
```
Cert note: the cert Secret must be reachable from the Gateway namespace; if the
Gateway is in openshift-ingress and the Secret in osac, use a ReferenceGrant or
copy the cert. SANs must include both hostnames.

### HTTPRoutes (REST/jwks/console-ws)  — EXTERNAL host
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: ext-http, namespace: osac }
spec:
  parentRefs: [ { name: osac-gateway, namespace: openshift-ingress, sectionName: external } ]
  hostnames: [ fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com ]
  rules:
  # 1 console-ws (Exact beats PathPrefix by specificity)
  - matches: [ { path: { type: Exact, value: /api/fulfillment/v1/console_sessions/connect } } ]
    backendRefs: [ { name: fulfillment-console-proxy, port: 8090 } ]
    timeouts: { request: "0s" }           # idle 1800s: NO FIELD -> D5
  # 2 jwks
  - matches: [ { path: { type: Exact, value: /.well-known/jwks.json } } ]
    backendRefs: [ { name: fulfillment-rest-gateway, port: 8000 } ]
    timeouts: { request: "10s" }
  # 3 REST  (regex -> TWO PathPrefix; avoid RegularExpression per rev3)
  - matches:
    - { path: { type: PathPrefix, value: /api/fulfillment } }
    - { path: { type: PathPrefix, value: /api/events } }
    backendRefs: [ { name: fulfillment-rest-gateway, port: 8000 } ]
    timeouts: { request: "300s", backendRequest: "300s" }
```
INTERNAL host HTTPRoute: identical #1/#2, but #3 = single PathPrefix `/api`.

### GRPCRoutes (Watch/Connect/unary) — EXTERNAL host
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata: { name: ext-grpc, namespace: osac }
spec:
  parentRefs: [ { name: osac-gateway, namespace: openshift-ingress, sectionName: external } ]
  hostnames: [ fulfillment-api-osac.apps.test-infra-cluster-dev.redhat.com ]
  rules:
  # 5 Connect (more specific method before #6)
  - matches: [ { method: { service: "osac.public.*", method: "Connect" } } ]   # verify wildcard support
    backendRefs: [ { name: fulfillment-console-proxy, port: 8000 } ]
    timeouts: { request: "0s" }           # idle 1800s -> D5
  # 4 Watch
  - matches: [ { method: { method: "Watch" } } ]
    backendRefs: [ { name: fulfillment-grpc-server, port: 8000 } ]
    timeouts: { request: "0s" }           # idle 0s -> D5 (verify Istio default not 15s)
  # 6 gRPC unary: osac.public.* + grpc.reflection + grpc.health
  - matches:
    - { method: { service: "osac.public.*" } }
    - { method: { service: "grpc.reflection.*" } }
    - { method: { service: "grpc.health.*" } }
    backendRefs: [ { name: fulfillment-grpc-server, port: 8000 } ]
    timeouts: { request: "300s" }
```
INTERNAL host GRPCRoute: Watch/Connect same; unary = match ALL services (catch-all).
If GRPCRoute service wildcards are unsupported on this build, fall back to HTTPRoute
with the method-path regex (cross-kind precedence then applies). Spike both.

### BackendTLSPolicy (upstream TLS 1.3 + validation) — one per backend
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: { name: btls-grpc-server, namespace: osac }
spec:
  targetRefs: [ { group: "", kind: Service, name: fulfillment-grpc-server } ]
  validation:
    caCertificateRefs: [ { group: "", kind: ConfigMap, name: ca-bundle } ]  # PEM bundle, NOT a Secret
    hostname: fulfillment-grpc-server.osac.svc                               # set to backend cert SAN
```
Repeat for fulfillment-rest-gateway and fulfillment-console-proxy. console-proxy
has two ports (8000 h2, 8090 ws) — target per-port via sectionName if the SANs or
protocols differ. TLS-1.3 floor + ALPN (h2 for grpc/rest, http/1.1 for ws) are not
in BackendTLSPolicy core; verify negotiation, use appProtocol/Istio-side only if
needed (flag support boundary).

## 3. Cutover topology (resolve before Gate 2)

Service selectors cannot cross namespaces -> no selector-edit shortcut. Options:

- (a) Cross-ns Route: repoint both Routes at the gateway Service in
  openshift-ingress. Verify OCP cross-ns Route support + passthrough contract.
  In-cluster callers of the Services stay on Envoy (inventory + move them).
- (b) RECOMMENDED for reversible POC: keep Service names fulfillment-api /
  fulfillment-internal-api, remove the selector, create manual Endpoints (or
  EndpointSlice) pointing at the gateway pod IP:port, keep named ports
  external-api/internal-api mapped to the gateway listener ports. This also moves
  in-cluster callers. Rollback = re-apply the captured Service YAML. (Lab's proven
  Keycloak-cutover pattern.)
- (c) Gateway in the osac namespace if the CIO path allows it on this release.

Chosen design must record: namespace, Service/Route edits, named-port mapping,
certificate refs, in-cluster-caller endpoint contract. Everything it touches goes
in the change ledger + restore plan.

## 4. Execution (phases mapped to the POC plan)

Phase 0 (read-only): mkdir baseline/ ; capture both Services (full spec),
both Routes, ingress-proxy Deployment, envoy configmap, cert Secret (protected);
`helm history osac -n osac --max 1` -> record revision; smoke baseline (JWT login,
osac get projects, console fetch, 60s Watch); `oc api-resources
--api-group=gateway.networking.k8s.io`; check for conflicting Envoy-Gateway
GatewayClass/CRDs. Gate 0: baseline green, inventories started, revision pinned.

Phase 1: apply GatewayClass + Gateway; wait Accepted/Programmed; confirm no SM
Operator Subscription; istiod + gateway pods healthy; Routes still -> Envoy. Write
the chosen cutover design. Gate 1: control plane healthy, zero traffic change.

Phase 2: apply HTTPRoutes/GRPCRoutes + BackendTLSPolicy; validate in parallel
against the gateway while Envoy still serves (curl/grpcurl): route conditions +
ready endpoints; TLS negatives (wrong CA, wrong hostname, TLS1.2 reject); gRPC/h2;
public/private isolation with a valid privileged token; a Watch held open through
the window. Gate 2: all parallel probes pass.

Phase 3 (only traffic step): apply option (b); smoke incl. real WS + CLI console;
prove Envoy out of path; `oc scale deploy/fulfillment-ingress-proxy --replicas=0`;
rehearse the <5-min rollback once. Gate 3: smoke green -> campaign.

Phase 4: D5 evidence matrix per route class with controlled, deliberately-quiet
fixtures (attribute expiry to a hop; console 30-min is an app deadline, not a
proxy idle timer). Columns: Envoy baseline vs Gateway result for JWKS 10s, REST
300s, console idle 1800s, Watch 0s/0s, Connect long-idle, CORS (app-side), upstream
TLS1.3+SAN via BackendTLSPolicy.

Phase 5: filled matrix, ranked gaps (idle-timeout first), go/no-go.

## 5. Rollback (from Phase 0 captured values, never hardcoded)

L1 (<5 min): `oc scale deploy/fulfillment-ingress-proxy --replicas=<captured>`;
rollout status; re-apply captured Services (selector + named ports); verify ready
endpoints + smoke. Leave the Gateway idle for a retry.
L2 (drift cleanup): scale Envoy back; `helm upgrade osac charts/osac -n osac
--reuse-values` (reasserts selectors); delete ONLY poc-created.txt objects.
L3: re-apply baseline Routes + Services + Envoy deployment. Cert key recovery =
reissue via cert-manager or restore the protected Phase 0 secret backup (ConfigMap
CA cannot recover the private key). Ultimate: `helm rollback osac --revision
<pre-POC>` (valid because the POC does no Helm ops).

## D5 — idle/stream timeout (the make-or-break)

No Gateway API field for idle timeout. Candidates, best-supported first:
1. App-level keepalive/heartbeat so streams are never idle (verify Istio stream
   idle resets on the keepalive frames used).
2. A supported platform knob if a later CIO/OSSM release adds one (none in v1.4.1).
3. EnvoyFilter ONLY as a lab-only, support-boundary-flagged patch — test whether it
   even takes effect on the CIO-managed istiod; never the default answer.
Supportability + FIPS are hard acceptance gates: a working EnvoyFilter can still
fail the gate.
