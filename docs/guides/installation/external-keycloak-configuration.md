# Deploying OSAC with an External Keycloak Instance

**Last Updated**: 2026-10-08
**Audience**: Platform engineers and cluster administrators
**Status**: Validated on Keycloak 26.6.4, OSAC 0.0.17, OpenShift Container Platform 4.22

---

This guide explains how to run Keycloak outside OpenShift and wire OSAC to it.
Use this approach when you need a persistent identity provider that survives
cluster rebuilds, when you want to reuse an existing Keycloak instance on a
lab host, or when you need to test against a Keycloak version without
redeploying the full cluster.

For the default bundled Keycloak deployment, see the
[Keycloak configuration guide](../keycloak-configuration.md).
For realm structure, clients, and OIDC settings, see the same guide — they
apply regardless of where Keycloak runs.

## Contents

1. [Architecture overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Deploying Keycloak on an external host](#3-deploying-keycloak-on-an-external-host)
4. [Configuring the OSAC realm](#4-configuring-the-osac-realm)
5. [Connecting OSAC to the external Keycloak](#5-connecting-osac-to-the-external-keycloak)
6. [Verifying the configuration](#6-verifying-the-configuration)
7. [Backing up and restoring Keycloak](#7-backing-up-and-restoring-keycloak)
8. [Reverting to the bundled Keycloak](#8-reverting-to-the-bundled-keycloak)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Architecture overview

In the default installation, Keycloak runs as a Deployment in the `keycloak`
namespace on the same OpenShift cluster as OSAC. In the external configuration,
Keycloak runs as a container on a host that is network-reachable from the
cluster. OSAC components that validate JWTs — the Fulfillment Service and the
Authorino `AuthConfig` — are updated to point to the external URL.

```
OpenShift cluster
├── fulfillment-grpc-server  ──[HTTPS / JWKS discovery]──▶  Keycloak
├── Authorino AuthConfig     ──[OIDC discovery]───────────▶  (external host)
└── osac-ui                  ──[browser OIDC redirect]────▶  port 8443
```

The external Keycloak must use HTTPS. OSAC enforces HTTPS for all OIDC
issuer URLs. The Keycloak TLS certificate (even a self-signed one) must be
added to the cluster CA bundle so that pods can verify it.

---

## 2. Prerequisites

**External host**

- A Linux host (RHEL 9 or Fedora) reachable from the OpenShift cluster nodes
  and from end-user browsers.
- Podman 4 or later installed on the host.
- Port 8443 open in the host firewall:

  ```console
  $ firewall-cmd --add-port=8443/tcp --permanent && firewall-cmd --reload
  ```

- Enough storage for the Keycloak data directory. The H2 database used by
  Keycloak in production mode typically stays under 1 GB for a development
  environment.

**OpenShift cluster**

- You are logged in to the cluster with `cluster-admin` privileges.
- The `ca-bundle` `ConfigMap` and the `ca-bundle`
  `Bundle` custom resource (trust-manager) exist. Verify with:

  ```console
  $ kubectl get bundle.trust.cert-manager.io ca-bundle
  ```

- The `cert-manager` namespace exists and trust-manager is running.

**Tools**

- `kubectl` or `oc`, matching the cluster version.
- `curl`, `openssl`, and `python3` on the external host.

---

## 3. Deploying Keycloak on an external host

### 3.1 Generating a TLS certificate

Keycloak must present a TLS certificate whose Subject Alternative Name (SAN)
matches the address that both OCP pods and browsers use to reach it. Use an IP
address SAN when there is no DNS name for the host.

**Procedure**

1. Generate a self-signed certificate on the external host:

   ```console
   $ openssl req -x509 -newkey rsa:2048 \
       -keyout /root/kc-key.pem \
       -out /root/kc-cert.pem \
       -days 365 -nodes \
       -subj "/CN=<HOST_IP_OR_FQDN>" \
       -addext "subjectAltName=IP:<HOST_IP>"
   ```

   Replace `<HOST_IP>` with the IP address that OpenShift pods use to reach
   the host. To use a DNS name instead of an IP address, replace the
   `subjectAltName` value with `DNS:<hostname>`.

2. Set file permissions so the Keycloak process can read both files:

   ```console
   $ chmod 644 /root/kc-key.pem /root/kc-cert.pem
   ```

   > **Note**
   >
   > Keycloak fails to start with an `AccessDeniedException` if the key file
   > is not world-readable. The certificate and key do not require a password.

### 3.2 Starting the Keycloak container

Run Keycloak as a persistent container with a bind-mounted data directory.
The bind mount (`-v /root/kc-data:/opt/keycloak/data`) ensures the embedded
H2 database survives container deletion. Without it, all realm data is lost
when the container is removed.

**Procedure**

1. Create the persistent data directory:

   ```console
   $ mkdir -p /root/kc-data
   ```

2. Start the container:

   ```console
   $ podman run -d --name keycloak \
       -p 8443:8443 \
       --security-opt label=disable \
       -v /root/kc-cert.pem:/etc/x509/https/tls.crt:z \
       -v /root/kc-key.pem:/etc/x509/https/tls.key:z \
       -v /root/kc-data:/opt/keycloak/data:z \
       -e KEYCLOAK_ADMIN=admin \
       -e KEYCLOAK_ADMIN_PASSWORD=<admin_password> \
       -e KC_HTTPS_CERTIFICATE_FILE=/etc/x509/https/tls.crt \
       -e KC_HTTPS_CERTIFICATE_KEY_FILE=/etc/x509/https/tls.key \
       -e KC_HOSTNAME=<HOST_IP_OR_FQDN> \
       -e KC_HOSTNAME_PORT=8443 \
       -e KC_HOSTNAME_STRICT=false \
       -e KC_HTTP_ENABLED=false \
       quay.io/keycloak/keycloak:26.6.4 start
   ```

   > **Note**
   >
   > `--security-opt label=disable` is required on RHEL and Fedora hosts.
   > Without it, SELinux prevents Keycloak from loading shared libraries and
   > the container exits immediately with a permission error. See
   > [Section 9](#9-troubleshooting) for the full error message.

3. Wait for Keycloak to become ready:

   ```console
   $ until curl -sk "https://<HOST_IP>:8443/realms/master" > /dev/null 2>&1; \
       do sleep 3; printf "."; done && echo " ready"
   ```

   Startup takes approximately 30 seconds on first run.

### 3.3 Enabling automatic restart

Configure systemd so the container restarts automatically after host reboots.

**Procedure**

1. Generate a systemd unit from the running container:

   ```console
   $ podman generate systemd --name keycloak --restart-policy=always \
       > /etc/systemd/system/keycloak.service
   ```

2. Enable and start the service:

   ```console
   $ systemctl daemon-reload
   $ systemctl enable --now keycloak
   ```

---

## 4. Configuring the OSAC realm

### 4.1 Importing the realm

OSAC requires a realm named `osac` with specific clients, scopes, and roles.
Import the authoritative `realm.json` from the installer repository.

**Procedure**

1. Set a shell variable for the Keycloak URL:

   ```console
   $ export KC="https://<HOST_IP>:8443"
   ```

2. Obtain an admin token:

   ```console
   $ export KC_TOKEN=$(curl -sk \
       -d "client_id=admin-cli&username=admin&password=<admin_password>&grant_type=password" \
       "${KC}/realms/master/protocol/openid-connect/token" \
       | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
   ```

3. Import the realm:

   ```console
   $ curl -sk -X POST \
       -H "Authorization: Bearer ${KC_TOKEN}" \
       -H "Content-Type: application/json" \
       -d @osac-installer/charts/osac-prereqs/files/realm.json \
       "${KC}/admin/realms"
   ```

4. Verify the import:

   ```console
   $ curl -sk "${KC}/realms/osac" \
       | python3 -c "import sys,json; print(json.load(sys.stdin)['realm'])"
   ```

   Expected output: `osac`

### 4.2 Adding LDAP federations (optional)

LDAP user federation is not included in `realm.json` and must be added
separately. For a full walkthrough, see the
[LDAP federation guide](../customer-ldap-federation-guide.md).

---

## 5. Connecting OSAC to the external Keycloak

Three changes are required in the OpenShift cluster: add the Keycloak
certificate to the cluster CA bundle, update the Authorino `AuthConfig` with
the new issuer URL, and update the `fulfillment-grpc-server` deployment.

Set these variables before running the commands in this section:

```console
$ export KC_REALM_URL="https://<HOST_IP>:8443/realms/osac"
$ export NAMESPACE=<osac_namespace>
$ export KUBECONFIG=/path/to/kubeconfig
```

### 5.1 Adding the Keycloak certificate to the CA bundle

The `ca-bundle` `ConfigMap` is managed by trust-manager. Direct edits to it
are reverted immediately. Add new certificates by updating the `Bundle`
custom resource, which trust-manager then syncs to the `ConfigMap`.

**Procedure**

1. Create a `Secret` in the `cert-manager` namespace with the Keycloak
   certificate:

   ```console
   $ kubectl create secret generic kc-ext-cert \
       -n cert-manager \
       --from-file=ca.crt=/root/kc-cert.pem \
       --dry-run=client -o yaml | kubectl apply -f -
   ```

2. Add the secret as a source in the `Bundle` custom resource:

   ```console
   $ kubectl patch bundle.trust.cert-manager.io ca-bundle --type=json -p='[
       {
         "op": "add",
         "path": "/spec/sources/-",
         "value": {
           "secret": {
             "name": "kc-ext-cert",
             "namespace": "cert-manager",
             "key": "ca.crt"
           }
         }
       }
     ]'
   ```

3. Verify that the bundle now contains one additional certificate:

   ```console
   $ sleep 5 && kubectl -n "${NAMESPACE}" get configmap ca-bundle \
       -o jsonpath='{.data.bundle\.pem}' | grep -c "BEGIN CERTIFICATE"
   ```

   The count must increase by one compared to the value before the patch.

### 5.2 Updating the Authorino AuthConfig

**Procedure**

1. Update the `issuerUrl` in the `AuthConfig`:

   ```console
   $ kubectl -n "${NAMESPACE}" get authconfig fulfillment-service -o json \
       | python3 -c "
   import sys, json, re
   d = json.load(sys.stdin)
   for m in d['spec'].get('authentication', {}).values():
       if 'jwt' in m and 'issuerUrl' in m['jwt']:
           m['jwt']['issuerUrl'] = '${KC_REALM_URL}'
   print(json.dumps(d, indent=2))" \
       | kubectl apply -f -
   ```

### 5.3 Updating the Fulfillment Service

**Procedure**

1. Update the `--grpc-authn-trusted-token-issuers` argument in the
   `fulfillment-grpc-server` deployment:

   ```console
   $ kubectl -n "${NAMESPACE}" get deployment fulfillment-grpc-server -o json \
       | python3 -c "
   import sys, json, re
   d = json.load(sys.stdin)
   for c in d['spec']['template']['spec']['containers']:
       c['args'] = [
           re.sub(r'--grpc-authn-trusted-token-issuers=.*',
                  '--grpc-authn-trusted-token-issuers=${KC_REALM_URL}', a)
           for a in c.get('args', [])
       ]
   print(json.dumps(d, indent=2))" \
       | kubectl apply -f -
   ```

2. Restart the deployment to pick up the refreshed CA bundle and updated
   arguments:

   ```console
   $ kubectl -n "${NAMESPACE}" rollout restart deployment/fulfillment-grpc-server
   $ kubectl -n "${NAMESPACE}" rollout status deployment/fulfillment-grpc-server \
       --timeout=180s
   ```

### 5.4 Pausing the bundled Keycloak (optional)

Scale down the in-cluster Keycloak to avoid token issuers conflicting. The
data is retained and can be restored at any time.

```console
$ kubectl -n keycloak scale deployment keycloak-service --replicas=0
$ kubectl -n keycloak scale statefulset keycloak-database --replicas=0
```

---

## 6. Verifying the configuration

**Procedure**

1. Check that the Fulfillment Service reports the external Keycloak as the
   trusted issuer:

   ```console
   $ ROUTE=$(kubectl -n "${NAMESPACE}" get route fulfillment-api \
       -o jsonpath='{.spec.host}')
   $ grpcurl -insecure "${ROUTE}:443" osac.public.v1.Capabilities/Get \
       | python3 -c "import sys,json; \
           [print(i) for i in json.load(sys.stdin).get('trustedTokenIssuers',[])]"
   ```

   Expected output includes `https://<HOST_IP>:8443/realms/osac`.

2. Log in with a realm user:

   ```console
   $ osac login --insecure \
       --user <username> \
       --password <password> \
       "${ROUTE}:443"
   $ osac get projects
   ```

   A successful response lists the tenant projects the user belongs to.

---

## 7. Backing up and restoring Keycloak

### 7.1 Exporting the realm

> **Note**
>
> `GET /admin/realms/{realm}` returns only realm metadata — clients, users,
> and organizations are always empty in its response. Always use
> `POST /admin/realms/{realm}/partial-export` to export the realm structure,
> and separate endpoints for users and organizations.

**Procedure**

1. Set shell variables:

   ```console
   $ export KC="https://<HOST_IP>:8443"
   $ export BACKUP=/root/kc-backup
   $ export TS=$(date +%Y%m%d-%H%M%S)
   $ mkdir -p "${BACKUP}"
   ```

2. Obtain an admin token:

   ```console
   $ export KC_TOKEN=$(curl -sk \
       -d "client_id=admin-cli&username=admin&password=<admin_password>&grant_type=password" \
       "${KC}/realms/master/protocol/openid-connect/token" \
       | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
   ```

3. Export the realm structure (clients, roles, groups):

   ```console
   $ curl -sk -X POST \
       -H "Authorization: Bearer ${KC_TOKEN}" \
       "${KC}/admin/realms/osac/partial-export?exportGroupsAndRoles=true&exportClients=true" \
       | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))" \
       > "${BACKUP}/realm-osac-${TS}.json"
   ```

4. Export users:

   ```console
   $ curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
       "${KC}/admin/realms/osac/users?max=1000&briefRepresentation=false" \
       | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))" \
       > "${BACKUP}/users-osac-${TS}.json"
   ```

5. Export organizations:

   ```console
   $ curl -sk -H "Authorization: Bearer ${KC_TOKEN}" \
       "${KC}/admin/realms/osac/organizations?max=100" \
       | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), indent=2))" \
       > "${BACKUP}/orgs-osac-${TS}.json"
   ```

6. Take a data directory snapshot (briefly stops the container for
   consistency):

   ```console
   $ podman stop keycloak
   $ tar -czf "${BACKUP}/kc-data-${TS}.tar.gz" -C /root kc-data
   $ podman start keycloak
   ```

7. Verify the export:

   ```console
   $ python3 -c "
   import json
   r = json.load(open('${BACKUP}/realm-osac-${TS}.json'))
   u = json.load(open('${BACKUP}/users-osac-${TS}.json'))
   o = json.load(open('${BACKUP}/orgs-osac-${TS}.json'))
   print(f'clients: {len(r.get(\"clients\", []))}')
   print(f'users:   {len(u)}')
   print(f'orgs:    {len(o)}')
   "
   ```

### 7.2 Restoring Keycloak

**Restore from data snapshot** — use when the data directory is corrupted or
the container was removed without a prior snapshot:

```console
$ podman stop keycloak && podman rm keycloak
$ LATEST=$(ls -t /root/kc-backup/kc-data-*.tar.gz | head -1)
$ rm -rf /root/kc-data && tar -xzf "${LATEST}" -C /root
```

Then re-run the `podman run` command from [Section 3.2](#32-starting-the-keycloak-container).

**Restore from realm JSON** — use when both the container and the data
directory are lost:

1. Start a fresh container with an empty data directory using the
   `podman run` command from [Section 3.2](#32-starting-the-keycloak-container).
2. Wait for Keycloak to become ready.
3. Import the most recent realm export:

   ```console
   $ LATEST_REALM=$(ls -t /root/kc-backup/realm-osac-*.json | head -1)
   $ export KC_TOKEN=$(curl -sk \
       -d "client_id=admin-cli&username=admin&password=<admin_password>&grant_type=password" \
       "${KC}/realms/master/protocol/openid-connect/token" \
       | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
   $ curl -sk -X POST \
       -H "Authorization: Bearer ${KC_TOKEN}" \
       -H "Content-Type: application/json" \
       -d @"${LATEST_REALM}" \
       "${KC}/admin/realms"
   ```

   > **Note**
   >
   > The `partial-export` format does not include LDAP federation
   > configurations or organization membership assignments. After restoring
   > from a realm JSON backup, re-add LDAP federations and re-enroll users
   > in organizations manually or by re-running the original setup procedure.

---

## 8. Reverting to the bundled Keycloak

**Procedure**

1. Restart the bundled Keycloak:

   ```console
   $ kubectl -n keycloak scale statefulset keycloak-database --replicas=1
   $ kubectl -n keycloak rollout status statefulset/keycloak-database --timeout=120s
   $ kubectl -n keycloak scale deployment keycloak-service --replicas=1
   $ kubectl -n keycloak rollout status deployment/keycloak-service --timeout=180s
   ```

2. Retrieve the original issuer URL:

   ```console
   $ export BUNDLED_KC_URL="https://$(kubectl -n keycloak get route keycloak \
       -o jsonpath='{.spec.host}')/realms/osac"
   ```

3. Revert the `AuthConfig`:

   ```console
   $ kubectl -n "${NAMESPACE}" get authconfig fulfillment-service -o json \
       | python3 -c "
   import sys, json, re
   d = json.load(sys.stdin)
   for m in d['spec'].get('authentication', {}).values():
       if 'jwt' in m and 'issuerUrl' in m['jwt']:
           m['jwt']['issuerUrl'] = '${BUNDLED_KC_URL}'
   print(json.dumps(d, indent=2))" \
       | kubectl apply -f -
   ```

4. Revert the `fulfillment-grpc-server` deployment:

   ```console
   $ kubectl -n "${NAMESPACE}" get deployment fulfillment-grpc-server -o json \
       | python3 -c "
   import sys, json, re
   d = json.load(sys.stdin)
   for c in d['spec']['template']['spec']['containers']:
       c['args'] = [
           re.sub(r'--grpc-authn-trusted-token-issuers=.*',
                  '--grpc-authn-trusted-token-issuers=${BUNDLED_KC_URL}', a)
           for a in c.get('args', [])
       ]
   print(json.dumps(d, indent=2))" \
       | kubectl apply -f -
   ```

5. Remove the external Keycloak certificate from the `Bundle` custom
   resource:

   ```console
   $ kubectl patch bundle.trust.cert-manager.io ca-bundle --type=json \
       -p='[{"op": "remove", "path": "/spec/sources/<index>"}]'
   ```

   Replace `<index>` with the zero-based position of the `kc-ext-cert` entry
   in `spec.sources`. To find it:

   ```console
   $ kubectl get bundle.trust.cert-manager.io ca-bundle \
       -o jsonpath='{.spec.sources}' | python3 -m json.tool
   ```

6. Restart the Fulfillment Service:

   ```console
   $ kubectl -n "${NAMESPACE}" rollout restart deployment/fulfillment-grpc-server
   $ kubectl -n "${NAMESPACE}" rollout status deployment/fulfillment-grpc-server \
       --timeout=180s
   ```

---

## 9. Troubleshooting

### SELinux prevents container startup

**Symptom**

```
/lib64/libc.so.6: cannot apply additional memory protection after relocation: Permission denied
```

**Cause**

SELinux on RHEL and Fedora hosts blocks the Keycloak JVM from applying memory
protections after loading shared libraries.

**Resolution**

Add `--security-opt label=disable` to the `podman run` command. This flag
disables SELinux labeling for the container without affecting the rest of
the system.

---

### Direct edits to `ca-bundle` are immediately reverted

**Symptom**

`kubectl apply` or `kubectl replace` on the `ca-bundle` `ConfigMap` succeeds,
but the change disappears within a few seconds and the certificate count
does not increase.

**Cause**

trust-manager owns the `ca-bundle` `ConfigMap` and continuously reconciles
it to match the `Bundle` custom resource. The `ConfigMap` carries a
`trust.cert-manager.io/hash` annotation that trust-manager checks on every
reconciliation loop.

**Resolution**

Never edit the `ConfigMap` directly. Add new CA certificates as sources on
the `Bundle` custom resource as described in
[Section 5.1](#51-adding-the-keycloak-certificate-to-the-ca-bundle).

---

### Token issue time is in the future

**Symptom**

```
token issue time is in the future, N minutes from now, check time synchronization
```

**Cause**

The clock on the OpenShift node is behind the clock on the Keycloak host.
JWT tokens carry an `iat` (issued-at) timestamp from Keycloak; if the
cluster's clock is more than about 30 seconds behind, the token appears to
be issued in the future.

**Diagnosis**

```console
$ podman exec keycloak date -u
$ kubectl -n "${NAMESPACE}" exec deploy/fulfillment-grpc-server -- date -u
```

Compare the two timestamps. A difference greater than 30 seconds causes
authentication failures.

**Resolution**

If `chronyc makestep` is not available or does not sync correctly on the
OpenShift node, set the clock directly by running the following commands
from the Keycloak host:

```console
$ CURRENT=$(date -u +"%Y-%m-%d %H:%M:%S")
$ ssh core@<ocp_node_ip> "sudo date -u -s '${CURRENT}'"
```

---

### Realm export shows zero clients, users, or organizations

**Symptom**

```
clients: 0
users:   0
orgs:    0
```

**Cause**

`GET /admin/realms/{realm}` returns only realm metadata. The query parameters
`exportGroupsAndRoles=true` and `exportClients=true` are not valid on this
endpoint and are silently ignored.

**Resolution**

Use `POST /admin/realms/{realm}/partial-export` for the realm structure, and
fetch users and organizations from their own list endpoints. See
[Section 7.1](#71-exporting-the-realm) for the correct commands.

---

### Organization membership POST returns `User does not exist`

**Symptom**

```json
{"errorMessage":"User does not exist"}
```

This error occurs even when the user is confirmed to exist in the realm.

**Cause**

Keycloak 26 changed the request body format for `POST
/admin/realms/{realm}/organizations/{id}/members`. Prior versions accepted
`{"id": "<uuid>"}`. Version 26 requires a plain JSON string `"<uuid>"`.

**Resolution**

Pass the user UUID as a bare JSON string, not as an object:

```console
$ curl -sk -X POST \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "\"${USER_ID}\"" \
    "${KC}/admin/realms/osac/organizations/${ORG_ID}/members"
```
