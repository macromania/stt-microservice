#!/usr/bin/env bash

###############################################################################
# Azure Container Apps Deployment Script
#
# This script builds Docker images, pushes them to Azure Container Registry,
# and updates existing Container Apps with the new images.
#
# Prerequisites:
# - Run ./scripts/provision.sh first to create infrastructure and container apps
# - Azure CLI installed and logged in
# - Docker installed and running
#
# Features:
# - Fast image-only updates (no infrastructure changes)
# - Builds Python and Java STT services
# - Pushes images to ACR
# - Updates existing Container Apps with new images
# - Generates env.remote with service URLs
#
# Usage:
#   ./scripts/deploy-azure.sh
###############################################################################

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

###############################################################################
# Configuration
###############################################################################

readonly ENV_FILE=".env"
readonly ENV_REMOTE_FILE="env.remote"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PYTHON_CONTEXT="${PROJECT_ROOT}"
readonly JAVA_CONTEXT="${PROJECT_ROOT}/stt-java-service"

# App names (must match provision.sh)
readonly PYTHON_APP_NAME="stt-python"
readonly JAVA_APP_NAME="stt-java"

# Image tags
readonly IMAGE_TAG="${IMAGE_TAG:-latest}"

###############################################################################
# Helper Functions
###############################################################################

# Load configuration from .env file
load_configuration() {
  print_step 1 "Loading Configuration"
  
  if [ ! -f "${ENV_FILE}" ]; then
    exit_error "Configuration file '${ENV_FILE}' not found. Please run ./scripts/provision.sh first" 1
  fi
  
  # Source the .env file
  set -a
  source "${ENV_FILE}"
  set +a
  
  # Validate required variables
  local required_vars=(
    "APP_ENV"
    "STT_AZURE_SPEECH_RESOURCE_NAME"
    "STT_AZURE_SPEECH_REGION"
    "AZURE_CONTAINER_REGISTRY"
    "AZURE_CONTAINER_APPS_ENVIRONMENT"
    "AZURE_MANAGED_IDENTITY_PYTHON"
    "AZURE_MANAGED_IDENTITY_JAVA"
    "AZURE_CONTAINER_APP_PYTHON"
    "AZURE_CONTAINER_APP_JAVA"
  )
  
  for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
      exit_error "Required variable '${var}' not found in ${ENV_FILE}" 1
    fi
  done
  
  print_success "Configuration loaded successfully"
  print_info "Environment: ${APP_ENV}"
  print_info "Region: ${STT_AZURE_SPEECH_REGION}"
  print_info "Container Registry: ${AZURE_CONTAINER_REGISTRY}"
  echo ""
}

# Get resource group from ACR name
get_resource_group() {
  print_progress "Detecting resource group..." >&2
  
  local rg_name
  rg_name=$(az acr show --name "${AZURE_CONTAINER_REGISTRY}" --query "resourceGroup" -o tsv 2>/dev/null) || {
    exit_error "Failed to find resource group for ACR '${AZURE_CONTAINER_REGISTRY}'. Ensure infrastructure is provisioned." 1
  }
  
  print_success "Resource group: ${rg_name}" >&2
  echo "${rg_name}"
}

# Login to Azure Container Registry
acr_login() {
  print_step 2 "Authenticating with Azure Container Registry"
  
  print_progress "Logging in to ACR '${AZURE_CONTAINER_REGISTRY}'..."
  az acr login --name "${AZURE_CONTAINER_REGISTRY}" || {
    exit_error "Failed to login to ACR. Ensure you have access and Docker is running." 1
  }
  
  print_success "Successfully authenticated with ACR"
  echo ""
}

