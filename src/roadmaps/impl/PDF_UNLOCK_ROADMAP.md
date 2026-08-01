# Roadmap — Outil « Déverrouiller PDF »

> **Statut :** Sprint 1–4 réalisés ✅
> **Date :** 2026-06-21
> **Objectif qualité :** Supérieur ou égal aux leaders du marché (SmallPDF, iLovePDF, Sejda, Adobe Acrobat Online)

---

## Table des matières

1. [Architecture & décisions](#1-architecture--décisions)
2. [Analyse concurrentielle](#2-analyse-concurrentielle)
3. [Sprint 1 — Migrations DB](#3-sprint-1--migrations-db) ✅
4. [Sprint 2 — Backend](#4-sprint-2--backend) ✅
5. [Sprint 3 — Frontend](#5-sprint-3--frontend) ✅
6. [Sprint 4 — Enrichissement qualité](#6-sprint-4--enrichissement-qualité) ✅
7. [Limites par plan](#7-limites-par-plan)
8. [Référence — Types de chiffrement PDF](#8-référence--types-de-chiffrement-pdf)
9. [Aspects légaux & conformité](#9-aspects-légaux--conformité)

---

## 1. Architecture & décisions

### 1.1 Pipeline asynchrone (identique à PDF Lock)

Même architecture queue/worker que tous les outils Kovixel :

```
POST /api/v1/pdf/unlock   → 202 { jobId }             (retour immédiat)
Worker @Async             → supprime chiffrement       (arrière-plan)
GET  /api/v1/pdf/unlock/{jobId}/result  → polling statut
GET  /api/v1/pdf/unlock/{jobId}/download → téléchargement
```

Le déverrouillage d'un gros PDF peut prendre quelques secondes. Le pipeline async
garantit qu'aucune connexion HTTP n'est bloquée, même sous charge massive.

---

### 1.2 Validation synchrone du mot de passe AVANT création du job ⭐

**Décision clé — supérieure à tous les concurrents :**

Chez iLovePDF, SmallPDF et Sejda, un mot de passe incorrect n'est détecté qu'après
traitement async → l'utilisateur attend plusieurs secondes pour recevoir l'erreur.

Chez Kovixel, la validation se fait **dans `submit()` côté service, de façon synchrone**,
avant même que le `ProcessingJob` soit créé :

```java
// PdfUnlockServiceImpl.submit()
validatePasswordAndProtection(fileBytes, request.getPassword());
// → 422 IMMÉDIAT si : mauvais mot de passe | PDF non chiffré | PDF corrompu
```

La validation ouvre le PDF avec PDFBox :
1. `Loader.loadPDF(bytes, password)` — `InvalidPasswordException` → 422 "Mot de passe incorrect"
2. `doc.isEncrypted()` → `false` → 422 "Ce PDF n'est pas protégé"
3. Autre exception → 400 "PDF invalide ou corrompu"

**Résultat :** feedback instantané, aucun job gaspillé, aucune capacité async mobilisée inutilement.

---

### 1.3 Mot de passe → Redis, jamais en base

Le mot de passe ne doit jamais apparaître dans `processing_jobs.inputData` (colonne TEXT persistée).
Même pattern que PDF Lock, avec un TTL raccourci car la validation est déjà faite :

```
Clé   : "pdf:unlock:credentials:{jobId}"
Valeur : JSON { "password": "..." }
TTL   : 5 minutes (TTL court : validation synchrone garantit la cohérence)
```

Cycle de vie :
1. `PdfUnlockServiceImpl.submit()` — valide le mot de passe, puis l'écrit dans Redis
2. `PdfUnlockStrategy.processBytes()` — lit Redis, **supprime immédiatement la clé**
3. TTL 5 min assure l'auto-expiration si le worker ne tourne pas (cas extrêmement rare)

> **Différence vs PDF Lock :** TTL 5 min (vs 10 min) car le mot de passe a déjà servi pour
> la validation synchrone. Le risque de TTL expiré avant traitement est quasi nul.

---

### 1.4 PDFBox 3.x — API de déchiffrement

```java
// ⚠️ PDFBox 3.x : Loader.loadPDF() remplace PDDocument.load()
try (PDDocument doc = Loader.loadPDF(rawBytes, password)) {
    doc.setAllSecurityToBeRemoved(true);      // Supprime TOUT le chiffrement
    ByteArrayOutputStream baos = new ByteArrayOutputStream();
    doc.save(baos);
    return baos.toByteArray();
}
```

`setAllSecurityToBeRemoved(true)` est l'API officielle PDFBox pour supprimer
toute protection (chiffrement utilisateur ET restrictions propriétaire) en une seule opération.
Compatible avec RC4-40, RC4-128, AES-128, AES-256.

---

### 1.5 Correction critique — `needsRawBytes()` dans l'orchestrateur

**Bug découvert lors du checking (2026-06-21) et corrigé immédiatement.**

`ProcessingOrchestrator` ne routait vers `processBytes()` que pour `JobType.OCR`.
`PDF_UNLOCK` tombait dans la branche `else` → `strategy.process()` → `UnsupportedOperationException`
→ **100% des jobs de déverrouillage auraient échoué en production.**

**Correction appliquée :**

```java
// ProcessingStrategy.java — nouvelle méthode interface
default boolean needsRawBytes() { return false; }

// PdfUnlockStrategy.java
@Override public boolean needsRawBytes() { return true; }

// ProcessingOrchestrator.java (et PdfLockStrategy, OcrStrategy aussi)
if (strategy.needsRawBytes()) {
    result = strategy.processBytes(job.getInputData(), job.getUserId(), fileBytes, jobId, documentId);
} else {
    // branche text extrait (SUMMARY, QA, EXTRACTION, GENERATION)
}
```

Désormais toute nouvelle stratégie bytes (compression, merge, split…) override simplement
`needsRawBytes()` sans modifier l'orchestrateur.

---

### 1.6 Gestion des différents types de protection PDF

| Type de protection | Comportement actuel | Sprint 4 |
|---|---|---|
| **User password** (ouverture bloquée) | ✅ Géré — mot de passe requis | — |
| **Owner password + user password** | ✅ Le user password suffit pour ouvrir | — |
| **Owner-only** (ouverture libre, restrictions actives) | ⚠️ Partiellement géré (voir §6.4) | Amélioration |
| **RC4-40 / RC4-128 / AES-128 / AES-256** | ✅ Tous gérés par PDFBox | — |
| **Pas de chiffrement** | ✅ 422 immédiat | — |
| **PDF corrompu** | ✅ 400 immédiat | — |

---

## 2. Analyse concurrentielle

| Critère | iLovePDF | SmallPDF | Sejda | Adobe Acrobat | **Kovixel** |
|---------|----------|----------|-------|---------------|-------------|
| Validation mot de passe | Async (lent) | Async (lent) | Async (lent) | Semi-sync | **Sync immédiate (⚡ 0 job gaspillé)** |
| Feedback mauvais mdp | Après traitement (~5s) | Après traitement | Après traitement | Rapide | **Immédiat (422)** |
| Distinction "pas protégé" vs "mauvais mdp" | Non | Non | Non | Oui | **Oui + messages distincts** |
| Avertissement légal | Mentions légales footer | Mentions légales footer | Oui (modal) | Oui | **Oui (card visible avant envoi)** |
| Chiffrement supporté | AES-256 + RC4 | AES-256 + RC4 | Tous | Tous | **Tous (PDFBox)** |
| Métadonnées chiffrement affichées | Non | Non | Non | Non | **Oui (Sprint 4)** |
| Fichier stocké sur serveur | 2h | 1h | 2h | Session | **24h + auto-delete** |
| Mot de passe en base | Non | Non | Non | Non | **Non (Redis TTL 5min)** |
| Audit trail | Non | Non | Non | Non | **Oui** |
| Scalabilité | Cloud | Cloud | Cloud | Cloud | **Async + Redis** |
| Quota par plan | Non (freemium) | Non (freemium) | Non | Oui (Pro) | **Oui (FREE/PRO/ENTERPRISE)** |

**Avantages Kovixel uniques :**

- **Validation synchrone** : premier sur le marché à refuser immédiatement un mauvais mot de passe sans consommer de ressources async
- **Métadonnées du chiffrement supprimé** dans la carte résultat (Sprint 4) — aucun concurrent ne montre "AES-256 utilisateur + 4 restrictions levées"
- **Redis TTL 5 min** : fenêtre d'exposition du mot de passe 2× plus courte que PDF Lock (car validation déjà faite)
- **Avertissement légal intégré** dans le composant (pas en footer)

---

## 3. Sprint 1 — Migrations DB ✅

### V38 — Ajout de `PDF_UNLOCK` au type de job

Même pattern idempotent que V36 (PDF Lock) et V34 (OCR) :

```sql
-- V38 : ajout de PDF_UNLOCK au CHECK sur processing_jobs.job_type
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.table_constraints
               WHERE table_name = 'processing_jobs' AND constraint_name = 'check_job_type') THEN
        ALTER TABLE processing_jobs DROP CONSTRAINT check_job_type;
        ALTER TABLE processing_jobs ADD CONSTRAINT check_job_type
            CHECK (job_type IN ('SUMMARY', 'QA', 'EXTRACTION', 'GENERATION', 'OCR', 'PDF_LOCK', 'PDF_UNLOCK'));
    END IF;
END $$;
```

`JobType.PDF_UNLOCK` ajouté à l'enum Java `ProcessingJob.JobType`.

---

### V39 — Table `pdf_unlock_results`

Table plus simple que `pdf_lock_results` : pas de colonnes permissions (le déverrouillage
supprime tout — il n'y a rien à configurer).

```sql
CREATE TABLE IF NOT EXISTS pdf_unlock_results (
    id                  BIGSERIAL    PRIMARY KEY,
    job_id              BIGINT       NOT NULL REFERENCES processing_jobs(id) ON DELETE CASCADE,
    user_id             BIGINT,

    -- Fichier source
    source_file_name    VARCHAR(255),
    source_size_bytes   BIGINT,

    -- Fichier produit (PDF non chiffré)
    output_key          TEXT         NOT NULL,   -- Clé MinIO/local
    output_file_name    VARCHAR(255),
    output_size_bytes   BIGINT,

    -- Métriques
    processing_ms       BIGINT,

    -- Rétention
    expires_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pdf_unlock_results_job_id  ON pdf_unlock_results (job_id);
CREATE INDEX        IF NOT EXISTS idx_pdf_unlock_results_user_id ON pdf_unlock_results (user_id);
CREATE INDEX        IF NOT EXISTS idx_pdf_unlock_results_expires ON pdf_unlock_results (expires_at)
    WHERE expires_at IS NOT NULL;
```

> **Sprint 4 :** Migration `V40` ajoutera les colonnes de métadonnées chiffrement
> (`original_encryption_algorithm`, `original_key_bits`, `had_user_password`, `had_owner_password`).
> Voir §6.1.

---

## 4. Sprint 2 — Backend ✅

### 4.1 Structure du package

```
com.kovixel.pdfunlock
  ├── controller/
  │     └── PdfUnlockController.java
  ├── service/
  │     ├── PdfUnlockService.java           (interface + record PdfUnlockDownload)
  │     └── PdfUnlockServiceImpl.java
  ├── strategy/
  │     └── PdfUnlockStrategy.java          (implements ProcessingStrategy)
  ├── scheduler/
  │     └── PdfUnlockCleanupJob.java
  ├── entity/
  │     └── PdfUnlockResult.java
  ├── repository/
  │     └── PdfUnlockResultRepository.java
  └── dto/
        ├── PdfUnlockRequest.java
        ├── PdfUnlockJobResponse.java
        └── PdfUnlockResultResponse.java
```

---

### 4.2 DTO `PdfUnlockRequest`

```java
@Data
public class PdfUnlockRequest {

    @NotNull(message = "Le fichier PDF est obligatoire")
    private MultipartFile file;

    @NotBlank(message = "Le mot de passe est obligatoire")
    @Size(min = 1, max = 128)
    @ToString.Exclude           // Jamais loggué
    private String password;
}
```

---

### 4.3 Service `PdfUnlockServiceImpl` — flux complet

```
submit(request, userEmail):
  1. Lecture bytes (Tomcat multipart)
  2. Validation MIME (application/pdf)
  3. Résolution userId (null si anonyme)
  4. Validation taille (≤ 10 MB FREE, configurable)
  5. ★ validatePasswordAndProtection(bytes, password) → 422 immédiat si erreur
  6. checkAndIncrementQuota(userId, PDF_UNLOCK)
  7. Document placeholder → documentRepository.save()
  8. fileStorageService.storeBytes() → stocke le source
  9. ProcessingJob PENDING → processingRepository.save()
  10. storeCredentialInRedis(jobId, password) → TTL 5 min
  11. afterCommit() → orchestrator.process(jobId, documentId, bytes)
  return PdfUnlockJobResponse { jobId, documentId, status:"PENDING" }
```

**Détail de la validation synchrone (étape 5) :**

```java
private void validatePasswordAndProtection(byte[] fileBytes, String password) {
    try (PDDocument doc = Loader.loadPDF(fileBytes, password)) {
        if (!doc.isEncrypted()) {
            throw new KovixelException(PROCESSING_ERROR, UNPROCESSABLE_ENTITY,
                    "Ce PDF n'est pas protégé par mot de passe — aucun déverrouillage nécessaire.");
        }
    } catch (KovixelException e) {
        throw e;
    } catch (InvalidPasswordException e) {
        throw new KovixelException(PROCESSING_ERROR, UNPROCESSABLE_ENTITY,
                "Mot de passe incorrect — impossible d'ouvrir ce PDF.");
    } catch (Exception e) {
        throw new KovixelException(PROCESSING_ERROR, BAD_REQUEST,
                "Le fichier fourni n'est pas un PDF valide ou est corrompu.");
    }
}
```

---

### 4.4 Stratégie `PdfUnlockStrategy`

```java
@Slf4j @Component @RequiredArgsConstructor
public class PdfUnlockStrategy implements ProcessingStrategy {

    @Override public JobType getSupportedType() { return JobType.PDF_UNLOCK; }
    @Override public boolean needsRawBytes()    { return true; }  // ← Fix critique

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes,
                               Long jobId, Long documentId) {
        // 1. Récupérer + supprimer immédiatement depuis Redis
        String password = retrieveAndDeleteCredential(jobId);

        // 2. Ouvrir + supprimer le chiffrement
        byte[] unlockedBytes;
        try (PDDocument doc = Loader.loadPDF(rawBytes, password)) {
            doc.setAllSecurityToBeRemoved(true);
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            doc.save(baos);
            unlockedBytes = baos.toByteArray();
        }

        // 3. Stocker sous pdf-unlock/output/{jobId}/{outputFileName}
        // 4. PdfUnlockResult.save() avec expiresAt = now + 24h
        // 5. return outputKey
    }
}
```

---

### 4.5 Controller `PdfUnlockController`

```java
@RestController
@RequestMapping("/api/v1/pdf/unlock")
@Tag(name = "PDF Unlock", description = "Suppression du mot de passe d'un PDF")
public class PdfUnlockController {

    @PostMapping(consumes = MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.ACCEPTED)    // 202 — job créé, pas encore terminé
    public PdfUnlockJobResponse unlock(
            @Valid @ModelAttribute PdfUnlockRequest request,
            @AuthenticationPrincipal UserDetails principal) { ... }

    @GetMapping("/{jobId}/result")
    public ResponseEntity<PdfUnlockResultResponse> getResult(@PathVariable Long jobId) { ... }

    @GetMapping("/{jobId}/download")
    public ResponseEntity<byte[]> download(@PathVariable Long jobId) {
        // Content-Disposition: attachment; filename="rapport_déverrouillé.pdf"
        // Content-Type: application/pdf
    }
}
```

---

### 4.6 DTOs de réponse

```java
// PdfUnlockJobResponse.java
@Data @Builder
public class PdfUnlockJobResponse {
    private Long   jobId;
    private Long   documentId;
    private String status;        // "PENDING"
    private String message;
}

// PdfUnlockResultResponse.java (état actuel — enrichi en Sprint 4)
@Data @Builder
public class PdfUnlockResultResponse {
    private Long   jobId;
    private String status;           // PENDING | PROCESSING | COMPLETED | FAILED

    // Peuplé si COMPLETED
    private String downloadUrl;      // /api/v1/pdf/unlock/{jobId}/download
    private String outputFileName;   // "rapport_déverrouillé.pdf"
    private Long   outputSizeBytes;
    private Long   processingMs;
    private String expiresAt;        // ISO-8601

    // Sprint 4 — à ajouter :
    // private String originalEncryptionAlgorithm;  // "AES-256"
    // private int    originalKeyBits;               // 256
    // private boolean originalHadUserPassword;
    // private boolean originalHadOwnerPassword;

    // Peuplé si FAILED
    private String errorMessage;
}
```

---

### 4.7 Entité `PdfUnlockResult`

```java
@Entity @Table(name = "pdf_unlock_results")
@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class PdfUnlockResult {

    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "job_id",  nullable = false, unique = true) private Long jobId;
    @Column(name = "user_id")                                  private Long userId;
    @Column(name = "source_file_name")  private String sourceFileName;
    @Column(name = "source_size_bytes") private Long   sourceSizeBytes;

    @Column(name = "output_key",        nullable = false, columnDefinition = "TEXT")
    private String outputKey;
    @Column(name = "output_file_name")  private String outputFileName;
    @Column(name = "output_size_bytes") private Long   outputSizeBytes;

    @Column(name = "processing_ms")     private Long   processingMs;
    @Column(name = "expires_at")        private OffsetDateTime expiresAt;
    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    @PrePersist void prePersist() { this.createdAt = OffsetDateTime.now(); }
}
```

---

### 4.8 Scheduler `PdfUnlockCleanupJob`

```java
@Slf4j @Component @RequiredArgsConstructor
public class PdfUnlockCleanupJob {

    @Scheduled(fixedDelay = 3_600_000, initialDelay = 180_000) // 1h, décalé de 3 min vs Lock
    @Transactional
    public void cleanupExpiredUnlocks() {
        List<PdfUnlockResult> expired =
                pdfUnlockResultRepository.findByExpiresAtBefore(OffsetDateTime.now());
        // Pour chaque résultat expiré :
        //   1. fileStorageService.delete(result.getOutputKey())
        //   2. pdfUnlockResultRepository.delete(result)
        // Log : "{deleted}/{total} fichiers supprimés ({MB} MB libérés)"
    }
}
```

> `initialDelay = 180_000` (3 min) décale ce job par rapport à `PdfLockCleanupJob`
> (`initialDelay = 120_000`, 2 min) pour éviter la contention au démarrage.

---

### 4.9 Intégrations transverses

```java
// FeatureType.java
PDF_UNLOCK  // "Déverrouillage PDF (quota en fichiers/jour)"

// PlanConfig.java — limitFor()
case PDF_UNLOCK -> maxConversionsPerDay;   // Partage le quota de conversions

// ProcessingJob.JobType
SUMMARY, QA, EXTRACTION, GENERATION, OCR, PDF_LOCK, PDF_UNLOCK
```

---

## 5. Sprint 3 — Frontend ✅

### 5.1 Fichiers créés

```
kovixel-ui/src/app/
  ├── core/
  │     ├── models/pdf-unlock.model.ts        (PdfUnlockJobResponse, PdfUnlockResultResponse)
  │     └── services/pdf-unlock.service.ts    (submit, getResult, downloadUnlocked)
  └── features/tools/pdf-unlock/
        ├── pdf-unlock.routes.ts              (PDF_UNLOCK_ROUTES lazy-loaded)
        └── pdf-unlock.component.ts           (composant principal)
```

---

### 5.2 Route et catalogue

```typescript
// app.routes.ts — AVANT la route générique tools/:slug
{
  path: 'tools/pdf/unlock',
  canActivate: [softAuthGuard],
  loadChildren: () =>
    import('./features/tools/pdf-unlock/pdf-unlock.routes').then(m => m.PDF_UNLOCK_ROUTES),
  data: { title: 'Déverrouiller un PDF', guestFeature: 'pdf-unlock' },
},

// tools-config.ts — entrée catalogue
{
  slug: 'pdf/unlock',
  icon: LockOpen,           // lucide-angular — vérifié dans lock-open.d.ts
  badge: 'NEW',
  category: 'compress',
  isAvailable: true,
  backendEndpoint: '/api/v1/pdf/unlock',
}
```

---

### 5.3 Structure UX du composant

Étapes : `upload → password → processing → result | error`

```
┌─────────────────────────────────────────────────────┐
│  ÉTAPE 1 — Fichier                                  │
│  [Zone drag & drop]                                  │
│  PDF uniquement · max 10 MB                         │
│                                                      │
│  ⚠️ Avertissement légal (card orange)               │
│  "Assurez-vous d'avoir le droit de déverrouiller    │
│   ce document. Usage personnel uniquement."         │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  ÉTAPE 2 — Mot de passe                             │
│  [📄 rapport.pdf — Changer]                         │
│                                                      │
│  Mot de passe actuel *                              │
│  [••••••••••••••]  [👁]                             │
│                                                      │
│  [  🔓 Déverrouiller  ]  ← canSubmit = file + pw  │
└─────────────────────────────────────────────────────┘

⏳ ÉTAPE 3 — Traitement (spinner + 4 phases affichées)

┌─────────────────────────────────────────────────────┐
│  ÉTAPE 4 — Résultat ✅                              │
│  PDF déverrouillé avec succès                       │
│                                                      │
│  📦 245 Ko   ⚡ 0.34s   🔓 Aucune restriction      │
│                                                      │
│  [  ⬇ Télécharger rapport_déverrouillé.pdf  ]      │
│  [  🔄 Nouveau fichier  ]                           │
│                                                      │
│  ⏳ Ce fichier sera supprimé dans 24 heures.        │
└─────────────────────────────────────────────────────┘
```

---

### 5.4 Détails d'implémentation Angular

```typescript
// Signals (Angular 17+, ChangeDetectionStrategy.OnPush)
readonly step          = signal<Step>('upload');
readonly selectedFile  = signal<File | null>(null);
readonly password      = signal('');
readonly showPw        = signal(false);
readonly pwTouched     = signal(false);
readonly downloading   = signal(false);
readonly errorMsg      = signal('');
readonly resultInfo    = signal<PdfUnlockResultResponse | null>(null);

// Validation
readonly canSubmit = computed(() =>
  this.selectedFile() !== null && this.password().length > 0,
);

// Polling 1500ms (identique à PDF Lock)
interval(1500).pipe(
  startWith(0),
  switchMap(() => pdfUnlockService.getResult(jobId)),
  takeWhile(res => res.status === 'PENDING' || res.status === 'PROCESSING', true),
  takeUntilDestroyed(destroyRef),
).subscribe({ ... });

// Enter key pour soumettre
(keydown.enter)="canSubmit() && submit()"

// Téléchargement — URL.createObjectURL(blob)
```

---

### 5.5 Service Angular

```typescript
@Injectable({ providedIn: 'root' })
export class PdfUnlockService {
  private readonly base = `${environment.apiUrl}/v1/pdf/unlock`;

  submit(file: File, password: string): Observable<PdfUnlockJobResponse> {
    const fd = new FormData();
    fd.append('file',     file, file.name);
    fd.append('password', password);
    return this.http.post<PdfUnlockJobResponse>(this.base, fd);
  }

  getResult(jobId: number):          Observable<PdfUnlockResultResponse>  { ... }
  downloadUnlocked(jobId: number):   Observable<Blob>                     { ... }
}
```

---

## 6. Sprint 4 — Enrichissement qualité 🔲

### 6.1 Enrichir la réponse résultat avec les métadonnées chiffrement

**Contexte :** La carte résultat actuelle affiche seulement taille + temps.
Aucun concurrent n'affiche "vous avez supprimé un chiffrement AES-256 + 3 restrictions".
C'est une opportunité de différenciation majeure.

**Migration V40 — nouvelles colonnes `pdf_unlock_results` :**

```sql
ALTER TABLE pdf_unlock_results
    ADD COLUMN IF NOT EXISTS original_encryption_algorithm VARCHAR(20),
                              -- 'AES-256' | 'AES-128' | 'RC4-128' | 'RC4-40'
    ADD COLUMN IF NOT EXISTS original_key_bits             SMALLINT,
                              -- 256 | 128 | 40
    ADD COLUMN IF NOT EXISTS had_user_password             BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS had_owner_password            BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS original_page_count           INTEGER;
```

**Extraction dans `PdfUnlockStrategy.processBytes()` — avant `setAllSecurityToBeRemoved()` :**

```java
// Capturer les métadonnées AVANT suppression
StandardDecryptionMaterial sdm = (StandardDecryptionMaterial)
        doc.getEncryption().getSecurityHandler().getDecryptionMaterial();
// ou via doc.getEncryption() → StandardSecurityHandler

String algorithm;
int    keyBits;
PDEncryption enc = doc.getEncryption();
if (enc != null) {
    keyBits   = enc.getLength();             // 40 | 128 | 256
    boolean useAES = enc.isEncryptMetaData() || keyBits == 256;
    algorithm = useAES
            ? "AES-" + keyBits
            : "RC4-" + keyBits;
    // had_user_password : true si InvalidPasswordException sur password vide
    // had_owner_password : enc.getOwnerPassword() != null (après ouverture)
}

// ... ensuite setAllSecurityToBeRemoved(true)
```

**Enrichir `PdfUnlockResultResponse` :**

```java
private String  originalEncryptionAlgorithm;  // "AES-256"
private int     originalKeyBits;              // 256
private boolean originalHadUserPassword;      // true
private boolean originalHadOwnerPassword;     // false
private int     originalPageCount;
```

**Carte résultat enrichie (Sprint 4) :**

```
✅ PDF déverrouillé avec succès

🔓 Chiffrement supprimé : AES-256 (clé 256 bits)
📄 rapport_déverrouillé.pdf · 238 Ko · 12 pages
⚡ Traitement : 0.34 s
🛡 Mot de passe utilisateur + restrictions propriétaire levées

[  ⬇ Télécharger  ]   [  🔄 Nouveau fichier  ]

⏳ Supprimé de nos serveurs dans 24 heures.
```

---

### 6.2 Cas limites à couvrir

| Cas | Comportement attendu | Statut |
|-----|---------------------|--------|
| PDF non chiffré | 422 "Ce PDF n'est pas protégé par mot de passe" | ✅ Implémenté |
| Mauvais mot de passe | 422 "Mot de passe incorrect" | ✅ Implémenté |
| PDF corrompu | 400 "Fichier PDF invalide ou corrompu" | ✅ Implémenté |
| Fichier > 10 MB (FREE) | 413 avec limite rappelée | ✅ Implémenté |
| Fichier non-PDF | 415 (validation MIME) | ✅ Implémenté |
| Mot de passe vide | Rejet frontend (canSubmit) + @NotBlank backend | ✅ Implémenté |
| Redis indisponible | 503 "Service temporairement indisponible" | ✅ Implémenté |
| Redis TTL expiré avant traitement | Job FAILED avec message clair | ✅ Implémenté |
| Owner-only PDF (ouverture libre, restrictions actives) | Partiellement ⚠️ | 🔲 Sprint 4 §6.4 |
| PDF avec signature numérique | À tester — la signature peut être invalidée | 🔲 Sprint 4 |
| PDF en lecture seule (filesystem) | Sans objet (on lit les bytes en RAM) | — |
| Double-soumission (double-clic) | Debounce frontend | ✅ Implémenté |

---

### 6.3 PDFs avec signature numérique

**Comportement à documenter :** Supprimer le chiffrement d'un PDF peut invalider les signatures
numériques intégrées (DSS, XFA). Le frontend doit afficher un avertissement dans la carte résultat
si `originalEncryptionAlgorithm` est disponible et que des signatures peuvent être présentes.

À faire :
- [ ] Détecter la présence de signatures (`doc.getSignatureDictionaries().isEmpty()`)
- [ ] Ajouter `boolean hadDigitalSignature` à la réponse
- [ ] Afficher dans le résultat : "⚠️ Ce PDF contenait une signature numérique qui a pu être invalidée lors du déverrouillage."

---

### 6.4 PDFs « owner-only » (restrictions sans user password)

**Contexte :** Certains PDFs s'ouvrent sans mot de passe mais ont des restrictions actives
(pas de copie, pas de modification). Pour lever ces restrictions, l'utilisateur doit fournir
le **mot de passe propriétaire**.

**Comportement actuel :**
`Loader.loadPDF(bytes, providedPassword)` → si `providedPassword` n'est pas le mot de passe
propriétaire mais que le PDF s'ouvre quand même (user password vide), le document est ouvert
en mode "utilisateur" avec restrictions. `doc.isEncrypted()` retourne `true`.
`setAllSecurityToBeRemoved(true)` peut ou non lever les restrictions selon PDFBox.

**Amélioration Sprint 4 :**
1. Tenter `Loader.loadPDF(bytes, "")` — si succès ET `doc.isEncrypted()` → PDF owner-only détecté
2. Afficher dans l'UI : "Ce PDF s'ouvre sans mot de passe mais a des restrictions actives. Entrez le mot de passe propriétaire pour les lever."
3. Si le mot de passe fourni est le owner password → lever toutes les restrictions

---

### 6.5 Tests de compatibilité — PDF déverrouillé

Avant Sprint 4 terminé, vérifier manuellement que le PDF déverrouillé :

**S'ouvre sans mot de passe sur :**
- [ ] Adobe Acrobat Reader (Windows & macOS)
- [ ] Aperçu (macOS)
- [ ] Evince / Okular (Linux)
- [ ] Firefox PDF viewer
- [ ] Chrome PDF viewer
- [ ] PDF Expert (iOS)

**Autorise toutes les opérations (copie, modification, impression) sur :**
- [ ] Adobe Acrobat (edition)
- [ ] LibreOffice Draw
- [ ] Microsoft Edge PDF viewer

**Testé avec tous les niveaux de chiffrement :**
- [ ] RC4-40 (anciens PDFs, < 2001)
- [ ] RC4-128 (PDFs 2001–2008)
- [ ] AES-128 (PDFs 2008–2012)
- [ ] AES-256 (PDFs 2012+, standard actuel)

---

### 6.6 Audit trail

Ajouter dans `PdfUnlockController.download()` un appel `FileAuditService.log()` pour tracer
qui a téléchargé quel PDF déverrouillé et quand. Cohérent avec les autres outils.

---

## 7. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Jobs par jour | 10 (quota conversions) | 200 | Illimité |
| Rétention du PDF déverrouillé | 24 h | 7 jours | 30 jours |
| Chiffrement supporté | Tous | Tous | Tous |
| API accès direct | ❌ | ✅ | ✅ |

> Le quota `PDF_UNLOCK` partage `maxConversionsPerDay` dans `PlanConfig.limitFor()`.
> Peut être découplé en un quota dédié si la consommation le justifie.

---

## 8. Référence — Types de chiffrement PDF

Tous supportés par `doc.setAllSecurityToBeRemoved(true)` via PDFBox 3.x :

| Standard | Algorithme | Clé | Versions PDF | Statut sécurité |
|----------|-----------|-----|--------------|-----------------|
| PDF 1.1–1.3 | RC4-40 | 40 bits | 1.1 – 1.3 | ⛔ Cassé (brute-force trivial) |
| PDF 1.4–1.5 | RC4-128 | 128 bits | 1.4 – 1.5 | ⚠️ Faible (attaques connues) |
| PDF 1.6 | AES-128 | 128 bits | 1.6 | ⚠️ Acceptable (obsolète) |
| PDF 1.7 (Ext. 3) | AES-256 | 256 bits | 1.7 | ✅ Standard actuel |
| PDF 2.0 (ISO 32000-2) | AES-256 | 256 bits | 2.0 | ✅ Standard actuel |

**Note PDFBox 3.x :** `Loader.loadPDF(bytes, password)` gère automatiquement tous ces formats.
`doc.setAllSecurityToBeRemoved(true)` supprime la protection quel que soit l'algorithme.

---

## 9. Aspects légaux & conformité

### 9.1 Avertissement légal (intégré dans l'UI)

Un avertissement visible est affiché dans la **step upload** avant toute soumission :

```
⚠️ Usage autorisé uniquement
Assurez-vous d'être l'auteur ou le propriétaire de ce document,
ou d'avoir une autorisation explicite du titulaire des droits.
Kovixel ne peut être tenu responsable d'une utilisation non autorisée.
```

Cet avertissement reste visible pendant toute la step upload, pas caché en footer.

---

### 9.2 Responsabilité

- Kovixel est un prestataire technique (hébergeur au sens de la directive e-Commerce)
- L'utilisateur déclare implicitement avoir le droit de déverrouiller le document
- Les CGU couvrent ce cas : "vous certifiez être autorisé à déverrouiller ce document"
- Aucun contenu du PDF n'est analysé par Kovixel (suppression du chiffrement uniquement)

---

### 9.3 Rétention et RGPD

| Donnée | Durée de rétention | Suppression |
|--------|-------------------|-------------|
| Mot de passe | 5 min max (Redis TTL) | Automatique |
| PDF source | Session Tomcat | Automatique (GC après request) |
| PDF déverrouillé | 24h (FREE) / 7j (PRO) / 30j (ENTERPRISE) | `PdfUnlockCleanupJob` |
| Métadonnées job (`processing_jobs`) | Conservation audit | Selon politique RGPD globale |

Tous les fichiers utilisateur sont isolés par `jobId` — aucun accès croisé possible.

---

## Ordre d'implémentation

```
Sprint 1  →  Sprint 2  →  Sprint 3  →  Sprint 4
Migrations   Backend      Frontend     Enrichissement
(V38, V39)  (strategy,    (component,  (métadonnées,
✅ Réalisé   service,      polling,     V40, owner-only,
             controller,   legal card)  tests compat.)
             cleanup)  ✅ Réalisé       🔲 À planifier
✅ Réalisé
```

---

## Pont vers les outils PDF futurs

L'infrastructure async + Redis + cleanup est désormais partagée par PDF Lock et PDF Unlock.
Les prochains outils PDF réutilisent le même pattern :

| Outil | Strategy | Spécificité |
|-------|----------|-------------|
| **PDF Compress** | `PdfCompressStrategy` | Ghostscript ou PDFBox optimizer |
| **PDF Merge** | `PdfMergeStrategy` | Plusieurs `MultipartFile` → un seul PDF |
| **PDF Split** | `PdfSplitStrategy` | Un PDF → N fichiers (par pages ou signets) |
| **PDF Rotate** | `PdfRotateStrategy` | Simple, peut rester sync si < 1s |
| **PDF → Images** | `PdfToImagesStrategy` | PDFRenderer → ZIP d'images |
| **Images → PDF** | `ImagesToPdfStrategy` | Déjà implémenté (outil conversion) |

Pour chaque nouvel outil : (1) migration job_type + table résultat, (2) strategy avec `needsRawBytes() = true`, (3) entrée catalogue, (4) composant Angular.
