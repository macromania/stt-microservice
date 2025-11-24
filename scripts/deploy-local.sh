#!/usr/bin/env bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utilities
source "${SCRIPT_DIR}/utils.sh"

# Configuration
MINIKUBE_PROFILE="stt-microservice"
MINIKUBE_CPUS=4
MINIKUBE_MEMORY=8192
NAMESPACE="default"
APP_NAME="stt-service"

print_banner "Local Cluster Deployment"

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
print_section "Checking Prerequisites"

if ! command_exists minikube; then
  print_error "minikube is not installed. Please install it first."
  exit 1
fi

if ! command_exists kubectl; then
  print_error "kubectl is not installed. Please install it first."
  exit 1
fi

if ! command_exists helm; then
  print_error "helm is not installed. Please install it first."
  exit 1
fi

if ! command_exists docker; then
  print_error "docker is not installed. Please install it first."
  exit 1
fi

print_success "All prerequisites are met"

# Function: Start Minikube
setup_minikube() {
  print_step 1 "Setting up Minikube cluster"
  
  if minikube status -p "${MINIKUBE_PROFILE}" &>/dev/null; then
    print_info "Minikube profile '${MINIKUBE_PROFILE}' is already running"
  else
    print_info "Starting Minikube cluster..."
    minikube start -p "${MINIKUBE_PROFILE}" \
      --cpus="${MINIKUBE_CPUS}" \
      --memory="${MINIKUBE_MEMORY}" \
      --driver=docker
    
    print_success "Minikube cluster started"
  fi
  
  # Enable metrics-server addon
  print_info "Enabling metrics-server addon..."
  minikube addons enable metrics-server -p "${MINIKUBE_PROFILE}"
  
  print_success "Minikube setup complete"
}

# Function: Install monitoring stack
install_monitoring() {
  print_step 2 "Installing Prometheus and Grafana"
  
  # Add Prometheus Community Helm repository (better ARM64 support)
  print_info "Adding Prometheus Community Helm repository..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update
  
  # Install kube-prometheus-stack (includes Prometheus, Grafana, Alertmanager)
  if helm list -n "${NAMESPACE}" | grep -q "kube-prometheus-stack"; then
    print_info "Prometheus stack is already installed"
  else
    print_info "Installing kube-prometheus-stack (Prometheus + Grafana)..."
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      -n "${NAMESPACE}" \
      --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
    print_success "Prometheus stack installation started"
  fi
  
  print_info "Monitoring stack is initializing in the background..."
  print_success "Monitoring stack installation complete"
}

# Function: Build Docker image
build_image() {
  print_step 3 "Building Docker image"
  
  print_info "Setting Docker environment to use Minikube's Docker daemon..."
  eval "$(minikube -p "${MINIKUBE_PROFILE}" docker-env)"
  
  print_info "Building ${APP_NAME}:latest..."
  docker build -t "${APP_NAME}:latest" -f "${PROJECT_ROOT}/src/Dockerfile" "${PROJECT_ROOT}"
  
  print_success "Docker image built successfully"
}

# Function: Create ConfigMap
create_configmap() {
  print_step 4 "Creating ConfigMap from .env"
  
  if [ ! -f "${PROJECT_ROOT}/.env" ]; then
    print_error ".env file not found at ${PROJECT_ROOT}/.env"
    exit 1
  fi
  
  # Delete existing ConfigMap if it exists
  kubectl delete configmap stt-config -n "${NAMESPACE}" 2>/dev/null || true
  
  print_info "Creating ConfigMap 'stt-config'..."
  kubectl create configmap stt-config \
    --from-env-file="${PROJECT_ROOT}/.env" \
    -n "${NAMESPACE}"
  
  print_success "ConfigMap created successfully"
}

# Function: Deploy application
deploy_app() {
  print_step 5 "Deploying STT service"
  
  print_info "Applying Kubernetes manifests..."
  kubectl apply -f "${PROJECT_ROOT}/k8s/deployment.yaml" -n "${NAMESPACE}"
  kubectl apply -f "${PROJECT_ROOT}/k8s/service.yaml" -n "${NAMESPACE}"
  kubectl apply -f "${PROJECT_ROOT}/k8s/monitor.yaml" -n "${NAMESPACE}"
  
  print_info "Waiting for deployment to be ready..."
  kubectl rollout status deployment/"${APP_NAME}" -n "${NAMESPACE}" --timeout=5m
  
  print_success "STT service deployed successfully"
}

