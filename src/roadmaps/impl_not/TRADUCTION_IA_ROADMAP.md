# Roadmap — Outil "Traduction IA" (Kovixel)

> **Objectif** : Délivrer un outil de traduction de documents PDF vers 30+ langues,
> alimenté par le routing IA (Ollama / Claude), accessible aux utilisateurs anonymes et authentifiés.
> Structure du document préservée (titres, listes, paragraphes).
> Sortie : texte traduit + téléchargement TXT / MD / PDF généré.

---

## Audit initial (2026-06-13)

| Composant | État |
|-----------|------|
| Backend (packages, controller, service, entity) | ❌ Inexistant |
| Migrations SQL | ❌ Inexistant |
| Frontend composant | ❌ Inexistant |
| Frontend service + modèle | ❌ Inexistant |
| Entrée dans `tools-config.ts` | ✅ Présente (badge `SOON`, `isAvailable: false`) |
| Route Angular | ❌ Inexistante |
| Quota Redis | ❌ Inexistant (méthodes à ajouter dans `AnonymousQuotaService`) |

**Conclusion** : implémentation entièrement greenfield. L'architecture est à concevoir de zéro,
en cohérence avec les patterns Q&A et Résumé IA déjà en production.

---

## Architecture cible

### Routing IA
```
Anonyme        → Ollama qwen3:1.7b   (local, modèle léger)
FREE           → Ollama qwen3:7b     (local)
PRO/ENT+LOCAL  → Ollama qwen3:7b     (local)
PRO/ENT+CLOUD  → Claude Sonnet       (cloud, fallback Ollama)
```

### Quota (Redis)
```
Anonyme : 2 traductions / jour / IP, max 10 pages / document
FREE    : 15 traductions / mois, max 30 pages / document
PRO     : illimité, max 100 pages / document
ENTERPRISE : illimité, pages illimitées
```
Clés Redis anonymes :
```
translate:anon:{ip}:daily:{date}         → 2/jour/IP (global)
translate:anon:{ip}:doc:{documentId}:{date} → 1/jour/IP/doc
```

### Endpoints
```
POST /api/v1/documents/{documentId}/translate         → lancer une traduction (anon + auth)
GET  /api/v1/documents/{documentId}/translations      → historique (auth requis)
GET  /api/v1/translations/{id}                        → détail résultat (auth requis)
GET  /api/v1/translations/{id}/download               → téléchargement (anon pour résultat immédiat)
GET  /api/v1/translate/languages                      → liste des langues supportées (public)
```

### Pipeline de traduction
```
PDF
 └─ [TextExtractor] → texte brut (déjà disponible via SummaryDocument.extractedText)
      └─ [TextSegmenter] → chunks ≤ 1500 mots, respectant les frontières de paragraphes
           └─ [AiRoutingService] → provider résolu (Ollama / Claude)
                └─ boucle : traduire chunk par chunk (avec contexte chevauchant)
                     └─ [assembler] → texte traduit complet (Markdown structuré)
                          └─ [cache] → stocker dans translation_results
                               └─ Réponse : texte + métadonnées
```

### Gestion asynchrone (grands documents)
```
Document ≤ 5 pages  → synchrone (HTTP 201 immédiat)
Document > 5 pages  → asynchrone : AiJob de type TRANSLATION + polling via /api/v1/jobs/{jobId}
```

---

## Langues supportées (30+)

### Groupe A — Europe occidentale
| Code | Langue | Natif |
|------|--------|-------|
| `fr` | Français | Français |
| `en` | Anglais | English |
| `es` | Espagnol | Español |
| `de` | Allemand | Deutsch |
| `it` | Italien | Italiano |
| `pt` | Portugais | Português |
| `nl` | Néerlandais | Nederlands |
| `sv` | Suédois | Svenska |
| `da` | Danois | Dansk |
| `no` | Norvégien | Norsk |
| `fi` | Finnois | Suomi |

### Groupe B — Europe orientale & centrale
| Code | Langue | Natif |
|------|--------|-------|
| `pl` | Polonais | Polski |
| `cs` | Tchèque | Čeština |
| `sk` | Slovaque | Slovenčina |
| `ro` | Roumain | Română |
| `hu` | Hongrois | Magyar |
| `bg` | Bulgare | Български |
| `hr` | Croate | Hrvatski |
| `el` | Grec | Ελληνικά |
| `ru` | Russe | Русский |
| `uk` | Ukrainien | Українська |

### Groupe C — Moyen-Orient & Afrique
| Code | Langue | Natif | Note |
|------|--------|-------|------|
| `ar` | Arabe | العربية | RTL |
| `he` | Hébreu | עברית | RTL |
| `tr` | Turc | Türkçe | |

### Groupe D — Asie
| Code | Langue | Natif |
|------|--------|-------|
| `zh-cn` | Chinois simplifié | 中文（简体） |
| `zh-tw` | Chinois traditionnel | 中文（繁體） |
| `ja` | Japonais | 日本語 |
| `ko` | Coréen | 한국어 |
| `vi` | Vietnamien | Tiếng Việt |
| `th` | Thaï | ภาษาไทย |
| `id` | Indonésien | Bahasa Indonesia |
| `ms` | Malais | Bahasa Melayu |

---

## Phase 1 — Fondations Backend (Greenfield)

