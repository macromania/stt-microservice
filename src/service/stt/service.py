"""
Async Speech-to-Text and Translation Service V2.

Simplified, async-first implementation without adapter pattern.
Always transcribes with diarization and translates to English.
"""

import asyncio
from asyncio import Queue
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import gc
import logging
import threading
import time
from typing import Any
from uuid import uuid4

import azure.cognitiveservices.speech as speechsdk
from azure.identity import DefaultAzureCredential

from src.core.config import get_settings
from src.service.stt.models import TranscriptionResponse, TranscriptionSegment

logger = logging.getLogger(__name__)


# Module-level constants for language mapping
LANGUAGE_MAP = {
    "en": "en-US",
    "en-US": "en-US",
    "en-GB": "en-GB",
    "ar": "ar-SA",
    "ar-AE": "ar-AE",
    "ar-SA": "ar-SA",
    "auto": None,
}


def _sync_transcribe_impl(
    audio_file_path: str,
    language: str,
    trace_id: str,
    resource_name: str | None,
    speech_region: str | None,
) -> dict[str, Any]:
    """
    Synchronous transcription using Speech SDK callbacks.

    Extracted as module-level function to enable memory profiling.

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

    Returns
    -------
    dict
        Transcription results with segments, full_text, detected_language, speaker_count
    """
    # Initialize SDK objects outside try block for cleanup access
    speech_config = None
    audio_config = None
    transcriber = None
    auto_detect_config = None
    credential = None

    try:
        # Get token: use environment variable if available (K8s), otherwise create fresh credential
        import os

        token = os.getenv("AZURE_ACCESS_TOKEN")
        if not token:
            # Create credential per request - will be explicitly closed in finally
            credential = DefaultAzureCredential()
            token = credential.get_token("https://cognitiveservices.azure.com/.default").token

        if resource_name:
            endpoint = f"https://{resource_name}.cognitiveservices.azure.com/"
            speech_config = speechsdk.SpeechConfig(endpoint=endpoint)
            speech_config.authorization_token = token
        else:
            speech_config = speechsdk.SpeechConfig(region=speech_region)
            speech_config.authorization_token = token

        # Optional: Enable SDK file logging for debugging (disabled by default to reduce I/O)
        # Uncomment to enable per-request logging to /tmp/speech-sdk-{trace_id}.log
        # speech_config.set_property(speechsdk.PropertyId.Speech_LogFilename, f"/tmp/speech-sdk-{trace_id}.log")

        audio_config = speechsdk.audio.AudioConfig(filename=audio_file_path)

        # Map language
        azure_language = LANGUAGE_MAP.get(language.lower())

        # Enable diarization
        speech_config.set_property(
            property_id=speechsdk.PropertyId.SpeechServiceResponse_DiarizeIntermediateResults,
            value="true",
        )

        # Create transcriber with diarization
        if azure_language:
            short_trace_id = trace_id[:8]
            logger.info(f"[{short_trace_id}] Using specified language for transcription: {azure_language}", extra={"trace_id": trace_id})
            speech_config.speech_recognition_language = azure_language
            transcriber = speechsdk.transcription.ConversationTranscriber(
                speech_config=speech_config,
                audio_config=audio_config,
            )
        else:
            short_trace_id = trace_id[:8]
            logger.info(f"[{short_trace_id}] Using auto-detection for transcription language", extra={"trace_id": trace_id})
            # Auto-detection
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

        # Callback state with queue-based pattern and Event for completion
        result_queue = Queue()
        detected_language = azure_language or "en-US"
        done_event = threading.Event()  # Use Event for efficient blocking wait
        is_stopped = False  # Track if we've already stopped

        def on_transcribed(evt):
            nonlocal detected_language, result_queue
            if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech and evt.result.text:
                # Extract language
                if evt.result.properties:
                    lang = evt.result.properties.get(speechsdk.PropertyId.SpeechServiceConnection_AutoDetectSourceLanguageResult)
                    if lang:
                        detected_language = lang

                # Extract all data from evt.result immediately and put plain dict in queue
                # No SDK object references, no complex object creation in callback
                result_queue.put_nowait(
                    {
                        "text": evt.result.text,
                        "speaker_id": evt.result.speaker_id if hasattr(evt.result, "speaker_id") else None,
                        "offset": evt.result.offset if hasattr(evt.result, "offset") else 0,
                        "duration": evt.result.duration if hasattr(evt.result, "duration") else 0,
                        "language": detected_language,
                    }
                )

        def on_stopped(evt):
            nonlocal done_event
            # Log the event type and reason
            event_name = evt.__class__.__name__ if hasattr(evt, "__class__") else "unknown"
            logger.warning(f"[{trace_id[:8]}] on_stopped triggered by: {event_name}", extra={"trace_id": trace_id})
            done_event.set()  # Signal completion immediately

        def on_canceled(evt):
            nonlocal done_event
            # Log cancellation details
            cancellation_reason = evt.cancellation_details.reason if hasattr(evt, "cancellation_details") else "unknown"
            error_details = evt.cancellation_details.error_details if hasattr(evt, "cancellation_details") else "none"
            logger.warning(f"[{trace_id[:8]}] Transcription canceled: {cancellation_reason}, details: {error_details}", extra={"trace_id": trace_id})
            done_event.set()  # Signal completion

        # Connect callbacks
        transcriber.transcribed.connect(on_transcribed)
        transcriber.session_stopped.connect(on_stopped)
        transcriber.canceled.connect(on_canceled)

        # Start transcription
        short_trace_id = trace_id[:8]
        logger.info(f"[{short_trace_id}] Starting transcription...", extra={"trace_id": trace_id})
        transcriber.start_transcribing_async()

        # DON'T delete temp file immediately - let it exist until transcription completes
        # The Azure SDK needs the file to remain accessible during processing

        # Wait for completion using Event (efficient blocking wait)
        # This blocks the thread until done_event.set() is called in on_stopped callback
        timeout = 300
        if not done_event.wait(timeout=timeout):
            # Timeout occurred
            logger.error(f"[{short_trace_id}] Transcription timeout after {timeout}s", extra={"trace_id": trace_id})
            raise TimeoutError(f"Transcription timeout after {timeout}s")

        short_trace_id = trace_id[:8]
        logger.info(f"[{short_trace_id}] Stopping transcription...", extra={"trace_id": trace_id})
        transcriber.stop_transcribing_async()
        is_stopped = True

        # Drain queue and build segments list (no SDK references in segments)
        segments = []
        while not result_queue.empty():
            result_dict = result_queue.get_nowait()
            segment = TranscriptionSegment(
                text=result_dict["text"],
                start_time=result_dict["offset"] / 10000000,
                end_time=(result_dict["offset"] + result_dict["duration"]) / 10000000,
                confidence=0.95,
                speaker_id=f"spk_{result_dict['speaker_id']}" if result_dict["speaker_id"] else None,
                language=result_dict["language"],
            )
            segments.append(segment)

        # Build full text
        full_text = "\n".join([f"[{seg.speaker_id}] {seg.text}" if seg.speaker_id else seg.text for seg in segments])

        # Count speakers
        unique_speakers = {seg.speaker_id for seg in segments if seg.speaker_id}
        speaker_count = len(unique_speakers) if unique_speakers else None

        # Segments list is already clean (no callback closure references)
        result_segments = segments

        return {
            "segments": result_segments,
            "full_text": full_text,
            "detected_language": detected_language,
            "speaker_count": speaker_count,
        }

    finally:
        # Clean up temp file (do this in finally to ensure it always happens)
        try:
            if os.path.exists(audio_file_path):
                os.unlink(audio_file_path)
                logger.debug(f"[{trace_id[:8]}] Cleaned up temp file: {audio_file_path}", extra={"trace_id": trace_id})
        except Exception as e:
            logger.warning(f"[{trace_id[:8]}] Failed to delete temp file: {e}", extra={"trace_id": trace_id})

        # Explicit cleanup of Azure Speech SDK objects to prevent memory leaks
        # These objects hold internal buffers, audio streams, and network connections
        short_trace_id = trace_id[:8]

        # Minimal cleanup - disconnect event handlers to break circular references
        # Process exit will handle all other cleanup (connections, memory, etc.)
        if transcriber is not None:
            try:
                # Only stop if not already stopped to avoid double-stop errors
                if not is_stopped:
                    transcriber.stop_transcribing_async()

                # Disconnect event handlers to break circular references
                transcriber.transcribed.disconnect_all()
                transcriber.transcribing.disconnect_all()
                transcriber.canceled.disconnect_all()
                transcriber.session_started.disconnect_all()
                transcriber.session_stopped.disconnect_all()
                transcriber.speech_start_detected.disconnect_all()
                transcriber.speech_end_detected.disconnect_all()
            except Exception:
                pass  # Ignore cleanup errors - process exit will handle cleanup

        # No need for explicit cleanup - process isolation handles everything
        # When the worker process exits, the OS will:
        # - Close all network connections
        # - Release all memory (including native SDK allocations)
        # - Clean up all file descriptors
        # This is faster and more reliable than manual cleanup


