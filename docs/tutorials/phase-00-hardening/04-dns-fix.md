---
tags: [infrastructure, phase-0, dns, coredns, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
phase: "0"
step: "04"
estimated-time: "5-10 minutes"
nodes: [heart, helix-worker-1]
author: Kit (DevOps Engineer)
---

# Step 04: DNS Configuration Fix

> **Goal**: Fix DNS resolution on both nodes to include IPv4 nameservers. Hetzner's default AlmaLinux image ships with IPv6-only DNS in `/etc/resolv.conf`, which causes CoreDNS to fail when K3s is installed. This is a known issue (see [[lessons_infrastructure]]).

## Prerequisites

- [ ] SSH access to both nodes confirmed
- [ ] K3s wiped (no active cluster -- we're fixing the host DNS, not CoreDNS)

> **Why this matters**: When K3s starts, CoreDNS reads the host's `/etc/resolv.conf` as its upstream DNS. If only IPv6 nameservers are present and IPv6 resolution is flaky (common on Hetzner), all in-cluster DNS fails. Pods can't resolve external domains, Helm charts can't download, and Devtron gets stuck in OutOfSync.

---

## 1. Fix DNS on Heart (Control Plane)

```bash
ssh -i ~/.ssh/helixstax_key root@178.156.233.12
```

### 1.1 Check Current DNS Configuration

```bash
cat /etc/resolv.conf
```

Typical Hetzner default (problematic):
```
# This file is managed by systemd-resolved or NetworkManager
nameserver 2a01:4ff:ff00::add:1
nameserver 2a01:4ff:ff00::add:2
```

If you already see `185.12.64.1` and `8.8.8.8`, skip to verification (step 1.5).

### 1.2 Check Who Manages resolv.conf

```bash
ls -la /etc/resolv.conf
systemctl is-active systemd-resolved
systemctl is-active NetworkManager
```

On Hetzner AlmaLinux 9, NetworkManager is typically the manager. `resolv.conf` may be a symlink or a regular file.

### 1.3 Configure NetworkManager for IPv4 DNS

The most reliable way to persist DNS on AlmaLinux 9 with NetworkManager:

```bash
# Find the active connection name
nmcli connection show --active
```

Note the connection name (usually `eth0`, `ens3`, or `System eth0`). Use it below:

```bash
# Replace CONNECTION_NAME with the actual name from above
CONNECTION_NAME=$(nmcli -t -f NAME connection show --active | head -1)

# Set IPv4 DNS servers
nmcli connection modify "$CONNECTION_NAME" ipv4.dns "185.12.64.1 185.12.64.2 8.8.8.8"

# Prevent DHCP from overwriting our DNS settings
nmcli connection modify "$CONNECTION_NAME" ipv4.ignore-auto-dns yes

# Apply changes
nmcli connection up "$CONNECTION_NAME"
```

### 1.4 Verify resolv.conf Updated

```bash
cat /etc/resolv.conf
```

Expected: Should now contain at least:
```
nameserver 185.12.64.1
nameserver 185.12.64.2
nameserver 8.8.8.8
```

> **Note**: IPv6 nameservers may still be present alongside IPv4 -- that's fine. The key is that IPv4 nameservers are present as fallback.

### 1.5 Test DNS Resolution

```bash
# Test with dig (install if not present: dnf install -y bind-utils)
dig google.com +short
# Expected: One or more IP addresses

dig helixstax.com +short
# Expected: IP address(es) for the domain

# Test reverse lookup
nslookup google.com
# Expected: Non-authoritative answer with IP addresses

# Test DNS over specific nameserver
dig @185.12.64.1 google.com +short
dig @8.8.8.8 google.com +short
```

All should return valid IP addresses. If any fail, double-check the nameserver IPs.

```bash
echo "=== DNS fix complete on heart ==="
```

---

## 2. Fix DNS on Helix-Worker-1

```bash
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
```

### 2.1 Check and Fix (Same Steps)

```bash
cat /etc/resolv.conf

# Find active connection
CONNECTION_NAME=$(nmcli -t -f NAME connection show --active | head -1)

# Set IPv4 DNS
nmcli connection modify "$CONNECTION_NAME" ipv4.dns "185.12.64.1 185.12.64.2 8.8.8.8"
nmcli connection modify "$CONNECTION_NAME" ipv4.ignore-auto-dns yes
nmcli connection up "$CONNECTION_NAME"
```

### 2.2 Verify

```bash
cat /etc/resolv.conf
dig google.com +short
dig helixstax.com +short
echo "=== DNS fix complete on helix-worker-1 ==="
```

---

## 3. Persist via Cloud-Init (For Future Reprovisioning)

If you ever rebuild these servers from the Hetzner dashboard, the DNS fix would be lost. Adding it to cloud-init user data ensures it's applied automatically on provisioning.

### 3.1 Create/Update Cloud-Init Config

On each node, check if cloud-init is installed:

```bash
which cloud-init && cloud-init status
```

If cloud-init is present, add DNS configuration:

```bash
mkdir -p /etc/cloud/cloud.cfg.d/

cat > /etc/cloud/cloud.cfg.d/99-dns-fix.cfg << 'EOF'
# Fix Hetzner IPv6-only DNS for Kubernetes CoreDNS compatibility
manage_resolv_conf: true
resolv_conf:
  nameservers:
    - 185.12.64.1
    - 185.12.64.2
    - 8.8.8.8
  searchdomains: []
  options:
    rotate: true
    timeout: 2
EOF
```

> **Note**: The `rotate` option distributes queries across nameservers (load balancing). The `timeout: 2` reduces wait time if a nameserver is slow.

> **Important**: Cloud-init runs on first boot or reprovisioning. It won't override the NetworkManager settings we already applied. Both methods coexist safely -- NetworkManager handles the running system, cloud-init handles reprovisioning.

---

## 4. Post-K3s DNS Verification (Run After K3s Reinstall)

These commands won't work until K3s is reinstalled in a later phase. Save them for then.

```bash
# Verify CoreDNS pods are running (not CrashLoopBackOff)
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Test in-cluster DNS resolution
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# Test external resolution from inside cluster
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup google.com
```

Expected: All resolve successfully. If CoreDNS is in CrashLoopBackOff, check `kubectl -n kube-system logs -l k8s-app=kube-dns` -- it's almost always a DNS upstream issue.

---

## Rollback Plan

### Revert NetworkManager DNS Changes

```bash
CONNECTION_NAME=$(nmcli -t -f NAME connection show --active | head -1)

# Remove custom DNS
nmcli connection modify "$CONNECTION_NAME" ipv4.dns ""

# Re-enable auto DNS from DHCP
nmcli connection modify "$CONNECTION_NAME" ipv4.ignore-auto-dns no

# Apply
nmcli connection up "$CONNECTION_NAME"
```

### Remove Cloud-Init Config

```bash
rm /etc/cloud/cloud.cfg.d/99-dns-fix.cfg
```

---

## Summary

| Action | Node | Status |
|--------|------|--------|
| IPv4 DNS servers configured | heart | [ ] |
| `ipv4.ignore-auto-dns` set | heart | [ ] |
| DNS resolution tested | heart | [ ] |
| IPv4 DNS servers configured | helix-worker-1 | [ ] |
| `ipv4.ignore-auto-dns` set | helix-worker-1 | [ ] |
| DNS resolution tested | helix-worker-1 | [ ] |
| Cloud-init DNS config created | both nodes | [ ] |

**Next step**: [[05-load-balancer-delete]] (if not done in step 01) or proceed to Phase 1

## Execution Log

### Issue 1: NetworkManager DNS Configuration Not Persisting (CP)
- **What happened**: Ran `nmcli connection modify` commands to set IPv4 DNS, but `nmcli connection up` didn't immediately update `/etc/resolv.conf` to reflect the changes. Cloud-init's IPv6-only config remained in place.
- **Root cause**: Cloud-init manages `/etc/resolv.conf` on Hetzner cloud images. NetworkManager changes require direct file write on top of cloud-init management, and config daemon restart timing issues caused delays.
- **Fix applied**: Directly edited `/etc/resolv.conf` to put IPv4 nameservers first, created `/etc/NetworkManager/conf.d/90-dns.conf` to ensure NetworkManager takes precedence over cloud-init going forward, and created cloud-init override in `/etc/cloud/cloud.cfg.d/99-dns-fix.cfg` for future reprovisions.
- **Lesson for readers**: On Hetzner cloud images with cloud-init enabled, DNS configuration layers can conflict. Don't rely on nmcli alone — verify `/etc/resolv.conf` directly. Create explicit NetworkManager config file and cloud-init override for multi-layer DNS management.

### Issue 2: bind-utils Package Not Pre-installed
- **What happened**: `dig` command was not available on either node, required for DNS verification step.
- **Root cause**: AlmaLinux 9 minimal images don't include bind-utils by default.
- **Fix applied**: Installed `bind-utils` on both nodes via dnf before running DNS tests.
- **Lesson for readers**: For troubleshooting DNS issues in tutorials, ensure `bind-utils` (dig, nslookup) is installed first. Add this as a prerequisite or early verification step.

### Issue 3: Cloud-Init vs NetworkManager Management Conflict (CP)
- **What happened**: CP node uses cloud-init to manage network config, but we're also using NetworkManager. Both wanted to manage DNS settings, creating potential for future conflicts.
- **Root cause**: Hetzner cloud images initialize both cloud-init and NetworkManager. On first boot, cloud-init writes config and may persist. NetworkManager handles runtime network changes.
- **Fix applied**: Created explicit NetworkManager config file (`/etc/NetworkManager/conf.d/90-dns.conf`) to disable auto-configuration and ensure NM controls DNS. Also created cloud-init override for reprovision scenarios.
- **Lesson for readers**: On servers with both cloud-init and NetworkManager, explicitly configure DNS management priority. Cloud-init runs once at boot; NetworkManager runs continuously. For persistent DNS config, configure both layers.

## Deviations from Guide
- **CP DNS Configuration**: Guide suggested using nmcli alone, but Hetzner cloud-init interference required direct /etc/resolv.conf editing and explicit NetworkManager config file.
- **DNS Testing**: Guide didn't pre-check for bind-utils; had to install it on both nodes.
- **Worker DNS**: Guide assumes dedicated servers need manual DNS config (true), but guide example used nmcli. Worker node worked correctly with nmcli since no cloud-init conflict.
