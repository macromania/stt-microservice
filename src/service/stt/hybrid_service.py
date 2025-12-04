"""
Hybrid Speech-to-Text Service: Async I/O + Sync SDK Processing.

Architecture:
- Async file I/O operations (handled by FastAPI)
- Sync Azure Speech SDK calls (run in thread pool via asyncio.to_thread)
- Clean separation of concerns for better memory management

Benefits over pure async approach:
1. Thread-isolated SDK cleanup (predictable resource release)
2. Simpler code (no async/await mixed with blocking SDK calls)
3. Better memory behavior (thread stack cleanup on exit)
4. Clearer object lifetimes and reference counting
"""

from asyncio import Queue
from datetime import datetime
import gc
import logging
import os
import threading
import time
from typing import Any
from uuid import uuid4

import azure.cognitiveservices.speech as speechsdk
from azure.identity import DefaultAzureCredential

from src.core.config import get_settings
from src.service.stt.models import TranscriptionResponse, TranscriptionSegment

logger = logging.getLogger(__name__)

# Language mapping constants
LANGUAGE_MAP = {
    "en": "en-US",
    "en-US": "en-US",
    "en-GB": "en-GB",
    "ar": "ar-SA",
    "ar-AE": "ar-AE",
    "ar-SA": "ar-SA",
    "auto": None,
}


