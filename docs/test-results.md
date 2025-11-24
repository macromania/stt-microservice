# Test Results

## Technical Reality: Understanding "Single-Threaded Per Request"

Throughout this document, we refer to the STT service as having "single-threaded per request" or "largely single-threaded" processing characteristics. Here's what this means:

### What Happens Inside a Single Pod

1. **Python GIL (Global Interpreter Lock)**:
   - Python's GIL prevents true parallel CPU execution within a single process
   - Even though the service uses async/await (FastAPI + asyncio), CPU-intensive work is still GIL-bound
   - Multiple concurrent requests share the same CPU resources sequentially

2. **CPU-Intensive Transcription**:
   - Audio transcription is computationally heavy work
   - Each request's processing happens sequentially through the underlying SDK
   - Adding more CPU cores to a single pod doesn't proportionally increase throughput

3. **Async != Parallel for CPU Work**:
   - The service can *accept* requests concurrently (non-blocking I/O)
   - But *processing* them runs one at a time per CPU core due to GIL
   - This is why 1 pod with 2 CPUs can't fully utilize both cores

### Why Multiple Pods Win

- **Multiple Pods = Multiple Python Processes**
- Each process has its own GIL and can truly run in parallel
- 3 pods with 1 CPU each > 1 pod with 2 CPUs
- This is **horizontal scaling** (more instances) vs **vertical scaling** (bigger instances)

### Test Results Confirm This

| Configuration | CPUs | Throughput | Explanation |
|--------------|------|------------|-------------|
| 1 Pod | 2 cores | 2.78 req/s | Can't fully utilize both cores (GIL) |
| 3 Pods | 3 cores total | 5.24 req/s | True parallelism across processes |

**Key Takeaway**: For CPU-bound Python services with GIL constraints, horizontal scaling dramatically outperforms vertical scaling.

---

## Local Tests

**Host:**

- OS: MacOS 26.1 (25B78)
- CPU: Apple M1 Pro
- Memory: 32 GB
- Deployment: Local Devcontainer

**Load:**

- VUs: 100
- Date: 2025-11-21-02:30 GST

**Results:**

```bash
     ✓ status is 200
     ✓ has original_text
     ✓ has translated_text
     ✓ has segments array
     ✓ segments have required fields

     █ setup

     █ teardown

     audio_file_size_kb.............: min=60.076172 avg=251.48167  med=195.857422 p(90)=516.326172 p(95)=554.607422 p(99)=703.201172 max=729.296875
     audio_files_used...............: 3648    3.023404/s
     checks.........................: 100.00% ✓ 18230    ✗ 0    
     data_received..................: 3.2 MB  2.6 kB/s
     data_sent......................: 941 MB  780 kB/s
     http_req_blocked...............: min=1µs       avg=23.75µs    med=4µs        p(90)=8µs        p(95)=12µs       p(99)=588.74µs   max=6.1ms     
     http_req_connecting............: min=0s        avg=16.49µs    med=0s         p(90)=0s         p(95)=0s         p(99)=533.1µs    max=6.05ms    
   ✓ http_req_duration..............: min=2.39s     avg=18.64s     med=14.89s     p(90)=40.33s     p(95)=50.47s     p(99)=1m6s       max=1m20s     
       { expected_response:true }...: min=2.39s     avg=18.64s     med=14.89s     p(90)=40.33s     p(95)=50.47s     p(99)=1m6s       max=1m20s     
   ✓ http_req_failed................: 0.00%   ✓ 0        ✗ 3646 
     http_req_receiving.............: min=12µs      avg=182.66µs   med=75µs       p(90)=160µs      p(95)=248.49µs   p(99)=1.1ms      max=89.97ms   
     http_req_sending...............: min=97µs      avg=410.22µs   med=292µs      p(90)=666µs      p(95)=850.74µs   p(99)=2.24ms     max=12.58ms   
     http_req_tls_handshaking.......: min=0s        avg=0s         med=0s         p(90)=0s         p(95)=0s         p(99)=0s         max=0s        
     http_req_waiting...............: min=2.39s     avg=18.64s     med=14.89s     p(90)=40.33s     p(95)=50.47s     p(99)=1m6s       max=1m20s     
     http_reqs......................: 3646    3.021747/s
     iteration_duration.............: min=148.83µs  avg=20.77s     med=16.92s     p(90)=42.28s     p(95)=52.41s     p(99)=1m9s       max=1m22s     
     iterations.....................: 3645    3.020918/s
     segment_count..................: min=0         avg=1.063083   med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
     transcription_length...........: min=36        avg=137.134431 med=111        p(90)=268        p(95)=291        p(99)=369        max=414       
   ✓ transcription_success..........: 100.00% ✓ 3646     ✗ 0    
     translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         
     vus............................: 1       min=0      max=100
     vus_max........................: 100     min=100    max=100


running (20m06.6s), 000/100 VUs, 3645 complete and 3 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s

```

