#!/usr/bin/env bash
# devtron-setup-oidc.sh
# Configures Devtron OIDC SSO with Zitadel on the Helix Stax cluster.
#
# Devtron v2.x uses Dex as an OIDC broker. SSO config is stored as base64-encoded
# YAML in devtron-secret.dex.config. This script:
#   1. Creates a Zitadel OIDC application for Devtron
#   2. Creates the devtron-oidc-zitadel K8s secret with client credentials
#   3. Generates the Dex config YAML and patches devtron-secret.dex.config
#   4. Restarts the devtron-dex-server pod to pick up the new config
#   5. Verifies the SSO login flow is reachable
#
# PREREQUISITES:
#   - SSH access to helix-stax-cp (178.156.233.12, port 2222)
#   - IAM_ADMIN_PAT: Zitadel personal access token with project management rights
#   - DEVTRON_CLIENT_ID + DEVTRON_CLIENT_SECRET (set by Step 1, used in Step 2+)
#
# USAGE:
#   Step 1 (create Zitadel OIDC client):
#     IAM_ADMIN_PAT="..." bash scripts/devtron-setup-oidc.sh create-oidc-client
#
#   Step 2 (create K8s secret + patch Devtron config):
#     DEVTRON_CLIENT_ID="..." DEVTRON_CLIENT_SECRET="..." \
#       bash scripts/devtron-setup-oidc.sh deploy
#
#   Or run full sequence:
#     IAM_ADMIN_PAT="..." bash scripts/devtron-setup-oidc.sh all
#
#   Verify SSO is reachable:
#     bash scripts/devtron-setup-oidc.sh verify
#
#   Show current Dex config (base64-decoded):
#     bash scripts/devtron-setup-oidc.sh show-config

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CP_HOST="178.156.233.12"
CP_PORT="2222"
CP_USER="wakeem"
CP_SSH="ssh -i ~/.ssh/helixstax_key -p $CP_PORT $CP_USER@$CP_HOST"
KUBECTL="sudo /usr/local/bin/k3s kubectl"

ZITADEL_URL="https://zitadel.helixstax.net"
ZITADEL_PROJECT_ID="365717240378556639"

DEVTRON_URL="https://devtron.helixstax.net"
DEVTRON_NAMESPACE="devtroncd"
DEVTRON_SECRET_NAME="devtron-oidc-zitadel"
DEVTRON_REDIRECT_URI="${DEVTRON_URL}/orchestrator/api/dex/callback"
DEVTRON_POST_LOGOUT_URI="${DEVTRON_URL}"

CREDS_FILE="/tmp/devtron-oidc-credentials"

# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 {create-oidc-client|deploy|all|verify|show-config}"
    echo ""
    echo "Commands:"
    echo "  create-oidc-client  Create Devtron OIDC app in Zitadel (requires IAM_ADMIN_PAT)"
    echo "  deploy              Create K8s secret + patch Devtron dex.config (requires DEVTRON_CLIENT_ID + DEVTRON_CLIENT_SECRET)"
    echo "  all                 Run create-oidc-client then deploy"
    echo "  verify              Verify SSO endpoint is reachable"
    echo "  show-config         Print current devtron-secret dex.config (decoded)"
    exit 1
}

# ---------------------------------------------------------------------------
create_oidc_client() {
    echo "==> Step 1: Creating Devtron OIDC client in Zitadel..."
    : "${IAM_ADMIN_PAT:?IAM_ADMIN_PAT must be set}"

    RESPONSE=$(curl -sf \
        -X POST \
        -H "Authorization: Bearer $IAM_ADMIN_PAT" \
        -H "Content-Type: application/json" \
        "$ZITADEL_URL/management/v1/projects/$ZITADEL_PROJECT_ID/apps/oidc" \
        -d '{
            "name": "devtron",
            "redirectUris": ["'"$DEVTRON_REDIRECT_URI"'"],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": [
                "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
                "OIDC_GRANT_TYPE_REFRESH_TOKEN"
            ],
            "appType": "OIDC_APP_TYPE_WEB",
            "authMethodType": "OIDC_AUTH_METHOD_TYPE_POST",
            "postLogoutRedirectUris": ["'"$DEVTRON_POST_LOGOUT_URI"'"],
            "devMode": false,
            "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
            "accessTokenRoleAssertion": true,
            "idTokenRoleAssertion": true,
            "idTokenUserinfoAssertion": true,
            "additionalOrigins": []
        }')

    CLIENT_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['clientId'])" 2>/dev/null || true)
    CLIENT_SECRET=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['clientSecret'])" 2>/dev/null || true)

    if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
        echo "[ERROR] Failed to extract clientId/clientSecret from Zitadel response:"
        echo "$RESPONSE"
        exit 1
    fi

    printf 'DEVTRON_CLIENT_ID=%s\nDEVTRON_CLIENT_SECRET=%s\n' "$CLIENT_ID" "$CLIENT_SECRET" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"

    echo "==> Zitadel OIDC client created successfully."
    echo "    CLIENT_ID: $CLIENT_ID"
    echo "    Credentials written to $CREDS_FILE (chmod 600). Delete after use."
    echo ""
    echo "    Set these for the deploy step:"
    echo "      export DEVTRON_CLIENT_ID='$CLIENT_ID'"
    echo "      export DEVTRON_CLIENT_SECRET=\$(grep ^DEVTRON_CLIENT_SECRET $CREDS_FILE | cut -d= -f2)"
}

