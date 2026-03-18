# Zero-Trust Network Architecture — Infrastructure Context

> **Phase**: PREPARE
> **Date**: 2026-03-17
> **Purpose**: Comprehensive inventory of all existing Docker Compose configs, port bindings, network topology, and OIDC state. Coding agents should treat this as the source of truth for current infrastructure state.

---

## 1. Docker Network Topology

### Network: `helix-net`

- **Defined in**: `docker-compose/docker-compose.yml`
- **Type**: Bridge network (`driver: bridge`)
- **Name**: `helix-net` (explicit `name: helix-net`)
- **Usage**: All services reference this as `external: true` in their own compose files, except the core compose file which creates it.

### Containers on `helix-net`

| Container Name | Service | Compose File |
|---------------|---------|--------------|
| `helix-postgres` | PostgreSQL 16 | `docker-compose/docker-compose.yml` |
| `helix-redis` | Redis 7 | `docker-compose/docker-compose.yml` |
| `authentik-server` | Authentik server | `docker-compose/authentik/docker-compose.yml` |
| `authentik-worker` | Authentik worker | `docker-compose/authentik/docker-compose.yml` |
| `vaultwarden` | Vaultwarden | `docker-compose/vaultwarden/docker-compose.yml` |
| `openbao` | OpenBao | `docker-compose/openbao/docker-compose.yml` |
| `minio` | MinIO | `docker-compose/minio/docker-compose.yml` |
| `netbird-dashboard` | Netbird Dashboard | `docker-compose/netbird/docker-compose.yml` |
| `netbird-signal` | Netbird Signal | `docker-compose/netbird/docker-compose.yml` |
| `netbird-management` | Netbird Management | `docker-compose/netbird/docker-compose.yml` |
| `netbird-relay` | Netbird Relay | `docker-compose/netbird/docker-compose.yml` |

### Container NOT on `helix-net`

| Container Name | Service | Network Mode | Why |
|---------------|---------|-------------|-----|
| `netbird-coturn` | Coturn STUN/TURN | `network_mode: host` | Needs direct UDP binding for relay traffic |

**Implication for Nginx**: Since Nginx will join `helix-net`, it can reach all containers by their container names (e.g., `authentik-server:9000`, `vaultwarden:80`). It cannot reach `netbird-coturn` by container name since coturn is on the host network.

**Implication for firewall**: UFW rules DO apply to `netbird-coturn` (host networking), but do NOT apply to bridged containers (Docker bypasses UFW via the DOCKER iptables chain). Port binding addresses (`127.0.0.1:` prefix) are the real access control for bridged containers.

---

## 2. Service Inventory

### 2.1 PostgreSQL (Core Data)

**File**: `docker-compose/docker-compose.yml`

| Property | Value |
|----------|-------|
| Image | `postgres:16-alpine` |
| Container name | `helix-postgres` |
| Port bindings | **None** (not exposed to host) |
| Network | `helix-net` |
| Restart | `unless-stopped` |
| Volumes | `postgres-data` → `/var/lib/postgresql/data` (bind mount to `/data/postgres`), `./postgres/init` → `/docker-entrypoint-initdb.d:ro` |
| Key env vars | `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=${POSTGRES_PASSWORD}`, `PGDATA=/var/lib/postgresql/data/pgdata` |
| Healthcheck | `pg_isready -U postgres` every 10s |
| Dependencies | None |

**Databases created by init script** (`postgres/init/00-create-databases.sql`):
- `authentik`, `harbor`, `harbor_notary_server`, `harbor_notary_signer`, `netbird`, `devtron`, `n8n`, `langfuse`

### 2.2 Redis (Core Data)

**File**: `docker-compose/docker-compose.yml`

| Property | Value |
|----------|-------|
| Image | `redis:7-alpine` |
| Container name | `helix-redis` |
| Port bindings | **None** (not exposed to host) |
| Network | `helix-net` |
| Restart | `unless-stopped` |
| Volumes | `redis-data` → `/data` (bind mount to `/data/redis`), `./redis/redis.conf` → `/usr/local/etc/redis/redis.conf:ro` |
| Key env vars | None in compose (password embedded in redis.conf at deploy time) |
| Healthcheck | `redis-cli -a "$REDIS_PASSWORD" ping` every 10s |
| Dependencies | None |

