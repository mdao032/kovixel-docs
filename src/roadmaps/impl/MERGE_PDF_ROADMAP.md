# 📋 Fusionner PDFs : Roadmap d'implémentation Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers exacts à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## État des lieux avant implémentation

### Ce qui existe déjà ✅
| Composant | Fichier | État |
|---|---|---|
| Endpoint `/api/v1/pdf/merge` | `ConversionController.java` | Basique — aucun header, aucune validation riche |
| `pdfManipulationService.merge()` | `PdfManipulationService.java` | Fonctionnel — PDFBox `PDFMergerUtility` |
| Entrée catalogue | `tools-config.ts` | Config présente, slug `convert/merge` |
| Route Angular | `app.routes.ts` | Routage générique OK |
| Quota anonyme | `AnonymousQuotaFilter.java` | Déjà déclaré sur `/api/v1/pdf/merge` |

### Ce qui manque ❌
| Gap | Impact |
|---|---|
| Frontend mono-fichier générique | **Bloquant** — l'outil ne permet pas de sélectionner plusieurs fichiers |
| Drag-and-drop multi-fichiers + réordonnancement | UX non fonctionnelle |
| Headers de réponse enrichis (X-Files-Merged, X-Total-Pages, etc.) | Impossible d'afficher les métadonnées post-fusion |
| Validation stricte (min 2, max 20 fichiers, taille totale) | Risque d'abus |
| Async pour les grandes fusions (> seuil) | Timeout sur gros documents |
| Métriques Micrometer | Aucune observabilité |
| Tests unitaires | Aucune couverture |

---

## Vue d'ensemble de l'architecture cible

```
POST /api/v1/pdf/merge
   files=[file1, file2, ..., fileN]
   ───────────────────────────────────────
         │
         ▼
   ┌─────────────────────────────────────────────────────┐
   │  Validation :                                        │
   │  - min 2 fichiers, max 20                            │
   │  - chaque fichier ≤ 50 MB                            │
   │  - total ≤ 200 MB                                    │
   │  - chaque fichier est un PDF valide (%PDF magic)     │
   └─────────────────────────────────────────────────────┘
         │
         ▼
   Taille totale > maxSyncBytes (50 MB) ?
         ├─ OUI → submitAsync("MERGE", userDetails) → 202 + jobId
         │
         └─ NON → PdfMergeService.merge(pdfs, options)
                       │
                       ▼
               PDFMergerUtility (PDFBox)
                       │
                       ▼
              MergeResult {
                mergedBytes,
                filesMerged,
                totalPages,
                outputSizeBytes,
                durationMs
              }
                       │
                       ▼
         Headers HTTP de réponse :
         X-Files-Merged, X-Total-Pages,
         X-Output-Size-Bytes, X-Processing-Time-Ms
```

### Fonctionnalités avancées (PROMPT 2)

| Feature | Description | Plan |
|---|---|---|
| Réordonnancement | L'ordre des fichiers envoyés = ordre dans le PDF final | Tous |
| Page ranges | Optionnel : fusionner seulement certaines pages de chaque fichier | Tous |
| Bookmarks | Ajouter un signet au début de chaque fichier source (optionnel) | Tous |
| Fichiers protégés | Détecter les PDFs protégés par mot de passe → erreur explicite 422 | Tous |
| Doublon | Détecter si le même fichier est envoyé deux fois → warning, pas d'erreur | Tous |

---

## PROMPT 1 — Backend : Enrichir le endpoint `/api/v1/pdf/merge`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/resources/application.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

