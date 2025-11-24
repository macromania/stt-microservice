"""Speech-to-Text V2 API router with async implementation."""

import asyncio
from functools import lru_cache
import logging
from pathlib import Path
import tempfile
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from prometheus_client import Counter, Histogram, Gauge

from src.core.config import get_settings
from src.core.exception import AudioFileSizeError, AudioFormatError
from src.core.trace import get_trace_id
from src.service.stt.models import TranscriptionResponse
from src.service.stt.service import TranscriptionService

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/transcriptions",
    tags=["transcriptions"],
)

settings = get_settings()

# Allowed file extensions
ALLOWED_EXTENSIONS = {".wav", ".mp3", ".m4a", ".flac", ".aac", ".ogg", ".webm", ".mp4"}

# Maximum file size: 100MB
MAX_FILE_SIZE = settings.stt_max_file_size_mb * 1024 * 1024

# Custom STT Prometheus Metrics
stt_transcriptions_total = Counter(
    'stt_transcriptions_total',
    'Total number of transcription requests',
    ['status', 'language']
)

stt_audio_duration_seconds = Histogram(
    'stt_audio_duration_seconds',
    'Duration of audio files processed in seconds',
    buckets=[5, 10, 30, 60, 120, 300, 600, 1800]  # 5s to 30min
)

stt_transcription_confidence = Gauge(
    'stt_transcription_confidence',
    'Average confidence score of transcriptions',
    ['language']
)

stt_transcription_time = Histogram(
    'stt_transcription_time_seconds',
    'Time spent on transcription in seconds',
    buckets=[1, 2, 5, 10, 20, 30, 60]
)

stt_translation_time = Histogram(
    'stt_translation_time_seconds',
    'Time spent on translation in seconds',
    buckets=[1, 2, 5, 10, 20, 30, 60]
)


@lru_cache
def get_speech_service() -> TranscriptionService:
    """
    Get cached TranscriptionServiceV2 instance (singleton).

    Uses lru_cache to create and reuse a single service instance,
    avoiding repeated Azure SDK initialization overhead (~4 seconds).

    Returns
    -------
    TranscriptionServiceV2
        Cached service instance
    """
    return TranscriptionService()


def validate_upload_file(audio_file: UploadFile) -> None:
    """
    Validate uploaded file metadata.

    Parameters
    ----------
    audio_file : UploadFile
        The uploaded audio file

    Raises
    ------
    HTTPException
        400: If file validation fails
    """
    if not audio_file or not audio_file.filename:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No audio file provided",
        )

    file_ext = Path(audio_file.filename).suffix.lower()
    if file_ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid file format. Allowed: {', '.join(ALLOWED_EXTENSIONS)}",
        )

    if audio_file.content_type and not audio_file.content_type.startswith(("audio/", "video/")):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid content type: {audio_file.content_type}",
        )