**Note**: Redis config template uses `REDIS_PASSWORD_PLACEHOLDER` which is replaced at deploy time. Bind address is `0.0.0.0` with `protected-mode yes`. Max memory: 512mb with `allkeys-lru` eviction.

### 2.3 Authentik (Identity Provider)

**File**: `docker-compose/authentik/docker-compose.yml`

#### authentik-server

| Property | Value |
|----------|-------|
| Image | `ghcr.io/goauthentik/server:2024.12.3` |
| Container name | `authentik-server` |
| Port bindings | **`127.0.0.1:9000:9000`**, **`127.0.0.1:9443:9443`** |
| Network | `helix-net` (external) |
| Restart | `unless-stopped` |
| Command | `server` |
| Volumes | `/data/authentik/media` → `/media`, `/data/authentik/templates` → `/templates` |
| Dependencies | `authentik-worker` |
| Healthcheck | `ak healthcheck` every 30s, start_period 60s |

Key environment variables:
```
AUTHENTIK_REDIS__HOST: helix-redis
AUTHENTIK_REDIS__PORT: 6379
AUTHENTIK_REDIS__PASSWORD: ${REDIS_PASSWORD}
AUTHENTIK_POSTGRESQL__HOST: helix-postgres
AUTHENTIK_POSTGRESQL__USER: postgres
AUTHENTIK_POSTGRESQL__NAME: authentik
AUTHENTIK_POSTGRESQL__PASSWORD: ${POSTGRES_PASSWORD}
AUTHENTIK_POSTGRESQL__PORT: 5432
AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
AUTHENTIK_ERROR_REPORTING__ENABLED: false
AUTHENTIK_BOOTSTRAP_EMAIL: admin@helixstax.com
AUTHENTIK_BOOTSTRAP_PASSWORD: ${AUTHENTIK_BOOTSTRAP_PASSWORD}
```

**Critical for Nginx proxy**: The container name for proxying is `authentik-server`, and it listens internally on port `9000` (HTTP) and `9443` (HTTPS). Nginx should proxy to `http://authentik-server:9000`.

#### authentik-worker

| Property | Value |
|----------|-------|
| Image | `ghcr.io/goauthentik/server:2024.12.3` |
| Container name | `authentik-worker` |
| Port bindings | **None** |
| Network | `helix-net` (external) |
| Restart | `unless-stopped` |
| Command | `worker` |
| Volumes | `/data/authentik/media` → `/media`, `/data/authentik/templates` → `/templates`, `/data/authentik/certs` → `/certs`, `/var/run/docker.sock` → `/var/run/docker.sock` |
| User | `root` (required for Docker socket access) |

### 2.4 Vaultwarden (Password Manager)

**File**: `docker-compose/vaultwarden/docker-compose.yml`

| Property | Value |
|----------|-------|
| Image | `vaultwarden/server:latest` |
| Container name | `vaultwarden` |
| Port bindings | **`127.0.0.1:8088:80`** |
| Network | `helix-net` (external) |
| Restart | `unless-stopped` |
| Volumes | `/data/vaultwarden` → `/data` |
| Memory limit | 256m |
| Healthcheck | `curl -f http://localhost:80/` every 30s |
| Dependencies | None |

Key environment variables:
```
DOMAIN: "https://vault.helixstax.com"      ← NEEDS UPDATE to https://vault.helixstax.net
SIGNUPS_ALLOWED: "false"
ADMIN_TOKEN: "${VAULTWARDEN_ADMIN_TOKEN}"
WEBSOCKET_ENABLED: "true"
```

**DOMAIN env var confirmation**: Currently set to `https://vault.helixstax.com`. The plan requires changing this to `https://vault.helixstax.net`.

**Nginx proxy target**: Container name `vaultwarden`, internal port `80`. Nginx should proxy to `http://vaultwarden:80`.

### 2.5 Harbor (Container Registry)

**File**: `docker-compose/harbor/harbor.yml`

**THIS IS NOT A DOCKER-COMPOSE FILE.** This is Harbor's installer configuration file (`harbor.yml`). Harbor's `install.sh` script reads this file and generates the actual `docker-compose.yml` at the install path (`/opt/harbor/` on VPS).

