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
from src.core.trace import extract_or_generate_trace_id, set_trace_id

# Initial basic logging configuration to capture logs during startup
logging.basicConfig(level=logging.INFO, force=True, format="%(asctime)s - %(levelname)s:    %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
logger = logging.getLogger(__name__)

logger.info("Loading application settings...")

# Load settings and setup logging
settings = get_settings()
setup_logging(log_level=settings.app_log_level or "INFO")
logger.info("Logging configured successfully.")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for startup and shutdown events."""
    # Startup code here
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
            service.shutdown()
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
Instrumentator().instrument(app).expose(app)


@app.get("/")
async def root():
    """Root endpoint with API information."""
    return {
        "name": "STT Microservice",
        "version": settings.app_version,
        "environment": settings.env,
    }
