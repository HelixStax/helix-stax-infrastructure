#!/usr/bin/env bash
# grafana-oidc-setup.sh
# Configures Grafana OIDC SSO with Zitadel on the Helix Stax cluster.
#
# PREREQUISITES:
#   - SSH access to helix-stax-cp (178.156.233.12, port 2222)
#   - iam-admin PAT stored in IAM_ADMIN_PAT env var
#   - Grafana OIDC client credentials stored in GRAFANA_CLIENT_ID and
#     GRAFANA_CLIENT_SECRET env vars (obtained in Step 1)
#
# USAGE:
#   Step 1 (create Zitadel OIDC client):
#     IAM_ADMIN_PAT="..." bash grafana-oidc-setup.sh create-oidc-client
#
#   Step 2 (create K8s secret + helm upgrade):
#     GRAFANA_CLIENT_ID="..." GRAFANA_CLIENT_SECRET="..." bash grafana-oidc-setup.sh deploy
#
#   Or run full sequence (requires both env vars set):
#     IAM_ADMIN_PAT="..." GRAFANA_CLIENT_ID="..." GRAFANA_CLIENT_SECRET="..." \
#       bash grafana-oidc-setup.sh all

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(dirname "$SCRIPT_DIR")/helm/monitoring"

CP_HOST="178.156.233.12"
CP_PORT="2222"
CP_USER="wakeem"
CP_SSH="ssh -i ~/.ssh/helixstax_key -p $CP_PORT $CP_USER@$CP_HOST"
KUBECTL="sudo /usr/local/bin/k3s kubectl"

ZITADEL_URL="https://zitadel.helixstax.net"
ZITADEL_PROJECT_ID="365717240378556639"

NAMESPACE="monitoring"
SECRET_NAME="grafana-zitadel-oauth"
HELM_RELEASE="monitoring"
HELM_CHART="prometheus-community/kube-prometheus-stack"
HELM_VALUES="$HELM_DIR/values-prometheus-stack.yaml"
INGRESSROUTE="$HELM_DIR/grafana-ingressroute.yaml"

