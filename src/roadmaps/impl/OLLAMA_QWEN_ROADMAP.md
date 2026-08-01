# Ollama + Qwen : Roadmap d'intégration IA Locale

> **Contexte** : Kovixel traite des documents professionnels potentiellement confidentiels
> (contrats, données médicales, financières). La confidentialité des documents est un impératif.
> SmallPDF et iLovePDF envoient tout au cloud — Kovixel se différencie en proposant
> un traitement **local par défaut**, avec un opt-in cloud explicite pour les PRO qui l'acceptent.
>
> **Décisions architecturales définitives** :
> - **Embeddings** : toujours Ollama `nomic-embed-text` — jamais externalisés, pour personne
> - **Chat** : Ollama par défaut pour tous ; PRO/Enterprise peuvent choisir Claude/Gemini
>   via un réglage explicite à l'inscription (modifiable dans les paramètres)
> - **Différenciation par plan** : modèle Ollama plus puissant selon le forfait
> - **Anonymes** : toujours local, modèle léger, accès très limité
>
> **Argument marché** : "Contrairement à SmallPDF, vos documents ne quittent jamais nos serveurs
> — ni pour le résumé, ni pour la recherche Q&A." (vrai même pour les embeddings)
>
> **Instructions** : Exécuter les prompts **dans l'ordre**.
> Chaque prompt est autonome et cite les fichiers à modifier/créer.

---

## Vue d'ensemble de l'architecture cible

```
Requête IA (résumé / Q&A / extraction)
         │
         ▼
   AiRoutingService.resolve(userId)
         │
         ├─ processingMode=LOCAL (défaut tous plans)
         │       │
         │       ├─ Anonyme    → OllamaAiService + qwen3:1.7b   (rapide, limité)
         │       ├─ FREE       → OllamaAiService + qwen3:7b     (bon, local ✅)
         │       ├─ PRO        → OllamaAiService + qwen2.5:14b  (excellent, local ✅)
         │       └─ ENTERPRISE → OllamaAiService + qwen2.5:14b  (illimité, local ✅)
         │
         └─ processingMode=CLOUD (opt-in PRO/ENTERPRISE uniquement, consentement signé)
                 │
                 ├─ ClaudeAiService   (Anthropic API, qualité max)
                 └─ GeminiService     (Google AI, alternatif)
                       │
                       └─ Fallback si API DOWN → OllamaAiService (local)

EMBEDDINGS — toujours locaux, pour tous les plans, sans exception :
   ┌─────────────────────────────────────────────────────────────────┐
   │  Ollama nomic-embed-text → pgvector vector(768)                 │
   │  Ingestion RAG · Recherche sémantique Q&A                       │
   │  Aucun document vectorisé n'est envoyé à un service tiers       │
   │  Même si l'utilisateur a activé "IA Cloud" pour le chat         │
   └─────────────────────────────────────────────────────────────────┘

Infrastructure VPS 24 Go RAM / 160 Go SSD :
   Phase 1 : qwen3:7b pour tous + nomic-embed-text           → ~8.5 Go RAM ✅
   Phase 2 : qwen2.5:14b pour PRO (nœud dédié ou GPU)        → ~13 Go RAM ⚠️
   Phase 3 : scaling horizontal (Kubernetes + Ollama pods)    → selon trafic
   Stockage : S3 externe dès Phase 1 (OVH/Scaleway/R2)       → SSD 160 Go pour DB seule
```

## Mapping plan → modèle Ollama

| Plan | Modèle chat | RAM Ollama | Vitesse CPU | Quota résumés |
|------|-------------|-----------|-------------|---------------|
| Anonyme | `qwen3:1.7b` | 3 Go | ~15 tok/s | Très limité |
| FREE | `qwen3:7b` | 5 Go | ~5 tok/s | 5/jour |
| PRO | `qwen2.5:14b` | 9 Go | ~2 tok/s | 100/jour |
| ENTERPRISE | `qwen2.5:14b` | 9 Go | ~2 tok/s | Illimité |
| PRO/ENT cloud | `claude-sonnet-4-6` | 0 (API) | ~200 tok/s | Selon plan |

> Tous les plans utilisent `nomic-embed-text` pour les embeddings (0.5 Go RAM, partagé).

---

## Comparatif modèles chat Ollama

| Modèle | Taille | RAM | Vitesse CPU | Qualité FR | Plan Kovixel |
|--------|--------|-----|-------------|------------|--------------|
| `qwen3:1.7b` | 1.2 Go | 3 Go | ~15 tok/s | ★★★☆☆ | Anonyme — accès limité |
| `qwen3:7b` ⭐ | 4.7 Go | 5 Go | ~5 tok/s | ★★★★☆ | FREE — bon équilibre |
| `qwen2.5:14b` ⭐⭐ | 8.3 Go | 9 Go | ~2 tok/s | ★★★★★ | PRO/ENTERPRISE — excellent |
| `nomic-embed-text` | 0.3 Go | 0.5 Go | ~50 emb/s | MTEB 62.4 | Embeddings — tous plans |

> **Phase 1** : démarrer avec `qwen3:7b` pour FREE et PRO (VPS 24 Go suffit).
> **Phase 2** : activer `qwen2.5:14b` pour PRO quand la base le justifie (nœud GPU ou 16 Go RAM dédié).

## Comparatif providers (architecture finale)

| Provider | Modèle | Quand | RGPD | Coût | Qualité |
|----------|--------|-------|------|------|---------|
| Ollama | `qwen3:1.7b` | Anonyme (toujours) | ✅ | 0€ | ★★★☆☆ |
| Ollama | `qwen3:7b` | FREE (toujours) | ✅ | 0€ | ★★★★☆ |
| Ollama | `qwen2.5:14b` | PRO/ENT mode local | ✅ | 0€ | ★★★★★ |
| Claude | `claude-sonnet-4-6` | PRO/ENT mode cloud (opt-in) | ⚠️ | $$ | ★★★★★ |
| Gemini | `gemini-2.5-flash` | PRO/ENT mode cloud (opt-in) | ⚠️ | $ | ★★★★☆ |
| Ollama | `nomic-embed-text` | Embeddings — TOUS plans | ✅ | 0€ | MTEB 62.4 |

> ⚠️ Claude/Gemini = données traitées par Anthropic/Google. Uniquement si l'utilisateur a activé
> "Mode IA cloud" dans ses paramètres après consentement explicite. Embeddings restent locaux même dans ce cas.

---

## PROMPT 1 — Dépendances Maven + Configuration

**Fichiers à modifier :**
- `pom.xml`
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`

```
Dans pom.xml, ajoute la dépendance Spring AI Ollama juste après le bloc spring-ai-starter-model-anthropic :

    <!-- Spring AI — Ollama (IA locale : Qwen, Llama, Mistral…) -->
    <dependency>
        <groupId>org.springframework.ai</groupId>
        <artifactId>spring-ai-starter-model-ollama</artifactId>
        <version>${spring-ai.version}</version>
    </dependency>

Dans application.yml, ajoute la section suivante dans kovixel: (après kovixel.ai.active-provider) :

