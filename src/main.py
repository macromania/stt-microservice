"""Main FastAPI application."""

import logging
import time

from fastapi import FastAPI, Request
from fastapi.concurrency import asynccontextmanager
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from src.api.debug import router as debug_router
from src.api.stt import router as stt_router
from src.core.config import get_settings
from src.core.logging import setup_logging
from src.core.process_metrics import ProcessPoolMonitor
from src.core.trace import extract_or_generate_trace_id, set_trace_id

# Initial basic logging configuration to capture logs during startup
logging.basicConfig(level=logging.INFO, force=True, format="%(asctime)s - %(levelname)s:    %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
logger = logging.getLogger(__name__)

# Global process pool monitor instance
_pool_monitor = None

logger.info("Loading application settings...")

# Load settings and setup logging
settings = get_settings()
setup_logging(log_level=settings.app_log_level or "INFO")
logger.info("Logging configured successfully.")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for startup and shutdown events."""
    # Startup code here
    logger.info("Initializing services...")

    # Initialize global process pool monitor
    global _pool_monitor
    _pool_monitor = ProcessPoolMonitor()
    logger.info("Process pool monitor initialized")

    # Eagerly initialize process pool to avoid delay on first request
    # This ensures the pool is ready before any traffic arrives
    try:
        from src.api.stt import get_process_service

        service = get_process_service()
        logger.info("Process pool initialized successfully during startup")
    except Exception as e:
        logger.error(f"Failed to initialize process pool: {e}")
        # Don't fail startup - pool will be initialized on first request as fallback

    logger.info("Application startup completed")

    yield

    # Shutdown code here
    logger.info("Shutting down application...")

    # Shutdown process pool if it exists
    try:
        from src.api.stt import get_process_service

        # Check if the service was ever created (lru_cache will have it cached)
        if get_process_service.cache_info().currsize > 0:
            logger.info("Shutting down process-isolated transcription service...")
            service = get_process_service()
            # Use 60s timeout to allow in-flight requests to complete
            # This works with terminationGracePeriodSeconds=180 in k8s
            service.shutdown(timeout=60)
            logger.info("Process pool shut down successfully")
    except (ImportError, AttributeError) as e:
        logger.debug(f"No process service to shutdown: {e}")

    logger.info("Application shutdown completed")


app = FastAPI(
    title="STT Microservice",
    description="Speech-to-Text Microservice using Azure Cognitive Services",
    version=settings.app_version,
    lifespan=lifespan,
    docs_url="/docs" if settings.env == "dev" else None,
    openapi_url="/openapi.json" if settings.env == "dev" else None,
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["*"],
)


@app.middleware("http")
async def request_logging_middleware(request: Request, call_next):
    """Log all requests with timing and trace ID.

    Extracts or generates a trace ID for each request, stores it in context,
    and adds it to response headers for distributed tracing.
    """
    start_time = time.time()

    # Extract or generate trace ID and set in context
    trace_id = extract_or_generate_trace_id(request)
    set_trace_id(trace_id)
    short_trace_id = trace_id[:8]

    # Process request
    response = await call_next(request)

    # Add trace ID to response headers
    response.headers["X-Trace-ID"] = trace_id

    # Log request with structured fields
    processing_time = time.time() - start_time
    logger.info(
        f"[{short_trace_id}] {request.method} {request.url.path} - Status: {response.status_code} - Time: {processing_time:.3f}s",
        extra={"trace_id": trace_id},
    )

    return response


# Register API routers
app.include_router(stt_router)
app.include_router(debug_router)

# Setup Prometheus metrics
instrumentator = Instrumentator()
instrumentator.instrument(app).expose(app)


@app.middleware("http")
async def update_pool_metrics_middleware(request: Request, call_next):
    """Update process pool metrics before each request for accurate monitoring."""
    global _pool_monitor

    # Update metrics before processing request
    if _pool_monitor is not None:
        try:
            from src.api.stt import (
                process_pool_avg_worker_memory_bytes,
                process_pool_cpu_percent,
                process_pool_memory_bytes,
                process_pool_worker_count,
            )

            # Update memory metrics
            mem_stats = _pool_monitor.get_aggregate_memory_usage()
            process_pool_memory_bytes.labels(process_type="total").set(mem_stats["total_rss_bytes"])
            process_pool_memory_bytes.labels(process_type="parent").set(mem_stats["parent_rss_bytes"])
            process_pool_memory_bytes.labels(process_type="workers").set(mem_stats["workers_rss_bytes"])
            process_pool_worker_count.set(mem_stats["worker_count"])
            process_pool_avg_worker_memory_bytes.set(mem_stats["per_worker_avg_bytes"])

            # Update CPU metrics
            cpu_stats = _pool_monitor.get_aggregate_cpu_usage()
            process_pool_cpu_percent.labels(process_type="total").set(cpu_stats["total_cpu_percent"])
            process_pool_cpu_percent.labels(process_type="parent").set(cpu_stats["parent_cpu_percent"])
            process_pool_cpu_percent.labels(process_type="workers").set(cpu_stats["workers_cpu_percent"])
        except Exception as e:
            logger.debug(f"Failed to update pool metrics: {e}")

    response = await call_next(request)
    return response


@app.get("/")
async def root():
    """Root endpoint with API information."""
    return {
        "name": "STT Microservice",
        "version": settings.app_version,
        "environment": settings.env,
    }


@app.get("/health")
async def health():
    """
    Lightweight health check endpoint for Kubernetes probes.

    This endpoint is intentionally simple and doesn't check dependencies
    to avoid blocking during heavy load or when transcription is in progress.
    """
    return {"status": "healthy"}


@app.get("/readiness")
async def readiness():
    """
    Readiness check endpoint for Kubernetes.

    Returns 200 if the service is ready to handle requests.
    Can be extended to check dependencies (Azure, etc.) if needed.
    """
    return {
        "status": "ready",
        "version": settings.app_version,
    }
