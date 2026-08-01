# 📋 Rotation PDF : Roadmap d'implémentation Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers exacts à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## État des lieux avant implémentation

### Ce qui existe déjà ✅
| Composant | Fichier | État |
|---|---|---|
| Endpoint `POST /api/v1/pdf/rotate` | `ConversionController.java` | Basique — une seule page, aucun header enrichi |
| `PdfManipulationService.rotate()` | `PdfManipulationService.java` | Fonctionnel — rotation d'une page unique (0-indexed) |
| Service Angular | `conversion.service.ts` | `rotatePdf(file, page, degrees)` — basique, retourne `ConversionResult` |
| Type `RotateDegrees` | `conversion.model.ts` | `90 \| 180 \| 270` — déjà défini |
| Entrée catalogue | `tools-config.ts` | Config présente, slug `convert/rotate` |
| Route Angular | `app.routes.ts` | Routage générique OK |
| `ConversionType.ROTATE` | `conversion.model.ts` | Enum déjà présent |

### Ce qui manque ❌
| Gap | Impact |
|---|---|
| `RotateResult` record avec métadonnées | Impossible d'afficher pages tournées, taille, durée |
| `ConversionProperties.Rotate` | Aucune limite configurable (taille max, pages max) |
| Headers de réponse enrichis | Frontend aveugle sur le résultat |
| Mode "toutes les pages" | Cas d'usage le plus fréquent non couvert |
| Mode "plages de pages" (`pages=1-3,5`) | Rotation sélective impossible |
| Validation `degrees` stricte | Valeurs invalides (ex. 45°) ne retournent pas d'erreur claire |
| Métriques Micrometer | Aucune observabilité |
| Tests unitaires | Aucune couverture |
| UI rotation dédiée (frontend) | L'outil utilise le flow générique — aucun sélecteur de pages/degrés visuel |
| Boutons visuels de rotation (90° / -90° / 180°) | UX non intuitive |
| Sélecteur de scope (toutes / une page / plages) | Manquant complètement |
| Écran succès enrichi | Après rotation : aucune info sur les pages tournées |

---

## Vue d'ensemble de l'architecture cible

```
POST /api/v1/pdf/rotate
   file    = PDF source
   degrees = 90 | 180 | 270 | -90 (alias 270)
   pages   = "ALL"         (mode ALL — toutes les pages)
           | "0"           (mode SINGLE — page unique, 0-indexed)
           | "1-3,5,8-10"  (mode RANGES — plages 1-indexed)
   ───────────────────────────────────────
         │
         ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Validation :                                             │
   │  - fichier ≤ 50 MB                                        │
   │  - degrees ∈ {90, 180, 270, -90}                         │
   │  - pages dans les bornes du document                     │
   │  - PDF non chiffré                                        │
   └──────────────────────────────────────────────────────────┘
         │
         ▼
   PdfManipulationService.rotateWithMeta(pdf, pageIndices, degrees)
         │
         ▼
   PDFBox → setRotation() sur chaque page ciblée
         │
         ▼
   RotateResult {
     rotatedBytes,      // byte[]
     pagesRotated,      // int (nombre de pages effectivement tournées)
     totalPages,        // int (nombre total de pages du document)
     outputSizeBytes,   // long
     durationMs         // long
   }
         │
         ▼
   ResponseEntity<byte[]> (application/pdf)
   Headers HTTP :
   X-Pages-Rotated, X-Total-Pages, X-Output-Size-Bytes, X-Processing-Time-Ms
```

### Modes de rotation

| Mode | Paramètre `pages` | Description |
|---|---|---|
| **Toutes les pages** | `ALL` | Chaque page du document est tournée |
| **Page unique** | `0` (0-indexed) | Une seule page est tournée |
| **Plages** | `1-3,5` (1-indexed) | Seules les pages listées sont tournées |

### Valeurs de `degrees`

| Valeur | Effet |
|---|---|
| `90` | Rotation horaire (→) |
| `180` | Retournement (↓↑) |
| `270` ou `-90` | Rotation antihoraire (←) |

---

## PROMPT 1 — Backend : Enrichir l'endpoint `/api/v1/pdf/rotate`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`
- `src/main/resources/application.yml`

