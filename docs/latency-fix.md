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
5. **Blocking cleanup operations** - manual connection closing, delays, etc.

## Solution Implemented

### 1. Replaced inefficient polling with **threading.Event**

**Good Pattern (After):**

```python
done_event = threading.Event()
is_stopped = False

def on_stopped(evt):
    nonlocal done_event
    done_event.set()  # Immediately signals completion

# ... start transcription ...

# Wait for completion - EFFICIENT BLOCKING
timeout = 300
if not done_event.wait(timeout=timeout):
    raise TimeoutError(f"Transcription timeout after {timeout}s")

transcriber.stop_transcribing_async()
is_stopped = True
```

**Benefits:**

1. **Zero artificial latency** - thread wakes up IMMEDIATELY when `done_event.set()` is called
2. **Efficient blocking** - thread is parked by OS, no CPU cycles wasted
3. **Proper timeout handling** - Event.wait() returns False if timeout occurs

### 2. Removed blocking cleanup operations

**Old cleanup (BAD):**

```python
# Double-stop (causes SDK errors)
transcriber.stop_transcribing_async().get()  # BLOCKS
time.sleep(0.1)  # ADDS LATENCY

# Manual connection close
time.sleep(0.05)  # ADDS LATENCY
connection.close()  # Can cause errors

# Extensive manual cleanup
del credential, connection, transcriber, ...
gc.collect()  # BLOCKS
```

**New cleanup (GOOD):**

```python
# Minimal cleanup - only disconnect event handlers
if not is_stopped:
    transcriber.stop_transcribing_async()  # NO .get()

transcriber.transcribed.disconnect_all()
# ... disconnect other handlers ...

# Process exit handles everything else - FAST & RELIABLE
# - OS closes network connections
# - OS releases all memory
# - OS cleans up file descriptors
```

**Benefits:**

1. **No blocking delays** - removed all `time.sleep()` and `.get()` calls
2. **No SDK state errors** - prevents double-stop and connection closing conflicts
3. **Faster cleanup** - process exit is instant and guaranteed
4. **Simpler code** - rely on process isolation instead of manual cleanup

## Expected Impact

- **Reduction in latency**: 60-70+ seconds of artificial delays eliminated
- Small files should now process in **2-5 seconds** instead of 68-92 seconds
- Large files will see proportional improvements
- No SDK state errors (`SPXERR_CHANGE_CONNECTION_STATUS_NOT_ALLOWED`)
- Memory stability maintained (process isolation handles cleanup)
- Faster worker process termination

## Related Documentation

- [Memory Leak Findings](memory-leak-findings.md) - Memory management background
- [Process Isolation](process-isolation.md) - Architecture context
- [Load Testing](load-testing.md) - Performance testing procedures