## Local Cluster - 3 Pods

- 3 Pods
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "750m"      # 0.75 CPU core
  - memory: "1536Mi" # 1.5 GB (proportional to 2Gi limit)
- limits:
  - cpu: "1000m"     # 1 CPU core
  - memory: "2Gi"    # 2 Gigabytes of RAM
- date: 2025-11-24 12:45:03 GST

![Single Worker Pod - 3 Pod Cluster](./images/single-worker-3-pods-100vu.png)

```bash

  █ THRESHOLDS 

    http_req_duration
    ✓ 'p(95)<180000' p(95)=31.84s

    http_req_failed
    ✓ 'rate<0.05' rate=2.74%

    transcription_success
    ✓ 'rate>0.95' rate=97.25%


  █ TOTAL RESULTS 

    checks_total.......: 31665  26.186686/s
    checks_succeeded...: 97.25% 30795 out of 31665
    checks_failed......: 2.74%  870 out of 31665

    ✗ status is 200
      ↳  97% — ✓ 6159 / ✗ 174
    ✗ has original_text
      ↳  97% — ✓ 6159 / ✗ 174
    ✗ has translated_text
      ↳  97% — ✓ 6159 / ✗ 174
    ✗ has segments array
      ↳  97% — ✓ 6159 / ✗ 174
    ✗ segments have required fields
      ↳  97% — ✓ 6159 / ✗ 174

    CUSTOM
    audio_file_size_kb.............: min=60.076172 avg=255.371018 med=196.326172 p(90)=516.326172 p(95)=554.607422 p(99)=703.201172 max=729.296875
    audio_files_used...............: 6339   5.242299/s
    segment_count..................: min=0         avg=1.06527    med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
    transcription_length...........: min=36        avg=137.796685 med=116        p(90)=268        p(95)=291        p(99)=390.6      max=414       
    transcription_success..........: 97.25% 6159 out of 6333
    translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         

    HTTP
    http_req_duration..............: min=0s        avg=9.3s       med=5.54s      p(90)=19.59s     p(95)=31.84s     p(99)=1m5s       max=2m16s     
      { expected_response:true }...: min=2.15s     avg=8.97s      med=5.51s      p(90)=17.57s     p(95)=29.69s     p(99)=1m3s       max=2m16s     
    http_req_failed................: 2.74%  174 out of 6333
    http_reqs......................: 6333   5.237337/s

    EXECUTION
    iteration_duration.............: min=1.64s     avg=11.9s      med=7.93s      p(90)=23s        p(95)=35.82s     p(99)=1m9s       max=2m18s     
    iterations.....................: 6333   5.237337/s
    vus............................: 1      min=0            max=100
    vus_max........................: 100    min=100          max=100

    NETWORK
    data_received..................: 5.5 MB 4.5 kB/s
    data_sent......................: 1.7 GB 1.4 MB/s

running (20m09.2s), 000/100 VUs, 6333 complete and 6 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s

```

### Explanation: Why Minikube Cluster Handled ~74% More Requests

The minikube cluster processed **6,333 requests** vs devcontainer's **3,646 requests** in the same 20-minute window. Here's why:

#### **Key Factor: Parallelization Through Multiple Pods**

**Devcontainer Setup:**

- Single instance running on your M1 Pro Mac
- 1 CPU processing all requests sequentially
- Average request duration: **18.64s**
- Throughput: **3.02 requests/second**

**Minikube Cluster Setup:**

