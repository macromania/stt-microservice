package com.stt.controller;

import java.io.IOException;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import com.stt.model.TranscriptionResponse;
import com.stt.service.TranscriptionService;

import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.tags.Tag;

/**
 * REST controller for transcription endpoints.
 * Matches the Python service API for comparison testing.
 */
@RestController
@RequestMapping("/api/v2")
@Tag(name = "Transcription", description = "Speech-to-Text transcription API")
public class TranscriptionController {

    private static final Logger log = LoggerFactory.getLogger(TranscriptionController.class);

    private final TranscriptionService transcriptionService;

    public TranscriptionController(TranscriptionService transcriptionService) {
        this.transcriptionService = transcriptionService;
    }

    /**
     * Transcribe an audio file.
     *
     * @param audioFile Audio file (WAV format)
     * @param language Source language code (default: auto)
     * @return Transcription response
     */
    @Operation(
            summary = "Transcribe audio file",
            description = "Upload a WAV audio file to transcribe it to text using Azure Speech SDK",
            responses = {
                    @ApiResponse(responseCode = "200", description = "Transcription successful",
                            content = @Content(schema = @Schema(implementation = TranscriptionResponse.class))),
                    @ApiResponse(responseCode = "400", description = "Invalid file or request"),
                    @ApiResponse(responseCode = "500", description = "Transcription failed")
            }
    )
    @PostMapping(value = "/transcriptions", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<TranscriptionResponse> transcribe(
            @Parameter(description = "Audio file (WAV format)") @RequestParam("audio_file") MultipartFile audioFile,
            @Parameter(description = "Source language code or 'auto' for detection") @RequestParam(value = "language", defaultValue = "auto") String language) {
        
        log.info("Received transcription request: filename={}, size={}, language={}",
                audioFile.getOriginalFilename(), audioFile.getSize(), language);

        try {
            byte[] audioData = audioFile.getBytes();
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
    @Operation(summary = "Health check", description = "Check if the service is healthy")
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of(
                "status", "healthy",
                "service", "stt-java-service"
        ));
    }
}
