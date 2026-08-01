# Roadmap — Outil « Signature Électronique PDF »

> **Statut :** Spec technique v1.0
> **Date :** 2026-06-21
> **Objectif qualité :** Supérieur ou égal aux leaders du marché (DocuSign, HelloSign, Adobe Sign, iLovePDF)

---

## Table des matières

1. [Architecture & décisions](#1-architecture--décisions)
2. [Analyse concurrentielle](#2-analyse-concurrentielle)
3. [Sprint 1 — Migrations DB](#3-sprint-1--migrations-db)
4. [Sprint 2 — Backend](#4-sprint-2--backend)
5. [Sprint 3 — Frontend](#5-sprint-3--frontend)
6. [Sprint 4 — Signature cryptographique, multi-signataires & audit](#6-sprint-4--signature-cryptographique-multi-signataires--audit)
7. [Limites par plan](#7-limites-par-plan)
8. [Référence — Modes, champs et coordonnées](#8-référence--modes-champs-et-coordonnées)

---

## 1. Architecture & décisions

### 1.1 Pipeline asynchrone (identique à PDF Watermark / Page Number)

L'ajout d'une signature sur un PDF volumineux (rendu PDF.js page par page, génération
de l'image de signature typée, embedding PDFBox) peut dépasser 5 secondes sur des
documents multi-pages. Le pipeline async est obligatoire, identique aux outils précédents :

```
POST /api/v1/pdf/esignature    → 202 { jobId }             (retour immédiat)
Worker @Async                  → signe le document          (arrière-plan)
GET  /api/v1/pdf/esignature/{jobId}/result  → polling statut
GET  /api/v1/pdf/esignature/{jobId}/download → téléchargement
```

### 1.2 Simplification clé : AUCUN Redis nécessaire (modes visuels) ⭐

Comme PDF Watermark et PDF Page Number — aucune donnée sensible dans la configuration.
La signature visuelle est transmise comme fichier multipart (`signatureFile`) et stockée
temporairement dans MinIO. La config complète transite dans `processing_jobs.inputData`
(colonne TEXT, chiffrée au repos par la DB) :

```
PDF Lock   →  Redis TTL (mot de passe : sensible)
PDF Unlock →  Redis TTL (mot de passe : sensible)
Watermark  →  inputData JSON   (config : non sensible)
Page Number →  inputData JSON   (config : non sensible)
Signature  →  inputData JSON + MinIO temp   (image signature : non sensible) ← PAS de Redis
```

> **Exception Sprint 4 — certificat PKCS#12** : le fichier de certificat numérique
> (`.p12`) sera stocké dans Redis avec un TTL de 30 min. C'est la seule exception à
> la règle, uniquement pour la signature cryptographique.

### 1.3 Modes de signature — 3 méthodes de création

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Méthode         │  Canal vers le backend                                │
├──────────────────┼──────────────────────────────────────────────────────┤
│  DRAW  (dessin)  │  Canvas → PNG blob → multipart `signatureFile`       │
│  UPLOAD (image)  │  PNG/JPG/SVG uploadé → multipart `signatureFile`      │
│  TYPE  (frappe)  │  Texte + police → params `signatureText`, `signatureFont` │
└──────────────────────────────────────────────────────────────────────────┘
```

En modes DRAW et UPLOAD, le backend stocke l'image dans MinIO sous
`pdf-esignature/signatures/{jobId}/signature.png` pendant le traitement,
l'intègre dans le PDF, puis supprime la clé MinIO **immédiatement après**.

### 1.4 Système de champs — positionnement précis sur les pages PDF

Le cœur de l'outil : l'utilisateur place des **champs de signature** sur les pages
du PDF via un aperçu interactif (PDF.js). Chaque champ est transmis en JSON dans
`inputData` :

```json
{
  "fields": [
    {
      "page": 1,
      "xPct": 12.5,
      "yPct": 78.3,
      "widthPct": 25.0,
      "heightPct": 8.5,
      "type": "SIGNATURE",
      "label": "Signature du client"
    },
    {
      "page": 1,
      "xPct": 65.0,
      "yPct": 78.3,
      "widthPct": 20.0,
      "heightPct": 4.0,
      "type": "DATE",
      "dateFormat": "dd/MM/yyyy"
    },
    {
      "page": 3,
      "xPct": 80.0,
      "yPct": 90.0,
      "widthPct": 12.0,
      "heightPct": 4.0,
      "type": "INITIALS"
    }
  ]
}
```

Les coordonnées sont stockées en **pourcentage de la page** (0–100 %) pour être
indépendantes de la résolution PDF réelle et du zoom du canvas Angular.

**Conversion coordonnées % → points PDF dans `PdfEsignatureStrategy` :**

```java
// xPct, yPct = position du coin haut-gauche du champ en % de la page
// PDFBox : origine bas-gauche, unité = points (1 pt = 1/72 pouce)

float pageWidthPt  = mediaBox.getWidth();
float pageHeightPt = mediaBox.getHeight();

float xPt = (float)(field.xPct()      / 100.0 * pageWidthPt);
float wPt = (float)(field.widthPct()   / 100.0 * pageWidthPt);
float hPt = (float)(field.heightPct()  / 100.0 * pageHeightPt);
// PDFBox Y mesuré depuis le bas → inverser depuis le haut Angular
float yPt = pageHeightPt - (float)(field.yPct() / 100.0 * pageHeightPt) - hPt;
```

### 1.5 Types de champs disponibles

| Type        | Contenu rendu                                              | MVP ?          |
|-------------|-----------------------------------------------------------|----------------|
| `SIGNATURE` | Image de signature (DRAW / UPLOAD / TYPE) — taille normale | ✅ Sprint 2-3  |
| `INITIALS`  | Image de signature à 40 % de la taille — paraphe          | ✅ Sprint 2-3  |
| `DATE`      | Date du traitement au format configuré (ex. `21/06/2026`)  | ✅ Sprint 2-3  |
| `TEXT`      | Texte libre saisi par l'utilisateur                        | Sprint 4       |
| `CHECKBOX`  | Case cochée (✓) — formulaires de consentement             | Sprint 4       |

### 1.6 Stockage du PDF signé

Clé MinIO/local : `pdf-esignature/output/{jobId}/{outputFileName}`

Nom de sortie : `{originalName}_signé.pdf`

TTL d'expiration : 24 h (FREE), 7 j (PRO), 30 j (ENTERPRISE). Auto-delete par
`PdfEsignatureCleanupJob`, décalé de 12 min par rapport au démarrage de l'app
(après PdfPageNumberCleanupJob à 9 min).

### 1.7 PDF.js — rendu de prévisualisation des vraies pages

Contrairement aux outils précédents (canvas A4 simulé), l'outil E-Signature rend
**les vraies pages PDF** dans le navigateur via PDF.js pour permettre le placement
précis des champs de signature. Cela nécessite :

1. `pdfjs-dist` installé dans kovixel-ui (`npm install pdfjs-dist`)
2. Worker PDF.js copié dans `public/assets/` via `angular.json`
3. Service `PdfRenderService` : charge le PDF, rend chaque page sur un `<canvas>`
4. Overlay Angular (div `absolute` sur le canvas) pour les champs drag & drop

> **Décision :** PDF.js est indispensable à la qualité DocuSign. Les outils précédents
> utilisaient un aperçu simulé (suffisant pour positionner une marge ou un filigrane).
> Pour la signature, l'utilisateur **doit** voir la vraie page pour placer avec précision.

---

## 2. Analyse concurrentielle

| Critère | iLovePDF | SmallPDF | HelloSign | Adobe Sign | **Kovixel** |
|---------|----------|----------|-----------|------------|-------------|
| Dessin signature (canvas) | ✅ | ✅ | ✅ | ✅ | **✅ (FREE)** |
| Upload image signature | ✅ | ✅ | ✅ | ✅ | **✅ (FREE)** |
| Signature typée (texte → cursive) | ❌ | ✅ | ✅ | ✅ | **✅ (FREE, 6 polices)** |
| Placement drag & drop libre | ❌ (position fixe) | ❌ (position fixe) | ✅ | ✅ | **✅ (FREE)** |
| Aperçu PDF réel (PDF.js) | ❌ | ❌ | ✅ | ✅ | **✅** |
| Champ Initiales distinct | ❌ | ❌ | ✅ | ✅ | **✅ (FREE)** |
| Champ Date automatique | ❌ | ❌ | ✅ | ✅ | **✅ (FREE)** |
| Champ Texte libre | ❌ | ❌ | ✅ | ✅ | **Sprint 4** |
| Placement sur plusieurs pages | ❌ | ❌ | ✅ | ✅ | **✅** |
| Redimensionnement du champ | ❌ | ❌ | ✅ | ✅ | **✅** |
| Couleur de signature libre | ❌ | ❌ | ❌ | ✅ | **✅ (FREE)** |
| Signature cryptographique (PAdES) | ❌ | ❌ | ✅ (ESIGN) | ✅ | **Sprint 4** |
| Multi-signataires (workflow) | ❌ | ❌ | ✅ | ✅ | **Sprint 4** |
| Audit trail téléchargeable | ❌ | ❌ | ✅ | ✅ | **Sprint 4** |
| QR code de vérification | ❌ | ❌ | ❌ | ✅ | **Sprint 4** |
| Quota par plan | ❌ | ❌ | 3/mois FREE | PRO uniquement | **✅ FREE/PRO/ENTERPRISE** |

**Avantages Kovixel uniques :**

1. **Placement drag & drop en FREE** : iLovePDF et SmallPDF imposent une position fixe
   (généralement bas de page). Kovixel permet un placement libre sur n'importe quelle
   zone de n'importe quelle page.
2. **Aperçu PDF réel via PDF.js** : contrairement à un canvas A4 générique, l'utilisateur
   voit exactement ses pages, son contenu, ses lignes de signature — et peut placer avec
   une précision pixel.
3. **3 modes de signature en FREE** : dessin, upload et frappe disponibles sans abonnement.
   HelloSign et Adobe Sign restreignent certains modes à leur offre payante.
4. **Champ Date automatique** : injecté automatiquement à la date de signature — aucune
   saisie manuelle, aucune erreur de date.
5. **Couleur de signature libre** : bleu marine, noir, rouge — selon l'usage (contrats,
   bons, tampons). Aucun concurrent FREE ne propose cela.
6. **Architecture extensible Sprint 4** : cryptographie + multi-signataires planifiés
   dès le modèle de données initial (colonnes Sprint 4 préajoutées en V46).

---

## 3. Sprint 1 — Migrations DB

### V45 — Ajout de `PDF_ESIGNATURE` au type de job

Même pattern idempotent que V36 (PDF Lock), V38 (PDF Unlock), V41 (Watermark) et
V43 (Page Number) :

```sql
-- V45 : ajout de PDF_ESIGNATURE à la contrainte CHECK sur processing_jobs.job_type
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
                'PDF_PAGE_NUMBER', 'PDF_ESIGNATURE'
            ));
    END IF;
END $$;
```

Ajouter `PDF_ESIGNATURE` à l'enum Java `ProcessingJob.JobType`.

---

### V46 — Table `pdf_esignature_results`

Table enrichie avec toute la config de l'outil pour l'audit trail et la carte résultat.
Les colonnes Sprint 4 (cryptographie, multi-signataires) sont déjà présentes pour éviter
une migration ultérieure.

```sql
CREATE TABLE IF NOT EXISTS pdf_esignature_results (
    id                     BIGSERIAL       PRIMARY KEY,
    job_id                 BIGINT          NOT NULL
                                           REFERENCES processing_jobs(id) ON DELETE CASCADE,
    user_id                BIGINT,

    -- Fichier source
    source_file_name       VARCHAR(255),
    source_size_bytes      BIGINT,
    source_page_count      INTEGER,

    -- Fichier produit
    output_key             TEXT            NOT NULL,
    output_file_name       VARCHAR(255),
    output_size_bytes      BIGINT,

    -- Configuration — Mode de signature
    signature_mode         VARCHAR(10)     NOT NULL,
                                           -- 'DRAW' | 'UPLOAD' | 'TYPE'

    -- Configuration — Signature typée (TYPE mode)
    signature_text         VARCHAR(200),
    signature_font         VARCHAR(50),    -- ex. 'DANCING_SCRIPT' | 'GREAT_VIBES' | ...

    -- Configuration — Couleur de signature
    signature_color        VARCHAR(7)      NOT NULL DEFAULT '#1a1a2e',
                                           -- Hex RGB, défaut : bleu marine (imite l'encre)

    -- Clé image temporaire (DRAW/UPLOAD — supprimée immédiatement après traitement)
    signature_image_key    TEXT,           -- NULL après nettoyage par le worker

    -- Champs placés (sérialisation JSON)
    fields_json            TEXT            NOT NULL,
                                           -- [{page, xPct, yPct, widthPct, heightPct, type, ...}]
    fields_count           SMALLINT        NOT NULL DEFAULT 1,
    pages_signed           SMALLINT,       -- Nombre de pages portant au moins un champ

    -- Sprint 4 — Signature cryptographique
    is_digitally_signed    BOOLEAN         NOT NULL DEFAULT FALSE,
    certification_level    VARCHAR(30),    -- 'NOT_CERTIFIED' | 'CERTIFIED_NO_CHANGES'
    signer_name            VARCHAR(200),   -- Extrait du certificat PKCS#12
    signer_email           VARCHAR(320),

    -- Sprint 4 — Multi-signataires (workflow)
    workflow_id            BIGINT,         -- Référence vers pdf_sign_workflows (Sprint 4)
    signer_order           SMALLINT,       -- Position dans le workflow (1, 2, 3…)
    workflow_status        VARCHAR(20),    -- 'INITIATED' | 'PENDING_OTHERS' | 'COMPLETED'

    -- Métriques
    processing_ms          BIGINT,

    -- Rétention
    expires_at             TIMESTAMPTZ,
    created_at             TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pdf_esig_results_job_id
    ON pdf_esignature_results (job_id);

CREATE INDEX IF NOT EXISTS idx_pdf_esig_results_user_id
    ON pdf_esignature_results (user_id);

CREATE INDEX IF NOT EXISTS idx_pdf_esig_results_expires
    ON pdf_esignature_results (expires_at)
    WHERE expires_at IS NOT NULL;

-- Sprint 4 : retrouver tous les jobs d'un même workflow
CREATE INDEX IF NOT EXISTS idx_pdf_esig_results_workflow
    ON pdf_esignature_results (workflow_id)
    WHERE workflow_id IS NOT NULL;
```

> **Sprint 4 :** les colonnes `is_digitally_signed`, `certification_level`,
> `signer_name`, `signer_email`, `workflow_id`, `signer_order`, `workflow_status`
> sont préajoutées dans V46 pour éviter une migration V47 uniquement sur ces champs.

---

## 4. Sprint 2 — Backend

### 4.1 Structure du package

```
com.kovixel.pdfesignature
  ├── controller/
  │     └── PdfEsignatureController.java
  ├── service/
  │     ├── PdfEsignatureService.java           (interface + record PdfEsignatureDownload)
  │     └── PdfEsignatureServiceImpl.java
  ├── strategy/
  │     └── PdfEsignatureStrategy.java          (implements ProcessingStrategy)
  ├── scheduler/
  │     └── PdfEsignatureCleanupJob.java
  ├── entity/
  │     └── PdfEsignatureResult.java
  ├── repository/
  │     └── PdfEsignatureResultRepository.java
  └── dto/
        ├── PdfEsignatureRequest.java
        ├── SignatureFieldDto.java
        ├── PdfEsignatureJobResponse.java
        └── PdfEsignatureResultResponse.java
```

---

### 4.2 DTO `PdfEsignatureRequest`

Multipart form-data. Le mot de passe du certificat (Sprint 4) est le seul champ sensible —
il n'est jamais loggué.

```java
@Data
public class PdfEsignatureRequest {

    @NotNull(message = "Le fichier PDF est obligatoire")
    private MultipartFile file;

    // ── Mode de création de la signature ─────────────────────────────────────

    @NotNull
    private SignatureMode signatureMode;             // DRAW | UPLOAD | TYPE

    /** Modes DRAW et UPLOAD : image PNG/JPG/SVG de la signature. */
    private MultipartFile signatureFile;

    /** Mode TYPE : texte à convertir en signature cursive. */
    @Size(max = 200)
    private String signatureText;

    /** Mode TYPE : police cursive embarquée dans le JAR. */
    private SignatureFont signatureFont = SignatureFont.DANCING_SCRIPT;

    // ── Apparence de la signature ─────────────────────────────────────────────

    @Pattern(regexp = "^#[0-9A-Fa-f]{6}$",
             message = "La couleur doit être au format hexadécimal (#RRGGBB)")
    private String signatureColor = "#1a1a2e";       // Bleu marine (imite l'encre)

    // ── Champs à placer (JSON string) ─────────────────────────────────────────
    // Tableau JSON de SignatureFieldDto sérialisé côté Angular, envoyé en String.

    @NotBlank(message = "Au moins un champ de signature est requis")
    private String fieldsJson;                        // "[{\"page\":1, \"xPct\":...}]"

    // ── Sprint 4 — Certificat numérique (PKCS#12) ─────────────────────────────

    private MultipartFile certificateFile;           // .p12 — Sprint 4 uniquement
    @ToString.Exclude                                 // Jamais loggué
    private String certificatePassword;              // Sprint 4 — TTL Redis 30 min
    private CertificationLevel certificationLevel = CertificationLevel.NOT_CERTIFIED;

    // ── Enums imbriqués ───────────────────────────────────────────────────────

    public enum SignatureMode      { DRAW, UPLOAD, TYPE }
    public enum CertificationLevel { NOT_CERTIFIED, CERTIFIED_NO_CHANGES }

    public enum SignatureFont {
        DANCING_SCRIPT,    // Cursive fluide, équilibrée — défaut
        GREAT_VIBES,       // Élégante, haut de gamme
        PACIFICO,          // Arrondie, moderne
        SATISFY,           // Rapide, naturelle
        ALLURA,            // Fine, précise
        ALEX_BRUSH         // Ferme, formelle
    }
}
```

**Record `SignatureFieldDto` (désérialisé depuis `fieldsJson`) :**

```java
public record SignatureFieldDto(
    int    page,          // 1-based
    double xPct,          // 0.0 – 100.0 (% de la largeur de la page, origine gauche)
    double yPct,          // 0.0 – 100.0 (% de la hauteur de la page, origine haut)
    double widthPct,      // 0.0 – 100.0
    double heightPct,     // 0.0 – 100.0
    String type,          // 'SIGNATURE' | 'INITIALS' | 'DATE' | 'TEXT' (Sprint 4)
    String dateFormat,    // pour type DATE, ex. 'dd/MM/yyyy'
    String label          // optionnel, ex. "Signature du client"
) {}
```

---

### 4.3 Service `PdfEsignatureServiceImpl`

```
submit(request, userEmail):
  1.  Lecture bytes PDF (Tomcat multipart)
  2.  Validation MIME (application/pdf)
  3.  Résolution userId (null si anonyme)
  4.  Validation taille PDF (≤ 10 MB FREE, ≤ 50 MB PRO, ≤ 200 MB ENTERPRISE)
  5.  Validation PDF (non corrompu, ≥ 1 page) → pageCount
  6.  Validation métier :
        - DRAW/UPLOAD → signatureFile obligatoire, MIME image/png|jpeg|svg+xml, ≤ 5 MB
        - TYPE        → signatureText obligatoire (non vide après trim)
        - fieldsJson  → JSON valide, ≥ 1 champ, toutes les pages ≤ pageCount,
                        coordonnées dans [0.0, 100.0]
  7.  Désérialisation et validation de la liste SignatureFieldDto
  8.  checkAndIncrementQuota(userId, PDF_ESIGNATURE)
  9.  Document placeholder → documentRepository.save()
  10. fileStorageService.storeBytes(pdfBytes) → clé source
  11. Si DRAW ou UPLOAD :
        signatureKey = "pdf-esignature/signatures/{jobId}/signature.png"
        fileStorageService.storeBytes(signatureBytes, signatureKey, "image/png")
  12. inputData = sérialisation JSON de toute la config (incluant signatureKey)
  13. ProcessingJob PENDING → processingRepository.save()
  14. afterCommit() → orchestrator.process(jobId, documentId, bytes)
  return PdfEsignatureJobResponse { jobId, documentId, status:"PENDING" }
```

```java
private String buildInputData(PdfEsignatureRequest req, String originalName,
                               String outputName, String sigImageKey,
                               List<SignatureFieldDto> fields) {
    Map<String, Object> data = new LinkedHashMap<>();
    data.put("sourceFileName",    originalName);
    data.put("outputFileName",    outputName);
    data.put("signatureMode",     req.getSignatureMode().name());
    data.put("signatureText",     req.getSignatureText());
    data.put("signatureFont",     req.getSignatureFont() != null
                                  ? req.getSignatureFont().name() : null);
    data.put("signatureColor",    req.getSignatureColor());
    data.put("signatureImageKey", sigImageKey);    // null si TYPE
    data.put("fields",            fields);
    return objectMapper.writeValueAsString(data);
}
```

**Nom de sortie** : `{originalName}_signé.pdf`

---

### 4.4 Stratégie `PdfEsignatureStrategy`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfEsignatureStrategy implements ProcessingStrategy {

    private final FileStorageService            fileStorageService;
    private final PdfEsignatureResultRepository esignatureResultRepository;
    private final ObjectMapper                  objectMapper;

    @Override public JobType getSupportedType() { return JobType.PDF_ESIGNATURE; }
    @Override public boolean needsRawBytes()    { return true; }

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes,
                               Long jobId, Long documentId) {
        long startMs = System.currentTimeMillis();
        log.info("PdfEsignatureStrategy — jobId={}, userId={}", jobId, userId);

        EsignatureOptions opts = parseOptions(inputData);

        // ── Récupération/génération de l'image de signature ───────────────────

        byte[] sigImageBytes = null;

        if (opts.signatureImageKey() != null) {
            try (InputStream is = fileStorageService.retrieve(opts.signatureImageKey())) {
                sigImageBytes = is.readAllBytes();
            } catch (Exception e) {
                throw new RuntimeException("Impossible de récupérer l'image de signature", e);
            }
        }

        if ("TYPE".equals(opts.signatureMode())) {
            try {
                sigImageBytes = generateTypedSignatureImage(
                    opts.signatureText(), opts.signatureFont(), opts.signatureColor()
                );
            } catch (Exception e) {
                throw new RuntimeException("Impossible de générer la signature typée", e);
            }
        }

        // ── Intégration dans le PDF ───────────────────────────────────────────

        byte[] signedBytes;
        int    pagesSigned      = 0;
        int    sourcePagesCount = 0;

        try (PDDocument doc = Loader.loadPDF(rawBytes)) {
            sourcePagesCount = doc.getNumberOfPages();

            PDImageXObject sigImage = (sigImageBytes != null)
                ? PDImageXObject.createFromByteArray(doc, sigImageBytes, "signature")
                : null;

            for (SignatureFieldDto field : opts.fields()) {
                int pageIdx = field.page() - 1;
                if (pageIdx < 0 || pageIdx >= doc.getNumberOfPages()) {
                    log.warn("PdfEsignatureStrategy — champ page={} hors plage ({}p), ignoré",
                            field.page(), doc.getNumberOfPages());
                    continue;
                }

                PDPage      page     = doc.getPage(pageIdx);
                PDRectangle mediaBox = page.getMediaBox();
                float       pw       = mediaBox.getWidth();
                float       ph       = mediaBox.getHeight();

                // Conversion coordonnées % → points PDF (origine bas-gauche)
                float xPt = (float)(field.xPct()      / 100.0 * pw);
                float wPt = (float)(field.widthPct()   / 100.0 * pw);
                float hPt = (float)(field.heightPct()  / 100.0 * ph);
                float yPt = ph - (float)(field.yPct()  / 100.0 * ph) - hPt;

                switch (field.type()) {

                    case "SIGNATURE" -> {
                        if (sigImage != null) {
                            try (PDPageContentStream cs = openAppendStream(doc, page)) {
                                cs.drawImage(sigImage, xPt, yPt, wPt, hPt);
                            }
                            pagesSigned++;
                        }
                    }

                    case "INITIALS" -> {
                        if (sigImage != null) {
                            // Initiales : 40 % de la largeur normale, centré verticalement
                            float iW = wPt * 0.40f;
                            float iH = hPt;
                            try (PDPageContentStream cs = openAppendStream(doc, page)) {
                                cs.drawImage(sigImage, xPt, yPt, iW, iH);
                            }
                            pagesSigned++;
                        }
                    }

                    case "DATE" -> {
                        String fmt   = field.dateFormat() != null ? field.dateFormat() : "dd/MM/yyyy";
                        String label = LocalDate.now()
                                .format(DateTimeFormatter.ofPattern(fmt));
                        drawText(doc, page, label, xPt, yPt + hPt * 0.4f,
                                 opts.signatureColor(), 10f);
                        pagesSigned++;
                    }
                }
            }

            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            doc.save(baos);
            signedBytes = baos.toByteArray();

        } catch (Exception e) {
            log.error("PdfEsignatureStrategy — échec jobId={}: {}", jobId, e.getMessage());
            throw new RuntimeException("Échec de la signature PDF : " + e.getMessage(), e);
        }

        // ── Nettoyage immédiat de l'image de signature temporaire ─────────────

        if (opts.signatureImageKey() != null) {
            try {
                fileStorageService.delete(opts.signatureImageKey());
            } catch (Exception e) {
                log.warn("PdfEsignatureStrategy — impossible de supprimer l'image temp {}: {}",
                        opts.signatureImageKey(), e.getMessage());
            }
        }

        // ── Stockage du PDF signé ─────────────────────────────────────────────

        String outputKey = "pdf-esignature/output/" + jobId + "/" + opts.outputFileName();
        fileStorageService.storeBytes(signedBytes, outputKey, "application/pdf");

        // ── Persistance du résultat ───────────────────────────────────────────

        long processingMs = System.currentTimeMillis() - startMs;
        try {
            esignatureResultRepository.save(PdfEsignatureResult.builder()
                    .jobId(jobId)
                    .userId(userId)
                    .sourceFileName(opts.sourceFileName())
                    .sourceSizeBytes((long) rawBytes.length)
                    .sourcePageCount(sourcePagesCount)
                    .outputKey(outputKey)
                    .outputFileName(opts.outputFileName())
                    .outputSizeBytes((long) signedBytes.length)
                    .signatureMode(opts.signatureMode())
                    .signatureText(opts.signatureText())
                    .signatureFont(opts.signatureFont())
                    .signatureColor(opts.signatureColor())
                    .fieldsJson(objectMapper.writeValueAsString(opts.fields()))
                    .fieldsCount((short) opts.fields().size())
                    .pagesSigned((short) pagesSigned)
                    .isDigitallySigned(false)
                    .processingMs(processingMs)
                    .expiresAt(OffsetDateTime.now().plusHours(24))
                    .build());
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Sérialisation des champs impossible", e);
        }

        log.info("PdfEsignatureStrategy — jobId={} terminé en {}ms ({} pages signées)",
                jobId, processingMs, pagesSigned);

        return outputKey;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private PDPageContentStream openAppendStream(PDDocument doc, PDPage page) throws IOException {
        return new PDPageContentStream(
            doc, page, PDPageContentStream.AppendMode.APPEND, true, true
        );
    }

    /**
     * Génère une image PNG transparent d'une signature cursive via AWT.
     * La police TTF est embarquée dans src/main/resources/fonts/.
     */
    private byte[] generateTypedSignatureImage(String text, String fontName,
                                               String colorHex) throws Exception {
        int W = 600, H = 180;
        BufferedImage img = new BufferedImage(W, H, BufferedImage.TYPE_INT_ARGB);
        Graphics2D    g   = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING,      RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        g.setComposite(AlphaComposite.Clear);
        g.fillRect(0, 0, W, H);
        g.setComposite(AlphaComposite.SrcOver);

        // Charge la police TTF depuis resources/fonts/
        String ttfRes = "/fonts/" + (fontName != null ? fontName : "DANCING_SCRIPT")
                              .toLowerCase().replace('_', '-') + ".ttf";
        Font font;
        try (InputStream is = getClass().getResourceAsStream(ttfRes)) {
            if (is == null) throw new RuntimeException("Police introuvable : " + ttfRes);
            font = Font.createFont(Font.TRUETYPE_FONT, is).deriveFont(72f);
        }
        g.setFont(font);

        int r  = Integer.parseInt(colorHex.substring(1, 3), 16);
        int gv = Integer.parseInt(colorHex.substring(3, 5), 16);
        int b  = Integer.parseInt(colorHex.substring(5, 7), 16);
        g.setColor(new Color(r, gv, b));

        FontMetrics fm = g.getFontMetrics();
        int tw = fm.stringWidth(text);
        // Centrage horizontal + ajustement vertical pour la hauteur de ligne cursive
        g.drawString(text, Math.max(0, (W - tw) / 2), H / 2 + fm.getAscent() / 2 - 10);
        g.dispose();

        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        ImageIO.write(img, "PNG", baos);
        return baos.toByteArray();
    }

    private void drawText(PDDocument doc, PDPage page, String text,
                          float x, float y, String colorHex, float size) throws Exception {
        PDFont  font = new PDType1Font(Standard14Fonts.FontName.HELVETICA);
        float[] rgb  = hexToRgb(colorHex);
        try (PDPageContentStream cs = openAppendStream(doc, page)) {
            cs.beginText();
            cs.setFont(font, size);
            cs.setNonStrokingColor(rgb[0], rgb[1], rgb[2]);
            cs.newLineAtOffset(x, y);
            cs.showText(text);
            cs.endText();
        }
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

    private record EsignatureOptions(
        String sourceFileName, String outputFileName,
        String signatureMode, String signatureText, String signatureFont,
        String signatureColor, String signatureImageKey,
        List<SignatureFieldDto> fields
    ) {}
}
```

---

### 4.5 Polices cursives embarquées (`resources/fonts/`)

Les 6 polices Google Fonts sont embarquées dans le JAR pour la génération des signatures
typées sans dépendance réseau. Toutes sont sous licence **SIL Open Font License 1.1** —
utilisables sans restriction dans un produit commercial.

```
src/main/resources/fonts/
  ├── dancing-script.ttf     ← DancingScript-Regular.ttf  (OFL 1.1)
  ├── great-vibes.ttf        ← GreatVibes-Regular.ttf     (OFL 1.1)
  ├── pacifico.ttf           ← Pacifico-Regular.ttf       (OFL 1.1)
  ├── satisfy.ttf            ← Satisfy-Regular.ttf        (OFL 1.1)
  ├── allura.ttf             ← Allura-Regular.ttf         (OFL 1.1)
  └── alex-brush.ttf         ← AlexBrush-Regular.ttf      (OFL 1.1)
```

Télécharger depuis Google Fonts et placer dans `src/main/resources/fonts/` avant
l'implémentation du Sprint 2.

---

### 4.6 Entité `PdfEsignatureResult`

```java
@Entity
@Table(name = "pdf_esignature_results")
@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class PdfEsignatureResult {

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

    // ── Signature ─────────────────────────────────────────────────────────────

    @Column(name = "signature_mode",     nullable = false) private String  signatureMode;
    @Column(name = "signature_text")                       private String  signatureText;
    @Column(name = "signature_font")                       private String  signatureFont;
    @Column(name = "signature_color",    nullable = false) private String  signatureColor;
    @Column(name = "signature_image_key", columnDefinition = "TEXT")
    private String signatureImageKey;

    // ── Champs ────────────────────────────────────────────────────────────────

    @Column(name = "fields_json",    nullable = false, columnDefinition = "TEXT")
    private String  fieldsJson;
    @Column(name = "fields_count",   nullable = false) private Short   fieldsCount;
    @Column(name = "pages_signed")                     private Short   pagesSigned;

    // ── Sprint 4 — Digital ────────────────────────────────────────────────────

    @Column(name = "is_digitally_signed", nullable = false) private Boolean isDigitallySigned;
    @Column(name = "certification_level")                   private String  certificationLevel;
    @Column(name = "signer_name")                           private String  signerName;
    @Column(name = "signer_email")                          private String  signerEmail;

    // ── Sprint 4 — Workflow ────────────────────────────────────────────────────

    @Column(name = "workflow_id")    private Long  workflowId;
    @Column(name = "signer_order")   private Short signerOrder;
    @Column(name = "workflow_status") private String workflowStatus;

    // ── Métriques & rétention ─────────────────────────────────────────────────

    @Column(name = "processing_ms")  private Long           processingMs;
    @Column(name = "expires_at")     private OffsetDateTime expiresAt;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @PrePersist
    void prePersist() { this.createdAt = OffsetDateTime.now(); }
}
```

---

### 4.7 Repository `PdfEsignatureResultRepository`

```java
public interface PdfEsignatureResultRepository
        extends JpaRepository<PdfEsignatureResult, Long> {

    Optional<PdfEsignatureResult> findByJobId(Long jobId);

    List<PdfEsignatureResult> findByExpiresAtBefore(OffsetDateTime threshold);
}
```

---

### 4.8 DTOs de réponse

```java
// PdfEsignatureJobResponse.java
@Value @Builder
public class PdfEsignatureJobResponse {
    Long   jobId;
    Long   documentId;
    String status;    // "PENDING"
    String message;
}

// PdfEsignatureResultResponse.java
@Value @Builder
public class PdfEsignatureResultResponse {
    Long    jobId;
    String  status;              // PENDING | PROCESSING | COMPLETED | FAILED

    // ── COMPLETED ─────────────────────────────────────────────────────────────
    String  downloadUrl;         // /api/v1/pdf/esignature/{jobId}/download
    String  outputFileName;
    Long    outputSizeBytes;
    Long    processingMs;
    String  expiresAt;           // ISO-8601

    // Métadonnées pour la carte résultat enrichie
    String  signatureMode;       // "DRAW" | "UPLOAD" | "TYPE"
    Integer fieldsCount;
    Integer pagesSigned;
    Integer sourcePageCount;
    Boolean isDigitallySigned;

    // ── FAILED ────────────────────────────────────────────────────────────────
    String  errorMessage;
}
```

---

### 4.9 Controller `PdfEsignatureController`

```java
@RestController
@RequestMapping("/api/v1/pdf/esignature")
@RequiredArgsConstructor
@Tag(name = "PDF E-Signature", description = "Signature électronique de documents PDF")
public class PdfEsignatureController {

    private final PdfEsignatureService pdfEsignatureService;

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Appose une ou plusieurs signatures sur un PDF")
    public PdfEsignatureJobResponse sign(
            @Valid @ModelAttribute PdfEsignatureRequest request,
            @AuthenticationPrincipal UserDetails principal
    ) {
        String email = principal != null ? principal.getUsername() : null;
        return pdfEsignatureService.submit(request, email);
    }

    @GetMapping("/{jobId}/result")
    @Operation(summary = "Statut et résultat du job de signature")
    public ResponseEntity<PdfEsignatureResultResponse> getResult(@PathVariable Long jobId) {
        return ResponseEntity.ok(pdfEsignatureService.getResult(jobId));
    }

    @GetMapping("/{jobId}/download")
    @Operation(summary = "Télécharge le PDF signé")
    public ResponseEntity<byte[]> download(@PathVariable Long jobId) {
        PdfEsignatureService.PdfEsignatureDownload dl =
                pdfEsignatureService.getDownload(jobId);

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

### 4.10 Scheduler `PdfEsignatureCleanupJob`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfEsignatureCleanupJob {

    private final PdfEsignatureResultRepository esignatureResultRepository;
    private final FileStorageService            fileStorageService;

    /**
     * Toutes les heures. initialDelay de 12 min pour éviter la contention avec
     * PdfLockCleanupJob (2 min), PdfUnlockCleanupJob (3 min),
     * PdfWatermarkCleanupJob (6 min) et PdfPageNumberCleanupJob (9 min).
     */
    @Scheduled(fixedDelay = 3_600_000, initialDelay = 720_000)
    @Transactional
    public void cleanupExpiredSignatures() {
        List<PdfEsignatureResult> expired =
                esignatureResultRepository.findByExpiresAtBefore(OffsetDateTime.now());

        if (expired.isEmpty()) {
            log.debug("PdfEsignatureCleanupJob — aucun PDF signé expiré");
            return;
        }

        log.info("PdfEsignatureCleanupJob — {} fichier(s) signé(s) expiré(s)", expired.size());
        int deleted = 0;
        AtomicLong freed = new AtomicLong(0);

        for (PdfEsignatureResult result : expired) {
            try {
                if (result.getOutputKey() != null) {
                    fileStorageService.delete(result.getOutputKey());
                    if (result.getOutputSizeBytes() != null)
                        freed.addAndGet(result.getOutputSizeBytes());
                }
                // Nettoyage image de signature temporaire (précaution — normalement déjà supprimée)
                if (result.getSignatureImageKey() != null) {
                    try { fileStorageService.delete(result.getSignatureImageKey()); }
                    catch (Exception ignored) {}
                }
                esignatureResultRepository.delete(result);
                deleted++;
            } catch (Exception e) {
                log.warn("PdfEsignatureCleanupJob — échec suppression jobId={}: {}",
                        result.getJobId(), e.getMessage());
            }
        }

        log.info("PdfEsignatureCleanupJob — {}/{} fichiers supprimés ({} MB libérés)",
                deleted, expired.size(),
                String.format("%.2f", freed.get() / (1024.0 * 1024.0)));
    }
}
```

---

### 4.11 Intégrations transverses

```java
// ProcessingJob.JobType
SUMMARY, QA, EXTRACTION, GENERATION, OCR,
PDF_LOCK, PDF_UNLOCK, PDF_WATERMARK, PDF_PAGE_NUMBER, PDF_ESIGNATURE

// FeatureType.java
/** Signature électronique PDF (quota en fichiers/jour). */
PDF_ESIGNATURE

// PlanConfig.java — limitFor()
case PDF_ESIGNATURE -> maxConversionsPerDay;  // Partage le quota de conversions

// PdfEsignatureStrategy implémente ProcessingStrategy
@Override public boolean needsRawBytes() { return true; }  // ← Obligatoire
```

---

## 5. Sprint 3 — Frontend

### 5.1 Fichiers à créer

```
kovixel-ui/src/app/
  ├── core/
  │     ├── models/pdf-esignature.model.ts        (interfaces TS)
  │     ├── services/pdf-esignature.service.ts    (submit, getResult, download)
  │     └── services/pdf-render.service.ts        (PDF.js — rendu pages PDF)
  └── features/tools/pdf-esignature/
        ├── pdf-esignature.routes.ts              (lazy-loading)
        ├── pdf-esignature.component.ts           (composant principal, 4 étapes)
        ├── signature-canvas/
        │     └── signature-canvas.component.ts   (canvas dessin touch/souris)
        └── field-placer/
              └── field-placer.component.ts       (placement drag & drop sur PDF.js)
```

---

### 5.2 Route et catalogue

```typescript
// app.routes.ts — APRÈS tools/pdf/page-number, AVANT la route générique tools/:slug
{
  path: 'tools/pdf/esignature',
  canActivate: [softAuthGuard],
  loadChildren: () =>
    import('./features/tools/pdf-esignature/pdf-esignature.routes')
      .then(m => m.PDF_ESIGNATURE_ROUTES),
  data: { title: 'Signer un PDF', guestFeature: 'pdf-esignature' },
},

// tools-config.ts — entrée catalogue
// Icône recommandée : PenTool (lucide-angular)
{
  slug:            'pdf/esignature',
  name:            'Signer un PDF',
  description:     'Apposez votre signature manuscrite, vos initiales et la date — dessin, upload ou frappe, placement libre sur vos pages',
  longDescription: '…',
  category:        'security',
  icon:            PenTool,
  badge:           'NEW',
  estimatedTime:   '~3 secondes',
  isPro:           false,
  isAvailable:     true,
  backendEndpoint: '/api/v1/pdf/esignature',
  keywords: [
    'signature', 'signer', 'électronique', 'esignature', 'esign', 'contrat',
    'paraphe', 'initiales', 'date', 'tampon', 'valider', 'approuver',
    'signataire', 'document', 'cursive', 'cachet', 'certifier',
  ],
},
```

---

### 5.3 UX — Structure de la page

4 étapes : `upload → créer signature → placer → résultat`

```
┌────────────────────────────────────────────────────────────────────┐
│  ✍  Signer un PDF                                                  │
│  Dessinez, importez ou tapez votre signature — placement libre     │
└────────────────────────────────────────────────────────────────────┘

[1] Fichier ── [2] Créer signature ── [3] Placer sur le PDF ── [4] Résultat

══════════════════════════════ ÉTAPE 2 ═══════════════════════════════
┌────────────────────────────────────────────────────────────────────┐
│  Comment souhaitez-vous créer votre signature ?                    │
│                                                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            │
│  │  ✍ Dessiner  │  │  ⬆ Importer  │  │  T  Taper    │            │
│  │  (actif)     │  │              │  │              │            │
│  └──────────────┘  └──────────────┘  └──────────────┘            │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  Signez ici avec votre souris, stylet ou doigt               │ │
│  │                                                              │ │
│  │                                                              │ │
│  │                    ~~~~~~~~~~~~                              │ │
│  │                                                              │ │
│  │  [Effacer]  [Annuler]                                        │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  Couleur  [■ Bleu marine ▼]                                        │
│           [■ Noir]  [■ Bleu royal]  [■ Rouge]  [# Personnalisé]   │
│                                                                    │
│                               [ Suivant → ]                        │
└────────────────────────────────────────────────────────────────────┘

══════════════════════════════ ÉTAPE 3 ═══════════════════════════════
┌─────────────────────────────────────────────────────────────────────┐
│  Placez vos champs sur le document                                  │
│                                                                     │
│  Ajouter :  [ ✍ Signature ]  [ P Initiales ]  [ 📅 Date ]         │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  Page 2 / 5  [← Préc.]  [Suiv. →]   Zoom [−] 100% [+]       │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐ │ │
│  │  │  (Rendu réel de la page PDF via PDF.js)                │ │ │
│  │  │                                                         │ │ │
│  │  │  Le Client soussigné reconnaît avoir pris               │ │ │
│  │  │  connaissance des conditions générales de vente.        │ │ │
│  │  │                                                         │ │ │
│  │  │  Signature : ___________________________   21/06/2026   │ │ │
│  │  │  ┌─────────────────────────────┐                        │ │ │
│  │  │  │ ✍ Signature du client      │ ✕                       │ │ │
│  │  │  │ (glisser pour déplacer)    │ ↔                       │ │ │
│  │  │  └─────────────────────────────┘                        │ │ │
│  │  │                                                         │ │ │
│  │  └─────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  [ ← Retour ]                      [ ✍ Signer le document → ]      │
└─────────────────────────────────────────────────────────────────────┘
```

---

### 5.4 Composant `SignatureCanvasComponent` — Dessin tactile/souris

```typescript
@Component({
  selector: 'app-signature-canvas',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="sig-wrapper">
      <canvas #sigCanvas
        width="600" height="200"
        (pointerdown)="onDown($event)"
        (pointermove)="onMove($event)"
        (pointerup)="onUp($event)"
        (pointerleave)="onUp($event)"
        style="touch-action: none; cursor: crosshair; border: 1px solid #e0e0e0; border-radius: 8px;">
      </canvas>
      <div class="sig-controls">
        <button type="button" (click)="undo()">Annuler</button>
        <button type="button" (click)="clear()">Effacer</button>
      </div>
      <p class="sig-hint">Signez ci-dessus avec votre souris, stylet ou doigt</p>
    </div>
  `,
})
export class SignatureCanvasComponent implements AfterViewInit {

  @Input()  color = '#1a1a2e';
  @Output() signatureChange = new EventEmitter<Blob | null>();

  private readonly canvas = viewChild.required<ElementRef<HTMLCanvasElement>>('sigCanvas');
  private ctx!: CanvasRenderingContext2D;
  private isDrawing = false;
  private lastX = 0;
  private lastY = 0;
  private history: ImageData[] = [];
  private isEmpty = true;

  ngAfterViewInit(): void {
    this.ctx = this.canvas().nativeElement.getContext('2d')!;
    this.ctx.lineCap  = 'round';
    this.ctx.lineJoin = 'round';
    this._clear();
  }

  onDown(e: PointerEvent): void {
    e.preventDefault();
    this.isDrawing = true;
    const { x, y } = this._coords(e);
    this.lastX = x;
    this.lastY = y;
    this.history.push(this.ctx.getImageData(0, 0, 600, 200));
    if (this.history.length > 30) this.history.shift();  // cap mémoire
    this.ctx.beginPath();
    this.ctx.moveTo(x, y);
  }

  onMove(e: PointerEvent): void {
    if (!this.isDrawing) return;
    e.preventDefault();
    const { x, y } = this._coords(e);
    // Lissage quadratique — donne une courbe fluide, naturelle
    const mx = (x + this.lastX) / 2;
    const my = (y + this.lastY) / 2;
    this.ctx.strokeStyle = this.color;
    this.ctx.lineWidth   = 2.5;
    this.ctx.quadraticCurveTo(this.lastX, this.lastY, mx, my);
    this.ctx.stroke();
    this.lastX = x;
    this.lastY = y;
    this.isEmpty = false;
  }

  onUp(e: PointerEvent): void {
    if (!this.isDrawing) return;
    this.isDrawing = false;
    this.ctx.closePath();
    this._emit();
  }

  undo(): void {
    if (this.history.length === 0) return;
    this.ctx.putImageData(this.history.pop()!, 0, 0);
    // Vérifier si on revient à la page blanche
    if (this.history.length === 0) {
      this.isEmpty = true;
      this.signatureChange.emit(null);
    } else {
      this._emit();
    }
  }

  clear(): void {
    this._clear();
    this.history = [];
    this.isEmpty = true;
    this.signatureChange.emit(null);
  }

  private _clear(): void {
    this.ctx.fillStyle = '#ffffff';
    this.ctx.fillRect(0, 0, 600, 200);
  }

  private _coords(e: PointerEvent): { x: number; y: number } {
    const rect = this.canvas().nativeElement.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left) * (600 / rect.width),
      y: (e.clientY - rect.top)  * (200 / rect.height),
    };
  }

  private _emit(): void {
    if (this.isEmpty) { this.signatureChange.emit(null); return; }
    this.canvas().nativeElement.toBlob(
      blob => this.signatureChange.emit(blob),
      'image/png'
    );
  }
}
```

**Points clés :**
- `pointerdown/pointermove/pointerup` avec `touch-action: none` → compatibilité
  universelle : souris, écran tactile, stylet (Surface Pen, Apple Pencil via navigateur)
- Lissage quadratique `quadraticCurveTo` pour une trace fluide et naturelle
- Pile `history: ImageData[]` plafonnée à 30 snapshots pour `undo()`
- Fond blanc explicite — l'aperçu upload montre le PNG tel quel (pas de fond transparent)
- Émission d'un `Blob PNG` vers le composant parent à chaque fin de trait

---

### 5.5 Service `PdfRenderService` — Rendu des pages via PDF.js

```typescript
import * as pdfjsLib from 'pdfjs-dist';
import type { PDFDocumentProxy } from 'pdfjs-dist';

@Injectable({ providedIn: 'root' })
export class PdfRenderService {

  private pdfDoc: PDFDocumentProxy | null = null;

  async loadPdf(file: File): Promise<number> {
    this.destroy();
    const arrayBuffer = await file.arrayBuffer();
    this.pdfDoc = await pdfjsLib.getDocument({
      data: new Uint8Array(arrayBuffer),
      cMapUrl:   'assets/cmaps/',
      cMapPacked: true,
    }).promise;
    return this.pdfDoc.numPages;
  }

  async renderPage(pageNum: number, canvas: HTMLCanvasElement,
                   scale = 1.5): Promise<void> {
    if (!this.pdfDoc) throw new Error('PDF non chargé');
    const page     = await this.pdfDoc.getPage(pageNum);
    const viewport = page.getViewport({ scale });
    canvas.width   = viewport.width;
    canvas.height  = viewport.height;
    await page.render({
      canvasContext: canvas.getContext('2d')!,
      viewport,
    }).promise;
  }

  async getPageCount(): Promise<number> {
    return this.pdfDoc?.numPages ?? 0;
  }

  destroy(): void {
    this.pdfDoc?.destroy();
    this.pdfDoc = null;
  }
}
```

**Configuration `angular.json` :**

```json
"assets": [
  "public",
  {
    "glob": "**/*",
    "input": "node_modules/pdfjs-dist/cmaps/",
    "output": "assets/cmaps/"
  },
  {
    "glob": "pdf.worker.min.mjs",
    "input": "node_modules/pdfjs-dist/build/",
    "output": "assets/"
  }
]
```

```typescript
// main.ts ou app.config.ts
import * as pdfjsLib from 'pdfjs-dist';
pdfjsLib.GlobalWorkerOptions.workerSrc = 'assets/pdf.worker.min.mjs';
```

---

### 5.6 Composant `FieldPlacerComponent` — Placement interactif sur PDF

```typescript
export interface FieldOverlay {
  id:        string;              // UUID local (crypto.randomUUID())
  type:      'SIGNATURE' | 'INITIALS' | 'DATE';
  page:      number;              // 1-based
  xPct:      number;              // % largeur canvas (= % largeur PDF)
  yPct:      number;              // % hauteur canvas, origine haut
  widthPct:  number;
  heightPct: number;
  label:     string;
}

@Component({
  selector: 'app-field-placer',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [CdkDrag],
  template: `
    <div class="placer-toolbar">
      <button (click)="addField('SIGNATURE')">✍ Signature</button>
      <button (click)="addField('INITIALS')">P Initiales</button>
      <button (click)="addField('DATE')">📅 Date</button>
    </div>

    <div class="page-nav">
      <button [disabled]="currentPage() === 1"
              (click)="goPage(currentPage() - 1)">← Préc.</button>
      <span>Page {{ currentPage() }} / {{ totalPages() }}</span>
      <button [disabled]="currentPage() === totalPages()"
              (click)="goPage(currentPage() + 1)">Suiv. →</button>
    </div>

    <div class="canvas-container" #container>
      <canvas #pdfCanvas></canvas>

      @for (f of pageFields(); track f.id) {
        <div class="field-overlay"
             [class.field-signature]="f.type === 'SIGNATURE'"
             [class.field-initials]="f.type === 'INITIALS'"
             [class.field-date]="f.type === 'DATE'"
             [style.left.%]="f.xPct"
             [style.top.%]="f.yPct"
             [style.width.%]="f.widthPct"
             [style.height.%]="f.heightPct"
             cdkDrag (cdkDragEnded)="onDragEnd($event, f)">
          <span class="field-label">{{ f.label }}</span>
          <button class="field-remove" (click)="removeField(f.id)">✕</button>
          <div class="field-resize" (mousedown)="onResizeStart($event, f)">↔</div>
        </div>
      }
    </div>
  `,
})
export class FieldPlacerComponent {

  readonly totalPages        = input.required<number>();   // signal input Angular 17+
  readonly signaturePreviewUrl = input<string | null>(null);
  readonly fieldsChange = output<FieldOverlay[]>();

  readonly currentPage = signal(1);
  readonly fields      = signal<FieldOverlay[]>([]);

  readonly pageFields = computed(() =>
    this.fields().filter(f => f.page === this.currentPage())
  );

  private readonly pdfRender  = inject(PdfRenderService);
  private readonly pdfCanvas  = viewChild.required<ElementRef<HTMLCanvasElement>>('pdfCanvas');
  private readonly container  = viewChild.required<ElementRef<HTMLDivElement>>('container');

  goPage(n: number): void {
    this.currentPage.set(n);
    this.pdfRender.renderPage(n, this.pdfCanvas().nativeElement, 1.5);
  }

  addField(type: FieldOverlay['type']): void {
    const label = type === 'DATE'     ? 'Date'      :
                  type === 'INITIALS' ? 'Initiales' : 'Signature';
    const field: FieldOverlay = {
      id: crypto.randomUUID(), type,
      page: this.currentPage(),
      xPct: 10, yPct: 70, widthPct: 28, heightPct: 9,
      label,
    };
    this.fields.update(f => [...f, field]);
    this._emit();
  }

  removeField(id: string): void {
    this.fields.update(f => f.filter(x => x.id !== id));
    this._emit();
  }

  onDragEnd(event: CdkDragEnd, field: FieldOverlay): void {
    const el   = event.source.element.nativeElement;
    const cont = this.container().nativeElement;
    const rect = el.getBoundingClientRect();
    const cRect = cont.getBoundingClientRect();
    const newXPct = ((rect.left - cRect.left) / cRect.width)  * 100;
    const newYPct = ((rect.top  - cRect.top)  / cRect.height) * 100;
    this.fields.update(f => f.map(x =>
      x.id === field.id
        ? { ...x, xPct: Math.max(0, Math.min(100 - x.widthPct,  newXPct)),
                  yPct: Math.max(0, Math.min(100 - x.heightPct, newYPct)) }
        : x
    ));
    this._emit();
  }

  onResizeStart(e: MouseEvent, field: FieldOverlay): void {
    // Implémentation du redimensionnement par mousedown/mousemove
    // Plafonnement : widthPct ∈ [10, 60], heightPct ∈ [4, 25]
  }

  private _emit(): void {
    this.fieldsChange.emit(this.fields());    // output() : même API que EventEmitter
  }
}
```

> **Note CDK :** `cdkDrag` de `@angular/cdk/drag-drop` est recommandé pour un drag
> fluide sans friction. Ajouter `DragDropModule` aux imports si non déjà disponible.
> Le resizing manuel par `mousedown/mousemove` est plus simple que `cdkResizable`
> (non disponible dans CDK). Limiter `widthPct` à [10, 60] et `heightPct` à [4, 25].

---

### 5.7 Modèle TypeScript

```typescript
// pdf-esignature.model.ts

export type SignatureMode = 'DRAW' | 'UPLOAD' | 'TYPE';
export type FieldType     = 'SIGNATURE' | 'INITIALS' | 'DATE' | 'TEXT';

export type SignatureFont =
  | 'DANCING_SCRIPT' | 'GREAT_VIBES' | 'PACIFICO'
  | 'SATISFY' | 'ALLURA' | 'ALEX_BRUSH';

export interface SignatureField {
  page:        number;
  xPct:        number;
  yPct:        number;
  widthPct:    number;
  heightPct:   number;
  type:        FieldType;
  dateFormat?: string;
  label?:      string;
}

export interface PdfEsignatureJobResponse {
  jobId:      number;
  documentId: number;
  status:     string;
  message:    string;
}

export interface PdfEsignatureResultResponse {
  jobId:   number;
  status:  string;   // PENDING | PROCESSING | COMPLETED | FAILED

  // COMPLETED
  downloadUrl?:      string;
  outputFileName?:   string;
  outputSizeBytes?:  number;
  processingMs?:     number;
  expiresAt?:        string;

  signatureMode?:     SignatureMode;
  fieldsCount?:       number;
  pagesSigned?:       number;
  sourcePageCount?:   number;
  isDigitallySigned?: boolean;

  // FAILED
  errorMessage?: string;
}

export const SIGNATURE_FONT_LABELS: Record<SignatureFont, string> = {
  DANCING_SCRIPT: 'Dancing Script',
  GREAT_VIBES:    'Great Vibes',
  PACIFICO:       'Pacifico',
  SATISFY:        'Satisfy',
  ALLURA:         'Allura',
  ALEX_BRUSH:     'Alex Brush',
};

export const SIGNATURE_COLOR_PRESETS = [
  { label: 'Bleu marine', hex: '#1a1a2e' },   // Défaut — imite l'encre bleue
  { label: 'Noir',        hex: '#000000' },
  { label: 'Bleu royal',  hex: '#0033cc' },
  { label: 'Rouge',       hex: '#cc0000' },
] as const;
```

---

### 5.8 Service Angular

```typescript
export interface EsignatureSubmitParams {
  file:           File;
  signatureMode:  SignatureMode;
  signatureFile?: Blob | File;      // DRAW (Blob PNG) | UPLOAD (File image)
  signatureText?: string;           // TYPE
  signatureFont?: SignatureFont;    // TYPE
  signatureColor: string;
  fields:         SignatureField[];
}

@Injectable({ providedIn: 'root' })
export class PdfEsignatureService {
  private readonly http = inject(HttpClient);
  private readonly base = `${environment.apiUrl}/v1/pdf/esignature`;

  submit(params: EsignatureSubmitParams): Observable<PdfEsignatureJobResponse> {
    const fd = new FormData();
    fd.append('file',           params.file, params.file.name);
    fd.append('signatureMode',  params.signatureMode);
    fd.append('signatureColor', params.signatureColor);
    fd.append('fieldsJson',     JSON.stringify(params.fields));

    if (params.signatureFile) {
      const name = params.signatureFile instanceof File
        ? params.signatureFile.name : 'signature.png';
      fd.append('signatureFile', params.signatureFile, name);
    }
    if (params.signatureText) fd.append('signatureText', params.signatureText);
    if (params.signatureFont) fd.append('signatureFont', params.signatureFont);

    return this.http.post<PdfEsignatureJobResponse>(this.base, fd);
  }

  getResult(jobId: number): Observable<PdfEsignatureResultResponse> {
    return this.http.get<PdfEsignatureResultResponse>(`${this.base}/${jobId}/result`);
  }

  downloadSigned(jobId: number): Observable<Blob> {
    return this.http.get(`${this.base}/${jobId}/download`, { responseType: 'blob' });
  }
}
```

---

### 5.9 Carte résultat enrichie

```
╔══════════════════════════════════════════════════════════════════════╗
║  ✅  Document signé avec succès                                      ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  # Récapitulatif                                                     ║
║     Mode de signature  : Dessiné à la main                          ║
║     Champs apposés     : 3 (1 signature, 1 paraphe, 1 date)         ║
║     Pages concernées   : 2 et 4 (sur 5)                             ║
║     Signature légale   : Visuelle (non certifiée)                   ║
║     Couleur            : Bleu marine (#1a1a2e)                       ║
║                                                                      ║
║  📄 5 pages   📦 312 Ko   ⚡ 1.4 s                                  ║
║                                                                      ║
║  [  ⬇ Télécharger contrat_signé.pdf  ]                              ║
║  [  🔄 Signer un nouveau document  ]                                 ║
║                                                                      ║
║  ⏳ Supprimé de nos serveurs dans 24 heures.                        ║
║  🔒 Votre image de signature a été supprimée immédiatement          ║
║     après traitement et n'est jamais stockée.                        ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## 6. Sprint 4 — Signature cryptographique, multi-signataires & audit

### 6.1 Signature numérique PDF (PKCS#12 / PAdES)

La signature cryptographique crée une empreinte vérifiable dans le PDF, reconnue
légalement (eIDAS en Europe, ESIGN Act aux États-Unis). Elle prouve que le document
n'a pas été modifié depuis la signature.

**Stack technique :**
- **PDFBox `PDSignature` + BouncyCastle** pour les signatures PAdES-B/LTA
- Certificat PKCS#12 (`.p12` / `.pfx`) fourni par l'utilisateur (PRO) ou
  auto-généré par Kovixel (ENTERPRISE, autorité de certification interne)
- Le fichier `.p12` transite par Redis avec un TTL de **30 min** — c'est la seule
  exception Redis de cet outil

```java
// PdfEsignatureStrategy.processBytes() — extension Sprint 4

if (opts.isDigitallySigned() && opts.certificateRedisKey() != null) {
    // Récupération sécurisée du PKCS#12 depuis Redis
    byte[] pkcs12 = redisTemplate.opsForValue()
            .get("pdf:esignature:cert:" + opts.certificateRedisKey());
    redisTemplate.delete("pdf:esignature:cert:" + opts.certificateRedisKey()); // Immédiat

    KeyStore ks = KeyStore.getInstance("PKCS12");
    ks.load(new ByteArrayInputStream(pkcs12),
            opts.certificatePassword().toCharArray());

    String   alias     = ks.aliases().nextElement();
    PrivateKey key     = (PrivateKey) ks.getKey(alias, opts.certificatePassword().toCharArray());
    Certificate[] chain = ks.getCertificateChain(alias);

    // Signer avec PDFBox SignatureInterface + BouncyCastle CMS
    PDSignature signature = new PDSignature();
    signature.setFilter(PDSignature.FILTER_ADOBE_PPKLITE);
    signature.setSubFilter(PDSignature.SUBFILTER_ADBE_PKCS7_DETACHED);
    signature.setName(opts.signerName());
    signature.setSignDate(Calendar.getInstance());
    doc.addSignature(signature, signerImpl);
}
```

**Niveaux de certification :**

| Niveau | Comportement Adobe Acrobat |
|--------|---------------------------|
| `NOT_CERTIFIED` | Signature apposée — modifications ultérieures autorisées |
| `CERTIFIED_NO_CHANGES` | Certifié — toute modification invalide la signature |

---

### 6.2 Workflow multi-signataires (Sprint 4)

Un document peut nécessiter des signatures successives (ex. client → commercial → direction).

**Migrations Sprint 4 :**

```sql
-- V47 (Sprint 4) : workflow multi-signataires
CREATE TABLE pdf_sign_workflows (
    id           BIGSERIAL   PRIMARY KEY,
    creator_id   BIGINT      NOT NULL,
    document_key TEXT        NOT NULL,   -- Clé MinIO du PDF source partagé
    status       VARCHAR(20) NOT NULL DEFAULT 'PENDING',
                                         -- 'PENDING'|'IN_PROGRESS'|'COMPLETED'|'EXPIRED'
    expires_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE pdf_sign_workflow_steps (
    id               BIGSERIAL    PRIMARY KEY,
    workflow_id      BIGINT       NOT NULL REFERENCES pdf_sign_workflows(id),
    step_order       SMALLINT     NOT NULL,
    signer_email     VARCHAR(320) NOT NULL,
    signer_name      VARCHAR(200),
    status           VARCHAR(20)  NOT NULL DEFAULT 'PENDING',
                                           -- 'PENDING'|'SIGNED'|'DECLINED'
    signed_at        TIMESTAMPTZ,
    job_id           BIGINT       REFERENCES processing_jobs(id),
    access_token     VARCHAR(128) UNIQUE,  -- Token envoyé par email, expire dans 7j
    token_expires_at TIMESTAMPTZ
);
```

**Flux multi-signataires :**

```
1. Créateur upload le PDF, place les champs de chaque signataire,
   saisit les adresses email dans l'ordre
2. Kovixel envoie un email à Signataire 1 avec un lien unique
   (https://kovixel.com/sign/{token})
3. Signataire 1 ouvre la page, voit les champs qui lui sont assignés,
   signe, valide
4. Kovixel envoie automatiquement l'email à Signataire 2, etc.
5. À la dernière signature : PDF final assemblé et disponible au créateur
6. Audit trail PDF généré et joint au document final
```

---

### 6.3 Audit trail PDF téléchargeable (Sprint 4)

Chaque signature produit une page d'audit trail jointe au PDF signé, téléchargeable
séparément ou annexée au document :

```
══════════════════════════════════════════════════════════════════════
                     PISTE D'AUDIT — Kovixel
══════════════════════════════════════════════════════════════════════

Document  : contrat_client.pdf
SHA-256   : 3f9a8b1c2d4e5f6a7b8c9d0e1f2a3b4c…
Créé le   : 21/06/2026 14:32:00 UTC par jean.dupont@acme.com

─────────────────────────────────────────────────────────────────────

Signature #1
  Signataire  : Jean Dupont <jean.dupont@acme.com>
  Date/Heure  : 21/06/2026 14:35:22 UTC
  IP          : 92.168.xxx.xxx (France)
  Navigateur  : Chrome 126 / macOS 14
  Méthode     : Dessin manuel (DRAW)
  Champs      : Signature page 3 (12.5 % × 78.3 %), Date page 3

Signature #2
  Signataire  : Marie Martin <m.martin@acme.com>
  Date/Heure  : 22/06/2026 09:12:07 UTC
  Méthode     : Frappe (TYPE — Great Vibes)
  Champs      : Signature page 5, Initiales page 2

─────────────────────────────────────────────────────────────────────

SHA-256 document final : 7e3c1f2a…
Statut        : COMPLÉTÉ — 2/2 signatures apposées
══════════════════════════════════════════════════════════════════════
```

---

### 6.4 QR Code de vérification (Sprint 4)

Un QR code est ajouté en bas de la dernière page du PDF signé, pointant vers
une page publique Kovixel qui affiche les métadonnées de signature sans révéler
le document :

```java
// Génération du QR code avec ZXing (déjà dans les dépendances Kovixel)
BitMatrix bitMatrix = new QRCodeWriter()
    .encode("https://kovixel.com/verify/" + jobId,
            BarcodeFormat.QR_CODE, 80, 80);
BufferedImage qrImage = MatrixToImageWriter.toBufferedImage(bitMatrix);
```

La page `/verify/{jobId}` affiche : signataire(s), date, méthode, hash du document.
Elle ne révèle **jamais** le contenu du PDF.

---

### 6.5 Cas limites à couvrir

| Cas | Comportement attendu |
|-----|---------------------|
| PDF chiffré (protégé) | 422 « Ce PDF est protégé — déverrouillez-le d'abord » |
| Fichier non-PDF | 415 (validation MIME) |
| PDF corrompu | 400 « Fichier PDF invalide ou corrompu » |
| `signatureFile` absente (DRAW/UPLOAD) | 400 « Image de signature requise pour ce mode » |
| `signatureText` vide (TYPE) | 400 « Veuillez saisir un texte de signature » |
| `fieldsJson` invalide ou vide | 400 « Au moins un champ de signature est requis » |
| Page hors plage (ex. page 5 sur 3 pages) | 422 « Le champ dépasse le nombre de pages (3) » |
| `signatureFile` > 5 MB | 413 « L'image de signature ne doit pas dépasser 5 MB » |
| MIME signature invalide | 415 « Formats acceptés : PNG, JPG, SVG » |
| PDF > limite plan | 413 avec rappel de la limite |
| Canvas vide (DRAW sans trait) | Validation frontend : « Veuillez dessiner votre signature » |
| Double-soumission (clic rapide) | Debounce 800 ms frontend + bouton désactivé après soumission |
| Champ SIGNATURE sans image générée | Loggé WARN, champ ignoré silencieusement |
| Coordonnées hors [0, 100] % | Clampées en service avant traitement |

---

### 6.6 Tests de compatibilité — PDF signé

**Vérifier que la signature s'affiche correctement dans :**
- [ ] Adobe Acrobat Reader (Windows & macOS)
- [ ] Aperçu (macOS)
- [ ] Evince / Okular (Linux)
- [ ] Firefox PDF viewer
- [ ] Chrome PDF viewer
- [ ] PDF Expert (iOS)

**Vérifier les modes de signature :**
- [ ] DRAW : canvas vide → erreur ; canvas signé → PNG transparent intégré
- [ ] UPLOAD : PNG transparent → fond transparent conservé dans le PDF
- [ ] UPLOAD : JPG (fond blanc) → fond blanc visible (comportement attendu, non un bug)
- [ ] TYPE : 6 polices cursives → vérifier le rendu AWT pour chaque police

**Vérifier les types de champs :**
- [ ] SIGNATURE (taille normale) + INITIALS (40 % plus petit)
- [ ] DATE : formats `dd/MM/yyyy`, `MM/dd/yyyy`, `yyyy-MM-dd`

**Vérifier le placement :**
- [ ] Coordonnées extrêmes (champ en coin haut-gauche / bas-droit) → pas de dépassement
- [ ] Champs sur plusieurs pages → chaque page reçoit exactement ses champs
- [ ] Redimensionnement (champ très petit, champ très grand)
- [ ] PDF en mode paysage (largeur > hauteur) → coordonnées correctes

**Vérifier le nettoyage :**
- [ ] Après COMPLETED : la clé MinIO `pdf-esignature/signatures/{jobId}/signature.png`
  est absente (supprimée par le worker)

---

## 7. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Taille max image signature | 5 MB | 5 MB | 5 MB |
| Jobs par jour | 10 (quota conversions) | 200 | Illimité |
| Rétention du PDF signé | 24 h | 7 jours | 30 jours |
| Mode DRAW (dessin) | ✅ | ✅ | ✅ |
| Mode UPLOAD (image) | ✅ | ✅ | ✅ |
| Mode TYPE (frappe cursive) | ✅ | ✅ | ✅ |
| Champ Signature | ✅ | ✅ | ✅ |
| Champ Initiales | ✅ | ✅ | ✅ |
| Champ Date automatique | ✅ | ✅ | ✅ |
| Champ Texte libre | ❌ | ✅ (Sprint 4) | ✅ |
| Champ Case à cocher | ❌ | ✅ (Sprint 4) | ✅ |
| Signature cryptographique (PAdES) | ❌ | ✅ (Sprint 4) | ✅ |
| Multi-signataires (workflow email) | ❌ | ✅ (Sprint 4) | ✅ |
| Audit trail téléchargeable (PDF) | ❌ | ✅ (Sprint 4) | ✅ |
| QR code de vérification | ❌ | ✅ (Sprint 4) | ✅ |
| Certificat PKCS#12 personnel | ❌ | ✅ (Sprint 4) | ✅ |
| Certificat Kovixel auto-généré | ❌ | ❌ | ✅ (Sprint 4) |
| API directe | ❌ | ✅ | ✅ |

> Le quota `PDF_ESIGNATURE` partage `maxConversionsPerDay` dans `PlanConfig.limitFor()`.

---

## 8. Référence — Modes, champs et coordonnées

### 8.1 Modes de création de signature

| Mode | Description | Rendu backend |
|------|-------------|---------------|
| `DRAW` | Dessin sur canvas tactile/souris | PNG reçu comme multipart, intégré tel quel |
| `UPLOAD` | Upload PNG/JPG/SVG par l'utilisateur | SVG converti en PNG si nécessaire ; JPG/PNG intégrés directement |
| `TYPE` | Texte → police cursive TTF embarquée | Rendu AWT `BufferedImage` transparent, PNG généré en backend |

> **Transparence :** les modes DRAW et TYPE produisent des PNG avec fond blanc
> (canvas DRAW) ou transparent (AWT TYPE). Préférer DRAW pour un résultat naturel
> sur des fonds colorés — TYPE avec fond transparent est idéal.

---

### 8.2 Types de champs disponibles

| Type | Sprint | Rendu PDF |
|------|--------|-----------|
| `SIGNATURE` | 2-3 | Image de signature à la taille du champ |
| `INITIALS` | 2-3 | Image de signature à 40 % de la taille — paraphe compact |
| `DATE` | 2-3 | Texte Helvetica 10 pt, date du traitement au format configuré |
| `TEXT` | 4 | Texte libre saisi par l'utilisateur, Helvetica 10 pt |
| `CHECKBOX` | 4 | Symbole ✓ (coche) rendu en Zapf Dingbats |

---

### 8.3 Système de coordonnées — Angular ↔ PDFBox

```
Angular (canvas PDF.js, origine haut-gauche, en pixels) :
  xPx = xPct / 100 × canvasWidth
  yPx = yPct / 100 × canvasHeight       ← depuis le haut

PDFBox (origine bas-gauche, en points PDF) :
  xPt   = xPct      / 100 × pageWidthPt
  wPt   = widthPct  / 100 × pageWidthPt
  hPt   = heightPct / 100 × pageHeightPt
  yPt   = pageHeightPt - (yPct / 100 × pageHeightPt) - hPt    ← Y inversé
```

> **Règle :** les coordonnées sont TOUJOURS transmises en **pourcentage** (0–100 %)
> pour être indépendantes de la résolution d'écran et de la taille réelle du PDF.
> La conversion en points PDF n'a lieu qu'une seule fois, dans `PdfEsignatureStrategy`.

---

### 8.4 Polices cursives (mode TYPE)

| Clé `SignatureFont` | Apparence | Cas d'usage |
|---------------------|-----------|-------------|
| `DANCING_SCRIPT` | Cursive fluide, équilibrée ← **défaut** | Usage général |
| `GREAT_VIBES` | Élégante, fins pleins et déliés | Contrats formels, luxe |
| `PACIFICO` | Arrondie, moderne | Signatures décontractées, bons |
| `SATISFY` | Rapide, naturelle | Devis, commandes |
| `ALLURA` | Fine, précise, verticale | Correspondance formelle |
| `ALEX_BRUSH` | Ferme, masculine | Documents juridiques, actes |

---

### 8.5 Couleurs de signature recommandées

| Couleur | Hex | Usage |
|---------|-----|-------|
| Bleu marine ← **défaut** | `#1a1a2e` | Standard professionnel — imite l'encre bleue |
| Noir | `#000000` | Contrats officiels, documents légaux |
| Bleu royal | `#0033cc` | Légèrement plus vif, très visible sur blanc |
| Rouge | `#cc0000` | Tampon de validation, mention « Approuvé » |

> **Remarque UX :** proposer un sélecteur de couleur libre (`<input type="color">`)
> après les 4 presets, avec validation `@Pattern` `#RRGGBB` côté backend.

---

## Ordre d'implémentation

```
Sprint 1  →  Sprint 2         →  Sprint 3                →  Sprint 4
Migrations   Backend              Frontend                    Cryptographique
(V45, V46)  (strategy AWT,       (canvas draw,               (PKCS#12, PAdES,
             fonts TTF,           PDF.js preview,             multi-signataires
             service,             placement drag&drop,        workflow email,
             controller,          3 modes signature,          audit trail PDF,
             cleanup)             champs SIGNATURE/           QR code /verify,
                                  INITIALS/DATE,              champs TEXT/CHECKBOX)
                                  carte résultat)
```

---

## Pont vers les outils PDF futurs

L'outil E-Signature introduit deux patterns nouveaux réutilisables dans les sprints
suivants :

1. **PDF.js preview** : rendu des vraies pages PDF dans Angular — sera réutilisé
   dans **Remplir un formulaire PDF** (AcroForm), **Extraire pages** (sélection
   visuelle), **Rogner PDF** (marquage de zones), etc.
2. **Génération AWT d'image** : technique `BufferedImage` + police TTF embarquée —
   réutilisable pour **Tampon/Cachet PDF**, **QR Code PDF**, watermark image avancé.

| Outil | Prochaine migration | Spécificité |
|-------|---------------------|-------------|
| **PDF Compress** | V49, V50 | Ghostscript / PDFBox optimizer, ratio de compression |
| **PDF Merge** | V51, V52 | Plusieurs `MultipartFile` → un seul PDF, ordonnancement drag |
| **PDF Split** | V53, V54 | Un PDF → N fichiers, ZIP de sortie, sélection visuelle |
| **PDF Rotate** | V55, V56 | Simple, peut rester sync si < 1s sur petits docs |
| **PDF → Images** | V57, V58 | `PDFRenderer` → ZIP d'images PNG/JPG par page |
| **Remplir PDF** | V59, V60 | PDF.js + champs AcroForm — réutilise `FieldPlacerComponent` |

Pour chaque nouvel outil : (1) migration job_type + table résultat, (2) strategy
avec `needsRawBytes() = true`, (3) entrée catalogue + route Angular,
(4) composant avec aperçu live.
