"""
Fast Transcription Service using Azure Speech REST API.

This service uses the Fast Transcription API endpoint instead of the Speech SDK,
providing a simpler implementation with no memory management overhead.
"""

from datetime import datetime
import json
import logging
from pathlib import Path
import time
from typing import Any
from uuid import uuid4

from azure.identity import DefaultAzureCredential
import httpx

from src.core.config import get_settings
from src.service.stt.models import TranscriptionResponse, TranscriptionSegment

logger = logging.getLogger(__name__)


class FastTranscriptionService:
    """
    Fast Transcription service using Azure Speech REST API.

    Uses the Fast Transcription API (faster than real-time) instead of SDK.
    Simpler architecture with no callbacks, threading, or manual memory management.

    Features:
    - Always enables diarization
    - Supports language auto-detection
    - Returns actual confidence scores
    - Provides real audio duration
    - Native async with httpx
    """

    # Language mapping for Azure Speech API
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

    # API version for Fast Transcription
    API_VERSION = "2025-10-15"

    def __init__(self) -> None:
        """Initialize Fast Transcription service."""
        config = get_settings()

        self.speech_region = config.stt_azure_speech_region
        self.resource_name = config.stt_azure_speech_resource_name

        if not self.speech_region:
            raise ValueError("Azure Speech region not configured. Set STT_AZURE_SPEECH_REGION")

        # Construct API endpoint - use resource name (custom subdomain) for token auth
        # This matches the SDK pattern: use custom subdomain when available
        if self.resource_name:
            # Token auth requires custom subdomain
            self.endpoint = f"https://{self.resource_name}.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe"
        else:
            # Fall back to regional endpoint (requires API key auth)
            self.endpoint = f"https://{self.speech_region}.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe"

    async def process_audio(self, audio_file_path: str, language: str = "auto", trace_id: str | None = None) -> TranscriptionResponse:
        """
        Process audio using Fast Transcription API.

        Parameters
        ----------
        audio_file_path : str
            Path to the audio file
        language : str
            Language code or "auto" for detection (default: "auto")
        trace_id : str | None
            Trace ID for request correlation

        Returns
        -------
        TranscriptionResponse
            Complete response with transcription and metadata
        """
        start_time = time.time()

        # Use provided trace_id or generate new one
        if trace_id is None:
            trace_id = uuid4().hex
        short_trace_id = trace_id[:8]

        logger.info(f"[{short_trace_id}] Fast transcription started: {audio_file_path}", extra={"trace_id": trace_id})

        # Get access token
        token = await self._get_access_token(trace_id)

        # Make API request
        transcription_start = time.time()
        response_data = await self._call_transcription_api(audio_file_path, language, token, trace_id)
        transcription_time = time.time() - transcription_start

        logger.info(
            f"[{short_trace_id}] Fast transcription completed: {transcription_time:.2f}s, {len(response_data.get('phrases', []))} phrases",
            extra={"trace_id": trace_id},
        )

        # Map response to our model
        result = self._map_response_to_model(response_data, transcription_time, start_time, trace_id)

        return result

    async def _get_access_token(self, trace_id: str) -> str:
        """
        Get Azure access token for Cognitive Services.

        Checks AZURE_ACCESS_TOKEN environment variable first (K8s deployments),
        then falls back to DefaultAzureCredential.

        Parameters
        ----------
        trace_id : str
            Trace ID for logging

        Returns
        -------
        str
            Bearer token
        """
        import os

        short_trace_id = trace_id[:8]

        # Check for pre-configured token (K8s environment)
        token = os.getenv("AZURE_ACCESS_TOKEN")
        if token:
            logger.debug(f"[{short_trace_id}] Using AZURE_ACCESS_TOKEN from environment", extra={"trace_id": trace_id})
            return token

        # Fall back to DefaultAzureCredential
        try:
            credential = DefaultAzureCredential()
            token_result = credential.get_token("https://cognitiveservices.azure.com/.default")
            token = token_result.token
            credential.close()
            logger.debug(f"[{short_trace_id}] Access token obtained via DefaultAzureCredential", extra={"trace_id": trace_id})
            return token
        except Exception as e:
            logger.error(f"[{short_trace_id}] Failed to get access token: {e}", extra={"trace_id": trace_id})
            raise

    async def _call_transcription_api(self, audio_file_path: str, language: str, token: str, trace_id: str) -> dict[str, Any]:
        """
        Call Fast Transcription API.

        Parameters
        ----------
        audio_file_path : str
            Path to audio file
        language : str
            Language code or "auto"
        token : str
            Bearer token
        trace_id : str
            Trace ID for logging

        Returns
        -------
        dict
            API response JSON
        """
        short_trace_id = trace_id[:8]

        # Map language
        azure_language = self.LANGUAGE_MAP.get(language.lower())

        # Build request definition
        definition = {"diarization": {"maxSpeakers": 10, "enabled": True}}

        # Add locales based on language parameter
        if azure_language:
            # Known language specified - use it for better accuracy
            definition["locales"] = [azure_language]
            logger.debug(f"[{short_trace_id}] Using specified language: {azure_language}", extra={"trace_id": trace_id})
        else:
            # Auto-detection mode: provide candidate locales for language identification
            # Note: Multi-lingual mode (empty locales) doesn't support Arabic
            # So we use language identification with multiple candidates instead
            # Supports common languages including Arabic, English, and others
            definition["locales"] = ["ar-AE", "ar-SA", "en-US", "en-GB", "fr-FR", "de-DE"]
            logger.debug(f"[{short_trace_id}] Using language identification with candidate locales", extra={"trace_id": trace_id})

        # Prepare multipart form data
        url = f"{self.endpoint}?api-version={self.API_VERSION}"
        headers = {"Authorization": f"Bearer {token}"}

        try:
            async with httpx.AsyncClient(timeout=300.0) as client:
                with open(audio_file_path, "rb") as audio_file:
                    files = {"audio": (Path(audio_file_path).name, audio_file, "audio/wav")}
                    data = {"definition": json.dumps(definition)}

                    logger.debug(f"[{short_trace_id}] Sending request to: {url}", extra={"trace_id": trace_id})

                    response = await client.post(url, headers=headers, files=files, data=data)

                    if response.status_code != 200:
                        error_detail = response.text
                        logger.error(
                            f"[{short_trace_id}] API request failed: {response.status_code} - {error_detail}",
                            extra={"trace_id": trace_id},
                        )
                        raise RuntimeError(f"Fast Transcription API failed: {response.status_code} - {error_detail}")

                    return response.json()

        except httpx.TimeoutException as e:
            logger.error(f"[{short_trace_id}] Request timeout: {e}", extra={"trace_id": trace_id})
            raise RuntimeError(f"Fast Transcription API timeout: {e}") from e
        except Exception as e:
            logger.error(f"[{short_trace_id}] Request failed: {e}", extra={"trace_id": trace_id})
            raise

    def _map_response_to_model(
        self,
        response_data: dict[str, Any],
        transcription_time: float,
        start_time: float,
        trace_id: str,
    ) -> TranscriptionResponse:
        """
        Map REST API response to TranscriptionResponse model.

        Parameters
        ----------
        response_data : dict
            API response JSON
        transcription_time : float
            Time taken for transcription
        start_time : float
            Request start time
        trace_id : str
            Trace ID for logging

        Returns
        -------
        TranscriptionResponse
            Mapped response model
        """
        short_trace_id = trace_id[:8]

        # Extract phrases
        phrases = response_data.get("phrases", [])
        duration_ms = response_data.get("durationMilliseconds", 0)

        # Convert phrases to segments
        segments = []
        detected_language = "en-US"  # Default

        for phrase in phrases:
            # Extract speaker ID (if diarization enabled)
            speaker = phrase.get("speaker")
            speaker_id = f"spk_{speaker}" if speaker is not None else None

            # Extract language
            locale = phrase.get("locale", "en-US")
            if locale:
                detected_language = locale

            # Convert milliseconds to seconds
            start_sec = phrase.get("offsetMilliseconds", 0) / 1000.0
            duration_sec = phrase.get("durationMilliseconds", 0) / 1000.0
            end_sec = start_sec + duration_sec

            segment = TranscriptionSegment(
                text=phrase.get("text", ""),
                start_time=start_sec,
                end_time=end_sec,
                confidence=phrase.get("confidence", 0.0),
                speaker_id=speaker_id,
                language=locale,
            )
            segments.append(segment)

        # Build full text with speaker attribution
        full_text = "\n".join([f"[{seg.speaker_id}] {seg.text}" if seg.speaker_id else seg.text for seg in segments])

        # Count unique speakers
        unique_speakers = {seg.speaker_id for seg in segments if seg.speaker_id}
        speaker_count = len(unique_speakers) if unique_speakers else None

        # Calculate average confidence
        avg_confidence = sum(seg.confidence for seg in segments) / len(segments) if segments else 0.0

        # Calculate total processing time
        processing_time = time.time() - start_time

        logger.debug(
            f"[{short_trace_id}] Mapped response: {len(segments)} segments, {speaker_count} speakers, {avg_confidence:.2f} confidence",
            extra={"trace_id": trace_id},
        )

        return TranscriptionResponse(
            original_text=full_text,
            translated_text="None",  # Not implemented in Fast API
            original_language=detected_language,
            segments=segments,
            speaker_count=speaker_count,
            audio_duration_seconds=duration_ms / 1000.0,
            processing_time_seconds=processing_time,
            transcription_time_seconds=transcription_time,
            translation_time_seconds=0.0,
            confidence_average=avg_confidence,
            timestamp=datetime.now(),
        )