> **Durée estimée** : 2–3 jours  
> **Priorité** : 🔴 Bloquante

### 1.1 Migration SQL

**`V23__create_translation_tables.sql`**

```sql
-- =========================================================================
-- V23 — Table des résultats de traduction IA
-- =========================================================================
CREATE TABLE IF NOT EXISTS translation_results (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id           UUID        NOT NULL
                              CONSTRAINT fk_translation_document
                              REFERENCES summary_documents(id) ON DELETE CASCADE,
    user_id               BIGINT,     -- null pour les anonymes
    source_lang           VARCHAR(10) NOT NULL,  -- 'auto', 'fr', 'en', etc.
    detected_source_lang  VARCHAR(10),            -- langue détectée si source='auto'
    target_lang           VARCHAR(10) NOT NULL,
    mode                  VARCHAR(20) NOT NULL DEFAULT 'STANDARD',
    result_text           TEXT,                   -- texte traduit (Markdown)
    page_count            INTEGER,
    word_count_source     INTEGER,
    word_count_translated INTEGER,
    model                 VARCHAR(100),
    engine                VARCHAR(100),            -- 'ollama:qwen3:7b' ou 'claude:...'
    tokens_used           INTEGER,
    duration_ms           INTEGER,
    cached                BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at            TIMESTAMP   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_translation_document_id
    ON translation_results (document_id);
CREATE INDEX IF NOT EXISTS idx_translation_user_id
    ON translation_results (user_id);
-- Recherche cache efficace (doc + paire de langues + mode)
CREATE INDEX IF NOT EXISTS idx_translation_cache_lookup
    ON translation_results (document_id, source_lang, target_lang, mode);
```

### 1.2 Entity & Repository

**`TranslationResult.java`** (`com.kovixel.ai.translation.entity`)
```java
@Entity
@Table(name = "translation_results")
@Getter @Setter @Builder @NoArgsConstructor @AllArgsConstructor
public class TranslationResult {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "document_id", nullable = false)
    private SummaryDocument document;

    @Column(name = "user_id")
    private Long userId;

    @Column(nullable = false, length = 10)
    private String sourceLang;           // 'auto', 'fr', etc.

    @Column(length = 10)
    private String detectedSourceLang;   // renseigné si sourceLang='auto'

    @Column(nullable = false, length = 10)
    private String targetLang;

    @Column(nullable = false, length = 20)
    private String mode;                 // STANDARD | QUALITY

    @Column(columnDefinition = "TEXT")
    private String resultText;           // texte traduit (Markdown)

    private Integer pageCount;
    private Integer wordCountSource;
    private Integer wordCountTranslated;

    @Column(length = 100)
    private String model;

    @Column(length = 100)
    private String engine;

    private Integer tokensUsed;
    private Integer durationMs;
    private boolean cached;

    @Column(nullable = false)
    private LocalDateTime createdAt;

    @PrePersist
    protected void onCreate() {
        if (createdAt == null) createdAt = LocalDateTime.now();
    }
}
```

**`TranslationResultRepository.java`**
```java
public interface TranslationResultRepository extends JpaRepository<TranslationResult, UUID> {

    // Cache lookup
    Optional<TranslationResult> findFirstByDocumentIdAndSourceLangAndTargetLangAndMode(
        UUID documentId, String sourceLang, String targetLang, String mode);

    // Historique utilisateur
    List<TranslationResult> findByDocumentIdAndUserIdOrderByCreatedAtDesc(
        UUID documentId, Long userId);

    // Ownership check
    Optional<TranslationResult> findByIdAndUserId(UUID id, Long userId);

    // Pagination pour l'historique global user
    Page<TranslationResult> findByUserIdOrderByCreatedAtDesc(Long userId, Pageable pageable);
}
```

### 1.3 DTOs

**`TranslationRequest.java`**
```java
public record TranslationRequest(
    @NotBlank @Size(max = 10)  String sourceLang,  // 'auto' ou code ISO 639-1
    @NotBlank @Size(max = 10)  String targetLang,
    @Pattern(regexp = "STANDARD|QUALITY") String mode  // défaut : STANDARD
) {
    public TranslationRequest {
        if (mode == null || mode.isBlank()) mode = "STANDARD";
    }
}
```

**`TranslationResponse.java`**
```java
public record TranslationResponse(
    UUID   id,
    UUID   documentId,
    String sourceLang,
    String detectedSourceLang,  // null si sourceLang != 'auto'
    String targetLang,
    String mode,
    String resultText,          // texte Markdown traduit
    Integer pageCount,
    Integer wordCountSource,
    Integer wordCountTranslated,
    String  engine,             // 'ollama:qwen3:7b'
    Integer tokensUsed,
    Integer durationMs,
    boolean cached,
    LocalDateTime createdAt
) {}
```

**`LanguageInfo.java`** (record immuable)
```java
public record LanguageInfo(
    String code,    // 'fr', 'en', 'zh-cn'
    String name,    // 'Français', 'English'
    String nativeName, // 'Français', '中文'
    String group,   // 'western_europe', 'eastern_europe', 'asia', etc.
    boolean rtl     // true pour ar, he
) {}
```

