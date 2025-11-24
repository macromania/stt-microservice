# Make exit on the first error for all commands by default
.SHELLFLAGS = -e -c 

.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-23s\033[0m %s\n", $$1, $$2}'

# Development Environment
restore: ## Install all dependencies (backend)
	@./scripts/restore.sh

provision: ## Provision development environment (backend)
	@./scripts/provision.sh

generate-audio-list: ## Generate audio files list JSON for load testing
	@./scripts/generate-audio-list.sh

run-api: ## Run the FastAPI application (development mode with auto-reload)
	@echo "[$$(date '+%Y-%m-%d %H:%M:%S')] Starting FastAPI in development mode..."
	@poetry run uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload


load-test: ## Run load test (will prompt for service URL)
	@if [ -z "$(BASE_URL)" ]; then \
		echo ""; \
		echo "📋 Enter the service URL from 'make local-api' output:"; \
		read -p "URL: " url; \
		$(MAKE) load-test BASE_URL=$$url; \
	else \
		echo "Starting load test with BASE_URL=$(BASE_URL)..."; \
		./scripts/run-load-test.sh -e BASE_URL=$(BASE_URL) load-test.js; \
	fi

# Local Kubernetes Cluster
setup-local-cluster: ## Setup Minikube cluster with Prometheus and Grafana
	@echo "Setting up Minikube cluster..."
	@minikube start -p stt-microservice --cpus=2 --memory=4096 --driver=docker
	@minikube addons enable metrics-server -p stt-microservice
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
	@helm repo update
	@helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n default --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false || echo "Prometheus stack already installed"
	@echo "Cluster setup complete! Monitoring stack is initializing in the background."

deploy-local: ## Deploy STT service to local Minikube cluster (full deployment)
	@./scripts/deploy-local.sh

k8s-azure-auth: ## Create/update Azure credentials secret for K8s (token expires in ~1hr)
	@./scripts/create-k8s-azure-credentials.sh

teardown-local-cluster: ## Delete Minikube cluster and all resources
	@echo "Deleting Minikube cluster..."
	@minikube delete -p stt-microservice
	@echo "Cluster deleted!"

local-grafana: ## Port-forward Grafana to localhost:3000 (Ctrl+C to stop)
	@echo "Opening Grafana at http://localhost:3000"
	@echo "Username: admin"
	@echo "Password: $$(kubectl get secret -n default kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -D)"
	@kubectl port-forward -n default svc/kube-prometheus-stack-grafana 3000:80

local-prometheus: ## Port-forward Prometheus to localhost:9090 (Ctrl+C to stop)
	@echo "Opening Prometheus at http://localhost:9090"
	@kubectl port-forward -n default svc/kube-prometheus-stack-prometheus 9090:9090

local-api: ## Start minikube service tunnel for load-balanced access (Ctrl+C to stop)
	@echo "═══════════════════════════════════════════════════════════════"
	@echo "Starting minikube service tunnel for STT service..."
	@echo "This provides load-balanced access across all pods."
	@echo "═══════════════════════════════════════════════════════════════"
	@echo ""
	@echo "📋 Copy this URL for load testing:"
	@echo ""
	@minikube service stt-service -p stt-microservice -n default --url
	@echo ""
	@echo "💡 Usage:"
	@echo "   1. Copy the URL above (e.g., http://127.0.0.1:xxxxx)"
	@echo "   2. In another terminal, run:"
	@echo "      make load-test"
	@echo ""
	@echo "⚠️  Keep this terminal open - tunnel is active"
	@echo "   Press Ctrl+C to stop the tunnel"
	@echo "═══════════════════════════════════════════════════════════════"
	@minikube service stt-service -p stt-microservice -n default

import-grafana-dashboard: ## Import STT dashboard into Grafana
	@./scripts/import-grafana-dashboard.sh

cleanup-local-cluster: ## Cleanup Minikube cluster
	@minikube delete -p stt-microservice
