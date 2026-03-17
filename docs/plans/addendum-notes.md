---
tags: [infrastructure, planning, notes]
created: 2026-03-17
updated: 2026-03-17
---

# Sprint Plan Addendum Notes

These notes MUST be incorporated into the sprint plan.

## CRITICAL DECISION: Full Wipe + Clean Install

**User directive**: Wipe both nodes completely. Nothing is worth keeping. Fresh install from scratch.

### What this means
- NO migration of any existing services (Devtron, ArgoCD, Flannel — all gone)
- NO data preservation from current cluster
- **KEEP the existing AlmaLinux OS** on all 3 nodes — do NOT reinstall the OS
- Just wipe K3s (`k3s-uninstall.sh`) and all cluster workloads
- External VPS: stop and remove all Docker containers/services
- Every service reinstalled intentionally from the sprint plan
- Every credential generated fresh and stored in OpenBao from Day 1
- NO plaintext passwords anywhere — OpenBao is the single source of truth for secrets
- Existing plaintext creds in memory files must be scrubbed

### Benefits of clean install
- Cilium installed as Day 1 CNI (no Flannel migration risk)
- Devtron installed pointing at CloudNativePG from the start (no database migration)
- No bundled MinIO/Postgres/Nats cruft from Devtron
- Hardening applied before any services exist
- Everything documented step-by-step for tutorial content
- Clean audit trail — every change is intentional and recorded

---

## Revised Phase 0: Wipe + Harden + Optimize

### Step 1: Wipe (cluster only, keep OS)
1. Backup nothing (user confirmed nothing worth keeping)
2. On heart (CP): `k3s-uninstall.sh` — removes K3s server + all cluster data
3. On helix-worker-1: `k3s-agent-uninstall.sh` — removes K3s agent
4. On external VPS: `docker stop $(docker ps -aq) && docker system prune -af` — remove all containers
5. Clean up leftover dirs: `/var/lib/rancher/`, `/etc/rancher/`, stale CNI configs

### Step 2: Harden existing OS (all 3 nodes)
- CIS Benchmark for AlmaLinux 9
- SSH: key-only auth, disable root login, disable password auth
- Firewall: firewalld with strict rules (only required ports)
- fail2ban for SSH brute force protection
- Automatic security updates (dnf-automatic)
- Audit logging (auditd)
- Remove unnecessary packages and services
- Credential rotation: ALL old passwords are dead — generate everything fresh

### Step 3: Worker Node Optimization (helix-worker-1 only)

#### Kernel Parameters
- `vm.swappiness=10` (minimize swap usage for database workloads)
- `vm.max_map_count=262144` (required for Elasticsearch-like workloads)
- `fs.inotify.max_user_watches=524288` (K8s needs high inotify limits)
- `fs.file-max=2097152` (high file descriptor limit for many pods)
- `net.core.somaxconn=32768` (connection backlog for Traefik)
- `net.ipv4.ip_forward=1` (required for CNI)

#### Kubelet Resource Reservation
- Reserve 2GB RAM + 1 CPU for system/kubelet
- Effective workload capacity: ~61GB RAM, 15 vCPU

#### Swap Configuration
- 4GB swap file as emergency overflow only
- `vm.swappiness=10` so it's rarely used

#### Disk I/O
- Verify NVMe is being used (not virtio-blk)
- Set I/O scheduler to `none` for NVMe
- Check TRIM/discard support

### Step 4: Fresh K3s Install
- Install K3s on heart (control plane) with `--flannel-backend=none` (we're using Cilium)
- Install Cilium as the CNI immediately (Day 1, not a migration)
- Join helix-worker-1 to the cluster
- Verify cluster is healthy: `kubectl get nodes`

---

## Secrets Management Strategy (Day 1)

Every credential generated during the buildout follows this flow:

```
Generate credential
    ↓
Store in OpenBao immediately (Phase 2)
    ↓
External Secrets Operator syncs to K8s (Phase 3)
    ↓
Apps read from K8s secrets (never hardcoded)
    ↓
User copies to Vaultwarden for personal access
```

For Phase 0-1 (before OpenBao exists): store credentials temporarily in a local encrypted file, then migrate to OpenBao as soon as it's deployed in Phase 2. NEVER commit credentials to git or memory files.

---

## Google SAML SSO via Authentik (Phase 2)

Authentik must be configured as a SAML/OIDC broker with Google Workspace:
- Google Workspace is the identity source (@helixstax.com accounts)
- Authentik federates Google identity to all internal services
- Services that get SSO: Grafana, Devtron, n8n, client portal, Harbor
- Client portal: clients can also "Sign in with Google" (their own Google accounts)
- RBAC: Authentik maps Google groups/email domains to roles (admin, client, viewer)
- Setup: Authentik admin → Providers → SAML → Google Workspace integration

---

## Devtron: Clean Install (NOT Migration)

Since we're wiping everything, Devtron gets a fresh install in Phase 9:
- Install Devtron Helm chart with `--set postgresql.enabled=false`
- Point Devtron at CloudNativePG connection string (Phase 4 database already exists)
- Point Devtron at external Harbor registry (Phase 2 already exists)
- Configure GitHub PAT integration fresh
- No bundled MinIO — build artifacts go to external MinIO or are ephemeral
- No bundled PostgreSQL — uses the shared CloudNativePG instance
- No bundled ArgoCD conflicts — Devtron manages its own ArgoCD cleanly

---

## Tutorial Content Note

This clean-install approach is IDEAL for tutorial content:
- Every step is documented from zero
- No "if you have existing X, do Y" branching
- Readers/viewers can follow along exactly
- Real production buildout, not a sanitized lab
- Mistakes and fixes are captured as learning content
