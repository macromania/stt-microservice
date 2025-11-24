"""Debug API endpoints for memory and performance monitoring."""

import gc
import io
import linecache
import logging
from pathlib import Path
import sys
import tempfile
import tracemalloc

from fastapi import APIRouter, File, HTTPException, Query, UploadFile

from src.core.config import get_settings

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/debug",
    tags=["debug"],
)

settings = get_settings()

# Store snapshots for comparison
_snapshots: dict[str, tracemalloc.Snapshot] = {}


def get_object_size(obj) -> int:
    """Get size of object in bytes, handling errors gracefully."""
    try:
        return sys.getsizeof(obj)
    except (TypeError, AttributeError):
        return 0


def get_memory_stats() -> dict:
    """Get comprehensive memory statistics from garbage collector."""
    gc.collect()  # Force garbage collection for accurate stats

    # Count objects by type
    type_counts = {}
    type_sizes = {}

    for obj in gc.get_objects():
        obj_type = type(obj).__name__
        type_counts[obj_type] = type_counts.get(obj_type, 0) + 1

        # Calculate size
        obj_size = get_object_size(obj)
        type_sizes[obj_type] = type_sizes.get(obj_type, 0) + obj_size

    return {
        "type_counts": type_counts,
        "type_sizes": type_sizes,
    }


@router.get("/memory")
async def get_memory_info(
    top_n: int = Query(default=20, ge=1, le=100, description="Number of top objects to return"),
    sort_by: str = Query(default="size", regex="^(size|count)$", description="Sort by 'size' or 'count'"),
) -> dict:
    """Get memory allocation statistics.

    Returns total object count, top N object types by count or size,
    GC statistics, and memory breakdown.
    """
    stats = get_memory_stats()
    type_counts = stats["type_counts"]
    type_sizes = stats["type_sizes"]

    # Calculate totals
    total_objects = sum(type_counts.values())
    total_size = sum(type_sizes.values())

    # Sort by requested criteria
    if sort_by == "size":
        sorted_types = sorted(type_sizes.items(), key=lambda x: x[1], reverse=True)[:top_n]
    else:
        sorted_types = sorted(type_counts.items(), key=lambda x: x[1], reverse=True)[:top_n]

    # Build top objects list
    top_objects = []
    for obj_type, _ in sorted_types:
        count = type_counts.get(obj_type, 0)
        size = type_sizes.get(obj_type, 0)
        top_objects.append(
            {
                "type": obj_type,
                "count": count,
                "total_size_bytes": size,
                "avg_size_bytes": size // count if count > 0 else 0,
                "total_size_mb": round(size / (1024 * 1024), 2),
            }
        )

    # Get GC stats
    gc_stats = {
        "collections": gc.get_count(),
        "thresholds": gc.get_threshold(),
        "garbage_count": len(gc.garbage),
    }

    return {
        "summary": {
            "total_objects": total_objects,
            "total_size_bytes": total_size,
            "total_size_mb": round(total_size / (1024 * 1024), 2),
            "unique_types": len(type_counts),
        },
        "top_objects": top_objects,
        "gc_stats": gc_stats,
        "sort_by": sort_by,
    }


@router.get("/memory/types")
async def get_memory_by_type(
    type_name: str = Query(..., description="Object type name to search for (e.g., 'dict', 'list')"),
) -> dict:
    """Get detailed information about objects of a specific type.

    Returns count, total size, and average size for the specified type.
    """
    gc.collect()

    objects_of_type = [obj for obj in gc.get_objects() if type(obj).__name__ == type_name]
    count = len(objects_of_type)

    if count == 0:
        return {
            "type": type_name,
            "count": 0,
            "message": f"No objects of type '{type_name}' found",
        }

    total_size = sum(get_object_size(obj) for obj in objects_of_type)
    avg_size = total_size // count if count > 0 else 0

    # Get sample of object representations (first 10)
    samples = []
    for obj in objects_of_type[:10]:
        try:
            obj_repr = str(obj)[:100]  # Truncate long representations
            samples.append(obj_repr)
        except Exception:
            samples.append("<unable to represent>")

    return {
        "type": type_name,
        "count": count,
        "total_size_bytes": total_size,
        "total_size_mb": round(total_size / (1024 * 1024), 2),
        "avg_size_bytes": avg_size,
        "samples": samples,
    }


