---
tags: [infrastructure, sprint-plan, kubernetes, helix-stax, tutorial-series]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Sable (Product Manager)
reviewers: [Cass (Architect), Kit (DevOps), Ezra (Security)]
total-phases: 10
estimated-sessions: 28-38
estimated-calendar-weeks: 10-14
---

# Infrastructure Buildout Sprint Plan

> Master plan for the 10-phase Kubernetes infrastructure buildout on Hetzner Cloud. Each phase produces working infrastructure AND tutorial content for the [[05-operations/tech-stack|Helix Stax website]].
>
> **Audience**: Mid-level DevOps engineers and technical founders building production infrastructure on a startup budget.

---

## Current State (Starting Point)

| Component | Status | Details |
|-----------|--------|---------|
| **OS** | Running | AlmaLinux 9.7 on both nodes |
| **K3s** | Running | v1.34.4+k3s1, freshly reinstalled 2026-03-10 |
| **CNI** | Running | Flannel (no NetworkPolicy enforcement) |
| **Ingress** | Running | Traefik (bundled) |
| **Storage** | Running | local-path-provisioner (bundled) |
| **CI/CD** | Running | Devtron + embedded ArgoCD |
| **Monitoring** | NONE | Blind -- no metrics, no logs, no alerts |
| **Backups** | NONE | No recovery path |
| **External VPS** | NOT provisioned | Planned CX32 (8GB) |
| **Secrets mgmt** | NONE | Credentials in plaintext memory files |

### Nodes

| Node | Spec | IP | Role |
|------|------|----|------|
| heart | CPX31 (4 vCPU, 8GB) | 178.156.233.12 | Control plane |
| helix-worker-1 | CPX51 (16 vCPU, 64GB) | 138.201.131.157 | Worker |
| External VPS | CX32 (4 vCPU, 8GB) | TBD | Management services |

---

## Dependency Diagram

```
Phase 0: Server Hardening
    |
    v
Phase 1: Foundation (Terraform + VPS Provisioning)
    |
    +---> Phase 2: Management Services (Harbor, Authentik, Netbird, OpenBao, MinIO)
    |         |
    |         +---> Phase 3: Cluster Security (Cilium, PSA, ESO, Kyverno)
    |         |         |
    |         |         +---> Phase 4: Data Layer (CloudNativePG, extensions)
    |         |         |         |
    |         |         |         +---> Phase 6: Application Layer (n8n, Ollama, Langfuse)
    |         |         |         |         |
    |         |         |         |         +---> Phase 7: Multi-Tenant (Cloudflare, client portal)
    |         |         |         |
    |         |         +---> Phase 5: Observability (Prometheus, Grafana, Loki, Tetragon)
    |         |
    |         +---> Phase 8: Backup & DR (Velero, MinIO, B2)
    |
    +---> Phase 9: CI/CD Completion (Devtron pipelines, Harbor integration)
```

**Key dependency chains**:
- Phase 0 -> 1 -> 2 -> 3 (strict sequence -- each builds on the prior)
- Phase 3 unlocks both Phase 4 and Phase 5 (can run in parallel)
- Phase 4 -> 6 -> 7 (strict sequence -- apps need databases, multi-tenant needs apps)
- Phase 2 -> 8 (backups need MinIO on VPS)
- Phase 2 -> 9 (CI/CD needs Harbor on VPS)
- Phases 5, 8, and 9 are parallelizable after their prerequisites are met

---

## Known Issues and Lessons Learned

> Sourced from [[infrastructure_k3s|K3s memory]], [[infrastructure_hetzner|Hetzner memory]], [[lessons_infrastructure|lessons learned]], and specialist reviews.

### Critical Issues

| Issue | Source | Impact | Addressed In |
|-------|--------|--------|--------------|
| **Plaintext credentials in memory files** | Ezra (P0) | Devtron, ArgoCD passwords exposed in `infrastructure_k3s.md` | Phase 0 |
| **Cilium eBPF + firewalld race condition** | Lessons learned | Crashed Devtron pods, forced fallback to Flannel | Phase 3 |
| **Devtron reinstall fragility** | Lessons learned | ArgoCD must use official stable manifest, not devtron/argocd chart | Phase 9 |
| **Hetzner AlmaLinux IPv6-only DNS** | Lessons learned | CoreDNS fails without IPv4 nameservers in resolv.conf | Phase 0 |
| **No backups exist** | Kit | Complete data loss on any node failure | Phase 8 |
| **K8s API + Devtron exposed on public IP** | Ezra | Attack surface -- 6443 and 31656 reachable from internet | Phase 0 |

### Specialist Review Conflicts

| Topic | Cass (Architect) | Kit (DevOps) | Ezra (Security) | Resolution |
|-------|-----------------|--------------|-----------------|------------|
| **Monitoring first vs. safety net first** | Phase 0 = external VPS | Phase 1 = monitoring | Phase 0 = credential rotation | **Phase 0 = hardening + creds. Phase 1 = Terraform + VPS. Monitoring in Phase 5 after cluster security.** Rationale: can't monitor securely without Cilium NetworkPolicies; hardening and VPS are prerequisites for everything. |
| **Cilium migration timing** | Phase 3 (after workload architecture) | Defer until monitoring exists | Phase 1 priority | **Phase 3** -- after VPS + management services so Netbird is available as fallback access before disabling firewalld. |
| **CX32 memory budget** | 7.5GB tight but viable | 7.5GB with 500MB headroom | OpenBao adds memory pressure | **Proceed with CX32. Monitor. Upgrade to CX42 if OOM within 30 days.** |
| **Harbor Trivy scanner** | Disable on VPS to save RAM | Not mentioned | Enable scan-on-push | **Disable Trivy on Harbor (save ~1GB). Scan in Devtron CI pipeline via Trivy CLI instead.** |

---

## Phase 0: Server Hardening

> **Goal**: Harden both existing nodes to CIS benchmarks, rotate all exposed credentials, and close public-facing attack surface before building anything new.

### Prerequisites
- SSH access to both nodes (heart + helix-worker-1)
- Hetzner Cloud Console access
- Current credentials from `~/.claude/helix-stax-secrets/`

### Specialist Team
- **Ezra** (Security Engineer) -- CIS benchmarks, SSH hardening, credential rotation
- **Kit** (DevOps Engineer) -- firewalld rules, auto-updates, DNS fix

### Tasks

1. **Credential rotation** (P0 -- do first)
   - Remove all plaintext credentials from `infrastructure_k3s.md`
   - Move credential references to `~/.claude/helix-stax-secrets/` (names only in memory files)
   - Rotate Devtron admin password: `kubectl -n devtroncd patch secret devtron-secret -p '{"data":{"ADMIN_PASSWORD":"<new-base64>"}}'`
   - Rotate ArgoCD admin password: `argocd account update-password`
   - Rotate ArgoCD devtron account password
   - Document new credentials ONLY in secrets store

2. **SSH hardening** (both nodes)
   - Disable root password login: `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config`
   - Disable password authentication entirely: `PasswordAuthentication no`
   - Change SSH port from 22 to a non-standard port (e.g., 2222)
   - Set `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`
   - Restart sshd: `systemctl restart sshd`

3. **Firewall hardening** (both nodes, using firewalld -- will be replaced by Cilium in Phase 3)
   - Restrict SSH to current admin IP only: `firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>" port port="2222" protocol="tcp" accept'`
   - Remove default SSH service: `firewall-cmd --permanent --remove-service=ssh`
   - Restrict K8s API (6443) to admin IP + cluster network only
   - Restrict Devtron NodePort (31656) to admin IP only
   - Ensure Hetzner Cloud Firewall (`helix-cp-firewall`, ID: 10604292) mirrors these rules as perimeter defense
   - Apply firewall to helix-worker-1 as well (currently no Hetzner firewall assigned)

