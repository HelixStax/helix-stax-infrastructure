---
tags: [infrastructure, tech-stack, helix-stax, reference]
created: 2026-03-17
updated: 2026-03-17
status: approved
---

# Helix Stax Technical Stack

> One-pager for explaining the Helix Stax infrastructure to clients, partners, or team members.

## Overview

Helix Stax runs on a lean Kubernetes infrastructure hosted on [[Hetzner]] Cloud. Designed for multi-tenant client hosting, AI-powered automation, and SEO consulting delivery — all for under $100/month.

---

## Infrastructure ($48/month base)

### Hetzner Cloud Servers (3 nodes)

| Node | Spec | Role | Cost |
|------|------|------|------|
| heart | CX32 (8GB RAM) | K3s control plane — the brain that schedules workloads | ~$8/mo |
| helix-worker-1 | CPX51 (64GB RAM, 16 vCPU) | Worker — runs all apps, databases, AI | ~$30/mo |
| External VPS | CX32 (8GB RAM) | Management — auth, container registry, backups | ~$8/mo |

### What is K3s?

K3s is a lightweight version of Kubernetes (K8s). Same technology, same capabilities, less overhead. Saves ~2-3GB RAM that goes to your actual workloads instead. Everything that runs on K3s works identically on full K8s.

---

## Networking & Security

| Layer | Tool | What it does |
|-------|------|-------------|
| Edge CDN & DDoS | [[Cloudflare]] for Platforms | Caches content globally, blocks attacks, manages SSL for all client domains automatically |
| Ingress routing | [[Traefik]] | Receives traffic from Cloudflare and routes it to the correct app/site inside the cluster |
| Network isolation | [[Cilium]] | Controls which containers can talk to each other. Default-deny — nothing communicates unless explicitly allowed |
| Zero-trust VPN | [[Netbird]] | Private encrypted tunnel for admin access. No open ports on servers |
| Identity & SSO | [[Authentik]] | Single sign-on for all dashboards. External to the cluster so you can always log in even if the cluster is down |
| TLS certificates | cert-manager + Let's Encrypt | Automatic HTTPS for internal services |

---

## Database Layer

### [[CloudNativePG]] — One Database To Rule Them All

CloudNativePG is a Kubernetes operator that automatically manages PostgreSQL. Instead of running 5 separate database engines, we run one managed PostgreSQL with extensions:

| Instead of... | We use... | What it does |
|--------------|-----------|-------------|
| Separate Postgres instances | CloudNativePG | One managed database with automated backups, failover, and upgrades |
| Qdrant (vector database) | pgvector extension | Stores AI embeddings for semantic search |
| Neo4j (graph database) | AGE extension | Graph queries like "show me all clients connected to this keyword cluster" |
| ClickHouse (analytics) | pg_analytics extension | Fast analytical queries for reporting dashboards |

**Result**: ~8-12GB RAM saved. One backup strategy. One thing to monitor.

### External VPS Databases

A separate small PostgreSQL + Redis on the external VPS serves management tools ([[Harbor]], [[Authentik]], [[Netbird]]). These stay outside the cluster so they're available even during cluster outages.

---

## AI & Automation

| Workload | Tool | How it works |
|----------|------|-------------|
| Real-time AI (client-facing) | Claude / OpenAI APIs | Fast responses for interactive features. Pay per use |
| Background AI (batch tasks) | [[Ollama]] (on CPU) | Document summarization, content classification, SEO analysis. ~12 tokens/sec — fine for queued work |
| GPU compute | RunPod / Lambda | Rented on-demand when heavy AI work is needed. No cost when idle |
| Vector storage | pgvector | Embeddings stored in [[CloudNativePG]] |
| Workflow automation | [[n8n]] | Visual workflow builder. Connects everything — AI pipelines, client onboarding, reports, notifications |
| AI observability | [[Langfuse]] | Tracks AI costs, latency, and quality across all LLM calls |

---

## Multi-Tenant Client Hosting

| Feature | How |
|---------|-----|
| Starter tier | `clientname.helixstax.com` — free, one Cloudflare zone |
| Custom domain | `clientdomain.com` — [[Cloudflare]] for Platforms handles SSL automatically |
| Onboarding | [[n8n]] workflow: add domain to Cloudflare -> create Traefik route -> create database record -> site appears in client portal |
| Isolation | Each client gets resource limits (ResourceQuotas) so one site can't crash another |
| Client portal | React app behind [[Authentik]] auth — clients see reports, project status, invoices |

---

## CI/CD & Deployment

| Component | Tool | What it does |
|-----------|------|-------------|
| Source control | GitHub | All code lives here. Single source of truth |
| CI/CD + GitOps | [[Devtron]] (bundles ArgoCD) | Push code to GitHub -> Devtron builds -> scans for vulnerabilities -> deploys to cluster |
| Container registry | [[Harbor]] | Private Docker image storage on the external VPS |
| Image scanning | Trivy (in Harbor) | Every image scanned for vulnerabilities before deployment |
| Image signing | Cosign + Kyverno | Only signed, verified images can run in the cluster |
| Package manager | [[Helm]] | Installs and upgrades apps on K3s. Like apt-get for Kubernetes |

