# Netbird ACL Groups & Access Policy

## Zero-Trust Baseline

```
DisableDefaultPolicy: true
```

With the default policy disabled, **no peer can communicate with any other peer** unless an explicit ACL rule grants access. This is the foundation of zero-trust — deny all, allow explicitly.

---

## Access Groups

### admins

**Members**: Wakeem (all devices)

Full access to every resource. This is the infrastructure owner group.

### developers

**Members**: Future team members (enrolled via Authentik SSO)

Access to development and monitoring tools:
- Harbor (container registry)
- Grafana (monitoring)
- Devtron (CI/CD)
- Assigned K8s namespaces (per-project)

**Does NOT include**: OpenBao (secrets), MinIO (object storage), Authentik admin.

### contractors

**Members**: Scoped accounts created per engagement

Access restricted to:
- Their assigned project namespace only
- Harbor (pull access to their project's images only — enforced at Harbor level, not Netbird)
- Grafana (dashboards for their project only — enforced at Grafana level)

**Setup keys**: Time-limited (e.g., 30 days). Generated per contractor, revoked when engagement ends.

**Does NOT include**: Any infrastructure service, any other client's namespace, Devtron, OpenBao, MinIO.

### client-nodes

**Members**: Client-enrolled servers (one setup key per client)

Access restricted to:
- Their own namespace only
- Deny all cross-client traffic

**Critical rule**: A client node in `client-a` namespace MUST NOT reach any resource in `client-b` namespace. Netbird ACLs enforce this at the network layer. Application-level isolation (Authentik policies, K8s RBAC) provides defense in depth.

### infrastructure

**Members**: VPS (5.78.145.30), K3s CP (178.156.233.12), K3s Worker (138.201.131.157)

Server-to-server communication:
- Cluster internal traffic (kubelet, API server, etcd)
- VPS to K3s (Harbor registry pull, monitoring)
- K3s to VPS (Authentik OIDC, PostgreSQL if needed)

---

## ACL Rules

| Rule Name | Source Group | Destination Group | Ports | Protocol | Direction |
|-----------|-------------|-------------------|-------|----------|-----------|
| Admin Full Access | `admins` | `*` (all) | All | All | Bidirectional |
| Dev Tools | `developers` | `infrastructure` | 443 (Harbor, Grafana, Devtron) | TCP | Bidirectional |
| Contractor Scoped | `contractors` | `infrastructure` | Project namespace ports only | TCP | Bidirectional |
| Client Isolation | `client-nodes` | `infrastructure` | Client namespace ports only | TCP | Bidirectional |
| Cluster Mesh | `infrastructure` | `infrastructure` | All | All | Bidirectional |
| Block Cross-Client | `client-nodes` | `client-nodes` | None | N/A | **DENY** |

> **Note**: The "Block Cross-Client" deny rule is implicit when `DisableDefaultPolicy: true` — no rule means no access. It is listed here for documentation clarity. If you ever re-enable the default policy, you MUST add an explicit deny rule.

---

## Emergency Access

### Long-Lived Setup Key

A Netbird setup key with **no expiration** is stored in Vaultwarden.

**Purpose**: If Authentik is down, SSO login to Netbird fails. This key allows enrolling a new peer without SSO to regain tunnel access.

**Location**: Vaultwarden (`vault.helixstax.net`) > Secure Note > "Netbird Emergency Setup Key"

**Usage**:
```bash
netbird up --setup-key <emergency-key>
```

### SSH Break-Glass

SSH on port 2222 is **completely independent** of Netbird and Authentik. It is the ultimate fallback.

- Restricted to admin IP via UFW
- If UFW locks you out: Hetzner web console > `ufw disable`

---

## Group Lifecycle

| Event | Action |
|-------|--------|
| New team member | Add to `developers` group in Netbird UI. They SSO via Authentik. |
| New contractor | Create Netbird account, add to `contractors` group, generate time-limited setup key. |
| Contractor offboarding | Revoke setup key, remove from `contractors` group, disable Authentik account. |
| New client enrollment | Generate client-specific setup key, add enrolled nodes to `client-nodes` group with namespace tag. |
| Client offboarding | Revoke setup key, remove nodes from `client-nodes` group, tear down namespace. |
