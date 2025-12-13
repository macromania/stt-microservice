#!/usr/bin/env bash

###############################################################################
# Azure AI Foundry Provisioning Script
#
# This script provisions Azure AI Foundry resources (AIServices multi-service
# resource with project management) and configures RBAC for DefaultAzureCredential
# authentication.
#
# Features:
# - Idempotent operations (safe to run multiple times)
# - Interactive prompts for region and resource group
# - Creates AI Foundry resource and project
# - Automatic RBAC role assignment (dual roles for full access)
# - Generates .env file with required configuration
#
# Usage:
#   ./scripts/provision.sh
###############################################################################

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

###############################################################################
# Configuration
###############################################################################

# Azure CAF naming conventions
readonly RG_PREFIX="rg"         # Resource Group abbreviation
readonly FOUNDRY_PREFIX="foundry" # AI Foundry resource abbreviation
readonly PROJECT_SUFFIX="project" # Project name suffix
readonly ACR_PREFIX="acr"       # Azure Container Registry abbreviation
readonly CAE_PREFIX="cae"       # Container Apps Environment abbreviation
readonly MANAGED_ID_PREFIX="id" # Managed Identity abbreviation
readonly SKU="S0"               # Standard tier for AIServices
# Dual RBAC roles required for full access
readonly RBAC_ROLE_GENERAL="Cognitive Services User"       # General inference API access
readonly RBAC_ROLE_SPEECH="Cognitive Services Speech User" # Speech STT/TTS access
readonly ENV_FILE=".env"
readonly DEFAULT_ENV="dev"      # Default environment

# Container Apps configuration
readonly PYTHON_APP_NAME="stt-python"
readonly JAVA_APP_NAME="stt-java"
# Resource allocations for load testing
readonly PYTHON_CPU="4.0"       # 4 vCPU cores
readonly PYTHON_MEMORY="8Gi"    # 8 GiB RAM
readonly JAVA_CPU="2.0"         # 2 vCPU cores
readonly JAVA_MEMORY="4Gi"      # 4 GiB RAM

###############################################################################
# Helper Functions
###############################################################################

# Check if Azure CLI is installed and user is logged in
check_azure_cli() {
  print_step 1 "Validating Azure CLI"
  
  if ! command -v az &> /dev/null; then
    exit_error "Azure CLI is not installed. Please install it first: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli" 1
  fi
  print_success "Azure CLI is installed"
  
  # Check if logged in
  if ! az account show &> /dev/null; then
    exit_error "Not logged in to Azure. Please run 'az login' first" 1
  fi
  
  local account_name
  account_name=$(az account show --query "name" -o tsv)
  local subscription_id
  subscription_id=$(az account show --query "id" -o tsv)
  
  print_success "Logged in to Azure"
  print_info "Account: ${account_name}"
  print_info "Subscription ID: ${subscription_id}"
  echo ""
}

# Get current user's object ID
get_current_user_object_id() {
  local user_id
  user_id=$(az ad signed-in-user show --query "id" -o tsv 2>/dev/null) || {
    exit_error "Failed to get current user's object ID. Ensure you have permissions to query Azure AD" 1
  }
  echo "${user_id}"
}

# Prompt for user input with validation
prompt_for_input() {
  local prompt_message="$1"
  local var_name="$2"
  local default_value="${3:-}"
  
  local input_value
  while true; do
    if [ -n "${default_value}" ]; then
      read -rp "${prompt_message} [${default_value}]: " input_value
      input_value="${input_value:-${default_value}}"
    else
      read -rp "${prompt_message}: " input_value
    fi
    
    if [ -n "${input_value}" ]; then
      eval "${var_name}='${input_value}'"
      break
    else
      print_warning "Input cannot be empty. Please try again."
    fi
  done
}

