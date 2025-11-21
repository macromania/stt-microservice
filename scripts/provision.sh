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
readonly SKU="S0"               # Standard tier for AIServices
# Dual RBAC roles required for full access
readonly RBAC_ROLE_GENERAL="Cognitive Services User"       # General inference API access
readonly RBAC_ROLE_SPEECH="Cognitive Services Speech User" # Speech STT/TTS access
readonly ENV_FILE=".env"
readonly DEFAULT_ENV="dev"      # Default environment

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
  else
    print_progress "Creating AI Foundry resource '${resource_name}'..."
    az cognitiveservices account create \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --kind "AIServices" \
      --sku "${SKU}" \
      --location "${location}" \
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

# Generate .env file
generate_env_file() {
  local foundry_resource_name="$1"
  local project_name="$2"
  local region="$3"
  local environment="$4"
  
  print_step 6 "Generating Environment Configuration"
  
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
  
  print_completion "Provisioning Complete!"
  
  echo "📋 Resource Summary (Azure CAF Naming):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Project:             ${project}"
  echo "  Environment:         ${environment}"
  echo "  Region:              ${region}"
  echo "  Resource Group:      ${rg_name}"
  echo "  AI Foundry Resource: ${foundry_resource_name}"
  echo "  AI Foundry Project:  ${project_name}"
  echo "  SKU:                 ${SKU}"
  echo "  RBAC Roles:          ${RBAC_ROLE_GENERAL}"
  echo "                       ${RBAC_ROLE_SPEECH}"
  echo "  Config File:         ${ENV_FILE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  print_info "Next steps:"
  echo "  1. Review the generated .env file"
  echo "  2. Wait 1-2 minutes for RBAC permissions to propagate"
  echo "  3. Run your application with DefaultAzureCredential authentication"
  echo "  4. Access AI Foundry portal: https://ai.azure.com"
  echo ""
  
  print_info "Useful commands:"
  echo "  • View AI Foundry resource: az cognitiveservices account show --name ${foundry_resource_name} --resource-group ${rg_name}"
  echo "  • List projects: az cognitiveservices account project list --account-name ${foundry_resource_name}"
  echo "  • Test auth: az account get-access-token --resource https://cognitiveservices.azure.com"
  echo "  • Check RBAC: az role assignment list --assignee \$(az ad signed-in-user show --query id -o tsv) --scope \$(az cognitiveservices account show --name ${foundry_resource_name} --resource-group ${rg_name} --query id -o tsv)"
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
  
  echo ""
  print_info "Configuration summary:"
  echo "  • Project:             ${PROJECT_NAME}"
  echo "  • Environment:         ${ENVIRONMENT}"
  echo "  • Region:              ${REGION}"
  echo "  • Resource Group:      ${RESOURCE_GROUP}"
  echo "  • AI Foundry Resource: ${FOUNDRY_RESOURCE_NAME}"
  echo "  • AI Foundry Project:  ${PROJECT_DISPLAY_NAME}"
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
  
  # Step 6: Generate .env
  generate_env_file "${FOUNDRY_RESOURCE_NAME}" "${PROJECT_DISPLAY_NAME}" "${ACTUAL_REGION}" "${ENVIRONMENT}"
  echo ""
  
  # Display summary
  display_summary "${RESOURCE_GROUP}" "${FOUNDRY_RESOURCE_NAME}" "${PROJECT_DISPLAY_NAME}" "${ACTUAL_REGION}" "${PROJECT_NAME}" "${ENVIRONMENT}"
}

# Run main function
main "$@"
