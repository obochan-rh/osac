# OSAC-4385 Task Breakdown — DRAFT v5 (pending approval)

Parent: OSAC-4385 (Request Rate Limiting) ← OSAC-4382 (Fulfillment
Service Zero Trust Hardening; feature assignee Manuel Lorenzo).

Related tickets: OSAC-7243 (RH build: remove standalone Envoy or
replace with OpenShift Service Mesh — linked from Juan Hernández's
comment on this epic), OSAC-5880 (MCP cross-replica shared request
and mutation limits, assignee Eran Cohen), OSAC-4384 (auth chain DoS,
unassigned).

Each task follows repo conventions: Jira **Task** type, Component
inherited from parent (**Core**), integration-test tier per
`docs/INTEGRATION-TESTING.md`.

Update in v4, following the Nov 4 epic discussion (Manuel Lorenzo,
Juan Hernández, Oved Ourfali): the Envoy local rate limit moves from
a deferred decision (old T10) into the MVP as an explicit interim
edge layer — Manuel endorsed starting there, and it is useful
upstream regardless of what OSAC-7243 decides for the Red Hat build.
The in-process pre-auth limiter stays the core MVP and the durable
control. A new finding from Manuel's zero-trust comment — no
NetworkPolicy prevents in-cluster traffic from bypassing the ingress
proxy — is recorded as its own linked item. Sequencing: the in-process
work has no dependency on OSAC-7243.

Owner codes:
- **FT** = fulfillment-service team (us — Ofer Bochan + team)
- **OPS** = osac-operator owners (Dan Manor, bkopilov)
- **MCP** = MCP server sub-team (Eran Cohen, Dan Manor)
- **INST** = osac-installer team (Linoy Hadad, Ori Amizur)
- **CPX** = console-proxy server owners (Juan Hernández, Manuel Lorenzo)

## Phase 0 — Decision record (deliverable BEFORE any implementation)

The Phase-0 output is a short decision record on the epic, covering:

1. **F11 MVP vs deferred hardening.** The epic text (F11) asks for
   source-IP keyed limiting early in the chain plus equivalent REST
   middleware. Post-auth per-tenant quotas, console-proxy session
   caps, and MCP limits are a hardening evolution beyond F11 —
   confirm with the feature assignee whether they are in this epic's
   committed scope or deferred. (Note: per-IP direction came from a
   direct discussion with Manuel, not from a ticket comment — the
   only on-ticket feedback so far is Juan's Envoy comment. Asking
   Manuel and Juan to review the decision record is a *proposed*
   step, not a mandatory joint sign-off.)
2. **Enforcement location per deployment variant, accounting for
   OSAC-7243.** Two layers, in order. First, the Envoy local rate
   limit in the ingress-proxy (Task E1) — chart-only work, endorsed
   by Manuel as the starting point, useful upstream regardless of
   7243's outcome. Second, the in-process per-IP limiter before
   txInterceptor (Task 2.1a) — the durable control that works in
   every build variant and covers paths that bypass the proxy.
   Neither layer depends on the other; the in-process work has no
   dependency on OSAC-7243 and is not blocked by it. What 7243
   decides only affects whether the Envoy layer exists in the Red
   Hat build.
3. **Trusted source-IP attribution and REST-to-gRPC accounting.**
   In-process per-IP requires the real client IP to survive the
   proxy hop (OpenBao/Vault `x_forwarded_for_authorized_addrs`-
   style trusted-proxy config). For the REST path (gateway dials
   grpc-server), distinct edge flood protection and application
   quotas can be intentional — the requirement is that **one logical
   quota is not accidentally charged twice**, and that every budget
   is documented. Do NOT prescribe "gRPC only" or a gateway
   service-account exemption until trusted client-IP propagation is
   proven and any proposed exemption is shown not to bypass
   protection.
4. **Local/per-replica budget semantics.** Both local Envoy and
   in-memory limiters scale as rate × replicas. Document as a known
   limit. MCP cross-replica identity quotas remain coordinated with
   OSAC-5880 (which explicitly disqualifies per-pod quotas for that
   surface) — link 4385 ↔ 5880 as Related.