# Create or verify resource group
create_resource_group() {
  local rg_name="$1"
  local location="$2"
  
  print_step 2 "Creating Resource Group"
  
  if az group show --name "${rg_name}" &> /dev/null; then
    print_info "Resource group '${rg_name}' already exists"
    local existing_location
    existing_location=$(az group show --name "${rg_name}" --query "location" -o tsv)
    print_info "Location: ${existing_location}"
    
    if [ "${existing_location}" != "${location}" ]; then
      print_warning "Existing resource group is in '${existing_location}', not '${location}'"
      print_warning "Will use existing location: ${existing_location}"
    fi
  else
    print_progress "Creating resource group '${rg_name}' in '${location}'..."
    az group create --name "${rg_name}" --location "${location}" --output none
    print_success "Resource group created: ${rg_name}"
  fi
}

# Create or verify AI Foundry Resource (AIServices with project management)
create_foundry_resource() {
  local rg_name="$1"
  local location="$2"
  local resource_name="$3"
  
  print_step 3 "Creating Azure AI Foundry Resource"
  
  if az cognitiveservices account show \
    --name "${resource_name}" \
    --resource-group "${rg_name}" &> /dev/null; then
    
    print_info "AI Foundry resource '${resource_name}' already exists"
    local existing_kind
    existing_kind=$(az cognitiveservices account show \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --query "kind" -o tsv)
    print_info "Kind: ${existing_kind}"
    print_info "SKU: $(az cognitiveservices account show --name "${resource_name}" --resource-group "${rg_name}" --query "sku.name" -o tsv)"
    
    # Check if custom domain is set, if not update it
    local existing_domain
    existing_domain=$(az cognitiveservices account show \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --query "properties.customSubDomainName" -o tsv 2>/dev/null)
    
    if [ -z "${existing_domain}" ] || [ "${existing_domain}" == "null" ]; then
      print_warning "Custom subdomain not set. Updating resource to enable project management..."
      az cognitiveservices account update \
        --name "${resource_name}" \
        --resource-group "${rg_name}" \
        --custom-domain "${resource_name}" \
        --output none
      print_success "Custom subdomain configured: ${resource_name}"
    else
      print_info "Custom subdomain: ${existing_domain}"
    fi
  else
    print_progress "Creating AI Foundry resource '${resource_name}'..."
    az cognitiveservices account create \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --kind "AIServices" \
      --sku "${SKU}" \
      --location "${location}" \
      --custom-domain "${resource_name}" \
      --allow-project-management \
      --yes \
      --output none
    
    print_success "AI Foundry resource created: ${resource_name}"
  fi
}

# Create or verify AI Foundry Project
create_foundry_project() {
  local rg_name="$1"
  local foundry_resource_name="$2"
  local project_name="$3"
  local location="$4"
  
  print_step 4 "Creating AI Foundry Project"
  
  # Check if project exists (list projects and grep for name)
  if az cognitiveservices account project list \
    --account-name "${foundry_resource_name}" \
    --resource-group "${rg_name}" 2>/dev/null | grep -q "${project_name}"; then
    
    print_info "AI Foundry project '${project_name}' already exists"
  else
    print_progress "Creating AI Foundry project '${project_name}'..."
    az cognitiveservices account project create \
      --name "${foundry_resource_name}" \
      --resource-group "${rg_name}" \
      --project-name "${project_name}" \
      --location "${location}" \
      --output none
    
    print_success "AI Foundry project created: ${project_name}"
  fi
}

# Assign RBAC roles to current user (dual roles for full access)
assign_rbac_role() {
  local rg_name="$1"
  local resource_name="$2"
  local user_object_id="$3"
  
  print_step 5 "Configuring RBAC Permissions"
  
  local resource_id
  resource_id=$(az cognitiveservices account show \
    --name "${resource_name}" \
    --resource-group "${rg_name}" \
    --query "id" -o tsv)
  
  print_info "Resource ID: ${resource_id}"
  print_info "User Object ID: ${user_object_id}"
  
  # Assign both required roles
  local roles=("${RBAC_ROLE_GENERAL}" "${RBAC_ROLE_SPEECH}")
  
  for role in "${roles[@]}"; do
    # Check if role assignment already exists
    if az role assignment list \
      --assignee "${user_object_id}" \
      --scope "${resource_id}" \
      --role "${role}" \
      --query "[0].id" -o tsv &> /dev/null | grep -q "."; then
      
      print_info "RBAC role '${role}' already assigned"
    else
      print_progress "Assigning '${role}' role to current user..."
      az role assignment create \
        --assignee-object-id "${user_object_id}" \
        --assignee-principal-type "User" \
        --role "${role}" \
        --scope "${resource_id}" \
        --output none
      
      print_success "RBAC role assigned: ${role}"
    fi
  done
  
  print_warning "Note: RBAC permissions may take 1-2 minutes to propagate"
}