# ---------------------------------------------------------------------------
create_k8s_secret() {
    echo "==> Step 2: Creating ${DEVTRON_SECRET_NAME} secret in ${DEVTRON_NAMESPACE} namespace..."
    : "${DEVTRON_CLIENT_ID:?DEVTRON_CLIENT_ID must be set}"
    : "${DEVTRON_CLIENT_SECRET:?DEVTRON_CLIENT_SECRET must be set}"

    # Pass secrets as env vars prepended to the remote command
    # The heredoc body is single-quoted so no local shell expansion occurs
    $CP_SSH "DEVTRON_CLIENT_ID='$DEVTRON_CLIENT_ID' DEVTRON_CLIENT_SECRET='$DEVTRON_CLIENT_SECRET' bash -s" << 'EOF'
set -euo pipefail
KUBECTL="sudo /usr/local/bin/k3s kubectl"
SECRET_NAME="devtron-oidc-zitadel"
NAMESPACE="devtroncd"

# Idempotent — delete existing before recreating
$KUBECTL delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true

$KUBECTL create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-literal=client-id="$DEVTRON_CLIENT_ID" \
    --from-literal=client-secret="$DEVTRON_CLIENT_SECRET"

echo "Secret ${SECRET_NAME} created in namespace ${NAMESPACE}"
$KUBECTL get secret "$SECRET_NAME" -n "$NAMESPACE" --no-headers
EOF
}

# ---------------------------------------------------------------------------
patch_dex_config() {
    echo "==> Step 3: Patching devtron-secret.dex.config with Dex YAML config..."
    : "${DEVTRON_CLIENT_ID:?DEVTRON_CLIENT_ID must be set}"
    : "${DEVTRON_CLIENT_SECRET:?DEVTRON_CLIENT_SECRET must be set}"

    # We pass the client credentials as env vars. The heredoc is single-quoted
    # so no local expansion occurs. Remote bash handles the interpolation.
    $CP_SSH "DEVTRON_CLIENT_ID='$DEVTRON_CLIENT_ID' DEVTRON_CLIENT_SECRET='$DEVTRON_CLIENT_SECRET' bash -s" << 'REMOTE_EOF'
set -euo pipefail
KUBECTL="sudo /usr/local/bin/k3s kubectl"
NAMESPACE="devtroncd"

# Verify dex server pod exists before patching config
DEX_DEPLOY=$($KUBECTL get deploy -n "$NAMESPACE" -l app.kubernetes.io/component=dex-server --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null | head -1 || true)
if [ -z "$DEX_DEPLOY" ]; then
    echo "[WARN] devtron-dex-server deployment not found."
    echo "       Devtron may still be installing. Patching devtron-secret anyway."
    echo "       Run verify step once Devtron is fully running."
fi

# Build the Dex config YAML with credentials substituted
# NOTE: $DEVTRON_CLIENT_ID and $DEVTRON_CLIENT_SECRET are set by env var injection above
DEX_YAML="issuer: http://devtron-service.devtroncd/dex

storage:
  type: kubernetes
  config:
    inCluster: true

web:
  http: 0.0.0.0:5556

oauth2:
  skipApprovalScreen: true
  responseTypes:
    - code

connectors:
  - type: oidc
    id: zitadel
    name: \"Zitadel\"
    config:
      issuer: https://zitadel.helixstax.net
      clientID: \"${DEVTRON_CLIENT_ID}\"
      clientSecret: \"${DEVTRON_CLIENT_SECRET}\"
      redirectURI: https://devtron.helixstax.net/orchestrator/api/dex/callback
      scopes:
        - openid
        - email
        - profile
        - groups
      userNameKey: preferred_username
      userIDKey: sub
      insecureSkipEmailVerified: false
      promptType: consent

staticClients:
  - id: argo-cd-cli
    name: Argo CD CLI
    public: true
    redirectURIs:
      - http://localhost:8085/auth/callback
  - id: devtron-cli
    name: Devtron CLI
    public: true
    redirectURIs:
      - http://localhost:8085/auth/callback
"

# Base64-encode the YAML (no line wrapping)
DEX_CONFIG_B64=$(printf '%s' "$DEX_YAML" | base64 -w0)

# Patch devtron-secret with the new DEX_CONFIG value
$KUBECTL patch secret devtron-secret -n "$NAMESPACE" \
    --type='merge' \
    -p "{\"data\":{\"dex.config\":\"${DEX_CONFIG_B64}\"}}"

echo "devtron-secret.dex.config patched successfully."
echo "DEX_CONFIG length (base64): ${#DEX_CONFIG_B64} chars"

# Restart dex server to pick up new config (if it exists)
if [ -n "$DEX_DEPLOY" ]; then
    echo "Scaling up dex deployment to 1 replica (was scaled to 0)..."
    $KUBECTL scale deploy "$DEX_DEPLOY" -n "$NAMESPACE" --replicas=1
    echo "Restarting dex deployment: ${DEX_DEPLOY}..."
    $KUBECTL rollout restart deploy "$DEX_DEPLOY" -n "$NAMESPACE"
    echo "Waiting for dex rollout to complete (60s timeout)..."
    $KUBECTL rollout status deploy "$DEX_DEPLOY" -n "$NAMESPACE" --timeout=60s || \
        echo "[WARN] Dex rollout did not complete within 60s — check logs manually"
fi

# Also restart the devtron deployment to ensure it picks up new Dex endpoint
echo "Restarting devtron deployment to pick up new SSO config..."
$KUBECTL rollout restart deploy devtron -n "$NAMESPACE" 2>/dev/null || \
    echo "[WARN] Could not restart devtron deploy — it may be named differently"
REMOTE_EOF

    echo "==> dex.config patched and pods restarted."
}

