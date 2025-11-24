# Load Balancing in Kubernetes - Important Information

## The Problem: kubectl port-forward Routes to a Single Pod

When you use `kubectl port-forward svc/stt-service 8000:8000`, it creates a direct tunnel to **one specific pod**, bypassing the Kubernetes service load balancer entirely. This means:

- All requests go to a single pod
- Other pods remain idle
- You cannot test real load distribution
- Memory and CPU usage is concentrated on one pod

## The Solution: Use NodePort Service

We've changed the service type from `ClusterIP` to `NodePort`. This allows external access with proper load balancing.

### For Load Testing (Multi-Pod Distribution)

Use the minikube service URL which properly routes through the Kubernetes service:

```bash
# Get the service URL
SERVICE_URL=$(./scripts/get-service-url.sh)
echo $SERVICE_URL
# Output: http://192.168.49.2:31234 (example)

# Run load test with proper load balancing
./scripts/run-load-test.sh -e BASE_URL=$SERVICE_URL -e TEST_MODE=smoke load-test.js
```

### For Quick Manual Testing (Single Pod)

If you just want to test the API manually (not load distribution):

```bash
kubectl port-forward -n default svc/stt-service 8000:8000
# Open: http://localhost:8000/docs
```

## Why This Matters

### With kubectl port-forward (❌ Wrong for Load Testing)
```
Load Test → kubectl tunnel → Single Pod
                              Pod 1: 100% traffic ⚠️
                              Pod 2: 0% traffic
                              Pod 3: 0% traffic
```

### With NodePort/Service URL (✅ Correct for Load Testing)
```
Load Test → Minikube NodePort → Kubernetes Service → Load Balancer
                                                    ↓
                                    ┌───────────────┼───────────────┐
                                    ↓               ↓               ↓
                                  Pod 1           Pod 2           Pod 3
                                  ~33%            ~33%            ~33%
```

## Additional Configuration: Connection Reuse

The load test script (`load-test.js`) has been configured with:

```javascript
noConnectionReuse: true
```

This ensures each HTTP request creates a new TCP connection, allowing the Kubernetes service to properly distribute requests. Without this, k6 would reuse connections and all requests from a single virtual user would go to the same pod.

## Verifying Load Distribution

After running a load test, check the Grafana dashboard or use kubectl:

```bash
# Check memory usage across pods
kubectl top pods -l app=stt-service

# Expected output (balanced):
NAME                           CPU(cores)   MEMORY(bytes)
stt-service-xxx-pod1          250m         600Mi
stt-service-xxx-pod2          240m         580Mi
stt-service-xxx-pod3          260m         620Mi

# Bad output (unbalanced - indicates port-forward was used):
NAME                           CPU(cores)   MEMORY(bytes)
stt-service-xxx-pod1          800m         1.6Gi  ⚠️
stt-service-xxx-pod2          10m          60Mi
stt-service-xxx-pod3          10m          60Mi
```

## Quick Reference

| Use Case | Method | Load Balanced? |
|----------|--------|----------------|
| Load testing multiple pods | `minikube service --url` + load test | ✅ Yes |
| Manual API testing | `kubectl port-forward` | ❌ No (single pod) |
| Production testing | External URL/Ingress | ✅ Yes |

## Helper Scripts

- `./scripts/get-service-url.sh` - Get the proper load-balanced service URL
- `./scripts/run-load-test.sh` - Run load tests (use with BASE_URL parameter)
- `./scripts/deploy-local.sh` - Deploy and get access instructions
