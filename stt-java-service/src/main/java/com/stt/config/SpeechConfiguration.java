package com.stt.config;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredentialBuilder;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Configuration for Azure Speech SDK using RBAC authentication.
 * Uses DefaultAzureCredential for token-based authentication.
 */
@Component
public class SpeechConfiguration {

    private static final Logger log = LoggerFactory.getLogger(SpeechConfiguration.class);
    private static final String COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default";

    @Value("${stt.azure.speech.region:swedencentral}")
    private String region;

    private final TokenCredential credential;

    public SpeechConfiguration() {
        // Initialize DefaultAzureCredential for RBAC authentication
        this.credential = new DefaultAzureCredentialBuilder().build();
        log.info("Initialized DefaultAzureCredential for Speech SDK");
    }

    /**
     * Get a fresh access token for Azure Speech Service.
     * Called per request to ensure valid token (no caching for baseline testing).
     *
     * @return Access token string
     */
    public String getAccessToken() {
        TokenRequestContext context = new TokenRequestContext()
                .addScopes(COGNITIVE_SERVICES_SCOPE);
        
        AccessToken token = credential.getToken(context).block();
        if (token == null) {
            throw new RuntimeException("Failed to obtain access token for Speech Service");
        }
        
        log.debug("Obtained access token, expires at: {}", token.getExpiresAt());
        return token.getToken();
    }

    /**
     * Get the Azure Speech region.
     *
     * @return Region string (e.g., "swedencentral")
     */
    public String getRegion() {
        return region;
    }
}
