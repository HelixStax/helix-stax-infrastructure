---
tags: [infrastructure, phase-0, k3s, wipe, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
phase: "0"
step: "01"
estimated-time: "15-20 minutes"
nodes: [heart, helix-worker-1]
author: Kit (DevOps Engineer)
---

# Step 01: Wipe K3s Cluster

> **Goal**: Completely remove K3s from both nodes, leaving a clean AlmaLinux 9.7 base ready for hardening and fresh install. The OS stays -- only K3s and its artifacts are removed.

## Prerequisites

- [ ] SSH access to both nodes confirmed
- [ ] **Hetzner Cloud Console open in browser** (backdoor if SSH breaks during cleanup)
  - heart: https://console.hetzner.cloud → Servers → heart → Console
  - helix-worker-1: https://console.hetzner.cloud → Servers → helix-worker-1 → Console
- [ ] No data worth preserving (user confirmed: nothing to keep)
- [ ] `hcloud` CLI installed locally with valid token

> **Tutorial note**: Screenshot the Hetzner Console tab open as your safety net before starting. Good visual for the tutorial intro.

---

## 1. Wipe Worker Node First (helix-worker-1)

Always wipe worker nodes before the control plane. The agent uninstall is simpler and avoids the worker trying to reconnect to a dead CP.

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
```

### 1.1 Run K3s Agent Uninstall

```bash
/usr/local/bin/k3s-agent-uninstall.sh
```

This script:
- Stops the k3s-agent service
- Kills all k3s-related processes
- Removes the k3s binary and systemd unit files
- Cleans up basic K3s data directories

### 1.2 Verify K3s Processes Gone

```bash
ps aux | grep -i k3s
```

Expected: Only the `grep` process itself shows up. No `k3s-agent`, no `containerd`, no `kubelet`.

### 1.3 Clean Up Leftover Directories

The uninstall script doesn't always clean everything. Remove manually:

```bash
rm -rf /var/lib/rancher/
rm -rf /etc/rancher/
rm -rf /var/lib/cni/
rm -rf /etc/cni/
rm -rf /var/lib/kubelet/
rm -rf /var/log/pods/
rm -rf /var/log/containers/
rm -rf /opt/cni/
```

### 1.4 Clean Up Stale Network Rules

Flannel and kube-proxy leave behind iptables/nftables rules and virtual interfaces:

```bash
# Remove CNI virtual interfaces
ip link delete cni0 2>/dev/null
ip link delete flannel.1 2>/dev/null
ip link delete flannel-v6.1 2>/dev/null
ip link delete kube-bridge 2>/dev/null
ip link delete kube-dummy-if 2>/dev/null

# Flush iptables rules left by kube-proxy and Flannel
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
ip6tables -F
ip6tables -t nat -F
ip6tables -t mangle -F
ip6tables -X

# If using nftables backend (AlmaLinux 9 default)
nft flush ruleset
```

> **Warning**: Flushing iptables/nftables removes ALL firewall rules, including any custom ones. This is fine because we're about to rebuild firewall rules from scratch in the hardening phase. If you have custom rules you want to keep, back them up first with `iptables-save > /tmp/iptables-backup.txt` and `nft list ruleset > /tmp/nft-backup.txt`.

### 1.5 Verify Clean State on Worker

```bash
# No K3s processes
ps aux | grep -E '(k3s|kubelet|containerd)' | grep -v grep

# No K3s directories
ls /var/lib/rancher/ 2>&1
ls /etc/rancher/ 2>&1
ls /var/lib/cni/ 2>&1
ls /etc/cni/ 2>&1

# No CNI interfaces
ip link show | grep -E '(cni0|flannel|kube)'

# No K3s binaries
which k3s 2>&1
which kubectl 2>&1
which crictl 2>&1
```

Expected: All commands return "No such file or directory" or empty output.

```bash
echo "=== Worker node (helix-worker-1) wipe complete ==="
```

> **Tutorial note**: Screenshot the clean verification output. Good before/after comparison.

---

## 2. Wipe Control Plane Node (heart)

```bash
ssh -i ~/.ssh/helixstax_key root@178.156.233.12
```

### 2.1 Run K3s Server Uninstall

```bash
/usr/local/bin/k3s-uninstall.sh
```

This script does more than the agent uninstall:
- Stops the k3s server service
- Kills all k3s-related processes (including embedded etcd, API server, scheduler, etc.)
- Removes binaries, systemd units, and data directories
- Removes the node token and kubeconfig

### 2.2 Verify K3s Processes Gone

```bash
ps aux | grep -i k3s
```

Expected: Only the `grep` process itself.

### 2.3 Clean Up Leftover Directories

```bash
rm -rf /var/lib/rancher/
rm -rf /etc/rancher/
rm -rf /var/lib/cni/
rm -rf /etc/cni/
rm -rf /var/lib/kubelet/
rm -rf /var/log/pods/
rm -rf /var/log/containers/
rm -rf /opt/cni/
```

### 2.4 Clean Up Stale Network Rules

Same as worker -- Flannel and kube-proxy leave behind rules:

```bash
# Remove CNI virtual interfaces
ip link delete cni0 2>/dev/null
ip link delete flannel.1 2>/dev/null
ip link delete flannel-v6.1 2>/dev/null
ip link delete kube-bridge 2>/dev/null
ip link delete kube-dummy-if 2>/dev/null

# Flush iptables rules
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
ip6tables -F
ip6tables -t nat -F
ip6tables -t mangle -F
ip6tables -X

# Flush nftables
nft flush ruleset
```

### 2.5 Verify Clean State on CP

```bash
# No K3s processes
ps aux | grep -E '(k3s|kubelet|containerd|etcd)' | grep -v grep

# No K3s directories
ls /var/lib/rancher/ 2>&1
ls /etc/rancher/ 2>&1
ls /var/lib/cni/ 2>&1
ls /etc/cni/ 2>&1

# No CNI interfaces
ip link show | grep -E '(cni0|flannel|kube)'

# No K3s binaries
which k3s 2>&1
which kubectl 2>&1
which crictl 2>&1

# No K3s systemd units
systemctl list-units | grep k3s
```

Expected: All commands return empty or "No such file or directory".

```bash
echo "=== Control plane node (heart) wipe complete ==="
```

---

## 3. Delete Unnecessary Hetzner Load Balancer

Run this from your **local machine** (not via SSH). Requires `hcloud` CLI with valid token.

### 3.1 Verify the Load Balancer Exists

```bash
hcloud load-balancer list
```

Expected: Shows `helix-k8s-api-lb` (ID: 5886481).

### 3.2 Delete It

```bash
hcloud load-balancer delete 5886481
```

### 3.3 Verify Deletion

```bash
hcloud load-balancer list
```

Expected: Empty list or the LB no longer appears.

> **Why delete?** Single control plane node means no HA benefit from a load balancer. Saves ~$6/month. If we add a second CP node later, we'll create a new one with proper config.

> **Tutorial note**: Screenshot the `hcloud load-balancer list` before and after deletion. Good cost-saving callout for the tutorial.

---

## 4. Final Verification (Both Nodes)

### 4.1 Heart (CP)

```bash
ssh -i ~/.ssh/helixstax_key root@178.156.233.12 "echo '--- heart ---' && ps aux | grep -c k3s && ls /var/lib/rancher 2>&1 && echo 'Wipe: CLEAN'"
```

### 4.2 Helix-Worker-1

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157 "echo '--- helix-worker-1 ---' && ps aux | grep -c k3s && ls /var/lib/rancher 2>&1 && echo 'Wipe: CLEAN'"
```

Expected for both: `grep -c` returns `1` (the grep itself), `/var/lib/rancher` not found.

---

## Rollback Plan

**There is no rollback.** This is a destructive wipe by design. The entire point is to start fresh. If something goes wrong with the OS itself:

1. Use Hetzner Cloud Console (your backdoor) to access the node
2. If the OS is broken, use Hetzner's "Rescue System" to boot into a live environment
3. Worst case: rebuild the server from Hetzner dashboard (AlmaLinux 9.7 image) -- IP is retained

---

## Summary

| Action | Node | Status |
|--------|------|--------|
| K3s agent uninstalled | helix-worker-1 | [ ] |
| Leftover dirs removed | helix-worker-1 | [ ] |
| Network rules flushed | helix-worker-1 | [ ] |
| Clean state verified | helix-worker-1 | [ ] |
| K3s server uninstalled | heart | [ ] |
| Leftover dirs removed | heart | [ ] |
| Network rules flushed | heart | [ ] |
| Clean state verified | heart | [ ] |
| Load balancer deleted | Hetzner Cloud | [ ] |

**Next step**: [[02-os-hardening]] (SSH hardening, firewall, CIS benchmarks)
