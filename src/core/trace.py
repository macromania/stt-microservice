"""Trace ID management for request correlation and logging."""

from contextvars import ContextVar
from uuid import uuid4

from fastapi import Request

# Context variable to store trace ID for the current request
_trace_id_context: ContextVar[str | None] = ContextVar("trace_id", default=None)


def generate_trace_id() -> str:
    """
    Generate a new trace ID.

    Returns
    -------
    str
        A new UUID-based trace ID (32 hex characters)
    """
    return uuid4().hex


def set_trace_id(trace_id: str) -> None:
    """
    Set the trace ID for the current request context.

    Parameters
    ----------
    trace_id : str
        The trace ID to set
    """
    _trace_id_context.set(trace_id)


def get_trace_id() -> str:
    """
    Get the trace ID for the current request.

    If no trace ID exists in context, generates a new one.

    Returns
    -------
    str
        The current trace ID
    """
    trace_id = _trace_id_context.get()
    if trace_id is None:
        trace_id = generate_trace_id()
        set_trace_id(trace_id)
    return trace_id


def extract_or_generate_trace_id(request: Request) -> str:
    """
    Extract trace ID from request headers or generate a new one.

    Checks for trace ID in the following order:
    1. X-Trace-ID header
    2. X-Request-ID header
    3. Generate new UUID

    Parameters
    ----------
    request : Request
        The incoming FastAPI request

    Returns
    -------
    str
        The extracted or generated trace ID
    """
    # Try to extract from headers (support common trace header names)
    trace_id = request.headers.get("x-trace-id") or request.headers.get("x-request-id") or generate_trace_id()
    return trace_id
