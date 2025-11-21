#!/bin/bash
# Wrapper script to run k6 load tests with automatic dataset preparation
# This script ensures the audio files list is generated before running tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AUDIO_DIR="${PROJECT_ROOT}/samples/test-clean"
AUDIO_LIST="${PROJECT_ROOT}/samples/audio-files.json"
ENV_FILE="${PROJECT_ROOT}/.env.k6"

# Check if k6 is installed
if ! command -v k6 &> /dev/null; then
    echo "Error: k6 is not installed"
    echo "Install with: brew install k6"
    exit 1
fi

# Check if dataset exists
if [ ! -d "${AUDIO_DIR}" ]; then
    echo "LibriSpeech dataset not found at: ${AUDIO_DIR}"
    echo "Downloading and preparing dataset..."
    echo ""
    "${SCRIPT_DIR}/generate-audio-list.sh"
else
    # Dataset exists, check if we need to regenerate the file list
    if [ ! -f "${AUDIO_LIST}" ]; then
        echo "Generating audio files list..."
        cd "${PROJECT_ROOT}"
        find samples/test-clean -name "*.flac" -type f | sort | \
            jq -R -s 'split("\n") | map(select(length > 0))' > "${AUDIO_LIST}"
        FILE_COUNT=$(jq '. | length' "${AUDIO_LIST}")
        echo "✓ Generated list of ${FILE_COUNT} audio files"
        echo ""
    fi
fi

# Verify audio list exists and is valid
if [ ! -f "${AUDIO_LIST}" ]; then
    echo "Error: Audio files list not found: ${AUDIO_LIST}"
    exit 1
fi

FILE_COUNT=$(jq '. | length' "${AUDIO_LIST}")
if [ "${FILE_COUNT}" -eq 0 ]; then
    echo "Error: Audio files list is empty"
    exit 1
fi

echo "✓ Ready to run tests with ${FILE_COUNT} audio files"
echo ""

# Load environment variables from .env.k6 and export them for k6
ENV_VARS=""
if [ -f "${ENV_FILE}" ]; then
    echo "Loading configuration from .env.k6..."
    # Read .env.k6 and build -e flags for k6
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Remove leading/trailing whitespace and quotes
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | sed "s/^['\"]//;s/['\"]$//")
        
        # Convert absolute paths to relative for path-related variables
        if [[ "$key" == *"PATH"* ]] || [[ "$key" == *"DIR"* ]] || [[ "$key" == *"LIST"* ]]; then
            # If value starts with absolute path to project, make it relative
            if [[ "$value" == "${PROJECT_ROOT}/"* ]]; then
                value="${value#${PROJECT_ROOT}/}"
            fi
        fi
        
        # Add to k6 env vars
        ENV_VARS="$ENV_VARS -e $key=$value"
    done < "${ENV_FILE}"
    echo ""
else
    echo "Warning: .env.k6 not found, using default configuration"
    echo "Create .env.k6 from .env.k6.example to customize settings"
    echo ""
fi

# Change to project root before running k6 (ensures relative paths work)
cd "${PROJECT_ROOT}"

# Run k6 with environment variables and all arguments passed through
echo "Running k6 load test from: ${PROJECT_ROOT}"
echo "Command: k6 run $ENV_VARS $@"
echo ""

# shellcheck disable=SC2086
k6 run $ENV_VARS "$@"
