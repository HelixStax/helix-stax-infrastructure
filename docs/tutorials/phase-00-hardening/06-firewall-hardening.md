---
tags: [infrastructure, hardening, firewall, firewalld, hetzner, security, phase-0, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
status: draft
author: Ezra (Security Engineer)
estimated-time: 45-60 minutes
applies-to: [heart, helix-worker-1]
---

# 06 — Firewall Hardening

> Lock down both nodes with strict firewalld rules and mirror them at the Hetzner Cloud perimeter. Default deny everything except what K3s and SSH explicitly need.
>
> **Run on**: heart (178.156.233.12) AND helix-worker-1 (138.201.131.157)
> **Estimated time**: 45-60 minutes (both nodes + Hetzner console)

---

## Prerequisites

- [[02-ssh-hardening]] completed (SSH on port 2222, key-only auth)
- SSH access to both nodes on port 2222
- Hetzner Cloud Console access (for cloud firewall configuration)
- Your admin workstation's public IP address

**Get your admin IP now** (run on your workstation):

```bash
curl -4 ifconfig.me
```

Write it down — you will use it repeatedly as `<ADMIN_IP>` in this guide.

---

## Tutorial Notes

> **Content capture**: Screenshot `firewall-cmd --list-all` before and after. Screenshot the Hetzner Cloud Firewall UI. Run an nmap scan from a non-admin IP to show the default-deny working.

---

## Part 1: firewalld on heart (Control Plane)

### Step 1: Audit Current Rules

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

```bash
echo "=== Current firewall state ==="
firewall-cmd --state
firewall-cmd --get-active-zones
firewall-cmd --list-all
```

Take note of what is currently open. Save this as your "before" snapshot.

---

### Step 2: Create a Custom K8s Zone

We create a dedicated zone with strict rules rather than modifying the default zone.

```bash
# Create the zone
firewall-cmd --permanent --new-zone=k8s-hardened

# Set default target to DROP (deny everything not explicitly allowed)
firewall-cmd --permanent --zone=k8s-hardened --set-target=DROP
```

---

### Step 3: Add Rules to k8s-hardened Zone

> [!WARNING]
> Replace `<ADMIN_IP>` with your actual admin IP from the prerequisites. If your IP changes (dynamic ISP), you will need to update these rules or use the Hetzner Cloud Console to regain access.

#### SSH (port 2222) — Admin only

```bash
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>/32" port port="2222" protocol="tcp" accept'
```

#### K8s API (port 6443) — Admin + cluster network

```bash
# From admin workstation
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>/32" port port="6443" protocol="tcp" accept'

# From cluster network (pod/service CIDR)
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="10.42.0.0/16" port port="6443" protocol="tcp" accept'

# From worker node
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="138.201.131.157/32" port port="6443" protocol="tcp" accept'
```

#### Kubelet API (port 10250) — Cluster network only

```bash
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="10.42.0.0/16" port port="10250" protocol="tcp" accept'

# Worker node needs kubelet access to CP
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="138.201.131.157/32" port port="10250" protocol="tcp" accept'

# CP needs kubelet access to itself
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="10250" protocol="tcp" accept'
```

#### Flannel VXLAN (port 8472/udp) — Cluster nodes only

```bash
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="138.201.131.157/32" port port="8472" protocol="udp" accept'

firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="8472" protocol="udp" accept'
```

#### etcd (ports 2379-2380) — CP node only (localhost + cluster network)

```bash
# etcd client and peer ports — CP only
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="2379-2380" protocol="tcp" accept'

firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="127.0.0.1/8" port port="2379-2380" protocol="tcp" accept'
```

#### NodePort range (30000-32767) — Admin only for now

```bash
# Only admin can reach NodePort services (Devtron dashboard on 31656, etc.)
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>/32" port port="30000-32767" protocol="tcp" accept'
```

#### HTTP/HTTPS (ports 80, 443) — Public (for Traefik ingress)

```bash
# These will serve public websites via Traefik — open to all
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" port port="80" protocol="tcp" accept'

firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" port port="443" protocol="tcp" accept'
```

---

### Step 4: Assign Interface and Activate

```bash
# Find the main network interface
ip -o link show | awk -F': ' '{print $2}' | grep -v lo

# Assign the zone to the interface (usually eth0 or ens3)
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "Main interface: $IFACE"

firewall-cmd --permanent --zone=k8s-hardened --change-interface=$IFACE
```

---

### Step 5: Reload and Verify

> [!WARNING]
> **Keep your current SSH session open.** After reload, test from a new terminal FIRST.

```bash
# Reload firewall
firewall-cmd --reload

# Verify active zone
firewall-cmd --get-active-zones

# List all rules in the new zone
firewall-cmd --zone=k8s-hardened --list-all
```

**Test from a NEW terminal on your workstation**:

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
```

If this works, the firewall rules are correct.

**If you are locked out**: Use Hetzner Cloud Console (web VNC) to access the node and fix the rules:

```bash
# Emergency: revert to default zone
firewall-cmd --permanent --zone=public --change-interface=$IFACE
firewall-cmd --permanent --zone=public --add-port=2222/tcp
firewall-cmd --reload
```

---

### Step 6: Remove the Default Zone Rules

Once `k8s-hardened` is confirmed working, clean up any lingering rules from the default `public` zone:

```bash
# Remove any stale rules from public zone
firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null
firewall-cmd --permanent --zone=public --remove-service=dhcpv6-client 2>/dev/null
firewall-cmd --permanent --zone=public --remove-service=cockpit 2>/dev/null
firewall-cmd --permanent --zone=public --remove-port=2222/tcp 2>/dev/null
firewall-cmd --reload
```

---

## Part 2: firewalld on helix-worker-1

SSH into the worker node:

```bash
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157
```

Repeat Steps 1-6 with these differences:

- **No etcd rules needed** (worker nodes do not run etcd)
- **Kubelet sources** reference the CP node IP instead:

```bash
# Worker-specific: CP needs kubelet access
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="10250" protocol="tcp" accept'
```

The full worker zone rules (copy-paste block):

```bash
# Create zone
firewall-cmd --permanent --new-zone=k8s-hardened
firewall-cmd --permanent --zone=k8s-hardened --set-target=DROP

# SSH — admin only
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>/32" port port="2222" protocol="tcp" accept'

# Kubelet — CP + self + pod network
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="10250" protocol="tcp" accept'
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="138.201.131.157/32" port port="10250" protocol="tcp" accept'
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="10.42.0.0/16" port port="10250" protocol="tcp" accept'

# Flannel VXLAN — cluster nodes
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="178.156.233.12/32" port port="8472" protocol="udp" accept'
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="138.201.131.157/32" port port="8472" protocol="udp" accept'

# NodePort — admin only
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" source address="<ADMIN_IP>/32" port port="30000-32767" protocol="tcp" accept'

# HTTP/HTTPS — public (Traefik ingress)
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" port port="80" protocol="tcp" accept'
firewall-cmd --permanent --zone=k8s-hardened \
  --add-rich-rule='rule family="ipv4" port port="443" protocol="tcp" accept'

# Assign interface
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
firewall-cmd --permanent --zone=k8s-hardened --change-interface=$IFACE

# Reload
firewall-cmd --reload
```

---

## Part 3: Hetzner Cloud Firewall

The Hetzner Cloud Firewall acts as a **perimeter defense** — traffic is filtered before it reaches the node. This is defense-in-depth: even if firewalld is misconfigured, the cloud firewall blocks unauthorized traffic.

### Step 7: Verify Existing Firewall on heart

1. Log into [Hetzner Cloud Console](https://console.hetzner.cloud)
2. Go to **Firewalls** in the left sidebar
3. Find **helix-cp-firewall** (ID: 10604292)
4. Review current rules — update to match:

| Direction | Protocol | Port | Source | Description |
|-----------|----------|------|--------|-------------|
| Inbound | TCP | 2222 | `<ADMIN_IP>/32` | SSH (hardened port) |
| Inbound | TCP | 6443 | `<ADMIN_IP>/32` | K8s API (admin) |
| Inbound | TCP | 6443 | `138.201.131.157/32` | K8s API (worker) |
| Inbound | TCP | 10250 | `138.201.131.157/32` | Kubelet (worker) |
| Inbound | UDP | 8472 | `138.201.131.157/32` | Flannel VXLAN (worker) |
| Inbound | TCP | 2379-2380 | `178.156.233.12/32` | etcd (self) |
| Inbound | TCP | 80 | `0.0.0.0/0, ::/0` | HTTP (Traefik) |
| Inbound | TCP | 443 | `0.0.0.0/0, ::/0` | HTTPS (Traefik) |
| Inbound | TCP | 30000-32767 | `<ADMIN_IP>/32` | NodePort (admin) |
| Outbound | TCP/UDP | Any | `0.0.0.0/0, ::/0` | Allow all outbound |

> [!NOTE]
> Remove any rules allowing port 22 from any source. SSH is now on port 2222.

### Step 8: Create Firewall for helix-worker-1

> [!WARNING]
> **helix-worker-1 currently has NO Hetzner Cloud Firewall.** This means all ports are exposed at the network level. Fix this now.

1. In Hetzner Cloud Console, go to **Firewalls** > **Create Firewall**
2. Name: `helix-worker-firewall`
3. Add these inbound rules:

| Direction | Protocol | Port | Source | Description |
|-----------|----------|------|--------|-------------|
| Inbound | TCP | 2222 | `<ADMIN_IP>/32` | SSH (hardened port) |
| Inbound | TCP | 10250 | `178.156.233.12/32` | Kubelet (CP) |
| Inbound | UDP | 8472 | `178.156.233.12/32` | Flannel VXLAN (CP) |
| Inbound | TCP | 80 | `0.0.0.0/0, ::/0` | HTTP (Traefik) |
| Inbound | TCP | 443 | `0.0.0.0/0, ::/0` | HTTPS (Traefik) |
| Inbound | TCP | 30000-32767 | `<ADMIN_IP>/32` | NodePort (admin) |
| Outbound | TCP/UDP | Any | `0.0.0.0/0, ::/0` | Allow all outbound |

4. Apply to server: **helix-worker-1**
5. Click **Create Firewall**

> [!NOTE]
> The worker does NOT need etcd ports (2379-2380) or K8s API (6443) open inbound.

### Alternative: Hetzner CLI

If you have `hcloud` CLI installed:

```bash
# Create worker firewall
hcloud firewall create --name helix-worker-firewall

# Add rules (repeat for each)
hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol tcp --port 2222 \
  --source-ips <ADMIN_IP>/32 \
  --description "SSH (hardened port)"

hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol tcp --port 10250 \
  --source-ips 178.156.233.12/32 \
  --description "Kubelet (CP)"

hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol udp --port 8472 \
  --source-ips 178.156.233.12/32 \
  --description "Flannel VXLAN (CP)"

hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol tcp --port 80 \
  --source-ips 0.0.0.0/0 \
  --description "HTTP (Traefik)"

hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol tcp --port 443 \
  --source-ips 0.0.0.0/0 \
  --description "HTTPS (Traefik)"

hcloud firewall add-rule helix-worker-firewall \
  --direction in --protocol tcp --port 30000-32767 \
  --source-ips <ADMIN_IP>/32 \
  --description "NodePort (admin)"

# Apply to server
hcloud firewall apply-to-resource helix-worker-firewall \
  --type server --server helix-worker-1
```

---

## Part 4: Verification

### Verify firewalld (on each node)

```bash
echo "=== Firewall Verification ==="

echo "--- Active zone ---"
firewall-cmd --get-active-zones

echo "--- Zone rules ---"
firewall-cmd --zone=k8s-hardened --list-all

echo "--- Default zone (should be empty/inactive) ---"
firewall-cmd --zone=public --list-all
```

### Verify from external (run from your workstation)

```bash
# Should SUCCEED (admin IP on port 2222)
ssh -i ~/.ssh/helixstax_key -p 2222 root@178.156.233.12
ssh -i ~/.ssh/helixstax_key -p 2222 root@138.201.131.157

# Should FAIL (port 22 closed)
ssh -i ~/.ssh/helixstax_key root@178.156.233.12
ssh -i ~/.ssh/helixstax_key root@138.201.131.157
```

### Verify with nmap (optional, from a different IP if possible)

```bash
# Scan from a non-admin IP to verify default deny
nmap -Pn -p 22,2222,6443,31656 178.156.233.12
nmap -Pn -p 22,2222,6443,31656 138.201.131.157
```

From a non-admin IP, only ports 80 and 443 should be open. Everything else should show as `filtered`.

---

## Rollback Plan

### Revert firewalld

```bash
# Switch back to default public zone
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
firewall-cmd --permanent --zone=public --change-interface=$IFACE
firewall-cmd --permanent --zone=public --add-port=2222/tcp
firewall-cmd --reload

# Delete custom zone
firewall-cmd --permanent --delete-zone=k8s-hardened
firewall-cmd --reload
```

### Revert Hetzner Cloud Firewall

1. Go to Hetzner Cloud Console > Firewalls
2. Remove the firewall from the affected server (this opens all ports at the perimeter)
3. Re-apply after fixing rules

> [!WARNING]
> Removing the Hetzner Cloud Firewall opens ALL ports at the perimeter level. Only do this as emergency access recovery.

---

## Notes for Phase 3 (Cilium Migration)

When Cilium replaces Flannel in Phase 3:
- Flannel VXLAN (port 8472/udp) rules can be replaced with Cilium's ports (4240/tcp for health, 8472/udp for VXLAN, or 6081/udp for Geneve depending on config)
- Cilium has a known race condition with firewalld on eBPF — see [[lessons_infrastructure]] for the workaround
- Consider disabling firewalld entirely and letting Cilium handle all network policy (common production pattern)
- Netbird will be available as fallback access before touching firewalld/Cilium

## Execution Log

### Issue 1: SSH Access Strategy (Admin IP Dynamically Assigned)
- **What happened**: Guide suggests restricting SSH (port 2222) in firewalld to admin IP only. However, admin workstation has dynamic ISP IP that changes regularly.
- **Root cause**: Hetzner residential ISP with dynamic IP. Setting firewalld rule to static `/32` would require frequent updates, creating lockout risk.
- **Fix applied**: Left SSH (2222) open to all IPs in firewalld, relying on defense-in-depth: key-only auth (no passwords allowed), non-standard port (port knocking effect), and fail2ban (automatic brute-force blocking). Added admin IP restriction at Hetzner Cloud Firewall perimeter on CP node for extra layer.
- **Lesson for readers**: If your admin IP is dynamic, don't restrict SSH in firewalld. Instead, rely on: (1) key-only authentication, (2) non-standard port, (3) fail2ban automatic banning, (4) cloud provider firewall restriction at perimeter if available. Avoid lockout by not requiring frequent rule updates.

### Issue 2: K8s API Accessible to Pod CIDR
- **What happened**: Removed old rule that opened K8s API (6443) to all (0.0.0.0/0) on CP node, replacing with restricted: admin IP + worker node + pod CIDR (10.42.0.0/16).
- **Root cause**: Previous configuration was over-permissive for security audit phase.
- **Fix applied**: Applied tighter rules. Verified rules work with actual pod traffic after K3s reinstall.
- **Lesson for readers**: K8s API should never be open to the internet. Always restrict to admin IPs, cluster nodes, and pod CIDR. Use Hetzner Cloud Firewall as additional perimeter defense.

### Issue 3: Old Devtron NodePort Rules Cleaned Up
- **What happened**: Previous rules exposed Devtron Dashboard (port 31656) and port-forward service (8080) to 0.0.0.0/0. Both were removed and replaced with admin-IP-only rules.
- **Root cause**: Pre-hardening configuration was permissive for development; now tightening for production.
- **Fix applied**: Removed `0.0.0.0/0` rules for NodePort range (30000-32767), restricted to admin IP only in both firewalld and Hetzner Cloud FW.
- **Lesson for readers**: NodePort services (which include dashboards) should be restricted to admin access unless they're intentionally public. Use firewall rules to enforce this, not just RBAC.

### Issue 4: Worker Node Interface Name Discovery
- **What happened**: Used dynamic interface detection `ip route get 1.1.1.1 | awk '{print $5; exit}'` instead of hardcoding `eth0`. Discovered worker's interface is `enp0s31f6` (dedicated server naming convention).
- **Root cause**: Different interface naming conventions: cloud images use `eth0`, dedicated servers use `enp0s<slot>f<function>` predictable names.
- **Fix applied**: Used dynamic interface detection command that works across all server types.
- **Lesson for readers**: Don't hardcode interface names. Use `ip route` or `nmcli` to dynamically detect the primary interface. Dedicated servers and cloud images have different naming schemes.

## Deviations from Guide
- **SSH Firewall Rule**: Guide assumes static admin IP. Implemented instead: SSH open in firewalld (compensated by key-only auth + fail2ban), restricted to admin IP at Hetzner Cloud FW perimeter on CP node.
- **Hetzner Cloud Firewall on CP**: Tightened more than guide specified; removed port 22, 8080, 31656 rules that were open to all.
- **Worker Node**: No Hetzner Cloud Firewall available (dedicated server product limitation). Relied entirely on firewalld with key-only auth + fail2ban for SSH security.
- **Interface Detection**: Used dynamic discovery instead of assuming eth0, improving portability.