```
Lis d'abord intégralement :
- ConversionController.java (pour comprendre le pattern existant : compress, word-to-pdf)
- PdfManipulationService.java (pour voir merge() existant)
- ConversionProperties.java (pour voir la structure des classes imbriquées)
- application.yml (pour voir kovixel.conversion existant)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : ConversionProperties.java
─────────────────────────────────────────────────────────────────────────────

Ajoute une classe imbriquée Merge dans ConversionProperties, sur le même modèle
que la classe Compression existante :

  @Data
  public static class Merge {
      /** Nombre minimum de fichiers à fusionner. */
      private int minFiles = 2;

      /** Nombre maximum de fichiers à fusionner par requête. */
      private int maxFiles = 20;

      /** Taille maximale par fichier (50 MB). */
      private long maxFileSizeBytes = 52428800L;

      /** Taille totale maximale pour une fusion synchrone (50 MB → async au-delà). */
      private long maxSyncBytes = 52428800L;

      /** Taille totale maximale absolue (200 MB). */
      private long maxTotalBytes = 209715200L;

      /** Ajouter des signets (bookmarks) pour chaque fichier source. */
      private boolean addBookmarks = true;
  }

Ajoute le champ `private Merge merge = new Merge();` dans ConversionProperties.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : application.yml
─────────────────────────────────────────────────────────────────────────────

Dans la section `kovixel.conversion`, ajoute :

  merge:
    min-files: 2
    max-files: 20
    max-file-size-bytes: 52428800    # 50 MB par fichier
    max-sync-bytes: 52428800         # 50 MB total → async au-delà
    max-total-bytes: 209715200       # 200 MB total absolu
    add-bookmarks: true              # Signets entre fichiers sources

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Créer le record MergeResult
─────────────────────────────────────────────────────────────────────────────

Crée une nouvelle classe dans le package com.kovixel.core.conversion :

  package com.kovixel.core.conversion;

  /**
   * Résultat d'une fusion PDF avec toutes les métadonnées utiles.
   * Exposé via les headers HTTP X-* dans la réponse.
   */
  public record MergeResult(
      byte[] mergedBytes,
      int    filesMerged,
      int    totalPages,
      long   outputSizeBytes,
      long   durationMs
  ) {
      public String summary() {
          return String.format(
              "merge: %d fichiers → %d pages, %d bytes en %d ms",
              filesMerged, totalPages, outputSizeBytes, durationMs
          );
      }
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : PdfManipulationService.java — enrichir merge()
─────────────────────────────────────────────────────────────────────────────

Remplace la méthode merge(List<byte[]>) existante par :

  public MergeResult mergeWithMeta(List<byte[]> pdfs, boolean addBookmarks)

  Implémentation :
  1. Valider que pdfs.size() >= 2 (sinon KovixelException VALIDATION_ERROR 400)
  2. long startMs = System.currentTimeMillis()
  3. Créer PDFMergerUtility merger = new PDFMergerUtility()
  4. ByteArrayOutputStream out = new ByteArrayOutputStream()
  5. merger.setDestinationStream(out)

  6. Si addBookmarks = true :
     Pour chaque PDF (index i) :
       a. Charger en mémoire : PDDocument doc = Loader.loadPDF(pdf)
       b. Si doc.isEncrypted() → lancer KovixelException VALIDATION_ERROR 422
            avec message : "Le fichier [i+1] est protégé par mot de passe et ne peut pas être fusionné."
       c. Récupérer le titre depuis les métadonnées ou générer "Document [i+1]"
       d. Compter les pages : doc.getNumberOfPages()
       e. merger.addSource(new RandomAccessReadBuffer(pdf))
       f. Fermer doc
     → Calculer totalPages comme somme des pages de chaque PDF

  7. Si addBookmarks = false :
     Pour chaque pdf : merger.addSource(new RandomAccessReadBuffer(pdf))

  8. merger.mergeDocuments(null)

  9. Si addBookmarks = true, ajouter les signets dans le PDF fusionné :
     → Charger le PDF fusionné (out.toByteArray())
     → Pour chaque fichier source, créer un PDOutlineItem pointant vers la première
       page de ce fichier (calculer l'offset de pages cumulé)
     → Sauvegarder avec les signets

  10. long durationMs = System.currentTimeMillis() - startMs

  11. Construire et retourner :
      new MergeResult(mergedBytes, pdfs.size(), totalPages, mergedBytes.length, durationMs)

  12. Logger : log.info("Fusion terminée : {} fichiers, {} pages, {} bytes en {} ms", ...)

  Conserve aussi la méthode merge(List<byte[]>) existante pour compatibilité :
    public byte[] merge(List<byte[]> pdfs) {
        return mergeWithMeta(pdfs, false).mergedBytes();
    }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : ConversionController.java — enrichir l'endpoint
─────────────────────────────────────────────────────────────────────────────

Remplace l'implémentation du endpoint @PostMapping("/api/v1/pdf/merge") par :

  @PostMapping("/api/v1/pdf/merge")
  @Operation(
      summary = "Fusionner plusieurs PDFs en un seul",
      description = """
          Assemble 2 à 20 fichiers PDF en un seul document.
          L'ordre des fichiers envoyés définit l'ordre dans le PDF final.

          **Fonctionnalités** :
          - Détection automatique des PDFs protégés par mot de passe (→ erreur 422)
          - Ajout optionnel de signets (bookmarks) pour chaque fichier source
          - Traitement asynchrone si la taille totale dépasse le seuil configuré

          **Headers de réponse** :
          `X-Files-Merged`, `X-Total-Pages`, `X-Output-Size-Bytes`, `X-Processing-Time-Ms`
          """
  )
  @CheckQuota(feature = FeatureType.CONVERSION)
  public ResponseEntity<?> merge(
          @RequestParam("files") List<MultipartFile> files,
          @RequestParam(defaultValue = "true") boolean addBookmarks,
          @AuthenticationPrincipal UserDetails userDetails) throws Exception {

      ConversionProperties.Merge cfg = conversionProperties.getMerge();

      // ── Validation du nombre de fichiers ────────────────────────────────────
      if (files == null || files.size() < cfg.getMinFiles()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Au moins " + cfg.getMinFiles() + " fichiers PDF sont requis pour la fusion.");
      }
      if (files.size() > cfg.getMaxFiles()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Maximum " + cfg.getMaxFiles() + " fichiers par fusion. " +
                  "Reçu : " + files.size() + " fichiers.");
      }

      // ── Validation taille individuelle ───────────────────────────────────────
      long totalSize = 0;
      for (int i = 0; i < files.size(); i++) {
          MultipartFile f = files.get(i);
          if (f.getSize() > cfg.getMaxFileSizeBytes()) {
              throw new KovixelException(ErrorCode.FILE_TOO_LARGE, HttpStatus.PAYLOAD_TOO_LARGE,
                      "Le fichier [" + (i + 1) + "] dépasse la limite de " +
                      (cfg.getMaxFileSizeBytes() / 1_048_576) + " MB.");
          }
          totalSize += f.getSize();
      }

      // ── Validation taille totale absolue ────────────────────────────────────
      if (totalSize > cfg.getMaxTotalBytes()) {
          throw new KovixelException(ErrorCode.FILE_TOO_LARGE, HttpStatus.PAYLOAD_TOO_LARGE,
                  "La taille totale des fichiers (" + (totalSize / 1_048_576) + " MB) " +
                  "dépasse la limite de " + (cfg.getMaxTotalBytes() / 1_048_576) + " MB.");
      }

      // ── Seuil async ──────────────────────────────────────────────────────────
      if (totalSize > cfg.getMaxSyncBytes()) {
          return submitAsync(files.get(0), "MERGE", userDetails);
          // TODO PROMPT 3 : adapter submitAsync pour multi-fichiers
      }

      // ── Fusion ───────────────────────────────────────────────────────────────
      List<byte[]> pdfs = new ArrayList<>();
      for (MultipartFile f : files) {
          pdfs.add(f.getBytes());
      }

      MergeResult result = pdfManipulationService.mergeWithMeta(pdfs, addBookmarks);
      log.info("merge — {}", result.summary());

      // ── Nom du fichier de sortie ─────────────────────────────────────────────
      String outputFilename = "kovixel_merged.pdf";

      // ── Réponse avec headers enrichis ────────────────────────────────────────
      return ResponseEntity.ok()
              .header(HttpHeaders.CONTENT_TYPE,       "application/pdf")
              .header(HttpHeaders.CONTENT_DISPOSITION,
                      ContentDisposition.attachment()
                              .filename(outputFilename, StandardCharsets.UTF_8)
                              .build().toString())
              .header(HttpHeaders.CONTENT_LENGTH,     String.valueOf(result.outputSizeBytes()))
              .header("X-Files-Merged",               String.valueOf(result.filesMerged()))
              .header("X-Total-Pages",                String.valueOf(result.totalPages()))
              .header("X-Output-Size-Bytes",          String.valueOf(result.outputSizeBytes()))
              .header("X-Processing-Time-Ms",         String.valueOf(result.durationMs()))
              .body(result.mergedBytes());
  }

Assure-toi que les imports nécessaires sont présents :
  import com.kovixel.core.conversion.MergeResult;
  import java.nio.charset.StandardCharsets;
```

