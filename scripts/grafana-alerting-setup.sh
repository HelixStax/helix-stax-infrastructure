#!/usr/bin/env bash
# grafana-alerting-setup.sh
# Configure Grafana alerting (contact points, notification policies, mute timings,
# service accounts) via the Grafana HTTP API.
#
# Must be run AFTER each Grafana pod restart (persistence=false wipes the database).
# Idempotent: safe to run multiple times.
#
# Run on: any host with curl and access to grafana.helixstax.net
#
# Usage:
#   GRAFANA_PASS=<admin-password> bash scripts/grafana-alerting-setup.sh
#
# Or with defaults (reads password from k8s secret if run on CP node):
#   bash scripts/grafana-alerting-setup.sh
#
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-https://grafana.helixstax.net}"
GRAFANA_USER="${GRAFANA_USER:-admin}"

# Resolve password: env var > k8s secret > prompt
if [ -z "${GRAFANA_PASS:-}" ]; then
  if command -v kubectl &>/dev/null || command -v k3s &>/dev/null; then
    KUBECTL="${KUBECTL:-sudo /usr/local/bin/k3s kubectl}"
    GRAFANA_PASS=$(${KUBECTL} get secret monitoring-grafana -n monitoring \
      -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d) || true
  fi
fi

if [ -z "${GRAFANA_PASS:-}" ]; then
  echo "ERROR: Set GRAFANA_PASS environment variable"
  exit 1
fi

GRAFANA_AUTH="${GRAFANA_USER}:${GRAFANA_PASS}"
TOKEN_FILE="${TOKEN_FILE:-/home/wakeem/grafana-service-tokens.txt}"

echo "=== Grafana Alerting Setup ==="
echo "URL: ${GRAFANA_URL}"

# Helper: call Grafana API
gapi() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [ -n "$data" ]; then
    curl -sf -u "$GRAFANA_AUTH" -X "$method" "${GRAFANA_URL}${path}" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -sf -u "$GRAFANA_AUTH" -X "$method" "${GRAFANA_URL}${path}"
  fi
}

# Helper: check if resource exists by name
contact_point_exists() {
  gapi GET "/api/v1/provisioning/contact-points" 2>/dev/null | \
    python3 -c "import sys,json; cps=json.load(sys.stdin); print('yes' if any(c['name']=='$1' for c in cps) else 'no')"
}

service_account_exists() {
  gapi GET "/api/serviceaccounts/search" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if any(s['name']=='$1' for s in d.get('serviceAccounts',[])) else 'no')"
}

# ─── 1. Contact Points ────────────────────────────────────────────────────────

echo ""
echo "-- Contact Points --"

if [ "$(contact_point_exists 'n8n-webhook')" = "no" ]; then
  gapi POST "/api/v1/provisioning/contact-points" '{
    "name": "n8n-webhook",
    "type": "webhook",
    "settings": {
      "url": "https://n8n.helixstax.net/webhook/grafana-alerts",
      "httpMethod": "POST",
      "maxAlerts": 10
    },
    "disableResolveMessage": false
  }' > /dev/null
  echo "  Created: n8n-webhook"
else
  echo "  Exists: n8n-webhook"
fi

# Rocket.Chat placeholder — update URL when RC is deployed
# Find the webhook URL in RC: Admin > Integrations > Incoming Webhook
if [ "$(contact_point_exists 'rocketchat-webhook')" = "no" ]; then
  gapi POST "/api/v1/provisioning/contact-points" '{
    "name": "rocketchat-webhook",
    "type": "webhook",
    "settings": {
      "url": "https://chat.helixstax.net/hooks/PLACEHOLDER_CONFIGURE_WHEN_DEPLOYED",
      "httpMethod": "POST"
    },
    "disableResolveMessage": false
  }' > /dev/null
  echo "  Created: rocketchat-webhook (PLACEHOLDER — update URL when Rocket.Chat is deployed)"
else
  echo "  Exists: rocketchat-webhook"
fi

# ─── 2. Notification Policies ─────────────────────────────────────────────────

echo ""
echo "-- Notification Policies --"

gapi PUT "/api/v1/provisioning/policies" '{
  "receiver": "n8n-webhook",
  "group_by": ["grafana_folder", "alertname", "cluster", "namespace"],
  "group_wait": "30s",
  "group_interval": "5m",
  "repeat_interval": "4h",
  "routes": [
    {
      "receiver": "rocketchat-webhook",
      "object_matchers": [
        ["severity", "=", "critical"]
      ],
      "group_wait": "10s",
      "group_interval": "2m",
      "repeat_interval": "1h",
      "continue": false
    }
  ]
}' > /dev/null
echo "  Updated: default -> n8n-webhook, severity=critical -> rocketchat-webhook"

