"""
Data models for Speech-to-Text V2 service.

Simplified models without medical terms support.
All responses include English translation.
"""

from datetime import datetime

from pydantic import BaseModel, Field


class TranscriptionSegment(BaseModel):
    """
    A single segment of transcription with timing and speaker info.

    Attributes
    ----------
    text : str
        The transcribed text for this segment
    start_time : float
        Start time in seconds
    end_time : float
        End time in seconds
    confidence : float
        Confidence score (0.0 to 1.0)
    speaker_id : str, optional
        Speaker identifier (e.g., "spk_0", "spk_1")
    language : str, optional
        Detected language for this segment
    """

    text: str = Field(..., description="Transcribed text")
    start_time: float = Field(..., ge=0, description="Start time in seconds")
    end_time: float = Field(..., ge=0, description="End time in seconds")
    confidence: float = Field(..., ge=0.0, le=1.0, description="Confidence score 0-1")
    speaker_id: str | None = Field(default=None, description="Speaker identifier")
    language: str | None = Field(default=None, description="Detected language")


class TranscriptionResponse(BaseModel):
    """
    Response model for transcription.

    V2 always includes English translation regardless of source language.

    Attributes
    ----------
    original_text : str
        Complete transcribed text in original language
    translated_text : str
        English translation (always provided)
    original_language : str
        Detected original language code
    segments : list[TranscriptionSegmentV2]
        List of transcription segments with timing
    speaker_count : int, optional
        Number of unique speakers detected (diarization always on)
    audio_duration_seconds : float
        Total duration of audio in seconds
    processing_time_seconds : float
        Time taken to process
    confidence_average : float
        Average confidence across all segments
    timestamp : datetime
        When the transcription was completed
    """

    original_text: str = Field(..., description="Original transcribed text")
    translated_text: str = Field(..., description="English translation (always provided)")
    original_language: str = Field(..., description="Detected original language")
    segments: list[TranscriptionSegment] = Field(..., description="Transcription segments")
    speaker_count: int | None = Field(default=None, description="Number of speakers detected")
    audio_duration_seconds: float = Field(..., ge=0, description="Audio duration in seconds")
    processing_time_seconds: float = Field(..., ge=0, description="Total processing time in seconds")
    transcription_time_seconds: float = Field(..., ge=0, description="Time taken for transcription step")
    translation_time_seconds: float = Field(..., ge=0, description="Time taken for translation step")
    confidence_average: float = Field(..., ge=0.0, le=1.0, description="Average confidence score")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="Completion timestamp")

    def to_json(self, **kwargs) -> str:
        """
        Export the response as JSON string.

        Parameters
        ----------
        **kwargs
            Additional arguments passed to model_dump_json

        Returns
        -------
        str
            JSON string representation
        """
        return self.model_dump_json(**kwargs)

    def to_dict(self, **kwargs) -> dict:
        """
        Export the response as a dictionary.

        Parameters
        ----------
        **kwargs
            Additional arguments passed to model_dump

        Returns
        -------
        dict
            Dictionary representation
        """
        return self.model_dump(**kwargs)
