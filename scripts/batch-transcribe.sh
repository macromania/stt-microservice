#!/usr/bin/env bash
#
# Test Azure Speech Batch Transcription API
#
# Usage:
#   ./scripts/batch-transcribe.sh create [AUDIO_URL]  - Create a batch transcription job
#   ./scripts/batch-transcribe.sh status <ID>         - Get transcription status
#   ./scripts/batch-transcribe.sh results <ID>        - Get transcription results
#   ./scripts/batch-transcribe.sh delete <ID>         - Delete a transcription
#   ./scripts/batch-transcribe.sh wait <ID>           - Poll until completion and show results

set -e

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Load environment variables from .env if it exists
if [ -f "${SCRIPT_DIR}/../.env" ]; then
    set -a
    source "${SCRIPT_DIR}/../.env"
    set +a
fi

# Configuration
REGION="${STT_AZURE_SPEECH_REGION:-swedencentral}"
RESOURCE_NAME="${STT_AZURE_SPEECH_RESOURCE_NAME:-}"
API_VERSION="2024-11-15"
DEFAULT_AUDIO_URL="https://raw.githubusercontent.com/macromania/stt-microservice/main/samples/sample-audio.wav"

# Build the base API URL - use custom subdomain if resource name is set (required for token auth)
get_base_url() {
    if [ -n "$RESOURCE_NAME" ]; then
        echo "https://${RESOURCE_NAME}.cognitiveservices.azure.com/speechtotext/v3.2"
    else
        echo "https://${REGION}.api.cognitive.microsoft.com/speechtotext/v3.2"
    fi
}

# Get access token
get_token() {
    if [ -n "$AZURE_ACCESS_TOKEN" ]; then
        echo "$AZURE_ACCESS_TOKEN"
    else
        az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
    fi
}