kovixel:
  ai:
    active-provider: claude          # claude | gemini | ollama
    ollama:
      # URL du service Ollama (Docker en prod, localhost en dev)
      base-url: ${OLLAMA_URL:http://localhost:11434}
      # Modèle de chat par défaut
      model: ${OLLAMA_MODEL:qwen3:7b}
      # Modèle d'embedding local (alternative à OpenAI)
      embedding-model: ${OLLAMA_EMBEDDING_MODEL:nomic-embed-text}
      # Timeout des appels Ollama en secondes
      timeout-seconds: 120
      # Nombre max de tokens générés
      max-tokens: 4096
      # Température (0.0 = déterministe, 1.0 = créatif)
      temperature: 0.3
      # Taille de la fenêtre contexte (num_ctx en Ollama)
      context-window: 8192
      # Activer le fallback vers Claude si Ollama est indisponible
      fallback-enabled: true
      # Délai d'attente max pour vérifier si Ollama est UP (health check)
      health-check-timeout-ms: 3000
      # Activer les embeddings locaux (nomic-embed-text) — désactiver si RAM limitée
      local-embeddings-enabled: false

Dans application-dev.yml, ajoute sous kovixel.ai :

kovixel:
  ai:
    active-provider: ollama          # Utiliser Ollama en dev (0 coût, offline)
    ollama:
      base-url: http://localhost:11434
      model: qwen3:7b
      timeout-seconds: 180           # Plus long en dev (CPU sans GPU)
      fallback-enabled: true         # Fallback Claude si Ollama non démarré

Ajoute aussi dans application-dev.yml (section spring.ai) :
  ai:
    ollama:
      base-url: ${OLLAMA_URL:http://localhost:11434}
      chat:
        enabled: true
        options:
          model: qwen3:7b
          temperature: 0.3
          num-ctx: 8192

Et dans spring.autoconfigure.exclude, ajoute (si Ollama actif, pour éviter les conflits) :
  # NB : la condition sera gérée par @ConditionalOnProperty dans OllamaAiService,
  #      pas besoin d'exclure les autres auto-configurations.
```

---

## PROMPT 2 — OllamaProperties + OllamaHealthChecker

**Fichiers à créer :**
- `src/main/java/com/kovixel/ai/provider/ollama/OllamaProperties.java`
- `src/main/java/com/kovixel/ai/provider/ollama/OllamaHealthChecker.java`

```
────────────────────────────────────────────────────────────────────
OllamaProperties.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.provider.ollama;

@Data
@Component
@ConfigurationProperties(prefix = "kovixel.ai.ollama")
public class OllamaProperties {

    /** URL HTTP du service Ollama. Défaut : http://localhost:11434 */
    private String baseUrl = "http://localhost:11434";

    /** Modèle de chat (ex: qwen3:7b, qwen2.5:14b, llama3.1:8b). */
    private String model = "qwen3:7b";

    /** Modèle d'embedding local (ex: nomic-embed-text). */
    private String embeddingModel = "nomic-embed-text";

    /** Timeout des appels HTTP Ollama en secondes. */
    private int timeoutSeconds = 120;

    /** Nombre max de tokens générés par réponse. */
    private int maxTokens = 4096;

    /** Température de génération [0.0–1.0]. */
    private double temperature = 0.3;

    /** Taille de la fenêtre contexte (num_ctx). */
    private int contextWindow = 8192;

    /** Active le fallback vers Claude si Ollama est indisponible. */
    private boolean fallbackEnabled = true;

    /** Timeout du health check pour savoir si Ollama est UP (ms). */
    private int healthCheckTimeoutMs = 3000;

    /** Active les embeddings locaux via nomic-embed-text. */
    private boolean localEmbeddingsEnabled = false;
}

────────────────────────────────────────────────────────────────────
OllamaHealthChecker.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.provider.ollama;

/**
 * Vérifie la disponibilité du service Ollama via GET /api/tags.
 *
 * <p>Résultat mis en cache (TTL 30s) pour éviter les appels réseau
 * à chaque requête IA.
 *
 * <p>Méthodes publiques :
 * - isAvailable()   → true si Ollama répond en < healthCheckTimeoutMs
 * - isModelPulled() → true si le modèle est dans la liste des modèles locaux
 * - getStatus()     → "UP" | "DOWN" | "MODEL_MISSING"
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class OllamaHealthChecker {

    private final OllamaProperties props;
    private final RestTemplate     restTemplate;

    /** Cache du statut : évite un appel réseau à chaque requête. */
    private volatile boolean   cachedAvailable = false;
    private volatile Instant   cacheTimestamp  = Instant.EPOCH;
    private static final Duration CACHE_TTL = Duration.ofSeconds(30);

    /**
     * Vérifie si Ollama est disponible.
     * Résultat mis en cache 30 secondes.
     */
    public boolean isAvailable() {
        if (Duration.between(cacheTimestamp, Instant.now()).compareTo(CACHE_TTL) < 0) {
            return cachedAvailable;
        }
        return refreshAndGet();
    }

    /**
     * Vérifie si le modèle configuré est téléchargé localement.
     * Appelle GET /api/tags et cherche le modèle dans la liste.
     */
    public boolean isModelPulled(String modelName) {
        // GET {baseUrl}/api/tags → { "models": [{ "name": "qwen3:7b", ... }] }
        // Parser la réponse et chercher modelName dans les noms
        // Retourner false si Ollama est DOWN ou si le modèle est absent
    }

    /**
     * Retourne le statut textuel pour le health indicator Spring Boot.
     * Valeurs : "UP" | "DOWN" | "MODEL_MISSING" | "UNKNOWN"
     */
    public String getStatus() {
        if (!isAvailable()) return "DOWN";
        if (!isModelPulled(props.getModel())) return "MODEL_MISSING";
        return "UP";
    }

    private boolean refreshAndGet() {
        try {
            SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
            factory.setConnectTimeout(props.getHealthCheckTimeoutMs());
            factory.setReadTimeout(props.getHealthCheckTimeoutMs());
            RestTemplate rt = new RestTemplate(factory);
            rt.getForObject(props.getBaseUrl() + "/api/tags", String.class);
            cachedAvailable = true;
        } catch (Exception e) {
            log.debug("OllamaHealthChecker — Ollama indisponible : {}", e.getMessage());
            cachedAvailable = false;
        }
        cacheTimestamp = Instant.now();
        return cachedAvailable;
    }
}
```

---

## PROMPT 3 — OllamaAiService

**Fichiers à créer :**
- `src/main/java/com/kovixel/ai/provider/ollama/OllamaAiService.java`

```
────────────────────────────────────────────────────────────────────
OllamaAiService.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.provider.ollama;

/**
 * Provider IA basé sur Ollama (IA locale).
 *
 * <p>Actif quand {@code kovixel.ai.active-provider=ollama}.
 * Utilise Spring AI OllamaChatModel ou RestTemplate direct.
 *
 * <p>Fonctionnalités :
 * - summarize()        → résumé structuré via Qwen
 * - generateResponse() → réponse libre (Q&A, extraction JSON)
 * - Fallback automatique vers Claude si Ollama est DOWN et fallback-enabled=true
 *
 * <p>Gestion de la longueur :
 * - Tronque le texte à MAX_TEXT_LENGTH (12000 chars) comme les autres providers
 * - Utilise num_ctx = props.contextWindow (8192 par défaut)
 *
 * <p>Format de prompt Qwen3 :
 * - Qwen3 supporte le format ChatML natif
 * - Spring AI OllamaChatModel gère automatiquement le format
 */
@Slf4j
@Service
@Primary
@ConditionalOnProperty(name = "kovixel.ai.active-provider", havingValue = "ollama")
@RequiredArgsConstructor
public class OllamaAiService implements AiProviderService {

    private static final int MAX_TEXT_LENGTH = 12_000;
    private static final long[] RETRY_DELAYS_MS = {2_000, 5_000};

    private final OllamaProperties     props;
    private final OllamaHealthChecker  healthChecker;
    private final AiProviderService    claudeFallback;  // injecté par @Qualifier("claudeAiService")
    private final RestTemplate         restTemplate;

    /**
     * Génère un résumé structuré via Qwen en utilisant le prompt fourni par SummaryPromptBuilder.
     *
     * <p>⚠️ Ne construit PAS son propre prompt : le promptTemplate est fourni par
     * SummaryPromptBuilder (mode, focus, length, outputLanguage déjà inclus).
     * Si Ollama est DOWN et fallback-enabled=true, délègue à Claude avec le même prompt.
     */
    @Override
    public String summarize(String promptTemplate, String documentText) {
        if (documentText == null || documentText.isBlank()) return "";

        String truncated = documentText.length() > MAX_TEXT_LENGTH
                ? documentText.substring(0, MAX_TEXT_LENGTH) + "\n[... texte tronqué]"
                : documentText;

        // Remplacer {{document}} dans le template (Spring AI ne gère pas .param() ici)
        String finalPrompt = promptTemplate.replace("{{document}}", truncated);

        if (!healthChecker.isAvailable()) {
            return handleOllamaUnavailable("summarize", () ->
                    claudeFallback != null && props.isFallbackEnabled()
                            ? claudeFallback.summarize(promptTemplate, documentText)
                            : "⚠ Ollama indisponible — résumé non généré.");
        }

        return callOllama(finalPrompt, "summarize");
    }

    /**
     * Génère une réponse libre (utilisé par Q&A et ExtractionService).
     *
     * <p>Retourne du JSON brut pour les appels d'extraction (callClaudeForExtraction).
     */
    @Override
    public String generateResponse(String prompt) {
        if (!healthChecker.isAvailable()) {
            return handleOllamaUnavailable("generateResponse", () ->
                    claudeFallback != null && props.isFallbackEnabled()
                            ? claudeFallback.generateResponse(prompt)
                            : "");
        }
        return callOllama(prompt, "generateResponse");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Appel HTTP Ollama (POST /api/generate — API Ollama native)
    // Utilise l'API generate plutôt que Spring AI pour un contrôle total
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Appelle l'API Ollama POST /api/generate avec retry sur 500/timeout.
     *
     * <p>Format de requête :
     * {
     *   "model": "qwen3:7b",
     *   "prompt": "<prompt>",
     *   "stream": false,
     *   "options": { "temperature": 0.3, "num_predict": 4096, "num_ctx": 8192 }
     * }
     *
     * <p>Format de réponse :
     * { "response": "<texte généré>", "done": true, "total_duration": <ns> }
     */
    private String callOllama(String prompt, String operation) {
        // Construire le body de la requête
        // POST {baseUrl}/api/generate
        // Retry 2 fois sur 5xx ou timeout
        // Logger la durée (total_duration en nano-secondes → ms)
        // Retourner response.trim()
        // En cas d'échec après retries → handleOllamaUnavailable()
    }

    // buildSummarizePrompt() supprimé : le prompt vient de SummaryPromptBuilder,
    // OllamaAiService ne construit plus son propre prompt pour les résumés.

    private <T> T handleOllamaUnavailable(String operation, java.util.function.Supplier<T> fallback) {
        if (props.isFallbackEnabled() && claudeFallback != null) {
            log.warn("OllamaAiService.{} — Ollama indisponible, fallback Claude", operation);
            return fallback.get();
        }
        log.error("OllamaAiService.{} — Ollama indisponible et fallback désactivé", operation);
        // ⚠️ Ordre correct : (ErrorCode, HttpStatus, message) — comme dans SummaryServiceImpl
        throw new com.kovixel.common.exception.KovixelException(
                com.kovixel.common.exception.ErrorCode.AI_SERVICE_ERROR,
                org.springframework.http.HttpStatus.SERVICE_UNAVAILABLE,
                "Le service IA local est temporairement indisponible."
        );
    }
}

────────────────────────────────────────────────────────────────────
Prérequis — mettre à jour AiProviderService.java (interface)
────────────────────────────────────────────────────────────────────

⚠️ La signature de summarize() doit être mise à jour AVANT d'implémenter OllamaAiService.
Voir RESUME_IA_BACKEND_ROADMAP.md Phase 6.1 pour le détail complet.

// Avant :
String summarize(String text);

// Après :
String summarize(String promptTemplate, String documentText);

Cette modification s'applique également à ClaudeAiService et GeminiService
(voir RESUME_IA_BACKEND_ROADMAP.md Phase 6.2).

────────────────────────────────────────────────────────────────────
Modifier ClaudeAiService.java :
────────────────────────────────────────────────────────────────────

Ajouter @Qualifier("claudeAiService") sur la classe pour que OllamaAiService
puisse l'injecter par nom (éviter l'ambiguïté de bean avec @Primary) :

@Service("claudeAiService")
@Primary   // Conserver @Primary sauf si Ollama ou Gemini est actif
@ConditionalOnProperty(name = "kovixel.ai.active-provider", havingValue = "claude", matchIfMissing = true)
public class ClaudeAiService implements AiProviderService { ... }

Dans OllamaAiService, injecter avec :
    @Qualifier("claudeAiService") AiProviderService claudeFallback

Note : utiliser @Lazy pour éviter la dépendance circulaire si Claude est aussi @Primary.
```

---

## PROMPT 4 — ProcessingMode + AiRoutingService

**Fichiers à créer :**
- `src/main/java/com/kovixel/ai/routing/ProcessingMode.java`
- `src/main/java/com/kovixel/ai/routing/AiRoutingDecision.java`
- `src/main/java/com/kovixel/ai/routing/AiRoutingService.java`
- `src/main/resources/db/migration/V5__add_processing_mode.sql`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/user/entity/User.java` — ajouter champ `processingMode`

```
────────────────────────────────────────────────────────────────────
V5__add_processing_mode.sql
────────────────────────────────────────────────────────────────────

-- V5 — Ajout du choix de mode de traitement IA par utilisateur
-- LOCAL (défaut) : Ollama sur notre infra — RGPD strict
-- CLOUD (opt-in) : Claude/Gemini — consentement explicite requis (PRO+ uniquement)

ALTER TABLE users
    ADD COLUMN processing_mode VARCHAR(10) NOT NULL DEFAULT 'LOCAL',
    ADD COLUMN processing_mode_consent_at TIMESTAMP;  -- date du consentement cloud

-- Index pour les stats d'usage par mode
CREATE INDEX idx_users_processing_mode ON users (processing_mode);

────────────────────────────────────────────────────────────────────
ProcessingMode.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.routing;

public enum ProcessingMode {
    LOCAL,   // Ollama local — RGPD strict, défaut pour tous
    CLOUD    // Claude/Gemini — opt-in, PRO/ENTERPRISE uniquement, consentement requis
}

────────────────────────────────────────────────────────────────────
AiRoutingDecision.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.routing;

/**
 * Résultat du routing IA : quel provider et quel modèle utiliser.
 *
 * @param provider  "ollama" | "claude" | "gemini"
 * @param model     nom du modèle (ex: "qwen3:7b", "qwen2.5:14b", "claude-sonnet-4-6")
 * @param isLocal   true si traitement sur notre infra (Ollama)
 */
public record AiRoutingDecision(String provider, String model, boolean isLocal) {

    public static AiRoutingDecision ollama(String model) {
        return new AiRoutingDecision("ollama", model, true);
    }

    public static AiRoutingDecision claude() {
        return new AiRoutingDecision("claude", "claude-sonnet-4-6", false);
    }

    public static AiRoutingDecision gemini() {
        return new AiRoutingDecision("gemini", "gemini-2.5-flash", false);
    }
}

────────────────────────────────────────────────────────────────────
AiRoutingService.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.routing;

/**
 * Service central de routing IA.
 *
 * <p>Logique de décision :
 * <pre>
 * userId == null (anonyme)
 *   → TOUJOURS Ollama qwen3:1.7b (pas de consentement possible, accès limité)
 *
 * processingMode == LOCAL (défaut)
 *   FREE       → Ollama qwen3:7b
 *   PRO        → Ollama qwen2.5:14b
 *   ENTERPRISE → Ollama qwen2.5:14b
 *
 * processingMode == CLOUD (opt-in PRO/ENTERPRISE uniquement)
 *   → Claude Sonnet (ou Gemini si indisponible)
 *   → Fallback : Ollama qwen2.5:14b si Claude/Gemini DOWN
 *   → Embeddings : TOUJOURS Ollama nomic-embed-text (non affecté par ce choix)
 * </pre>
 *
 * <p>Note : les Anonymes et les FREE ne peuvent PAS activer le mode CLOUD.
 * La validation est faite ici + au niveau du service de paramètres utilisateur.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class AiRoutingService {

    private final UserRepository      userRepository;
    private final OllamaHealthChecker healthChecker;
    private final OllamaProperties    ollamaProps;

    // Modèles Ollama par plan (Phase 1 : qwen3:7b pour tous ; Phase 2 : 14b pour PRO)
    @Value("${kovixel.ai.models.anonymous:qwen3:1.7b}")
    private String modelAnonymous;

    @Value("${kovixel.ai.models.free:qwen3:7b}")
    private String modelFree;

    @Value("${kovixel.ai.models.pro:qwen3:7b}")   // Phase 1 : 7b ; Phase 2 : qwen2.5:14b
    private String modelPro;

    @Value("${kovixel.ai.models.enterprise:qwen3:7b}")
    private String modelEnterprise;

    /**
     * Résout la décision de routing pour une requête IA.
     *
     * @param userId null = anonyme
     * @return AiRoutingDecision (provider + modèle + isLocal)
     */
    public AiRoutingDecision resolve(Long userId) {
        // Anonyme : toujours local, modèle léger, sans exception
        if (userId == null) {
            log.debug("AiRoutingService — anonyme → ollama:{}", modelAnonymous);
            return AiRoutingDecision.ollama(modelAnonymous);
        }

        User user = userRepository.findById(userId)
            .orElseThrow(() -> new KovixelException(ErrorCode.USER_NOT_FOUND,
                HttpStatus.UNAUTHORIZED, "Utilisateur introuvable"));

        UserPlan plan = user.getPlan() != null ? user.getPlan() : UserPlan.FREE;
        ProcessingMode mode = user.getProcessingMode() != null
            ? user.getProcessingMode() : ProcessingMode.LOCAL;

        // FREE : toujours local, quelle que soit la preference
        if (plan == UserPlan.FREE) {
            log.debug("AiRoutingService — FREE → ollama:{}", modelFree);
            return AiRoutingDecision.ollama(modelFree);
        }

        // PRO / ENTERPRISE en mode CLOUD (opt-in explicite)
        if (mode == ProcessingMode.CLOUD) {
            if (healthChecker.isCloudAvailable()) {
                log.debug("AiRoutingService — {}+CLOUD → claude", plan);
                return AiRoutingDecision.claude();
            }
            // Fallback local si API cloud DOWN
            log.warn("AiRoutingService — API cloud indisponible, fallback local");
        }

        // PRO / ENTERPRISE en mode LOCAL (défaut ou fallback)
        String model = plan == UserPlan.ENTERPRISE ? modelEnterprise : modelPro;
        log.debug("AiRoutingService — {}+LOCAL → ollama:{}", plan, model);
        return AiRoutingDecision.ollama(model);
    }
}

────────────────────────────────────────────────────────────────────
Ajouter dans User.java :
────────────────────────────────────────────────────────────────────

@Column(name = "processing_mode", length = 10)
@Enumerated(EnumType.STRING)
private ProcessingMode processingMode = ProcessingMode.LOCAL;

@Column(name = "processing_mode_consent_at")
private Instant processingModeConsentAt;

────────────────────────────────────────────────────────────────────
Ajouter dans application.yml (kovixel.ai.models) :
────────────────────────────────────────────────────────────────────

kovixel:
  ai:
    models:
      # Phase 1 : qwen3:7b pour tous les plans locaux
      # Phase 2 : passer pro et enterprise à qwen2.5:14b (nécessite nœud 16 Go)
      anonymous: ${OLLAMA_MODEL_ANONYMOUS:qwen3:1.7b}
      free:       ${OLLAMA_MODEL_FREE:qwen3:7b}
      pro:        ${OLLAMA_MODEL_PRO:qwen3:7b}        # → qwen2.5:14b en Phase 2
      enterprise: ${OLLAMA_MODEL_ENTERPRISE:qwen3:7b} # → qwen2.5:14b en Phase 2

────────────────────────────────────────────────────────────────────
Ajouter dans application-dev.yml :
────────────────────────────────────────────────────────────────────

kovixel:
  ai:
    models:
      anonymous: qwen3:1.7b
      free:       qwen3:7b
      pro:        qwen3:7b    # En dev, pas besoin du 14b (trop lent sur CPU sans cache)
      enterprise: qwen3:7b
```

### Intégration dans `SummaryServiceImpl` et autres services IA

`AiRoutingService` remplace la sélection de provider dans `SummaryServiceImpl` :

```java
// Remplacer la résolution du provider hardcodée par :
AiRoutingDecision decision = aiRoutingService.resolve(userId);

// Le decision.provider() détermine quel AiProviderService utiliser :
AiProviderService provider = switch (decision.provider()) {
    case "claude"  -> claudeAiService;
    case "gemini"  -> geminiService;
    default        -> ollamaAiService.withModel(decision.model());
};

// Le champ engine de SummaryResponse utilise decision directement :
String engine = decision.isLocal()
    ? "ollama/" + decision.model()   // ex: "ollama/qwen3:7b"
    : decision.provider();            // ex: "claude"
```

### Nouveau endpoint : `PUT /api/v1/users/me/processing-mode`

```java
// UserController — permet à l'utilisateur PRO/ENTERPRISE de changer son mode
@PutMapping("/me/processing-mode")
public ResponseEntity<Void> updateProcessingMode(
    @RequestBody ProcessingModeRequest req,  // { "mode": "CLOUD", "consentGiven": true }
    @AuthenticationPrincipal UserDetails user
) {
    // Vérifier que le plan est PRO ou ENTERPRISE
    // Si mode=CLOUD : vérifier consentGiven=true et enregistrer processingModeConsentAt
    // Sauvegarder en DB
}
```

---

## PROMPT 5 — Health Indicator Ollama

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/ai/provider/ollama/OllamaHealthIndicator.java`

```
────────────────────────────────────────────────────────────────────
OllamaHealthIndicator.java
────────────────────────────────────────────────────────────────────

package com.kovixel.ai.provider.ollama;

/**
 * Health indicator Spring Boot Actuator pour le service Ollama.
 *
 * <p>Exposé via GET /actuator/health/ollamaAi
 *
 * <p>Répond :
 * - UP        → Ollama disponible ET modèle téléchargé
 * - DEGRADED  → Ollama UP mais modèle absent (MODEL_MISSING)
 * - DOWN      → Ollama indisponible (fallback Claude actif si configuré)
 * - DISABLED  → kovixel.ai.active-provider != "ollama" ET routing.enabled=false
 */
@Component
@RequiredArgsConstructor
public class OllamaHealthIndicator implements HealthIndicator {

    private final OllamaProperties    props;
    private final OllamaHealthChecker healthChecker;

    @Value("${kovixel.ai.active-provider:claude}")
    private String activeProvider;

    @Value("${kovixel.ai.routing.enabled:false}")
    private boolean routingEnabled;

    @Override
    public Health health() {
        boolean relevant = "ollama".equals(activeProvider) || routingEnabled;
        if (!relevant) {
            return Health.unknown()
                    .withDetail("status", "DISABLED")
                    .withDetail("reason", "kovixel.ai.active-provider != ollama")
                    .build();
        }

        String status = healthChecker.getStatus();
        boolean fallbackActive = props.isFallbackEnabled();

        return switch (status) {
            case "UP" -> Health.up()
                    .withDetail("model",            props.getModel())
                    .withDetail("baseUrl",          props.getBaseUrl())
                    .withDetail("embeddingModel",   props.getEmbeddingModel())
                    .withDetail("contextWindow",    props.getContextWindow())
                    .withDetail("fallbackEnabled",  fallbackActive)
                    .build();
            case "MODEL_MISSING" -> Health.status("DEGRADED")
                    .withDetail("model",            props.getModel())
                    .withDetail("issue",            "Modèle non téléchargé — lancer : ollama pull " + props.getModel())
                    .withDetail("fallbackEnabled",  fallbackActive)
                    .build();
            default -> (fallbackActive ? Health.status("DEGRADED") : Health.down())
                    .withDetail("model",            props.getModel())
                    .withDetail("baseUrl",          props.getBaseUrl())
                    .withDetail("issue",            "Ollama indisponible")
                    .withDetail("fallbackEnabled",  fallbackActive)
                    .withDetail("fallbackProvider", fallbackActive ? "claude" : "none")
                    .build();
        };
    }
}

────────────────────────────────────────────────────────────────────
Ajouter dans application.yml (section management.health) :
────────────────────────────────────────────────────────────────────

management:
  health:
    ollamaAi:
      enabled: true
```

---

## PROMPT 6 — Migration Embeddings : OpenAI → nomic-embed-text (local)

> **Contexte** : Kovixel traite des documents confidentiels. Envoyer le texte des documents
> à l'API OpenAI pour les embeddings est incompatible avec la confidentialité requise.
> **Décision : migrer vers `nomic-embed-text` via Ollama — 100% local, 0€, RGPD natif.**

---

### État actuel à migrer

```
DocumentIngestionService  →  EmbeddingModel (OpenAI)  →  document_chunks.embedding  vector(1536)
QnaServiceImpl            →  EmbeddingModel (OpenAI)  →  requête pgvector <=>
```

### État cible

```
DocumentIngestionService  →  OllamaEmbeddingModel     →  document_chunks.embedding  vector(768)
QnaServiceImpl            →  OllamaEmbeddingModel     →  requête pgvector <=>
```

### Comparatif modèles d'embedding

| Modèle                            | Dim  | MTEB  | RGPD | Coût     | RAM Ollama |
|-----------------------------------|------|-------|------|----------|------------|
| `text-embedding-3-small` (OpenAI) | 1536 | 62.3  | ❌   | $0.02/MT | 0 (cloud)  |
| `nomic-embed-text` ⭐ (Ollama)    | 768  | 62.4* | ✅   | 0€       | ~0.5 Go    |
| `mxbai-embed-large` (Ollama)      | 1024 | 64.7  | ✅   | 0€       | ~0.7 Go    |

> *`nomic-embed-text` v1.5 avec Matryoshka atteint 62.4 MTEB — **comparable à OpenAI** avec dimensionnalité réduite.
> Choisir `nomic-embed-text` : meilleur rapport qualité/RAM, parfaitement supporté par Spring AI Ollama.

### Budget RAM avec les deux modèles Ollama

```
qwen3:7b (chat)               →  ~5.0 Go RAM
nomic-embed-text (embeddings) →  ~0.5 Go RAM
PostgreSQL + pgvector          →  ~1.0 Go RAM
Spring Boot                    →  ~0.5 Go RAM
──────────────────────────────────────────────
Total                          →  ~7.0 Go      ← juste dans un VPS 8 Go
```

> Si la RAM est contrainte : utiliser `qwen3:1.7b` (~1.2 Go) + `nomic-embed-text` → total ~3.2 Go.

---

### 6.1 — Dépendance Maven (déjà incluse via PROMPT 1)

`spring-ai-starter-model-ollama` inclut `OllamaEmbeddingModel`. Aucune dépendance supplémentaire.

### 6.2 — Configuration Spring AI

**Fichier** : `src/main/resources/application.yml`

```yaml
spring:
  ai:
    ollama:
      base-url: ${OLLAMA_URL:http://localhost:11434}
      embedding:
        enabled: true
        options:
          model: ${OLLAMA_EMBEDDING_MODEL:nomic-embed-text}
    vectorstore:
      pgvector:
        dimensions: 768          # ← était 1536 pour OpenAI
        distance-type: COSINE_DISTANCE
    # Désactiver OpenAI embedding
    openai:
      embedding:
        enabled: false
```

### 6.3 — Migration Flyway : `V6__local_embeddings_migration.sql`

> ⚠️ Migration destructive — tous les vecteurs existants deviennent invalides.
> Exécuter sur une base de développement ou après backup. Les documents devront
> être re-ingérés (le flag `ingested=false` les remettra dans la file).

**Fichier** : `src/main/resources/db/migration/V6__local_embeddings_migration.sql`

```sql
-- V6 — Migration embeddings : OpenAI vector(1536) → nomic-embed-text vector(768)
-- ⚠ DESTRUCTIF : invalide tous les vecteurs existants → re-ingestion obligatoire

-- 1. Supprimer les index vectoriels (incompatibles avec la nouvelle dimension)
DROP INDEX IF EXISTS vector_store_embedding_idx;
DROP INDEX IF EXISTS idx_chunks_embedding_cosine;
DROP INDEX IF EXISTS idx_document_chunks_embedding;

-- 2. Changer la dimensionnalité dans vector_store
ALTER TABLE vector_store
    ALTER COLUMN embedding TYPE vector(768)
    USING NULL;

-- 3. Changer la dimensionnalité dans document_chunks
ALTER TABLE document_chunks
    ALTER COLUMN embedding TYPE vector(768)
    USING NULL;

-- 4. Marquer tous les documents comme non-ingérés → re-ingestion automatique
UPDATE summary_documents SET ingested = false, ingested_at = NULL;

-- 5. Supprimer les chunks obsolètes (vecteurs 1536 dims désormais NULL)
DELETE FROM document_chunks;

-- 6. Recréer les index HNSW pour 768 dimensions
CREATE INDEX vector_store_embedding_idx
    ON vector_store USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX idx_document_chunks_embedding
    ON document_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON COLUMN document_chunks.embedding IS 'nomic-embed-text via Ollama — 768 dims';
COMMENT ON COLUMN vector_store.embedding    IS 'nomic-embed-text via Ollama — 768 dims';
```

### 6.4 — Supprimer l'injection OpenAI dans `DocumentIngestionService` et `QnaServiceImpl`

Spring AI injecte `EmbeddingModel` par `@Primary`. Quand `spring.ai.openai.embedding.enabled: false`
et `spring.ai.ollama.embedding.enabled: true`, le bean `@Primary EmbeddingModel` devient
automatiquement `OllamaEmbeddingModel`. **Aucune modification de code dans ces deux services.**

Il suffit de :
1. Désactiver OpenAI embedding dans `application.yml` (fait en 6.2)
2. Activer Ollama embedding dans `application.yml` (fait en 6.2)
3. Vérifier que `OllamaEmbeddingModel` est bien le bean `@Primary` au démarrage (log Spring)

### 6.5 — Supprimer `OPENAI_API_KEY` des configurations

**Fichier** : `src/main/resources/application.yml`

```yaml
spring:
  ai:
    openai:
      api-key: ""          # Vider — plus utilisé pour les embeddings
      embedding:
        enabled: false     # Désactivé
      chat:
        enabled: false     # OpenAIService est déjà désactivé (@Service retiré)
```

**Fichier** : `src/main/resources/application-dev.yml` — retirer les lignes `openai:` entièrement.

### 6.6 — Checklist de migration

- [ ] Backup PostgreSQL avant migration
- [ ] `V6__local_embeddings_migration.sql` créée et testée en dev
- [ ] `nomic-embed-text` tiré dans Ollama (`ollama pull nomic-embed-text`)
- [ ] `application.yml` : OpenAI embedding désactivé, Ollama embedding activé, dimensions: 768
- [ ] Démarrage Spring Boot : vérifier dans les logs que `OllamaEmbeddingModel` est `@Primary`
- [ ] Re-ingestion de tous les documents déclenchée (flag `ingested=false` suffit)
- [ ] Test Q&A : vérifier que les réponses sont cohérentes avec les chunks retrouvés
- [ ] `OPENAI_API_KEY` retirée de `.env` et `.env.example`

---

### Décision finale documentée

```
╔═══════════════════════════════════════════════════════════════════╗
║  DÉCISION : Migrer vers nomic-embed-text (Ollama local)          ║
║                                                                   ║
║  ✅ Confidentialité totale — aucun document envoyé à OpenAI       ║
║  ✅ RGPD natif — données sur votre infrastructure uniquement      ║
║  ✅ Qualité comparable (MTEB 62.4 vs 62.3)                        ║
║  ✅ Coût 0€ — plus besoin d'OPENAI_API_KEY                        ║
║  ✅ Un seul service (Ollama) gère CHAT + EMBEDDINGS               ║
║                                                                   ║
║  Ollama = CHAT (qwen3:7b) + EMBEDDINGS (nomic-embed-text)        ║
║  OpenAI = supprimé de l'infrastructure                           ║
╚═══════════════════════════════════════════════════════════════════╝
```

---

## PROMPT 7 — Docker Compose + Pull automatique du modèle

**Fichiers à modifier :**
- `docker-compose.yml`
- `docker-compose.infra.yml`

**Fichiers à créer :**
- `docker/ollama/pull-models.sh`

```
────────────────────────────────────────────────────────────────────
docker-compose.yml — Ajouter le service Ollama
────────────────────────────────────────────────────────────────────

Ajouter ce service AVANT kovixel-app (pour que depends_on fonctionne) :

  # ---------------------------------------------------------------------------
  # Ollama — Serveur IA local (Qwen3, Llama, Mistral...)
  # Interface web : http://localhost:11434
  # Modèles stockés dans : ollama_data:/root/.ollama
  #
  # CPU seulement (défaut) : ~5 tokens/s sur qwen3:7b
  # GPU NVIDIA (optionnel) : décommenter les lignes deploy ci-dessous (~50 tok/s)
  # ---------------------------------------------------------------------------
  ollama:
    image: ollama/ollama:latest
    container_name: kovixel-ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
      - ./docker/ollama/pull-models.sh:/pull-models.sh:ro
    environment:
      # Durée de vie du modèle en mémoire après le dernier appel
      OLLAMA_KEEP_ALIVE: 24h
      # Nombre de couches GPU (0 = CPU uniquement)
      OLLAMA_NUM_GPU: 0
      # Threads CPU (0 = auto-détection)
      OLLAMA_NUM_THREAD: 0
      # Note : nomic-embed-text N'EST PAS tiré — les embeddings restent sur OpenAI.
      # Seul le modèle de chat (qwen3:7b) est nécessaire ici.
    # GPU NVIDIA (décommenter si disponible) :
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:11434/api/tags || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - kovixel-network

  # ---------------------------------------------------------------------------
  # Ollama Model Puller — pull les modèles au 1er démarrage (init container)
  # ---------------------------------------------------------------------------
  ollama-puller:
    image: ollama/ollama:latest
    container_name: kovixel-ollama-puller
    restart: "no"          # Exécuté une seule fois
    depends_on:
      ollama:
        condition: service_healthy
    volumes:
      - ollama_data:/root/.ollama
      - ./docker/ollama/pull-models.sh:/pull-models.sh:ro
    entrypoint: ["/bin/sh", "/pull-models.sh"]
    environment:
      OLLAMA_HOST: http://ollama:11434
      OLLAMA_MODELS: "qwen3:7b nomic-embed-text"    # Chat + Embeddings (100% local)
    networks:
      - kovixel-network

Dans kovixel-app, ajouter la dépendance Ollama et la variable d'environnement :

  kovixel-app:
    depends_on:
      ollama:
        condition: service_healthy
      # ... (garder les autres depends_on existants)
    environment:
      # ... (garder les variables existantes)
      OLLAMA_URL: http://ollama:11434
      OLLAMA_MODEL: ${OLLAMA_MODEL:-qwen3:7b}
      KOVIXEL_AI_ACTIVE_PROVIDER: ${AI_PROVIDER:-claude}

Dans la section volumes, ajouter :
  ollama_data:
    driver: local

────────────────────────────────────────────────────────────────────
docker/ollama/pull-models.sh
────────────────────────────────────────────────────────────────────

#!/bin/sh
# pull-models.sh — Télécharge les modèles Ollama au premier démarrage
# Exécuté par le service ollama-puller (init container)
#
# Modèles tirés :
#   qwen3:7b          → chat (résumé, Q&A, extraction)
#   nomic-embed-text  → embeddings RAG (remplace OpenAI — 100% local, RGPD ✅)

set -e

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MODELS="${OLLAMA_MODELS:-qwen3:7b}"

echo "🤖 Ollama Model Puller — démarrage"
echo "   Host   : ${OLLAMA_HOST}"
echo "   Modèles : ${MODELS}"
echo ""

# Attendre qu'Ollama soit prêt (max 60s)
echo "⏳ Attente du service Ollama..."
for i in $(seq 1 12); do
    if curl -sf "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1; then
        echo "✅ Ollama est prêt."
        break
    fi
    echo "   Tentative ${i}/12..."
    sleep 5
done

# Télécharger chaque modèle s'il n'est pas déjà présent
for MODEL in ${MODELS}; do
    echo ""
    echo "📥 Vérification du modèle : ${MODEL}"

    # Vérifier si le modèle est déjà téléchargé
    TAGS_RESPONSE=$(curl -sf "${OLLAMA_HOST}/api/tags" || echo '{"models":[]}')
    if echo "${TAGS_RESPONSE}" | grep -q "\"name\":\"${MODEL}\""; then
        echo "   ✅ ${MODEL} déjà présent — skip"
        continue
    fi

    echo "   ⬇ Téléchargement de ${MODEL}..."
    OLLAMA_HOST="${OLLAMA_HOST}" ollama pull "${MODEL}"
    echo "   ✅ ${MODEL} téléchargé avec succès"
done

echo ""
echo "🎉 Tous les modèles sont prêts."

────────────────────────────────────────────────────────────────────
docker-compose.infra.yml — Ajouter Ollama pour le dev natif
────────────────────────────────────────────────────────────────────

Ajouter le même service ollama (sans ollama-puller — le dev le tire manuellement).
Adapter : OLLAMA_KEEP_ALIVE: 1h (plus court pour libérer la RAM en dev).

Note pour le développeur :
  # Premier démarrage : tirer les deux modèles (chat + embeddings)
  docker exec kovixel-ollama ollama pull qwen3:7b
  docker exec kovixel-ollama ollama pull nomic-embed-text
  
  # Vérifier les modèles disponibles
  docker exec kovixel-ollama ollama list
```

---

## PROMPT 8 — Variables d'environnement + `.env.example`

**Fichiers à modifier :**
- `kovixel/.env.example`
- `README.md`

```
────────────────────────────────────────────────────────────────────
Ajouter dans .env.example (après la section Adobe) :
────────────────────────────────────────────────────────────────────

# --- Ollama (IA 100% locale — RGPD natif) ---
# URL du service Ollama. Défaut : http://localhost:11434 (dev) ou http://ollama:11434 (Docker)
OLLAMA_URL=http://localhost:11434

# Modèle de CHAT (génération de texte : résumé, Q&A réponses, extraction)
# Valeurs recommandées (RAM requise) :
#   qwen3:1.7b  → 1.2 Go — tests rapides, faible RAM
#   qwen3:7b    → 5.0 Go — production FREE (recommandé)
#   qwen2.5:14b → 9.0 Go — qualité proche de Claude Sonnet
OLLAMA_MODEL=qwen3:7b

# Modèle d'EMBEDDING (vectorisation pour RAG — remplace OpenAI text-embedding-3-small)
# nomic-embed-text : 768 dims, MTEB 62.4, ~0.5 Go RAM, multilingue
OLLAMA_EMBEDDING_MODEL=nomic-embed-text

# Provider IA actif : claude | gemini | ollama
# Utiliser "ollama" pour confidentialité totale (aucune donnée externe)
AI_PROVIDER=ollama

# OPENAI_API_KEY : plus nécessaire — embeddings migrés vers nomic-embed-text (local)
# Conserver uniquement si vous utilisez Claude PRO via API Anthropic (pas OpenAI)
# OPENAI_API_KEY=

────────────────────────────────────────────────────────────────────
Ajouter dans README.md (section ## Variables d'environnement) :
────────────────────────────────────────────────────────────────────

| `OLLAMA_URL`    | URL du service Ollama              | `http://localhost:11434` |
| `OLLAMA_MODEL`  | Modèle de chat Ollama (génération) | `qwen3:7b`               |
| `AI_PROVIDER`   | Provider IA actif (claude/gemini/ollama) | `claude`            |
```

---

## PROMPT 9 — Frontend Angular : badge moteur IA

**Fichiers à modifier :**
- `kovixel-ui/src/app/core/services/ai.service.ts` (si existant) ou `conversion.service.ts`
- Composants IA : `summary`, `qna`, `extraction` (si présents)

**Fichiers à créer :**
- `kovixel-ui/src/app/shared/components/ai-engine-badge/ai-engine-badge.component.ts`

```
────────────────────────────────────────────────────────────────────
Endpoint backend à ajouter dans un controller existant :
────────────────────────────────────────────────────────────────────

GET /api/v1/ai/engine-info
→ Réponse JSON :
{
  "provider":    "OLLAMA",          // CLAUDE | GEMINI | OLLAMA
  "model":       "qwen3:7b",
  "local":       true,              // true si moteur local (OLLAMA)
  "available":   true,
  "fallback":    null               // "CLAUDE" si Ollama est en fallback
}

Ce header peut aussi être retourné dans les réponses IA existantes :
  X-Ai-Provider: OLLAMA
  X-Ai-Model: qwen3:7b
  X-Ai-Local: true

────────────────────────────────────────────────────────────────────
AiEngineBadgeComponent (standalone, Angular 17+)
────────────────────────────────────────────────────────────────────

@Component({
  selector: 'app-ai-engine-badge',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <span class="badge" [class]="badgeClass()" [title]="tooltip()">
      {{ icon() }} {{ label() }}
    </span>
  `,
  styles: [`
    .badge { display:inline-flex; align-items:center; gap:.3rem;
             padding:.2rem .6rem; border-radius:9999px; font-size:.75rem; font-weight:600; }
    .badge-local  { background:#d1fae5; color:#065f46; }  /* vert - IA locale */
    .badge-cloud  { background:#dbeafe; color:#1e40af; }  /* bleu - IA cloud  */
    .badge-fallback { background:#fef3c7; color:#92400e; } /* orange - fallback */
  `],
})
export class AiEngineBadgeComponent {
  @Input() provider = 'CLAUDE';   // CLAUDE | GEMINI | OLLAMA
  @Input() model    = '';
  @Input() fallback = '';

  icon()       = computed(() => this.provider === 'OLLAMA' ? '🔒' : '☁️');
  label()      = computed(() => this.provider === 'OLLAMA'
                                  ? `IA locale · ${this.model}`
                                  : `IA cloud · ${this.provider}`);
  badgeClass() = computed(() => this.fallback
                                  ? 'badge badge-fallback'
                                  : this.provider === 'OLLAMA'
                                    ? 'badge badge-local'
                                    : 'badge badge-cloud');
  tooltip()    = computed(() => this.provider === 'OLLAMA'
                                  ? 'Traitement local — vos données ne quittent pas le serveur'
                                  : 'Traitement cloud — données envoyées à ' + this.provider);
}

────────────────────────────────────────────────────────────────────
Intégrer le badge dans les composants IA existants :
────────────────────────────────────────────────────────────────────

Dans chaque réponse IA (résumé, Q&A, extraction) :
- Lire le header X-Ai-Provider de la réponse HTTP
- Afficher <app-ai-engine-badge [provider]="aiProvider" [model]="aiModel" />
- Position recommandée : coin bas-droit de la carte résultat

Exemple dans la carte de résultat d'un résumé :
  <div class="result-meta">
    <app-ai-engine-badge [provider]="aiProvider()" [model]="aiModel()" />
    <span>Traitement : {{ processingTime() }}ms</span>
  </div>
```

---

## PROMPT 10 — Tests JUnit 5

**Fichiers à créer :**
- `src/test/java/com/kovixel/ai/provider/ollama/OllamaHealthCheckerTest.java`
- `src/test/java/com/kovixel/ai/provider/ollama/OllamaAiServiceTest.java`
- `src/test/java/com/kovixel/ai/provider/ollama/OllamaRoutingServiceTest.java`

```
────────────────────────────────────────────────────────────────────
OllamaHealthCheckerTest (WireMock pour simuler Ollama)
────────────────────────────────────────────────────────────────────

@Test ollamaAvailable_whenApiTagsResponds200()
  - WireMock stub : GET /api/tags → 200 { "models": [{"name":"qwen3:7b"}] }
  - Vérifier : isAvailable() = true, isModelPulled("qwen3:7b") = true

@Test ollamaUnavailable_whenConnectionRefused()
  - WireMock stub : pas de réponse (connexion refusée)
  - Vérifier : isAvailable() = false

@Test ollamaAvailableButModelMissing()
  - WireMock stub : GET /api/tags → 200 { "models": [] } (aucun modèle)
  - Vérifier : isModelPulled("qwen3:7b") = false, getStatus() = "MODEL_MISSING"

@Test cacheExpires_afterTtl()
  - Premier appel → isAvailable() = true (stub 200)
  - Modifier stub → 503
  - Appel immédiat → toujours true (cache actif)
  - Attendre > 30s (ou réduire TTL en test à 1s)
  - Nouvel appel → false (cache expiré)

────────────────────────────────────────────────────────────────────
OllamaAiServiceTest (Mockito)
────────────────────────────────────────────────────────────────────

@Test summarize_callsOllamaApi_whenAvailable()
  - healthChecker.isAvailable() = true
  - WireMock stub POST /api/generate → { "response": "Résumé test" }
  - Vérifier : retour = "Résumé test", claudeFallback.summarize() non appelé

@Test summarize_fallsBackToClaude_whenOllamaDown()
  - healthChecker.isAvailable() = false, fallbackEnabled = true
  - claudeFallback.summarize() retourne "Résumé Claude"
  - Vérifier : retour = "Résumé Claude"

@Test summarize_throwsException_whenOllamaDownAndFallbackDisabled()
  - healthChecker.isAvailable() = false, fallbackEnabled = false
  - Vérifier : KovixelException levée (SERVICE_UNAVAILABLE)

@Test summarize_truncatesLongText()
  - Texte de 15000 chars
  - Vérifier : corps de la requête Ollama contient ≤ 12000 chars

@Test generateResponse_returnsRawJson_forExtractionPrompt()
  - WireMock stub → { "response": "{\"facture\":\"INV-001\"}" }
  - Vérifier : retour contient JSON valide

────────────────────────────────────────────────────────────────────
OllamaRoutingServiceTest (Mockito)
────────────────────────────────────────────────────────────────────

@Test freeUser_routesToOllama_whenOllamaAvailable()
  - userId = null (anonyme)
  - healthChecker.isAvailable() = true
  - routingEnabled = true
  - Vérifier : resolveProvider(null) = "ollama"

@Test proUser_routesToClaude_alwaysIgnoringOllama()
  - userId = 42 (PRO)
  - healthChecker.isAvailable() = true (peu importe)
  - Vérifier : resolveProvider(42) = "claude"

@Test freeUser_fallsBackToClaude_whenOllamaDown()
  - userId = null
  - healthChecker.isAvailable() = false
  - Vérifier : resolveProvider(null) = "claude"

@Test forceLocal_routesToOllama_forAllPlans()
  - forceLocal = true
  - userId = 42 (PRO)
  - Vérifier : resolveProvider(42) = "ollama"

@Test routingDisabled_doesNotInterferWithActiveProvider()
  - routingEnabled = false
  - Vérifier : resolveProvider(null) ne consulte pas le UserRepository
```

---

## PROMPT 11 — Documentation + README

**Fichiers à modifier :**
- `README.md`
- `kovixel/.env.example`

```
Dans README.md, ajouter une nouvelle section "## IA Locale (Ollama + Qwen)" :

### Pourquoi Ollama ?

| Critère         | Claude (cloud)         | Ollama (local)              |
|-----------------|------------------------|-----------------------------|
| Coût            | $$$ (par token)        | 0 € (infrastructure locale) |
| RGPD            | Données envoyées USA   | Données sur votre serveur   |
| Vitesse         | ~200 tok/s (API)       | ~5–50 tok/s (CPU/GPU)       |
| Qualité         | ★★★★★                 | ★★★★☆ (Qwen3-7B)            |
| Disponibilité   | 99.9% (cloud)          | Dépend de votre infra       |
| Offline         | ❌                     | ✅                           |

### Démarrage rapide Ollama

  # 1. Lancer Ollama avec Docker
  docker-compose up -d ollama
  
  # 2. Tirer les deux modèles (à faire une seule fois)
  docker exec kovixel-ollama ollama pull qwen3:7b          # chat — 5.2 Go
  docker exec kovixel-ollama ollama pull nomic-embed-text  # embeddings — 0.5 Go
  
  # 3. Activer Ollama dans la config
  # .env :
  AI_PROVIDER=ollama
  OLLAMA_URL=http://localhost:11434
  OLLAMA_MODEL=qwen3:7b
  OLLAMA_EMBEDDING_MODEL=nomic-embed-text
  # OPENAI_API_KEY : plus nécessaire — supprimer
  
  # 4. Vérifier le health check
  curl http://localhost:8080/actuator/health/ollamaAi

### Routing automatique FREE → Ollama / PRO → Claude

  # application-dev.yml :
  kovixel:
    ai:
      routing:
        enabled: true
        force-local: true    # Tout passe par Ollama en dev

  # application-prod.yml :
  kovixel:
    ai:
      routing:
        enabled: true        # FREE → Ollama, PRO → Claude
        force-local: false

### Commandes utiles Ollama

  # Lister les modèles disponibles localement
  docker exec kovixel-ollama ollama list
  
  # Tirer un modèle plus puissant (nécessite 16 Go RAM)
  docker exec kovixel-ollama ollama pull qwen2.5:14b
  
  # Tester directement le modèle
  docker exec -it kovixel-ollama ollama run qwen3:7b
  
  # Supprimer un modèle pour libérer de l'espace
  docker exec kovixel-ollama ollama rm qwen3:7b
  
  # Voir les logs Ollama
  docker logs -f kovixel-ollama
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5
    ↓           ↓           ↓           ↓           ↓
  Config    Properties  OllamaAI   Routing    Health
  + Maven   + Health     Service   par plan   Indicator
            Checker

PROMPT 6 — Migration Embeddings OpenAI → nomic-embed-text
    → V6__local_embeddings_migration.sql (vector 1536→768, re-ingestion)
    → application.yml : OpenAI embedding désactivé, Ollama embedding activé
    → OPENAI_API_KEY supprimée — plus aucune dépendance externe pour les données

PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10 → PROMPT 11
    ↓           ↓          ↓           ↓            ↓
  Docker      .env       Badge       Tests         Docs
  Compose   variables   Angular     JUnit 5       README
  + pull.sh
```

---

## Notes importantes

### Compatibilité Spring AI

Spring AI 1.0.0 (utilisé par Kovixel) supporte nativement Ollama via
`spring-ai-starter-model-ollama`. Le `OllamaChatModel` peut être utilisé
directement comme alternative à `RestTemplate`.

Deux approches possibles pour `OllamaAiService` :

**Option A — Spring AI OllamaChatModel (recommandée pour cohérence)** :
```java
// Réutilise le ChatClient Spring AI avec OllamaChatModel
// Avantage : cohérent avec ClaudeAiService, supporte streaming
@Bean
public ChatClient ollamaChatClient(OllamaChatModel ollamaModel) {
    return ChatClient.builder(ollamaModel)
            .defaultSystem(KOVIXEL_SYSTEM_PROMPT)
            .build();
}
```

**Option B — RestTemplate direct (plus de contrôle)** :
```java
// Appel direct POST /api/generate
// Avantage : contrôle total des options (num_ctx, stop tokens, etc.)
// Inconvénient : plus de code, pas de streaming
```

### Performance CPU — VPS 24 Go RAM / 160 Go SSD

```
Modèle          RAM Ollama  Vitesse CPU   Temps résumé 1 page
qwen3:1.7b      3 Go        ~15 tok/s     ~10–20 secondes     ← Anonyme
qwen3:7b        5 Go        ~5 tok/s      ~30–60 secondes     ← FREE
qwen2.5:14b     9 Go        ~2 tok/s      ~90–180 secondes    ← PRO (Phase 2)
nomic-embed-text 0.5 Go     ~50 emb/s     négligeable         ← Tous

Budget RAM Phase 1 (qwen3:7b + nomic-embed-text) :
  5 Go (Ollama 7b) + 0.5 Go (nomic) + 1.5 Go (PG) + 0.5 Go (Spring) + 1 Go (OS)
  = ~8.5 Go ✅ (15 Go de marge sur VPS 24 Go)

Budget RAM Phase 2 (qwen2.5:14b pour PRO) :
  9 Go (Ollama 14b) + 0.5 Go (nomic) + 1.5 Go (PG) + 0.5 Go (Spring) + 1 Go (OS)
  = ~12.5 Go ✅ (11 Go de marge — confortable)
```

**Capacité de traitement (Phase 1, VPS actuel) :**
- ~5 résumés simultanés en queue → acceptable jusqu'à ~3 000 DAU
- Au-delà : les PRO en mode cloud (Claude) soulagent automatiquement le VPS

**Attention SSD 160 Go :** prévoir S3 externe dès le lancement pour le stockage PDF
(MinIO → OVH Object Storage / Scaleway / Cloudflare R2, ~2€/mois/100 Go)

### RGPD — positionnement concurrentiel

```
SmallPDF / iLovePDF :
  Upload PDF → serveurs cloud → API OpenAI/GPT → résultat
  ✅ RGPD légal (ISO 27001, DPA, rétention 1-2h) mais données externalisées

Kovixel (mode LOCAL, défaut) :
  Upload PDF → VPS Kovixel → Ollama local → résultat
  ✅ RGPD strict — aucune donnée ne quitte l'infra, jamais

Kovixel (mode CLOUD, opt-in PRO) :
  Upload PDF → VPS Kovixel → Claude API → résultat
  ⚠️  Même niveau que SmallPDF — consentement explicite requis
  ✅  Embeddings restent locaux même dans ce cas (avantage vs SmallPDF)
```

**Message marketing vérifiable :** "Par défaut, vos documents ne quittent jamais nos serveurs.
Contrairement à SmallPDF, même notre moteur de recherche (Q&A) est 100% local."

### Modèles alternatifs à Qwen

Si Qwen3 ne convient pas, d'autres modèles sont compatibles sans
modification du code :

| Modèle          | Taille | Forces vs Qwen          |
|-----------------|--------|-------------------------|
| `llama3.1:8b`   | 5.0 Go | Meilleur en anglais     |
| `mistral:7b`    | 4.1 Go | Plus rapide, moins précis|
| `phi3:mini`     | 2.3 Go | Très léger (3 Go RAM)   |
| `deepseek-r1:7b`| 4.7 Go | Excellent raisonnement  |
| `gemma3:4b`     | 2.5 Go | Google, bon compromis   |

Changer de modèle : modifier les variables `OLLAMA_MODEL_*` dans `.env` et redémarrer.

---

## Phases de déploiement

### Phase 1 — Lancement (0 → ~2 000 DAU) — VPS actuel 24 Go

**Objectif** : fonctionnel, RGPD, différencié. Zéro dette technique.

```
Infrastructure :
  VPS 24 Go RAM / 160 Go SSD (actuel)
  + Bucket S3 externe pour les PDF (OVH/Scaleway R2 — ~2€/mois)

Modèles actifs :
  qwen3:1.7b  → Anonyme
  qwen3:7b    → FREE + PRO (même modèle, différencié par quota)
  nomic-embed-text → Embeddings (tous)

Mode cloud (PRO opt-in) :
  Activé dès le lancement — différenciation qualité pour PRO sans coût infra

Quotas Phase 1 :
  Anonyme  : 1 résumé/session, fichier 5 Mo, pas de Q&A
  FREE     : 5 résumés/jour, 10 Mo, 10 Q&A/jour
  PRO      : 100 résumés/jour, 100 Mo, 500 Q&A/jour
  ENTERPRISE : illimité, 500 Mo
```

**Checklist Phase 1 :**
- [ ] PROMPT 1 à 11 de ce roadmap implémentés
- [ ] RESUME_IA_BACKEND_ROADMAP.md implémenté (mode/focus/length/outputLanguage)
- [ ] `AiRoutingService` branché dans Summary, Q&A, Extraction
- [ ] Endpoint `PUT /api/v1/users/me/processing-mode` avec consentement
- [ ] UI frontend : toggle Local/Cloud dans les paramètres du compte (PRO uniquement)
- [ ] UI frontend : badge "🔒 Local" / "☁️ Cloud" sur chaque résultat
- [ ] Bucket S3 externe configuré pour MinIO
- [ ] Migration V5 (processing_mode) + V6 (embeddings 768 dims)

---

### Phase 2 — Croissance (~2 000 → ~20 000 DAU)

**Objectif** : meilleure qualité locale pour PRO, scaling Ollama.

```
Infrastructure :
  VPS actuel (24 Go) → conserver pour FREE + anonymes + embeddings
  + 1 nœud Ollama dédié : VPS 16 Go RAM (ou GPU 8 Go VRAM)
    → qwen2.5:14b pour PRO/ENTERPRISE en mode LOCAL
    → x5-x10 plus rapide si GPU (NVIDIA RTX 3090 ou A10 en location)

Modèles Phase 2 :
  qwen3:1.7b    → Anonyme (inchangé)
  qwen3:7b      → FREE (inchangé)
  qwen2.5:14b   → PRO + ENTERPRISE mode LOCAL (nouveau nœud)
  nomic-embed-text → Embeddings (inchangé)

Changement de config (zero code) :
  OLLAMA_MODEL_PRO=qwen2.5:14b
  OLLAMA_MODEL_ENTERPRISE=qwen2.5:14b
  OLLAMA_URL_PRO=http://ollama-pro:11434   ← nouveau nœud dédié
```

**Déclencheurs pour passer en Phase 2 :**
- Temps de résumé PRO > 3 minutes en heure de pointe
- File d'attente Ollama > 10 requêtes simultanées
- Taux de conversion FREE → PRO justifie l'investissement nœud (~30-50€/mois VPS GPU)

**Checklist Phase 2 :**
- [ ] Nœud Ollama PRO provisionné (VPS 16 Go ou GPU)
- [ ] `application.yml` : `OLLAMA_URL_PRO` séparé du nœud FREE
- [ ] `AiRoutingService` route vers le bon nœud selon le plan
- [ ] Pull `qwen2.5:14b` sur le nœud PRO
- [ ] Tests de charge : valider la capacité sous pic
- [ ] Monitoring : Prometheus/Grafana sur temps de génération par plan

---

### Phase 3 — Scale (~20 000+ DAU)

**Objectif** : haute disponibilité, scaling horizontal, SLA Enterprise.

```
Infrastructure :
  Kubernetes (K3s ou GKE/EKS) avec :
    - Pool FREE : N pods Ollama qwen3:7b (auto-scale selon charge)
    - Pool PRO  : M pods Ollama qwen2.5:14b (GPU, auto-scale)
    - Pool embeddings : P pods nomic-embed-text (CPU, rapide)
  Load balancer devant chaque pool
  PostgreSQL managed (RDS/CloudSQL) ou Patroni HA
  Redis pour les files d'attente IA (async jobs)

Mode cloud pour PRO (économie d'échelle) :
  À ce stade, Claude Batch API devient compétitif vs GPU cluster
  → Les PRO en mode CLOUD allègent le cluster local
  → Pricing : coût Claude/résumé < coût GPU/résumé au-delà de ~50 000 résumés/jour

SLA Enterprise :
  Instance Ollama dédiée par client Enterprise (isolation totale)
  OU déploiement on-premise chez le client (Kovixel self-hosted)
```

**Déclencheurs pour passer en Phase 3 :**
- Coût infrastructure Phase 2 > coût d'un cluster K8s géré
- Besoin SLA 99.9% pour clients Enterprise
- Revenus récurrents couvrant l'équipe DevOps

---

### Résumé décisionnel des phases

| Critère | Phase 1 | Phase 2 | Phase 3 |
|---------|---------|---------|---------|
| DAU estimés | 0 → 2K | 2K → 20K | 20K+ |
| Coût infra/mois | ~30€ (VPS + S3) | ~80€ (+ nœud PRO) | ~500€+ (K8s) |
| Modèle PRO | qwen3:7b | qwen2.5:14b | qwen2.5:14b (GPU) |
| Latence résumé PRO | ~60s | ~30s (GPU: ~5s) | ~5s (GPU pool) |
| Revenu requis avant upgrade | — | ~500€ MRR | ~5 000€ MRR |