```
Lis d'abord intégralement :
- ConversionController.java (endpoint rotate existant ~ligne 627, méthode fileResponse)
- PdfManipulationService.java (méthode rotate() existante ~ligne 366)
- ConversionProperties.java (pour voir la structure des classes imbriquées Merge, Split)
- application.yml (pour voir kovixel.conversion existant)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : ConversionProperties.java — classe imbriquée Rotate
─────────────────────────────────────────────────────────────────────────────

Ajoute une classe imbriquée Rotate dans ConversionProperties, sur le même
modèle que la classe Split existante :

  @Data
  public static class Rotate {
      /** Taille maximale du fichier source (50 MB). */
      private long maxFileSizeBytes = 52_428_800L;

      /** Nombre maximum de pages pouvant être tournées par requête. */
      private int maxPages = 500;
  }

Ajoute le champ `private Rotate rotate = new Rotate();` dans ConversionProperties
(avec @NestedConfigurationProperty), juste après le champ `split`.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : application.yml
─────────────────────────────────────────────────────────────────────────────

Dans la section `kovixel.conversion`, ajoute (après `split:`) :

  rotate:
    max-file-size-bytes: 52428800    # 50 MB
    max-pages: 500                   # Maximum de pages à tourner par requête

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Créer le record RotateResult
─────────────────────────────────────────────────────────────────────────────

Crée un nouveau fichier dans le package com.kovixel.core.conversion :

  package com.kovixel.core.conversion;

  /**
   * Résultat d'une rotation PDF avec toutes les métadonnées.
   * Exposé via les headers HTTP X-* dans la réponse.
   */
  public record RotateResult(
      byte[] rotatedBytes,
      int    pagesRotated,
      int    totalPages,
      long   outputSizeBytes,
      long   durationMs
  ) {
      public String summary() {
          return String.format(
              "rotate: %d/%d pages tournées, %d bytes en %d ms",
              pagesRotated, totalPages, outputSizeBytes, durationMs
          );
      }
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : PdfManipulationService.java — ajouter rotateWithMeta()
─────────────────────────────────────────────────────────────────────────────

Ajoute la méthode rotateWithMeta() JUSTE APRÈS la méthode rotate() existante.
Ne supprime PAS rotate() — conserve-la pour compatibilité (délégation).

  /**
   * Applique une rotation à une sélection de pages et retourne les métadonnées.
   *
   * @param pdf         PDF source en bytes
   * @param pageIndices indices des pages à tourner (0-indexed, liste triée)
   * @param degrees     rotation : 90, 180, 270 (ou -90 normalisé en 270)
   * @return RotateResult avec le PDF modifié et toutes les métadonnées
   */
  public RotateResult rotateWithMeta(byte[] pdf, List<Integer> pageIndices, int degrees) {
      // Normaliser -90 → 270
      int normalizedDegrees = ((degrees % 360) + 360) % 360;
      if (normalizedDegrees == 0 || normalizedDegrees % 90 != 0) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "La rotation doit être 90, 180 ou 270 degrés (reçu : " + degrees + ").");
      }
      if (pageIndices == null || pageIndices.isEmpty()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Au moins une page doit être sélectionnée pour la rotation.");
      }

      long startMs = System.currentTimeMillis();

      try (PDDocument doc = Loader.loadPDF(pdf);
           ByteArrayOutputStream out = new ByteArrayOutputStream()) {

          int totalPages = doc.getNumberOfPages();

          // Valider tous les indices
          for (int idx : pageIndices) {
              if (idx < 0 || idx >= totalPages) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR,
                          HttpStatus.UNPROCESSABLE_ENTITY,
                          "Index de page invalide : " + idx +
                          " (le document a " + totalPages + " pages, indices 0 à " + (totalPages - 1) + ").");
              }
          }

          // Appliquer la rotation
          for (int idx : pageIndices) {
              PDPage page   = doc.getPage(idx);
              int current   = page.getRotation();
              page.setRotation((current + normalizedDegrees) % 360);
          }

          doc.save(out);
          byte[] rotatedBytes = out.toByteArray();
          long durationMs = System.currentTimeMillis() - startMs;

          log.info("Rotation terminée — {}/{} pages tournées de {}° en {} ms",
                   pageIndices.size(), totalPages, normalizedDegrees, durationMs);

          return new RotateResult(
              rotatedBytes,
              pageIndices.size(),
              totalPages,
              rotatedBytes.length,
              durationMs
          );

      } catch (KovixelException e) {
          throw e;
      } catch (Exception e) {
          throw new KovixelException(ErrorCode.PROCESSING_ERROR,
                  HttpStatus.UNPROCESSABLE_ENTITY,
                  "Erreur lors de la rotation : " + e.getMessage(), e);
      }
  }

  // Méthode legacy mise à jour pour déléguer à rotateWithMeta()
  public byte[] rotate(byte[] pdf, int pageIndex, int degrees) {
      return rotateWithMeta(pdf, List.of(pageIndex), degrees).rotatedBytes();
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : ConversionController.java — enrichir l'endpoint rotate
─────────────────────────────────────────────────────────────────────────────

Remplace l'implémentation du endpoint @PostMapping("/api/v1/pdf/rotate") par :

  @PostMapping("/api/v1/pdf/rotate")
  @Operation(
      summary = "Rotation de pages PDF",
      description = """
          Applique une rotation à une ou plusieurs pages d'un PDF.

          **Modes via le paramètre `pages`** :
          - `pages=ALL` — toutes les pages du document
          - `pages=0` — page unique (0-indexed)
          - `pages=1-3,5` — plages de pages (1-indexed, virgule-séparées)

          **Valeurs de `degrees`** :
          - `90` — rotation horaire (→)
          - `180` — retournement (↓↑)
          - `270` ou `-90` — rotation antihoraire (←)

          **Headers de réponse** :
          `X-Pages-Rotated`, `X-Total-Pages`, `X-Output-Size-Bytes`, `X-Processing-Time-Ms`
          """
  )
  @CheckQuota(feature = FeatureType.CONVERSION)
  public ResponseEntity<?> rotate(
          @RequestParam("file") MultipartFile file,
          @RequestParam(defaultValue = "ALL") String pages,
          @RequestParam(defaultValue = "90")  int degrees,
          @AuthenticationPrincipal UserDetails userDetails) throws Exception {

      ConversionProperties.Rotate cfg = conversionProperties.getRotate();

      // ── Validation taille fichier ────────────────────────────────────────────
      if (file.getSize() > cfg.getMaxFileSizeBytes()) {
          throw new KovixelException(ErrorCode.FILE_TOO_LARGE, HttpStatus.PAYLOAD_TOO_LARGE,
                  "Le fichier dépasse la limite de " +
                  (cfg.getMaxFileSizeBytes() / 1_048_576) + " MB.");
      }

      byte[] pdfBytes = file.getBytes();

      // ── Résolution des indices de pages ──────────────────────────────────────
      List<Integer> pageIndices = resolveRotatePageIndices(pages, pdfBytes, cfg);

      // ── Rotation ─────────────────────────────────────────────────────────────
      RotateResult result = pdfManipulationService.rotateWithMeta(pdfBytes, pageIndices, degrees);
      log.info("rotate — {}", result.summary());

      // ── Nom du fichier de sortie ─────────────────────────────────────────────
      String baseName = sanitizeFilename(file.getOriginalFilename());
      String outName  = baseName + "_rotated.pdf";

      // ── Réponse avec headers enrichis ────────────────────────────────────────
      return ResponseEntity.ok()
              .header(HttpHeaders.CONTENT_TYPE, "application/pdf")
              .header(HttpHeaders.CONTENT_DISPOSITION,
                      ContentDisposition.attachment()
                              .filename(outName, StandardCharsets.UTF_8)
                              .build().toString())
              .header(HttpHeaders.CONTENT_LENGTH,    String.valueOf(result.outputSizeBytes()))
              .header("X-Pages-Rotated",             String.valueOf(result.pagesRotated()))
              .header("X-Total-Pages",               String.valueOf(result.totalPages()))
              .header("X-Output-Size-Bytes",         String.valueOf(result.outputSizeBytes()))
              .header("X-Processing-Time-Ms",        String.valueOf(result.durationMs()))
              .body(result.rotatedBytes());
  }

Ajoute cette méthode privée dans ConversionController :

  /**
   * Résout la liste d'indices de pages (0-indexed) à tourner selon le paramètre `pages`.
   * Supporte : "ALL", "0" (single, 0-indexed), "1-3,5" (plages 1-indexed).
   */
  private List<Integer> resolveRotatePageIndices(String pages, byte[] pdf,
                                                  ConversionProperties.Rotate cfg) throws Exception {
      if (pages == null || pages.isBlank()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Le paramètre 'pages' est obligatoire (valeurs : ALL, 0, 1-3,5…).");
      }

      // Mode ALL
      if ("ALL".equalsIgnoreCase(pages.trim())) {
          try (PDDocument doc = Loader.loadPDF(pdf)) {
              int n = doc.getNumberOfPages();
              if (n > cfg.getMaxPages()) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                          "Le document a " + n + " pages. Maximum configurable : " + cfg.getMaxPages() + ".");
              }
              return java.util.stream.IntStream.range(0, n).boxed()
                     .collect(java.util.stream.Collectors.toList());
          }
      }

      // Mode SINGLE (0-indexed, rétrocompatibilité avec l'ancien endpoint)
      if (pages.trim().matches("^\\d+$")) {
          int idx = Integer.parseInt(pages.trim());
          return List.of(idx);
      }

      // Mode RANGES (1-indexed → convertir en 0-indexed)
      int[][] ranges = parsePageRanges(pages);
      List<Integer> indices = new java.util.ArrayList<>();
      for (int[] range : ranges) {
          for (int p = range[0]; p <= range[1]; p++) {
              indices.add(p - 1); // 1-indexed → 0-indexed
          }
      }
      // Dédupliquer et trier
      return indices.stream().distinct().sorted().collect(java.util.stream.Collectors.toList());
  }

Ajoute les imports nécessaires :
  import com.kovixel.core.conversion.RotateResult;
  import java.nio.charset.StandardCharsets;
  import java.util.List;
```

