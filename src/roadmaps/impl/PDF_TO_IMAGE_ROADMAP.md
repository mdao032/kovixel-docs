# 📋 PDF → Image : Roadmap d'implémentation

> **Contexte** : Le endpoint `/api/v1/convert/pdf-to-images` et la méthode
> `ConversionService.pdfToImages()` existent déjà (PDFBox, PNG/JPG uniquement).
> Cette roadmap étend et industrialise l'implémentation existante.
>
> **Instructions** : Exécuter les prompts dans l'ordre.
> Chaque prompt est autonome et cite les fichiers à modifier.

---

## Vue d'ensemble de l'architecture cible

```
Requête POST /api/v1/convert/pdf-to-images
  params: file, format, dpi, quality, pages, pageRange
        │
        ▼
  ImageConversionOptions (DTO de validation)
        │
        ▼
  ┌──────────────────────────────────────────────────────┐
  │  ImageConversionRouter                               │
  │  (routing par plan + disponibilité moteur)           │
  └──────────────────────────────────────────────────────┘
        │
        ├─ PRO / ENTERPRISE ──► Adobe PDF Services (Export PDF API)
        │                       └─ Formats : JPEG, PNG, GIF, TIFF
        │                       └─ Fallback → PDFBox
        │
        └─ FREE / ANONYMOUS ──► PDFBox + TwelveMonkeys
                                 └─ Formats : JPEG, PNG, WEBP, TIFF, GIF
                                 └─ Fallback → Ghostscript (si installé)

        ▼
  Output selon nombre de pages :
    1 page  → image directe (image/jpeg | image/png | image/webp | ...)
    N pages → archive ZIP  (pages.zip)
```

---

## Formats cibles et moteur recommandé

| Format | MIME type       | PDFBox natif | TwelveMonkeys | Adobe | Ghostscript |
|--------|-----------------|:------------:|:-------------:|:-----:|:-----------:|
| JPEG   | image/jpeg      | ✅            | ✅             | ✅    | ✅           |
| PNG    | image/png       | ✅            | ✅             | ✅    | ✅           |
| WEBP   | image/webp      | ❌            | ✅             | ❌    | ✅           |
| TIFF   | image/tiff      | ❌            | ✅             | ✅    | ✅           |
| GIF    | image/gif       | ❌            | ✅             | ✅    | ✅           |

> WEBP est uniquement disponible via PDFBox+TwelveMonkeys ou Ghostscript.
> Adobe ne supporte pas WEBP — le router bascule automatiquement sur PDFBox.

---

## PROMPT 1 — Configuration & types partagés

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/image/ImageOutputFormat.java`
- `src/main/java/com/kovixel/core/conversion/image/ImageConversionOptions.java`
- `src/main/java/com/kovixel/core/conversion/image/ImageConversionResult.java`

```
1. Dans ConversionProperties.java, ajoute une section imbriquée `image` :

   @NestedConfigurationProperty
   private Image image = new Image();

   @Data
   public static class Image {
       /** DPI par défaut (web = 150, impression = 300). Défaut : 150 */
       private int defaultDpi = 150;

       /** DPI maximum autorisé (prévient les conversions trop lourdes). Défaut : 300 */
       private int maxDpi = 300;

       /** Format de sortie par défaut. Défaut : "png" */
       private String defaultFormat = "png";

       /** Qualité JPEG (0-100). Défaut : 85 */
       private int jpegQuality = 85;

       /** Nombre maximum de pages traitables par requête synchrone. Défaut : 50 */
       private int maxPages = 50;

       /**
        * Active le moteur Ghostscript si disponible sur le système.
        * Désactivé par défaut (non installé en Docker par défaut).
        * Défaut : false
        */
       private boolean ghostscriptEnabled = false;

       /** Chemin vers l'exécutable Ghostscript (si ghostscriptEnabled=true). */
       private String ghostscriptPath = "gs";
   }

2. Dans application.yml, sous kovixel.conversion, ajoute :

   image:
     default-dpi: 150
     max-dpi: 300
     default-format: png
     jpeg-quality: 85
     max-pages: 50
     ghostscript-enabled: false
     ghostscript-path: gs

3. Dans application-dev.yml, surcharge locale :

   image:
     max-dpi: 300
     ghostscript-enabled: false

