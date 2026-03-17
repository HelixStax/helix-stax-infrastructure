#!/usr/bin/env bash
# =============================================================================
# install-agent.sh — K3s Worker Agent Bootstrap
# Helix Stax Infrastructure — Phase 1
#
# Usage:
#   K3S_TOKEN=<secret> K3S_URL=https://<CP_IP>:6443 ./install-agent.sh
#
# Prerequisites:
#   - Debian 12 or AlmaLinux 9 with internet access
#   - K3S_TOKEN env var set (same token used when installing server)
#   - K3S_URL env var set (control plane API URL)
#   - Run as root
# =============================================================================

set -euo pipefail

# ---- Prerequisites check ---------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must run as root" >&2
  exit 1
fi

if [[ -z "${K3S_TOKEN:-}" ]]; then
  echo "ERROR: K3S_TOKEN environment variable must be set" >&2
  exit 1
fi

if [[ -z "${K3S_URL:-}" ]]; then
  echo "ERROR: K3S_URL environment variable must be set" >&2
  echo "  Example: export K3S_URL=https://178.156.233.12:6443" >&2
  exit 1
fi

echo "==> Installing K3s agent (worker)..."
echo "    Connecting to: $K3S_URL"

# ---- Install K3s agent ------------------------------------------------------
curl -sfL https://get.k3s.io | \
  K3S_URL="$K3S_URL" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh -s -

echo "==> K3s agent installed and joining cluster."
echo "    Verify on control plane with: kubectl get nodes"
