# Batch Transcription Implementation Plan

## Overview

Implement `/transcriptions/batch` endpoint following the same architecture pattern as `/transcriptions/fast` endpoint, using Azure Batch Transcription REST API instead of SDK callbacks.

## Architecture Pattern (Based on Fast Transcription)

### 1. **Service Layer** (`src/service/stt/batch_transcription.py`)

Follow `FastTranscriptionService` pattern:

- Class-based service with `__init__` for config
- Main `process_audio()` async method
- Helper methods for each API call step
- Response mapping to `TranscriptionResponse` model

### 2. **API Layer** (`src/api/stt.py`)

Follow `/fast` endpoint pattern:

- `@router.post("/batch")` endpoint
- File upload validation with `validate_upload_file()`
- Stream upload to temp file with size limits
- Service instantiation and call
- Metrics recording
- Error handling and cleanup
- Return `TranscriptionResponse` model

## Implementation Details

### BatchTranscriptionService Class

```python
class BatchTranscriptionService:
    """
    Batch Transcription service using Azure Speech REST API.
    
    Uses Batch Transcription API for async processing with per-segment
    language detection and speaker diarization.
    
    Features:
    - Uploads audio to Azure Blob Storage
    - Submits batch transcription job
    - Polls for completion
    - Downloads and parses JSON results
    - Maps to TranscriptionResponse model
    """
    
    API_VERSION = "2024-11-15"
    POLL_INTERVAL_START = 5  # seconds
    POLL_INTERVAL_MAX = 60   # seconds
    POLL_TIMEOUT = 1800      # 30 minutes
```

### Key Methods

#### 1. `process_audio(audio_file_path, language, trace_id)`

Main entry point - orchestrates entire workflow:

1. Upload audio to blob storage
2. Submit transcription job
3. Poll for completion
4. Download results
5. Map to TranscriptionResponse

#### 2. `_upload_to_blob(audio_file_path, trace_id)`

Uploads audio file to Azure Blob Storage:

- Uses `azure-storage-blob` SDK
- `BlobServiceClient` with `DefaultAzureCredential`
- Container: configured in settings
- Generate SAS URL with read permissions (1 hour expiry)
- Return blob URL for job submission

#### 3. `_submit_job(blob_url, language, trace_id)`

Submits batch transcription job:

```python
POST /speechtotext/transcriptions:submit?api-version=2024-11-15
Headers:
  Authorization: Bearer {token}
Body:
  {
    "contentUrls": [blob_url],
    "locale": "ar-AE",  # or detected from language param
    "displayName": "Batch-{trace_id}",
    "properties": {
      "diarization": {
        "enabled": true,
        "maxSpeakers": 10
      },
      "languageIdentification": {
        "candidateLocales": ["ar-AE", "ar-SA", "en-US", "en-GB"],
        "mode": "Continuous"
      },
      "wordLevelTimestampsEnabled": true,
      "timeToLiveHours": 48
    }
  }
```

#### 4. `_poll_status(job_uri, trace_id)`

Polls job status with exponential backoff:

- Start: 5s delay
- Exponential: 5s → 10s → 20s → 40s → 60s (max)
- Timeout: 30 minutes total
- Check status: `GET {job_uri}?api-version=2024-11-15`
- States: NotStarted → Running → Succeeded/Failed
- Return files link when Succeeded

#### 5. `_download_results(files_link, trace_id)`

Downloads transcription results:

- GET files list from `{job_uri}/files`
- Find file with `kind: "Transcription"`
- Download JSON from `contentUrl`
- Return parsed JSON

#### 6. `_parse_results(response_json, trace_id)`

Maps Batch API response to model:

**Input JSON structure:**

```json
{
  "source": "blob_url",
  "durationMilliseconds": 61170,
  "recognizedPhrases": [
    {
      "speaker": 0,
      "locale": "ar-AE",
      "offsetMilliseconds": 2090,
      "durationMilliseconds": 840,
      "nBest": [
        {
          "confidence": 0.95,
          "display": "السلام عليكم دكتورة.",
          "words": [...]
        }
      ]
    }
  ]
}
```

**Mapping logic:**

```python
segments = []
for phrase in recognizedPhrases:
    segment = TranscriptionSegment(
        text=phrase["nBest"][0]["display"],
        start_time=phrase["offsetMilliseconds"] / 1000.0,
        end_time=(phrase["offsetMilliseconds"] + phrase["durationMilliseconds"]) / 1000.0,
        confidence=phrase["nBest"][0]["confidence"],
        speaker_id=f"spk_Guest-{phrase['speaker']}" if phrase.get("speaker") is not None else None,
        language=phrase.get("locale", "en-US")
    )
    segments.append(segment)
```

### API Endpoint Pattern

```python
@router.post("/batch", response_model=TranscriptionResponse)
async def create_batch_transcription(
    audio_file: Annotated[UploadFile, File(description="Audio file (max 100MB)")],
    language: Annotated[str, Form(description="Language code or 'auto'")] = "auto",
) -> TranscriptionResponse:
    """
    Create transcription using Batch Transcription REST API (async processing).
    
    This endpoint uses Azure's Batch Transcription REST API for async processing
    with per-segment language detection and speaker diarization.
    
    Supports: WAV, MP3, M4A, FLAC, AAC, OGG, WEBM, MP4 (max 100MB, max 240 min)
    Processing time: Minutes to hours depending on queue and audio length
    
    Features:
    - Per-segment language detection (ar-AE, ar-SA, en-US, en-GB)
    - Speaker diarization (up to 36 speakers)
    - Higher accuracy with bilingual Arabic+English support
    - No memory leaks (no SDK callbacks)
    
    Parameters
    ----------
    audio_file : UploadFile
        Audio file to process
    language : str
        Language code (e.g., "ar-AE", "en-US") or "auto" for detection
    
    Returns
    -------
    TranscriptionResponse
        Transcription with per-segment language and speaker labels
    """
    # Same pattern as /fast endpoint:
    # 1. validate_upload_file()
    # 2. Stream to temp file with size limits
    # 3. Create BatchTranscriptionService()
    # 4. Call service.process_audio()
    # 5. Record metrics
    # 6. Error handling
    # 7. Cleanup in finally block
```