- **3 replicas** (pods) running in parallel
- Each pod gets 1 CPU core (3 cores total)
- Average request duration: **9.3s** (50% faster!)
- Throughput: **5.24 requests/second** (73% higher)

#### **Why the Cluster is Faster:**

1. **Parallel Processing Power:**
   - 3 pods × 1 CPU = 3x computational capacity
   - Can process 3 requests simultaneously instead of 1
   - Better resource utilization under load

2. **Lower Average Latency:**
   - Devcontainer p95: **50.47s**
   - Cluster p95: **31.84s** (37% improvement)
   - With 100 VUs, requests queue less in the cluster

3. **Load Distribution:**
   - Your test configuration uses `noConnectionReuse: true` and `dns: { select: 'random' }`
   - k6 distributes requests across all 3 pod IPs
   - No single pod becomes a bottleneck

4. **Service Characteristics:**
   - STT transcription is CPU-intensive
   - Processing is largely single-threaded per request
   - More pods = more parallel processing capacity

#### **The Math:**

- 20 minutes = 1,200 seconds
- Devcontainer: 3,646 requests / 1,200s = **3.04 req/s**
- Cluster: 6,333 requests / 1,200s = **5.28 req/s**
- **Improvement: 74% more throughput**

#### **Note on Failures:**

The cluster had a **2.74% failure rate** (174 failed requests) likely due to:

- Resource contention under higher load
- Possible memory pressure with 2GB limits per pod
- Some requests timing out when all pods were busy

The devcontainer had **0% failures** because requests were processed more conservatively at a slower rate.

## Local Cluster - 1 Pod

- 1 Pod
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "1500m"     # 1.5 CPU cores
  - memory: "3072Mi" # 3 GB (proportional to 4Gi limit)
- limits:
  - cpu: "2000m"     # 2 CPU cores
  - memory: "4Gi"    # 4 Gigabytes of RAM
- date: 2025-11-24 13:14:30 GST

![Single Worker Pod 100 VUs](./images/single-worker-pod-100vu.png)

```bash

  █ THRESHOLDS 

    http_req_duration
    ✓ 'p(95)<180000' p(95)=1m5s

    http_req_failed
    ✓ 'rate<0.05' rate=0.26%

    transcription_success
    ✓ 'rate>0.95' rate=99.73%


  █ TOTAL RESULTS 

    checks_total.......: 16740  13.907379/s
    checks_succeeded...: 99.73% 16695 out of 16740
    checks_failed......: 0.26%  45 out of 16740

    ✗ status is 200
      ↳  99% — ✓ 3339 / ✗ 9
    ✗ has original_text
      ↳  99% — ✓ 3339 / ✗ 9
    ✗ has translated_text
      ↳  99% — ✓ 3339 / ✗ 9
    ✗ has segments array
      ↳  99% — ✓ 3339 / ✗ 9
    ✗ segments have required fields
      ↳  99% — ✓ 3339 / ✗ 9

    CUSTOM
    audio_file_size_kb.............: min=60.076172 avg=258.301244 med=196.326172 p(90)=522.419922 p(95)=554.607422 p(99)=729.296875 max=729.296875
    audio_files_used...............: 3353   2.78563/s
    segment_count..................: min=0         avg=1.050614   med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
    transcription_length...........: min=36        avg=139.709451 med=116.5      p(90)=272        p(95)=291        p(99)=414        max=414       
    transcription_success..........: 99.73% 3339 out of 3348
    translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         

    HTTP
    http_req_duration..............: min=1.65s     avg=20.26s     med=12.82s     p(90)=43.46s     p(95)=1m5s       p(99)=1m58s      max=3m0s      
      { expected_response:true }...: min=1.65s     avg=19.82s     med=12.76s     p(90)=43s        p(95)=1m3s       p(99)=1m55s      max=2m49s     
    http_req_failed................: 0.26%  9 out of 3348
    http_reqs......................: 3348   2.781476/s

    EXECUTION
    iteration_duration.............: min=3.35s     avg=22.59s     med=15.17s     p(90)=46.69s     p(95)=1m7s       p(99)=2m1s       max=3m4s      
    iterations.....................: 3348   2.781476/s
    vus............................: 1      min=0            max=100
    vus_max........................: 100    min=100          max=100

    NETWORK
    data_received..................: 3.0 MB 2.5 kB/s
    data_sent......................: 889 MB 738 kB/s


running (20m03.7s), 000/100 VUs, 3348 complete and 5 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s

```

