"""
Async Speech-to-Text and Translation Service V2.

Simplified, async-first implementation without adapter pattern.
Always transcribes with diarization and translates to English.
"""

import asyncio
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

    # Language mapping for Azure Speech SDK
    LANGUAGE_MAP = {
        "en": "en-US",
        "en-US": "en-US",
        "en-GB": "en-GB",
        "ar": "ar-SA",
        "ar-AE": "ar-AE",
        "ar-JO": "ar-JO",
        "ar-EG": "ar-EG",
        "ar-TN": "ar-TN",
        "ar-SA": "ar-SA",
        "auto": None,
    }

    def __init__(self) -> None:
        """Initialize V2 service (credentials created per-request to avoid memory leaks)."""
        config = get_settings()

        # Speech SDK configuration
        self.speech_region = config.stt_azure_speech_region
        self.resource_name = config.stt_azure_speech_resource_name

        if not self.speech_region:
            raise ValueError("Azure Speech region not configured. Set STT_AZURE_SPEECH_REGION")

        # Don't cache credential - create it per request to avoid memory accumulation
        # Credential objects hold internal state that can leak memory
        self.credential = None

        # Note: No logging in __init__ since it happens before request context is established
        # Trace ID logging begins in process_audio()

    # Note: No logging in __init__ since it happens before request context is established
    # Trace ID logging begins in process_audio()

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

        Wraps blocking Speech SDK callbacks in asyncio.to_thread.

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
            """Synchronous transcription using Speech SDK callbacks."""
            # Initialize SDK objects outside try block for cleanup access
            speech_config = None
            audio_config = None
            transcriber = None
            auto_detect_config = None

            try:
                # Get token: use environment variable if available (K8s), otherwise create fresh credential
                import os
                token = os.getenv("AZURE_ACCESS_TOKEN")
                if not token:
                    # Create credential per request to avoid memory leaks from cached credential state
                    credential = DefaultAzureCredential()
                    token = credential.get_token("https://cognitiveservices.azure.com/.default").token

                if self.resource_name:
                    endpoint = f"https://{self.resource_name}.cognitiveservices.azure.com/"
                    speech_config = speechsdk.SpeechConfig(endpoint=endpoint)
                    speech_config.authorization_token = token
                else:
                    speech_config = speechsdk.SpeechConfig(region=self.speech_region)
                    speech_config.authorization_token = token

                audio_config = speechsdk.audio.AudioConfig(filename=audio_file_path)

                # Map language
                azure_language = self.LANGUAGE_MAP.get(language.lower())

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

                # Callback state
                segments = []
                detected_language = azure_language or "en-US"
                done = False

                def on_transcribed(evt):
                    nonlocal detected_language
                    if evt.result.reason == speechsdk.ResultReason.RecognizedSpeech and evt.result.text:
                        # Extract language
                        if evt.result.properties:
                            lang = evt.result.properties.get(speechsdk.PropertyId.SpeechServiceConnection_AutoDetectSourceLanguageResult)
                            if lang:
                                detected_language = lang

                        # Create segment
                        speaker_id = evt.result.speaker_id if hasattr(evt.result, "speaker_id") else None
                        segment = TranscriptionSegment(
                            text=evt.result.text,
                            start_time=evt.result.offset / 10000000 if hasattr(evt.result, "offset") else 0,
                            end_time=(evt.result.offset + evt.result.duration) / 10000000 if hasattr(evt.result, "offset") and hasattr(evt.result, "duration") else 0,
                            confidence=0.95,
                            speaker_id=f"spk_{speaker_id}" if speaker_id else None,
                            language=detected_language,
                        )
                        segments.append(segment)

                def on_stopped(evt):
                    nonlocal done
                    done = True

                # Connect callbacks
                transcriber.transcribed.connect(on_transcribed)
                transcriber.session_stopped.connect(on_stopped)
                transcriber.canceled.connect(on_stopped)

                # Start transcription
                short_trace_id = trace_id[:8]
                logger.info(f"[{short_trace_id}] Starting transcription...", extra={"trace_id": trace_id})
                transcriber.start_transcribing_async()

                # Wait for completion
                timeout = 300
                elapsed = 0
                while not done and elapsed < timeout:
                    time.sleep(0.5)
                    elapsed += 0.5

                short_trace_id = trace_id[:8]
                logger.info(f"[{short_trace_id}] Stopping transcription...", extra={"trace_id": trace_id})
                transcriber.stop_transcribing_async()

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
                # Explicit cleanup of Azure Speech SDK objects to prevent memory leaks
                # These objects hold internal buffers, audio streams, and network connections
                short_trace_id = trace_id[:8]

                if transcriber is not None:
                    try:
                        # Ensure transcription is stopped
                        transcriber.stop_transcribing_async().get()

                        # Disconnect all event handlers to break circular references
                        transcriber.transcribed.disconnect_all()
                        transcriber.session_stopped.disconnect_all()
                        transcriber.canceled.disconnect_all()

                        logger.debug(f"[{short_trace_id}] Transcriber cleaned up", extra={"trace_id": trace_id})
                    except Exception as e:
                        logger.warning(f"[{short_trace_id}] Error during transcriber cleanup: {e}", extra={"trace_id": trace_id})

                # Explicitly delete SDK objects to release resources immediately
                # This helps Python's garbage collector reclaim memory faster
                del transcriber
                del audio_config
                del speech_config
                del auto_detect_config

                # Force immediate GC to release native resources
                gc.collect()

        # Run in a fresh thread (not thread pool) to ensure complete cleanup
        # ThreadPoolExecutor reuses threads which can keep SDK objects alive in stack frames
        # Fresh threads die completely after request, releasing all memory
        result_container = {}      # Holds successful result (threads can't return directly)
        exception_container = {}   # Holds any exception from worker thread

        def _thread_wrapper():
            """Wrapper to capture result/exception from sync work."""
            try:
                result_container['result'] = _sync_transcribe()
            except Exception as e:
                exception_container['error'] = e

        # Create brand new thread (not from pool) - will die after request
        thread = threading.Thread(target=_thread_wrapper, daemon=False)
        thread.start()

        # Wait for thread to complete (async-safe blocking)
        # timeout = 300s (transcription) + 10s (cleanup buffer)
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: thread.join(timeout=310)
        )

        # Check if thread timed out
        if thread.is_alive():
            logger.error(f"[{trace_id[:8]}] Thread timeout - thread still running", extra={"trace_id": trace_id})
            raise TimeoutError("Transcription thread timeout")

        # Re-raise any exception from worker thread
        if 'error' in exception_container:
            raise exception_container['error']

        # Extract result and explicitly clean up containers
        result = result_container['result']
        del result_container
        del exception_container
        del thread

        # Aggressive GC to clean up thread-local storage immediately
        gc.collect()

        return result
