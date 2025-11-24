# Memory Debugging Guide

When diagnosing memory leaks in a Python service, especially when using third-party SDKs like Azure's Cognitive Services, it's crucial to have effective tools and methods to inspect memory usage and object retention.

## How to See Objects Staying in Memory for API Requests

Here are **5 practical methods** to inspect memory objects, from simple to advanced:

---

## **Method 1: Python's `tracemalloc` (Built-in, Recommended)**

Add memory snapshot comparison to your endpoint:

```python
# Add to src/api/stt.py
import tracemalloc
import gc

@router.post("", response_model=TranscriptionResponse)
async def create_transcription(...):
    # Start tracking
    tracemalloc.start()
    snapshot_before = tracemalloc.take_snapshot()
    
    try:
        # ... your existing code ...
        result = await service.process_audio(...)
        
        # Take snapshot after
        snapshot_after = tracemalloc.take_snapshot()
        
        # Compare snapshots
        top_stats = snapshot_after.compare_to(snapshot_before, 'lineno')
        
        # Log top 10 memory allocations
        logger.info(f"[{short_trace_id}] Top memory allocations:")
        for stat in top_stats[:10]:
            logger.info(f"  {stat}")
        
        return result
    finally:
        tracemalloc.stop()
        # ... cleanup ...
```

**Output example:**

```
Top memory allocations:
  src/service/stt/service.py:195: size=1024 KiB (+1024 KiB), count=1 (+1)
  azure/cognitiveservices/speech.py:425: size=2048 KiB (+2048 KiB), count=3 (+3)
```

---

## **Method 2: `objgraph` Library (Visual Object References)**

Install and use to see what's keeping objects alive:

```bash
# Add to pyproject.toml
poetry add objgraph --group dev
```

```python
# Add debug endpoint to src/api/stt.py
import objgraph
import gc

@router.get("/debug/memory-objects")
async def debug_memory_objects():
    """Debug endpoint to inspect memory objects"""
    gc.collect()  # Force collection first
    
    # Show most common types
    most_common = objgraph.most_common_types(limit=20)
    
    # Find objects that might be leaking
    transcriber_count = objgraph.count('ConversationTranscriber')
    speech_config_count = objgraph.count('SpeechConfig')
    
    # Generate object graph (saves to file)
    # objgraph.show_most_common_types(limit=10)
    
    return {
        "most_common_types": dict(most_common),
        "azure_sdk_objects": {
            "conversation_transcriber": transcriber_count,
            "speech_config": speech_config_count,
        },
        "total_objects": len(gc.get_objects())
    }
```

**Usage:**

```bash
# During/after load test:
curl http://localhost:8000/debug/memory-objects
```

---

## **Method 3: `memory_profiler` (Line-by-Line Profiling)**

Profile memory usage per line of code:

```bash
poetry add memory-profiler --group dev
```

```python
# Add decorator to the heavy function
from memory_profiler import profile

@profile  # This decorator prints line-by-line memory usage
async def process_audio(self, audio_file_path: str, ...):
    # ... existing code ...
```

**Run and see output:**

```
Line    Mem usage    Increment   Line Contents
=================================================
   95   125.5 MiB    0.0 MiB     async def process_audio(...):
  100   125.5 MiB    0.0 MiB         transcription_start = time.time()
  102  1250.8 MiB  1125.3 MiB         transcription = await self._transcribe_async(...)
  110   450.2 MiB -800.6 MiB         return response
```

---

## **Method 4: Prometheus Memory Metrics (Production-Ready)**

Add custom memory metrics to track objects:

```python
# Add to src/api/stt.py
from prometheus_client import Gauge
import gc
import sys

# Add memory metrics
stt_memory_objects = Gauge(
    'stt_memory_objects_total',
    'Total number of objects in memory',
    ['type']
)

stt_memory_usage_bytes = Gauge(
    'stt_memory_usage_bytes',
    'Process memory usage in bytes'
)

@router.post("", response_model=TranscriptionResponse)
async def create_transcription(...):
    try:
        # ... process request ...
        result = await service.process_audio(...)
        
        # Record metrics after request
        import psutil
        process = psutil.Process()
        stt_memory_usage_bytes.set(process.memory_info().rss)
        
        # Count objects by type
        all_objects = gc.get_objects()
        stt_memory_objects.labels(type='total').set(len(all_objects))
        
        # Count specific Azure SDK objects
        azure_objects = [obj for obj in all_objects 
                        if 'azure' in type(obj).__module__.lower()]
        stt_memory_objects.labels(type='azure_sdk').set(len(azure_objects))
        
        return result
    finally:
        # ... cleanup ...
```

**View in Prometheus:**

```promql
# Total objects over time
stt_memory_objects_total{type="total"}

# Azure SDK objects
stt_memory_objects_total{type="azure_sdk"}

# Memory growth
rate(stt_memory_usage_bytes[5m])
```

---

## **Method 5: `pympler` (Detailed Object Tracking)**

Most comprehensive but heaviest:

```bash
poetry add pympler --group dev
```

```python
# Add debug endpoint
from pympler import muppy, summary

@router.get("/debug/memory-summary")
async def memory_summary():
    """Detailed memory summary"""
    import gc
    gc.collect()
    
    all_objects = muppy.get_objects()
    sum_stats = summary.summarize(all_objects)
    
    # Format for JSON
    summary_lines = []
    for line in summary.format_(sum_stats)[:30]:  # Top 30
        summary_lines.append(line)
    
    return {
        "memory_summary": summary_lines,
        "total_objects": len(all_objects)
    }
```

**Output example:**

```json
{
  "memory_summary": [
    "                            types |   # objects |   total size",
    "================================= | =========== | ============",
    "                             dict |       45234 |     12.5 MiB",
    "                              str |       38421 |      8.2 MiB",
    "  azure.speech.ConversationTranscr|          12 |      3.8 MiB",
    "                             list |       12456 |      2.1 MiB"
  ]
}
```