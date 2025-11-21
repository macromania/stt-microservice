#!/usr/bin/env bash

# Utility functions for consistent script output formatting
# Usage: source "$(dirname "$0")/utils.sh"

# Guard against multiple sourcing
if [ -n "${UTILS_SOURCED:-}" ]; then
  return 0
fi
readonly UTILS_SOURCED=1

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Print a banner with a title
# Usage: print_banner "Title Text"
print_banner() {
  local title="$1"
  local width=64
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  printf "║%-${width}s║\n" "       ${title}"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
}

# Print a section header
# Usage: print_section "Section Title"
print_section() {
  local title="$1"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "${title}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# Print a numbered step header
# Usage: print_step 1 "Step Description"
print_step() {
  local step_num="$1"
  local title="$2"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step ${step_num}: ${title}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# Print a success message
# Usage: print_success "Operation completed successfully"
print_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

# Print an error message
# Usage: print_error "Something went wrong"
print_error() {
  echo -e "${RED}❌ $1${NC}" >&2
}

# Print a warning message
# Usage: print_warning "This is a warning"
print_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

# Print an info message
# Usage: print_info "Processing item..."
print_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

# Print a progress message
# Usage: print_progress "Initializing..."
print_progress() {
  echo -e "${CYAN}🔧 $1${NC}"
}

# Print a separator line
# Usage: print_separator
print_separator() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print a completion banner
# Usage: print_completion "Infrastructure Deployed Successfully!"
print_completion() {
  local message="$1"
  local width=64
  echo ""
  echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
  printf "${GREEN}║%-${width}s║${NC}\n" "       ${message}"
  echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# Exit with error message
# Usage: exit_error "Fatal error occurred" 1
exit_error() {
  local message="$1"
  local code="${2:-1}"
  print_error "${message}"
  exit "${code}"
}
