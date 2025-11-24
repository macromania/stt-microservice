"""
Process worker for isolated transcription execution.

This module provides the entry point for child processes that execute
transcription in complete memory isolation from the parent process.
"""

import logging
import os
import signal
import traceback
from typing import Any

# Set up logging before any other imports
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


def _setup_signal_handlers(timeout: int) -> None:
    """
    Set up signal handlers for timeout enforcement.

    Parameters
    ----------
    timeout : int
        Timeout in seconds after which SIGALRM will fire
    """

    def timeout_handler(signum, frame):
        logger.error(f"Process timeout after {timeout}s, raising TimeoutError")
        raise TimeoutError(f"Transcription exceeded timeout of {timeout} seconds")

    # Set SIGALRM handler
    signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(timeout)


def transcribe_in_process(
    audio_file_path: str,
    language: str,
    trace_id: str,
    resource_name: str | None,
    speech_region: str | None,
    timeout: int = 300,
) -> dict[str, Any]:
    """
    Execute transcription in isolated process.

    This function is the entry point for multiprocessing workers.
    It imports and executes _sync_transcribe_impl() with proper
    error handling and timeout enforcement.

    Parameters
    ----------
    audio_file_path : str
        Path to audio file
    language : str
        Language code or "auto"
    trace_id : str
        Trace ID for logging
    resource_name : str | None
        Azure AI Services resource name
    speech_region : str | None
        Azure region for Speech service
    timeout : int, optional
        Timeout in seconds (default: 300)

    Returns
    -------
    dict
        Serializable result dictionary with keys:
        - success: bool
        - data: dict (if success=True) containing segments, full_text, etc.
        - error: str (if success=False)
        - error_type: str (if success=False)
        - traceback: str (if success=False)

    Notes
    -----
    This function is designed to be called via multiprocessing.Pool.
    All return values must be JSON-serializable (no Pydantic models).

    The parent process will reconstruct TranscriptionResponse from
    the returned dictionary.
    """
    # Set up timeout enforcement
    _setup_signal_handlers(timeout)

    short_trace_id = trace_id[:8]
    logger.info(
        f"[{short_trace_id}] Process worker started (PID: {os.getpid()})",
        extra={"trace_id": trace_id},
    )

    try:
        # Import here to avoid loading Azure SDK in parent process
        from src.service.stt.service import _sync_transcribe_impl

        logger.info(
            f"[{short_trace_id}] Calling _sync_transcribe_impl",
            extra={"trace_id": trace_id},
        )

        # Execute transcription
        result = _sync_transcribe_impl(
            audio_file_path=audio_file_path,
            language=language,
            trace_id=trace_id,
            resource_name=resource_name,
            speech_region=speech_region,
        )

        # Convert segments to serializable dicts
        serializable_segments = []
        for seg in result["segments"]:
            # TranscriptionSegment is a Pydantic model, convert to dict
            if hasattr(seg, "model_dump"):
                # Pydantic v2 model
                seg_dict = seg.model_dump()
            elif hasattr(seg, "dict"):
                # Pydantic v1 model
                seg_dict = seg.dict()
            else:
                # Already a dict or plain object
                seg_dict = {
                    "text": seg.text,
                    "start_time": seg.start_time,
                    "end_time": seg.end_time,
                    "confidence": seg.confidence,
                    "speaker_id": seg.speaker_id,
                    "language": seg.language,
                }
            serializable_segments.append(seg_dict)

        logger.info(
            f"[{short_trace_id}] Transcription completed successfully",
            extra={"trace_id": trace_id},
        )

        # Cancel the alarm since we completed successfully
        signal.alarm(0)

        return {
            "success": True,
            "data": {
                "segments": serializable_segments,
                "full_text": result["full_text"],
                "detected_language": result["detected_language"],
                "speaker_count": result["speaker_count"],
            },
        }

    except TimeoutError as e:
        logger.error(
            f"[{short_trace_id}] Transcription timeout: {e}",
            extra={"trace_id": trace_id},
        )
        return {
            "success": False,
            "error": str(e),
            "error_type": "TimeoutError",
            "traceback": traceback.format_exc(),
        }

    except Exception as e:
        logger.error(
            f"[{short_trace_id}] Transcription failed: {e}",
            extra={"trace_id": trace_id},
            exc_info=True,
        )
        return {
            "success": False,
            "error": str(e),
            "error_type": type(e).__name__,
            "traceback": traceback.format_exc(),
        }

    finally:
        logger.info(
            f"[{short_trace_id}] Process worker exiting (PID: {os.getpid()})",
            extra={"trace_id": trace_id},
        )
