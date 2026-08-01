# Résumé IA — Roadmap Backend

> **Statut frontend** : ✅ Terminé (952 lignes, toutes options envoyées via FormData)  
> **Statut backend** : 🔶 Fondations solides, paramètres non câblés  
> **Objectif** : Brancher mode / focus / length / outputLanguage pour que chaque option produit un résumé différent et structuré

---

## Vue d'ensemble des phases

| Phase | Titre | Complexité | Prérequis |
|-------|-------|-----------|-----------|
| 1 | Request DTO + Controller | Faible | — |
| 2 | Cache multi-options | Moyenne | Phase 1 |
| 3 | Migration DB | Faible | Phase 1 |
| 4 | PromptBuilder | Moyenne | Phase 1 |
| 5 | Response enrichie + Sections | Moyenne | Phase 3 + 4 |
| 6 | Refactor AiService | Faible | Phase 4 |
| 7 | Tests | Moyenne | Phases 1–6 |
| 8 | OpenAPI + polish final | Faible | Phases 1–7 |

---

## Phase 1 — Request DTO + câblage Controller

### Problème actuel
`SummaryController` reçoit les paramètres `mode`, `focus`, `length`, `outputLanguage` en `@RequestParam` mais ne les transmet pas à `SummaryServiceImpl`. Ils sont ignorés silencieusement.

### 1.1 Créer `SummaryRequest.java`

**Fichier** : `src/main/java/com/kovixel/ai/summary/dto/SummaryRequest.java`

```java
@Data
@Builder
public class SummaryRequest {

    @NotNull
    private MultipartFile file;

    @Builder.Default
    private SummaryMode mode = SummaryMode.STANDARD;

    @Builder.Default
    private SummaryFocus focus = SummaryFocus.GENERAL;

    @Builder.Default
    private SummaryLength length = SummaryLength.MEDIUM;

    @Builder.Default
    private SummaryOutputLanguage outputLanguage = SummaryOutputLanguage.AUTO;

    @Size(max = 500)
    private String customInstruction;
}
```

### 1.2 Créer les enums

**Fichier** : `src/main/java/com/kovixel/ai/summary/dto/SummaryMode.java`

```java
public enum SummaryMode {
    STANDARD, EXECUTIVE, BULLETS, DETAILED, CUSTOM
}
```

Idem pour `SummaryFocus` (GENERAL, FINANCIAL, LEGAL, MEDICAL, TECHNICAL, CUSTOM) et `SummaryLength` (SHORT, MEDIUM, LONG) et `SummaryOutputLanguage` (AUTO, FR, EN, ES, DE, IT, PT).

> **Note** : Utiliser `@JsonProperty` sur chaque valeur pour matcher les strings minuscules envoyées par le frontend (`"standard"`, `"executive"`, etc.)

### 1.3 Mettre à jour `SummaryController`

```java
// Avant
@PostMapping("/summarize")
public ResponseEntity<SummaryResponse> summarize(@RequestParam MultipartFile file,
    @RequestParam(defaultValue = "standard") String mode, ...) { ... }

// Après
@PostMapping(value = "/summarize", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
public ResponseEntity<SummaryResponse> summarize(
    @RequestParam MultipartFile file,
    @RequestParam(defaultValue = "standard") SummaryMode mode,
    @RequestParam(defaultValue = "general") SummaryFocus focus,
    @RequestParam(defaultValue = "medium") SummaryLength length,
    @RequestParam(defaultValue = "auto") SummaryOutputLanguage outputLanguage,
    @RequestParam(required = false) @Size(max = 500) String customInstruction
) {
    SummaryRequest request = SummaryRequest.builder()
        .file(file).mode(mode).focus(focus).length(length)
        .outputLanguage(outputLanguage).customInstruction(customInstruction)
        .build();
    return ResponseEntity.ok(summaryService.summarize(request, currentUserId()));
}
```

### 1.4 Mettre à jour `SummaryService` (interface)

```java
SummaryResponse summarize(SummaryRequest request, Long userId);
```

---

## Phase 2 — Cache multi-options (idempotence étendue)

### Problème actuel
La clé de cache est `SHA-256(fichier)` → un seul résumé possible par PDF, peu importe les options. Changer le mode ne génère pas un nouveau résumé.