# Create or verify Azure Container Registry
create_container_registry() {
  local rg_name="$1"
  local location="$2"
  local acr_name="$3"
  
  print_step 7 "Creating Azure Container Registry"
  
  if az acr show --name "${acr_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "ACR '${acr_name}' already exists"
    local existing_sku
    existing_sku=$(az acr show --name "${acr_name}" --resource-group "${rg_name}" --query "sku.name" -o tsv)
    print_info "SKU: ${existing_sku}"
  else
    print_progress "Creating Azure Container Registry '${acr_name}'..."
    az acr create \
      --name "${acr_name}" \
      --resource-group "${rg_name}" \
      --location "${location}" \
      --sku "Basic" \
      --admin-enabled true \
      --output none
    
    print_success "ACR created: ${acr_name}"
  fi
  
  local login_server
  login_server=$(az acr show --name "${acr_name}" --resource-group "${rg_name}" --query "loginServer" -o tsv)
  print_info "Login server: ${login_server}"
}

# Create or verify Container Apps Environment
create_container_apps_environment() {
  local rg_name="$1"
  local location="$2"
  local env_name="$3"
  
  print_step 8 "Creating Container Apps Environment"
  
  if az containerapp env show --name "${env_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "Container Apps environment '${env_name}' already exists"
    local existing_location
    existing_location=$(az containerapp env show --name "${env_name}" --resource-group "${rg_name}" --query "location" -o tsv)
    print_info "Location: ${existing_location}"
  else
    print_progress "Creating Container Apps environment '${env_name}'..."
    az containerapp env create \
      --name "${env_name}" \
      --resource-group "${rg_name}" \
      --location "${location}" \
      --output none
    
    print_success "Container Apps environment created: ${env_name}"
  fi
}

# Create or verify managed identities and assign RBAC
create_managed_identities() {
  local rg_name="$1"
  local location="$2"
  local python_id_name="$3"
  local java_id_name="$4"
  local foundry_resource_name="$5"
  
  print_step 9 "Creating Managed Identities"
  
  local resource_id
  resource_id=$(az cognitiveservices account show \
    --name "${foundry_resource_name}" \
    --resource-group "${rg_name}" \
    --query "id" -o tsv)
  
  # Create Python managed identity
  if az identity show --name "${python_id_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "Managed identity '${python_id_name}' already exists"
  else
    print_progress "Creating managed identity '${python_id_name}'..."
    az identity create \
      --name "${python_id_name}" \
      --resource-group "${rg_name}" \
      --location "${location}" \
      --output none
    print_success "Managed identity created: ${python_id_name}"
  fi
  
  # Create Java managed identity
  if az identity show --name "${java_id_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "Managed identity '${java_id_name}' already exists"
  else
    print_progress "Creating managed identity '${java_id_name}'..."
    az identity create \
      --name "${java_id_name}" \
      --resource-group "${rg_name}" \
      --location "${location}" \
      --output none
    print_success "Managed identity created: ${java_id_name}"
  fi
  
  # Assign RBAC roles to Python identity
  local python_principal_id
  python_principal_id=$(az identity show --name "${python_id_name}" --resource-group "${rg_name}" --query "principalId" -o tsv)
  print_info "Python identity principal ID: ${python_principal_id}"
  
  local roles=("${RBAC_ROLE_GENERAL}" "${RBAC_ROLE_SPEECH}")
  for role in "${roles[@]}"; do
    if az role assignment list \
      --assignee "${python_principal_id}" \
      --scope "${resource_id}" \
      --role "${role}" \
      --query "[0].id" -o tsv &> /dev/null | grep -q "."; then
      print_info "Python identity: '${role}' already assigned"
    else
      print_progress "Assigning '${role}' to Python identity..."
      az role assignment create \
        --assignee-object-id "${python_principal_id}" \
        --assignee-principal-type "ServicePrincipal" \
        --role "${role}" \
        --scope "${resource_id}" \
        --output none
      print_success "Role assigned: ${role}"
    fi
  done
  
  # Assign RBAC roles to Java identity
  local java_principal_id
  java_principal_id=$(az identity show --name "${java_id_name}" --resource-group "${rg_name}" --query "principalId" -o tsv)
  print_info "Java identity principal ID: ${java_principal_id}"
  
  for role in "${roles[@]}"; do
    if az role assignment list \
      --assignee "${java_principal_id}" \
      --scope "${resource_id}" \
      --role "${role}" \
      --query "[0].id" -o tsv &> /dev/null | grep -q "."; then
      print_info "Java identity: '${role}' already assigned"
    else
      print_progress "Assigning '${role}' to Java identity..."
      az role assignment create \
        --assignee-object-id "${java_principal_id}" \
        --assignee-principal-type "ServicePrincipal" \
        --role "${role}" \
        --scope "${resource_id}" \
        --output none
      print_success "Role assigned: ${role}"
    fi
  done
  
  print_warning "Note: RBAC permissions may take 1-2 minutes to propagate"
}

