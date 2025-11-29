package com.stt.controller;

import com.stt.model.TranscriptionResponse;
import com.stt.service.TranscriptionService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.Map;

/**
 * REST controller for transcription endpoints.
 * Matches the Python service API for comparison testing.
 */
@RestController
@RequestMapping("/api/v2")
public class TranscriptionController {

    private static final Logger log = LoggerFactory.getLogger(TranscriptionController.class);

    private final TranscriptionService transcriptionService;

    public TranscriptionController(TranscriptionService transcriptionService) {
        this.transcriptionService = transcriptionService;
    }

    /**
     * Transcribe an audio file.
     *
     * @param file Audio file (WAV format)
     * @param language Source language code (default: en-US)
     * @return Transcription response
     */
    @PostMapping(value = "/transcribe", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<TranscriptionResponse> transcribe(
            @RequestParam("file") MultipartFile file,
            @RequestParam(value = "language", defaultValue = "en-US") String language) {
        
        log.info("Received transcription request: filename={}, size={}, language={}",
                file.getOriginalFilename(), file.getSize(), language);

        try {
            byte[] audioData = file.getBytes();
            TranscriptionResponse response = transcriptionService.transcribe(audioData, language);
            return ResponseEntity.ok(response);
        } catch (IOException e) {
            log.error("Failed to read uploaded file", e);
            return ResponseEntity.badRequest().build();
        } catch (Exception e) {
            log.error("Transcription failed", e);
            return ResponseEntity.internalServerError().build();
        }
    }

    /**
     * Health check endpoint.
     */
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of(
                "status", "healthy",
                "service", "stt-java-service"
        ));
    }
}
