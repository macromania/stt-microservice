#!/usr/bin/env bash

###############################################################################
# Create Azure Credentials Secret for Kubernetes
#
# This script creates a Kubernetes secret with Azure Service Principal
# credentials for authenticating to Azure services from the pod.
#
# Usage:
#   ./scripts/create-azure-secret.sh
###############################################################################

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

###############################################################################
# Main Script
###############################################################################

print_banner "Azure Credentials Secret Setup"

# Get Azure account info
print_step 1 "Retrieving Azure account information"
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

if [ -z "$TENANT_ID" ] || [ -z "$SUBSCRIPTION_ID" ]; then
  print_error "Failed to retrieve Azure account information. Please run 'az login' first."
  exit 1
fi

print_info "Tenant ID: $TENANT_ID"
print_info "Subscription ID: $SUBSCRIPTION_ID"

# Get or create service principal
print_step 2 "Setting up Service Principal"
SP_NAME="stt-microservice-local-dev"

print_info "Checking if service principal exists..."
SP_APP_ID=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [ -z "$SP_APP_ID" ]; then
  print_info "Creating new service principal..."
  
  # Get resource group name from .env
  RESOURCE_NAME=$(grep STT_AZURE_SPEECH_RESOURCE_NAME .env | cut -d'=' -f2)
  REGION=$(grep STT_AZURE_SPEECH_REGION .env | cut -d'=' -f2)
  
  if [ -z "$RESOURCE_NAME" ] || [ -z "$REGION" ]; then
    print_error "Could not find Azure resource information in .env file"
    exit 1
  fi
  
  # Find the resource group
  RG_NAME=$(az cognitiveservices account list --query "[?name=='$RESOURCE_NAME'].resourceGroup" -o tsv)
  
  if [ -z "$RG_NAME" ]; then
    print_error "Could not find resource group for $RESOURCE_NAME"
    exit 1
  fi
  
  SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NAME"
  
  # Create service principal without role assignment first (to avoid policy issues)
  print_info "Creating service principal (app registration)..."
  SP_OUTPUT=$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --skip-assignment \
    --output json)
  
  if [ $? -ne 0 ]; then
    print_error "Failed to create service principal"
    exit 1
  fi
  
  SP_APP_ID=$(echo "$SP_OUTPUT" | jq -r '.appId')
  SP_PASSWORD=$(echo "$SP_OUTPUT" | jq -r '.password')
  
  print_success "Service principal created: $SP_APP_ID"
  
  # Assign Cognitive Services User role
  print_info "Assigning Cognitive Services User role..."
  az role assignment create \
    --assignee "$SP_APP_ID" \
    --role "Cognitive Services User" \
    --scope "$SCOPE" \
    --output none
  
  # Also assign Speech User role
  print_info "Assigning Cognitive Services Speech User role..."
  az role assignment create \
    --assignee "$SP_APP_ID" \
    --role "Cognitive Services Speech User" \
    --scope "$SCOPE" \
    --output none
  
  print_success "Roles assigned successfully"
else
  print_info "Service principal already exists: $SP_APP_ID"
  print_warning "If you need to reset the password, delete the secret and service principal first:"
  print_warning "  kubectl delete secret azure-credentials"
  print_warning "  az ad sp delete --id $SP_APP_ID"
  
  # Check if secret already exists
  if kubectl get secret azure-credentials -n default &>/dev/null; then
    print_success "Secret 'azure-credentials' already exists in cluster"
    print_info "To recreate, delete it first: kubectl delete secret azure-credentials"
    exit 0
  fi
  
  print_error "Service principal exists but password is not available."
  print_error "Please either:"
  print_error "  1. Delete and recreate: az ad sp delete --id $SP_APP_ID && ./scripts/create-azure-secret.sh"
  print_error "  2. Reset credentials: az ad sp credential reset --id $SP_APP_ID"
  exit 1
fi

# Create Kubernetes secret
print_step 3 "Creating Kubernetes secret"

kubectl delete secret azure-credentials -n default 2>/dev/null || true

kubectl create secret generic azure-credentials \
  --from-literal=AZURE_CLIENT_ID="$SP_APP_ID" \
  --from-literal=AZURE_CLIENT_SECRET="$SP_PASSWORD" \
  --from-literal=AZURE_TENANT_ID="$TENANT_ID" \
  -n default

print_success "Secret 'azure-credentials' created successfully"

# Verify deployment is configured
print_step 4 "Verification"
print_info "Checking deployment configuration..."

if kubectl get deployment stt-service -n default &>/dev/null; then
  print_info "Restarting deployment to pick up new credentials..."
  kubectl rollout restart deployment/stt-service -n default
  print_success "Deployment restarted"
else
  print_warning "Deployment not found. Deploy using: ./scripts/deploy-local.sh"
fi

print_banner "Setup Complete!"
cat << EOF

The following environment variables will be available in your pod:
  - AZURE_CLIENT_ID: Service Principal Application ID
  - AZURE_CLIENT_SECRET: Service Principal Password
  - AZURE_TENANT_ID: Azure Tenant ID

DefaultAzureCredential will automatically use these for authentication.

To verify:
  kubectl logs -l app=stt-service --tail=50

EOF
