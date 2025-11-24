## Review: How Process-Level Isolation Solves Native Memory Leaks

Let me explain the fundamental difference between threading and process isolation, and why it's the only real solution for native memory leaks.

### 🔍 Current Architecture (Thread-Based)

**What you have now:**

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
- After 10 requests: Process has 2.6 GB leaked native memory
- Python's GC: Can't see or touch native memory

### ✅ Process-Level Isolation Solution

**What it does:**

```python
# Each request runs in a SEPARATE process
from multiprocessing import Process

process = Process(target=_sync_transcribe, args=(...))
process.start()
result = process.join()  # Wait for completion
# Process terminates → OS reclaims ALL memory (Python + native)
```

**Why it works:**

- Each transcription runs in **isolated process**
- Process has its own memory space (separate from parent)
- When process exits: OS **forcibly reclaims ALL memory**
  - Python heap ✅
  - Native C++ allocations ✅
  - Kernel buffers ✅
  - Everything ✅

### 📊 Memory Behavior Comparison

#### **Current (Thread-Based):**

```
Request 1: Parent Process 100MB → 360MB (leaked 260MB in native heap)
Request 2: Parent Process 360MB → 620MB (leaked another 260MB)
Request 3: Parent Process 620MB → 880MB (leaked another 260MB)
...
Request 10: Parent Process → 2.7GB → OOMKilled
```

#### **Process Isolation:**

```
Request 1: 
  - Parent Process: 100MB (stable)
  - Child Process: 100MB → 360MB → EXIT → OS reclaims 360MB
  - Parent remains: 100MB ✅

Request 2:
  - Parent Process: 100MB (stable)
  - Child Process: 100MB → 360MB → EXIT → OS reclaims 360MB
  - Parent remains: 100MB ✅

Request 10:
  - Parent Process: 100MB (stable) ✅
  - Each child dies, memory fully reclaimed ✅
```

### 🛠️ Implementation Plan

**Plan Overview:**

1. **Create Process-Safe Transcription Wrapper**
   - Serialize input (file path, config)
   - Use multiprocessing Queue for result passing
   - Handle process lifecycle

2. **Implement Timeout & Error Handling**
   - Process timeout (kill if hangs)
   - Exception propagation from child
   - Resource cleanup on failure

3. **Add Process Pool Management**
   - Limit concurrent processes
   - Queue requests when at capacity
   - Monitor process health

4. **Update Service Architecture**
   - New `ProcessIsolatedTranscriptionService` class
   - Backward compatible with existing API
   - Optional feature flag to enable/disable

### 📝 Detailed Implementation Plan

#### **Task 1: Create Process-Safe Wrapper Module**

Create `src/service/stt/process_worker.py`:

- `transcribe_in_process()` - Main entry point
- Serializable input/output with pickle
- Queue-based IPC for results
- Exception marshaling back to parent

#### **Task 2: Implement Process Manager**

Create `src/service/stt/process_manager.py`:

- `ProcessTranscriptionManager` class
- Process pool with max workers limit
- Timeout enforcement (kill zombie processes)
- Health monitoring and auto-recovery

#### **Task 3: Create New Service Class**

Update service.py:

- `ProcessIsolatedTranscriptionService` (new)
- Delegates to process manager
- Same interface as `TranscriptionService`
- Configurable via environment variable

#### **Task 4: API Integration**

Update stt.py:

- Feature flag: `USE_PROCESS_ISOLATION=true/false`
- Conditional service instantiation
- Fallback to thread-based for compatibility

#### **Task 5: Add Monitoring**

Enhance debug.py:

- Process pool stats endpoint
- Memory tracking per-process
- Process lifecycle metrics

#### **Task 6: Testing & Validation**

- Load test with process isolation
- Memory growth measurement
- Failure scenario testing

### ⚠️ Trade-offs to Consider

**Pros:**

- ✅ **100% memory isolation** - OS guarantees cleanup
- ✅ **Crash isolation** - Child crash doesn't kill parent
- ✅ **Solves native leaks** - No Python code changes needed
- ✅ **Predictable memory** - Parent stays constant

**Cons:**

- ❌ **Slower startup** - Process spawn overhead (~50-200ms)
- ❌ **IPC overhead** - Serialization of data
- ❌ **No shared memory** - Each process loads SDK separately
- ❌ **More complex** - Process management, error handling

### 🎯 Expected Results

**Before (Thread-based):**

```
10 requests → 2.6GB leaked → OOM
```

**After (Process-isolation):**

```
10 requests → Parent: 100MB (stable)
1000 requests → Parent: 100MB (stable)
Infinite requests → Parent: 100MB (stable) ✅
```

### 💡 Alternative: Hybrid Approach

**Best of both worlds:**

```python
class HybridTranscriptionService:
    def __init__(self):
        self.request_count = 0
        self.max_requests_per_process = 5  # Recycle after N requests
        
    async def process_audio(self, ...):
        self.request_count += 1
        
        if self.request_count <= self.max_requests_per_process:
            # Fast path: use thread
            return await self._thread_based_transcribe(...)
        else:
            # Cleanup path: use process
            # After this, restart the service
            return await self._process_based_transcribe(...)
```

This gives you:

- Fast performance (thread-based for first N requests)
- Periodic memory cleanup (process-based + service restart)
- Gradual degradation instead of sudden OOM