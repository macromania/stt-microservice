# Latency Fix: Azure Speech SDK Transcription

## Problem Identified

Massive latency was observed in transcription processing:
- Small audio files (0.1-0.7 MB) taking **68-92 seconds** to process
- 296.5 KB file taking **12.3 seconds**
- Memory was stable, but throughput was extremely poor

## Root Cause

The issue was in `/workspaces/stt-microservice/src/service/stt/service.py` in the `_sync_transcribe_impl()` function.

**Bad Pattern (Before):**
```python
done = False

def on_stopped(evt):
    nonlocal done
    done = True

# ... start transcription ...

# Wait for completion - INEFFICIENT POLLING
timeout = 300
elapsed = 0
while not done and elapsed < timeout:
    time.sleep(0.5)  # <-- BLOCKS FOR 0.5s REPEATEDLY
    elapsed += 0.5
```

**Problems:**
1. **Polling with 0.5s sleep intervals** - artificially adds latency
2. The Azure SDK calls callbacks immediately when events occur
3. But we only check the `done` flag every 0.5 seconds
4. This creates **cumulative latency** across all transcription events

## Solution Implemented

Replaced inefficient polling with **threading.Event** for immediate signaling:

**Good Pattern (After):**
```python
done_event = threading.Event()

def on_stopped(evt):
    nonlocal done_event
    done_event.set()  # Immediately signals completion

# ... start transcription ...

# Wait for completion - EFFICIENT BLOCKING
timeout = 300
if not done_event.wait(timeout=timeout):
    raise TimeoutError(f"Transcription timeout after {timeout}s")
```

**Benefits:**
1. **Zero artificial latency** - thread wakes up IMMEDIATELY when `done_event.set()` is called
2. **Efficient blocking** - thread is parked by OS, no CPU cycles wasted
3. **Proper timeout handling** - Event.wait() returns False if timeout occurs

## Additional Improvements

1. **Ensured async operations complete:**
   ```python
   transcriber.start_transcribing_async().get()  # Wait for start
   # ... work ...
   transcriber.stop_transcribing_async().get()  # Wait for stop
   ```

2. **Proper cleanup** - Updated to delete `done_event` instead of `done` flag

## Expected Impact

- **Reduction in latency**: 60-70 seconds of artificial delays eliminated
- Small files should now process in **2-5 seconds** instead of 68-92 seconds
- Large files will see proportional improvements
- Memory stability maintained (no change to memory management)

## Testing Recommendations

1. **Run load test** to verify improved throughput:
   ```bash
   ./scripts/run-load-test.sh -e TEST_MODE=smoke
   ```

2. **Monitor metrics:**
   - `process_execution_time_seconds` - should drop dramatically
   - `stt_transcription_time_seconds` - should reflect actual SDK time
   - Request throughput should increase 10-15x

3. **Check for regressions:**
   - Memory should remain stable
   - No errors in transcription quality
   - Proper timeout handling still works

## Deployment

1. **Rebuild Docker image:**
   ```bash
   cd src
   docker build -t stt-microservice:latest .
   ```

2. **Update Kubernetes deployment:**
   ```bash
   kubectl rollout restart deployment/stt-service
   ```

3. **Monitor logs** for improved timing:
   ```bash
   kubectl logs -f deployment/stt-service | grep "execution_time"
   ```

## Files Modified

- `/workspaces/stt-microservice/src/service/stt/service.py`
  - Added `threading` import
  - Replaced `done` flag with `done_event` (threading.Event)
  - Replaced polling loop with `done_event.wait(timeout)`
  - Added `.get()` calls to ensure async operations complete
  - Updated cleanup code

## Related Documentation

- [Memory Leak Findings](memory-leak-findings.md) - Memory management background
- [Process Isolation](process-isolation.md) - Architecture context
- [Load Testing](load-testing.md) - Performance testing procedures