### Explanation: Why 3 Pods Outperformed 1 Pod (Despite Lower Per-Pod Resources)

The 3-pod cluster processed **6,333 requests** vs the 1-pod cluster's **3,348 requests** in the same 20-minute window—**89% more throughput**. Here's the analysis:

#### **Configuration Comparison**

**1 Pod Setup:**

- Single pod with 2 CPU cores (2000m limit)
- 4GB memory
- Average request duration: **20.26s**
- Throughput: **2.78 requests/second**
- Success rate: **99.73%**

**3 Pods Setup:**

- Three pods with 1 CPU core each (1000m limit)
- 2GB memory per pod
- Total cluster resources: **3 CPU cores, 6GB memory**
- Average request duration: **9.3s** (54% faster!)
- Throughput: **5.24 requests/second** (88% higher)
- Success rate: **97.25%**

#### **Why More Pods with Less Per-Pod Resources Won:**

1. **True Parallel Processing:**
   - **1 pod:** Despite having 2 CPUs, the service's processing is largely single-threaded per request
   - **3 pods:** Can process 3 separate audio files simultaneously across different instances
   - Result: 3 concurrent transcriptions vs 1 at a time

2. **Reduced Request Queuing:**
   - With 100 VUs generating load, the 1-pod setup creates a long queue
   - 3 pods distribute incoming requests, drastically reducing wait times
   - Median latency: **12.82s** (1 pod) vs **5.54s** (3 pods) — **57% improvement**

3. **Better CPU Utilization:**
   - Single pod can't fully utilize 2 cores for single-threaded processing
   - 3 separate instances across 3 pods = better CPU saturation
   - Each pod's 1 CPU is fully utilized for its workload

4. **Memory Efficiency:**
   - Each pod loads its own service resources independently
   - 4GB in 1 pod = 1 service instance
   - 3 pods × 2GB = 3 service instances running simultaneously
   - More instances = more parallel transcription capacity

#### **The Math:**

- **1 Pod:** 3,348 requests / 1,203s = **2.78 req/s**
- **3 Pods:** 6,333 requests / 1,209s = **5.24 req/s**
- **Improvement: 89% more throughput**

#### **Latency Improvements (p95):**

- **1 Pod p95:** 1m5s (65 seconds)
- **3 Pods p95:** 31.84s
- **Improvement: 51% faster at p95**

#### **Trade-off: Reliability vs Throughput**

The 3-pod configuration had a slightly higher failure rate:

- **1 Pod:** 0.26% failures (9 requests)
- **3 Pods:** 2.74% failures (174 requests)

This is likely due to:

- Higher overall system load (processing 89% more requests)
- Individual pods hitting memory limits (2GB vs 4GB)
- Network/load balancer overhead with higher request rates

#### **Key Takeaway:**

For CPU-intensive, single-threaded workloads like STT services:

- **Horizontal scaling (more pods)** >> **Vertical scaling (bigger pods)**
- 3 pods × 1 CPU (3 total CPUs) > 1 pod × 2 CPUs
- Parallel processing across instances beats multi-core allocation to a single instance
- Trade-off: Accept slightly more failures for dramatically higher throughput

## Local Cluster - 1 Pod with Improved Azure SDK Disposal

- 1 Pod
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "1500m"     # 1.5 CPU cores
  - memory: "3072Mi" # 3 GB (proportional to 4Gi limit)
- limits:
  - cpu: "2000m"     # 2 CPU cores
  - memory: "4Gi"    # 4 Gigabytes of RAM
- date: 2025-11-24 13:14:30 GST
- Azure SDK object disposal implemented - 62c7c4b62d68c9553857882feeb1e0133769d250

![Single Worker Pod with Improved SDK Disposal 100 VUs](./images/single-workder-pod-100vu-sdk-object-disposal.png)