class HybridTranscriptionService:
    """
    Hybrid transcription service with sync SDK processing.

    This service is designed to be called with asyncio.to_thread() for
    optimal memory management and resource cleanup.
    """

    def __init__(self):
        """Initialize service with settings."""
        settings = get_settings()
        self.speech_region = settings.stt_azure_speech_region
        self.resource_name = settings.stt_azure_speech_resource_name

    def process_audio_sync(
        self,
        audio_file_path: str,
        language: str = "auto",
        trace_id: str | None = None,
    ) -> TranscriptionResponse:
        """
        Process audio synchronously (designed to run in thread pool).

        This is a PURE SYNC method - no async/await. It runs in a dedicated
        thread via asyncio.to_thread(), providing:
        - Thread-isolated cleanup
        - Predictable SDK resource release
        - Simpler error handling

        Parameters
        ----------
        audio_file_path : str
            Path to the audio file
        language : str
            Language code or "auto" for detection
        trace_id : str | None
            Trace ID for request correlation

        Returns
        -------
        TranscriptionResponse
            Complete transcription response

        Notes
        -----
        This method is blocking and should be called via asyncio.to_thread():
            result = await asyncio.to_thread(service.process_audio_sync, path, lang)
        """
        start_time = time.time()

        # Generate trace ID if not provided
        if trace_id is None:
            trace_id = uuid4().hex
        short_trace_id = trace_id[:8]

        logger.info(
            f"[{short_trace_id}] [Hybrid] Starting sync transcription: {audio_file_path}",
            extra={"trace_id": trace_id},
        )

        # Transcribe with diarization (blocking SDK calls)
        transcription_start = time.time()
        transcription = self._transcribe_sync(audio_file_path, language, trace_id)
        transcription_time = time.time() - transcription_start

        logger.info(
            f"[{short_trace_id}] [Hybrid] Transcription complete: {transcription_time:.2f}s, {len(transcription['segments'])} segments",
            extra={"trace_id": trace_id},
        )

        # Calculate metrics
        processing_time = time.time() - start_time
        segments = transcription["segments"]
        avg_confidence = sum(seg.confidence for seg in segments) / len(segments) if segments else 0.0

        # Build response
        response = TranscriptionResponse(
            original_text=transcription["full_text"],
            translated_text="None",  # Translation disabled for hybrid endpoint
            original_language=transcription["detected_language"],
            segments=segments,
            speaker_count=transcription.get("speaker_count"),
            audio_duration_seconds=0.0,  # Validation disabled
            processing_time_seconds=processing_time,
            transcription_time_seconds=transcription_time,
            translation_time_seconds=0.0,
            confidence_average=avg_confidence,
            timestamp=datetime.now(),
        )

        logger.info(
            f"[{short_trace_id}] [Hybrid] Processing complete: {processing_time:.2f}s total",
            extra={"trace_id": trace_id},
        )

        return response

    def _transcribe_sync(
        self,
        audio_file_path: str,
        language: str,
        trace_id: str,
    ) -> dict[str, Any]:
        """
        Synchronous transcription using Azure Speech SDK.

        All SDK operations are blocking - no async/await.
        Runs in thread pool with explicit cleanup.

        Parameters
        ----------
        audio_file_path : str
            Path to audio file
        language : str
            Language code or "auto"
        trace_id : str
            Trace ID for logging

        Returns
        -------
        dict
            Transcription results with segments, full_text, detected_language, speaker_count
        """
        # Initialize SDK objects for cleanup tracking
        speech_config = None
        audio_config = None
        transcriber = None
        auto_detect_config = None
        credential = None
        is_stopped = False

        try:
            # Get authentication token
            token = os.getenv("AZURE_ACCESS_TOKEN")
            if not token:
                credential = DefaultAzureCredential()
                token = credential.get_token("https://cognitiveservices.azure.com/.default").token

            # Configure Speech SDK
            if self.resource_name:
                endpoint = f"https://{self.resource_name}.cognitiveservices.azure.com/"
                speech_config = speechsdk.SpeechConfig(endpoint=endpoint)
                speech_config.authorization_token = token
            else:
                speech_config = speechsdk.SpeechConfig(region=self.speech_region)
                speech_config.authorization_token = token

            audio_config = speechsdk.audio.AudioConfig(filename=audio_file_path)

            # Map language
            azure_language = LANGUAGE_MAP.get(language.lower())

            # Enable diarization
            speech_config.set_property(
                property_id=speechsdk.PropertyId.SpeechServiceResponse_DiarizeIntermediateResults,
                value="true",
            )

            # Create transcriber
            if azure_language:
                logger.info(
                    f"[{trace_id[:8]}] [Hybrid] Using language: {azure_language}",
                    extra={"trace_id": trace_id},
                )
                speech_config.speech_recognition_language = azure_language
                transcriber = speechsdk.transcription.ConversationTranscriber(
                    speech_config=speech_config,
                    audio_config=audio_config,
                )
            else:
                logger.info(
                    f"[{trace_id[:8]}] [Hybrid] Using auto-detection",
                    extra={"trace_id": trace_id},
                )
                speech_config.set_property(
                    property_id=speechsdk.PropertyId.SpeechServiceConnection_LanguageIdMode,
                    value="Continuous",
                )
                auto_detect_config = speechsdk.languageconfig.AutoDetectSourceLanguageConfig(languages=["ar-AE", "ar-SA", "en-US", "en-GB"])
                transcriber = speechsdk.transcription.ConversationTranscriber(
                    speech_config=speech_config,
                    auto_detect_source_language_config=auto_detect_config,
                    audio_config=audio_config,
                )

            # Setup callbacks with queue-based pattern
            result_queue = Queue()
            detected_language = azure_language or "en-US"
            done_event = threading.Event()

            def on_transcribed(evt):
                """Extract data immediately, no SDK references kept."""
                nonlocal detected_language
                if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech and evt.result.text:
                    # Extract language
                    if evt.result.properties:
                        lang = evt.result.properties.get(speechsdk.PropertyId.SpeechServiceConnection_AutoDetectSourceLanguageResult)
                        if lang:
                            detected_language = lang

                    # Extract all data immediately (no SDK references)
                    result_queue.put_nowait(
                        {
                            "text": evt.result.text,
                            "speaker_id": (evt.result.speaker_id if hasattr(evt.result, "speaker_id") else None),
                            "offset": (evt.result.offset if hasattr(evt.result, "offset") else 0),
                            "duration": (evt.result.duration if hasattr(evt.result, "duration") else 0),
                            "language": detected_language,
                        }
                    )

            def on_stopped(evt):
                """Signal completion."""
                logger.debug(
                    f"[{trace_id[:8]}] [Hybrid] Session stopped",
                    extra={"trace_id": trace_id},
                )
                done_event.set()

            def on_canceled(evt):
                """Handle cancellation."""
                reason = evt.cancellation_details.reason if hasattr(evt, "cancellation_details") else "unknown"
                reason_str = str(reason)

                # EndOfStream is normal completion, not an error
                if "EndOfStream" in reason_str:
                    logger.debug(
                        f"[{trace_id[:8]}] [Hybrid] Transcription completed (EndOfStream)",
                        extra={"trace_id": trace_id},
                    )
                else:
                    logger.warning(
                        f"[{trace_id[:8]}] [Hybrid] Transcription canceled: {reason}",
                        extra={"trace_id": trace_id},
                    )
                done_event.set()

            # Connect callbacks
            transcriber.transcribed.connect(on_transcribed)
            transcriber.session_stopped.connect(on_stopped)
            transcriber.canceled.connect(on_canceled)

            # Start transcription (blocking)
            transcriber.start_transcribing_async()

            # Wait for completion (blocking wait in thread)
            timeout = 300
            if not done_event.wait(timeout=timeout):
                logger.error(
                    f"[{trace_id[:8]}] [Hybrid] Transcription timeout",
                    extra={"trace_id": trace_id},
                )
                raise TimeoutError(f"Transcription timeout after {timeout}s")

            # Stop transcription
            transcriber.stop_transcribing_async()
            is_stopped = True

            # Build segments from queue (no SDK references)
            segments = []
            while not result_queue.empty():
                result_dict = result_queue.get_nowait()
                segment = TranscriptionSegment(
                    text=result_dict["text"],
                    start_time=result_dict["offset"] / 10000000,
                    end_time=(result_dict["offset"] + result_dict["duration"]) / 10000000,
                    confidence=0.95,
                    speaker_id=(f"spk_{result_dict['speaker_id']}" if result_dict["speaker_id"] else None),
                    language=result_dict["language"],
                )
                segments.append(segment)

            # Build full text
            full_text = "\n".join([f"[{seg.speaker_id}] {seg.text}" if seg.speaker_id else seg.text for seg in segments])

            # Count speakers
            unique_speakers = {seg.speaker_id for seg in segments if seg.speaker_id}
            speaker_count = len(unique_speakers) if unique_speakers else None

            return {
                "segments": segments,
                "full_text": full_text,
                "detected_language": detected_language,
                "speaker_count": speaker_count,
            }

        finally:
            # CRITICAL: Explicit cleanup to release C++ resources
            # This runs in thread context, ensuring proper cleanup

            # Cleanup temp file
            try:
                if os.path.exists(audio_file_path):
                    os.unlink(audio_file_path)
                    logger.debug(
                        f"[{trace_id[:8]}] [Hybrid] Cleaned up temp file",
                        extra={"trace_id": trace_id},
                    )
            except Exception as e:
                logger.warning(
                    f"[{trace_id[:8]}] [Hybrid] Failed to delete temp file: {e}",
                    extra={"trace_id": trace_id},
                )

            # Disconnect event handlers to break circular references
            if transcriber is not None:
                try:
                    if not is_stopped:
                        transcriber.stop_transcribing_async()

                    # Disconnect all event handlers (breaks circular refs)
                    transcriber.transcribed.disconnect_all()
                    transcriber.transcribing.disconnect_all()
                    transcriber.canceled.disconnect_all()
                    transcriber.session_started.disconnect_all()
                    transcriber.session_stopped.disconnect_all()
                    transcriber.speech_start_detected.disconnect_all()
                    transcriber.speech_end_detected.disconnect_all()
                except Exception as e:
                    logger.warning(
                        f"[{trace_id[:8]}] [Hybrid] Error during transcriber cleanup: {e}",
                        extra={"trace_id": trace_id},
                    )

            # Close credential to release HTTP client
            if credential is not None:
                try:
                    credential.close()
                except Exception as e:
                    logger.warning(
                        f"[{trace_id[:8]}] [Hybrid] Error closing credential: {e}",
                        extra={"trace_id": trace_id},
                    )

            # Explicitly delete SDK objects
            del transcriber
            del audio_config
            del speech_config
            del auto_detect_config
            del credential

            # Force garbage collection in this thread
            gc.collect()

            logger.debug(
                f"[{trace_id[:8]}] [Hybrid] Cleanup complete",
                extra={"trace_id": trace_id},
            )
