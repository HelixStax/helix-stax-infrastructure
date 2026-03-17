---
tags: [infrastructure, hardening, fail2ban, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 15-20 minutes
applies-to: [heart, helix-worker-1]
---

# 07 — fail2ban Setup

> Install and configure fail2ban to automatically ban IPs that brute-force SSH. Integrates with firewalld for banning via ipset.
>
> **Run on**: heart (178.156.233.12) AND helix-worker-1 (138.201.131.157)
> **Estimated time**: 15-20 minutes (both nodes)

---

## Prerequisites

- [[02-ssh-hardening]] completed (SSH on port 2222)
- [[06-firewall-hardening]] completed (firewalld with k8s-hardened zone)
- SSH access to both nodes on port 2222

---

## Tutorial Notes

> **Content capture**: Screenshot `fail2ban-client status sshd` showing active jail. Demonstrate a ban by intentionally failing SSH from a throwaway IP (or a VPN). Show the unban command for recovery.

---

## Step 1: Install fail2ban

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

```bash
# Install EPEL repository (fail2ban lives here on RHEL-based distros)
dnf install -y epel-release

# Install fail2ban
dnf install -y fail2ban fail2ban-firewalld
```

**Verify installation**:

```bash
fail2ban-client --version
```

---

## Step 2: Create jail.local Configuration

> [!NOTE]
> Never edit `/etc/fail2ban/jail.conf` directly — it gets overwritten on updates. Use `/etc/fail2ban/jail.local` for overrides.

```bash
cat > /etc/fail2ban/jail.local << 'EOF'
# Helix Stax fail2ban configuration
# Created: Phase 0 hardening

[DEFAULT]
# Ban for 1 hour
bantime = 3600

# Detection window: 10 minutes
findtime = 600

# Ban after 3 failed attempts
maxretry = 3

# Use firewalld with ipset for efficient banning
banaction = firewallcmd-ipset

# Send ban notifications to journal (no email setup yet)
action = %(action_)s

# Ignore localhost
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
# Match our hardened SSH port
port = 2222
# Log file for sshd on AlmaLinux 9 (uses systemd journal)
backend = systemd
# Override: slightly stricter than default
maxretry = 3
bantime = 3600
findtime = 600
EOF
```

---

## Step 3: Enable and Start fail2ban

```bash
# Enable to start on boot + start now
systemctl enable --now fail2ban
```

**Verify it started**:

```bash
systemctl status fail2ban
```

You should see `Active: active (running)`.

---

## Step 4: Verify the SSH Jail

```bash
# Check overall status
fail2ban-client status

# Check SSH jail specifically
fail2ban-client status sshd
```

Expected output:

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

Key things to verify:
- `Journal matches` includes `sshd.service` (it is reading the right logs)
- The jail is listed as active in `fail2ban-client status`

---

## Step 5: Test the Ban Mechanism

> [!WARNING]
> Do NOT test from your admin IP unless you are prepared to unban yourself. Use a VPN or different IP.

**Option A: Safe test (check the regex works)**:

```bash
# Test that fail2ban's SSH regex matches your log format
fail2ban-regex systemd-journal "sshd[]: Failed password" --print-all-matched
```

**Option B: Live test (from a different IP)**:

```bash
# From a different machine/VPN, attempt SSH with wrong key 4 times
ssh -p 2222 root@178.156.233.12  # will fail without correct key
# Repeat 3+ times
```

Then check on the server:

```bash
# Should show the banned IP
fail2ban-client status sshd

# Check firewalld ipset for banned IPs
firewall-cmd --direct --get-all-rules
ipset list 2>/dev/null || echo "ipset not populated yet (no bans triggered)"
```

---

## Step 6: Useful fail2ban Commands

```bash
# Check jail status
fail2ban-client status sshd

# Manually unban an IP (if you ban yourself)
fail2ban-client set sshd unbanip <IP_ADDRESS>

# Check all bans across all jails
fail2ban-client banned

# Check fail2ban logs
journalctl -u fail2ban -f

# Reload config after changes
fail2ban-client reload
```

---

## Step 7: Repeat on helix-worker-1

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

Run Steps 1-5 identically on the worker node. The configuration is the same.

---

## Final Verification Checklist

Run on BOTH nodes:

```bash
echo "=== fail2ban Verification ==="

echo "--- Service status ---"
systemctl is-active fail2ban
systemctl is-enabled fail2ban

echo "--- Active jails ---"
fail2ban-client status

echo "--- SSH jail detail ---"
fail2ban-client status sshd

echo "--- fail2ban is using firewalld ---"
grep banaction /etc/fail2ban/jail.local

echo "--- Config validates ---"
fail2ban-client -t && echo "Config: OK" || echo "Config: ERROR"
```

---

## Rollback Plan

```bash
# Stop and disable fail2ban
systemctl stop fail2ban
systemctl disable fail2ban

# Remove the config
rm -f /etc/fail2ban/jail.local

# Unban all IPs (if any were banned)
fail2ban-client unban --all 2>/dev/null

# Optional: uninstall
dnf remove -y fail2ban fail2ban-firewalld
```

---

## Emergency: Unbanning Yourself

If you accidentally get banned from your admin IP:

1. **Hetzner Cloud Console**: Use the web VNC to access the node
2. Run: `fail2ban-client set sshd unbanip <YOUR_IP>`
3. Or: `systemctl stop fail2ban` (nuclear option — stops all banning)

To prevent accidental self-ban, add your admin IP to the ignore list:

```bash
# Edit jail.local and add your IP to ignoreip
sed -i "s|ignoreip = 127.0.0.1/8 ::1|ignoreip = 127.0.0.1/8 ::1 <ADMIN_IP>|" /etc/fail2ban/jail.local
fail2ban-client reload
```

> [!NOTE]
> Adding your admin IP to `ignoreip` means fail2ban will never ban it, even if someone brute-forces from your IP. Only do this if your admin IP is static and trusted.

## Execution Log

### Issue 1: Race Condition Between Service Enable and Status Query (CP)
- **What happened**: After running `systemctl enable --now fail2ban`, immediately querying `fail2ban-client status` returned a socket connection error, implying the service failed to start.
- **Root cause**: systemd enables the service and starts it asynchronously. The fail2ban socket wasn't ready immediately for client connections.
- **Fix applied**: Waited ~2 seconds before running `fail2ban-client status`. Service was actually running; only the client connection timing was off.
- **Lesson for readers**: After `systemctl enable --now`, always verify service status with a small delay or use `systemctl status` first (which is more forgiving of timing). Don't assume service startup is instantaneous. If you see socket errors, wait and retry before assuming failure.

### Issue 2: Existing Brute-Force Traffic on Worker
- **What happened**: Worker node sshd jail showed 3 failed login attempts already recorded before configuration completed, indicating existing brute-force traffic hitting port 2222.
- **Root cause**: Worker's public SSH port had been receiving brute-force attempts before fail2ban was installed and configured.
- **Fix applied**: No action needed. fail2ban jail immediately started monitoring and would ban the source IPs after 3 more attempts within the findtime window.
- **Lesson for readers**: On public-facing nodes, expect brute-force traffic on SSH. fail2ban will start protecting once installed. If you're concerned about existing compromise, check auth logs for successful logins: `grep "Accepted\|Failed password" /var/log/auth.log` after fail2ban is running.

## Deviations from Guide
- **No deviations encountered**: Configuration matched guide exactly. Both nodes use port 2222, systemd backend, firewallcmd-ipset integration as specified.
- **Implicit: Dynamic ISP IP**: Unlike earlier steps, no special handling needed here. fail2ban works regardless of admin IP changes; it bans based on actual failed attempts captured in logs.
