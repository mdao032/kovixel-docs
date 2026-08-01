# 📋 Diviser un PDF : Roadmap d'implémentation Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers exacts à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## État des lieux avant implémentation

### Ce qui existe déjà ✅
| Composant | Fichier | État |
|---|---|---|
| Endpoint `POST /api/v1/pdf/split` | `ConversionController.java` | Basique — aucun header, aucune validation riche |
| `PdfManipulationService.split()` | `PdfManipulationService.java` | Fonctionnel — PDFBox `extractPages()`, retourne `List<byte[]>` |
| Helper `parsePageRanges()` | `ConversionController.java` | Parse `"1-3,4-6"` → `int[][]`, validation basique |
| Helper `zipPdfs()` | `ConversionController.java` | Crée un ZIP quand plusieurs parties |
| Service Angular | `conversion.service.ts` | `splitPdf(file, pages)` — basique, pas de métadonnées |
| Entrée catalogue | `tools-config.ts` | Config présente, slug `convert/split` |
| Route Angular | `app.routes.ts` | Routage générique OK |
| Quota anonyme | `AnonymousQuotaFilter.java` | À vérifier sur `/api/v1/pdf/split` |

### Ce qui manque ❌
| Gap | Impact |
|---|---|
| `SplitResult` record avec métadonnées | Impossible d'afficher le nombre de parties, pages, taille |
| `ConversionProperties.Split` | Aucune limite configurable (max pages, taille fichier) |
| Headers de réponse enrichis | Frontend aveugle sur le résultat |
| Validation bornes de pages | Crash si page > totalPages sans message clair |
| Mode "une page par fichier" | Cas d'usage fréquent non couvert |
| Mode "toutes les N pages" | Cas d'usage fréquent non couvert |
| Métriques Micrometer | Aucune observabilité |
| Tests unitaires | Aucune couverture |
| UI split dédiée (frontend) | L'outil utilise la dropzone générique — pas de saisie de plages |
| Builder visuel de plages | L'utilisateur ne sait pas comment saisir "1-3,5,8-10" |
| Preview des parties | L'utilisateur ne voit pas combien de parties seront générées |
| Écran succès enrichi | Après split : aucune info sur le résultat (N parties, taille ZIP) |

---

## Vue d'ensemble de l'architecture cible

```
POST /api/v1/pdf/split
   file  = PDF source
   pages = "1-3,5,8-10"     (mode RANGES — défaut)
         | "ALL"             (mode ALL_PAGES — une page par fichier)
         | "EVERY_N:3"       (mode EVERY_N — toutes les 3 pages)
   ───────────────────────────────────────
         │
         ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Validation :                                             │
   │  - fichier ≤ 50 MB                                        │
   │  - fichier est un PDF valide (%PDF magic)                 │
   │  - numéros de pages dans les bornes [1, totalPages]       │
   │  - max 50 parties en sortie                              │
   │  - plages non vides (from ≤ to)                          │
   └──────────────────────────────────────────────────────────┘
         │
         ▼
   PdfManipulationService.splitWithMeta(pdf, pageRanges)
         │
         ▼
   PDFBox extractPages() × N plages
         │
         ▼
   SplitResult {
     parts[],          // List<byte[]>
     partsCount,       // int
     totalPages,       // int (somme des pages de toutes les parties)
     outputSizeBytes,  // long (somme des tailles)
     durationMs        // long
   }
         │
         ▼
   partsCount == 1 ?
     OUI → ResponseEntity<byte[]> (application/pdf, nom = "split_p1-3.pdf")
     NON → ResponseEntity<byte[]> (application/zip, nom = "kovixel_split.zip")
         │
         ▼
   Headers HTTP :
   X-Parts-Count, X-Total-Pages, X-Output-Size-Bytes, X-Processing-Time-Ms
```

### Modes de découpage

| Mode | Paramètre | Exemple | Description |
|---|---|---|---|
| **Plages** | `pages=1-3,5,8-10` | 3 parties | Chaque segment de la liste devient un PDF |
| **Toutes les pages** | `pages=ALL` | N parties (1 par page) | Chaque page devient un PDF distinct |
| **Toutes les N pages** | `pages=EVERY_N:3` | ⌈totalPages/3⌉ parties | Regroupe les pages par paquets de N |

---

## PROMPT 1 — Backend : Enrichir l'endpoint `/api/v1/pdf/split`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`
- `src/main/resources/application.yml`

