"""Core configurations for the STT microservice."""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Application settings
    app_version: str = Field(default="0.1.0", description="Application version", alias="APP_VERSION")
    env: str = Field(default="dev", description="Environment: dev|staging|prod", alias="APP_ENV")
    app_log_level: str = Field(default="INFO", description="Logging level", alias="APP_LOG_LEVEL")

    # Azure AI Foundry / Speech Services (uses RBAC authentication via DefaultAzureCredential)
    # Note: Points to AI Foundry AIServices resource (kind: AIServices) which provides Speech + other AI services
    stt_azure_speech_resource_name: str | None = Field(default=None, description="Azure AI Foundry resource name (AIServices kind, provides Speech access)")
    stt_azure_speech_region: str | None = Field(default=None, description="Azure AI Foundry / Speech region")

    # STT limits
    stt_max_file_size_mb: int = Field(default=100, description="Maximum audio file size for STT in MB", alias="STT_MAX_FILE_SIZE_MB")
    stt_max_duration_minutes: int = Field(default=120, description="Maximum audio duration for STT in minutes", alias="STT_MAX_DURATION_MINUTES")

    # Process isolation settings
    enable_process_isolated: bool = Field(default=True, description="Enable process-isolated transcription endpoint and worker pool", alias="ENABLE_PROCESS_ISOLATED")
    process_pool_size: int = Field(default=12, description="Number of worker processes for process-isolated transcription", alias="PROCESS_POOL_SIZE")
    process_timeout: int = Field(default=300, description="Timeout in seconds per transcription process (5 minutes)", alias="PROCESS_TIMEOUT")


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