---

## PROMPT 2 — Backend : Métriques, CORS & Tests unitaires

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/java/com/kovixel/common/config/WebConfig.java`
- `src/main/java/com/kovixel/common/security/SecurityConfig.java`

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/PdfRotateServiceTest.java`

```
Lis d'abord :
- PdfManipulationService.java (pour voir rotateWithMeta() ajouté en PROMPT 1)
- PdfMergeServiceTest.java ou PdfSplitServiceTest.java (pattern de tests PDFBox)
- WebConfig.java et SecurityConfig.java (exposedHeaders déjà configurés)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Métriques Micrometer dans rotateWithMeta()
─────────────────────────────────────────────────────────────────────────────

MeterRegistry est DÉJÀ injecté dans PdfManipulationService (ajouté pour merge).
Utilise-le directement.

Dans rotateWithMeta(), enregistre dans un bloc try/finally :

  kovixel.rotate.total
    Type : Counter
    Tags : status=SUCCESS|ERROR, degrees={normalizedDegrees}
    Incrémenter après chaque rotation (SUCCESS si pas d'exception, ERROR sinon)

  kovixel.rotate.duration
    Type : Timer
    Enregistrer la durée totale

  kovixel.rotate.pages_rotated
    Type : DistributionSummary
    Valeur : result.pagesRotated()

  kovixel.rotate.output_size
    Type : DistributionSummary
    Valeur : result.outputSizeBytes()

En cas d'exception :
  - Counter kovixel.rotate.total avec tag status=ERROR
  - Puis relancer l'exception

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : CORS — exposer les headers de rotation
─────────────────────────────────────────────────────────────────────────────

Dans WebConfig.java, vérifie que .exposedHeaders() contient :
  "X-Pages-Rotated"

(X-Total-Pages, X-Output-Size-Bytes, X-Processing-Time-Ms sont déjà présents.)

Idem dans SecurityConfig.java (config.setExposedHeaders(List.of(...))).

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Tests unitaires PdfRotateServiceTest
─────────────────────────────────────────────────────────────────────────────

Crée PdfRotateServiceTest.java sur le modèle de PdfSplitServiceTest.

  @ExtendWith(MockitoExtension.class)
  class PdfRotateServiceTest {

    private static byte[] pdf6pages;
    private PdfManipulationService service;

    @BeforeAll
    static void generateTestPdf() {
        // Générer un PDF de 6 pages avec PDFBox (même helper que PdfMergeServiceTest)
    }

    @BeforeEach
    void setUp() {
        MeterRegistry registry = new SimpleMeterRegistry();
        service = new PdfManipulationService(..., registry);
    }

    Tests à écrire :

    rotateWithMeta() mode ALL de 90°
      → RotateResult non null, pagesRotated = 6, totalPages = 6
      → rotatedBytes commence par "%PDF"
      → Chaque page a une rotation = 90 dans le PDF résultant

    rotateWithMeta() page unique index 0 de 90°
      → pagesRotated = 1, totalPages = 6
      → La page 0 du PDF résultant a rotation = 90
      → Les autres pages ont rotation = 0

    rotateWithMeta() avec plages [1,2] (0-indexed) de 180°
      → pagesRotated = 2, pages 1 et 2 ont rotation = 180

    rotateWithMeta() avec index invalide (-1 ou >= totalPages)
      → KovixelException avec "Index de page invalide"

    rotateWithMeta() avec degrees = 45
      → KovixelException VALIDATION_ERROR "multiple de 90"

    rotateWithMeta() avec degrees = -90
      → Normalisé en 270, rotation antihoraire OK

    rotateWithMeta() avec degrees = 180, rotation cumulée
      → Si page déjà à 90°, résultat = 270°

    rotate() legacy retourne les mêmes bytes que rotateWithMeta()
  }
```