```
Lis d'abord intégralement :
- ConversionController.java (endpoint split existant lines ~453–468, parsePageRanges, zipPdfs)
- PdfManipulationService.java (méthode split() existante)
- ConversionProperties.java (pour voir la structure des classes imbriquées Merge, Compression)
- application.yml (pour voir kovixel.conversion existant)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : ConversionProperties.java — classe imbriquée Split
─────────────────────────────────────────────────────────────────────────────

Ajoute une classe imbriquée Split dans ConversionProperties, sur le même modèle
que la classe Merge existante :

  @Data
  public static class Split {
      /** Taille maximale du fichier source (50 MB). */
      private long maxFileSizeBytes = 52_428_800L;

      /** Nombre maximum de parties en sortie. */
      private int maxParts = 50;

      /** Nombre maximum de pages dans le document source. */
      private int maxSourcePages = 500;
  }

Ajoute le champ `private Split split = new Split();` dans ConversionProperties.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : application.yml
─────────────────────────────────────────────────────────────────────────────

Dans la section `kovixel.conversion`, ajoute :

  split:
    max-file-size-bytes: 52428800    # 50 MB
    max-parts: 50                    # Maximum de parties en sortie
    max-source-pages: 500            # Maximum de pages dans le document source

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Créer le record SplitResult
─────────────────────────────────────────────────────────────────────────────

Crée un nouveau fichier dans le package com.kovixel.core.conversion :

  package com.kovixel.core.conversion;

  import java.util.List;

  /**
   * Résultat d'un découpage PDF avec toutes les métadonnées.
   * Exposé via les headers HTTP X-* dans la réponse.
   */
  public record SplitResult(
      List<byte[]> parts,
      int          partsCount,
      int          totalPages,
      long         outputSizeBytes,
      long         durationMs
  ) {
      public String summary() {
          return String.format(
              "split: %d parties, %d pages, %d bytes en %d ms",
              partsCount, totalPages, outputSizeBytes, durationMs
          );
      }
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : PdfManipulationService.java — ajouter splitWithMeta()
─────────────────────────────────────────────────────────────────────────────

Ajoute la méthode splitWithMeta() JUSTE APRÈS la méthode split() existante.
Ne supprime PAS split() — conserve-la comme délégation pour compatibilité.

  /**
   * Découpe un PDF en plusieurs parties selon les plages de pages données,
   * et retourne les métadonnées complètes.
   *
   * @param pdf        PDF source en bytes
   * @param pageRanges plages [[from, to], ...] (1-indexed, inclusif)
   * @return SplitResult avec les parties et toutes les métadonnées
   */
  public SplitResult splitWithMeta(byte[] pdf, int[][] pageRanges) {
      if (pageRanges == null || pageRanges.length == 0) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Au moins une plage de pages est requise.");
      }

      long startMs = System.currentTimeMillis();
      List<byte[]> parts  = new ArrayList<>();
      int          totalPages = 0;
      long         outputSize = 0;

      try (PDDocument doc = Loader.loadPDF(pdf)) {
          int docPages = doc.getNumberOfPages();

          // Valider toutes les plages avant de commencer
          for (int i = 0; i < pageRanges.length; i++) {
              int from = pageRanges[i][0];
              int to   = pageRanges[i][1];
              if (from < 1 || to < 1 || from > to) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                          "Plage invalide [" + (i + 1) + "] : " + from + "-" + to +
                          " (from doit être ≥ 1 et ≤ to).");
              }
              if (from > docPages || to > docPages) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR,
                          HttpStatus.UNPROCESSABLE_ENTITY,
                          "Plage [" + (i + 1) + "] (" + from + "-" + to +
                          ") dépasse le nombre de pages du document (" + docPages + ").");
              }
          }

          // Découper
          for (int[] range : pageRanges) {
              byte[] part = extractPages(doc, range[0], range[1]);
              parts.add(part);
              totalPages += (range[1] - range[0] + 1);
              outputSize += part.length;
          }

      } catch (KovixelException e) {
          throw e;
      } catch (Exception e) {
          throw new KovixelException(ErrorCode.PROCESSING_ERROR,
                  HttpStatus.UNPROCESSABLE_ENTITY,
                  "Erreur lors du découpage : " + e.getMessage(), e);
      }

      long durationMs = System.currentTimeMillis() - startMs;
      log.info("Découpage terminé — {} parties, {} pages, {} bytes en {} ms",
               parts.size(), totalPages, outputSize, durationMs);

      return new SplitResult(parts, parts.size(), totalPages, outputSize, durationMs);
  }

  // Mise à jour de la méthode legacy pour déléguer
  public List<byte[]> split(byte[] pdf, int[][] pageRanges) {
      return splitWithMeta(pdf, pageRanges).parts();
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : ConversionController.java — enrichir l'endpoint split
─────────────────────────────────────────────────────────────────────────────

Remplace l'implémentation du endpoint @PostMapping("/api/v1/pdf/split") par :

  @PostMapping("/api/v1/pdf/split")
  @Operation(
      summary = "Découper un PDF en plusieurs parties",
      description = """
          Découpe un PDF selon des plages de pages ou des modes prédéfinis.

          **Modes de découpage** :
          - `pages=1-3,5,8-10` — plages personnalisées (virgule-séparées)
          - `pages=ALL` — une page par fichier (retourne un ZIP)
          - `pages=EVERY_N:3` — toutes les 3 pages (retourne un ZIP)

          **Sortie** :
          - 1 partie → `application/pdf` direct
          - N parties → `application/zip` (kovixel_split.zip)

          **Headers de réponse** :
          `X-Parts-Count`, `X-Total-Pages`, `X-Output-Size-Bytes`, `X-Processing-Time-Ms`
          """
  )
  @CheckQuota(feature = FeatureType.CONVERSION)
  public ResponseEntity<?> split(
          @RequestParam("file") MultipartFile file,
          @RequestParam String pages,
          @AuthenticationPrincipal UserDetails userDetails) throws Exception {

      ConversionProperties.Split cfg = conversionProperties.getSplit();

      // ── Validation taille fichier ────────────────────────────────────────────
      if (file.getSize() > cfg.getMaxFileSizeBytes()) {
          throw new KovixelException(ErrorCode.FILE_TOO_LARGE, HttpStatus.PAYLOAD_TOO_LARGE,
                  "Le fichier dépasse la limite de " +
                  (cfg.getMaxFileSizeBytes() / 1_048_576) + " MB.");
      }

      byte[] pdfBytes = file.getBytes();

      // ── Résolution des plages selon le mode ──────────────────────────────────
      int[][] ranges = resolvePageRanges(pages, pdfBytes, cfg);

      // ── Validation nombre de parties ─────────────────────────────────────────
      if (ranges.length > cfg.getMaxParts()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Trop de parties demandées (" + ranges.length +
                  "). Maximum : " + cfg.getMaxParts() + ".");
      }

      // ── Découpage ────────────────────────────────────────────────────────────
      SplitResult result = pdfManipulationService.splitWithMeta(pdfBytes, ranges);
      log.info("split — {}", result.summary());

      // ── Construction de la réponse ───────────────────────────────────────────
      String baseName = sanitizeFilename(file.getOriginalFilename());

      if (result.partsCount() == 1) {
          // Réponse PDF direct
          String outName = baseName + "_part1.pdf";
          return ResponseEntity.ok()
                  .header(HttpHeaders.CONTENT_TYPE, "application/pdf")
                  .header(HttpHeaders.CONTENT_DISPOSITION,
                          ContentDisposition.attachment()
                                  .filename(outName, StandardCharsets.UTF_8)
                                  .build().toString())
                  .header("X-Parts-Count",           "1")
                  .header("X-Total-Pages",            String.valueOf(result.totalPages()))
                  .header("X-Output-Size-Bytes",      String.valueOf(result.outputSizeBytes()))
                  .header("X-Processing-Time-Ms",     String.valueOf(result.durationMs()))
                  .body(result.parts().get(0));
      } else {
          // Réponse ZIP
          byte[] zip = zipSplitParts(result.parts(), baseName);
          return ResponseEntity.ok()
                  .header(HttpHeaders.CONTENT_TYPE, "application/zip")
                  .header(HttpHeaders.CONTENT_DISPOSITION,
                          ContentDisposition.attachment()
                                  .filename("kovixel_split.zip", StandardCharsets.UTF_8)
                                  .build().toString())
                  .header("X-Parts-Count",           String.valueOf(result.partsCount()))
                  .header("X-Total-Pages",            String.valueOf(result.totalPages()))
                  .header("X-Output-Size-Bytes",      String.valueOf(result.outputSizeBytes()))
                  .header("X-Processing-Time-Ms",     String.valueOf(result.durationMs()))
                  .body(zip);
      }
  }

Ajoute ces méthodes privées dans ConversionController :

  /**
   * Résout les plages de pages selon le mode demandé.
   * Supporte : "1-3,5", "ALL", "EVERY_N:3"
   */
  private int[][] resolvePageRanges(String pages, byte[] pdf,
                                    ConversionProperties.Split cfg) throws Exception {
      if (pages == null || pages.isBlank()) {
          throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                  "Le paramètre 'pages' est obligatoire.");
      }

      // Mode ALL : une page par fichier
      if ("ALL".equalsIgnoreCase(pages.trim())) {
          try (PDDocument doc = Loader.loadPDF(pdf)) {
              int n = doc.getNumberOfPages();
              if (n > cfg.getMaxParts()) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                          "Le document a " + n + " pages. Maximum " +
                          cfg.getMaxParts() + " parties.");
              }
              int[][] ranges = new int[n][2];
              for (int i = 0; i < n; i++) {
                  ranges[i][0] = i + 1;
                  ranges[i][1] = i + 1;
              }
              return ranges;
          }
      }

      // Mode EVERY_N : toutes les N pages
      if (pages.toUpperCase().startsWith("EVERY_N:")) {
          int n;
          try { n = Integer.parseInt(pages.substring(8).trim()); }
          catch (NumberFormatException e) {
              throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                      "Format EVERY_N invalide. Attendu : EVERY_N:3");
          }
          if (n < 1) {
              throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                      "N doit être ≥ 1.");
          }
          try (PDDocument doc = Loader.loadPDF(pdf)) {
              int total = doc.getNumberOfPages();
              int parts = (int) Math.ceil((double) total / n);
              if (parts > cfg.getMaxParts()) {
                  throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                          "Trop de parties (" + parts + "). Maximum : " + cfg.getMaxParts() + ".");
              }
              int[][] ranges = new int[parts][2];
              for (int i = 0; i < parts; i++) {
                  ranges[i][0] = i * n + 1;
                  ranges[i][1] = Math.min((i + 1) * n, total);
              }
              return ranges;
          }
      }

      // Mode RANGES (défaut) : "1-3,5,8-10"
      return parsePageRanges(pages);
  }

  /**
   * Crée un ZIP nommé intelligemment avec les parties du split.
   * Nommage : baseName_part001.pdf, baseName_part002.pdf, ...
   */
  private byte[] zipSplitParts(List<byte[]> parts, String baseName) throws Exception {
      ByteArrayOutputStream baos = new ByteArrayOutputStream();
      try (ZipOutputStream zos = new ZipOutputStream(baos)) {
          for (int i = 0; i < parts.size(); i++) {
              String entryName = String.format("%s_part%03d.pdf", baseName, i + 1);
              zos.putNextEntry(new ZipEntry(entryName));
              zos.write(parts.get(i));
              zos.closeEntry();
          }
      }
      return baos.toByteArray();
  }

  /**
   * Nettoie le nom du fichier original pour l'utiliser dans les noms de sortie.
   */
  private String sanitizeFilename(String original) {
      if (original == null || original.isBlank()) return "document";
      return original.replaceAll("\\.[^.]+$", "")
                     .replaceAll("[^a-zA-Z0-9_\\-]", "_")
                     .substring(0, Math.min(50, original.length()));
  }

Ajoute aussi les imports nécessaires :
  import com.kovixel.core.conversion.SplitResult;
  import java.nio.charset.StandardCharsets;
  import java.util.zip.ZipEntry;
  import java.util.zip.ZipOutputStream;
```

