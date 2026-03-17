# Changelog

All notable changes to the Helix Stax infrastructure are documented here.

## [0.1.0] - 2026-03-17

### Phase 0: Server Hardening

#### Added
- SSH hardening on both nodes (port 2222, key-only auth, fail2ban)
- Firewall hardening via firewalld (default-deny, custom k8s-hardened zone)
- Hetzner Cloud Firewall on CP node (port 2222, 6443, 80, 443)
- Kernel tuning on worker node (sysctl, file descriptors, kubelet reservation)
- DNS fix for IPv4 nameservers on both nodes
- CIS Level 1 benchmarks passed on both nodes
- Automatic security updates (dnf-automatic) on both nodes
- Audit logging (auditd) with 25+ watch rules on both nodes
- SSH legal warning banner on both nodes

#### Changed
- Renamed heart → helix-stax-cp
- Renamed helix-worker-1 → helix-stax-worker-1
- SSH port 22 → 2222 on both nodes

#### Removed
- K3s cluster (full wipe for clean rebuild)
- Load balancer: helix-k8s-api-lb (ID: 5886481) — $6/mo saved
- Load balancer: helix-ingress-lb (ID: 5889680) — $6/mo saved
- Plaintext credentials from memory files (3 passwords scrubbed)
- All K3s residual directories (/var/lib/rancher/, /etc/rancher/, /var/lib/cni/)

#### Fixed
- SSH lockout during initial hardening attempt (Hetzner Cloud Firewall missing port 2222)
- Resolved via rescue mode — documented in 02-ssh-hardening.md execution log

#### Discovered
- Worker node has SATA SSDs (not NVMe) — I/O scheduler left as mq-deadline
- Worker already had 8GB swap partition — skipped swap file creation
- SELinux in Permissive mode on CP — semanage still required for port labeling
- firewalld not installed by default on Hetzner AlmaLinux — installed manually

### Infrastructure Cost
- Monthly savings: $12/mo (deleted 2 load balancers)
- Current spend: ~$46/mo (2 nodes, no VPS yet)