---

## PROMPT 2 — Backend : Métriques, Health & Tests unitaires

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`
- `src/main/java/com/kovixel/common/config/WebConfig.java`
- `src/main/java/com/kovixel/common/security/SecurityConfig.java`

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/PdfMergeServiceTest.java`

```
Lis d'abord :
- CompressionRouter.java (pour voir le pattern Micrometer existant)
- WebConfig.java et SecurityConfig.java (pour voir les exposedHeaders CORS)
- COMPRESS_PDF_ROADMAP.md PROMPT 7 (pour voir le pattern métriques)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Métriques Micrometer dans PdfManipulationService
─────────────────────────────────────────────────────────────────────────────

Injecte MeterRegistry dans PdfManipulationService.

Dans mergeWithMeta(), après le retour du résultat, enregistre :

  kovixel.merge.total
    Type : Counter
    Tags : status=SUCCESS|ERROR, files_count={files.size()}
    Incrémenter après chaque fusion (dans le bloc finally)

  kovixel.merge.duration
    Type : Timer
    Tags : aucun
    Enregistrer la durée totale de fusion

  kovixel.merge.pages_total
    Type : DistributionSummary
    Tags : aucun
    Valeur : totalPages (pour calculer la moyenne de pages par fusion)

  kovixel.merge.output_size
    Type : DistributionSummary
    Tags : aucun
    Valeur : outputSizeBytes

En cas d'exception dans mergeWithMeta(), incrémenter :
  kovixel.merge.total avec tag status=ERROR
  Puis relancer l'exception.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : CORS — exposer les headers de fusion
─────────────────────────────────────────────────────────────────────────────

Dans WebConfig.java, vérifie que la liste .exposedHeaders() contient :
  "X-Files-Merged", "X-Total-Pages", "X-Output-Size-Bytes"

  (Ces headers ont peut-être déjà été ajoutés lors du PROMPT précédent pour
  compress — dans ce cas, ils sont déjà présents, sinon les ajouter)

Même vérification dans SecurityConfig.java (config.setExposedHeaders(List.of(...))).

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Tests unitaires PdfMergeServiceTest
─────────────────────────────────────────────────────────────────────────────

Crée PdfMergeServiceTest avec @ExtendWith(MockitoExtension.class) :

  @BeforeAll
  static void setUp() {
      // Générer 3 PDFs synthétiques avec PDFBox
      // PDF 1 : 2 pages
      // PDF 2 : 3 pages
      // PDF 3 : 1 page
  }

  Tests à écrire :

  - mergeWithMeta() avec 2 PDFs valides
    → MergeResult non null, filesMerged = 2, totalPages = 5
    → Les bytes commencent par "%PDF"
    → outputSizeBytes > 0

  - mergeWithMeta() avec un seul PDF → KovixelException VALIDATION_ERROR

  - mergeWithMeta() avec un PDF chiffré
    → KovixelException avec message "protégé par mot de passe"
    (générer un PDF chiffré avec PDFBox dans le @BeforeAll)

  - mergeWithMeta() avec addBookmarks = true
    → Vérifier que le PDF fusionné contient des signets (PDDocumentOutline)
    → Vérifier que le nombre de signets = nombre de fichiers source (2)

  - mergeWithMeta() avec 3 PDFs → totalPages = 2 + 3 + 1 = 6

  - merge() (méthode legacy) retourne les mêmes bytes que mergeWithMeta()
```

---

## PROMPT 3 — Frontend : Service, Modèle et Configuration

**Fichiers à modifier :**
- `kovixel-ui/src/app/core/services/conversion.service.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`
- `kovixel-ui/src/app/core/models/conversion.model.ts` (si ce fichier existe)