### 2.1 Nouvelle clé de cache

```java
// Dans SummaryServiceImpl
private String computeCacheKey(byte[] fileBytes, SummaryRequest req) {
    String raw = Hex.encodeHexString(DigestUtils.sha256(fileBytes))
        + "|" + req.getMode().name()
        + "|" + req.getFocus().name()
        + "|" + req.getLength().name()
        + "|" + req.getOutputLanguage().name();
    return Hex.encodeHexString(DigestUtils.sha256(raw.getBytes(StandardCharsets.UTF_8)));
}
```

> La colonne `content_hash` dans `summary_documents` stocke déjà ce hash — elle continue à servir de clé d'idempotence, mais avec un scope plus large.

### 2.2 Impact DB

`summary_documents.content_hash` est `UNIQUE` — avec la nouvelle clé composite (hash fichier + options), le même PDF avec des modes différents crée plusieurs lignes `summary_documents` mais avec des `content_hash` distincts. **Aucune migration nécessaire**, la contrainte UNIQUE reste valide.

---

## Phase 3 — Migration DB : stocker les options choisies

### 3.1 Créer `V4__add_summary_options.sql`

**Fichier** : `src/main/resources/db/migration/V4__add_summary_options.sql`

```sql
ALTER TABLE summaries
    ADD COLUMN mode         VARCHAR(20)  DEFAULT 'standard',
    ADD COLUMN focus        VARCHAR(20)  DEFAULT 'general',
    ADD COLUMN length       VARCHAR(10)  DEFAULT 'medium',
    ADD COLUMN output_language VARCHAR(10) DEFAULT 'auto',
    ADD COLUMN engine       VARCHAR(50),
    ADD COLUMN duration_ms  INTEGER,
    ADD COLUMN sections     JSONB;

-- Index pour retrouver l'historique par (document_id, mode, focus)
CREATE INDEX idx_summaries_options ON summaries (document_id, mode, focus, length, output_language);
```

> `sections JSONB` stocke le tableau `[{title, icon, content}]` — évite une table relationnelle pour des données non-interrogées.

### 3.2 Mettre à jour l'entité `Summary.java`

```java
@Column(name = "mode")
@Enumerated(EnumType.STRING)
private SummaryMode mode;

@Column(name = "focus")
@Enumerated(EnumType.STRING)
private SummaryFocus focus;

@Column(name = "length")
@Enumerated(EnumType.STRING)
private SummaryLength length;

@Column(name = "output_language")
@Enumerated(EnumType.STRING)
private SummaryOutputLanguage outputLanguage;

@Column(name = "engine")
private String engine;

@Column(name = "duration_ms")
private Integer durationMs;

@Type(JsonType.class)  // hibernate-types
@Column(name = "sections", columnDefinition = "jsonb")
private List<SummarySection> sections;
```

---

## Phase 4 — PromptBuilder : le cœur de la feature

### 4.1 Créer `SummaryPromptBuilder.java`

**Fichier** : `src/main/java/com/kovixel/ai/summary/service/SummaryPromptBuilder.java`

C'est le service le plus important de cette roadmap. Il génère un prompt Claude adapté à chaque combinaison d'options.

#### Structure du prompt généré

```
[SYSTEM PERSONA]
Tu es un expert en synthèse documentaire professionnelle.

[FOCUS CONTEXT]
(ex: "Tu analyses ce document avec un prisme financier...")

[MODE INSTRUCTIONS]
(ex: mode EXECUTIVE → "Rédige un résumé de type C-suite, en 5 bullet points...")

[LENGTH TARGET]
(ex: "Cible ~400 mots pour le résumé principal.")

[OUTPUT LANGUAGE]
(ex: "Réponds EXCLUSIVEMENT en français.")

[CUSTOM INSTRUCTION]
(ex: "Insiste particulièrement sur les risques ESG.")

[STRUCTURE REQUIREMENT]
Retourne ta réponse en JSON strict avec ce schéma :
{ "sections": [{ "title": "...", "icon": "...", "content": "..." }] }

[DOCUMENT]
{{document}}
```

#### Implémentation

