"""Setup logging configuration for the application."""

import logging
import sys

from uvicorn.logging import DefaultFormatter


def setup_logging(log_level: str = "INFO") -> None:
    """Setup logging configuration."""
    # Setup root logger
    root_logger = logging.getLogger()
    root_logger.setLevel(getattr(logging, log_level.upper()))

    # Remove existing handlers
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    # Create console handler with appropriate formatter
    console_handler = logging.StreamHandler(sys.stdout)

    formatter = DefaultFormatter(fmt="%(asctime)s - %(levelprefix)s%(message)s", datefmt="%Y-%m-%d %H:%M:%S", use_colors=True)

    console_handler.setFormatter(formatter)
    root_logger.addHandler(console_handler)

    # Batch suppress noisy third-party loggers for cleaner logs
    suppressed_loggers = {
        "uvicorn.access": logging.WARNING,
        "httpx": logging.WARNING,
        "azure.core": logging.WARNING,
        "azure.monitor": logging.ERROR,  # Suppress config version mismatch warnings
        "azure": logging.WARNING,
        "azure.identity": logging.ERROR,  # Suppress authentication debug noise
    }

    for logger_name, level in suppressed_loggers.items():
        logging.getLogger(logger_name).setLevel(level)