# Create container apps with hello-world image
create_container_apps() {
  local rg_name="$1"
  local cae_name="$2"
  local acr_name="$3"
  local acr_login_server="$4"
  local python_id_name="$5"
  local java_id_name="$6"
  local environment="$7"
  
  print_step 10 "Creating Container Apps"
  
  local python_app_name="${PYTHON_APP_NAME}-${environment}"
  local java_app_name="${JAVA_APP_NAME}-${environment}"
  
  # Get managed identity resource IDs
  local python_identity_id
  python_identity_id=$(az identity show --name "${python_id_name}" --resource-group "${rg_name}" --query "id" -o tsv)
  
  local java_identity_id
  java_identity_id=$(az identity show --name "${java_id_name}" --resource-group "${rg_name}" --query "id" -o tsv)
  
  # Get ACR credentials
  local acr_username
  local acr_password
  acr_username=$(az acr credential show --name "${acr_name}" --query "username" -o tsv)
  acr_password=$(az acr credential show --name "${acr_name}" --query "passwords[0].value" -o tsv)
  
  # Create Python container app
  if az containerapp show --name "${python_app_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "Python container app '${python_app_name}' already exists"
  else
    print_progress "Creating Python container app '${python_app_name}'..."
    
    az containerapp create \
      --name "${python_app_name}" \
      --resource-group "${rg_name}" \
      --environment "${cae_name}" \
      --image "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" \
      --registry-server "${acr_login_server}" \
      --registry-username "${acr_username}" \
      --registry-password "${acr_password}" \
      --user-assigned "${python_identity_id}" \
      --cpu "${PYTHON_CPU}" \
      --memory "${PYTHON_MEMORY}" \
      --min-replicas 3 \
      --max-replicas 3 \
      --target-port 80 \
      --ingress external \
      --output none || {
      exit_error "Failed to create Python container app '${python_app_name}'" 1
    }
    
    print_success "Python container app created: ${python_app_name}"
  fi
  
  # Get Python app FQDN
  local python_fqdn
  python_fqdn=$(az containerapp show \
    --name "${python_app_name}" \
    --resource-group "${rg_name}" \
    --query "properties.configuration.ingress.fqdn" -o tsv)
  print_info "Python app URL: https://${python_fqdn}"
  
  # Create Java container app
  if az containerapp show --name "${java_app_name}" --resource-group "${rg_name}" &> /dev/null; then
    print_info "Java container app '${java_app_name}' already exists"
  else
    print_progress "Creating Java container app '${java_app_name}'..."
    
    az containerapp create \
      --name "${java_app_name}" \
      --resource-group "${rg_name}" \
      --environment "${cae_name}" \
      --image "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" \
      --registry-server "${acr_login_server}" \
      --registry-username "${acr_username}" \
      --registry-password "${acr_password}" \
      --user-assigned "${java_identity_id}" \
      --cpu "${JAVA_CPU}" \
      --memory "${JAVA_MEMORY}" \
      --min-replicas 3 \
      --max-replicas 3 \
      --target-port 80 \
      --ingress external \
      --output none || {
      exit_error "Failed to create Java container app '${java_app_name}'" 1
    }
    
    print_success "Java container app created: ${java_app_name}"
  fi
  
  # Get Java app FQDN
  local java_fqdn
  java_fqdn=$(az containerapp show \
    --name "${java_app_name}" \
    --resource-group "${rg_name}" \
    --query "properties.configuration.ingress.fqdn" -o tsv)
  print_info "Java app URL: https://${java_fqdn}"
  
  echo ""
  print_success "Container apps created with hello-world images"
  print_info "Run ./scripts/deploy-azure.sh to deploy your STT services"
}

