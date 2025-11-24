# Local Cluster Deployment Guide

This guide explains how to deploy the STT microservice to a local Minikube cluster with Prometheus and Grafana monitoring.

## Quick Start

```bash
# Deploy everything with a single command
make deploy-local
```

This command will:

- Start Minikube cluster (if not running)
- Install Prometheus and Grafana via Helm
- Build the Docker image in Minikube's context
- Create Kubernetes ConfigMap from `.env` file
- Deploy the STT service with 1 replica
- Configure metrics collection and dashboards

Access the services:

```bash
# Grafana dashboard (default credentials: admin/admin)
make local-grafana

# Prometheus UI
make local-prometheus

# STT API (from within cluster or port-forward)
kubectl port-forward svc/stt-service 8000:8000
```

## What Gets Deployed

### Architecture

```
┌─────────────────────────────────────────────────┐
│              Minikube Cluster                   │
│                                                 │
│  ┌──────────────────┐     ┌─────────────────┐   │
│  │   STT Service    │────▶│   Prometheus    │   │
│  │  (1 replica)     │     │  (via Helm)     │   │
│  │  Port: 8000      │     │  Port: 9090     │   │
│  │  /metrics        │     └────────┬────────┘   │
│  └──────────────────┘              │            │
│         ▲                          │            │
│         │                          ▼            │
│         │                  ┌─────────────────┐  │
│         │                  │    Grafana      │  │
│         │                  │  (via Helm)     │  │
│         └──────────────────│  Port: 3000     │  │
│          HTTP Requests     └─────────────────┘  │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Components

- **STT Service**: FastAPI application with 1GB memory limit, exposing `/metrics` endpoint
- **Prometheus**: Metrics collection and storage, scrapes `/metrics` every 15 seconds
- **Grafana**: Visualization dashboards for CPU, memory, and HTTP metrics
- **ServiceMonitor**: Custom resource that configures Prometheus scraping

### Resource Allocation

- **CPU**: 100m (request) / 1000m (limit)
- **Memory**: 256Mi (request) / 1Gi (limit)
- **Replicas**: 1 (configurable)

## Prerequisites

### Required Tools

1. **Minikube** (v1.28.0+)

   ```bash
   # macOS
   brew install minikube
   
   # Linux
   curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
   sudo install minikube-linux-amd64 /usr/local/bin/minikube
   ```

2. **kubectl** (v1.28.0+)

   ```bash
   # macOS
   brew install kubectl
   
   # Linux
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   ```

3. **Helm** (v3.10.0+)

   ```bash
   # macOS
   brew install helm
   
   # Linux
   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
   ```

4. **Docker** (for building images)

   ```bash
   # Already installed in dev container
   docker --version
   ```

### System Requirements

- **CPU**: 2+ cores
- **Memory**: 4GB+ available RAM
- **Disk**: 20GB+ free space

## Step-by-Step Setup

### 1. Prepare Environment Variables

Ensure your `.env` file exists with required Azure configuration:

```bash
# Check if .env exists
ls -la .env

# Example .env content (yours may differ)
APP_ENV=dev
APP_LOG_LEVEL=INFO
STT_AZURE_SPEECH_RESOURCE_NAME=your-resource-name
STT_AZURE_SPEECH_REGION=swedencentral
STT_MAX_FILE_SIZE_MB=100
STT_MAX_DURATION_MINUTES=120
```

### 2. Start Minikube Cluster

```bash
# Start cluster with adequate resources
make setup-local-cluster
```

This command:

- Creates a Minikube profile named `stt-microservice`
- Allocates 2 CPUs and 4GB RAM
- Enables necessary addons (metrics-server)
- Installs Helm charts for Prometheus and Grafana

**Expected output:**

```
✓ Starting Minikube cluster 'stt-microservice'...
✓ Installing Prometheus (bitnami/kube-prometheus)...
✓ Installing Grafana (bitnami/grafana)...
✓ Cluster ready
```

**Verify cluster:**

```bash
# Check Minikube status
minikube status -p stt-microservice

# Check nodes
kubectl get nodes

# Check monitoring pods
kubectl get pods -l app.kubernetes.io/name=kube-prometheus
kubectl get pods -l app.kubernetes.io/name=grafana
```

### 3. Build Docker Image

The deployment script builds the image directly in Minikube's Docker daemon:

```bash
# This happens automatically during 'make deploy-local'
# Or manually:
eval $(minikube -p stt-microservice docker-env)
docker build -t stt-service:latest -f src/Dockerfile .
```

**Why?** Building in Minikube's context avoids image pull issues and speeds up deployment.

### 4. Deploy STT Service

```bash
# Full deployment (includes steps 1-3)
make deploy-local
```

The deployment process:

1. Creates ConfigMap from `.env` file
2. Applies Kubernetes manifests (Deployment, Service, ServiceMonitor)
3. Waits for pod to be ready
4. Verifies metrics endpoint

**Expected output:**

```
✓ ConfigMap 'stt-config' created
✓ Deployment 'stt-service' created
✓ Service 'stt-service' created
✓ ServiceMonitor 'stt-monitor' created
✓ Waiting for rollout to complete...
✓ Deployment successful
```

**Verify deployment:**

```bash
# Check pod status
kubectl get pods -l app=stt-service

