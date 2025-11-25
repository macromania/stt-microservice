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

# Install system dependencies including Azure CLI for DefaultAzureCredential and jemalloc
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    libjemalloc2 && \
    # Install Azure CLI
    mkdir -p /etc/apt/keyrings && \
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg && \
    chmod go+r /etc/apt/keyrings/microsoft.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && \
    apt-get install -y azure-cli && \
    rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"

# Copy only the application code
COPY src/ /app/src/

# Configure jemalloc for aggressive memory purging
# background_thread:true - Enable background thread for active memory purging
# dirty_decay_ms:1000 - Purge freed (dirty) pages every ~1 second (50% half-life)
# muzzy_decay_ms:1000 - Purge MADV_FREE pages every ~1 second
ENV MALLOC_CONF="background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:1000"
# Create a wrapper script to dynamically find and preload jemalloc
RUN printf '#!/bin/sh\nexport LD_PRELOAD=$(find /usr/lib -name "libjemalloc.so.2*" -type f | head -n 1)\nexec "$@"\n' > /usr/local/bin/entrypoint.sh && \
    chmod +x /usr/local/bin/entrypoint.sh

# Expose the port the app will run on
EXPOSE 8000

# Use entrypoint wrapper to dynamically load jemalloc before starting the app
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]