4. Crée ImageOutputFormat.java (enum) :

   public enum ImageOutputFormat {
       JPEG("jpeg", "image/jpeg",   "jpg",  false),
       PNG ("png",  "image/png",    "png",  false),
       WEBP("webp", "image/webp",   "webp", true),   // requiresTwelveMonkeys=true
       TIFF("tiff", "image/tiff",   "tiff", true),
       GIF ("gif",  "image/gif",    "gif",  true);

       // champs : formatName, mimeType, extension, requiresTwelveMonkeys
       // méthode statique fromString(String) avec fallback PNG
       // méthode boolean isNativelySupported() (JPEG et PNG seulement)
       // méthode boolean isSupportedByAdobe() (JPEG, PNG, GIF, TIFF — pas WEBP)
   }

5. Crée ImageConversionOptions.java (record) :

   public record ImageConversionOptions(
       ImageOutputFormat format,   // format de sortie
       int dpi,                    // résolution (72-300, default 150)
       int quality,                // qualité JPEG (0-100, ignoré pour PNG/WEBP)
       PageSelection pages         // sélection de pages
   ) {
       // méthode factory : static ImageConversionOptions defaults()
       // validation dans le constructeur compact
   }

   public sealed interface PageSelection permits
       PageSelection.All, PageSelection.Single, PageSelection.Range {

       record All() implements PageSelection {}
       record Single(int pageNumber) implements PageSelection {}
       record Range(int from, int to) implements PageSelection {}
   }

6. Crée ImageConversionResult.java (record) :

   public record ImageConversionResult(
       List<byte[]> pages,         // une entrée par page convertie
       ImageOutputFormat format,
       String engine,              // "ADOBE" | "PDFBOX" | "GHOSTSCRIPT"
       int totalPages,
       long durationMs
   ) {
       /** true si une seule page → retourner l'image directement, pas de ZIP */
       public boolean isSinglePage() { return pages.size() == 1; }

       /** MIME type pour la réponse HTTP */
       public String mimeType() { return format.mimeType(); }

       /** Nom de fichier de sortie */
       public String filename(int pageIndex) {
           return "page_" + (pageIndex + 1) + "." + format.extension();
       }
   }
```

---

## PROMPT 2 — Support WEBP, TIFF, GIF via TwelveMonkeys

**Fichiers à modifier :**
- `pom.xml`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/image/ImageIoConfig.java`

```
1. Dans pom.xml, ajoute les dépendances TwelveMonkeys ImageIO (version stable 3.11.0) :

   <!-- TwelveMonkeys ImageIO — support WEBP, TIFF, GIF avancé -->
   <dependency>
       <groupId>com.twelvemonkeys.imageio</groupId>
       <artifactId>imageio-webp</artifactId>
       <version>3.11.0</version>
   </dependency>
   <dependency>
       <groupId>com.twelvemonkeys.imageio</groupId>
       <artifactId>imageio-tiff</artifactId>
       <version>3.11.0</version>
   </dependency>
   <dependency>
       <groupId>com.twelvemonkeys.imageio</groupId>
       <artifactId>imageio-bmp</artifactId>
       <version>3.11.0</version>
   </dependency>

   Vérifie que apache-pdfbox (ou pdfbox) est déjà présent (il l'est dans ConversionService).

2. Crée ImageIoConfig.java — bean Spring qui force l'enregistrement des plugins TwelveMonkeys :

   @Configuration
   public class ImageIoConfig {

       /** Force l'enregistrement des plugins ImageIO au démarrage Spring. */
       @Bean
       public boolean registerImageIoPlugins() {
           IIORegistry registry = IIORegistry.getDefaultInstance();
           registry.registerServiceProviders(ServiceRegistry.lookupProviders(
                   ImageReaderSpi.class,
                   Thread.currentThread().getContextClassLoader()
           ));
           registry.registerServiceProviders(ServiceRegistry.lookupProviders(
                   ImageWriterSpi.class,
                   Thread.currentThread().getContextClassLoader()
           ));
           return true;
       }
   }

   Note : TwelveMonkeys s'enregistre normalement via SPI automatiquement,
   mais ce bean garantit l'enregistrement dans les environnements Spring Boot fat-jar.

3. Pour la qualité JPEG, utilise JPEGImageWriteParam :

   private byte[] encodeJpeg(BufferedImage img, float quality) throws IOException {
       ByteArrayOutputStream baos = new ByteArrayOutputStream();
       ImageWriter writer = ImageIO.getImageWritersByFormatName("jpeg").next();
       ImageWriteParam param = writer.getDefaultWriteParam();
       param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
       param.setCompressionQuality(quality);  // 0.0f–1.0f
       try (ImageOutputStream ios = ImageIO.createImageOutputStream(baos)) {
           writer.setOutput(ios);
           writer.write(null, new IIOImage(img, null, null), param);
       } finally {
           writer.dispose();
       }
       return baos.toByteArray();
   }
```

