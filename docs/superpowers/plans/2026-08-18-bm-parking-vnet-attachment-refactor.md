# BM Parking V-Net + Unified Port-Attachment Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the netris `create_network_attachment`/`delete_network_attachment` roles into generic V-Net-name-keyed port-move primitives (attach / detach) and orchestrate every fabric-port move as detach(from)+attach(to), so provision (parking→tenant), deprovision (tenant→parking), and test-infra's initial parking attach all share one code path.

**Architecture:** Two netris roles become pure Netris port movers keyed on a plain V-Net *name*: `create_network_attachment` attaches the server's fabric port to `target_vnet_name`; `delete_network_attachment` detaches it from `target_vnet_name`. A shared task file resolves the target V-Net + the server port once. The operator-facing playbooks resolve the tenant `subnet_ref`→Subnet-CR→V-Net name, read the parking V-Net name from `osac_job_vars.bm_parking_vnet`, and run detach-then-attach. The current-owner V-Net enumeration is removed. The BMF operator supplies the parking name on both the provision and deprovision paths.

**Tech Stack:** Ansible (netris.controller collection, kubernetes.core), Go (controller-runtime), Netris REST API v2.

**Spec:** `osac/docs/superpowers/specs/2026-08-17-bm-parking-vnet-attachment-refactor-design.md`

## Global Constraints

- Netris V-Net PUT must send the full V-Net object with a modified `ports` list (`_vnet | combine({'ports': ...})`); partial PUT is undocumented — copied verbatim from the existing roles.
- All Netris GETs send `Cache-Control: no-cache` and `Pragma: no-cache` headers (ETag 304 avoidance).
- All Netris `ansible.builtin.uri` calls set `force: true`, `timeout: "{{ netris_timeout | default(30) }}"`, `validate_certs: "{{ netris_validate_certs | default(true) }}"`, and `no_log: true` on credentialed calls.
- A port is added to a V-Net as `{'id': <port_id>, 'state': 'active', 'accessMode': true}`.
- `detach` is a **no-op** (debug message, no failure) when the target V-Net is not found or the port is not on it. `attach` **fails** when the target V-Net or the server port cannot be resolved.
- Ansible role/task files live under `osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/`.
- Go: run `make lint test` in the affected component before committing; commits use `-s` (DCO) and an `Assisted-by: Claude Code <noreply@anthropic.com>` trailer.
- Parking V-Net name contract value: `bm-parking` (operator `OSAC_BM_PARKING_VNET`).

---

### Task 1: Shared attachment-context resolution task

