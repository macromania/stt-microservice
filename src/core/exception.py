"""Exceptions related to audio processing and transcription."""


class AudioFormatError(Exception):
    """Exception raised for audio format errors."""


class AudioFileSizeError(Exception):
    """Exception raised when audio file exceeds size limits."""


class AudioDurationError(Exception):
    """Exception raised when audio duration exceeds limits."""