---

## PROMPT 3 — Frontend : Service, Interface & Configuration

**Fichiers à modifier :**
- `kovixel-ui/src/app/core/services/conversion.service.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`

```
Lis d'abord :
- conversion.service.ts (rotatePdf() existant, MergeMeta et SplitMeta pour le pattern)
- tools-config.ts (entrée convert/rotate existante)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Interface RotateMeta dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute l'interface RotateMeta juste après SplitMeta :

  /** Métadonnées de rotation lues depuis les headers X-* de la réponse HTTP. */
  export interface RotateMeta {
    /** Nombre de pages effectivement tournées (X-Pages-Rotated) */
    pagesRotated:    number;
    /** Nombre total de pages du document (X-Total-Pages) */
    totalPages:      number;
    /** Taille du PDF produit en bytes (X-Output-Size-Bytes) */
    outputSizeBytes: number;
    /** Durée de traitement côté serveur en ms (X-Processing-Time-Ms) */
    durationMs:      number;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Méthode rotatePdfWithMeta() dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute rotatePdfWithMeta() juste après rotatePdf() (conserve rotatePdf()
pour la compatibilité avec le code existant) :

  rotatePdfWithMeta(
    file:    File,
    pages:   string,       // "ALL", "0", "1-3,5"
    degrees: number,       // 90, 180, 270, -90
  ): Observable<{ blob: Blob; meta: RotateMeta }> {
    const params = new HttpParams()
      .set('pages',   pages)
      .set('degrees', String(degrees));

    return this.http
      .post(`${this.base}/pdf/rotate`, this._single(file), {
        params,
        responseType: 'blob',
        observe: 'response',
      })
      .pipe(
        map((response) => {
          const blob = response.body as Blob;
          const h    = response.headers;
          const meta: RotateMeta = {
            pagesRotated:    Number(h.get('X-Pages-Rotated')        ?? 0),
            totalPages:      Number(h.get('X-Total-Pages')          ?? 0),
            outputSizeBytes: Number(h.get('X-Output-Size-Bytes')    ?? 0),
            durationMs:      Number(h.get('X-Processing-Time-Ms')   ?? 0),
          };
          return { blob, meta };
        }),
      );
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Mise à jour de tools-config.ts
─────────────────────────────────────────────────────────────────────────────

Enrichis l'entrée slug: 'convert/rotate' :

  {
    slug:            'convert/rotate',
    name:            'Rotation PDF',
    description:     'Orientez vos pages dans le bon sens',
    longDescription: 'Tournez une page, une sélection ou l\'intégralité du document de 90°, 180° ou 270°. La rotation est appliquée proprement et conserve la qualité du PDF.',
    category:        'compress',
    icon:            RotateCw,
    badge:           'NEW',
    estimatedTime:   '~2 secondes',
    isPro:           false,
    isAvailable:     true,
    backendEndpoint: '/api/v1/pdf/rotate',
  },
```

---

## PROMPT 4 — Frontend : UI dédiée dans tool-page.component.ts

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord intégralement tool-page.component.ts pour comprendre :
- Le pattern isCompressTool(), isMergeTool(), isSplitTool() (modèle à suivre)
- La machine à états (idle → selected → uploading → success/error)
- La méthode startConversion() et ses cas spéciaux (après le cas split)
- Le bloc state() === 'selected' avec les options compression et split

Ne modifie pas l'architecture générale du composant.
Ajoute uniquement le traitement spécial pour le slug 'convert/rotate',
en suivant exactement le même pattern.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Import RotateMeta
─────────────────────────────────────────────────────────────────────────────

Modifie la ligne d'import :
  import { CompressionMeta, MergeMeta, SplitMeta, RotateMeta }
    from '../../core/services/conversion.service';

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Signaux et computed pour l'outil rotate
─────────────────────────────────────────────────────────────────────────────

Ajoute ces signaux dans la classe, juste après les signaux split :

  // ── Rotate tool signals ───────────────────────────────────────────────────
  /** Métadonnées du dernier rotate réalisé */
  readonly rotateMeta     = signal<RotateMeta | null>(null);
  /** Scope de rotation : toutes les pages, une seule, ou des plages */
  readonly rotateScope    = signal<'all' | 'single' | 'ranges'>('all');
  /** Index de page (0-indexed) pour le mode 'single' */
  readonly rotatePage     = signal<number>(0);
  /** Plages de pages (1-indexed) pour le mode 'ranges', ex: "1-3, 5" */
  readonly rotateRanges   = signal<string>('');
  /** Valeur de rotation sélectionnée : 90, 180, 270 */
  readonly rotateDegrees  = signal<number>(90);
  /** true uniquement sur l'outil de rotation PDF */
  readonly isRotateTool   = computed(() => this.tool()?.slug === 'convert/rotate');
  /** Construit le paramètre `pages` à envoyer à l'API selon le scope */
  readonly rotatePagesParam = computed(() => {
    switch (this.rotateScope()) {
      case 'single': return String(this.rotatePage());
      case 'ranges': return this.rotateRanges().trim();
      default:       return 'ALL';
    }
  });
  /** true si les paramètres de rotation sont valides */
  readonly rotateIsValid = computed(() => {
    const scope = this.rotateScope();
    if (scope === 'all') return true;
    if (scope === 'single') return this.rotatePage() >= 0;
    const r = this.rotateRanges().trim();
    return r.length > 0 && /^[\d,\-\s]+$/.test(r);
  });

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Cas spécial rotate dans startConversion()
─────────────────────────────────────────────────────────────────────────────