---

## PROMPT 3 — Moteur PDFBox amélioré (PdfBoxImageEngine)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/image/PdfBoxImageEngine.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionService.java`

```
Crée PdfBoxImageEngine.java — moteur principal pour les utilisateurs FREE.

Classe PdfBoxImageEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  ImageConversionResult convert(byte[] pdfBytes, ImageConversionOptions options)

Logique interne :
  1. Ouvre le PDF avec PDDocument doc = Loader.loadPDF(pdfBytes)
  2. Résout les pages à convertir selon options.pages() :
     - PageSelection.All   → toutes les pages (0 à doc.getNumberOfPages()-1)
     - PageSelection.Single(n) → page n-1 uniquement (validation : 1 ≤ n ≤ nbPages)
     - PageSelection.Range(from, to) → pages from-1 à to-1
  3. Valide que le nombre de pages sélectionnées ≤ props.getImage().getMaxPages()
  4. Pour chaque page :
     a. ImageType selon format : JPEG → RGB, PNG/WEBP → ARGB, TIFF → ARGB
     b. renderer.renderImageWithDPI(pageIndex, dpi, imageType)
     c. Encode selon le format :
        - JPEG : encodeJpeg(img, quality/100f) [méthode privée avec JPEGImageWriteParam]
        - PNG  : ImageIO.write(img, "png", baos)
        - WEBP : ImageIO.write(img, "webp", baos) [via TwelveMonkeys]
        - TIFF : ImageIO.write(img, "tiff", baos) [via TwelveMonkeys]
        - GIF  : convertit en RGB d'abord (GIF ne supporte pas ARGB), puis ImageIO.write
  5. Log par page si > 5 pages : "Page {i}/{total} convertie ({ms}ms)"
  6. Retourne ImageConversionResult

Méthode utilitaire isFormatSupported(ImageOutputFormat) : true si JPEG/PNG (natif)
ou si TwelveMonkeys est enregistré pour le format.

Erreurs :
  - Si page hors limites → KovixelException(ErrorCode.VALIDATION_ERROR, HTTP 400)
  - Si trop de pages → KovixelException(ErrorCode.VALIDATION_ERROR, HTTP 400,
    "Sélectionnez au maximum {maxPages} pages par conversion")
  - Si erreur ImageIO (format non supporté) → KovixelException(PROCESSING_ERROR, HTTP 422)

Dans ConversionService.java :
  - Injecte PdfBoxImageEngine engine
  - Délègue pdfToImages() à engine.convert() avec ImageConversionOptions.defaults()
  - Conserve la signature existante pour la compatibilité :
    public List<byte[]> pdfToImages(byte[] pdf, String format, int dpi)
    → crée un ImageConversionOptions depuis ces paramètres et appelle engine.convert()
```

---

## PROMPT 4 — Moteur Ghostscript (fallback haute qualité)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/image/GhostscriptImageEngine.java`
- `src/main/java/com/kovixel/core/conversion/image/GhostscriptUnavailableException.java`