**`SupportedLanguages.java`** (constante statique)
```java
public final class SupportedLanguages {
    public static final List<LanguageInfo> ALL = List.of(
        new LanguageInfo("auto", "Détection automatique", "Auto", "special", false),
        new LanguageInfo("fr",   "Français",   "Français",  "western_europe", false),
        new LanguageInfo("en",   "Anglais",    "English",   "western_europe", false),
        new LanguageInfo("es",   "Espagnol",   "Español",   "western_europe", false),
        new LanguageInfo("de",   "Allemand",   "Deutsch",   "western_europe", false),
        new LanguageInfo("it",   "Italien",    "Italiano",  "western_europe", false),
        new LanguageInfo("pt",   "Portugais",  "Português", "western_europe", false),
        new LanguageInfo("nl",   "Néerlandais","Nederlands","western_europe", false),
        new LanguageInfo("sv",   "Suédois",    "Svenska",   "western_europe", false),
        new LanguageInfo("da",   "Danois",     "Dansk",     "western_europe", false),
        new LanguageInfo("no",   "Norvégien",  "Norsk",     "western_europe", false),
        new LanguageInfo("fi",   "Finnois",    "Suomi",     "western_europe", false),
        new LanguageInfo("pl",   "Polonais",   "Polski",    "eastern_europe", false),
        new LanguageInfo("cs",   "Tchèque",    "Čeština",   "eastern_europe", false),
        new LanguageInfo("sk",   "Slovaque",   "Slovenčina","eastern_europe", false),
        new LanguageInfo("ro",   "Roumain",    "Română",    "eastern_europe", false),
        new LanguageInfo("hu",   "Hongrois",   "Magyar",    "eastern_europe", false),
        new LanguageInfo("bg",   "Bulgare",    "Български", "eastern_europe", false),
        new LanguageInfo("hr",   "Croate",     "Hrvatski",  "eastern_europe", false),
        new LanguageInfo("el",   "Grec",       "Ελληνικά",  "eastern_europe", false),
        new LanguageInfo("ru",   "Russe",      "Русский",   "eastern_europe", false),
        new LanguageInfo("uk",   "Ukrainien",  "Українська","eastern_europe", false),
        new LanguageInfo("ar",   "Arabe",      "العربية",   "middle_east",    true),
        new LanguageInfo("he",   "Hébreu",     "עברית",     "middle_east",    true),
        new LanguageInfo("tr",   "Turc",       "Türkçe",    "middle_east",    false),
        new LanguageInfo("zh-cn","Chinois (simplifié)","中文（简体）","asia",  false),
        new LanguageInfo("zh-tw","Chinois (traditionnel)","中文（繁體）","asia",false),
        new LanguageInfo("ja",   "Japonais",   "日本語",    "asia",           false),
        new LanguageInfo("ko",   "Coréen",     "한국어",    "asia",           false),
        new LanguageInfo("vi",   "Vietnamien", "Tiếng Việt","asia",           false),
        new LanguageInfo("th",   "Thaï",       "ภาษาไทย",  "asia",           false),
        new LanguageInfo("id",   "Indonésien", "Bahasa Indonesia","asia",     false),
        new LanguageInfo("ms",   "Malais",     "Bahasa Melayu",  "asia",      false)
    );

    public static Optional<LanguageInfo> find(String code) {
        return ALL.stream().filter(l -> l.code().equals(code)).findFirst();
    }
}
```

### 1.4 TextSegmenter

**`TextSegmenter.java`** (`com.kovixel.ai.translation.service`)
```java
/**
 * Découpe un texte long en segments traduisibles.
 *
 * Stratégie :
 *  - Découpe sur les frontières de paragraphes (double saut de ligne)
 *  - Respecte une taille maximale de MAX_WORDS mots par chunk
 *  - Chaque chunk inclut un overlap (dernière phrase du chunk précédent)
 *    pour conserver le contexte entre appels IA
 */
@Component
public class TextSegmenter {

    private static final int MAX_WORDS_PER_CHUNK = 1200; // ~1600 tokens
    private static final int OVERLAP_SENTENCES   = 1;

    /**
     * @return liste ordonnée de chunks à traduire
     */
    public List<String> segment(String text) { ... }

    /** Compte approximatif de mots (pour estimer les tokens). */
    public int wordCount(String text) { ... }

    /** Estime le nombre de pages (~250 mots/page). */
    public int estimatePageCount(String text) { ... }
}
```

### 1.5 TranslationService

**`TranslationService.java`** (interface)
```java
public interface TranslationService {
    TranslationResponse translate(UUID documentId, TranslationRequest request,
                                  Long userId, String clientIp);
    List<TranslationResponse> getHistory(UUID documentId, Long userId);
    TranslationResponse getById(UUID translationId, Long userId);
    List<LanguageInfo> getSupportedLanguages();
}
```

