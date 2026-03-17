---
tags: [infrastructure, hardening, ssh, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 30-45 minutes
applies-to: [heart, helix-worker-1]
---

# 02 — SSH Hardening

> Harden SSH on both cluster nodes. Key-only auth, non-standard port, session limits, legal banner.
>
> **Run on**: heart (178.156.233.12) AND helix-worker-1 (138.201.131.157)
> **Estimated time**: 30-45 minutes (both nodes)

---

## Prerequisites

- SSH access to both nodes as root (current: `ssh -i ~/.ssh/helixstax_key root@<IP>`)
- Your admin workstation's public IP (for firewall rule in [[06-firewall-hardening]])
- A second terminal window available (for testing before closing your session)

---

## Tutorial Notes

> **Content capture**: Screenshot the before/after of `sshd_config`, the banner file, and the `ss` output showing port 2222. Record the "test from new terminal" step — viewers love seeing the safety net in action.

---

## Step 1: Backup Current SSH Config

SSH into the node and create a timestamped backup.

```bash
# Connect to the node
ssh -i ~/.ssh/helixstax_key root@178.156.233.12

# Backup current config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)
```

**Verify backup exists**:

```bash
ls -la /etc/ssh/sshd_config.bak.*
```

---

## Step 2: Create SSH Banner

Create a legal warning banner that displays before authentication.

```bash
cat > /etc/ssh/banner.txt << 'EOF'
========================================================================
                    AUTHORIZED ACCESS ONLY

This system is the property of Helix Stax LLC. Unauthorized access is
prohibited and will be prosecuted to the fullest extent of the law.
All connections are monitored and logged.

By proceeding, you consent to monitoring and agree that you are an
authorized user of this system.
========================================================================
EOF
```

**Verify**:

```bash
cat /etc/ssh/banner.txt
```

---

## Step 3: Harden sshd_config

> [!WARNING]
> **DO NOT restart sshd yet.** We need to update the firewall FIRST (Step 4) to allow port 2222, or you will lock yourself out.

Edit `/etc/ssh/sshd_config`. Find and change (or add) each directive:

```bash
# Use sed to apply all changes at once
# Back up one more time just in case
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.pre-hardening

# Change SSH port to 2222
sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config

# Disable root password login (key-only)
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Disable password authentication entirely
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Limit auth attempts
sed -i 's/^#\?MaxAuthTries .*/MaxAuthTries 3/' /etc/ssh/sshd_config

# Session keepalive (drop idle connections after 10 min)
sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 300/' /etc/ssh/sshd_config
sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 2/' /etc/ssh/sshd_config

# Disable X11 forwarding (no GUI needed on servers)
sed -i 's/^#\?X11Forwarding .*/X11Forwarding no/' /etc/ssh/sshd_config

# Disable TCP forwarding (unless you need SSH tunneling)
sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding no/' /etc/ssh/sshd_config

# Enable the legal banner
sed -i 's|^#\?Banner .*|Banner /etc/ssh/banner.txt|' /etc/ssh/sshd_config
```

**Verify the changes** — review the full config and confirm each setting:

```bash
grep -E '^(Port|PermitRootLogin|PasswordAuthentication|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax|X11Forwarding|AllowTcpForwarding|Banner)' /etc/ssh/sshd_config
```

Expected output:

```
Port 2222
PermitRootLogin prohibit-password
PasswordAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
Banner /etc/ssh/banner.txt
```

> [!NOTE]
> If any line is missing from the output, append it manually:
> ```bash
> echo 'Port 2222' >> /etc/ssh/sshd_config  # example — only add missing lines
> ```

**Validate config syntax** (catches typos before restart):

```bash
sshd -t
```

If this prints nothing, the config is valid. If it prints errors, fix them before continuing.

---

## Step 4: Update SELinux for New SSH Port

AlmaLinux 9 uses SELinux in enforcing mode by default. SSH on a non-standard port will be blocked unless we tell SELinux about it.

```bash
# Check if SELinux is enforcing
getenforce

# Install semanage if not present
dnf install -y policycoreutils-python-utils

# Allow SSH on port 2222
semanage port -a -t ssh_port_t -p tcp 2222

# Verify it was added
semanage port -l | grep ssh_port_t
```

Expected output should include `2222` in the list:

```
ssh_port_t                     tcp      2222, 22
```

---

## Step 5: Update Firewall for New Port

> [!WARNING]
> **CRITICAL**: Open port 2222 in firewalld BEFORE restarting sshd. If you restart sshd first and port 2222 is blocked, you are locked out.

```bash
# Add new SSH port to firewall
firewall-cmd --permanent --add-port=2222/tcp

# Reload firewall to apply
firewall-cmd --reload

# Verify port 2222 is open
firewall-cmd --list-ports
```

You should see `2222/tcp` in the output.

> [!NOTE]
> Do NOT remove port 22 yet. We will remove it after confirming port 2222 works.

---

## Step 6: Restart sshd

> [!WARNING]
> **Keep your current SSH session open.** Do NOT close it until you have verified connectivity on port 2222 from a NEW terminal.

```bash
# Restart SSH daemon
systemctl restart sshd
```

**Verify sshd is listening on port 2222**:

```bash
ss -tlnp | grep 2222
```

Expected output:

```
LISTEN  0  128  0.0.0.0:2222  0.0.0.0:*  users:(("sshd",pid=...,fd=...))
LISTEN  0  128  [::]:2222     [::]:*     users:(("sshd",pid=...,fd=...))
```

---

## Step 7: Test from a NEW Terminal

> [!WARNING]
> **Do NOT close your original session yet.** Open a completely new terminal window on your workstation.

```bash
# Test connection on new port
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

You should see:
1. The legal banner text
2. A successful login

**If it works**: You are safe. Continue to Step 8.

**If it fails**: Your original session is still open. Debug from there:

```bash
# Check sshd status
systemctl status sshd

# Check for SELinux denials
ausearch -m avc -ts recent

# Check firewall
firewall-cmd --list-all

# Nuclear rollback if needed (from original session)
cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config
systemctl restart sshd
```

---

## Step 8: Remove Old Port 22

Once you have confirmed port 2222 works:

```bash
# Remove default SSH service (port 22) from firewall
firewall-cmd --permanent --remove-service=ssh

# Reload
firewall-cmd --reload

# Verify port 22 is no longer open
firewall-cmd --list-services
firewall-cmd --list-ports
```

Port 22 should no longer appear in services, and `2222/tcp` should be in ports.

---

## Step 9: Repeat on helix-worker-1

Run Steps 1-8 on the worker node:

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
```

Then repeat every step. After completion, connect to the worker on the new port:

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

---

## Final Verification Checklist

Run on BOTH nodes after completing all steps:

```bash
echo "=== SSH Hardening Verification ==="

echo "--- Port ---"
ss -tlnp | grep -E '(2222|:22\b)'

echo "--- sshd_config key settings ---"
grep -E '^(Port|PermitRootLogin|PasswordAuthentication|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax|X11Forwarding|AllowTcpForwarding|Banner)' /etc/ssh/sshd_config

echo "--- SELinux SSH ports ---"
semanage port -l | grep ssh_port_t

echo "--- Firewall (should NOT show port 22/ssh) ---"
firewall-cmd --list-all

echo "--- Banner file ---"
test -f /etc/ssh/banner.txt && echo "Banner: OK" || echo "Banner: MISSING"

echo "--- sshd running ---"
systemctl is-active sshd
```

---

## Rollback Plan

If something goes wrong and you need to revert:

```bash
# Restore original sshd_config
cp /etc/ssh/sshd_config.bak.* /etc/ssh/sshd_config

# Re-add default SSH service to firewall
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --remove-port=2222/tcp
firewall-cmd --reload

# Restart sshd
systemctl restart sshd

# Remove SELinux port (optional cleanup)
semanage port -d -t ssh_port_t -p tcp 2222
```

If you are completely locked out and cannot SSH at all:
1. Use Hetzner Cloud Console (web-based VNC) to access the node
2. Restore from backup and restart sshd from the console

---

## Connection Reference (Post-Hardening)

After this guide, SSH commands change to:

```bash
# heart (control plane)
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12

# helix-worker-1 (worker)
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

Update any SSH config files (`~/.ssh/config`) or scripts that reference these nodes:

```
Host heart
    HostName 178.156.233.12
    User root
    Port 2222
    IdentityFile ~/.ssh/helixstax_key

Host helix-worker-1
    HostName 138.201.131.157
    User root
    Port 2222
    IdentityFile ~/.ssh/helixstax_key
```

## Execution Log

### Issue 0: SSH Lockout During Initial Attempt (Pre-Kit)
- **What happened**: Orchestrator changed sshd_config to Port 2222 without first adding port 2222 to the Hetzner Cloud Firewall. Also didn't verify which SSH key was in authorized_keys. Result: locked out of CP node entirely.
- **Root cause**: Hetzner Cloud Firewall only allowed port 22. New sshd listened on 2222 only. No fallback port configured.
- **Fix applied**: Used Hetzner rescue mode (hcloud server enable-rescue), mounted disk, restored sshd_config from backup, rebooted to normal.
- **Lesson for readers**: ALWAYS add the new SSH port to your cloud provider's firewall BEFORE changing sshd_config. Keep both ports open until the new one is confirmed working. Never change SSH config without a backup access method (Hetzner Console, rescue mode).

### Issue 1: Port 2222 Already Configured in Hetzner Cloud Firewall (CP)
- **What happened**: Port 2222 was already in Hetzner Cloud Firewall and SELinux from the prior failed attempt.
- **Root cause**: Previous orchestrator attempt had set up partial configuration before lockout.
- **Fix applied**: Verified port 2222 was present in both Hetzner Cloud FW and SELinux, then proceeded with sshd_config changes.
- **Lesson for readers**: If you have a failed attempt, check cloud provider firewall rules and SELinux policy before starting fresh.

### Issue 2: firewalld and policycoreutils Not Installed (Worker)
- **What happened**: Worker node was missing firewalld and policycoreutils-python-utils, which are required for firewall configuration and SELinux port management.
- **Root cause**: Different provisioning configuration between cloud control plane and dedicated server worker.
- **Fix applied**: Installed both packages via dnf before proceeding with SELinux and firewall configuration.
- **Lesson for readers**: Verify prerequisite packages exist on all node types before starting hardening. Dedicated servers often ship with different defaults than cloud images.

## Deviations from Guide
- Used dual-port strategy: kept both Port 22 and Port 2222 in sshd_config during testing phase, then removed port 22 after confirming port 2222 worked. Guide only mentioned port 2222 removal order.
- CP node had firewalld already enabled from prior attempt; worker required fresh enablement.
- Local SSH config updated to use Port 2222 for both nodes (convenience, not strictly required by tutorial).