```
Crée GhostscriptImageEngine.java — moteur de fallback optionnel.

Ghostscript produit des images de qualité supérieure à PDFBox pour les PDFs
complexes (effets transparence, ombres, dégradés). Il supporte nativement
JPEG, PNG, TIFF, et WEBP (gs >= 9.54 avec device "pngox").

Classe GhostscriptImageEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode isAvailable() : boolean
  - Exécute `{ghostscriptPath} --version` avec timeout 3s
  - Résultat mis en cache 60s (volatile + timestamp)
  - Retourne false si ghostscriptEnabled=false dans la config

Méthode convert(byte[] pdfBytes, ImageConversionOptions options) : ImageConversionResult
  1. Crée un répertoire temporaire (Files.createTempDirectory)
  2. Écrit le PDF en fichier temporaire : input.pdf
  3. Construit la commande Ghostscript :
     gs -dBATCH -dNOPAUSE -dSAFER
        -sDEVICE={gsDevice(format)}      # png16m, jpeg, tiff24nc, etc.
        -r{dpi}
        -dJPEGQ={quality}               # uniquement si format=JPEG
        -sOutputFile={tmpDir}/page_%03d.{ext}
        {inputFile}
  4. Exécute via ProcessBuilder avec timeout configurable
  5. Lit les fichiers générés triés par nom
  6. Applique la sélection de pages (filtre les fichiers générés)
  7. Nettoie le répertoire temporaire dans un bloc finally
  8. Retourne ImageConversionResult

  Mapping format → gs device :
    JPEG → "jpeg"
    PNG  → "png16m"
    WEBP → "pngox"   # pseudo-WEBP via PNG optimisé, ou "webp" si gs >= 9.54
    TIFF → "tiff24nc"
    GIF  → "gif24"

Erreurs :
  - Si process.exitValue() != 0 → lance GhostscriptUnavailableException avec stderr
  - Si timeout → kill process + GhostscriptUnavailableException("Timeout Ghostscript")

Nettoyage :
  - Toujours supprimer tmpDir dans finally (FileUtils.deleteDirectory ou Files.walk)

Crée GhostscriptUnavailableException extends RuntimeException.
```

---

## PROMPT 5 — ImageConversionRouter

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/image/ImageConversionRouter.java`

```
Crée ImageConversionRouter.java — orchestre le choix du moteur de conversion.

Classe ImageConversionRouter :
- Annotée @Component, @Slf4j
- Injecte : ConversionProperties, AdobePdfServicesClient,
            PdfBoxImageEngine, GhostscriptImageEngine,
            UserRepository, MeterRegistry

Méthode principale :
  ImageConversionResult route(byte[] pdfBytes, ImageConversionOptions options, Long userId)

Logique de routage :

  1. Résoudre le plan utilisateur (FREE si userId=null)

  2. Si format = WEBP :
     → Adobe ne supporte pas WEBP → passer directement à PDFBox ou Ghostscript

  3. Si plan = PRO ou ENTERPRISE ET props.adobe.isConfigured() :
     → Tenter Adobe Export PDF (JPEG, PNG, GIF, TIFF seulement)
     → Si AdobeServiceException → fallback PDFBox (logguer WARN + métrique)
     → Si WEBP → skip Adobe directement

  4. Sinon (FREE, ANONYMOUS ou format non supporté par Adobe) :
     → PDFBox + TwelveMonkeys (moteur principal)
     → Si erreur → fallback Ghostscript si isAvailable()
     → Si Ghostscript non disponible → propager l'exception PDFBox

  5. À chaque fallback : enregistrer kovixel.conversion.pdf_to_image.fallback
     avec tags : from, to, reason, format

  Métriques à enregistrer après chaque conversion réussie :
    kovixel.conversion.pdf_to_image.total
      tags : engine, format, plan, pageCount=SINGLE|MULTI
    kovixel.conversion.pdf_to_image.duration (Timer)
      tags : engine, format
    kovixel.conversion.pdf_to_image.pages_count (DistributionSummary)
      tags : engine

Adobe pour les images — Méthode dans AdobePdfServicesClient :
  byte[] exportPdfToImage(byte[] pdfBytes, ImageOutputFormat format, int dpi)
  Flux :
    1. POST /token (token cache)
    2. POST /assets → assetID
    3. PUT {uploadUri} → upload du PDF
    4. POST /operation/exportpdf avec body :
       { "assetID": "...",
         "targetFormat": "jpeg"|"png"|"gif"|"tiff",
         "pageRanges": [{"start":1,"end":999}] }
    5. GET {jobUri} polling (status=done ou failed)
    6. GET {downloadUri} → bytes image
  Note : Adobe retourne UNE image par page dans un ZIP pour les PDFs multi-pages.
  → Dézipper la réponse et retourner les bytes de chaque image.
  → AdobeServiceException si format WEBP → doit être géré dans le router AVANT l'appel.