---

## PROMPT 2 — Backend : Métriques, CORS & Tests unitaires

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`
- `src/main/java/com/kovixel/common/config/WebConfig.java`
- `src/main/java/com/kovixel/common/security/SecurityConfig.java`

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/PdfSplitServiceTest.java`

```
Lis d'abord :
- PdfManipulationService.java (pour voir splitWithMeta() ajouté en PROMPT 1)
- PdfMergeServiceTest.java (pour voir le pattern de tests PDFBox existant)
- WebConfig.java et SecurityConfig.java (exposedHeaders déjà configurés)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Métriques Micrometer dans splitWithMeta()
─────────────────────────────────────────────────────────────────────────────

MeterRegistry est DÉJÀ injecté dans PdfManipulationService (ajouté pour merge).
Utilise-le directement.

Dans splitWithMeta(), après le retour du résultat, enregistre :

  kovixel.split.total
    Type : Counter
    Tags : status=SUCCESS|ERROR, parts_count={result.partsCount()}
    Incrémenter dans un bloc finally (SUCCESS si pas d'exception, ERROR sinon)

  kovixel.split.duration
    Type : Timer
    Enregistrer la durée totale

  kovixel.split.parts_count
    Type : DistributionSummary
    Valeur : result.partsCount()

  kovixel.split.output_size
    Type : DistributionSummary
    Valeur : result.outputSizeBytes()

En cas d'exception :
  - Counter kovixel.split.total avec tag status=ERROR
  - Puis relancer l'exception

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : CORS — exposer les headers de split
─────────────────────────────────────────────────────────────────────────────

Dans WebConfig.java, vérifie que .exposedHeaders() contient :
  "X-Parts-Count"

(X-Total-Pages, X-Output-Size-Bytes, X-Processing-Time-Ms sont déjà présents
depuis les implémentations merge et compress.)

Idem dans SecurityConfig.java.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Tests unitaires PdfSplitServiceTest
─────────────────────────────────────────────────────────────────────────────

Crée PdfSplitServiceTest.java sur le modèle de PdfMergeServiceTest.

  @ExtendWith(MockitoExtension.class)
  class PdfSplitServiceTest {

    private PdfManipulationService service;

    @BeforeAll
    static void generateTestPdfs() {
        // Générer un PDF de 6 pages avec PDFBox
        // (utiliser le même helper que PdfMergeServiceTest)
    }

    @BeforeEach
    void setUp() {
        // Instancier PdfManipulationService avec un MeterRegistry mock
        MeterRegistry registry = new SimpleMeterRegistry();
        service = new PdfManipulationService(..., registry);
    }

    Tests à écrire :

    splitWithMeta() avec plage valide [1-3]
      → SplitResult non null, partsCount = 1, totalPages = 3
      → parts.get(0) commence par "%PDF"
      → outputSizeBytes > 0

    splitWithMeta() avec 2 plages [1-2, 3-4]
      → partsCount = 2, totalPages = 4

    splitWithMeta() avec plage hors bornes (page > totalPages)
      → KovixelException avec message "dépasse le nombre de pages"

    splitWithMeta() avec plage invalide (from > to)
      → KovixelException VALIDATION_ERROR

    splitWithMeta() avec plages null
      → KovixelException "Au moins une plage"

    split() legacy délègue à splitWithMeta()
      → Retourne la même liste que splitWithMeta().parts()

    splitWithMeta() avec 6 pages en mode ALL (6 plages [[1,1],[2,2],...])
      → partsCount = 6, totalPages = 6
  }
```