```java
@Component
@RequiredArgsConstructor
public class SummaryPromptBuilder {

    public String build(SummaryRequest req) {
        return String.join("\n\n",
            systemPersona(),
            focusContext(req.getFocus()),
            modeInstructions(req.getMode()),
            lengthTarget(req.getLength()),
            outputLanguageInstruction(req.getOutputLanguage()),
            customInstruction(req.getCustomInstruction()),
            structureRequirement(req.getMode()),
            "## Document\n{{document}}"
        );
    }

    private String modeInstructions(SummaryMode mode) {
        return switch (mode) {
            case STANDARD -> """
                ## Mode : Standard
                Rédige un résumé équilibré : une vue d'ensemble claire, les points clés, et une conclusion.
                Structure : Introduction → Points principaux → Conclusion.
                """;
            case EXECUTIVE -> """
                ## Mode : Executive
                Rédige un résumé de niveau direction générale (C-suite).
                - Commence par l'enjeu stratégique principal (1 phrase d'accroche).
                - 3 à 5 points d'action ou décisions critiques, en bullet points.
                - Termine par une recommandation ou un risque majeur.
                Langage : direct, chiffres si présents, zéro jargon technique.
                """;
            case BULLETS -> """
                ## Mode : Bullet Points
                Présente UNIQUEMENT des listes à puces, sans paragraphes narratifs.
                - Section "Points essentiels" : 5 à 8 bullets.
                - Section "À retenir" : 3 bullets maximum.
                - Section "Actions / Prochaines étapes" si applicable.
                """;
            case DETAILED -> """
                ## Mode : Analyse détaillée
                Produis une analyse approfondie :
                - Contexte et objectif du document
                - Développement complet de chaque thème majeur
                - Arguments, preuves, chiffres cités
                - Implications et limites
                - Conclusion analytique
                """;
            case CUSTOM -> """
                ## Mode : Personnalisé
                Applique les instructions personnalisées ci-dessous à la lettre.
                Si aucune instruction n'est fournie, applique le mode Standard.
                """;
        };
    }

    private String focusContext(SummaryFocus focus) {
        return switch (focus) {
            case GENERAL -> "";
            case FINANCIAL -> """
                ## Prisme d'analyse : Financier
                Priorise : chiffres, revenus, coûts, marges, flux de trésorerie,
                ratios financiers, risques financiers, tendances économiques.
                """;
            case LEGAL -> """
                ## Prisme d'analyse : Juridique
                Priorise : obligations contractuelles, clauses critiques, risques légaux,
                conformité réglementaire, responsabilités, droits et devoirs des parties.
                """;
            case MEDICAL -> """
                ## Prisme d'analyse : Médical / Clinique
                Priorise : méthodologie, résultats cliniques, effets indésirables,
                dosages, populations étudiées, conclusions thérapeutiques, niveau de preuve.
                """;
            case TECHNICAL -> """
                ## Prisme d'analyse : Technique
                Priorise : architecture, spécifications, composants, contraintes techniques,
                performances, standards utilisés, dépendances, risques d'implémentation.
                """;
            case CUSTOM -> """
                ## Prisme d'analyse : Personnalisé
                Applique les instructions personnalisées pour orienter ton analyse.
                """;
        };
    }

    private String lengthTarget(SummaryLength length) {
        return switch (length) {
            case SHORT  -> "## Longueur cible\nRésumé court : **150 mots maximum**. Sois concis, va à l'essentiel.";
            case MEDIUM -> "## Longueur cible\nRésumé moyen : **300 à 450 mots**. Équilibre densité et clarté.";
            case LONG   -> "## Longueur cible\nRésumé long : **700 à 900 mots**. Développe chaque point important.";
        };
    }

    private String outputLanguageInstruction(SummaryOutputLanguage lang) {
        if (lang == SummaryOutputLanguage.AUTO) return "";
        String langName = switch (lang) {
            case FR -> "français";
            case EN -> "English";
            case ES -> "español";
            case DE -> "Deutsch";
            case IT -> "italiano";
            case PT -> "português";
            default -> "";
        };
        return "## Langue de sortie\nRéponds EXCLUSIVEMENT en **" + langName + "**, quelle que soit la langue du document source.";
    }

    private String customInstruction(String instruction) {
        if (instruction == null || instruction.isBlank()) return "";
        return "## Instructions personnalisées\n" + instruction.strip();
    }

    private String structureRequirement(SummaryMode mode) {
        // Mode BULLETS → JSON avec sections title/icon/content
        // Autres modes → markdown avec headers ## marquant les sections
        return """
            ## Format de réponse requis
            Retourne ta réponse au format JSON strict (pas de texte autour) :
            {
              "sections": [
                { "title": "Titre de section", "icon": "nom-lucide-icon", "content": "contenu markdown" }
              ]
            }
            Icônes Lucide suggérées : FileText, TrendingUp, AlertTriangle, CheckCircle, Lightbulb, BarChart2, Scale, Stethoscope, Code, Star.
            """;
    }

    private String systemPersona() {
        return """
            ## Rôle
            Tu es un expert en synthèse documentaire professionnelle.
            Tu lis des documents complexes et tu en extrais l'information la plus utile,
            avec précision et sans hallucination. Tu ne mentionnes jamais les limites du document
            au-delà de ce qui est écrit dedans.
            """;
    }
}
```