```

---

## PROMPT 6 — Endpoint API amélioré

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Remplace le endpoint pdfToImages() existant par une version enrichie.

Nouveau endpoint POST /api/v1/convert/pdf-to-images :

  @PostMapping("/api/v1/convert/pdf-to-images")
  @Operation(summary = "PDF → Images (JPEG, PNG, WEBP, TIFF, GIF)")
  @CheckQuota(feature = FeatureType.CONVERSION)
  public ResponseEntity<?> pdfToImages(
          @RequestParam("file") MultipartFile file,
          @RequestParam(defaultValue = "png")  String format,
          @RequestParam(defaultValue = "150")  int dpi,
          @RequestParam(defaultValue = "85")   int quality,
          @RequestParam(required = false)       String pages,   // "all", "1", "2-5"
          @AuthenticationPrincipal UserDetails userDetails) throws Exception

Validation des paramètres :
  - format   → ImageOutputFormat.fromString(format) [IllegalArgumentException → 400]
  - dpi      → 72 ≤ dpi ≤ props.image.maxDpi [sinon → 400 "DPI invalide (72-300)"]
  - quality  → 1 ≤ quality ≤ 100 [sinon → 400]
  - pages    → parser via PageSelectionParser.parse(pages) :
               null / "all" → PageSelection.All()
               "3"          → PageSelection.Single(3)
               "2-7"        → PageSelection.Range(2, 7)
               sinon        → 400 "Format invalide pour 'pages' (ex: all, 3, 2-7)"

Crée PageSelectionParser.java :
  public final class PageSelectionParser {
      public static PageSelection parse(String pages) { ... }
  }

Seuil async : file.getSize() > ASYNC_THRESHOLD_BYTES → submitAsync
  (passe format, dpi, quality, pages en métadonnées du job)

Réponse :
  - result.isSinglePage() → fileResponse(bytes, "page_1.{ext}", mimeType)
  - multi-pages → ZIP :
    * ZipOutputStream avec une entrée par page : "page_001.{ext}", "page_002.{ext}"...
    * fileResponse(zipBytes, "pages_{timestamp}.zip", "application/zip")
    * Header X-Page-Count: {totalPages} dans la réponse

Helper zipImages(ImageConversionResult result) → byte[] :
  Utilise ZipOutputStream, nomme les fichiers page_%03d.{ext},
  ajoute un manifeste "manifest.json" avec les métadonnées :
  { "format": "png", "dpi": 150, "totalPages": 5, "engine": "PDFBOX" }

Headers de réponse à ajouter :
  X-Conversion-Engine: ADOBE|PDFBOX|GHOSTSCRIPT
  X-Page-Count: {n}
  X-Processing-Time-Ms: {ms}
```

---

## PROMPT 7 — Frontend : page outil PDF → Image

**Fichiers à modifier :**
- `kovixel-ui/src/app/core/config/tools-config.ts` (si l'outil n'est pas encore listé)
- `kovixel-ui/src/app/features/tools/tool-page.component.ts` (ou composant dédié)
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
1. Dans ConversionService Angular (conversion.service.ts), ajoute :

   pdfToImages(
     file: File,
     format: 'jpeg' | 'png' | 'webp' | 'tiff' | 'gif',
     dpi: 72 | 96 | 150 | 300,
     quality: number,
     pages: string
   ): Observable<HttpEvent<Blob>>
   → POST /api/v1/convert/pdf-to-images
   → responseType: 'blob', observe: 'events', reportProgress: true
   → Params: format, dpi, quality, pages

2. Dans tools-config.ts, vérifie / ajoute l'outil "convert/pdf-to-image" :

   {
     slug: 'convert/pdf-to-image',
     title: 'PDF → Image',
     description: 'Convertissez chaque page de votre PDF en image haute résolution.',
     icon: 'image',
     isAvailable: true,
     acceptedTypes: ['.pdf'],
     outputLabel: 'Télécharger les images',
   }

3. Dans la page outil (tool-page ou composant dédié), ajoute les contrôles :

   FORMAT (sélecteur visuel avec icônes) :
     [JPEG] [PNG ✓] [WEBP] [TIFF] [GIF]
     Signal : selectedFormat = signal<string>('png')

   RÉSOLUTION / DPI (radio buttons stylisés) :
     ○ 72 dpi — Aperçu web (léger)
     ● 150 dpi — Standard (recommandé)
     ○ 300 dpi — Impression haute qualité
     Signal : selectedDpi = signal<number>(150)

   QUALITÉ JPEG (slider 1-100, visible uniquement si format = jpeg) :
     @if (selectedFormat() === 'jpeg') {
       <input type="range" min="1" max="100" [value]="jpegQuality()">
       <span>{{ jpegQuality() }}%</span>
     }
     Signal : jpegQuality = signal<number>(85)

   SÉLECTION DE PAGES (radio + champ conditionnel) :
     ● Toutes les pages
     ○ Page spécifique : [__] (input number)
     ○ Plage de pages  : [__] à [__]
     Signal : pageSelection = signal<string>('all')

   BOUTON CONVERTIR :
     → disabled si aucun fichier sélectionné
     → affiche la barre de progression 3-phases (upload 0→60%, traitement 60→92%, done 100%)

