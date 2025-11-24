# Test Results

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

## Local Cluster

- 3 Pods
- NodePort Service
- Load Balanced Requests
- requests:
  - cpu: "750m"      # 0.75 CPU core
  - memory: "1536Mi" # 1.5 GB (proportional to 2Gi limit)
limits:
  - cpu: "1000m"     # 1 CPU core
  - memory: "2Gi"    # 2 Gigabytes of RAM


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