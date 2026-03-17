---
tags: [infrastructure, tools, inventory, helix-stax, reference, devops]
created: 2026-03-17
updated: 2026-03-17
status: active
phase: pre-flight
related:
  - "[[05-operations/tech-stack]]"
  - "[[10-tutorials/infrastructure-buildout/_index]]"
  - "[[10-tutorials/infrastructure-buildout/addendum-notes]]"
---

# Tools Inventory — Helix Stax Infrastructure Buildout

> Complete inventory of every CLI tool, Helm chart, Docker image, skill, and external account required for the infrastructure buildout. Nothing gets installed ad-hoc — if it's not on this list, it doesn't belong in the stack.

---

## 1. CLI Tools — Local Machine (Wakeem's Dev Machine / Windows 11)

These tools are installed on the local Windows workstation and used to manage the cluster remotely.

| Tool | Purpose | Install Command (Windows) | Target Version | Used In Phase |
|------|---------|--------------------------|----------------|---------------|
| **kubectl** | Kubernetes cluster management, pod inspection, log tailing | `winget install Kubernetes.kubectl` | v1.34.x (match K3s) | All phases |
| **helm** | Kubernetes package manager — installs charts into K3s | `winget install Helm.Helm` | v3.16+ | Phase 3–9 |
| **terraform** | Infrastructure as Code — codifies Hetzner + Cloudflare resources | `winget install Hashicorp.Terraform` | v1.10+ | Phase 1 |
| **hcloud** | Hetzner Cloud CLI — server provisioning, firewall rules, snapshots | `winget install hetznercloud.cli` | v1.48+ | Phase 1–2 |
| **docker** | Local container testing, image builds | Docker Desktop or `winget install Docker.DockerDesktop` | v27+ | Phase 2, 9 |
| **gh** | GitHub CLI — repo management, PATs, webhooks, PR creation | `winget install GitHub.cli` | v2.60+ | Phase 1, 9 |
| **cilium** | Cilium CNI management CLI — status, connectivity tests | `curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-windows-amd64.tar.gz` | v0.16+ | Phase 3 |
| **velero** | Backup/restore management — schedule backups, trigger restores | Download from [GitHub releases](https://github.com/vmware-tanzu/velero/releases) and add to PATH | v1.15+ | Phase 8 |
| **cosign** | Container image signing and verification | `winget install sigstore.cosign` | v2.4+ | Phase 3, 9 |
| **jq** | JSON processing — parse kubectl output, API responses | `winget install jqlang.jq` | v1.7+ | All phases |
| **yq** | YAML processing — edit Helm values, K8s manifests | `winget install MikeFarah.yq` | v4.44+ | All phases |
| **python3** | PACT hooks, automation scripts, cover photo rendering | `winget install Python.Python.3.12` | 3.12+ | Support tooling |
| **ssh** | Remote node access (built into Windows 11) | Pre-installed (OpenSSH client) | — | All phases |
| **rclone** | S3-compatible sync — used locally for testing B2 sync config | `winget install Rclone.Rclone` | v1.68+ | Phase 8 |
| **k3sup** | K3s bootstrap over SSH — installs K3s server/agent remotely | Download from [GitHub releases](https://github.com/alexellis/k3sup/releases) | v0.14+ | Phase 0 (optional — can use raw SSH) |
| **talosctl** | Talos OS management CLI (DEFERRED — Q3 2026+) | `curl -sL https://talos.dev/install | sh` | v1.8+ | Deferred |
| **wrangler** | Cloudflare Workers/Pages CLI (if custom edge logic needed) | `npm install -g wrangler` | v3+ | Phase 7 (conditional) |

### Notes
- **kubectl config**: After K3s install, copy `/etc/rancher/k3s/k3s.yaml` from heart, replace `127.0.0.1` with heart's IP, save to `~/.kube/config`
- **Helm repos**: Add repos after Helm install (see Section 3)
- **talosctl**: Listed for completeness. Not needed until the OS migration in Q3 2026+

---

## 2. CLI Tools — On Nodes (via SSH)

### 2a. Control Plane Node (heart — CPX31, AlmaLinux 9)

| Tool / Package | Purpose | Install Method |
|----------------|---------|----------------|
| **K3s server** | Kubernetes control plane | `curl -sfL https://get.k3s.io \| INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy --disable=traefik" sh -` |
| **firewalld** | Host firewall | `dnf install firewalld` (likely pre-installed) |
| **fail2ban** | SSH brute-force protection | `dnf install fail2ban` |
| **dnf-automatic** | Automatic security patching | `dnf install dnf-automatic` |
| **auditd** | Audit logging (CIS compliance) | `dnf install audit` (likely pre-installed) |
| **curl / wget** | Download scripts, test endpoints | Pre-installed |
| **jq** | JSON parsing for scripts | `dnf install jq` |
| **htop** | Process monitoring (debugging) | `dnf install htop` |
| **crictl** | CRI container runtime debugging | Bundled with K3s |

### 2b. Worker Node (helix-worker-1 — CPX51, AlmaLinux 9)

Everything from the CP node above, plus:

| Tool / Package | Purpose | Install Method |
|----------------|---------|----------------|
| **K3s agent** | Kubernetes worker agent | `curl -sfL https://get.k3s.io \| K3S_URL=https://<heart-ip>:6443 K3S_TOKEN=<token> sh -` |
| **sysctl tuning** | Kernel parameter optimization | Applied via `/etc/sysctl.d/99-k8s-tuning.conf` |
| **iotop** | Disk I/O monitoring | `dnf install iotop` |
| **nvme-cli** | NVMe drive health checks | `dnf install nvme-cli` |

#### Kernel Parameters (helix-worker-1 only)
```
vm.swappiness=10
vm.max_map_count=262144
fs.inotify.max_user_watches=524288
fs.file-max=2097152
net.core.somaxconn=32768
net.ipv4.ip_forward=1
```

### 2c. External VPS (CX32, AlmaLinux 9)

| Tool / Package | Purpose | Install Method |
|----------------|---------|----------------|
| **Docker Engine** | Container runtime for management services | [Official Docker install for RHEL/AlmaLinux](https://docs.docker.com/engine/install/rhel/) |
| **Docker Compose** | Multi-container orchestration | `dnf install docker-compose-plugin` (v2, bundled with Docker) |
| **firewalld** | Host firewall | `dnf install firewalld` |
| **fail2ban** | SSH brute-force protection | `dnf install fail2ban` |
| **dnf-automatic** | Automatic security patching | `dnf install dnf-automatic` |
| **auditd** | Audit logging | `dnf install audit` |
| **rclone** | Sync MinIO backups to Backblaze B2 | `dnf install rclone` or [official install](https://rclone.org/install/) |
| **certbot** | Let's Encrypt TLS certificates (if not using nginx + acme) | `dnf install certbot` |
| **htop** | Process monitoring | `dnf install htop` |
| **jq** | JSON parsing | `dnf install jq` |
| **pg_dump** | PostgreSQL backup utility (from postgres client) | `dnf install postgresql` |
| **nginx** | Reverse proxy / TLS termination for VPS services | `dnf install nginx` OR run as Docker container |

---

## 3. Helm Charts (Installed into K3s Cluster)

Add these Helm repos on the local machine before starting Phase 3:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo add jetstack https://charts.jetstack.io
helm repo add devtron https://helm.devtron.ai
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

| Chart | Repo URL | Namespace | Phase | Purpose |
|-------|----------|-----------|-------|---------|
| **cilium/cilium** | `https://helm.cilium.io/` | `kube-system` | Phase 0/3 | CNI — pod networking, network policies, eBPF observability |
| **jetstack/cert-manager** | `https://charts.jetstack.io` | `cert-manager` | Phase 3 | Automatic TLS certificate management via Let's Encrypt |
| **external-secrets/external-secrets** | `https://charts.external-secrets.io` | `external-secrets` | Phase 3 | Sync secrets from OpenBao into K8s Secrets |
| **kyverno/kyverno** | `https://kyverno.github.io/kyverno/` | `kyverno` | Phase 3 | Policy engine — enforce image signing, resource limits, best practices |
| **cnpg/cloudnative-pg** | `https://cloudnative-pg.github.io/charts` | `cnpg-system` | Phase 4 | PostgreSQL operator — automated clusters, backups, failover |
| **prometheus-community/kube-prometheus-stack** | `https://prometheus-community.github.io/helm-charts` | `monitoring` | Phase 5 | Prometheus + Grafana + AlertManager + node-exporter + kube-state-metrics |
| **grafana/loki** | `https://grafana.github.io/helm-charts` | `monitoring` | Phase 5 | Log aggregation (pair with Promtail/Alloy) |
| **grafana/promtail** | `https://grafana.github.io/helm-charts` | `monitoring` | Phase 5 | Log shipping DaemonSet — sends logs to Loki |
| **cilium/tetragon** | `https://helm.cilium.io/` | `kube-system` | Phase 5 | Runtime security observability — syscall/process monitoring |
| **n8n** (community or custom) | Self-hosted chart or raw manifests | `apps` | Phase 6 | Workflow automation engine |
| **ollama** | Raw manifests (no official Helm chart) | `apps` | Phase 6 | Local LLM inference on CPU |
| **langfuse** (community or custom) | Self-hosted chart or raw manifests | `apps` | Phase 6 | AI/LLM observability — cost, latency, quality tracking |
| **vmware-tanzu/velero** | `https://vmware-tanzu.github.io/helm-charts` | `velero` | Phase 8 | Cluster backup and restore |
| **devtron** | `https://helm.devtron.ai` | `devtroncd` | Phase 9 | CI/CD platform (bundles ArgoCD) |

### Chart Install Notes
- **Cilium**: Install with `--set kubeProxyReplacement=true` and `--set hubble.enabled=true` for full eBPF + observability
- **Devtron**: Install with `--set postgresql.enabled=false` — point at CloudNativePG database (Phase 4)
- **kube-prometheus-stack**: Bundles Prometheus, Grafana, AlertManager, node-exporter, and kube-state-metrics in one chart
- **n8n / Langfuse / Ollama**: No official Helm charts with wide adoption. Plan to write custom manifests or use community charts. Track in Phase 6 preparation.
- **Traefik**: K3s bundles Traefik by default. If disabled during K3s install (`--disable=traefik`), install separately via `traefik/traefik` Helm chart in `traefik` namespace

---

## 4. Docker Images — External VPS (Docker Compose)

All services on the external VPS run via a single `docker-compose.yml`. Images listed with recommended tags.

| Service | Image | Tag | RAM Budget | Purpose |
|---------|-------|-----|------------|---------|
| **PostgreSQL** | `postgres` | `16-alpine` | 1.5 GB | Shared database for Harbor, Authentik, Netbird |
| **Redis** | `redis` | `7-alpine` | 512 MB | Shared cache/session store (logical DB separation) |
| **Harbor** (core) | `goharbor/harbor-core` | `v2.12+` | — | Container registry — core API |
| **Harbor** (portal) | `goharbor/harbor-portal` | `v2.12+` | — | Container registry — web UI |
| **Harbor** (registry) | `goharbor/harbor-registryctl` | `v2.12+` | — | Container registry — image storage |
| **Harbor** (jobservice) | `goharbor/harbor-jobservice` | `v2.12+` | — | Container registry — async jobs (scanning, replication) |
| **Harbor** (trivy adapter) | `goharbor/trivy-adapter` | `v2.12+` | — | Image vulnerability scanning |
| **Harbor** total | — | — | 1.5 GB | All Harbor components combined |
| **Authentik** (server) | `ghcr.io/goauthentik/server` | `2024.12+` | 768 MB | Identity provider — SAML/OIDC SSO |
| **Authentik** (worker) | `ghcr.io/goauthentik/server` | `2024.12+` | 768 MB | Background tasks (celery worker) |
| **Netbird** (management) | `netbirdio/management` | `latest` | 256 MB | Zero-trust VPN — peer management |
| **Netbird** (signal) | `netbirdio/signal` | `latest` | 128 MB | Zero-trust VPN — signaling server |
| **Netbird** (coturn) | `coturn/coturn` | `latest` | 128 MB | TURN/STUN relay for NAT traversal |
| **MinIO** | `minio/minio` | `latest` | 512 MB | S3-compatible object storage — Velero backup target |
| **OpenBao** | `openbao/openbao` | `latest` | 512 MB | Secrets vault — all credentials stored here |
| **Vaultwarden** | `vaultwarden/server` | `latest` | 256 MB | Bitwarden-compatible password manager |
| **nginx** | `nginx` | `1.27-alpine` | ~50 MB | Reverse proxy / TLS termination (optional — can use host nginx) |

### Docker Compose Placement
```
C:/Users/MSI LAPTOP/HelixStax/helix-stax-infra/
  vps/
    docker-compose.yml
    .env.example
    postgres/
      init.sql            # CREATE DATABASE harbor_db, authentik_db, netbird_db
      postgresql.conf      # Tuned config (shared_buffers=512MB, etc.)
    nginx/
      nginx.conf           # Reverse proxy for all VPS services
```

### Total VPS RAM Budget: ~7.5 GB (out of 8 GB, ~500 MB headroom)

---

## 5. PACT Skills Available (Claude Code Skills for the Buildout)

Skills available in `~/.claude/skills/` that are relevant to infrastructure work:

### Directly Relevant (Infrastructure & Operations)

| Skill | Purpose | Used In Phase |
|-------|---------|---------------|
| **k8s-ops** | Kubernetes operations — workloads, networking, storage, Helm charts, GitOps | All cluster phases (3–9) |
| **k8s-troubleshooter** | Diagnose K8s issues — pods, Helm, networking, performance | All cluster phases |
| **terraform-configuration** | Terraform module patterns, state management, provider config | Phase 1 |
| **docker-docs** | Dockerfile best practices, Compose patterns | Phase 2 (VPS services) |
| **secrets-management** | Vault/OpenBao patterns, secret rotation, ESO integration | Phase 2–3 |
| **observability** | Prometheus, Grafana, Loki, alerting, SLO/SLA design, runbook templates | Phase 5 |
| **debugging** | Root cause analysis, defense-in-depth, condition-based waiting | All phases (troubleshooting) |
| **incident-response** | Incident runbooks, post-incident reviews, escalation patterns | Phase 5+ (operational) |
| **git-advanced-workflows** | Branch strategies, worktrees, rebasing, conflict resolution | All phases (GitOps) |

### Supporting (Code Quality & Security)

| Skill | Purpose | Used In Phase |
|-------|---------|---------------|
| **pact-security-patterns** | OWASP top 10, auth patterns, data protection | Phase 2–3 (hardening) |
| **pact-architecture-patterns** | Design patterns, C4 diagrams, anti-patterns | Phase 1 (Terraform modules) |
| **pact-coding-standards** | Clean code, error handling | Phase 6 (app manifests) |
| **pact-testing-strategies** | Integration testing, test pyramid | Phase 8 (restore drills) |
| **production-code-audit** | Audit existing code for production readiness | Phase 9 (CI/CD review) |
| **pact-prepare-research** | Requirements analysis, technology comparison | Pre-phase research |

### Post-Buildout (Website & SEO)

| Skill | Purpose | Used When |
|-------|---------|-----------|
| **seo-audit** | Full SEO audit of helixstax.com | After website is live |
| **seo-technical** | Technical SEO (Core Web Vitals, crawlability) | After website is live |
| **schema-markup** | Structured data / JSON-LD | After website is live |
| **seo-geo** | GEO/AEO optimization | After website is live |

### Automation (n8n)

| Skill | Purpose | Used In Phase |
|-------|---------|---------------|
| **n8n-workflow-patterns** | Workflow design patterns (webhooks, scheduled, API integration) | Phase 6 |
| **n8n-node-configuration** | Node setup, operation patterns, dependencies | Phase 6 |
| **n8n-code-javascript** | Code node patterns (JS) | Phase 6 |
| **n8n-code-python** | Code node patterns (Python) | Phase 6 |
| **n8n-validation-expert** | Workflow validation, error catalog, false positive handling | Phase 6 |

---

## 6. Cloudflare Setup Requirements

### Account Type
- **Cloudflare Pro** ($20/month) — required for Cloudflare for Platforms (custom hostname support)
- Alternatively: **Cloudflare for SaaS** add-on on the Pro plan

### Cloudflare for Platforms Enrollment
- Needed for multi-tenant client hosting (Phase 7)
- Allows automatic SSL provisioning for client custom domains (e.g., `clientdomain.com`)
- Configured via API: create a custom hostname, Cloudflare handles DCV and SSL issuance
- Requires a "fallback origin" pointing at the K3s cluster (via Traefik ingress)

### API Token Scopes (for Terraform + automation)

Create a **scoped API token** (not the Global API Key) with these permissions:

| Permission | Scope | Used By |
|------------|-------|---------|
| `Zone:Zone:Read` | All zones | Terraform (DNS read) |
| `Zone:DNS:Edit` | `helixstax.com` zone | Terraform (DNS record management) |
| `Zone:SSL and Certificates:Edit` | `helixstax.com` zone | cert-manager DNS-01 challenge |
| `Zone:Zone Settings:Edit` | `helixstax.com` zone | Terraform (zone settings) |
| `Account:Cloudflare for SaaS:Edit` | Account level | n8n automation (custom hostname provisioning) |
| `Account:Account Settings:Read` | Account level | Terraform (account-level reads) |

### Wrangler CLI
- **Conditional** — only needed if custom Cloudflare Workers are used for edge logic (rate limiting, geolocation routing, etc.)
- Install: `npm install -g wrangler`
- Likely not needed until Phase 7 (multi-tenant) and possibly not at all if Traefik handles routing

### DNS Records to Create

| Record | Type | Value | Proxy | Phase |
|--------|------|-------|-------|-------|
| `helixstax.com` | A | Worker node IP | Proxied | Phase 1 |
| `*.helixstax.com` | A | Worker node IP | Proxied | Phase 1 |
| `grafana.internal.helixstax.com` | A | Worker node IP | DNS only (VPN access) | Phase 5 |
| `harbor.helixstax.com` | A | External VPS IP | Proxied | Phase 2 |
| `auth.helixstax.com` | A | External VPS IP | Proxied | Phase 2 |
| `vpn.helixstax.com` | A | External VPS IP | DNS only (Netbird needs direct) | Phase 2 |
| `vault.helixstax.com` | A | External VPS IP | DNS only (VPN access) | Phase 2 |

---

## 7. External Accounts & Services Required

| Service | Status | Purpose | Phase Needed | Notes |
|---------|--------|---------|--------------|-------|
| **Hetzner Cloud** | Existing | Server hosting (3 nodes) | Phase 0+ | heart, helix-worker-1, external VPS |
| **GitHub** | Existing | Source control, GitOps repos, CI webhooks | Phase 1+ | User: [[KeemWilliams|https://github.com/KeemWilliams]] |
| **Cloudflare** | Existing (needs upgrade check) | CDN, DNS, DDoS, SSL, custom hostnames | Phase 1+ | Verify Pro plan or Cloudflare for Platforms enrollment |
| **Backblaze B2** | Needs setup | Offsite backup storage (S3-compatible) | Phase 8 | Create bucket `helix-stax-velero-backups`. ~$0.30/mo for 50GB |
| **Google Workspace** | Existing | SAML SSO identity source (@helixstax.com) | Phase 2 | Authentik federates Google identity to all services |
| **Let's Encrypt** | Automatic | TLS certificates | Phase 2–3 | No account creation needed — cert-manager handles ACME automatically |
| **Docker Hub** | Existing (free tier) | Pull public images (rate-limited) | Phase 2+ | Harbor mirrors images to avoid rate limits |
| **RunPod / Lambda** | Deferred | On-demand GPU compute for heavy AI workloads | Post-buildout | Not needed until real-time AI demand exceeds CPU inference |
| **Telegram** | Existing (bot needs token rotation) | Alerting (Grafana → Telegram) | Phase 5 | Bot token currently returning 401 — rotate before Phase 5 |

### Credentials to Generate Fresh (Day 1 — stored in OpenBao)

Per the [[addendum-notes|addendum]], ALL credentials are generated fresh. Nothing carries over.

| Credential | For | Generated When |
|------------|-----|----------------|
| K3s server token | Cluster join token | Phase 0 (K3s install) |
| PostgreSQL superuser password | VPS shared PostgreSQL | Phase 2 |
| Harbor admin password | Container registry | Phase 2 |
| Authentik bootstrap password | SSO provider | Phase 2 |
| Netbird setup key | VPN management | Phase 2 |
| OpenBao root token + unseal keys | Secrets vault | Phase 2 |
| Vaultwarden admin token | Password manager | Phase 2 |
| MinIO root credentials | Object storage | Phase 2 |
| GitHub PAT (fine-grained) | Devtron GitOps push | Phase 9 |
| Cloudflare API token | Terraform + cert-manager | Phase 1 |
| Backblaze B2 app key | rclone sync | Phase 8 |
| Hetzner API token | Terraform + hcloud CLI | Phase 1 |
| Cosign keypair | Image signing | Phase 3 |

---

## 8. Pre-Flight Checklist

Everything below must be verified/installed **BEFORE Phase 0 begins** (wipe + harden + fresh K3s install).

### Local Machine (Windows 11)

- [ ] `kubectl` installed and in PATH — `kubectl version --client`
- [ ] `helm` installed and in PATH — `helm version`
- [ ] `terraform` installed and in PATH — `terraform version`
- [ ] `hcloud` installed and in PATH — `hcloud version`
- [ ] `gh` (GitHub CLI) installed and authenticated — `gh auth status`
- [ ] `docker` installed and running — `docker info`
- [ ] `jq` installed — `jq --version`
- [ ] `yq` installed — `yq --version`
- [ ] `python3` installed — `python --version`
- [ ] `cosign` installed — `cosign version`
- [ ] `ssh` key-based access to all 3 nodes verified — `ssh root@<ip> hostname`
- [ ] Hetzner API token available (not in plaintext — store in local encrypted file until OpenBao is up)
- [ ] Cloudflare API token created with required scopes (see Section 6)
- [ ] GitHub fine-grained PAT created for Devtron (can defer to Phase 9)
- [ ] `~/.kube/config` backup of current config (even though cluster is being wiped)
- [ ] Git repo `helix-stax-infra` cloned locally with expected directory structure

### Hetzner Cloud Console

- [ ] External VPS (CX32) provisioned — AlmaLinux 9, same Hetzner project, same network
- [ ] All 3 nodes accessible via SSH with key-based auth
- [ ] Hetzner network "Nerve" (10.0.0.0/16) confirmed — all nodes attached
- [ ] Firewall rules documented (current state snapshot before wipe)
- [ ] Load balancer `helix-k8s-api-lb` — decide: delete to save ~$6/mo? (Kit recommends yes)
- [ ] Hetzner snapshot of all nodes taken as safety net before wipe

### Cloudflare

- [ ] Domain `helixstax.com` active on Cloudflare
- [ ] Plan verified — Pro or Cloudflare for Platforms enrollment confirmed
- [ ] API token created and tested — `curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" -H "Authorization: Bearer <token>"`
- [ ] DNS records for VPS services planned (see Section 6 table)

### Backblaze B2

- [ ] Account created
- [ ] Bucket `helix-stax-velero-backups` created
- [ ] Application Key generated (restrict to bucket)

### Google Workspace

- [ ] Admin access to Google Workspace for @helixstax.com
- [ ] SAML/OIDC app configuration ready (will configure in Authentik Phase 2)

### Documentation

- [ ] [[addendum-notes|Addendum notes]] reviewed — clean install decisions confirmed
- [ ] [[05-operations/tech-stack|Tech stack]] approved — no pending changes
- [ ] This tools inventory reviewed and approved
- [ ] Sprint plan phases 0–9 understood and sequenced

### Credential Hygiene

- [ ] Existing plaintext credentials in memory files identified for scrubbing
- [ ] Local encrypted file prepared for temporary credential storage (Phase 0–1, before OpenBao)
- [ ] Old SSH keys rotated or confirmed still secure
- [ ] Telegram bot token rotation planned (currently 401)

### Deferred Items (Document but Don't Install)

- [ ] `talosctl` — noted for Q3 2026+ OS migration
- [ ] `longhorn` — noted for 3+ worker node expansion
- [ ] RunPod/Lambda accounts — noted for GPU rental when AI demand grows
- [ ] Wrangler CLI — only if Cloudflare Workers needed in Phase 7

---

*Generated: 2026-03-17. Cross-reference with [[05-operations/tech-stack]] for architectural decisions and [[addendum-notes]] for clean-install directives.*
