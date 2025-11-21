#!/usr/bin/env bash

###############################################################################
# Azure Speech Service Provisioning Script
#
# This script provisions Azure Speech Service resources and configures RBAC
# for DefaultAzureCredential authentication.
#
# Features:
# - Idempotent operations (safe to run multiple times)
# - Interactive prompts for region and resource group
# - Automatic RBAC role assignment
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
readonly SPCH_PREFIX="spch"     # Speech Service abbreviation
readonly SKU="S0"               # Standard tier for Speech Service
readonly RBAC_ROLE="Cognitive Services Speech User"
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

# Create or verify Speech Service
create_speech_service() {
  local rg_name="$1"
  local location="$2"
  local resource_name="$3"
  
  print_step 3 "Creating Azure Speech Service"
  
  if az cognitiveservices account show \
    --name "${resource_name}" \
    --resource-group "${rg_name}" &> /dev/null; then
    
    print_info "Speech service '${resource_name}' already exists"
    local existing_kind
    existing_kind=$(az cognitiveservices account show \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --query "kind" -o tsv)
    print_info "Kind: ${existing_kind}"
    print_info "SKU: $(az cognitiveservices account show --name "${resource_name}" --resource-group "${rg_name}" --query "sku.name" -o tsv)"
  else
    print_progress "Creating Speech service '${resource_name}'..."
    az cognitiveservices account create \
      --name "${resource_name}" \
      --resource-group "${rg_name}" \
      --kind "SpeechServices" \
      --sku "${SKU}" \
      --location "${location}" \
      --yes \
      --output none
    
    print_success "Speech service created: ${resource_name}"
  fi
}

# Assign RBAC role to current user
assign_rbac_role() {
  local rg_name="$1"
  local resource_name="$2"
  local user_object_id="$3"
  
  print_step 4 "Configuring RBAC Permissions"
  
  local resource_id
  resource_id=$(az cognitiveservices account show \
    --name "${resource_name}" \
    --resource-group "${rg_name}" \
    --query "id" -o tsv)
  
  print_info "Resource ID: ${resource_id}"
  print_info "User Object ID: ${user_object_id}"
  
  # Check if role assignment already exists
  if az role assignment list \
    --assignee "${user_object_id}" \
    --scope "${resource_id}" \
    --role "${RBAC_ROLE}" \
    --query "[0].id" -o tsv &> /dev/null | grep -q "."; then
    
    print_info "RBAC role '${RBAC_ROLE}' already assigned"
  else
    print_progress "Assigning '${RBAC_ROLE}' role to current user..."
    az role assignment create \
      --assignee-object-id "${user_object_id}" \
      --assignee-principal-type "User" \
      --role "${RBAC_ROLE}" \
      --scope "${resource_id}" \
      --output none
    
    print_success "RBAC role assigned: ${RBAC_ROLE}"
    print_warning "Note: RBAC permissions may take 1-2 minutes to propagate"
  fi
}

# Generate .env file
generate_env_file() {
  local resource_name="$1"
  local region="$2"
  local environment="$3"
  
  print_step 5 "Generating Environment Configuration"
  
  if [ -f "${ENV_FILE}" ]; then
    print_warning "Existing .env file found"
    local backup_file="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "${ENV_FILE}" "${backup_file}"
    print_info "Backup created: ${backup_file}"
  fi
  
  cat > "${ENV_FILE}" << EOF
# Azure Speech Service Configuration
# Generated by provision.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Azure CAF naming convention applied

# Application Settings
APP_ENV=${environment}
APP_LOG_LEVEL=INFO

# Azure Speech Service (uses RBAC with DefaultAzureCredential)
STT_AZURE_SPEECH_RESOURCE_NAME=${resource_name}
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
  local resource_name="$2"
  local region="$3"
  local project="$4"
  local environment="$5"
  
  print_completion "Provisioning Complete!"
  
  echo "📋 Resource Summary (Azure CAF Naming):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Project:           ${project}"
  echo "  Environment:       ${environment}"
  echo "  Region:            ${region}"
  echo "  Resource Group:    ${rg_name}"
  echo "  Speech Service:    ${resource_name}"
  echo "  SKU:               ${SKU}"
  echo "  RBAC Role:         ${RBAC_ROLE}"
  echo "  Config File:       ${ENV_FILE}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  print_info "Next steps:"
  echo "  1. Review the generated .env file"
  echo "  2. Wait 1-2 minutes for RBAC permissions to propagate"
  echo "  3. Run your application with DefaultAzureCredential authentication"
  echo ""
  
  print_info "Useful commands:"
  echo "  • View resource: az cognitiveservices account show --name ${resource_name} --resource-group ${rg_name}"
  echo "  • Test auth: az account get-access-token --resource https://cognitiveservices.azure.com"
  echo "  • Check RBAC: az role assignment list --assignee \$(az ad signed-in-user show --query id -o tsv) --scope \$(az cognitiveservices account show --name ${resource_name} --resource-group ${rg_name} --query id -o tsv)"
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
  SPEECH_RESOURCE_NAME="${SPCH_PREFIX}-${PROJECT_NAME}-${ENVIRONMENT}-${REGION}"
  
  echo ""
  print_info "Configuration summary:"
  echo "  • Project:           ${PROJECT_NAME}"
  echo "  • Environment:       ${ENVIRONMENT}"
  echo "  • Region:            ${REGION}"
  echo "  • Resource Group:    ${RESOURCE_GROUP}"
  echo "  • Speech Service:    ${SPEECH_RESOURCE_NAME}"
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
  
  # Step 3: Create Speech Service
  create_speech_service "${RESOURCE_GROUP}" "${ACTUAL_REGION}" "${SPEECH_RESOURCE_NAME}"
  echo ""
  
  # Step 4: Assign RBAC
  assign_rbac_role "${RESOURCE_GROUP}" "${SPEECH_RESOURCE_NAME}" "${USER_OBJECT_ID}"
  echo ""
  
  # Step 5: Generate .env
  generate_env_file "${SPEECH_RESOURCE_NAME}" "${ACTUAL_REGION}" "${ENVIRONMENT}"
  echo ""
  
  # Display summary
  display_summary "${RESOURCE_GROUP}" "${SPEECH_RESOURCE_NAME}" "${ACTUAL_REGION}" "${PROJECT_NAME}" "${ENVIRONMENT}"
}

# Run main function
main "$@"