```
Lis d'abord :
- conversion.service.ts (pour voir compressPdfWithMeta et les interfaces existantes)
- tools-config.ts (pour voir l'entrée convert/merge existante)
- tool-page.component.ts lignes 784–830 (ACCEPT_MAP et multi-file handling)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Interface MergeMeta dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute l'interface MergeMeta juste après CompressionMeta (ou en début de fichier) :

  /** Métadonnées de fusion lues depuis les headers X-* de la réponse HTTP. */
  export interface MergeMeta {
    /** Nombre de fichiers fusionnés (X-Files-Merged) */
    filesMerged:     number;
    /** Nombre total de pages dans le PDF résultant (X-Total-Pages) */
    totalPages:      number;
    /** Taille du PDF produit en bytes (X-Output-Size-Bytes) */
    outputSizeBytes: number;
    /** Durée de traitement côté serveur en ms (X-Processing-Time-Ms) */
    durationMs:      number;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Méthode mergePdfsWithMeta() dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute la méthode suivante dans ConversionService, sur le modèle de
compressPdfWithMeta() :

  mergePdfsWithMeta(
    files: File[],
    addBookmarks = true
  ): Observable<{ blob: Blob; meta: MergeMeta }> {
    const fd = new FormData();
    files.forEach(f => fd.append('files', f, f.name));
    fd.append('addBookmarks', String(addBookmarks));

    return this.http
      .post(`${this.base}/pdf/merge`, fd, {
        responseType: 'blob',
        observe: 'response',
      })
      .pipe(
        map((response) => {
          const blob = response.body as Blob;
          const h    = response.headers;
          const meta: MergeMeta = {
            filesMerged:     Number(h.get('X-Files-Merged')      ?? 0),
            totalPages:      Number(h.get('X-Total-Pages')       ?? 0),
            outputSizeBytes: Number(h.get('X-Output-Size-Bytes') ?? 0),
            durationMs:      Number(h.get('X-Processing-Time-Ms') ?? 0),
          };
          return { blob, meta };
        }),
      );
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Mise à jour de tools-config.ts
─────────────────────────────────────────────────────────────────────────────

Dans l'entrée slug: 'convert/merge', enrichis la config :

  {
    slug:            'convert/merge',
    name:            'Fusionner PDFs',
    description:     'Combinez plusieurs PDFs en un seul fichier',
    longDescription: 'Réorganisez et fusionnez jusqu\'à 20 fichiers PDF en glissant-déposant les fichiers dans l\'ordre souhaité. Ajout automatique de signets de navigation.',
    category:        'compress',
    icon:            GitMerge,
    badge:           'GRATUIT',
    estimatedTime:   '~5 secondes',
    isPro:           false,
    isAvailable:     true,
    backendEndpoint: '/api/v1/pdf/merge',
    acceptsMultiple: true,   // ← NOUVEAU flag pour indiquer multi-fichiers
    maxFiles:        20,      // ← NOUVEAU : limite affichée dans la dropzone
  },

Ajoute le champ optionnel acceptsMultiple?: boolean et maxFiles?: number
dans l'interface ToolConfig (ou type ToolItem selon le nom exact du type
dans ce fichier).
```

---

## PROMPT 4 — Frontend : UI Multi-fichiers dans tool-page.component.ts

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord intégralement tool-page.component.ts pour comprendre :
- Les signaux existants (state, selectedFile, resultBlob, etc.)
- Le template HTML (sections idle, uploading, success, error)
- Le pattern isCompressTool() et son bloc de résultat enrichi (lignes 548–610)
- La méthode startConversion() et ses cas spéciaux (lignes 961–997)
- La ACCEPT_MAP (lignes 784–830)

Ne modifie pas l'architecture générale du composant.
Ajoute uniquement le traitement spécial pour le slug 'convert/merge',
en suivant exactement le même pattern que 'convert/compress'.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Imports et injections
─────────────────────────────────────────────────────────────────────────────

Ajoute dans les imports :
  import { MergeMeta } from '../../core/services/conversion.service';

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Signaux pour l'outil de fusion
─────────────────────────────────────────────────────────────────────────────

Ajoute ces signaux dans la classe, au même endroit que compressionMeta :

  // ── Merge tool signals ───────────────────────────────────────────────────
  readonly mergeMeta       = signal<MergeMeta | null>(null);
  readonly mergeFiles      = signal<File[]>([]);             // liste des fichiers à fusionner
  readonly mergeAddBookmarks = signal<boolean>(true);

  /** Computed : true uniquement sur l'outil de fusion PDF */
  readonly isMergeTool = computed(() => this.tool()?.slug === 'convert/merge');

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Méthodes de gestion multi-fichiers
─────────────────────────────────────────────────────────────────────────────