@router.post("/memory/gc")
async def trigger_garbage_collection() -> dict:
    """Manually trigger garbage collection and return statistics.

    Useful for forcing cleanup before checking memory usage.
    """
    before_count = sum(1 for _ in gc.get_objects())

    # Run garbage collection
    collected = gc.collect()

    after_count = sum(1 for _ in gc.get_objects())

    return {
        "collected_objects": collected,
        "objects_before": before_count,
        "objects_after": after_count,
        "objects_freed": before_count - after_count,
        "gc_stats": {
            "collections": gc.get_count(),
            "thresholds": gc.get_threshold(),
            "garbage_count": len(gc.garbage),
        },
    }


@router.get("/memory/referrers")
async def get_object_referrers(
    type_name: str = Query(..., description="Object type to analyze"),
    max_referrers: int = Query(default=5, ge=1, le=20, description="Max number of referrer types to show"),
) -> dict:
    """Get information about what's holding references to objects of a specific type.

    Useful for debugging memory leaks.
    """
    gc.collect()

    objects_of_type = [obj for obj in gc.get_objects() if type(obj).__name__ == type_name]

    if not objects_of_type:
        return {
            "type": type_name,
            "count": 0,
            "message": f"No objects of type '{type_name}' found",
        }

    # Analyze referrers for a sample of objects
    referrer_counts = {}
    sample_size = min(10, len(objects_of_type))

    for obj in objects_of_type[:sample_size]:
        referrers = gc.get_referrers(obj)
        for ref in referrers:
            ref_type = type(ref).__name__
            referrer_counts[ref_type] = referrer_counts.get(ref_type, 0) + 1

    # Sort by count
    top_referrers = sorted(referrer_counts.items(), key=lambda x: x[1], reverse=True)[:max_referrers]

    return {
        "type": type_name,
        "object_count": len(objects_of_type),
        "analyzed_sample_size": sample_size,
        "top_referrers": [{"type": ref_type, "count": count} for ref_type, count in top_referrers],
    }


# ============================================================================
# Tracemalloc Endpoints - Memory allocation tracking with source location
# ============================================================================


@router.post("/tracemalloc/start")
async def start_tracemalloc(frames: int = Query(default=25, ge=1, le=100, description="Number of frames to capture")) -> dict:
    """Start tracemalloc to track memory allocations with source location.

    Must be called before using other tracemalloc endpoints.
    """
    if tracemalloc.is_tracing():
        return {
            "status": "already_running",
            "message": "tracemalloc is already running",
            "frames": tracemalloc.get_traceback_limit(),
        }

    tracemalloc.start(frames)
    return {
        "status": "started",
        "message": f"tracemalloc started with {frames} frame limit",
        "frames": frames,
    }


@router.post("/tracemalloc/stop")
async def stop_tracemalloc() -> dict:
    """Stop tracemalloc."""
    if not tracemalloc.is_tracing():
        return {
            "status": "not_running",
            "message": "tracemalloc is not running",
        }

    tracemalloc.stop()
    return {
        "status": "stopped",
        "message": "tracemalloc stopped",
    }


@router.get("/tracemalloc/status")
async def get_tracemalloc_status() -> dict:
    """Get current tracemalloc status."""
    is_tracing = tracemalloc.is_tracing()

    result = {
        "is_tracing": is_tracing,
        "available_snapshots": list(_snapshots.keys()),
    }

    if is_tracing:
        result["frames"] = tracemalloc.get_traceback_limit()
        current, peak = tracemalloc.get_traced_memory()
        result["current_mb"] = round(current / (1024 * 1024), 2)
        result["peak_mb"] = round(peak / (1024 * 1024), 2)

    return result


