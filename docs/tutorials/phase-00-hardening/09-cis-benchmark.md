---
tags: [infrastructure, hardening, cis-benchmark, auditd, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 60-90 minutes
applies-to: [heart, helix-worker-1]
---

# 09 — CIS Benchmark Hardening

> Apply CIS Level 1 benchmarks for AlmaLinux 9 and configure auditd for filesystem monitoring. After K3s is reinstalled (Phase 1), run kube-bench for Kubernetes-specific checks.
>
> **Run on**: heart (178.156.233.12) AND helix-worker-1 (138.201.131.157)
> **Estimated time**: 60-90 minutes (both nodes)

---

## Prerequisites

- SSH access to both nodes on port 2222
- [[02-ssh-hardening]] completed
- [[06-firewall-hardening]] completed
- [[07-fail2ban-setup]] completed

---

## Tutorial Notes

> **Content capture**: Screenshot each section's before/after check. Run the full verification script at the end and capture the pass/fail summary. Explain what CIS benchmarks are and why Level 1 vs Level 2 matters for a startup.

---

## Part 1: Filesystem Hardening

### Step 1: Harden /tmp Mount Options

The `/tmp` directory should have `nodev`, `nosuid`, and `noexec` to prevent privilege escalation via temp files.

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

**Check current mount**:

```bash
findmnt /tmp
```

If `/tmp` is not a separate mount (common on cloud VPS), create one using tmpfs:

```bash
# Check if /tmp is already in fstab
grep '/tmp' /etc/fstab

# If not present, add a tmpfs mount with hardened options
echo 'tmpfs /tmp tmpfs defaults,nodev,nosuid,noexec,size=2G 0 0' >> /etc/fstab

# Mount it
mount -o remount /tmp 2>/dev/null || mount /tmp
```

**Verify**:

```bash
findmnt /tmp
# Should show: nodev,nosuid,noexec
```

### Step 2: Harden /var/tmp

```bash
# Bind mount /var/tmp to /tmp (inherits /tmp restrictions)
echo '/tmp /var/tmp none bind 0 0' >> /etc/fstab
mount --bind /tmp /var/tmp
```

**Verify**:

```bash
findmnt /var/tmp
```

### Step 3: Harden /home Mount Options

```bash
# Check if /home is a separate mount
findmnt /home

# If it is, remount with nodev
# If /home is in fstab, add nodev to the options
# If /home is not a separate mount, skip this step (common on cloud VPS)
```

> [!NOTE]
> On Hetzner cloud VPS, /home is typically not a separate partition. If it is, add `nodev` to its mount options in `/etc/fstab`.

---

## Part 2: File Permission Hardening

### Step 4: Critical File Permissions

```bash
# /etc/passwd — world-readable, not writable
chmod 644 /etc/passwd
chown root:root /etc/passwd

# /etc/shadow — root-only
chmod 000 /etc/shadow
chown root:root /etc/shadow

# /etc/group — world-readable, not writable
chmod 644 /etc/group
chown root:root /etc/group

# /etc/gshadow — root-only
chmod 000 /etc/gshadow
chown root:root /etc/gshadow

# SSH config directory
chmod 600 /etc/ssh/sshd_config
chown root:root /etc/ssh/sshd_config
```

**Verify**:

```bash
echo "=== File Permissions ==="
stat -c '%a %U:%G %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/ssh/sshd_config
```

Expected:

```
644 root:root /etc/passwd
000 root:root /etc/shadow
644 root:root /etc/group
000 root:root /etc/gshadow
600 root:root /etc/ssh/sshd_config
```

---

## Part 3: Disable Unnecessary Services

### Step 5: Audit and Disable

```bash
echo "=== Currently enabled services ==="
systemctl list-unit-files --state=enabled --type=service --no-pager

# Disable services not needed on a K8s node
# Check if each exists before disabling (some may not be installed)

for svc in cups.service avahi-daemon.service cups-browsed.service \
           bluetooth.service ModemManager.service rpcbind.service \
           rpcbind.socket nfs-server.service; do
    if systemctl is-enabled "$svc" 2>/dev/null | grep -q enabled; then
        echo "Disabling: $svc"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        systemctl mask "$svc"
    else
        echo "Already disabled or not installed: $svc"
    fi
done
```

**Verify**:

```bash
# Should all show "masked" or "not-found"
for svc in cups avahi-daemon bluetooth ModemManager rpcbind nfs-server; do
    echo "$svc: $(systemctl is-enabled $svc.service 2>/dev/null || echo 'not-found')"
done
```

---

## Part 4: Network Hardening

### Step 6: Kernel Network Parameters

```bash
cat > /etc/sysctl.d/90-cis-hardening.conf << 'EOF'
# CIS Benchmark — Network Hardening

# Disable IPv6 (not used in this cluster)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# Disable ICMP redirects (prevent MITM routing attacks)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing (prevent IP spoofing)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Enable reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log martian packets (suspicious source addresses)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP broadcast requests (prevent smurf attacks)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable TCP SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1

# IP forwarding — MUST stay enabled for K8s/CNI
net.ipv4.ip_forward = 1
EOF
```

> [!WARNING]
> `net.ipv4.ip_forward = 1` MUST remain enabled. K3s and all CNI plugins (Flannel, Cilium) require IP forwarding. Disabling it will break pod networking.

**Apply immediately**:

```bash
sysctl --system
```

**Verify key settings**:

```bash
echo "=== Network Hardening Verification ==="
sysctl net.ipv6.conf.all.disable_ipv6
sysctl net.ipv4.conf.all.accept_redirects
sysctl net.ipv4.conf.all.send_redirects
sysctl net.ipv4.tcp_syncookies
sysctl net.ipv4.ip_forward
```

> [!NOTE]
> **IPv6 note**: Disabling IPv6 may affect Hetzner's default DNS config (see [[lessons_infrastructure]] — Hetzner AlmaLinux has IPv6-only DNS by default). Ensure `/etc/resolv.conf` has IPv4 nameservers (185.12.64.1, 185.12.64.2, 8.8.8.8) before disabling IPv6. This is handled in the DNS fix task (Phase 0, Task 7).

---

## Part 5: Audit Logging (auditd)

### Step 7: Install and Configure auditd

```bash
# Install audit framework
dnf install -y audit

# Verify
rpm -q audit
```

### Step 8: Configure Audit Rules

Create rules to monitor critical system files:

```bash
cat > /etc/audit/rules.d/50-cis-hardening.rules << 'EOF'
# CIS Benchmark — Audit Rules for Critical Files

# Monitor user/group changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity

# Monitor sudo configuration
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor SSH configuration
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/ -p wa -k ssh_config_dir

# Monitor login/logout events
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock/ -p wa -k logins

# Monitor cron jobs
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /etc/cron.weekly/ -p wa -k cron
-w /etc/cron.monthly/ -p wa -k cron

# Monitor kernel module loading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules

# Monitor network configuration changes
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl
-w /etc/hosts -p wa -k hosts

# Monitor time changes
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-w /etc/localtime -p wa -k time-change

# Monitor firewall changes
-w /etc/firewalld/ -p wa -k firewall

# Make audit config immutable (requires reboot to change)
# Uncomment after testing:
# -e 2
EOF
```

### Step 9: Enable and Start auditd

```bash
# Enable to start on boot
systemctl enable auditd

# Restart to load new rules
systemctl restart auditd
```

> [!NOTE]
> On AlmaLinux 9, auditd should NOT be managed with `systemctl stop/start` for the audit daemon itself in production. Use `augenrules --load` to reload rules without restarting.

**Load the rules**:

```bash
augenrules --load
```

**Verify rules are loaded**:

```bash
auditctl -l
```

You should see all the `-w` watch rules listed.

**Verify auditd is running**:

```bash
systemctl status auditd
auditctl -s
```

The status should show `enabled = 1`.

---

## Part 6: World-Writable Files Check

### Step 10: Find and Fix World-Writable Files

```bash
# Find world-writable files in system directories (excluding /tmp, /proc, /sys, /dev)
find / -path /tmp -prune -o -path /var/tmp -prune -o -path /proc -prune \
  -o -path /sys -prune -o -path /dev -prune -o -path /run -prune \
  -o -type f -perm -0002 -print 2>/dev/null
```

If any files are found, review them individually:

```bash
# For each file found, decide if world-writable is appropriate
# Most system files should NOT be world-writable
# Fix example:
# chmod o-w /path/to/file
```

---

## Part 7: kube-bench (Post-K3s Reinstall)

> [!NOTE]
> This section runs AFTER K3s is reinstalled in Phase 1. Skip for now and return to it later.

### Step 11: Run kube-bench

After K3s is freshly installed:

```bash
# Run kube-bench as a Kubernetes job
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml

# Wait for it to complete
kubectl wait --for=condition=complete job/kube-bench -n default --timeout=120s

# View results
kubectl logs job/kube-bench -n default
```

**Alternative: Run directly on the node**:

```bash
# Download kube-bench binary
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_0.8.0_linux_amd64.tar.gz -o kube-bench.tar.gz
tar xzf kube-bench.tar.gz
chmod +x kube-bench

# Run against K3s
./kube-bench run --targets node,master,controlplane,etcd,policies \
  --config-dir ./cfg --benchmark k3s-cis-1.24

# Save results
./kube-bench run --targets node,master,controlplane,etcd,policies \
  --config-dir ./cfg --benchmark k3s-cis-1.24 > /root/kube-bench-results.txt
```

### Step 12: Review and Remediate

Review the output for FAIL items. Common K3s-specific findings:

| Finding | Fix | Notes |
|---------|-----|-------|
| Secrets encryption at rest | Enable in Phase 1 K3s install | `--secrets-encryption` flag |
| Audit logging | Enable in Phase 1 K3s install | `--kube-apiserver-arg` flags |
| Pod Security Admission | Configure in Phase 3 | Cilium + PSA setup |
| RBAC restrictions | Configure per-namespace | Phase 3 |

Document any items that are deferred to later phases or accepted as exceptions.

---

## Step 13: Repeat on helix-worker-1

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

Run Parts 1-6 identically on the worker node. Part 7 (kube-bench) only needs to run once from the CP node.

---

## Final Verification Script

Run on BOTH nodes:

```bash
echo "==========================================="
echo "  CIS Level 1 Benchmark Verification"
echo "==========================================="

echo ""
echo "--- 1. Filesystem: /tmp mount options ---"
findmnt /tmp -o OPTIONS 2>/dev/null || echo "/tmp: NOT a separate mount"

echo ""
echo "--- 2. File permissions ---"
stat -c '%a %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/ssh/sshd_config

echo ""
echo "--- 3. Disabled services ---"
for svc in cups avahi-daemon bluetooth ModemManager rpcbind nfs-server; do
    status=$(systemctl is-enabled $svc.service 2>/dev/null || echo 'not-found')
    echo "  $svc: $status"
done

echo ""
echo "--- 4. Network hardening (sysctl) ---"
sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | xargs -I{} echo "  IPv6 disabled: {}"
sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null | xargs -I{} echo "  ICMP redirects: {} (should be 0)"
sysctl -n net.ipv4.tcp_syncookies 2>/dev/null | xargs -I{} echo "  SYN cookies: {} (should be 1)"
sysctl -n net.ipv4.ip_forward 2>/dev/null | xargs -I{} echo "  IP forwarding: {} (should be 1)"

echo ""
echo "--- 5. auditd ---"
systemctl is-active auditd | xargs -I{} echo "  auditd status: {}"
auditctl -l 2>/dev/null | wc -l | xargs -I{} echo "  Audit rules loaded: {}"

echo ""
echo "--- 6. World-writable files (system dirs) ---"
count=$(find / -path /tmp -prune -o -path /var/tmp -prune -o -path /proc -prune \
  -o -path /sys -prune -o -path /dev -prune -o -path /run -prune \
  -o -type f -perm -0002 -print 2>/dev/null | wc -l)
echo "  World-writable files found: $count"

echo ""
echo "==========================================="
echo "  Verification complete"
echo "==========================================="
```

---

## Rollback Plan

### Filesystem mounts

```bash
# Remove added lines from /etc/fstab
# Then: mount -a (or reboot)
```

### Sysctl

```bash
rm /etc/sysctl.d/90-cis-hardening.conf
sysctl --system
```

### auditd rules

```bash
rm /etc/audit/rules.d/50-cis-hardening.rules
augenrules --load
# Or:
auditctl -D  # delete all rules (temporary, until reboot)
```

### Disabled services

```bash
# Unmask and re-enable if needed
systemctl unmask <service>
systemctl enable --now <service>
```

## Execution Log

### Issue 1: augenrules Performance Warnings During Load
- **What happened**: Loading audit rules from `/etc/audit/rules.d/50-cis-hardening.rules` generated warnings: "Old style watch rules are slower."
- **Root cause**: Audit rules use file system watches (`-w` directives), which are monitored via inotify. Modern auditd can use syscall-based rules for better performance, but both approaches work.
- **Fix applied**: No action taken. Warnings are informational. Watch rules were successfully loaded (25 rules active on both nodes).
- **Lesson for readers**: File watch rules (`-w`) are simpler and sufficient for most use cases, but they do add more inotify overhead than syscall-based rules. For this phase of hardening, watch rules are appropriate. Production systems with high logging load may benefit from syscall-based audit rules later.

### Issue 2: No Unnecessary Services Found Enabled
- **What happened**: Loop through common unnecessary services (cups, avahi, bluetooth, ModemManager, rpcbind, nfs-server) found all were already disabled or not installed.
- **Root cause**: AlmaLinux 9 minimal image ships with minimal services by default. Hetzner provisioning doesn't enable unnecessary daemons.
- **Fix applied**: No action needed. Systems were already in hardened state for this aspect.
- **Lesson for readers**: Always run the service audit step anyway — it's a good hygiene check and documents the baseline. Some provisioning configurations may leave unnecessary services enabled.

### Issue 3: IPv6 Disabled May Conflict with DNS Configuration
- **What happened**: CIS benchmark recommends disabling IPv6 globally. However, Step 04-dns-fix configured IPv4 nameservers because Hetzner's default DNS is IPv6-only.
- **Root cause**: CIS assumes pure IPv6-disable safety. Hetzner's infrastructure has IPv6 DNS, which CoreDNS will try to use if available. DNS fix was needed before IPv6 disable.
- **Fix applied**: Applied DNS fix (Phase 0, Step 4) before this step. IPv6 is now disabled with IPv4 nameservers confirmed working.
- **Lesson for readers**: On cloud providers with IPv6-only defaults (like Hetzner), configure IPv4 DNS BEFORE disabling IPv6 globally. Otherwise, future DNS resolution attempts will fail silently. The order matters.

## Deviations from Guide
- **kube-bench Deferred**: Part 7 (kube-bench) intentionally deferred to Phase 1 after K3s reinstall, as per guide instruction. No deviation here.
- **No service disabling needed**: Guide shows example disabling commands; all were already disabled. This is expected on modern minimal images.
- **IPv6 Disable Order**: Guide doesn't specify when to apply IPv6-disable relative to DNS fix. Best practice discovered: apply DNS fix first (earlier phase), then IPv6 disable.
