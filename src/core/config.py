"""Core configurations for the STT microservice."""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    # Application settings
    app_version: str = "1.0.0"
    env: str = Field(default="dev", description="Environment: dev|staging|prod", alias="APP_ENV")
    app_log_level: str = Field(default="INFO", description="Logging level", alias="APP_LOG_LEVEL")

    # Azure Speech Services (uses RBAC authentication via DefaultAzureCredential)
    stt_azure_speech_resource_name: str | None = Field(default=None, description="Azure Speech resource name (uses AI Foundry AIServices resource)")
    stt_azure_speech_region: str | None = Field(default=None, description="Azure Speech region")

    # STT limits
    stt_max_file_size_mb: int = Field(default=100, description="Maximum audio file size for STT in MB", alias="STT_MAX_FILE_SIZE_MB")
    stt_max_duration_minutes: int = Field(default=120, description="Maximum audio duration for STT in minutes", alias="STT_MAX_DURATION_MINUTES")


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