@router.get("/tracemalloc/top")
async def get_top_allocations(
    top_n: int = Query(default=10, ge=1, le=100, description="Number of top allocations to return"),
    group_by: str = Query(default="lineno", regex="^(lineno|filename)$", description="Group by 'lineno' or 'filename'"),
) -> dict:
    """Get top memory allocations by source location.

    Shows where in your code memory is being allocated.
    """
    if not tracemalloc.is_tracing():
        raise HTTPException(status_code=400, detail="tracemalloc is not running. Call POST /debug/tracemalloc/start first")

    snapshot = tracemalloc.take_snapshot()

    # Group and sort statistics
    if group_by == "lineno":
        top_stats = snapshot.statistics("lineno")
    else:
        top_stats = snapshot.statistics("filename")

    top_stats = top_stats[:top_n]

    allocations = []
    for stat in top_stats:
        frame = stat.traceback[0]
        allocations.append(
            {
                "size_bytes": stat.size,
                "size_mb": round(stat.size / (1024 * 1024), 2),
                "count": stat.count,
                "filename": frame.filename,
                "lineno": frame.lineno if group_by == "lineno" else None,
                "line": linecache.getline(frame.filename, frame.lineno).strip() if group_by == "lineno" else None,
            }
        )

    current, peak = tracemalloc.get_traced_memory()

    return {
        "group_by": group_by,
        "top_allocations": allocations,
        "summary": {
            "current_mb": round(current / (1024 * 1024), 2),
            "peak_mb": round(peak / (1024 * 1024), 2),
        },
    }


@router.post("/tracemalloc/snapshot")
async def create_snapshot(name: str = Query(..., description="Name for this snapshot (e.g., 'before_test')")) -> dict:
    """Take a memory snapshot for later comparison.

    Snapshots are stored in memory and can be compared to track memory growth.
    """
    if not tracemalloc.is_tracing():
        raise HTTPException(status_code=400, detail="tracemalloc is not running. Call POST /debug/tracemalloc/start first")

    snapshot = tracemalloc.take_snapshot()
    _snapshots[name] = snapshot

    current, peak = tracemalloc.get_traced_memory()

    return {
        "status": "created",
        "name": name,
        "current_mb": round(current / (1024 * 1024), 2),
        "peak_mb": round(peak / (1024 * 1024), 2),
        "available_snapshots": list(_snapshots.keys()),
    }


@router.get("/tracemalloc/compare")
async def compare_snapshots(
    snapshot1: str = Query(..., description="First snapshot name"),
    snapshot2: str = Query(..., description="Second snapshot name"),
    top_n: int = Query(default=10, ge=1, le=100, description="Number of top differences to return"),
    group_by: str = Query(default="lineno", regex="^(lineno|filename)$", description="Group by 'lineno' or 'filename'"),
) -> dict:
    """Compare two snapshots to see memory growth/reduction.

    Shows what allocated or freed memory between snapshots.
    """
    if snapshot1 not in _snapshots:
        raise HTTPException(status_code=404, detail=f"Snapshot '{snapshot1}' not found")

    if snapshot2 not in _snapshots:
        raise HTTPException(status_code=404, detail=f"Snapshot '{snapshot2}' not found")

    snap1 = _snapshots[snapshot1]
    snap2 = _snapshots[snapshot2]

    # Compare snapshots
    if group_by == "lineno":
        top_stats = snap2.compare_to(snap1, "lineno")
    else:
        top_stats = snap2.compare_to(snap1, "filename")

    top_stats = top_stats[:top_n]

    differences = []
    for stat in top_stats:
        frame = stat.traceback[0]
        differences.append(
            {
                "size_diff_bytes": stat.size_diff,
                "size_diff_mb": round(stat.size_diff / (1024 * 1024), 2),
                "count_diff": stat.count_diff,
                "filename": frame.filename,
                "lineno": frame.lineno if group_by == "lineno" else None,
                "line": linecache.getline(frame.filename, frame.lineno).strip() if group_by == "lineno" else None,
            }
        )

    return {
        "snapshot1": snapshot1,
        "snapshot2": snapshot2,
        "group_by": group_by,
        "differences": differences,
    }


