# Speech SDK Memory Tracking

This document explains the memory tracking strategy for the Azure Speech SDK, based on [Microsoft's official guidance](https://learn.microsoft.com/azure/ai-services/speech-service/how-to-track-speech-sdk-memory-usage).

## Overview

The Speech SDK includes built-in memory management tooling to track and limit internal object creation. This helps prevent memory leaks and unbounded memory growth in production.

## Configuration

### Environment Variables

```bash
# Warning threshold: logs warning with object dump when exceeded
STT_SPEECH_SDK_OBJECT_WARN_THRESHOLD=100  # default

# Error threshold: prevents new recognizer creation when exceeded  
STT_SPEECH_SDK_OBJECT_ERROR_THRESHOLD=200  # default
```

### Default Thresholds

- **Warning Threshold: 100 objects**
  - Logs warning message with object dump when exceeded
  - Helps identify potential memory leaks early
  - ~5-7 concurrent/leaked requests at this level

- **Error Threshold: 200 objects**
  - Prevents creation of new recognizer objects
  - Existing recognizers continue to work
  - Hard limit to prevent OOM crashes
  - ~10 concurrent/leaked requests at this level

### Typical Object Usage

According to Microsoft documentation:

- A typical recognition consumes **7-10 internal objects**
- Our service creates: `SpeechConfig` + `AudioConfig` + `ConversationTranscriber` + auto-detect config
- Estimated **15-20 objects per request** including SDK internals

## How It Works

### 1. Object Count Tracking

The SDK tracks all internal objects with these properties:

- `TrackHandle`: Logged when object is created
- `StopTracking`: Logged when object is destroyed
- Current count of each object type

Example log entry:

```
SPX_DBG_TRACE_VERBOSE: handle_table.h:90 TrackHandle type=Microsoft::CognitiveServices::Speech::Impl::ISpxRecognitionResult handle=0x7f688401e1a0, total=19
```

### 2. Warning Threshold

When object count exceeds `SPEECH-ObjectCountWarnThreshold`:

- Warning message is logged
- Object dump shows all objects and their counts
- Service continues to operate normally
- **Action**: Investigate potential leak or increase threshold

### 3. Error Threshold

When object count exceeds `SPEECH-ObjectCountErrorThreshold`:

- New recognizer creation fails with error
- Existing recognizers continue to work
- Error message includes object dump
- **Action**: Fix memory leak or scale horizontally

Example error:

```
Runtime error: The maximum object count of 200 has been exceeded.
Handle table dump by object type:
class Microsoft::CognitiveServices::Speech::Impl::ISpxRecognitionResult 0
class Microsoft::CognitiveServices::Speech::Impl::ISpxRecognizer 0
...
```

## Implementation Details

### Service Configuration

In `TranscriptionService.__init__()`:

```python
# Store thresholds from config
self.sdk_warn_threshold = config.speech_sdk_object_warn_threshold
self.sdk_error_threshold = config.speech_sdk_object_error_threshold
```

**Note:** The Python SDK does not have a `speechsdk.logging` module like C#/.NET.
Logging is configured per-request on the `SpeechConfig` object (see below).

### Per-Request Configuration

In `_transcribe_async()` when creating `SpeechConfig`:

```python
# Configure memory tracking thresholds
speech_config.set_property_by_name("SPEECH-ObjectCountWarnThreshold", str(self.sdk_warn_threshold))
speech_config.set_property_by_name("SPEECH-ObjectCountErrorThreshold", str(self.sdk_error_threshold))

# Optional: Enable SDK file logging for debugging (disabled by default)
# Uncomment to enable per-request logging to /tmp/speech-sdk-{trace_id}.log
# speech_config.set_property(speechsdk.PropertyId.Speech_LogFilename, f"/tmp/speech-sdk-{trace_id}.log")
```

### SDK File Logging (Optional)

The Speech SDK can write detailed logs to a file for debugging. This is **disabled by default**
to reduce I/O overhead in production.

**To enable per-request logging:**

```python
# Option 1: Property-based (works with all SDK versions)
speech_config.set_property(speechsdk.PropertyId.Speech_LogFilename, f"/tmp/speech-sdk-{trace_id}.log")

# Option 2: FileLogger (requires SDK 1.43.0+, global state)
import azure.cognitiveservices.speech.diagnostics.logging as speechsdk_logging
speechsdk_logging.FileLogger.start("/tmp/speech-sdk.log")
# ... SDK operations ...
speechsdk_logging.FileLogger.stop()
```

**Recommendation:** Use property-based logging per-request for better isolation.
The `FileLogger` creates global state and all recognizers write to the same file.

## Python SDK Logging Details

### Available Logging Methods

The Python Speech SDK supports multiple logging approaches:

#### 1. Property-Based Logging (Recommended)

**Pros:**

- Per-request isolation (separate log file per request)
- No global state
- Works with all SDK versions
- Simple to implement

**Cons:**

- Creates multiple log files
- Each `SpeechConfig` needs configuration

```python
speech_config.set_property(speechsdk.PropertyId.Speech_LogFilename, f"/tmp/speech-{trace_id}.log")
```

#### 2. FileLogger (SDK 1.43.0+)

**Pros:**

- Single log file for all operations
- Can enable/disable dynamically
- Supports log filtering

**Cons:**

- Global state (all recognizers log to same file)
- Interleaved logs from concurrent requests
- Requires careful lifecycle management

```python
import azure.cognitiveservices.speech.diagnostics.logging as speechsdk_logging
speechsdk_logging.FileLogger.start("/tmp/speech-sdk.log")
```

#### 3. MemoryLogger (SDK 1.43.0+)

**Pros:**

- No file I/O overhead
- Dump on-demand (e.g., after errors)
- 2MB ring buffer

**Cons:**

- Limited size (recent logs only)
- Global state (shared across all recognizers)

```python
speechsdk_logging.MemoryLogger.start()
# ... on error ...
speechsdk_logging.MemoryLogger.dump("/tmp/error-dump.log")
```

### Our Implementation Choice

**We use property-based logging (disabled by default)** because:

- ✅ No global state complications
- ✅ Request-scoped logs with trace IDs
- ✅ Compatible with containerized environments
- ✅ Can enable per-request for debugging
- ✅ Memory thresholds are primary defense

## Monitoring

### Log Analysis

Monitor application logs for:

1. **Normal operation**:

   ```
   Speech SDK memory tracking enabled: warn=100, error=200
   ```

2. **Warning signals**:

   ```
   WARNING: Speech SDK object count exceeded warning threshold (100)
   Handle table dump by object type: ...
   ```

3. **Error conditions**:

   ```
   ERROR: The maximum object count of 200 has been exceeded
   ```

### Metrics to Track

- Object count warnings per hour
- Object count errors per hour
- Request failure rate due to threshold
- Object types in dump (identify leak sources)

## Tuning Guidelines

### Conservative (Default)

Suitable for:

- Development and testing
- Low-traffic services
- Debugging memory issues

```bash
STT_SPEECH_SDK_OBJECT_WARN_THRESHOLD=100
STT_SPEECH_SDK_OBJECT_ERROR_THRESHOLD=200
```

### High Concurrency

Suitable for:

- Production with high traffic
- Multiple concurrent requests
- Proven stable memory behavior

```bash
STT_SPEECH_SDK_OBJECT_WARN_THRESHOLD=500
STT_SPEECH_SDK_OBJECT_ERROR_THRESHOLD=1000
```

### Calculation

For high-concurrency environments:

```
concurrent_requests = threshold / 20 (objects per request)

Example with 500 warn threshold:
  500 / 20 = ~25 concurrent requests before warning
```

## Troubleshooting

### Warning Threshold Exceeded

1. Check if concurrent requests are high (normal under load)
2. Review recent changes to cleanup code
3. Look for SDK objects in object dump
4. Increase threshold if behavior is expected
5. Fix cleanup logic if objects are leaking

### Error Threshold Exceeded

1. Service stops accepting new requests (protective measure)
2. Indicates serious memory leak or traffic spike
3. **Immediate action**: Scale horizontally or restart pods
4. **Investigation**: Analyze object dump to identify leak
5. **Fix**: Improve cleanup logic or increase threshold

### Common Leak Sources

Based on our implementation:

- `ConversationTranscriber` not stopped/disconnected
- Event handlers not disconnected (circular references)
- `DefaultAzureCredential` not closed
- Audio streams not released
- Thread pool reusing threads with SDK objects

## Current Safeguards

Our service already implements aggressive cleanup:

1. ✅ Single-use thread pool executors (no thread reuse)
2. ✅ Explicit `stop_transcribing_async()` in finally block
3. ✅ Event handler disconnection (`disconnect_all()`)
4. ✅ Credential closing (`credential.close()`)
5. ✅ Explicit object deletion (`del transcriber`, etc.)
6. ✅ Immediate garbage collection (`gc.collect()`)
7. ✅ Temp file deletion during processing

**SDK memory tracking adds defense in depth** - catching leaks that escape our cleanup logic.

## References

- [Microsoft: Track Speech SDK Memory Usage](https://learn.microsoft.com/azure/ai-services/speech-service/how-to-track-speech-sdk-memory-usage)
- [Speech SDK Python API Reference](https://learn.microsoft.com/python/api/azure-cognitiveservices-speech/)
