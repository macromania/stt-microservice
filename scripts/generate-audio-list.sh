#!/bin/bash
# Generate audio files list for k6 load testing
# This script downloads the LibriSpeech test-clean dataset and creates a JSON array of all FLAC files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLES_DIR="${PROJECT_ROOT}/samples"
AUDIO_DIR="${SAMPLES_DIR}/test-clean"
OUTPUT_FILE="${SAMPLES_DIR}/audio-files.json"
DOWNLOAD_URL="https://openslr.trmal.net/resources/12/test-clean.tar.gz"
TEMP_FILE="${SAMPLES_DIR}/test-clean.tar.gz"

echo "=================================================="
echo "LibriSpeech Dataset Preparation for k6 Load Tests"
echo "=================================================="
echo ""

# Create samples directory if it doesn't exist
mkdir -p "${SAMPLES_DIR}"

# Check if dataset already exists
if [ -d "${AUDIO_DIR}" ]; then
    echo "✓ Dataset already exists at: ${AUDIO_DIR}"
    FILE_COUNT=$(find "${AUDIO_DIR}" -name "*.flac" -type f | wc -l)
    echo "  Found ${FILE_COUNT} audio files"
    
    read -p "Do you want to re-download the dataset? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping download, using existing files..."
    else
        echo "Removing existing dataset..."
        rm -rf "${AUDIO_DIR}"
    fi
fi

# Download dataset if not present
if [ ! -d "${AUDIO_DIR}" ]; then
    echo ""
    echo "Downloading LibriSpeech test-clean dataset..."
    echo "Source: ${DOWNLOAD_URL}"
    echo "Size: ~346 MB (compressed)"
    echo ""
    
    if ! command -v wget &> /dev/null; then
        echo "Error: wget is required but not installed"
        exit 1
    fi
    
    # Download with progress bar
    wget --progress=bar:force:noscroll -O "${TEMP_FILE}" "${DOWNLOAD_URL}"
    
    echo ""
    echo "Extracting dataset..."
    tar -xzf "${TEMP_FILE}" -C "${SAMPLES_DIR}"
    
    # LibriSpeech extracts to LibriSpeech/test-clean, we want samples/test-clean
    if [ -d "${SAMPLES_DIR}/LibriSpeech/test-clean" ]; then
        mv "${SAMPLES_DIR}/LibriSpeech/test-clean" "${AUDIO_DIR}"
        rm -rf "${SAMPLES_DIR}/LibriSpeech"
    fi
    
    # Cleanup
    rm -f "${TEMP_FILE}"
    echo "✓ Dataset extracted successfully"
fi

echo ""
echo "Generating audio files list..."
echo "Output file: ${OUTPUT_FILE}"

if [ ! -d "${AUDIO_DIR}" ]; then
    echo "Error: Audio directory not found: ${AUDIO_DIR}"
    exit 1
fi

# Find all FLAC files and create JSON array
find "${AUDIO_DIR}" -name "*.flac" -type f | \
    jq -R -s 'split("\n") | map(select(length > 0)) | sort' > "${OUTPUT_FILE}"

FILE_COUNT=$(jq '. | length' "${OUTPUT_FILE}")
echo "✓ Generated list of ${FILE_COUNT} audio files"

# Show sample files
echo ""
echo "Sample files (first 5):"
jq -r '.[:5][]' "${OUTPUT_FILE}"

echo ""
echo "Dataset statistics:"
TOTAL_SIZE=$(find "${AUDIO_DIR}" -name "*.flac" -type f -exec stat --format='%s' {} + | \
    awk '{sum+=$1} END {printf "%.2f MB", sum/1024/1024}')
echo "  Total files: ${FILE_COUNT}"
echo "  Total size: ${TOTAL_SIZE}"
echo "  Average size: $(find "${AUDIO_DIR}" -name "*.flac" -type f -exec stat --format='%s' {} + | \
    awk '{sum+=$1; count++} END {printf "%.2f KB", sum/count/1024}')"

SPEAKER_COUNT=$(find "${AUDIO_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "  Speakers: ${SPEAKER_COUNT}"

echo ""
echo "=================================================="
echo "✓ Setup complete!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Review configuration: .env.k6"
echo "  2. Run smoke test: k6 run -e TEST_MODE=smoke load-test.js"
echo "  3. Run load test: k6 run load-test.js"
echo ""
