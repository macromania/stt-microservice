#!/usr/bin/env bash

set -euo pipefail

# Import Grafana dashboard into Grafana via API
# This script wraps the dashboard JSON in the proper Grafana API format

NAMESPACE="${NAMESPACE:-default}"

echo "Importing STT dashboard to Grafana..."

# Get Grafana pod
GRAFANA_POD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=grafana -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)

if [ -z "$GRAFANA_POD" ]; then
  echo "Error: Grafana pod not found in namespace '${NAMESPACE}'"
  echo "Make sure Grafana is deployed: kubectl get pods -l app.kubernetes.io/name=grafana -n ${NAMESPACE}"
  exit 1
fi

echo "Found Grafana pod: ${GRAFANA_POD}"

# Get script directory to find dashboard JSON
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASHBOARD_FILE="${PROJECT_ROOT}/k8s/grafana-dashboard.json"

if [ ! -f "${DASHBOARD_FILE}" ]; then
  echo "Error: Dashboard file not found at ${DASHBOARD_FILE}"
  exit 1
fi

echo "Copying dashboard to pod..."
kubectl cp "${DASHBOARD_FILE}" "${NAMESPACE}/${GRAFANA_POD}:/tmp/dashboard-raw.json"

# Get Grafana admin password
GRAFANA_PASSWORD=$(kubectl get secret -n "${NAMESPACE}" kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)

echo "Wrapping dashboard in API format..."
kubectl exec -n "${NAMESPACE}" "${GRAFANA_POD}" -- sh -c 'echo "{\"dashboard\": $(cat /tmp/dashboard-raw.json), \"overwrite\": true, \"message\": \"Updated via script\"}" > /tmp/dashboard.json'

echo "Importing via Grafana API..."
IMPORT_RESULT=$(kubectl exec -n "${NAMESPACE}" "${GRAFANA_POD}" -- curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "admin:${GRAFANA_PASSWORD}" \
  -d @/tmp/dashboard.json \
  http://localhost:3000/api/dashboards/db)

# Check result
if echo "$IMPORT_RESULT" | grep -q '"status":"success"'; then
  echo "✅ Dashboard imported successfully"
  echo "Access it at: http://localhost:3000/dashboards"
  exit 0
else
  echo "⚠️  Dashboard import may have failed"
  echo "Response: ${IMPORT_RESULT}"
  echo ""
  echo "You can manually import the dashboard:"
  echo "  1. Open Grafana: kubectl port-forward -n ${NAMESPACE} svc/kube-prometheus-stack-grafana 3000:80"
  echo "  2. Go to http://localhost:3000"
  echo "  3. Navigate to Dashboards > Import"
  echo "  4. Upload ${DASHBOARD_FILE}"
  exit 1
fi