---

## Phase 5 — SummaryResponse enrichie + parser de sections

### 5.1 Mettre à jour `SummaryResponse.java`

```java
@Data @Builder
public class SummaryResponse {
    // Champs existants
    private UUID summaryId;
    private UUID documentId;
    private String fileName;
    private Long fileSize;
    private String content;       // markdown complet (concaténation des sections)
    private String language;
    private String model;
    private Integer tokensUsed;
    private Instant createdAt;
    private boolean cached;

    // Nouveaux champs
    private String engine;        // "claude" | "gemini" | "ollama"
    private Integer durationMs;
    private SummaryMode mode;
    private SummaryFocus focus;
    private SummaryLength length;
    private SummaryOutputLanguage outputLanguage;
    private List<SummarySection> sections; // null si mode non-structuré
}
```

### 5.2 Créer `SummarySection.java` (DTO + record JPA)

```java
@Data @AllArgsConstructor @NoArgsConstructor
public class SummarySection {
    private String title;
    private String icon;    // nom d'icône Lucide (ex: "TrendingUp")
    private String content; // markdown
}
```

### 5.3 Créer `SummaryResponseParser.java`

Le backend demande à Claude de répondre en JSON. Ce parser extrait les sections.

```java
@Component
@RequiredArgsConstructor
public class SummaryResponseParser {

    private final ObjectMapper objectMapper;

    public ParsedSummary parse(String rawResponse) {
        try {
            // Claude peut envelopper son JSON dans ```json ... ```
            String json = extractJson(rawResponse);
            JsonNode root = objectMapper.readTree(json);
            List<SummarySection> sections = objectMapper.convertValue(
                root.get("sections"),
                new TypeReference<>() {}
            );
            String content = sections.stream()
                .map(s -> "## " + s.getTitle() + "\n\n" + s.getContent())
                .collect(Collectors.joining("\n\n"));
            return new ParsedSummary(content, sections);
        } catch (Exception e) {
            // Fallback : réponse brute comme section unique "Résumé"
            return new ParsedSummary(rawResponse,
                List.of(new SummarySection("Résumé", "FileText", rawResponse)));
        }
    }

    private String extractJson(String text) {
        // Retire les éventuels blocs ```json ... ```
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start >= 0 && end > start) return text.substring(start, end + 1);
        return text;
    }

    public record ParsedSummary(String content, List<SummarySection> sections) {}
}
```

---

## Phase 6 — Brancher le PromptBuilder dans `SummaryServiceImpl`

### Architecture actuelle (le problème réel)

```
SummaryController
      │
      ▼
SummaryServiceImpl
  ├── validateFile()
  ├── computeSha256(bytes)       ← hash fichier seul, sans les options
  ├── extractText()
  ├── truncateIntelligently()
  └── callClaude(text)           ← ChatClient injecté DIRECTEMENT (ligne 62),
                                    PROMPT HARDCODÉ lignes 252–273,
                                    mode/focus/length/outputLanguage ignorés,
                                    OllamaAiService/GeminiService JAMAIS utilisés

AiProviderService (interface)    ← summarize(String text) — signature insuffisante
  ├── ClaudeAiService            ← prompt hardcodé indépendant
  └── GeminiService              ← idem
```