| Property | Value |
|----------|-------|
| Hostname | `harbor.helixstax.com` ← **NEEDS UPDATE to `harbor.helixstax.net`** |
| HTTP port | `8080` |
| HTTPS | Disabled (comments reference Traefik TLS termination) |
| external_url | Commented out (`# external_url: https://harbor.helixstax.com`) |
| Data volume | `/data/harbor` |
| Admin password | `CHANGE_ME` (placeholder — real value in `/opt/helix-stax/.env`) |

External database config:
```
host: helix-postgres
port: 5432
db_name: harbor
username: postgres
password: CHANGE_ME  # POSTGRES_PASSWORD from /opt/helix-stax/.env
ssl_mode: disable
```

External Redis config:
```
host: helix-redis:6379
password: CHANGE_ME  # REDIS_PASSWORD from /opt/helix-stax/.env
registry_db_index: 1
jobservice_db_index: 2
trivy_db_index: 5
```

**Important for coding agents**:
1. `harbor.yml` does NOT support `${ENV_VAR}` interpolation — it's a YAML file read by Harbor's Python installer, not by Docker Compose.
2. To change the hostname, you must either:
   - (a) Edit `harbor.yml` and re-run `/opt/harbor/install.sh` on the VPS, OR
   - (b) Directly edit the generated `docker-compose.yml` in `/opt/harbor/` on the VPS
3. Option (a) is the correct approach — it regenerates all derived configs consistently.
4. Harbor manages its own Docker Compose internally with multiple containers (core, portal, registry, jobservice, etc.) — these are NOT in this repo.

### 2.6 OpenBao (Secrets Management)

**File**: `docker-compose/openbao/docker-compose.yml`

| Property | Value |
|----------|-------|
| Image | `quay.io/openbao/openbao:latest` |
| Container name | `openbao` |
| Port bindings | **`127.0.0.1:8200:8200`** |
| Network | `helix-net` (external) |
| Restart | `unless-stopped` |
| Capabilities | `IPC_LOCK` |
| Volumes | `/data/openbao/data` → `/data/openbao/data`, `/opt/helix-stax/openbao/config.hcl` → `/vault/config/config.hcl:ro` |
| Command | `server -config=/vault/config/config.hcl` |
| Key env vars | `BAO_ADDR=http://127.0.0.1:8200` |
| Dependencies | None |

**OpenBao config.hcl**:
```hcl
ui = true

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "file" {
  path = "/data/openbao/data"
}

api_addr = "http://0.0.0.0:8200"
```

**Note**: Listener binds to `0.0.0.0:8200` inside the container, but the Docker port binding restricts host access to `127.0.0.1:8200`. The plan changes this to `${NETBIRD_IP:-127.0.0.1}:8200`.

### 2.7 MinIO (Object Storage)

**File**: `docker-compose/minio/docker-compose.yml`

| Property | Value |
|----------|-------|
| Image | `minio/minio:latest` |
| Container name | `minio` |
| Port bindings | **`127.0.0.1:9002:9000`** (API), **`127.0.0.1:9003:9001`** (Console) |
| Network | `helix-net` (external) |
| Restart | `unless-stopped` |
| Volumes | `/data/minio` → `/data` |
| Command | `server /data --console-address ":9001"` |
| Memory limit | 512m |
| Healthcheck | `curl -f http://localhost:9000/minio/health/live` every 30s |
| Dependencies | None |

Key environment variables:
```
MINIO_ROOT_USER: helix-minio-admin
MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
```

**Note**: Internal API port is 9000 (mapped to host 9002), internal console port is 9001 (mapped to host 9003). The plan changes binding to `${NETBIRD_IP:-127.0.0.1}:9002` and `${NETBIRD_IP:-127.0.0.1}:9003`.

### 2.8 Netbird (VPN / Zero-Trust Mesh)

**File**: `docker-compose/netbird/docker-compose.yml`

All Netbird services share a YAML anchor `x-default` for restart and logging config:
```yaml
x-default: &default
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "100m"
      max-file: "3"
```

#### netbird-dashboard

| Property | Value |
|----------|-------|
| Image | `netbirdio/dashboard:latest` |
| Container name | `netbird-dashboard` |
| Port bindings | **`33080:80`** (binds to `0.0.0.0`) |
| Network | `helix-net` (external) |
| Healthcheck | `curl -f http://localhost:80` every 30s |
| Dependencies | None |

