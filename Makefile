# Make exit on the first error for all commands by default
.SHELLFLAGS = -e -c 

.DEFAULT_GOAL := help

help: ## Show this help message
	@grep -E '[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-23s\033[0m %s\n", $$1, $$2}'

# Development Environment
restore: ## Install all dependencies (backend)
	@./scripts/restore.sh
