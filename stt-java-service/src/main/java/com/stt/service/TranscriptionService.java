package com.stt.service;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Semaphore;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import com.microsoft.cognitiveservices.speech.AutoDetectSourceLanguageConfig;
import com.microsoft.cognitiveservices.speech.CancellationReason;
import com.microsoft.cognitiveservices.speech.PropertyId;
import com.microsoft.cognitiveservices.speech.ResultReason;
import com.microsoft.cognitiveservices.speech.SpeechConfig;
import com.microsoft.cognitiveservices.speech.audio.AudioConfig;
import com.microsoft.cognitiveservices.speech.transcription.ConversationTranscriber;
import com.stt.config.SpeechConfiguration;
import com.stt.model.TranscriptionResponse;
import com.stt.model.TranscriptionSegment;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;

/**
 * Transcription service using Azure Speech SDK.
 * Basic implementation without optimizations for memory leak investigation.
 */
@Service
public class TranscriptionService {

    // Language mapping (matches Python service)
    private static final java.util.Map<String, String> LANGUAGE_MAP = java.util.Map.ofEntries(
            java.util.Map.entry("en", "en-US"),
            java.util.Map.entry("en-us", "en-US"),
            java.util.Map.entry("en-gb", "en-GB"),
            java.util.Map.entry("ar", "ar-SA"),
            java.util.Map.entry("ar-ae", "ar-AE"),
            java.util.Map.entry("ar-sa", "ar-SA"),
            java.util.Map.entry("auto", null)
    );

    private static final Logger log = LoggerFactory.getLogger(TranscriptionService.class);

    private final SpeechConfiguration speechConfiguration;
    private final Counter transcriptionCounter;
    private final Counter errorCounter;
    private final Timer transcriptionTimer;

    public TranscriptionService(SpeechConfiguration speechConfiguration, MeterRegistry meterRegistry) {
        this.speechConfiguration = speechConfiguration;
        
        // Register metrics
        this.transcriptionCounter = Counter.builder("stt_transcription_requests_total")
                .description("Total number of transcription requests")
                .tag("service", "java")
                .register(meterRegistry);
        
        this.errorCounter = Counter.builder("stt_transcription_errors_total")
                .description("Total number of transcription errors")
                .tag("service", "java")
                .register(meterRegistry);
        
        this.transcriptionTimer = Timer.builder("stt_transcription_duration_seconds")
                .description("Transcription processing duration")
                .tag("service", "java")
                .register(meterRegistry);
    }

