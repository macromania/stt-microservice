# Make exit on the first error for all commands by default
.SHELLFLAGS = -e -c 

.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-23s\033[0m %s\n", $$1, $$2}'

# Development Environment
restore: ## Install all dependencies (backend)
	@./scripts/restore.sh

run-api: ## Run the FastAPI application (development mode with auto-reload)
	@echo "[$$(date '+%Y-%m-%d %H:%M:%S')] Starting FastAPI in development mode..."
	@poetry run uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload
