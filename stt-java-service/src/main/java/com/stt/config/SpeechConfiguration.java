package com.stt.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenCredential;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredentialBuilder;

/**
 * Configuration for Azure Speech SDK using RBAC authentication.
 * 
 * Authentication priority:
 * 1. AZURE_ACCESS_TOKEN environment variable (for K8s deployments with pre-fetched token)
 * 2. DefaultAzureCredential (for local development with az login, managed identity, etc.)
 */
@Component
public class SpeechConfiguration {

    private static final Logger log = LoggerFactory.getLogger(SpeechConfiguration.class);
    private static final String COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default";

    @Value("${stt.azure.speech.region:swedencentral}")
    private String region;

    @Value("${STT_AZURE_SPEECH_RESOURCE_NAME:#{null}}")
    private String resourceName;

    @Value("${AZURE_ACCESS_TOKEN:#{null}}")
    private String preConfiguredToken;

    private final TokenCredential credential;

    public SpeechConfiguration() {
        // Initialize DefaultAzureCredential for RBAC authentication (fallback)
        this.credential = new DefaultAzureCredentialBuilder().build();
        log.info("Initialized DefaultAzureCredential for Speech SDK");
    }

    /**
     * Get a fresh access token for Azure Speech Service.
     * 
     * First checks for AZURE_ACCESS_TOKEN env var (K8s deployments),
     * then falls back to DefaultAzureCredential.
     *
     * @return Access token string
     */
    public String getAccessToken() {
        // Check for pre-configured token first (K8s environment)
        if (preConfiguredToken != null && !preConfiguredToken.isBlank()) {
            log.debug("Using AZURE_ACCESS_TOKEN from environment");
            return preConfiguredToken;
        }

        // Fall back to DefaultAzureCredential
        TokenRequestContext context = new TokenRequestContext()
                .addScopes(COGNITIVE_SERVICES_SCOPE);
        
        AccessToken token = credential.getToken(context).block();
        if (token == null) {
            throw new RuntimeException("Failed to obtain access token for Speech Service");
        }
        
        log.debug("Obtained access token via DefaultAzureCredential, expires at: {}", token.getExpiresAt());
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

    /**
     * Get the Azure Speech resource name (custom subdomain for AI Foundry).
     *
     * @return Resource name or null if not configured
     */
    public String getResourceName() {
        return resourceName;
    }

    /**
     * Check if using AI Foundry (custom subdomain) endpoint.
     *
     * @return true if resource name is configured
     */
    public boolean hasResourceName() {
        return resourceName != null && !resourceName.isBlank();
    }

    /**
     * Get the endpoint URL for AI Foundry resources.
     *
     * @return Endpoint URL or null if not using AI Foundry
     */
    public String getEndpoint() {
        if (hasResourceName()) {
            return "https://" + resourceName + ".cognitiveservices.azure.com/";
        }
        return null;
    }
}