# Check logs
kubectl logs -l app=stt-service -f

# Test metrics endpoint
kubectl exec -it $(kubectl get pod -l app=stt-service -o jsonpath='{.items[0].metadata.name}') -- curl localhost:8000/metrics
```

### 5. Import Grafana Dashboard

```bash
# The dashboard is automatically imported during deployment
# Verify it exists:
make local-grafana
# Navigate to Dashboards → STT Microservice
```

## Accessing Services

### Grafana Dashboard

```bash
# Start port-forward (runs in background)
make local-grafana
```

Then open: <http://localhost:3000>

**Default credentials:**

- Username: `admin`
- Password: Get from secret:

  ```bash
  kubectl get secret grafana-admin --namespace default -o jsonpath="{.data.GF_SECURITY_ADMIN_PASSWORD}" | base64 -d
  echo
  ```

**Available dashboards:**

- STT Microservice Overview (CPU, Memory, HTTP metrics)
- Kubernetes Cluster Monitoring (Node metrics)

### Prometheus UI

```bash
# Start port-forward
make local-prometheus
```

Then open: <http://localhost:9090>

**Useful queries:**

```promql
# HTTP request rate
rate(http_requests_total[5m])

# Request latency (p95)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Memory usage
container_memory_usage_bytes{pod=~"stt-service.*"}

# CPU usage
rate(container_cpu_usage_seconds_total{pod=~"stt-service.*"}[5m])
```

### STT API Endpoint

```bash
# Port-forward to access locally
kubectl port-forward svc/stt-service 8000:8000

# Test in another terminal
curl http://localhost:8000/docs
```

## Configuration

### Environment Variables

Modify `.env` file and redeploy:

```bash
# Edit .env
nano .env

# Redeploy with new configuration
kubectl delete configmap stt-config
kubectl create configmap stt-config --from-env-file=.env
kubectl rollout restart deployment/stt-service
```

### Resource Limits

Edit `k8s/deployment.yaml`:

```yaml
resources:
  requests:
    cpu: "100m"      # Minimum guaranteed
    memory: "256Mi"
  limits:
    cpu: "1000m"     # Maximum allowed
    memory: "1Gi"
```

Apply changes:

```bash
kubectl apply -f k8s/deployment.yaml
```

### Scaling Replicas

```bash
# Scale to 3 replicas
kubectl scale deployment/stt-service --replicas=3

# Or edit deployment.yaml
# spec:
#   replicas: 3

# Verify
kubectl get pods -l app=stt-service
```

## Monitoring & Metrics

### Available Metrics

The STT service exposes the following Prometheus metrics at `/metrics`:

**HTTP Metrics** (from prometheus-fastapi-instrumentator):

- `http_requests_total` - Total number of HTTP requests
- `http_request_duration_seconds` - Request latency histogram
- `http_request_size_bytes` - Request body size summary
- `http_response_size_bytes` - Response body size summary
- `http_requests_inprogress` - Current number of requests being processed

**System Metrics** (from Kubernetes):

- `container_cpu_usage_seconds_total` - CPU usage
- `container_memory_usage_bytes` - Memory usage
- `container_network_receive_bytes_total` - Network ingress
- `container_network_transmit_bytes_total` - Network egress

### Dashboard Panels

The Grafana dashboard includes:

1. **Request Rate**: Requests per second over time
2. **Request Latency**: P50, P95, P99 latencies
3. **Error Rate**: 4xx and 5xx response percentages
4. **CPU Usage**: Current and average CPU utilization
5. **Memory Usage**: Current memory with limit threshold
6. **Active Requests**: Number of concurrent requests

### Custom Metrics

To add custom metrics, modify `src/main.py`:

```python
from prometheus_client import Counter

custom_counter = Counter('stt_transcriptions_total', 'Total transcriptions')

# In your endpoint:
custom_counter.inc()
```

## Troubleshooting

### Pod Stuck in Pending

**Symptoms:** Pod doesn't start, status shows `Pending`

**Diagnosis:**

```bash
kubectl describe pod -l app=stt-service
```

**Common causes:**

- Insufficient resources: Increase Minikube resources

  ```bash
  minikube delete -p stt-microservice
  minikube start -p stt-microservice --cpus=4 --memory=8192
  ```

- Image pull error: Ensure image is built in Minikube context

  ```bash
  eval $(minikube -p stt-microservice docker-env)
  docker images | grep stt-service
  ```

### Pod CrashLoopBackOff

**Symptoms:** Pod repeatedly restarts

**Diagnosis:**

```bash
# Check logs
kubectl logs -l app=stt-service --previous