@router.delete("/tracemalloc/snapshot/{name}")
async def delete_snapshot(name: str) -> dict:
    """Delete a stored snapshot."""
    if name not in _snapshots:
        raise HTTPException(status_code=404, detail=f"Snapshot '{name}' not found")

    del _snapshots[name]

    return {
        "status": "deleted",
        "name": name,
        "remaining_snapshots": list(_snapshots.keys()),
    }


@router.get("/tracemalloc/traceback")
async def get_allocation_traceback(
    top_n: int = Query(default=5, ge=1, le=50, description="Number of top allocations to return"),
) -> dict:
    """Get detailed traceback for top memory allocations.

    Shows the full call stack for where memory was allocated.
    """
    if not tracemalloc.is_tracing():
        raise HTTPException(status_code=400, detail="tracemalloc is not running. Call POST /debug/tracemalloc/start first")

    snapshot = tracemalloc.take_snapshot()
    top_stats = snapshot.statistics("traceback")[:top_n]

    allocations = []
    for stat in top_stats:
        traceback_lines = []
        for frame in stat.traceback:
            traceback_lines.append(
                {
                    "filename": frame.filename,
                    "lineno": frame.lineno,
                    "line": linecache.getline(frame.filename, frame.lineno).strip(),
                }
            )

        allocations.append(
            {
                "size_bytes": stat.size,
                "size_mb": round(stat.size / (1024 * 1024), 2),
                "count": stat.count,
                "traceback": traceback_lines,
            }
        )

    return {
        "top_allocations": allocations,
    }


@router.post("/memory-profile")
async def profile_memory(
    audio_file: UploadFile = File(..., description="Audio file to process with memory profiling"),
) -> dict:
    """
    Profile memory usage of process_audio and _transcribe_async methods.

    This endpoint accepts an audio file, processes it through the transcription service
    with memory profiling enabled, and returns detailed line-by-line memory usage data.

    Returns profiling data for:
    - process_audio method (main entry point)
    - _sync_transcribe internal function (Azure SDK interaction)

    Note: This endpoint has significant overhead and should only be used for debugging.
    """
    from memory_profiler import profile as mp_profile

    from src.service.stt.service import TranscriptionService

    # Validate file
    if not audio_file or not audio_file.filename:
        raise HTTPException(status_code=400, detail="No audio file provided")

    file_ext = Path(audio_file.filename).suffix.lower()
    allowed_extensions = {".wav", ".mp3", ".m4a", ".flac", ".aac", ".ogg", ".webm", ".mp4"}
    if file_ext not in allowed_extensions:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file format. Allowed: {', '.join(allowed_extensions)}",
        )

    # Save uploaded file to temp location
    temp_file = None
    try:
        # Create temp file
        with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp:
            temp_file = tmp.name
            content = await audio_file.read()
            tmp.write(content)

        logger.info(f"Profiling transcription for file: {audio_file.filename} ({len(content)} bytes)")

        # Create service instance
        service = TranscriptionService()

        # Profile process_audio method
        process_audio_output = io.StringIO()
        profiled_process_audio = mp_profile(stream=process_audio_output)(service.process_audio)

        # Execute with profiling
        result = await profiled_process_audio(temp_file, language="auto")

        # Get profiling output
        process_audio_profiling = process_audio_output.getvalue()
        process_audio_output.close()

        # Parse the profiling data
        from src.core.profiler import parse_memory_profiler_output

        process_audio_data = parse_memory_profiler_output(process_audio_profiling)

        # Return profiling results along with transcription metadata
        return {
            "status": "success",
            "audio_file": audio_file.filename,
            "audio_size_bytes": len(content),
            "transcription_metadata": {
                "original_language": result.original_language,
                "segment_count": len(result.segments),
                "processing_time_seconds": result.processing_time_seconds,
                "transcription_time_seconds": result.transcription_time_seconds,
            },
            "profiling_data": {
                "process_audio": process_audio_data,
            },
            "warning": "Memory profiling adds significant overhead. Results may not reflect production performance.",
        }

    except Exception as e:
        logger.exception(f"Error during memory profiling: {e}")
        raise HTTPException(status_code=500, detail=f"Profiling failed: {e!s}")

    finally:
        # Cleanup temp file
        if temp_file and Path(temp_file).exists():
            try:
                Path(temp_file).unlink()
            except Exception as e:
                logger.warning(f"Failed to delete temp file {temp_file}: {e}")