**`TranslationServiceImpl.java`** — points clés

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class TranslationServiceImpl implements TranslationService {

    private static final int MAX_TEXT_LENGTH = 150_000; // ~600 pages
    private static final int ASYNC_THRESHOLD_WORDS = 2_500; // > 10 pages → async

    // Prompts
    private static final String SYSTEM_PROMPT_TRANSLATE = """
        Tu es un traducteur professionnel expert. Traduis le texte ci-dessous de %s vers %s.

        Règles absolues :
        1. Préserve EXACTEMENT la structure Markdown (# titres, - listes, paragraphes séparés par une ligne vide)
        2. Maintiens le registre du texte source (formel / informel / technique)
        3. Ne traduis pas les noms propres, acronymes et termes techniques universels (ex : PDF, API, URL)
        4. Si un terme n'a pas d'équivalent naturel, garde l'original entre parenthèses après la traduction
        5. Retourne UNIQUEMENT le texte traduit — aucun commentaire, aucune explication
        """;

    private static final String SYSTEM_PROMPT_AUTO_DETECT = """
        Tu es un traducteur expert. Détecte la langue du texte ci-dessous, puis traduis-le vers %s.
        Réponds UNIQUEMENT avec un JSON strict : {"detected": "fr", "translation": "texte traduit..."}
        """;

    @Override
    public TranslationResponse translate(UUID documentId, TranslationRequest request,
                                          Long userId, String clientIp) {
        // 1. Quota anonyme
        if (userId == null) {
            anonymousQuotaService.checkAndIncrementTranslation(clientIp, documentId.toString());
        }

        // 2. Charger + ownership check
        SummaryDocument doc = loadDocument(documentId, userId);
        String text = resolveText(doc);

        // 3. Vérifier page limit selon plan
        int pageCount = segmenter.estimatePageCount(text);
        enforcePageLimit(pageCount, userId);

        // 4. Cache lookup (documentId + sourceLang + targetLang + mode)
        Optional<TranslationResult> cached = resultRepository
            .findFirstByDocumentIdAndSourceLangAndTargetLangAndMode(
                documentId, request.sourceLang(), request.targetLang(), request.mode());
        if (cached.isPresent()) {
            log.info("Cache hit — traduction documentId={}", documentId);
            return toResponse(cached.get(), true);
        }

        // 5. Segmentation
        List<String> chunks = segmenter.segment(text);
        int wordCount = segmenter.wordCount(text);

        // 6. AI routing
        AiRoutingDecision decision = aiRoutingService.resolve(userId);

        // 7. Traduction par chunks
        long t0 = System.currentTimeMillis();
        String translatedText = translateChunks(chunks, request, decision);
        int durationMs = (int)(System.currentTimeMillis() - t0);

        // 8. Extraction langue détectée (si auto)
        String detectedLang = null;
        if ("auto".equals(request.sourceLang())) {
            detectedLang = parseDetectedLang(translatedText);
            translatedText = parseTranslationFromAutoResponse(translatedText);
        }

        // 9. Persistance
        TranslationResult result = resultRepository.save(TranslationResult.builder()
            .document(doc).userId(userId)
            .sourceLang(request.sourceLang()).detectedSourceLang(detectedLang)
            .targetLang(request.targetLang()).mode(request.mode())
            .resultText(translatedText)
            .pageCount(pageCount).wordCountSource(wordCount)
            .wordCountTranslated(segmenter.wordCount(translatedText))
            .model(decision.modelName()).engine(decision.engineLabel())
            .tokensUsed(estimateTokens(text, translatedText))
            .durationMs(durationMs).cached(false)
            .build());

        // 10. Usage tracking (async, skip si anonyme)
        if (userId != null) trackUsage(result, userId);

        return toResponse(result, false);
    }

    private String translateChunks(List<String> chunks, TranslationRequest req,
                                    AiRoutingDecision decision) {
        StringBuilder result = new StringBuilder();
        String sourceLangLabel = getLangLabel(req.sourceLang());
        String targetLangLabel = getLangLabel(req.targetLang());
        boolean autoDetect = "auto".equals(req.sourceLang());

        for (int i = 0; i < chunks.size(); i++) {
            String chunk = chunks.get(i);
            String systemPrompt = autoDetect && i == 0
                ? String.format(SYSTEM_PROMPT_AUTO_DETECT, targetLangLabel)
                : String.format(SYSTEM_PROMPT_TRANSLATE, sourceLangLabel, targetLangLabel);

            String translated = decision.provider().generateResponse(systemPrompt + "\n\n" + chunk);
            if (i > 0) result.append("\n\n");
            result.append(translated.trim());
        }
        return result.toString();
    }

    private void enforcePageLimit(int pageCount, Long userId) {
        int maxPages = resolveMaxPages(userId);
        if (pageCount > maxPages) {
            throw new KovixelException(ErrorCode.QUOTA_EXCEEDED, HttpStatus.FORBIDDEN,
                String.format("Ce document dépasse la limite de %d pages pour votre plan.", maxPages));
        }
    }

    private int resolveMaxPages(Long userId) {
        if (userId == null) return 10;    // anonyme
        User user = userRepository.findById(userId).orElse(null);
        if (user == null) return 10;
        return switch (user.getPlan() != null ? user.getPlan() : UserPlan.FREE) {
            case FREE       -> 30;
            case PRO        -> 100;
            case ENTERPRISE -> Integer.MAX_VALUE;
        };
    }
}
```

### 1.6 Controller

**`TranslationController.java`**
```java
@Slf4j
@RestController
@RequiredArgsConstructor
@Tag(name = "Traduction IA", description = "Traduction neurale de documents PDF vers 30+ langues")
public class TranslationController {

    private final TranslationService translationService;

