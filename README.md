# STT Microservice

This repository contains a Speech-to-Text (STT) microservice built using FastAPI and integrated with Azure Speech Service for transcription. The service allows users to upload audio files and receive transcribed text in response.

## Load Testing with k6

The microservice has been load tested using the k6 framework to ensure its performance and reliability under high traffic conditions. The tests utilized the LibriSpeech dataset for realistic audio input.

More details about the load testing setup, configuration, and results can be found in the [Load Testing Guide](./docs/load-testing.md).

## Local Deployment to Minikube

The microservice can be deployed to a local Minikube cluster with Prometheus and Grafana for monitoring. The deployment includes automatic metrics collection for CPU, memory usage, and HTTP request metrics.

```bash
# Deploy everything in one command
make deploy-local
```

This will set up a complete local Kubernetes environment with the STT service, Prometheus for metrics scraping, and Grafana with pre-configured dashboards. For detailed setup instructions, configuration options, and troubleshooting, see the [Local Cluster Deployment Guide](./docs/local-cluster.md).
