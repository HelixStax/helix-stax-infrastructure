#!/usr/bin/env bash
# =============================================================================
# Helix Stax — UFW Firewall Hardening Script
# =============================================================================
#
# Zero-trust firewall configuration for VPS (5.78.145.30, Debian 12).
#
# Opens ONLY the ports required for public-facing services:
#   - SSH (2222)        — break-glass admin access, independent of Netbird/Authentik
#   - HTTP/HTTPS (80/443) — Nginx TLS termination for Authentik + Vaultwarden
#   - Netbird Signal (10000) — peer signaling
#   - Netbird Management (33073) — gRPC management API
#   - Netbird Relay (33080) — relay traffic for peers behind NAT
#   - Coturn STUN/TURN (3478 + 49152-65535/UDP) — NAT traversal
#
# NOT opened (Netbird-only after rebind):
#   - Harbor (8080)
#   - OpenBao (8200)
#   - MinIO API (9002)
#   - MinIO Console (9003)
#
# Usage:
#   sudo ./firewall-setup.sh                  # UFW rules only
#   sudo ./firewall-setup.sh --with-docker-rules  # UFW + DOCKER-USER iptables rules
#   sudo ADMIN_IP=203.0.113.5 ./firewall-setup.sh # Restrict SSH to specific IP
#
# Safety:
#   - Dead man's switch auto-disables firewall in 15 minutes if not confirmed
#   - Confirmation prompt before applying rules
#   - Idempotent — safe to run multiple times
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (or with sudo)."
    exit 1
fi

# Check for required tools
for cmd in ufw at logger; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Install it first."
        [[ "$cmd" == "at" ]] && echo "  → apt-get install at"
        exit 1
    fi
done

# Ensure the 'at' daemon is running (needed for dead man's switch)
if ! systemctl is-active --quiet atd 2>/dev/null; then
    echo "Starting atd service (required for dead man's switch)..."
    systemctl start atd
    systemctl enable atd
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# ADMIN_IP controls who can SSH in on port 2222.
# If not set, SSH is open to all IPs (0.0.0.0/0) — a WARNING is printed.
ADMIN_IP="${ADMIN_IP:-0.0.0.0/0}"

# Parse flags
WITH_DOCKER_RULES=false
for arg in "$@"; do
    case "$arg" in
        --with-docker-rules)
            WITH_DOCKER_RULES=true
            ;;
        --help|-h)
            echo "Usage: sudo [ADMIN_IP=x.x.x.x] $0 [--with-docker-rules]"
            echo ""
            echo "Options:"
            echo "  --with-docker-rules  Add DOCKER-USER iptables rules for defense-in-depth"
            echo ""
            echo "Environment:"
            echo "  ADMIN_IP    IP address allowed to SSH (default: 0.0.0.0/0 = open)"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument '$arg'. Use --help for usage."
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Warnings
# ---------------------------------------------------------------------------

if [[ "$ADMIN_IP" == "0.0.0.0/0" ]]; then
    echo "============================================================"
    echo "  WARNING: ADMIN_IP is not set."
    echo "  SSH (port 2222) will be open to ALL IP addresses."
    echo "  For production, set ADMIN_IP to your admin IP:"
    echo "    sudo ADMIN_IP=203.0.113.5 $0"
    echo "============================================================"
    echo ""
fi

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------

echo "This script will:"
echo "  1. Reset UFW to a clean state"
echo "  2. Apply firewall rules (default deny incoming, allow outgoing)"
echo "  3. Open ports: 2222/tcp, 80/tcp, 443/tcp, 10000/tcp, 33073/tcp, 33080/tcp, 3478/udp, 49152-65535/udp"
echo "  4. Restrict SSH (2222) to: ${ADMIN_IP}"
if [[ "$WITH_DOCKER_RULES" == "true" ]]; then
    echo "  5. Add DOCKER-USER iptables rules (defense-in-depth)"
fi
echo ""
read -r -p "This will modify firewall rules. Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Dead man's switch
# ---------------------------------------------------------------------------
# Schedule automatic firewall disable in 15 minutes. If the admin gets locked
# out, the firewall will revert itself. The admin confirms access after rules
# are applied, which cancels this scheduled job.

DEAD_MAN_JOB_ID=$(echo 'ufw disable && echo "Firewall auto-disabled — dead man switch triggered" | logger -t firewall-setup' | at now + 15 minutes 2>&1 | grep -oP 'job \K\d+' || true)