> **Double problème** :
> 1. `SummaryServiceImpl` bypasse `AiProviderService` en injectant `ChatClient` directement → Ollama et Gemini ne sont jamais utilisés pour les résumés, même si `active-provider=ollama`.
> 2. `AiProviderService.summarize(String text)` ne reçoit que le texte → le `PromptBuilder` ne peut pas injecter le prompt dynamique dans les providers.

### Architecture cible

> **Lien avec OLLAMA_QWEN_ROADMAP.md** : Le routage vers le bon provider est géré par `AiRoutingService` (PROMPT 4 du roadmap Ollama). Ce service résout le provider en fonction du plan de l'utilisateur (`UserPlan`) et de son `ProcessingMode` (LOCAL / CLOUD). `SummaryServiceImpl` délègue ce choix à `AiRoutingService` au lieu de dépendre d'un `@Primary` statique.

```
SummaryController  (reçoit mode/focus/length/outputLanguage → SummaryRequest)
      │
      ▼
SummaryServiceImpl
  ├── validateFile()
  ├── computeCacheKey(bytes, request)         ← hash fichier + options
  ├── extractText()
  ├── truncateIntelligently()
  ├── SummaryPromptBuilder.build(request)     ← prompt dynamique
  └── callAiProvider(builtPrompt, text, userId)  ← délègue à AiRoutingService
        │
        ▼
  AiRoutingService.resolve(userId, processingMode)   ← retourne AiRoutingDecision
        │
        ├─ LOCAL  → OllamaAiService  → REST → Ollama local (RGPD ✅)
        │     ├─ Anonymous / FREE → qwen3:1.7b / qwen3:7b
        │     └─ PRO / ENTERPRISE → qwen3:7b (Phase 1) / qwen2.5:14b (Phase 2+)
        └─ CLOUD  → ClaudeAiService / GeminiService → API externe (PRO opt-in)
```

### 6.1 Mettre à jour `AiProviderService` (interface)

**Fichier** : `src/main/java/com/kovixel/ai/service/AiProviderService.java`

```java
public interface AiProviderService {

    /**
     * Génère un résumé en appliquant le prompt dynamique fourni par SummaryPromptBuilder.
     * Le promptTemplate contient le placeholder {{document}} remplacé par documentText.
     */
    String summarize(String promptTemplate, String documentText);

    String generateResponse(String prompt);
}
```

> ⚠️ Ce changement casse `ClaudeAiService` et `GeminiService` — ils doivent être mis à jour en même temps (voir 6.2).

### 6.2 Mettre à jour `ClaudeAiService`

**Fichier** : `src/main/java/com/kovixel/ai/provider/ClaudeAiService.java`

```java
// Avant :
@Override
public String summarize(String text) {
    // prompt hardcodé en 3 sections
}

// Après — le prompt vient du PromptBuilder, ClaudeAiService ne construit plus rien :
@Override
public String summarize(String promptTemplate, String documentText) {
    String truncated = documentText.length() > MAX_TEXT_LENGTH
        ? documentText.substring(0, MAX_TEXT_LENGTH) + "\n[... texte tronqué]"
        : documentText;

    log.info("ClaudeAiService.summarize — {} chars envoyés à Claude", truncated.length());

    try {
        String result = chatClient.prompt()
            .user(u -> u
                .text(promptTemplate)          // ← injecté par SummaryPromptBuilder
                .param("document", truncated)) // ← {{document}} remplacé par Spring AI
            .call()
            .content();

        return result != null ? result.trim() : "";
    } catch (Exception e) {
        log.error("ClaudeAiService.summarize erreur — {}", e.getMessage(), e);
        throw new KovixelException(ErrorCode.AI_SERVICE_ERROR, HttpStatus.SERVICE_UNAVAILABLE,
            "Le service IA Claude est indisponible : " + e.getMessage(), e);
    }
}
```

Faire de même pour `GeminiService.summarize(String promptTemplate, String documentText)`.

### 6.3 Remplacer `ChatClient` par `AiRoutingService` dans `SummaryServiceImpl`

