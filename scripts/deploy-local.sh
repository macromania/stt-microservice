#!/usr/bin/env bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utilities
source "${SCRIPT_DIR}/utils.sh"

# Configuration
MINIKUBE_PROFILE="stt-microservice"
MINIKUBE_CPUS=2
MINIKUBE_MEMORY=4096
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
  
  # Add Bitnami Helm repository
  print_info "Adding Bitnami Helm repository..."
  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo update
  
  # Install Prometheus
  if helm list -n "${NAMESPACE}" | grep -q "prometheus"; then
    print_info "Prometheus is already installed"
  else
    print_info "Installing Prometheus..."
    helm install prometheus bitnami/kube-prometheus \
      --namespace "${NAMESPACE}" \
      --set prometheus.service.type=ClusterIP \
      --wait --timeout=5m
    print_success "Prometheus installed"
  fi
  
  # Install Grafana
  if helm list -n "${NAMESPACE}" | grep -q "grafana"; then
    print_info "Grafana is already installed"
  else
    print_info "Installing Grafana..."
    helm install grafana bitnami/grafana \
      --namespace "${NAMESPACE}" \
      --set service.type=ClusterIP \
      --set admin.user=admin \
      --set admin.password=admin \
      --wait --timeout=5m
    print_success "Grafana installed"
  fi
  
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
  
  print_info "Waiting for Grafana to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n "${NAMESPACE}" --timeout=5m
  
  print_info "Configuring Prometheus data source in Grafana..."
  
  # Get Grafana pod name
  GRAFANA_POD=$(kubectl get pod -l app.kubernetes.io/name=grafana -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
  
  # Create Prometheus data source
  kubectl exec -n "${NAMESPACE}" "${GRAFANA_POD}" -- \
    grafana-cli --homepath /opt/bitnami/grafana admin data-source add \
    --name "Prometheus" \
    --type "prometheus" \
    --url "http://prometheus-kube-prometheus-prometheus:9090" \
    --access "proxy" \
    --isDefault true 2>/dev/null || print_info "Prometheus data source may already exist"
  
  print_success "Grafana configured successfully"
}

# Function: Display access information
display_info() {
  print_section "Deployment Complete!"
  
  echo "Access your services using these commands:"
  echo ""
  echo "  ${CYAN}Grafana Dashboard:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/grafana 3000:3000"
  echo "    Open: http://localhost:3000 (admin/admin)"
  echo ""
  echo "  ${CYAN}Prometheus:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/prometheus-kube-prometheus-prometheus 9090:9090"
  echo "    Open: http://localhost:9090"
  echo ""
  echo "  ${CYAN}STT API:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/stt-service 8000:8000"
  echo "    Open: http://localhost:8000/docs"
  echo ""
  echo "  ${CYAN}View Metrics:${NC}"
  echo "    kubectl port-forward -n ${NAMESPACE} svc/stt-service 8000:8000"
  echo "    curl http://localhost:8000/metrics"
  echo ""
  echo "  ${CYAN}View Logs:${NC}"
  echo "    kubectl logs -f -l app=${APP_NAME} -n ${NAMESPACE}"
  echo ""
  echo "  ${CYAN}Check Status:${NC}"
  echo "    kubectl get all -l app=${APP_NAME} -n ${NAMESPACE}"
  echo ""
  
  print_info "Import the dashboard in Grafana:"
  echo "    1. Go to http://localhost:3000"
  echo "    2. Login with admin/admin"
  echo "    3. Go to Dashboards → Import"
  echo "    4. Upload: ${PROJECT_ROOT}/k8s/grafana-dashboard.json"
  echo ""
}

# Main execution
main() {
  setup_minikube
  install_monitoring
  build_image
  create_configmap
  deploy_app
  configure_grafana
  display_info
  
  print_success "All done! Your local cluster is ready."
}

# Run main function
main "$@"