4. **CIS benchmark hardening** (AlmaLinux 9)
   - Install and run `kube-bench`: `kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml`
   - Review and remediate findings (target: pass all Level 1 checks)
   - Enable K3s secrets encryption at rest:
     ```bash
     # Create /var/lib/rancher/k3s/server/encryption-config.yaml
     # Restart K3s with --secrets-encryption
     k3s secrets-encrypt reencrypt
     ```
   - Enable K3s audit logging:
     ```bash
     # Add to K3s server args:
     --kube-apiserver-arg="audit-log-path=/var/log/k8s-audit.log"
     --kube-apiserver-arg="audit-log-maxage=30"
     --kube-apiserver-arg="audit-log-maxbackup=10"
     --kube-apiserver-arg="audit-log-maxsize=100"
     ```

5. **Automatic security updates** (both nodes)
   - Install and enable `dnf-automatic`:
     ```bash
     dnf install -y dnf-automatic
     # Edit /etc/dnf/automatic.conf:
     # apply_updates = yes
     # upgrade_type = security
     systemctl enable --now dnf-automatic-install.timer
     ```

6. **fail2ban** (both nodes)
   - Install: `dnf install -y fail2ban`
   - Configure SSH jail with custom port
   - Enable: `systemctl enable --now fail2ban`

7. **DNS fix** (both nodes -- prevent CoreDNS failures)
   - Verify `/etc/resolv.conf` contains IPv4 nameservers: `185.12.64.1`, `185.12.64.2`, `8.8.8.8`
   - Persist via cloud-init user data (for future reprovisioning)

8. **Delete unnecessary load balancer**
   - Delete `helix-k8s-api-lb` (ID: 5886481) -- serves no HA purpose with single CP node
   - Saves ~$6/mo

### Acceptance Criteria
- [ ] Zero plaintext credentials in any memory or docs file
- [ ] SSH reachable only via key auth on non-standard port from admin IP
- [ ] `kube-bench` Level 1 checks pass (or documented exceptions)
- [ ] K3s secrets encrypted at rest (`k3s secrets-encrypt status` shows "Enabled")
- [ ] Audit logging active (`ls /var/log/k8s-audit.log` exists and growing)
- [ ] `dnf-automatic` timer active on both nodes
- [ ] fail2ban running on both nodes
- [ ] Hetzner Cloud Firewall applied to BOTH nodes (not just heart)
- [ ] Load balancer deleted

### Handoff to Phase 1
- SSH connection details (new port, key-only)
- Hetzner firewall rule IDs (for Terraform import)
- CIS benchmark report (pass/fail/exception list)
- Credential rotation log (which credentials were rotated, where they now live)

### Tutorial Content Deliverables
- **Article**: "Hardening AlmaLinux 9 for Kubernetes: CIS Benchmarks, SSH, and Firewall"
- **Video**: "Server Hardening Before Kubernetes -- The Step Everyone Skips"
- **Screenshots/recordings needed**: kube-bench output, firewalld rules, sshd_config diff, fail2ban status

### Estimated Effort
2-3 sessions

### Risks and Gotchas
- Locking yourself out of SSH if firewall rules are wrong -- always keep a Hetzner Console session open as backdoor
- K3s secrets-encrypt reencrypt can take time on large clusters -- this cluster is small, should be fast
- fail2ban + firewalld can conflict -- test ban/unban cycle after setup
- DNS fix must persist across reboots -- verify with `reboot` + check resolv.conf

---

## Phase 1: Foundation (Terraform + VPS Provisioning)

> **Goal**: Codify all existing Hetzner infrastructure in Terraform and provision the External VPS (CX32) for management services.

### Prerequisites
- Phase 0 complete (hardened nodes, rotated credentials)
- Hetzner API token (stored in `~/.claude/.env.secrets`)
- Cloudflare API token for DNS management
- `helix-stax-infra` repo initialized

### Specialist Team
- **Kit** (DevOps Engineer) -- Terraform modules, VPS provisioning
- **Cass** (Architect) -- Module structure review

### Tasks

1. **Initialize Terraform project**
   ```
   helix-stax-infra/
     terraform/
       main.tf
       variables.tf
       outputs.tf
       modules/
         hetzner-network/
         hetzner-server/
         hetzner-firewall/
         cloudflare-dns/
       environments/
         production/
           main.tf
           terraform.tfvars
           backend.tf
   ```

2. **Import existing Hetzner resources** (read-only, no changes)
   ```bash
   terraform import module.hetzner_network.hetzner_network.nerve 11913771
   terraform import module.hetzner_server.hetzner_server.heart 117889841
   terraform import module.hetzner_firewall.hetzner_firewall.cp 10604292
   ```

3. **Validate `terraform plan` shows no changes** (imported state matches reality)

4. **Provision External VPS via Terraform**
   - CX32 (4 vCPU, 8GB RAM, 80GB NVMe) in Ashburn DC
   - Attach to Nerve network (10.0.0.0/16)
   - Apply firewall rules (SSH from admin IP, internal cluster traffic)
   - cloud-init: install Docker, set up DNS, create data directories

5. **Codify Cloudflare DNS records**
   - Import existing A/CNAME records for helixstax.com
   - Add internal DNS records for VPS services (harbor.internal.helixstax.com, auth.internal.helixstax.com, etc.)

6. **Create VPS disk layout**
   ```
   /data/postgres   (10GB)
   /data/harbor     (25GB)
   /data/minio      (20GB)
   /data/authentik  (5GB)
   ```

7. **Install Docker + Docker Compose on VPS**
   - AlmaLinux 9 minimal + Docker CE
   - Ensure `tar` is installed (AlmaLinux minimal omits it)

8. **Create K3s bootstrap scripts** (for future reprovisioning)
   ```
   k3s/
     install-server.sh
     install-agent.sh
     k3s-config.yaml
   ```

### Acceptance Criteria
- [ ] `terraform plan` shows no drift for existing resources
- [ ] External VPS provisioned and accessible via SSH (key-only, non-standard port)
- [ ] VPS on Nerve network, reachable from cluster nodes on private IP
- [ ] Docker + Docker Compose running on VPS
- [ ] Cloudflare DNS records codified
- [ ] All Terraform state committed to private `helix-stax-infra` repo

### Handoff to Phase 2
- VPS private IP address (for cluster -> VPS communication)
- VPS public IP address (for DNS records)
- Terraform state file location
- Docker Compose readiness confirmation

### Tutorial Content Deliverables
- **Article**: "Terraform on Hetzner Cloud: Importing Existing Infrastructure and Provisioning New Nodes"
- **Video**: "Infrastructure as Code for Kubernetes -- Terraform + Hetzner from Zero"
- **Screenshots/recordings needed**: `terraform import` output, `terraform plan` clean run, VPS creation in Hetzner console vs. Terraform, cloud-init script walkthrough

### Estimated Effort
2-3 sessions

### Risks and Gotchas
- `terraform import` can fail silently if resource IDs are wrong -- verify each import with `terraform state show`
- Terraform state contains sensitive data (IPs, resource IDs) -- keep in private repo, never public
- Hetzner CX32 has 80GB NVMe total -- the disk layout above uses 60GB, leaving 20GB for OS + growth
- cloud-init runs only on first boot -- changes require VPS rebuild or manual SSH

---

## Phase 2: Management Services

> **Goal**: Deploy Harbor, Authentik, Netbird, OpenBao, Vaultwarden, and MinIO on the External VPS via Docker Compose, with shared PostgreSQL and Redis.

