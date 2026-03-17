---
tags: [infrastructure, phase-0, kernel, tuning, worker-node, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
phase: "0"
step: "03"
estimated-time: "10-15 minutes"
nodes: [helix-worker-1]
author: Kit (DevOps Engineer)
---

# Step 03: Worker Node Kernel Tuning

> **Goal**: Optimize helix-worker-1 (CPX51: 16 vCPU, 64GB RAM) kernel parameters for Kubernetes workloads, database operations, and high pod density. This runs BEFORE K3s is reinstalled.

## Prerequisites

- [ ] K3s fully wiped from helix-worker-1 (completed in [[01-wipe-cluster]])
- [ ] OS hardening completed (completed in [[02-os-hardening]])
- [ ] SSH access to helix-worker-1 confirmed

> **Why worker only?** Heart (CP, 8GB) runs the control plane with default tuning. The worker (64GB) runs all workloads -- databases, app pods, ingress -- and benefits significantly from tuned kernel parameters.

---

## 1. Kernel Parameter Tuning (sysctl)

SSH into the worker node:

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
```

### 1.1 Check Current Values (Before)

Record current values for comparison:

```bash
echo "=== Current kernel parameters ==="
sysctl vm.swappiness
sysctl vm.max_map_count
sysctl fs.inotify.max_user_watches
sysctl fs.file-max
sysctl net.core.somaxconn
sysctl net.ipv4.ip_forward
sysctl net.ipv4.conf.all.forwarding
sysctl net.bridge.bridge-nf-call-iptables 2>/dev/null || echo "bridge module not loaded (OK)"
```

> **Tutorial note**: Screenshot this output. Good before/after comparison for the tutorial.

### 1.2 Create Kernel Tuning Configuration

```bash
cat > /etc/sysctl.d/99-k8s-tuning.conf << 'EOF'
# =============================================================================
# Kubernetes Worker Node Kernel Tuning
# Node: helix-worker-1 (CPX51 -- 16 vCPU, 64GB RAM)
# Created: 2026-03-17
# =============================================================================

# --- Memory Management ---
# Minimize swap usage. Kubernetes prefers OOM kills over swap thrashing.
# Value of 10 means swap is used only as emergency overflow.
vm.swappiness = 10

# Required for Elasticsearch/OpenSearch-like workloads (Loki, vector DBs).
# Default is 65530; many data services require 262144+.
vm.max_map_count = 262144

# --- File System ---
# High inotify watch limit for Kubernetes. Each pod/container uses watchers
# for config maps, secrets, and health probes. Default (8192) is too low
# for clusters with 50+ pods.
fs.inotify.max_user_watches = 524288

# Max inotify instances (default is usually 128, raise for many pods)
fs.inotify.max_user_instances = 1024

# System-wide file descriptor limit. Supports many concurrent connections
# across database, ingress, and application pods.
fs.file-max = 2097152

# --- Networking ---
# Max connection backlog for listening sockets. Traefik ingress and databases
# benefit from higher values under load. Default is 4096.
net.core.somaxconn = 32768

# Required for CNI (Cilium, Flannel, Calico). Allows pod-to-pod and
# pod-to-external traffic forwarding.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1

# Required for kube-proxy/iptables mode. Bridge traffic must pass through
# iptables for Kubernetes Service routing to work.
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# --- Connection Tracking ---
# Increase conntrack table size for high pod counts. Default (65536) can
# cause packet drops under heavy inter-pod traffic.
net.netfilter.nf_conntrack_max = 131072
EOF
```

### 1.3 Load Bridge Module (Required for bridge-nf-call Settings)

The `bridge-nf-call-iptables` settings require the `br_netfilter` module:

```bash
# Load now
modprobe br_netfilter
modprobe overlay

# Persist across reboots
cat > /etc/modules-load.d/k8s.conf << 'EOF'
br_netfilter
overlay
EOF
```

### 1.4 Apply Kernel Parameters

```bash
sysctl --system
```

### 1.5 Verify Applied Values

```bash
echo "=== Verifying kernel parameters ==="
sysctl vm.swappiness                        # Expected: 10
sysctl vm.max_map_count                     # Expected: 262144
sysctl fs.inotify.max_user_watches          # Expected: 524288
sysctl fs.inotify.max_user_instances        # Expected: 1024
sysctl fs.file-max                          # Expected: 2097152
sysctl net.core.somaxconn                   # Expected: 32768
sysctl net.ipv4.ip_forward                  # Expected: 1
sysctl net.ipv4.conf.all.forwarding         # Expected: 1
sysctl net.bridge.bridge-nf-call-iptables   # Expected: 1
sysctl net.netfilter.nf_conntrack_max       # Expected: 131072
```

> **Tutorial note**: Screenshot this verification output side by side with the "before" values.

---

## 2. File Descriptor Limits (ulimit)

Kernel `fs.file-max` sets the system-wide limit, but per-process limits also need raising. This affects all services running on the node (kubelet, containerd, database pods).

### 2.1 Check Current Limits

```bash
ulimit -n        # Soft limit (per-process open files)
ulimit -Hn       # Hard limit
```

### 2.2 Create Limits Configuration

```bash
cat > /etc/security/limits.d/99-k8s.conf << 'EOF'
# Kubernetes worker node file descriptor limits
# Applies to all users and services
*    soft    nofile    1048576
*    hard    nofile    1048576
*    soft    nproc     65535
*    hard    nproc     65535
root soft    nofile    1048576
root hard    nofile    1048576
root soft    nproc     65535
root hard    nproc     65535
EOF
```

### 2.3 Verify (Requires New Session)

File descriptor limits apply to new sessions. Open a new SSH connection to verify:

```bash
# Exit and reconnect
exit
```

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
ulimit -n        # Expected: 1048576
ulimit -Hn       # Expected: 1048576
```

---

## 3. Kubelet Resource Reservation

When K3s is reinstalled, the kubelet should reserve system resources so workloads don't starve the OS and kubelet itself. This config is **prepared now** but **takes effect when K3s is installed** in a later phase.

### 3.1 Create Kubelet Extra Config Directory

```bash
mkdir -p /etc/rancher/k3s/
```

### 3.2 Write Kubelet Config

```bash
cat > /etc/rancher/k3s/kubelet-config.yaml << 'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Reserve resources for system daemons and kubelet itself
# helix-worker-1: 16 vCPU, 64GB RAM
# Reserve: 1 CPU + 2GB RAM for system, leaving ~15 vCPU + 62GB for pods
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "1Gi"
# Eviction thresholds -- start evicting pods before the node runs dry
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "10%"
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "15%"
  imagefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: "1m30s"
  nodefs.available: "1m30s"
  imagefs.available: "1m30s"
EOF
```

> **Note**: When installing K3s on this worker, pass `--kubelet-arg="config=/etc/rancher/k3s/kubelet-config.yaml"` to use this config. This will be covered in the K3s reinstall phase.

### 3.3 Effective Workload Capacity

| Resource | Total | System Reserved | Kube Reserved | Eviction Buffer | Available for Pods |
|----------|-------|----------------|---------------|-----------------|-------------------|
| CPU | 16 vCPU | 500m | 500m | -- | ~15 vCPU |
| Memory | 64 GiB | 1 GiB | 1 GiB | 500 MiB (hard) | ~61.5 GiB |

---

## 4. Swap Configuration

Kubernetes historically didn't support swap well, but K3s (1.29+) supports swap with `NodeSwap` feature gate. We configure a small swap file as emergency overflow only -- `swappiness=10` means it's rarely touched.

### 4.1 Check Existing Swap

```bash
swapon --show
free -h | grep Swap
```

If swap already exists, skip to 4.4 to verify the size. Otherwise:

### 4.2 Create 4GB Swap File

```bash
# Create the swap file (fallocate is faster than dd)
fallocate -l 4G /swapfile

# Secure permissions (swap should only be readable by root)
chmod 600 /swapfile

# Format as swap
mkswap /swapfile

# Enable swap
swapon /swapfile
```

### 4.3 Persist Across Reboots

```bash
# Add to fstab if not already present
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 4.4 Verify Swap

```bash
swapon --show
# Expected: /swapfile file 4G 0B -2

free -h | grep Swap
# Expected: Swap: 4.0Gi  0B  4.0Gi

sysctl vm.swappiness
# Expected: 10 (set in step 1)
```

> **Tutorial note**: Explain why swappiness=10 is the right balance -- not 0 (which can cause OOM kills when memory is barely full) and not the default 60 (which swaps too aggressively for database workloads).

---

## 5. NVMe Verification and I/O Scheduler

Hetzner CPX51 uses NVMe storage. Verify it's properly detected and using the optimal I/O scheduler.

### 5.1 Check Storage Device Type

```bash
lsblk -d -o NAME,ROTA,TRAN,MODEL
```

Expected: `ROTA=0` (not rotational = SSD/NVMe), `TRAN=nvme`.

### 5.2 Check I/O Scheduler

```bash
cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null || cat /sys/block/sda/queue/scheduler
```

Expected output for NVMe: `[none] mq-deadline kyber bfq`

The `[none]` scheduler is optimal for NVMe -- the device has its own internal queue management, and adding a software scheduler adds overhead.

### 5.3 Set I/O Scheduler (If Not Already `none`)

If the scheduler isn't `none`:

```bash
# Set for current session
echo "none" > /sys/block/nvme0n1/queue/scheduler

# Persist via udev rule
cat > /etc/udev/rules.d/60-ioscheduler.rules << 'EOF'
# Use 'none' scheduler for NVMe devices (they have internal queuing)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
EOF
```

### 5.4 Check TRIM/Discard Support

```bash
# Check if TRIM is supported
lsblk -D | grep -E '(NAME|nvme)'

# Check fstrim timer (should be enabled on Hetzner by default)
systemctl status fstrim.timer
```

If `fstrim.timer` is not enabled:

```bash
systemctl enable --now fstrim.timer
```

### 5.5 Verify I/O Performance (Quick Sanity Check)

```bash
# Sequential write test (should see 500+ MB/s on NVMe)
dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 oflag=direct 2>&1 | tail -1

# Clean up
rm -f /tmp/testfile
```

---

## 6. Final Verification

Run all checks in one shot:

```bash
echo "=============================="
echo "  Kernel Tuning Verification"
echo "  Node: helix-worker-1"
echo "=============================="
echo ""
echo "--- sysctl values ---"
sysctl vm.swappiness vm.max_map_count fs.inotify.max_user_watches fs.file-max net.core.somaxconn net.ipv4.ip_forward
echo ""
echo "--- File descriptor limits ---"
ulimit -n
echo ""
echo "--- Swap ---"
swapon --show
echo ""
echo "--- I/O Scheduler ---"
cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null || cat /sys/block/sda/queue/scheduler
echo ""
echo "--- Kernel modules ---"
lsmod | grep -E '(br_netfilter|overlay)'
echo ""
echo "--- Kubelet config prepared ---"
ls -la /etc/rancher/k3s/kubelet-config.yaml
echo ""
echo "=============================="
echo "  All checks complete"
echo "=============================="
```

> **Tutorial note**: Screenshot this full verification block. Summarizes all tuning in one view.

---

## Rollback Plan

### Kernel Parameters

```bash
# Remove the tuning file and reapply defaults
rm /etc/sysctl.d/99-k8s-tuning.conf
sysctl --system
```

### File Descriptor Limits

```bash
rm /etc/security/limits.d/99-k8s.conf
# Reconnect SSH for defaults to take effect
```

### Swap

```bash
swapoff /swapfile
rm /swapfile
sed -i '/\/swapfile/d' /etc/fstab
```

### Kubelet Config

```bash
rm -rf /etc/rancher/k3s/
```

### I/O Scheduler

```bash
rm /etc/udev/rules.d/60-ioscheduler.rules
# Reboot to restore default scheduler
```

---

## Summary

| Action | Status |
|--------|--------|
| Kernel parameters (`/etc/sysctl.d/99-k8s-tuning.conf`) | [ ] |
| File descriptor limits (`/etc/security/limits.d/99-k8s.conf`) | [ ] |
| Kernel modules (br_netfilter, overlay) | [ ] |
| Kubelet resource reservation config prepared | [ ] |
| 4GB swap file created (swappiness=10) | [ ] |
| NVMe verified + I/O scheduler = none | [ ] |
| TRIM/fstrim timer enabled | [ ] |
| All values verified | [ ] |

**Next step**: [[04-dns-fix]] (DNS configuration for CoreDNS)

## Execution Log

### Issue 1: Some Kernel Parameters Already Set from Prior K3s Install
- **What happened**: Running `sysctl --system` applied new parameters, but some were already in place from the previous K3s installation (swappiness=10, ip_forward=1, bridge-nf-call-iptables=1).
- **Root cause**: Previous K3s install had already configured these; the fresh configuration re-applied them idempotently.
- **Fix applied**: No action needed. sysctl values were verified post-application. Any pre-existing values that matched the guide were left alone.
- **Lesson for readers**: If re-running kernel tuning on a node that previously had K3s, some values may be duplicated. Use `sysctl --system` idempotently — it won't hurt to re-apply.

### Issue 2: Swap Partition Already Existed
- **What happened**: The worker node already had an 8GB swap partition (/dev/md1) from previous setup. The guide assumes creating a swap file; swap file creation step was skipped.
- **Root cause**: Hetzner dedicated server provisioning included pre-configured swap during OS deployment.
- **Fix applied**: Verified swap was enabled and properly configured. Skipped fallocate and mkswap steps since partition-based swap was already present.
- **Lesson for readers**: Check `swapon --show` before creating a swap file. Some cloud providers and dedicated server installers pre-allocate swap. Partition-based swap is actually preferable to file-based swap.

### Issue 3: Storage Type Differs from Guide Assumptions
- **What happened**: Guide assumed NVMe storage (CPX51 cloud server), but worker node actually has SATA SSDs (INTEL SSDSC2KB480G8 + INTEL SSDSC2BB480G4). This affects I/O scheduler choice.
- **Root cause**: Tutorial was written for a specific Hetzner CPX51 model; worker is a dedicated server with different hardware.
- **Fix applied**: Left I/O scheduler as `mq-deadline` (optimal for SATA), which was already set. Did not change to `none` (which is for NVMe only).
- **Lesson for readers**: Always verify hardware before applying I/O scheduler tuning. Use `lsblk -d -o NAME,ROTA,TRAN,MODEL` to check. For SATA SSDs, `mq-deadline` is correct; for NVMe, `none` is optimal.

## Deviations from Guide
- **Swap**: Skipped swap file creation because partition-based swap already existed. Confirmed swappiness=10 was set, which is the same as guide intent.
- **I/O Scheduler**: Left as `mq-deadline` instead of setting to `none`. Guide assumes NVMe; this node has SATA SSDs where `mq-deadline` is the correct choice.
- **Hardware mismatch**: Guide is for Hetzner CPX51 (cloud instance); worker is a dedicated server with SATA storage and existing swap partition.