---

## PROMPT 3 — Frontend : Service, Interface & Configuration

**Fichiers à modifier :**
- `kovixel-ui/src/app/core/services/conversion.service.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`

```
Lis d'abord :
- conversion.service.ts (splitPdf() existant, MergeMeta pour le pattern)
- tools-config.ts (entrée convert/split existante)

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Interface SplitMeta dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute l'interface SplitMeta juste après MergeMeta :

  /** Métadonnées de découpage lues depuis les headers X-* de la réponse HTTP. */
  export interface SplitMeta {
    /** Nombre de parties générées (X-Parts-Count) */
    partsCount:      number;
    /** Nombre total de pages dans toutes les parties (X-Total-Pages) */
    totalPages:      number;
    /** Taille totale des fichiers produits en bytes (X-Output-Size-Bytes) */
    outputSizeBytes: number;
    /** Durée de traitement côté serveur en ms (X-Processing-Time-Ms) */
    durationMs:      number;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Méthode splitPdfWithMeta() dans conversion.service.ts
─────────────────────────────────────────────────────────────────────────────

Ajoute splitPdfWithMeta() juste après splitPdf() (conserve splitPdf() pour
la compatibilité avec le code existant) :

  splitPdfWithMeta(
    file: File,
    pages: string,
  ): Observable<{ blob: Blob; meta: SplitMeta }> {
    const params = new HttpParams().set('pages', pages);

    return this.http
      .post(`${this.base}/pdf/split`, this._single(file), {
        params,
        responseType: 'blob',
        observe: 'response',
      })
      .pipe(
        map((response) => {
          const blob = response.body as Blob;
          const h    = response.headers;
          const meta: SplitMeta = {
            partsCount:      Number(h.get('X-Parts-Count')          ?? 1),
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

Enrichis l'entrée slug: 'convert/split' :

  {
    slug:            'convert/split',
    name:            'Diviser un PDF',
    description:     'Extrayez des pages spécifiques de votre PDF',
    longDescription: 'Découpez un PDF en plusieurs parties selon des plages de pages (ex : 1-3, 5, 8-10). Obtenez un PDF par plage ou une page par fichier. Téléchargement en ZIP automatique.',
    category:        'compress',
    icon:            Scissors,
    estimatedTime:   '~3 secondes',
    isPro:           false,
    isAvailable:     true,
    backendEndpoint: '/api/v1/pdf/split',
  },
```

---

## PROMPT 4 — Frontend : UI dédiée dans tool-page.component.ts

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord intégralement tool-page.component.ts pour comprendre :
- Le pattern isCompressTool() et isMergeTool() (modèle à suivre)
- La machine à états (idle → selected → uploading → success/error)
- La méthode startConversion() et ses cas spéciaux (après le cas merge)
- Le bloc state() === 'selected' actuel

Ne modifie pas l'architecture générale du composant.
Ajoute uniquement le traitement spécial pour le slug 'convert/split',
en suivant exactement le même pattern que convert/compress et convert/merge.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Import SplitMeta
─────────────────────────────────────────────────────────────────────────────

