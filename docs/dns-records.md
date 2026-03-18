# DNS Records Reference

## helixstax.net (Private / Ops)

Managed in Cloudflare. All records are **grey cloud** (DNS only — no Cloudflare proxy).

### Public-Facing (Direct to VPS: 5.78.145.30)

These services must be reachable from the internet for bootstrapping (OIDC, VPN enrollment, password manager).

| Subdomain | Type | Value | Proxy | Purpose |
|-----------|------|-------|-------|---------|
| `auth` | A | `5.78.145.30` | Grey | Authentik — OIDC provider for SSO |
| `vault` | A | `5.78.145.30` | Grey | Vaultwarden — WebCrypto requires HTTPS origin |
| `vpn` | A | `5.78.145.30` | Grey | Netbird management UI + API |

### Private (Netbird Tunnel Only)

These resolve to the VPS's Netbird IP. Created after the VPS is enrolled as a Netbird peer and assigned a stable IP.

| Subdomain | Type | Value | Proxy | Purpose |
|-----------|------|-------|-------|---------|
| `harbor` | A | TBD (Netbird IP) | Grey | Container registry — tunnel only |
| `openbao` | A | TBD (Netbird IP) | Grey | Secrets management — tunnel only |
| `minio` | A | TBD (Netbird IP) | Grey | Object storage — tunnel only |
| `grafana` | A | TBD (Netbird IP) | Grey | Monitoring dashboards — tunnel only |
| `devtron` | A | TBD (Netbird IP) | Grey | CI/CD platform — tunnel only |
| `dashboard` | A | TBD (Netbird IP) | Grey | Homepage ops dashboard — tunnel only |

> **Note**: Private DNS records are deferred until Phase 7 (Netbird peer enrollment). The VPS must be enrolled and assigned a stable Netbird IP before these records can be created.

### TLS

All `*.helixstax.net` subdomains use **Let's Encrypt** certificates issued via DNS-01 challenge (certbot with `certbot-dns-cloudflare` plugin). Grey cloud means browsers connect directly to origin — a real certificate is required.

---

## helixstax.com (Public / Client-Facing)

Managed in Cloudflare. All records are **orange cloud** (Cloudflare proxied).

| Subdomain | Type | Value | Proxy | Purpose |
|-----------|------|-------|-------|---------|
| `@` | A | `138.201.131.157` | Orange | Public website (K3s worker node) |
| `*` | A | `138.201.131.157` | Orange | Client subdomains (future) |

### TLS

All `*.helixstax.com` subdomains use **Cloudflare origin certificates**. Orange cloud means Cloudflare terminates TLS at the edge. The origin cert secures the Cloudflare-to-server hop.

---

## Cloud Mode Reference

| Mode | Icon | What It Means |
|------|------|---------------|
| Grey cloud | DNS only | Cloudflare resolves DNS but does NOT proxy traffic. Browser connects directly to the origin server IP. |
| Orange cloud | Proxied | Cloudflare resolves DNS AND proxies traffic through its edge network. Origin IP is hidden. DDoS protection, WAF, and caching are active. |

---

## Server IPs

| Server | IP | Role |
|--------|-----|------|
| VPS (CX32) | `5.78.145.30` | Authentik, Netbird, Harbor, OpenBao, MinIO, Vaultwarden |
| K3s CP (heart) | `178.156.233.12` | Control plane |
| K3s Worker (helix-worker-1) | `138.201.131.157` | Workloads, public ingress |
