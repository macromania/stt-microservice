"""Main FastAPI application."""

import logging
import time

from fastapi import FastAPI, Request
from fastapi.concurrency import asynccontextmanager
from fastapi.middleware.cors import CORSMiddleware

from src.core.config import get_settings
from src.core.logging import setup_logging

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

    OpenTelemetry's FastAPIInstrumentor automatically creates spans for HTTP requests
    and extracts/propagates trace IDs from X-Trace-ID headers. This middleware simply
    retrieves the trace ID for logging consistency and adds it to response headers.
    """
    start_time = time.time()

    # Process request (OpenTelemetry span is automatically created by FastAPIInstrumentor)
    response = await call_next(request)

    # Log request with structured fields
    processing_time = time.time() - start_time
    logger.info(f"Request: {request.method} {request.url} - Status: {response.status_code} - Time: {processing_time:.3f}s")

    return response


@app.get("/")
async def root():
    """Root endpoint with API information."""
    return {
        "name": "STT Microservice",
        "version": settings.app_version,
        "environment": settings.env,
    }
