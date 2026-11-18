[~accountid:6269a25607b842006f14b8d5] — please review this Gateway API migration plan (rev 3).

Gateway API direction is already decided (arch meeting 2026-11-11). Looking for your feedback on the phase-0 gates, edge topology choice (LB/MetalLB vs ClusterIP+Route), idle/timeout risks, and whether anything important is missing before we spike on a real 4.22 cluster.

---

Status: internal draft, not filed. Decision input for the team lead.
Decision context: arch meeting 2026-11-11 chose OpenShift Gateway API.
Framing: this removes OSAC's standalone upstream Envoy deployment and
consumes a platform-managed gateway — it does not remove the proxy
runtime. Supportability and applicable FIPS requirements are explicit
acceptance gates.

Rev 3 (2026-11-12): re-verified against Mario's comments and public
sources. Route-fronted gateway exposure is documented (not
unconfirmed). Cluster Ingress Operator embeds Sail/Istio — Service Mesh
Operator (OLM Subscription) is not required. CORS closed as app-side
policy with a verification gate. Public/private isolation and phase-0
exit gates remain the delivery spine.

## What we run today

Two layers of hand-rolled Envoy:

1. `fulfillment-ingress-proxy` (fulfillment-service chart): a standalone
   Envoy Deployment with a static config from `_config.yaml.tpl`. Two TLS
   listeners (external 8000, internal 8001), a metrics/healthz listener
   (8002), six ordered route classes, CORS, upstream TLS 1.3 to four
   backends.
2. `envoy-gateway-resources.yaml` (osac-infra chart): an Envoy Gateway
   GatewayClass/Gateway plus a TLSRoute for Keycloak, used on kind
   profiles and NodePort setups.

OpenShift Routes (fulfillment-api, fulfillment-internal-api) sit in front
of layer 1 on OCP deployments.

**Public/private isolation is intentional, not incidental**: the external
listener restricts rest-gateway to `/api/(fulfillment|events)` and gRPC
to `osac.public.*` plus reflection/health; only the internal listener has
the broad `/api` prefix and `/` catch-all (private APIs). The replacement
must preserve this boundary explicitly and test it — external denial of
private APIs with valid privileged credentials.

## Verified platform facts

From OKD Gateway API docs, CIO source (release-4.22 / master), OSSM 3.4
gateway docs, Mario's guidance, and Jira — checked directly unless noted:

- GatewayClass `spec.controllerName` must be exactly
  `openshift.io/gateway-controller/v1`; any other value and the CIO
  ignores the GatewayClass and all attached routes.
- Creating that GatewayClass causes the Cluster Ingress Operator to
  install a lightweight Istio control plane in `openshift-ingress`
  (docs: "based on Red Hat OpenShift Service Mesh"). **This is
  CIO-embedded Sail/Istio — not an OLM `servicemeshoperator3`
  Subscription / InstallPlan / CatalogSource.** Gateways live in
  `openshift-ingress`; listener hostnames must be under the cluster
  domain.
- **Service Mesh Operator is not a prerequisite for OpenShift Gateway
  API.** Mario: CIO installs/manages its isolated Istio control plane
  via the embedded Sail library. Aligns with NE-2471 (Sail library
  replace OLM Istio install) and OCPBUGS-91967 (works without OLM;
  GatewayAPIWithoutOLM GA on 4.22). Do not plan OSAC enablement around
  installing the SM Operator.
- **Edge exposure via OpenShift Route is documented**, not speculative:
  OSSM 3.4 "Exposing a gateway … using OpenShift Routes" — set the
  gateway `Service` to `ClusterIP`, then create a Route to that
  Service. Public MaaS samples use the same ClusterIP + Route
  (passthrough or reencrypt) pattern in `openshift-ingress`. Default
  CIO path still provisions LoadBalancer-style addressing when used;
  on-prem/MetalLB and Route-fronted are the realistic OSAC options.
  Route adds a hop (and often decrypt/re-encrypt); phase 0 must prove
  gRPC/h2, WebSocket, and long-lived streams through the chosen path.
- **release-4.22 ships gateway-api bundle v1.4.1** (CIO CRD assets).
  Consequences:
  - HTTPRoute v1 filter enum on 4.22: RequestHeaderModifier,
    ResponseHeaderModifier, RequestMirror, RequestRedirect, URLRewrite,
    ExtensionRef — **no CORS**. CORS went GA in gateway-api v1.5.0;
    CIO master (4.23+) ships v1.5.1 with CORS. Upstream Istio
    conversion cannot overcome the served-schema limitation.
  - BackendTLSPolicy IS present (v1 + v1alpha3) on 4.22.
  - HTTPRouteRule `timeouts` IS present (Support: Extended) on 4.22,
    including the zero-disables wording.
  - Path match types: Exact, PathPrefix, RegularExpression. The type
    value is `RegularExpression` (no "Path" prefix); conformance and
    precedence are implementation-specific.
- CIO master pins Istio `v1.30-latest` (OSSM 3.5 line). Istio's CORS
  conversion exists in release-1.30/1.29 — relevant only once the
  platform serves a schema that allows CORS; OSAC does not need it for
  cutover (app-side CORS already exists).