# Function: Configure Grafana
configure_grafana() {
  print_step 6 "Configuring Grafana"
  
  print_info "Waiting for Grafana to be ready (this may take a few minutes)..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n "${NAMESPACE}" --timeout=10m
  
  print_info "Grafana is ready. Prometheus data source is pre-configured in kube-prometheus-stack."
  print_success "Grafana configured successfully"
}

# Function: Import Grafana dashboard
import_dashboard() {
  print_step 7 "Importing Grafana dashboard"
  
  print_info "Waiting for Grafana to be ready..."
  if ! kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n "${NAMESPACE}" --timeout=2m 2>/dev/null; then
    print_warning "Grafana not ready yet. You can import the dashboard later with: make import-grafana-dashboard"
    return
  fi
  
  print_info "Running import script..."
  if NAMESPACE="${NAMESPACE}" "${SCRIPT_DIR}/import-grafana-dashboard.sh"; then
    print_success "Dashboard imported successfully"
  else
    print_warning "Dashboard import failed. You can retry with: make import-grafana-dashboard"
  fi
}

# Function: Display access information
display_info() {
  print_section "Deployment Complete!"
  
  echo "Access your services using these commands:"
  echo ""
  echo -e "  ${CYAN}Grafana Dashboard:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/kube-prometheus-stack-grafana 3000:80"
  echo "    Open: http://localhost:3000"
  echo "    Username: admin"
  echo "    Password: (run command below to get password)"
  echo "    kubectl get secret -n ${NAMESPACE} kube-prometheus-stack-grafana -o jsonpath=\"{.data.admin-password}\" | base64 --decode && echo"
  echo ""
  echo -e "  ${CYAN}Prometheus:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/kube-prometheus-stack-prometheus 9090:9090"
  echo "    Open: http://localhost:9090"
  echo ""
  echo -e "  ${CYAN}STT API - For Load Testing (IMPORTANT for multi-pod distribution):${NC}"
  echo "    # Get the load-balanced service URL:"
  echo "    SERVICE_URL=\$(./scripts/get-service-url.sh)"
  echo "    echo \$SERVICE_URL"
  echo ""
  echo "    # Run load test with proper load balancing:"
  echo "    ./scripts/run-load-test.sh -e BASE_URL=\$SERVICE_URL -e TEST_MODE=smoke load-test.js"
  echo ""
  echo -e "  ${CYAN}STT API - For Quick Manual Testing (single pod only):${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/stt-service 8000:8000"
  echo "    Open: http://localhost:8000/docs"
  echo ""
  echo -e "  ${CYAN}View Metrics:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/stt-service 8000:8000"
  echo "    curl http://localhost:8000/metrics"
  echo ""
  echo -e "  ${CYAN}View Logs:${NC}"
  echo "    kubectl logs -f -l app=${APP_NAME} -n ${NAMESPACE}"
  echo ""
  echo -e "  ${CYAN}Check Status:${NC}"
  echo "    kubectl get all -l app=${APP_NAME} -n ${NAMESPACE}"
  echo ""
  
  print_info "STT Dashboard has been automatically imported to Grafana"
  echo "    Access it at: http://localhost:3000/dashboards"
  echo ""
}

# Function: Create Azure credentials secret
create_azure_credentials() {
  print_step 4.5 "Creating Azure credentials for authentication"
  
  print_info "Retrieving Azure access token..."
  if ! command -v az &> /dev/null; then
    print_warning "Azure CLI not found. Skipping Azure credentials setup."
    print_warning "Run 'make k8s-azure-auth' after deployment to configure authentication."
    return
  fi
  
  if ! az account show &>/dev/null; then
    print_warning "Not logged into Azure CLI. Skipping Azure credentials setup."
    print_warning "Run 'az login' then 'make k8s-azure-auth' to configure authentication."
    return
  fi
  
  "${SCRIPT_DIR}/create-k8s-azure-credentials.sh"
}

# Main execution
main() {
  setup_minikube
  install_monitoring
  build_image
  create_configmap
  create_azure_credentials
  deploy_app
  configure_grafana
  import_dashboard
  display_info
  
  print_success "All done! Your local cluster is ready."
}

# Run main function
main "$@"