@router.post("", response_model=TranscriptionResponse)
async def create_transcription(
    audio_file: Annotated[UploadFile, File(description="Audio file (max 100MB)")],
    service: Annotated[TranscriptionService, Depends(get_speech_service)],
    language: Annotated[str, Form(description="Language code or 'auto'")] = "auto",
) -> TranscriptionResponse:
    """
    Create transcription with automatic English translation (Async).

    Supports: WAV, MP3, M4A, FLAC, AAC, OGG, WEBM, MP4 (max 100MB)

    Parameters
    ----------
    audio_file : UploadFile
        Audio file to process
    language : str
        Language code (e.g., "ar-AE", "en-US") or "auto" for detection
    service : TranscriptionServiceV2
        Injected service instance

    Returns
    -------
    TranscriptionResponseV2
        Transcription with segments, English translation, and metadata

    Raises
    ------
    HTTPException
        400: Invalid file
        413: File too large
        422: Invalid audio content
        500: Processing failed
    """
    temp_file_path = None

    try:
        # Validate upload metadata
        validate_upload_file(audio_file)

        # Stream file to disk with size limit (avoids loading full file into memory)
        file_ext = Path(audio_file.filename).suffix.lower()
        bytes_written = 0
        chunk_size = 8192  # 8KB chunks

        # Use NamedTemporaryFile with mode='wb' for explicit binary write control
        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=file_ext, mode="wb")
        try:
            while chunk := await audio_file.read(chunk_size):
                bytes_written += len(chunk)
                if bytes_written > MAX_FILE_SIZE:
                    # Cleanup partial file before raising
                    await asyncio.to_thread(temp_file.close)
                    Path(temp_file.name).unlink(missing_ok=True)
                    raise HTTPException(
                        status_code=status.HTTP_400_BAD_REQUEST,
                        detail=f"File too large. Maximum: {MAX_FILE_SIZE / 1024 / 1024:.0f}MB",
                    )
                # Offload blocking write to thread pool to avoid blocking event loop
                await asyncio.to_thread(temp_file.write, chunk)

            # Ensure all data is flushed to disk before closing (non-blocking)
            await asyncio.to_thread(temp_file.flush)
            temp_file_path = temp_file.name
        finally:
            await asyncio.to_thread(temp_file.close)

        # Get trace ID once for entire request
        trace_id = get_trace_id()
        short_trace_id = trace_id[:8]

        # Sanitize filename for logging
        sanitized_filename = audio_file.filename.replace("\n", "").replace("\r", "").replace("\t", "")
        logger.info(f"[{short_trace_id}] Processing: {sanitized_filename} ({bytes_written / 1024 / 1024:.2f}MB)", extra={"trace_id": trace_id})

        result = await service.process_audio(
            audio_file_path=temp_file_path,
            language=language,
            trace_id=trace_id,
        )

        # Record metrics
        stt_transcriptions_total.labels(status='success', language=result.original_language).inc()
        stt_audio_duration_seconds.observe(result.audio_duration_seconds)
        stt_transcription_confidence.labels(language=result.original_language).set(result.confidence_average)
        stt_transcription_time.observe(result.transcription_time_seconds)
        stt_translation_time.observe(result.translation_time_seconds)

        logger.info(f"[{short_trace_id}] V2 complete: {len(result.segments)} segments, {result.original_language} → en", extra={"trace_id": trace_id})
        return result

    except HTTPException:
        raise
    except AudioFileSizeError as e:
        trace_id = get_trace_id()
        short_trace_id = trace_id[:8]
        logger.error(f"[{short_trace_id}] Audio size error: {e}", extra={"trace_id": trace_id})
        stt_transcriptions_total.labels(status='error_size', language='unknown').inc()
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=str(e),
        ) from e
    except AudioFormatError as e:
        trace_id = get_trace_id()
        short_trace_id = trace_id[:8]
        logger.error(f"[{short_trace_id}] Audio format error: {e}", extra={"trace_id": trace_id})
        stt_transcriptions_total.labels(status='error_format', language='unknown').inc()
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e),
        ) from e
    except ValueError as e:
        trace_id = get_trace_id()
        short_trace_id = trace_id[:8]
        logger.error(f"[{short_trace_id}] Validation error: {e}", extra={"trace_id": trace_id})
        stt_transcriptions_total.labels(status='error_validation', language='unknown').inc()
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=str(e),
        ) from e
    except Exception as e:
        trace_id = get_trace_id()
        short_trace_id = trace_id[:8]
        logger.error(f"[{short_trace_id}] V2 processing failed: {e}", exc_info=True, extra={"trace_id": trace_id})
        stt_transcriptions_total.labels(status='error_processing', language='unknown').inc()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Processing failed: {str(e)}",
        ) from e
    finally:
        # Cleanup temp file
        if temp_file_path and Path(temp_file_path).exists():
            try:
                Path(temp_file_path).unlink()
            except Exception as e:
                trace_id = get_trace_id()
                short_trace_id = trace_id[:8]
                logger.warning(f"[{short_trace_id}] Failed to cleanup temp file: {e}", extra={"trace_id": trace_id})

        # Force garbage collection after heavy operation
        import gc
        gc.collect()