# Build and push Python service image
build_and_push_python() {
  local acr_login_server="$1"
  
  print_step 2 "Building Python STT Service"
  
  local image_name="${acr_login_server}/${PYTHON_APP_NAME}:${IMAGE_TAG}"
  
  print_info "Image: ${image_name}"
  print_info "Context: ${PYTHON_CONTEXT}"
  print_info "Dockerfile: ${PYTHON_CONTEXT}/src/Dockerfile"
  echo ""
  
  print_progress "Building and pushing Python image to ACR (native linux/amd64)..."
  az acr build \
    --registry "${AZURE_CONTAINER_REGISTRY}" \
    --image "${PYTHON_APP_NAME}:${IMAGE_TAG}" \
    --file "${PYTHON_CONTEXT}/src/Dockerfile" \
    --platform linux/amd64 \
    "${PYTHON_CONTEXT}" || {
    exit_error "Failed to build and push Python image" 1
  }
  
  print_success "Python image pushed: ${image_name}"
  echo ""
}

# Build and push Java service image
build_and_push_java() {
  local acr_login_server="$1"
  
  print_step 3 "Building Java STT Service"
  
  local image_name="${acr_login_server}/${JAVA_APP_NAME}:${IMAGE_TAG}"
  
  print_info "Image: ${image_name}"
  print_info "Context: ${JAVA_CONTEXT}"
  print_info "Dockerfile: ${JAVA_CONTEXT}/Dockerfile"
  echo ""
  
  print_progress "Building and pushing Java image to ACR (native linux/amd64)..."
  az acr build \
    --registry "${AZURE_CONTAINER_REGISTRY}" \
    --image "${JAVA_APP_NAME}:${IMAGE_TAG}" \
    --file "${JAVA_CONTEXT}/Dockerfile" \
    --platform linux/amd64 \
    "${JAVA_CONTEXT}" || {
    exit_error "Failed to build and push Java image" 1
  }
  
  print_success "Java image pushed: ${image_name}"
  echo ""
}

