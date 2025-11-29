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


load-test: ## Run load test (requires .env.k6)
	@if [ ! -f ".env.k6" ]; then \
		echo "Error: .env.k6 not found"; \
		echo "Please create .env.k6 with your configuration"; \
		echo "See .env.k6.example for reference"; \
		exit 1; \
	fi
	@./scripts/run-load-test.sh load-test.js

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
	@echo "Starting minikube service tunnel for Python STT service..."
	@minikube service stt-service -p stt-microservice -n default

import-grafana-dashboard: ## Import STT dashboard into Grafana
	@./scripts/import-grafana-dashboard.sh

cleanup-local-cluster: ## Cleanup Minikube cluster
	@minikube delete -p stt-microservice

# Batch Transcription Testing
batch-transcribe-demo: ## Run full demo: create, wait, show results, cleanup (optional: AUDIO_URL=...)
	@./scripts/batch-transcribe.sh demo $(AUDIO_URL)

batch-transcribe-create: ## Create a batch transcription job (optional: AUDIO_URL=...)
	@./scripts/batch-transcribe.sh create $(AUDIO_URL)

batch-transcribe-status: ## Get batch transcription status (requires: TRANSCRIPTION_ID=...)
	@./scripts/batch-transcribe.sh status $(TRANSCRIPTION_ID)

batch-transcribe-results: ## Get batch transcription results (requires: TRANSCRIPTION_ID=...)
	@./scripts/batch-transcribe.sh results $(TRANSCRIPTION_ID)

batch-transcribe-wait: ## Wait for completion and show results (requires: TRANSCRIPTION_ID=...)
	@./scripts/batch-transcribe.sh wait $(TRANSCRIPTION_ID)

batch-transcribe-delete: ## Delete a batch transcription (requires: TRANSCRIPTION_ID=...)
	@./scripts/batch-transcribe.sh delete $(TRANSCRIPTION_ID)

# Java STT Service
java-build: ## Build Java STT service
	@echo "Building Java STT service..."
	@cd stt-java-service && ./mvnw clean package -DskipTests -B

java-docker: ## Build Java Docker image in Minikube
	@echo "Building Java Docker image in Minikube..."
	@eval $$(minikube docker-env -p stt-microservice) && \
	docker build -t stt-java-service:latest stt-java-service/

java-deploy: ## Deploy Java STT service to local cluster
	@echo "Deploying Java STT service..."
	@kubectl apply -f stt-java-service/k8s/

java-logs: ## Stream logs from Java STT service
	@kubectl logs -l app=stt-java-service -f --all-containers

java-delete: ## Delete Java STT service from cluster
	@echo "Deleting Java STT service..."
	@kubectl delete -f stt-java-service/k8s/ || true

java-full-deploy: java-build java-docker java-deploy ## Full Java service deployment (build, docker, deploy)
	@echo "Java STT service fully deployed!"

local-api-java: ## Start minikube service tunnel for Java service (Ctrl+C to stop)
	@echo "Starting minikube service tunnel for Java STT service..."
	@minikube service stt-java-service -p stt-microservice -n default

compare-memory: ## Show memory usage comparison between Python and Java services
	@echo "═══════════════════════════════════════════════════════════════"
	@echo "Memory Usage Comparison"
	@echo "═══════════════════════════════════════════════════════════════"
	@echo ""
	@echo "=== Python STT Service ==="
	@kubectl top pod -l app=stt-service 2>/dev/null || echo "Python service not running"
	@echo ""
	@echo "=== Java STT Service ==="
	@kubectl top pod -l app=stt-java-service 2>/dev/null || echo "Java service not running"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════"

load-test-java: ## Run load test against Java service
	@if [ ! -f ".env.k6" ]; then \
		echo "Error: .env.k6 not found"; \
		exit 1; \
	fi
	@echo "Running load test against Java STT service..."
	@K6_TARGET_PORT=30880 ./scripts/run-load-test.sh load-test.js