    @PostMapping("/api/v1/documents/{documentId}/translate")
    @Operation(summary = "Traduire un document",
               description = "Accesssible sans compte (quota IP). Source 'auto' pour détection automatique.")
    public ResponseEntity<TranslationResponse> translate(
            @PathVariable UUID documentId,
            @Valid @RequestBody TranslationRequest request,
            @AuthenticationPrincipal UserDetails userDetails,
            HttpServletRequest httpRequest) {

        Long userId = resolveUserId(userDetails);
        String clientIp = resolveIp(httpRequest);
        log.info("Traduction — docId={}, {}→{}, user={}", documentId,
                request.sourceLang(), request.targetLang(),
                userId != null ? userDetails.getUsername() : "anonymous");

        return ResponseEntity.status(HttpStatus.CREATED)
                .body(translationService.translate(documentId, request, userId, clientIp));
    }

    @GetMapping("/api/v1/documents/{documentId}/translations")
    @Operation(summary = "Historique des traductions d'un document")
    public ResponseEntity<List<TranslationResponse>> getHistory(
            @PathVariable UUID documentId,
            @AuthenticationPrincipal UserDetails userDetails) {
        Long userId = resolveUserId(userDetails);
        if (userId == null) throw new KovixelException(ErrorCode.ACCESS_DENIED,
                HttpStatus.UNAUTHORIZED, "Connexion requise pour l'historique.");
        return ResponseEntity.ok(translationService.getHistory(documentId, userId));
    }

    @GetMapping("/api/v1/translations/{id}/download")
    @Operation(summary = "Télécharger le résultat d'une traduction",
               description = "Formats : txt | md | pdf")
    public ResponseEntity<byte[]> download(
            @PathVariable UUID id,
            @RequestParam(defaultValue = "txt") String format,
            @AuthenticationPrincipal UserDetails userDetails) {
        Long userId = resolveUserId(userDetails);
        TranslationResponse result = translationService.getById(id, userId);
        // ... génération du fichier selon format
    }

    @GetMapping("/api/v1/translate/languages")
    @Operation(summary = "Liste des langues supportées (public)")
    public ResponseEntity<List<LanguageInfo>> getSupportedLanguages() {
        return ResponseEntity.ok(translationService.getSupportedLanguages());
    }

    private Long resolveUserId(UserDetails u) { ... }  // null si anonyme
    private String resolveIp(HttpServletRequest r) { ... }
}
```

### 1.7 AnonymousQuotaService — extension

```java
// Constantes à ajouter
public static final int TRANSLATE_DAILY_LIMIT     = 2;  // 2/jour/IP
public static final int TRANSLATE_DOC_DAILY_LIMIT = 1;  // 1/jour/IP/doc

public void checkAndIncrementTranslation(String ip, String documentId) {
    // Même pattern que checkAndIncrementQna()
    // Clés :
    //   translate:anon:{ip}:daily:{date}
    //   translate:anon:{ip}:doc:{documentId}:{date}
}
```

### 1.8 SecurityConfig — extension

```java
private static final String[] PUBLIC_ENDPOINTS = {
    // ... endpoints existants ...
    "/api/v1/documents/*/translate",          // POST traduction (anon + auth)
    "/api/v1/translate/languages",            // GET liste langues (public)
    // GET /translations/{id}/download laissé protected (auth required)
};
```

### 1.9 ExportService de traduction

**`TranslationExportService.java`**
```java
@Service
public class TranslationExportService {

    /** Export TXT : texte brut sans Markdown. */
    public byte[] toTxt(TranslationResult result) { ... }

    /** Export MD : texte Markdown tel quel. */
    public byte[] toMarkdown(TranslationResult result) { ... }

    /**
     * Export PDF : rendu du Markdown traduit via Markdown → HTML → PDF.
     * Utilise Commonmark (parsing MD) + Flying Saucer ou OpenHtmlToPdf.
     * En-tête : nom document source, langue de traduction, date, moteur IA.
     */
    public byte[] toPdf(TranslationResult result) { ... }
}
```

---

## Phase 2 — Frontend

> **Durée estimée** : 2–3 jours  
> **Priorité** : 🔴 Bloquante (rien à montrer sans le UI)

### 2.1 Modèle TypeScript

**`translation.model.ts`**
```typescript
export interface LanguageInfo {
  code: string;           // 'fr', 'en', 'zh-cn'
  name: string;           // 'Français', 'Anglais'
  nativeName: string;     // 'Français', 'English'
  group: 'western_europe' | 'eastern_europe' | 'middle_east' | 'asia' | 'special';
  rtl: boolean;
}

export type TranslationMode = 'STANDARD' | 'QUALITY';

export interface TranslationRequest {
  sourceLang: string;     // 'auto' ou code ISO
  targetLang: string;
  mode?: TranslationMode;
}

export interface TranslationResponse {
  id: string;
  documentId: string;
  sourceLang: string;
  detectedSourceLang?: string;   // renseigné si sourceLang='auto'
  targetLang: string;
  mode: TranslationMode;
  resultText: string;            // Markdown
  pageCount?: number;
  wordCountSource?: number;
  wordCountTranslated?: number;
  engine?: string;               // 'ollama:qwen3:7b'
  tokensUsed?: number;
  durationMs?: number;
  cached: boolean;
  createdAt: string;
}

export interface TranslationHistoryItem extends TranslationResponse {
  preview: string;  // premiers 120 chars du resultText (brut)
}
```

### 2.2 Service TypeScript

**`translation.service.ts`**
```typescript
@Injectable({ providedIn: 'root' })
export class TranslationService {
  private readonly base = `${environment.apiUrl}/v1`;

