# Review: How Process-Level Isolation Solves Native Memory Leaks

This documentation explains the fundamental difference between threading and process isolation, and why process isolation solution helps dealing with native memory leaks.

## Transcriptions Endpoint Architecture (Thread-Based)

**What is implemented:**

```python
# In TranscriptionService._transcribe_async()
executor = ThreadPoolExecutor(max_workers=1)
result = await loop.run_in_executor(executor, _sync_transcribe)
executor.shutdown(wait=True)
```

**Problem:**

- Thread runs **within the same process**
- Native memory (C++ allocations from Azure SDK) belongs to the **process**, not the thread
- When thread ends: ✅ Thread resources freed
- When thread ends: ❌ Native memory **stays in process heap**
- After ~10 requests: Process has ~2.6 GB leaked native memory
- Python's GC: Can't see or touch native memory

## Process-Level Isolation with Recycling Solution (transcriptions/process-isolated)

**What it does:**

```python
# Each request runs in a SEPARATE process
from multiprocessing import Process

process = Process(target=_sync_transcribe, args=(...))
process.start()
result = process.join()  # Wait for completion
# Process terminates → OS reclaims ALL memory (Python + native)

# From main.py
# Periodically restart process pool to reclaim memory
service.restart_if_idle()
```

**Why it works:**

- Each transcription runs in **isolated process**
- Process has its own memory space (separate from parent)
- When process exits: OS **forcibly reclaims ALL memory**
  - Python heap
  - Native C++ allocations
  - Kernel buffers
  - Anything else that can be claimed
- When process pool recycles workers:
  - Old processes die → memory reclaimed
  - New processes start fresh → zero memory

### 📊 Memory Behavior Comparison

#### **Current (Thread-Based):**

```
Request 1: Parent Process 100MB → 360MB (leaked 260MB in native heap)
Request 2: Parent Process 360MB → 620MB (leaked another 260MB)
Request 3: Parent Process 620MB → 880MB (leaked another 260MB)
...
Request 10: Parent Process → 2.7GB → OOMKilled
```

#### **Process Isolation with Process Pool Recycling**

```
Request 1: 
  - Parent Process: 100MB (stable)
  - Process Pool Worker: 100MB → 360MB → Completes → Worker stays alive
  - Parent remains: 100MB ✅

Request 2:
  - Parent Process: 100MB (stable)  
  - Same Pool Worker: 360MB → 620MB → Completes → Worker stays alive
  - Parent remains: 100MB ✅

Request 5 (worker accumulates memory):
  - Parent Process: 100MB (stable)
  - Pool Worker: 1.4GB → Completes → Worker enters idle state
  - Parent remains: 100MB ✅

After 5 minutes idle time:
  - Parent Process: 100MB (stable)
  - Idle Detection: Worker has been idle > threshold
  - WORKER RECYCLED → OS reclaims 1.4GB
  - New Worker starts: 100MB fresh ✅
  - Parent remains: 100MB ✅

Request 6:
  - Parent Process: 100MB (stable)
  - New Pool Worker: 100MB → 360MB → Completes → Worker stays alive
  - Memory cycle resets ✅
```
