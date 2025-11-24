#!/usr/bin/env bash

###############################################################################
# Create Azure Authentication Secret for Kubernetes
#
# Creates a Kubernetes secret with Azure CLI access token for local development
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

print_banner "Azure Authentication Setup"

# Get Azure account info
print_step 1 "Retrieving Azure credentials"
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
ACCESS_TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)

if [ -z "$TENANT_ID" ] || [ -z "$SUBSCRIPTION_ID" ] || [ -z "$ACCESS_TOKEN" ]; then
  print_error "Failed to retrieve Azure credentials. Please run 'az login' first."
  exit 1
fi

print_info "Tenant ID: $TENANT_ID"
print_info "Subscription ID: $SUBSCRIPTION_ID"
print_success "Access token retrieved"

# Create Kubernetes secret
print_step 2 "Creating Kubernetes secret"

kubectl delete secret azure-credentials -n default 2>/dev/null || true

kubectl create secret generic azure-credentials \
  --from-literal=AZURE_ACCESS_TOKEN="$ACCESS_TOKEN" \
  --from-literal=AZURE_TENANT_ID="$TENANT_ID" \
  --from-literal=AZURE_SUBSCRIPTION_ID="$SUBSCRIPTION_ID" \
  -n default

print_success "Secret 'azure-credentials' created successfully"

# Restart deployment if it exists
print_step 3 "Updating deployment"
if kubectl get deployment stt-service -n default &>/dev/null; then
  print_info "Restarting deployment to pick up new credentials..."
  kubectl rollout restart deployment/stt-service -n default
  print_success "Deployment restarted"
else
  print_warning "Deployment not found. Deploy using: make deploy-local"
fi

print_banner "Setup Complete!"
cat << EOF

Azure CLI credentials configured for Kubernetes.
Note: Access tokens expire after ~1 hour. Re-run this command if authentication fails.

To verify:
  kubectl logs -l app=stt-service --tail=50

EOF
