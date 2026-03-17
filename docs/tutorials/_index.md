---
tags: [tutorial, infrastructure, helix-stax, series]
created: 2026-03-17
updated: 2026-03-17
status: planning
---

# Infrastructure Buildout Tutorial Series

> Step-by-step guide to building a production Kubernetes infrastructure from scratch on Hetzner Cloud. Each phase is a standalone tutorial suitable for website articles, video scripts, and documentation.

## Prerequisites
- [[05-operations/tech-stack|Tech Stack Reference]]
- Hetzner Cloud account
- GitHub account
- Domain pointed to Cloudflare

## Phases

### Phase 1: Foundation
> Terraform, Hetzner resource codification, External VPS provisioning
- Folder: [[phase-01-foundation/]]
- Status: Not started

### Phase 2: Management Services
> Harbor, Authentik, Netbird, OpenBao, Vaultwarden, MinIO on External VPS
- Folder: [[phase-02-management-services/]]
- Status: Not started

### Phase 3: Cluster Security
> Cilium CNI migration, Pod Security Admission, External Secrets Operator, Cosign + Kyverno
- Folder: [[phase-03-cluster-security/]]
- Status: Not started

### Phase 4: Data Layer
> CloudNativePG operator, PostgreSQL cluster, pgvector, AGE, pg_analytics
- Folder: [[phase-04-data-layer/]]
- Status: Not started

### Phase 5: Observability
> Prometheus, Grafana, Loki, Tetragon
- Folder: [[phase-05-observability/]]
- Status: Not started

### Phase 6: Application Layer
> n8n, Ollama, Langfuse, namespace ResourceQuotas
- Folder: [[phase-06-application-layer/]]
- Status: Not started

### Phase 7: Multi-Tenant & Client Hosting
> Cloudflare for Platforms, dynamic Traefik routing, React + React Flow client portal
- Folder: [[phase-07-multi-tenant/]]
- Status: Not started

### Phase 8: Backup & Disaster Recovery
> Velero, MinIO, Backblaze B2, restore testing
- Folder: [[phase-08-backup-dr/]]
- Status: Not started

### Phase 9: CI/CD Completion
> Devtron + GitHub integration, Harbor push pipeline, environment promotion
- Folder: [[phase-09-cicd/]]
- Status: Not started

---

## Content Output Per Phase
Each phase produces:
1. **Tutorial article** — Step-by-step walkthrough for helixstax.com blog
2. **Video script** — Narrated screen recording outline
3. **Commands/config** — Copy-paste ready code blocks
4. **Handoff doc** — What the next phase needs to know
5. **Lesson learned** — Gotchas and tips for the audience

---

*This series documents the real infrastructure buildout of [[Helix Stax]] — not a lab exercise. Every decision, mistake, and fix is captured for educational content.*
