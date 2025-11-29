package com.stt.model;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.Instant;
import java.util.List;

/**
 * Response model for transcription.
 * Matches Python TranscriptionResponse model.
 */
public class TranscriptionResponse {

    @JsonProperty("original_text")
    private String originalText;

    @JsonProperty("translated_text")
    private String translatedText;

    @JsonProperty("original_language")
    private String originalLanguage;

    @JsonProperty("segments")
    private List<TranscriptionSegment> segments;

    @JsonProperty("speaker_count")
    private Integer speakerCount;

    @JsonProperty("audio_duration_seconds")
    private double audioDurationSeconds;

    @JsonProperty("processing_time_seconds")
    private double processingTimeSeconds;

    @JsonProperty("transcription_time_seconds")
    private double transcriptionTimeSeconds;

    @JsonProperty("translation_time_seconds")
    private double translationTimeSeconds;

    @JsonProperty("confidence_average")
    private double confidenceAverage;

    @JsonProperty("timestamp")
    private Instant timestamp;

    public TranscriptionResponse() {
        this.timestamp = Instant.now();
    }

    // Builder-style setters for fluent API
    public TranscriptionResponse withOriginalText(String originalText) {
        this.originalText = originalText;
        return this;
    }

    public TranscriptionResponse withTranslatedText(String translatedText) {
        this.translatedText = translatedText;
        return this;
    }

    public TranscriptionResponse withOriginalLanguage(String originalLanguage) {
        this.originalLanguage = originalLanguage;
        return this;
    }

    public TranscriptionResponse withSegments(List<TranscriptionSegment> segments) {
        this.segments = segments;
        return this;
    }

    public TranscriptionResponse withSpeakerCount(Integer speakerCount) {
        this.speakerCount = speakerCount;
        return this;
    }

    public TranscriptionResponse withAudioDurationSeconds(double audioDurationSeconds) {
        this.audioDurationSeconds = audioDurationSeconds;
        return this;
    }

    public TranscriptionResponse withProcessingTimeSeconds(double processingTimeSeconds) {
        this.processingTimeSeconds = processingTimeSeconds;
        return this;
    }

    public TranscriptionResponse withTranscriptionTimeSeconds(double transcriptionTimeSeconds) {
        this.transcriptionTimeSeconds = transcriptionTimeSeconds;
        return this;
    }

    public TranscriptionResponse withTranslationTimeSeconds(double translationTimeSeconds) {
        this.translationTimeSeconds = translationTimeSeconds;
        return this;
    }

    public TranscriptionResponse withConfidenceAverage(double confidenceAverage) {
        this.confidenceAverage = confidenceAverage;
        return this;
    }

    // Standard Getters and Setters
    public String getOriginalText() {
        return originalText;
    }

    public void setOriginalText(String originalText) {
        this.originalText = originalText;
    }

    public String getTranslatedText() {
        return translatedText;
    }

    public void setTranslatedText(String translatedText) {
        this.translatedText = translatedText;
    }

    public String getOriginalLanguage() {
        return originalLanguage;
    }

    public void setOriginalLanguage(String originalLanguage) {
        this.originalLanguage = originalLanguage;
    }

    public List<TranscriptionSegment> getSegments() {
        return segments;
    }

    public void setSegments(List<TranscriptionSegment> segments) {
        this.segments = segments;
    }

    public Integer getSpeakerCount() {
        return speakerCount;
    }

    public void setSpeakerCount(Integer speakerCount) {
        this.speakerCount = speakerCount;
    }

    public double getAudioDurationSeconds() {
        return audioDurationSeconds;
    }

    public void setAudioDurationSeconds(double audioDurationSeconds) {
        this.audioDurationSeconds = audioDurationSeconds;
    }

    public double getProcessingTimeSeconds() {
        return processingTimeSeconds;
    }

    public void setProcessingTimeSeconds(double processingTimeSeconds) {
        this.processingTimeSeconds = processingTimeSeconds;
    }

    public double getTranscriptionTimeSeconds() {
        return transcriptionTimeSeconds;
    }

    public void setTranscriptionTimeSeconds(double transcriptionTimeSeconds) {
        this.transcriptionTimeSeconds = transcriptionTimeSeconds;
    }

    public double getTranslationTimeSeconds() {
        return translationTimeSeconds;
    }

    public void setTranslationTimeSeconds(double translationTimeSeconds) {
        this.translationTimeSeconds = translationTimeSeconds;
    }

    public double getConfidenceAverage() {
        return confidenceAverage;
    }

    public void setConfidenceAverage(double confidenceAverage) {
        this.confidenceAverage = confidenceAverage;
    }

    public Instant getTimestamp() {
        return timestamp;
    }

    public void setTimestamp(Instant timestamp) {
        this.timestamp = timestamp;
    }
}