Modifie la ligne d'import :
  import { CompressionMeta, MergeMeta, SplitMeta } from '../../core/services/conversion.service';

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Signaux et computed pour l'outil split
─────────────────────────────────────────────────────────────────────────────

Ajoute ces signaux dans la classe, juste après les signaux merge :

  // ── Split tool signals ────────────────────────────────────────────────────
  /** Métadonnées du dernier split réalisé */
  readonly splitMeta        = signal<SplitMeta | null>(null);
  /** Mode de découpage sélectionné */
  readonly splitMode        = signal<'ranges' | 'all' | 'every_n'>('ranges');
  /** Chaîne de plages saisie par l'utilisateur (ex : "1-3,5,8-10") */
  readonly splitRanges      = signal<string>('');
  /** Valeur N pour le mode EVERY_N */
  readonly splitEveryN      = signal<number>(2);
  /** true uniquement sur l'outil de découpage PDF */
  readonly isSplitTool      = computed(() => this.tool()?.slug === 'convert/split');
  /** Construit le paramètre `pages` à envoyer à l'API selon le mode */
  readonly splitPagesParam  = computed(() => {
    switch (this.splitMode()) {
      case 'all':     return 'ALL';
      case 'every_n': return `EVERY_N:${this.splitEveryN()}`;
      default:        return this.splitRanges().trim();
    }
  });
  /** true si le paramètre pages est valide pour activer le bouton */
  readonly splitIsValid     = computed(() => {
    const p = this.splitPagesParam();
    if (!p || p.trim() === '') return false;
    if (p === 'ALL') return true;
    if (p.startsWith('EVERY_N:')) return this.splitEveryN() >= 1;
    // Valider format basique "1-3,5" : doit contenir au moins un chiffre
    return /^[\d,\-\s]+$/.test(p);
  });

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Cas spécial split dans startConversion()
─────────────────────────────────────────────────────────────────────────────