# Generate .env file
generate_env_file() {
  local foundry_resource_name="$1"
  local project_name="$2"
  local region="$3"
  local environment="$4"
  local acr_name="$5"
  local cae_name="$6"
  local python_id_name="$7"
  local java_id_name="$8"
  local python_app_name="$9"
  local java_app_name="${10}"
  
  print_step 11 "Generating Environment Configuration"
  
  if [ -f "${ENV_FILE}" ]; then
    print_warning "Existing .env file found"
    local backup_file="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${ENV_FILE}" "${backup_file}"
    print_info "Backup created: ${backup_file}"
  fi
  
  cat > "${ENV_FILE}" << EOF
# Azure AI Foundry Configuration
# Generated by provision.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Azure CAF naming convention applied
#
# Note: Using AI Foundry (AIServices multi-service resource) for Speech access
# The STT_AZURE_SPEECH_* variables point to the AI Foundry resource for backward compatibility
# AI Foundry Project: ${project_name}

# Application Settings
APP_ENV=${environment}
APP_LOG_LEVEL=INFO

# Azure AI Foundry / Speech Service (uses RBAC with DefaultAzureCredential)
# Resource is AI Foundry AIServices kind, provides Speech + other AI services
STT_AZURE_SPEECH_RESOURCE_NAME=${foundry_resource_name}
STT_AZURE_SPEECH_REGION=${region}

# STT Processing Limits
STT_MAX_FILE_SIZE_MB=100
STT_MAX_DURATION_MINUTES=120

# Azure Container Infrastructure (for deployment)
AZURE_CONTAINER_REGISTRY=${acr_name}
AZURE_CONTAINER_APPS_ENVIRONMENT=${cae_name}
AZURE_MANAGED_IDENTITY_PYTHON=${python_id_name}
AZURE_MANAGED_IDENTITY_JAVA=${java_id_name}
AZURE_CONTAINER_APP_PYTHON=${python_app_name}
AZURE_CONTAINER_APP_JAVA=${java_app_name}
EOF
  
  print_success "Environment file created: ${ENV_FILE}"
  print_info "Configuration:"
  echo ""
  cat "${ENV_FILE}" | grep -v "^#" | grep -v "^$"
  echo ""
}