@router.post("/memory-profile-deep")
async def profile_memory_deep(
    audio_file: UploadFile = File(..., description="Audio file to process with comprehensive memory profiling"),
) -> dict:
    """
    Deep memory profiling with GC analysis and cleanup phase tracking.

    Provides comprehensive memory analysis including:
    - Line-by-line profiling of process_audio and _sync_transcribe_impl
    - Memory snapshots before/after each major phase
    - GC effectiveness analysis
    - Cleanup phase tracking
    - Memory retention/leak detection

    Returns detailed insights into where memory is allocated and whether cleanup is effective.
    """
    import gc as garbage_collector

    from memory_profiler import profile as mp_profile

    from src.core.profiler import compare_memory_snapshots, get_memory_snapshot, parse_memory_profiler_output
    from src.service.stt.service import TranscriptionService, _sync_transcribe_impl

    # Validate file
    if not audio_file or not audio_file.filename:
        raise HTTPException(status_code=400, detail="No audio file provided")

    file_ext = Path(audio_file.filename).suffix.lower()
    allowed_extensions = {".wav", ".mp3", ".m4a", ".flac", ".aac", ".ogg", ".webm", ".mp4"}
    if file_ext not in allowed_extensions:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file format. Allowed: {', '.join(allowed_extensions)}",
        )

    temp_file = None
    try:
        # Save uploaded file
        with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp:
            temp_file = tmp.name
            content = await audio_file.read()
            tmp.write(content)

        logger.info(f"Deep profiling for: {audio_file.filename} ({len(content)} bytes)")

        # Phase 0: Initial state
        snapshot_initial = get_memory_snapshot("0_initial")

        # Create service
        service = TranscriptionService()
        trace_id = "profile-" + str(hash(audio_file.filename))[:8]

        snapshot_after_service_init = get_memory_snapshot("1_after_service_init")

        # Phase 1: Profile process_audio
        process_audio_output = io.StringIO()
        profiled_process_audio = mp_profile(stream=process_audio_output)(service.process_audio)

        snapshot_before_transcription = get_memory_snapshot("2_before_transcription")

        result = await profiled_process_audio(temp_file, language="auto", trace_id=trace_id)

        snapshot_after_transcription = get_memory_snapshot("3_after_transcription")

        # Parse process_audio profiling
        process_audio_profiling = process_audio_output.getvalue()
        process_audio_output.close()
        process_audio_data = parse_memory_profiler_output(process_audio_profiling)

        # Phase 2: Force GC and measure
        garbage_collector.collect()
        garbage_collector.collect()
        garbage_collector.collect()  # Full collection
        snapshot_after_first_gc = get_memory_snapshot("4_after_first_gc")

        # Phase 3: Profile _sync_transcribe_impl directly (for detailed line-by-line)
        # Create fresh temp file for this test
        with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp2:
            temp_file_2 = tmp2.name
            tmp2.write(content)

        sync_transcribe_output = io.StringIO()
        profiled_sync_transcribe = mp_profile(stream=sync_transcribe_output)(_sync_transcribe_impl)

        snapshot_before_sync_transcribe = get_memory_snapshot("5_before_sync_transcribe_test")

        # Run sync transcribe in thread pool (mimicking production)
        from concurrent.futures import ThreadPoolExecutor

        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="profile")
        loop = asyncio.get_running_loop()

        _ = await loop.run_in_executor(
            executor,
            profiled_sync_transcribe,
            temp_file_2,
            "auto",
            trace_id,
            service.resource_name,
            service.speech_region,
        )

        executor.shutdown(wait=True)
        del executor

        snapshot_after_sync_transcribe = get_memory_snapshot("6_after_sync_transcribe_test")

        # Parse sync_transcribe profiling
        sync_transcribe_profiling = sync_transcribe_output.getvalue()
        sync_transcribe_output.close()
        sync_transcribe_data = parse_memory_profiler_output(sync_transcribe_profiling)

        # Phase 4: Final GC
        garbage_collector.collect()
        garbage_collector.collect()
        garbage_collector.collect()
        snapshot_final = get_memory_snapshot("7_final_after_full_gc")

        # Calculate comparisons
        comparison_service_init = compare_memory_snapshots(snapshot_initial, snapshot_after_service_init)
        comparison_transcription = compare_memory_snapshots(snapshot_before_transcription, snapshot_after_transcription)
        comparison_first_gc = compare_memory_snapshots(snapshot_after_transcription, snapshot_after_first_gc)
        comparison_sync_test = compare_memory_snapshots(snapshot_before_sync_transcribe, snapshot_after_sync_transcribe)
        comparison_final_gc = compare_memory_snapshots(snapshot_after_sync_transcribe, snapshot_final)
        comparison_overall = compare_memory_snapshots(snapshot_initial, snapshot_final)

        # Cleanup temp file 2
        try:
            Path(temp_file_2).unlink()
        except Exception:
            pass

        # Build comprehensive response
        return {
            "status": "success",
            "audio_file": audio_file.filename,
            "audio_size_bytes": len(content),
            "transcription_metadata": {
                "original_language": result.original_language,
                "segment_count": len(result.segments),
                "processing_time_seconds": result.processing_time_seconds,
            },
            "memory_snapshots": {
                "0_initial": snapshot_initial,
                "1_after_service_init": snapshot_after_service_init,
                "2_before_transcription": snapshot_before_transcription,
                "3_after_transcription": snapshot_after_transcription,
                "4_after_first_gc": snapshot_after_first_gc,
                "5_before_sync_transcribe_test": snapshot_before_sync_transcribe,
                "6_after_sync_transcribe_test": snapshot_after_sync_transcribe,
                "7_final_after_full_gc": snapshot_final,
            },
            "memory_comparisons": {
                "service_init": comparison_service_init,
                "transcription_impact": comparison_transcription,
                "first_gc_effectiveness": comparison_first_gc,
                "sync_transcribe_test": comparison_sync_test,
                "final_gc_effectiveness": comparison_final_gc,
                "overall_retention": comparison_overall,
            },
            "profiling_data": {
                "process_audio": process_audio_data,
                "_sync_transcribe_impl": sync_transcribe_data,
            },
            "analysis": {
                "peak_memory_mb": snapshot_after_transcription["rss_mb"],
                "initial_memory_mb": snapshot_initial["rss_mb"],
                "final_memory_mb": snapshot_final["rss_mb"],
                "total_leaked_mb": round(snapshot_final["rss_mb"] - snapshot_initial["rss_mb"], 2),
                "gc_recovered_mb": round(snapshot_after_transcription["rss_mb"] - snapshot_final["rss_mb"], 2),
                "gc_effectiveness_pct": round(
                    (snapshot_after_transcription["rss_mb"] - snapshot_final["rss_mb"]) / max(snapshot_after_transcription["rss_mb"] - snapshot_initial["rss_mb"], 1) * 100,
                    1,
                ),
                "objects_retained": snapshot_final["total_objects"] - snapshot_initial["total_objects"],
                "azure_sdk_objects_retained": snapshot_final["azure_sdk_objects"] - snapshot_initial["azure_sdk_objects"],
            },
            "warnings": [
                "Memory profiling adds significant overhead",
                "Results may not reflect production performance",
                "Multiple transcriptions run for comprehensive analysis",
            ],
        }

    except Exception as e:
        logger.exception(f"Error during deep profiling: {e}")
        raise HTTPException(status_code=500, detail=f"Deep profiling failed: {e!s}")

    finally:
        # Cleanup
        if temp_file and Path(temp_file).exists():
            try:
                Path(temp_file).unlink()
            except Exception as e:
                logger.warning(f"Failed to delete temp file {temp_file}: {e}")