Key environment variables:
```
NETBIRD_MGMT_API_ENDPOINT: http://5.78.145.30:33073
NETBIRD_MGMT_GRPC_API_ENDPOINT: http://5.78.145.30:33073
AUTH_AUDIENCE: (empty)
AUTH_CLIENT_ID: (empty)
AUTH_CLIENT_SECRET: (empty)
AUTH_AUTHORITY: (empty)
USE_AUTH0: false
AUTH_SUPPORTED_SCOPES: openid profile email offline_access api
AUTH_REDIRECT_URI: (empty)
AUTH_SILENT_REDIRECT_URI: (empty)
NETBIRD_TOKEN_SOURCE: accessToken
```

#### netbird-signal

| Property | Value |
|----------|-------|
| Image | `netbirdio/signal:latest` |
| Container name | `netbird-signal` |
| Port bindings | **`10000:80`** (binds to `0.0.0.0`) |
| Network | `helix-net` (external) |
| Volumes | `netbird-signal` → `/var/lib/netbird` (bind mount to `/data/netbird/signal`) |
| Command | `--log-file=console --log-level=info --port=80` |
| Healthcheck | `/usr/local/bin/netbird-signal health` every 30s |

#### netbird-management

| Property | Value |
|----------|-------|
| Image | `netbirdio/management:latest` |
| Container name | `netbird-management` |
| Port bindings | **`33073:33073`** (binds to `0.0.0.0`) |
| Network | `helix-net` (external) |
| Depends on | `netbird-dashboard` (condition: service_healthy) |
| Volumes | `netbird-mgmt` → `/var/lib/netbird` (bind mount to `/data/netbird/management`), `./management.json` → `/etc/netbird/management.json:ro` |
| Command | `--port=33073 --log-file=console --log-level=info --disable-anonymous-metrics=true --single-account-mode-domain=netbird.helixstax.com --dns-domain=netbird.helixstax.com` |
| Healthcheck | `curl -f http://localhost:33073/api/accounts` every 30s |

Key environment variables:
```
NETBIRD_STORE_ENGINE_POSTGRES_DSN: host=helix-postgres port=5432 user=postgres password=${POSTGRES_PASSWORD} dbname=netbird sslmode=disable
```

#### netbird-relay

| Property | Value |
|----------|-------|
| Image | `netbirdio/relay:latest` |
| Container name | `netbird-relay` |
| Port bindings | **`33080:33080`** (binds to `0.0.0.0`) |
| Network | `helix-net` (external) |

Key environment variables:
```
NB_LOG_LEVEL: info
NB_LISTEN_ADDRESS: :33080
NB_EXPOSED_ADDRESS: rel://5.78.145.30:33080
NB_AUTH_SECRET: ${NETBIRD_RELAY_SECRET}
```

#### netbird-coturn

| Property | Value |
|----------|-------|
| Image | `coturn/coturn:latest` |
| Container name | `netbird-coturn` |
| Network | **`network_mode: host`** (NOT on `helix-net`) |
| Volumes | `./turnserver.conf` → `/etc/turnserver.conf:ro` |
| Command | `-c /etc/turnserver.conf` |

---

## 3. Critical Findings

### 3.1 PORT 33080 COLLISION (CONFIRMED)

**Both `netbird-dashboard` and `netbird-relay` bind to host port 33080.**

```yaml
# netbird-dashboard
ports:
  - "33080:80"          # Dashboard HTTP on host port 33080

# netbird-relay
ports:
  - "33080:33080"       # Relay on host port 33080
```

**This is a real collision.** Docker Compose will fail to start both containers simultaneously on the same host port. One of them must move.

**Recommendation**: Move dashboard to a different host port (e.g., `33081:80` or bind to `127.0.0.1` only since it will be behind Nginx/Netbird anyway). The relay port must remain at 33080 because it is referenced in:
- `management.json` → `Relay.Addresses: ["rel://5.78.145.30:33080"]`
- `NB_EXPOSED_ADDRESS=rel://5.78.145.30:33080` env var

The dashboard is an HTTP UI that will go behind Nginx, so changing its host port is low-impact.

### 3.2 Publicly Bound Ports (Security Concern)

Several Netbird services bind to `0.0.0.0` (all interfaces), meaning they are accessible from the public internet without firewall rules:

| Service | Port Binding | Public? |
|---------|-------------|---------|
| netbird-dashboard | `33080:80` | YES — `0.0.0.0` |
| netbird-signal | `10000:80` | YES — `0.0.0.0` |
| netbird-management | `33073:33073` | YES — `0.0.0.0` |
| netbird-relay | `33080:33080` | YES — `0.0.0.0` |
| netbird-coturn | host networking | YES — port 3478 + 49152-65535 |

