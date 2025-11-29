package com.stt;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * STT Java Service - Speech-to-Text microservice using Azure Speech SDK.
 * 
 * This is a basic implementation for memory leak investigation,
 * comparing Java SDK behavior against Python SDK.
 */
@SpringBootApplication
public class SttJavaApplication {

    public static void main(String[] args) {
        SpringApplication.run(SttJavaApplication.class, args);
    }
}
