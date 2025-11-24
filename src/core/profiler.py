"""Memory profiling utilities for debugging memory usage in async functions."""

import asyncio
from collections.abc import Callable
from functools import wraps
import io
import logging
import re
from typing import Any

from memory_profiler import profile as mp_profile

logger = logging.getLogger(__name__)


def parse_memory_profiler_output(output: str) -> dict[str, Any]:
    """
    Parse memory_profiler output into structured data.

    Parameters
    ----------
    output : str
        Raw output from memory_profiler

    Returns
    -------
    dict
        Structured profiling data with lines, peak memory, and total increase
    """
    lines = []
    peak_memory_mb = 0.0
    initial_memory_mb = 0.0

    # Pattern: Line # Mem usage Increment Occurrences Line Contents
    # Example: 95 125.5 MiB 0.0 MiB 1 async def process_audio(...):
    pattern = re.compile(r"^\s*(\d+)\s+([\d.]+)\s+MiB\s+([\d.\-]+)\s+MiB(?:\s+\d+)?\s+(.*)$")

    for line in output.split("\n"):
        match = pattern.match(line)
        if match:
            line_no = int(match.group(1))
            mem_mb = float(match.group(2))
            increment_mb = float(match.group(3))
            code = match.group(4).strip()

            lines.append({"line_no": line_no, "mem_mb": mem_mb, "increment_mb": increment_mb, "code": code})

            if mem_mb > peak_memory_mb:
                peak_memory_mb = mem_mb

            if initial_memory_mb == 0.0:
                initial_memory_mb = mem_mb

    total_increase_mb = peak_memory_mb - initial_memory_mb if initial_memory_mb > 0 else 0.0

    # Find top memory increases
    sorted_lines = sorted(lines, key=lambda x: x["increment_mb"], reverse=True)
    top_increases = sorted_lines[:5]

    return {"lines": lines, "peak_memory_mb": round(peak_memory_mb, 2), "initial_memory_mb": round(initial_memory_mb, 2), "total_increase_mb": round(total_increase_mb, 2), "top_memory_increases": top_increases}


def profile_function(func: Callable) -> tuple[Any, dict[str, Any]]:
    """
    Profile a function and return both its result and profiling data.

    This wraps a function with memory_profiler and captures the output.

    Parameters
    ----------
    func : Callable
        Function to profile (can be sync or async)

    Returns
    -------
    tuple[T, dict]
        Function result and parsed profiling data
    """
    # Capture memory_profiler output
    output_buffer = io.StringIO()

    # Create profiled version of the function
    profiled_func = mp_profile(stream=output_buffer)(func)

    # Execute the function
    if asyncio.iscoroutinefunction(func):
        # For async functions
        async def async_wrapper(*args, **kwargs):
            result = await profiled_func(*args, **kwargs)
            return result

        # Run in event loop
        result = asyncio.run(async_wrapper())
    else:
        # For sync functions
        result = profiled_func()

    # Get profiling output
    profiling_output = output_buffer.getvalue()
    output_buffer.close()

    # Parse the output
    profiling_data = parse_memory_profiler_output(profiling_output)

    return result, profiling_data


def profile_async(func: Callable) -> Callable:
    """
    Decorator to profile async functions and return both result and profiling data.

    Usage:
        @profile_async
        async def my_function():
            ...

        result, profiling_data = await my_function()

    Parameters
    ----------
    func : Callable
        Async function to profile

    Returns
    -------
    Callable
        Wrapped function that returns (result, profiling_data)
    """

    @wraps(func)
    async def wrapper(*args, **kwargs) -> tuple[Any, dict[str, Any]]:
        output_buffer = io.StringIO()

        # Create profiled version
        profiled_func = mp_profile(stream=output_buffer)(func)

        # Execute
        result = await profiled_func(*args, **kwargs)

        # Parse output
        profiling_output = output_buffer.getvalue()
        output_buffer.close()
        profiling_data = parse_memory_profiler_output(profiling_output)

        logger.debug(f"Profiled {func.__name__}: peak={profiling_data['peak_memory_mb']}MB, increase={profiling_data['total_increase_mb']}MB")

        return result, profiling_data

    return wrapper


class MemoryProfiler:
    """
    Context manager for profiling memory usage of code blocks.

    Usage:
        with MemoryProfiler() as profiler:
            # code to profile
            ...

        profiling_data = profiler.get_results()
    """

    def __init__(self):
        """Initialize the profiler."""
        self.output_buffer = io.StringIO()
        self.profiling_data = None

    def __enter__(self):
        """Enter context - not really used for memory_profiler but kept for consistency."""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Exit context and capture results."""
        profiling_output = self.output_buffer.getvalue()
        self.output_buffer.close()

        if profiling_output:
            self.profiling_data = parse_memory_profiler_output(profiling_output)

    def get_results(self) -> dict[str, Any] | None:
        """Get parsed profiling results."""
        return self.profiling_data
