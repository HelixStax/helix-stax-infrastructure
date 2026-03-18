# Zero-Trust Network Deployment Runbook

**STRICT ORDERING** — Do not skip steps. Each step depends on the previous one succeeding.

**Target server**: VPS `5.78.145.30` (SSH port 2222)

---

## Prerequisites

Before starting, confirm:

- [ ] DNS A records live in Cloudflare for `auth.helixstax.net`, `vault.helixstax.net`, `vpn.helixstax.net` (all grey cloud, pointing to `5.78.145.30`)
- [ ] Authentik OAuth2 provider created (slug: `netbird`) with Client ID and Client Secret noted
- [ ] Authentik database backed up (see [authentik-backup-restore.md](authentik-backup-restore.md))
- [ ] Emergency Netbird setup key generated (long-lived, no expiry) and stored in Vaultwarden
- [ ] SSH access confirmed on port 2222
- [ ] Cloudflare API token created with `Zone:DNS:Edit` permission for `helixstax.net` zone

---

## Step 1: Generate Snakeoil Cert for Nginx Default Server

Nginx needs a cert to start on port 443, even for the default catch-all that returns 444. Generate a self-signed cert.

```bash
mkdir -p /opt/helix-stax/nginx/certs
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /opt/helix-stax/nginx/certs/snakeoil.key \
  -out /opt/helix-stax/nginx/certs/snakeoil.crt \
  -subj "/CN=localhost"
```

**Expected**: Two files created in `/opt/helix-stax/nginx/certs/`.

---

## Step 2: Deploy Nginx

```bash
cd /opt/helix-stax
docker compose -f docker-compose/nginx/docker-compose.yml up -d
```

**Verify**:
```bash
docker ps | grep nginx
# Should show nginx container running, ports 80 and 443 mapped

curl -I http://5.78.145.30
# Should return "444" or connection closed (default catch-all)
```

**Rollback**:
```bash
docker compose -f docker-compose/nginx/docker-compose.yml down
```

---

## Step 3: Issue Let's Encrypt Certificates

The certbot sidecar handles this, but if running manually:

```bash
docker exec certbot certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d auth.helixstax.net \
  -d vault.helixstax.net \
  -d vpn.helixstax.net \
  --agree-tos \
  --email admin@helixstax.com \
  --non-interactive
```

After certs are issued, reload Nginx:

```bash
docker exec nginx nginx -s reload
```

**Rollback**: Certs are non-destructive. If they fail, Nginx continues with snakeoil cert (443 still works, just untrusted).

---

## Step 4: Verify HTTPS

```bash
curl -I https://auth.helixstax.net
# Expected: HTTP/2 200 (or 302 redirect to login)

curl -I https://vault.helixstax.net
# Expected: HTTP/2 200
```

If either fails, check:
```bash
docker logs nginx --tail 50
docker logs certbot --tail 50
```

**Do NOT proceed until both return valid HTTPS responses.**

---

## Step 5: Apply Firewall

**CRITICAL**: Open a SECOND SSH session before running this. Keep it open. If the firewall locks you out, use the second session to disable it.

```bash
ADMIN_IP=$(echo $SSH_CLIENT | awk '{print $1}')
echo "Admin IP detected: $ADMIN_IP"
# Verify this is YOUR IP before proceeding

ADMIN_IP=$ADMIN_IP bash /opt/helix-stax/scripts/firewall-setup.sh
```

The script includes a dead man's switch: `at now + 15 min <<< 'ufw disable'`. If you cannot confirm access within 15 minutes, the firewall auto-disables.

**Rollback**:
```bash
ufw disable
```

**If locked out**: Use Hetzner web console at https://console.hetzner.cloud, open the VNC console for the VPS, and run:
```bash
ufw disable
```

---

## Step 6: Verify SSH (IMMEDIATELY)

From your SECOND terminal:

```bash
ssh -p 2222 root@5.78.145.30
# Must succeed
```

If this fails, you have 15 minutes before the dead man's switch reverts the firewall.

---

## Step 7: Cancel Dead Man's Switch

Once SSH is confirmed working:

```bash
# List scheduled jobs
atq

# Remove the ufw disable job (use the job number from atq output)
atrm <job_number>
```

**Verify**:
```bash
atq
# Should be empty
```

---

## Step 8: Update Netbird OIDC Configuration

Edit `management.json` with the Authentik OAuth2 provider details from the prerequisites.

```bash
cd /opt/helix-stax
# Edit docker-compose/netbird/management.json
# Replace empty OIDC fields with Authentik values:
#   HttpConfig.AuthIssuer = https://auth.helixstax.net/application/o/netbird/
#   HttpConfig.AuthAudience = <Client ID from Authentik>
#   HttpConfig.OIDCConfigEndpoint = https://auth.helixstax.net/application/o/netbird/.well-known/openid-configuration
#   PKCEAuthorizationFlow fields (ClientID, AuthorizationEndpoint, TokenEndpoint)
#   DeviceAuthorizationFlow fields (ClientID, DeviceAuthEndpoint, TokenEndpoint)
#   DisableDefaultPolicy = true

docker restart netbird-management
```

**Verify**:
```bash
docker logs netbird-management --tail 20
# Should show successful startup with no OIDC errors
```