Services bound to `127.0.0.1` (localhost only, NOT publicly accessible):

| Service | Port Binding |
|---------|-------------|
| authentik-server | `127.0.0.1:9000:9000`, `127.0.0.1:9443:9443` |
| vaultwarden | `127.0.0.1:8088:80` |
| openbao | `127.0.0.1:8200:8200` |
| minio | `127.0.0.1:9002:9000`, `127.0.0.1:9003:9001` |

Services with NO port bindings (internal only, reachable only on `helix-net`):

| Service | Notes |
|---------|-------|
| helix-postgres | Reachable by container name on helix-net |
| helix-redis | Reachable by container name on helix-net |
| authentik-worker | No ports needed (background worker) |

### 3.3 Vaultwarden DOMAIN Env Var

**Current**: `DOMAIN: "https://vault.helixstax.com"`
**Planned**: `DOMAIN: "https://vault.helixstax.net"`

This is confirmed in `docker-compose/vaultwarden/docker-compose.yml` line 7.

### 3.4 Authentik Proxy Details

For Nginx to proxy to Authentik:
- **Container name**: `authentik-server`
- **Internal HTTP port**: `9000`
- **Internal HTTPS port**: `9443`
- **Proxy target**: `http://authentik-server:9000` (use HTTP since TLS is terminated at Nginx)
- **Host port binding**: `127.0.0.1:9000` (already localhost-only, correct for zero-trust)

### 3.5 Harbor Is Not Docker-Compose

`harbor.yml` is Harbor's installer config, NOT a docker-compose file. Key facts:
- **Current hostname**: `harbor.helixstax.com` (needs change to `harbor.helixstax.net`)
- **HTTP port**: `8080`
- **HTTPS**: Disabled
- **Does NOT support `${ENV_VAR}` interpolation** — this is a YAML config read by Harbor's Python installer
- The installer generates the actual docker-compose at `/opt/harbor/docker-compose.yml`
- To change settings: edit `harbor.yml`, then re-run `/opt/harbor/install.sh` on the VPS
- Harbor containers (core, portal, registry, jobservice, etc.) are managed by Harbor's own compose, not this repo

---

## 4. Netbird management.json — Full OIDC/Auth State

**File**: `docker-compose/netbird/management.json`

All authentication fields are currently **empty** — Netbird is running in setup-key-only mode with no OIDC provider.

### HttpConfig (Management API auth)

```json
"HttpConfig": {
    "Address": "0.0.0.0:33073",
    "AuthIssuer": "",              ← EMPTY — needs Authentik OIDC issuer URL
    "AuthAudience": "",            ← EMPTY — needs Authentik client ID
    "AuthKeysLocation": "",        ← EMPTY
    "AuthUserIDClaim": "",         ← EMPTY
    "CertFile": "",
    "CertKey": "",
    "IdpSignKeyRefreshEnabled": false,
    "OIDCConfigEndpoint": ""       ← EMPTY — needs Authentik OIDC discovery URL
}
```

### PKCEAuthorizationFlow (Browser/Dashboard login)

```json
"PKCEAuthorizationFlow": {
    "ProviderConfig": {
        "Audience": "",                    ← EMPTY
        "ClientID": "",                    ← EMPTY
        "ClientSecret": "",                ← EMPTY
        "Domain": "",                      ← EMPTY
        "AuthorizationEndpoint": "",       ← EMPTY
        "TokenEndpoint": "",               ← EMPTY
        "Scope": "openid profile email offline_access api",   ← POPULATED
        "RedirectURLs": [],                ← EMPTY
        "UseIDToken": false,
        "DisablePromptLogin": false,
        "LoginFlag": ""
    }
}
```

### DeviceAuthorizationFlow (CLI login)

```json
"DeviceAuthorizationFlow": {
    "Provider": "none",            ← Set to "none"
    "ProviderConfig": {
        "Audience": "",            ← EMPTY
        "AuthorizationEndpoint": "",
        "Domain": "",
        "ClientID": "",
        "ClientSecret": "",
        "TokenEndpoint": "",
        "DeviceAuthEndpoint": "",  ← EMPTY — needed for CLI flow
        "Scope": "openid",
        "UseIDToken": false,
        "RedirectURLs": null
    }
}
```