  getLanguages(): Observable<LanguageInfo[]> {
    return this.http.get<LanguageInfo[]>(`${this.base}/translate/languages`);
  }

  translate(documentId: string, request: TranslationRequest): Observable<TranslationResponse> {
    return this.http.post<TranslationResponse>(
      `${this.base}/documents/${documentId}/translate`, request
    ).pipe(timeout(5 * 60 * 1000));   // 5 min max (grands docs)
  }

  getHistory(documentId: string): Observable<TranslationResponse[]> {
    return this.http.get<TranslationResponse[]>(
      `${this.base}/documents/${documentId}/translations`
    );
  }

  download(translationId: string, format: 'txt' | 'md' | 'pdf'): Observable<Blob> {
    return this.http.get(`${this.base}/translations/${translationId}/download`,
      { params: { format }, responseType: 'blob' }
    );
  }

  triggerDownload(blob: Blob, filename: string): void {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = filename; a.click();
    URL.revokeObjectURL(url);
  }
}
```

### 2.3 Composant — Layout général

**`translation.component.ts`** — Structure complète :

```
┌─────────────────────────────────────────────────────────────────┐
│  Header : "Traduction IA"  [ badge moteur IA ]                  │
├────────────────────┬────────────────────────────────────────────┤
│  Sélecteur document│           Zone principale                  │
│  + Upload PDF      │                                            │
│  ────────────────  │  ┌──────────────────────────────────────┐  │
│  Config :          │  │  Configuration de la traduction      │  │
│  • Source  [auto▼] │  │  ┌──────────┐  ↔  ┌──────────────┐  │  │
│  • Cible   [en  ▼] │  │  │ Source   │     │ Cible        │  │  │
│  • Mode    [std ▼] │  │  │ [auto ▼] │     │ [Anglais ▼]  │  │  │
│  ────────────────  │  │  └──────────┘     └──────────────┘  │  │
│  [ Traduire ↗ ]    │  └──────────────────────────────────────┘  │
│                    │                                            │
│  Historique (n)    │  ┌──── Résultat ─────────────────────────┐ │
│  ─ Français→EN     │  │  [ TXT ] [ MD ] [ PDF ]  [ Copier ]   │ │
│  ─ Français→DE     │  │  ──────────────────────────────────── │ │
│                    │  │  Vue :  [ Côte à côte ] [ Traduit seul]│ │
│                    │  │  ──────────────────────────────────── │ │
│                    │  │  [source original] | [texte traduit]  │ │
│                    │  │   (scroll synchronisé)                │ │
│                    │  └───────────────────────────────────────┘ │
└────────────────────┴────────────────────────────────────────────┘
```

**Signals du composant :**
```typescript
readonly languages        = signal<LanguageInfo[]>([]);
readonly documents        = signal<DocumentResponse[]>([]);
readonly selectedDocId    = signal<string | null>(null);
readonly sourceLang       = signal('auto');
readonly targetLang       = signal('en');
readonly mode             = signal<TranslationMode>('STANDARD');
readonly translating      = signal(false);
readonly currentResult    = signal<TranslationResponse | null>(null);
readonly history          = signal<TranslationResponse[]>([]);
readonly viewMode         = signal<'side-by-side' | 'translated-only'>('side-by-side');
readonly langSearch       = signal('');
readonly uploading        = signal(false);
readonly uploadError      = signal<string | null>(null);
readonly translateError   = signal<string | null>(null);
readonly exporting        = signal(false);

// Computed
readonly filteredLangs = computed(() => {
  const q = this.langSearch().toLowerCase();
  return this.languages().filter(l =>
    l.name.toLowerCase().includes(q) || l.nativeName.toLowerCase().includes(q)
  );
});

readonly canTranslate = computed(() =>
  !!this.selectedDocId() && !!this.targetLang() && !this.translating()
  && this.sourceLang() !== this.targetLang()
);