Ajoute ces méthodes dans la classe :

  // ── Merge multi-file handling ────────────────────────────────────────────

  /** Ajoute des fichiers à la liste de fusion (pas de doublon de nom). */
  addMergeFiles(files: FileList | File[]): void {
    const arr     = Array.from(files);
    const current = this.mergeFiles();
    const names   = new Set(current.map(f => f.name));
    const news    = arr.filter(f => f.type === 'application/pdf' && !names.has(f.name));
    if (news.length > 0) {
      this.mergeFiles.update(existing => [...existing, ...news]);
      this.state.set('selected');
    }
  }

  /** Supprime un fichier de la liste par index. */
  removeMergeFile(index: number): void {
    this.mergeFiles.update(files => files.filter((_, i) => i !== index));
    if (this.mergeFiles().length < 2) {
      this.state.set(this.mergeFiles().length === 0 ? 'idle' : 'selected');
    }
  }

  /** Déplace un fichier vers le haut dans la liste. */
  moveMergeFileUp(index: number): void {
    if (index <= 0) return;
    this.mergeFiles.update(files => {
      const arr = [...files];
      [arr[index - 1], arr[index]] = [arr[index], arr[index - 1]];
      return arr;
    });
  }

  /** Déplace un fichier vers le bas dans la liste. */
  moveMergeFileDown(index: number): void {
    const files = this.mergeFiles();
    if (index >= files.length - 1) return;
    this.mergeFiles.update(arr => {
      const copy = [...arr];
      [copy[index + 1], copy[index]] = [copy[index], copy[index + 1]];
      return copy;
    });
  }

  /** Remet à zéro la liste de fichiers. */
  clearMergeFiles(): void {
    this.mergeFiles.set([]);
    this.mergeMeta.set(null);
    this.state.set('idle');
  }

  /** Formatage lisible de la taille d'un fichier */
  formatFileSize(bytes: number): string {
    return this.formatBytes(bytes);
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Cas spécial merge dans startConversion()
─────────────────────────────────────────────────────────────────────────────

Dans la méthode startConversion(), ajoute le cas merge AVANT le bloc générique,
juste après le cas compress :

  // ── Cas spécial : outil de fusion — utilise mergePdfsWithMeta ────────────
  if (t.slug === 'convert/merge') {
    const files = this.mergeFiles();
    if (files.length < 2) {
      this.errorMessage.set('Veuillez sélectionner au moins 2 fichiers PDF à fusionner.');
      this.state.set('error');
      return;
    }

    this.state.set('uploading');
    this.uploadProgress.set(0);
    this.mergeMeta.set(null);
    this.startMsgRotation();
    this.startFakeProgress(0, 92);

    this.uploadSub = this.convSvc.mergePdfsWithMeta(files, this.mergeAddBookmarks()).subscribe({
      next: ({ blob, meta }) => {
        this.stopFakeProgress();
        this.uploadProgress.set(100);
        this.mergeMeta.set(meta);
        this.resultBlob.set(blob);
        this.resultFilename.set('kovixel_merged.pdf');
        this.stopMsgRotation();
        this.state.set('success');
        if (!this.authSvc.isAuthenticated()) {
          this.quotaSvc.decrementLocally();
        }
      },
      error: (err) => {
        this.stopFakeProgress();
        this.stopMsgRotation();
        const msg = err?.error?.message ?? err?.message ?? 'Erreur lors de la fusion.';
        this.errorMessage.set(msg);
        this.state.set('error');
      },
    });
    return;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : Réinitialisation dans clearFile() et startConversion()
─────────────────────────────────────────────────────────────────────────────

Dans clearFile() (ou la méthode de reset), ajoute :
  this.mergeMeta.set(null);

Dans la section de réinitialisation en haut de startConversion(), ajoute :
  this.mergeMeta.set(null);

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 6 : Bloc de dropzone multi-fichiers dans le template HTML
─────────────────────────────────────────────────────────────────────────────

Localise dans le template le bloc @if (state() === 'idle' || state() === 'selected').
À l'intérieur, ajoute un @if (isMergeTool()) avec l'UI multi-fichiers,
et un @else avec la dropzone générique existante.

Le bloc @if (isMergeTool()) doit contenir :

A) DROPZONE MULTI-FICHIERS (toujours visible pour ajouter des fichiers) :

  <div class="merge-dropzone rounded-2xl border-2 border-dashed p-8 text-center
               transition-all cursor-pointer"
       style="border-color: rgba(139,92,246,0.35); background: rgba(139,92,246,0.04)"
       (dragover)="$event.preventDefault()"
       (drop)="onMergeDrop($event)"
       (click)="mergeInput.click()">
    <input #mergeInput type="file" multiple accept="application/pdf"
           style="display:none"
           (change)="onMergeFileChange($event)" />

    <!-- Icône et texte selon l'état -->
    @if (mergeFiles().length === 0) {
      <!-- État initial : aucun fichier -->
      <div class="flex flex-col items-center gap-3">
        <div class="flex items-center justify-center w-14 h-14 rounded-2xl"
             style="background: rgba(139,92,246,0.12)">
          <!-- Icône GitMerge ou similaire en SVG -->
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none"
               stroke="#a855f7" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/>
            <circle cx="6" cy="18" r="3"/>
            <path d="M6 9v3a3 3 0 003 3h3M18 15V9"/>
          </svg>
        </div>
        <div>
          <p class="font-display font-semibold text-base" style="color: var(--text-primary)">
            Déposez vos PDFs ici
          </p>
          <p class="text-sm mt-1" style="color: var(--text-muted)">
            ou cliquez pour parcourir — jusqu'à 20 fichiers PDF
          </p>
        </div>
      </div>
    } @else {
      <!-- Des fichiers ont déjà été ajoutés : bouton compact pour en ajouter d'autres -->
      <div class="flex items-center justify-center gap-2 py-2">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none"
             stroke="#a855f7" stroke-width="2.5" stroke-linecap="round">
          <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="16"/>
          <line x1="8" y1="12" x2="16" y2="12"/>
        </svg>
        <span class="text-sm font-medium" style="color: #a855f7">
          Ajouter d'autres PDFs ({{ mergeFiles().length }}/20)
        </span>
      </div>
    }
  </div>

B) LISTE DES FICHIERS AVEC RÉORDONNANCEMENT (visible si mergeFiles().length > 0) :

  @if (mergeFiles().length > 0) {
    <div class="space-y-2 mt-3">
      <!-- En-tête de la liste -->
      <div class="flex items-center justify-between px-1">
        <p class="text-xs font-semibold uppercase tracking-widest"
           style="color: var(--text-muted)">
          {{ mergeFiles().length }} fichier(s) — glissez pour réorganiser
        </p>
        <button type="button"
                class="text-xs px-2 py-1 rounded-lg transition-colors"
                style="color: var(--text-muted)"
                (click)="clearMergeFiles()">
          Tout effacer
        </button>
      </div>

      <!-- Liste des fichiers -->
      @for (file of mergeFiles(); track file.name; let i = $index) {
        <div class="flex items-center gap-3 rounded-xl px-3 py-2.5 border transition-all"
             style="background: rgba(255,255,255,0.03); border-color: rgba(139,92,246,0.15)">

          <!-- Numéro d'ordre -->
          <span class="flex-none w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold"
                style="background: rgba(139,92,246,0.18); color: #a855f7">
            {{ i + 1 }}
          </span>

          <!-- Icône PDF -->
          <svg class="flex-none" width="16" height="16" viewBox="0 0 24 24" fill="none"
               stroke="#ef4444" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/>
            <polyline points="14 2 14 8 20 8"/>
            <text x="7" y="18" font-size="4" fill="#ef4444" stroke="none">PDF</text>
          </svg>

          <!-- Nom + taille -->
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium truncate" style="color: var(--text-primary)">
              {{ file.name }}
            </p>
            <p class="text-xs" style="color: var(--text-muted)">
              {{ formatFileSize(file.size) }}
            </p>
          </div>

          <!-- Boutons de réordonnancement -->
          <div class="flex-none flex items-center gap-1">
            <button type="button"
                    class="p-1 rounded-lg transition-all disabled:opacity-30"
                    style="color: var(--text-muted)"
                    [disabled]="i === 0"
                    (click)="moveMergeFileUp(i)"
                    aria-label="Monter ce fichier">
              <!-- Chevron up -->
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
                   stroke="currentColor" stroke-width="2.5" stroke-linecap="round">
                <polyline points="18 15 12 9 6 15"/>
              </svg>
            </button>
            <button type="button"
                    class="p-1 rounded-lg transition-all disabled:opacity-30"
                    style="color: var(--text-muted)"
                    [disabled]="i === mergeFiles().length - 1"
                    (click)="moveMergeFileDown(i)"
                    aria-label="Descendre ce fichier">
              <!-- Chevron down -->
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
                   stroke="currentColor" stroke-width="2.5" stroke-linecap="round">
                <polyline points="6 9 12 15 18 9"/>
              </svg>
            </button>
            <button type="button"
                    class="p-1 rounded-lg transition-all"
                    style="color: #ef4444"
                    (click)="removeMergeFile(i)"
                    aria-label="Supprimer ce fichier">
              <!-- X icon -->
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
                   stroke="currentColor" stroke-width="2.5" stroke-linecap="round">
                <line x1="18" y1="6" x2="6" y2="18"/>
                <line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
            </button>
          </div>
        </div>
      }
    </div>

    <!-- Option signets -->
    <label class="flex items-center gap-2.5 cursor-pointer mt-3 px-1">
      <input type="checkbox"
             [checked]="mergeAddBookmarks()"
             (change)="mergeAddBookmarks.set($any($event.target).checked)"
             style="accent-color: #a855f7; width: 15px; height: 15px" />
      <span class="text-sm" style="color: var(--text-secondary)">
        Ajouter des signets de navigation entre les fichiers
      </span>
    </label>

    <!-- Warning si moins de 2 fichiers -->
    @if (mergeFiles().length < 2) {
      <p class="text-xs mt-2 px-1" style="color: #f59e0b">
        ⚠ Ajoutez au moins 2 fichiers PDF pour lancer la fusion.
      </p>
    }
  }