if [[ -z "$DEAD_MAN_JOB_ID" ]]; then
    echo "WARNING: Could not schedule dead man's switch via 'at'."
    echo "Proceeding without automatic rollback — be careful!"
    read -r -p "Continue without dead man's switch? [y/N] " confirm_no_dms
    if [[ ! "$confirm_no_dms" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
else
    echo ""
    echo "Dead man's switch set (at job #${DEAD_MAN_JOB_ID})."
    echo "Firewall will AUTO-DISABLE in 15 minutes if not confirmed."
    echo ""
fi

# ---------------------------------------------------------------------------
# UFW Rules
# ---------------------------------------------------------------------------

echo ">>> Resetting UFW to clean state..."
ufw --force reset

echo ">>> Setting default policies..."
# Deny all incoming traffic by default — only explicitly allowed ports are open
ufw default deny incoming
# Allow all outgoing traffic — server needs to reach apt repos, DNS, APIs, etc.
ufw default allow outgoing

# --- SSH (port 2222) ---
# Break-glass access. This is the ONLY way to reach the server if Netbird or
# Authentik are down. It must NEVER depend on either service.
# Restricted to ADMIN_IP when set; open to all as fallback (with warning above).
ufw allow from "${ADMIN_IP}" to any port 2222 proto tcp comment 'SSH (restricted to admin IP)'

# --- Nginx (ports 80, 443) ---
# Public TLS termination point. Nginx reverse-proxies to:
#   - auth.helixstax.net  → authentik-server:9000 (OIDC, public for SSO)
#   - vault.helixstax.net → vaultwarden:80 (password manager, public for WebCrypto)
# All other services are NOT exposed through Nginx.
ufw allow 80/tcp comment 'HTTP (Nginx redirect to HTTPS)'
ufw allow 443/tcp comment 'HTTPS (Nginx — Authentik + Vaultwarden)'

# --- Netbird Signal Server (port 10000) ---
# WebSocket-based signaling for Netbird peers to discover each other.
# Must be publicly accessible so peers behind NAT can connect.
ufw allow 10000/tcp comment 'Netbird Signal'

# --- Netbird Management API (port 33073) ---
# gRPC API used by Netbird clients to register, authenticate, and receive
# network configuration. Must be publicly accessible for peer enrollment.
ufw allow 33073/tcp comment 'Netbird Management gRPC'

# --- Netbird Relay (port 33080) ---
# Relay server for peers that cannot establish direct WireGuard tunnels.
# Must be publicly accessible as a fallback transport.
ufw allow 33080/tcp comment 'Netbird Relay'

# --- Coturn STUN/TURN (host networking — UFW applies directly) ---
# Coturn runs with network_mode: host, so it binds directly to the host's
# network stack. Unlike bridged Docker containers (which bypass UFW via the
# DOCKER iptables chain), UFW rules DO apply to coturn's ports.
#
# STUN: Lightweight NAT discovery (single UDP packet exchange)
ufw allow 3478/udp comment 'Coturn STUN/TURN'
# TURN relay range: Used when peers cannot connect directly. Each active
# relay session consumes a port from this range.
ufw allow 49152:65535/udp comment 'Coturn relay range'

echo ">>> Enabling UFW..."
ufw --force enable

# ---------------------------------------------------------------------------
# Docker iptables interaction — IMPORTANT NOTES
# ---------------------------------------------------------------------------
#
# Docker bypasses UFW entirely by inserting its own rules into the DOCKER
# iptables chain (before UFW's INPUT chain is evaluated). This means:
#
# 1. Services bound to 127.0.0.1:PORT (e.g., Authentik on 127.0.0.1:9000,
#    Vaultwarden on 127.0.0.1:8088, OpenBao on 127.0.0.1:8200, MinIO on
#    127.0.0.1:9002/9003) are SAFE — Docker only creates iptables rules
#    for the loopback interface. These are NOT accessible from the internet.
#
# 2. Services bound to 0.0.0.0:PORT (Netbird Signal on 10000, Management
#    on 33073, Relay on 33080) are exposed regardless of UFW rules. This
#    is INTENTIONAL — these Netbird services must be publicly reachable
#    for the mesh VPN to function.
#
# 3. After Netbird IP rebinding (Phase 3a of zero-trust plan), private
#    services will bind to 100.64.0.x (Netbird CGNAT range). This range
#    is NOT internet-routable, so even without UFW, these services will
#    only be reachable through the Netbird tunnel.
#
# 4. Coturn runs with network_mode: host — it does NOT use the DOCKER
#    iptables chain. UFW rules apply to coturn directly (see rules above).
#
# The UFW rules above handle non-Docker traffic (SSH, coturn). Docker port
# bindings (127.0.0.1: prefix) are the real access control for bridged
# containers. The DOCKER-USER rules below add defense-in-depth.
#

# ---------------------------------------------------------------------------
# DOCKER-USER chain rules (optional, defense-in-depth)
# ---------------------------------------------------------------------------

if [[ "$WITH_DOCKER_RULES" == "true" ]]; then
    echo ""
    echo ">>> Applying DOCKER-USER iptables rules (defense-in-depth)..."
    echo ""

    # Detect the primary public-facing network interface.
    # On Hetzner VPS this is typically eth0, but could vary.
    PUBLIC_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [[ -z "$PUBLIC_IFACE" ]]; then
        echo "WARNING: Could not detect default network interface. Defaulting to eth0."
        PUBLIC_IFACE="eth0"
    fi
    echo "  Using network interface: ${PUBLIC_IFACE}"

    # Ensure the DOCKER-USER chain exists (Docker creates it, but be safe)
    iptables -N DOCKER-USER 2>/dev/null || true

    # Flush existing DOCKER-USER rules to make this idempotent.
    # Docker inserts a default RETURN rule; we flush and re-add our rules + RETURN.
    iptables -F DOCKER-USER

    # Block direct public access to private service ports.
    # These services should ONLY be reached via loopback (127.0.0.1) or
    # Netbird tunnel (100.64.0.x). Blocking them on the public interface
    # adds a second layer of protection beyond the 127.0.0.1 bind address.

    # Harbor — container registry (internal only, Netbird-only after rebind)
    iptables -A DOCKER-USER -i "$PUBLIC_IFACE" -p tcp --dport 8080 -j DROP
    echo "  Blocked: ${PUBLIC_IFACE} → port 8080 (Harbor)"

    # OpenBao — secrets management (internal only, Netbird-only after rebind)
    iptables -A DOCKER-USER -i "$PUBLIC_IFACE" -p tcp --dport 8200 -j DROP
    echo "  Blocked: ${PUBLIC_IFACE} → port 8200 (OpenBao)"

    # MinIO API — object storage API (internal only, Netbird-only after rebind)
    iptables -A DOCKER-USER -i "$PUBLIC_IFACE" -p tcp --dport 9002 -j DROP
    echo "  Blocked: ${PUBLIC_IFACE} → port 9002 (MinIO API)"

    # MinIO Console — object storage web UI (internal only, Netbird-only after rebind)
    iptables -A DOCKER-USER -i "$PUBLIC_IFACE" -p tcp --dport 9003 -j DROP
    echo "  Blocked: ${PUBLIC_IFACE} → port 9003 (MinIO Console)"

    # IMPORTANT: The DOCKER-USER chain must end with RETURN so that
    # legitimate Docker traffic (allowed ports) continues to the DOCKER chain.
    iptables -A DOCKER-USER -j RETURN
    echo "  Added: RETURN rule (allows remaining Docker traffic)"

    echo ""
    echo "  NOTE: DOCKER-USER rules are NOT persistent across reboots."
    echo "  To persist, add these rules to /etc/iptables/rules.v4 or use"
    echo "  iptables-persistent (apt-get install iptables-persistent)."
fi

# ---------------------------------------------------------------------------
# Status output
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "  FIREWALL STATUS"
echo "============================================================"
echo ""
ufw status verbose
echo ""

echo "============================================================"
echo "  PORT SUMMARY"
echo "============================================================"
echo ""
echo "  OPEN PORTS:"
echo "    TCP  2222           SSH (admin access, restricted to: ${ADMIN_IP})"
echo "    TCP  80             HTTP → HTTPS redirect (Nginx)"
echo "    TCP  443            HTTPS — Authentik + Vaultwarden (Nginx)"
echo "    TCP  10000          Netbird Signal (peer discovery)"
echo "    TCP  33073          Netbird Management (gRPC API)"
echo "    TCP  33080          Netbird Relay (NAT fallback)"
echo "    UDP  3478           Coturn STUN/TURN (NAT traversal)"
echo "    UDP  49152-65535    Coturn relay range"
echo ""
echo "  BLOCKED (not opened — Netbird-only after rebind):"
echo "    TCP  8080           Harbor (container registry)"
echo "    TCP  8200           OpenBao (secrets management)"
echo "    TCP  9002           MinIO API (object storage)"
echo "    TCP  9003           MinIO Console (object storage UI)"
echo ""
if [[ "$WITH_DOCKER_RULES" == "true" ]]; then
    echo "  DOCKER-USER iptables rules applied (defense-in-depth)"
    echo ""
fi

# ---------------------------------------------------------------------------
# Dead man's switch confirmation
# ---------------------------------------------------------------------------

if [[ -n "${DEAD_MAN_JOB_ID:-}" ]]; then
    echo "============================================================"
    echo "  DEAD MAN'S SWITCH — CONFIRMATION REQUIRED"
    echo "============================================================"
    echo ""
    echo "  The firewall will AUTO-DISABLE in ~15 minutes (at job #${DEAD_MAN_JOB_ID})."
    echo "  Open a SECOND SSH session to verify you can still connect,"
    echo "  then return here to confirm."
    echo ""
    read -r -p "  Can you still SSH in? Confirm to cancel dead man's switch [y/N] " ssh_confirm
    if [[ "$ssh_confirm" =~ ^[Yy]$ ]]; then
        atrm "$DEAD_MAN_JOB_ID" 2>/dev/null && \
            echo "  Dead man's switch CANCELLED (at job #${DEAD_MAN_JOB_ID} removed)." || \
            echo "  WARNING: Could not remove at job #${DEAD_MAN_JOB_ID}. Check manually with 'atq'."
        echo ""
        echo "  Firewall is ACTIVE and CONFIRMED."
    else
        echo ""
        echo "  Dead man's switch remains active."
        echo "  Firewall will auto-disable in ~15 minutes."
        echo "  If you lose access, wait for auto-disable or use Hetzner console."
    fi
fi

echo ""
echo "Done."
