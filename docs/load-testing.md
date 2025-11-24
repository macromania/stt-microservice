# Load Testing Guide

This guide explains how to run load tests against the STT API using k6 and the LibriSpeech dataset.

## Quick Start

### Testing Against Local Minikube Cluster

**IMPORTANT:** For proper load balancing across multiple pods, you MUST use the minikube service URL, NOT `kubectl port-forward`.

```bash
# 1. Get the service URL (this uses NodePort for proper load balancing)
minikube service stt-service -p stt-microservice -n default --url
# Example output: http://192.168.49.2:31234

# 2. Run load test with that URL
./scripts/run-load-test.sh -e BASE_URL=http://192.168.49.2:31234 load-test.js

# Or run specific test modes
./scripts/run-load-test.sh -e TEST_MODE=smoke -e BASE_URL=http://192.168.49.2:31234 load-test.js
```

**Why?** `kubectl port-forward` creates a tunnel to a single pod, bypassing the Kubernetes service load balancer. Using the minikube service URL ensures requests are distributed across all pods.

### Testing Against Production

```bash
# Use the external URL
./scripts/run-load-test.sh -e BASE_URL=https://your-api.example.com load-test.js
```

The `run-load-test.sh` wrapper automatically:

- Downloads LibriSpeech dataset if needed (~350MB, one-time)
- Generates audio files list on-the-fly
- Loads configuration from `.env.k6`
- Runs k6 with your specified options

### Manual Approach

```bash
# 1. Download dataset (one-time setup)
./scripts/generate-audio-list.sh

# 2. Run tests directly with k6
export $(cat .env.k6 | grep -v '^#' | xargs) && k6 run -e TEST_MODE=smoke load-test.js
export $(cat .env.k6 | grep -v '^#' | xargs) && k6 run load-test.js
```

## Prerequisites

### 1. Install k6

**macOS:**

```bash
brew install k6
```

**Linux:**

```bash
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

**Windows:**

```powershell
choco install k6
```

### 2. Download Dataset (Optional - Automatic)

The load test uses the LibriSpeech test-clean dataset (2,620 FLAC audio files, ~350MB).

**Automatic:** The `run-load-test.sh` wrapper downloads it automatically on first run.

**Manual:** Download explicitly with:

```bash
./scripts/generate-audio-list.sh
```

This script will:

- Download the dataset from <https://openslr.trmal.net/resources/12/test-clean.tar.gz>
- Extract it to `samples/test-clean/`
- Generate `samples/audio-files.json` with all file paths (temporary, not committed to git)

## Configuration

### Environment Variables

Configuration is managed via `.env.k6` file. Copy from example:

```bash
cp .env.k6.example .env.k6
```

Key configuration options:

| Variable | Default | Description |
|----------|---------|-------------|
| `TEST_MODE` | `load` | Preset: `smoke`, `load`, `stress`, `soak` |
| `MAX_VUS` | `100` | Maximum virtual users |
| `RAMP_UP_DURATION` | `10m` | Time to reach max VUs |
| `STEADY_DURATION` | `5m` | Time to maintain max VUs |
| `RAMP_DOWN_DURATION` | `5m` | Time to ramp down to 0 |
| `RAMP_STEPS` | `4` | Intermediate ramp stages |
| `BASE_URL` | `http://localhost:8000` | API base URL |
| `LANGUAGE` | `en-US` | Target language |
| `USE_RANDOM_AUDIO` | `true` | Use random files vs single file |
| `AUDIO_DIR` | `samples/test-clean` | LibriSpeech directory |
| `AUDIO_FILES_LIST` | `samples/audio-files.json` | File list (auto-generated) |
| `REQUEST_TIMEOUT_MS` | `180000` | Request timeout (3 min) |
| `K6_WEB_DASHBOARD` | `false` | Enable web dashboard for real-time visualization |

### Test Mode Presets

#### Smoke Test

Quick validation with minimal load:

- 1 VU
- 30s ramp-up, 1m steady, 30s ramp-down
- Total: 2 minutes

```bash
./scripts/run-load-test.sh -e TEST_MODE=smoke load-test.js
```

#### Load Test (Default)

Standard load testing:

- 100 VUs
- 10m ramp-up, 5m steady, 5m ramp-down
- Total: 20 minutes

