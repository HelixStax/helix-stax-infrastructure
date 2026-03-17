---
tags: [infrastructure, phase-0, hetzner, load-balancer, cost-optimization, tutorial-series, helix-stax]
created: 2026-03-17
updated: 2026-03-17
phase: "0"
step: "05"
estimated-time: "2-3 minutes"
nodes: []
author: Kit (DevOps Engineer)
---

# Step 05: Delete Unnecessary Hetzner Load Balancer

> **Goal**: Remove the `helix-k8s-api-lb` load balancer (ID: 5886481) that serves no purpose with a single control plane node. Saves ~$6/month.

## Prerequisites

- [ ] `hcloud` CLI installed on your local machine
- [ ] Hetzner Cloud API token configured (`hcloud context active`)
- [ ] K3s cluster wiped (no services relying on the LB)

> **Note**: This step is also included at the end of [[01-wipe-cluster]]. If you already deleted the LB during the wipe, skip this guide entirely. This standalone guide exists for reference and if the steps were done out of order.

---

## Why Delete?

| Factor | Details |
|--------|---------|
| **Current config** | `helix-k8s-api-lb` -- routes traffic to K3s API (6443) on heart |
| **HA benefit** | None. Single control plane node means the LB is a pass-through with no failover target |
| **Cost** | ~$6/month (~$72/year) for zero benefit |
| **Risk of keeping** | Extra attack surface (public LB endpoint), confusing network topology |
| **If we add HA later** | We'll create a fresh LB with proper multi-CP config when/if a second CP node is added |

---

## 1. Verify Current State

Run from your **local machine**:

```bash
hcloud load-balancer list
```

Expected output:
```
ID        NAME               IPV4             IPV6                   TYPE   LOCATION   NETWORK ZONE
5886481   helix-k8s-api-lb   <some-ip>        <some-ipv6>           lb11   fsn1       eu-central
```

### 1.1 Check Load Balancer Details (Optional)

```bash
hcloud load-balancer describe 5886481
```

This shows targets, services, health checks. Useful for the tutorial to explain what the LB was doing.

> **Tutorial note**: Screenshot the `describe` output before deletion. Shows the audience what was configured and why it's unnecessary for a single-node CP.

---

## 2. Delete the Load Balancer

```bash
hcloud load-balancer delete 5886481
```

Expected: No output (silent success) or a confirmation message.

---

## 3. Verify Deletion

```bash
hcloud load-balancer list
```

Expected: Empty list or the `helix-k8s-api-lb` entry no longer appears.

### 3.1 Verify No DNS/Firewall References

If any DNS records or firewall rules pointed at the LB's IP, they should be cleaned up:

```bash
# Check Hetzner firewalls for LB IP references
hcloud firewall list

# If you had DNS records pointing to the LB IP, remove them
# (unlikely for API LB, but verify)
```

---

## 4. Verify K3s API Access Path

After deletion, the K3s API (when reinstalled) will be accessed directly via the CP node's IP:

| Before (with LB) | After (without LB) |
|-------------------|---------------------|
| `https://<lb-ip>:6443` | `https://178.156.233.12:6443` |

When K3s is reinstalled, ensure your kubeconfig points to `178.156.233.12:6443` directly, not the old LB IP.

---

## Rollback Plan

If you need the load balancer back (e.g., adding a second CP node):

```bash
# Create a new LB
hcloud load-balancer create --name helix-k8s-api-lb --type lb11 --location fsn1

# Add the CP node as target
hcloud load-balancer add-target <new-lb-id> --server heart

# Add K3s API service
hcloud load-balancer add-service <new-lb-id> \
  --protocol tcp \
  --listen-port 6443 \
  --destination-port 6443 \
  --health-check-port 6443 \
  --health-check-protocol tcp \
  --health-check-interval 15 \
  --health-check-timeout 10 \
  --health-check-retries 3
```

---

## Summary

| Action | Status |
|--------|--------|
| Current LB state verified | [ ] |
| LB deleted (`hcloud load-balancer delete 5886481`) | [ ] |
| Deletion confirmed (`hcloud load-balancer list`) | [ ] |
| No stale DNS/firewall references | [ ] |

**Monthly savings**: ~$6/month ($72/year)

**Next step**: Phase 0 complete. Proceed to [[../phase-01-foundation/]] (Terraform + VPS provisioning)
