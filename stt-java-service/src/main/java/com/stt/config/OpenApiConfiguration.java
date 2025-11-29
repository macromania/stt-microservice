package com.stt.config;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.info.Contact;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * OpenAPI/Swagger configuration.
 */
@Configuration
public class OpenApiConfiguration {

    @Bean
    public OpenAPI customOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("STT Java Service API")
                        .version("0.1.0")
                        .description("Speech-to-Text microservice using Azure Speech SDK for Java. " +
                                "This service provides real-time transcription of audio files.")
                        .contact(new Contact()
                                .name("STT Service")
                                .url("https://github.com/macromania/stt-microservice")));
    }
}
