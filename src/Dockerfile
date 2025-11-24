# --- Builder stage ---
FROM python:3.13.4-slim AS builder

WORKDIR /app

ENV POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    POETRY_CACHE_DIR=/tmp/poetry_cache

# Install system dependencies needed for Poetry and building packages
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Install Poetry
RUN curl -sSL https://install.python-poetry.org | python3 && ln -s /root/.local/bin/poetry /usr/local/bin/poetry

# Copy only requirements to install dependencies
COPY poetry.lock pyproject.toml ./
RUN poetry install --only=main && rm -rf $POETRY_CACHE_DIR

# Copy application code for linting/type-checking if needed (optional)
COPY src/ /app/src/

# --- Final stage ---
FROM python:3.13.4-slim AS final

WORKDIR /app

# This keeps the container filesystem cleaner and avoids unnecessary file writes.
ENV PYTHONDONTWRITEBYTECODE=1

# This ensures that Python output is sent straight to terminal (e.g. logs).
ENV PYTHONUNBUFFERED=1

# Install system dependencies (if any, e.g. for uvicorn)
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Copy only the application code
COPY src/ /app/src/

# Expose the port the app will run on
EXPOSE 8000

# Use python -m uvicorn to run the FastAPI application
CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]