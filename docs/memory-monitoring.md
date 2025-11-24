# Memory Monitoring Endpoints

Debug endpoints for monitoring Python memory allocation using both `gc` (garbage collector) and `tracemalloc` modules.

## Overview

This implementation provides **two complementary approaches**:

1. **`gc` endpoints** (`/debug/memory/*`) - Object counting and type analysis
2. **`tracemalloc` endpoints** (`/debug/tracemalloc/*`) - Allocation tracking with source code location

## GC Endpoints (Object Analysis)

### 1. GET `/debug/memory`

Get comprehensive memory allocation statistics.

**Query Parameters:**

- `top_n` (int, default=20): Number of top objects to return (1-100)
- `sort_by` (string, default="size"): Sort by `size` or `count`

**Example:**

```bash
curl "http://localhost:8000/debug/memory?top_n=10&sort_by=size"
```

**Response:**

```json
{
  "summary": {
    "total_objects": 45678,
    "total_size_bytes": 12345678,
    "total_size_mb": 11.77,
    "unique_types": 234
  },
  "top_objects": [
    {
      "type": "dict",
      "count": 5432,
      "total_size_bytes": 2345678,
      "avg_size_bytes": 432,
      "total_size_mb": 2.24
    },
    ...
  ],
  "gc_stats": {
    "collections": [123, 45, 6],
    "thresholds": [700, 10, 10],
    "garbage_count": 0
  },
  "sort_by": "size"
}
```

### 2. GET `/debug/memory/types`

Get detailed information about objects of a specific type.

**Query Parameters:**

- `type_name` (string, required): Object type name (e.g., 'dict', 'list', 'str')

**Example:**

```bash
curl "http://localhost:8000/debug/memory/types?type_name=dict"
```

**Response:**

```json
{
  "type": "dict",
  "count": 5432,
  "total_size_bytes": 2345678,
  "total_size_mb": 2.24,
  "avg_size_bytes": 432,
  "samples": [
    "{'key': 'value'}",
    "{'another': 'dict'}",
    ...
  ]
}
```

### 3. POST `/debug/memory/gc`

Manually trigger garbage collection.

**Example:**

```bash
curl -X POST "http://localhost:8000/debug/memory/gc"
```

**Response:**

```json
{
  "collected_objects": 42,
  "objects_before": 45678,
  "objects_after": 45636,
  "objects_freed": 42,
  "gc_stats": {
    "collections": [124, 45, 6],
    "thresholds": [700, 10, 10],
    "garbage_count": 0
  }
}
```

### 4. GET `/debug/memory/referrers`

Analyze what's holding references to objects (useful for memory leak debugging).

**Query Parameters:**

- `type_name` (string, required): Object type to analyze
- `max_referrers` (int, default=5): Max number of referrer types to show (1-20)

**Example:**

```bash
curl "http://localhost:8000/debug/memory/referrers?type_name=dict&max_referrers=10"
```

**Response:**

```json
{
  "type": "dict",
  "object_count": 5432,
  "analyzed_sample_size": 10,
  "top_referrers": [
    {"type": "list", "count": 45},
    {"type": "dict", "count": 32},
    {"type": "module", "count": 12}
  ]
}
```

## Use Cases

### 1. Monitor Memory Usage During Load Testing

```bash
# Before test
curl "http://localhost:8000/debug/memory?top_n=20" > before.json

# Run load test
# ...

# After test
curl "http://localhost:8000/debug/memory?top_n=20" > after.json

# Compare results
```

### 2. Debug Memory Leaks

```bash
# Find objects that are growing unexpectedly
curl "http://localhost:8000/debug/memory?sort_by=count&top_n=20"

# Check what's holding references to leaked objects
curl "http://localhost:8000/debug/memory/referrers?type_name=SpeechRecognizer"
```

### 3. Force Cleanup Before Testing

```bash
# Trigger GC before measuring
curl -X POST "http://localhost:8000/debug/memory/gc"

# Then get clean memory stats
curl "http://localhost:8000/debug/memory"
```

### 4. Monitor Specific Object Types

```bash
# Check Azure SDK objects
curl "http://localhost:8000/debug/memory/types?type_name=SpeechRecognizer"

# Check asyncio tasks
curl "http://localhost:8000/debug/memory/types?type_name=Task"
```

## Performance Considerations

- These endpoints trigger full garbage collection, which can cause brief pauses
- They iterate through all objects in memory, which can be slow with many objects
- Use only during development or debugging, not in production hot paths
- Consider adding authentication/authorization for production environments