```java
// Avant (champ ligne 62) :
private final ChatClient chatClient;

// Après — AiRoutingService résout dynamiquement le provider selon userId + plan + processingMode :
private final AiRoutingService aiRoutingService;
private final SummaryPromptBuilder promptBuilder;
```

### 6.4 Renommer `callClaude()` en `callAiProvider()`

```java
// Avant :
private String callClaude(String text) {
    return chatClient.prompt()
        .user(u -> u.text("""...""").param("document", text))
        .call().content();
}

// Après — AiRoutingService résout le bon provider, callAiProvider() n'a plus de logique IA :
@Retryable(retryFor = KovixelException.class, maxAttempts = 3,
           backoff = @Backoff(delay = 2000, multiplier = 2.0, maxDelay = 30_000))
private String callAiProvider(String promptTemplate, String text, Long userId) {
    AiRoutingDecision decision = aiRoutingService.resolve(userId);
    log.info("Appel IA — provider={}, model={}, mode={}, {} chars",
        decision.providerName(), decision.modelName(), decision.processingMode(), text.length());
    return decision.provider().summarize(promptTemplate, text);
}
```

### 6.5 Mettre à jour `generateAndSave()`

```java
// 1. Nouvelle signature
private SummaryResponse generateAndSave(SummaryRequest request, byte[] bytes,
                                        String hash, Long userId) { ... }

// 2. Construire le prompt dynamique
String builtPrompt = promptBuilder.build(request);

// 3. Appel IA via AiRoutingService (provider + modèle résolus selon plan + processingMode)
long t0 = System.currentTimeMillis();
AiRoutingDecision decision = aiRoutingService.resolve(userId);
String content = callAiProvider(builtPrompt, processedText, userId);
int durationMs = (int)(System.currentTimeMillis() - t0);

// 4. Le champ engine vient directement de AiRoutingDecision
String engine = decision.providerName() + ":" + decision.modelName();
// ex: "ollama:qwen3:7b" | "claude:claude-sonnet-4-5" | "gemini:gemini-2.5-flash"
```

### 6.6 Récapitulatif — fichiers et lignes touchés

| Fichier | Avant | Après |
|---------|-------|-------|
| `AiProviderService.java` | `summarize(String text)` | `summarize(String promptTemplate, String text)` |
| `ClaudeAiService.java` | prompt hardcodé | délègue le prompt entrant au `ChatClient` |
| `GeminiService.java` | prompt hardcodé | idem (même pattern) |
| `SummaryServiceImpl.java:62` | `ChatClient chatClient` | `AiRoutingService aiRoutingService` + `SummaryPromptBuilder promptBuilder` |
| `SummaryServiceImpl.java:77` | `summarize(MultipartFile, Long)` | `summarize(SummaryRequest, Long)` |
| `SummaryServiceImpl.java:82` | `computeSha256(bytes)` | `computeCacheKey(bytes, request)` |
| `SummaryServiceImpl.java:138` | `callClaude(processedText)` | `callAiProvider(builtPrompt, processedText, userId)` |
| `SummaryServiceImpl.java:248` | méthode `callClaude(String text)` | méthode `callAiProvider(String prompt, String text, Long userId)` |
| **`AiRoutingService.java`** (nouveau) | — | Résout provider + modèle selon plan + processingMode (voir OLLAMA_QWEN_ROADMAP.md PROMPT 4) |

> **Résultat** : le provider IA est désormais résolu dynamiquement par `AiRoutingService` selon le plan de l'utilisateur (`FREE`→Ollama, `PRO LOCAL`→Ollama PRO, `PRO CLOUD`→Claude/Gemini). Aucune variable d'environnement statique à changer, le routage est piloté par les données utilisateur.

---

## Phase 7 — Tests

### 7.1 Tests unitaires `SummaryPromptBuilderTest.java`

```java
@Test void modeExecutive_shouldContainCsuite() {
    SummaryRequest req = SummaryRequest.builder()
        .mode(SummaryMode.EXECUTIVE).focus(SummaryFocus.GENERAL)
        .length(SummaryLength.SHORT).outputLanguage(SummaryOutputLanguage.AUTO).build();
    String prompt = builder.build(req);
    assertThat(prompt).contains("C-suite").contains("150 mots");
}

@Test void outputLanguageFR_shouldForceLanguage() {
    // ...
    assertThat(prompt).contains("EXCLUSIVEMENT en **français**");
}

@Test void noCustomInstruction_shouldNotContainSection() {
    // ...
    assertThat(prompt).doesNotContain("Instructions personnalisées");
}
```