- OCPBUGS-91967: Closed/Done on release-4.22.
- Constraints from the docs: no UDN support for Gateway API; active
  OSSM v2 conflicts; third-party Gateway API CRDs already on the cluster
  (e.g. Envoy Gateway's) trigger a CRD-succession admin-gate.
- Reviewer-provided, not independently re-verified here: 4.22
  on-premise docs state NodePort as LB replacement is unsupported and
  MetalLB is the tested/certified on-premise LB path.

## Sources

Verified directly:
- OKD Gateway API enablement
  (`docs.okd.io/.../configuring_gateway_api/enable-gateway-api.html`):
  controllerName, lightweight Istio in `openshift-ingress`,
  Accepted / ControllerInstalled / CRDsReady.
- OSSM 3.4 gateways chapter (Mario): LoadBalancer **or** OpenShift
  Route exposure; ClusterIP + Route procedure; notes the extra hop /
  decrypt-reencrypt latency of the router path.
- openshift/cluster-ingress-operator (release-4.22 / master): CRD
  assets (bundle versions, filter enums, BackendTLSPolicy), Sail
  installer path, controllerName / Istio defaults; NE-2471 /
  OCPBUGS-91967.
- gateway-api: GEP-1767, v1.5.0 notes, CORS filter Extended in v1.5.
- Public MaaS Route pattern (substitute for Mario's private repo
  links): `opendatahub-io/models-as-a-service` ClusterIP + Route
  reencrypt/passthrough samples; similar patterns in MaaS quickstarts.
- Our own code: `_config.yaml.tpl` (public/private match differences),
  `internal/network/cors.go` (allowlist, rejects `*`),
  `envoy-gateway-resources.yaml`.

Not publicly accessible (Mario cited; treat as pointer, not sole
evidence):
- `RHsyseng/ai-grid-policies` MaasGateway / MaasGatewayClass at commit
  `492bce4…` — GitHub returns 404 for anonymous fetch. Content claim
  (gateway exposed via Route) is corroborated by OSSM 3.4 + public
  MaaS samples above.

Still to verify in phase 0:
- Exact on-prem LB wording for the target 4.22 build.
- End-to-end OSAC traffic through Route-fronted CIO gateway (not just
  that the pattern exists in docs).

## Requirement inventory, mapped to Gateway API

| Current behavior | Gateway API mechanism | Status |
|---|---|---|
| TLS listeners 8000/8001, cert from Secret | Gateway HTTPS listeners, `certificateRefs` | standard |
| Six route classes; external/internal match sets differ (see isolation note) | HTTPRoute rules; keep external/internal as separate routes with explicit, non-overlapping matches; rewrite the external rest-gateway regex `/api/(fulfillment|events)(/.*)?` as two `PathPrefix` matches | Exact/PathPrefix are Core. `RegularExpression` is implementation-specific — avoid. Do not assume copying six rules in order preserves Envoy first-match behavior |
| WebSocket upgrade (console-ws) | plain HTTPRoute rule; Istio proxies upgrades by default | Istio behavior, not a spec guarantee — verify in spike |
| No request timeout on Watch and Connect streams | `timeouts.request: 0s` | valid on 4.22 (Extended); zero means no timeout per schema. Remaining gate: effective behavior across the whole path — fronting router/LB and backendRequest timer included |
| 300s timeouts on other classes | `timeouts.request` / `backendRequest` | available on 4.22 |
| Idle timeouts (1800s console, 0 events) | not in core; Istio-side setting | main open risk. Note: the console backend's 30-minute limit is an absolute session duration (context deadline), not an inactivity timer — it cannot prove a quiet stream survives an earlier proxy idle timeout |
| CORS: Envoy allow-all origins with credentials, expose Grpc-Status/Message, max-age 86400 | Gateway CORS filter **absent on 4.22** (v1.4.1). App already has `internal/network/cors.go` (explicit origins, rejects `*`; used by REST gateway / MCP) | **Closed for cutover.** Do not preserve Envoy's permissive `.*`+credentials. Keep app-side policy; verify preflight / credentialed / denied origins / exposed headers through the real gateway. Check UI connect-RPC path has the same middleware if needed. Do not install unsupported CRDs to get gateway CORS |
| Upstream TLS 1.3 only, CA pinned | `BackendTLSPolicy` (present on 4.22). `caCertificateRefs` must point at a ConfigMap with a PEM CA bundle — NOT the existing certificate Secret. Includes backend hostname/SAN validation, per-port targeting where needed, rotation, rejection of invalid certs | CRD confirmed. TLS 1.3: the shared server TLS config already requires 1.3 — verify negotiation against actual backends before adding any Istio-specific policy for the version floor |
| h2 upstream for grpc/rest, h1 for websocket | BackendTLSPolicy ALPN; `appProtocol: grpc` is Istio-specific (portable GEP-1911 values are h2c/ws/wss only) | low risk, verify in spike |
| /healthz | Gateway/Deployment status probes | replaces the health filter |

Not mapped as cutover requirements (optional later): Envoy metrics
listener (8002) and access logs to stdout. Nice to have from platform
gateway observability if available; we can ship without parity.

GRPCRoute (Standard, in the 4.22 CRD set) matches gRPC service/method
directly — cleaner for the Watch and ConsoleProxy/Connect classes than
path regexes. But rest-gateway must stay HTTPRoute, so mixing kinds on
one hostname inherits cross-resource precedence rules. Spike should try
both; not a commitment.

## Open questions to close in phase 0

1. **Which supported edge topology for OSAC cutover?** Documented
   options: CIO LoadBalancer/MetalLB addressing, or ClusterIP Gateway
   Service + OpenShift Route (OSSM 3.4 / MaaS pattern Mario pointed
   at). NodePort-as-LB-replacement is unsupported on-prem
   (reviewer-cited). Pick one primary path; prove hostname/certificate
   continuity and streaming through it before charting around it.
2. **Idle/stream timeouts**: no core Gateway API mechanism.
   Istio-specific policy vs accepting stream-level defaults; absolute
   console session deadline ≠ proxy idle timeout.
3. **Effective zero-timeout behavior end-to-end**, including a
   fronting OpenShift Route/router if that topology is chosen.
4. **Layer 2 (Envoy Gateway on kind/dev)**: keep as kind/dev provider
   initially — do not combine provider consolidation with this
   cutover. Inventory Keycloak infra-chart TLSRoute and fulfillment
   TLSRoutes. CRD-succession admin-gate if converging later.
5. **OSAC-4385 rate limiting**: linked epic; confirm it does not assume
   Envoy filter hooks that disappear with this cutover (follow-up, not
   cutover scope).

Closed:
- controllerName `openshift.io/gateway-controller/v1` (verified).
- CIO-embedded Sail/Istio; SM Operator / OLM Subscription not required
  (Mario + NE-2471 / OCPBUGS-91967 / OKD enablement doc).
- Route-fronted gateway exposure is documented (OSSM 3.4 + public MaaS
  samples). Remaining work is OSAC validation, not existence proof.
- 4.22 gateway-api bundle v1.4.1; BackendTLSPolicy and HTTPRoute
  timeouts present; CORS filter absent (CIO CRD assets).
- CORS cutover policy: app-side allowlist (not Envoy `.*`).
- OCPBUGS-91967 fixed on 4.22 (verified).

## Delivery plan

Phase 0 — parallel spikes, OCP and Kind (1-2 days, gates everything):
- Start the actual CIO-managed 4.22 path immediately; Kind alone cannot
  close CIO-specific questions. Record: tested release, installed API
  schema (bundle version), gateway implementation, chosen exposure,
  required extensions. Confirm no SM Operator Subscription was needed.
- Spike both exposure candidates if unclear: direct LB/MetalLB vs
  ClusterIP + OpenShift Route (Mario / OSSM 3.4). Prefer the path that
  preserves current hostnames with least TLS/stream breakage.
- Hand-write Gateway + HTTPRoutes + BackendTLSPolicy reproducing the
  route classes; try GRPCRoute for the gRPC classes; test the
  public/private boundary with valid privileged credentials.
- Run the fulfillment integration suite (`SUITE=fulfillment`) against
  the Kind path.
- Exit gates (binary): support/FIPS boundary written; edge topology
  chosen; external denial of private REST+gRPC with privileged token;
  quiet Watch + real console WS/Connect through that topology; CORS
  verification against app middleware (not gateway CORS); TLS fail /
  CA rotation smoke.

Phase 1 — chart mode, default unchanged:
- Opt-in `ingress.driver: gatewayapi` alongside the existing proxy.
- Configurable `gatewayClassName`; explicit external/internal route
  attachment; CA publication as a ConfigMap; chart contract tests.
- Separate cluster-admin enablement (GatewayClass, CRD succession) from
  OSAC application installation.
- Do not package unsupported CRD replacements to obtain CORS.

Phase 2 — behavioral acceptance:
- Public/private REST and gRPC boundaries; real authenticated
  browser/CLI console sessions (existing console ingress tests use
  invalid tickets — they prove routing, not working sessions); quiet
  Watch streams beyond relevant timers; active/idle console behavior
  through the configured deadline; CORS; TLS failures; certificate
  rotation.
- E2E on a real OCP cluster with the CIO GatewayClass.

Phase 3 — upgrade, rollback, then default flip:
- Prove hostname/certificate continuity and rollback before cutover.
- Keeping the old templates one release is reasonable, but downstream
  rollback must not silently reintroduce the unsupported upstream Envoy
  image the epic requires removing.
- Layer 2 consolidation is a separate follow-up, not part of cutover.

## Effort

"About two weeks" is a provisional implementation estimate that applies
only after the phase-0 gates pass — not a cutover commitment. Top risks
after rev 3: chosen edge topology (LB/MetalLB vs Route) under real
streams, idle/timeout behavior across that path, and public/private
isolation. CORS is a verification item, not a design blocker.
