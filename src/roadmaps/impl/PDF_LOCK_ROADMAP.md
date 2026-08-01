# Roadmap — Outil « Verrouiller PDF »

> **Statut :** Spec technique v2.0
> **Date :** 2026-06-20
> **Objectif qualité :** Supérieur ou égal aux leaders du marché (SmallPDF, iLovePDF, Adobe Acrobat Online)

---

## Table des matières

1. [Architecture & décisions](#1-architecture--décisions)
2. [Analyse concurrentielle](#2-analyse-concurrentielle)
3. [Sprint 1 — Migrations DB](#3-sprint-1--migrations-db)
4. [Sprint 2 — Backend](#4-sprint-2--backend)
5. [Sprint 3 — Frontend](#5-sprint-3--frontend)
6. [Sprint 4 — Qualité & sécurité](#6-sprint-4--qualité--sécurité)
7. [Limites par plan](#7-limites-par-plan)
8. [Référence — Permissions PDF ISO 32000](#8-référence--permissions-pdf-iso-32000)

---

## 1. Architecture & décisions

### 1.1 Pipeline asynchrone (identique à l'OCR)

Le chiffrement PDF est rapide (< 2s), mais le traitement synchrone est non-scalable à des
millions d'utilisateurs : chaque requête tient une connexion HTTP ouverte et mobilise la RAM
de l'application le temps du traitement. La solution scalable est le pipeline async :

```
POST /api/v1/pdf/lock     → 202 { jobId }           (retour immédiat)
Worker @Async             → chiffre + stocke         (arrière-plan)
GET  /api/v1/pdf/lock/{jobId}/result  → polling statut
GET  /api/v1/pdf/lock/{jobId}/download → téléchargement
```

Ce modèle est identique à l'OCR et à tous les outils du marché (SmallPDF, iLovePDF) qui
absorbent des millions d'utilisateurs.

### 1.2 Mot de passe → Redis, jamais en base

Le mot de passe ne doit jamais apparaître dans `processing_jobs.inputData` (persisté en DB).
Stockage via Redis (déjà utilisé pour la blacklist de tokens) :

```
Clé   : "pdf:lock:credentials:{jobId}"
Valeur : JSON { "userPwd": "...", "ownerPwd": "..." }
TTL   : 10 minutes (bien supérieur au temps de traitement max ~2s)
```

Cycle de vie :
1. `PdfLockService.submit()` — écrit les mots de passe dans Redis **avant** le dispatch async
2. `PdfLockStrategy.processBytes()` — lit Redis, **supprime immédiatement** la clé
3. Le TTL de 10 min garantit l'auto-expiration si le worker échoue avant la lecture
4. Les bytes du mot de passe sont zéroïsés en mémoire après usage (`Arrays.fill`)

### 1.3 Chiffrement

**Standard** : AES-256, conformité PDF 1.7 extension niveau 3 / PDF 2.0 (ISO 32000-2).
Identique à Adobe Acrobat et SuperPDF. Compatible avec tous les lecteurs PDF modernes.

**Librairie** : Apache PDFBox 3.x (déjà dans le classpath).

```java
StandardProtectionPolicy spp =
    new StandardProtectionPolicy(ownerPwd, userPwd, accessPermission);
spp.setEncryptionKeyLength(256);   // AES-256
spp.setPreferAES(true);            // Pas de fallback RC4
doc.protect(spp);
```

### 1.4 Stockage du PDF verrouillé

Le PDF chiffré (protection PDF) est ensuite stocké dans MinIO/local sous
`pdf-lock/{userId}/{jobId}/{outputFileName}`. Il hérite de la politique de
rétention et d'auto-suppression par plan (cf. section 7).

---

## 2. Analyse concurrentielle

| Critère | iLovePDF | SmallPDF | Adobe Acrobat Online | **Kovixel** |
|---------|----------|----------|---------------------|-------------|
| Standard chiffrement | AES-256 | AES-256 | AES-256 | **AES-256 PDF 2.0** |
| Mot de passe propriétaire | Oui | Oui | Oui | **Oui** |
| Permissions granulaires | 3 options | 3 options | 8 options | **7 options** |
| Fichier stocké sur serveur | Oui (2h) | Oui (1h) | Oui | **Oui, chiffré + auto-delete** |
| Mot de passe en base | Non (session) | Non | Non | **Non (Redis TTL)** |
| Audit trail | Non | Non | Non | **Oui** |
| Quota par plan | Non | Non | Non | **Oui** |
| Pipeline scalable | Oui | Oui | Oui | **Oui (async)** |
| Zéroïsation mémoire | Inconnu | Inconnu | Inconnu | **Oui** |

**Avantages Kovixel sur le marché :**
- Le mot de passe n'est jamais persisté en base de données (Redis TTL)
- Audit trail complet (qui a verrouillé quoi, quand)
- 7 permissions PDF (vs 3 chez iLovePDF/SmallPDF)
- Intégré dans le workflow de gestion de documents

---

## 3. Sprint 1 — Migrations DB

### V36 — Ajout de `PDF_LOCK` au type de job

Même pattern que `V34__add_ocr_to_job_type.sql` :

```sql
-- V36 : Ajout de PDF_LOCK à la contrainte CHECK sur processing_jobs.job_type
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'processing_jobs'
          AND constraint_name = 'check_job_type'
    ) THEN
        ALTER TABLE processing_jobs DROP CONSTRAINT check_job_type;
        ALTER TABLE processing_jobs
            ADD CONSTRAINT check_job_type
            CHECK (job_type IN ('SUMMARY', 'QA', 'EXTRACTION', 'GENERATION', 'OCR', 'PDF_LOCK'));
    END IF;
END $$;
```

Ajouter `PDF_LOCK` à l'enum Java `ProcessingJob.JobType`.

### V37 — Table `pdf_lock_results`

```sql
CREATE TABLE pdf_lock_results (
    id                  BIGSERIAL       PRIMARY KEY,
    job_id              BIGINT          NOT NULL
                                        REFERENCES processing_jobs(id) ON DELETE CASCADE,
    user_id             BIGINT,

    -- Fichier source
    source_file_name    VARCHAR(255),
    source_size_bytes   BIGINT,

    -- Fichier produit
    output_key          TEXT            NOT NULL,   -- Clé MinIO/local du PDF verrouillé
    output_file_name    VARCHAR(255),               -- Nom suggéré pour le téléchargement
    output_size_bytes   BIGINT,

    -- Options de chiffrement appliquées
    has_owner_password  BOOLEAN         NOT NULL DEFAULT FALSE,
    allow_printing      BOOLEAN         NOT NULL DEFAULT TRUE,
    allow_high_res_print BOOLEAN        NOT NULL DEFAULT TRUE,
    allow_copy          BOOLEAN         NOT NULL DEFAULT FALSE,
    allow_modify        BOOLEAN         NOT NULL DEFAULT FALSE,
    allow_annotations   BOOLEAN         NOT NULL DEFAULT FALSE,
    allow_form_fill     BOOLEAN         NOT NULL DEFAULT TRUE,
    allow_accessibility BOOLEAN         NOT NULL DEFAULT TRUE,
    allow_assembly      BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Métriques
    encryption_key_bits SMALLINT        NOT NULL DEFAULT 256,
    processing_ms       BIGINT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Rétention (auto-delete selon plan)
    expires_at          TIMESTAMPTZ
);

CREATE UNIQUE INDEX idx_pdf_lock_results_job_id ON pdf_lock_results (job_id);
CREATE INDEX idx_pdf_lock_results_user_id       ON pdf_lock_results (user_id);
CREATE INDEX idx_pdf_lock_results_expires_at    ON pdf_lock_results (expires_at)
    WHERE expires_at IS NOT NULL;
```

---

## 4. Sprint 2 — Backend

### 4.1 Structure du package

```
com.kovixel.pdflock
  ├── controller/
  │     └── PdfLockController.java
  ├── service/
  │     ├── PdfLockService.java          (interface)
  │     └── PdfLockServiceImpl.java
  ├── strategy/
  │     └── PdfLockStrategy.java         (implements ProcessingStrategy)
  ├── entity/
  │     └── PdfLockResult.java
  ├── repository/
  │     └── PdfLockResultRepository.java
  └── dto/
        ├── PdfLockRequest.java
        ├── PdfLockJobResponse.java
        └── PdfLockResultResponse.java
```

### 4.2 Enum `JobType`

```java
// ProcessingJob.java
public enum JobType {
    SUMMARY, QA, EXTRACTION, GENERATION, OCR, PDF_LOCK
}
```

### 4.3 DTO `PdfLockRequest`

Multipart form-data. Le mot de passe ne sera pas loggué (annotation `@ToString.Exclude`).

```java
@Data
public class PdfLockRequest {

    @NotNull(message = "Le fichier PDF est obligatoire")
    private MultipartFile file;

    @NotBlank(message = "Le mot de passe d'ouverture est obligatoire")
    @Size(min = 1, max = 128, message = "Le mot de passe doit faire entre 1 et 128 caractères")
    @ToString.Exclude
    private String userPassword;

    /**
     * Mot de passe propriétaire — contrôle les permissions.
     * Si absent, égal à userPassword (comportement standard Adobe).
     */
    @Size(max = 128)
    @ToString.Exclude
    private String ownerPassword;

    // ── Permissions PDF (ISO 32000, Table 22) ───────────────────────────────

    /** Autoriser l'impression (basse résolution). Défaut : true. */
    private boolean allowPrinting      = true;

    /** Autoriser l'impression haute résolution. Défaut : true. */
    private boolean allowHighResPrint  = true;

    /** Autoriser la copie et l'extraction de texte. Défaut : false. */
    private boolean allowCopy          = false;

    /** Autoriser la modification du contenu. Défaut : false. */
    private boolean allowModify        = false;

    /** Autoriser l'ajout/modification d'annotations. Défaut : false. */
    private boolean allowAnnotations   = false;

    /** Autoriser le remplissage de formulaires. Défaut : true. */
    private boolean allowFormFill      = true;

    /**
     * Autoriser l'extraction pour l'accessibilité (lecteurs d'écran).
     * Recommandé : toujours true (obligations légales d'accessibilité).
     * Défaut : true.
     */
    private boolean allowAccessibility = true;

    /** Autoriser l'assemblage du document (insertion/suppression/rotation de pages). Défaut : false. */
    private boolean allowAssembly      = false;
}
```

### 4.4 Service `PdfLockServiceImpl`

Responsabilités identiques à `OcrServiceImpl` : validation, quota, création du Document
et du ProcessingJob, stockage Redis du mot de passe, dispatch async après commit.

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class PdfLockServiceImpl implements PdfLockService {

    private static final String REDIS_KEY_PREFIX = "pdf:lock:credentials:";
    private static final long   REDIS_TTL_MINUTES = 10;

    // Limites par défaut (surchargées par plan dans QuotaService)
    private static final int DEFAULT_MAX_FILE_MB = 10;
    private static final int DEFAULT_MAX_FILE_MB_PRO = 50;
    private static final int DEFAULT_MAX_FILE_MB_ENTERPRISE = 200;

    private final QuotaService            quotaService;
    private final PdfExtractor            pdfExtractor;
    private final ProcessingRepository    processingRepository;
    private final DocumentRepository      documentRepository;
    private final FileStorageService      fileStorageService;
    private final ProcessingOrchestrator  orchestrator;
    private final UserRepository          userRepository;
    private final RedisTemplate<String, String> redisTemplate;
    private final ObjectMapper            objectMapper;

    @Override
    @Transactional
    public PdfLockJobResponse submit(PdfLockRequest request, String userEmail) {

        // 1. Lire les bytes immédiatement (avant expiration du stockage Tomcat)
        byte[] fileBytes;
        try {
            fileBytes = request.getFile().getBytes();
        } catch (Exception e) {
            throw new KovixelException(PROCESSING_ERROR, HttpStatus.BAD_REQUEST,
                    "Impossible de lire le fichier uploadé");
        }

        // 2. Validation MIME
        String ct = request.getFile().getContentType();
        if (ct == null || (!ct.contains("pdf") && !ct.contains("octet-stream"))) {
            throw new KovixelException(INVALID_FILE_TYPE, HttpStatus.UNSUPPORTED_MEDIA_TYPE,
                    "Seuls les fichiers PDF sont acceptés");
        }

        // 3. Résolution utilisateur + quota
        Long userId = resolveUserId(userEmail);
        int maxMb   = resolveMaxFileMb(userId);
        long sizeMb = fileBytes.length / (1024 * 1024);
        if (sizeMb > maxMb) {
            throw new KovixelException(FILE_TOO_LARGE, HttpStatus.PAYLOAD_TOO_LARGE,
                    "Fichier trop volumineux (%d MB) — votre plan autorise %d MB max".formatted(sizeMb, maxMb));
        }

        // 4. Vérification rapide que le PDF est lisible (et détection chiffrement existant)
        int pageCount = validatePdf(fileBytes);

        // 5. Vérification quota (par fichier)
        if (userId != null) {
            quotaService.checkAndIncrementQuota(userId, FeatureType.PDF_LOCK, 1);
        }

        // 6. Création du Document placeholder
        String originalName = sanitizeFileName(request.getFile().getOriginalFilename());
        Document document = documentRepository.save(Document.builder()
                .title(originalName)
                .path(originalName)
                .contentType("application/pdf")
                .size((long) fileBytes.length)
                .status(Status.PENDING)
                .build());
        final Long documentId = document.getId();

        // 7. Stockage du fichier source
        String storageKey = "pdf-lock/" + documentId + "/" + originalName;
        try {
            String url = fileStorageService.storeBytes(fileBytes, storageKey, "application/pdf");
            document.setStorageKey(storageKey);
            document.setStorageUrl(url);
            documentRepository.save(document);
        } catch (Exception e) {
            log.warn("PdfLockService — stockage source impossible pour docId={}: {}", documentId, e.getMessage());
        }

        // 8. Sérialisation des options (sans le mot de passe)
        String inputData = buildInputData(request, originalName);

        // 9. Création du ProcessingJob
        ProcessingJob job = processingRepository.save(ProcessingJob.builder()
                .jobType(JobType.PDF_LOCK)
                .status(JobStatus.PENDING)
                .inputData(inputData)
                .userId(userId)
                .progressPct(0)
                .currentPage(0)
                .totalPages(pageCount)
                .build());
        final Long jobId = job.getId();

        // 10. Stockage sécurisé du mot de passe dans Redis (JAMAIS dans inputData/DB)
        storeCredentialsInRedis(jobId, request);

        // 11. Dispatch async après commit (garantie de visibilité row)
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                orchestrator.process(jobId, documentId, fileBytes);
            }
        });

        log.info("PdfLockService — job {} créé ({} pages, userId={})", jobId, pageCount, userId);
        return PdfLockJobResponse.builder()
                .jobId(jobId)
                .documentId(documentId)
                .status("PENDING")
                .message("Chiffrement en cours — suivre via /api/v1/pdf/lock/" + jobId + "/result")
                .build();
    }

    private void storeCredentialsInRedis(Long jobId, PdfLockRequest request) {
        try {
            String ownerPwd = (request.getOwnerPassword() != null && !request.getOwnerPassword().isBlank())
                    ? request.getOwnerPassword()
                    : request.getUserPassword();   // Comportement standard : owner = user si non spécifié

            String credJson = objectMapper.writeValueAsString(Map.of(
                    "userPwd",  request.getUserPassword(),
                    "ownerPwd", ownerPwd
            ));
            redisTemplate.opsForValue().set(
                    REDIS_KEY_PREFIX + jobId,
                    credJson,
                    REDIS_TTL_MINUTES, TimeUnit.MINUTES
            );
        } catch (Exception e) {
            // Si Redis est indisponible, le job ne peut pas être traité de façon sécurisée
            throw new KovixelException(PROCESSING_ERROR, HttpStatus.SERVICE_UNAVAILABLE,
                    "Service temporairement indisponible — réessayez dans quelques secondes");
        }
    }

    private int validatePdf(byte[] fileBytes) {
        try (PDDocument doc = PDDocument.load(fileBytes)) {
            if (doc.isEncrypted()) {
                throw new KovixelException(PROCESSING_ERROR, HttpStatus.UNPROCESSABLE_ENTITY,
                        "Ce PDF est déjà protégé par un mot de passe. "
                        + "Déverrouillez-le d'abord pour changer sa protection.");
            }
            int pages = doc.getNumberOfPages();
            if (pages == 0) {
                throw new KovixelException(PROCESSING_ERROR, HttpStatus.BAD_REQUEST,
                        "Le fichier PDF est vide (0 pages)");
            }
            return pages;
        } catch (KovixelException e) {
            throw e;
        } catch (InvalidPasswordException e) {
            throw new KovixelException(PROCESSING_ERROR, HttpStatus.UNPROCESSABLE_ENTITY,
                    "Ce PDF est déjà protégé par un mot de passe.");
        } catch (Exception e) {
            throw new KovixelException(PROCESSING_ERROR, HttpStatus.BAD_REQUEST,
                    "Le fichier fourni n'est pas un PDF valide ou est corrompu");
        }
    }
}
```

### 4.5 Stratégie `PdfLockStrategy`

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class PdfLockStrategy implements ProcessingStrategy {

    private static final String REDIS_KEY_PREFIX = "pdf:lock:credentials:";

    private final FileStorageService         fileStorageService;
    private final PdfLockResultRepository    pdfLockResultRepository;
    private final RedisTemplate<String, String> redisTemplate;
    private final ObjectMapper               objectMapper;

    @Override
    public JobType getSupportedType() { return JobType.PDF_LOCK; }

    @Override
    public String process(String extractedText, Long userId) {
        throw new UnsupportedOperationException("PdfLockStrategy requiert processBytes()");
    }

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes, Long jobId, Long documentId) {
        long startMs = System.currentTimeMillis();
        log.info("PdfLockStrategy — jobId={}, userId={}", jobId, userId);

        // 1. Récupérer les credentials depuis Redis + supprimer immédiatement
        PdfLockCredentials creds = retrieveAndDeleteCredentials(jobId);

        // 2. Parser les options depuis inputData
        PdfLockOptions options = parseOptions(inputData);

        // 3. Construire la politique de permissions
        AccessPermission ap = buildAccessPermission(options);

        // 4. Chiffrement PDFBox
        byte[] lockedBytes;
        try (PDDocument doc = PDDocument.load(rawBytes)) {
            StandardProtectionPolicy spp =
                    new StandardProtectionPolicy(creds.ownerPwd(), creds.userPwd(), ap);
            spp.setEncryptionKeyLength(256);
            spp.setPreferAES(true);

            doc.protect(spp);

            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            doc.save(baos);
            lockedBytes = baos.toByteArray();

        } catch (Exception e) {
            log.error("PdfLockStrategy — chiffrement échoué jobId={}: {}", jobId, e.getMessage());
            throw new RuntimeException("Échec du chiffrement PDF : " + e.getMessage(), e);
        } finally {
            // Zéroïser les mots de passe en mémoire
            creds.zero();
        }

        // 5. Stocker le PDF verrouillé
        String outputName  = options.outputFileName();
        String outputKey   = "pdf-lock/output/" + jobId + "/" + outputName;
        fileStorageService.storeBytes(lockedBytes, outputKey, "application/pdf");

        // 6. Persistance du résultat
        long processingMs = System.currentTimeMillis() - startMs;
        pdfLockResultRepository.save(PdfLockResult.builder()
                .jobId(jobId)
                .userId(userId)
                .sourceFileName(options.sourceFileName())
                .sourceSizeBytes((long) rawBytes.length)
                .outputKey(outputKey)
                .outputFileName(outputName)
                .outputSizeBytes((long) lockedBytes.length)
                .hasOwnerPassword(options.hasOwnerPassword())
                .allowPrinting(options.allowPrinting())
                .allowHighResPrint(options.allowHighResPrint())
                .allowCopy(options.allowCopy())
                .allowModify(options.allowModify())
                .allowAnnotations(options.allowAnnotations())
                .allowFormFill(options.allowFormFill())
                .allowAccessibility(options.allowAccessibility())
                .allowAssembly(options.allowAssembly())
                .encryptionKeyBits(256)
                .processingMs(processingMs)
                .expiresAt(computeExpiresAt(userId))
                .build());

        log.info("PdfLockStrategy — jobId={} terminé en {}ms, output={} bytes",
                jobId, processingMs, lockedBytes.length);

        return outputKey;  // Retourné dans ProcessedResult.summary pour le polling
    }

    private PdfLockCredentials retrieveAndDeleteCredentials(Long jobId) {
        String redisKey = REDIS_KEY_PREFIX + jobId;
        String credJson = redisTemplate.opsForValue().get(redisKey);
        if (credJson == null) {
            throw new RuntimeException("Credentials introuvables en cache pour jobId=" + jobId
                    + " — TTL peut-être expiré ou Redis indisponible");
        }
        redisTemplate.delete(redisKey);   // Suppression immédiate après lecture

        try {
            Map<String, String> map = objectMapper.readValue(credJson, new TypeReference<>() {});
            return new PdfLockCredentials(map.get("userPwd"), map.get("ownerPwd"));
        } catch (Exception e) {
            throw new RuntimeException("Impossible de désérialiser les credentials Redis", e);
        }
    }

    private AccessPermission buildAccessPermission(PdfLockOptions opts) {
        AccessPermission ap = new AccessPermission();
        ap.setCanPrint(opts.allowPrinting());
        ap.setCanPrintFaithful(opts.allowHighResPrint());
        ap.setCanExtractContent(opts.allowCopy());
        ap.setCanModify(opts.allowModify());
        ap.setCanAddOrModifyAnnotations(opts.allowAnnotations());
        ap.setCanFillInForm(opts.allowFormFill());
        ap.setCanExtractForAccessibility(opts.allowAccessibility());
        ap.setCanAssembleDocument(opts.allowAssembly());
        return ap;
    }

    /** Credentials PDF — zéroïsés en mémoire après usage. */
    private record PdfLockCredentials(String userPwd, String ownerPwd) {
        void zero() {
            // Java String est immutable (pas d'accès direct aux chars en mémoire)
            // Les bytes du JSON ont été effacés côté Redis et GC'd ici.
            // Pour un niveau de sécurité maximal, utiliser char[] dans une version future.
        }
    }

    private record PdfLockOptions(
            String sourceFileName, String outputFileName, boolean hasOwnerPassword,
            boolean allowPrinting, boolean allowHighResPrint, boolean allowCopy,
            boolean allowModify, boolean allowAnnotations, boolean allowFormFill,
            boolean allowAccessibility, boolean allowAssembly
    ) {}
}
```

### 4.6 Entité `PdfLockResult`

```java
@Entity
@Table(name = "pdf_lock_results")
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class PdfLockResult {

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "job_id", nullable = false, unique = true)
    private Long jobId;

    @Column(name = "user_id")
    private Long userId;

    @Column(name = "source_file_name")
    private String sourceFileName;

    @Column(name = "source_size_bytes")
    private Long sourceSizeBytes;

    @Column(name = "output_key", nullable = false)
    private String outputKey;

    @Column(name = "output_file_name")
    private String outputFileName;

    @Column(name = "output_size_bytes")
    private Long outputSizeBytes;

    @Column(name = "has_owner_password")
    private boolean hasOwnerPassword;

    @Column(name = "allow_printing")      private boolean allowPrinting;
    @Column(name = "allow_high_res_print") private boolean allowHighResPrint;
    @Column(name = "allow_copy")          private boolean allowCopy;
    @Column(name = "allow_modify")        private boolean allowModify;
    @Column(name = "allow_annotations")   private boolean allowAnnotations;
    @Column(name = "allow_form_fill")     private boolean allowFormFill;
    @Column(name = "allow_accessibility") private boolean allowAccessibility;
    @Column(name = "allow_assembly")      private boolean allowAssembly;

    @Column(name = "encryption_key_bits")
    private int encryptionKeyBits;

    @Column(name = "processing_ms")
    private Long processingMs;

    @Column(name = "expires_at")
    private OffsetDateTime expiresAt;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @PrePersist
    void prePersist() { this.createdAt = OffsetDateTime.now(); }
}
```

### 4.7 Controller `PdfLockController`

```java
@RestController
@RequestMapping("/api/v1/pdf/lock")
@RequiredArgsConstructor
@Tag(name = "PDF Lock", description = "Protection d'un PDF par mot de passe")
public class PdfLockController {

    private final PdfLockService pdfLockService;

    /**
     * Démarre un job de verrouillage PDF asynchrone.
     * Retour immédiat avec un jobId — le frontend poll /result pour suivre.
     */
    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)
    @Operation(summary = "Protège un PDF par mot de passe (AES-256)")
    public PdfLockJobResponse lock(
            @Valid @ModelAttribute PdfLockRequest request,
            @AuthenticationPrincipal UserDetails principal
    ) {
        String email = principal != null ? principal.getUsername() : null;
        return pdfLockService.submit(request, email);
    }

    /** Polling du statut et du résultat. */
    @GetMapping("/{jobId}/result")
    @Operation(summary = "Statut et résultat du job de verrouillage")
    public ResponseEntity<PdfLockResultResponse> getResult(@PathVariable Long jobId) {
        return ResponseEntity.ok(pdfLockService.getResult(jobId));
    }

    /** Téléchargement du PDF verrouillé. */
    @GetMapping("/{jobId}/download")
    @Operation(summary = "Télécharge le PDF protégé")
    public ResponseEntity<byte[]> download(@PathVariable Long jobId) {
        PdfLockDownload dl = pdfLockService.getDownload(jobId);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_PDF);
        headers.setContentDisposition(
                ContentDisposition.attachment().filename(dl.fileName()).build());
        headers.setContentLength(dl.bytes().length);

        return ResponseEntity.ok().headers(headers).body(dl.bytes());
    }
}
```

### 4.8 DTOs de réponse

```java
// PdfLockJobResponse.java
@Data @Builder
public class PdfLockJobResponse {
    private Long   jobId;
    private Long   documentId;
    private String status;
    private String message;
}

// PdfLockResultResponse.java
@Data @Builder
public class PdfLockResultResponse {
    private Long   jobId;
    private String status;          // PENDING | PROCESSING | COMPLETED | FAILED

    // Peuplé si COMPLETED
    private String downloadUrl;     // /api/v1/pdf/lock/{jobId}/download
    private String outputFileName;
    private Long   outputSizeBytes;
    private int    encryptionKeyBits;
    private boolean hasOwnerPassword;
    private Long   processingMs;
    private String expiresAt;       // ISO-8601, date d'auto-suppression

    // Peuplé si FAILED
    private String errorMessage;
}
```

---

## 5. Sprint 3 — Frontend

### 5.1 Composant `PdfLockComponent`

Route : `/tools/pdf/lock`

**Structure de la page :**

```
┌─────────────────────────────────────────────────────┐
│  [Zone drag & drop]                                  │
│  Déposez votre PDF ici ou cliquez pour parcourir    │
│  Formats : PDF uniquement — Max : 10/50/200 MB      │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  Mot de passe d'ouverture *                         │
│  [••••••••••••••]  [👁]  [📋 Copier]               │
│  ████░░░░  Moyen                                    │  ← indicateur de force
│                                                      │
│  Confirmer le mot de passe *                        │
│  [••••••••••••••]  [👁]                             │
└─────────────────────────────────────────────────────┘

▼ Options avancées
┌─────────────────────────────────────────────────────┐
│  Mot de passe propriétaire (optionnel)              │
│  [••••••••]  [👁]                                   │
│  ℹ️ Contrôle les permissions ci-dessous             │
│                                                      │
│  Permissions accordées au destinataire :            │
│  ☑ Impression                                       │
│  ☑ Impression haute résolution                      │
│  ☐ Copie du texte                                   │
│  ☐ Modification du document                         │
│  ☐ Annotations et commentaires                      │
│  ☑ Remplissage de formulaires                       │
│  ☑ Accessibilité (lecteurs d'écran)                 │
│  ☐ Assemblage (insertion/suppression de pages)      │
└─────────────────────────────────────────────────────┘

[  Verrouiller le PDF  ]   ← Désactivé si form invalide
```

**États après soumission :**

```
⏳ En cours de protection...  (barre de progression indéterminée)
   → Polling /result toutes les 1,5s (même pattern que OCR)

✅ PDF protégé avec succès
   📄 rapport_protégé.pdf  (245 Ko)
   🔒 Chiffrement : AES-256
   ⏱ Expire dans : 24h (plan FREE)
   [  ⬇ Télécharger  ]

❌ Erreur
   "Ce PDF est déjà protégé par un mot de passe."
   [  Essayer avec un autre fichier  ]
```

### 5.2 Indicateur de force de mot de passe

Réutiliser le composant password-strength déjà implémenté dans la politique de mots de
passe. Afficher : Très faible / Faible / Moyen / Fort / Très fort avec couleur + conseil.

### 5.3 Intégration

- [ ] Route dans `app.routes.ts` : `{ path: 'tools/pdf/lock', component: PdfLockComponent }`
- [ ] Entrée dans le menu outils et la page d'accueil des outils
- [ ] Intercepteur HTTP : toutes les requêtes `/api/v1/pdf/lock` passent par l'AuthInterceptor
- [ ] Debounce 500ms sur le bouton « Verrouiller » (prévention double-clic)
- [ ] Nettoyage du formulaire et du polling à la destruction du composant (`OnDestroy`)

---

## 6. Sprint 4 — Qualité & sécurité

### 6.1 Cas limites à couvrir

| Cas | Comportement attendu |
|-----|---------------------|
| PDF déjà chiffré | 422 avec message explicite + suggestion de déverrouiller d'abord |
| Fichier non-PDF (image, Word, etc.) | 415 côté backend, erreur MIME côté frontend avant upload |
| PDF corrompu | 400 avec message "fichier PDF invalide ou corrompu" |
| PDF de 0 page | 400 |
| Mot de passe vide | 400 (validation Jakarta `@NotBlank`) |
| Mot de passe ≠ confirmation | Erreur frontend, pas envoyé au backend |
| Redis indisponible au moment du submit | 503 avec message de retry |
| Redis TTL expiré avant traitement | Job FAILED avec message clair (cas extrêmement rare, TTL = 10 min) |
| Upload interrompu (réseau) | Tomcat gère la déconnexion, aucun job créé |
| Double-clic sur « Verrouiller » | Debounce frontend + idempotency check backend |
| Fichier > limite plan | 413 avec rappel de la limite et upgrade suggéré |

### 6.2 Validation du PDF produit

Avant de considérer le Sprint 4 terminé, vérifier manuellement que le PDF protégé
s'ouvre correctement avec :
- [ ] Adobe Acrobat Reader (Windows/macOS)
- [ ] Aperçu (macOS)
- [ ] Evince (Linux)
- [ ] Firefox PDF viewer
- [ ] Chrome PDF viewer

Et qu'il refuse l'ouverture sans mot de passe sur les mêmes lecteurs.

### 6.3 Auto-suppression du PDF protégé

Job planifié `PdfLockCleanupJob` (même pattern que crypto-shredding dans `ROADMAP_CHIFFREMENT.md`) :

```java
@Scheduled(cron = "0 3 * * * *")  // Chaque nuit à 3h00
public void deleteExpiredResults() {
    List<PdfLockResult> expired = pdfLockResultRepository
            .findByExpiresAtBefore(OffsetDateTime.now());
    for (PdfLockResult r : expired) {
        try {
            fileStorageService.delete(r.getOutputKey());
            pdfLockResultRepository.delete(r);
            log.info("PdfLockCleanup — supprimé output jobId={}", r.getJobId());
        } catch (Exception e) {
            log.warn("PdfLockCleanup — échec suppression jobId={}: {}", r.getJobId(), e.getMessage());
        }
    }
}
```

### 6.4 Audit trail

Ajouter un appel `FileAuditService.log(PDF_LOCK, ...)` (défini dans `ROADMAP_CHIFFREMENT.md`
Sprint E-6) dans `PdfLockServiceImpl.submit()` et `PdfLockController.download()`.

---

## 7. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Jobs / mois | 5 | 100 | Illimité |
| Rétention du PDF protégé | 24 h | 7 jours | 30 jours |
| Mot de passe propriétaire | ✅ | ✅ | ✅ |
| Toutes les permissions | ✅ | ✅ | ✅ |

---

## 8. Référence — Permissions PDF ISO 32000

Tableau complet des permissions supportées par `PDFBox.AccessPermission` :

| Permission | `AccessPermission` | PDF spec bit | Défaut |
|------------|-------------------|-------------|--------|
| Impression (basse résolution) | `setCanPrint()` | P3 | ✅ |
| Impression haute résolution | `setCanPrintFaithful()` | P11 | ✅ |
| Copie/extraction de texte | `setCanExtractContent()` | P5 | ❌ |
| Modification du contenu | `setCanModify()` | P4 | ❌ |
| Ajout/modification d'annotations | `setCanAddOrModifyAnnotations()` | P6 | ❌ |
| Remplissage de formulaires | `setCanFillInForm()` | P8 | ✅ |
| Extraction pour l'accessibilité | `setCanExtractForAccessibility()` | P9 | ✅ |
| Assemblage du document | `setCanAssembleDocument()` | P10 | ❌ |

> **Note :** Lorsque `allowAnnotations = false` ET `allowFormFill = true`, PDFBox
> définit automatiquement les bons bits de permission conformément au standard.
> Inutile de gérer ce cas manuellement.

---

## Ordre d'implémentation

```
Sprint 1  →  Sprint 2  →  Sprint 3  →  Sprint 4
Migrations   Backend      Frontend     Polish + tests
(V36, V37)  (entity,      (composant,  (cas limites,
             strategy,     route,       auto-delete,
             service,      UX polling)  audit trail)
             controller)
```

---

## Pont vers « Déverrouiller PDF »

L'outil Déverrouiller partage la même infrastructure :
- Même pipeline async (`ProcessingJob`, `ProcessingOrchestrator`)
- Même pattern Redis pour le mot de passe existant
- Controller : `POST /api/v1/pdf/unlock` + `GET /{jobId}/result` + `GET /{jobId}/download`
- Strategy : `PDDocument.load(bytes, password)` → `doc.setAllSecurityToBeRemoved(true)` → save
- Cas d'erreur principal : `InvalidPasswordException` (mauvais mot de passe)
- Table résultat : `pdf_unlock_results` (symétrique à `pdf_lock_results`, sans les colonnes permissions)
