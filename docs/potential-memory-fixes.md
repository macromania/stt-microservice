# Potential Memory Fixes for STT Microservice

This document outlines several potential fixes to address memory retention issues observed in the STT microservice. Each fix includes a high-level plan, code snippets, and an analysis of the expected impact on memory usage and performance.

## High-Level Fix Plan with Code Snippets

Here are the specific locations and proposed changes for each fix:

---

### **Fix 1: Azure SDK Object Disposal**

**Location:** service.py - `_sync_transcribe()` function (lines ~160-260)

**Current Problem:**

```python
def _sync_transcribe() -> dict[str, Any]:
    try:
        speech_config = speechsdk.SpeechConfig(...)
        audio_config = speechsdk.audio.AudioConfig(filename=audio_file_path)
        transcriber = speechsdk.transcription.ConversationTranscriber(...)
        
        # ... transcription logic ...
        transcriber.stop_transcribing_async()
        
        return {...}
    finally:
        pass  # ⚠️ NO CLEANUP!
```

**Proposed Fix:**

```python
def _sync_transcribe() -> dict[str, Any]:
    transcriber = None
    audio_config = None
    speech_config = None
    
    try:
        # ... existing logic ...
        return {...}
    finally:
        # Explicit cleanup of Azure SDK objects
        if transcriber:
            try:
                transcriber.stop_transcribing_async().get()
                # Disconnect all event handlers
                transcriber.transcribed.disconnect_all()
                transcriber.session_stopped.disconnect_all()
                transcriber.canceled.disconnect_all()
            except Exception as e:
                logger.warning(f"Error during transcriber cleanup: {e}")
        
        # Let Python GC handle these, but help with explicit deletion
        del transcriber
        del audio_config
        del speech_config
```

---

### **Fix 2: Service Lifecycle Management**

**Location:** stt.py - Service dependency and endpoint cleanup

**Current Problem:**

```python
@lru_cache
def get_speech_service() -> TranscriptionService:
    """Cached singleton - never cleaned up"""
    return TranscriptionService()
```

**Proposed Fix Option A (Add cleanup endpoint):**

```python
# Keep singleton but add manual cleanup capability
@router.post("/admin/cleanup-cache")
async def cleanup_service_cache():
    """Force cleanup of cached service (admin only)"""
    get_speech_service.cache_clear()
    gc.collect()
    return {"status": "cache cleared"}
```

**Proposed Fix Option B (Remove caching):**

```python
# Remove @lru_cache - create new instance per request
# (Slower but no memory accumulation)
def get_speech_service() -> TranscriptionService:
    return TranscriptionService()
```

---

### **Fix 3: Explicit Garbage Collection**

**Locations:**

- stt.py - After request completion
- main.py - Periodic background task

**Current State:**

```python
finally:
    # Cleanup temp file
    if temp_file_path and Path(temp_file_path).exists():
        try:
            Path(temp_file_path).unlink()
        except Exception:
            logger.warning(...)
    # No GC trigger
```

**Proposed Fix A (After each request):**

```python
finally:
    # Cleanup temp file
    if temp_file_path and Path(temp_file_path).exists():
        try:
            Path(temp_file_path).unlink()
        except Exception:
            logger.warning(...)
    
    # Force garbage collection after heavy operation
    import gc
    gc.collect()
```

**Proposed Fix B (Periodic background task in main.py):**

```python
import gc
from fastapi import BackgroundTasks

async def periodic_gc_task():
    """Run garbage collection periodically"""
    while True:
        await asyncio.sleep(60)  # Every minute
        gc.collect()
        logger.debug("Periodic GC completed")

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Application startup completed")
    gc_task = asyncio.create_task(periodic_gc_task())
    
    yield
    
    # Shutdown
    gc_task.cancel()
    logger.info("Application shutdown completed")
```

---

### **Fix 4: Credential Caching Strategy**

**Location:** service.py - `__init__` and credential usage (lines ~58-68, ~165)

**Current Problem:**

```python
def __init__(self):
    # Singleton holds credential forever
    self.credential = DefaultAzureCredential()
```

**Proposed Fix Option A (Token-based instead of credential caching):**

```python
def __init__(self):
    # Don't cache credential object, only use tokens
    self.credential = None  # Only create when needed
    self._token_cache = None
    self._token_expiry = None

def _get_token(self):
    """Get token with expiry-based refresh"""
    import os
    from datetime import datetime, timedelta
    
    # Check env var first
    token = os.getenv("AZURE_ACCESS_TOKEN")
    if token:
        return token
    
    # Check cache
    now = datetime.now()
    if self._token_cache and self._token_expiry and now < self._token_expiry:
        return self._token_cache
    
    # Get fresh token
    if not self.credential:
        self.credential = DefaultAzureCredential()
    
    token_obj = self.credential.get_token("https://cognitiveservices.azure.com/.default")
    self._token_cache = token_obj.token
    self._token_expiry = datetime.fromtimestamp(token_obj.expires_on) - timedelta(minutes=5)
    
    return self._token_cache
```

**Proposed Fix Option B (Recreate credential per request - slower but cleaner):**

```python
async def _transcribe_async(self, ...):
    def _sync_transcribe():
        # Create credential fresh each time
        credential = DefaultAzureCredential()
        try:
            token = credential.get_token("...").token
            # ... rest of logic ...
        finally:
            del credential  # Explicit cleanup
```

---

## Summary of Impact

| Fix | Memory Impact | Performance Impact | Complexity |
|-----|--------------|-------------------|------------|
| **Fix 1: SDK Cleanup** | ⭐⭐⭐ High | None | Low |
| **Fix 2A: Cleanup Endpoint** | ⭐⭐ Medium | None | Low |
| **Fix 2B: Remove Cache** | ⭐⭐ Medium | -0.5s per request | Low |
| **Fix 3A: Per-Request GC** | ⭐⭐ Medium | ~10ms per request | Low |
| **Fix 3B: Periodic GC** | ⭐ Low | None | Medium |
| **Fix 4A: Token Cache** | ⭐ Low | +0.1s occasionally | Medium |
| **Fix 4B: No Credential Cache** | ⭐⭐ Medium | -2s per request | Low |
