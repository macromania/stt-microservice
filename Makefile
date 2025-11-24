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

teardown-local-cluster: ## Delete Minikube cluster and all resources
	@echo "Deleting Minikube cluster..."
	@minikube delete -p stt-microservice
	@echo "Cluster deleted!"

local-grafana: ## Port-forward Grafana to localhost:3000 (Ctrl+C to stop)
	@echo "Opening Grafana at http://localhost:3000"
	@echo "Username: admin"
	@echo "Password: prom-operator"
	@kubectl port-forward -n default svc/kube-prometheus-stack-grafana 3000:80

local-prometheus: ## Port-forward Prometheus to localhost:9090 (Ctrl+C to stop)
	@echo "Opening Prometheus at http://localhost:9090"
	@kubectl port-forward -n default svc/kube-prometheus-stack-prometheus 9090:9090

local-api: ## Port-forward STT API to localhost:8000 (Ctrl+C to stop)
	@echo "Opening STT API at http://localhost:8000"
	@kubectl port-forward -n default svc/stt-service 8000:8000

cleanup-local-cluster: ## Cleanup Minikube cluster
	@minikube delete -p stt-microservice
