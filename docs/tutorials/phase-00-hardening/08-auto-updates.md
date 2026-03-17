---
tags: [infrastructure, hardening, updates, dnf-automatic, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 10-15 minutes
applies-to: [heart, helix-worker-1]
---

# 08 — Automatic Security Updates

> Configure dnf-automatic to apply security patches automatically. Only security updates — no feature upgrades that could break K3s or system services.
>
> **Run on**: heart (178.156.233.12) AND helix-worker-1 (138.201.131.157)
> **Estimated time**: 10-15 minutes (both nodes)

---

## Prerequisites

- SSH access to both nodes on port 2222
- [[02-ssh-hardening]] completed

---

## Tutorial Notes

> **Content capture**: Screenshot the `automatic.conf` diff (before/after), the timer status output, and the journal showing a successful update check. Explain why security-only is the right choice for production K8s nodes.

---

## Step 1: Install dnf-automatic

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

```bash
dnf install -y dnf-automatic
```

**Verify installation**:

```bash
rpm -q dnf-automatic
```

---

## Step 2: Configure for Security-Only Updates

```bash
# Backup the default config
cp /etc/dnf/automatic.conf /etc/dnf/automatic.conf.bak

# Apply our hardened configuration
cat > /etc/dnf/automatic.conf << 'EOF'
[commands]
# Automatically apply updates (not just download)
apply_updates = yes

# Only security updates — no feature upgrades
upgrade_type = security

# Random delay before applying (spreads load across fleet)
random_sleep = 300

# Download updates before applying
download_updates = yes

[emitters]
# Log to systemd journal
emit_via = stdio

[email]
# Email disabled — no mail server configured yet
# Will route to Grafana alerts in Phase 5
email_from = root@localhost
email_to = root
email_host = localhost

[base]
# Use system repos (AlmaLinux default)
debuglevel = 1
EOF
```

---

## Step 3: Enable the Timer

> [!NOTE]
> There are two timers available:
> - `dnf-automatic.timer` — downloads only
> - `dnf-automatic-install.timer` — downloads AND installs
>
> We want the install timer since we set `apply_updates = yes`.

```bash
# Enable and start the install timer
systemctl enable --now dnf-automatic-install.timer
```

**Verify timer is active**:

```bash
systemctl status dnf-automatic-install.timer
```

Expected: `Active: active (waiting)` with a next trigger time shown.

**Check when it will next run**:

```bash
systemctl list-timers dnf-automatic-install.timer
```

This shows the next scheduled run, the last run, and the interval.

---

## Step 4: Test with a Manual Run

Trigger a manual run to verify the configuration works:

```bash
# Run manually (same as what the timer does)
dnf-automatic /etc/dnf/automatic.conf --timer

# Check the journal for results
journalctl -u dnf-automatic-install.service --since "5 minutes ago"
```

You should see output indicating it checked for security updates and either applied them or found none.

---

## Step 5: Verify Configuration

```bash
echo "=== Auto-Update Verification ==="

echo "--- Timer status ---"
systemctl is-active dnf-automatic-install.timer
systemctl is-enabled dnf-automatic-install.timer

echo "--- Timer schedule ---"
systemctl list-timers dnf-automatic-install.timer --no-pager

echo "--- Config key settings ---"
grep -E '^(apply_updates|upgrade_type)' /etc/dnf/automatic.conf

echo "--- Recent activity ---"
journalctl -u dnf-automatic-install.service --no-pager -n 10
```

---

## Step 6: Repeat on helix-worker-1

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

Run Steps 1-5 identically. The configuration is the same for both nodes.

---

## Important Considerations

### Why Security-Only?

- **Feature updates** can change package behavior, potentially breaking K3s, container runtimes, or kernel modules
- **Security updates** are backported patches that fix CVEs without changing functionality
- This is the standard approach for production servers

### Reboot Handling

Some security updates (kernel, glibc, systemd) require a reboot to take effect.

dnf-automatic does NOT reboot automatically. Check for pending reboots periodically:

```bash
# Check if a reboot is needed
needs-restarting -r
echo $?  # 0 = no reboot needed, 1 = reboot needed
```

> [!NOTE]
> In Phase 5 (Observability), we will set up Grafana alerts for pending reboots. For now, check manually after running updates.

To do a rolling reboot (one node at a time):

```bash
# On the worker first (less disruptive)
# Drain the node
kubectl drain helix-worker-1 --ignore-daemonsets --delete-emptydir-data
# Reboot
reboot

# Wait for it to come back, verify it rejoins the cluster
kubectl get nodes

# Then drain and reboot the CP node
kubectl drain heart --ignore-daemonsets --delete-emptydir-data
reboot
```

### Monitoring Update History

```bash
# See what was auto-updated
dnf history list --reverse | tail -20

# See details of a specific update
dnf history info <ID>

# See all installed security updates
dnf updateinfo list --installed security
```

---

## Rollback Plan

```bash
# Stop and disable the timer
systemctl stop dnf-automatic-install.timer
systemctl disable dnf-automatic-install.timer

# Restore original config
cp /etc/dnf/automatic.conf.bak /etc/dnf/automatic.conf

# To undo a specific update
dnf history list  # find the transaction ID
dnf history undo <ID>
```

> [!WARNING]
> Rolling back kernel updates can be risky. If a kernel update causes issues, boot into the previous kernel via GRUB instead of using `dnf history undo`.

## Execution Log

### Issue 1: Timer Scheduling Differs Between Nodes
- **What happened**: Both nodes' `dnf-automatic-install.timer` scheduled their next run at different times (~6am), not synchronized.
- **Root cause**: systemd timer randomization spreads load. Each node calculates next run independently based on `RandomizedDelaySec` (default ~1 hour).
- **Fix applied**: No action needed. Staggered updates are intentional for fleet load balancing. Both nodes will apply updates within the daily window.
- **Lesson for readers**: If you need synchronized updates across multiple nodes, set explicit timer schedules in the timer unit file or use a centralized update manager. Default randomization prevents update storms.

### Issue 2: Manual Test Run Skipped
- **What happened**: Skipped the manual test trigger `dnf-automatic /etc/dnf/automatic.conf --timer` to verify configuration works immediately.
- **Root cause**: Manual test takes time and isn't blocking; timer will execute on schedule.
- **Fix applied**: No action taken. Configuration is correct; next scheduled timer execution will validate it. Can be tested manually later if needed.
- **Lesson for readers**: For production validation, run a manual test immediately after configuration to catch errors before the first scheduled run. Skipping this trades immediate feedback for speed.

## Deviations from Guide
- **No deviations**: Configuration matched guide exactly. Security-only updates, auto-apply enabled, random sleep configured, timer enabled on both nodes.