4. Gestion de la réponse :
   - Si Content-Type = image/* → prévisualisation dans un <img> + bouton télécharger
   - Si Content-Type = application/zip :
     → message "X pages converties — téléchargez le ZIP"
     → bouton télécharger déclenche un saveAs automatique
   - Lire le header X-Page-Count pour afficher le nombre de pages
   - Lire le header X-Conversion-Engine pour afficher le moteur utilisé (info bulle)
```

---

## PROMPT 8 — Métriques & Health Indicator

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`

```
Enrichis ConversionEngineHealthIndicator pour inclure les moteurs image.

Dans la méthode health() du HealthIndicator, ajoute :

  // Moteur PDFBox (toujours disponible — pas de réseau)
  details.put("pdfbox", "UP");
  details.put("pdfbox.formats", "JPEG, PNG, WEBP (TwelveMonkeys), TIFF, GIF");

  // Ghostscript (optionnel)
  if (props.getImage().isGhostscriptEnabled()) {
      boolean gsUp = ghostscriptEngine.isAvailable();
      details.put("ghostscript", gsUp ? "UP" : "DOWN");
      if (gsUp) details.put("ghostscript.version", ghostscriptEngine.getVersion());
  } else {
      details.put("ghostscript", "DISABLED");
  }

Métriques Micrometer à enregistrer dans ImageConversionRouter :

  // Compteur total
  Counter.builder("kovixel.conversion.pdf_to_image.total")
      .tag("engine", result.engine())
      .tag("format", options.format().name())
      .tag("plan",   plan.name())
      .tag("pages",  result.isSinglePage() ? "SINGLE" : "MULTI")
      .register(meterRegistry)
      .increment();

  // Timer par moteur
  Timer.builder("kovixel.conversion.pdf_to_image.duration")
      .tag("engine", result.engine())
      .tag("format", options.format().name())
      .register(meterRegistry)
      .record(result.durationMs(), TimeUnit.MILLISECONDS);

  // Distribution du nombre de pages (pour dimensionner le timeout)
  DistributionSummary.builder("kovixel.conversion.pdf_to_image.pages_count")
      .tag("engine", result.engine())
      .register(meterRegistry)
      .record(result.totalPages());
```

---

## PROMPT 9 — Tests

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/image/PdfBoxImageEngineTest.java`
- `src/test/java/com/kovixel/core/conversion/image/ImageConversionRouterTest.java`
- `src/test/java/com/kovixel/core/conversion/image/PageSelectionParserTest.java`

```
PdfBoxImageEngineTest (tests unitaires) :
  - Teste conversion PNG d'un PDF 1 page
  - Teste conversion JPEG avec qualité 60 (vérifier taille < taille qualité 95)
  - Teste conversion WEBP (TwelveMonkeys doit être enregistré)
  - Teste PageSelection.Single(1) → 1 image
  - Teste PageSelection.Range(1, 3) sur PDF 5 pages → 3 images
  - Teste PageSelection.Single(99) sur PDF 3 pages → KovixelException 400
  - Teste dépassement maxPages → KovixelException 400

  PDF de test : générer un mini-PDF en mémoire avec PDDocument :
    PDDocument doc = new PDDocument();
    doc.addPage(new PDPage()); // 3 pages vides
    doc.addPage(new PDPage());
    doc.addPage(new PDPage());

ImageConversionRouterTest (tests unitaires avec Mockito) :
  @ExtendWith(MockitoExtension.class)
  - Mock PdfBoxImageEngine, GhostscriptImageEngine, AdobePdfServicesClient
  - Teste plan FREE → route vers PDFBox (Adobe non appelé)
  - Teste plan PRO + format PNG → route vers Adobe d'abord
  - Teste plan PRO + format WEBP → skip Adobe, route vers PDFBox directement
  - Teste fallback Adobe → PDFBox quand AdobeServiceException
  - Teste fallback PDFBox → Ghostscript quand Ghostscript disponible
  - Teste que la métrique fallback est incrémentée (MeterRegistry.simple())

PageSelectionParserTest :
  - "all"  → PageSelection.All
  - null   → PageSelection.All
  - "5"    → PageSelection.Single(5)
  - "2-8"  → PageSelection.Range(2, 8)
  - "abc"  → IllegalArgumentException
  - "0"    → IllegalArgumentException (pages ≥ 1)
  - "5-2"  → IllegalArgumentException (from ≤ to)
  - "0-5"  → IllegalArgumentException

Dépendance test à ajouter dans pom.xml (si absente) :
  <dependency>
      <groupId>org.apache.pdfbox</groupId>
      <artifactId>pdfbox</artifactId>
      <scope>test</scope>
  </dependency>
```

---

## PROMPT 10 — Documentation & Migration

**Fichiers à modifier / créer :**
- `README.md` (section "Configuration PDF → Image")
- `.env.example` (aucun ajout requis — pas de variables Adobe supplémentaires)

```
Dans README.md, ajoute une section "## PDF → Image" :

### Formats supportés

| Format | Moteur              | Plan requis | Notes                               |
|--------|---------------------|-------------|-------------------------------------|
| JPEG   | PDFBox / Adobe      | FREE        | Qualité configurable (1-100)        |
| PNG    | PDFBox / Adobe      | FREE        | Sans perte, fond transparent        |
| WEBP   | PDFBox+TwelveMonkeys| FREE        | Non supporté par Adobe → PDFBox auto|
| TIFF   | PDFBox / Adobe      | FREE        | Idéal impression, fichier lourd     |
| GIF    | PDFBox / Adobe      | FREE        | 256 couleurs max                    |

### Paramètres API

| Paramètre | Type   | Défaut | Description                                |
|-----------|--------|--------|--------------------------------------------|
| file      | File   | —      | PDF à convertir (multipart)                |
| format    | String | png    | Format de sortie : jpeg, png, webp, tiff, gif |
| dpi       | int    | 150    | Résolution (72-300)                        |
| quality   | int    | 85     | Qualité JPEG (1-100, ignoré pour PNG/WEBP) |
| pages     | String | all    | Sélection : "all", "3", "2-7"             |

### Comportement par plan

- **FREE** : PDFBox (CPU local) — tous formats — limité à 50 pages/requête
- **PRO**  : Adobe PDF Services (JPEG/PNG/TIFF/GIF) — qualité optimale
  - WEBP → bascule automatiquement sur PDFBox (Adobe ne supporte pas WEBP)
- **Fallback** : Ghostscript (si installé et ghostscript-enabled=true)

### Configuration Ghostscript (optionnel, haute qualité)

Pour activer Ghostscript en local (gs doit être installé) :

  kovixel.conversion.image.ghostscript-enabled=true
  kovixel.conversion.image.ghostscript-path=gs   # ou /usr/bin/gs

Dans Docker, ajouter à l'image kovixel-api :
  RUN apt-get install -y ghostscript
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10
  Config    TwelveM.  PDFBox+    Adobe      Router     API        Frontend   Métriques  Tests      Docs
            WEBP/TIFF PageSelect Image
```

> **Note** : PROMPT 4 (Adobe image) peut être parallélisé avec PROMPT 3 (PDFBox).
> PROMPT 7 (Frontend) peut être développé dès PROMPT 6 (API) validé.

---

## Critères de validation finale

- [ ] `mvn test` passe (PdfBoxImageEngineTest, RouterTest, ParserTest)
- [ ] Conversion PNG fonctionne pour un utilisateur FREE (PDFBox)
- [ ] Conversion WEBP fonctionne (TwelveMonkeys enregistré)
- [ ] JPEG avec `quality=60` est plus léger que `quality=95`
- [ ] `pages=2-4` sur un PDF 10 pages retourne exactement 3 images
- [ ] 1 page → réponse image directe ; N pages → ZIP avec manifeste JSON
- [ ] Header `X-Conversion-Engine` présent dans la réponse
- [ ] Plan PRO + format PNG → Adobe utilisé (vérifié via log + header)
- [ ] Format WEBP + plan PRO → Adobe ignoré, PDFBox utilisé (log WARN)
- [ ] `curl /actuator/health` expose `{ pdfbox: "UP", ghostscript: "DISABLED" }`
- [ ] `curl /actuator/metrics/kovixel.conversion.pdf_to_image.total` retourne des valeurs
- [ ] Le sélecteur de format sur le frontend affiche le moteur utilisé dans l'interface

