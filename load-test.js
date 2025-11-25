/**
 * k6 Load Test for STT API with LibriSpeech Dataset
 * 
 * Features:
 * - Random audio file selection from LibriSpeech test-clean dataset (100 files by default)
 * - Configurable VUs and load patterns via environment variables
 * - Test mode presets (smoke, load, stress, soak)
 * - Dynamic stage generation with gradual ramp-up
 * - Enhanced metrics and validation
 * - CI/CD friendly configuration
 * 
 * Usage:
 *   # Use wrapper script (recommended)
 *   ./scripts/run-load-test.sh -e TEST_MODE=smoke load-test.js
 * 
 *   # Or run k6 directly with environment variables
 *   k6 run -e TEST_MODE=smoke load-test.js
 * 
 * Requirements:
 *   - Run scripts/generate-audio-list.sh first to prepare dataset
 *     (Downloads LibriSpeech, converts to WAV, selects random 100 files)
 *   - Backend service running (default: http://localhost:8000)
 */

import { FormData } from 'https://jslib.k6.io/formdata/0.0.2/index.js';
import { check, sleep } from 'k6';
import http from 'k6/http';
import { Counter, Rate, Trend } from 'k6/metrics';

// =============================================================================
// CONFIGURATION & CONSTANTS
// =============================================================================

// Test mode presets
const TEST_MODES = {
  smoke: {
    vus: 1,
    rampUp: '30s',
    steady: '1m',
    rampDown: '30s',
    description: 'Quick validation with 1 VU'
  },
  load: {
    vus: 100,
    rampUp: '10m',
    steady: '5m',
    rampDown: '5m',
    description: 'Standard load test with gradual ramp'
  },
  stress: {
    vus: 200,
    rampUp: '15m',
    steady: '10m',
    rampDown: '5m',
    description: 'High load stress test'
  },
  soak: {
    vus: 50,
    rampUp: '5m',
    steady: '60m',
    rampDown: '5m',
    description: 'Extended duration stability test'
  }
};

// Get configuration from environment or use defaults
const TEST_MODE = __ENV.TEST_MODE || 'load';
const USE_RANDOM_AUDIO = __ENV.USE_RANDOM_AUDIO !== 'false';
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
const LANGUAGE = __ENV.LANGUAGE || 'en-US';
const REQUEST_TIMEOUT_MS = parseInt(__ENV.REQUEST_TIMEOUT_MS || '180000');
const THINK_TIME_MIN = parseFloat(__ENV.THINK_TIME_MIN || '1');
const THINK_TIME_MAX = parseFloat(__ENV.THINK_TIME_MAX || '3');
const VERBOSE_ERRORS = __ENV.VERBOSE_ERRORS !== 'false';
const LOG_SAMPLE_RATE = parseInt(__ENV.LOG_SAMPLE_RATE || '10');
const ENDPOINT = '/transcriptions';

// Load pattern configuration
const getLoadConfig = () => {
  // Start with test mode preset if valid, otherwise use defaults
  let baseConfig = TEST_MODES[TEST_MODE] || {
    vus: 100,
    rampUp: '10m',
    steady: '5m',
    rampDown: '5m'
  };
  
  // Environment variables ALWAYS override preset values
  return {
    vus: parseInt(__ENV.MAX_VUS || baseConfig.vus.toString()),
    rampUp: __ENV.RAMP_UP_DURATION || baseConfig.rampUp,
    steady: __ENV.STEADY_DURATION || baseConfig.steady,
    rampDown: __ENV.RAMP_DOWN_DURATION || baseConfig.rampDown
  };
};

const LOAD_CONFIG = getLoadConfig();
const RAMP_STEPS = parseInt(__ENV.RAMP_STEPS || '4');
const START_VUS = parseInt(__ENV.START_VUS || '0');
const GRACEFUL_STOP = __ENV.GRACEFUL_STOP || '30s';

// Thresholds
const THRESHOLD_P95_DURATION = parseInt(__ENV.THRESHOLD_P95_DURATION || REQUEST_TIMEOUT_MS.toString());
const THRESHOLD_ERROR_RATE = parseFloat(__ENV.THRESHOLD_ERROR_RATE || '0.05');

// =============================================================================
// CUSTOM METRICS
// =============================================================================

const audioFilesUsed = new Counter('audio_files_used');
const transcriptionSuccess = new Rate('transcription_success');
const segmentCount = new Trend('segment_count');
const transcriptionLength = new Trend('transcription_length');
const translationLength = new Trend('translation_length');
const audioFileSize = new Trend('audio_file_size_kb');