```bash
./scripts/run-load-test.sh -e TEST_MODE=load load-test.js
# or simply:
./scripts/run-load-test.sh load-test.js
```

#### Stress Test

High load to find breaking points:

- 200 VUs
- 15m ramp-up, 10m steady, 5m ramp-down
- Total: 30 minutes

```bash
./scripts/run-load-test.sh -e TEST_MODE=stress load-test.js
```

#### Soak Test

Extended duration for stability:

- 50 VUs
- 5m ramp-up, 60m steady, 5m ramp-down
- Total: 70 minutes

```bash
./scripts/run-load-test.sh -e TEST_MODE=soak load-test.js
```

## Web Dashboard

k6 provides a real-time web dashboard for monitoring test execution with interactive charts and metrics.

**Requirements:** k6 v0.47.0 or later

### Upgrade k6

If you have an older version, upgrade to enable the web dashboard:

```bash
# macOS
brew upgrade k6

# Linux (Debian/Ubuntu)
sudo apt-get update
sudo apt-get install --only-upgrade k6

# Or download latest from https://github.com/grafana/k6/releases
```

Check your version:

```bash
k6 version
```

### Enable Web Dashboard

Set `K6_WEB_DASHBOARD=true` in your `.env.k6` file or pass it as an environment variable:

```bash
# Option 1: Set in .env.k6
K6_WEB_DASHBOARD=true

# Option 2: Pass as environment variable
./scripts/run-load-test.sh -e K6_WEB_DASHBOARD=true load-test.js
```

### Access Dashboard

Once enabled, the dashboard is available at:

```
http://127.0.0.1:5665
```

Open this URL in your browser while the test is running to view:

- Real-time metrics and charts
- Active VUs and request rates
- Response times (p50, p90, p95, p99)
- Error rates and trends
- Custom metrics visualization

### Automatic Report Saving

When the web dashboard is enabled, test reports are **automatically saved** with timestamps:

```
reports/k6-report-2025-11-24-143052.html
reports/k6-report-2025-11-24-154521.html
reports/k6-report-2025-11-24-161203.html
```

**Filename format:** `k6-report-YYYY-MM-DD-HHMMSS.html`

Each report is a standalone HTML file containing:

- Complete test results and metrics
- Interactive charts and visualizations
- Request/response statistics
- Error details
- Can be opened in any browser
- Can be shared or archived

The `reports/` directory is automatically created and excluded from git (via `.gitignore`).

### Custom Dashboard Host

To expose the dashboard on a different host/port (e.g., for remote access):

```bash
K6_WEB_DASHBOARD_HOST=0.0.0.0:5665
```

**Note:** The web dashboard is only available during test execution. For permanent results, use the export feature or k6's other output options (Cloud, InfluxDB, etc.).

## Custom Configuration

Override any environment variable:

```bash
# Custom VUs and duration
./scripts/run-load-test.sh \
  -e MAX_VUS=150 \
  -e RAMP_UP_DURATION=5m \
  -e STEADY_DURATION=10m \
  -e RAMP_DOWN_DURATION=3m \
  load-test.js

# Test against different environment
./scripts/run-load-test.sh \
  -e BASE_URL=https://api.staging.example.com \
  -e MAX_VUS=50 \
  load-test.js

# Use single audio file instead of random
./scripts/run-load-test.sh \
  -e USE_RANDOM_AUDIO=false \
  -e AUDIO_FILE_PATH=samples/sample-audio.wav \
  load-test.js

# Direct k6 usage (if you prefer - requires exporting env vars first)
export $(cat .env.k6 | grep -v '^#' | xargs) && k6 run -e MAX_VUS=150 load-test.js
```

## Understanding Results

### Key Metrics

**Standard HTTP Metrics:**

- `http_req_duration`: Total request duration (includes network + processing)
- `http_req_waiting`: Time to first byte (server processing time)
- `http_req_failed`: Percentage of failed requests

**Custom Metrics:**

- `audio_files_used`: Total unique audio files processed
- `transcription_success`: Success rate of transcriptions
- `segment_count`: Number of segments per transcription
- `transcription_length`: Length of transcribed text
- `translation_length`: Length of translated text
- `audio_file_size_kb`: Audio file sizes in KB

### Interpreting Results

**Good:**

```
✓ http_req_failed: rate<0.05     // <5% errors
✓ http_req_duration: p(95)<180000 // p95 < 3 minutes
✓ transcription_success: rate>0.95 // >95% success
```