Dans startConversion(), ajoute le cas split JUSTE APRÈS le cas merge :

  // ── Cas spécial : outil de découpage — utilise splitPdfWithMeta ──────────
  if (t.slug === 'convert/split') {
    const file  = this.selectedFile();
    const pages = this.splitPagesParam();
    if (!file) return;
    if (!this.splitIsValid()) {
      this.errorMessage.set('Veuillez saisir au moins une plage de pages valide (ex : 1-3,5).');
      this.state.set('error');
      return;
    }

    this.state.set('uploading');
    this.uploadProgress.set(0);
    this.splitMeta.set(null);
    this.startMsgRotation();
    this.startFakeProgress(0, 92);

    this.uploadSub = this.convSvc.splitPdfWithMeta(file, pages).subscribe({
      next: ({ blob, meta }) => {
        this.stopFakeProgress();
        this.uploadProgress.set(100);
        this.splitMeta.set(meta);
        this.resultBlob.set(blob);
        const ext = meta.partsCount > 1 ? '.zip' : '.pdf';
        const base = file.name.replace(/\.[^.]+$/, '');
        this.resultFilename.set(`${base}_split${ext}`);
        this.stopMsgRotation();
        this.state.set('success');
        if (!this.authSvc.isAuthenticated()) {
          this.quotaSvc.decrementLocally();
        }
      },
      error: (err) => {
        this.stopFakeProgress();
        this.stopMsgRotation();
        const msg = err?.error?.message ?? err?.message ?? 'Erreur lors du découpage.';
        this.errorMessage.set(msg);
        this.state.set('error');
      },
    });
    return;
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Réinitialisation
─────────────────────────────────────────────────────────────────────────────

Dans clearFile() ajoute : this.splitMeta.set(null);

Dans reset() ajoute :
  this.splitMeta.set(null);
  this.splitMode.set('ranges');
  this.splitRanges.set('');
  this.splitEveryN.set(2);

Dans la section de réinitialisation en haut de startConversion() ajoute :
  this.splitMeta.set(null);

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 5 : Bloc d'options split dans le template (state 'selected')
─────────────────────────────────────────────────────────────────────────────

Localise dans le template le bloc @if (isCompressTool()) qui affiche les
options de compression. Juste APRÈS ce bloc (dans le même state 'selected'),
ajoute un bloc @if (isSplitTool()) :

  @if (isSplitTool()) {
    <div class="space-y-4 rounded-xl border p-4"
         style="background: rgba(168,85,247,0.04); border-color: rgba(168,85,247,0.18)">

      <!-- Titre -->
      <p class="text-xs font-semibold uppercase tracking-widest"
         style="color: var(--text-muted)">Mode de découpage</p>

      <!-- Sélecteur de mode -->
      <div class="flex flex-col gap-2">
        <!-- Mode : Plages personnalisées -->
        <label class="flex items-start gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
               [style.background]="splitMode()==='ranges' ? 'rgba(168,85,247,0.10)' : 'transparent'"
               [style.border]="splitMode()==='ranges' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
          <input type="radio" name="splitMode" value="ranges"
                 [checked]="splitMode()==='ranges'"
                 (change)="splitMode.set('ranges')"
                 style="accent-color:#a855f7; margin-top:3px; flex-shrink:0" />
          <div class="flex-1">
            <span class="text-sm font-semibold" style="color: var(--text-primary)">
              Plages personnalisées
            </span>
            <p class="text-xs mt-0.5" style="color: var(--text-muted)">
              Ex : 1-3, 5, 8-10 → 3 fichiers PDF
            </p>
            @if (splitMode() === 'ranges') {
              <input type="text"
                     [value]="splitRanges()"
                     (input)="splitRanges.set($any($event.target).value)"
                     placeholder="1-3, 5, 8-10"
                     class="mt-2 w-full rounded-lg px-3 py-2 text-sm border font-mono"
                     style="background:rgba(255,255,255,0.06);
                            border-color:rgba(139,92,246,0.35);
                            color:var(--text-primary);
                            outline:none" />
              <p class="text-xs mt-1" style="color: var(--text-muted)">
                Séparez les plages par des virgules. Utilisez
                <code style="color:#a855f7">1-5</code> pour une plage ou
                <code style="color:#a855f7">3</code> pour une page seule.
              </p>
            }
          </div>
        </label>

        <!-- Mode : Une page par fichier -->
        <label class="flex items-start gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
               [style.background]="splitMode()==='all' ? 'rgba(168,85,247,0.10)' : 'transparent'"
               [style.border]="splitMode()==='all' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
          <input type="radio" name="splitMode" value="all"
                 [checked]="splitMode()==='all'"
                 (change)="splitMode.set('all')"
                 style="accent-color:#a855f7; margin-top:3px; flex-shrink:0" />
          <div class="flex-1">
            <span class="text-sm font-semibold" style="color: var(--text-primary)">
              Une page par fichier
            </span>
            <p class="text-xs mt-0.5" style="color: var(--text-muted)">
              Chaque page devient un PDF distinct — téléchargement en ZIP
            </p>
          </div>
        </label>

        <!-- Mode : Toutes les N pages -->
        <label class="flex items-start gap-3 cursor-pointer rounded-xl p-2.5 transition-all"
               [style.background]="splitMode()==='every_n' ? 'rgba(168,85,247,0.10)' : 'transparent'"
               [style.border]="splitMode()==='every_n' ? '1px solid rgba(168,85,247,0.35)' : '1px solid transparent'">
          <input type="radio" name="splitMode" value="every_n"
                 [checked]="splitMode()==='every_n'"
                 (change)="splitMode.set('every_n')"
                 style="accent-color:#a855f7; margin-top:3px; flex-shrink:0" />
          <div class="flex-1">
            <div class="flex items-center gap-3 flex-wrap">
              <span class="text-sm font-semibold" style="color: var(--text-primary)">
                Toutes les
              </span>
              @if (splitMode() === 'every_n') {
                <input type="number" min="1" max="100"
                       [value]="splitEveryN()"
                       (input)="splitEveryN.set(+$any($event.target).value || 2)"
                       class="w-16 rounded-lg px-2 py-1 text-sm border text-center"
                       style="background:rgba(255,255,255,0.06);
                              border-color:rgba(139,92,246,0.35);
                              color:var(--text-primary)" />
              } @else {
                <span class="font-bold text-sm" style="color:#a855f7">
                  {{ splitEveryN() }}
                </span>
              }
              <span class="text-sm font-semibold" style="color: var(--text-primary)">
                pages
              </span>
            </div>
            <p class="text-xs mt-0.5" style="color: var(--text-muted)">
              Regroupe les pages par paquets de {{ splitEveryN() }} — téléchargement en ZIP
            </p>
          </div>
        </label>
      </div>

      <!-- Aperçu du paramètre pages -->
      @if (splitPagesParam()) {
        <div class="flex items-center gap-2 px-1">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none"
               stroke="#a855f7" stroke-width="2.5" stroke-linecap="round">
            <polyline points="20 6 9 17 4 12"/>
          </svg>
          <code class="text-xs" style="color:#a855f7">pages={{ splitPagesParam() }}</code>
        </div>
      }
    </div>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 6 : Bloc résultat enrichi pour split dans le state 'success'
─────────────────────────────────────────────────────────────────────────────

Localise le bloc @else if (isMergeTool() && mergeMeta()) dans le template.
Juste APRÈS ce bloc, ajoute :

  @else if (isSplitTool() && splitMeta()) {
    <div class="rounded-2xl border p-5 space-y-4"
         style="background: rgba(255,255,255,0.025); border-color: rgba(139,92,246,0.20)">

      <!-- Titre succès -->
      <div class="flex items-center gap-2">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
             stroke="#34d399" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="20 6 9 17 4 12"/>
        </svg>
        <p class="font-display font-semibold text-base" style="color: #34d399">
          @if (splitMeta()!.partsCount > 1) { Découpage réussi — ZIP prêt }
          @else { Page(s) extraite(s) avec succès }
        </p>
      </div>

      <!-- Grille métriques -->
      <div class="grid grid-cols-3 gap-3 text-center">
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Parties</p>
          <p class="font-display font-bold text-lg" style="color: #a855f7">
            {{ splitMeta()!.partsCount }}
          </p>
        </div>
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Pages</p>
          <p class="font-display font-bold text-lg" style="color: var(--text-primary)">
            {{ splitMeta()!.totalPages }}
          </p>
        </div>
        <div class="rounded-xl p-3"
             style="background: rgba(255,255,255,0.04); border: 1px solid rgba(139,92,246,0.12)">
          <p class="text-xs mb-1" style="color: var(--text-muted)">Taille</p>
          <p class="font-display font-bold text-sm" style="color: var(--text-primary)">
            {{ formatBytes(splitMeta()!.outputSizeBytes) }}
          </p>
        </div>
      </div>

      <!-- Info ZIP -->
      @if (splitMeta()!.partsCount > 1) {
        <p class="text-xs px-1" style="color: var(--text-muted)">
          📦 Le ZIP contient {{ splitMeta()!.partsCount }} fichiers PDF nommés
          <code style="color:#a855f7">document_part001.pdf</code>,
          <code style="color:#a855f7">document_part002.pdf</code>…
        </p>
      }
    </div>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 7 : Labels adaptatifs dans le state 'success'
─────────────────────────────────────────────────────────────────────────────

Dans le template du state 'success', adapte les labels des boutons existants :

  Bouton téléchargement :
  @if (isCompressTool()) { Télécharger le PDF compressé }
  @else if (isMergeTool()) { Télécharger le PDF fusionné }
  @else if (isSplitTool() && splitMeta()!.partsCount > 1) { Télécharger le ZIP ({{ splitMeta()!.partsCount }} fichiers) }
  @else if (isSplitTool()) { Télécharger le PDF découpé }
  @else { Télécharger le fichier }

  Bouton recommencer :
  @if (isCompressTool()) { Compresser un autre fichier }
  @else if (isMergeTool()) { Fusionner d'autres fichiers }
  @else if (isSplitTool()) { Découper un autre fichier }
  @else { Traiter un autre fichier }

  L'action du bouton recommencer pour split appelle reset() (retour à idle
  avec rechargement du fichier = clearFile()).
```

---

## PROMPT 5 — Frontend : Bonus UX & Messages de progression

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`

```
Lis d'abord le résultat du PROMPT 4 pour comprendre l'état actuel.

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 1 : Messages de progression spécifiques au split
─────────────────────────────────────────────────────────────────────────────

Ajoute ce tableau de constantes juste après MERGE_MESSAGES :

  const SPLIT_MESSAGES = [
    'Analyse du PDF…',
    'Lecture des plages de pages…',
    'Extraction des pages sélectionnées…',
    'Création des fichiers PDF…',
    'Compression du ZIP…',
    'Finalisation…',
  ];

Dans startMsgRotation(), ajoute le cas split :
  const messages = this.isMergeTool()  ? MERGE_MESSAGES
                 : this.isSplitTool()  ? SPLIT_MESSAGES
                 : PROCESSING_MESSAGES;

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 2 : Aperçu du nombre de parties (computed)
─────────────────────────────────────────────────────────────────────────────

Ajoute le computed :

  /** Estimation du nombre de parties basée sur le paramètre pages saisi */
  readonly splitEstimatedParts = computed(() => {
    const p = this.splitPagesParam();
    if (!p || p.trim() === '') return 0;
    if (p === 'ALL') return null;          // inconnu sans connaître le nb de pages
    if (p.startsWith('EVERY_N:')) return null;
    // Compter les segments séparés par virgule
    return p.split(',').filter(s => s.trim().length > 0).length;
  });

Affiche dans la zone d'options split, en dessous de l'aperçu du paramètre :

  @if (splitEstimatedParts() !== null && splitEstimatedParts()! > 0) {
    <p class="text-xs px-1" style="color: var(--text-muted)">
      → <strong style="color: var(--text-secondary)">{{ splitEstimatedParts() }}</strong>
      fichier(s) PDF seront générés
      @if (splitEstimatedParts()! > 1) { et téléchargés dans un ZIP }
    </p>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 3 : Validation visuelle du champ de plages
─────────────────────────────────────────────────────────────────────────────

Sur l'input de plages (mode 'ranges'), ajoute une bordure colorée selon la
validité du contenu :

  [style.border-color]="splitRanges().trim() && !splitIsValid()
    ? '#ef4444'
    : splitRanges().trim() && splitIsValid()
    ? '#34d399'
    : 'rgba(139,92,246,0.35)'"

Si le champ est non vide mais invalide, affiche un message d'erreur inline :

  @if (splitMode() === 'ranges' && splitRanges().trim() && !splitIsValid()) {
    <p class="text-xs mt-1" style="color: #ef4444">
      ⚠ Format invalide. Exemples valides : <code>1-3</code>, <code>1-3, 5, 8-10</code>
    </p>
  }

─────────────────────────────────────────────────────────────────────────────
ÉTAPE 4 : Désactivation du bouton Convertir si invalide
─────────────────────────────────────────────────────────────────────────────

Le bouton "Convertir maintenant" générique (dans le state 'selected')
est déjà masqué pour l'outil split puisque le bouton de conversion
est géré par le bloc générique ci-dessous.

Dans le bloc générique du bouton Convertir, ajoute pour l'outil split
la désactivation si !splitIsValid() :

  [disabled]="isSplitTool() && !splitIsValid()"
  [style.opacity]="isSplitTool() && !splitIsValid() ? '0.4' : '1'"
```

---

## PROMPT 6 — Documentation & Mise à jour README

**Fichiers à modifier :**
- `kovixel/README.md`

```
Ajoute une section "## Diviser un PDF" dans README.md,
juste après la section "## Fusionner PDFs" existante.

La section doit documenter :

### Endpoint
POST /api/v1/pdf/split

### Paramètres
| Paramètre | Type     | Défaut | Description |
|-----------|----------|--------|-------------|
| `file`    | `File`   | —      | PDF source (multipart, 1 fichier) |
| `pages`   | `string` | —      | Plages de pages (voir modes ci-dessous) |

### Modes de découpage
| Valeur de `pages`  | Mode            | Exemple de sortie              |
|--------------------|-----------------|-------------------------------|
| `1-3,5,8-10`       | Plages custom   | 3 PDFs → ZIP                  |
| `ALL`              | Page par page   | N PDFs → ZIP (N = nb de pages)|
| `EVERY_N:3`        | Toutes les 3p   | ⌈N/3⌉ PDFs → ZIP              |

### Headers de réponse
| Header                  | Description                                      |
|-------------------------|--------------------------------------------------|
| `X-Parts-Count`         | Nombre de parties générées                       |
| `X-Total-Pages`         | Nombre total de pages dans toutes les parties    |
| `X-Output-Size-Bytes`   | Taille totale produite en bytes                  |
| `X-Processing-Time-Ms`  | Durée de traitement côté serveur en ms           |

### Sortie
- **1 partie** → réponse `application/pdf` directe
- **N parties** → réponse `application/zip` (kovixel_split.zip)

### Limites par configuration
| Propriété                               | Défaut   | Description                  |
|-----------------------------------------|----------|------------------------------|
| `kovixel.conversion.split.max-file-size-bytes` | 50 MB | Taille max du fichier source |
| `kovixel.conversion.split.max-parts`     | 50       | Maximum de parties en sortie |
| `kovixel.conversion.split.max-source-pages` | 500   | Maximum de pages source      |

### Exemples de requêtes

```bash
# Plages personnalisées → 3 PDFs dans un ZIP
curl -X POST http://localhost:8080/api/v1/pdf/split \
  -F "file=@rapport.pdf" \
  -F "pages=1-3,5,8-10" \
  --output split_result.zip

# Une page par fichier → ZIP
curl -X POST http://localhost:8080/api/v1/pdf/split \
  -F "file=@rapport.pdf" \
  -F "pages=ALL" \
  --output pages.zip

# Toutes les 5 pages
curl -X POST http://localhost:8080/api/v1/pdf/split \
  -F "file=@rapport.pdf" \
  -F "pages=EVERY_N:5" \
  --output chapitres.zip
```

### Comportement sur les erreurs de plages

| Cas | Code HTTP | Message |
|-----|-----------|---------|
| Plage hors bornes (page > totalPages) | 422 | "Plage [2] (8-12) dépasse le nombre de pages (10)" |
| Format invalide "abc" | 400 | "Format de plage invalide : 'abc'. Attendu : '1-3'" |
| Trop de parties | 400 | "Trop de parties demandées (55). Maximum : 50" |
| Fichier trop grand | 413 | "Le fichier dépasse la limite de 50 MB" |

### Métriques disponibles

| Métrique                     | Type                  | Description                                       |
|------------------------------|-----------------------|---------------------------------------------------|
| `kovixel.split.total`         | Counter               | Total des découpages (tags : `status`, `parts_count`) |
| `kovixel.split.duration`      | Timer                 | Durée totale de découpage                         |
| `kovixel.split.parts_count`   | DistributionSummary   | Distribution du nombre de parties par découpage   |
| `kovixel.split.output_size`   | DistributionSummary   | Distribution des tailles en sortie (bytes)        |
```

---

## Ordre d'exécution recommandé

```
PROMPT 1        PROMPT 2        PROMPT 3        PROMPT 4        PROMPT 5        PROMPT 6
Backend         Backend         Frontend        Frontend        Frontend        Docs
Endpoint        Métriques +     Service +       UI dédiée +     Bonus UX +      README
enrichi +       Tests +         Interface +     Options mode    Messages +
Modes +         CORS            Config          + Résultat méta Validation      
SplitResult
```

> **PROMPT 1 et PROMPT 3** peuvent être exécutés en parallèle.  
> **PROMPT 2** nécessite PROMPT 1 terminé.  
> **PROMPT 4 et 5** nécessitent PROMPT 3 terminé.

---

## Critères de validation finale

### Backend
- [ ] `POST /api/v1/pdf/split` avec `pages=1-3` → retourne PDF avec headers `X-Parts-Count=1`, `X-Total-Pages=3`
- [ ] `POST /api/v1/pdf/split` avec `pages=1-3,4-6` → retourne ZIP avec `X-Parts-Count=2`
- [ ] `POST /api/v1/pdf/split` avec `pages=ALL` → retourne ZIP avec autant de parties que de pages
- [ ] `POST /api/v1/pdf/split` avec `pages=EVERY_N:3` → retourne ZIP avec ⌈N/3⌉ parties
- [ ] Page hors bornes → HTTP 422 avec message explicite (numéro de plage incriminée)
- [ ] Format invalide → HTTP 400
- [ ] Trop de parties → HTTP 400
- [ ] Fichier > 50 MB → HTTP 413
- [ ] `mvn test` passe sans erreur (`PdfSplitServiceTest`)
- [ ] Métriques `kovixel.split.*` visibles sur `/actuator/metrics`

### Frontend
- [ ] Page `/tools/convert/split` affiche le sélecteur de mode (Plages / Une page / Toutes les N)
- [ ] Mode "Plages" : champ texte avec placeholder `1-3, 5, 8-10`
- [ ] Mode "Une page par fichier" : pas d'input supplémentaire
- [ ] Mode "Toutes les N" : input numérique pour N
- [ ] Validation visuelle : bordure verte/rouge selon la validité de la saisie
- [ ] Aperçu du nombre de parties estimées (mode plages uniquement)
- [ ] Bouton "Convertir" désactivé si saisie invalide
- [ ] Messages de progression spécifiques au split
- [ ] Écran succès : grille 3 colonnes (parties / pages / taille)
- [ ] Info ZIP affiché si partsCount > 1
- [ ] Label bouton téléchargement adapté (PDF ou ZIP)
- [ ] "Découper un autre fichier" → reset propre

---

## Notes d'implémentation

### Pourquoi 3 modes et pas juste les plages textuelles ?
Les modes "ALL" et "EVERY_N" couvrent les cas d'usage les plus fréquents
sans forcer l'utilisateur à connaître le nombre de pages de son document.
Ils sont exprimés via des valeurs spéciales du paramètre `pages`
(pas un nouveau paramètre) pour ne pas modifier la signature de l'API.

### ZIP nommé intelligemment
`zipSplitParts()` nomme chaque entrée `[baseName]_part001.pdf` au lieu de
`split_1.pdf` (ancien comportement). Le baseName est extrait du fichier original
et sanitizé pour éviter les caractères spéciaux dans le ZIP.

### Validation côté client (mode plages)
La validation `splitIsValid()` utilise `/^[\d,\-\s]+$/` pour un feedback
instantané. La validation fine (bornes de pages) reste côté serveur car elle
nécessite le nombre de pages du document — information non disponible avant upload.

### Réutilisation de l'extractPages() existant
La méthode `extractPages(PDDocument doc, int from, int to)` est déjà
présente dans `PdfManipulationService`. `splitWithMeta()` la réutilise
directement — aucune duplication.