readonly resultPreview = computed(() => {
  const text = this.currentResult()?.resultText ?? '';
  return text.replace(/#+\s*/g, '').replace(/\*+/g, '').slice(0, 300);
});
```

**Sélecteur de langue** — Composant dédié ou inline avec recherche :
```html
<div class="language-selector">
  <!-- Champ recherche -->
  <input [ngModel]="langSearch()" (ngModelChange)="langSearch.set($event)"
         placeholder="Rechercher une langue…" />
  <!-- Groupes -->
  @for (group of languageGroups(); track group.id) {
    <p class="group-label">{{ group.label }}</p>
    @for (lang of group.langs; track lang.code) {
      <button (click)="selectTargetLang(lang.code)"
              [class.selected]="targetLang() === lang.code">
        {{ lang.nativeName }} — {{ lang.name }}
        @if (lang.rtl) { <span class="badge-rtl">RTL</span> }
      </button>
    }
  }
</div>
```

**Vue côte à côte (side-by-side) :**
```html
<div class="grid grid-cols-2 gap-4 h-[500px]">
  <!-- Original -->
  <div class="overflow-y-auto rounded-xl p-4 border" style="...">
    <div class="text-xs mb-2 font-semibold">{{ sourceLangLabel() }}</div>
    <pre class="whitespace-pre-wrap text-sm">{{ originalText() }}</pre>
  </div>
  <!-- Traduit -->
  <div class="overflow-y-auto rounded-xl p-4 border"
       [attr.dir]="isTargetRtl() ? 'rtl' : 'ltr'" style="...">
    <div class="text-xs mb-2 font-semibold">{{ targetLangLabel() }}</div>
    <div class="prose prose-sm" [innerHTML]="translatedHtml()"></div>
  </div>
</div>
```

**Indicateurs :**
- Badge moteur IA : `Ollama local` ou `Claude IA` (visible dans les métadonnées résultat)
- Badge cache : `Depuis le cache` si `cached: true`
- Langue détectée : si `detectedSourceLang` est renseigné → `"Langue détectée : Français (fr)"`
- Compteur de mots : `X mots traduits` / `Y mots source`
- Durée : `Traduit en 4.2s`

### 2.4 Route Angular

**`translation.routes.ts`**
```typescript
export const TRANSLATION_ROUTES: Routes = [
  {
    path: '',
    loadComponent: () =>
      import('./translation.component').then(m => m.TranslationComponent),
    data: { requiresAuthHint: false },  // softAuthGuard — anonymes bienvenus
  },
];
```

**`app.routes.ts`** — Ajouter :
```typescript
{
  path: 'translate',
  loadChildren: () =>
    import('./features/translation/translation.routes').then(r => r.TRANSLATION_ROUTES),
  canActivate: [softAuthGuard],
}
```

### 2.5 tools-config.ts — Mise à jour

```typescript
// Passer isAvailable: true, badge: 'NEW', retirer 'SOON'
{
  slug:        'translate',
  name:        'Traduction IA',
  badge:       'NEW',
  isAvailable: true,
  isPro:       false,       // disponible pour tous
  // ...
}
```

---

## Phase 3 — Qualité & Enrichissement traduction

> **Durée estimée** : 2–3 jours  
> **Priorité** : 🟡 Haute — différenciation concurrentielle

### 3.1 Contexte chevauchant inter-chunks (Overlap)

Amélioration du `TextSegmenter` pour transmettre la dernière phrase du chunk précédent
comme contexte de départ du chunk suivant — évite les ruptures de style/ton à la jointure.

```java
// Exemple de prompt avec contexte
"[CONTEXTE PRÉCÉDENT - ne pas traduire, uniquement pour cohérence de style]\n"
+ previousSentence + "\n\n"
+ "[TEXTE À TRADUIRE]\n"
+ currentChunk
```

### 3.2 Glossaire / Terminologie personnalisée

- **Endpoint** : `POST /api/v1/translate/glossary` — définir des paires terme/traduction
- **Entité** `GlossaryEntry` : `{ sourceTerm, targetTerm, targetLang, userId }`
- **Injection dans le prompt** : liste des termes du glossaire injectée dans le system prompt
- **Frontend** : panneau "Glossaire" dépliable dans la config, avec ajout/suppression de termes
- **Use case** : "Toujours traduire 'Board of Directors' par 'Conseil d'Administration'"

### 3.3 Swap de langues (source ↔ cible)

Bouton `⇄` entre les sélecteurs pour inverser rapidement la paire de langues.
Utile pour re-traduire dans l'autre sens une fois le résultat obtenu.

### 3.4 Réutilisation d'une traduction comme source

Bouton "Retranslate" dans l'historique — recharger une traduction passée et lancer
une nouvelle traduction vers une troisième langue (ex : FR→EN→DE en deux clics).

### 3.5 Métriques de qualité

Calcul d'un score approximatif de qualité (sans référence humaine) :
- **Ratio de longueur** : `wordCountTranslated / wordCountSource` (doit être dans 0.6–1.5)
- **Coverage score** : segments du texte source couverts dans la traduction
- Afficher dans l'UI avec des alertes si ratio anormal

---

## Phase 4 — Formats avancés

> **Durée estimée** : 3–4 jours  
> **Priorité** : 🟠 Moyenne — valeur ajoutée pour PRO

### 4.1 Traduction de documents Word (.docx)

- Accepter un `.docx` directement (sans passer par PDF)
- Extraction via Apache POI (déjà disponible dans le projet pour PDF→Excel)
- Conserver les styles (gras, italique, listes) via traduction Markdown intermédiaire
- Sortie : `.docx` traduit généré via POI

### 4.2 Sortie PDF mise en forme préservée (avancé)

Pipeline :
```
PDF source → PDFTextExtractor (avec positions) → Markdown structuré
→ Traduction Markdown → HTML via Commonmark → PDF via OpenHtmlToPdf
```
Limite : ne préserve pas le layout pixel-perfect — restructure proprement le contenu traduit.

### 4.3 Traduction batch (multi-documents)

- Endpoint : `POST /api/v1/translate/batch`
- Corps : `{ documentIds: UUID[], sourceLang, targetLang, mode }`
- Lancement async via `AiJob` de type `TRANSLATION`
- Zip des résultats téléchargeable

---

## Phase 5 — Tests & Production

> **Durée estimée** : 1–2 jours  
> **Priorité** : 🔴 Haute avant mise en production

### 5.1 Tests Backend

**`TranslationControllerTest.java`** (`@WebMvcTest`) :
- `translate_autoDetect_returns201WithDetectedLang`
- `translate_sameLangs_returns400`
- `translate_anonymousUser_returns201`
- `translate_anonymousQuotaExceeded_returns429`
- `translate_documentNotFound_returns404`
- `translate_pageLimitExceeded_returns403`
- `translate_cachedResult_returns201WithCachedTrue`
- `getHistory_unauthenticated_returns401`
- `getLanguages_returns200WithAllLanguages`
- `download_validId_returnsFile`

**`TranslationServiceImplTest.java`** (unit) :
- Mock de `AiRoutingService` — vérifier Ollama vs Claude selon plan
- Mock de `TextSegmenter` — tester la boucle de chunks
- Tester le cache lookup
- Tester `enforcePageLimit()` par plan
- Tester la détection automatique de langue (parsing JSON)
- Tester le calcul des compteurs de mots

**`TextSegmenterTest.java`** (unit) :
- Segmentation d'un texte court (<MAX_WORDS) → 1 chunk
- Segmentation d'un texte long → n chunks, frontières de paragraphes respectées
- Overlap entre chunks
- `estimatePageCount()` — précision à ±20%

**`AnonymousQuotaServiceTest.java`** — extension :
- `checkAndIncrementTranslation` — quota global + quota par doc

### 5.2 Tests Frontend

**`TranslationComponent` spec** :
- Rendu sans connexion (guest) : pas d'appel `getAll()`
- Swap source ↔ cible fonctionne
- Bouton "Traduire" désactivé si sourceLang === targetLang
- Résultat affiché en side-by-side et traduit seul
- Download déclenche le téléchargement
- Cache badge affiché si `cached: true`
- Langue détectée affichée si `detectedSourceLang` présent
- RTL : attribut `dir="rtl"` appliqué pour ar, he

### 5.3 Observabilité

**Logs structurés** (MDC) :
```java
MDC.put("feature",    "TRANSLATION");
MDC.put("userId",     userId != null ? userId.toString() : "anonymous");
MDC.put("documentId", documentId.toString());
MDC.put("langs",      request.sourceLang() + "→" + request.targetLang());
MDC.put("chunks",     String.valueOf(chunks.size()));
MDC.put("durationMs", String.valueOf(durationMs));
```

**Métriques Micrometer** :
- `translation.duration.ms` (Timer par langue cible)
- `translation.word_count.source` (Distribution)
- `translation.cache.hit_rate` (Gauge)
- `translation.quota.exceeded` (Counter par type : global / par-doc)

---

## Récapitulatif par phase

| Phase | Durée est. | Priorité | Livrable |
|-------|------------|----------|---------|
| **1 — Backend** | 2–3 j | 🔴 Critique | API fonctionnelle, quota Redis, 30 langues |
| **2 — Frontend** | 2–3 j | 🔴 Critique | Composant complet, side-by-side, export |
| **3 — Qualité** | 2–3 j | 🟡 Haute | Overlap chunks, glossaire, swap langs |
| **4 — Formats avancés** | 3–4 j | 🟠 Moyenne | DOCX input/output, PDF mis en forme, batch |
| **5 — Tests & Prod** | 1–2 j | 🔴 Haute | Suite de tests complète, métriques |

**Total estimé : 10–15 jours pour les phases 1+2+5 (livraison MVP qualité production).**

---

## Ordre d'implémentation recommandé

```
1.  V23__create_translation_tables.sql
2.  TranslationResult (entity) + TranslationResultRepository
3.  SupportedLanguages (constante), LanguageInfo (DTO)
4.  TranslationRequest + TranslationResponse DTOs
5.  TextSegmenter (unit-testable isolément)
6.  AnonymousQuotaService.checkAndIncrementTranslation()
7.  SecurityConfig — publier les endpoints
8.  TranslationServiceImpl — translate() sans cache
9.  TranslationServiceImpl — ajout cache lookup
10. TranslationExportService (TXT + MD + PDF)
11. TranslationController (tous les endpoints)
12. Tests backend (Phase 5.1)
13. translation.model.ts + translation.service.ts
14. TranslationComponent — sélecteur doc + config langues
15. TranslationComponent — UI résultat (side-by-side + téléchargement)
16. translation.routes.ts + intégration app.routes.ts
17. tools-config.ts — passer isAvailable: true
18. Tests frontend (Phase 5.2)
19. Phase 3 (enrichissements) — selon périmètre validé
```

---

## Points d'attention & décisions à valider

| Sujet | Décision suggérée | À confirmer |
|-------|-------------------|-------------|
| Accès anonyme | ✅ Oui — quota 2/jour/IP, 1/jour/IP/doc | |
| Page limit anonyme | 10 pages max | |
| Page limit FREE | 30 pages max | |
| Détection auto de langue | Via LLM (JSON `{"detected":"fr","translation":"..."}`) | |
| Format sortie PDF | Commonmark → HTML → OpenHtmlToPdf | Dépendance à ajouter |
| Support DOCX en entrée | Phase 4 uniquement | |
| Glossaire | Phase 3 — migration DB requise | |
| Batch multi-docs | Phase 4 uniquement | |
| RTL (arabe, hébreu) | Frontend `dir="rtl"` + CSS Tailwind `text-right` | |
| Migration numéro | V23 (V22 = extraction userId) | À vérifier selon ordre d'application |

---

*Document généré le 2026-06-13 — Kovixel Traduction IA*
