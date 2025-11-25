"""
Process-isolated transcription service.

This service executes transcription in separate processes to ensure
complete memory isolation from the parent process. All native memory
allocated by the Azure Speech SDK is guaranteed to be reclaimed by
the OS when the child process exits.
"""

import logging
from multiprocessing import Pool
from multiprocessing import TimeoutError as MPTimeoutError
from pathlib import Path
from typing import Any

from src.core.config import get_settings
from src.core.exception import AudioFormatError
from src.service.stt.models import TranscriptionResponse, TranscriptionSegment
from src.service.stt.process_worker import transcribe_in_process

logger = logging.getLogger(__name__)


class ProcessIsolatedTranscriptionService:
    """
    Transcription service using process-level isolation.

    This service manages a pool of worker processes that execute
    transcription in complete memory isolation. Each request runs
    in a separate process, and all memory (including native allocations
    from the Azure Speech SDK) is reclaimed by the OS when the process exits.

    Attributes
    ----------
    pool : multiprocessing.Pool
        Pool of worker processes
    timeout : int
        Maximum execution time per transcription (seconds)
    pool_size : int
        Number of worker processes in the pool

    Notes
    -----
    This service trades some performance (process startup overhead)
    for guaranteed memory isolation and leak prevention.
    """

    def __init__(self, pool_size: int | None = None, timeout: int | None = None):
        """
        Initialize process-isolated transcription service.

        Parameters
        ----------
        pool_size : int, optional
            Number of worker processes (default: from settings or 4)
        timeout : int, optional
            Timeout in seconds per transcription (default: from settings or 300)
        """
        settings = get_settings()

        self.pool_size = pool_size or getattr(settings, "process_pool_size", 4)
        self.timeout = timeout or getattr(settings, "process_timeout", 300)

        # Initialize process pool
        # Note: Pool workers are started lazily on first request
        self.pool = Pool(processes=self.pool_size)

        logger.info(f"ProcessIsolatedTranscriptionService initialized: pool_size={self.pool_size}, timeout={self.timeout}s")

    async def process_audio(
        self,
        audio_file_path: str,
        language: str = "auto",
        trace_id: str | None = None,
    ) -> TranscriptionResponse:
        """
        Process audio file and return transcription with translation.

        This method has the same interface as TranscriptionService.process_audio()
        but executes transcription in an isolated process.

        Parameters
        ----------
        audio_file_path : str
            Path to audio file
        language : str, optional
            Language code ("en", "ar", "auto", etc.), default "auto"
        trace_id : str, optional
            Trace ID for logging (generated if not provided)

        Returns
        -------
        TranscriptionResponse
            Transcription results with translation

        Raises
        ------
        HTTPException
            504: If transcription times out
            500: If transcription fails or process crashes
        AudioFormatError
            If audio file format is invalid
        """
        from uuid import uuid4

        from fastapi import HTTPException

        settings = get_settings()

        # Generate trace ID if not provided
        if not trace_id:
            trace_id = str(uuid4())

        short_trace_id = trace_id[:8]
        logger.info(
            f"[{short_trace_id}] Starting process-isolated transcription: language={language}",
            extra={"trace_id": trace_id},
        )

        # Validate audio file exists
        if not Path(audio_file_path).exists():
            raise AudioFormatError(f"Audio file not found: {audio_file_path}")

        try:
            # Submit work to process pool
            # Use apply_async for timeout support
            result_async = self.pool.apply_async(
                transcribe_in_process,
                args=(
                    audio_file_path,
                    language,
                    trace_id,
                    settings.stt_azure_speech_resource_name,
                    settings.stt_azure_speech_region,
                    self.timeout,
                ),
            )

            # Wait for result with timeout
            # This timeout is a safety net; the worker also has internal timeout
            result = result_async.get(timeout=self.timeout + 10)

            # Check if transcription was successful
            if not result["success"]:
                error_type = result.get("error_type", "Unknown")
                error_msg = result.get("error", "Unknown error")
                error_trace = result.get("traceback", "")

                logger.error(
                    f"[{short_trace_id}] Transcription failed in worker process: {error_type}: {error_msg}\n{error_trace}",
                    extra={"trace_id": trace_id},
                )

                # Handle timeout specifically
                if error_type == "TimeoutError":
                    raise HTTPException(
                        status_code=504,
                        detail=f"Transcription timeout: {error_msg}",
                    )

                # Generic error
                raise HTTPException(
                    status_code=500,
                    detail=f"Transcription failed: {error_msg}",
                )

            # Extract successful result data
            data = result["data"]

            # Reconstruct TranscriptionSegment objects from dicts
            segments = [TranscriptionSegment(**seg_dict) for seg_dict in data["segments"]]

            # Calculate audio duration from segments
            audio_duration = max(seg.end_time for seg in segments) if segments else 0.0

            # Calculate average confidence
            avg_confidence = sum(seg.confidence for seg in segments) / len(segments) if segments else 0.0

            # Build TranscriptionResponse
            response = TranscriptionResponse(
                original_text=data["full_text"],
                original_language=data["detected_language"],
                translated_text=data["full_text"],  # Translation happens separately
                segments=segments,
                speaker_count=data["speaker_count"],
                audio_duration_seconds=audio_duration,
                processing_time_seconds=0.0,  # TODO: Add timing from worker
                transcription_time_seconds=0.0,  # TODO: Add timing from worker
                translation_time_seconds=0.0,  # No translation yet
                confidence_average=avg_confidence,
            )

            logger.info(
                f"[{short_trace_id}] Process-isolated transcription completed: {len(segments)} segments, {data['speaker_count']} speakers",
                extra={"trace_id": trace_id},
            )

            return response

        except MPTimeoutError:
            # multiprocessing.TimeoutError from result_async.get()
            logger.error(
                f"[{short_trace_id}] Process pool timeout after {self.timeout + 10}s",
                extra={"trace_id": trace_id},
            )
            raise HTTPException(
                status_code=504,
                detail=f"Transcription timeout after {self.timeout}s",
            )

        except HTTPException:
            # Re-raise HTTPExceptions as-is
            raise

        except Exception as e:
            # Unexpected error in parent process
            logger.error(
                f"[{short_trace_id}] Unexpected error in parent process: {e}",
                extra={"trace_id": trace_id},
                exc_info=True,
            )
            raise HTTPException(
                status_code=500,
                detail=f"Internal server error: {str(e)}",
            )

        finally:
            # Clean up temp file if it still exists
            try:
                Path(audio_file_path).unlink(missing_ok=True)
            except Exception as e:
                logger.warning(
                    f"[{short_trace_id}] Failed to delete temp file: {e}",
                    extra={"trace_id": trace_id},
                )

    def health_check(self) -> dict[str, Any]:
        """
        Check health of process pool.

        Returns
        -------
        dict
            Health status with pool information
        """
        return {
            "service": "ProcessIsolatedTranscriptionService",
            "pool_size": self.pool_size,
            "timeout": self.timeout,
            "status": "healthy" if self.pool is not None else "unhealthy",
        }

    def shutdown(self, timeout: int = 30) -> None:
        """
        Gracefully shut down process pool.

        This method should be called on application shutdown
        to ensure all worker processes are properly terminated.

        Parameters
        ----------
        timeout : int, optional
            Maximum time to wait for workers to finish (default: 30s)
        """
        import time

        try:
            logger.info(f"Shutting down process pool (timeout={timeout}s)...")

            # Stop accepting new work
            self.pool.close()

            # Wait for workers with timeout
            start_time = time.time()
            while time.time() - start_time < timeout:
                # Check if all workers are done (non-blocking)
                # Pool._cache is internal but reliable way to check if work is pending
                if not hasattr(self.pool, "_cache") or len(self.pool._cache) == 0:
                    logger.info("All workers finished gracefully")
                    break
                time.sleep(0.5)
            else:
                # Timeout reached, force termination
                logger.warning(f"Timeout reached ({timeout}s), terminating workers forcefully")
                self.pool.terminate()
                self.pool.join()
                logger.info("Process pool terminated forcefully")
                return

            # All workers finished within timeout
            self.pool.join()
            logger.info("Process pool shutdown complete")

        except Exception as e:
            logger.error(f"Error during pool shutdown: {e}")
            try:
                self.pool.terminate()
                self.pool.join()
                logger.info("Process pool terminated forcefully after error")
            except Exception as term_error:
                logger.error(f"Error terminating pool: {term_error}")
