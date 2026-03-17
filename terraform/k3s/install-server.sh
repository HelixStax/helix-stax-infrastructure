#!/usr/bin/env bash
# =============================================================================
# install-server.sh — K3s Control Plane Bootstrap
# Helix Stax Infrastructure — Phase 1
#
# Usage:
#   K3S_TOKEN=<secret> ./install-server.sh
#
# Prerequisites:
#   - AlmaLinux 9 with internet access
#   - K3S_TOKEN env var set (shared secret for agent join)
#   - Run as root
#
# This script:
#   1. Installs K3s server with Flannel disabled (Cilium will handle CNI)
#   2. Places k3s-config.yaml at /etc/rancher/k3s/config.yaml
#   3. Verifies the cluster is healthy
# =============================================================================

set -euo pipefail

# ---- Prerequisites check ---------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must run as root" >&2
  exit 1
fi

if [[ -z "${K3S_TOKEN:-}" ]]; then
  echo "ERROR: K3S_TOKEN environment variable must be set" >&2
  echo "  Generate one with: openssl rand -hex 32" >&2
  exit 1
fi

echo "==> Installing K3s control plane..."

# ---- Create config dir ------------------------------------------------------
mkdir -p /etc/rancher/k3s

# ---- Place server config ----------------------------------------------------
# Copy k3s-config.yaml from the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/k3s-config.yaml" ]]; then
  cp "$SCRIPT_DIR/k3s-config.yaml" /etc/rancher/k3s/config.yaml
  echo "    Placed k3s-config.yaml at /etc/rancher/k3s/config.yaml"
else
  echo "WARNING: k3s-config.yaml not found, using inline defaults" >&2
fi

# ---- Install K3s ------------------------------------------------------------
# --flannel-backend=none     → We'll install Cilium as CNI
# --disable-network-policy   → Cilium handles network policies
# --disable traefik          → We install Traefik separately via Helm
# --disable servicelb        → Not needed with Hetzner CCM or MetalLB
# Config file at /etc/rancher/k3s/config.yaml is auto-loaded
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server \
    --flannel-backend=none \
    --disable-network-policy \
    --disable traefik \
    --disable servicelb" \
  sh -s -

echo "==> K3s installed. Waiting for node to become ready..."

# ---- Wait for node ready ----------------------------------------------------
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    echo "==> Node is Ready."
    break
  fi
  echo "    Waiting... ($i/30)"
  sleep 10
done

# ---- Print join token -------------------------------------------------------
echo ""
echo "==> K3s control plane is up."
echo "==> Node token (for agents): $(cat /var/lib/rancher/k3s/server/node-token)"
echo ""
echo "==> Kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo "    Copy to local machine:"
echo "    scp -P 2222 root@178.156.233.12:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
echo "    sed -i 's/127.0.0.1/178.156.233.12/' ~/.kube/config"
echo ""
echo "==> Next step: install Cilium CNI (nodes will be NotReady until then)"
echo "    See: https://docs.cilium.io/en/stable/installation/k3s/"