# Update Python Container App with new image
update_python_app() {
  local rg_name="$1"
  local acr_login_server="$2"
  
  print_step 4 "Updating Python STT Container App"
  
  local image_name="${acr_login_server}/${PYTHON_APP_NAME}:${IMAGE_TAG}"
  local app_name="${AZURE_CONTAINER_APP_PYTHON}"
  
  print_info "App: ${app_name}" >&2
  print_info "Image: ${image_name}" >&2
  print_info "Resource Group: ${rg_name}" >&2
  echo "" >&2
  
  # Debug: Check what we're looking for
  print_progress "Verifying container app exists..." >&2
  
  # Verify app exists (should have been created by provision.sh)
  if ! az containerapp show --name "${app_name}" --resource-group "${rg_name}" --query "name" -o tsv >/dev/null 2>&1; then
    exit_error "Container app '${app_name}' not found in resource group '${rg_name}'. Please run ./scripts/provision.sh first" 1
  fi
  
  print_success "Container app found" >&2
  
  # Get managed identity client ID for DefaultAzureCredential
  print_progress "Retrieving managed identity client ID..." >&2
  local client_id
  client_id=$(az identity show --name "${AZURE_MANAGED_IDENTITY_PYTHON}" --resource-group "${rg_name}" --query "clientId" -o tsv 2>/dev/null) || {
    exit_error "Failed to retrieve client ID for managed identity '${AZURE_MANAGED_IDENTITY_PYTHON}'" 1
  }
  print_info "Client ID: ${client_id}" >&2
  
  print_progress "Updating container app with new image..." >&2
  az containerapp update \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --image "${image_name}" \
    --min-replicas 1 \
    --max-replicas 3 \
    --set-env-vars \
      "APP_ENV=dev" \
      "ENABLE_PROCESS_ISOLATED=false" \
      "APP_LOG_LEVEL=${APP_LOG_LEVEL:-INFO}" \
      "STT_AZURE_SPEECH_RESOURCE_NAME=${STT_AZURE_SPEECH_RESOURCE_NAME}" \
      "STT_AZURE_SPEECH_REGION=${STT_AZURE_SPEECH_REGION}" \
      "STT_MAX_FILE_SIZE_MB=${STT_MAX_FILE_SIZE_MB:-100}" \
      "STT_MAX_DURATION_MINUTES=${STT_MAX_DURATION_MINUTES:-120}" \
      "AZURE_CLIENT_ID=${client_id}" || {
    exit_error "Failed to update container app '${app_name}'" 1
  }
  
  # Update ingress target port separately
  print_progress "Updating ingress target port to 8000..." >&2
  az containerapp ingress update \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --target-port 8000 || {
    exit_error "Failed to update ingress for '${app_name}'" 1
  }
  
  print_success "Container app updated: ${app_name}" >&2
  
  # Get the FQDN
  print_progress "Retrieving service URL..." >&2
  local fqdn
  fqdn=$(az containerapp show \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || {
    exit_error "Failed to retrieve FQDN for '${app_name}'" 1
  }
  
  if [ -z "${fqdn}" ]; then
    exit_error "FQDN is empty for container app '${app_name}'" 1
  fi
  
  print_success "Python service URL: https://${fqdn}" >&2
  echo "${fqdn}"
}

# Update Java Container App with new image
update_java_app() {
  local rg_name="$1"
  local acr_login_server="$2"
  
  print_step 5 "Updating Java STT Container App"
  
  local image_name="${acr_login_server}/${JAVA_APP_NAME}:${IMAGE_TAG}"
  local app_name="${AZURE_CONTAINER_APP_JAVA}"
  
  print_info "App: ${app_name}" >&2
  print_info "Image: ${image_name}" >&2
  print_info "Resource Group: ${rg_name}" >&2
  echo "" >&2
  
  # Debug: Check what we're looking for
  print_progress "Verifying container app exists..." >&2
  
  # Verify app exists (should have been created by provision.sh)
  if ! az containerapp show --name "${app_name}" --resource-group "${rg_name}" --query "name" -o tsv 2>&1; then
    exit_error "Container app '${app_name}' not found in resource group '${rg_name}'. Please run ./scripts/provision.sh first" 1
  fi
  
  print_success "Container app found"
  
  # Get managed identity client ID for DefaultAzureCredential
  print_progress "Retrieving managed identity client ID..."
  local client_id
  client_id=$(az identity show --name "${AZURE_MANAGED_IDENTITY_JAVA}" --resource-group "${rg_name}" --query "clientId" -o tsv 2>/dev/null) || {
    exit_error "Failed to retrieve client ID for managed identity '${AZURE_MANAGED_IDENTITY_JAVA}'" 1
  }
  print_info "Client ID: ${client_id}"
  
  print_progress "Updating container app with new image..."
  az containerapp update \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --image "${image_name}" \
    --min-replicas 1 \
    --max-replicas 3 \
    --set-env-vars \
      "APP_ENV=${APP_ENV}" \
      "STT_AZURE_SPEECH_RESOURCE_NAME=${STT_AZURE_SPEECH_RESOURCE_NAME}" \
      "STT_AZURE_SPEECH_REGION=${STT_AZURE_SPEECH_REGION}" \
      "AZURE_CLIENT_ID=${client_id}" || {
    exit_error "Failed to update container app '${app_name}'" 1
  }
  
  # Update ingress target port separately
  print_progress "Updating ingress target port to 8080..."
  az containerapp ingress update \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --target-port 8080 || {
    exit_error "Failed to update ingress for '${app_name}'" 1
  }
  
  print_success "Container app updated: ${app_name}"
  
  # Get the FQDN
  print_progress "Retrieving service URL..."
  local fqdn
  fqdn=$(az containerapp show \
    --name "${app_name}" \
    --resource-group "${rg_name}" \
    --query "properties.configuration.ingress.fqdn" -o tsv) || {
    exit_error "Failed to retrieve FQDN for '${app_name}'" 1
  }
  
  if [ -z "${fqdn}" ]; then
    exit_error "FQDN is empty for container app '${app_name}'" 1
  fi
  
  print_success "Java service URL: https://${fqdn}"
  echo "${fqdn}"
}

# Generate env.remote file with service URLs
generate_remote_env() {
  local python_fqdn="$1"
  local java_fqdn="$2"
  
  print_step 6 "Generating Remote Environment Configuration"
  
  if [ -f "${ENV_REMOTE_FILE}" ]; then
    print_warning "Existing ${ENV_REMOTE_FILE} file found"
    local backup_file="${ENV_REMOTE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${ENV_REMOTE_FILE}" "${backup_file}"
    print_info "Backup created: ${backup_file}"
  fi
  
  cat > "${ENV_REMOTE_FILE}" << EOF
# Azure Container Apps Remote Configuration
# Generated by deploy-azure.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#
# These URLs point to deployed services in Azure Container Apps
# Use these for load testing and external access

# Python STT Service
PYTHON_STT_SERVICE_URL=https://${python_fqdn}

# Java STT Service
JAVA_STT_SERVICE_URL=https://${java_fqdn}

# Service Endpoints
# Python: https://${python_fqdn}/docs (OpenAPI docs)
# Python: https://${python_fqdn}/health (Health check)
# Java:   https://${java_fqdn}/actuator/health (Health check)
EOF
  
  print_success "Remote environment file created: ${ENV_REMOTE_FILE}"
  echo ""
  cat "${ENV_REMOTE_FILE}"
  echo ""
}

# Display deployment summary
display_summary() {
  local python_fqdn="$1"
  
  print_completion "Deployment Complete!"
  
  echo "🚀 Deployed Services:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Python STT Service:"
  echo "  ├─ URL:      https://${python_fqdn}"
  echo "  ├─ Docs:     https://${python_fqdn}/docs"
  echo "  ├─ Health:   https://${python_fqdn}/health"
  echo "  ├─ CPU:      4.0 cores"
  echo "  └─ Memory:   8Gi"
  echo ""
  
  print_info "Next steps:"
  echo "  1. Test services using curl or your browser"
  echo "  2. Run load tests using the URLs in ${ENV_REMOTE_FILE}"
  echo "  3. Monitor services in Azure Portal"
  echo "  4. View logs: az containerapp logs show --name <app-name> --resource-group <rg-name> --follow"
  echo ""
  
  print_info "Quick test commands:"
  echo "  • Python health: curl https://${python_fqdn}/health"
  echo ""
}

###############################################################################
# Main Script
###############################################################################

main() {
  print_banner "Azure Container Apps Deployment"
  
  # Step 1: Load configuration
  load_configuration
  
  # Get resource group
  RESOURCE_GROUP=$(get_resource_group)
  echo ""
  
  # Get ACR login server
  ACR_LOGIN_SERVER=$(az acr show --name "${AZURE_CONTAINER_REGISTRY}" --query "loginServer" -o tsv)
  print_info "ACR Login Server: ${ACR_LOGIN_SERVER}"
  echo ""
  
  # Step 2-3: Build and push images (using ACR build tasks)
  build_and_push_python "${ACR_LOGIN_SERVER}"
  #build_and_push_java "${ACR_LOGIN_SERVER}"
  
  print_info "Images built and pushed successfully, proceeding to deployment..."
  echo ""
  
  # Step 4-5: Update Container Apps
  PYTHON_FQDN=$(update_python_app "${RESOURCE_GROUP}" "${ACR_LOGIN_SERVER}")
  echo ""
  
  # JAVA_FQDN=$(update_java_app "${RESOURCE_GROUP}" "${ACR_LOGIN_SERVER}")
  # echo ""
  
  # # Step 6: Generate remote environment file
  # generate_remote_env "${PYTHON_FQDN}" "${JAVA_FQDN}"
  
  # Display summary
  display_summary "${PYTHON_FQDN}"
}

# Run main function
main "$@"
