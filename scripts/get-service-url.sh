#!/usr/bin/env bash

# Get the proper load-balanced service URL for testing
# This script ensures you're testing with proper load distribution across all pods

set -euo pipefail

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-stt-microservice}"
NAMESPACE="${NAMESPACE:-default}"
SERVICE_NAME="stt-service"

# Check if minikube is running
if ! minikube status -p "${MINIKUBE_PROFILE}" &>/dev/null; then
    echo "Error: Minikube profile '${MINIKUBE_PROFILE}' is not running" >&2
    echo "Start it with: minikube start -p ${MINIKUBE_PROFILE}" >&2
    exit 1
fi

# Get the service URL
SERVICE_URL=$(minikube service "${SERVICE_NAME}" -p "${MINIKUBE_PROFILE}" -n "${NAMESPACE}" --url 2>/dev/null)

if [ -z "${SERVICE_URL}" ]; then
    echo "Error: Could not get service URL" >&2
    echo "Make sure the service is deployed: kubectl get svc ${SERVICE_NAME}" >&2
    exit 1
fi

echo "${SERVICE_URL}"