### IdpManagerConfig

```json
"IdpManagerConfig": {
    "ManagerType": "none",         ← Correctly "none" — Authentik has no built-in type
    "ClientConfig": {
        "Issuer": "",              ← EMPTY
        "TokenEndpoint": "",       ← EMPTY
        "ClientID": "",            ← EMPTY
        "ClientSecret": "",        ← EMPTY
        "GrantType": "client_credentials"
    },
    "ExtraConfig": {},
    "Auth0ClientCredentials": null,
    "AzureClientCredentials": null,
    "KeycloakClientCredentials": null,
    "ZitadelClientCredentials": null
}
```

### Other management.json fields

```json
"DisableDefaultPolicy": false      ← NEEDS CHANGE to true for zero-trust

"ReverseProxy": {
    "TrustedHTTPProxies": [],
    "TrustedHTTPProxiesCount": 0,
    "TrustedPeers": ["0.0.0.0/0"] ← NEEDS RESTRICTION to Nginx container subnet
}

"Relay": {
    "Addresses": ["rel://5.78.145.30:33080"],
    "CredentialsTTL": "24h",
    "Secret": "SEE /opt/helix-stax/.env NETBIRD_RELAY_SECRET"
}

"Signal": {
    "Proto": "http",
    "URI": "5.78.145.30:10000"
}

"Stuns": [{ "URI": "stun:5.78.145.30:3478" }]

"TURNConfig": {
    "Turns": [{ "URI": "turn:5.78.145.30:3478", "Username": "netbird" }],
    "CredentialsTTL": "12h",
    "TimeBasedCredentials": false
}
```

---

## 5. Coturn Configuration

**File**: `docker-compose/netbird/turnserver.conf`

| Property | Value |
|----------|-------|
| Listening port | `3478` (UDP + TCP) |
| TLS listening port | `5349` (but TLS is disabled: `no-tls`, `no-dtls`) |
| External IP | `5.78.145.30` |
| Relay port range | `49152-65535` |
| Realm | `netbird.helixstax.com` |
| Auth | Long-term credential mechanism (`lt-cred-mech`) |
| Static user | `netbird:SEE_ENV_NETBIRD_TURN_PASSWORD` (replaced at deploy time) |

---

## 6. Environment Variable Patterns

### Shared `.env.example` (root `docker-compose/`)

```
POSTGRES_PASSWORD=
REDIS_PASSWORD=
```

### Netbird `.env.example` (`docker-compose/netbird/`)

```
POSTGRES_PASSWORD=
NETBIRD_RELAY_SECRET=
NETBIRD_TURN_PASSWORD=
NETBIRD_TURN_SECRET=
NETBIRD_DATASTORE_ENC_KEY=
```

### Variables referenced across compose files but defined elsewhere

| Variable | Used By | Source |
|----------|---------|-------|
| `POSTGRES_PASSWORD` | Core, Authentik, Netbird | `.env` |
| `REDIS_PASSWORD` | Core, Authentik | `.env` |
| `AUTHENTIK_SECRET_KEY` | Authentik | `/opt/helix-stax/authentik.env` or `.env` |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | Authentik | `.env` |
| `VAULTWARDEN_ADMIN_TOKEN` | Vaultwarden | `.env` |
| `MINIO_ROOT_PASSWORD` | MinIO | `.env` |
| `NETBIRD_RELAY_SECRET` | Netbird relay | `netbird/.env` |

---

## 7. Port Summary (All Services)

### Host-facing ports

| Host Port | Bind Address | Service | Container Port | Protocol |
|-----------|-------------|---------|---------------|----------|
| 9000 | `127.0.0.1` | authentik-server | 9000 | TCP (HTTP) |
| 9443 | `127.0.0.1` | authentik-server | 9443 | TCP (HTTPS) |
| 8088 | `127.0.0.1` | vaultwarden | 80 | TCP (HTTP) |
| 8200 | `127.0.0.1` | openbao | 8200 | TCP (HTTP) |
| 9002 | `127.0.0.1` | minio (API) | 9000 | TCP |
| 9003 | `127.0.0.1` | minio (Console) | 9001 | TCP |
| 33080 | `0.0.0.0` | netbird-dashboard | 80 | TCP (COLLISION) |
| 33080 | `0.0.0.0` | netbird-relay | 33080 | TCP (COLLISION) |
| 10000 | `0.0.0.0` | netbird-signal | 80 | TCP |
| 33073 | `0.0.0.0` | netbird-management | 33073 | TCP |
| 3478 | host network | netbird-coturn | 3478 | UDP+TCP |
| 49152-65535 | host network | netbird-coturn | 49152-65535 | UDP |