Resolves, from `na_host_name` + `na_logical_interface` + `na_target_vnet_name`, the full target V-Net (`_target_vnet`, or `none` if the named V-Net doesn't exist) and the server's fabric port (`_target_port`, or `none` if the server/port isn't found). Both roles include this, eliminating duplication and the current-owner enumeration.

**Files:**
- Create: `osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/_resolve_attachment_context.yaml`

**Interfaces:**
- Consumes: facts `na_host_name`, `na_logical_interface`, `na_target_vnet_name`; vars `netris_controller_url`, `netris_session_cookie` (may be unset), `netris_timeout`, `netris_validate_certs`.
- Produces: facts `_target_vnet` (dict with `.id`, `.ports`, … or `none`), `_target_port` (dict with `.id` or `none`).

- [ ] **Step 1: Write the shared task file**

```yaml
---
# Shared resolution for netris port attach/detach. Given a host name, a logical
# interface, and a target V-Net *name*, resolves:
#   _target_vnet  - full V-Net object (with ports), or none if the V-Net is absent
#   _target_port  - the server's port for the interface, or none if absent
# No Subnet CR lookup and no current-owner enumeration here — callers pass a
# plain Netris V-Net name.

- name: Ensure Netris auth
  ansible.builtin.include_role:
    name: netris.controller.auth
  when: netris_session_cookie is not defined

- name: Get existing V-Nets
  ansible.builtin.uri:
    force: true
    url: "{{ netris_controller_url }}/api/v2/vnet"
    method: GET
    headers:
      Cookie: "connect.sid={{ netris_session_cookie }}"
      Cache-Control: "no-cache"
      Pragma: "no-cache"
    return_content: true
    status_code: 200
    timeout: "{{ netris_timeout | default(30) }}"
    validate_certs: "{{ netris_validate_certs | default(true) }}"
  register: _rac_vnet_list_resp
  no_log: true

- name: Find target V-Net summary by name
  ansible.builtin.set_fact:
    _rac_vnet_summary: >-
      {{ (_rac_vnet_list_resp.json.data | default([]))
         | selectattr('name', 'equalto', na_target_vnet_name)
         | list | first | default(none) }}

- name: Reset resolved facts
  ansible.builtin.set_fact:
    _target_vnet: "{{ none }}"
    _target_port: "{{ none }}"

- name: Fetch target V-Net details (includes ports)
  ansible.builtin.uri:
    force: true
    url: "{{ netris_controller_url }}/api/v2/vnet/{{ _rac_vnet_summary.id }}"
    method: GET
    headers:
      Cookie: "connect.sid={{ netris_session_cookie }}"
      Cache-Control: "no-cache"
      Pragma: "no-cache"
    return_content: true
    status_code: 200
    timeout: "{{ netris_timeout | default(30) }}"
    validate_certs: "{{ netris_validate_certs | default(true) }}"
  register: _rac_vnet_resp
  when: _rac_vnet_summary is not none
  no_log: true

- name: Set target V-Net fact
  ansible.builtin.set_fact:
    _target_vnet: "{{ _rac_vnet_resp.json.data }}"
  when: _rac_vnet_summary is not none

- name: Get Netris inventory servers
  ansible.builtin.uri:
    force: true
    url: "{{ netris_controller_url }}/api/v2/hw?type=server"
    method: GET
    headers:
      Cookie: "connect.sid={{ netris_session_cookie }}"
      Cache-Control: "no-cache"
      Pragma: "no-cache"
    return_content: true
    status_code: 200
    timeout: "{{ netris_timeout | default(30) }}"
    validate_certs: "{{ netris_validate_certs | default(true) }}"
  register: _rac_server_list_resp
  no_log: true

- name: Find server by host_name
  ansible.builtin.set_fact:
    _rac_server: >-
      {{ (_rac_server_list_resp.json.data | default([]))
         | selectattr('name', 'equalto', na_host_name)
         | list | first | default(none) }}

- name: Get server ports
  ansible.builtin.uri:
    force: true
    url: "{{ netris_controller_url }}/api/v2/ports?switchID={{ _rac_server.id }}"
    method: GET
    headers:
      Cookie: "connect.sid={{ netris_session_cookie }}"
      Cache-Control: "no-cache"
      Pragma: "no-cache"
    return_content: true
    status_code: 200
    timeout: "{{ netris_timeout | default(30) }}"
    validate_certs: "{{ netris_validate_certs | default(true) }}"
  register: _rac_ports_resp
  when: _rac_server is not none
  no_log: true

- name: Find port matching interface name
  ansible.builtin.set_fact:
    _target_port: >-
      {{ ((_rac_ports_resp.json.data.data | default(_rac_ports_resp.json.data)) | default([]))
         | selectattr('port', 'equalto', na_logical_interface)
         | list | first | default(none) }}
  when: _rac_server is not none
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" collections/ansible_collections/osac/templates/roles/netris/tasks/_resolve_attachment_context.yaml && uv run python -c "import yaml; yaml.safe_load(open('collections/ansible_collections/osac/templates/roles/netris/tasks/_resolve_attachment_context.yaml')); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 3: Commit**

```bash
git add osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/_resolve_attachment_context.yaml
git commit -s -m "OSAC-1448: add shared netris attachment-context resolution task

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Refactor create_network_attachment into a pure attach

Replace the whole file: resolve context via Task 1, fail if V-Net/port unresolved, add the port to the target V-Net (idempotent).

**Files:**
- Modify (replace contents): `osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml`

**Interfaces:**
- Consumes: `network_attachment` dict with `host_name`, `logical_interface_name`, `target_vnet_name`; Task 1's `_target_vnet`, `_target_port`.
- Produces: fact `network_attachment_already_existed` (bool); the port is on `target_vnet_name`.

- [ ] **Step 1: Replace the file contents**

```yaml
---
# Attach a server's fabric port to a Netris V-Net (by name). Pure add:
# idempotent if the port is already on the target V-Net. Fails if the target
# V-Net or the server port cannot be resolved.

- name: Extract attach configuration
  ansible.builtin.set_fact:
    na_host_name: "{{ network_attachment.host_name }}"
    na_logical_interface: "{{ network_attachment.logical_interface_name }}"
    na_target_vnet_name: "{{ network_attachment.target_vnet_name }}"

- name: Resolve target V-Net and server port
  ansible.builtin.include_tasks: _resolve_attachment_context.yaml

- name: Fail if target V-Net not found
  ansible.builtin.fail:
    msg: >-
      V-Net '{{ na_target_vnet_name }}' not found in Netris controller.
  when: _target_vnet is none

- name: Fail if server port not found
  ansible.builtin.fail:
    msg: >-
      Port '{{ na_logical_interface }}' not found on server '{{ na_host_name }}'
      (ensure the host is registered in Netris and the interface name is correct).
  when: _target_port is none

- name: Check if port is already on the target V-Net
  ansible.builtin.set_fact:
    network_attachment_already_existed: >-
      {{ (_target_vnet.ports | default([]))
         | selectattr('id', 'equalto', _target_port.id)
         | list | length > 0 }}

- name: Build updated ports list with the target port
  ansible.builtin.set_fact:
    _updated_ports: >-
      {{ (_target_vnet.ports | default([]))
         + [{'id': _target_port.id, 'state': 'active', 'accessMode': true}] }}
  when: not (network_attachment_already_existed | bool)

- name: Add port to target V-Net
  ansible.builtin.uri:
    force: true
    url: "{{ netris_controller_url }}/api/v2/vnet/{{ _target_vnet.id }}"
    method: PUT
    headers:
      Cookie: "connect.sid={{ netris_session_cookie }}"
      Content-Type: "application/json"
    body_format: json
    body: "{{ _target_vnet | combine({'ports': _updated_ports}) }}"
    return_content: true
    status_code: [200, 201]
    timeout: "{{ netris_timeout | default(30) }}"
    validate_certs: "{{ netris_validate_certs | default(true) }}"
  when: not (network_attachment_already_existed | bool)
  no_log: true

- name: Display attach result
  ansible.builtin.debug:
    msg: >-
      Attach host '{{ na_host_name }}' interface '{{ na_logical_interface }}'
      to V-Net '{{ na_target_vnet_name }}'
      {{ (network_attachment_already_existed | bool) | ternary('already present', 'done') }}
      (port ID: {{ _target_port.id }}, V-Net ID: {{ _target_vnet.id }})
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml && uv run python -c "import yaml; yaml.safe_load(open('collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml')); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 3: Commit**

```bash
git add osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml
git commit -s -m "OSAC-1448: make create_network_attachment a generic attach-to-vnet-by-name

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: Refactor delete_network_attachment into a pure detach

Replace the whole file: resolve context via Task 1; no-op if V-Net/port unresolved or port not on the V-Net; else remove the port from the target V-Net.

**Files:**
- Modify (replace contents): `osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml`

**Interfaces:**
- Consumes: `network_attachment` dict with `host_name`, `logical_interface_name`, `target_vnet_name`; Task 1's `_target_vnet`, `_target_port`.
- Produces: the port is not on `target_vnet_name`.

- [ ] **Step 1: Replace the file contents**

```yaml
---
# Detach a server's fabric port from a Netris V-Net (by name). Pure remove:
# no-op if the V-Net is absent, the server port is unresolved, or the port is
# not on the V-Net.

- name: Extract detach configuration
  ansible.builtin.set_fact:
    na_host_name: "{{ network_attachment.host_name }}"
    na_logical_interface: "{{ network_attachment.logical_interface_name }}"
    na_target_vnet_name: "{{ network_attachment.target_vnet_name }}"

- name: Resolve target V-Net and server port
  ansible.builtin.include_tasks: _resolve_attachment_context.yaml

- name: Skip detach when nothing to remove
  ansible.builtin.debug:
    msg: >-
      Detach host '{{ na_host_name }}' interface '{{ na_logical_interface }}'
      from V-Net '{{ na_target_vnet_name }}' — nothing to do
      (V-Net or port not found).
  when: _target_vnet is none or _target_port is none

- name: Detach the port from the V-Net
  when:
    - _target_vnet is not none
    - _target_port is not none
  block:
    - name: Determine whether the port is on the V-Net
      ansible.builtin.set_fact:
        _port_on_vnet: >-
          {{ (_target_vnet.ports | default([]))
             | selectattr('id', 'equalto', _target_port.id)
             | list | length > 0 }}

    - name: Build ports list without the target port
      ansible.builtin.set_fact:
        _updated_ports: >-
          {{ (_target_vnet.ports | default([]))
             | rejectattr('id', 'equalto', _target_port.id)
             | list }}
      when: _port_on_vnet | bool

    - name: Remove port from V-Net
      ansible.builtin.uri:
        force: true
        url: "{{ netris_controller_url }}/api/v2/vnet/{{ _target_vnet.id }}"
        method: PUT
        headers:
          Cookie: "connect.sid={{ netris_session_cookie }}"
          Content-Type: "application/json"
        body_format: json
        body: "{{ _target_vnet | combine({'ports': _updated_ports}) }}"
        return_content: true
        status_code: [200, 201]
        timeout: "{{ netris_timeout | default(30) }}"
        validate_certs: "{{ netris_validate_certs | default(true) }}"
      when: _port_on_vnet | bool
      no_log: true

    - name: Display detach result
      ansible.builtin.debug:
        msg: >-
          Detach host '{{ na_host_name }}' interface '{{ na_logical_interface }}'
          from V-Net '{{ na_target_vnet_name }}'
          {{ (_port_on_vnet | bool) | ternary('done', 'was not attached') }}
          (port ID: {{ _target_port.id }}, V-Net ID: {{ _target_vnet.id }})
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml && uv run python -c "import yaml; yaml.safe_load(open('collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml')); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 3: Commit**

```bash
git add osac-aap/collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml
git commit -s -m "OSAC-1448: make delete_network_attachment a generic detach-from-vnet-by-name

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: Update the netris role argument_specs

Bring the role's documented arguments in line with the new `target_vnet_name` interface (the roles no longer take `subnet_ref`/`parking_vnet_name`).

**Files:**
- Modify: `osac-aap/collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: documented entrypoints for `create_network_attachment` / `delete_network_attachment` describing `network_attachment.{host_name, logical_interface_name, target_vnet_name}`.

- [ ] **Step 1: Inspect the current entries**

Run:
```bash
cd osac-aap && grep -n "network_attachment\|subnet_ref\|parking_vnet_name\|target_vnet_name\|logical_interface_name\|host_name" collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml
```
Expected: shows the existing `create_network_attachment` / `delete_network_attachment` argument entries (with `subnet_ref` / `parking_vnet_name`).

- [ ] **Step 2: Edit the two entrypoints**

For the `create_network_attachment` and `delete_network_attachment` entries, replace the `network_attachment` option schema so its documented sub-options are exactly `host_name` (str, required), `logical_interface_name` (str, required), and `target_vnet_name` (str, required). Remove any `subnet_ref` and `parking_vnet_name` sub-options. Match the file's existing indentation/style. Example shape for each entrypoint's option:

```yaml
    network_attachment:
      type: dict
      required: true
      description: Fabric port + target V-Net for the move.
      options:
        host_name:
          type: str
          required: true
          description: Netris server (host) name.
        logical_interface_name:
          type: str
          required: true
          description: Server port / logical interface name (e.g. eth9).
        target_vnet_name:
          type: str
          required: true
          description: Netris V-Net name to attach to / detach from.
```

- [ ] **Step 3: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml && uv run python -c "import yaml; yaml.safe_load(open('collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml')); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 4: Commit**

```bash
git add osac-aap/collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml
git commit -s -m "OSAC-1448: update netris attachment role arg specs to target_vnet_name

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Rewrite the provision playbook (detach parking + attach tenant)

Per attachment: resolve the tenant `subnetRef`→Subnet-CR→V-Net name; detach the port from the parking V-Net (when a parking name is supplied); attach it to the tenant V-Net.

**Files:**
- Modify (replace `vars`/`tasks`): `osac-aap/playbook_osac_create_network_attachment.yml`

**Interfaces:**
- Consumes: `osac_job_vars.resource` (BMI CR), `osac_job_vars.bm_parking_vnet` (may be empty); the netris `create_network_attachment` / `delete_network_attachment` roles (Tasks 2–3).
- Produces: each fabric port moved from parking to its tenant V-Net.

- [ ] **Step 1: Replace the file contents**

```yaml
---
- name: Create network attachments
  hosts: localhost
  gather_facts: false

  vars:
    resource: "{{ osac_job_vars.resource }}"
    resource_name: "{{ resource.metadata.name }}"
    implementation_strategy: >-
      {{ resource.metadata.annotations
         ['osac.openshift.io/implementation-strategy']
         | default('netris', true) }}
    network_attachments: "{{ resource.spec.networkAttachments | default([]) }}"
    parking_vnet: "{{ osac_job_vars.bm_parking_vnet | default('', true) }}"
    host_name: >-
      {{ (resource.spec.externalHostName
         | default(resource.spec.externalHostID, true)).split('/')[-1] }}

  pre_tasks:
    - name: Show resource metadata
      ansible.builtin.debug:
        var: resource.metadata

    - name: Fail if no network attachments
      ansible.builtin.fail:
        msg: "No networkAttachments defined on {{ resource_name }}"
      when: network_attachments | length == 0

  tasks:
    - name: Resolve tenant V-Net name for each attachment
      kubernetes.core.k8s_info:
        api_version: osac.openshift.io/v1alpha1
        kind: Subnet
        label_selectors:
          - "osac.openshift.io/subnet-uuid={{ item.subnetRef }}"
      register: _subnet_lookups
      loop: "{{ network_attachments }}"
      loop_control:
        label: "{{ item.subnetRef }}"

    - name: Build resolved attachment list (interface + tenant V-Net name)
      ansible.builtin.set_fact:
        _resolved_attachments: >-
          {{ _resolved_attachments | default([]) + [{
               'interface': item.item.interface,
               'subnet_ref': item.item.subnetRef,
               'tenant_vnet_name': (item.resources[0].metadata.name
                                    if (item.resources | length > 0) else '')
             }] }}
      loop: "{{ _subnet_lookups.results }}"
      loop_control:
        label: "{{ item.item.subnetRef }}"

    - name: Fail if any Subnet CR is missing
      ansible.builtin.fail:
        msg: >-
          Subnet CR not found for subnetRef(s):
          {{ _resolved_attachments | selectattr('tenant_vnet_name', 'equalto', '')
             | map(attribute='subnet_ref') | list }}
      when: _resolved_attachments | selectattr('tenant_vnet_name', 'equalto', '') | list | length > 0

    - name: Detach each port from the parking V-Net
      ansible.builtin.include_role:
        name: "osac.templates.{{ implementation_strategy }}"
        tasks_from: delete_network_attachment
      vars:
        network_attachment:
          host_name: "{{ host_name }}"
          logical_interface_name: "{{ item.interface }}"
          target_vnet_name: "{{ parking_vnet }}"
      loop: "{{ _resolved_attachments }}"
      loop_control:
        label: "{{ item.interface | default('default') }} ← {{ parking_vnet }}"
      when: parking_vnet | length > 0

    - name: Attach each port to its tenant V-Net
      ansible.builtin.include_role:
        name: "osac.templates.{{ implementation_strategy }}"
        tasks_from: create_network_attachment
      vars:
        network_attachment:
          host_name: "{{ host_name }}"
          logical_interface_name: "{{ item.interface }}"
          target_vnet_name: "{{ item.tenant_vnet_name }}"
      loop: "{{ _resolved_attachments }}"
      loop_control:
        label: "{{ item.interface | default('default') }} → {{ item.tenant_vnet_name }}"
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" playbook_osac_create_network_attachment.yml && uv run python -c "import yaml; list(yaml.safe_load_all(open('playbook_osac_create_network_attachment.yml'))); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 3: Commit**

```bash
git add osac-aap/playbook_osac_create_network_attachment.yml
git commit -s -m "OSAC-1448: provision playbook detaches from parking then attaches to tenant V-Net

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: Rewrite the deprovision playbook (detach tenant + attach parking)

Per attachment: resolve the tenant V-Net name; detach the port from it; attach it to the parking V-Net (when a parking name is supplied, else leave detached). Supersedes the `3e6046cd` playbook edit.

**Files:**
- Modify (replace `vars`/`tasks`): `osac-aap/playbook_osac_delete_network_attachment.yml`

**Interfaces:**
- Consumes: `osac_job_vars.resource` (BMI CR), `osac_job_vars.bm_parking_vnet` (may be empty); the netris `create_network_attachment` / `delete_network_attachment` roles (Tasks 2–3).
- Produces: each fabric port moved from its tenant V-Net back to parking (or left detached).

- [ ] **Step 1: Replace the file contents**

```yaml
---
- name: Delete network attachments
  hosts: localhost
  gather_facts: false

  vars:
    resource: "{{ osac_job_vars.resource }}"
    resource_name: "{{ resource.metadata.name }}"
    implementation_strategy: >-
      {{ resource.metadata.annotations
         ['osac.openshift.io/implementation-strategy']
         | default('netris', true) }}
    network_attachments: "{{ resource.spec.networkAttachments | default([]) }}"
    parking_vnet: "{{ osac_job_vars.bm_parking_vnet | default('', true) }}"
    host_name: >-
      {{ (resource.spec.externalHostName
         | default(resource.spec.externalHostID, true)).split('/')[-1] }}

  pre_tasks:
    - name: Show resource metadata
      ansible.builtin.debug:
        var: resource.metadata

  tasks:
    - name: Resolve tenant V-Net name for each attachment
      kubernetes.core.k8s_info:
        api_version: osac.openshift.io/v1alpha1
        kind: Subnet
        label_selectors:
          - "osac.openshift.io/subnet-uuid={{ item.subnetRef }}"
      register: _subnet_lookups
      loop: "{{ network_attachments }}"
      loop_control:
        label: "{{ item.subnetRef }}"
      when: network_attachments | length > 0

    - name: Build resolved attachment list (interface + tenant V-Net name)
      ansible.builtin.set_fact:
        _resolved_attachments: >-
          {{ _resolved_attachments | default([]) + [{
               'interface': item.item.interface,
               'tenant_vnet_name': (item.resources[0].metadata.name
                                    if (item.resources | length > 0) else '')
             }] }}
      loop: "{{ _subnet_lookups.results | default([]) }}"
      loop_control:
        label: "{{ item.item.subnetRef }}"
      when: network_attachments | length > 0

    - name: Detach each port from its tenant V-Net
      ansible.builtin.include_role:
        name: "osac.templates.{{ implementation_strategy }}"
        tasks_from: delete_network_attachment
      vars:
        network_attachment:
          host_name: "{{ host_name }}"
          logical_interface_name: "{{ item.interface }}"
          target_vnet_name: "{{ item.tenant_vnet_name }}"
      loop: "{{ _resolved_attachments | default([]) }}"
      loop_control:
        label: "{{ item.interface | default('default') }} ← {{ item.tenant_vnet_name }}"
      when:
        - _resolved_attachments is defined
        - item.tenant_vnet_name | length > 0

    - name: Attach each port to the parking V-Net
      ansible.builtin.include_role:
        name: "osac.templates.{{ implementation_strategy }}"
        tasks_from: create_network_attachment
      vars:
        network_attachment:
          host_name: "{{ host_name }}"
          logical_interface_name: "{{ item.interface }}"
          target_vnet_name: "{{ parking_vnet }}"
      loop: "{{ _resolved_attachments | default([]) }}"
      loop_control:
        label: "{{ item.interface | default('default') }} → {{ parking_vnet }}"
      when:
        - _resolved_attachments is defined
        - parking_vnet | length > 0
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
cd osac-aap && uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" playbook_osac_delete_network_attachment.yml && uv run python -c "import yaml; list(yaml.safe_load_all(open('playbook_osac_delete_network_attachment.yml'))); print('parse OK')"
```
Expected: yamllint exits 0; prints `parse OK`.

- [ ] **Step 3: Commit**

```bash
git add osac-aap/playbook_osac_delete_network_attachment.yml
git commit -s -m "OSAC-1448: deprovision playbook detaches from tenant then attaches to parking V-Net

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: Supply the parking V-Net name on the operator provision path

The provision path must detach the port from parking, so it needs `bm_parking_vnet` in the job's extra_vars. Add the same `WithBMParkingVNet` plumbing already on the deprovision path to `reconcileNetworking`.

**Files:**
- Modify: `bare-metal-fulfillment-operator/internal/controller/baremetalinstance_networking.go`
- Test: `bare-metal-fulfillment-operator/internal/controller/baremetalinstance_networking_test.go`

**Interfaces:**
- Consumes: `r.BMParkingVNet` (reconciler field, already added), `provisioning.WithBMParkingVNet` (already added).
- Produces: the networking (provision) job receives `osac_job_vars.bm_parking_vnet` when configured.

- [ ] **Step 1: Write the failing test**

Add to `baremetalinstance_networking_test.go` (uses the existing `mockProvisioningProvider` + envtest `k8sClient`). This asserts the provision path passes the parking name into the context handed to the provider:

```go
var _ = Describe("BareMetalInstance networking parking plumbing", func() {
	var ctx context.Context

	BeforeEach(func() { ctx = context.Background() })

	It("passes the parking V-Net name to the networking provider on provision", func() {
		bmi := &v1alpha1.BareMetalInstance{
			ObjectMeta: metav1.ObjectMeta{
				GenerateName: "test-bmi-parking-",
				Namespace:    "default",
			},
			Spec: v1alpha1.BareMetalInstanceSpec{
				HostType:       "test-host",
				ExternalHostID: "host-parking-1",
				HostClass:      "openstack",
				TemplateID:     "noop",
				NetworkAttachments: []v1alpha1.BareMetalNetworkAttachment{
					{SubnetRef: "subnet-1", Interface: "eth9", Primary: true},
				},
			},
		}
		Expect(k8sClient.Create(ctx, bmi)).To(Succeed())
		defer func() { Expect(k8sClient.Delete(ctx, bmi)).To(Succeed()) }()

		var seenParking string
		mockProvider := &mockProvisioningProvider{
			triggerProvisionFunc: func(c context.Context, _ client.Object) (*provisioning.ProvisionResult, error) {
				seenParking = provisioning.BMParkingVNetFromContext(c)
				return &provisioning.ProvisionResult{JobID: "net-1", InitialState: opv1alpha1.JobStatePending}, nil
			},
		}
		reconciler := &BareMetalInstanceReconciler{
			Client:                        k8sClient,
			Scheme:                        k8sClient.Scheme(),
			NetworkingProvider:            mockProvider,
			ProvisionPollIntervalDuration: DefaultProvisionPollIntervalDuration,
			BMParkingVNet:                 "bm-parking",
		}

		// First call adds the finalizer; second triggers the provider.
		_, err := reconciler.reconcileNetworking(ctx, bmi)
		Expect(err).NotTo(HaveOccurred())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(bmi), bmi)).To(Succeed())
		_, err = reconciler.reconcileNetworking(ctx, bmi)
		Expect(err).NotTo(HaveOccurred())

		Expect(seenParking).To(Equal("bm-parking"))
	})
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd bare-metal-fulfillment-operator && ASSETS="$(pwd)/$(ls -d bin/k8s/* | head -1)" KUBEBUILDER_ASSETS="$ASSETS" go test ./internal/controller/ -run TestControllers -args -ginkgo.focus="networking parking plumbing"
```
Expected: FAIL — `seenParking` is empty (`""`), because `reconcileNetworking` does not yet put the parking name in the context.

- [ ] **Step 3: Add the plumbing**

In `baremetalinstance_networking.go`, in `reconcileNetworking`, immediately before the `provisioning.RunProvisioningLifecycle(` call, insert:

```go
	// Provide the parking V-Net name so the create playbook can detach the port
	// from parking before attaching it to the tenant V-Net.
	if r.BMParkingVNet != "" {
		ctx = provisioning.WithBMParkingVNet(ctx, r.BMParkingVNet)
	}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd bare-metal-fulfillment-operator && ASSETS="$(pwd)/$(ls -d bin/k8s/* | head -1)" KUBEBUILDER_ASSETS="$ASSETS" go test ./internal/controller/ -run TestControllers -args -ginkgo.focus="networking parking plumbing"
```
Expected: PASS.

- [ ] **Step 5: Lint + full component test**

Run:
```bash
cd bare-metal-fulfillment-operator && make test && make lint
```
Expected: all packages `ok`; golangci-lint `0 issues`.

- [ ] **Step 6: Commit**

```bash
git add bare-metal-fulfillment-operator/internal/controller/baremetalinstance_networking.go bare-metal-fulfillment-operator/internal/controller/baremetalinstance_networking_test.go
git commit -s -m "OSAC-1448: pass parking V-Net name on the BMI provision networking path

Assisted-by: Claude Code <noreply@anthropic.com>"
```

---

### Task 8: Whole-feature validation, push, and image rebuild

**Files:** none (verification + delivery).

**Interfaces:**
- Consumes: all prior tasks.
- Produces: pushed branch + rebuilt bmf image.

- [ ] **Step 1: Re-validate all changed Ansible files**

Run:
```bash
cd osac-aap && for f in \
  collections/ansible_collections/osac/templates/roles/netris/tasks/_resolve_attachment_context.yaml \
  collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml \
  collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml \
  collections/ansible_collections/osac/templates/roles/netris/meta/argument_specs.yaml \
  playbook_osac_create_network_attachment.yml \
  playbook_osac_delete_network_attachment.yml ; do \
  uv run yamllint -d "{extends: relaxed, rules: {line-length: disable, comments: disable, comments-indentation: disable}}" "$f" || exit 1 ; done && echo "yamllint OK"
```
Expected: `yamllint OK`.

- [ ] **Step 2: Confirm no stale references to the old role interface**

Run:
```bash
cd osac-aap && grep -rn "subnet_ref\|parking_vnet_name" collections/ansible_collections/osac/templates/roles/netris/tasks/create_network_attachment.yaml collections/ansible_collections/osac/templates/roles/netris/tasks/delete_network_attachment.yaml playbook_osac_create_network_attachment.yml playbook_osac_delete_network_attachment.yml || echo "no stale refs"
```
Expected: `no stale refs` (the roles/playbooks now use `target_vnet_name`; note the playbooks still read `item.subnetRef` from the CR spec, which is expected — grep for the role-arg names `subnet_ref`/`parking_vnet_name`, not `subnetRef`).

- [ ] **Step 3: Build + test + lint the operators**

Run:
```bash
cd bare-metal-fulfillment-operator && make test && make lint
cd ../osac-operator && make lint
```
Expected: all `ok` / `0 issues`.

- [ ] **Step 4: Push the branch**

Run:
```bash
cd .. && git push --force-with-lease origin feat/OSAC-2047-reconcile-networking
```
Expected: fast-forward push succeeds.

- [ ] **Step 5: Rebuild + push the bmf image**

Run:
```bash
cd bare-metal-fulfillment-operator && make image-build image-push IMG=quay.io/dmanor/bare-metal-fulfillment-operator:bmaas-networking
```
Expected: image built and pushed (requires `podman login quay.io`).

---

## Test-infra handoff (separate session — not part of this plan's tasks)

For the other session working in `osac-test-infra` `setup-bmaas` (before metal3 inspection):

1. Create the parking V-Net `bm-parking` in Netris with a subnet CIDR, **DHCP enabled**, and a **default gateway** (like tenant subnets get).
2. Create a **SNAT** rule on the parking VPC → an external IP (`netris.controller.nat`, `nat_action: snat`, `nat_source_address` = parking CIDR) so parked hosts reach the internet.
3. For each registered Netris server, attach its fabric port (`eth9`) to `bm-parking` — now reusable via the role: `include_role: osac.templates.netris tasks_from=create_network_attachment` with `network_attachment: {host_name: <server>, logical_interface_name: eth9, target_vnet_name: bm-parking}`.
4. The name **must** equal the operator's `OSAC_BM_PARKING_VNET` (`bm-parking`).

## Self-review notes

- **Spec coverage:** generic V-Net-name roles (Tasks 2–3), shared resolution + dropped enumeration (Task 1), detach-then-attach playbooks with Subnet-CR resolution moved to callers (Tasks 5–6), arg specs (Task 4), operator provision-path parking name (Task 7), test-infra reuse (handoff). All spec sections mapped.
- **Detach semantics:** no-op when V-Net/port unresolved or port not on the V-Net (Task 3), per spec.
- **Type/interface consistency:** roles consume `network_attachment.{host_name, logical_interface_name, target_vnet_name}` in Tasks 2, 3, 5, 6; shared facts `_target_vnet`/`_target_port` produced by Task 1 and consumed by Tasks 2–3; `provisioning.WithBMParkingVNet` / `BMParkingVNetFromContext` already exist and are used consistently in Task 7.
