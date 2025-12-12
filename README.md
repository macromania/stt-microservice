# STT Microservice

This repository contains a Speech-to-Text (STT) microservice built using FastAPI and integrated with Azure Speech Service for transcription. The service allows users to upload audio files and receive transcribed text in response.

## Load Testing with k6

The microservice has been load tested using the k6 framework to ensure its performance and reliability under high traffic conditions. The tests utilize the LibriSpeech dataset for realistic audio input and target the `/transcriptions/process-isolated` endpoint by default, which prevents memory leaks through process-level isolation.

### Prerequisites

**k6 Load Testing Tool (Host Machine Only):**

⚠️ **Important**: k6 must be installed on your **host machine**, not inside the DevContainer. Load tests should be run from the host to generate realistic network load against the Minikube cluster.

Install k6 on your host machine:

- **macOS**: `brew install k6`
- **Linux/Windows**: See [k6 installation guide](https://k6.io/docs/get-started/installation/)

**DevContainer Dependencies (Pre-installed):**

If you're using the provided DevContainer, the following are already available:

- Docker (for Minikube)
- kubectl and Helm
- Minikube
- All required CLI tools

**Running Outside DevContainer:**

If not using the DevContainer, install these tools manually on your host:

- **Minikube**: Local Kubernetes cluster ([installation guide](https://minikube.sigs.k8s.io/docs/start/))
- **kubectl**: Kubernetes CLI ([installation guide](https://kubernetes.io/docs/tasks/tools/))
- **Helm**: Kubernetes package manager ([installation guide](https://helm.sh/docs/intro/install/))
- **Docker**: Container runtime (required by Minikube)

### One-Time Setup

#### 1. Provision Azure Resources

Set up Azure AI Foundry resources and authentication:

```bash
make provision
```

This interactive script:

- Creates Azure AI Foundry resource and project
- Configures RBAC permissions for your user
- Generates `.env` file with Azure credentials

The `.env` file contains:

- `STT_AZURE_SPEECH_RESOURCE_NAME`: Your Azure AI Foundry resource name
- `STT_AZURE_SPEECH_REGION`: Azure region (e.g., `eastus`)
- Other application settings

The API loads these settings at startup to authenticate with Azure Speech Service using DefaultAzureCredential (no API keys needed). The `.env` file is also used by Kubernetes as a ConfigMap during deployment.

#### 2. Download LibriSpeech Dataset

Generate the audio files list for load testing (~350MB download):

```bash
make generate-audio-list
```

This downloads the LibriSpeech test-clean dataset (2,620 audio files) and creates `samples/audio-files.json`.

#### 3. Deploy Local Minikube Cluster

Deploy the local Minikube cluster with monitoring infrastructure:

```bash
# Deploy STT service with Prometheus and Grafana
make deploy-local
```

This sets up:

- Minikube cluster with the STT service
- Prometheus for metrics collection
- Grafana for visualization

#### 4. Configure Load Test Settings

Create and configure your load test settings:

```bash
# Create configuration file
cp .env.k6.example .env.k6

# Edit .env.k6 to configure:
# - BASE_URL: Will be set from make local-api output
# - TEST_MODE: Choose from smoke, load, stress, or soak
# - Load parameters: MAX_VUS, durations, etc.
```

**Why .env.k6?** All load test configuration is centralized in `.env.k6` for:

- **Consistency**: Same configuration across all test runs
- **Reproducibility**: Easy to version control and share test parameters
- **Flexibility**: Override any setting without modifying test scripts
- **CI/CD Ready**: Environment-based configuration for automated testing

### Running Load Tests

The typical development loop: **change code → deploy → test → monitor → iterate**

#### 1. Start the Service Tunnel

In a **separate terminal session**, start the Minikube service tunnel for load-balanced access:

```bash
make local-api
```

This displays the service URL (e.g., `http://127.0.0.1:xxxxx`). **Keep this terminal open** during testing.

Copy the URL and update `BASE_URL` in your `.env.k6` file.

#### 2. Run Load Test

In your main terminal, execute the load test:

```bash
make load-test
```

This runs the configured test pattern (default: `load` mode with 100 VUs over 20 minutes). The test:

- Sends requests to `/transcriptions/process-isolated` endpoint
- Uses random LibriSpeech audio files for realistic workload
- Reports metrics in real-time and generates an HTML report

#### 3. Monitor Results in Grafana

Open Grafana to visualize metrics during and after testing:

```bash
make local-grafana
```

Access Grafana at `http://localhost:3000`:

- **Username**: `admin`
- **Password**: Displayed in terminal output

Import the STT dashboard:

```bash
make import-grafana-dashboard
```

The dashboard shows:

- Request rate and latency (P50, P95, P99)
- Memory usage per pod (tracking leak prevention)
- Transcription duration and confidence metrics
- Process pool health and timeout counters
- Error rates and success rates

**Development Loop**: After making code changes, redeploy with `make deploy-local`, run `make load-test`, and check Grafana to validate improvements in performance or memory behavior.

### Demonstrating Memory Leak vs Process Isolation

To understand why the process-isolated endpoint is the default, you can test the memory leak behavior with the standard thread-based endpoint.

#### Testing the Memory Leak (Thread-Based Endpoint)

Edit your `.env.k6` to change the endpoint:

```bash
# Add/modify in .env.k6:
ENDPOINT=/transcriptions
TEST_MODE=smoke  # Use short test to see leak quickly
```

Run the load test and watch Grafana's memory panel:

```bash
make load-test
```

**What you'll observe:**

- Memory steadily increases with each request (~260MB per request)
- Memory never gets reclaimed (native C++ SDK leaks)
- After 20-25 requests: Pod memory exceeds 6GB limit → OOMKilled

#### Testing Process Isolation (Default)

Reset the endpoint to process-isolated in your `.env.k6`:

```bash
# Modify in .env.k6:
ENDPOINT=/transcriptions/process-isolated
```

Run the same test:

```bash
make load-test
```

**What you'll observe:**

- Memory remains stable across all requests
- Parent process memory stays constant (~100-200MB)
- No OOMKills regardless of request count

#### Why Process Isolation Fixes This

**Thread-Based (`/transcriptions`):**

- Runs in main process using ThreadPoolExecutor
- Native memory (Azure SDK C++ allocations) leaks in process heap
- Python's garbage collector can't see or free native memory
- Memory accumulates: 100MB → 360MB → 620MB → 880MB → OOMKilled

**Process-Isolated (`/transcriptions/process-isolated`):**

- Each request runs in a separate child process
- Child process exits after transcription completes
- **OS forcibly reclaims ALL memory** (Python + native allocations)
- Parent process memory stays constant indefinitely
- **Worker recycling**: Pool workers automatically restart after 100 tasks, refreshing any accumulated memory
- **Idle cleanup**: When no requests are active, workers remain idle (not consuming transcription memory)

The trade-off: Process isolation shows ~4-5 seconds higher average request duration compared to thread-based processing (16s vs 11s average), but guarantees zero memory leaks for 24/7 operation. This overhead comes from inter-process communication and pool management, not from spawning new processes per request. The process pool (12 workers with recycling) maintains warm worker processes that are reused across requests, making the isolation cost relatively small compared to the memory safety benefits.

### Feature Flag: Disabling Process-Isolated Endpoint

For testing or debugging purposes, you can completely disable the `/transcriptions/process-isolated` endpoint and prevent worker process creation. This allows clean isolation testing of the `/transcriptions/sync` endpoint without process-isolated workers.

**To disable the process-isolated endpoint:**

```bash
# In your .env file or as environment variable
ENABLE_PROCESS_ISOLATED=false
```

**What happens when disabled:**

- `/transcriptions/process-isolated` endpoint returns `503 Service Unavailable`
- No worker processes are created (0 workers)
- Memory metrics show only parent process (workers = 0 GiB)
- `/transcriptions/sync` endpoint remains fully functional
- Pool recycler and worker monitoring are automatically disabled

**Use cases:**

- **Testing `/sync` endpoint in isolation**: Verify memory behavior without worker process interference
- **Memory debugging**: Isolate parent process memory from worker memory
- **Resource optimization**: Reduce memory footprint when process isolation isn't needed
- **Development**: Faster startup during local development

**To re-enable (default):**

```bash
ENABLE_PROCESS_ISOLATED=true
# Or simply remove the variable (defaults to true)
```

The feature flag is documented in `.env.example` with all other configuration options.

### Configuration

Key settings in `.env.k6`:

- `BASE_URL`: Target API endpoint (from `make local-api` output)
- `ENDPOINT`: API endpoint path (default: `/transcriptions/process-isolated`)
- `TEST_MODE`: Preset patterns (`smoke`, `load`, `stress`, `soak`)
- `MAX_VUS`: Maximum virtual users for custom load patterns
- Load durations: `RAMP_UP_DURATION`, `STEADY_DURATION`, `RAMP_DOWN_DURATION`

More details about test modes, advanced configuration, and results can be found in the [Load Testing Guide](./docs/load-testing.md).

### Test Results Summary

Extensive load testing has validated the memory leak fix and performance characteristics:

- **Memory Leak Confirmed**: Thread-based endpoint leaks ~260MB per request, hitting 6GB limit after 20-25 requests
- **Process Isolation Works**: Memory remains stable indefinitely with process-isolated endpoint
- **Horizontal Scaling Wins**: 3 pods with 1 CPU each (5.24 req/s) outperforms 1 pod with 2 CPUs (2.78 req/s) by 88%
- **Performance Trade-off**: Process isolation adds ~4-5s average overhead but guarantees zero memory leaks

See [detailed test results](./docs/test-results.md) for detailed analysis, performance comparisons, and Grafana dashboard screenshots showing memory behavior under load.

## Azure Deployment

Deploy the STT microservice to Azure Container Apps with a two-step workflow:

### 1. One-Time Infrastructure Setup

```bash
make provision
```

Creates Azure AI Foundry resources, Container Registry, Container Apps Environment, managed identities with RBAC, and generates `.env` configuration (see [Provision Azure Resources](#1-provision-azure-resources) above).

### 2. Fast Iterative Deployments

```bash
make deploy-azure
```

Builds Docker images using ACR native build tasks, pushes to registry, and updates Container Apps with new images. Generates `env.remote` with service URLs for testing. Run this after code changes for quick redeployment without infrastructure modifications.

## Local Deployment to Minikube

The microservice can be deployed to a local Minikube cluster with Prometheus and Grafana for monitoring. The deployment includes automatic metrics collection for CPU, memory usage, and HTTP request metrics.

```bash
# Deploy everything in one command
make deploy-local
```

This will set up a complete local Kubernetes environment with the STT service, Prometheus for metrics scraping, and Grafana with pre-configured dashboards. For detailed setup instructions, configuration options, and troubleshooting, see the [Local Cluster Deployment Guide](./docs/local-cluster.md).