### Internal-only (no host port, helix-net only)

| Service | Internal Port | Protocol |
|---------|-------------|----------|
| helix-postgres | 5432 | TCP |
| helix-redis | 6379 | TCP |
| authentik-worker | None | N/A |

---

## 8. Changes Required by Zero-Trust Plan

| File | Change | Detail |
|------|--------|--------|
| `vaultwarden/docker-compose.yml` | Update `DOMAIN` | `https://vault.helixstax.com` → `https://vault.helixstax.net` |
| `harbor/harbor.yml` | Update `hostname` | `harbor.helixstax.com` → `harbor.helixstax.net` |
| `openbao/docker-compose.yml` | Rebind port | `127.0.0.1:8200:8200` → `${NETBIRD_IP:-127.0.0.1}:8200:8200` |
| `minio/docker-compose.yml` | Rebind ports | `127.0.0.1:9002:9000` → `${NETBIRD_IP:-127.0.0.1}:9002:9000` (same for 9003) |
| `netbird/docker-compose.yml` | Fix port collision | Move dashboard from `33080:80` to different port (e.g., `33081:80`) |
| `netbird/docker-compose.yml` | Update dashboard auth env vars | Populate `AUTH_AUTHORITY`, `AUTH_CLIENT_ID`, `AUTH_REDIRECT_URI`, `AUTH_SILENT_REDIRECT_URI` |
| `netbird/docker-compose.yml` | Update MGMT endpoint | `http://5.78.145.30:33073` → `https://vpn.helixstax.net` |
| `netbird/management.json` | Populate OIDC fields | HttpConfig, PKCEAuthorizationFlow, DeviceAuthorizationFlow — all empty |
| `netbird/management.json` | Disable default policy | `DisableDefaultPolicy: false` → `true` |
| `netbird/management.json` | Restrict trusted peers | `TrustedPeers: ["0.0.0.0/0"]` → Nginx container subnet only |
| NEW | `nginx/docker-compose.yml` | Nginx reverse proxy + certbot on `helix-net` |
| NEW | `scripts/firewall-setup.sh` | UFW + Docker iptables rules |
| NEW | `homepage/docker-compose.yml` | Homepage dashboard on Netbird-only |

---

## 9. Dependency Graph

```
helix-postgres ← authentik-server (DB)
               ← authentik-worker (DB)
               ← harbor (external_database)
               ← netbird-management (NETBIRD_STORE_ENGINE_POSTGRES_DSN)

helix-redis    ← authentik-server (cache)
               ← authentik-worker (cache)
               ← harbor (external_redis)

authentik-worker ← authentik-server (depends_on)

netbird-dashboard ← netbird-management (depends_on, condition: service_healthy)

netbird-management ← netbird-signal (configured in management.json)
                   ← netbird-relay (configured in management.json)
                   ← netbird-coturn (configured in management.json)
```

---

## 10. Volumes Summary

| Volume | Host Path | Container Path | Used By |
|--------|-----------|---------------|---------|
| `postgres-data` | `/data/postgres` | `/var/lib/postgresql/data` | helix-postgres |
| `redis-data` | `/data/redis` | `/data` | helix-redis |
| `netbird-mgmt` | `/data/netbird/management` | `/var/lib/netbird` | netbird-management |
| `netbird-signal` | `/data/netbird/signal` | `/var/lib/netbird` | netbird-signal |
| (bind mount) | `/data/authentik/media` | `/media` | authentik-server, authentik-worker |
| (bind mount) | `/data/authentik/templates` | `/templates` | authentik-server, authentik-worker |
| (bind mount) | `/data/authentik/certs` | `/certs` | authentik-worker |
| (bind mount) | `/data/vaultwarden` | `/data` | vaultwarden |
| (bind mount) | `/data/openbao/data` | `/data/openbao/data` | openbao |
| (bind mount) | `/data/minio` | `/data` | minio |
| (bind mount) | `/data/harbor` | varies | harbor (data_volume) |
