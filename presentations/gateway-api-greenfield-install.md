# OSAC install with OpenShift Gateway API ingress (replacing the bundled Envoy)

Greenfield guide: install OSAC so its API front door is the OpenShift
CIO-managed Gateway API (the platform's own Istio/Envoy) instead of the bundled
`fulfillment-ingress-proxy` Envoy. Addresses OSAC-7243 (replace the upstream
Envoy with a Red Hat-built/supported proxy).

Status: proposal + manual procedure. Derived from the POC validated on
`test-infra-cluster-dev` (OCP 4.22.14), 2026-11-17. The chart option to skip the
bundled Envoy does not exist yet — see "Chart work required". Companions:
`gateway-api-migration-plan-draft.md` (strategy), `gateway-api-cutover-steps.md`
(migrate an existing deployment), `gateway-api-cutover-procedure.md` (YAML).

## Why

OSAC ships a hand-rolled upstream Envoy (`fulfillment-ingress-proxy`) as its
single API entry point. The downstream Red Hat build has no supported standalone
Envoy. The OpenShift Cluster Ingress Operator (CIO) already runs a supported
Envoy via the Gateway API (embedded Sail/Istio) — so OSAC can consume that
instead of maintaining its own. The proxy runtime stays Envoy; the owner becomes
the platform.

## Requirements

- OpenShift **4.22** (4.19+ in general): Gateway API v1 CRDs served,
  `GatewayAPIWithoutOLM` GA. Confirmed NOT viable on 4.17.
- cert-manager + trust-manager (shipped by `osac-deps`) for the frontend cert and
  the backend CA.
- **No Service Mesh Operator** — the CIO installs/manages its own Istio control
  plane (`istiod-openshift-gateway` in `openshift-ingress`) from the GatewayClass.

## What replaces what

| Bundled Envoy (today) | Gateway API (this guide) |
|---|---|
| `fulfillment-ingress-proxy` Deployment + `_config.yaml.tpl` | CIO gateway Envoy in `openshift-ingress` |
| 2 TLS listeners (8000/8001) | Gateway HTTPS listeners (by hostname) |
| 6 ordered route classes | HTTPRoute rules (RegEx for the gRPC stream classes) |
| per-route request timeouts | `HTTPRoute.spec.rules[].timeouts.request` |
| upstream TLS 1.3 + CA | `BackendTLSPolicy` (CA = ConfigMap `ca.crt`) |
| public/private split (2 listeners) | 2 hostnames with different attached routes |
| CORS (Envoy filter) | **app-side** (`internal/network/cors.go`) — no gateway CORS on 4.22 |
| console/Watch idle timeouts (0s/1800s) | **no Gateway API field** — see D5 |

## Chart work required (for a true one-command greenfield)

The manual steps below work today. To make this a profile toggle, the charts need:
1. `fulfillment-service`: an option to **not** deploy `fulfillment-ingress-proxy`
   (e.g. `service.ingressProxy.enabled=false` / `ingress.driver=gatewayapi`), and
   to render `fulfillment-api` / `fulfillment-internal-api` as selectorless
   Services wired to the gateway (plus the Gateway / HTTPRoute / BackendTLSPolicy).
2. the chart must render all gRPC stream routes with a **non-order-dependent
   `request: 0s`** timeout (Watch/Connect/unary; REST stays 300s) — so streams are
   never request-capped regardless of RegEx precedence (the real D5 fix; no code change).
3. A small controller (or chart hook) to keep the Service EndpointSlice pointed at
   the current gateway pod IP across pod replacement — the one lifecycle gap of the
   manual bridge.

## Steps (manual, until the chart option lands)

Constants used below: ns `osac`, gateway ns `openshift-ingress`, cluster apps
domain `apps.<cluster>`, cert Secret `fulfillment-api-tls` (its SANs must cover
both the `fulfillment-api-osac.apps.<cluster>` / `fulfillment-internal-api-...`
hosts AND the bare `fulfillment-api` / `fulfillment-internal-api` names).

1. **Install OSAC** normally (`make install PLATFORM=openshift PROFILE=<p> NS=osac`),
   then take the bundled Envoy out of the path:
   `oc scale deploy/fulfillment-ingress-proxy -n osac --replicas=0`
   (or, once it exists, the chart option so it's never created).

2. **Enable the CIO Gateway API** — GatewayClass with the exact controllerName:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata: { name: openshift-default }
   spec: { controllerName: openshift.io/gateway-controller/v1 }
   ```
   Wait for `Accepted` / `ControllerInstalled` / `CRDsReady`; confirm NO
   `servicemesh` Subscription appeared; `istiod-openshift-gateway` comes up in
   `openshift-ingress`.

3. **Frontend cert into `openshift-ingress`** (a Gateway there needs the cert in
   that namespace — name reuse alone is not enough):
   `oc get secret fulfillment-api-tls -n osac -o ...| oc create secret tls ... -n openshift-ingress`
   (or a supported cross-namespace reference).

4. **Gateway** — four HTTPS listeners on 443 by hostname (SNI), attachment
   restricted to ns `osac`:
   - `external`  → `fulfillment-api-osac.apps.<cluster>`        (external clients via Route)
   - `internal`  → `fulfillment-internal-api-osac.apps.<cluster>`
   - `ext-svc`   → `fulfillment-api`               (in-cluster callers' SNI)
   - `int-svc`   → `fulfillment-internal-api`      (e.g. the operator → `:8001`)
   All `tls.mode: Terminate`, `certificateRefs: fulfillment-api-tls`,
   `allowedRoutes.namespaces.from: Selector` on `kubernetes.io/metadata.name: osac`.
   (Bare-label hostnames ARE accepted by the CIO/Istio implementation — verified.)

5. **Backend CA + BackendTLSPolicy** — the existing `ca-bundle` ConfigMap is keyed
   `bundle.pem`, but BackendTLSPolicy needs **`ca.crt`**. Create a dedicated,
   rotation-safe ConfigMap keyed `ca.crt` (the `default-ca` PEM), then a
   BackendTLSPolicy per backend (`fulfillment-grpc-server`, `-rest-gateway`,
   `-console-proxy`) with `caCertificateRefs` → that CM and
   `validation.hostname` → the backend cert SAN
   (`fulfillment-<svc>.osac.svc.cluster.local`).

6. **HTTPRoutes (all-HTTPRoute, no GRPCRoute)** — on v1.4.1 an HTTPRoute and a
   GRPCRoute cannot share a hostname (only one is accepted), and GRPCRoute has no
   `timeouts.request`; so reproduce every class as HTTPRoute rules:
   - External (public, restricted): console-ws (Exact → console-proxy:8090,
     `request:0s`), jwks (Exact → rest-gateway:8000, `request:10s`), REST
     (PathPrefix `/api/fulfillment` + `/api/events` → rest-gateway:8000,
     `request:300s`), **Connect (`Exact: /osac.public.v1.ConsoleProxy/Connect` →
     console-proxy:8000, `request:0s`)**, unary (RegEx
     `/(osac\.public\.|grpc\.(reflection|health)\.).*` → grpc-server:8000,
     `request:0s`). Attach to listeners `external` + `ext-svc`; hostnames both the apps
     host and the bare `fulfillment-api`.
   - Internal (private, broad): same console-ws/jwks; REST PathPrefix `/api`;
     Connect as above (`Exact`); unary PathPrefix `/`. Attach to `internal` +
     `int-svc`; hostnames the apps host and bare `fulfillment-internal-api`.
   - **Precedence is specificity + creation time, NOT Envoy first-match, and
     RegEx-vs-RegEx order is implementation-specific** (per the Gateway API spec:
     Exact → longest Prefix → method → headers → query, then first-rule-in-list-order;
     regex precedence is a documented carve-out). Therefore any route whose backend is
     NOT the grpc-server fallback MUST use `Exact`/`Prefix`, never a regex that competes
     with the broad grpc rule. **Connect must be `Exact`** — as a regex it got shadowed
     by the broad unary regex and misrouted to grpc-server → `Unimplemented` (ISSUE-2).
     A separate Watch rule is unnecessary (same backend+`0s` as the fallback). Verify
     Connect lands on console-proxy (`osac-ext.4`) and a Watch path on the `0s` grpc rule.

7. **Wire the Services to the gateway** — make both Services selectorless and add a
   manual EndpointSlice to the gateway pod:
   - `oc patch svc fulfillment-api -n osac --type=json -p '[{"op":"remove","path":"/spec/selector"}]'` (and `-internal-api`)
   - EndpointSlice per Service → gateway pod IP `:443`, port name `external-api` /
     `internal-api`.
   - **Delete the legacy `Endpoints` object** (`oc delete endpoints fulfillment-api
     fulfillment-internal-api -n osac`) — otherwise `endpointslicemirroring-controller`
     keeps re-creating slices pointing at the old Envoy and traffic splits ~50/50.

8. **D5 — Watch heartbeat (required).** The CIO gateway cuts a quiet stream at the
   Istio default `stream_idle_timeout` (~300s), and idle timeout has no Gateway API
   field. Console is safe (30s WS ping). `Events.Watch` has no keepalive, so a quiet
   Watch dies at ~5min. Fix in `fulfillment-service` `events_server.go`: emit a
   periodic (<300s, e.g. 60s) keepalive on the Watch stream. The CLI client already
   ignores responses with no event, so an empty `EventsWatchResponse` is
   contract-safe; the PR decides whether to use that or an explicit keepalive field.
   **CORRECTED 2026-11-17 — the heartbeat is NOT the fix.** Re-diagnosis (access log
   `…/Events/Watch … 300001 … osac.osac-ext.5`) showed the 300s cut is a REQUEST-timeout
   routing issue (R-1), not idle: the Watch matched the broad gRPC rule (`request:300s`),
   not the `0s` Watch rule, because Gateway API doesn't honor RegEx order the way Envoy's
   first-match did. **Real fix: set all gRPC HTTPRoute rules to `request: 0s`** (Watch,
   Connect, unary; keep REST `300s`) — a routing requirement of the gateway, no
   `fulfillment-service` change. The keepalive was trialed (fired fine) but the stream
   still died at 300s, proving it's request-duration not idle — do NOT ship it.
   **CONFIRMED 2026-11-17:** with the route fix applied and the stock grpc-server (no
   keepalive), a truly quiet Watch survived 400s through the gateway → D5 is closed by
   the route config alone; no idle timeout, no `fulfillment-service` change.

## Validation

- REST ext + int → 200; jwks → 200; `osac-ui` → 200.
- ALPN `h2` (check with `openssl s_client -alpn h2`, not the OSAC client — it
  disables ALPN enforcement).
- gRPC reflection + public unary via the gateway.
- Public/private isolation: a private method on the **external** host → 404 /
  Unimplemented; on **internal** → served. Use a valid privileged token.
- TLS negatives: untrusted CA rejected; unknown SNI rejected.
- CORS: disallowed origin gets no `Access-Control-Allow-Origin`.
- console-ws route → 426 (Upgrade Required) = correctly routed to console-proxy.
- **Watch survives >5 min** quiet (only after the heartbeat ships).
- Gateway access log shows `… 200 … via_upstream … fulfillment-rest-gateway.osac…`.

## Known gaps / operational notes

- **D5 idle timeout** — needs the Watch heartbeat (above). Do NOT rely on an
  `EnvoyFilter` against the CIO-managed istiod (support boundary).
- **CORS allowlist** — the gateway drops Envoy's allow-all (`.*`) CORS filter, so
  CORS is now only the app's `--http-cors-allowed-origins` (chart
  `httpCorsAllowedOrigins`), which defaults to just the API's own host. Add any
  real cross-origin caller (e.g. the UI origin) explicitly, or browser cross-origin
  calls that worked under Envoy's `.*` will fail. Verified: configured origin →
  full ACAO/credentials/headers; others → denied.
- **Downstream TLS 1.2 is accepted** (same as the old Envoy). If TLS-1.3-min at the
  edge is required, add an explicit min-TLS policy.
- **HPA metrics** for `istiod`/`osac-gateway` may be unavailable on the lab
  (no autoscale) — benign, watch in production.
- **EndpointSlice bridge lifecycle** — the manual slice pins the gateway pod IP;
  it must be updated if that pod is replaced. Productize via a controller or the
  chart.
- **Access logging** is on by default on the CIO gateway Envoy (request logs
  present) — parity with the old Envoy's stdout access log.
