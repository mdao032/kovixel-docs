# Roadmap — Outil « Numérotation de pages / En-têtes & Pieds de page »

> **Statut :** Spec technique v1.0
> **Date :** 2026-06-21
> **Objectif qualité :** Supérieur ou égal aux leaders du marché (iLovePDF, Sejda, Adobe Acrobat Online, SmallPDF)

---

## Table des matières

1. [Architecture & décisions](#1-architecture--décisions)
2. [Analyse concurrentielle](#2-analyse-concurrentielle)
3. [Sprint 1 — Migrations DB](#3-sprint-1--migrations-db)
4. [Sprint 2 — Backend](#4-sprint-2--backend)
5. [Sprint 3 — Frontend](#5-sprint-3--frontend)
6. [Sprint 4 — Chiffres romains, image logo & numérotation par section](#6-sprint-4--chiffres-romains-image-logo--numérotation-par-section)
7. [Limites par plan](#7-limites-par-plan)
8. [Référence — Variables, formats et typographies](#8-référence--variables-formats-et-typographies)

---

## 1. Architecture & décisions

### 1.1 Pipeline asynchrone (identique à PDF Watermark)

L'ajout d'en-têtes et de pieds de page sur un document de 500 pages peut dépasser
5 secondes avec de nombreuses variables à substituer. Le pipeline async est obligatoire :

```
POST /api/v1/pdf/page-number    → 202 { jobId }             (retour immédiat)
Worker @Async                   → applique les zones         (arrière-plan)
GET  /api/v1/pdf/page-number/{jobId}/result  → polling statut
GET  /api/v1/pdf/page-number/{jobId}/download → téléchargement
```

### 1.2 Simplification clé : AUCUN Redis nécessaire ⭐

Identique à PDF Watermark — aucune donnée sensible dans la configuration
(pas de mot de passe). L'intégralité des paramètres transite dans
`processing_jobs.inputData` (colonne TEXT, chiffrée au repos par la DB) :

```
PDF Lock   →  Redis TTL (mot de passe : sensible)
PDF Unlock →  Redis TTL (mot de passe : sensible)
Watermark  →  inputData JSON   (config : non sensible)
Page Number →  inputData JSON   (config : non sensible) ← PAS de Redis
```

### 1.3 PDFBox 3.x — Positionnement texte en marges

Le système de coordonnées PDFBox place l'origine en **bas-à-gauche**. Les marges
sont saisies en millimètres (UX), converties en points PDF dans la stratégie
(1 mm ≈ 2.8346 points).

```java
// Constante de conversion
private static final float MM_TO_PT = 2.8346f;

// Pied de page (footer) — Y mesuré depuis le bas
float footerY = opts.marginBottomMm() * MM_TO_PT;

// En-tête (header) — Y mesuré depuis le bas + hauteur page - marge haute
float headerY = pageHeight - opts.marginTopMm() * MM_TO_PT - opts.fontSize();

// Alignement horizontal
float textWidth = font.getStringWidth(text) / 1000f * opts.fontSize();
float marginLeftPt  = opts.marginLeftMm()  * MM_TO_PT;
float marginRightPt = opts.marginRightMm() * MM_TO_PT;

float x = switch (alignment) {
    case "LEFT"   -> marginLeftPt;
    case "RIGHT"  -> pageWidth - marginRightPt - textWidth;
    default       -> (pageWidth - textWidth) / 2f;  // CENTER
};

try (PDPageContentStream cs = new PDPageContentStream(
        doc, page, PDPageContentStream.AppendMode.APPEND, true, true)) {
    cs.beginText();
    cs.setFont(font, opts.fontSize());
    float[] rgb = hexToRgb(opts.colorHex());
    cs.setNonStrokingColor(rgb[0], rgb[1], rgb[2]);
    cs.newLineAtOffset(x, footerY);   // ou headerY selon la zone
    cs.showText(text);
    cs.endText();
}
```

> **Note :** `AppendMode.APPEND` est toujours utilisé — les en-têtes/pieds de page
> doivent s'afficher par-dessus le contenu existant. Contrairement au filigrane,
> il n'y a pas de mode « arrière-plan ».

### 1.4 Système de variables — substitution au moment du traitement

Les templates (ex. `"Page {page} sur {total}"`) sont substitués à l'exécution
dans `PdfPageNumberStrategy`, page par page. La date est celle du traitement
(pas de la soumission) pour garantir l'exactitude.

```java
private String renderTemplate(String template, int pageDisplay, int totalPages,
                               String fileName, String dateStr) {
    if (template == null || template.isBlank()) return null;
    return template
        .replace("{page}",  formatPageNumber(pageDisplay, opts.numberFormat()))
        .replace("{total}", formatPageNumber(totalPages,  opts.numberFormat()))
        .replace("{file}",  fileName)
        .replace("{date}",  dateStr);
}

private String formatPageNumber(int n, String format) {
    return switch (format) {
        case "ROMAN_UPPER" -> toRomanUpper(n);
        case "ROMAN_LOWER" -> toRomanUpper(n).toLowerCase();
        case "ALPHA_UPPER" -> toAlpha(n).toUpperCase();
        case "ALPHA_LOWER" -> toAlpha(n);
        default            -> String.valueOf(n);   // ARABIC
    };
}

// Sprint 4 — chiffres romains
private String toRomanUpper(int number) {
    if (number <= 0) return String.valueOf(number);
    int[] vals = {1000,900,500,400,100,90,50,40,10,9,5,4,1};
    String[] syms = {"M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"};
    StringBuilder sb = new StringBuilder();
    for (int i = 0; i < vals.length; i++) {
        while (number >= vals[i]) { sb.append(syms[i]); number -= vals[i]; }
    }
    return sb.toString();
}

// Sprint 4 — lettres (A, B, C, …, Z, AA, AB, …)
private String toAlpha(int n) {
    StringBuilder sb = new StringBuilder();
    while (n > 0) {
        n--;
        sb.insert(0, (char) ('a' + n % 26));
        n /= 26;
    }
    return sb.toString();
}
```

### 1.5 Numéro de départ et pages ignorées

```java
// Pages effectivement numérotées
List<Integer> processedIndices = new ArrayList<>();
for (int i = 0; i < totalPages; i++) {
    if (i >= opts.skipFirstPages()) {
        processedIndices.add(i);
    }
}

// Numéro d'affichage pour la page d'index i
int displayNumber = opts.startNumber() + (i - opts.skipFirstPages());
```

Les `skipFirstPages` premières pages (couverture, sommaire, etc.) reçoivent
le texte de template **sans substitution de numéro de page** — soit elles n'ont
ni en-tête ni pied de page, soit elles ont un texte statique (sans `{page}`).

> **Décision :** en MVP (Sprint 2-3), les pages ignorées ne reçoivent rien
> (ni header ni footer). La configuration avancée (texte différent sur les pages
> sautées) est réservée au Sprint 4.

### 1.6 Stockage du PDF numéroté

Clé MinIO/local : `pdf-page-number/output/{jobId}/{outputFileName}`

Nom de sortie : `{originalName}_numéroté.pdf`

TTL d'expiration : 24 h (FREE), 7 j (PRO), 30 j (ENTERPRISE). Auto-delete par
`PdfPageNumberCleanupJob`, décalé de 9 min par rapport au démarrage de l'app
(après PdfWatermarkCleanupJob à 6 min).

---

## 2. Analyse concurrentielle

| Critère | iLovePDF | SmallPDF | Sejda | Adobe Acrobat | **Kovixel** |
|---------|----------|----------|-------|---------------|-------------|
| Numérotation de pages | ✅ | ✅ | ✅ | ✅ | **✅** |
| En-tête personnalisé | ❌ | ❌ | ✅ | ✅ | **✅** |
| Pied de page personnalisé | ✅ (numéro) | ✅ (numéro) | ✅ | ✅ | **✅** |
| Header ET footer simultanés | ❌ | ❌ | ✅ | ✅ | **✅ (FREE)** |
| Variables `{page}` `{total}` | ✅ (fixe) | ❌ | ✅ | ✅ | **✅ + `{date}` `{file}`** |
| Variable `{date}` | ❌ | ❌ | ✅ | ✅ | **✅** |
| Variable `{file}` (nom du doc) | ❌ | ❌ | ❌ | ✅ | **✅** |
| Format chiffres romains | ❌ | ❌ | ✅ | ✅ | **Sprint 4** |
| Format lettres (A, B, C) | ❌ | ❌ | ❌ | ✅ | **Sprint 4** |
| Numéro de départ personnalisé | ✅ | ❌ | ✅ | ✅ | **✅** |
| Ignorer les N premières pages | ❌ | ❌ | ✅ | ✅ | **✅** |
| Police personnalisée | ❌ | ❌ | ❌ (Arial seul) | ✅ | **✅ (12 polices)** |
| Couleur personnalisée | ❌ | ❌ | ❌ | ✅ | **✅** |
| Taille de police personnalisée | Fixe | Fixe | Limité | ✅ | **✅ (6–72 pt)** |
| Marges personnalisées (mm) | ❌ | ❌ | ✅ | ✅ | **✅** |
| Alignement gauche/centre/droite | Centre seul | Centre seul | ✅ | ✅ | **✅ par zone** |
| Aperçu en temps réel | ❌ | ❌ | ❌ | Statique | **✅ Canvas live** |
| Modèles prédéfinis | ❌ | ❌ | ❌ | ❌ | **✅ (6 presets)** |
| Audit trail | ❌ | ❌ | ❌ | ❌ | **✅** |
| Quota par plan | ❌ | ❌ | 3/j | PRO | **✅ FREE/PRO/ENTERPRISE** |

**Avantages Kovixel uniques :**

1. **Aperçu canvas en temps réel** : l'utilisateur voit exactement la position,
   la police, la couleur et le texte rendu sur une miniature de page **avant la
   soumission**. Aucun concurrent ne propose cela en tier gratuit.
2. **4 variables dynamiques** : `{page}`, `{total}`, `{date}`, `{file}` —
   iLovePDF n'a pas `{date}` ni `{file}` ; SmallPDF n'a aucune variable.
3. **Header ET footer simultanément en FREE** : iLovePDF et SmallPDF forcent
   à choisir l'un ou l'autre.
4. **6 modèles prédéfinis** en un clic, personnalisables ensuite.
5. **Ignorer N pages** (couverture, sommaire) : iLovePDF ne le supporte pas.
6. **12 polices avec couleur libre** : aucun concurrent en FREE ne le propose.

---

## 3. Sprint 1 — Migrations DB

### V43 — Ajout de `PDF_PAGE_NUMBER` au type de job

Même pattern idempotent que V36 (PDF Lock), V38 (PDF Unlock) et V41 (Watermark) :

```sql
-- V43 : ajout de PDF_PAGE_NUMBER à la contrainte CHECK sur processing_jobs.job_type
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name  = 'processing_jobs'
          AND constraint_name = 'check_job_type'
    ) THEN
        ALTER TABLE processing_jobs DROP CONSTRAINT check_job_type;
        ALTER TABLE processing_jobs
            ADD CONSTRAINT check_job_type
            CHECK (job_type IN (
                'SUMMARY', 'QA', 'EXTRACTION', 'GENERATION',
                'OCR', 'PDF_LOCK', 'PDF_UNLOCK', 'PDF_WATERMARK',
                'PDF_PAGE_NUMBER'
            ));
    END IF;
END $$;
```

Ajouter `PDF_PAGE_NUMBER` à l'enum Java `ProcessingJob.JobType`.

---

### V44 — Table `pdf_page_number_results`

Table enrichie avec toute la config de l'outil pour l'audit trail et la carte
résultat. Les colonnes Sprint 4 (chiffres romains, logo image) sont déjà
présentes pour éviter une migration ultérieure.

```sql
CREATE TABLE IF NOT EXISTS pdf_page_number_results (
    id                   BIGSERIAL       PRIMARY KEY,
    job_id               BIGINT          NOT NULL
                                         REFERENCES processing_jobs(id) ON DELETE CASCADE,
    user_id              BIGINT,

    -- Fichier source
    source_file_name     VARCHAR(255),
    source_size_bytes    BIGINT,
    source_page_count    INTEGER,

    -- Fichier produit
    output_key           TEXT            NOT NULL,
    output_file_name     VARCHAR(255),
    output_size_bytes    BIGINT,

    -- Configuration — En-tête (header)
    header_text          VARCHAR(200),   -- Template, ex. "{file} | {date}" — NULL = pas d'en-tête
    header_alignment     VARCHAR(10),    -- 'LEFT' | 'CENTER' | 'RIGHT'

    -- Configuration — Pied de page (footer)
    footer_text          VARCHAR(200),   -- Template, ex. "Page {page} sur {total}" — NULL = pas de pied
    footer_alignment     VARCHAR(10),    -- 'LEFT' | 'CENTER' | 'RIGHT'

    -- Configuration — Format de numéro
    number_format        VARCHAR(15)     NOT NULL DEFAULT 'ARABIC',
                                         -- 'ARABIC' | 'ROMAN_UPPER' | 'ROMAN_LOWER'
                                         -- | 'ALPHA_UPPER' | 'ALPHA_LOWER'
    start_number         SMALLINT        NOT NULL DEFAULT 1,
    skip_first_pages     SMALLINT        NOT NULL DEFAULT 0,

    -- Configuration — Typographie
    font_name            VARCHAR(50),    -- Standard14 FontName
    font_size            SMALLINT,       -- 6 – 72
    color_hex            VARCHAR(7),     -- '#000000'

    -- Configuration — Marges (en mm)
    margin_top           DECIMAL(5,2),   -- 5.0 – 50.0 mm
    margin_bottom        DECIMAL(5,2),
    margin_left          DECIMAL(5,2),
    margin_right         DECIMAL(5,2),

    -- Configuration — Format de date pour la variable {date}
    date_format          VARCHAR(20),    -- 'dd/MM/yyyy' | 'MM/dd/yyyy' | 'yyyy-MM-dd'

    -- Sprint 4 — Logo image en en-tête
    logo_storage_key     TEXT,           -- Clé MinIO de l'image uploadée
    logo_original_filename VARCHAR(255),
    logo_zone            VARCHAR(10),    -- 'HEADER' | 'FOOTER'
    logo_scale           DECIMAL(3,2),   -- 0.10 – 1.00

    -- Métriques
    pages_numbered       INTEGER,        -- Nombre effectif de pages numérotées
    processing_ms        BIGINT,

    -- Rétention
    expires_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pdf_pn_results_job_id
    ON pdf_page_number_results (job_id);

CREATE INDEX IF NOT EXISTS idx_pdf_pn_results_user_id
    ON pdf_page_number_results (user_id);

CREATE INDEX IF NOT EXISTS idx_pdf_pn_results_expires
    ON pdf_page_number_results (expires_at)
    WHERE expires_at IS NOT NULL;
```

> **Sprint 4 :** les colonnes `logo_storage_key`, `logo_original_filename`,
> `logo_zone` et `logo_scale` sont préajoutées dans V44 pour éviter une migration
> V45 uniquement sur ces champs.

---

## 4. Sprint 2 — Backend

### 4.1 Structure du package

```
com.kovixel.pdfpagenumber
  ├── controller/
  │     └── PdfPageNumberController.java
  ├── service/
  │     ├── PdfPageNumberService.java          (interface + record PdfPageNumberDownload)
  │     └── PdfPageNumberServiceImpl.java
  ├── strategy/
  │     └── PdfPageNumberStrategy.java         (implements ProcessingStrategy)
  ├── scheduler/
  │     └── PdfPageNumberCleanupJob.java
  ├── entity/
  │     └── PdfPageNumberResult.java
  ├── repository/
  │     └── PdfPageNumberResultRepository.java
  └── dto/
        ├── PdfPageNumberRequest.java
        ├── PdfPageNumberJobResponse.java
        └── PdfPageNumberResultResponse.java
```

---

### 4.2 DTO `PdfPageNumberRequest`

Multipart form-data. Aucune donnée sensible — pas de `@ToString.Exclude`.

```java
@Data
public class PdfPageNumberRequest {

    @NotNull(message = "Le fichier PDF est obligatoire")
    private MultipartFile file;

    // ── Zone en-tête (Header) ─────────────────────────────────────────────────
    //    Si headerText est null ou vide → aucun en-tête ajouté.

    @Size(max = 200)
    private String headerText;                  // ex. "{file} | {date}"

    @NotNull
    private Alignment headerAlignment = Alignment.CENTER;

    // ── Zone pied de page (Footer) ────────────────────────────────────────────
    //    Si footerText est null ou vide → aucun pied de page ajouté.

    @Size(max = 200)
    private String footerText = "Page {page} sur {total}";

    @NotNull
    private Alignment footerAlignment = Alignment.CENTER;

    // ── Format de numérotation ────────────────────────────────────────────────

    @NotNull
    private NumberFormat numberFormat = NumberFormat.ARABIC;

    /** Numéro affiché sur la première page numérotée. Défaut : 1. */
    @Min(1) @Max(9999)
    private int startNumber = 1;

    /**
     * Nombre de pages à ignorer au début (couverture, sommaire…).
     * Ces pages n'auront ni en-tête ni pied de page.
     */
    @Min(0) @Max(100)
    private int skipFirstPages = 0;

    // ── Typographie ───────────────────────────────────────────────────────────

    @NotNull
    private PageFontName fontName = PageFontName.HELVETICA;

    @Min(6) @Max(72)
    private int fontSize = 10;

    @Pattern(regexp = "^#[0-9A-Fa-f]{6}$",
             message = "La couleur doit être au format hexadécimal (#RRGGBB)")
    private String colorHex = "#000000";

    // ── Marges (en mm) ────────────────────────────────────────────────────────

    @DecimalMin("5.0") @DecimalMax("50.0")
    private double marginTop    = 10.0;

    @DecimalMin("5.0") @DecimalMax("50.0")
    private double marginBottom = 10.0;

    @DecimalMin("5.0") @DecimalMax("50.0")
    private double marginLeft   = 15.0;

    @DecimalMin("5.0") @DecimalMax("50.0")
    private double marginRight  = 15.0;

    // ── Format de date pour la variable {date} ────────────────────────────────

    @Pattern(regexp = "^(dd/MM/yyyy|MM/dd/yyyy|yyyy-MM-dd)$")
    private String dateFormat = "dd/MM/yyyy";

    // ── Sprint 4 — Logo image ─────────────────────────────────────────────────

    private MultipartFile logoFile;         // PNG / JPG — Sprint 4 uniquement

    @DecimalMin("0.10") @DecimalMax("1.00")
    private double logoScale = 0.30;

    private LogoZone logoZone = LogoZone.HEADER;

    // ── Enums imbriqués ───────────────────────────────────────────────────────

    public enum Alignment     { LEFT, CENTER, RIGHT }
    public enum NumberFormat  { ARABIC, ROMAN_UPPER, ROMAN_LOWER, ALPHA_UPPER, ALPHA_LOWER }
    public enum LogoZone      { HEADER, FOOTER }

    public enum PageFontName {
        HELVETICA,             HELVETICA_BOLD,
        HELVETICA_OBLIQUE,     HELVETICA_BOLD_OBLIQUE,
        TIMES_ROMAN,           TIMES_BOLD,
        TIMES_ITALIC,          TIMES_BOLD_ITALIC,
        COURIER,               COURIER_BOLD,
        COURIER_OBLIQUE,       COURIER_BOLD_OBLIQUE
    }
}
```

---

### 4.3 Service `PdfPageNumberServiceImpl`

```
submit(request, userEmail):
  1.  Lecture bytes (Tomcat multipart)
  2.  Validation MIME (application/pdf)
  3.  Résolution userId (null si anonyme)
  4.  Validation taille (≤ 10 MB FREE, ≤ 50 MB PRO, ≤ 200 MB ENTERPRISE)
  5.  Validation PDF (non corrompu, ≥ 1 page) → pageCount
  6.  Validation métier :
        - headerText vide ET footerText vide → 400 (rien à ajouter)
        - headerText présent mais SANS variable {page}/{total}/{date}/{file}
          → accepté (texte statique)
  7.  checkAndIncrementQuota(userId, PDF_PAGE_NUMBER)
  8.  Document placeholder → documentRepository.save()
  9.  fileStorageService.storeBytes() → stocke le source
  10. inputData = sérialisation JSON de toute la config
  11. ProcessingJob PENDING → processingRepository.save()
  12. afterCommit() → orchestrator.process(jobId, documentId, bytes)
  return PdfPageNumberJobResponse { jobId, documentId, status:"PENDING" }
```

```java
private String buildInputData(PdfPageNumberRequest req, String originalName,
                               String outputName) {
    Map<String, Object> data = new LinkedHashMap<>();
    data.put("sourceFileName",   originalName);
    data.put("outputFileName",   outputName);
    data.put("headerText",       req.getHeaderText());
    data.put("headerAlignment",  req.getHeaderAlignment().name());
    data.put("footerText",       req.getFooterText());
    data.put("footerAlignment",  req.getFooterAlignment().name());
    data.put("numberFormat",     req.getNumberFormat().name());
    data.put("startNumber",      req.getStartNumber());
    data.put("skipFirstPages",   req.getSkipFirstPages());
    data.put("fontName",         req.getFontName().name());
    data.put("fontSize",         req.getFontSize());
    data.put("colorHex",         req.getColorHex());
    data.put("marginTop",        req.getMarginTop());
    data.put("marginBottom",     req.getMarginBottom());
    data.put("marginLeft",       req.getMarginLeft());
    data.put("marginRight",      req.getMarginRight());
    data.put("dateFormat",       req.getDateFormat());
    return objectMapper.writeValueAsString(data);
}
```

**Nom de sortie** : `{originalName}_numéroté.pdf`

---

### 4.4 Stratégie `PdfPageNumberStrategy`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfPageNumberStrategy implements ProcessingStrategy {

    private static final float MM_TO_PT = 2.8346f;

    private final FileStorageService              fileStorageService;
    private final PdfPageNumberResultRepository   pdfPageNumberResultRepository;
    private final ObjectMapper                    objectMapper;

    @Override public JobType getSupportedType() { return JobType.PDF_PAGE_NUMBER; }
    @Override public boolean needsRawBytes()    { return true; }

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes,
                               Long jobId, Long documentId) {
        long startMs = System.currentTimeMillis();
        log.info("PdfPageNumberStrategy — jobId={}, userId={}", jobId, userId);

        PageNumberOptions opts = parseOptions(inputData);

        byte[] numberedBytes;
        int    sourcePagesCount;
        int    pagesNumbered;

        // Date calculée une fois au moment du traitement (pas de la soumission)
        String dateStr = LocalDate.now().format(
            DateTimeFormatter.ofPattern(
                opts.dateFormat() != null ? opts.dateFormat() : "dd/MM/yyyy"
            )
        );

        // Nom de fichier sans extension pour la variable {file}
        String fileLabel = opts.sourceFileName() != null
            ? opts.sourceFileName().replaceAll("\\.pdf$", "")
            : "document";

        try (PDDocument doc = Loader.loadPDF(rawBytes)) {
            sourcePagesCount = doc.getNumberOfPages();
            pagesNumbered    = Math.max(0, sourcePagesCount - opts.skipFirstPages());

            PDFont font = new PDType1Font(
                Standard14Fonts.FontName.valueOf(opts.fontName())
            );
            float[] rgb = hexToRgb(opts.colorHex());

            for (int pageIdx = 0; pageIdx < sourcePagesCount; pageIdx++) {

                // Pages sautées (couverture, sommaire) → skip
                if (pageIdx < opts.skipFirstPages()) continue;

                int displayNumber = opts.startNumber() + (pageIdx - opts.skipFirstPages());

                String headerRendered = renderTemplate(opts.headerText(), displayNumber,
                        sourcePagesCount, fileLabel, dateStr, opts.numberFormat());
                String footerRendered = renderTemplate(opts.footerText(), displayNumber,
                        sourcePagesCount, fileLabel, dateStr, opts.numberFormat());

                // Au moins une zone à dessiner pour cette page
                if (headerRendered == null && footerRendered == null) continue;

                PDPage      page     = doc.getPage(pageIdx);
                PDRectangle mediaBox = page.getMediaBox();
                float       pw       = mediaBox.getWidth();
                float       ph       = mediaBox.getHeight();
                float       sz       = opts.fontSize();

                try (PDPageContentStream cs = new PDPageContentStream(
                        doc, page, PDPageContentStream.AppendMode.APPEND, true, true)) {

                    cs.setFont(font, sz);
                    cs.setNonStrokingColor(rgb[0], rgb[1], rgb[2]);

                    if (footerRendered != null) {
                        float tw = font.getStringWidth(footerRendered) / 1000f * sz;
                        float x  = alignX(opts.footerAlignment(), pw, tw,
                                          opts.marginLeftMm(), opts.marginRightMm());
                        float y  = opts.marginBottomMm() * MM_TO_PT;
                        cs.beginText();
                        cs.newLineAtOffset(x, y);
                        cs.showText(footerRendered);
                        cs.endText();
                    }

                    if (headerRendered != null) {
                        float tw = font.getStringWidth(headerRendered) / 1000f * sz;
                        float x  = alignX(opts.headerAlignment(), pw, tw,
                                          opts.marginLeftMm(), opts.marginRightMm());
                        float y  = ph - opts.marginTopMm() * MM_TO_PT - sz;
                        cs.beginText();
                        cs.newLineAtOffset(x, y);
                        cs.showText(headerRendered);
                        cs.endText();
                    }
                }
            }

            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            doc.save(baos);
            numberedBytes = baos.toByteArray();

        } catch (Exception e) {
            log.error("PdfPageNumberStrategy — échec jobId={}: {}", jobId, e.getMessage());
            throw new RuntimeException("Échec de la numérotation PDF : " + e.getMessage(), e);
        }

        // Stockage
        String outputKey = "pdf-page-number/output/" + jobId + "/" + opts.outputFileName();
        fileStorageService.storeBytes(numberedBytes, outputKey, "application/pdf");

        // Persistance du résultat
        long processingMs = System.currentTimeMillis() - startMs;
        pdfPageNumberResultRepository.save(PdfPageNumberResult.builder()
                .jobId(jobId)
                .userId(userId)
                .sourceFileName(opts.sourceFileName())
                .sourceSizeBytes((long) rawBytes.length)
                .sourcePageCount(sourcePagesCount)
                .outputKey(outputKey)
                .outputFileName(opts.outputFileName())
                .outputSizeBytes((long) numberedBytes.length)
                .headerText(opts.headerText())
                .headerAlignment(opts.headerAlignment())
                .footerText(opts.footerText())
                .footerAlignment(opts.footerAlignment())
                .numberFormat(opts.numberFormat())
                .startNumber((short) opts.startNumber())
                .skipFirstPages((short) opts.skipFirstPages())
                .fontName(opts.fontName())
                .fontSize((short) opts.fontSize())
                .colorHex(opts.colorHex())
                .marginTop(opts.marginTopMm())
                .marginBottom(opts.marginBottomMm())
                .marginLeft(opts.marginLeftMm())
                .marginRight(opts.marginRightMm())
                .dateFormat(opts.dateFormat())
                .pagesNumbered(pagesNumbered)
                .processingMs(processingMs)
                .expiresAt(OffsetDateTime.now().plusHours(24))
                .build());

        log.info("PdfPageNumberStrategy — jobId={} terminé en {}ms ({} pages numérotées)",
                jobId, processingMs, pagesNumbered);

        return outputKey;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private float alignX(String alignment, float pageWidth, float textWidth,
                         double marginLeftMm, double marginRightMm) {
        return switch (alignment) {
            case "LEFT"  -> (float) (marginLeftMm * MM_TO_PT);
            case "RIGHT" -> pageWidth - (float)(marginRightMm * MM_TO_PT) - textWidth;
            default      -> (pageWidth - textWidth) / 2f;   // CENTER
        };
    }

    private String renderTemplate(String template, int pageDisplay, int totalPages,
                                  String fileLabel, String dateStr, String numberFormat) {
        if (template == null || template.isBlank()) return null;
        return template
            .replace("{page}",  formatNumber(pageDisplay, numberFormat))
            .replace("{total}", formatNumber(totalPages,  numberFormat))
            .replace("{file}",  fileLabel)
            .replace("{date}",  dateStr);
    }

    private String formatNumber(int n, String format) {
        return switch (format) {
            case "ROMAN_UPPER" -> toRoman(n).toUpperCase();
            case "ROMAN_LOWER" -> toRoman(n).toLowerCase();
            case "ALPHA_UPPER" -> toAlpha(n).toUpperCase();
            case "ALPHA_LOWER" -> toAlpha(n);
            default            -> String.valueOf(n);
        };
    }

    private String toRoman(int n) {
        if (n <= 0) return String.valueOf(n);
        int[]    vals = {1000,900,500,400,100,90,50,40,10,9,5,4,1};
        String[] syms = {"M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"};
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < vals.length; i++) {
            while (n >= vals[i]) { sb.append(syms[i]); n -= vals[i]; }
        }
        return sb.toString();
    }

    private String toAlpha(int n) {
        StringBuilder sb = new StringBuilder();
        while (n > 0) { n--; sb.insert(0, (char)('a' + n % 26)); n /= 26; }
        return sb.toString();
    }

    private float[] hexToRgb(String hex) {
        if (hex == null || hex.length() < 7) return new float[]{0f, 0f, 0f};
        try {
            return new float[]{
                Integer.parseInt(hex.substring(1, 3), 16) / 255f,
                Integer.parseInt(hex.substring(3, 5), 16) / 255f,
                Integer.parseInt(hex.substring(5, 7), 16) / 255f
            };
        } catch (NumberFormatException e) {
            return new float[]{0f, 0f, 0f};
        }
    }

    private record PageNumberOptions(
        String sourceFileName, String outputFileName,
        String headerText, String headerAlignment,
        String footerText, String footerAlignment,
        String numberFormat, int startNumber, int skipFirstPages,
        String fontName, int fontSize, String colorHex,
        double marginTopMm, double marginBottomMm,
        double marginLeftMm, double marginRightMm,
        String dateFormat
    ) {}
}
```

---

### 4.5 Entité `PdfPageNumberResult`

```java
@Entity
@Table(name = "pdf_page_number_results")
@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class PdfPageNumberResult {

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "job_id",  nullable = false, unique = true) private Long    jobId;
    @Column(name = "user_id")                                  private Long    userId;

    @Column(name = "source_file_name")   private String  sourceFileName;
    @Column(name = "source_size_bytes")  private Long    sourceSizeBytes;
    @Column(name = "source_page_count")  private Integer sourcePageCount;

    @Column(name = "output_key",         nullable = false, columnDefinition = "TEXT")
    private String outputKey;
    @Column(name = "output_file_name")   private String  outputFileName;
    @Column(name = "output_size_bytes")  private Long    outputSizeBytes;

    // ── Config header ─────────────────────────────────────────────────────────

    @Column(name = "header_text")        private String  headerText;
    @Column(name = "header_alignment")   private String  headerAlignment;

    // ── Config footer ─────────────────────────────────────────────────────────

    @Column(name = "footer_text")        private String  footerText;
    @Column(name = "footer_alignment")   private String  footerAlignment;

    // ── Config numérotation ───────────────────────────────────────────────────

    @Column(name = "number_format")      private String  numberFormat;
    @Column(name = "start_number")       private Short   startNumber;
    @Column(name = "skip_first_pages")   private Short   skipFirstPages;

    // ── Config typographie ────────────────────────────────────────────────────

    @Column(name = "font_name")          private String  fontName;
    @Column(name = "font_size")          private Short   fontSize;
    @Column(name = "color_hex")          private String  colorHex;

    // ── Config marges (mm) ────────────────────────────────────────────────────

    @Column(name = "margin_top")         private Double  marginTop;
    @Column(name = "margin_bottom")      private Double  marginBottom;
    @Column(name = "margin_left")        private Double  marginLeft;
    @Column(name = "margin_right")       private Double  marginRight;

    @Column(name = "date_format")        private String  dateFormat;

    // ── Sprint 4 — Logo ───────────────────────────────────────────────────────

    @Column(name = "logo_storage_key",         columnDefinition = "TEXT")
    private String  logoStorageKey;
    @Column(name = "logo_original_filename")
    private String  logoOriginalFilename;
    @Column(name = "logo_zone")          private String  logoZone;
    @Column(name = "logo_scale")         private Double  logoScale;

    // ── Métriques & rétention ─────────────────────────────────────────────────

    @Column(name = "pages_numbered")     private Integer pagesNumbered;
    @Column(name = "processing_ms")      private Long    processingMs;
    @Column(name = "expires_at")         private OffsetDateTime expiresAt;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @PrePersist
    void prePersist() { this.createdAt = OffsetDateTime.now(); }
}
```

---

### 4.6 Repository `PdfPageNumberResultRepository`

```java
public interface PdfPageNumberResultRepository
        extends JpaRepository<PdfPageNumberResult, Long> {

    Optional<PdfPageNumberResult> findByJobId(Long jobId);

    List<PdfPageNumberResult> findByExpiresAtBefore(OffsetDateTime threshold);
}
```

---

### 4.7 DTOs de réponse

```java
// PdfPageNumberJobResponse.java
@Value @Builder
public class PdfPageNumberJobResponse {
    Long   jobId;
    Long   documentId;
    String status;    // "PENDING"
    String message;
}

// PdfPageNumberResultResponse.java
@Value @Builder
public class PdfPageNumberResultResponse {
    Long    jobId;
    String  status;              // PENDING | PROCESSING | COMPLETED | FAILED

    // ── COMPLETED ─────────────────────────────────────────────────────────────
    String  downloadUrl;         // /api/v1/pdf/page-number/{jobId}/download
    String  outputFileName;
    Long    outputSizeBytes;
    Long    processingMs;
    String  expiresAt;           // ISO-8601

    // Métadonnées pour la carte résultat enrichie
    String  footerText;          // Template rendu (après variables)
    String  headerText;
    String  numberFormat;        // "ARABIC" | "ROMAN_UPPER" | ...
    Integer startNumber;
    Integer skipFirstPages;
    Integer pagesNumbered;
    Integer sourcePageCount;

    // ── FAILED ────────────────────────────────────────────────────────────────
    String  errorMessage;
}
```

---

### 4.8 Controller `PdfPageNumberController`

```java
@RestController
@RequestMapping("/api/v1/pdf/page-number")
@RequiredArgsConstructor
@Tag(name = "PDF Page Number", description = "Numérotation de pages et en-têtes/pieds de page")
public class PdfPageNumberController {

    private final PdfPageNumberService pdfPageNumberService;

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Ajoute numéros de pages, en-têtes et pieds de page à un PDF")
    public PdfPageNumberJobResponse pageNumber(
            @Valid @ModelAttribute PdfPageNumberRequest request,
            @AuthenticationPrincipal UserDetails principal
    ) {
        String email = principal != null ? principal.getUsername() : null;
        return pdfPageNumberService.submit(request, email);
    }

    @GetMapping("/{jobId}/result")
    @Operation(summary = "Statut et résultat du job de numérotation")
    public ResponseEntity<PdfPageNumberResultResponse> getResult(@PathVariable Long jobId) {
        return ResponseEntity.ok(pdfPageNumberService.getResult(jobId));
    }

    @GetMapping("/{jobId}/download")
    @Operation(summary = "Télécharge le PDF numéroté")
    public ResponseEntity<byte[]> download(@PathVariable Long jobId) {
        PdfPageNumberService.PdfPageNumberDownload dl =
                pdfPageNumberService.getDownload(jobId);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_PDF);
        headers.setContentDisposition(
                ContentDisposition.attachment().filename(dl.fileName()).build());
        headers.setContentLength(dl.bytes().length);

        return ResponseEntity.ok().headers(headers).body(dl.bytes());
    }
}
```

---

### 4.9 Scheduler `PdfPageNumberCleanupJob`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfPageNumberCleanupJob {

    private final PdfPageNumberResultRepository pdfPageNumberResultRepository;
    private final FileStorageService            fileStorageService;

    /**
     * Toutes les heures. initialDelay de 9 min pour éviter la contention avec
     * PdfLockCleanupJob (2 min), PdfUnlockCleanupJob (3 min) et
     * PdfWatermarkCleanupJob (6 min) au démarrage.
     */
    @Scheduled(fixedDelay = 3_600_000, initialDelay = 540_000)
    @Transactional
    public void cleanupExpiredPageNumbers() {
        List<PdfPageNumberResult> expired =
                pdfPageNumberResultRepository.findByExpiresAtBefore(OffsetDateTime.now());

        if (expired.isEmpty()) {
            log.debug("PdfPageNumberCleanupJob — aucun PDF numéroté expiré");
            return;
        }

        log.info("PdfPageNumberCleanupJob — {} fichier(s) numéroté(s) expiré(s)",
                expired.size());

        int deleted = 0;
        AtomicLong freed = new AtomicLong(0);

        for (PdfPageNumberResult result : expired) {
            try {
                if (result.getOutputKey() != null) {
                    fileStorageService.delete(result.getOutputKey());
                    if (result.getOutputSizeBytes() != null) {
                        freed.addAndGet(result.getOutputSizeBytes());
                    }
                }
                pdfPageNumberResultRepository.delete(result);
                deleted++;
            } catch (Exception e) {
                log.warn("PdfPageNumberCleanupJob — échec suppression jobId={}: {}",
                        result.getJobId(), e.getMessage());
            }
        }

        log.info("PdfPageNumberCleanupJob — {}/{} fichiers supprimés ({} MB libérés)",
                deleted, expired.size(),
                String.format("%.2f", freed.get() / (1024.0 * 1024.0)));
    }
}
```

---

### 4.10 Intégrations transverses

```java
// ProcessingJob.JobType
SUMMARY, QA, EXTRACTION, GENERATION, OCR,
PDF_LOCK, PDF_UNLOCK, PDF_WATERMARK, PDF_PAGE_NUMBER

// FeatureType.java
/** Numérotation de pages PDF (quota en fichiers/jour). */
PDF_PAGE_NUMBER

// PlanConfig.java — limitFor()
case PDF_PAGE_NUMBER -> maxConversionsPerDay;  // Partage le quota de conversions

// PdfPageNumberStrategy implémente ProcessingStrategy
@Override public boolean needsRawBytes() { return true; }  // ← Obligatoire
```

---

## 5. Sprint 3 — Frontend

### 5.1 Fichiers à créer

```
kovixel-ui/src/app/
  ├── core/
  │     ├── models/pdf-page-number.model.ts      (interfaces TS)
  │     └── services/pdf-page-number.service.ts  (submit, getResult, download)
  └── features/tools/pdf-page-number/
        ├── pdf-page-number.routes.ts             (lazy-loading)
        └── pdf-page-number.component.ts          (composant principal + canvas preview)
```

---

### 5.2 Route et catalogue

```typescript
// app.routes.ts — AVANT la route générique tools/:slug
{
  path: 'tools/pdf/page-number',
  canActivate: [softAuthGuard],
  loadChildren: () =>
    import('./features/tools/pdf-page-number/pdf-page-number.routes')
      .then(m => m.PDF_PAGE_NUMBER_ROUTES),
  data: { title: 'Numéroter les pages PDF', guestFeature: 'pdf-page-number' },
},

// tools-config.ts — entrée catalogue
// Icône recommandée : Hash (lucide-angular) — import { Hash } from 'lucide-angular'
{
  slug:            'pdf/page-number',
  name:            'Numéroter les pages',
  description:     'Ajoutez des numéros de page, en-têtes et pieds de page personnalisés — 4 variables, 6 templates, aperçu live',
  longDescription: '…',
  category:        'compress',
  icon:            Hash,
  badge:           'NEW',
  estimatedTime:   '~2 secondes',
  isPro:           false,
  isAvailable:     true,
  backendEndpoint: '/api/v1/pdf/page-number',
  keywords: [
    'numérotation', 'page', 'header', 'footer', 'en-tête', 'pied de page',
    'numéro', 'pagination', 'tampon', 'index', 'romain', 'nombre',
    'bas de page', 'haut de page', 'date', 'fichier',
  ],
},
```

---

### 5.3 UX — Structure de la page

Étapes : `upload → configure → processing → result | error`

```
┌───────────────────────────────────────────────────────────────────┐
│  # Numéroter les pages PDF                                        │
│  En-têtes · Pieds de page · Variables · Aperçu live              │
└───────────────────────────────────────────────────────────────────┘

[1] Fichier  ─────  [2] En-têtes/Pieds  ─────  [3] Traitement  ── [4] Résultat

╔══════════════════════════════════════════════════════════════════════╗
║  ÉTAPE 2 — Configuration                                            ║
╠═══════════════════════════╦══════════════════════════════════════════╣
║                           ║                                          ║
║  Modèles rapides :        ║       APERÇU EN TEMPS RÉEL              ║
║  [Classique] [Pro]        ║                                          ║
║  [Académique] [Rapport]   ║  ┌────────────────────────────────┐      ║
║  [Discret] [Numéro seul]  ║  │  Document.pdf | 21/06/2026    │      ║
║                           ║  │                                │      ║
║  ─────────────────────    ║  │  ~~~~~~~~~~~~~~~~~~~~          │      ║
║  EN-TÊTE (optionnel)      ║  │  ~~~~~~~~~~~~~~~~~~~           │      ║
║  Texte  [_____________]   ║  │  ~~~~~~~~~~~~~~~               │      ║
║  Alignement               ║  │  ~~~~~~~~~~~~~~~~~~~~~~        │      ║
║  [←] [·] [→]             ║  │  ~~~~~~~~~~~~~~~~~~~           │      ║
║                           ║  │  ~~~~~~~~~~~~~~~               │      ║
║  PIED DE PAGE             ║  │                                │      ║
║  Texte  [Page {page}   ]  ║  │       Page 1 sur 10           │      ║
║  Alignement [←] [·] [→]  ║  └────────────────────────────────┘      ║
║                           ║  (mis à jour à chaque frappe)            ║
║  ─────────────────────    ║                                          ║
║  FORMAT DU NUMÉRO         ║                                          ║
║  ● 1, 2, 3 (Arabe)        ║                                          ║
║  ○ I, II, III (Romain)    ║                                          ║
║  ○ A, B, C (Lettre)       ║                                          ║
║                           ║                                          ║
║  Commencer à     [ 1 ]    ║                                          ║
║  Ignorer 1ères   [ 0 ] pages                                         ║
║                           ║                                          ║
║  ─────────────────────    ║                                          ║
║  TYPOGRAPHIE              ║                                          ║
║  Police [Helvetica  ▼]    ║                                          ║
║  Taille [ 10 ] pt         ║                                          ║
║  Couleur [■] #000000      ║                                          ║
║                           ║                                          ║
║  ─────────────────────    ║                                          ║
║  MARGES (mm)              ║                                          ║
║  Haut [10] · Bas [10]     ║                                          ║
║  Gauche [15] · Droite [15]║                                          ║
╠═══════════════════════════╩══════════════════════════════════════════╣
║  [ ← Retour ]                          [ # Numéroter → ]            ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

### 5.4 Aperçu canvas en temps réel ⭐

```typescript
// Dans pdf-page-number.component.ts

private _drawPreview(): void {
  const canvas = this.previewCanvas.nativeElement;
  const ctx    = canvas.getContext('2d')!;
  const W = canvas.width;
  const H = canvas.height;

  // Page blanche avec ombre légère
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = '#d0d0d0';
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, W - 1, H - 1);

  // Lignes de texte simulées (corps du document)
  ctx.fillStyle = '#e8e8e8';
  const lineCount = Math.floor((H - 80) / 16);
  for (let i = 0; i < lineCount; i++) {
    const y       = 50 + i * 16;
    const lineW   = (0.5 + Math.random() * 0.45) * (W - 40);
    ctx.fillRect(20, y, lineW, 7);
  }

  // Calcul des marges canvas (A4 : 210 × 297 mm → proportionnel)
  const marginTopPx    = (this.marginTop()    / 297) * H;
  const marginBottomPx = (this.marginBottom() / 297) * H;
  const marginLeftPx   = (this.marginLeft()   / 210) * W;
  const marginRightPx  = (this.marginRight()  / 210) * W;

  // Typographie canvas (fontSize converti de pt A4 → canvas)
  const fsPx = Math.max(8, Math.min(this.fontSize() * (W / 595) * 1.33, 16));
  ctx.fillStyle = this.colorHex();
  ctx.font = `${fsPx}px Helvetica, Arial, sans-serif`;

  const previewPage  = Math.max(this.startNumber(), 1);
  const previewTotal = 10; // simulé

  // Rend le template avec des valeurs de prévisualisation
  const renderPreview = (tmpl: string | null): string | null => {
    if (!tmpl) return null;
    return tmpl
      .replace('{page}',  String(previewPage))
      .replace('{total}', String(previewTotal))
      .replace('{file}',  'Document')
      .replace('{date}',  '21/06/2026');
  };

  const drawAligned = (text: string, alignment: string, y: number) => {
    const tw = ctx.measureText(text).width;
    let x: number;
    switch (alignment) {
      case 'LEFT':  x = marginLeftPx;       break;
      case 'RIGHT': x = W - marginRightPx - tw; break;
      default:      x = (W - tw) / 2;       break;
    }
    ctx.fillText(text, x, y);
  };

  const headerRendered = renderPreview(this.headerText());
  const footerRendered = renderPreview(this.footerText());

  if (headerRendered) {
    drawAligned(headerRendered, this.headerAlignment(), marginTopPx + fsPx);
  }
  if (footerRendered) {
    drawAligned(footerRendered, this.footerAlignment(), H - marginBottomPx);
  }

  // Séparateurs visuels (trait fin sous le header / au-dessus du footer)
  ctx.strokeStyle = '#f0f0f0';
  ctx.lineWidth = 0.5;
  if (headerRendered) {
    ctx.beginPath();
    ctx.moveTo(marginLeftPx, marginTopPx + fsPx + 4);
    ctx.lineTo(W - marginRightPx, marginTopPx + fsPx + 4);
    ctx.stroke();
  }
  if (footerRendered) {
    ctx.beginPath();
    ctx.moveTo(marginLeftPx, H - marginBottomPx - fsPx - 4);
    ctx.lineTo(W - marginRightPx, H - marginBottomPx - fsPx - 4);
    ctx.stroke();
  }
}
```

Le composant utilise `viewChild<ElementRef<HTMLCanvasElement>>('previewCanvas')`
et un `effect()` qui écoute les 11 signaux de configuration pour redessiner à chaque
modification.

---

### 5.5 Modèles prédéfinis (6 presets)

```typescript
export const PAGE_NUMBER_PRESETS = [
  {
    label: 'Classique',
    headerText: null, headerAlignment: 'CENTER',
    footerText: 'Page {page} sur {total}', footerAlignment: 'CENTER',
    fontName: 'HELVETICA', fontSize: 10, colorHex: '#000000',
    marginTop: 10, marginBottom: 10, marginLeft: 15, marginRight: 15,
    startNumber: 1, skipFirstPages: 0,
  },
  {
    label: 'Professionnel',
    headerText: '{file}', headerAlignment: 'LEFT',
    footerText: 'Page {page}', footerAlignment: 'RIGHT',
    fontName: 'HELVETICA', fontSize: 9, colorHex: '#444444',
    marginTop: 12, marginBottom: 12, marginLeft: 20, marginRight: 20,
    startNumber: 1, skipFirstPages: 1,   // Ignore la couverture
  },
  {
    label: 'Académique',
    headerText: null, headerAlignment: 'CENTER',
    footerText: '{page} / {total}', footerAlignment: 'CENTER',
    fontName: 'TIMES_ROMAN', fontSize: 11, colorHex: '#000000',
    marginTop: 10, marginBottom: 12, marginLeft: 25, marginRight: 25,
    startNumber: 1, skipFirstPages: 0,
  },
  {
    label: 'Rapport',
    headerText: '{file} | {date}', headerAlignment: 'CENTER',
    footerText: 'Page {page} sur {total}', footerAlignment: 'CENTER',
    fontName: 'HELVETICA', fontSize: 9, colorHex: '#555555',
    marginTop: 12, marginBottom: 12, marginLeft: 20, marginRight: 20,
    startNumber: 1, skipFirstPages: 1,
  },
  {
    label: 'Discret',
    headerText: null, headerAlignment: 'CENTER',
    footerText: '{page}', footerAlignment: 'CENTER',
    fontName: 'HELVETICA', fontSize: 8, colorHex: '#888888',
    marginTop: 8, marginBottom: 8, marginLeft: 15, marginRight: 15,
    startNumber: 1, skipFirstPages: 0,
  },
  {
    label: 'Numéro seul',
    headerText: null, headerAlignment: 'CENTER',
    footerText: '— {page} —', footerAlignment: 'CENTER',
    fontName: 'HELVETICA', fontSize: 10, colorHex: '#000000',
    marginTop: 10, marginBottom: 10, marginLeft: 15, marginRight: 15,
    startNumber: 1, skipFirstPages: 0,
  },
] as const;
```

---

### 5.6 Modèle TypeScript

```typescript
// pdf-page-number.model.ts

export interface PdfPageNumberJobResponse {
  jobId:      number;
  documentId: number;
  status:     string;
  message:    string;
}

export interface PdfPageNumberResultResponse {
  jobId:   number;
  status:  string;   // PENDING | PROCESSING | COMPLETED | FAILED

  // COMPLETED
  downloadUrl?:      string;
  outputFileName?:   string;
  outputSizeBytes?:  number;
  processingMs?:     number;
  expiresAt?:        string;

  // Métadonnées carte résultat
  headerText?:       string;
  footerText?:       string;
  numberFormat?:     string;   // 'ARABIC' | 'ROMAN_UPPER' | ...
  startNumber?:      number;
  skipFirstPages?:   number;
  pagesNumbered?:    number;
  sourcePageCount?:  number;

  // FAILED
  errorMessage?: string;
}

export type PageAlignment   = 'LEFT' | 'CENTER' | 'RIGHT';
export type NumberFormat    = 'ARABIC' | 'ROMAN_UPPER' | 'ROMAN_LOWER' | 'ALPHA_UPPER' | 'ALPHA_LOWER';
export type PageFontName    =
  'HELVETICA' | 'HELVETICA_BOLD' | 'HELVETICA_OBLIQUE' | 'HELVETICA_BOLD_OBLIQUE' |
  'TIMES_ROMAN' | 'TIMES_BOLD' | 'TIMES_ITALIC' | 'TIMES_BOLD_ITALIC' |
  'COURIER' | 'COURIER_BOLD' | 'COURIER_OBLIQUE' | 'COURIER_BOLD_OBLIQUE';
```

---

### 5.7 Service Angular

```typescript
export interface PageNumberSubmitParams {
  file:           File;
  headerText?:    string;
  headerAlignment: PageAlignment;
  footerText?:    string;
  footerAlignment: PageAlignment;
  numberFormat:   NumberFormat;
  startNumber:    number;
  skipFirstPages: number;
  fontName:       PageFontName;
  fontSize:       number;
  colorHex:       string;
  marginTop:      number;
  marginBottom:   number;
  marginLeft:     number;
  marginRight:    number;
  dateFormat:     string;
}

@Injectable({ providedIn: 'root' })
export class PdfPageNumberService {
  private readonly http = inject(HttpClient);
  private readonly base = `${environment.apiUrl}/v1/pdf/page-number`;

  submit(params: PageNumberSubmitParams): Observable<PdfPageNumberJobResponse> {
    const fd = new FormData();
    fd.append('file',           params.file, params.file.name);
    fd.append('headerAlignment', params.headerAlignment);
    fd.append('footerAlignment', params.footerAlignment);
    fd.append('numberFormat',   params.numberFormat);
    fd.append('startNumber',    String(params.startNumber));
    fd.append('skipFirstPages', String(params.skipFirstPages));
    fd.append('fontName',       params.fontName);
    fd.append('fontSize',       String(params.fontSize));
    fd.append('colorHex',       params.colorHex);
    fd.append('marginTop',      String(params.marginTop));
    fd.append('marginBottom',   String(params.marginBottom));
    fd.append('marginLeft',     String(params.marginLeft));
    fd.append('marginRight',    String(params.marginRight));
    fd.append('dateFormat',     params.dateFormat);
    if (params.headerText) fd.append('headerText', params.headerText);
    if (params.footerText) fd.append('footerText', params.footerText);
    return this.http.post<PdfPageNumberJobResponse>(this.base, fd);
  }

  getResult(jobId: number): Observable<PdfPageNumberResultResponse> {
    return this.http.get<PdfPageNumberResultResponse>(`${this.base}/${jobId}/result`);
  }

  downloadNumbered(jobId: number): Observable<Blob> {
    return this.http.get(`${this.base}/${jobId}/download`, { responseType: 'blob' });
  }
}
```

---

### 5.8 Carte résultat enrichie

```
╔══════════════════════════════════════════════════════════════╗
║  ✅  Numérotation appliquée avec succès                      ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  # Configuration appliquée                                   ║
║     Pied de page  : "Page {page} sur {total}"               ║
║     En-tête       : "{file} | {date}"                        ║
║     Format        : Arabe (1, 2, 3, …)                       ║
║     Commence à    : 1  ·  Pages ignorées : 1 (couverture)   ║
║     Typographie   : Helvetica 10 pt · #000000               ║
║                                                              ║
║  📄 15 pages numérotées (sur 16)   📦 312 Ko   ⚡ 0.67 s   ║
║                                                              ║
║  [  ⬇ Télécharger rapport_numéroté.pdf  ]                   ║
║  [  🔄 Nouveau fichier  ]                                    ║
║                                                              ║
║  ⏳ Supprimé de nos serveurs dans 24 heures.                ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 6. Sprint 4 — Chiffres romains, image logo & numérotation par section

### 6.1 Formats de numérotation avancés (UI complète)

Les formats `ROMAN_UPPER`, `ROMAN_LOWER`, `ALPHA_UPPER`, `ALPHA_LOWER` sont
**déjà implémentés dans `PdfPageNumberStrategy`** (toRoman, toAlpha).
Le Sprint 2-3 active uniquement `ARABIC` dans l'UI (radio button). Le Sprint 4
déverrouille les autres options dans le composant Angular.

```
Format du numéro :
● 1, 2, 3         (Arabe)
○ I, II, III      (Romain — majuscule)
○ i, ii, iii      (Romain — minuscule)
○ A, B, C, …, AA (Lettre — majuscule)
○ a, b, c, …, aa (Lettre — minuscule)
```

---

### 6.2 Logo image en en-tête ou pied de page (Sprint 4)

Un logo PNG/JPG peut remplacer (ou compléter) le texte d'en-tête ou de pied.
Utile pour les documents d'entreprise avec logo imposé.

**Backend — `PdfPageNumberStrategy.processBytes()` — ajout logo :**

```java
if (opts.logoStorageKey() != null) {
    byte[] logoBytes;
    try (InputStream is = fileStorageService.retrieve(opts.logoStorageKey())) {
        logoBytes = is.readAllBytes();
    }
    PDImageXObject logo = PDImageXObject.createFromByteArray(doc, logoBytes, "logo");
    float logoH = opts.fontSize() * 1.4f;          // Même hauteur que le texte
    float logoW = logo.getWidth() * (logoH / logo.getHeight()) * (float) opts.logoScale();

    for (int idx : processedIndices) {
        PDPage      page     = doc.getPage(idx);
        PDRectangle mediaBox = page.getMediaBox();
        float       pw       = mediaBox.getWidth();
        float       ph       = mediaBox.getHeight();
        float       logoY    = "FOOTER".equals(opts.logoZone())
            ? opts.marginBottomMm() * MM_TO_PT
            : ph - opts.marginTopMm() * MM_TO_PT - logoH;
        float logoX = alignX("LEFT", pw, logoW, opts.marginLeftMm(), opts.marginRightMm());

        try (PDPageContentStream cs = new PDPageContentStream(
                doc, page, PDPageContentStream.AppendMode.APPEND, true, true)) {
            cs.drawImage(logo, logoX, logoY, logoW, logoH);
        }
    }
}
```

---

### 6.3 Numérotation par section (Sprint 4+)

Certains documents (rapports, thèses) utilisent des formats différents selon les
sections : `i, ii, iii` pour le sommaire puis `1, 2, 3` pour le corps.

**Architecture préliminaire :** passer une liste JSON de `sections` dans `inputData` :

```json
{
  "sections": [
    { "fromPage": 1, "toPage": 3, "numberFormat": "ROMAN_LOWER", "startNumber": 1 },
    { "fromPage": 4, "toPage": -1, "numberFormat": "ARABIC", "startNumber": 1 }
  ]
}
```

À réserver au Sprint 4+ — l'UI est plus complexe (interface d'ajout de sections).

---

### 6.4 Cas limites à couvrir

| Cas | Comportement attendu |
|-----|---------------------|
| PDF chiffré (protégé) | 422 « Ce PDF est protégé — déverrouillez-le d'abord » |
| Fichier non-PDF | 415 (validation MIME) |
| PDF corrompu | 400 « Fichier PDF invalide ou corrompu » |
| PDF de 0 page | 400 |
| headerText ET footerText vides | 400 « Veuillez saisir au moins un en-tête ou un pied de page » |
| startNumber = 0 ou négatif | 400 (`@Min(1)`) |
| skipFirstPages > pageCount | Pages ignorées = toutes → 0 pages numérotées, avertissement |
| Texte très long dépassant la marge | Tronqué silencieusement (clamp PDFBox) |
| PDF > limite plan | 413 avec rappel de la limite |
| Variable `{date}` sans format | Défaut `dd/MM/yyyy` |
| Caractères spéciaux dans `{file}` | Sanitisation du nom avant substitution |
| Double-soumission | Debounce frontend + idempotency backend |

---

### 6.5 Tests de compatibilité — PDF numéroté

**Vérifier que les numéros de page s'affichent correctement dans :**
- [ ] Adobe Acrobat Reader (Windows & macOS)
- [ ] Aperçu (macOS)
- [ ] Evince / Okular (Linux)
- [ ] Firefox PDF viewer
- [ ] Chrome PDF viewer
- [ ] PDF Expert (iOS)

**Vérifier les positions d'alignement :**
- [ ] LEFT (gauche), CENTER (centré), RIGHT (droite) — pour header et footer

**Vérifier les formules de template :**
- [ ] `{page}`, `{total}`, `{date}`, `{file}` — vérifier les valeurs injectées
- [ ] Template sans aucune variable → texte statique répété sur chaque page

**Vérifier le saut de pages :**
- [ ] `skipFirstPages = 0` (toutes les pages numérotées)
- [ ] `skipFirstPages = 1` (couverture sans numéro)
- [ ] `skipFirstPages = 3` (couverture + 2 pages de sommaire)

**Vérifier les polices Standard14 :**
- [ ] Helvetica, Times, Courier — toutes les variantes bold/italic

---

## 7. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Jobs par jour | 10 (quota conversions) | 200 | Illimité |
| Rétention du PDF numéroté | 24 h | 7 jours | 30 jours |
| En-tête | ✅ | ✅ | ✅ |
| Pied de page | ✅ | ✅ | ✅ |
| Header + Footer simultanés | ✅ | ✅ | ✅ |
| Variables `{page}` `{total}` | ✅ | ✅ | ✅ |
| Variables `{date}` `{file}` | ✅ | ✅ | ✅ |
| Format chiffres romains | ✅ (Sprint 4) | ✅ | ✅ |
| Logo image | ✅ (Sprint 4) | ✅ | ✅ |
| API directe | ❌ | ✅ | ✅ |

> Le quota `PDF_PAGE_NUMBER` partage `maxConversionsPerDay` dans `PlanConfig.limitFor()`.

---

## 8. Référence — Variables, formats et typographies

### 8.1 Variables disponibles dans les templates

| Variable | Valeur injectée | Exemple |
|----------|----------------|---------|
| `{page}` | Numéro de la page courante (applique `startNumber`) | `3` |
| `{total}` | Nombre total de pages du document | `24` |
| `{date}` | Date du traitement au format choisi | `21/06/2026` |
| `{file}` | Nom du fichier source (sans extension `.pdf`) | `Rapport_Q2` |

**Exemples de templates populaires :**

| Template | Rendu page 3/24 |
|----------|----------------|
| `Page {page} sur {total}` | `Page 3 sur 24` |
| `{page}` | `3` |
| `— {page} —` | `— 3 —` |
| `{page} / {total}` | `3 / 24` |
| `{file} · {date}` | `Rapport_Q2 · 21/06/2026` |
| `{file}` | `Rapport_Q2` |
| `Confidentiel — page {page}` | `Confidentiel — page 3` |

---

### 8.2 Formats de numérotation (Sprint 2 : ARABIC uniquement ; Sprint 4 : tous)

| Clé `NumberFormat` | Séquence | Cas d'usage |
|-------------------|----------|------------|
| `ARABIC` | 1, 2, 3, 10, 99, 100 | **Défaut** — usage général |
| `ROMAN_UPPER` | I, II, III, X, XCIX, C | Avant-propos, sommaires académiques |
| `ROMAN_LOWER` | i, ii, iii, x, xcix, c | Préfaces, pages liminaires |
| `ALPHA_UPPER` | A, B, C, …, Z, AA, AB | Annexes (Annexe A, Annexe B) |
| `ALPHA_LOWER` | a, b, c, …, z, aa, ab | Sous-sections discrètes |

---

### 8.3 Marges recommandées (mm)

| Usage | Haut | Bas | Gauche | Droite |
|-------|------|-----|--------|--------|
| Standard A4 impression | 10 | 10 | 15 | 15 |
| Recto-verso reliure | 10 | 10 | 25 | 15 |
| Document compact | 7 | 7 | 12 | 12 |
| Académique (norme) | 15 | 15 | 25 | 25 |

> **Règle** : la marge ne doit jamais être inférieure à 5 mm (validation `@DecimalMin("5.0")`),
> sous peine que le texte soit rogné à l'impression.

---

### 8.4 Guide taille de police recommandée

| Taille | Usage | Caractère |
|--------|-------|-----------|
| 6–8 pt | Très discret, mention légale | Quasi-invisible |
| **9–11 pt** | **Standard recommandé** | Lisible sans dominer le corps |
| 12–14 pt | Numérotation mise en avant | Visible mais sobre |
| 15–72 pt | Cas particuliers (affichage, présentation) | Dominant |

---

### 8.5 Polices Standard14 (PDFBox — sans embedding)

Identiques à la section équivalente du Filigrane PDF — 12 variantes Helvetica,
Times et Courier, toutes disponibles sans hausse de taille du document.

| Clé `PageFontName` | Apparence |
|------------------|-----------|
| `HELVETICA` | Sans-serif, normal ← **défaut recommandé** |
| `HELVETICA_BOLD` | Sans-serif, gras |
| `HELVETICA_OBLIQUE` | Sans-serif, italique |
| `HELVETICA_BOLD_OBLIQUE` | Sans-serif, gras + italique |
| `TIMES_ROMAN` | Serif, normal |
| `TIMES_BOLD` | Serif, gras |
| `TIMES_ITALIC` | Serif, italique |
| `TIMES_BOLD_ITALIC` | Serif, gras + italique |
| `COURIER` | Monospace, normal |
| `COURIER_BOLD` | Monospace, gras |
| `COURIER_OBLIQUE` | Monospace, italique |
| `COURIER_BOLD_OBLIQUE` | Monospace, gras + italique |

---

## Ordre d'implémentation

```
Sprint 1  →  Sprint 2  →  Sprint 3  →  Sprint 4
Migrations   Backend      Frontend     Formats avancés
(V43, V44)  (strategy,    (canvas live, (chiffres romains,
             service,      6 presets,    logo image,
             controller,   résultat      numérotation
             cleanup)      enrichi)      par section)
```

---

## Pont vers les outils PDF futurs

L'outil Page Number réutilise entièrement le même pattern que Watermark :
`needsRawBytes() = true`, `inputData` JSON, auto-discovery `@Component`.

| Outil | Prochaine migration | Spécificité |
|-------|---------------------|-------------|
| **PDF Compress** | V45, V46 | Ghostscript / PDFBox optimizer, ratio de compression |
| **PDF Merge** | V47, V48 | Plusieurs `MultipartFile` → un seul PDF, ordonnancement |
| **PDF Split** | V49, V50 | Un PDF → N fichiers, ZIP de sortie |
| **PDF Rotate** | V51, V52 | Simple, peut rester sync si < 1s sur petits docs |
| **PDF → Images** | V53, V54 | `PDFRenderer` → ZIP d'images PNG/JPG |

Pour chaque nouvel outil : (1) migration job_type + table résultat, (2) strategy
avec `needsRawBytes() = true`, (3) entrée catalogue + route Angular,
(4) composant avec aperçu live.
