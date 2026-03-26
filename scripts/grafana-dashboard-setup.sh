#!/usr/bin/env bash
# grafana-dashboard-setup.sh
# Bootstrap Grafana community dashboards as ConfigMaps for persistent provisioning.
#
# Run on: control plane node (178.156.233.12)
# Required: python3, kubectl (k3s), internet access to grafana.com
#
# Usage:
#   scp -P 2222 scripts/grafana-dashboard-setup.sh wakeem@178.156.233.12:/tmp/
#   ssh -p 2222 wakeem@178.156.233.12 'bash /tmp/grafana-dashboard-setup.sh'
#
set -euo pipefail

KUBECTL="sudo /usr/local/bin/k3s kubectl"
NAMESPACE="monitoring"
WORK_DIR="/tmp/grafana-dashboards"
mkdir -p "$WORK_DIR"

echo "=== Grafana Dashboard Bootstrap ==="
echo "Downloading community dashboards from grafana.com..."

python3 << 'PYEOF'
import json, urllib.request, ssl, os, subprocess

ctx = ssl.create_default_context()
WORK_DIR = "/tmp/grafana-dashboards"
KUBECTL = "sudo /usr/local/bin/k3s kubectl"

def fetch_dashboard(gnet_id):
    url = f"https://grafana.com/api/dashboards/{gnet_id}/revisions/latest/download"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return r.read().decode()

def create_dashboard_configmap(filepath, folder, cm_name, namespace):
    filename = os.path.basename(filepath)

    # Delete if exists (idempotent)
    subprocess.run(
        KUBECTL.split() + ["delete", "configmap", cm_name, "-n", namespace, "--ignore-not-found=true"],
        capture_output=True
    )

    # Create from file
    result = subprocess.run(
        KUBECTL.split() + ["create", "configmap", cm_name, "-n", namespace, f"--from-file={filename}={filepath}"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  CREATE ERROR: {result.stderr[:200]}")
        return False

    # Add required label
    subprocess.run(
        KUBECTL.split() + ["label", "configmap", cm_name, "-n", namespace, "grafana_dashboard=1", "--overwrite"],
        capture_output=True
    )

    # Add folder annotation
    subprocess.run(
        KUBECTL.split() + ["annotate", "configmap", cm_name, "-n", namespace, f"grafana_folder={folder}", "--overwrite"],
        capture_output=True
    )
    return True

# Dashboard definitions: (grafana.com ID, local filename, Grafana folder, ConfigMap name)
DASHBOARDS = [
    (1860,  "node-exporter-full.json",          "Infrastructure", "helix-stax-node-exporter-full"),
    (17346, "traefik-official-standalone.json",  "Networking",     "helix-stax-traefik-dashboard"),
    (20417, "cloudnativepg.json",               "Database",       "helix-stax-cloudnativepg-dashboard"),
    (9628,  "postgresql-database.json",          "Database",       "helix-stax-postgresql-dashboard"),
    (14584, "argocd.json",                       "CI-CD",          "helix-stax-argocd-dashboard"),
    (19974, "argocd-app-overview.json",          "CI-CD",          "helix-stax-argocd-app-overview"),
]

for gnet_id, filename, folder, cm_name in DASHBOARDS:
    filepath = os.path.join(WORK_DIR, filename)
    print(f"[{gnet_id}] {filename} -> folder: {folder}")

    if not os.path.exists(filepath):
        print(f"  Fetching from grafana.com...")
        content = fetch_dashboard(gnet_id)
        with open(filepath, "w") as f:
            f.write(content)
        print(f"  Downloaded ({len(content)} chars)")
    else:
        print(f"  Using cached file")

    ok = create_dashboard_configmap(filepath, folder, cm_name, "monitoring")
    print(f"  ConfigMap: {'OK' if ok else 'FAILED'}")

print("")
print("Bootstrap complete. Grafana sidecar will reload dashboards within 30s.")
PYEOF

echo ""
echo "=== Verifying ConfigMaps ==="
sudo /usr/local/bin/k3s kubectl get configmap -n monitoring -l grafana_dashboard=1 \
    -o custom-columns='NAME:.metadata.name,FOLDER:.metadata.annotations.grafana_folder' 2>/dev/null

echo ""
echo "=== Done ==="
echo "Dashboards will appear in Grafana at https://grafana.helixstax.net within ~30 seconds."