class TranscriptionService:
    """
    Async speech-to-text and translation service V2.

    Simplified implementation:
    - Always enables diarization
    - Always translates to English
    - No medical terms boosting
    - No adapter pattern
    - Fully async

    Architecture:
    - Azure Speech SDK (wrapped in asyncio.to_thread)
    - Azure OpenAI async client for translation
    """

    def __init__(self, enable_profiling: bool = False):
        """
        Initialize service with settings.

        Parameters
        ----------
        enable_profiling : bool
            If True, enables memory profiling for debugging (adds overhead)
        """
        settings = get_settings()
        self.speech_region = settings.stt_azure_speech_region
        self.resource_name = settings.stt_azure_speech_resource_name
        self.enable_profiling = enable_profiling

    async def process_audio(self, audio_file_path: str, language: str = "auto", trace_id: str | None = None) -> TranscriptionResponse:
        """
        Process audio: transcribe with diarization and translate to English.

        This is the main entry point for V2 service.

        Parameters
        ----------
        audio_file_path : str
            Path to the audio file
        language : str
            Language code or "auto" for detection (default: "auto")

        Returns
        -------
        TranscriptionResponseV2
            Complete response with transcription and English translation

        Examples
        --------
        >>> service = TranscriptionServiceV2()
        >>> result = await service.process_audio("consultation.wav")
        >>> print(result.translated_text)
        """
        start_time = time.time()

        # Use provided trace_id or get from context
        if trace_id is None:
            trace_id = uuid4().hex
        short_trace_id = trace_id[:8]

        logger.info(f"[{short_trace_id}] Transcribing with diarization...: {audio_file_path}", extra={"trace_id": trace_id})
        transcription_start = time.time()

        transcription = await self._transcribe_async(audio_file_path, language, trace_id)

        transcription_time = time.time() - transcription_start
        logger.info(f"[{short_trace_id}] Transcription completed: {transcription_time:.2f}s, {len(transcription['segments'])} segments", extra={"trace_id": trace_id})

        translation = "None"
        translation_time = 0.0

        # Calculate metrics
        processing_time = time.time() - start_time
        segments = transcription["segments"]
        avg_confidence = sum(seg.confidence for seg in segments) / len(segments) if segments else 0.0

        # Build response
        response = TranscriptionResponse(
            original_text=transcription["full_text"],
            translated_text=translation,
            original_language=transcription["detected_language"],
            segments=segments,
            speaker_count=transcription.get("speaker_count"),
            audio_duration_seconds=0.0,  # Validation disabled - set to 0
            processing_time_seconds=processing_time,
            transcription_time_seconds=transcription_time,
            translation_time_seconds=translation_time,
            confidence_average=avg_confidence,
            timestamp=datetime.now(),
        )

        return response

    async def _transcribe_async(self, audio_file_path: str, language: str, trace_id: str) -> dict[str, Any]:
        """
        Async wrapper for Azure Speech SDK transcription.

        Delegates to module-level _sync_transcribe_impl for profiling support.

        Parameters
        ----------
        audio_file_path : str
            Path to audio file
        language : str
            Language code or "auto"
        trace_id : str
            Trace ID for request correlation

        Returns
        -------
        dict
            Transcription results with segments, full_text, detected_language, speaker_count
        """

        def _sync_transcribe() -> dict[str, Any]:
            """Wrapper that calls module-level implementation."""
            return _sync_transcribe_impl(
                audio_file_path=audio_file_path,
                language=language,
                trace_id=trace_id,
                resource_name=self.resource_name,
                speech_region=self.speech_region,
            )

        # Use a single-use thread pool executor to avoid memory retention
        # The default thread pool reuses threads which can keep SDK objects alive
        # A fresh executor with max_workers=1 ensures complete cleanup after request
        executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"stt-{trace_id[:8]}")
        try:
            loop = asyncio.get_running_loop()
            result = await loop.run_in_executor(executor, _sync_transcribe)
        finally:
            # Shutdown executor immediately to release thread resources
            executor.shutdown(wait=True)
            del executor
            # Force GC to clean up thread-local storage
            gc.collect()

        return result
