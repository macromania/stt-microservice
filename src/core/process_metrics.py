"""
Process pool resource monitoring utilities.

Tracks memory and CPU usage across parent process and all worker processes
in the multiprocessing.Pool for accurate resource monitoring.
"""

import logging
import os
from typing import Any

import psutil

logger = logging.getLogger(__name__)


class ProcessPoolMonitor:
    """
    Monitor resource usage of parent process and all worker processes.

    Tracks memory, CPU, and process count for the entire process tree
    including multiprocessing.Pool worker processes.
    """

    def __init__(self):
        """Initialize the monitor with the current (parent) process."""
        self.parent_process = psutil.Process(os.getpid())

    def get_worker_processes(self) -> list[psutil.Process]:
        """
        Get all child worker processes spawned by multiprocessing.Pool.

        Returns
        -------
        list[psutil.Process]
            List of worker process objects
        """
        try:
            # Get all children of the parent process
            children = self.parent_process.children(recursive=False)
            return [p for p in children if p.is_running()]
        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.warning(f"Failed to get worker processes: {e}")
            return []

    def get_aggregate_memory_usage(self) -> dict[str, Any]:
        """
        Get total memory usage across parent and all worker processes.

        Returns
        -------
        dict
            Memory usage statistics with keys:
            - total_rss_bytes: Total resident set size (all processes)
            - parent_rss_bytes: Parent process RSS
            - workers_rss_bytes: Sum of all worker RSS
            - worker_count: Number of active worker processes
            - per_worker_avg_bytes: Average memory per worker
        """
        try:
            # Get parent memory
            parent_info = self.parent_process.memory_info()
            parent_rss = parent_info.rss

            # Get worker processes
            workers = self.get_worker_processes()
            worker_count = len(workers)

            # Sum worker memory
            workers_rss = 0
            for worker in workers:
                try:
                    worker_info = worker.memory_info()
                    workers_rss += worker_info.rss
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    # Worker may have exited during iteration
                    continue

            total_rss = parent_rss + workers_rss
            avg_worker_rss = workers_rss / worker_count if worker_count > 0 else 0

            return {
                "total_rss_bytes": total_rss,
                "parent_rss_bytes": parent_rss,
                "workers_rss_bytes": workers_rss,
                "worker_count": worker_count,
                "per_worker_avg_bytes": avg_worker_rss,
            }

        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.error(f"Failed to get aggregate memory usage: {e}")
            return {
                "total_rss_bytes": 0,
                "parent_rss_bytes": 0,
                "workers_rss_bytes": 0,
                "worker_count": 0,
                "per_worker_avg_bytes": 0,
            }

    def get_aggregate_cpu_usage(self) -> dict[str, Any]:
        """
        Get CPU usage across parent and all worker processes.

        Returns
        -------
        dict
            CPU usage statistics with keys:
            - total_cpu_percent: Total CPU usage (all processes)
            - parent_cpu_percent: Parent process CPU
            - workers_cpu_percent: Sum of all worker CPU
            - worker_count: Number of active worker processes
        """
        try:
            # Get parent CPU (as percentage, interval=None uses cached value)
            parent_cpu = self.parent_process.cpu_percent(interval=None)

            # Get worker processes
            workers = self.get_worker_processes()
            worker_count = len(workers)

            # Sum worker CPU
            workers_cpu = 0.0
            for worker in workers:
                try:
                    worker_cpu = worker.cpu_percent(interval=None)
                    workers_cpu += worker_cpu
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    # Worker may have exited during iteration
                    continue

            total_cpu = parent_cpu + workers_cpu

            return {
                "total_cpu_percent": total_cpu,
                "parent_cpu_percent": parent_cpu,
                "workers_cpu_percent": workers_cpu,
                "worker_count": worker_count,
            }

        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.error(f"Failed to get aggregate CPU usage: {e}")
            return {
                "total_cpu_percent": 0.0,
                "parent_cpu_percent": 0.0,
                "workers_cpu_percent": 0.0,
                "worker_count": 0,
            }

    def get_process_tree_info(self) -> dict[str, Any]:
        """
        Get detailed information about the entire process tree.

        Returns
        -------
        dict
            Process tree information including PIDs, memory, CPU for each process
        """
        try:
            parent_info = self.parent_process.as_dict(attrs=["pid", "name", "memory_info", "cpu_percent", "status"])

            workers = self.get_worker_processes()
            worker_info_list = []

            for worker in workers:
                try:
                    info = worker.as_dict(attrs=["pid", "name", "memory_info", "cpu_percent", "status"])
                    worker_info_list.append(
                        {
                            "pid": info["pid"],
                            "name": info["name"],
                            "rss_mb": info["memory_info"].rss / (1024 * 1024),
                            "cpu_percent": info["cpu_percent"],
                            "status": info["status"],
                        }
                    )
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue

            return {
                "parent": {
                    "pid": parent_info["pid"],
                    "name": parent_info["name"],
                    "rss_mb": parent_info["memory_info"].rss / (1024 * 1024),
                    "cpu_percent": parent_info["cpu_percent"],
                    "status": parent_info["status"],
                },
                "workers": worker_info_list,
                "worker_count": len(worker_info_list),
            }

        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.error(f"Failed to get process tree info: {e}")
            return {
                "parent": {},
                "workers": [],
                "worker_count": 0,
            }
