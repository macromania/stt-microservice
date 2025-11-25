"""
Background task for collecting process memory metrics.

This module provides a non-blocking background task that periodically
collects memory statistics from the process pool and exposes them
to Prometheus.
"""

import asyncio
import logging
from typing import Any

logger = logging.getLogger(__name__)

# Global task reference for cancellation
_memory_collector_task: asyncio.Task[Any] | None = None


async def collect_process_memory_metrics() -> None:
    """
    Background task that collects process memory metrics every 15 seconds.

    This task runs continuously until cancelled, updating Prometheus
    gauges with current memory usage from the parent process and all
    worker processes.

    The task is safe to run even if the process service hasn't been
    initialized - it will simply skip collection until the service exists.
    """
    from src.api.stt import (
        get_process_service,
        process_parent_memory_bytes,
        process_per_worker_memory_bytes,
        process_total_memory_bytes,
        process_worker_count,
        process_workers_memory_bytes,
    )
    from src.core.process_metrics import ProcessPoolMonitor

    logger.info("Starting process memory collector (interval: 15s)")

    # Wait a bit for service initialization
    await asyncio.sleep(5)

    monitor: ProcessPoolMonitor | None = None

    while True:
        try:
            # Check if process service exists (lazy initialization)
            if get_process_service.cache_info().currsize > 0:
                # Initialize monitor if needed
                if monitor is None:
                    monitor = ProcessPoolMonitor()
                    logger.info("Process memory monitor initialized")

                # Collect memory stats
                memory_stats = monitor.get_aggregate_memory_usage()

                # Update Prometheus gauges
                process_parent_memory_bytes.set(memory_stats["parent_rss_bytes"])
                process_workers_memory_bytes.set(memory_stats["workers_rss_bytes"])
                process_worker_count.set(memory_stats["worker_count"])
                process_per_worker_memory_bytes.set(memory_stats["per_worker_avg_bytes"])
                process_total_memory_bytes.set(memory_stats["total_rss_bytes"])

                logger.debug(f"Memory stats: parent={memory_stats['parent_rss_bytes'] / 1024 / 1024:.1f}MB, workers={memory_stats['workers_rss_bytes'] / 1024 / 1024:.1f}MB, worker_count={memory_stats['worker_count']}")

        except asyncio.CancelledError:
            logger.info("Process memory collector cancelled")
            raise
        except Exception as e:
            logger.warning(f"Error collecting process memory metrics: {e}")
            # Continue running despite errors

        # Wait 15 seconds before next collection
        await asyncio.sleep(15)


def start_memory_collector() -> None:
    """
    Start the background memory collector task.

    This function should be called during application startup.
    The task will run in the background until stop_memory_collector() is called.
    """
    global _memory_collector_task

    if _memory_collector_task is not None:
        logger.warning("Memory collector is already running")
        return

    _memory_collector_task = asyncio.create_task(collect_process_memory_metrics())
    logger.info("Process memory collector started")


def stop_memory_collector() -> None:
    """
    Stop the background memory collector task.

    This function should be called during application shutdown.
    Waits up to 5 seconds for graceful cancellation.
    """
    global _memory_collector_task

    if _memory_collector_task is None:
        logger.debug("Memory collector is not running")
        return

    logger.info("Stopping process memory collector...")
    _memory_collector_task.cancel()

    try:
        # Give it a moment to cancel gracefully
        asyncio.get_event_loop().run_until_complete(asyncio.wait_for(asyncio.shield(_memory_collector_task), timeout=5))
    except (asyncio.CancelledError, TimeoutError):
        pass
    except Exception as e:
        logger.error(f"Error stopping memory collector: {e}")

    _memory_collector_task = None
    logger.info("Process memory collector stopped")
