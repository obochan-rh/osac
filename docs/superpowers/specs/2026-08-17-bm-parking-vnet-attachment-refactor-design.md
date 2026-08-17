# BM Parking V-Net + Unified Port-Attachment Refactor — Design

Date: 2026-08-17
Status: Proposed (awaiting review)
Area: `osac-aap` netris roles/playbooks, `osac-operator`/`bare-metal-fulfillment-operator`, `osac-test-infra` (handoff)
Jira: OSAC-1448 (BMaaS network attachments)

## Problem

Bare-metal servers configure host-side networking entirely via DHCP, and we
want to keep it that way. But an unassigned server (belonging to no tenant) has
no V-Net, so it has no default gateway and no internet — which breaks the IPA
(Ironic Python Agent) during metal3 inspection/cleaning (e.g. it can't download
its rootfs). We can't hang the default gateway off the management/BMC NIC,
because then the host would have two DHCP default routes (mgmt + fabric) once a
tenant subnet is attached — a default-gateway race.

Solution: a Netris **parking V-Net** with DHCP + a default gateway + SNAT
(internet). Every server's **fabric NIC** starts attached to the parking V-Net,
so an idle server always has internet via the fabric NIC. When a tenant
provisions the server, its fabric port moves parking → tenant subnet's V-Net;
when the tenant releases it, the port moves back tenant → parking.

## Insight driving the refactor

Provision and deprovision are the **same primitive** — "move a fabric port from
one V-Net to another." Today the netris roles are Subnet-CR-centric and split by
tenant-attachment lifecycle:

- `create_network_attachment` takes a tenant `subnet_ref`, resolves its Subnet
  CR → tenant V-Net, and moves the port there — finding the *current* owner by
  **enumerating every V-Net with ports** (fragile, expensive).
- `delete_network_attachment` removes the port from the tenant V-Net and
  (optionally, for `parking_vnet_name`) adds it back to parking.

The parking V-Net exists **only in Netris** — it has no OSAC Subnet CR — so the
Subnet-CR-centric interface can't express "attach to parking" directly. That's
why the initial parking attach would otherwise be hand-rolled Netris API in
test-infra, duplicating the role's server→port→move logic.

## Goals

- One mechanism, keyed on a plain Netris **V-Net name**, used for every port
  move (parking↔tenant), by both operator flows and by test-infra's initial
  parking attach.
- Roles stop touching Subnet CRs; callers resolve `subnet_ref` → V-Net name.
- Drop the "enumerate every V-Net to find the current owner" logic: the caller
  now knows both the source and target V-Net.
- Deliver the parking lifecycle: idle→parking, provision→tenant, delete→parking.

## Non-goals

- Creating the parking V-Net / SNAT / DHCP and doing the initial per-server
  attach — that is a deployment prerequisite handled in **osac-test-infra**
  (separate session; see Handoff).
- Any change to host-side networking (stays DHCP-only).
- CaaS wiring — there is no active CaaS caller today (see Blast Radius); the
  generic V-Net-name interface naturally serves a future CaaS parking flow.

## Design

### Two generic mechanism roles (netris), keyed on V-Net name

```
create_network_attachment(host_name, logical_interface_name, target_vnet_name)
    → attach the server's fabric port to target_vnet_name (pure add; idempotent
      if already there)

delete_network_attachment(host_name, logical_interface_name, target_vnet_name)
    → detach the server's fabric port from target_vnet_name (pure remove;
      no-op if the port is not on that V-Net)
```

- Roles operate purely against Netris: resolve host → server → fabric port, then
  add-to / remove-from the named V-Net. **No Subnet CR lookup inside the roles.**
- `detach` is a **no-op when the port isn't on the named V-Net** (robust to
  retries / unexpected state), not a hard failure.
- The current-owner V-Net enumeration is removed.

### Every move = detach(from) then attach(to)

| Flow | Trigger | detach from | attach to |
|------|---------|-------------|-----------|
| Initial | test-infra bootstrap | — | `bm-parking` |
| Provision | BMI networking phase | `bm-parking` | tenant subnet's V-Net |
| Deprovision | BMI deletion | tenant subnet's V-Net | `bm-parking` |

### Callers resolve names

The two operator-facing playbooks keep their names (they map to the CR lifecycle
the operator drives) and become thin orchestrators:

- `playbook_osac_create_network_attachment.yml` (provision): for each attachment,
  resolve `item.subnetRef` → Subnet CR → tenant V-Net name; read parking name
  from `osac_job_vars.bm_parking_vnet`; run `delete_network_attachment(target=parking)`
  then `create_network_attachment(target=tenant V-Net)`.
