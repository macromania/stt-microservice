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
        find "${AUDIO_DIR}" -name "*.flac" -type f | sort | \
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

# Check if .env.k6 exists
if [ ! -f "${ENV_FILE}" ]; then
    echo "Warning: .env.k6 not found, using default configuration"
    echo "Create .env.k6 from .env.k6.example to customize settings"
    echo ""
fi

# Run k6 with all arguments passed through
echo "Running k6 load test..."
echo "Command: k6 run --env-file ${ENV_FILE} $@"
echo ""

if [ -f "${ENV_FILE}" ]; then
    k6 run --env-file "${ENV_FILE}" "$@"
else
    k6 run "$@"
fi