## Disabling in Production

To disable these endpoints in production, you can:

1. Add a setting in `src/core/config.py`:

```python
enable_debug_endpoints: bool = Field(default=False)
```

2. Conditionally register the router in `src/main.py`:

```python
if settings.enable_debug_endpoints:
    app.include_router(debug_router)
```

## Common Object Types to Monitor

- `dict`: Dictionaries (configuration, caches, etc.)
- `list`: Lists (buffers, queues, etc.)
- `str`: Strings (text data, logs, etc.)
- `bytes`: Byte arrays (audio data, file contents, etc.)
- `Task`: Asyncio tasks
- `Future`: Asyncio futures
- `SpeechRecognizer`: Azure Speech SDK objects
- `SpeechConfig`: Azure Speech configuration objects
- `DataFrame`: Pandas dataframes (if used)

---

## Tracemalloc Endpoints (Allocation Tracking)

Tracemalloc provides **source code location** tracking - showing WHERE in your code memory is allocated.

### Setup: Start Tracemalloc

**POST `/debug/tracemalloc/start`**

Must be called before using other tracemalloc endpoints.

**Query Parameters:**
- `frames` (int, default=25): Number of call stack frames to capture (1-100)

**Example:**
```bash
curl -X POST "http://localhost:8000/debug/tracemalloc/start?frames=25"
```

**Response:**
```json
{
  "status": "started",
  "message": "tracemalloc started with 25 frame limit",
  "frames": 25
}
```

### 1. GET `/debug/tracemalloc/status`
Check if tracemalloc is running and view available snapshots.

**Example:**
```bash
curl "http://localhost:8000/debug/tracemalloc/status"
```

**Response:**
```json
{
  "is_tracing": true,
  "frames": 25,
  "current_mb": 45.23,
  "peak_mb": 67.89,
  "available_snapshots": ["before_test", "after_test"]
}
```

### 2. GET `/debug/tracemalloc/top`
Get top memory allocations **with source code location**.

**Query Parameters:**
- `top_n` (int, default=10): Number of top allocations (1-100)
- `group_by` (string, default="lineno"): Group by `lineno` or `filename`

**Example:**
```bash
curl "http://localhost:8000/debug/tracemalloc/top?top_n=10&group_by=lineno"
```

**Response:**
```json
{
  "group_by": "lineno",
  "top_allocations": [
    {
      "size_bytes": 2345678,
      "size_mb": 2.24,
      "count": 1234,
      "filename": "/workspaces/stt-microservice/src/service/stt/service.py",
      "lineno": 145,
      "line": "audio_data = await asyncio.to_thread(recognizer.recognize_once_async)"
    },
    ...
  ],
  "summary": {
    "current_mb": 45.23,
    "peak_mb": 67.89
  }
}
```

### 3. POST `/debug/tracemalloc/snapshot`
Take a memory snapshot for later comparison.

**Query Parameters:**
- `name` (string, required): Snapshot name (e.g., "before_test", "after_request")

**Example:**
```bash
curl -X POST "http://localhost:8000/debug/tracemalloc/snapshot?name=before_test"
```

**Response:**
```json
{
  "status": "created",
  "name": "before_test",
  "current_mb": 45.23,
  "peak_mb": 67.89,
  "available_snapshots": ["before_test"]
}
```

### 4. GET `/debug/tracemalloc/compare`
Compare two snapshots to see memory growth/reduction with **source locations**.

**Query Parameters:**
- `snapshot1` (string, required): First snapshot name
- `snapshot2` (string, required): Second snapshot name
- `top_n` (int, default=10): Number of top differences
- `group_by` (string, default="lineno"): Group by `lineno` or `filename`

**Example:**
```bash
curl "http://localhost:8000/debug/tracemalloc/compare?snapshot1=before_test&snapshot2=after_test&top_n=10"
```

**Response:**
```json
{
  "snapshot1": "before_test",
  "snapshot2": "after_test",
  "group_by": "lineno",
  "differences": [
    {
      "size_diff_bytes": 1234567,
      "size_diff_mb": 1.18,
      "count_diff": 500,
      "filename": "/workspaces/stt-microservice/src/service/stt/service.py",
      "lineno": 145,
      "line": "audio_data = await asyncio.to_thread(recognizer.recognize_once_async)"
    },
    ...
  ]
}
```

### 5. GET `/debug/tracemalloc/traceback`
Get detailed call stack traceback for top allocations.