# Display summary
display_summary() {
  local rg_name="$1"
  local foundry_resource_name="$2"
  local project_name="$3"
  local region="$4"
  local project="$5"
  local environment="$6"
  local acr_name="$7"
  local cae_name="$8"
  local python_id_name="$9"
  local java_id_name="${10}"
  
  print_completion "Provisioning Complete!"
  
  echo "📋 Resource Summary (Azure CAF Naming):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Project:                ${project}"
  echo "  Environment:            ${environment}"
  echo "  Region:                 ${region}"
  echo "  Resource Group:         ${rg_name}"
  echo ""
  echo "  AI Services:"
  echo "  ├─ Foundry Resource:    ${foundry_resource_name}"
  echo "  ├─ Foundry Project:     ${project_name}"
  echo "  └─ SKU:                 ${SKU}"
  echo ""
  echo "  Container Infrastructure:"
  echo "  ├─ Container Registry:  ${acr_name}"
  echo "  ├─ Apps Environment:    ${cae_name}"
  echo "  ├─ Python Identity:     ${python_id_name}"
  echo "  └─ Java Identity:       ${java_id_name}"
  echo ""
  echo "  Resource Allocations:"
  echo "  ├─ Python Service:      ${PYTHON_CPU} CPU, ${PYTHON_MEMORY} RAM"
  echo "  └─ Java Service:        ${JAVA_CPU} CPU, ${JAVA_MEMORY} RAM"
  echo ""
  echo "  RBAC Roles:             ${RBAC_ROLE_GENERAL}"
  echo "                          ${RBAC_ROLE_SPEECH}"
  echo "  Config File:            ${ENV_FILE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  print_info "Next steps:"
  echo "  1. Review the generated .env file"
  echo "  2. Wait 1-2 minutes for RBAC permissions to propagate"
  echo "  3. Run ./scripts/deploy-azure.sh to build and deploy applications"
  echo "  4. Access AI Foundry portal: https://ai.azure.com"
  echo ""
  
  print_info "Useful commands:"
  echo "  • View ACR: az acr show --name ${acr_name} --resource-group ${rg_name}"
  echo "  • View Container Apps Env: az containerapp env show --name ${cae_name} --resource-group ${rg_name}"
  echo "  • Check managed identity: az identity show --name ${python_id_name} --resource-group ${rg_name}"
  echo "  • Test auth: az account get-access-token --resource https://cognitiveservices.azure.com"
  echo ""
}

###############################################################################
# Main Script
###############################################################################