    /**
     * Transcribe audio data using Azure Speech SDK.
     * Basic implementation - creates new resources per request (no pooling).
     *
     * @param audioData Audio file bytes (WAV format)
     * @param language Source language code (e.g., "en-US")
     * @return TranscriptionResponse with results
     */
    public TranscriptionResponse transcribe(byte[] audioData, String language) {
        transcriptionCounter.increment();
        long startTime = System.currentTimeMillis();
        
        File tempFile = null;
        SpeechConfig speechConfig = null;
        AudioConfig audioConfig = null;
        ConversationTranscriber transcriber = null;

        try {
            // Write audio to temp file (SDK requires file input)
            tempFile = Files.createTempFile("audio-", ".wav").toFile();
            try (FileOutputStream fos = new FileOutputStream(tempFile)) {
                fos.write(audioData);
            }
            log.info("Created temp audio file: {} ({} bytes)", tempFile.getName(), audioData.length);

            // Get fresh access token (no caching for baseline testing)
            String accessToken = speechConfiguration.getAccessToken();

            // Create SpeechConfig - use endpoint for AI Foundry, region otherwise
            // This matches Python's approach for custom subdomain authentication
            if (speechConfiguration.hasResourceName()) {
                String endpoint = speechConfiguration.getEndpoint();
                log.info("Using endpoint-based auth: {}", endpoint);
                speechConfig = SpeechConfig.fromEndpoint(java.net.URI.create(endpoint));
                speechConfig.setAuthorizationToken(accessToken);
            } else {
                String region = speechConfiguration.getRegion();
                log.info("Using region-based auth: {}", region);
                speechConfig = SpeechConfig.fromAuthorizationToken(accessToken, region);
            }
            // Enable diarization
            speechConfig.setProperty(PropertyId.SpeechServiceResponse_DiarizeIntermediateResults, "true");

            // Create AudioConfig from temp file
            audioConfig = AudioConfig.fromWavFileInput(tempFile.getAbsolutePath());

            // Map language code
            String azureLanguage = LANGUAGE_MAP.getOrDefault(language.toLowerCase(), language);

            // Create ConversationTranscriber with or without auto-detection
            AutoDetectSourceLanguageConfig autoDetectConfig = null;
            if (azureLanguage == null || "auto".equalsIgnoreCase(language)) {
                // Auto-detection mode with continuous language identification
                log.info("Using auto-detection for transcription language");
                speechConfig.setProperty(PropertyId.SpeechServiceConnection_LanguageIdMode, "Continuous");
                autoDetectConfig = AutoDetectSourceLanguageConfig.fromLanguages(
                        java.util.Arrays.asList("ar-AE", "ar-SA", "en-US", "en-GB"));
                transcriber = new ConversationTranscriber(speechConfig, autoDetectConfig, audioConfig);
            } else {
                // Specified language mode
                log.info("Using specified language for transcription: {}", azureLanguage);
                speechConfig.setSpeechRecognitionLanguage(azureLanguage);
                transcriber = new ConversationTranscriber(speechConfig, audioConfig);
            }

            // Collect transcription results
            List<TranscriptionSegment> segments = Collections.synchronizedList(new ArrayList<>());
            Set<String> speakers = Collections.synchronizedSet(new HashSet<>());
            Semaphore stopSemaphore = new Semaphore(0);
            List<Exception> errors = Collections.synchronizedList(new ArrayList<>());

            long transcriptionStartTime = System.currentTimeMillis();

            // Event handlers
            transcriber.transcribed.addEventListener((s, e) -> {
                if (e.getResult().getReason() == ResultReason.RecognizedSpeech) {
                    String text = e.getResult().getText();
                    String speakerId = e.getResult().getSpeakerId();
                    
                    log.debug("TRANSCRIBED: {} (Speaker: {})", text, speakerId);
                    
                    if (speakerId != null && !speakerId.isEmpty() && !speakerId.equals("Unknown")) {
                        speakers.add(speakerId);
                    }

                    // Create segment (timing info not available in basic API)
                    TranscriptionSegment segment = new TranscriptionSegment(
                            text,
                            0.0,  // Start time not available in basic transcription
                            0.0,  // End time not available in basic transcription
                            0.9,  // Default confidence (not exposed in this API)
                            speakerId,
                            language
                    );
                    segments.add(segment);
                }
            });

            transcriber.canceled.addEventListener((s, e) -> {
                log.warn("CANCELED: Reason={}", e.getReason());
                if (e.getReason() == CancellationReason.Error) {
                    log.error("CANCELED: ErrorCode={}, Details={}", 
                            e.getErrorCode(), e.getErrorDetails());
                    errors.add(new RuntimeException("Transcription canceled: " + e.getErrorDetails()));
                }
                stopSemaphore.release();
            });

            transcriber.sessionStopped.addEventListener((s, e) -> {
                log.info("Session stopped");
                stopSemaphore.release();
            });

            // Start transcription
            log.info("Starting transcription for {} bytes of audio", audioData.length);
            transcriber.startTranscribingAsync().get();

            // Wait for completion
            stopSemaphore.acquire();

            // Stop transcription
            transcriber.stopTranscribingAsync().get();

            long transcriptionEndTime = System.currentTimeMillis();
            double transcriptionTimeSeconds = (transcriptionEndTime - transcriptionStartTime) / 1000.0;

            // Check for errors
            if (!errors.isEmpty()) {
                errorCounter.increment();
                throw new RuntimeException("Transcription failed", errors.get(0));
            }

            // Build response
            String fullText = segments.stream()
                    .map(TranscriptionSegment::getText)
                    .reduce((a, b) -> a + " " + b)
                    .orElse("");

            double processingTimeSeconds = (System.currentTimeMillis() - startTime) / 1000.0;

            TranscriptionResponse response = new TranscriptionResponse()
                    .withOriginalText(fullText)
                    .withTranslatedText(fullText)  // No translation in basic implementation
                    .withOriginalLanguage(language)
                    .withSegments(segments)
                    .withSpeakerCount(speakers.isEmpty() ? null : speakers.size())
                    .withAudioDurationSeconds(estimateAudioDuration(audioData.length))
                    .withProcessingTimeSeconds(processingTimeSeconds)
                    .withTranscriptionTimeSeconds(transcriptionTimeSeconds)
                    .withTranslationTimeSeconds(0.0)
                    .withConfidenceAverage(0.9);

            log.info("Transcription completed: {} segments, {} speakers, {:.2f}s processing time",
                    segments.size(), speakers.size(), processingTimeSeconds);

            // Record timer
            transcriptionTimer.record(java.time.Duration.ofMillis(System.currentTimeMillis() - startTime));

            return response;

        } catch (Exception e) {
            errorCounter.increment();
            log.error("Transcription error", e);
            throw new RuntimeException("Transcription failed: " + e.getMessage(), e);
        } finally {
            // Explicit resource cleanup (important for memory leak investigation)
            if (transcriber != null) {
                try {
                    transcriber.close();
                    log.debug("Closed ConversationTranscriber");
                } catch (Exception e) {
                    log.warn("Error closing transcriber", e);
                }
            }
            if (audioConfig != null) {
                try {
                    audioConfig.close();
                    log.debug("Closed AudioConfig");
                } catch (Exception e) {
                    log.warn("Error closing audioConfig", e);
                }
            }
            if (speechConfig != null) {
                try {
                    speechConfig.close();
                    log.debug("Closed SpeechConfig");
                } catch (Exception e) {
                    log.warn("Error closing speechConfig", e);
                }
            }
            if (tempFile != null && tempFile.exists()) {
                if (tempFile.delete()) {
                    log.debug("Deleted temp file: {}", tempFile.getName());
                } else {
                    log.warn("Failed to delete temp file: {}", tempFile.getName());
                }
            }
        }
    }

    /**
     * Estimate audio duration based on file size.
     * Assumes 16kHz, 16-bit mono WAV (32000 bytes/second).
     */
    private double estimateAudioDuration(int fileSize) {
        // WAV header is ~44 bytes, rest is audio data
        int audioBytes = Math.max(0, fileSize - 44);
        // 16kHz * 2 bytes per sample * 1 channel = 32000 bytes/second
        return audioBytes / 32000.0;
    }
}