**Query Parameters:**
- `top_n` (int, default=5): Number of top allocations (1-50)

**Example:**
```bash
curl "http://localhost:8000/debug/tracemalloc/traceback?top_n=3"
```

**Response:**
```json
{
  "top_allocations": [
    {
      "size_bytes": 2345678,
      "size_mb": 2.24,
      "count": 1234,
      "traceback": [
        {
          "filename": "/workspaces/stt-microservice/src/service/stt/service.py",
          "lineno": 145,
          "line": "audio_data = await asyncio.to_thread(recognizer.recognize_once_async)"
        },
        {
          "filename": "/workspaces/stt-microservice/src/api/stt.py",
          "lineno": 89,
          "line": "result = await service.transcribe_and_translate(audio_file)"
        },
        ...
      ]
    }
  ]
}
```

### 6. DELETE `/debug/tracemalloc/snapshot/{name}`
Delete a stored snapshot.

**Example:**
```bash
curl -X DELETE "http://localhost:8000/debug/tracemalloc/snapshot/before_test"
```

### 7. POST `/debug/tracemalloc/stop`
Stop tracemalloc tracking.

**Example:**
```bash
curl -X POST "http://localhost:8000/debug/tracemalloc/stop"
```

---

## Comparison: gc vs tracemalloc

| Feature | GC Endpoints | Tracemalloc Endpoints |
|---------|-------------|----------------------|
| **What it shows** | Object counts and sizes by type | Memory allocations by source location |
| **Source location** | ❌ No | ✅ Yes (file + line number) |
| **Performance impact** | Low (only when called) | Low to Medium (always tracking when enabled) |
| **Memory overhead** | None | ~2-5% |
| **Call stack** | ❌ No | ✅ Yes (full traceback) |
| **Snapshot comparison** | ❌ No | ✅ Yes |
| **Best for** | Finding leaked object types | Finding WHERE memory is allocated |

## Complete Workflow Example

### Scenario: Debug Memory Leak During Load Test

```bash
# 1. Start tracemalloc
curl -X POST "http://localhost:8000/debug/tracemalloc/start?frames=25"

# 2. Take baseline snapshot
curl -X POST "http://localhost:8000/debug/tracemalloc/snapshot?name=baseline"

# 3. Check object types (gc)
curl "http://localhost:8000/debug/memory?top_n=20&sort_by=size"

# 4. Run your load test
# ... send requests ...

# 5. Take after snapshot
curl -X POST "http://localhost:8000/debug/tracemalloc/snapshot?name=after_load_test"

# 6. Compare snapshots to see what grew (with source locations!)
curl "http://localhost:8000/debug/tracemalloc/compare?snapshot1=baseline&snapshot2=after_load_test&top_n=20"

# 7. Check object types again
curl "http://localhost:8000/debug/memory?top_n=20&sort_by=size"

# 8. Get detailed traceback for top allocations
curl "http://localhost:8000/debug/tracemalloc/traceback?top_n=10"

# 9. Force garbage collection
curl -X POST "http://localhost:8000/debug/memory/gc"

# 10. Check if objects were cleaned up
curl "http://localhost:8000/debug/memory?top_n=20"
```

### Scenario: Find Specific Memory Leak Source

```bash
# 1. Start tracking
curl -X POST "http://localhost:8000/debug/tracemalloc/start?frames=25"

# 2. Get top allocations by file
curl "http://localhost:8000/debug/tracemalloc/top?top_n=20&group_by=filename"

# 3. Get detailed line-by-line allocations
curl "http://localhost:8000/debug/tracemalloc/top?top_n=50&group_by=lineno"

# 4. Check what's holding references to leaked objects
curl "http://localhost:8000/debug/memory/referrers?type_name=SpeechRecognizer"

# 5. Get full call stack for allocations
curl "http://localhost:8000/debug/tracemalloc/traceback?top_n=10"
```

## Answer to Your Question

**Yes!** The new `tracemalloc` endpoints provide:

✅ **Class allocation details** - See which classes are being instantiated and where  
✅ **Source code location** - File name and line number for each allocation  
✅ **Call stack traceback** - Full call chain showing how you got there  
✅ **Snapshot comparison** - Track memory growth between points in time  
✅ **Memory attribution** - Know exactly which line of code allocated memory  

This is **more detailed than just gc** and gives you the same capabilities as running `tracemalloc` directly in your code, but exposed via REST API.

