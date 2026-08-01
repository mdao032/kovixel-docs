# Roadmap — Outil « Filigrane PDF »

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
6. [Sprint 4 — Filigrane image & sélection de pages](#6-sprint-4--filigrane-image--sélection-de-pages)
7. [Limites par plan](#7-limites-par-plan)
8. [Référence — Positions, polices et opacité](#8-référence--positions-polices-et-opacité)

---

## 1. Architecture & décisions

### 1.1 Pipeline asynchrone (identique à PDF Lock / PDF Unlock)

Le filigranage peut être quasi-instantané sur un PDF léger, mais dépasse facilement 3 s
sur un document de 200 pages ou 50 MB. La cohérence avec les autres outils et la scalabilité
imposent le pipeline async :

```
POST /api/v1/pdf/watermark     → 202 { jobId }             (retour immédiat)
Worker @Async                  → applique le filigrane      (arrière-plan)
GET  /api/v1/pdf/watermark/{jobId}/result  → polling statut
GET  /api/v1/pdf/watermark/{jobId}/download → téléchargement
```

### 1.2 Simplification clé : AUCUN Redis nécessaire ⭐

**Différence fondamentale vs PDF Lock et PDF Unlock :**

Le filigrane ne manipule **aucune donnée sensible** (pas de mot de passe, pas de clé de
chiffrement). La configuration complète (texte, couleur, opacité, position, rotation…)
peut être stockée directement dans `processing_jobs.inputData` (colonne TEXT chiffrée au
repos par la politique DB).

```
PDF Lock   →  Redis TTL (mot de passe : sensible)
PDF Unlock →  Redis TTL (mot de passe : sensible)
Watermark  →  inputData JSON   (config : non sensible) ← PAS de Redis
```

Cela simplifie considérablement l'implémentation tout en restant totalement sécurisé.

### 1.3 PDFBox 3.x — API de filigranage texte

```java
// PDFBox 3.x — texte en filigrane, couche avant-plan
try (PDDocument doc = Loader.loadPDF(rawBytes)) {
    PDFont font = new PDType1Font(Standard14Fonts.FontName.HELVETICA_BOLD);

    for (PDPage page : doc.getPages()) {
        PDRectangle box = page.getMediaBox();

        // Transparence via ExtendedGraphicsState
        PDExtendedGraphicsState gs = new PDExtendedGraphicsState();
        gs.setNonStrokingAlphaConstant((float) opacity); // 0.0 – 1.0
        gs.setAlphaSourceFlag(true);

        // AppendMode.APPEND = filigrane PAR-DESSUS le contenu (avant-plan)
        // AppendMode.PREPEND = filigrane SOUS le contenu (arrière-plan)
        PDPageContentStream.AppendMode appendMode = layer == FOREGROUND
                ? PDPageContentStream.AppendMode.APPEND
                : PDPageContentStream.AppendMode.PREPEND;

        try (PDPageContentStream cs = new PDPageContentStream(
                doc, page, appendMode, true, true)) {

            cs.saveGraphicsState();
            cs.setGraphicsStateParameters(gs);

            float[] rgb = hexToRgb(colorHex);
            cs.setNonStrokingColor(rgb[0], rgb[1], rgb[2]);

            float textWidth = font.getStringWidth(text) / 1000f * fontSize;

            // Matrice de transformation (translation + rotation)
            Matrix matrix = computeMatrix(position, box, textWidth, fontSize, rotationDeg);

            cs.beginText();
            cs.setFont(font, fontSize);
            cs.setTextMatrix(matrix);
            cs.showText(text);
            cs.endText();

            cs.restoreGraphicsState();
        }
    }

    ByteArrayOutputStream baos = new ByteArrayOutputStream();
    doc.save(baos);
    return baos.toByteArray();
}
```

### 1.4 Calcul des matrices de position

```java
/**
 * Retourne la matrice de transformation du texte selon la position demandée.
 * Système de coordonnées PDFBox : origine en bas-à-gauche, rotation antihoraire.
 */
private Matrix computeMatrix(WatermarkPosition pos, PDRectangle box,
                              float textWidth, float fontSize, int rotDeg) {
    float pw = box.getWidth();
    float ph = box.getHeight();
    float cx = pw / 2f;
    float cy = ph / 2f;
    float th = fontSize * 0.7f;  // approx. cap-height
    float margin = 30f;

    float tx, ty, angleDeg;

    switch (pos) {
        case DIAGONAL -> {
            // Centré sur la page, incliné selon l'angle de la diagonale
            tx       = cx;
            ty       = cy;
            angleDeg = (float) Math.toDegrees(Math.atan2(ph, pw)); // ~55° pour A4
        }
        case CENTER -> {
            tx = cx; ty = cy; angleDeg = rotDeg;
        }
        case TOP_LEFT -> {
            tx = margin + textWidth / 2f; ty = ph - margin - th; angleDeg = rotDeg;
        }
        case TOP_RIGHT -> {
            tx = pw - margin - textWidth / 2f; ty = ph - margin - th; angleDeg = rotDeg;
        }
        case BOTTOM_LEFT -> {
            tx = margin + textWidth / 2f; ty = margin; angleDeg = rotDeg;
        }
        case BOTTOM_RIGHT -> {
            tx = pw - margin - textWidth / 2f; ty = margin; angleDeg = rotDeg;
        }
        default -> { tx = cx; ty = cy; angleDeg = rotDeg; }
    }

    AffineTransform at = new AffineTransform();
    at.translate(tx, ty);
    at.rotate(Math.toRadians(angleDeg));
    at.translate(-textWidth / 2f, -th / 2f);
    return new Matrix(at);
}
```

### 1.5 Mode TILE — répétition en grille

```java
// Position TILE : le texte est répété en motif sur toute la page
case TILE -> {
    float stepX = textWidth * 2.2f;
    float stepY = (fontSize + 30f) * 2.5f;
    int numX = (int) Math.ceil(pw / stepX) + 2;
    int numY = (int) Math.ceil(ph / stepY) + 2;

    for (int ix = 0; ix < numX; ix++) {
        for (int iy = 0; iy < numY; iy++) {
            float ox = -stepX / 2f + ix * stepX;
            float oy = -stepY / 2f + iy * stepY;

            AffineTransform at = new AffineTransform();
            at.translate(ox, oy);
            at.rotate(Math.toRadians(rotDeg));  // -45° par défaut pour TILE
            at.translate(-textWidth / 2f, -th / 2f);

            cs.beginText();
            cs.setFont(font, fontSize);
            cs.setTextMatrix(new Matrix(at));
            cs.showText(text);
            cs.endText();
        }
    }
}
```

> **Note :** TILE est géré dans la boucle de dessin de la stratégie, pas comme une
> position dans la matrice — le `switch` appelle un bloc spécifique.

### 1.6 Décision : polices Standard14 uniquement (MVP)

Pour le MVP (Sprint 2-3), seules les 14 polices Type 1 intégrées à PDFBox sont utilisées.
Elles ne nécessitent **aucune intégration de police dans le PDF** (pas de hausse de taille).
Les polices supportées et leurs noms d'affichage sont détaillés en section 8.

Les polices personnalisées (TrueType / OTF) sont réservées au Sprint 5+ et nécessitent
l'intégration de la police dans le PDF (`PDType0Font.load()`), ce qui alourdit le document.

### 1.7 Stockage du PDF filigrané

Clé MinIO/local : `pdf-watermark/output/{jobId}/{outputFileName}`

TTL d'expiration : 24 h (FREE), 7 j (PRO), 30 j (ENTERPRISE). Auto-delete par
`PdfWatermarkCleanupJob`, décalé de 6 min par rapport aux autres jobs de nettoyage.

---

## 2. Analyse concurrentielle

| Critère | iLovePDF | SmallPDF | Sejda | Adobe Acrobat | **Kovixel** |
|---------|----------|----------|-------|---------------|-------------|
| Filigrane texte | ✅ | ✅ | ✅ | ✅ | **✅** |
| Filigrane image | PRO | ❌ | PRO | ✅ | **Sprint 4** |
| Positions disponibles | 5 | 1 (centre) | 8 | Précis (%) | **7 + TILE** |
| Mode mosaïque / TILE | ✅ | ❌ | ✅ | ❌ | **✅** |
| Couche avant-plan / arrière-plan | ❌ | ❌ | ❌ | ✅ | **✅ (FREE)** |
| Aperçu en temps réel | ❌ | ❌ | Statique | Statique | **✅ Canvas live** |
| Profils prédéfinis | ❌ | ❌ | ❌ | ❌ | **✅ (4 presets)** |
| Couleur libre | ✅ | ❌ | ✅ | ✅ | **✅** |
| Opacité configurable | ✅ | ✅ | ✅ | ✅ | **✅** |
| Rotation configurable | ✅ | ❌ | ✅ | ✅ | **✅** |
| Sélection de pages | ✅ | ❌ | ✅ | ✅ | **Sprint 4** |
| Métadonnées dans le résultat | ❌ | ❌ | ❌ | ❌ | **✅ (pages, position, opacité)** |
| Audit trail | ❌ | ❌ | ❌ | ❌ | **✅** |
| Quota par plan | ❌ | ❌ | 3/j | PRO | **✅ FREE/PRO/ENTERPRISE** |
| Pipeline scalable | Cloud | Cloud | Cloud | Cloud | **Async** |

**Avantages Kovixel uniques :**

1. **Aperçu canvas en temps réel** avant même la soumission : l'utilisateur voit exactement
   le résultat pendant qu'il tape le texte et ajuste les paramètres. Aucun concurrent ne
   propose cela en tier gratuit.
2. **4 profils prédéfinis cliquables** : CONFIDENTIEL, BROUILLON, COPIE, APPROUVÉ — prêts
   en un clic, modifiables ensuite.
3. **Calque avant-plan / arrière-plan** disponible en FREE (Adobe Acrobat l'a, mais en
   version Desktop payante uniquement).
4. **Mode TILE** inclus dans le MVP (mosaïque complète de la page).
5. **Carte résultat enrichie** : algorithme appliqué, nombre de pages traitées, position,
   opacité — aucun concurrent ne trace ces métadonnées.

---

## 3. Sprint 1 — Migrations DB

### V41 — Ajout de `PDF_WATERMARK` au type de job

Même pattern idempotent que V36 (PDF Lock), V38 (PDF Unlock) et V34 (OCR) :

```sql
-- V41 : ajout de PDF_WATERMARK à la contrainte CHECK sur processing_jobs.job_type
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
                'OCR', 'PDF_LOCK', 'PDF_UNLOCK', 'PDF_WATERMARK'
            ));
    END IF;
END $$;
```

Ajouter `PDF_WATERMARK` à l'enum Java `ProcessingJob.JobType`.

---

### V42 — Table `pdf_watermark_results`

Table plus riche que `pdf_unlock_results` : elle stocke la configuration complète du
filigrane pour l'audit trail et la carte résultat enrichie.

```sql
CREATE TABLE IF NOT EXISTS pdf_watermark_results (
    id                   BIGSERIAL       PRIMARY KEY,
    job_id               BIGINT          NOT NULL
                                         REFERENCES processing_jobs(id) ON DELETE CASCADE,
    user_id              BIGINT,

    -- Fichier source
    source_file_name     VARCHAR(255),
    source_size_bytes    BIGINT,
    source_page_count    INTEGER,        -- Nombre de pages dans le PDF source

    -- Fichier produit
    output_key           TEXT            NOT NULL,   -- Clé MinIO/local
    output_file_name     VARCHAR(255),
    output_size_bytes    BIGINT,

    -- Configuration du filigrane (audit trail + carte résultat)
    watermark_type       VARCHAR(10)     NOT NULL DEFAULT 'TEXT',
                                         -- 'TEXT' | 'IMAGE'

    -- Options texte
    watermark_text       VARCHAR(200),   -- Contenu du filigrane
    font_name            VARCHAR(50),    -- 'HELVETICA_BOLD' (Standard14)
    font_size            SMALLINT,       -- 6 – 200

    -- Apparence
    color_hex            VARCHAR(7),     -- '#FF0000' (rouge par défaut)
    opacity              DECIMAL(3, 2),  -- 0.05 – 1.00
    rotation_deg         SMALLINT,       -- -360 – 360

    -- Placement
    position             VARCHAR(20),    -- 'CENTER' | 'DIAGONAL' | 'TOP_LEFT' | 'TOP_RIGHT'
                                         -- | 'BOTTOM_LEFT' | 'BOTTOM_RIGHT' | 'TILE'
    layer                VARCHAR(15)     NOT NULL DEFAULT 'FOREGROUND',
                                         -- 'FOREGROUND' (par-dessus) | 'BACKGROUND' (en dessous)

    -- Sélection de pages
    pages_mode           VARCHAR(10)     NOT NULL DEFAULT 'ALL',
                                         -- 'ALL' | 'FIRST' | 'LAST' | 'ODD' | 'EVEN' | 'CUSTOM'
    pages_range          VARCHAR(100),   -- '1,3,5-10' uniquement si pages_mode = 'CUSTOM'
    pages_watermarked    INTEGER,        -- Nombre effectif de pages filigranées

    -- Filigrane image (Sprint 4)
    image_storage_key    TEXT,           -- Clé MinIO de l'image uploadée
    image_original_filename VARCHAR(255),
    image_scale          DECIMAL(3, 2),  -- 0.10 – 2.00

    -- Métriques
    processing_ms        BIGINT,

    -- Rétention
    expires_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pdf_wm_results_job_id
    ON pdf_watermark_results (job_id);

CREATE INDEX IF NOT EXISTS idx_pdf_wm_results_user_id
    ON pdf_watermark_results (user_id);

CREATE INDEX IF NOT EXISTS idx_pdf_wm_results_expires
    ON pdf_watermark_results (expires_at)
    WHERE expires_at IS NOT NULL;
```

> **Sprint 4 :** les colonnes `image_storage_key`, `image_original_filename` et
> `image_scale` sont déjà présentes dans V42 pour éviter une migration V43 uniquement
> sur ces champs. Elles restent `NULL` tant que le Sprint 4 n'est pas déployé.

---

## 4. Sprint 2 — Backend

### 4.1 Structure du package

```
com.kovixel.pdfwatermark
  ├── controller/
  │     └── PdfWatermarkController.java
  ├── service/
  │     ├── PdfWatermarkService.java          (interface + record PdfWatermarkDownload)
  │     └── PdfWatermarkServiceImpl.java
  ├── strategy/
  │     └── PdfWatermarkStrategy.java         (implements ProcessingStrategy)
  ├── scheduler/
  │     └── PdfWatermarkCleanupJob.java
  ├── entity/
  │     └── PdfWatermarkResult.java
  ├── repository/
  │     └── PdfWatermarkResultRepository.java
  └── dto/
        ├── PdfWatermarkRequest.java
        ├── PdfWatermarkJobResponse.java
        └── PdfWatermarkResultResponse.java
```

---

### 4.2 DTO `PdfWatermarkRequest`

Multipart form-data. Aucune donnée sensible → pas de `@ToString.Exclude` nécessaire.

```java
@Data
public class PdfWatermarkRequest {

    @NotNull(message = "Le fichier PDF est obligatoire")
    private MultipartFile file;

    // ── Type de filigrane ──────────────────────────────────────────────────────

    @NotNull
    private WatermarkType watermarkType = WatermarkType.TEXT;

    // ── Filigrane texte ────────────────────────────────────────────────────────

    @Size(min = 1, max = 200, message = "Le texte doit faire entre 1 et 200 caractères")
    private String text;                       // Obligatoire si watermarkType = TEXT

    private FontName fontName = FontName.HELVETICA_BOLD;

    @Min(6) @Max(200)
    private int fontSize = 60;

    @Pattern(regexp = "^#[0-9A-Fa-f]{6}$",
             message = "La couleur doit être au format hexadécimal (#RRGGBB)")
    private String colorHex = "#FF0000";

    @DecimalMin(value = "0.05", message = "L'opacité minimum est 5 %")
    @DecimalMax(value = "1.00", message = "L'opacité maximum est 100 %")
    private double opacity = 0.30;

    @Min(-360) @Max(360)
    private int rotationDeg = 45;

    // ── Placement ─────────────────────────────────────────────────────────────

    @NotNull
    private WatermarkPosition position = WatermarkPosition.DIAGONAL;

    @NotNull
    private WatermarkLayer layer = WatermarkLayer.FOREGROUND;

    // ── Sélection de pages (Sprint 2 : ALL uniquement ; Sprint 4 : toutes les options) ──

    @NotNull
    private PagesMode pagesMode = PagesMode.ALL;

    @Pattern(regexp = "^(\\d+(-\\d+)?)(,(\\d+(-\\d+)?))*$",
             message = "Format : '1,3,5-10' ou '2-5'")
    private String pagesRange;               // Requis si pagesMode = CUSTOM

    // ── Filigrane image (Sprint 4) ────────────────────────────────────────────

    private MultipartFile imageFile;         // PNG / JPG — Sprint 4 uniquement

    @DecimalMin("0.10") @DecimalMax("2.00")
    private double imageScale = 0.30;

    // ── Enums imbriqués ───────────────────────────────────────────────────────

    public enum WatermarkType {
        TEXT, IMAGE
    }

    public enum WatermarkPosition {
        CENTER, DIAGONAL, TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, TILE
    }

    public enum WatermarkLayer {
        FOREGROUND, BACKGROUND
    }

    public enum PagesMode {
        ALL, FIRST, LAST, ODD, EVEN, CUSTOM
    }

    public enum FontName {
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

### 4.3 Service `PdfWatermarkServiceImpl`

```
submit(request, userEmail):
  1.  Lecture bytes (Tomcat multipart)
  2.  Validation MIME (application/pdf)
  3.  Résolution userId (null si anonyme)
  4.  Validation taille (≤ 10 MB FREE, ≤ 50 MB PRO, ≤ 200 MB ENTERPRISE)
  5.  Validation PDF (non corrompu, ≥ 1 page) → pageCount
  6.  Validation request : watermarkType = TEXT → text non vide
                           pagesMode = CUSTOM → pagesRange non vide
  7.  checkAndIncrementQuota(userId, PDF_WATERMARK)
  8.  Document placeholder → documentRepository.save()
  9.  fileStorageService.storeBytes() → stocke le source
  10. inputData = sérialisation JSON de la config watermark + noms de fichiers
                  (SANS données sensibles — pas de Redis)
  11. ProcessingJob PENDING → processingRepository.save()
  12. afterCommit() → orchestrator.process(jobId, documentId, bytes)
  return PdfWatermarkJobResponse { jobId, documentId, status:"PENDING" }
```

**Différence clé vs PDF Lock/Unlock :** la configuration complète transite dans `inputData`
(pas de Redis). Le service est donc plus simple et plus résilient aux pannes Redis.

```java
private String buildInputData(PdfWatermarkRequest req, String originalName,
                               String outputName) {
    Map<String, Object> data = new LinkedHashMap<>();
    data.put("sourceFileName",  originalName);
    data.put("outputFileName",  outputName);
    data.put("watermarkType",   req.getWatermarkType().name());
    data.put("text",            req.getText());
    data.put("fontName",        req.getFontName().name());
    data.put("fontSize",        req.getFontSize());
    data.put("colorHex",        req.getColorHex());
    data.put("opacity",         req.getOpacity());
    data.put("rotationDeg",     req.getRotationDeg());
    data.put("position",        req.getPosition().name());
    data.put("layer",           req.getLayer().name());
    data.put("pagesMode",       req.getPagesMode().name());
    data.put("pagesRange",      req.getPagesRange());
    return objectMapper.writeValueAsString(data);
}
```

**Nom de sortie** : `{originalName}_filigrané.pdf`
(ou `_watermarked.pdf` si le nom source est en ASCII)

---

### 4.4 Stratégie `PdfWatermarkStrategy`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfWatermarkStrategy implements ProcessingStrategy {

    private static final float MARGIN = 30f;

    private final FileStorageService           fileStorageService;
    private final PdfWatermarkResultRepository pdfWatermarkResultRepository;
    private final ObjectMapper                 objectMapper;

    @Override public JobType getSupportedType() { return JobType.PDF_WATERMARK; }
    @Override public boolean needsRawBytes()    { return true; }

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes,
                               Long jobId, Long documentId) {
        long startMs = System.currentTimeMillis();
        log.info("PdfWatermarkStrategy — jobId={}, userId={}", jobId, userId);

        WatermarkOptions opts = parseOptions(inputData);

        byte[] watermarkedBytes;
        int    sourcePagesCount;
        int    pagesWatermarked;

        try (PDDocument doc = Loader.loadPDF(rawBytes)) {
            sourcePagesCount = doc.getNumberOfPages();

            // Sélection des pages à filigraner
            List<Integer> pageIndices = resolvePageIndices(opts.pagesMode(),
                    opts.pagesRange(), sourcePagesCount);
            pagesWatermarked = pageIndices.size();

            // Police Standard14 (aucun embedding nécessaire)
            Standard14Fonts.FontName fontEnum =
                    Standard14Fonts.FontName.valueOf(opts.fontName());
            PDFont font = new PDType1Font(fontEnum);

            float textWidth = font.getStringWidth(opts.text()) / 1000f * opts.fontSize();

            // Transparence
            PDExtendedGraphicsState gs = new PDExtendedGraphicsState();
            gs.setNonStrokingAlphaConstant((float) opts.opacity());
            gs.setAlphaSourceFlag(true);

            // Couleur
            float[] rgb = hexToRgb(opts.colorHex());

            // Calque
            PDPageContentStream.AppendMode appendMode =
                    "BACKGROUND".equals(opts.layer())
                    ? PDPageContentStream.AppendMode.PREPEND
                    : PDPageContentStream.AppendMode.APPEND;

            for (int idx : pageIndices) {
                PDPage page = doc.getPage(idx);
                PDRectangle mediaBox = page.getMediaBox();

                try (PDPageContentStream cs = new PDPageContentStream(
                        doc, page, appendMode, true, true)) {

                    cs.saveGraphicsState();
                    cs.setGraphicsStateParameters(gs);
                    cs.setNonStrokingColor(rgb[0], rgb[1], rgb[2]);

                    if ("TILE".equals(opts.position())) {
                        drawTile(cs, font, opts, mediaBox, textWidth, rgb);
                    } else {
                        Matrix matrix = computeMatrix(opts.position(), mediaBox,
                                textWidth, opts.fontSize(), opts.rotationDeg());
                        cs.beginText();
                        cs.setFont(font, opts.fontSize());
                        cs.setTextMatrix(matrix);
                        cs.showText(opts.text());
                        cs.endText();
                    }

                    cs.restoreGraphicsState();
                }
            }

            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            doc.save(baos);
            watermarkedBytes = baos.toByteArray();

        } catch (Exception e) {
            log.error("PdfWatermarkStrategy — filigranage échoué jobId={}: {}",
                    jobId, e.getMessage());
            throw new RuntimeException("Échec du filigranage PDF : " + e.getMessage(), e);
        }

        // Stockage du PDF filigrané
        String outputKey = "pdf-watermark/output/" + jobId + "/" + opts.outputFileName();
        fileStorageService.storeBytes(watermarkedBytes, outputKey, "application/pdf");

        // Persistance
        long processingMs = System.currentTimeMillis() - startMs;
        pdfWatermarkResultRepository.save(PdfWatermarkResult.builder()
                .jobId(jobId)
                .userId(userId)
                .sourceFileName(opts.sourceFileName())
                .sourceSizeBytes((long) rawBytes.length)
                .sourcePageCount(sourcePagesCount)
                .outputKey(outputKey)
                .outputFileName(opts.outputFileName())
                .outputSizeBytes((long) watermarkedBytes.length)
                .watermarkType(opts.watermarkType())
                .watermarkText(opts.text())
                .fontName(opts.fontName())
                .fontSize((short) opts.fontSize())
                .colorHex(opts.colorHex())
                .opacity(opts.opacity())
                .rotationDeg((short) opts.rotationDeg())
                .position(opts.position())
                .layer(opts.layer())
                .pagesMode(opts.pagesMode())
                .pagesRange(opts.pagesRange())
                .pagesWatermarked(pagesWatermarked)
                .processingMs(processingMs)
                .expiresAt(OffsetDateTime.now().plusHours(24))
                .build());

        log.info("PdfWatermarkStrategy — jobId={} terminé en {}ms ({} pages filigranées)",
                jobId, processingMs, pagesWatermarked);

        return outputKey;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    private void drawTile(PDPageContentStream cs, PDFont font, WatermarkOptions opts,
                          PDRectangle box, float textWidth, float[] rgb) throws IOException {
        float pw = box.getWidth();
        float ph = box.getHeight();
        float th = opts.fontSize() * 0.7f;
        float stepX = textWidth * 2.2f;
        float stepY = (opts.fontSize() + 30f) * 2.5f;

        int numX = (int) Math.ceil(pw / stepX) + 2;
        int numY = (int) Math.ceil(ph / stepY) + 2;

        for (int ix = 0; ix < numX; ix++) {
            for (int iy = 0; iy < numY; iy++) {
                float ox = -stepX / 2f + ix * stepX;
                float oy = -stepY / 2f + iy * stepY;

                AffineTransform at = new AffineTransform();
                at.translate(ox, oy);
                at.rotate(Math.toRadians(opts.rotationDeg()));
                at.translate(-textWidth / 2f, -th / 2f);

                cs.beginText();
                cs.setFont(font, opts.fontSize());
                cs.setTextMatrix(new Matrix(at));
                cs.showText(opts.text());
                cs.endText();
            }
        }
    }

    private List<Integer> resolvePageIndices(String pagesMode, String pagesRange,
                                              int totalPages) {
        return switch (pagesMode) {
            case "FIRST"  -> List.of(0);
            case "LAST"   -> List.of(totalPages - 1);
            case "ODD"    -> IntStream.range(0, totalPages)
                                .filter(i -> i % 2 == 0)  // 0-indexed → pages impaires
                                .boxed().toList();
            case "EVEN"   -> IntStream.range(0, totalPages)
                                .filter(i -> i % 2 != 0)
                                .boxed().toList();
            case "CUSTOM" -> parsePageRange(pagesRange, totalPages);
            default       -> IntStream.range(0, totalPages).boxed().toList(); // ALL
        };
    }

    private List<Integer> parsePageRange(String range, int totalPages) {
        List<Integer> indices = new ArrayList<>();
        if (range == null || range.isBlank()) return indices;
        for (String part : range.split(",")) {
            part = part.trim();
            if (part.contains("-")) {
                String[] bounds = part.split("-", 2);
                int from = Integer.parseInt(bounds[0].trim()) - 1;  // 1-indexed → 0-indexed
                int to   = Integer.parseInt(bounds[1].trim()) - 1;
                IntStream.rangeClosed(Math.max(0, from), Math.min(totalPages - 1, to))
                         .forEach(indices::add);
            } else {
                int page = Integer.parseInt(part) - 1;
                if (page >= 0 && page < totalPages) indices.add(page);
            }
        }
        return indices.stream().distinct().sorted().toList();
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

    private record WatermarkOptions(
        String sourceFileName, String outputFileName,
        String watermarkType, String text, String fontName,
        int fontSize, String colorHex, double opacity, int rotationDeg,
        String position, String layer, String pagesMode, String pagesRange
    ) {}
}
```

---

### 4.5 Entité `PdfWatermarkResult`

```java
@Entity
@Table(name = "pdf_watermark_results")
@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class PdfWatermarkResult {

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "job_id",  nullable = false, unique = true) private Long   jobId;
    @Column(name = "user_id")                                  private Long   userId;

    @Column(name = "source_file_name")   private String sourceFileName;
    @Column(name = "source_size_bytes")  private Long   sourceSizeBytes;
    @Column(name = "source_page_count")  private Integer sourcePageCount;

    @Column(name = "output_key",         nullable = false, columnDefinition = "TEXT")
    private String outputKey;
    @Column(name = "output_file_name")   private String outputFileName;
    @Column(name = "output_size_bytes")  private Long   outputSizeBytes;

    // ── Config filigrane ──────────────────────────────────────────────────────

    @Column(name = "watermark_type")     private String watermarkType;
    @Column(name = "watermark_text")     private String watermarkText;
    @Column(name = "font_name")          private String fontName;
    @Column(name = "font_size")          private Short  fontSize;
    @Column(name = "color_hex")          private String colorHex;
    @Column(name = "opacity")            private Double opacity;
    @Column(name = "rotation_deg")       private Short  rotationDeg;
    @Column(name = "position")           private String position;
    @Column(name = "layer")              private String layer;
    @Column(name = "pages_mode")         private String pagesMode;
    @Column(name = "pages_range")        private String pagesRange;
    @Column(name = "pages_watermarked")  private Integer pagesWatermarked;

    // ── Sprint 4 — image ─────────────────────────────────────────────────────

    @Column(name = "image_storage_key",        columnDefinition = "TEXT")
    private String  imageStorageKey;
    @Column(name = "image_original_filename")
    private String  imageOriginalFilename;
    @Column(name = "image_scale")
    private Double  imageScale;

    // ── Métriques & rétention ─────────────────────────────────────────────────

    @Column(name = "processing_ms")  private Long   processingMs;
    @Column(name = "expires_at")     private OffsetDateTime expiresAt;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @PrePersist
    void prePersist() { this.createdAt = OffsetDateTime.now(); }
}
```

---

### 4.6 Repository `PdfWatermarkResultRepository`

```java
public interface PdfWatermarkResultRepository extends JpaRepository<PdfWatermarkResult, Long> {

    Optional<PdfWatermarkResult> findByJobId(Long jobId);

    List<PdfWatermarkResult> findByExpiresAtBefore(OffsetDateTime threshold);
}
```

---

### 4.7 DTOs de réponse

```java
// PdfWatermarkJobResponse.java
@Value @Builder
public class PdfWatermarkJobResponse {
    Long   jobId;
    Long   documentId;
    String status;    // "PENDING"
    String message;
}

// PdfWatermarkResultResponse.java
@Value @Builder
public class PdfWatermarkResultResponse {
    Long   jobId;
    String status;              // PENDING | PROCESSING | COMPLETED | FAILED

    // ── COMPLETED ─────────────────────────────────────────────────────────────
    String  downloadUrl;        // /api/v1/pdf/watermark/{jobId}/download
    String  outputFileName;
    Long    outputSizeBytes;
    Long    processingMs;
    String  expiresAt;          // ISO-8601

    // Métadonnées du filigrane appliqué (carte résultat enrichie)
    String  watermarkType;      // "TEXT" | "IMAGE"
    String  watermarkText;
    String  position;           // "DIAGONAL", "CENTER", etc.
    String  layer;              // "FOREGROUND" | "BACKGROUND"
    Double  opacity;
    Integer pagesWatermarked;
    Integer sourcePageCount;

    // ── FAILED ───────────────────────────────────────────────────────────────
    String  errorMessage;
}
```

---

### 4.8 Controller `PdfWatermarkController`

```java
@RestController
@RequestMapping("/api/v1/pdf/watermark")
@RequiredArgsConstructor
@Tag(name = "PDF Watermark", description = "Ajout de filigrane sur un PDF")
public class PdfWatermarkController {

    private final PdfWatermarkService pdfWatermarkService;

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Ajoute un filigrane sur un PDF (texte ou image)")
    public PdfWatermarkJobResponse watermark(
            @Valid @ModelAttribute PdfWatermarkRequest request,
            @AuthenticationPrincipal UserDetails principal
    ) {
        String email = principal != null ? principal.getUsername() : null;
        return pdfWatermarkService.submit(request, email);
    }

    @GetMapping("/{jobId}/result")
    @Operation(summary = "Statut et résultat du job de filigranage")
    public ResponseEntity<PdfWatermarkResultResponse> getResult(@PathVariable Long jobId) {
        return ResponseEntity.ok(pdfWatermarkService.getResult(jobId));
    }

    @GetMapping("/{jobId}/download")
    @Operation(summary = "Télécharge le PDF filigrané")
    public ResponseEntity<byte[]> download(@PathVariable Long jobId) {
        PdfWatermarkService.PdfWatermarkDownload dl =
                pdfWatermarkService.getDownload(jobId);

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

### 4.9 Scheduler `PdfWatermarkCleanupJob`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfWatermarkCleanupJob {

    private final PdfWatermarkResultRepository pdfWatermarkResultRepository;
    private final FileStorageService            fileStorageService;

    /**
     * Toutes les heures. initialDelay de 6 min pour éviter la contention avec
     * PdfLockCleanupJob (2 min) et PdfUnlockCleanupJob (3 min) au démarrage.
     */
    @Scheduled(fixedDelay = 3_600_000, initialDelay = 360_000)
    @Transactional
    public void cleanupExpiredWatermarks() {
        List<PdfWatermarkResult> expired =
                pdfWatermarkResultRepository.findByExpiresAtBefore(OffsetDateTime.now());

        if (expired.isEmpty()) {
            log.debug("PdfWatermarkCleanupJob — aucun PDF filigrané expiré");
            return;
        }

        log.info("PdfWatermarkCleanupJob — {} fichier(s) filigrané(s) expiré(s)",
                expired.size());

        int deleted = 0;
        AtomicLong freed = new AtomicLong(0);

        for (PdfWatermarkResult result : expired) {
            try {
                if (result.getOutputKey() != null) {
                    fileStorageService.delete(result.getOutputKey());
                    if (result.getOutputSizeBytes() != null) {
                        freed.addAndGet(result.getOutputSizeBytes());
                    }
                }
                pdfWatermarkResultRepository.delete(result);
                deleted++;
            } catch (Exception e) {
                log.warn("PdfWatermarkCleanupJob — échec suppression jobId={}: {}",
                        result.getJobId(), e.getMessage());
            }
        }

        log.info("PdfWatermarkCleanupJob — {}/{} fichiers supprimés ({} MB libérés)",
                deleted, expired.size(),
                String.format("%.2f", freed.get() / (1024.0 * 1024.0)));
    }
}
```

---

### 4.10 Intégrations transverses

```java
// ProcessingJob.JobType
SUMMARY, QA, EXTRACTION, GENERATION, OCR, PDF_LOCK, PDF_UNLOCK, PDF_WATERMARK

// FeatureType.java
/** Filigranage PDF (quota en fichiers/jour). */
PDF_WATERMARK

// PlanConfig.java — limitFor()
case PDF_WATERMARK -> maxConversionsPerDay;  // Partage le quota de conversions

// PdfWatermarkStrategy implémente ProcessingStrategy
@Override public boolean needsRawBytes() { return true; }  // ← Obligatoire
```

---

## 5. Sprint 3 — Frontend

### 5.1 Fichiers à créer

```
kovixel-ui/src/app/
  ├── core/
  │     ├── models/pdf-watermark.model.ts      (interfaces TS)
  │     └── services/pdf-watermark.service.ts  (submit, getResult, download)
  └── features/tools/pdf-watermark/
        ├── pdf-watermark.routes.ts            (lazy-loading)
        └── pdf-watermark.component.ts         (composant principal + canvas preview)
```

---

### 5.2 Route et catalogue

```typescript
// app.routes.ts — AVANT la route générique tools/:slug
{
  path: 'tools/pdf/watermark',
  canActivate: [softAuthGuard],
  loadChildren: () =>
    import('./features/tools/pdf-watermark/pdf-watermark.routes')
      .then(m => m.PDF_WATERMARK_ROUTES),
  data: { title: 'Ajouter un filigrane', guestFeature: 'pdf-watermark' },
},

// tools-config.ts — entrée catalogue
// Icône recommandée : Stamp (lucide-angular) — importer depuis 'lucide-angular'
{
  slug:            'pdf/watermark',
  name:            'Filigrane PDF',
  description:     'Apposez un filigrane texte ou image sur toutes vos pages — 7 positions, opacité, calque avant/arrière-plan',
  longDescription: '…',
  category:        'compress',
  icon:            Stamp,     // import { Stamp } from 'lucide-angular'
  badge:           'NEW',
  estimatedTime:   '~3 secondes',
  isPro:           false,
  isAvailable:     true,
  backendEndpoint: '/api/v1/pdf/watermark',
  keywords: [
    'filigrane', 'watermark', 'tampon', 'confidentiel', 'brouillon', 'copie',
    'approuvé', 'draft', 'confidential', 'stamp', 'texte', 'image', 'logo',
    'transparent', 'opacité', 'diagonal', 'calque', 'avant-plan', 'arrière-plan',
  ],
},
```

---

### 5.3 UX — Structure de la page

Étapes : `upload → configure → processing → result | error`

```
┌───────────────────────────────────────────────────────────────────┐
│  🖋 Ajouter un filigrane PDF                                       │
│  Texte ou image · 7 positions · opacité configurable · 24 h       │
└───────────────────────────────────────────────────────────────────┘

[1] Fichier  ──────  [2] Filigrane  ──────  [3] Traitement  ──  [4] Résultat

╔══════════════════════════════════════════════════════════════════╗
║  ÉTAPE 2 — Configuration du filigrane                           ║
╠═══════════════════════════╦══════════════════════════════════════╣
║                           ║                                      ║
║  Profils rapides :        ║      APERÇU EN TEMPS RÉEL           ║
║  [CONFIDENTIEL] [BROUILLON]║                                      ║
║  [COPIE] [APPROUVÉ]       ║  ┌──────────────────────────────┐   ║
║                           ║  │                              │   ║
║  ─────────────────────    ║  │   (représentation canvas     │   ║
║  Texte *                  ║  │    du PDF avec filigrane)    │   ║
║  [CONFIDENTIEL         ]  ║  │                              │   ║
║                           ║  │  C O N F I D E N T I E L    │   ║
║  Police                   ║  │       ↗ (diagonal, rouge)   │   ║
║  [Helvetica Bold    ▼]    ║  │                              │   ║
║                           ║  └──────────────────────────────┘   ║
║  Taille    Opacité        ║                                      ║
║  [ 60 ] px [  30 ] %      ║  (mis à jour en temps réel à chaque ║
║                           ║   frappe / glissement de curseur)    ║
║  Couleur                  ║                                      ║
║  [████] #FF0000           ║                                      ║
║                           ║                                      ║
║  Rotation    Position     ║                                      ║
║  [ 45 ]°    [Diagonal ▼]  ║                                      ║
║                           ║                                      ║
║  Calque                   ║                                      ║
║  ● Avant-plan (par-dessus)║                                      ║
║  ○ Arrière-plan (en dessous)                                     ║
║                           ║                                      ║
╠═══════════════════════════╩══════════════════════════════════════╣
║  [ ← Retour ]                         [ 🖋 Appliquer → ]        ║
╚══════════════════════════════════════════════════════════════════╝
```

---

### 5.4 Aperçu canvas en temps réel ⭐ (différenciateur majeur)

L'aperçu est un canvas HTML5 qui simule le filigrane **avant la soumission**, sans aucun
appel serveur. Il se met à jour à chaque modification d'un paramètre.

```typescript
// Dans pdf-watermark.component.ts

private _drawPreview(): void {
  const canvas = this.previewCanvas.nativeElement;
  const ctx    = canvas.getContext('2d')!;
  const W = canvas.width;
  const H = canvas.height;

  // Fond page (gris clair simulant un PDF)
  ctx.fillStyle = '#f8f8f8';
  ctx.fillRect(0, 0, W, H);

  // Lignes de texte simulées
  ctx.fillStyle = '#e0e0e0';
  for (let y = 40; y < H - 40; y += 22) {
    ctx.fillRect(30, y, W - 60, 10);
  }

  // Filigrane
  const text    = this.watermarkText() || 'FILIGRANE';
  const opacity = this.opacity() / 100;
  const color   = this.colorHex();
  const size    = Math.max(10, Math.min(this.fontSize() * (W / 595), 80));  // scale A4 → canvas
  const angle   = (this.rotationDeg() * Math.PI) / 180;

  ctx.save();
  ctx.globalAlpha = opacity;
  ctx.fillStyle   = color;
  ctx.font        = `bold ${size}px Helvetica, sans-serif`;
  ctx.textAlign   = 'center';
  ctx.textBaseline = 'middle';

  if (this.position() === 'TILE') {
    const tw    = ctx.measureText(text).width;
    const stepX = tw * 2.2;
    const stepY = size * 3.5;
    for (let x = 0; x < W + stepX; x += stepX) {
      for (let y = 0; y < H + stepY; y += stepY) {
        ctx.save();
        ctx.translate(x - stepX / 2, y - stepY / 2);
        ctx.rotate(angle);
        ctx.fillText(text, 0, 0);
        ctx.restore();
      }
    }
  } else {
    const [cx, cy] = this._positionToCoords(W, H, this.position());
    ctx.translate(cx, cy);
    ctx.rotate(angle);
    ctx.fillText(text, 0, 0);
  }

  ctx.restore();
}
```

> **Rendu au format HTML** : le canvas est une div `<canvas #previewCanvas>` intégrée
> dans le composant. Chaque signal déclenche `effect(() => this._drawPreview())` via
> `effect()` Angular.

---

### 5.5 Profils prédéfinis

```typescript
readonly PRESETS = [
  {
    label: 'CONFIDENTIEL',
    text: 'CONFIDENTIEL', fontName: 'HELVETICA_BOLD', fontSize: 60,
    colorHex: '#DC2626', opacity: 30, rotationDeg: 45, position: 'DIAGONAL',
    layer: 'FOREGROUND',
  },
  {
    label: 'BROUILLON',
    text: 'BROUILLON', fontName: 'HELVETICA_BOLD', fontSize: 72,
    colorHex: '#6B7280', opacity: 25, rotationDeg: 45, position: 'DIAGONAL',
    layer: 'FOREGROUND',
  },
  {
    label: 'COPIE',
    text: 'COPIE', fontName: 'HELVETICA_BOLD', fontSize: 80,
    colorHex: '#2563EB', opacity: 20, rotationDeg: 0, position: 'CENTER',
    layer: 'FOREGROUND',
  },
  {
    label: 'APPROUVÉ',
    text: 'APPROUVÉ', fontName: 'HELVETICA_BOLD', fontSize: 60,
    colorHex: '#16A34A', opacity: 35, rotationDeg: -15, position: 'CENTER',
    layer: 'FOREGROUND',
  },
] as const;

applyPreset(preset: typeof this.PRESETS[number]): void {
  this.watermarkText.set(preset.text);
  this.fontName.set(preset.fontName);
  this.fontSize.set(preset.fontSize);
  this.colorHex.set(preset.colorHex);
  this.opacity.set(preset.opacity);
  this.rotationDeg.set(preset.rotationDeg);
  this.position.set(preset.position);
  this.layer.set(preset.layer);
  // L'effet Angular redessine le canvas automatiquement
}
```

---

### 5.6 Carte résultat enrichie

```
╔══════════════════════════════════════════════════════════════╗
║  ✅  Filigrane appliqué avec succès                          ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  🖋 Filigrane                                                ║
║     "CONFIDENTIEL"  · Helvetica Bold · 60 pt               ║
║     Rouge #DC2626 · 30 % opacité · diagonal 45°            ║
║     Calque : avant-plan                                      ║
║                                                              ║
║  📄 12 pages filigranées   📦 248 Ko   ⚡ 0.82 s           ║
║                                                              ║
║  [  ⬇ Télécharger rapport_filigrané.pdf  ]                 ║
║  [  🔄 Nouveau fichier  ]                                   ║
║                                                              ║
║  ⏳ Supprimé de nos serveurs dans 24 heures.               ║
╚══════════════════════════════════════════════════════════════╝
```

---

### 5.7 Modèle TypeScript

```typescript
// pdf-watermark.model.ts

export interface PdfWatermarkJobResponse {
  jobId:      number;
  documentId: number;
  status:     string;
  message:    string;
}

export interface PdfWatermarkResultResponse {
  jobId:   number;
  status:  string;             // PENDING | PROCESSING | COMPLETED | FAILED

  // COMPLETED
  downloadUrl?:       string;
  outputFileName?:    string;
  outputSizeBytes?:   number;
  processingMs?:      number;
  expiresAt?:         string;

  // Métadonnées carte résultat
  watermarkType?:     string;  // 'TEXT' | 'IMAGE'
  watermarkText?:     string;
  position?:          string;
  layer?:             string;
  opacity?:           number;
  pagesWatermarked?:  number;
  sourcePageCount?:   number;

  // FAILED
  errorMessage?: string;
}

export type WatermarkPosition =
  'CENTER' | 'DIAGONAL' | 'TOP_LEFT' | 'TOP_RIGHT' |
  'BOTTOM_LEFT' | 'BOTTOM_RIGHT' | 'TILE';

export type WatermarkLayer    = 'FOREGROUND' | 'BACKGROUND';
export type WatermarkFontName =
  'HELVETICA' | 'HELVETICA_BOLD' | 'HELVETICA_OBLIQUE' | 'HELVETICA_BOLD_OBLIQUE' |
  'TIMES_ROMAN' | 'TIMES_BOLD' | 'TIMES_ITALIC' | 'TIMES_BOLD_ITALIC' |
  'COURIER' | 'COURIER_BOLD' | 'COURIER_OBLIQUE' | 'COURIER_BOLD_OBLIQUE';
```

---

### 5.8 Service Angular

```typescript
@Injectable({ providedIn: 'root' })
export class PdfWatermarkService {
  private readonly http = inject(HttpClient);
  private readonly base = `${environment.apiUrl}/v1/pdf/watermark`;

  submit(file: File, config: WatermarkConfig): Observable<PdfWatermarkJobResponse> {
    const fd = new FormData();
    fd.append('file',         file, file.name);
    fd.append('watermarkType', config.watermarkType);
    fd.append('text',          config.text);
    fd.append('fontName',      config.fontName);
    fd.append('fontSize',      String(config.fontSize));
    fd.append('colorHex',      config.colorHex);
    fd.append('opacity',       String(config.opacity / 100));  // % → 0.0–1.0
    fd.append('rotationDeg',   String(config.rotationDeg));
    fd.append('position',      config.position);
    fd.append('layer',         config.layer);
    fd.append('pagesMode',     config.pagesMode ?? 'ALL');
    if (config.pagesRange) fd.append('pagesRange', config.pagesRange);
    return this.http.post<PdfWatermarkJobResponse>(this.base, fd);
  }

  getResult(jobId: number): Observable<PdfWatermarkResultResponse> {
    return this.http.get<PdfWatermarkResultResponse>(`${this.base}/${jobId}/result`);
  }

  downloadWatermarked(jobId: number): Observable<Blob> {
    return this.http.get(`${this.base}/${jobId}/download`, { responseType: 'blob' });
  }
}
```

---

## 6. Sprint 4 — Filigrane image & sélection de pages

### 6.1 Filigrane image (PNG / JPG / SVG)

**Contexte :** Sprint 2-3 = texte uniquement. Sprint 4 ajoute la possibilité d'apposer
un logo ou une image à la place du texte — fonctionnalité PRO chez les concurrents,
gratuite chez Kovixel.

**Backend — `PdfWatermarkStrategy.processBytes()` — branche IMAGE :**

```java
if ("IMAGE".equals(opts.watermarkType())) {
    // Récupérer l'image depuis le stockage (uploadée pendant submit())
    byte[] imageBytes;
    try (InputStream is = fileStorageService.retrieve(opts.imageStorageKey())) {
        imageBytes = is.readAllBytes();
    }

    PDImageXObject pdImage =
            PDImageXObject.createFromByteArray(doc, imageBytes, "watermark-image");

    for (int idx : pageIndices) {
        PDPage page = doc.getPage(idx);
        PDRectangle mediaBox = page.getMediaBox();
        float pw = mediaBox.getWidth();
        float ph = mediaBox.getHeight();

        float imgW = pdImage.getWidth()  * (float) opts.imageScale();
        float imgH = pdImage.getHeight() * (float) opts.imageScale();
        float x    = (pw - imgW) / 2f;
        float y    = (ph - imgH) / 2f;

        try (PDPageContentStream cs = new PDPageContentStream(
                doc, page, appendMode, true, true)) {
            cs.saveGraphicsState();
            cs.setGraphicsStateParameters(gs);   // transparence
            cs.drawImage(pdImage, x, y, imgW, imgH);
            cs.restoreGraphicsState();
        }
    }
}
```

**Upload de l'image dans `submit()` :**

```java
// Stockage temporaire de l'image (liée au jobId, supprimée avec le résultat)
if (req.getWatermarkType() == WatermarkType.IMAGE && req.getImageFile() != null) {
    byte[] imgBytes = req.getImageFile().getBytes();
    String imgKey   = "pdf-watermark/images/" + jobId + "/" +
                      sanitizeFileName(req.getImageFile().getOriginalFilename());
    fileStorageService.storeBytes(imgBytes, imgKey, req.getImageFile().getContentType());
    // Inclure imgKey dans inputData JSON → la stratégie le lit
    data.put("imageStorageKey", imgKey);
}
```

**Formats d'image supportés :** JPEG, PNG (avec transparence). SVG via rasterisation
(PDFBox ne supporte pas SVG natif — utiliser Apache Batik pour convertir en PNG).

---

### 6.2 Sélecteur de pages complet (UI)

```
Pages concernées :

  ● Toutes les pages
  ○ Première page uniquement
  ○ Dernière page uniquement
  ○ Pages impaires (1, 3, 5…)
  ○ Pages paires (2, 4, 6…)
  ○ Plage personnalisée  →  [ 1,3,5-10     ]
                              ↑ Format : 1,3,5-10 (validé en temps réel)
```

Le sélecteur est déjà préparé dans le backend (Sprint 2) via `resolvePageIndices()`.
Le Sprint 4 se limite à exposer l'UI complète dans le composant Angular (Sprint 2 expose
`pagesMode = ALL` uniquement).

---

### 6.3 Cas limites à couvrir

| Cas | Comportement attendu |
|-----|---------------------|
| PDF chiffré (protégé par mot de passe) | 422 « Ce PDF est protégé — déverrouillez-le d'abord » |
| Fichier non-PDF | 415 (validation MIME) |
| PDF corrompu | 400 « Fichier PDF invalide ou corrompu » |
| PDF de 0 page | 400 |
| Texte vide (watermarkType = TEXT) | 400 (`@Size min=1`) |
| Texte > 200 caractères | 400 (`@Size max=200`) |
| Couleur invalide (format non #RRGGBB) | 400 (`@Pattern`) |
| Opacité hors [0.05, 1.0] | 400 (`@DecimalMin / @DecimalMax`) |
| Rotation hors [-360, 360] | 400 (`@Min / @Max`) |
| pagesMode = CUSTOM sans pagesRange | 400 (validation service) |
| pagesRange invalide ('1-x', 'abc') | 400 (`@Pattern`) |
| Pages hors limites dans pagesRange | Pages ignorées silencieusement (clamp) |
| Image trop grande (IMAGE type) | 413 (limite fichier source + image ≤ 5 MB) |
| Image format non supporté | 415 (validation MIME image) |
| PDF > limite plan | 413 avec rappel de la limite |
| Double-soumission (double-clic) | Debounce frontend + idempotency check backend |

---

### 6.4 Tests de compatibilité — PDF filigrané

**Vérifier que le filigrane est visible et correctement positionné sur :**
- [ ] Adobe Acrobat Reader (Windows & macOS)
- [ ] Aperçu (macOS)
- [ ] Evince / Okular (Linux)
- [ ] Firefox PDF viewer
- [ ] Chrome PDF viewer
- [ ] PDF Expert (iOS)

**Vérifier la couche ARRIÈRE-PLAN (le contenu doit être lisible par-dessus) :**
- [ ] Texte du document non masqué par le filigrane
- [ ] Filigrane visible mais non obstructif

**Vérifier tous les modes de position :**
- [ ] CENTER, DIAGONAL, TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, TILE

**Vérifier les polices Standard14 :**
- [ ] Helvetica, Times, Courier — toutes les variantes bold/italic

**Vérifier les niveaux d'opacité extrêmes :**
- [ ] 5 % (très transparent), 50 %, 100 % (opaque)

---

## 7. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Jobs par jour | 10 (quota conversions) | 200 | Illimité |
| Rétention du PDF filigrané | 24 h | 7 jours | 30 jours |
| Filigrane texte | ✅ | ✅ | ✅ |
| Filigrane image | ✅ (Sprint 4) | ✅ | ✅ |
| Mode TILE | ✅ | ✅ | ✅ |
| Calque avant/arrière-plan | ✅ | ✅ | ✅ |
| Sélection de pages | ✅ (Sprint 4) | ✅ | ✅ |
| API directe | ❌ | ✅ | ✅ |

> Le quota `PDF_WATERMARK` partage `maxConversionsPerDay` dans `PlanConfig.limitFor()`.
> Peut être découplé si la consommation le justifie.

---

## 8. Référence — Positions, polices et opacité

### 8.1 Positions disponibles

| Clé | Description | Cas d'usage |
|-----|-------------|------------|
| `DIAGONAL` | Centré, incliné selon la diagonale naturelle de la page | Filigrane classique CONFIDENTIEL / BROUILLON |
| `CENTER` | Centré horizontalement et verticalement, rotation libre | Tampon APPROUVÉ / COPIE |
| `TOP_LEFT` | Coin supérieur gauche | En-tête discret |
| `TOP_RIGHT` | Coin supérieur droit | Logo léger |
| `BOTTOM_LEFT` | Coin inférieur gauche | Mention légale |
| `BOTTOM_RIGHT` | Coin inférieur droit | Copyright |
| `TILE` | Motif répété sur toute la page | Protection maximale anti-scan |

### 8.2 Polices Standard14 (PDFBox — sans embedding)

| Clé `FontName` | Apparence |
|---------------|-----------|
| `HELVETICA` | Sans-serif, normal |
| `HELVETICA_BOLD` | Sans-serif, gras ← **défaut recommandé** |
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

### 8.3 Guide opacité recommandée

| Valeur | Usage |
|--------|-------|
| 5–15 % | Filigrane très discret (arrière-plan, logos d'eau) |
| 20–35 % | **Recommandé** — visible sans gêner la lecture ← *défaut 30 %* |
| 40–60 % | Marquage fort (documents confidentiels haute sécurité) |
| 70–100 % | Opaque — utilisé surtout en avant-plan avec texte court |

### 8.4 Rotations courantes

| Angle | Effet |
|-------|-------|
| 0° | Horizontal (pour CENTER, coins) |
| 45° | Diagonal montant ← *défaut DIAGONAL* |
| -45° | Diagonal descendant |
| `atan2(H, W)` | Diagonale exacte de la page (calculé par le backend pour DIAGONAL) |
| 90° | Vertical (texte vers le haut) |

---

## Ordre d'implémentation

```
Sprint 1  →  Sprint 2  →  Sprint 3  →  Sprint 4
Migrations   Backend      Frontend     Image + pages
(V41, V42)  (strategy,    (canvas live, (image watermark,
             service,      presets,      sélecteur pages,
             controller,   résultat      tests compat.)
             cleanup)      enrichi)
```

---

## Pont vers les outils PDF futurs

L'infrastructure async + cleanup est désormais partagée par PDF Lock, PDF Unlock
et PDF Watermark. Les prochains outils réutilisent le même pattern `needsRawBytes() = true` :

| Outil | Strategy | Spécificité |
|-------|----------|-------------|
| **PDF Compress** | `PdfCompressStrategy` | Ghostscript ou PDFBox optimizer |
| **PDF Merge** | `PdfMergeStrategy` | Plusieurs `MultipartFile` → un seul PDF |
| **PDF Split** | `PdfSplitStrategy` | Un PDF → N fichiers ZIP |
| **PDF Rotate** | `PdfRotateStrategy` | Simple, peut rester sync si < 1 s |
| **PDF → Images** | `PdfToImagesStrategy` | PDFRenderer → ZIP d'images |
| **Numérotation pages** | `PdfPageNumberStrategy` | Insertion pagination |

Pour chaque nouvel outil : (1) migration job_type + table résultat, (2) strategy avec
`needsRawBytes() = true`, (3) entrée catalogue + route, (4) composant Angular.