# Create batch transcription
create_transcription() {
    local audio_url="${1:-$DEFAULT_AUDIO_URL}"
    local token
    token=$(get_token)
    
    print_banner "Create Batch Transcription"
    print_info "Audio URL: $audio_url"
    print_info "Region: $REGION"
    if [ -n "$RESOURCE_NAME" ]; then
        print_info "Resource: $RESOURCE_NAME (custom subdomain)"
    fi
    print_info "Features enabled:"
    echo "  • Word-level timestamps"
    echo "  • Speaker diarization (up to 10 speakers)"
    echo "  • Continuous language ID (en-US, en-GB, ar-AE, ar-SA, ar-EG, ar-JO, ar-KW, ar-QA, ar-BH, ar-IQ)"
    echo "  • Automatic punctuation"
    
    print_progress "Submitting transcription job..."
    
    local base_url
    base_url=$(get_base_url)
    
    response=$(curl -s -X POST \
        "${base_url}/transcriptions" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{
            "contentUrls": ["'"${audio_url}"'"],
            "locale": "en-US",
            "displayName": "Batch Test '"$(date +%Y-%m-%d-%H%M%S)"'",
            "properties": {
                "wordLevelTimestampsEnabled": true,
                "displayFormWordLevelTimestampsEnabled": true,
                "diarizationEnabled": true,
                "diarization": {
                    "speakers": {
                        "minCount": 1,
                        "maxCount": 10
                    }
                },
                "languageIdentification": {
                    "candidateLocales": ["en-US", "en-GB", "ar-AE", "ar-SA", "ar-EG", "ar-JO", "ar-KW", "ar-QA", "ar-BH", "ar-IQ"],
                    "mode": "Continuous"
                },
                "punctuationMode": "DictatedAndAutomatic",
                "profanityFilterMode": "None",
                "timeToLive": "PT48H"
            }
        }')
    
    print_section "Response"
    echo "$response" | jq .
    
    # Extract and display the transcription ID
    transcription_id=$(echo "$response" | jq -r '.self' | sed 's|.*/||' | cut -d'?' -f1)
    if [ -n "$transcription_id" ] && [ "$transcription_id" != "null" ]; then
        print_separator
        print_success "Transcription created!"
        echo ""
        print_info "Transcription ID: ${transcription_id}"
        echo ""
        echo "Next steps:"
        echo "  Check status:    ./scripts/batch-transcribe.sh status ${transcription_id}"
        echo "  Wait & results:  ./scripts/batch-transcribe.sh wait ${transcription_id}"
        echo ""
    else
        print_error "Failed to create transcription"
        exit 1
    fi
}

# Get transcription status
get_status() {
    local transcription_id="$1"
    local token
    token=$(get_token)
    
    if [ -z "$transcription_id" ]; then
        print_error "Transcription ID required"
        echo "Usage: $0 status <TRANSCRIPTION_ID>"
        exit 1
    fi
    
    print_banner "Transcription Status"
    print_info "Transcription ID: ${transcription_id}"
    
    print_progress "Fetching status..."
    
    local base_url
    base_url=$(get_base_url)
    
    response=$(curl -s -X GET \
        "${base_url}/transcriptions/${transcription_id}" \
        -H "Authorization: Bearer ${token}")
    
    status=$(echo "$response" | jq -r '.status')
    
    print_section "Status: ${status}"
    echo "$response" | jq .
}

# Get transcription results/files
get_results() {
    local transcription_id="$1"
    local token
    token=$(get_token)
    
    if [ -z "$transcription_id" ]; then
        print_error "Transcription ID required"
        echo "Usage: $0 results <TRANSCRIPTION_ID>"
        exit 1
    fi
    
    print_banner "Transcription Results"
    print_info "Transcription ID: ${transcription_id}"
    
    print_progress "Fetching result files..."
    
    local base_url
    base_url=$(get_base_url)
    
    # Get file list
    files_response=$(curl -s -X GET \
        "${base_url}/transcriptions/${transcription_id}/files" \
        -H "Authorization: Bearer ${token}")
    
    print_section "Available Files"
    echo "$files_response" | jq '.values[] | {name: .name, kind: .kind}'
    
    # Extract and fetch transcription content
    content_url=$(echo "$files_response" | jq -r '.values[] | select(.kind=="Transcription") | .links.contentUrl')
    
    if [ -n "$content_url" ] && [ "$content_url" != "null" ]; then
        print_section "Transcription Content"
        transcription_content=$(curl -s "$content_url")
        echo "$transcription_content" | jq .
        
        # Show combined recognized phrases
        print_section "Recognized Text"
        echo "$transcription_content" | jq -r '.combinedRecognizedPhrases[]?.display // "No text recognized"'
    else
        print_warning "Transcription content not available yet"
    fi
}

# Delete transcription
delete_transcription() {
    local transcription_id="$1"
    local token
    token=$(get_token)
    
    if [ -z "$transcription_id" ]; then
        print_error "Transcription ID required"
        echo "Usage: $0 delete <TRANSCRIPTION_ID>"
        exit 1
    fi
    
    print_banner "Delete Transcription"
    print_info "Transcription ID: ${transcription_id}"
    
    print_progress "Deleting transcription..."
    
    local base_url
    base_url=$(get_base_url)
    
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "${base_url}/transcriptions/${transcription_id}" \
        -H "Authorization: Bearer ${token}")
    
    if [ "$http_code" = "204" ]; then
        print_success "Transcription deleted successfully"
    else
        print_error "Delete failed with HTTP $http_code"
        exit 1
    fi
}