### 7.2 Tests unitaires `SummaryResponseParserTest.java`

```java
@Test void validJson_shouldExtractSections() { ... }
@Test void jsonInCodeBlock_shouldStripMarkdown() { ... }
@Test void invalidJson_shouldFallbackToRawContent() { ... }
```

### 7.3 Test d'intégration `SummaryControllerIT.java`

```java
@SpringBootTest @AutoConfigureMockMvc
class SummaryControllerIT {
    @Test void summarize_withModeBullets_shouldReturnSections() throws Exception {
        MockMultipartFile pdf = new MockMultipartFile("file", "test.pdf",
            "application/pdf", pdfBytes());
        mockMvc.perform(multipart("/api/v1/documents/summarize")
            .file(pdf)
            .param("mode", "bullets")
            .param("focus", "financial")
            .param("length", "short")
            .param("outputLanguage", "fr")
            .header("Authorization", "Bearer " + testToken()))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.sections").isArray())
            .andExpect(jsonPath("$.engine").value("claude"))
            .andExpect(jsonPath("$.durationMs").isNumber())
            .andExpect(jsonPath("$.mode").value("BULLETS"));
    }
}
```

### 7.4 Test de non-régression cache

```java
@Test void samePdfDifferentMode_shouldReturnDifferentSummaries() {
    // Appel 1 : mode STANDARD → summaryId_1
    // Appel 2 : même PDF, mode EXECUTIVE → summaryId_2
    assertThat(summaryId_1).isNotEqualTo(summaryId_2);
    // Appel 3 : même PDF, mode STANDARD → summaryId_1 (cache hit)
    assertThat(summaryId_3).isEqualTo(summaryId_1);
}
```

---

## Phase 8 — OpenAPI + polish final

### 8.1 Mettre à jour les annotations Swagger sur `SummaryController`

```java
@Operation(summary = "Génère un résumé IA d'un document PDF",
    description = "Upload un PDF et retourne un résumé structuré selon le mode, focus, longueur et langue choisis.")
@ApiResponses({
    @ApiResponse(responseCode = "200", description = "Résumé généré ou récupéré depuis le cache",
        content = @Content(schema = @Schema(implementation = SummaryResponse.class))),
    @ApiResponse(responseCode = "400", description = "Fichier invalide ou paramètres incorrects"),
    @ApiResponse(responseCode = "413", description = "Fichier trop volumineux (max 20 MB)"),
    @ApiResponse(responseCode = "415", description = "Type MIME non supporté (PDF uniquement)"),
    @ApiResponse(responseCode = "503", description = "Service IA temporairement indisponible")
})
```

### 8.2 Vérifier la cohérence des messages d'erreur

| Cas | Code HTTP | Message JSON |
|-----|-----------|--------------|
| MIME != application/pdf | 415 | `{ "error": "UNSUPPORTED_MEDIA_TYPE", "message": "Seuls les fichiers PDF sont acceptés." }` |
| Taille > 20 MB | 413 | `{ "error": "PAYLOAD_TOO_LARGE", "message": "Le fichier ne doit pas dépasser 20 MB." }` |
| Claude timeout/quota | 503 | `{ "error": "AI_SERVICE_UNAVAILABLE", "message": "Le service IA est temporairement indisponible. Réessayez dans quelques instants." }` |
| customInstruction > 500 chars | 400 | `{ "error": "VALIDATION_ERROR", "message": "L'instruction personnalisée ne doit pas dépasser 500 caractères." }` |

### 8.3 Vérifier l'endpoint GET existant

`GET /api/v1/documents/{documentId}/summary` doit aussi retourner les nouveaux champs (`engine`, `durationMs`, `sections`, `mode`, etc.) via le `SummaryMapper` mis à jour.

---

## Ordre d'implémentation recommandé