5. **Defaults, failure behavior, validation evidence, and owners for
   unresolved decisions** — including OSAC-4384 coordination (rate
   limiting does not replace the tx-before-authn fix; 4384 is
   unassigned).
   - Defaults: propose starting rate/burst numbers as **provisional**
     values with stated workload assumptions and load-test criteria;
     unset = off. Do not present unmeasured values as production-safe.
   - Failure behavior: decide fail-open vs fail-closed for limiter
     errors (panic in the limiter, map contention, clock issues) —
     recommend fail-open with alerting for v1 (availability over
     strictness), recorded as a decision.
   - Coverage: integration-test evidence matrix per repo policy
     (suite path, command, real vs mocked boundary, gap Jira URLs).
6. **In-cluster bypass (from Manuel's zero-trust comment).** Nothing
   today prevents in-cluster traffic from reaching the fulfillment
   services directly, bypassing the ingress proxy — so proxy-level
   limiting alone never covers internal callers. Two outcomes: the
   in-process limiter (2.1a) is the layer that covers this, and the
   NetworkPolicy gap itself deserves its own ticket (see N1 in
   linked scope) since it is a pre-existing finding independent of
   rate limiting.

## Two-stage enforcement model (resolves the chain-position question)

Current grpc-server chain: panic → metrics → logging → validation →
tx (opens DB txn) → authn → authz → jit → refVal.

Stage     | Position                | Key             | Purpose
----------|-------------------------|-----------------|---------
Pre-auth  | Before txInterceptor    | source IP       | Flood protection (F11), no DB txn on rejection
Post-auth | After authn             | subject/tenant  | Abuse by authenticated callers (hardening, deferred pending Phase-0 item 1)

Anonymous regex endpoints (`Capabilities/`, `JsonWebKeySet/`,
`grpc.health.`) are keyed in the pre-auth stage with a separate,
higher bucket.

## MVP scope (F11-faithful)

### Task P1 — Proof of concept (both layers, before committing the design)

**Summary:** Prototype the two enforcement layers end to end and
validate behavior before full implementation

**Owner:** FT

**Background:** The Phase-0 record gains force with working
evidence. A throwaway POC on a dev/Kind cluster answers the behavior
questions cheaply, before tasks 1.1–2.1a harden the design into
production code.

**Description:**
- In-process: a minimal pre-auth interceptor with a naive limiter,
  wired first in the chain on a dev deployment. Confirm rejected
  requests open no DB transaction, anonymous endpoints behave, and
  Watch streams are limited at establishment only.
- Edge: the E1 Envoy filter on the same cluster with per-route
  stream exemption. Confirm console WebSocket and Watch streams
  survive a throttled default bucket.
- REST: confirm 429 + Retry-After reach a REST client through the
  gateway.
- Rough overhead measurement (latency p99 with and without the
  limiter) — indicative only, the real numbers come from S1.

**Acceptance criteria:** findings recorded on the Phase-0 decision
record; any behavior surprise turns into a plan change before 1.1
starts.

**Test tier:** N/A (throwaway evidence, not merged code).
**Dependencies:** none — can start immediately, in parallel with
Phase-0 drafting.

### Task S1 — Load and scale validation

**Summary:** Measure the limiter's cost and calibrate the provisional
defaults under production-like load

**Owner:** FT; QE support for the load rig

**Background:** Phase-0 item 5 requires defaults backed by workload
assumptions and load-test criteria. This task is where those criteria
get executed. Without it the defaults stay guesses and the perf cost
of the limiter is unknown.

**Description:**
- Load suite against a deployed stack with the limiter enabled:
  latency overhead (p50/p99) versus limiter disabled, at normal and
  flood rates.
- Memory footprint of per-key buckets under many distinct client
  keys (idle GC effectiveness), and the Envoy filter's overhead on
  the edge path.
- Throughput ceiling comparison: limiter off, edge only, in-process
  only, both — so the layered cost is known, not assumed.
- Output: measured numbers feeding the 4.1 default values, recorded
  with the workload assumptions on the epic.

**Acceptance criteria:** results documented; 4.1 defaults cite them;
no unexplained regression versus the limiter-disabled baseline.

**Test tier:** performance/load (FT rig, QE-assisted; not part of
the CI regression suite — run per release or on demand).
**Dependencies:** 2.1a, 3.1, E1 (all layers present to measure).

### Task E1 — Envoy local rate limit (interim edge layer)

**Summary:** Add Envoy local_ratelimit filter to the ingress-proxy as
the interim edge layer

**Owner:** FT; INST review for the chart change (Linoy Hadad, Ori
Amizur)

**Background / findings:**
- Manuel's Nov 4 comment endorses starting at the Envoy level:
  easy to implement, a positive first step.
- The external-api listener's HTTP filter chain is currently only
  `cors` → `router` (verified in
  `charts/service/templates/ingress-proxy/_config.yaml.tpl`), so this
  is chart-only work — no service code.
- Scope guard: this is the outer layer only. It does not cover
  in-cluster bypass (Manuel's zero-trust point, see Phase-0 item 6),
  it is keyed per replica not per tenant, and OSAC-7243 may remove
  standalone Envoy from the Red Hat build — so it is interim and
  upstream-first, not the answer to F11 by itself.

**Description:**
- Add `envoy.filters.http.local_ratelimit` to the external-api
  listener's filter chain, configurable via chart values, off by
  default.
- Per-route `typed_per_filter_config` for console WebSocket and Watch
  stream routes so long-lived streams are not throttled by the default
  bucket (same mechanism as the chart's existing CORS per-route
  config).
- Also apply to the REST gateway route with its own bucket.

**Acceptance criteria:**
- `helm template` renders with the filter on and off; stream routes
  carry the per-route exemption; installer CI green.

**Test tier:** chart render evidence + covered end-to-end by Task 4.3.
**Dependencies:** Phase-0 record only — can start in parallel with
1.1.

### Task 1.1 — Rate limiter core (internal/ratelimit package)

**Summary:** Implement reusable token-bucket rate limiter package

**Owner:** FT (implementer: Ofer Bochan)

**Background / findings:**
- No server-side rate limiting exists in the monorepo (verified by
  scan). `golang.org/x/time v0.15.0` is already an indirect dep.
- Package layout follows `internal/{auth, database, logging,
  metrics, recovery}` precedent.

**Description:**
- `fulfillment-service/internal/ratelimit`: `Limiter` interface
  `Allow(ctx, key, method) (Decision, error)` with
  `Allowed bool` + `RetryAfter` (grpc-ecosystem pluggable-Limiter
  pattern).
- Token bucket via `x/time/rate`; per-key lazy buckets with idle GC;
  concurrency-safe (benchmark under parallel Allow()).
- Pluggable key resolution; exempt-list support.
- Promote `x/time` to direct dependency.
- Fail-open behavior on internal error (per Phase-0 decision),
  with an error counter metric.

**Acceptance criteria:**
- Unit tests (allow/deny, retry-after, exempt, concurrency; `go test
  -race` clean), lint clean, benchmark committed.

**Test tier:** Unit. **Dependencies:** none.

### Task 1.2 — Error contract and observability

**Summary:** Define rate-limit error contract and metrics

**Owner:** FT

**Description:**
- gRPC: RESOURCE_EXHAUSTED + RetryInfo (retry-delay) error detail.
- REST: HTTP 429 + Retry-After.
- Metric `rate_limited_requests_total` (surface, method, result;
  bounded cardinality — no raw tenant label).
- Structured log on rejection.
- Document the REST↔gRPC accounting intent (Phase-0 item 3): one
  logical request must not consume the same quota twice.

**Acceptance criteria:**
- Unit tests at gRPC and REST mapping boundaries; metric verified in
  a component test.

**Test tier:** Unit + component. **Dependencies:** 1.1.

### Task 2.1a — Pre-auth per-source-IP interceptor (grpc-server)

**Summary:** Add pre-auth per-IP rate-limit interceptor to grpc-server

**Owner:** FT

**Background / findings:**
- Must sit BEFORE txInterceptor so rejected requests open no DB
  transaction (F11; overlaps OSAC-4384's chain-reorder concern).
- Keying on source IP at this position requires trusted client-IP
  propagation from the ingress-proxy (the grpc-server otherwise sees
  only the proxy pod IP). Implement OpenBao/Vault-style
  trusted-proxy handling: explicit allowlist of proxy addresses,
  XFF parsing, reject/untrust forwarded headers from non-allowlisted
  sources.
- OSAC-7243 may remove standalone Envoy from the RH build — this
  in-process approach is portable across build variants and is the
  default; the Envoy local-limit alternative is a candidate for
  upstream builds only (see T10).
- Stream chain gets the limiter first as well; Watch streams limited
  at establishment, not message flow.

**Description:**
- Unary + stream interceptor, first in both chains, IP-keyed, using
  1.1 Limiter; anonymous-regex endpoints in a separate bucket.
- Trusted-proxy client-IP resolution (config flag for the proxy
  CIDR allowlist; default trusts nothing → if unconfigured, falls
  back to connection peer IP).
- Exempt internal callers per Phase-0 (CSI driver, controller,
  event-publisher, reconciler).

**Acceptance criteria:**
- Unit tests: enforcement, exempt paths, anonymous bucket, XFF trust
  rules (trusted vs untrusted vs absent).
- Integration test: exceeded limit → RESOURCE_EXHAUSTED + RetryInfo,
  no DB txn opened.

**Test tier:** Unit + component-integration (grpc boundary).
**Dependencies:** 1.1, 1.2.

### Task 3.1 — REST 429 mapping

**Summary:** Ensure rate-limit errors map correctly through the REST
gateway

**Owner:** FT; review sign-off from REST gateway owners (Daniel Erez,
Riccardo Piccoli)

**Background / findings:**
- REST gateway dials grpc-server. grpc-gateway maps
  RESOURCE_EXHAUSTED → 429 by default; RetryInfo → Retry-After must
  be verified to propagate.
- Per Phase-0 item 3: do not add independent gateway-side limiting
  until the accounting question is decided — the default single
  enforcement point is grpc-server; any gateway-level budget must be
  a documented, distinct quota.

**Description:**
- Verify/fix 429 + Retry-After propagation through grpc-gateway.
- JWKS route uses the anonymous pre-auth bucket (server-side).
- Document the chosen accounting model.

**Acceptance criteria:**
- Integration test: exceeding limit via REST returns 429 with
  Retry-After; no double-charging of a single logical quota.

**Test tier:** Component-integration (REST boundary).
**Dependencies:** 1.2, 2.1a.

### Task 4.1 — Helm values and configuration flags

**Summary:** Expose rate-limit configuration via flags and Helm values

**Owner:** FT; INST coordination for installer values (Linoy Hadad,
Ori Amizur)

**Description:**
- Flags per surface (enable, rate, burst, exempt list, trusted-proxy
  CIDR) following the GrpcKeepaliveConfigFromFlags pattern; unset =
  off.
- Provisional default numbers documented WITH workload assumptions
  and load-test criteria (Phase-0 item 5) — explicitly provisional,
  not production-safe claims.
- Chart values (fulfillment-service + osac-installer; read the
  Enclave Wizard pipeline doc before touching installer schema).

**Acceptance criteria:**
- `helm template` renders with limits set/unset; installer CI green.

**Test tier:** N/A (chart render evidence).
**Dependencies:** 2.1a, 3.1.

### Task 4.2 — Documentation

**Summary:** Document rate-limiting behavior and configuration

**Owner:** FT

**Description:**
- Architecture + admin guide: two-stage model, trusted-proxy IP
  attribution, exemption policy, error contract, provisional
  defaults and their assumptions, per-replica semantics (rate ×
  replicas known limit), failure behavior (fail-open).
- Client-facing note: 429/Retry-After semantics for osac-ui, CLI,
  and public REST clients (retry guidance).
- Update error-mapping docs and `docs/agent-context/` review
  patterns.

**Acceptance criteria:** merged in the same train as 4.1.
**Dependencies:** 4.1.

### Task 4.3 — E2E rate-limit journey (QE)

**Summary:** Deployed single-client throttle and recovery journey

**Owner:** QE (test authored with FT review)

**Description:**
- Deployed stack with a low limit set via the 4.1 Helm values.
- One client hammers a public API route past the limit; expect 429
  with Retry-After while the health endpoint keeps answering 200.
- After the retry delay, the same client succeeds again.
- Not covered, recorded on purpose: multi-source-IP traffic. Each
  real client is a single source IP, so per-user isolation is proven
  at the unit tier (key derivation) instead.

**Acceptance criteria:** journey green in `tests/e2e`, case IDs
linked from this task.
**Dependencies:** 3.1, 4.1.

## Deferred / linked scope

### Task N1 — In-cluster bypass NetworkPolicy (linked finding, own ticket)

**Summary:** File and track the missing NetworkPolicy that allows
in-cluster traffic to bypass the ingress proxy

**Owner:** to assign — raised by Manuel's Nov 4 comment, pre-existing
and independent of rate limiting. Our role: file the ticket (finding:
fulfillment-internal-api / fulfillment-api services are reachable
from inside the cluster without going through the ingress-proxy; no
NetworkPolicy restricts this), link it to this epic and to OSAC-4382,
and let the platform owners decide the policy. Rate limiting does not
wait on it: the in-process limiter covers direct traffic regardless.

### Task 2.1b — Post-auth per-tenant quotas (deferred pending Phase-0 item 1)

**Summary:** Per-tenant (authenticated subject) rate limiting after
authn
**Owner:** FT. **Status:** deferred — in epic scope only if the
feature assignee confirms hardening beyond F11 is committed here.
Implementation mirrors 2.1a position after authn, tenant/subject key.

### Task 2.2 — console-proxy session guard (stretch, pending Phase-0)

**Summary:** Per-tenant concurrent console session cap + connect-rate
limit at stream establishment
**Owner:** CPX (Juan Hernández / Manuel Lorenzo). **Status:**
stretch — real resource-exhaustion vector (unbounded VNC/serial
sessions), but beyond F11; requires CPX review.
**Dependencies:** 1.1, 1.2 (if committed).

### Task 3.2 — MCP per-pod interim limits (linked to OSAC-5880)

**Summary:** Coordinate MCP rate limiting with OSAC-5880
**Owner:** MCP (Eran Cohen — 5880 assignee). **Status:** linked, not
duplicated. OSAC-5880 requires aggregate cross-replica subject/
tenant quotas and explicitly disqualifies per-pod quotas for that
surface. Our role: link 4385 ↔ 5880 as Related; optionally document
a per-pod interim behavior; cross-replica identity quotas belong to
5880 / its design work.

### Task T9 — Operator fulfillment-client audit (audit-first)

**Summary:** Audit osac-operator's fulfillment gRPC client for
RESOURCE_EXHAUSTED handling; implement only if a gap is found

**Background / correction:** `RateLimitError` in
`osac-operator/pkg/provisioning` is produced after provider/AAP
provision/deprovision calls to drive requeue delays — it is NOT
evidence of the fulfillment gRPC client's retry contract. No hard
compatibility constraint exists today.

**Owner:** OPS (Dan Manor / bkopilov). **Description:** audit whether
the operator's fulfillment gRPC client paths can receive
RESOURCE_EXHAUSTED once limits tighten, and whether they requeue
with backoff; implementation work only if the audit finds a gap.
**Dependencies:** 1.2 (contract), 2.1a.

### Task T10 — OSAC-7243 contingency tracking

**Summary:** Track what OSAC-7243 decides for the ingress and its
effect on the Envoy edge layer

**Owner:** FT (tracking only)
**Description:** The Envoy local rate limit is now MVP Task E1. What
remains here is tracking: OSAC-7243 may remove standalone Envoy from
the Red Hat build, in which case the E1 layer exists upstream only
and the Red Hat build relies on the in-process limiter (2.1a) plus
whatever platform-managed ingress 7243 selects. When 7243's decision
record lands, record the per-deployment-variant enforcement matrix
(Phase-0 item 2) on this epic.
**Dependencies:** follows OSAC-7243's Phase 1; nothing in this epic
blocks on it.

## Testing plan (coverage matrix per docs/INTEGRATION-TESTING.md)

Tiers use the repo's canonical names. Each MVP task carries its rows
into its testing approach when decomposed.

### Task 1.1 — limiter core (Unit, DEV)

- Token bucket: admits N, rejects N+1, refills over time. The limiter
  takes an injected clock/time source; refill tests run on a fake clock
  so they cannot flake on a loaded CI runner.
- Key derivation: direct peer, trusted-proxy XFF (first untrusted hop),
  XFF from an untrusted peer ignored. Different keys land in different
  buckets — this is the whole per-user isolation proof, and it needs no
  deployed traffic.
- Exempt paths (health, reflection) bypass the bucket.
- Zero-value config = disabled, fails open.
- Suite: new `internal/ratelimit` package tests, `ginkgo run -r internal`.

### Task 1.2 — error contract (Unit, DEV)

- Rejected request maps to RESOURCE_EXHAUSTED with RetryInfo carrying
  the retry delay.
- Allowed/rejected counters increment against a real prometheus.Registry.

### Task 2.1a — pre-auth interceptor (Unit + component integration, DEV)

- Unit: interceptor with a mocked limiter. Rejects before the tx
  interceptor runs (no DB transaction on a rejected call), correct
  status, health/reflection pass through, stream variant matches unary.
- Component integration: extend the `register_servers_test.go` pattern
  (`itesting.NewServer` with production interceptor chain, real client
  over the wire). In-process clients share one peer, so per-key
  behavior goes through the trusted-proxy XFF path plus one direct-peer
  case. Real: gRPC server, interceptor chain, limiter (fake clock).
  Faked/omitted: authn (pre-auth by design), database on rejected calls.

### Task 3.1 — REST 429 mapping (Unit + component integration, DEV)

- Unit: grpc-gateway error handler maps RESOURCE_EXHAUSTED to HTTP 429
  with Retry-After derived from RetryInfo.
- Component integration: request through the real gateway mux against
  the limited server; assert 429, headers, body shape.

### Task 4.1 — Helm flags (component integration, DEV)

- `it-osac-installer`: render with the limiter enabled and disabled;
  disabled by default; values reach the deployment env.

### E2E (QE — own child task)

Single-client journey, matching the real scenario: one source hammering
a public API route above a low limit set via Helm values for the run.
Trigger: N rapid calls from one client. Observable: 429 responses with
Retry-After, and the health endpoint still answering 200 during the
throttling window. Pass bound: the same client recovers and succeeds
once the retry delay passes; zero non-429 failures.

Recorded gap (not covered, intentionally): no E2E sends traffic from
two real source IPs. Per-user isolation is proven at the unit tier via
key derivation; a deployed multi-IP run adds cost without adding
signal, since each real client is a single source IP anyway.

## Dependencies, sequencing, priorities

```text
P1-POC (immediately, evidence for Phase-0) ──┐
Phase-0 decision record ──> E1 (Envoy edge, chart-only)
                        └─> 1.1 ──> 1.2 ──> 2.1a ──> 3.1 ──> 4.1 ──> 4.2
                                                    └─> S1 (load/scale) ──> 4.1 defaults
2.1b, 2.2  (deferred/stretch, pending Phase-0 item 1)
3.2        (linked to 5880, no work here unless interim chosen)
T9         (audit after 1.2/2.1a)
T10        (tracks 7243, no dependency in either direction)
N1         (linked finding, file anytime)
```

**P1:** Phase-0 decision record (fed by the POC) → E1 + 1.1 → 1.2 → 2.1a
**P2:** 3.1, S1 (defaults must cite measured numbers), T9 audit
**P3:** 4.1, 4.2 (closing)
**Deferred:** 2.1b, 2.2, 3.2, T10-tracking

Rationale: the decision record precedes implementation by design,
and the POC feeds it evidence rather than assertions. E1 runs first
or in parallel — it is small, Manuel endorsed starting there, and it
buys outer-layer protection while the real work happens. 2.1a is the
reference implementation and carries the trusted-proxy plumbing that
every later stage depends on. S1 runs once all layers exist so the
4.1 defaults cite measurements instead of guesses. Nothing in the
MVP blocks on OSAC-7243.

## Cross-team coordination

| Team | Tasks | Interaction | When |
|---|---|---|---|
| FT (us) | P1-POC, E1, 1.1, 1.2, 2.1a, 3.1, S1, 4.1, 4.2 | — | POC immediately, rest after Phase-0 |
| Manuel (feature assignee) | Phase-0 record | review proposed (not mandatory sign-off) | Phase 0 |
| CPX (Juan H., Manuel L.) | 2.2 (stretch) | their surface; review if committed | post Phase-0 |
| REST owners (Daniel E., Riccardo P.) | 3.1 sign-off | review | after 2.1a |
| MCP (Eran C.) | 5880 coordination | link, align scope | Phase 0 |
| OPS (Dan M., bkopilov) | T9 audit | their client code | after 2.1a |
| INST (Linoy H., Ori A.) | E1 chart review, 4.1 values, 7243 tracking | chart change; values wiring; Envoy contingency | E1 early, rest end of MVP |

## Out of scope (record on epic)
- Envoy global rate-limit service (external ratelimit cluster).
- Distributed limiter (Redis/Postgres-backed) across replicas —
  aggregate cross-replica quotas for MCP are owned by OSAC-5880.
- Per-method weighted costs.
- OSAC-4384 (auth chain DoS) — sibling, unassigned; link only and
  flag ownership question. Rate limiting does not replace the
  tx-before-authn reorder.

## Draft reply for the epic (to Manuel's cost-benefit comment and
## Oved's sequencing question)

Replying to Manuel Lorenzo's cost-benefit question and Oved
Ourfali's sequencing question. The Juan reply from v3 was posted on
Nov 4; this replaces the older Phase-0 draft comment, which was
never posted.

Draft text:

---

Answering Manuel's cost-benefit question, and Oved's question about
sequencing with the Envoy work.

Our recommendation is both layers, in order:

1. The Envoy local rate limit first. It's chart-only work — the
   external-api listener's filter chain is just CORS and router
   today, so adding the local_ratelimit filter is a small change. It
   buys outer-layer protection quickly, which is what Manuel
   suggested starting with. We'd exempt the console WebSocket and
   Watch stream routes so long-lived streams are not throttled.
2. The in-process limiter in the grpc-server as the durable control.
   This is the part that satisfies F11 as written: it sits before
   the transaction interceptor, so rejected requests open no DB
   transaction, and it works the same in every build variant.

On the cost side of Manuel's question: the in-process limiter is a
real implementation effort — a reusable limiter package, the
interceptor with trusted client-IP propagation, REST 429 mapping,
and configuration. We have that broken into tasks and will share the
breakdown below.

Two things worth recording from the discussion so far:

- Manuel's zero-trust point cuts both ways. Envoy protects external
  traffic, but nothing stops in-cluster traffic from reaching the
  services directly — AFAIK there is no NetworkPolicy for that
  today. That is a pre-existing gap independent of rate limiting; we
  think it deserves its own ticket, and it's also the reason the
  in-process layer matters: it covers direct traffic regardless of
  proxy.
- For Oved's sequencing question: no need to wait for OSAC-7243.
  The Envoy config is useful upstream either way, and the in-process
  limiter doesn't depend on what proxy ends up in front. What 7243
  decides only affects whether the Envoy layer exists in the Red Hat
  build. For context, assisted-service serves its API through plain
  OpenShift ingress with no proxy of its own — one way Red Hat
  products do it — but that's context only; the ingress choice
  itself is OSAC-7243's to make and still open.

Task breakdown follows in the next comment.