```bash
  █ THRESHOLDS 

    http_req_duration
    ✓ 'p(95)<180000' p(95)=47.43s

    http_req_failed
    ✓ 'rate<0.05' rate=0.00%

    transcription_success
    ✓ 'rate>0.95' rate=100.00%


  █ TOTAL RESULTS 

    checks_total.......: 19255   16.014222/s
    checks_succeeded...: 100.00% 19255 out of 19255
    checks_failed......: 0.00%   0 out of 19255

    ✓ status is 200
    ✓ has original_text
    ✓ has translated_text
    ✓ has segments array
    ✓ segments have required fields

    CUSTOM
    audio_file_size_kb.............: min=60.076172 avg=257.721861 med=196.326172 p(90)=516.326172 p(95)=566.482422 p(99)=729.296875 max=729.296875
    audio_files_used...............: 3854    3.205339/s
    segment_count..................: min=0         avg=1.069073   med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
    transcription_length...........: min=36        avg=140.0543   med=117        p(90)=272        p(95)=291        p(99)=414        max=414       
    transcription_success..........: 100.00% 3851 out of 3851
    translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         

    HTTP
    http_req_duration..............: min=2.15s     avg=17.38s     med=13.32s     p(90)=38.38s     p(95)=47.43s     p(99)=1m4s       max=1m19s     
      { expected_response:true }...: min=2.15s     avg=17.38s     med=13.32s     p(90)=38.38s     p(95)=47.43s     p(99)=1m4s       max=1m19s     
    http_req_failed................: 0.00%   0 out of 3851
    http_reqs......................: 3851    3.202844/s

    EXECUTION
    iteration_duration.............: min=3.28s     avg=19.62s     med=15.46s     p(90)=40.48s     p(95)=49.85s     p(99)=1m7s       max=1m21s     
    iterations.....................: 3849    3.201181/s
    vus............................: 1       min=0            max=100
    vus_max........................: 100     min=100          max=100

    NETWORK
    data_received..................: 3.5 MB  2.9 kB/s
    data_sent......................: 1.0 GB  848 kB/s

running (20m02.4s), 000/100 VUs, 3849 complete and 5 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s
```

## Local Cluster - 1 Pod with Improved Azure SDK Disposal and Removed Service Cache

- 1 Pod
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "1500m"     # 1.5 CPU cores
  - memory: "3072Mi" # 3 GB (proportional to 4Gi limit)
- limits:
  - cpu: "2000m"     # 2 CPU cores
  - memory: "4Gi"    # 4 Gigabytes of RAM
- date: 2025-11-24 13:14:30 GST
- Azure SDK object disposal implemented - 62c7c4b62d68c9553857882feeb1e0133769d250
- Service cache disabled - 17feb1583d27aafcc3afdea50340dd91df94201c
- Increased overall memory usage and doesn't have a significant impact on latency or throughput

![No Service Cache Single Worker Pod with Improved SDK Disposal 100 VUs](./images/single-workder-pod-100vu-sdk-object-no-service-cache.png)


```bash
  █ THRESHOLDS 

    http_req_duration
    ✓ 'p(95)<180000' p(95)=46.84s

    http_req_failed
    ✓ 'rate<0.05' rate=0.00%

    transcription_success
    ✓ 'rate>0.95' rate=100.00%


  █ TOTAL RESULTS 

    checks_total.......: 19435   16.166694/s
    checks_succeeded...: 100.00% 19435 out of 19435
    checks_failed......: 0.00%   0 out of 19435

    ✓ status is 200
    ✓ has original_text
    ✓ has translated_text
    ✓ has segments array
    ✓ segments have required fields

    CUSTOM
    audio_file_size_kb.............: min=60.076172 avg=257.852454 med=196.326172 p(90)=516.326172 p(95)=554.607422 p(99)=729.296875 max=729.296875
    audio_files_used...............: 3889    3.235003/s
    segment_count..................: min=0         avg=1.066118   med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
    transcription_length...........: min=36        avg=140.557529 med=117        p(90)=272        p(95)=304        p(99)=414        max=414       
    transcription_success..........: 100.00% 3887 out of 3887
    translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         

    HTTP
    http_req_duration..............: min=2.15s     avg=17.25s     med=13.47s     p(90)=37.8s      p(95)=46.84s     p(99)=1m1s       max=1m11s     
      { expected_response:true }...: min=2.15s     avg=17.25s     med=13.47s     p(90)=37.8s      p(95)=46.84s     p(99)=1m1s       max=1m11s     
    http_req_failed................: 0.00%   0 out of 3887
    http_reqs......................: 3887    3.233339/s

    EXECUTION
    iteration_duration.............: min=3.35s     avg=19.51s     med=15.7s      p(90)=40.28s     p(95)=49.31s     p(99)=1m4s       max=1m14s     
    iterations.....................: 3886    3.232507/s
    vus............................: 1       min=0            max=100
    vus_max........................: 100     min=100          max=100

    NETWORK
    data_received..................: 3.5 MB  2.9 kB/s
    data_sent......................: 1.0 GB  856 kB/s

running (20m02.2s), 000/100 VUs, 3886 complete and 3 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s
```