// =============================================================================
// AUDIO FILE MANAGEMENT
// =============================================================================

let audioFiles = [];
let audioFileContents = {};
let singleAudioFile = null;
let requestCounter = 0;

// Load audio files list in init stage (required by k6)
if (USE_RANDOM_AUDIO) {
  const listPath = __ENV.AUDIO_FILES_LIST || 'samples/audio-files.json';
  try {
    const content = open(listPath);
    audioFiles = JSON.parse(content);
    if (!Array.isArray(audioFiles) || audioFiles.length === 0) {
      throw new Error('File list is empty or invalid');
    }
    
    console.log(`Loading ${audioFiles.length} audio files into memory...`);
    
    // Preload all audio file contents during init stage (required by k6)
    // All files must be opened in the global init context - k6 doesn't allow
    // opening new files during VU initialization or test execution
    for (const filePath of audioFiles) {
      try {
        const content = open(filePath, 'b');
        // k6 open() with 'b' returns an ArrayBuffer-like object
        // Check if content exists and has byteLength (for ArrayBuffer) or length
        const size = content ? (content.byteLength || content.length) : 0;
        
        if (content && size > 0) {
          audioFileContents[filePath] = content;
        } else {
          console.warn(`  Skipping empty file: ${filePath}`);
        }
      } catch (e) {
        console.warn(`  Failed to load: ${filePath} - ${e.message}`);
      }
    }
    
    // Update audioFiles array to only include successfully loaded files
    audioFiles = Object.keys(audioFileContents);
    
    console.log(`✓ Loaded ${audioFiles.length} audio files successfully`);
    
    // Ensure we have at least some files loaded
    if (audioFiles.length === 0) {
      throw new Error('No audio files could be loaded successfully');
    }
  } catch (error) {
    console.error(`Failed to load audio files list from ${listPath}`);
    console.error(`Error: ${error.message}`);
    console.error('');
    console.error('To fix this:');
    console.error('  1. Ensure you are running from project root directory');
    console.error('  2. Run: ./scripts/generate-audio-list.sh');
    console.error('  3. Or verify samples/audio-files.json exists with relative paths');
    throw new Error('Audio files list not found or invalid');
  }
} else {
  const singleFilePath = __ENV.AUDIO_FILE_PATH || 'samples/sample-audio.wav';
  singleAudioFile = open(singleFilePath, 'b');
}

/**
 * Parse duration string (e.g., "10m", "30s") to seconds
 */
function parseDuration(duration) {
  const match = duration.match(/^(\d+)([smh])$/);
  if (!match) {
    throw new Error(`Invalid duration format: ${duration}`);
  }
  
  const value = parseInt(match[1]);
  const unit = match[2];
  
  switch (unit) {
    case 's': return value;
    case 'm': return value * 60;
    case 'h': return value * 3600;
    default: throw new Error(`Unknown duration unit: ${unit}`);
  }
}

/**
 * Build load test stages with gradual ramp-up
 */
function buildStages(maxVus, rampUp, steady, rampDown, steps) {
  const stages = [];
  const rampUpSeconds = parseDuration(rampUp);
  const stepDuration = rampUpSeconds / steps;
  
  // Gradual ramp up (e.g., 0% -> 25% -> 50% -> 75% -> 100%)
  for (let i = 1; i <= steps; i++) {
    stages.push({
      duration: `${Math.floor(stepDuration)}s`,
      target: Math.floor(maxVus * (i / steps))
    });
  }
  
  // Steady state
  stages.push({
    duration: steady,
    target: maxVus
  });
  
  // Ramp down
  stages.push({
    duration: rampDown,
    target: 0
  });
  
  return stages;
}

/**
 * Pick a random audio file from the list
 */
function pickRandomAudioFile() {
  const randomIndex = Math.floor(Math.random() * audioFiles.length);
  const filePath = audioFiles[randomIndex];
  
  return {
    path: filePath,
    content: audioFileContents[filePath],
    name: filePath.split('/').pop()
  };
}

/**
 * Get the filename for the audio file
 */
function getAudioFileName(filePath) {
  return filePath.split('/').pop();
}

/**
 * Extract speaker ID from LibriSpeech filename (e.g., "121-121726-0000.flac" -> "121")
 */
function extractSpeakerId(filename) {
  const match = filename.match(/^(\d+)-/);
  return match ? match[1] : 'unknown';
}

// =============================================================================
// TEST CONFIGURATION
// =============================================================================

