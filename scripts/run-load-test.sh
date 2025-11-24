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
WEB_DASHBOARD_ENABLED="false"
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
        
        # Check if this is the web dashboard setting
        if [ "$key" = "K6_WEB_DASHBOARD" ]; then
            WEB_DASHBOARD_ENABLED="$value"
            # Don't pass K6_WEB_DASHBOARD as -e flag, it's handled separately
            continue
        fi
        
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

# Create reports directory if it doesn't exist
REPORTS_DIR="${PROJECT_ROOT}/reports"
mkdir -p "${REPORTS_DIR}"

# Check if web dashboard should be enabled
DASHBOARD_FLAG=""
REPORT_FILE=""
if [ "${WEB_DASHBOARD_ENABLED}" = "true" ] || [ "${WEB_DASHBOARD_ENABLED}" = "1" ]; then
    # Check k6 version - web dashboard requires v0.47.0+
    K6_VERSION=$(k6 version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    K6_MAJOR=$(echo "$K6_VERSION" | cut -d'v' -f2 | cut -d'.' -f1)
    K6_MINOR=$(echo "$K6_VERSION" | cut -d'v' -f2 | cut -d'.' -f2)
    
    if [ "$K6_MAJOR" -gt 0 ] || ([ "$K6_MAJOR" -eq 0 ] && [ "$K6_MINOR" -ge 47 ]); then
        # Generate timestamp-based report filename
        TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
        REPORT_FILE="${REPORTS_DIR}/k6-report-${TIMESTAMP}.html"
        
        DASHBOARD_FLAG="--out web-dashboard"
        export K6_WEB_DASHBOARD_EXPORT="${REPORT_FILE}"
        
        echo "✓ Web dashboard enabled"
        echo "  Dashboard will be available at: http://127.0.0.1:5665"
        echo "  Report will be saved to: ${REPORT_FILE}"
        echo ""
    else
        echo "⚠ Web dashboard requires k6 v0.47.0 or later (you have $K6_VERSION)"
        echo "  Upgrade with: brew upgrade k6"
        echo "  Continuing without web dashboard..."
        echo ""
    fi
fi

# Run k6 with environment variables and all arguments passed through
echo "Running k6 load test from: ${PROJECT_ROOT}"
echo "Command: k6 run $ENV_VARS $DASHBOARD_FLAG $@"
echo ""

# shellcheck disable=SC2086
k6 run $ENV_VARS $DASHBOARD_FLAG "$@"
