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

#### 1. Download LibriSpeech Dataset

Generate the audio files list for load testing (~350MB download):

```bash
make generate-audio-list
```

This downloads the LibriSpeech test-clean dataset (2,620 audio files) and creates `samples/audio-files.json`.

#### 2. Deploy Local Minikube Cluster

Deploy the local Minikube cluster with monitoring infrastructure:

```bash
# Deploy STT service with Prometheus and Grafana
make deploy-local
```

This sets up:

- Minikube cluster with the STT service
- Prometheus for metrics collection
- Grafana for visualization

#### 3. Configure Load Test Settings

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

### Configuration

Key settings in `.env.k6`:

- `BASE_URL`: Target API endpoint (from `make local-api` output)
- `TEST_MODE`: Preset patterns (`smoke`, `load`, `stress`, `soak`)
- `MAX_VUS`: Maximum virtual users for custom load patterns
- Load durations: `RAMP_UP_DURATION`, `STEADY_DURATION`, `RAMP_DOWN_DURATION`

More details about test modes, advanced configuration, and results can be found in the [Load Testing Guide](./docs/load-testing.md).

## Local Deployment to Minikube

The microservice can be deployed to a local Minikube cluster with Prometheus and Grafana for monitoring. The deployment includes automatic metrics collection for CPU, memory usage, and HTTP request metrics.

```bash
# Deploy everything in one command
make deploy-local
```

This will set up a complete local Kubernetes environment with the STT service, Prometheus for metrics scraping, and Grafana with pre-configured dashboards. For detailed setup instructions, configuration options, and troubleshooting, see the [Local Cluster Deployment Guide](./docs/local-cluster.md).