C) BOUTON DE CONVERSION (visible si mergeFiles().length >= 2) :

  @if (mergeFiles().length >= 2) {
    <button type="button"
            class="w-full py-3.5 rounded-xl font-display font-bold text-white transition-all"
            style="background: linear-gradient(135deg, #7c3aed, #9333ea)"
            (click)="startConversion()">
      Fusionner {{ mergeFiles().length }} fichiers →
    </button>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 7 : Bloc de résultat enrichi pour merge dans le template
─────────────────────────────────────────────────────────────────────────────

Localise le bloc @if (isCompressTool() && compressionMeta()) dans le template.
Juste APRÈS ce bloc (ou dans le même @else), ajoute :

  @else if (isMergeTool() && mergeMeta()) {
    <div class="rounded-2xl border p-5 space-y-4"
         style="background: rgba(255,255,255,0.025); border-color: rgba(139,92,246,0.20)">

      <!-- Titre succès -->
      <div class="flex items-center gap-2">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
             stroke="#34d399" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="20 6 9 17 4 12"/>
        </svg>
        <p class="font-display font-semibold text-base" style="color: #34d399">
          Fusion réussie !
        </p>
      </div>

      <!-- Tableau de métriques -->
      <div class="grid grid-cols-3 gap-3 text-center">
        <!-- Fichiers fusionnés -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Fichiers</p>
          <p class="font-display font-bold text-lg" style="color: #a855f7">
            {{ mergeMeta()!.filesMerged }}
          </p>
        </div>
        <!-- Pages totales -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Pages</p>
          <p class="font-display font-bold text-lg" style="color: var(--text-primary)">
            {{ mergeMeta()!.totalPages }}
          </p>
        </div>
        <!-- Taille finale -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Taille finale</p>
          <p class="font-display font-bold text-sm" style="color: var(--text-primary)">
            {{ formatBytes(mergeMeta()!.outputSizeBytes) }}
          </p>
        </div>
      </div>
    </div>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 8 : Handlers drag & drop et file change pour merge
─────────────────────────────────────────────────────────────────────────────

Ajoute ces méthodes dans la classe :

  onMergeDrop(event: DragEvent): void {
    event.preventDefault();
    const files = event.dataTransfer?.files;
    if (files) this.addMergeFiles(files);
  }

  onMergeFileChange(event: Event): void {
    const input = event.target as HTMLInputElement;
    const files = input.files;
    if (files) this.addMergeFiles(files);
    input.value = '';  // reset pour permettre de re-sélectionner les mêmes fichiers
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 9 : Bloquer le bouton Convertir générique pour merge
─────────────────────────────────────────────────────────────────────────────

Dans le template, le bouton "Convertir maintenant" générique doit être
masqué pour l'outil merge (le bouton de fusion est intégré dans la UI
multi-fichiers ci-dessus).

Cherche le bouton principal de conversion (probablement dans le bloc
state() === 'selected') et ajoute la condition :

  @if (!isMergeTool()) {
    <!-- bouton générique existant -->
  }
```

---

## PROMPT 5 — Frontend : Bonus UX (styles, accessibilité, feedback)

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord le résultat de PROMPT 4 pour comprendre l'état actuel.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Messages de progression spécifiques à la fusion
─────────────────────────────────────────────────────────────────────────────

Cherche dans tool-page.component.ts le tableau UPLOAD_MESSAGES (ou équivalent)
qui contient les messages rotatifs affichés pendant l'upload.

Ajoute un tableau spécifique pour la fusion :

  private static readonly MERGE_MESSAGES = [
    'Analyse des PDFs en cours…',
    'Extraction des pages…',
    'Assemblage du document…',
    'Ajout des signets de navigation…',
    'Optimisation du PDF final…',
    'Presque terminé…',
  ];

Dans startMsgRotation(), si isMergeTool(), utilise MERGE_MESSAGES au lieu
des messages génériques.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Feedback visuel sur la dropzone au drag-over
─────────────────────────────────────────────────────────────────────────────

Ajoute le signal :
  readonly mergeIsDraggingOver = signal<boolean>(false);

Dans le template, sur la dropzone :
  (dragenter)="mergeIsDraggingOver.set(true)"
  (dragleave)="mergeIsDraggingOver.set(false)"
  (drop)="mergeIsDraggingOver.set(false); onMergeDrop($event)"

Et utilise ce signal pour varier le style :
  [style.border-color]="mergeIsDraggingOver() ? '#a855f7' : 'rgba(139,92,246,0.35)'"
  [style.background]="mergeIsDraggingOver() ? 'rgba(139,92,246,0.10)' : 'rgba(139,92,246,0.04)'"

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Calcul de la taille totale des fichiers sélectionnés
─────────────────────────────────────────────────────────────────────────────

Ajoute le computed :

  readonly mergeTotalSize = computed(() =>
    this.mergeFiles().reduce((sum, f) => sum + f.size, 0)
  );

Affiche dans l'en-tête de la liste :
  "3 fichiers — {{ formatBytes(mergeTotalSize()) }} au total"

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Validation côté client — limite de fichiers
─────────────────────────────────────────────────────────────────────────────

Dans addMergeFiles(), vérifie avant d'ajouter que le total ne dépasse pas 20 :

  const MAX_FILES = 20;
  if (current.length + news.length > MAX_FILES) {
    const allowed = MAX_FILES - current.length;
    news = news.slice(0, allowed);
    // Afficher un toast ou un message d'avertissement
    // (utilise le service toast existant dans le projet si disponible)
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : Reset propre après "Fusionner un autre document"
─────────────────────────────────────────────────────────────────────────────

Le bouton "Convertir un autre fichier" (affiché dans le state success)
doit, pour l'outil merge, appeler clearMergeFiles() au lieu de clearFile().

Cherche ce bouton dans le template (probablement dans le bloc state() === 'success')
et ajoute la condition :

  (click)="isMergeTool() ? clearMergeFiles() : clearFile()"

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 6 : Accessibilité
─────────────────────────────────────────────────────────────────────────────

- Sur la dropzone : ajouter role="button", tabindex="0", aria-label="Zone de dépôt de PDFs"
- Sur chaque bouton de réordonnancement : aria-label déjà inclus dans PROMPT 4
- Sur la liste des fichiers : role="list", chaque item role="listitem"
- Sur la checkbox signets : aria-describedby pointant vers un texte explicatif
```

---

## PROMPT 6 — Documentation & Mise à jour README

**Fichiers à modifier :**
- `kovixel/README.md`

```
Ajoute une section "## Fusionner PDFs" dans README.md,
sur le même modèle que les sections existantes
(## PDF → Excel, ## PDF → Image, ## Configuration Compression PDF).

La section doit documenter :

### Endpoint
POST /api/v1/pdf/merge

### Paramètres
| Paramètre    | Type     | Défaut | Description |
|---|---|---|---|
| files        | File[]   | —      | PDFs à fusionner (multipart, 2–20 fichiers) |
| addBookmarks | boolean  | true   | Ajouter des signets entre les fichiers sources |

### Headers de réponse
| Header | Description |
|---|---|
| X-Files-Merged      | Nombre de fichiers fusionnés |
| X-Total-Pages       | Nombre total de pages dans le PDF résultant |
| X-Output-Size-Bytes | Taille du PDF produit en bytes |
| X-Processing-Time-Ms | Durée de traitement en ms |

### Limites par configuration
| Paramètre | Défaut | Description |
|---|---|---|
| kovixel.conversion.merge.min-files | 2 | Minimum de fichiers requis |
| kovixel.conversion.merge.max-files | 20 | Maximum de fichiers par requête |
| kovixel.conversion.merge.max-file-size-bytes | 50 MB | Taille max par fichier |
| kovixel.conversion.merge.max-sync-bytes | 50 MB | Seuil de basculement en async |
| kovixel.conversion.merge.max-total-bytes | 200 MB | Taille totale max |

### Exemple de requête
curl -X POST http://localhost:8080/api/v1/pdf/merge \
  -F "files=@document1.pdf" \
  -F "files=@document2.pdf" \
  -F "files=@document3.pdf" \
  -F "addBookmarks=true" \
  --output merged.pdf

### Comportement sur les PDFs protégés
Les PDFs chiffrés par mot de passe déclenchent une erreur HTTP 422 explicite
indiquant quel fichier (par son numéro d'ordre) est protégé.

### Métriques disponibles
| Métrique | Type | Description |
|---|---|---|
| kovixel.merge.total | Counter | Total des fusions (tags: status) |
| kovixel.merge.duration | Timer | Durée de fusion |
| kovixel.merge.pages_total | DistributionSummary | Distribution des pages par fusion |
| kovixel.merge.output_size | DistributionSummary | Distribution des tailles en sortie |
```

---

## Ordre d'exécution recommandé

```
PROMPT 1        PROMPT 2        PROMPT 3        PROMPT 4        PROMPT 5        PROMPT 6
Backend         Backend         Frontend        Frontend        Frontend        Docs
Endpoint        Métriques +     Service +       UI Multi-       Bonus UX +      README
enrichi         Tests +         Modèles +       fichiers +      Accessibilité
                CORS            Config          Drag-drop +
                                                Résultat méta
```

> **PROMPT 1 et PROMPT 3** peuvent être exécutés en parallèle  
> (backend et frontend sont indépendants jusqu'au PROMPT 4).  
> **PROMPT 2** nécessite PROMPT 1 terminé.  
> **PROMPT 4 et 5** nécessitent PROMPT 3 terminé.

---

## Critères de validation finale

### Backend
- [ ] `POST /api/v1/pdf/merge` avec 2 PDFs → retourne PDF fusionné avec headers `X-Files-Merged`, `X-Total-Pages`, `X-Output-Size-Bytes`, `X-Processing-Time-Ms`
- [ ] Moins de 2 fichiers → HTTP 400 avec message explicite
- [ ] Plus de 20 fichiers → HTTP 400 avec message explicite
- [ ] Fichier protégé par mot de passe → HTTP 422 avec numéro du fichier incriminé
- [ ] Fichier > 50 MB → HTTP 413
- [ ] Total > 200 MB → HTTP 413
- [ ] `mvn test` passe sans erreur (PdfMergeServiceTest)
- [ ] Métriques `kovixel.merge.*` visibles sur `/actuator/metrics`

### Frontend
- [ ] Page `/tools/convert/merge` affiche la dropzone multi-fichiers (et non la dropzone mono-fichier générique)
- [ ] Clic sur la dropzone → explorateur de fichiers avec `multiple` → sélection de plusieurs PDFs
- [ ] Glisser-déposer de fichiers PDF → ajout à la liste
- [ ] Boutons ▲ ▼ fonctionnels (réordonnancement)
- [ ] Bouton ✕ par fichier → suppression individuelle
- [ ] Bouton "Tout effacer" → reset de la liste
- [ ] Bouton "Fusionner N fichiers" visible uniquement si N ≥ 2
- [ ] Warning affiché si N < 2
- [ ] Checkbox signets fonctionnelle
- [ ] Après fusion : écran succès avec métadonnées (N fichiers, P pages, taille)
- [ ] "Fusionner un autre document" → reset propre de la liste
- [ ] Drag-over : feedback visuel (bordure + fond violets)
- [ ] Limite 20 fichiers respectée côté client avec message

---

## Notes d'implémentation

### Pourquoi `addMergeFiles()` au lieu de remplacer `selectedFile`
L'outil de fusion est fondamentalement différent des autres outils : il nécessite
une liste de fichiers plutôt qu'un fichier unique. Plutôt que de modifier la
machine à états générique du composant, on maintient un signal séparé `mergeFiles`
et on court-circuite le flow générique dans `startConversion()`, exactement comme
le fait `isCompressTool()`.

### Réordonnancement via boutons (pas Angular CDK)
Le drag-and-drop natif HTML5 est complexe sur mobile et nécessite Angular CDK.
Pour une première version pro et sans dépendance supplémentaire, on utilise des
boutons ▲ ▼ qui sont aussi accessibles au clavier.
Une version V2 pourra utiliser `@angular/cdk/drag-drop` pour un vrai drag natif.

### Signets (bookmarks) — implémentation PDFBox
Les signets PDFBox utilisent `PDDocumentOutline` et `PDOutlineItem`.
La difficulté est de calculer l'offset de page cumulé pour pointer vers la
bonne page dans le PDF fusionné. Exemple :
- Fichier 1 → 5 pages → signet "Document 1" → page 0 (0-indexed)
- Fichier 2 → 3 pages → signet "Document 2" → page 5
- Fichier 3 → 4 pages → signet "Document 3" → page 8