**Rollback**:
```bash
# Restore original management.json from git
cd /opt/helix-stax
git checkout -- docker-compose/netbird/management.json
docker restart netbird-management
```

---

## Step 9: Update Netbird Dashboard Auth

Update the dashboard environment variables in `docker-compose/netbird/docker-compose.yml`:

```yaml
AUTH_AUTHORITY: https://auth.helixstax.net/application/o/netbird/
AUTH_CLIENT_ID: <Client ID from Authentik>
AUTH_REDIRECT_URI: https://vpn.helixstax.net/auth
AUTH_SILENT_REDIRECT_URI: https://vpn.helixstax.net/silent-auth
```

```bash
docker compose -f docker-compose/netbird/docker-compose.yml up -d
```

**Verify**: Open `https://vpn.helixstax.net` in browser. It should redirect to Authentik login, then to Google Workspace SSO.

**Rollback**:
```bash
git checkout -- docker-compose/netbird/docker-compose.yml
docker compose -f docker-compose/netbird/docker-compose.yml up -d
```

---

## Step 10: Enroll VPS as Netbird Peer

Install the Netbird client on the VPS and enroll it:

```bash
# Install netbird client (if not already installed)
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Enroll using SSO (opens browser — use the emergency setup key if headless)
netbird up --setup-key <emergency-setup-key>

# Note the assigned Netbird IP
netbird status
```

**Record the Netbird IP** (e.g., `100.64.0.1`). This is the `NETBIRD_IP` value for the next step.

**Rollback**:
```bash
netbird down
```

---

## Step 11: Rebind Private Services to Netbird IP

Update `.env` with the Netbird IP:

```bash
echo "NETBIRD_IP=<netbird-ip-from-step-10>" >> /opt/helix-stax/.env
```

Restart private services:

```bash
cd /opt/helix-stax
docker compose -f docker-compose/openbao/docker-compose.yml up -d
docker compose -f docker-compose/minio/docker-compose.yml up -d
```

**Verify — accessible over tunnel**:
```bash
# From your laptop (connected to Netbird):
curl -I http://<netbird-ip>:8200    # OpenBao
curl -I http://<netbird-ip>:9002    # MinIO API
curl -I http://<netbird-ip>:9003    # MinIO Console
```

**Verify — NOT accessible from public internet**:
```bash
# From any machine NOT on the Netbird mesh:
curl --connect-timeout 5 http://5.78.145.30:8200
# Expected: Connection refused or timeout

curl --connect-timeout 5 http://5.78.145.30:9002
# Expected: Connection refused or timeout
```

**Rollback**: Remove `NETBIRD_IP` from `.env` (services fall back to `127.0.0.1`), restart services.

---

## Step 12: Deploy Homepage Dashboard

```bash
cd /opt/helix-stax
docker compose -f docker-compose/homepage/docker-compose.yml up -d
```

**Verify**: From your laptop (over Netbird tunnel):
```bash
curl -I http://<netbird-ip>:3000
# Expected: HTTP/1.1 200
```

**Rollback**:
```bash
docker compose -f docker-compose/homepage/docker-compose.yml down
```

---

## Post-Deployment Verification Checklist

Run all of these after completing all steps:

```bash
# 1. Public services respond over HTTPS
curl -I https://auth.helixstax.net       # 200 or 302
curl -I https://vault.helixstax.net      # 200

# 2. Private services NOT reachable from public internet
curl --connect-timeout 5 http://5.78.145.30:8200    # timeout/refused
curl --connect-timeout 5 http://5.78.145.30:9002    # timeout/refused
curl --connect-timeout 5 http://5.78.145.30:3000    # timeout/refused

# 3. SSH still works
ssh -p 2222 root@5.78.145.30

# 4. Netbird tunnel works (from laptop)
ping <netbird-ip>

# 5. Private services reachable over tunnel (from laptop)
curl -I http://<netbird-ip>:8200   # OpenBao
curl -I http://<netbird-ip>:9002   # MinIO

# 6. Netbird SSO works
# Open https://vpn.helixstax.net → should redirect to Authentik → Google SSO

# 7. Port scan shows only expected ports
nmap 5.78.145.30
# Expected open: 80, 443, 2222, 3478, 10000, 33073, 33080

# 8. Emergency key works
# From a clean machine: netbird up --setup-key <emergency-key>
```

---

## Emergency Recovery

### Locked out of SSH

1. Go to https://console.hetzner.cloud
2. Select the VPS
3. Open VNC console
4. Login as root
5. Run: `ufw disable`
6. Fix the firewall rules
7. Re-enable: `ufw enable`

### Authentik is down

1. SSH into VPS (port 2222 — independent of Authentik)
2. Check containers: `docker ps | grep authentik`
3. Check logs: `docker logs authentik-server --tail 50`
4. If database issue, see [authentik-backup-restore.md](authentik-backup-restore.md)
5. For Netbird access without Authentik: use emergency setup key from Vaultwarden

### Netbird is down

1. SSH into VPS (port 2222 — independent of Netbird)
2. Check containers: `docker ps | grep netbird`
3. Restart: `docker compose -f docker-compose/netbird/docker-compose.yml restart`
4. If OIDC misconfigured: revert management.json from git, restart