### Prerequisites
- Phase 1 complete (VPS provisioned with Docker)
- DNS records pointing to VPS (harbor.internal.helixstax.com, etc.)
- TLS certificates (Let's Encrypt via nginx reverse proxy on VPS)

### Specialist Team
- **Kit** (DevOps Engineer) -- Docker Compose stack, service configuration
- **Ezra** (Security Engineer) -- OpenBao setup, TLS configuration, Authentik OIDC

### Tasks

1. **Deploy shared PostgreSQL 16**
   - Create databases: `harbor_db`, `authentik_db`, `netbird_db`
   - Tuned config: `shared_buffers=384MB`, `work_mem=4MB`, `max_connections=100`
   - Enable WAL archiving for PITR: `wal_level=replica`, `archive_mode=on`

2. **Deploy shared Redis 7**
   - Logical databases: DB 0 (Harbor), DB 1 (Authentik)
   - `maxmemory 512mb`, `maxmemory-policy allkeys-lru`

3. **Deploy Harbor** (core + portal + registry -- NO Trivy scanner)
   - Configure project with auto-scan disabled (scan in CI instead)
   - Set up pull-through cache for Docker Hub (avoid rate limits)
   - TLS via nginx reverse proxy

4. **Deploy Authentik** (server + worker)
   - Configure OIDC providers for: Devtron, Grafana, Kubernetes API
   - Create admin user and initial groups (admin, developer, ci-cd)
   - Set up OIDC for K3s API server:
     ```
     --kube-apiserver-arg="oidc-issuer-url=https://auth.helixstax.com/application/o/kubernetes/"
     --kube-apiserver-arg="oidc-client-id=kubernetes"
     --kube-apiserver-arg="oidc-username-claim=preferred_username"
     --kube-apiserver-arg="oidc-groups-claim=groups"
     ```

5. **Deploy Netbird** (management + signal + coturn)
   - Integrate with Authentik for SSO
   - Create peer groups: admin, cluster-nodes
   - Configure routes for cluster network (10.0.0.0/16)

6. **Deploy OpenBao** (vault fork)
   - Initialize with Shamir key shares (3-of-5)
   - Store unseal keys in Vaultwarden (at least 2 in separate locations)
   - TLS mandatory for listener
   - Create initial secret engines: `secret/`, `database/`

7. **Deploy Vaultwarden** (Bitwarden-compatible)
   - Uses SQLite (no additional PostgreSQL dependency)
   - Store all infrastructure credentials here

8. **Deploy MinIO** (single-node, single-drive)
   - Create buckets: `velero-backups`, `cnpg-wal-archive`, `vps-pg-backups`
   - Enable server-side encryption (SSE-S3)
   - TLS for S3 API endpoint

9. **Deploy nginx reverse proxy**
   - TLS termination via Let's Encrypt (certbot)
   - Route: harbor.internal.helixstax.com -> Harbor
   - Route: auth.helixstax.com -> Authentik
   - Route: vpn.helixstax.com -> Netbird
   - Route: vault.internal.helixstax.com -> OpenBao

10. **Lock down VPS access**
    - After Netbird is running, restrict SSH to Netbird overlay only
    - Close port 22 on Hetzner firewall, access via Netbird peer IP
    - Keep one break-glass rule: SSH from a specific backup IP

11. **Configure VPS backups**
    - Daily `pg_dump` to `/data/minio/vps-pg-backups/`
    - Weekly Hetzner snapshot via API

### Acceptance Criteria
- [ ] All 7 services running (`docker compose ps` shows healthy)
- [ ] Harbor accessible at harbor.internal.helixstax.com with TLS
- [ ] Authentik login page at auth.helixstax.com
- [ ] Netbird VPN connection from admin machine to cluster nodes
- [ ] OpenBao initialized and unsealed, secret engine operational
- [ ] MinIO buckets created, S3 API reachable from cluster
- [ ] VPS memory usage < 7.5GB (`free -h`)
- [ ] VPS PostgreSQL serving all 3 databases
- [ ] SSH only via Netbird (public SSH port closed)
- [ ] pg_dump cron running daily

### Handoff to Phase 3
- Harbor registry URL and pull secret for K3s
- Authentik OIDC endpoint URLs and client credentials
- Netbird peer configuration for cluster nodes
- OpenBao address and Kubernetes auth mount path
- MinIO endpoint and access credentials (for Velero + CloudNativePG)

### Tutorial Content Deliverables
- **Article**: "Building a Management VPS: Harbor, Authentik, and Zero-Trust VPN on a $8/month Server"
- **Video**: "The External VPS Pattern -- Why Your Auth and Registry Should Live Outside Kubernetes"
- **Screenshots/recordings needed**: Docker Compose stack overview, Harbor UI, Authentik OIDC flow, Netbird peer connection, memory usage dashboard

### Estimated Effort
4-5 sessions

### Risks and Gotchas
- **Memory pressure**: 7.5GB budget on 8GB VPS is tight. Monitor with `docker stats`. If OOM, upgrade to CX42 (16GB, ~$16/mo)
- **Circular dependency**: Authentik needs DNS, DNS needs Cloudflare, Cloudflare needs Terraform. Break the loop by using direct IP access initially, then switch to DNS once records propagate
- **OpenBao unseal**: Hetzner has no KMS. Auto-unseal not available. After every VPS reboot, you must manually unseal. Document the procedure. Consider a systemd timer that prompts via Telegram
- **Harbor without Trivy**: Images pushed to Harbor will NOT be scanned. Scanning moves to CI pipeline (Phase 9). This is a deliberate trade-off for VPS memory
- **Netbird + Authentik ordering**: Deploy Authentik first, then Netbird (Netbird depends on Authentik for SSO). If both go down simultaneously on VPS reboot, Authentik must come up first

---

## Phase 3: Cluster Security

> **Goal**: Migrate CNI from Flannel to Cilium, enforce Pod Security Admission, deploy External Secrets Operator connected to OpenBao, and establish namespace architecture with default-deny NetworkPolicies.

### Prerequisites
- Phase 2 complete (Netbird running for fallback access, OpenBao running for secrets)
- Hetzner Cloud Firewall covering all perimeter rules (confirmed in Phase 0)
- Maintenance window planned (Cilium migration requires brief cluster downtime)

### Specialist Team
- **Ezra** (Security Engineer) -- NetworkPolicies, PSA, RBAC
- **Kit** (DevOps Engineer) -- Cilium installation, K3s reconfiguration
- **Cass** (Architect) -- Namespace design review

### Tasks

1. **Create namespace structure with labels**
   ```bash
   kubectl create namespace ingress
   kubectl create namespace auth
   kubectl create namespace data-layer
   kubectl create namespace ai-inference
   kubectl create namespace automation
   kubectl create namespace observability

   # Apply labels for NetworkPolicy selectors
   kubectl label namespace ingress tier=edge
   kubectl label namespace data-layer tier=data data-access="true"
   kubectl label namespace ai-inference tier=compute ai-access="true"
   kubectl label namespace automation tier=app data-access="true" ai-access="true"
   kubectl label namespace observability tier=monitoring
   ```

2. **Apply ResourceQuotas per namespace**

   | Namespace | CPU Limit | Memory Limit |
   |-----------|-----------|--------------|
   | ai-inference | 8 vCPU | 24GB |
   | data-layer | 8 vCPU | 20GB |
   | automation | 4 vCPU | 8GB |
   | observability | 2 vCPU | 4GB |
   | ingress | 2 vCPU | 2GB |
   | devtroncd + argo | 4 vCPU | 6GB |

3. **Disable firewalld on all nodes** (prerequisite for Cilium)
   ```bash
   # Verify Hetzner Cloud Firewall covers all perimeter rules FIRST
   systemctl disable --now firewalld
   ```
   > **WARNING**: This was the root cause of the previous Cilium crash. The fix is to disable firewalld BEFORE installing Cilium, not after. Hetzner Cloud Firewall provides perimeter protection. Cilium provides pod-level protection.

4. **Reinstall K3s with Cilium CNI**
   ```bash
   # On control plane (heart):
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
     --flannel-backend=none \
     --disable-network-policy \
     --secrets-encryption \
     --kube-apiserver-arg=audit-log-path=/var/log/k8s-audit.log" sh -

   # Install Cilium via Helm:
   helm repo add cilium https://helm.cilium.io/
   helm install cilium cilium/cilium --version 1.16.x \
     --namespace kube-system \
     --set operator.replicas=1 \
     --set encryption.enabled=true \
     --set encryption.type=wireguard \
     --set hubble.enabled=true \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true
   ```

5. **Verify Cilium health**
   ```bash
   cilium status
   cilium connectivity test
   ```

6. **Deploy default-deny NetworkPolicies** (every namespace)
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-all
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
       - Egress
   ```

7. **Deploy explicit allow NetworkPolicies** (per Ezra's templates)
   - Traefik: allow ingress from internet (80/443), egress to backend namespaces
   - data-layer: allow ingress from namespaces with `data-access="true"` on 5432
   - ai-inference: allow ingress from namespaces with `ai-access="true"` on 11434
   - automation (n8n): allow egress to data-layer, ai-inference, and internet (443 for webhooks)
   - observability: allow Prometheus to scrape all namespaces on metrics ports
   - All namespaces: allow DNS egress to kube-system (port 53)

8. **Test all service connectivity** via Cilium Hubble
   ```bash
   hubble observe --namespace automation
   hubble observe --namespace data-layer
   ```

9. **Apply Pod Security Admission** (start in warn mode)
   ```yaml
   # Per namespace labels:
   pod-security.kubernetes.io/warn: "restricted"
   pod-security.kubernetes.io/audit: "restricted"
   ```
   - After 48h with no violations, switch to `enforce: "restricted"`
   - Exceptions: `kube-system` stays `privileged`, `ingress` and `devtroncd` use `baseline`

10. **Deploy External Secrets Operator (ESO)**
    ```bash
    helm repo add external-secrets https://charts.external-secrets.io
    helm install external-secrets external-secrets/external-secrets \
      --namespace kube-system
    ```
    - Create `ClusterSecretStore` pointing to OpenBao on VPS
    - Migrate existing manually-created secrets to `ExternalSecret` resources

11. **Create scoped RBAC roles**
    - `admin` ClusterRole: full access (break-glass, stored in OpenBao)
    - `developer` Role: namespace-scoped, no secrets, no node ops
    - `ci-cd` Role: deploy to specific namespaces only (Devtron ServiceAccount)
    - Integrate with Authentik OIDC for human access

12. **Deploy Cosign + Kyverno** (image signing and admission)
    ```bash
    helm repo add kyverno https://kyverno.github.io/kyverno/
    helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace
    ```
    - Create ClusterPolicy: reject unsigned images from Harbor
    - Configure Devtron CI to sign images with Cosign after build

### Acceptance Criteria
- [ ] Cilium running as sole CNI (`cilium status` healthy)
- [ ] WireGuard node-to-node encryption active
- [ ] firewalld disabled on all nodes, Hetzner Cloud Firewall active
- [ ] Default-deny NetworkPolicies in all application namespaces
- [ ] All services still communicating (verified via Hubble)
- [ ] PSA in at least `warn` mode on all namespaces
- [ ] ESO syncing at least one secret from OpenBao
- [ ] ResourceQuotas applied and verified (`kubectl describe quota -n <ns>`)
- [ ] Kyverno blocking unsigned test image
- [ ] RBAC: non-admin kubeconfig cannot access secrets

### Handoff to Phase 4
- Namespace list with labels and ResourceQuotas
- NetworkPolicy templates (for new namespaces)
- ESO ClusterSecretStore name (for ExternalSecret resources)
- Cilium version and configuration (for compatibility checks)

### Tutorial Content Deliverables
- **Article**: "Migrating from Flannel to Cilium on K3s: Fixing the eBPF + firewalld Crash"
- **Video**: "Zero-Trust Kubernetes Networking -- Default-Deny with Cilium NetworkPolicies"
- **Screenshots/recordings needed**: Cilium status output, Hubble UI showing traffic flows, NetworkPolicy YAML walkthrough, PSA violation warnings, kube-bench before/after

### Estimated Effort
4-5 sessions

### Risks and Gotchas
- **Cilium migration requires cluster downtime**: Plan a maintenance window. All pods lose networking briefly during CNI swap. Estimated: 5-15 minutes
- **The Cilium + firewalld crash**: This was the EXACT issue that crashed the cluster before. The fix is confirmed: disable firewalld FIRST, let Cilium manage iptables. Do NOT re-enable firewalld
- **NetworkPolicy lockouts**: Start with `warn`/`audit` on PSA. Deploy default-deny one namespace at a time starting with `ai-inference` (fewest dependencies). Have `kubectl delete networkpolicy default-deny-all -n <ns>` ready as emergency rollback
- **Devtron compatibility**: Devtron runs in `devtroncd` namespace. Its NetworkPolicies are complex (needs GitHub webhooks, Harbor push, ArgoCD sync). Leave devtroncd on `baseline` PSA and liberal NetworkPolicies until Phase 9
- **ESO + OpenBao**: If OpenBao is sealed (e.g., after VPS reboot), ESO sync fails silently. Monitor ESO logs for connection errors

---

## Phase 4: Data Layer

> **Goal**: Deploy CloudNativePG operator and establish a consolidated PostgreSQL cluster with pgvector, AGE, and pg_analytics extensions. Migrate Devtron's bundled Postgres.

### Prerequisites
- Phase 3 complete (namespaces with ResourceQuotas, NetworkPolicies, ESO running)
- `data-layer` namespace created with appropriate labels

### Specialist Team
- **Soren** (Database Engineer) -- CloudNativePG deployment, extension setup, Devtron migration
- **Cass** (Architect) -- Consolidation strategy review

### Tasks

1. **Deploy CloudNativePG operator**
   ```bash
   kubectl apply --server-side -f \
     https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
   ```

2. **Create CloudNativePG cluster** in `data-layer` namespace
   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: helix-pg
     namespace: data-layer
   spec:
     instances: 1  # Single instance for now (single worker node)
     postgresql:
       parameters:
         shared_buffers: "4GB"
         effective_cache_size: "12GB"
         work_mem: "64MB"
         maintenance_work_mem: "512MB"
         max_connections: "200"
       shared_preload_libraries:
         - "vectors.so"  # pgvector
         - "age"          # Apache AGE
     storage:
       size: 50Gi
       storageClass: local-path
     backup:
       barmanObjectStore:
         destinationPath: "s3://cnpg-wal-archive/"
         endpointURL: "https://minio.internal.helixstax.com"
         s3Credentials:
           accessKeyId:
             name: cnpg-minio-creds
             key: ACCESS_KEY_ID
           secretAccessKey:
             name: cnpg-minio-creds
             key: SECRET_ACCESS_KEY
       retentionPolicy: "7d"
   ```

3. **Create application databases**
   ```sql
   CREATE DATABASE devtron;
   CREATE DATABASE n8n;
   CREATE DATABASE langfuse;
   CREATE DATABASE app;  -- For future application use
   ```

4. **Enable extensions**
   ```sql
   -- On 'app' database:
   CREATE EXTENSION vector;          -- pgvector for embeddings
   CREATE EXTENSION age;             -- Apache AGE for graph queries
   -- pg_analytics via DuckDB FDW or pg_analytics extension (verify compatibility)
   ```

5. **Migrate Devtron PostgreSQL** to CloudNativePG
   - pg_dump from Devtron's bundled subchart Postgres
   - pg_restore into `devtron` database on CloudNativePG cluster
   - Update Devtron Helm values to point to new Postgres endpoint
   - Verify Devtron functionality after migration
   - Decommission bundled Postgres subchart

6. **Configure WAL archiving to MinIO**
   - Continuous WAL shipping to `s3://cnpg-wal-archive/` on VPS MinIO
   - Test point-in-time recovery (PITR)

7. **Create ExternalSecret resources** for database credentials
   - Store all DB passwords in OpenBao
   - ESO syncs to K8s secrets in `data-layer` namespace

8. **Configure Pod Disruption Budget**
   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: helix-pg-pdb
     namespace: data-layer
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         cnpg.io/cluster: helix-pg
   ```

### Acceptance Criteria
- [ ] CloudNativePG operator running, cluster healthy (`kubectl cnpg status helix-pg -n data-layer`)
- [ ] All 4 databases created and accessible
- [ ] pgvector and AGE extensions enabled on `app` database
- [ ] Devtron migrated to CloudNativePG and fully functional
- [ ] WAL archiving to MinIO active (verify with `kubectl cnpg backup helix-pg -n data-layer`)
- [ ] Database credentials managed via ESO (not manual secrets)
- [ ] PDB applied

### Handoff to Phase 5
- CloudNativePG service endpoint (for other workloads to connect)
- Database names and credential secret names
- WAL archive location (for backup verification in Phase 8)

### Tutorial Content Deliverables
- **Article**: "CloudNativePG: One Postgres to Rule Them All -- Replacing 5 Databases with Extensions"
- **Video**: "PostgreSQL Consolidation on Kubernetes -- pgvector, AGE, and CloudNativePG"
- **Screenshots/recordings needed**: CloudNativePG operator status, database creation, pgvector similarity search demo, Devtron migration steps, WAL archive verification

### Estimated Effort
3-4 sessions

### Risks and Gotchas
- **Devtron migration is the riskiest task**: Take a full Devtron backup first. Test the migration in a staging namespace if possible. Have rollback plan: re-enable bundled Postgres
- **CloudNativePG on local-path**: No replication possible with single worker. This is acceptable -- HA comes from WAL archiving + Velero backups, not storage replication
- **pg_analytics**: DuckDB-based analytics extension may have compatibility issues with CloudNativePG. Test thoroughly. If incompatible, defer to standalone DuckDB sidecar
- **Memory**: CloudNativePG with `shared_buffers=4GB` consumes significant memory. Monitor pod memory usage against the 20GB ResourceQuota for `data-layer`

---

## Phase 5: Observability

> **Goal**: Deploy the full PLG stack (Prometheus, Loki, Grafana) plus Tetragon for runtime security monitoring. Configure critical alerts to Telegram.

### Prerequisites
- Phase 3 complete (namespaces, NetworkPolicies, ResourceQuotas)
- `observability` namespace created (4GB memory quota)
- Telegram bot token rotated and working (currently returning 401)

### Specialist Team
- **Kit** (DevOps Engineer) -- Helm deployments, Grafana dashboards, alert rules
- **Ezra** (Security Engineer) -- Tetragon policies, audit log integration

### Tasks

1. **Deploy kube-prometheus-stack** (bundles Prometheus + Grafana + node-exporter + kube-state-metrics + Alertmanager)
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm install kube-prometheus prometheus-community/kube-prometheus-stack \
     --namespace observability \
     --set prometheus.prometheusSpec.retention=15d \
     --set prometheus.prometheusSpec.retentionSize=10GB \
     --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
     --set prometheus.prometheusSpec.resources.limits.memory=2Gi \
     --set grafana.resources.requests.memory=256Mi \
     --set grafana.resources.limits.memory=512Mi
   ```

2. **Deploy Loki + Promtail**
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm install loki grafana/loki-stack \
     --namespace observability \
     --set loki.persistence.enabled=true \
     --set loki.persistence.size=10Gi \
     --set loki.config.limits_config.retention_period=168h  # 7 days
   ```

3. **Configure Grafana data sources**
   - Prometheus (auto-configured by kube-prometheus-stack)
   - Loki (add manually or via Helm values)

4. **Import dashboards**
   - K8s cluster overview (ID: 6417)
   - Node exporter full (ID: 1860)
   - K8s pod resources (ID: 6879)
   - Loki log explorer (built-in)
   - CloudNativePG dashboard (from CNPG docs)

5. **Rotate Telegram bot token** (currently returning 401)
   - Create new bot via @BotFather
   - Store token in OpenBao
   - Configure Grafana contact point: Telegram

6. **Configure critical alerts**

   | Alert | Condition | Severity |
   |-------|-----------|----------|
   | NodeMemoryPressure | Available memory < 10% | Critical |
   | NodeDiskPressure | Available disk < 15% | Critical |
   | NodeNotReady | Node status != Ready > 5min | Critical |
   | PodOOMKilled | Any pod OOM killed | Warning |
   | PodCrashLooping | Restart count > 5 in 10min | Warning |
   | PersistentVolumeUsage | PV usage > 80% | Warning |
   | CertificateExpiry | TLS cert expires < 14d | Warning |
   | CloudNativePGDown | CNPG cluster not healthy | Critical |

7. **Ship K8s audit logs to Loki**
   - Configure Promtail to tail `/var/log/k8s-audit.log`
   - Create Grafana dashboard for audit log queries

8. **Deploy Tetragon** (runtime security)
   ```bash
   helm repo add cilium https://helm.cilium.io/
   helm install tetragon cilium/tetragon \
     --namespace observability \
     --set tetragon.resources.requests.memory=128Mi \
     --set tetragon.resources.limits.memory=300Mi
   ```

9. **Configure Tetragon policies**
   - Detect: reverse shells, crypto miners, /etc/shadow reads
   - Detect: unexpected outbound connections from database pods
   - Alert via Grafana (Tetragon exports Prometheus metrics)

10. **Expose Grafana** via Traefik IngressRoute
    - Route: grafana.internal.helixstax.com
    - Protect with Authentik forward-auth (SSO login)
    - Also accessible directly via Netbird VPN

11. **Establish resource baselines**
    - Record idle CPU/memory per namespace for 48h
    - Document baselines for future capacity planning

### Acceptance Criteria
- [ ] Prometheus scraping all targets (check Targets page in Grafana)
- [ ] Loki receiving logs from all pods (`logcli query '{namespace="kube-system"}'`)
- [ ] Grafana accessible at grafana.internal.helixstax.com behind Authentik SSO
- [ ] All 8 critical alerts configured and tested (fire a test alert to Telegram)
- [ ] Audit logs visible in Grafana Loki dashboard
- [ ] Tetragon running, baseline policies active
- [ ] Resource baselines documented
- [ ] Total observability stack memory < 4GB (within quota)

### Handoff to Phase 6
- Grafana URL and SSO access
- Alert notification channel configuration
- Prometheus scrape targets list (for new workloads to register)
- Loki endpoint (for workloads that push logs directly)

### Tutorial Content Deliverables
- **Article**: "Kubernetes Observability on a Budget: Prometheus + Loki + Grafana under 4GB"
- **Video**: "Stop Flying Blind -- Monitoring K3s with the PLG Stack and Tetragon"
- **Screenshots/recordings needed**: Grafana dashboards (cluster overview, node exporter), Loki log queries, Telegram alert notification, Tetragon detecting suspicious activity, Hubble UI network flows

### Estimated Effort
3-4 sessions

### Risks and Gotchas
- **Prometheus memory**: `retentionSize=10GB` hard cap prevents disk exhaustion, but Prometheus itself can spike memory during high cardinality scrapes. Watch the first 48h closely
- **Loki storage**: 10Gi PV on local-path. Monitor usage -- 7-day retention with moderate log volume should fit, but verbose apps can fill it fast. Set `loki.config.limits_config.ingestion_rate_mb` to prevent burst
- **Telegram bot**: Must rotate token BEFORE configuring Grafana alerts. Current token returns 401
- **Tetragon + Cilium**: Both use eBPF. On a single worker node, eBPF map limits could be reached. Monitor `bpftool prog show` for map count. Unlikely at this scale but worth watching
- **Grafana behind Authentik**: If Authentik (on VPS) goes down, Grafana becomes inaccessible via SSO. Ensure Grafana has a local admin fallback account

---

## Phase 6: Application Layer

> **Goal**: Deploy n8n, Ollama, and Langfuse in their respective namespaces with proper resource limits, health probes, and database connectivity.

### Prerequisites
- Phase 4 complete (CloudNativePG cluster with databases)
- Phase 5 complete (monitoring for observability during deployment)
- `automation` and `ai-inference` namespaces with ResourceQuotas

### Specialist Team
- **Kit** (DevOps Engineer) -- Helm deployments, StatefulSet configuration
- **Dax** (Backend Developer) -- n8n workflow configuration, Langfuse setup
- **Cass** (Architect) -- Health probe patterns, rolling update config review

### Tasks

1. **Deploy Ollama as StatefulSet**
   ```bash
   # In ai-inference namespace
   helm install ollama ollama/ollama \
     --namespace ai-inference \
     --set resources.requests.memory=8Gi \
     --set resources.limits.memory=20Gi \
     --set resources.requests.cpu=2 \
     --set resources.limits.cpu=8 \
     --set persistence.enabled=true \
     --set persistence.size=30Gi  # For model weights
   ```

2. **Configure Ollama health probes**
   ```yaml
   startupProbe:
     httpGet:
       path: /api/tags
       port: 11434
     failureThreshold: 60    # Allow 10 min for model loading
     periodSeconds: 10
   readinessProbe:
     httpGet:
       path: /api/tags
       port: 11434
     periodSeconds: 10
   livenessProbe:
     httpGet:
       path: /api/tags
       port: 11434
     periodSeconds: 30
     failureThreshold: 3
   ```

3. **Deploy n8n** in `automation` namespace
   ```bash
   helm install n8n n8n/n8n \
     --namespace automation \
     --set database.type=postgresdb \
     --set database.postgresdb.host=helix-pg-rw.data-layer.svc \
     --set database.postgresdb.database=n8n \
     --set resources.requests.memory=512Mi \
     --set resources.limits.memory=2Gi
   ```
   - Configure n8n health probes: readiness and liveness on `/healthz`
   - Create ExternalSecret for database credentials

4. **Deploy Langfuse** in `automation` namespace
   ```bash
   helm install langfuse langfuse/langfuse \
     --namespace automation \
     --set database.host=helix-pg-rw.data-layer.svc \
     --set database.name=langfuse \
     --set resources.requests.memory=256Mi \
     --set resources.limits.memory=1Gi
   ```
   - Configure Langfuse to use Authentik SSO

5. **Configure rolling update strategy** (all deployments)
   ```yaml
   strategy:
     type: RollingUpdate
     rollingUpdate:
       maxSurge: 1
       maxUnavailable: 0
   ```

6. **Configure PDBs**

   | Workload | minAvailable |
   |----------|-------------|
   | n8n | 1 |
   | Ollama | 0 (can tolerate brief downtime) |
   | Langfuse | 0 |

7. **Expose services via Traefik IngressRoutes**
   - n8n.internal.helixstax.com (behind Authentik forward-auth)
   - langfuse.internal.helixstax.com (behind Authentik forward-auth)
   - Ollama: internal only (no ingress, accessed via cluster DNS from n8n)

8. **Connect n8n to Ollama** for AI workflows
   - Create n8n credentials for Ollama API (cluster-internal: `ollama.ai-inference.svc:11434`)
   - Test a basic workflow: trigger -> Ollama completion -> store result

9. **Connect n8n to Langfuse** for observability
   - Configure Langfuse tracing in n8n AI nodes

10. **Verify all health probes are working**
    - `kubectl get pods -n automation -o wide` -- all Running
    - `kubectl get pods -n ai-inference -o wide` -- all Running
    - Grafana dashboards showing metrics from new pods

### Acceptance Criteria
- [ ] Ollama running with model loaded, responding to API calls
- [ ] n8n accessible at n8n.internal.helixstax.com, connected to PostgreSQL
- [ ] Langfuse accessible, receiving traces from n8n
- [ ] All health probes defined and passing
- [ ] Rolling update strategy configured on all deployments
- [ ] PDBs applied
- [ ] Grafana showing resource usage for new workloads
- [ ] Test n8n -> Ollama workflow executing successfully
- [ ] Total memory usage within namespace ResourceQuotas

### Handoff to Phase 7
- n8n webhook URL (for external triggers)
- Ollama model list and API endpoint (cluster-internal)
- Langfuse project ID and API key
- Service endpoints for all application-layer workloads

### Tutorial Content Deliverables
- **Article**: "Running AI Workloads on K3s: Ollama, n8n, and Langfuse on a Single Node"
- **Video**: "AI Automation Stack on Kubernetes -- n8n + Ollama + Langfuse End-to-End"
- **Screenshots/recordings needed**: Ollama model loading, n8n workflow editor with AI node, Langfuse trace view, Grafana showing Ollama memory usage, health probe configuration

### Estimated Effort
3-4 sessions

### Risks and Gotchas
- **Ollama model loading**: First model pull can take 10+ minutes and consume 10-20GB disk per model. Ensure PV is large enough. `startupProbe` must be generous
- **Ollama memory**: Ollama loads models into RAM. A 7B model needs ~4GB, 13B needs ~8GB. Monitor against the 24GB namespace quota. Do NOT load models larger than what the quota allows
- **n8n database migrations**: n8n runs schema migrations on startup. If the database is slow or locked, n8n startup will fail. CloudNativePG should be stable, but watch for migration errors in logs
- **Langfuse cold start**: Langfuse can be slow to start. Use a generous `startupProbe`

---

## Phase 7: Multi-Tenant & Client Hosting

> **Goal**: Set up Cloudflare for Platforms for automatic SSL on client domains, dynamic Traefik routing for client sites, and begin the React + React Flow client portal.

### Prerequisites
- Phase 6 complete (application layer running)
- Cloudflare for Platforms account set up
- CloudNativePG `app` database available

### Specialist Team
- **Kit** (DevOps Engineer) -- Cloudflare for Platforms, Traefik dynamic config
- **Wren** (Frontend Developer) -- React client portal
- **Dax** (Backend Developer) -- Client onboarding API, n8n workflows
- **Nix** (n8n Engineer) -- Client onboarding automation workflow

### Tasks

1. **Configure Cloudflare for Platforms**
   - Enable Custom Hostnames on helixstax.com zone
   - Set up Cloudflare Full (Strict) SSL mode
   - Configure fallback origin to cluster ingress IP

2. **Deploy cert-manager** for origin certificates
   ```bash
   helm repo add jetstack https://charts.jetstack.io
   helm install cert-manager jetstack/cert-manager \
     --namespace ingress \
     --set crds.enabled=true \
     --set resources.requests.memory=64Mi
   ```
   - Create ClusterIssuer for Let's Encrypt (production)
   - Create wildcard cert for *.helixstax.com

3. **Configure Traefik dynamic routing**
   - Middleware for Authentik forward-auth (internal services)
   - Dynamic IngressRoute generation for client subdomains
   - Default backend for `*.helixstax.com` showing "Coming Soon" page

4. **Build client onboarding n8n workflow**
   - Trigger: webhook from client portal
   - Steps: Add domain to Cloudflare -> Create Traefik route -> Create DB record -> Notify via Telegram
   - Error handling: rollback partial changes on failure

5. **Scaffold React client portal**
   - Authentication via Authentik OIDC
   - Client dashboard: project status, reports, invoices
   - Admin dashboard: client management, domain management
   - React Flow for workflow visualization (future)

6. **Configure per-client ResourceQuotas**
   ```yaml
   # Template for client namespaces:
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: client-quota
     namespace: client-<name>
   spec:
     hard:
       requests.cpu: "500m"
       requests.memory: "512Mi"
       limits.cpu: "1"
       limits.memory: "1Gi"
   ```

7. **Set up starter tier routing**
   - `clientname.helixstax.com` -> client namespace service
   - One Cloudflare zone (helixstax.com) handles all starter subdomains

8. **Set up custom domain tier routing**
   - Cloudflare for Platforms Custom Hostnames
   - Automatic SSL provisioning for client domains

### Acceptance Criteria
- [ ] Cloudflare for Platforms Custom Hostnames working (test with a dummy domain)
- [ ] cert-manager issuing Let's Encrypt certificates
- [ ] Traefik dynamic routing serving different content per subdomain
- [ ] Client onboarding n8n workflow executing end-to-end
- [ ] Client portal scaffold deployed and accessible behind Authentik
- [ ] Per-client ResourceQuotas template ready
- [ ] Starter tier: `test.helixstax.com` resolves and serves content

### Handoff to Phase 8
- Cloudflare for Platforms configuration details
- Client namespace template (YAML)
- n8n webhook endpoints for client operations
- Client portal deployment endpoint

### Tutorial Content Deliverables
- **Article**: "Multi-Tenant Kubernetes Hosting: Cloudflare for Platforms + Traefik Dynamic Routing"
- **Video**: "Building a Client Hosting Platform on K3s -- From Signup to SSL in 60 Seconds"
- **Screenshots/recordings needed**: Cloudflare Custom Hostnames UI, Traefik routing diagram, n8n onboarding workflow, client portal UI, SSL certificate auto-provisioning

### Estimated Effort
4-5 sessions

### Risks and Gotchas
- **Cloudflare for Platforms pricing**: Starts at ~$20/mo for the Platforms add-on. Verify pricing before enabling
- **cert-manager + Cloudflare**: Full (Strict) mode requires valid origin certs. cert-manager must be working BEFORE enabling Full (Strict) or existing sites will break
- **Client isolation**: NetworkPolicies must isolate client namespaces from each other AND from internal services. One compromised client site must NOT access another client's data or the main database
- **React portal is a multi-session effort**: The portal scaffold in this phase is MVP -- auth + basic dashboard. Full features (React Flow, reports, invoices) are iterative

---

## Phase 8: Backup & Disaster Recovery

> **Goal**: Deploy Velero for cluster backups, configure MinIO as primary target and Backblaze B2 as off-site replica. Test full restore.

### Prerequisites
- Phase 2 complete (MinIO running on VPS)
- Phase 4 complete (CloudNativePG WAL archiving to MinIO)
- Backblaze B2 account created

### Specialist Team
- **Kit** (DevOps Engineer) -- Velero deployment, backup schedules, restore testing
- **Ezra** (Security Engineer) -- Backup encryption, break-glass documentation

### Tasks

1. **Deploy Velero**
   ```bash
   helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
   helm install velero vmware-tanzu/velero \
     --namespace velero --create-namespace \
     --set configuration.backupStorageLocation[0].provider=aws \
     --set configuration.backupStorageLocation[0].bucket=velero-backups \
     --set configuration.backupStorageLocation[0].config.s3Url=https://minio.internal.helixstax.com \
     --set configuration.backupStorageLocation[0].config.region=us-east-1 \
     --set configuration.uploaderType=kopia \
     --set credentials.useSecret=true
   ```

2. **Configure backup schedules**

   | Schedule | Cron | TTL | Includes |
   |----------|------|-----|----------|
   | Daily | `0 2 * * *` | 168h (7d) | All namespaces (except kube-system, kube-public) + PVs |
   | Weekly | `0 3 * * 0` | 672h (28d) | All namespaces + PVs |

3. **Enable Kopia encryption** for backup data at rest
   - Kopia encrypts by default with repository password
   - Store Kopia passphrase in OpenBao (NOT in a Kubernetes secret)

4. **Configure K3s etcd snapshots**
   ```bash
   # Add to K3s server config:
   --etcd-snapshot-schedule-cron="0 */6 * * *"
   --etcd-snapshot-retention=10
   ```
   - Rsync snapshots to VPS MinIO daily

5. **Set up Backblaze B2 replication**
   - Create B2 bucket: `helix-stax-velero-backups`
   - Install rclone on VPS
   - Configure daily sync:
     ```bash
     # /etc/cron.daily/velero-b2-sync
     rclone sync /data/minio/velero-backups b2:helix-stax-velero-backups \
       --transfers 4 --checkers 8
     ```

6. **Test backup and restore** (MANDATORY)
   - Take a manual backup: `velero backup create test-backup-001`
   - Verify backup contents: `velero backup describe test-backup-001`
   - Simulate disaster: delete a non-critical namespace (e.g., create a test namespace, populate it, delete it)
   - Restore: `velero restore create --from-backup test-backup-001 --include-namespaces test-ns`
   - Verify restore: all resources and PV data recovered

7. **Test CloudNativePG PITR**
   - Insert test data into a database
   - Note the timestamp
   - Delete the test data
   - Perform point-in-time recovery to before deletion
   - Verify data restored

8. **Document break-glass procedures**
   - If Authentik down: direct SSH + kubeconfig
   - If Netbird down: direct SSH via backup IP firewall rule
   - If VPS down: cluster continues, rebuild from Terraform + restore MinIO from B2
   - If cluster unrecoverable: Velero restore from MinIO (or B2) to fresh Terraform nodes
   - Store break-glass credentials: Vaultwarden + offline USB drive

9. **Create Grafana alerts for backup health**
   - Alert: Velero backup failed
   - Alert: Velero backup age > 36h (missed daily)
   - Alert: B2 sync failed (check rclone exit code)

### Acceptance Criteria
- [ ] Velero daily + weekly backups running
- [ ] Kopia encryption enabled (verified: backup data is encrypted at rest in MinIO)
- [ ] K3s etcd snapshots running every 6 hours
- [ ] B2 replication working (verify bucket has data)
- [ ] Full restore test passed (namespace restored from backup)
- [ ] CloudNativePG PITR test passed
- [ ] Break-glass procedures documented and stored in Vaultwarden
- [ ] Grafana backup health alerts configured
- [ ] Estimated B2 cost: < $1/mo at current scale

### Handoff to Phase 9
- Velero backup schedule configuration
- B2 bucket name and replication status
- Break-glass procedure document location
- Backup monitoring alerts in Grafana

### Tutorial Content Deliverables
- **Article**: "Kubernetes Backup That Actually Works: Velero + MinIO + Backblaze B2 on a Budget"
- **Video**: "Disaster Recovery for K3s -- Backup, Restore, and the Drill You Must Run"
- **Screenshots/recordings needed**: Velero backup output, restore demo (delete + restore), MinIO bucket contents, B2 bucket dashboard, Kopia encryption verification, CloudNativePG PITR, break-glass procedure walkthrough

### Estimated Effort
2-3 sessions

### Risks and Gotchas
- **An untested backup is not a backup**: The restore test is the most important task in this phase. Do NOT skip it
- **Velero + local-path**: local-path-provisioner PVs are backed up via Kopia file-system backup (restic-style). This is slower than snapshot-based backup but works on any storage
- **Kopia passphrase management**: If stored only in OpenBao and OpenBao is on the VPS that failed, you cannot decrypt backups. Keep a copy in Vaultwarden AND offline
- **B2 egress costs**: Free storage is cheap (~$0.006/GB/mo), but egress during restore is ~$0.01/GB. Budget $5-10 for a full cluster restore
- **MinIO TLS**: Velero must connect to MinIO over TLS. If TLS is not configured on MinIO, backup uploads will fail or be insecure

---

## Phase 9: CI/CD Completion

> **Goal**: Complete the Devtron pipeline: GitHub webhooks, Harbor push, image scanning in CI, environment promotion, and end-to-end deployment testing.

### Prerequisites
- Phase 2 complete (Harbor running, Authentik OIDC configured)
- Phase 3 complete (Kyverno admission control, Cosign signing)
- Phase 5 complete (monitoring for pipeline observability)

### Specialist Team
- **Kit** (DevOps Engineer) -- Devtron pipeline config, GitHub integration, Harbor push
- **Ezra** (Security Engineer) -- Trivy scanning in CI, Cosign signing step

### Tasks

1. **Configure GitHub PAT for Devtron GitOps**
   - Create fine-grained PAT with repo + webhook permissions
   - Store in OpenBao, sync via ESO to Devtron
   - Configure Devtron global configuration -> Git Accounts

2. **Configure Devtron to push to Harbor**
   - Add Harbor registry in Devtron: Container Registry -> harbor.internal.helixstax.com
   - Configure pull secret for all application namespaces
   - Set `imagePullPolicy: IfNotPresent` globally (avoid Docker Hub rate limits)

3. **Add Trivy scan step to CI pipeline**
   - Devtron has built-in Trivy integration -- enable in pipeline configuration
   - Set vulnerability threshold: fail pipeline on High/Critical CVEs
   - Alternative: use Trivy CLI as a pre-deployment step

4. **Add Cosign signing step to CI pipeline**
   - After successful build + scan, sign image with Cosign
   - Store Cosign private key in OpenBao
   - Kyverno (deployed in Phase 3) will reject unsigned images

5. **Set up environments in Devtron**
   - Production environment: auto-deploy on main branch merge
   - Staging environment: auto-deploy on PR creation (if resources allow)
   - Manual promotion: staging -> production via Devtron UI

6. **Configure GitHub webhooks**
   - Point to Devtron ingress endpoint
   - Trigger on: push to main, PR opened, PR merged
   - Expose Devtron webhook endpoint behind Traefik IngressRoute (authenticated)

7. **Move Devtron dashboard behind Traefik + Authentik**
   - Create IngressRoute for devtron.internal.helixstax.com
   - Configure Authentik forward-auth middleware
   - Remove NodePort 31656 exposure (close firewall rule)

8. **End-to-end pipeline test**
   - Create test repo on GitHub
   - Push a Dockerfile + simple app
   - Verify: webhook fires -> Devtron builds -> Trivy scans -> Cosign signs -> Harbor pushes -> ArgoCD deploys to cluster
   - Verify: Kyverno accepts signed image, rejects unsigned

9. **Configure pipeline notifications**
   - Build success/failure -> Telegram
   - Deployment success/failure -> Telegram
   - Critical CVE found -> Telegram

10. **Configure Harbor pull-through cache**
    - Set up pull-through proxy for Docker Hub
    - Redirect cluster image pulls through Harbor to avoid rate limits

### Acceptance Criteria
- [ ] GitHub -> Devtron webhook working (push triggers build)
- [ ] CI pipeline: build -> scan -> sign -> push to Harbor
- [ ] Trivy blocking images with High/Critical CVEs
- [ ] Cosign signing all images, Kyverno rejecting unsigned
- [ ] ArgoCD deploying from Harbor to cluster
- [ ] Devtron dashboard accessible only via Traefik + Authentik (NodePort closed)
- [ ] End-to-end test: code push -> running pod in cluster
- [ ] Pipeline notifications to Telegram working
- [ ] Harbor pull-through cache serving Docker Hub images

### Handoff (Final)
- CI/CD pipeline documentation
- Harbor registry URL and credentials
- Devtron access URL (internal only)
- Environment promotion procedure
- Pipeline notification channels

### Tutorial Content Deliverables
- **Article**: "Complete CI/CD on K3s: Devtron + Harbor + Image Signing with Zero Docker Hub Dependency"
- **Video**: "From Git Push to Production -- Full Pipeline Demo on Kubernetes"
- **Screenshots/recordings needed**: Devtron pipeline editor, Trivy scan results, Cosign signing output, Harbor image list, ArgoCD sync status, Kyverno admission/rejection logs, end-to-end deployment recording

### Estimated Effort
3-4 sessions

### Risks and Gotchas
- **Devtron + external Harbor**: Devtron's built-in CI expects a registry. Switching from default GHCR/DockerHub to self-hosted Harbor requires correct configuration of registry credentials, TLS trust, and pull secrets
- **Cosign key management**: If the Cosign private key is lost, all future images will be unsigned and Kyverno will block them. Store in OpenBao with backup in Vaultwarden
- **Webhook exposure**: Devtron needs a public endpoint for GitHub webhooks. This is a controlled exposure -- authenticate with webhook secret. Do NOT expose the full Devtron dashboard publicly
- **ArgoCD sync conflicts**: If manual `kubectl apply` changes resources that ArgoCD manages, ArgoCD will detect drift and revert. Ensure all deployments go through GitOps only
- **Devtron reinstall fragility**: From lessons learned -- ArgoCD must use official stable manifest, NOT the devtron/argocd chart (it is obsolete). If Devtron needs reconfiguration, proceed carefully

---

## Timeline Summary

| Phase | Name | Estimated Sessions | Calendar Weeks | Parallelizable With |
|-------|------|--------------------|----------------|---------------------|
| 0 | Server Hardening | 2-3 | 1 | -- |
| 1 | Foundation (Terraform + VPS) | 2-3 | 1-2 | -- |
| 2 | Management Services | 4-5 | 2 | -- |
| 3 | Cluster Security | 4-5 | 2 | -- |
| 4 | Data Layer | 3-4 | 1-2 | Phase 5 |
| 5 | Observability | 3-4 | 1-2 | Phase 4 |
| 6 | Application Layer | 3-4 | 1-2 | Phase 8, Phase 9 |
| 7 | Multi-Tenant | 4-5 | 2 | -- |
| 8 | Backup & DR | 2-3 | 1 | Phase 5, Phase 6, Phase 9 |
| 9 | CI/CD Completion | 3-4 | 1-2 | Phase 5, Phase 6, Phase 8 |
| **TOTAL** | | **30-40 sessions** | **10-14 weeks** | |

### Critical Path
```
Phase 0 (1 wk) -> Phase 1 (1.5 wk) -> Phase 2 (2 wk) -> Phase 3 (2 wk) -> Phase 4 (1.5 wk) -> Phase 6 (1.5 wk) -> Phase 7 (2 wk)
                                                                              \-> Phase 5 (1.5 wk, parallel with 4)
                                                                              \-> Phase 8 (1 wk, after Phase 2)
                                                                              \-> Phase 9 (1.5 wk, after Phase 2)
```

**Minimum calendar time** (with maximum parallelism): ~10 weeks
**Expected calendar time** (realistic with overhead): ~12-14 weeks

---

## Monthly Cost After Completion

| Resource | Monthly Cost |
|----------|-------------|
| heart (CPX31, control plane) | ~$8 |
| helix-worker-1 (CPX51, 64GB) | ~$35 |
| External VPS (CX32, 8GB) | ~$8 |
| Backblaze B2 (~50GB) | ~$0.30 |
| Cloudflare for Platforms | ~$20-50 (scales with clients) |
| **Base (no clients)** | **~$51** |
| **With 10+ clients** | **~$73-100** |

---

## Post-Buildout: What Comes Next

| Trigger | Action | Estimated Phase |
|---------|--------|----------------|
| Worker RAM > 80% consistently | Add 2nd worker node | Post-buildout |
| 3+ worker nodes | Evaluate Talos OS migration, enable Longhorn | Q3 2026 |
| 10+ microservices | Evaluate Cilium mutual auth (SPIFFE mTLS) | Q3 2026 |
| Real-time AI demand | Rent GPU instances (RunPod/Lambda) | On-demand |
| 50+ client sites | Dedicated database server | Revenue trigger |
| Enterprise clients | SOC 2 Type II certification | Revenue trigger |
| Quarterly | Disaster recovery drill (full restore test) | Recurring |
| 90 days | Credential rotation cycle | Recurring |

---

*Sprint plan by Sable (Product Manager) -- synthesized from specialist reviews by [[06-agents/stax-architect|Cass]], [[06-agents/stax-devops-engineer|Kit]], and [[06-agents/stax-security-engineer|Ezra]]. 2026-03-17.*
