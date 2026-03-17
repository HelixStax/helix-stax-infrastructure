# Helix Stax Infrastructure

Production Kubernetes infrastructure for [Helix Stax](https://helixstax.com) — AI-powered consulting and automation platform.

## Stack

- **Orchestration**: K3s on Hetzner Cloud (AlmaLinux 9.7)
- **CNI**: Cilium (zero-trust networking)
- **Database**: CloudNativePG (PostgreSQL + pgvector + AGE + pg_analytics)
- **Ingress**: Traefik + Cloudflare for Platforms
- **CI/CD**: Devtron (bundles ArgoCD) + GitHub + Harbor
- **Monitoring**: Prometheus + Grafana + Loki
- **Secrets**: OpenBao + External Secrets Operator
- **Backup**: Velero → MinIO → Backblaze B2
- **AI**: Ollama (batch) + Claude/OpenAI APIs (real-time) + pgvector
- **Automation**: n8n + Flowise + Langchain
- **Identity**: Authentik (Google SAML SSO)
- **VPN**: Netbird (zero-trust)

## Architecture

```
Internet
    |
Cloudflare (CDN + DDoS + SSL)
    |
+--- Hetzner Cloud ------------------------------------+
|                                                       |
|  External VPS (8GB)       K3s Cluster                 |
|  +----------------+      +-------------------------+  |
|  | PostgreSQL     |      | helix-stax-cp (CP)      |  |
|  | Redis          |      |   K3s API + Scheduler   |  |
|  | Harbor         |      +-------------------------+  |
|  | Authentik      |                |                  |
|  | Netbird        |      +-------------------------+  |
|  | MinIO          |      | helix-stax-worker-1     |  |
|  | OpenBao        |      |   CloudNativePG         |  |
|  | Vaultwarden    |      |   Ollama + n8n          |  |
|  +----------------+      |   Traefik + Apps        |  |
|                           |   Prometheus + Grafana  |  |
|                           +-------------------------+  |
+-------------------------------------------------------+
    |
Backblaze B2 (offsite backups)
```

## Repo Structure

```
helix-stax-infrastructure/
├── docs/
│   ├── tech-stack.md              # Full tech stack reference
│   ├── tools-inventory.md         # CLIs, Helm charts, pre-flight checklist
│   ├── plans/
│   │   ├── sprint-plan.md         # 10-phase buildout plan
│   │   └── addendum-notes.md      # Decisions and context
│   └── tutorials/
│       ├── _index.md              # Tutorial series overview
│       └── phase-00-hardening/    # Step-by-step server hardening
├── terraform/                     # Infrastructure as Code (Phase 1)
├── helm/                          # Helm value overrides (Phase 3+)
├── CHANGELOG.md
└── README.md
```

## Buildout Progress

| Phase | Name | Status |
|-------|------|--------|
| 0 | Server Hardening | ✅ Complete |
| 1 | Foundation (Terraform + VPS) | Not started |
| 2 | Management Services | Not started |
| 3 | Cluster Security (Cilium) | Not started |
| 4 | Data Layer (CloudNativePG) | Not started |
| 5 | Observability | Not started |
| 6 | Application Layer | Not started |
| 7 | Multi-Tenant Hosting | Not started |
| 8 | Backup & DR | Not started |
| 9 | CI/CD Completion | Not started |

## Cost

| Item | Monthly |
|------|---------|
| Hetzner (3 nodes) | ~$46 |
| Backblaze B2 | ~$1-2 |
| Cloudflare for Platforms | ~$20-50 (scales with clients) |
| **Base** | **~$48** |
| **With 10+ client sites** | **~$70-100** |

## License

Private repository. All rights reserved.