# ---------------------------------------------------------------------------
create_oidc_client() {
    echo "==> Step 1: Creating Grafana OIDC client in Zitadel..."
    : "${IAM_ADMIN_PAT:?IAM_ADMIN_PAT must be set}"

    RESPONSE=$(curl -sf \
        -X POST \
        -H "Authorization: Bearer $IAM_ADMIN_PAT" \
        -H "Content-Type: application/json" \
        "$ZITADEL_URL/management/v1/projects/$ZITADEL_PROJECT_ID/apps/oidc" \
        -d '{
            "name": "grafana",
            "redirectUris": ["https://grafana.helixstax.net/login/generic_oauth"],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
            "appType": "OIDC_APP_TYPE_WEB",
            "authMethodType": "OIDC_AUTH_METHOD_TYPE_POST",
            "postLogoutRedirectUris": ["https://grafana.helixstax.net"],
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
        echo "[ERROR] Failed to extract clientId/clientSecret from response:"
        echo "$RESPONSE"
        exit 1
    fi

    local CREDS_FILE="/tmp/grafana-oidc-credentials"
    printf 'GRAFANA_CLIENT_ID=%s\nGRAFANA_CLIENT_SECRET=%s\n' "$CLIENT_ID" "$CLIENT_SECRET" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"

    echo "==> OIDC client created successfully."
    echo "    CLIENT_ID: $CLIENT_ID"
    echo "    Credentials written to $CREDS_FILE (chmod 600). Delete after use."
    echo ""
    echo "    Set these for the next step:"
    echo "      export GRAFANA_CLIENT_ID='$CLIENT_ID'"
    echo "      export GRAFANA_CLIENT_SECRET=\$(grep ^GRAFANA_CLIENT_SECRET $CREDS_FILE | cut -d= -f2)"
}

# ---------------------------------------------------------------------------
create_k8s_secret() {
    echo "==> Step 2: Creating grafana-zitadel-oauth secret in $NAMESPACE namespace..."
    : "${GRAFANA_CLIENT_ID:?GRAFANA_CLIENT_ID must be set}"
    : "${GRAFANA_CLIENT_SECRET:?GRAFANA_CLIENT_SECRET must be set}"

    # Pass secrets as env vars prepended to the remote command so the heredoc
    # body is quoted ('EOF') and never expanded by the local shell.
    $CP_SSH "GRAFANA_CLIENT_ID='$GRAFANA_CLIENT_ID' GRAFANA_CLIENT_SECRET='$GRAFANA_CLIENT_SECRET' bash -s" << 'EOF'
set -euo pipefail
KUBECTL="sudo /usr/local/bin/k3s kubectl"
SECRET_NAME="grafana-zitadel-oauth"
NAMESPACE="monitoring"

# Delete existing secret if present (idempotent)
$KUBECTL delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true

$KUBECTL create secret generic "$SECRET_NAME" \
    -n "$NAMESPACE" \
    --from-literal=client-id="$GRAFANA_CLIENT_ID" \
    --from-literal=client-secret="$GRAFANA_CLIENT_SECRET"

echo "Secret $SECRET_NAME created in namespace $NAMESPACE"
$KUBECTL get secret "$SECRET_NAME" -n "$NAMESPACE" --no-headers
EOF
}

# ---------------------------------------------------------------------------
helm_upgrade() {
    echo "==> Step 3: Copying Helm values to CP and running helm upgrade..."

    # Copy updated values file to CP
    scp -P "$CP_PORT" -i ~/.ssh/helixstax_key \
        "$HELM_VALUES" \
        "$CP_USER@$CP_HOST:/tmp/values-prometheus-stack.yaml"

    $CP_SSH bash -s << 'EOF'
set -euo pipefail

sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f /tmp/values-prometheus-stack.yaml \
    --wait \
    --timeout 5m

echo "Helm upgrade complete"
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm status monitoring -n monitoring | grep -E "STATUS|DEPLOYED|LAST DEPLOYED"
rm -f /tmp/values-prometheus-stack.yaml
EOF
}

# ---------------------------------------------------------------------------
apply_ingressroute() {
    echo "==> Step 4: Applying Grafana IngressRoute..."

    scp -P "$CP_PORT" -i ~/.ssh/helixstax_key \
        "$INGRESSROUTE" \
        "$CP_USER@$CP_HOST:/tmp/grafana-ingressroute.yaml"

    $CP_SSH bash -s << 'EOF'
set -euo pipefail
sudo /usr/local/bin/k3s kubectl apply -f /tmp/grafana-ingressroute.yaml
echo "IngressRoute applied:"
sudo /usr/local/bin/k3s kubectl get ingressroute grafana -n monitoring
rm -f /tmp/grafana-ingressroute.yaml
EOF
}

# ---------------------------------------------------------------------------
verify_dns() {
    echo "==> Step 5: Checking Cloudflare DNS for grafana.helixstax.net..."

    CNAME=$(dig +short grafana.helixstax.net CNAME 2>/dev/null || true)
    if echo "$CNAME" | grep -q "cfargotunnel.com"; then
        echo "    CNAME -> $CNAME (Cloudflare tunnel routing confirmed)"
    else
        echo "[WARN] grafana.helixstax.net CNAME not pointing to cfargotunnel.com"
        echo "       Current: $CNAME"
        echo "       Run on CP to add DNS route:"
        echo "         cloudflared tunnel route dns helix-k3s-main grafana.helixstax.net"
    fi
}

# ---------------------------------------------------------------------------
verify_grafana() {
    echo "==> Step 6: Verifying Grafana is accessible..."

    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" https://grafana.helixstax.net/login 2>/dev/null || echo "unreachable")
    echo "    https://grafana.helixstax.net/login -> HTTP $HTTP_STATUS"

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ]; then
        echo "    Grafana is reachable."
        echo ""
        echo "    Manual verification required:"
        echo "    1. Open https://grafana.helixstax.net in browser"
        echo "    2. Confirm 'Sign in with Zitadel' button is visible"
        echo "    3. Log in as admin@helixstax.com — should get GrafanaAdmin role"
        echo "    4. Confirm local admin login (admin / helix-temp-password) still works"
    else
        echo "[WARN] Grafana not reachable at https://grafana.helixstax.net"
        echo "       Check IngressRoute and Cloudflare tunnel config."
    fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    create-oidc-client) create_oidc_client ;;
    create-secret)      create_k8s_secret ;;
    helm-upgrade)       helm_upgrade ;;
    apply-ingressroute) apply_ingressroute ;;
    verify-dns)         verify_dns ;;
    verify)             verify_grafana ;;
    deploy)
        create_k8s_secret
        helm_upgrade
        apply_ingressroute
        verify_dns
        verify_grafana
        ;;
    all)
        create_oidc_client
        create_k8s_secret
        helm_upgrade
        apply_ingressroute
        verify_dns
        verify_grafana
        ;;
    *)
        echo "Usage: $0 {create-oidc-client|create-secret|helm-upgrade|apply-ingressroute|verify-dns|verify|deploy|all}"
        echo ""
        echo "  create-oidc-client  -- Create Zitadel OIDC app (requires IAM_ADMIN_PAT)"
        echo "  create-secret       -- Create K8s secret (requires GRAFANA_CLIENT_ID + GRAFANA_CLIENT_SECRET)"
        echo "  helm-upgrade        -- Run helm upgrade with updated values"
        echo "  apply-ingressroute  -- Apply Traefik IngressRoute"
        echo "  verify-dns          -- Check Cloudflare DNS CNAME"
        echo "  verify              -- Check Grafana HTTP status"
        echo "  deploy              -- Steps 2-6 (secret + helm + ingressroute + dns + verify)"
        echo "  all                 -- All steps 1-6"
        exit 1
        ;;
esac

echo ""
echo "Done."