main() {
  print_banner "Azure Speech Service Provisioning"
  
  # Step 1: Validate Azure CLI
  check_azure_cli
  
  # Get current user for RBAC
  print_progress "Getting current user information..."
  USER_OBJECT_ID=$(get_current_user_object_id)
  print_success "User object ID retrieved"
  echo ""
  
  # Prompt for inputs
  print_section "Configuration Input"
  
  prompt_for_input "Enter Azure region (e.g., eastus, uaenorth, westeurope)" "REGION" "eastus"
  prompt_for_input "Enter project name (e.g., stt-service, voice-transcribe)" "PROJECT_NAME"
  
  # Optional: prompt for environment (default: dev)
  read -rp "Enter environment [dev]: " ENV_INPUT
  ENVIRONMENT="${ENV_INPUT:-${DEFAULT_ENV}}"
  
  # Generate Azure CAF compliant names
  # Format: {prefix}-{project}-{environment}-{region}
  RESOURCE_GROUP="${RG_PREFIX}-${PROJECT_NAME}-${ENVIRONMENT}-${REGION}"
  FOUNDRY_RESOURCE_NAME="${FOUNDRY_PREFIX}-${PROJECT_NAME}-${ENVIRONMENT}-${REGION}"
  PROJECT_DISPLAY_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${PROJECT_SUFFIX}"
  
  # Container infrastructure names (ACR must be alphanumeric only)
  ACR_NAME="${ACR_PREFIX}${PROJECT_NAME//-/}${ENVIRONMENT}${REGION//-/}"
  CAE_NAME="${CAE_PREFIX}-${PROJECT_NAME}-${ENVIRONMENT}-${REGION}"
  PYTHON_IDENTITY_NAME="${MANAGED_ID_PREFIX}-${PROJECT_NAME}-${PYTHON_APP_NAME}-${ENVIRONMENT}"
  JAVA_IDENTITY_NAME="${MANAGED_ID_PREFIX}-${PROJECT_NAME}-${JAVA_APP_NAME}-${ENVIRONMENT}"
  
  echo ""
  print_info "Configuration summary:"
  echo "  • Project:                ${PROJECT_NAME}"
  echo "  • Environment:            ${ENVIRONMENT}"
  echo "  • Region:                 ${REGION}"
  echo "  • Resource Group:         ${RESOURCE_GROUP}"
  echo "  • AI Foundry Resource:    ${FOUNDRY_RESOURCE_NAME}"
  echo "  • AI Foundry Project:     ${PROJECT_DISPLAY_NAME}"
  echo "  • Container Registry:     ${ACR_NAME}"
  echo "  • Container Apps Env:     ${CAE_NAME}"
  echo "  • Python Identity:        ${PYTHON_IDENTITY_NAME}"
  echo "  • Java Identity:          ${JAVA_IDENTITY_NAME}"
  echo ""
  
  read -rp "Proceed with provisioning? (y/n): " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    print_warning "Provisioning cancelled by user"
    exit 0
  fi
  
  echo ""
  print_separator
  echo ""
  
  # Step 2: Create Resource Group
  create_resource_group "${RESOURCE_GROUP}" "${REGION}"
  ACTUAL_REGION="${REGION}"
  
  # Check if resource group exists and get actual location
  if az group show --name "${RESOURCE_GROUP}" &> /dev/null; then
    ACTUAL_REGION=$(az group show --name "${RESOURCE_GROUP}" --query "location" -o tsv)
  fi
  echo ""
  
  # Step 3: Create AI Foundry Resource
  create_foundry_resource "${RESOURCE_GROUP}" "${ACTUAL_REGION}" "${FOUNDRY_RESOURCE_NAME}"
  echo ""
  
  # Step 4: Create AI Foundry Project
  create_foundry_project "${RESOURCE_GROUP}" "${FOUNDRY_RESOURCE_NAME}" "${PROJECT_DISPLAY_NAME}" "${ACTUAL_REGION}"
  echo ""
  
  # Step 5: Assign RBAC (dual roles)
  assign_rbac_role "${RESOURCE_GROUP}" "${FOUNDRY_RESOURCE_NAME}" "${USER_OBJECT_ID}"
  echo ""
  
  # Step 6: Create Azure Container Registry
  create_container_registry "${RESOURCE_GROUP}" "${ACTUAL_REGION}" "${ACR_NAME}"
  echo ""
  
  # Get ACR login server for container apps
  ACR_LOGIN_SERVER=$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query "loginServer" -o tsv)
  
  # Step 7: Create Container Apps Environment
  create_container_apps_environment "${RESOURCE_GROUP}" "${ACTUAL_REGION}" "${CAE_NAME}"
  echo ""
  
  # Step 8: Create Managed Identities and assign RBAC
  create_managed_identities "${RESOURCE_GROUP}" "${ACTUAL_REGION}" "${PYTHON_IDENTITY_NAME}" "${JAVA_IDENTITY_NAME}" "${FOUNDRY_RESOURCE_NAME}"
  echo ""
  
  # Step 9: Create Container Apps
  create_container_apps "${RESOURCE_GROUP}" "${CAE_NAME}" "${ACR_NAME}" "${ACR_LOGIN_SERVER}" "${PYTHON_IDENTITY_NAME}" "${JAVA_IDENTITY_NAME}" "${ENVIRONMENT}"
  echo ""
  
  # Define container app names for .env
  PYTHON_APP_NAME_FULL="${PYTHON_APP_NAME}-${ENVIRONMENT}"
  JAVA_APP_NAME_FULL="${JAVA_APP_NAME}-${ENVIRONMENT}"
  
  # Step 10: Generate .env
  generate_env_file "${FOUNDRY_RESOURCE_NAME}" "${PROJECT_DISPLAY_NAME}" "${ACTUAL_REGION}" "${ENVIRONMENT}" "${ACR_NAME}" "${CAE_NAME}" "${PYTHON_IDENTITY_NAME}" "${JAVA_IDENTITY_NAME}" "${PYTHON_APP_NAME_FULL}" "${JAVA_APP_NAME_FULL}"
  echo ""
  
  # Display summary
  display_summary "${RESOURCE_GROUP}" "${FOUNDRY_RESOURCE_NAME}" "${PROJECT_DISPLAY_NAME}" "${ACTUAL_REGION}" "${PROJECT_NAME}" "${ENVIRONMENT}" "${ACR_NAME}" "${CAE_NAME}" "${PYTHON_IDENTITY_NAME}" "${JAVA_IDENTITY_NAME}"
}

# Run main function
main "$@"
