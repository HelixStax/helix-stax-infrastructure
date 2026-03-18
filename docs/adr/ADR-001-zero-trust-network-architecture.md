# ADR-001: Zero-Trust Network Architecture

**Status**: Accepted
**Date**: 2026-03-17
**Authors**: Wakeem Williams

## Context

Helix Stax operates a multi-tenant consulting platform with several security requirements:

- **Multi-tenant isolation**: Client workloads must be isolated from each other and from internal ops tooling.
- **Contractor access**: External contractors need scoped, time-limited access to specific project resources only.
- **Client isolation**: Client-enrolled nodes must reach only their assigned namespace — never another client's resources.
- **Admin access**: Internal team needs full access to all infrastructure services (Harbor, Grafana, Devtron, OpenBao, MinIO).

The current state has multiple services bound to `0.0.0.0` (publicly reachable) and no network-level access control beyond Docker port bindings to `127.0.0.1`. Netbird is deployed but has no OIDC provider configured and `DisableDefaultPolicy: false` (all peers talk to all peers).

## Decision

### Two Traffic Paths

All traffic follows one of two paths:

1. **Public path** (exceptions only): Internet --> Cloudflare DNS --> Nginx reverse proxy --> service
   - Only for services that *must* be publicly reachable: Authentik (OIDC provider), Vaultwarden (WebCrypto requires HTTPS origin), Netbird management/signal/relay (VPN bootstrapping).
   - TLS terminated at Nginx via Let's Encrypt (DNS-01 challenge with Cloudflare plugin).

2. **Private path** (default): Laptop/server --> Netbird tunnel --> service
   - All other services: Harbor, OpenBao, MinIO, Grafana, Devtron, Homepage dashboard.
   - Services bind to `${NETBIRD_IP:-127.0.0.1}` — accessible only over the Netbird mesh or locally on the host.

### Domain Split

| Domain | Purpose | Cloudflare Mode | TLS |
|--------|---------|-----------------|-----|
| `helixstax.net` | Private admin/ops | Grey cloud (DNS only) | Let's Encrypt (browser connects directly to origin) |
| `helixstax.com` | Public client-facing | Orange cloud (proxied) | Cloudflare origin certs (Cloudflare terminates edge TLS) |

**Why two domains?**
- Grey cloud on `.net` means browsers connect directly to origin — required for Let's Encrypt HTTP validation and for services where Cloudflare proxying adds unnecessary complexity (SSO flows, VPN management).
- Orange cloud on `.com` provides DDoS protection, WAF, and edge caching for client-facing services.
- Clean separation: ops team uses `.net`, clients use `.com`. No confusion about which services are internal.

### TLS Strategy

| Domain | Cloud Mode | TLS Provider | Why |
|--------|-----------|--------------|-----|
| `*.helixstax.net` | Grey (DNS only) | Let's Encrypt (DNS-01) | Browser connects directly to server. Need a real cert. Certbot with `certbot-dns-cloudflare` plugin handles issuance and renewal. |
| `*.helixstax.com` | Orange (proxied) | Cloudflare origin certs | Cloudflare terminates TLS at the edge. Origin cert secures the Cloudflare-to-origin hop. Let's Encrypt would fail HTTP-01 validation behind Cloudflare proxy. |

### SSO Architecture

All service authentication flows through:

```
User --> Google Workspace (@helixstax.com) --> Authentik (auth.helixstax.net) --> Service
```

Authentik is the central identity provider. Netbird, Grafana, Devtron, and future services authenticate via Authentik OIDC.

### Approach: Manual-First, Terraform-Second

1. Deploy and verify everything by hand using the deployment runbook.
2. Once confirmed working, codify DNS records and firewall rules in Terraform.
3. Future changes go through Terraform, not dashboard clicking.

**Why?** Zero-trust networking is high-risk — a misconfiguration can lock you out of your own server. Manual verification at each step catches issues before they compound. Terraform comes after confidence.

## Consequences

### Positive

- **Defense in depth**: Firewall + Docker port binding + Netbird ACLs = three layers of access control.
- **Least privilege by default**: `DisableDefaultPolicy: true` means no peer-to-peer access unless explicitly granted.
- **Client isolation**: Netbird ACL groups enforce namespace-level isolation — a compromised client node cannot reach other clients.
- **SSO everywhere**: Single identity provider (Authentik) with Google Workspace federation. No scattered credentials.
- **Emergency bypass**: Vaultwarden is publicly accessible (independent of Netbird/Authentik) and stores the emergency Netbird setup key. SSH on port 2222 is the ultimate break-glass path.
- **Incremental rollout**: `${NETBIRD_IP:-127.0.0.1}` fallback means services stay accessible locally during migration.

### Negative

- **Operational complexity**: Two domains, two TLS strategies, two traffic paths. More moving parts than a flat network.
- **Single points of failure**: Authentik down = no new SSO logins (mitigated by emergency setup key in Vaultwarden). Netbird down = no private service access (mitigated by SSH break-glass).
- **Certbot maintenance**: Let's Encrypt certs expire every 90 days. Certbot renewal cron must be reliable.
- **Port collision fix required**: Dashboard and relay both bind 33080 — must be resolved before deployment.

### Risks

- **Lockout risk**: Firewall misconfiguration can lock out SSH. Mitigated by dead man's switch (`at now + 15 min <<< 'ufw disable'`) and Hetzner web console as last resort.
- **Docker bypasses UFW**: Docker's DOCKER iptables chain bypasses UFW. Port binding addresses (`127.0.0.1:` prefix) are the real access control for bridged containers, not UFW rules. Coturn (host networking) is the exception — UFW does apply.

## Related Documents

- [DNS Records Reference](../dns-records.md)
- [Netbird ACL Groups](../netbird-acls.md)
- [Zero-Trust Deployment Runbook](../runbooks/zero-trust-deployment.md)
- [Authentik Backup & Restore](../runbooks/authentik-backup-restore.md)
- [Infrastructure Context (PREPARE)](../preparation/zero-trust-context.md)