# Wait for completion and show results
wait_for_completion() {
    local transcription_id="$1"
    local token
    token=$(get_token)
    local max_attempts=60
    local attempt=0
    
    if [ -z "$transcription_id" ]; then
        print_error "Transcription ID required"
        echo "Usage: $0 wait <TRANSCRIPTION_ID>"
        exit 1
    fi
    
    print_banner "Wait for Transcription"
    print_info "Transcription ID: ${transcription_id}"
    print_info "Max wait time: $((max_attempts * 5)) seconds"
    
    print_progress "Polling for completion..."
    echo ""
    
    local base_url
    base_url=$(get_base_url)
    
    while [ $attempt -lt $max_attempts ]; do
        response=$(curl -s -X GET \
            "${base_url}/transcriptions/${transcription_id}" \
            -H "Authorization: Bearer ${token}")
        
        status=$(echo "$response" | jq -r '.status')
        printf "\r  Status: %-15s (attempt %d/%d)" "$status" "$((attempt+1))" "$max_attempts"
        
        case "$status" in
            "Succeeded")
                echo ""
                print_success "Transcription completed!"
                get_results "$transcription_id"
                print_completion "Batch Transcription Succeeded!"
                exit 0
                ;;
            "Failed")
                echo ""
                print_error "Transcription failed!"
                print_section "Error Details"
                echo "$response" | jq .
                exit 1
                ;;
            "NotStarted"|"Running")
                sleep 5
                ;;
            *)
                echo ""
                print_error "Unknown status: $status"
                echo "$response" | jq .
                exit 1
                ;;
        esac
        
        attempt=$((attempt+1))
    done
    
    echo ""
    print_error "Timeout waiting for transcription after $((max_attempts * 5)) seconds"
    exit 1
}

# Run full demo: create, wait, show results, then delete
run_demo() {
    local audio_url="${1:-$DEFAULT_AUDIO_URL}"
    
    print_banner "Batch Transcription Demo"
    print_info "This will create a transcription, wait for completion, show results, and clean up"
    print_info "Audio URL: $audio_url"
    print_info "Features enabled:"
    echo "  • Word-level timestamps"
    echo "  • Speaker diarization (up to 10 speakers)"
    echo "  • Continuous language ID (en-US, en-GB, ar-AE, ar-SA, ar-EG, ar-JO, ar-KW, ar-QA, ar-BH, ar-IQ)"
    echo "  • Automatic punctuation"
    echo ""
    
    # Step 1: Create
    print_step 1 "Creating Batch Transcription"
    local token
    token=$(get_token)
    
    local base_url
    base_url=$(get_base_url)
    
    response=$(curl -s -X POST \
        "${base_url}/transcriptions" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{
            "contentUrls": ["'"${audio_url}"'"],
            "locale": "en-US",
            "displayName": "Demo '"$(date +%Y-%m-%d-%H%M%S)"'",
            "properties": {
                "wordLevelTimestampsEnabled": true,
                "displayFormWordLevelTimestampsEnabled": true,
                "diarizationEnabled": true,
                "diarization": {
                    "speakers": {
                        "minCount": 1,
                        "maxCount": 10
                    }
                },
                "languageIdentification": {
                    "candidateLocales": ["en-US", "en-GB", "ar-AE", "ar-SA", "ar-EG", "ar-JO", "ar-KW", "ar-QA", "ar-BH", "ar-IQ"],
                    "mode": "Continuous"
                },
                "punctuationMode": "DictatedAndAutomatic",
                "profanityFilterMode": "None",
                "timeToLive": "PT1H"
            }
        }')
    
    transcription_id=$(echo "$response" | jq -r '.self' | sed 's|.*/||' | cut -d'?' -f1)
    
    if [ -z "$transcription_id" ] || [ "$transcription_id" = "null" ]; then
        print_error "Failed to create transcription"
        echo "$response" | jq .
        exit 1
    fi
    
    print_success "Created transcription: ${transcription_id}"
    
    # Step 2: Wait for completion
    print_step 2 "Waiting for Completion"
    local max_attempts=60
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        status_response=$(curl -s -X GET \
            "${base_url}/transcriptions/${transcription_id}" \
            -H "Authorization: Bearer ${token}")
        
        status=$(echo "$status_response" | jq -r '.status')
        printf "\r  Status: %-15s (attempt %d/%d)" "$status" "$((attempt+1))" "$max_attempts"
        
        case "$status" in
            "Succeeded")
                echo ""
                print_success "Transcription completed!"
                break
                ;;
            "Failed")
                echo ""
                print_error "Transcription failed!"
                echo "$status_response" | jq .
                exit 1
                ;;
            "NotStarted"|"Running")
                sleep 5
                ;;
            *)
                echo ""
                print_error "Unknown status: $status"
                exit 1
                ;;
        esac
        
        attempt=$((attempt+1))
    done
    
    if [ $attempt -ge $max_attempts ]; then
        print_error "Timeout waiting for transcription"
        exit 1
    fi
    
    # Step 3: Get results
    print_step 3 "Fetching Results"
    
    files_response=$(curl -s -X GET \
        "${base_url}/transcriptions/${transcription_id}/files" \
        -H "Authorization: Bearer ${token}")
    
    content_url=$(echo "$files_response" | jq -r '.values[] | select(.kind=="Transcription") | .links.contentUrl')
    
    if [ -n "$content_url" ] && [ "$content_url" != "null" ]; then
        transcription_content=$(curl -s "$content_url")
        
        print_info "Recognized Text:"
        echo ""
        echo "$transcription_content" | jq -r '.combinedRecognizedPhrases[]?.display // "No text recognized"'
        echo ""
        
        # Show detailed segments with speakers
        print_info "Detailed Segments (with speakers):"
        echo "$transcription_content" | jq -r '
            .recognizedPhrases[]? | 
            "  [\(.speaker // "?")] \(.nBest[0].display // "")"
        ' 2>/dev/null || echo "  (No detailed segments available)"
        echo ""
    else
        print_warning "No transcription content available"
    fi
    
    # Step 4: Cleanup
    print_step 4 "Cleaning Up"
    
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "${base_url}/transcriptions/${transcription_id}" \
        -H "Authorization: Bearer ${token}")
    
    if [ "$http_code" = "204" ]; then
        print_success "Transcription deleted"
    else
        print_warning "Could not delete transcription (HTTP $http_code)"
    fi
    
    print_completion "Demo Complete!"
}