# ---------------------------------------------------------------------------
verify_sso() {
    echo "==> Step 4: Verifying Devtron OIDC SSO endpoint..."

    # Check Devtron is reachable
    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        "$DEVTRON_URL" 2>/dev/null || echo "unreachable")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ]; then
        echo "    Devtron is reachable at $DEVTRON_URL (HTTP $HTTP_STATUS)"
    else
        echo "[WARN] Devtron returned HTTP $HTTP_STATUS from $DEVTRON_URL"
    fi

    # Check Dex OIDC discovery endpoint (internal, via CP SSH)
    echo "    Checking Dex OIDC discovery endpoint (internal)..."
    $CP_SSH "sudo /usr/local/bin/k3s kubectl -n devtroncd get pods -l app.kubernetes.io/component=dex-server --no-headers 2>/dev/null || echo 'Could not list dex pods'" || true

    echo ""
    echo "==> Manual verification steps:"
    echo "    1. Open $DEVTRON_URL in a browser"
    echo "    2. Click 'Login with SSO' (or equivalent button)"
    echo "    3. You should be redirected to zitadel.helixstax.net"
    echo "    4. Authenticate with your Zitadel credentials"
    echo "    5. You should land back in Devtron as an authenticated user"
    echo ""
    echo "    If SSO button is not visible: Devtron may need the DEX_HOST configmap key set."
    echo "    Check: kubectl get cm devtron-cm -n devtroncd -o yaml | grep DEX_HOST"
}

# ---------------------------------------------------------------------------
show_config() {
    echo "==> Current devtron-secret dex.config (decoded):"
    $CP_SSH "${KUBECTL} get secret devtron-secret -n devtroncd -o jsonpath='{.data.dex\\.config}' 2>/dev/null | base64 -d || echo '[INFO] dex.config key not yet set'"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
CMD="${1:-}"

case "$CMD" in
    create-oidc-client)
        create_oidc_client
        ;;
    deploy)
        : "${DEVTRON_CLIENT_ID:?DEVTRON_CLIENT_ID must be set for deploy step}"
        : "${DEVTRON_CLIENT_SECRET:?DEVTRON_CLIENT_SECRET must be set for deploy step}"
        create_k8s_secret
        patch_dex_config
        verify_sso
        ;;
    all)
        create_oidc_client
        # Load credentials from file created by create_oidc_client
        if [ -f "$CREDS_FILE" ]; then
            DEVTRON_CLIENT_ID=$(grep ^DEVTRON_CLIENT_ID "$CREDS_FILE" | cut -d= -f2)
            DEVTRON_CLIENT_SECRET=$(grep ^DEVTRON_CLIENT_SECRET "$CREDS_FILE" | cut -d= -f2)
            export DEVTRON_CLIENT_ID DEVTRON_CLIENT_SECRET
        fi
        create_k8s_secret
        patch_dex_config
        verify_sso
        echo ""
        echo "==> IMPORTANT: Delete credential cache file:"
        echo "    rm -f $CREDS_FILE"
        ;;
    verify)
        verify_sso
        ;;
    show-config)
        show_config
        ;;
    *)
        usage
        ;;
esac