---

## Observability

| Component | Tool | RAM | Purpose |
|-----------|------|-----|---------|
| Metrics | [[Prometheus]] | ~1.5GB | Collects numbers — CPU, RAM, request counts, error rates |
| Dashboards | [[Grafana]] | ~500MB | Visualizes metrics. Pretty graphs, alerts. Web UI accessible via browser |
| Logs | [[Loki]] | ~1.5GB | Centralized log storage. Search across all containers |
| Runtime security | Tetragon | ~300MB | Monitors container behavior for suspicious activity |

> Access Grafana at `grafana.internal.helixstax.com` via Netbird VPN, or expose dashboards through the client portal.

---

## Backup & Disaster Recovery

| Layer | Tool | Schedule |
|-------|------|----------|
| Cluster backup | [[Velero]] | Nightly |
| First tier | MinIO (external VPS) | Receives backups via S3 protocol |
| Offsite | Backblaze B2 | Second copy in a separate data center (~$1-2/mo) |
| Retention | — | 7 daily / 4 weekly / 3 monthly |
| Encryption | Kopia | All backups encrypted at rest |

---

## Secrets Management

| Component | Tool | Purpose |
|-----------|------|---------|
| Secrets vault | [[OpenBao]] | Stores all credentials, API keys, certificates (external VPS) |
| K8s integration | External Secrets Operator | Syncs secrets from OpenBao into Kubernetes automatically |
| Password manager | Vaultwarden | Team password management (Bitwarden-compatible) |

---

## Storage

| Type | Tool | Why |
|------|------|-----|
| Current | local-path-provisioner | Uses NVMe drives directly. 6-17x faster than distributed storage |
| Future (3+ nodes) | Longhorn | Distributed storage that replicates data across nodes |

---

## What We Don't Use (and Why)

| Dropped | Why |
|---------|-----|
| Gravitee (API gateway) | Java-based, 2-4GB RAM. [[Traefik]] does the same at 50MB |
| Kong | Not needed yet |
| GitLab | Redundant with GitHub |
| Kargo | Redundant with [[Devtron]] |
| Qdrant | pgvector extension covers vector search |
| Neo4j | AGE extension covers graph queries |
| ClickHouse | pg_analytics covers analytics |
| Longhorn | No benefit with one worker node. Deferred |
| Istio/Linkerd (service mesh) | [[Cilium]] + [[Netbird]] sufficient |
| Ansible | Terraform + GitOps handles everything |
| Talos OS | Deferred until 3+ nodes |

---

## Cost Summary

| Item | Cost |
|------|------|
| Hetzner (3 nodes) | ~$46/mo |
| Backblaze B2 | ~$1-2/mo |
| Cloudflare for Platforms | ~$20-50/mo (scales with clients) |
| Claude/OpenAI APIs | Usage-based |
| GPU rental | On-demand |
| **Base (no clients)** | **~$48/mo** |
| **With 10+ client sites** | **~$70-100/mo** |

---

## Scaling Roadmap

| Trigger | Action |
|---------|--------|
| Worker RAM > 80% consistently | Add 2nd worker node (~$30/mo) |
| 3+ worker nodes | Migrate to Talos OS, enable Longhorn |
| Real-time AI demand | Rent GPU instances (RunPod/Lambda) |
| 50+ client sites | Dedicated database server |
| Enterprise clients | SOC 2 certification |

---

## Architecture Diagram

```
Internet
    |
Cloudflare (CDN + DDoS + SSL)
    |
+--- Hetzner Cloud ----------------------------------------+
|                                                           |
|  External VPS (8GB)          K3s Cluster                  |
|  +----------------+         +---------------------------+ |
|  | PostgreSQL     |         | heart (Control Plane)     | |
|  | Redis          |         |   K3s API server          | |
|  | Harbor         |         |   Scheduler               | |
|  | Authentik      |         +---------------------------+ |
|  | Netbird        |                   |                   |
|  | MinIO          |         +---------------------------+ |
|  | OpenBao        |         | helix-worker-1 (64GB)     | |
|  | Vaultwarden    |         |   CloudNativePG           | |
|  +----------------+         |   Ollama                  | |
|   "Recovery tier"           |   n8n + Langfuse          | |
|                             |   Traefik                 | |
|                             |   Client apps/sites       | |
|                             |   Prometheus + Grafana    | |
|                             |   Loki + Tetragon         | |
|                             +---------------------------+ |
|                              "Business tier"              |
+-----------------------------------------------------------+
    |
Backblaze B2 (offsite backups)
```

---

## External VPS Memory Budget

| Service | RAM |
|---------|-----|
| Shared PostgreSQL | 1.5GB |
| Shared Redis | 512MB |
| Harbor | 1.5GB |
| Authentik | 1.5GB |
| Netbird | 512MB |
| MinIO | 512MB |
| OpenBao | 512MB |
| Vaultwarden | 256MB |
| **Headroom** | **~256MB** |

---

*Source: Gemini Deep Research infrastructure review (2026-03-17) + specialist reviews by [[06-agents/stax-architect|Cass]], [[06-agents/stax-devops-engineer|Kit]], and [[06-agents/stax-security-engineer|Ezra]].*
