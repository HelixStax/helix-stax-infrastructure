# Helix Stax Infrastructure

IaC, configuration, and operational docs for the Helix Stax platform — a self-hosted
Kubernetes environment on Hetzner Cloud.

## Stack

| Layer | Tool |
|-------|------|
| Provisioning | OpenTofu + Hetzner Cloud |
| OS hardening | Ansible (CIS Level 1, SELinux enforcing) |
| Orchestration | K3s on AlmaLinux 9.7 |
| Ingress | Traefik + Cloudflare (CDN, WAF, Zero Trust) |
| Identity | Zitadel (OIDC/SAML) |
| Database | CloudNativePG (PostgreSQL) |
| Cache | Valkey |
| Secrets | OpenBao + External Secrets Operator |
| Registry | Harbor |
| Object storage | MinIO |
| CI/CD | Devtron + ArgoCD |
| Monitoring | Prometheus + Grafana + Loki |
| IDS | CrowdSec |
| Backup | Velero → MinIO → Backblaze B2 |

All production workloads deploy via Helm charts through Devtron CD. No Docker Compose in production.

## Nodes

| Name | Role | IP |
|------|------|----|
| heart | Control plane | 178.156.233.12 |
| helix-worker-1 | Worker | 138.201.131.157 |

## Directory Structure

```
helix-stax-infrastructure/
├── opentofu/          # Hetzner provisioning, Cloudflare DNS, firewall rules
├── ansible/           # OS hardening, K3s install, CrowdSec, dev-sec roles
├── helm/              # Helm value overrides for all in-cluster services
├── docs/
│   ├── architecture/  # ADRs
│   ├── plans/         # Sprint plans and decisions
│   ├── runbooks/      # Break-glass and operational procedures
│   ├── sops/          # Standard operating procedures
│   └── tutorials/     # Step-by-step phase walkthroughs
├── scripts/           # One-off tooling and helpers
└── shared/            # Configs shared across layers
```

## Security Model

- Cloudflare edge: DDoS protection, WAF, Zero Trust access for internal services
- CrowdSec: Host-level IDS with crowdsourced threat intelligence
- Ansible hardening runs before K3s install — CIS Level 1, SELinux enforcing, SSH lockdown
- No secrets in git — all secrets via OpenBao, consumed by ESO into K3s secrets

## Domains

- `helixstax.com` — public website, email, Google Workspace
- `helixstax.net` — internal platform services (Grafana, Devtron, n8n, Rocket.Chat)

## Key Docs

- [Architecture decisions](docs/architecture/) — ADRs for all major choices
- [Runbooks](docs/runbooks/) — incident response and operational procedures
- [Sprint plan](docs/plans/sprint-plan.md) — phased buildout sequence

## License

Private repository. All rights reserved.