## Local Cluster - 1 Pod with Improved Azure SDK Disposal and Forced Garbage Collection

- 1 Pod
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "1500m"     # 1.5 CPU cores
  - memory: "3072Mi" # 3 GB (proportional to 4Gi limit)
- limits:
  - cpu: "2000m"     # 2 CPU cores
  - memory: "4Gi"    # 4 Gigabytes of RAM
- date: 2025-11-24 13:14:30 GST
- Azure SDK object disposal implemented - 62c7c4b62d68c9553857882feeb1e0133769d250
- Service cache enabled and garbage collection is forced - 012a1012651b7a92b164dc62202a88b50aa1cdd1
- Reduced some memoryy

![Forced Garbage Collection Single Worker Pod with Improved SDK Disposal 100 VUs](./images/single-worker-pod-100vu-force-gc.png)

```bash
  █ THRESHOLDS 

    http_req_duration
    ✓ 'p(95)<180000' p(95)=46.31s

    http_req_failed
    ✓ 'rate<0.05' rate=0.00%

    transcription_success
    ✓ 'rate>0.95' rate=100.00%


  █ TOTAL RESULTS 

    checks_total.......: 19150   15.844205/s
    checks_succeeded...: 100.00% 19150 out of 19150
    checks_failed......: 0.00%   0 out of 19150

    ✓ status is 200
    ✓ has original_text
    ✓ has translated_text
    ✓ has segments array
    ✓ segments have required fields

    CUSTOM
    audio_file_size_kb.............: min=60.076172 avg=250.514587 med=195.857422 p(90)=516.326172 p(95)=554.607422 p(99)=703.201172 max=729.296875
    audio_files_used...............: 3835    3.172978/s
    segment_count..................: min=0         avg=1.065274   med=1          p(90)=1          p(95)=2          p(99)=2          max=2         
    transcription_length...........: min=36        avg=136.689592 med=111        p(90)=268        p(95)=304        p(99)=369        max=414       
    transcription_success..........: 100.00% 3830 out of 3830
    translation_length.............: min=4         avg=4          med=4          p(90)=4          p(95)=4          p(99)=4          max=4         

    HTTP
    http_req_duration..............: min=1.69s     avg=17.41s     med=13.73s     p(90)=37.6s      p(95)=46.31s     p(99)=1m4s       max=1m19s     
      { expected_response:true }...: min=1.69s     avg=17.41s     med=13.73s     p(90)=37.6s      p(95)=46.31s     p(99)=1m4s       max=1m19s     
    http_req_failed................: 0.00%   0 out of 3830
    http_reqs......................: 3830    3.168841/s

    EXECUTION
    iteration_duration.............: min=3.35s     avg=19.72s     med=15.84s     p(90)=40.14s     p(95)=49.22s     p(99)=1m7s       max=1m22s     
    iterations.....................: 3829    3.168014/s
    vus............................: 1       min=0            max=100
    vus_max........................: 100     min=100          max=100

    NETWORK
    data_received..................: 3.4 MB  2.8 kB/s
    data_sent......................: 986 MB  816 kB/s

running (20m08.6s), 000/100 VUs, 3829 complete and 6 interrupted iterations
stt_load_test ✓ [======================================] 000/100 VUs  20m0s
```