## Configuration Updates

### `src/core/config.py`

Add blob storage settings:

```python
class Settings(BaseSettings):
    # ... existing fields ...
    
    # Azure Blob Storage for Batch Transcription
    stt_azure_storage_account_name: str | None = Field(
        default=None, 
        description="Azure Storage account name for batch transcription uploads"
    )
    stt_azure_storage_container_name: str = Field(
        default="batch-transcription-audio", 
        description="Container name for batch transcription audio files"
    )
```

## Dependencies Update

### `pyproject.toml`

Add blob storage SDK:

```toml
[tool.poetry.dependencies]
azure-storage-blob = "^12.19.0"  # For batch transcription uploads
```

## Error Handling

Follow fast transcription error patterns:

1. **File validation errors** → `HTTPException(400)`
2. **File size errors** → `HTTPException(413)`
3. **Blob upload errors** → `HTTPException(500, "Blob upload failed")`
4. **Job submission errors** → `HTTPException(500, "Job submission failed")`
5. **Polling timeout** → `HTTPException(504, "Transcription timeout")`
6. **Processing errors** → `HTTPException(500, "Processing failed")`

## Metrics

Follow fast transcription metrics pattern:

- `stt_transcriptions_total` - Counter with status/language labels
- `stt_audio_duration_seconds` - Histogram
- `stt_transcription_confidence` - Gauge
- `stt_transcription_time` - Histogram (full processing time)
- `stt_translation_time` - Histogram (0 for batch API)

## Cleanup Strategy

Follow fast transcription cleanup:

1. Delete temp audio file in `finally` block
2. (Optional) Delete blob after successful processing
3. Set job TTL to auto-delete after 48 hours
4. Force `gc.collect()` after processing

## Key Differences: Fast vs Batch

| Feature | Fast API | Batch API |
|---------|----------|-----------|
| **Processing** | Synchronous | Asynchronous (polling) |
| **Latency** | <5s (faster than real-time) | Minutes to hours |
| **Audio Limit** | 2 hours, 300MB | 240 minutes per file |
| **Language Detection** | Per-file | Per-segment ✅ |
| **Max Speakers** | ~10 | Up to 36 ✅ |
| **Blob Storage** | Not required | Required |
| **Use Case** | Quick transcription | High accuracy, multi-lingual |

## Testing Plan

1. **Basic test**: Single speaker Arabic audio
2. **Multi-speaker test**: 2-3 speakers Arabic
3. **Multi-lingual test**: Arabic + English code-switching
4. **Edge cases**:
   - Large file (100MB)
   - Long audio (2+ hours)
   - Poor quality audio
   - Timeout scenario (mock)
5. **Error tests**:
   - Invalid file format
   - Blob upload failure
   - Job submission failure
   - Polling timeout

## Implementation Order

1. ✅ Architecture analysis (completed)
2. ⏳ Update `pyproject.toml` with azure-storage-blob
3. ⏳ Update `src/core/config.py` with blob settings
4. ⏳ Create `src/service/stt/batch_transcription.py`
   - Basic class structure
   - `_get_access_token()` method (reuse from fast)
   - `_upload_to_blob()` method
   - `_submit_job()` method
   - `_poll_status()` method
   - `_download_results()` method
   - `_parse_results()` method
   - Main `process_audio()` orchestration
5. ⏳ Add endpoint in `src/api/stt.py`
6. ⏳ Test with sample audio
7. ⏳ Documentation update in README

## Expected Output Format

Matches your example exactly:

```json
{
  "original_text": "[spk_Guest-1] السلام عليكم دكتورة.\n[spk_Guest-2] السلام ورحمة الله...",
  "translated_text": "None",
  "original_language": "ar-AE",
  "segments": [
    {
      "text": "السلام عليكم دكتورة.",
      "start_time": 2.09,
      "end_time": 2.93,
      "confidence": 0.95,
      "speaker_id": "spk_Guest-1",
      "language": "ar-AE"
    },
    {
      "text": "I need to come home.",
      "start_time": 40.29,
      "end_time": 41.57,
      "confidence": 0.95,
      "speaker_id": "spk_Guest-2",
      "language": "en-US"
    }
  ],
  "speaker_count": 2,
  "audio_duration_seconds": 61.17,
  "processing_time_seconds": 125.5,
  "transcription_time_seconds": 125.5,
  "translation_time_seconds": 0.0,
  "confidence_average": 0.95,
  "timestamp": "2025-11-24T20:24:53.852408"
}
```

## Notes

- **Per-segment language detection**: Key feature that Fast API doesn't provide
- **Higher latency**: Trade-off for better accuracy and multi-lingual support
- **No callbacks**: Eliminates memory leak issues from SDK
- **Blob storage requirement**: Audio must be uploaded before job submission
- **Job cleanup**: Auto-deleted after 48 hours (TTL)
- **Billing**: Charged per minute of audio processed