**Needs Investigation:**

```
✗ http_req_failed: rate<0.05     // High error rate
✗ http_req_duration: p(95)<180000 // Slow responses
```

### Example Output

```
scenarios: (100.00%) 1 scenario, 100 max VUs, 20m30s max duration
default: 100 VUs ramping up/down in 20m

✓ status is 200
✓ has original_text
✓ has translated_text
✓ has segments array
✓ segments have required fields

checks.........................: 100.00% ✓ 5000    ✗ 0
data_received..................: 45 MB   38 kB/s
data_sent......................: 350 MB  292 kB/s
http_req_duration..............: avg=45.2s   min=12.3s   med=42.1s   max=89.4s   p(90)=67.8s   p(95)=78.5s
http_req_failed................: 0.00%   ✓ 0       ✗ 5000
iteration_duration.............: avg=47.5s   min=14.8s   med=44.3s   max=92.1s   p(90)=70.2s   p(95)=81.3s
iterations.....................: 5000    4.17/s
transcription_success..........: 100.00% ✓ 5000    ✗ 0
vus............................: 1       min=1     max=100
vus_max........................: 100     min=100   max=100
```

## Advanced Usage

### Output to File

```bash
# JSON output for analysis
./scripts/run-load-test.sh --out json=results.json load-test.js

# CSV output
./scripts/run-load-test.sh --out csv=results.csv load-test.js
```

### Cloud Execution

```bash
# k6 Cloud (requires account)
export $(cat .env.k6 | grep -v '^#' | xargs) && k6 cloud load-test.js
```

### CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Load Test

on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM
  workflow_dispatch:

jobs:
  load-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install k6
        run: |
          sudo gpg -k
          sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
          echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
          sudo apt-get update
          sudo apt-get install k6
      
      - name: Download dataset
        run: ./scripts/generate-audio-list.sh
      
      - name: Run smoke test
        run: ./scripts/run-load-test.sh -e TEST_MODE=smoke load-test.js
      
      - name: Run load test
        run: ./scripts/run-load-test.sh -e BASE_URL=${{ secrets.API_URL }} load-test.js
```

## Troubleshooting

### Dataset Not Found

```
Audio files list not found. Please run: scripts/generate-audio-list.sh
```

**Solution:** Use the wrapper script which handles this automatically:

```bash
./scripts/run-load-test.sh load-test.js
```

Or manually download:

```bash
./scripts/generate-audio-list.sh
```

### Connection Refused

```
http_req_failed: rate>0.05
```

**Solution:** Ensure API is running at `BASE_URL` (default: <http://localhost:8000>)

```bash
# Start API
make run-api
```

### High Error Rate

Check API logs for errors:

```bash
docker logs stt-api-container
```

Common causes:

- Azure Speech Service quota exceeded
- Invalid audio formats
- Timeout too short for large files

### Memory Issues

If k6 runs out of memory with large datasets:

- Reduce `MAX_VUS`
- Use smaller audio file subset
- Increase system memory

## LibriSpeech Dataset

The test uses LibriSpeech test-clean dataset:

- **Files:** 2,620 FLAC audio files
- **Size:** ~350 MB total
- **Speakers:** 40 unique speakers
- **Format:** 16kHz, 16-bit, mono FLAC
- **Duration:** Variable (avg ~8 seconds per file)
- **Language:** US English
- **Source:** <https://www.openslr.org/12>

Each test iteration randomly selects an audio file, ensuring realistic load patterns with diverse audio samples.

## Best Practices

1. **Start Small:** Always run smoke test first
2. **Gradual Ramp:** Use ramp stages to avoid overwhelming the system
3. **Monitor Resources:** Watch CPU, memory, network on both client and server
4. **Realistic Think Time:** Add delays between requests (1-3s default)
5. **Set Timeouts:** Configure appropriate timeouts for your audio files
6. **Track Metrics:** Monitor custom metrics for business KPIs
7. **Regular Testing:** Run load tests regularly to catch regressions

## Further Reading

- [k6 Documentation](https://k6.io/docs/)
- [LibriSpeech Dataset](https://www.openslr.org/12)
- [Azure Speech Service Limits](https://docs.microsoft.com/en-us/azure/cognitive-services/speech-service/speech-services-quotas-and-limits)