# Common issues:
# 1. Missing environment variables
kubectl describe configmap stt-config

# 2. Azure authentication issues
kubectl logs -l app=stt-service | grep -i "auth\|credential\|azure"

# 3. Port already in use
kubectl get svc
```

**Solutions:**

- Verify `.env` file is complete
- Check Azure credentials and permissions
- Ensure no port conflicts

### Metrics Not Appearing in Prometheus

**Diagnosis:**

```bash
# Check ServiceMonitor
kubectl get servicemonitor stt-monitor -o yaml

# Check if Prometheus is scraping
kubectl logs -l app.kubernetes.io/name=kube-prometheus-prometheus | grep stt

# Test metrics endpoint directly
kubectl exec -it $(kubectl get pod -l app=stt-service -o jsonpath='{.items[0].metadata.name}') -- curl localhost:8000/metrics
```

**Solutions:**

- Verify service labels match ServiceMonitor selector
- Ensure `/metrics` endpoint returns data
- Check Prometheus targets: <http://localhost:9090/targets>

### Grafana Dashboard Not Loading

**Diagnosis:**

```bash
# Check Grafana pod
kubectl get pods -l app.kubernetes.io/name=grafana

# Check logs
kubectl logs -l app.kubernetes.io/name=grafana
```

**Solutions:**

- Reimport dashboard: `kubectl apply -f k8s/grafana-dashboard.json`
- Verify Prometheus data source is configured
- Check network connectivity between Grafana and Prometheus

### Out of Memory Issues

**Symptoms:** Pod OOMKilled, restarts frequently

**Diagnosis:**

```bash
kubectl describe pod -l app=stt-service | grep -A 5 "Last State"
```

**Solutions:**

- Increase memory limit in `k8s/deployment.yaml`
- Reduce file size limits in `.env` (`STT_MAX_FILE_SIZE_MB`)
- Monitor actual usage to determine appropriate limits

### Commands for Debugging

```bash
# Get all resources
kubectl get all -l app=stt-service

# Describe deployment
kubectl describe deployment stt-service

# Interactive shell in pod
kubectl exec -it $(kubectl get pod -l app=stt-service -o jsonpath='{.items[0].metadata.name}') -- /bin/sh

# Port-forward for direct access
kubectl port-forward $(kubectl get pod -l app=stt-service -o jsonpath='{.items[0].metadata.name}') 8000:8000

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep stt-service

# Resource usage
kubectl top pods -l app=stt-service
kubectl top nodes
```

## Cleanup

### Remove Deployment Only

```bash
# Delete STT service resources
kubectl delete -f k8s/

# Remove ConfigMap
kubectl delete configmap stt-config
```

### Remove Everything

```bash
# Uninstall Helm releases
helm uninstall prometheus
helm uninstall grafana

# Delete Minikube cluster
minikube delete -p stt-microservice
```

### Partial Cleanup

```bash
# Stop cluster (keep data)
minikube stop -p stt-microservice

# Start again later
minikube start -p stt-microservice
```

## Advanced Configuration

### Custom Helm Values

Override default Prometheus/Grafana settings:

```bash
# Create values file
cat > prometheus-values.yaml <<EOF
prometheus:
  retention: 7d
  resources:
    requests:
      memory: 512Mi
EOF

# Upgrade release
helm upgrade prometheus bitnami/kube-prometheus -f prometheus-values.yaml
```

### Enable Ingress

```bash
# Enable ingress addon
minikube addons enable ingress -p stt-microservice

# Create ingress resource
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: stt-ingress
spec:
  rules:
  - host: stt.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: stt-service
            port:
              number: 8000
EOF

# Add to /etc/hosts
echo "$(minikube ip -p stt-microservice) stt.local" | sudo tee -a /etc/hosts
```

### Persistent Storage

Add volume for caching:

```yaml
# In k8s/deployment.yaml
spec:
  template:
    spec:
      volumes:
      - name: cache
        emptyDir: {}
      containers:
      - name: stt-service
        volumeMounts:
        - name: cache
          mountPath: /app/cache
```

## Next Steps

- **Load Testing**: Run k6 tests against the local deployment

  ```bash
  # Point k6 to local service
  export STT_API_URL=http://$(minikube ip -p stt-microservice):$(kubectl get svc stt-service -o jsonpath='{.spec.ports[0].nodePort}')
  ./scripts/run-load-test.sh load-test.js
  ```

- **Production Deployment**: Adapt manifests for cloud Kubernetes (AKS, EKS, GKE)
- **CI/CD Integration**: Automate deployment with GitHub Actions
- **Security Hardening**: Add network policies, pod security policies, secrets management

## References

- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [prometheus-fastapi-instrumentator](https://github.com/trallnag/prometheus-fastapi-instrumentator)