Dans startConversion(), ajoute le cas rotate JUSTE APRÈS le cas split :

  // ── Cas spécial : outil de rotation — utilise rotatePdfWithMeta ──────────
  if (t.slug === 'convert/rotate') {
    const file = this.selectedFile();
    if (!file) return;
    if (!this.rotateIsValid()) {
      this.errorMessage.set('Veuillez saisir une sélection de pages valide.');
      this.state.set('error');
      return;
    }

    this.state.set('uploading');
    this.uploadProgress.set(0);
    this.rotateMeta.set(null);
    this.startMsgRotation();
    this.startFakeProgress(0, 92);

    this.uploadSub = this.convSvc
      .rotatePdfWithMeta(file, this.rotatePagesParam(), this.rotateDegrees())
      .subscribe({
        next: ({ blob, meta }) => {
          this.stopFakeProgress();
          this.uploadProgress.set(100);
          this.rotateMeta.set(meta);
          this.resultBlob.set(blob);
          const base = file.name.replace(/\.[^.]+$/, '');
          this.resultFilename.set(`${base}_rotated.pdf`);
          this.stopMsgRotation();
          this.state.set('success');
          if (!this.authSvc.isAuthenticated()) {
            this.quotaSvc.decrementLocally();
          }
        },
        error: (err) => {
          this.stopFakeProgress();
          this.stopMsgRotation();
          const msg = err?.error?.message ?? err?.message ?? 'Erreur lors de la rotation.';
          this.errorMessage.set(msg);
          this.state.set('error');
        },
      });
    return;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Réinitialisation
─────────────────────────────────────────────────────────────────────────────

Dans clearFile() ajoute : this.rotateMeta.set(null);

Dans la section de réinitialisation en haut de startConversion() ajoute :
  this.rotateMeta.set(null);

Si une méthode reset() existe (appelée par le bouton "Traiter un autre") :
  this.rotateMeta.set(null);
  this.rotateScope.set('all');
  this.rotatePage.set(0);
  this.rotateRanges.set('');
  this.rotateDegrees.set(90);

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : Bloc d'options rotate dans le template (state 'selected')
─────────────────────────────────────────────────────────────────────────────

Localise le bloc @if (isSplitTool()) dans le template (state 'selected').
Juste APRÈS ce bloc, ajoute @if (isRotateTool()) :

  @if (isRotateTool()) {
    <div class="space-y-4 rounded-xl border p-4"
         style="background: rgba(168,85,247,0.04); border-color: rgba(168,85,247,0.18)">

      <!-- ── Sélecteur de rotation (3 boutons visuels) ── -->
      <div>
        <p class="text-xs font-semibold uppercase tracking-widest mb-2"
           style="color: var(--text-muted)">Angle de rotation</p>
        <div class="flex gap-2">

          <!-- 90° horaire -->
          <button type="button"
                  class="flex-1 flex flex-col items-center gap-1.5 rounded-xl p-3 border transition-all"
                  [style.background]="rotateDegrees()===90 ? 'rgba(168,85,247,0.12)' : 'rgba(255,255,255,0.03)'"
                  [style.border-color]="rotateDegrees()===90 ? '#a855f7' : 'rgba(168,85,247,0.18)'"
                  (click)="rotateDegrees.set(90)">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"
                 [attr.stroke]="rotateDegrees()===90 ? '#a855f7' : 'var(--text-muted)'"
                 stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M21 2v6h-6"/><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/>
            </svg>
            <span class="text-xs font-semibold"
                  [style.color]="rotateDegrees()===90 ? '#a855f7' : 'var(--text-muted)'">
              90° →
            </span>
          </button>

          <!-- 180° -->
          <button type="button"
                  class="flex-1 flex flex-col items-center gap-1.5 rounded-xl p-3 border transition-all"
                  [style.background]="rotateDegrees()===180 ? 'rgba(168,85,247,0.12)' : 'rgba(255,255,255,0.03)'"
                  [style.border-color]="rotateDegrees()===180 ? '#a855f7' : 'rgba(168,85,247,0.18)'"
                  (click)="rotateDegrees.set(180)">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"
                 [attr.stroke]="rotateDegrees()===180 ? '#a855f7' : 'var(--text-muted)'"
                 stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M12 2v20M2 12l10 10 10-10"/>
            </svg>
            <span class="text-xs font-semibold"
                  [style.color]="rotateDegrees()===180 ? '#a855f7' : 'var(--text-muted)'">
              180° ↓
            </span>
          </button>

          <!-- 270° / -90° antihoraire -->
          <button type="button"
                  class="flex-1 flex flex-col items-center gap-1.5 rounded-xl p-3 border transition-all"
                  [style.background]="rotateDegrees()===270 ? 'rgba(168,85,247,0.12)' : 'rgba(255,255,255,0.03)'"
                  [style.border-color]="rotateDegrees()===270 ? '#a855f7' : 'rgba(168,85,247,0.18)'"
                  (click)="rotateDegrees.set(270)">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none"
                 [attr.stroke]="rotateDegrees()===270 ? '#a855f7' : 'var(--text-muted)'"
                 stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 2v6h6"/><path d="M21 12a9 9 0 0 0-15-6.7L3 8"/>
            </svg>
            <span class="text-xs font-semibold"
                  [style.color]="rotateDegrees()===270 ? '#a855f7' : 'var(--text-muted)'">
              90° ←
            </span>
          </button>
        </div>
      </div>

      <!-- ── Sélecteur de scope ── -->
      <div>
        <p class="text-xs font-semibold uppercase tracking-widest mb-2"
           style="color: var(--text-muted)">Pages à tourner</p>
        <div class="flex flex-col gap-2">

          <!-- Toutes les pages -->
          <label class="flex items-center gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
                 [style.background]="rotateScope()==='all' ? 'rgba(168,85,247,0.10)' : 'transparent'"
                 [style.border]="rotateScope()==='all' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
            <input type="radio" name="rotateScope" value="all"
                   [checked]="rotateScope()==='all'"
                   (change)="rotateScope.set('all')"
                   style="accent-color:#a855f7; flex-shrink:0" />
            <div>
              <span class="text-sm font-semibold" style="color: var(--text-primary)">
                Toutes les pages
              </span>
              <p class="text-xs mt-0.5" style="color: var(--text-muted)">
                Le document entier est tourné
              </p>
            </div>
          </label>

          <!-- Page unique -->
          <label class="flex items-start gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
                 [style.background]="rotateScope()==='single' ? 'rgba(168,85,247,0.10)' : 'transparent'"
                 [style.border]="rotateScope()==='single' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
            <input type="radio" name="rotateScope" value="single"
                   [checked]="rotateScope()==='single'"
                   (change)="rotateScope.set('single')"
                   style="accent-color:#a855f7; margin-top:3px; flex-shrink:0" />
            <div class="flex-1">
              <span class="text-sm font-semibold" style="color: var(--text-primary)">
                Page unique
              </span>
              @if (rotateScope() === 'single') {
                <div class="flex items-center gap-2 mt-2">
                  <span class="text-xs" style="color: var(--text-muted)">Page n°</span>
                  <input type="number" min="1"
                         [value]="rotatePage() + 1"
                         (input)="rotatePage.set(+$any($event.target).value - 1 || 0)"
                         class="w-20 rounded-lg px-2 py-1 text-sm border text-center"
                         style="background:rgba(255,255,255,0.06);
                                border-color:rgba(139,92,246,0.35);
                                color:var(--text-primary)" />
                  <span class="text-xs" style="color: var(--text-muted)">(1-indexé)</span>
                </div>
              }
            </div>
          </label>

          <!-- Plages de pages -->
          <label class="flex items-start gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
                 [style.background]="rotateScope()==='ranges' ? 'rgba(168,85,247,0.10)' : 'transparent'"
                 [style.border]="rotateScope()==='ranges' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
            <input type="radio" name="rotateScope" value="ranges"
                   [checked]="rotateScope()==='ranges'"
                   (change)="rotateScope.set('ranges')"
                   style="accent-color:#a855f7; margin-top:3px; flex-shrink:0" />
            <div class="flex-1">
              <span class="text-sm font-semibold" style="color: var(--text-primary)">
                Sélection de pages
              </span>
              <p class="text-xs mt-0.5" style="color: var(--text-muted)">
                Ex : 1-3, 5, 8-10
              </p>
              @if (rotateScope() === 'ranges') {
                <input type="text"
                       [value]="rotateRanges()"
                       (input)="rotateRanges.set($any($event.target).value)"
                       placeholder="1-3, 5, 8-10"
                       class="mt-2 w-full rounded-lg px-3 py-2 text-sm border font-mono"
                       style="background:rgba(255,255,255,0.06);
                              border-color:rgba(139,92,246,0.35);
                              color:var(--text-primary);
                              outline:none" />
              }
            </div>
          </label>
        </div>
      </div>

      <!-- Résumé de l'action -->
      <div class="flex items-center gap-2 px-1">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none"
             stroke="#a855f7" stroke-width="2.5" stroke-linecap="round">
          <polyline points="20 6 9 17 4 12"/>
        </svg>
        <p class="text-xs" style="color:#a855f7">
          @if (rotateScope() === 'all') { Toutes les pages }
          @else if (rotateScope() === 'single') { Page {{ rotatePage() + 1 }} }
          @else { Pages : {{ rotatePagesParam() || '—' }} }
          → rotation de {{ rotateDegrees() }}°
        </p>
      </div>
    </div>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 6 : Désactivation du bouton Convertir si invalide
─────────────────────────────────────────────────────────────────────────────

Sur le bouton "Convertir maintenant" générique dans le template, ajoute :

  [disabled]="isRotateTool() && !rotateIsValid()"
  [style.opacity]="isRotateTool() && !rotateIsValid() ? '0.4' : '1'"

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 7 : Bloc de résultat enrichi pour rotate dans le template
─────────────────────────────────────────────────────────────────────────────

Localise le bloc @else if (isSplitTool() && splitMeta()) dans le template.
Juste APRÈS ce bloc, ajoute :

  @else if (isRotateTool() && rotateMeta()) {
    <div class="rounded-2xl border p-5 space-y-4"
         style="background: rgba(255,255,255,0.025); border-color: rgba(139,92,246,0.20)">

      <!-- Titre succès -->
      <div class="flex items-center gap-2">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
             stroke="#34d399" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="20 6 9 17 4 12"/>
        </svg>
        <p class="font-display font-semibold text-base" style="color: #34d399">
          Rotation appliquée avec succès !
        </p>
      </div>

      <!-- Grille métriques -->
      <div class="grid grid-cols-3 gap-3 text-center">
        <!-- Pages tournées -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Pages tournées</p>
          <p class="font-display font-bold text-lg" style="color: #a855f7">
            {{ rotateMeta()!.pagesRotated }}
            <span class="text-xs font-normal" style="color: var(--text-muted)">
              / {{ rotateMeta()!.totalPages }}
            </span>
          </p>
        </div>
        <!-- Angle appliqué -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Rotation</p>
          <p class="font-display font-bold text-lg" style="color: var(--text-primary)">
            {{ rotateDegrees() }}°
          </p>
        </div>
        <!-- Taille finale -->
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Taille</p>
          <p class="font-display font-bold text-sm" style="color: var(--text-primary)">
            {{ formatBytes(rotateMeta()!.outputSizeBytes) }}
          </p>
        </div>
      </div>
    </div>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 8 : Labels adaptatifs dans le state 'success'
─────────────────────────────────────────────────────────────────────────────

Dans le template du state 'success', adapte les labels des boutons :

  Bouton téléchargement — ajoute le cas rotate :
  @else if (isRotateTool()) { Télécharger le PDF tourné }

  Bouton recommencer — ajoute le cas rotate :
  @else if (isRotateTool()) { Tourner un autre fichier }
```

---

## PROMPT 5 — Frontend : Bonus UX & Messages de progression

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord le résultat du PROMPT 4 pour comprendre l'état actuel.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Messages de progression spécifiques à la rotation
─────────────────────────────────────────────────────────────────────────────

Cherche le tableau SPLIT_MESSAGES dans tool-page.component.ts.
Ajoute juste après :

  private static readonly ROTATE_MESSAGES = [
    'Analyse du PDF…',
    'Identification des pages cibles…',
    'Application de la rotation…',
    'Recalcul des dimensions…',
    'Optimisation du fichier…',
    'Finalisation…',
  ];

Dans startMsgRotation(), ajoute le cas rotate :
  const messages = this.isMergeTool()  ? MERGE_MESSAGES
                 : this.isSplitTool()  ? SPLIT_MESSAGES
                 : this.isRotateTool() ? ROTATE_MESSAGES
                 : PROCESSING_MESSAGES;

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Indicateur visuel de la rotation sélectionnée
─────────────────────────────────────────────────────────────────────────────

Dans le bloc @if (isRotateTool()) du state 'selected', affiche une icône
animée qui représente visuellement la rotation sélectionnée.

Ajoute un computed pour la classe CSS de rotation :

  readonly rotatePreviewDeg = computed(() => {
    // Renvoie la string CSS pour transform
    const d = this.rotateDegrees();
    return `rotate(${d}deg)`;
  });

Dans le template, affiche un aperçu animé :

  <!-- Aperçu de rotation -->
  <div class="flex justify-center py-2">
    <div class="w-12 h-16 rounded-lg border-2 flex items-center justify-center transition-transform duration-500"
         style="border-color: rgba(139,92,246,0.35); background: rgba(139,92,246,0.06)"
         [style.transform]="rotatePreviewDeg()">
      <!-- Mini icône PDF -->
      <svg width="18" height="22" viewBox="0 0 24 28" fill="none"
           stroke="#a855f7" stroke-width="1.5" stroke-linecap="round">
        <rect x="2" y="2" width="20" height="24" rx="2"/>
        <line x1="7" y1="9" x2="17" y2="9"/>
        <line x1="7" y1="13" x2="17" y2="13"/>
        <line x1="7" y1="17" x2="13" y2="17"/>
      </svg>
    </div>
  </div>

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Validation visuelle du champ de plages (mode 'ranges')
─────────────────────────────────────────────────────────────────────────────

Sur l'input de plages (mode 'ranges'), ajoute une bordure colorée :

  [style.border-color]="rotateRanges().trim() && !rotateIsValid()
    ? '#ef4444'
    : rotateRanges().trim() && rotateIsValid()
    ? '#34d399'
    : 'rgba(139,92,246,0.35)'"

Si invalide, affiche un message d'erreur inline :

  @if (rotateScope() === 'ranges' && rotateRanges().trim() && !rotateIsValid()) {
    <p class="text-xs mt-1" style="color: #ef4444">
      ⚠ Format invalide. Exemples valides : <code>1</code>, <code>1-3</code>,
      <code>1-3, 5, 8-10</code>
    </p>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Reset propre dans le state 'success'
─────────────────────────────────────────────────────────────────────────────

Le bouton "Tourner un autre fichier" doit appeler clearFile() pour l'outil rotate.
La méthode clearFile() a déjà été mise à jour à l'ÉTAPE 4 du PROMPT 4
pour réinitialiser rotateMeta.

Vérifie que dans le template, le bouton "recommencer" pour isRotateTool()
appelle bien clearFile() :

  (click)="isMergeTool() ? clearMergeFiles()
         : clearFile()"

(Le cas rotate est inclus dans clearFile() puisqu'il n'a pas de liste
de fichiers séparée — on reste sur le flow selectedFile existant.)
```

---

## PROMPT 6 — Documentation & Mise à jour README

**Fichiers à modifier :**
- `kovixel/README.md`

```
Ajoute une section "## Rotation PDF" dans README.md,
juste après la section "## Diviser un PDF" existante.

La section doit documenter :

### Endpoint
POST /api/v1/pdf/rotate

### Paramètres
| Paramètre | Type     | Défaut | Description |
|-----------|----------|--------|-------------|
| `file`    | `File`   | —      | PDF source (multipart, 1 fichier) |
| `pages`   | `string` | `ALL`  | Sélection des pages (voir modes ci-dessous) |
| `degrees` | `int`    | `90`   | Angle de rotation : 90, 180, 270, -90 |

### Modes via `pages`
| Valeur de `pages`  | Mode            | Exemple                        |
|--------------------|-----------------|-------------------------------|
| `ALL`              | Toutes pages    | Tout le document est tourné   |
| `0`                | Page unique     | Seule la 1ère page (0-indexed)|
| `1-3,5`            | Plages custom   | Pages 1, 2, 3 et 5 tournées  |

### Headers de réponse
| Header                  | Description                                      |
|-------------------------|--------------------------------------------------|
| `X-Pages-Rotated`       | Nombre de pages effectivement tournées           |
| `X-Total-Pages`         | Nombre total de pages du document                |
| `X-Output-Size-Bytes`   | Taille du PDF produit en bytes                   |
| `X-Processing-Time-Ms`  | Durée de traitement côté serveur en ms           |

### Comportement sur les rotations cumulées
La rotation est **additive** : si une page est déjà à 90°, appliquer une
rotation de 90° donne 180°. Le résultat final est toujours `(rotation_actuelle + degrees) % 360`.

### Limites par configuration
| Propriété                                 | Défaut   | Description                     |
|-------------------------------------------|----------|---------------------------------|
| `kovixel.conversion.rotate.max-file-size-bytes` | 50 MB | Taille max du fichier source   |
| `kovixel.conversion.rotate.max-pages`      | 500      | Maximum de pages traitables     |

### Exemples de requêtes

```bash
# Tourner tout le document de 90° (sens horaire)
curl -X POST http://localhost:8080/api/v1/pdf/rotate \
  -F "file=@scan.pdf" \
  -F "pages=ALL" \
  -F "degrees=90" \
  --output scan_rotated.pdf

# Tourner seulement la première page de 180°
curl -X POST http://localhost:8080/api/v1/pdf/rotate \
  -F "file=@rapport.pdf" \
  -F "pages=0" \
  -F "degrees=180" \
  --output rapport_rotated.pdf

# Tourner les pages 1 à 3 de 270° (= -90°, sens antihoraire)
curl -X POST http://localhost:8080/api/v1/pdf/rotate \
  -F "file=@rapport.pdf" \
  -F "pages=1-3" \
  -F "degrees=270" \
  --output rapport_rotated.pdf
```

### Comportement sur les erreurs

| Cas | Code HTTP | Message |
|-----|-----------|---------|
| Degrees invalide (ex. 45) | 400 | "La rotation doit être 90, 180 ou 270 degrés" |
| Index hors bornes | 422 | "Index de page invalide : 5 (le document a 3 pages)" |
| Fichier trop grand | 413 | "Le fichier dépasse la limite de 50 MB" |

### Métriques disponibles

| Métrique                      | Type                  | Description                                        |
|-------------------------------|-----------------------|----------------------------------------------------|
| `kovixel.rotate.total`         | Counter               | Total des rotations (tags : `status`, `degrees`)   |
| `kovixel.rotate.duration`      | Timer                 | Durée totale de rotation                           |
| `kovixel.rotate.pages_rotated` | DistributionSummary   | Distribution du nombre de pages tournées           |
| `kovixel.rotate.output_size`   | DistributionSummary   | Distribution des tailles en sortie (bytes)         |
```

---

## Ordre d'exécution recommandé

```
PROMPT 1        PROMPT 2        PROMPT 3        PROMPT 4        PROMPT 5        PROMPT 6
Backend         Backend         Frontend        Frontend        Frontend        Docs
Endpoint        Métriques +     Service +       UI dédiée +     Bonus UX +      README
enrichi +       Tests +         Interface +     Boutons visuels Messages +
RotateResult    CORS            Config          + Résultat méta Validation
```

> **PROMPT 1 et PROMPT 3** peuvent être exécutés en parallèle.  
> **PROMPT 2** nécessite PROMPT 1 terminé.  
> **PROMPT 4 et 5** nécessitent PROMPT 3 terminé.

---

## Critères de validation finale

### Backend
- [ ] `POST /api/v1/pdf/rotate` avec `pages=ALL&degrees=90` → retourne PDF avec headers `X-Pages-Rotated=N`, `X-Total-Pages=N`
- [ ] `POST /api/v1/pdf/rotate` avec `pages=0&degrees=90` → retourne PDF avec `X-Pages-Rotated=1`
- [ ] `POST /api/v1/pdf/rotate` avec `pages=1-3,5&degrees=180` → retourne PDF avec `X-Pages-Rotated=4`
- [ ] `degrees=45` → HTTP 400 avec message explicite
- [ ] `degrees=-90` → normalisé en 270, rotation OK
- [ ] Index hors bornes → HTTP 422 avec message explicite
- [ ] Fichier > 50 MB → HTTP 413
- [ ] Rotation cumulée correcte (page déjà à 90° + 90° = 180°)
- [ ] `mvn test` passe sans erreur (`PdfRotateServiceTest`)
- [ ] Métriques `kovixel.rotate.*` visibles sur `/actuator/metrics`

### Frontend
- [ ] Page `/tools/convert/rotate` affiche les 3 boutons de rotation (90° →, 180° ↓, 90° ←)
- [ ] Bouton actif mis en évidence (fond violet, bordure)
- [ ] Sélecteur de scope : Toutes / Page unique / Sélection
- [ ] Mode "Page unique" : input numérique (1-indexé)
- [ ] Mode "Sélection" : champ texte avec placeholder `1-3, 5, 8-10`
- [ ] Aperçu de rotation animé (icône PDF qui pivote)
- [ ] Résumé de l'action affiché ("Page 2 → rotation de 90°")
- [ ] Validation visuelle du champ plages (bordure verte/rouge)
- [ ] Bouton "Convertir" désactivé si saisie invalide
- [ ] Messages de progression spécifiques à la rotation
- [ ] Écran succès : grille 3 colonnes (pages tournées / angle / taille)
- [ ] "Tourner un autre fichier" → reset propre

---

## Notes d'implémentation

### Rétrocompatibilité avec l'ancien endpoint
L'ancien endpoint acceptait `page=0` (0-indexed, entier unique) et `degrees=90`.
Le nouveau accepte `pages=ALL|0|1-3,5` et `degrees=90|180|270|-90`.

Pour éviter de casser les anciens clients, la méthode `rotate(byte[] pdf, int pageIndex, int degrees)`
dans `PdfManipulationService` est conservée et délègue à `rotateWithMeta()`.

Le paramètre `page` (singulier) de l'ancien endpoint est remplacé par `pages` (pluriel).
Si un client envoie encore `page=0`, le paramètre sera ignoré (defaultValue="ALL" pour `pages`).

### Rotation additive vs absolue
PDFBox stocke la rotation comme un angle absolu dans les métadonnées de la page.
L'implémentation fait `(rotation_actuelle + degrees) % 360` ce qui est additif.
Ce comportement est intentionnel : il permet d'appeler l'endpoint plusieurs fois
et d'obtenir une rotation cumulée (comme un vrai bouton "tourner").

### Aperçu animé CSS
L'aperçu de rotation utilise `transition-transform duration-500` de Tailwind
pour une animation fluide lors du changement de valeur. L'icône PDF pivote
visuellement lorsque l'utilisateur clique sur un bouton de rotation, donnant
un feedback immédiat et intuitif sur l'angle sélectionné.

### Mode 'single' : 0-indexed vs 1-indexed
- Le **backend** reçoit l'index 0-indexed directement dans `pages` (ex: `pages=0`)
- Le **frontend** affiche et accepte le numéro de page 1-indexed dans l'input
  et effectue la conversion `-1` avant d'envoyer à l'API (`rotatePage()` est 0-indexed)
- Cela évite la confusion pour l'utilisateur tout en restant cohérent avec
  l'implémentation PDFBox (0-indexed)