# Show help
show_help() {
    print_banner "Batch Transcription Test"
    echo "Test Azure Speech Batch Transcription API using REST/curl"
    echo ""
    print_section "Usage"
    echo "  $0 demo [AUDIO_URL]    - Run full demo: create, wait, show results, cleanup"
    echo "  $0 create [AUDIO_URL]  - Create a batch transcription job"
    echo "  $0 status <ID>         - Get transcription status"
    echo "  $0 results <ID>        - Get transcription results"
    echo "  $0 delete <ID>         - Delete a transcription"
    echo "  $0 wait <ID>           - Poll until completion and show results"
    echo ""
    print_section "Environment Variables"
    echo "  STT_AZURE_SPEECH_REGION        Azure region (default: swedencentral)"
    echo "  STT_AZURE_SPEECH_RESOURCE_NAME Azure resource name (required for token auth)"
    echo "  AZURE_ACCESS_TOKEN             Azure access token (optional)"
    echo "                                 If not set, uses: az account get-access-token"
    echo ""
    print_section "Examples"
    echo "  # Create with default sample audio"
    echo "  $0 create"
    echo ""
    echo "  # Create with custom audio URL"
    echo "  $0 create https://example.com/audio.wav"
    echo ""
    echo "  # Wait for completion and show results"
    echo "  $0 wait abc123-def456-..."
    echo ""
}

# Main command handler
case "${1:-help}" in
    demo)
        run_demo "$2"
        ;;
    create)
        create_transcription "$2"
        ;;
    status)
        get_status "$2"
        ;;
    results)
        get_results "$2"
        ;;
    delete)
        delete_transcription "$2"
        ;;
    wait)
        wait_for_completion "$2"
        ;;
    help|--help|-h|*)
        show_help
        ;;
esac
