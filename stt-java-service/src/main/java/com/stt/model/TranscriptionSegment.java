package com.stt.model;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * A single segment of transcription with timing and speaker info.
 * Matches Python TranscriptionSegment model.
 */
public class TranscriptionSegment {

    @JsonProperty("text")
    private String text;

    @JsonProperty("start_time")
    private double startTime;

    @JsonProperty("end_time")
    private double endTime;

    @JsonProperty("confidence")
    private double confidence;

    @JsonProperty("speaker_id")
    private String speakerId;

    @JsonProperty("language")
    private String language;

    public TranscriptionSegment() {
    }

    public TranscriptionSegment(String text, double startTime, double endTime, 
                                double confidence, String speakerId, String language) {
        this.text = text;
        this.startTime = startTime;
        this.endTime = endTime;
        this.confidence = confidence;
        this.speakerId = speakerId;
        this.language = language;
    }

    // Getters and Setters
    public String getText() {
        return text;
    }

    public void setText(String text) {
        this.text = text;
    }

    public double getStartTime() {
        return startTime;
    }

    public void setStartTime(double startTime) {
        this.startTime = startTime;
    }

    public double getEndTime() {
        return endTime;
    }

    public void setEndTime(double endTime) {
        this.endTime = endTime;
    }

    public double getConfidence() {
        return confidence;
    }

    public void setConfidence(double confidence) {
        this.confidence = confidence;
    }

    public String getSpeakerId() {
        return speakerId;
    }

    public void setSpeakerId(String speakerId) {
        this.speakerId = speakerId;
    }

    public String getLanguage() {
        return language;
    }

    public void setLanguage(String language) {
        this.language = language;
    }
}
