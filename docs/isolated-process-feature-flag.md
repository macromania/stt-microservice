# Implementation Plan: Feature Flag for Process-Isolated Endpoint

## Overview
The goal is to introduce a feature flag that allows completely disabling the `/transcriptions/process-isolated` endpoint and preventing the creation of the 12 worker processes. This will enable clean testing of the `/sync` endpoint without interference from the process-isolated workers.

## **Goal:**
Add a feature flag to completely disable `/transcriptions/process-isolated` endpoint and prevent the 12 worker processes from being created, allowing clean testing of `/sync` endpoint.

---

## **1. Configuration (Environment Variable)**

Add to .env / `config.py`:
```python
# src/core/config.py
class Settings(BaseSettings):
    # ... existing settings ...
    
    # Process isolation feature flag
    enable_process_isolated: bool = Field(
        default=True,
        env="ENABLE_PROCESS_ISOLATED",
        description="Enable process-isolated transcription endpoint and worker pool"
    )
```

**Usage:**
```bash
# Disable process-isolated endpoint
ENABLE_PROCESS_ISOLATED=false

# Or in .env file
ENABLE_PROCESS_ISOLATED=false
```

---

## **2. Conditional Endpoint Registration**

Modify stt.py:
```python
# Option A: Conditional decorator (cleaner)
settings = get_settings()

if settings.enable_process_isolated:
    @router.post("/process-isolated", response_model=TranscriptionResponse)
    async def create_transcription_process_isolated(...):
        # ... existing code ...

# Option B: Runtime check (keeps endpoint but returns 501 Not Implemented)
@router.post("/process-isolated", response_model=TranscriptionResponse)
async def create_transcription_process_isolated(...):
    if not settings.enable_process_isolated:
        raise HTTPException(
            status_code=501,
            detail="Process-isolated endpoint is disabled"
        )
    # ... existing code ...
```

**Recommendation:** Use **Option A** (conditional registration) - cleaner, endpoint doesn't appear in OpenAPI docs when disabled.

---

## **3. Prevent Worker Pool Initialization**

Modify `get_process_service()` singleton:
```python
# src/api/stt.py

@lru_cache(maxsize=1)
def get_process_service():
    """Get cached ProcessIsolatedTranscriptionService instance (singleton)."""
    settings = get_settings()
    
    # Return None if feature is disabled
    if not settings.enable_process_isolated:
        logger.info("Process-isolated service disabled by feature flag")
        return None
    
    from src.service.stt.process_service import ProcessIsolatedTranscriptionService
    return ProcessIsolatedTranscriptionService()
```

**Problem:** This still gets called during endpoint definition. Better approach:

---

## **4. Lazy Initialization (Better Approach)**

```python
# src/api/stt.py

# Remove @lru_cache and make it conditional
def get_process_service():
    """Get ProcessIsolatedTranscriptionService instance if enabled."""
    settings = get_settings()
    
    if not settings.enable_process_isolated:
        raise HTTPException(
            status_code=503,
            detail="Process-isolated endpoint is disabled via ENABLE_PROCESS_ISOLATED flag"
        )
    
    # Import and create only when actually called
    from src.service.stt.process_service import ProcessIsolatedTranscriptionService
    
    # Use a module-level cache
    global _process_service_instance
    if _process_service_instance is None:
        _process_service_instance = ProcessIsolatedTranscriptionService()
    
    return _process_service_instance

# Module-level cache
_process_service_instance = None
```

---

## **5. Update Memory Collector**

Modify memory_collector.py to handle missing worker pool:
```python
async def collect_process_memory_metrics() -> None:
    """Background task that collects process memory metrics."""
    settings = get_settings()
    
    # Skip worker metrics if feature disabled
    if not settings.enable_process_isolated:
        logger.info("Process memory collector: worker pool disabled, monitoring parent only")
        # Set worker metrics to 0
        process_workers_memory_bytes.set(0)
        process_worker_count.set(0)
        process_per_worker_memory_bytes.set(0)
        return
    
    # ... existing collection code ...
```

---

## **6. Graceful Shutdown**

Ensure shutdown doesn't try to close non-existent pool:
```python
# src/main.py (lifespan context)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    start_memory_collector()
    
    yield
    
    # Shutdown
    settings = get_settings()
    if settings.enable_process_isolated:
        service = get_process_service()
        if service is not None:
            await service.shutdown()
    
    stop_memory_collector()
```

---

## **7. Files to Modify**

1. **config.py** - Add `enable_process_isolated` setting
2. **stt.py** - Conditional endpoint registration and lazy service init
3. **memory_collector.py** - Skip worker metrics when disabled
4. **main.py** - Conditional shutdown
5. **`.env.example`** - Document the flag
6. **README.md** - Document feature flag usage

---

## **8. Testing Strategy**

```bash
# Test 1: With process-isolated ENABLED (default)
ENABLE_PROCESS_ISOLATED=true uvicorn main:app
# Should see: 12 worker processes, all endpoints available

# Test 2: With process-isolated DISABLED
ENABLE_PROCESS_ISOLATED=false uvicorn main:app
# Should see: 0 worker processes, /process-isolated returns 404 or not in docs

# Test 3: Load test /sync with workers disabled
ENABLE_PROCESS_ISOLATED=false
make load-test  # ENDPOINT=/transcriptions/sync
# Dashboard should show: Parent memory growing, Workers = 0
```

---

## **9. Expected Dashboard Behavior**

When `ENABLE_PROCESS_ISOLATED=false`:
```
Parent Process Memory: Growing (from /sync tests)
Worker Processes Memory: 0 GiB (flat line)
Active Worker Processes: 0
Avg Memory per Worker: 0 B
```

**Clean isolation** - you'll see ONLY the `/sync` endpoint memory leak without worker contamination!

---

## **10. Alternative: Separate Docker Compose Profile**

If you want environment-level separation:

```yaml
# docker-compose.yml
services:
  stt-sync-only:
    <<: *stt-base
    environment:
      - ENABLE_PROCESS_ISOLATED=false
    profiles: ["sync-only"]
  
  stt-full:
    <<: *stt-base
    environment:
      - ENABLE_PROCESS_ISOLATED=true
    profiles: ["full"]
```

**Usage:**
```bash
docker-compose --profile sync-only up  # Only /sync endpoint
docker-compose --profile full up       # All endpoints
```

---

## **Recommendation: Implement Order**

1. ✅ **Start with config** (`enable_process_isolated` setting)
2. ✅ **Add lazy initialization** (prevent worker creation)
3. ✅ **Update memory collector** (handle missing workers)
4. ✅ **Test with flag disabled** (verify 0 workers)
5. ✅ **Document usage** (README + .env.example)

This gives you a **clean /sync endpoint test environment** without worker process contamination!

Ready to implement? 🚀