```
Phase 1 → Phase 2 → Phase 3 → Phase 6 → Phase 4 → Phase 5 → Phase 7 → Phase 8
  (DTOs)   (cache)   (DB)    (AiService)  (Prompt)  (Parser)  (Tests)  (Swagger)
```

> Commencer par Phase 6 (refactor AiService) avant Phase 4 (PromptBuilder) évite de toucher deux fois au même fichier.

---

## Checklist de livraison

- [ ] `SummaryRequest.java` + enums créés
- [ ] `SummaryController` transmet les options au service
- [ ] `computeCacheKey()` inclut mode/focus/length/outputLanguage
- [ ] `V4__add_summary_options.sql` appliquée
- [ ] Entité `Summary` mise à jour avec nouveaux champs
- [ ] `AiProviderService.summarize(String promptTemplate, String documentText)` — nouvelle signature
- [ ] `ClaudeAiService.summarize()` — implémente nouvelle signature, retire le prompt hardcodé
- [ ] `GeminiService.summarize()` — idem
- [ ] `AiRoutingService` implémenté (voir OLLAMA_QWEN_ROADMAP.md PROMPT 4) — résout provider + modèle selon userId + plan + processingMode
- [ ] `SummaryServiceImpl` injecte `AiRoutingService` + `SummaryPromptBuilder` au lieu de `ChatClient`
- [ ] `SummaryServiceImpl.callAiProvider(prompt, text, userId)` remplace `callClaude()`, délègue via `AiRoutingService`
- [ ] Champ `engine` dans `Summary` + réponse = `"providerName:modelName"` (ex: `"ollama:qwen3:7b"`)
- [ ] `SummaryPromptBuilder` implémenté (5 modes × 6 focus)
- [ ] `SummaryResponseParser` gère JSON + fallback
- [ ] `SummaryResponse` inclut engine, durationMs, sections, mode, focus, length
- [ ] `SummaryMapper` mis à jour
- [ ] `SummaryServiceImpl` câble tout le pipeline
- [ ] Tests unitaires PromptBuilder (≥ 8 cas)
- [ ] Tests unitaires Parser (≥ 3 cas)
- [ ] Test d'intégration Controller (≥ 3 scenarios)
- [ ] Test non-régression cache multi-options
- [ ] Swagger mis à jour
- [ ] Messages d'erreur cohérents
- [ ] Test manuel end-to-end avec le frontend

---

## Fichiers touchés (récapitulatif)

| Action | Fichier |
|--------|---------|
| **Créer** | `dto/SummaryRequest.java` |
| **Créer** | `dto/SummaryMode.java`, `SummaryFocus.java`, `SummaryLength.java`, `SummaryOutputLanguage.java` |
| **Créer** | `dto/SummarySection.java` |
| **Créer** | `service/SummaryPromptBuilder.java` |
| **Créer** | `service/SummaryResponseParser.java` |
| **Créer** | `db/migration/V4__add_summary_options.sql` |
| **Modifier** | `controller/SummaryController.java` |
| **Modifier** | `service/SummaryService.java` (interface) |
| **Modifier** | `service/SummaryServiceImpl.java` — remplacer `ChatClient` par `AiProviderService` + `SummaryPromptBuilder` |
| **Modifier** | `dto/SummaryResponse.java` |
| **Modifier** | `dto/SummaryMapper.java` |
| **Modifier** | `entity/Summary.java` |
| **Modifier** | `ai/service/AiProviderService.java` — nouvelle signature `summarize(promptTemplate, text)` |
| **Modifier** | `provider/ClaudeAiService.java` — implémenter nouvelle signature, retirer prompt hardcodé |
| **Modifier** | `provider/GeminiService.java` — idem |
| **Créer** | `ai/routing/AiRoutingService.java` — voir OLLAMA_QWEN_ROADMAP.md PROMPT 4 |
| **Créer** | `ai/routing/AiRoutingDecision.java` — record (provider, providerName, modelName, processingMode) |
| **Note** | `provider/ollama/OllamaAiService.java` — voir OLLAMA_QWEN_ROADMAP.md PROMPT 3 |
| **Créer (tests)** | `SummaryPromptBuilderTest.java` |
| **Créer (tests)** | `SummaryResponseParserTest.java` |
| **Créer (tests)** | `SummaryControllerIT.java` |