# ─── 3. Mute Timings ──────────────────────────────────────────────────────────

echo ""
echo "-- Mute Timings --"

EXISTING_MUTE=$(gapi GET "/api/v1/provisioning/mute-timings" 2>/dev/null | \
  python3 -c "import sys,json; mts=json.load(sys.stdin); print('yes' if any(m['name']=='sunday-maintenance' for m in mts) else 'no')")

if [ "$EXISTING_MUTE" = "no" ]; then
  gapi POST "/api/v1/provisioning/mute-timings" '{
    "name": "sunday-maintenance",
    "time_intervals": [
      {
        "times": [{"start_time": "02:00", "end_time": "04:00"}],
        "weekdays": ["sunday"],
        "location": "UTC"
      }
    ]
  }' > /dev/null
  echo "  Created: sunday-maintenance (Sunday 02:00-04:00 UTC)"
else
  echo "  Exists: sunday-maintenance"
fi

# ─── 4. Service Accounts ──────────────────────────────────────────────────────

echo ""
echo "-- Service Accounts --"

create_sa_token() {
  local sa_name="$1"
  local token_name="$2"
  local role="${3:-Editor}"

  if [ "$(service_account_exists "$sa_name")" = "no" ]; then
    sa_id=$(gapi POST "/api/serviceaccounts" \
      "{\"name\": \"${sa_name}\", \"role\": \"${role}\", \"isDisabled\": false}" | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "  Created SA: ${sa_name} (id: ${sa_id})"
  else
    sa_id=$(gapi GET "/api/serviceaccounts/search" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); [print(s['id']) for s in d.get('serviceAccounts',[]) if s['name']=='${sa_name}']")
    echo "  Exists SA: ${sa_name} (id: ${sa_id})"
  fi

  # Create a new token (tokens are not idempotent — always create fresh)
  token=$(gapi POST "/api/serviceaccounts/${sa_id}/tokens" \
    "{\"name\": \"${token_name}\"}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")
  echo "    Token: ${token}"
  echo "${sa_name^^}_TOKEN=${token}" >> /tmp/grafana_new_tokens.txt
}

rm -f /tmp/grafana_new_tokens.txt

create_sa_token "n8n-sa" "n8n-alerts-token" "Editor"
create_sa_token "devtron-sa" "devtron-annotations-token" "Editor"

# Write tokens to secure file
if [ -f /tmp/grafana_new_tokens.txt ]; then
  {
    echo "# Grafana Service Account Tokens — Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# chmod 600 — Never commit to git."
    echo "# Recreated after each Grafana pod restart."
    echo ""
    cat /tmp/grafana_new_tokens.txt
    echo ""
    echo "# Annotation API (use DEVTRON_SA token for deploy events):"
    echo "# curl -H 'Authorization: Bearer \${DEVTRON_SA_TOKEN}' \\"
    echo "#      -H 'Content-Type: application/json' \\"
    echo "#      -X POST ${GRAFANA_URL}/api/annotations \\"
    echo "#      -d '{\"dashboardId\":0,\"time\":\$(date +%s000),\"text\":\"Deployed: <service> via Devtron\",\"tags\":[\"deploy\",\"<service>\"]}'"
  } > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  rm -f /tmp/grafana_new_tokens.txt
  echo "  Tokens written to: ${TOKEN_FILE} (chmod 600)"
fi

# ─── 5. Folders ───────────────────────────────────────────────────────────────
# Note: Infrastructure, Database, Networking, CI-CD are provisioned via ConfigMaps.
# These API-created folders are for manual dashboards only.

echo ""
echo "-- Additional Folders --"

for folder_name in "Identity" "Security" "AI" "Platform" "Monitoring" "Applications"; do
  EXISTING=$(gapi GET "/api/folders" 2>/dev/null | \
    python3 -c "import sys,json; fs=json.load(sys.stdin); print('yes' if any(f['title']=='${folder_name}' for f in fs) else 'no')")
  if [ "$EXISTING" = "no" ]; then
    gapi POST "/api/folders" "{\"title\": \"${folder_name}\"}" > /dev/null
    echo "  Created: ${folder_name}"
  else
    echo "  Exists: ${folder_name}"
  fi
done

echo ""
echo "=== Setup complete ==="
echo "Note: API-configured items (contact points, policies, SAs) are recreated"
echo "      after each Grafana pod restart. Run this script after upgrades."
