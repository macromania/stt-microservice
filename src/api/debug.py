"""Debug API endpoints for memory and performance monitoring."""

import gc
import linecache
import logging
import sys
import tracemalloc

from fastapi import APIRouter, HTTPException, Query

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