export const options = {
  scenarios: {
    stt_load_test: {
      executor: 'ramping-vus',
      startVUs: START_VUS,
      stages: buildStages(LOAD_CONFIG.vus, LOAD_CONFIG.rampUp, LOAD_CONFIG.steady, LOAD_CONFIG.rampDown, RAMP_STEPS),
      gracefulRampDown: GRACEFUL_STOP,
    },
  },
  
  thresholds: {
    // Response time thresholds
    'http_req_duration': [`p(95)<${THRESHOLD_P95_DURATION}`],
    
    // Error rate threshold
    'http_req_failed': [`rate<${THRESHOLD_ERROR_RATE}`],
    
    // Custom transcription success rate
    'transcription_success': [`rate>${1 - THRESHOLD_ERROR_RATE}`],
  },
  
  // Disable default thresholds for cleaner output
  summaryTrendStats: ['min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  
  // Load balancing configuration for multi-pod testing
  // These options ensure requests are distributed across all pods
  noConnectionReuse: true,        // Disable HTTP keep-alive connections
  noVUConnectionReuse: true,      // VUs don't reuse TCP connections between iterations
  
  // DNS configuration for better load distribution
  // - ttl: 0 means DNS lookup on every request (no caching)
  // - select: 'random' picks a random IP from resolved IPs
  // - This helps when service DNS returns multiple pod IPs
  dns: {
    ttl: '0',           // No DNS caching - resolve on every connection
    select: 'random',   // Randomly select from resolved IPs
    policy: 'any',      // Use both IPv4 and IPv6
  },
};

// =============================================================================
// TEST LIFECYCLE
// =============================================================================

/**
 * Setup - runs once before test starts
 */
export function setup() {
  console.log('================================================');
  console.log('STT API Load Test Configuration');
  console.log('================================================');
  console.log('');
  
  // Display test configuration
  console.log('Test Mode:', TEST_MODE);
  if (TEST_MODES[TEST_MODE]) {
    console.log('Description:', TEST_MODES[TEST_MODE].description);
  }
  console.log('');
  
  console.log('Load Pattern:');
  console.log(`  Max VUs: ${LOAD_CONFIG.vus}`);
  console.log(`  Ramp-up: ${LOAD_CONFIG.rampUp} (${RAMP_STEPS} steps)`);
  console.log(`  Steady: ${LOAD_CONFIG.steady}`);
  console.log(`  Ramp-down: ${LOAD_CONFIG.rampDown}`);
  console.log('');
  
  console.log('API Configuration:');
  console.log(`  Endpoint: ${BASE_URL}${ENDPOINT}`);
  console.log(`  Language: ${LANGUAGE}`);
  console.log(`  Timeout: ${REQUEST_TIMEOUT_MS}ms (${REQUEST_TIMEOUT_MS / 1000}s)`);
  console.log('');
  
  console.log('Audio Configuration:');
  console.log(`  Random audio: ${USE_RANDOM_AUDIO}`);
  
  if (USE_RANDOM_AUDIO) {
    console.log(`  Dataset: LibriSpeech test-clean`);
    console.log(`  Files available: ${audioFiles.length}`);
    
    // Extract unique speakers
    const speakers = new Set(audioFiles.map(f => extractSpeakerId(getAudioFileName(f))));
    console.log(`  Unique speakers: ${speakers.size}`);
  } else {
    const singleFilePath = __ENV.AUDIO_FILE_PATH || 'samples/sample-audio.wav';
    console.log(`  Single file: ${singleFilePath}`);
  }
  
  console.log('');
  console.log('Thresholds:');
  console.log(`  P95 duration: <${THRESHOLD_P95_DURATION}ms`);
  console.log(`  Error rate: <${(THRESHOLD_ERROR_RATE * 100).toFixed(1)}%`);
  console.log('');
  
  console.log('================================================');
  console.log('Starting test...');
  console.log('================================================');
  console.log('');
  
  return {
    startTime: new Date().toISOString(),
    config: LOAD_CONFIG
  };
}

/**
 * Main test function - executed by each VU in each iteration
 */
export default function (data) {
  requestCounter++;
  const logThisRequest = LOG_SAMPLE_RATE > 0 && requestCounter % LOG_SAMPLE_RATE === 0;
  
  // Select audio file
  let audioFile, audioContent, audioFileName;
  
  if (USE_RANDOM_AUDIO) {
    const selected = pickRandomAudioFile();
    audioFile = selected.content;
    audioFileName = selected.name;
    audioFilesUsed.add(1);
  } else {
    audioFile = singleAudioFile;
    audioFileName = 'sample-audio.wav';
  }
  
  // Validate audio file content before proceeding
  const fileSize = audioFile ? (audioFile.byteLength || audioFile.length || 0) : 0;
  if (!audioFile || fileSize === 0) {
    console.error(`Audio file content is invalid or empty: ${audioFileName}`);
    transcriptionSuccess.add(0);
    sleep(THINK_TIME_MIN);
    return; // Skip this iteration
  }
  
  // Track audio file size (approximate from content length)
  const fileSizeKB = fileSize / 1024;
  audioFileSize.add(fileSizeKB);
  
  // Prepare multipart form data
  const formData = new FormData();
  formData.append('audio_file', http.file(audioFile, audioFileName, 'audio/wav'));
  formData.append('language', LANGUAGE);
  
  // Send request
  const startTime = Date.now();
  const response = http.post(
    `${BASE_URL}${ENDPOINT}`,
    formData.body(),
    {
      headers: {
        'Content-Type': `multipart/form-data; boundary=${formData.boundary}`,
      },
      timeout: `${REQUEST_TIMEOUT_MS}ms`,
    }
  );
  const duration = Date.now() - startTime;
  
  // Validate response
  const checks = check(response, {
    'status is 200': (r) => r.status === 200,
    'has original_text': (r) => {
      try {
        const body = r.json();
        return body.original_text !== undefined && body.original_text !== null;
      } catch (e) {
        return false;
      }
    },
    'has translated_text': (r) => {
      try {
        const body = r.json();
        return body.translated_text !== undefined && body.translated_text !== null;
      } catch (e) {
        return false;
      }
    },
    'has segments array': (r) => {
      try {
        const body = r.json();
        return Array.isArray(body.segments);
      } catch (e) {
        return false;
      }
    },
    'segments have required fields': (r) => {
      try {
        const body = r.json();
        if (!Array.isArray(body.segments) || body.segments.length === 0) {
          return true; // Empty segments is valid
        }
        const firstSegment = body.segments[0];
        return firstSegment.text !== undefined &&
               firstSegment.start_time !== undefined &&
               firstSegment.end_time !== undefined &&
               firstSegment.confidence !== undefined;
      } catch (e) {
        return false;
      }
    },
  });
  
  // Track success
  transcriptionSuccess.add(response.status === 200 && checks);
  
  // Extract metrics from successful responses
  if (response.status === 200) {
    try {
      const body = response.json();
      
      // Track transcription metrics
      if (body.original_text) {
        transcriptionLength.add(body.original_text.length);
      }
      
      if (body.translated_text) {
        translationLength.add(body.translated_text.length);
      }
      
      if (body.segments) {
        segmentCount.add(body.segments.length);
      }
      
      // Log sample successful request
      if (logThisRequest) {
        const speakerId = extractSpeakerId(audioFileName);
        console.log(`[${new Date().toISOString()}] ✓ ${audioFileName} (speaker: ${speakerId}, ${fileSizeKB.toFixed(1)}KB) - ${duration}ms - ${body.segments ? body.segments.length : 0} segments`);
      }
    } catch (error) {
      if (VERBOSE_ERRORS) {
        console.error(`Failed to parse response JSON: ${error.message}`);
      }
    }
  } else {
    // Log errors
    if (VERBOSE_ERRORS || logThisRequest) {
      const speakerId = extractSpeakerId(audioFileName);
      console.error(`[${new Date().toISOString()}] ✗ ${audioFileName} (speaker: ${speakerId}, ${fileSizeKB.toFixed(1)}KB) - Status ${response.status} - ${duration}ms`);
      if (VERBOSE_ERRORS && response.body) {
        try {
          const errorBody = response.json();
          console.error(`  Error: ${JSON.stringify(errorBody)}`);
        } catch (e) {
          console.error(`  Body: ${response.body.substring(0, 200)}`);
        }
      }
    }
  }
  
  // Think time between requests
  const thinkTime = THINK_TIME_MIN + Math.random() * (THINK_TIME_MAX - THINK_TIME_MIN);
  sleep(thinkTime);
}

/**
 * Teardown - runs once after test completes
 */
export function teardown(data) {
  console.log('');
  console.log('================================================');
  console.log('Load Test Completed');
  console.log('================================================');
  console.log('');
  console.log('Test started:', data.startTime);
  console.log('Test ended:', new Date().toISOString());
  console.log('');
  console.log('Review detailed results above.');
  console.log('');
}