- `playbook_osac_delete_network_attachment.yml` (deprovision): resolve
  `item.subnetRef` → tenant V-Net name; read parking name; run
  `delete_network_attachment(target=tenant V-Net)` then, when a parking name is
  set, `create_network_attachment(target=parking)`. With no parking name the
  port is left detached (unchanged default).

Subnet-CR resolution (by `osac.openshift.io/subnet-uuid` label → `metadata.name`
= V-Net name) moves from the roles into the playbooks.

### Operator changes

- `bare-metal-fulfillment-operator` supplies the parking V-Net name on **both**
  the networking (provision) and networking-deletion (deprovision) paths via
  `provisioning.WithBMParkingVNet(ctx, r.BMParkingVNet)` (so the provision
  playbook can detach-from-parking). `BMParkingVNet` comes from
  `OSAC_BM_PARKING_VNET` (already added).
- `osac-operator/pkg/provisioning` already emits `osac_job_vars.bm_parking_vnet`
  when set (already added).
- The operator still passes the tenant `subnet_ref` via the CR
  (`resource.spec.networkAttachments[].subnetRef`); the playbook resolves it.

### Test-infra reuse (Handoff)

The initial parking attach becomes: for each registered server, call
`create_network_attachment(host_name, logical_interface_name=eth9,
target_vnet_name=bm-parking)` — the **same role** as provisioning, no hand-rolled
Netris API. Parking V-Net + SNAT + DHCP creation remains test-infra's job. The
parking V-Net name must equal the operator's `OSAC_BM_PARKING_VNET` (`bm-parking`).

## Blast Radius (audit)

- Only the **netris** strategy implements `create/delete_network_attachment`
  tasks (no other `osac.templates.*` strategy has them).
- The only callers are `playbook_osac_create_network_attachment.yml`,
  `playbook_osac_delete_network_attachment.yml`, the config-as-code job-template
  registration, and the netris `meta/argument_specs.yaml`.
- **No active CaaS caller** (`agentless_net`, `manage_agents`, `ci` reference
  neither `network_attachment` nor `parking_vnet`). The CaaS-parking mentions in
  the role are comments, not wiring.
- Therefore the interface change (`subnet_ref` → `target_vnet_name`) is
  **BMaaS-only** in practice, and preserves generic semantics for a future CaaS
  parking flow.

## Files to change

`osac-aap`:
- `collections/.../netris/tasks/create_network_attachment.yaml` — target a V-Net
  name; pure attach; drop Subnet-CR lookup and current-owner enumeration.
- `collections/.../netris/tasks/delete_network_attachment.yaml` — target a V-Net
  name; pure detach (no-op if absent); drop Subnet-CR lookup and parking-add
  (parking-add is now a `create_network_attachment` call from the playbook).
- `collections/.../netris/meta/argument_specs.yaml` — update role arg specs.
- `playbook_osac_create_network_attachment.yml` — resolve Subnet CR → V-Net name;
  detach(parking) + attach(tenant).
- `playbook_osac_delete_network_attachment.yml` — resolve Subnet CR → V-Net name;
  detach(tenant) + attach(parking when set). Supersedes the `3e6046cd` playbook
  edit.

`bare-metal-fulfillment-operator`:
- `baremetalinstance_networking.go` — set `WithBMParkingVNet` on the provision
  path too (deprovision already done).

(No change to config-as-code job templates or the operator env/config beyond the
above.)

## Testing

- osac-operator provisioning: `bm_parking_vnet` extra-var emission (done).
- bmf: provision and deprovision networking paths set the parking name in ctx.
- Ansible: `yamllint` + YAML parse (EE ansible-lint is unavailable locally; CI
  covers the rest).
- E2E on the lab: create BMI → port moves `bm-parking`→tenant; delete BMI → port
  returns to `bm-parking` (verify in Netris); a re-inspection then has internet.

## Risks / mitigations

- **Momentary detached window** between detach and attach — same as today's
  remove-then-add; acceptable.
- **Provision assumes the port is on parking** — detach(parking) is a no-op if
  not, and attach(tenant) is idempotent, so re-runs and unexpected states are
  safe.
- **Shared-role change** — mitigated by the audit: no active non-BMaaS caller.

## Delivery

- bmf-operator image (provision-path parking plumbing + shared pkg).
- osac-aap role/playbook changes → AAP project sync.
- osac-operator image unaffected (bmf dispatches these jobs).
- test-infra: parking V-Net/SNAT/DHCP + initial attach (separate session).
