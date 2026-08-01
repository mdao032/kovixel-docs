# 🖼️ Images → PDF : Roadmap d'implémentation Pro/Ultra-Pro

> **Contexte** : Kovixel dispose déjà d'un module de conversion complet (PDF→Word, PDF→Image,
> PDF→Excel). Cette roadmap ajoute l'outil inverse : assembler une ou plusieurs images
> (JPEG, PNG, WEBP, TIFF, GIF, BMP) en un PDF unique, avec mise en page configurable
> (format papier, orientation, marges, ajustement, qualité, ordre).
>
> **Moteur** : Apache PDFBox 3.x (déjà présent dans le projet) — pas de dépendance
> supplémentaire requise pour les formats courants. TwelveMonkeys ImageIO (déjà présent)
> assure le support WEBP, TIFF et GIF.
>
> **Instructions** : Exécuter les prompts dans l'ordre.
> Chaque prompt est autonome et cite les fichiers à modifier.
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Requête POST /api/v1/convert/images-to-pdf
  params: files[], pageSize, orientation, margins, fit, quality, orderBy
        │
        ▼
  ┌──────────────────────────────────────────────────────────┐
  │  ImageToPdfOptions (DTO de validation)                   │
  │  pageSize, orientation, margin, fitMode, jpegQuality     │
  │  imageOrder (index[] pour réordonner côté serveur)       │
  └──────────────────────────────────────────────────────────┘
        │
        ├─ Taille totale > 50 MB ──► Job Asynchrone
        │                            └─ GET /api/v1/jobs/{jobId}/result → PDF
        │
        └─ Taille totale ≤ 50 MB ──► Conversion Synchrone
                │
                ▼
        ┌──────────────────────────────────────────────────────┐
        │  ImageToPdfEngine (PDFBox)                           │
        │  Aucun routage nécessaire : PDFBox gère tout         │
        └──────────────────────────────────────────────────────┘
                │
                ▼
        Pour chaque image (dans l'ordre défini) :
          1. Decode → BufferedImage (TwelveMonkeys pour WEBP/TIFF/GIF)
          2. Calcule la disposition (FitMode + taille de page + marges)
          3. Crée une PDPage à la bonne dimension
          4. Encode l'image en JPEG dans le PDF (compression configurable)
             ou PNG si transparence détectée (ARGB)
          5. Ajoute les métadonnées PDF (titre, auteur, date)
                │
                ▼
        Output :
          PDF unique contenant N pages (une image par page)
          Metadata : XMP, titre, date, producteur "Kovixel"
          Compression : JPEG qualité configurable (défaut 85)
                        ou Flate pour PNG (sans perte)
```

---

## Formats d'entrée supportés

| Format | MIME type       | Support natif Java | TwelveMonkeys | Transparence |
|--------|-----------------|--------------------|---------------|--------------|
| JPEG   | image/jpeg      | ✅                 | ✅            | ❌           |
| PNG    | image/png       | ✅                 | ✅            | ✅ (ARGB)   |
| WEBP   | image/webp      | ❌                 | ✅            | ✅           |
| TIFF   | image/tiff      | ❌                 | ✅            | ✅           |
| GIF    | image/gif       | ✅ (limité)        | ✅            | ✅           |
| BMP    | image/bmp       | ✅                 | ✅            | ❌           |
| HEIC   | image/heic      | ❌                 | ❌            | ❌           |

> HEIC non supporté (absence de décodeur libre — orientez vers PNG/JPEG).

---

## Formats de page et options de mise en page

| Option        | Valeurs                                               | Défaut    |
|---------------|-------------------------------------------------------|-----------|
| pageSize      | A4, A3, A5, Letter, Legal, Tabloid, auto              | A4        |
| orientation   | portrait, landscape, auto (suit l'image)              | portrait  |
| margin        | none (0px), small (10px), medium (20px), large (40px) | small     |
| fitMode       | fit (zoom ≤ 100%), fill (recadre), center, stretch    | fit       |
| jpegQuality   | 1–100                                                 | 85        |
| backgroundColor| white, transparent (PNG), custom (#RRGGBB)           | white     |

---

## PROMPT 1 — Configuration & types partagés

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imagetopdf/PdfPageSize.java`
- `src/main/java/com/kovixel/core/conversion/imagetopdf/PdfFitMode.java`
- `src/main/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfOptions.java`
- `src/main/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfResult.java`

```
1. Dans ConversionProperties.java, ajoute une section imbriquée `imageToPdf` :

   @NestedConfigurationProperty
   private ImageToPdf imageToPdf = new ImageToPdf();

   @Data
   public static class ImageToPdf {

       /** Nombre maximum d'images par requête synchrone. Défaut : 50 */
       private int maxImages = 50;

       /** Taille maximale totale (bytes) avant de basculer en async. Défaut : 50 MB */
       private long asyncThresholdBytes = 50L * 1024 * 1024;

       /** Taille maximale par image individuelle (bytes). Défaut : 20 MB */
       private long maxImageBytes = 20L * 1024 * 1024;

       /** Qualité JPEG par défaut dans le PDF (0-100). Défaut : 85 */
       private int defaultJpegQuality = 85;

       /** Format de page par défaut. Défaut : "A4" */
       private String defaultPageSize = "A4";

       /** Orientation par défaut. Défaut : "portrait" */
       private String defaultOrientation = "portrait";

       /** Mode de mise en page par défaut. Défaut : "fit" */
       private String defaultFitMode = "fit";

       /**
        * Active la métadonnée XMP dans le PDF généré.
        * Inclut : titre, auteur (Kovixel), date, logiciel.
        * Défaut : true
        */
       private boolean xmpMetadataEnabled = true;
   }

2. Dans application.yml, sous kovixel.conversion, ajoute :

   image-to-pdf:
     max-images: 50
     async-threshold-bytes: 52428800   # 50 MB
     max-image-bytes: 20971520          # 20 MB
     default-jpeg-quality: 85
     default-page-size: A4
     default-orientation: portrait
     default-fit-mode: fit
     xmp-metadata-enabled: true

3. Dans application-dev.yml, surcharge :

   image-to-pdf:
     max-images: 10
     async-threshold-bytes: 5242880    # 5 MB en dev

4. Crée PdfPageSize.java (enum) :

   public enum PdfPageSize {
       A3    (841.89f, 1190.55f, "A3"),
       A4    (595.28f,  841.89f, "A4"),   // format par défaut
       A5    (419.53f,  595.28f, "A5"),
       LETTER(612.00f,  792.00f, "Letter"),
       LEGAL (612.00f, 1008.00f, "Legal"),
       TABLOID(792.00f,1224.00f, "Tabloid"),
       AUTO  (  0.00f,    0.00f, "auto");  // dimensions déduites de l'image

       // widthPt, heightPt en points PDF (1 pt = 1/72 inch)
       private final float widthPt;
       private final float heightPt;
       private final String label;

       // méthode statique fromString(String) avec fallback A4
       // méthode PDRectangle toRectangle(String orientation) :
       //   portrait  → widthPt x heightPt
       //   landscape → heightPt x widthPt
       //   auto      → calculé depuis la BufferedImage (pixel/DPI * 72)
   }

5. Crée PdfFitMode.java (enum) :

   public enum PdfFitMode {
       /**
        * FIT — Ajuste l'image pour tenir entièrement dans la page (zoom ≤ 100%).
        * Conserve les proportions. Pas de recadrage. Marges visibles si ratio différent.
        * C'est le comportement "letterbox".
        */
       FIT,

       /**
        * FILL — Remplit toute la page. Recadre les bords si nécessaire.
        * Équivalent "cover" CSS. Aucune marge blanche visible.
        */
       FILL,

       /**
        * CENTER — Taille originale centrée. Ne redimensionne PAS (ni zoom in, ni zoom out).
        * Marges blanches si image plus petite. Recadrage si image plus grande.
        */
       CENTER,

       /**
        * STRETCH — Étire l'image aux dimensions exactes de la page.
        * Déforme les proportions. Usage : images déjà au bon ratio.
        */
       STRETCH;

       public static PdfFitMode fromString(String value) {
           if (value == null || value.isBlank()) return FIT;
           try { return valueOf(value.trim().toUpperCase()); }
           catch (IllegalArgumentException e) { return FIT; }
       }
   }

6. Crée ImageToPdfOptions.java (record) :

   public record ImageToPdfOptions(
       PdfPageSize pageSize,        // format de page (A4, Letter, auto...)
       String orientation,          // "portrait" | "landscape" | "auto"
       int marginPt,                // marge en points PDF (0, 10, 20, 40)
       PdfFitMode fitMode,          // comment l'image remplit la page
       int jpegQuality,             // qualité compression JPEG (1-100)
       String backgroundColor,      // fond : "white" | "#RRGGBB" | "transparent"
       boolean addPageNumbers,      // ajoute numéros de page en pied
       String outputFilename        // nom de base du fichier PDF résultat
   ) {
       // Constructeur compact : validation
       //   - jpegQuality 1-100
       //   - marginPt 0-100
       //   - orientation in {"portrait","landscape","auto"}

       /** Factory defaults : A4, portrait, marge 10pt, FIT, qualité 85, fond blanc */
       public static ImageToPdfOptions defaults() {
           return new ImageToPdfOptions(
               PdfPageSize.A4, "portrait", 10, PdfFitMode.FIT,
               85, "white", false, "images"
           );
       }

       /** Résout les marges depuis un label lisible */
       public static int marginFromLabel(String label) {
           return switch (label == null ? "small" : label.toLowerCase()) {
               case "none"   -> 0;
               case "small"  -> 10;
               case "medium" -> 20;
               case "large"  -> 40;
               default       -> 10;
           };
       }
   }

7. Crée ImageToPdfResult.java (record) :

   public record ImageToPdfResult(
       byte[] pdfBytes,             // contenu binaire du PDF généré
       int totalImages,             // nombre d'images assemblées
       int totalPages,              // == totalImages (1 image = 1 page)
       long durationMs,
       long outputSizeBytes,
       List<PageInfo> pages         // métadonnées de chaque page
   ) {
       public record PageInfo(
           int pageIndex,           // 0-based
           String originalFilename, // nom de l'image source
           int widthPx,
           int heightPx,
           String detectedFormat,   // "JPEG" | "PNG" | "WEBP" | "TIFF" | "GIF" | "BMP"
           boolean hasTransparency  // true si ARGB détecté → encodé en PNG dans le PDF
       ) {}
   }
```

---

## PROMPT 2 — Moteur PDFBox (ImageToPdfEngine)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfEngine.java`
- `src/main/java/com/kovixel/core/conversion/imagetopdf/ImageDecoder.java`

```
Crée ImageToPdfEngine.java — moteur principal basé sur Apache PDFBox 3.x.

Classe ImageToPdfEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  ImageToPdfResult convert(List<NamedImage> images, ImageToPdfOptions options)

  record NamedImage(String filename, byte[] data) {}

Logique interne :

  1. Valide le nombre d'images ≤ props.getImageToPdf().getMaxImages()
     Sinon → KovixelException(VALIDATION_ERROR, HTTP 400)
  2. Valide chaque image ≤ props.getImageToPdf().getMaxImageBytes()
     Sinon → KovixelException(VALIDATION_ERROR, HTTP 400, "Image {filename} trop volumineuse")
  3. Crée un PDDocument vide
  4. Pour chaque NamedImage (dans l'ordre fourni) :
     a. ImageDecoder.decode(data) → BufferedImage + détection du format
     b. Détecte la transparence : image.getColorModel().hasAlpha()
     c. Calcule PDRectangle (page) :
        - Si pageSize = AUTO : largeur = imgWidth/DPI_SCREEN*72, hauteur=imgHeight/DPI_SCREEN*72
          avec orientation "auto" : landscape si largeur > hauteur, portrait sinon
        - Sinon : options.pageSize().toRectangle(orientation effectif)
     d. Applique les marges : zone utile = (pageW - 2*margin) x (pageH - 2*margin)
     e. Calcule position/taille de l'image selon options.fitMode() :
        - FIT    : scale = min(zoneW/imgW, zoneH/imgH) — zoom ≤ 1.0 (jamais agrandissement
                   au-delà de la taille originale si image déjà plus petite)
                   Non : le roadmap dit zoom ≤ 100% = jamais de zoom avant.
                   Implémentation : scale = min(1.0, min(zoneW/imgW, zoneH/imgH))
                   Centrage dans la zone utile
        - FILL   : scale = max(zoneW/imgW, zoneH/imgH) — clipping si nécessaire
        - CENTER : scale = 1.0, centrer (clipper si image > zone)
        - STRETCH: drawX=margin, drawY=margin, drawW=zoneW, drawH=zoneH (déformé)
     f. Encode l'image :
        - Si hasTransparency (PNG/WEBP/GIF avec alpha) :
          → PDImageXObject.createFromByteArray(doc, encodePng(img), "png")
          → Fond coloré si backgroundColor != "transparent" :
            ajouter un rectangle PDPageContentStream avant l'image
        - Sinon (JPEG, BMP, ou PNG sans alpha avec fond blanc) :
          → Convertit en BufferedImage TYPE_INT_RGB (fond backgroundColor)
          → PDJpeg = PDImageXObject.createFromByteArray(doc, encodeJpeg(img, quality), "jpeg")
     g. Ajoute la PDPage au document
     h. Dessine l'image avec PDPageContentStream :
        cs.drawImage(pdImg, drawX, drawY, drawW, drawH)
     i. Optionnel : si addPageNumbers → ajoute numéro de page (Helvetica, 9pt, bas de page)
  5. Ajoute les métadonnées XMP (si props.imageToPdf.xmpMetadataEnabled) :
     - PDDocumentInformation : title, producer="Kovixel", creationDate
     - XMPMetadata via PDMetadata (org.apache.xmpbox)
  6. Sérialise le PDDocument → ByteArrayOutputStream
  7. Log récapitulatif : "ImageToPdfEngine — {n} images → PDF {size}KB en {ms}ms"
  8. Retourne ImageToPdfResult

Méthode privée encodeJpeg(BufferedImage img, int quality) : byte[]
  - Utilise JPEGImageWriteParam avec CompressionQuality
  - Identique au pattern de PdfBoxImageEngine existant

Méthode privée encodePng(BufferedImage img) : byte[]
  - ImageIO.write(img, "png", baos)

Méthode privée applyBackgroundColor(BufferedImage src, String bgColor) : BufferedImage
  - Crée un BufferedImage TYPE_INT_RGB
  - Remplit avec la couleur (blanc par défaut, ou Color.decode(bgColor))
  - Dessine src par-dessus via Graphics2D

Crée ImageDecoder.java — utilitaire de décodage multi-format :

  public final class ImageDecoder {

      /** Résultat du décodage */
      public record Decoded(BufferedImage image, String detectedFormat) {}

      /**
       * Décode des bytes d'image en BufferedImage.
       * Utilise TwelveMonkeys ImageIO pour WEBP, TIFF, GIF avancé.
       *
       * @throws KovixelException HTTP 422 si le format n'est pas reconnu
       */
      public static Decoded decode(byte[] data) {
          // 1. Détecter le format via les magic bytes (premiers octets)
          //    JPEG : FF D8 FF
          //    PNG  : 89 50 4E 47
          //    WEBP : 52 49 46 46 ... 57 45 42 50
          //    GIF  : 47 49 46 38
          //    TIFF : 49 49 ou 4D 4D
          //    BMP  : 42 4D
          // 2. ImageIO.read(new ByteArrayInputStream(data))
          //    Si null → KovixelException(PROCESSING_ERROR, HTTP 422, "Format image non supporté")
          // 3. Retourner Decoded(image, formatDetecté)
      }

      /** Retourne le format détecté depuis les magic bytes */
      public static String detectFormat(byte[] data) { ... }

      /** Vérifie si l'image a un canal alpha (transparence) */
      public static boolean hasAlpha(BufferedImage img) {
          return img.getColorModel().hasAlpha();
      }
  }

Gestion des erreurs dans ImageToPdfEngine :
  - Image illisible (ImageDecoder lance KovixelException) → propagée telle quelle
  - Erreur PDFBox → KovixelException(PROCESSING_ERROR, HTTP 422,
    "Erreur génération PDF : " + e.getMessage())
  - OutOfMemoryError (image trop grande) → KovixelException(PROCESSING_ERROR, HTTP 422,
    "Image trop grande pour être traitée — réduisez la résolution")
```

---

## PROMPT 3 — Endpoint API

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Ajoute l'endpoint POST /api/v1/convert/images-to-pdf dans ConversionController.

@PostMapping("/api/v1/convert/images-to-pdf")
@Operation(
    summary = "Images → PDF",
    description = "Assemble une ou plusieurs images (JPEG, PNG, WEBP, TIFF, GIF, BMP) "
                + "en un PDF unique. Une image = une page. Ordre configurable."
)
@CheckQuota(feature = FeatureType.CONVERSION)
public ResponseEntity<?> imagesToPdf(
    @RequestParam("files")
    @Parameter(description = "Images à assembler (max 50, total ≤ 50 MB)")
    List<MultipartFile> files,

    @RequestParam(defaultValue = "A4")        String pageSize,
    @RequestParam(defaultValue = "portrait")  String orientation,
    @RequestParam(defaultValue = "small")     String margin,
    @RequestParam(defaultValue = "fit")       String fitMode,
    @RequestParam(defaultValue = "85")        int jpegQuality,
    @RequestParam(defaultValue = "white")     String backgroundColor,
    @RequestParam(defaultValue = "false")     boolean addPageNumbers,
    @RequestParam(required = false)           String order,        // "0,2,1" → réordonner
    @AuthenticationPrincipal UserDetails userDetails
) throws Exception

Validation :
  - files non null et non vide → 400 "Au moins une image requise"
  - files.size() > props.imageToPdf.maxImages → 400 "Maximum {n} images par conversion"
  - Chaque file.getSize() > props.imageToPdf.maxImageBytes → 400
  - Content-Type de chaque fichier doit être image/* → 415
  - pageSize → PdfPageSize.fromString(pageSize) [fallback A4]
  - fitMode  → PdfFitMode.fromString(fitMode) [fallback FIT]
  - jpegQuality 1-100 → 400 si hors range
  - order : si présent, parser "0,2,1" → int[] indices → réordonner `files`
    Valider que les indices sont uniques et couvrent [0, files.size()-1]

Parsing de `order` (helper parseOrder(String order, int size)) :
  - null → identité [0, 1, 2, ..., n-1]
  - "0,2,1" → [0, 2, 1]
  - Indices hors range ou doublons → 400 "Ordre invalide"

Taille totale = Σ file.getSize()
Seuil async : totalSize > props.imageToPdf.asyncThresholdBytes
  → AiJobService.submitJob() avec les bytes + options sérialisées
  → HTTP 202 + { "jobId": "...", "pollUrl": "/api/v1/jobs/{jobId}/status" }

Flow synchrone :
  1. Construire la liste NamedImage[] (dans l'ordre résolu)
  2. Construire ImageToPdfOptions depuis les paramètres
  3. imageToPdfEngine.convert(namedImages, options)
  4. Construire la réponse

Réponse HTTP 200 :
  - Content-Type: application/pdf
  - Content-Disposition: attachment; filename="{baseName}_kovixel.pdf"
    où baseName = premier fichier sans extension si 1 image,
                = "images" si > 1 image
  - Body: result.pdfBytes()

Headers de réponse :
  X-Images-Count:       nombre d'images assemblées
  X-Total-Pages:        nombre de pages du PDF (== images)
  X-Processing-Time-Ms: durée de traitement
  X-Output-Size-Bytes:  taille du PDF généré
  X-Async-Job-Id:       présent uniquement si async (HTTP 202)

Exemple curl :
  curl -X POST http://localhost:8080/api/v1/convert/images-to-pdf \
    -F "files=@photo1.jpg" \
    -F "files=@photo2.png" \
    -F "files=@scan.webp" \
    -F "pageSize=A4" \
    -F "orientation=auto" \
    -F "margin=medium" \
    -F "fitMode=fit" \
    -F "order=2,0,1" \
    -o "document_kovixel.pdf"
```

---

## PROMPT 4 — Métriques & Health Indicator

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`
- `src/main/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfEngine.java`

```
1. Dans ImageToPdfEngine.convert(), injecte MeterRegistry et enregistre :

   // Compteur total
   Counter.builder("kovixel.conversion.images_to_pdf.total")
       .tag("page_size",   options.pageSize().name())
       .tag("fit_mode",    options.fitMode().name())
       .tag("count",       result.totalImages() == 1 ? "SINGLE" :
                           result.totalImages() <= 10 ? "FEW" : "MANY")
       .register(meterRegistry)
       .increment();

   // Timer
   Timer.builder("kovixel.conversion.images_to_pdf.duration")
       .tag("page_size", options.pageSize().name())
       .register(meterRegistry)
       .record(result.durationMs(), TimeUnit.MILLISECONDS);

   // Distribution nombre d'images
   DistributionSummary.builder("kovixel.conversion.images_to_pdf.images_count")
       .register(meterRegistry)
       .record(result.totalImages());

   // Distribution taille de sortie (en KB)
   DistributionSummary.builder("kovixel.conversion.images_to_pdf.output_size_kb")
       .register(meterRegistry)
       .record(result.outputSizeBytes() / 1024.0);

   // Compteur par format d'entrée détecté
   result.pages().forEach(p ->
       Counter.builder("kovixel.conversion.images_to_pdf.input_format")
           .tag("format", p.detectedFormat())
           .register(meterRegistry)
           .increment()
   );

2. Dans ConversionEngineHealthIndicator.health(), ajoute :

   // Sonde Images → PDF (PDFBox, toujours disponible)
   details.put("images_to_pdf", "UP");
   details.put("images_to_pdf.engine", "PDFBox " + PDDocument.class.getPackage().getImplementationVersion());
   details.put("images_to_pdf.formats_in",  "JPEG, PNG, WEBP, TIFF, GIF, BMP");
   details.put("images_to_pdf.max_images",
       String.valueOf(props.getImageToPdf().getMaxImages()));
   details.put("images_to_pdf.async_threshold_mb",
       String.valueOf(props.getImageToPdf().getAsyncThresholdBytes() / 1024 / 1024) + " MB");

   // TwelveMonkeys (pour WEBP/TIFF/GIF)
   try {
       Class.forName("com.twelvemonkeys.imageio.plugins.webp.WebPImageReaderSpi");
       details.put("twelvemonkeys", "UP");
   } catch (ClassNotFoundException e) {
       details.put("twelvemonkeys", "DOWN");
       details.put("twelvemonkeys.note", "WEBP/TIFF avancé non disponible");
   }
```

---

## PROMPT 5 — Tests complets

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfEngineTest.java`
- `src/test/java/com/kovixel/core/conversion/imagetopdf/ImageDecoderTest.java`
- `src/test/java/com/kovixel/core/conversion/imagetopdf/ImageToPdfControllerTest.java`

```
ImageToPdfEngineTest (tests unitaires) :

  Images de test — générer programmatiquement (pas de fichiers externes) :
    private byte[] createTestJpeg(int width, int height, Color color) throws IOException {
        BufferedImage img = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = img.createGraphics();
        g.setColor(color); g.fillRect(0, 0, width, height); g.dispose();
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        ImageIO.write(img, "jpeg", baos);
        return baos.toByteArray();
    }

    private byte[] createTestPng(int width, int height, boolean withAlpha) throws IOException {
        int type = withAlpha ? BufferedImage.TYPE_INT_ARGB : BufferedImage.TYPE_INT_RGB;
        BufferedImage img = new BufferedImage(width, height, type);
        // fond semi-transparent si alpha
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        ImageIO.write(img, "png", baos);
        return baos.toByteArray();
    }

  @Test convertsSingleJpeg_returnsOnePage() :
    - 1 JPEG 800x600 → PDF 1 page
    - Vérifie : result.totalPages() == 1, result.pdfBytes().length > 0
    - Ouvre le PDF avec PDDocument et vérifie getNumberOfPages() == 1

  @Test convertsMultipleImages_correctPageCount() :
    - 3 images → PDF 3 pages
    - Vérifie : result.totalImages() == 3, result.totalPages() == 3

  @Test fitModeDoesNotUpscaleSmallImage() :
    - Image 100x100, page A4 (595x842 pt), FIT
    - L'image doit occuper au maximum 100x100 pt (pas d'agrandissement)
    - Vérifie via les dimensions de la page dans le PDF

  @Test fillModeCoversFullPage() :
    - Image 800x600 (paysage), page A4 portrait, FILL
    - Image dessinée sur toute la hauteur de la page

  @Test orientationAutoAdaptsToImageRatio() :
    - Image paysage 1920x1080 + orientation="auto"
    - La page doit être en mode paysage (largeur > hauteur)

  @Test pageSizeAutoDeducedFromImage() :
    - PdfPageSize.AUTO + image 300x400 px (96 DPI)
    - La page PDF doit mesurer environ (300/96*72) x (400/96*72) points
      ≈ 225 x 300 points

  @Test jpegQualityAffectsOutputSize() :
    - Même image, qualité 30 vs qualité 95
    - PDF qualité 30 doit être significativement plus petit

  @Test pngWithTransparencyPreserved() :
    - PNG ARGB → encodé en PNG dans le PDF (pas en JPEG)
    - result.pages().get(0).hasTransparency() == true

  @Test rejectsExcessiveImageCount() :
    - 11 images avec maxImages=10 → KovixelException HTTP 400

  @Test rejectsOversizedImage() :
    - Image simulant 25 MB avec maxImageBytes=20 MB → KovixelException HTTP 400

  @Test orderIsRespected() :
    - 3 images de couleurs différentes (rouge, vert, bleu)
    - Vérifie que la première page correspond à la première NamedImage fournie

  @Test addPageNumbersAddsText() :
    - addPageNumbers=true → le PDF contient du texte (PDFTextStripper)
    - Vérifie que "1" apparaît dans le contenu text de la page 1

ImageDecoderTest :

  @Test decodesJpeg()
  @Test decodesPng()
  @Test decodesBmp()
  @Test detectsAlphaInArgbPng()
  @Test detectsNoAlphaInRgbPng()
  @Test throwsOn_invalidData()      → KovixelException HTTP 422
  @Test detectsJpegMagicBytes()
  @Test detectsPngMagicBytes()
  @Test detectsGifMagicBytes()
  @Test detectsBmpMagicBytes()
  @Test detectsTiffMagicBytes_littleEndian()  // 49 49
  @Test detectsTiffMagicBytes_bigEndian()     // 4D 4D

ImageToPdfControllerTest (@SpringBootTest slice ou MockMvc) :

  @Test postSingleImage_returns200WithPdf()
  @Test postMultipleImages_returns200()
  @Test postNoFiles_returns400()
  @Test postWithInvalidOrder_returns400()     // "0,0,1" doublon
  @Test postWithOutOfRangeOrder_returns400()  // index 5 avec 3 fichiers
  @Test postWithInvalidQuality_returns400()   // quality=200
  @Test postNonImageFile_returns415()
  @Test responseHeadersArePresent()
    → X-Images-Count, X-Total-Pages, X-Processing-Time-Ms, X-Output-Size-Bytes
```

---

## PROMPT 6 — Frontend : composant Angular dédié

**Fichiers à créer :**
- `kovixel-ui/src/app/features/tools/images-to-pdf/images-to-pdf.component.ts`

**Fichiers à modifier :**
- `kovixel-ui/src/app/app.routes.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
Crée PdfToExcelComponent (standalone, OnPush) — UX premium pour Images → PDF.

1. SIGNAUX (état de l'application) :

   selectedFiles    = signal<FileItem[]>([])      // liste ordonnée avec métadonnées
   state            = signal<'idle'|'ready'|'uploading'|'success'|'error'>('idle')
   uploadProgress   = signal<number>(0)
   // Options de mise en page
   pageSize         = signal<string>('A4')
   orientation      = signal<string>('portrait')
   margin           = signal<string>('small')
   fitMode          = signal<string>('fit')
   jpegQuality      = signal<number>(85)
   backgroundColor  = signal<string>('white')
   addPageNumbers   = signal<boolean>(false)
   // Résultats
   resultBlob       = signal<Blob | null>(null)
   resultFilename   = signal<string>('')
   imagesCount      = signal<number | null>(null)
   totalPages       = signal<number | null>(null)
   outputSizeKb     = signal<number | null>(null)
   errorMessage     = signal<string>('')

   interface FileItem {
     file: File
     id: string          // UUID local pour le drag-and-drop
     preview: string     // URL.createObjectURL() pour la preview
     width: number       // dimensions décodées (si disponibles)
     height: number
   }

2. ZONE DE DROP MULTI-FICHIERS :

   - Accepte : image/jpeg, image/png, image/webp, image/tiff, image/gif, image/bmp
   - Glisser-déposer ou clic → ouverture du sélecteur multi-fichiers
   - Affiche une grille de previews (thumbnails 80x80px) avec :
     * Nom de fichier tronqué
     * Poids (formaté)
     * Bouton ✕ pour supprimer
     * Indicateur de format (badge coloré : JPEG=orange, PNG=bleu, WEBP=vert, etc.)
   - Compteur : "X image(s) sélectionnée(s) · Y MB total"
   - Alerte si > 50 images ou > 50 MB total

3. RÉORDONNEMENT DES IMAGES (drag-and-drop) :

   Utilise le CDK Angular DragDrop (@angular/cdk/drag-drop) :
   <div cdkDropList (cdkDropListDropped)="onDrop($event)">
     @for (item of selectedFiles(); track item.id) {
       <div cdkDrag class="file-card">...</div>
     }
   </div>

   onDrop(event: CdkDragDrop<FileItem[]>) {
     // moveItemInArray(selectedFiles(), event.previousIndex, event.currentIndex)
     selectedFiles.update(files => { ... });
   }

   → L'ordre visuel final = ordre d'envoi à l'API

4. OPTIONS DE MISE EN PAGE :

   FORMAT DE PAGE — sélecteur visuel (chips) :
   ┌────┐ ┌──────┐ ┌────┐ ┌────────┐ ┌───────┐ ┌──────┐
   │ A4 │ │Letter│ │ A3 │ │ Legal  │ │Tabloid│ │ Auto │
   └────┘ └──────┘ └────┘ └────────┘ └───────┘ └──────┘
   Tooltip "Auto" : "La page s'adapte aux dimensions de chaque image"

   ORIENTATION — 3 boutons radio visuels avec icône :
   [◻ Portrait]  [▭ Paysage]  [⟳ Auto (suit l'image)]

   MARGES — 4 chips :
   [Aucune] [Petite ✓] [Moyenne] [Grande]

   MODE D'AJUSTEMENT — 4 chips avec tooltip :
   [Adapter ✓]  [Remplir]  [Centrer]  [Étirer]
   Tooltips :
     Adapter  : "L'image tient entière dans la page, jamais agrandie"
     Remplir  : "L'image remplit la page, les bords sont recadrés si nécessaire"
     Centrer  : "Taille originale, centrée — marges si l'image est petite"
     Étirer   : "L'image est déformée pour remplir exactement la page"

   OPTIONS AVANCÉES (section repliable <details>) :
   ── Qualité JPEG (slider, visible si au moins 1 image est JPEG/BMP) :
      <input type="range" min="1" max="100"> {{ jpegQuality() }}%
   ── Couleur de fond (sélecteur) : ● Blanc  ○ Noir  ○ Transparent  ○ Personnalisé #______
   ── ☐ Ajouter les numéros de page

5. BARRE DE PROGRESSION (état 'uploading') — 3 phases :
   Phase 1 : Upload (0 → 70%) — HttpEvent UploadProgress
   Phase 2 : Traitement serveur (70% → 90%) — animation indéterminée
   Phase 3 : Finalisation (90% → 100%)

6. ÉTAT SUCCESS :
   ┌──────────────────────────────────────────────────────────────┐
   │  ✅ PDF généré avec succès                                   │
   │                                                              │
   │  📄 3 images assemblées · 3 pages · 245 KB                  │
   │  ⚡ Traitement : 0.8s                                        │
   │                                                              │
   │  [↓ Télécharger le PDF (document_kovixel.pdf)]               │
   │                                                              │
   │  [+ Ajouter d'autres images]   [🔄 Recommencer]             │
   └──────────────────────────────────────────────────────────────┘

7. Dans ConversionService Angular, ajoute :

   imagesToPdf(
     files: File[],
     options: {
       pageSize?: string,
       orientation?: string,
       margin?: string,
       fitMode?: string,
       jpegQuality?: number,
       backgroundColor?: string,
       addPageNumbers?: boolean,
       order?: string         // ex: "0,2,1"
     } = {}
   ): Observable<HttpEvent<Blob>> {
     const formData = new FormData();
     files.forEach(f => formData.append('files', f));
     if (options.pageSize)       formData.append('pageSize', options.pageSize);
     if (options.orientation)    formData.append('orientation', options.orientation);
     if (options.margin)         formData.append('margin', options.margin);
     if (options.fitMode)        formData.append('fitMode', options.fitMode);
     if (options.jpegQuality != null)
                                 formData.append('jpegQuality', String(options.jpegQuality));
     if (options.backgroundColor)formData.append('backgroundColor', options.backgroundColor);
     if (options.addPageNumbers) formData.append('addPageNumbers', 'true');
     if (options.order)          formData.append('order', options.order);

     return this.http.request(
       new HttpRequest('POST', `${this.baseUrl}/images-to-pdf`, formData, {
         responseType: 'blob',
         reportProgress: true,
       })
     );
   }

8. Dans app.routes.ts, ajoute AVANT toute route générique :
   {
     path: 'tools/convert/images-to-pdf',
     loadComponent: () =>
       import('./features/tools/images-to-pdf/images-to-pdf.component')
         .then(m => m.ImagesToPdfComponent),
     data: { title: 'Images → PDF' }
   }

9. Dans tools-config.ts, ajoute l'outil :
   {
     id: 'images-to-pdf',
     path: 'tools/convert/images-to-pdf',
     label: 'Images → PDF',
     icon: 'file-image',           // icône adaptée
     description: 'Assemblez vos images en un PDF unique. Glissez-déposez et réordonnez.',
     longDescription: 'Convertit JPEG, PNG, WEBP, TIFF, GIF et BMP en un PDF multi-pages. '
                    + 'Une image par page. Mise en page configurable : format (A4, Letter...), '
                    + 'orientation, marges, mode d'ajustement. Glisser-déposer et réordonner '
                    + 'les images avant la conversion.',
     tags: ['images', 'pdf', 'jpg', 'png', 'webp', 'tiff', 'assembler', 'convertir'],
     acceptedTypes: ['.jpg', '.jpeg', '.png', '.webp', '.tiff', '.tif', '.gif', '.bmp'],
     maxFiles: 50,
     outputLabel: 'Télécharger le PDF',
     isAvailable: true,
   }
```

---

## PROMPT 7 — Documentation

**Fichiers à modifier :**
- `README.md` (section "Images → PDF")
- `.env.example` (aucun ajout requis — pas de credentials supplémentaires)

```
Dans README.md, ajoute une section "## Images → PDF" :

### Formats d'entrée supportés

| Format | Extension | Transparence | Notes                                  |
|--------|-----------|:------------:|----------------------------------------|
| JPEG   | .jpg .jpeg | ❌           | Format le plus courant, fond blanc     |
| PNG    | .png       | ✅           | Sans perte, supporte le fond transparent|
| WEBP   | .webp      | ✅           | Via TwelveMonkeys ImageIO              |
| TIFF   | .tiff .tif | ✅           | Via TwelveMonkeys ImageIO              |
| GIF    | .gif       | ✅           | 1ère frame uniquement                  |
| BMP    | .bmp       | ❌           | Format Windows non compressé           |

> Maximum 50 images par requête synchrone. Total ≤ 50 MB.

### Options de mise en page

| Paramètre       | Valeurs                              | Défaut   |
|-----------------|--------------------------------------|----------|
| pageSize        | A3, A4, A5, Letter, Legal, Tabloid, auto | A4   |
| orientation     | portrait, landscape, auto            | portrait |
| margin          | none, small, medium, large           | small    |
| fitMode         | fit, fill, center, stretch           | fit      |
| jpegQuality     | 1–100                                | 85       |
| backgroundColor | white, black, transparent, #RRGGBB   | white    |
| addPageNumbers  | true, false                          | false    |
| order           | "0,2,1" (indices, 0-based)           | —        |

### Modes d'ajustement (fitMode)

| Mode    | Description                                                          |
|---------|----------------------------------------------------------------------|
| fit     | L'image tient entièrement dans la page. Pas d'agrandissement.        |
| fill    | L'image remplit toute la page. Les bords sont recadrés si nécessaire.|
| center  | Taille originale, centrée dans la page.                              |
| stretch | L'image est déformée pour remplir exactement la page (sans marge).   |

### Paramètres API

| Paramètre       | Type    | Défaut   | Description                              |
|-----------------|---------|----------|------------------------------------------|
| files           | File[]  | —        | Images à assembler (multipart, requis)   |
| pageSize        | String  | A4       | Format de page                           |
| orientation     | String  | portrait | portrait / landscape / auto              |
| margin          | String  | small    | none / small / medium / large            |
| fitMode         | String  | fit      | fit / fill / center / stretch            |
| jpegQuality     | int     | 85       | Qualité compression JPEG (1-100)         |
| backgroundColor | String  | white    | Couleur de fond (white, black, #RRGGBB) |
| addPageNumbers  | boolean | false    | Numéros de page en pied                  |
| order           | String  | —        | Réordonnancement : "0,2,1"              |

### Headers de réponse

| Header                | Description                              |
|-----------------------|------------------------------------------|
| X-Images-Count        | Nombre d'images assemblées               |
| X-Total-Pages         | Nombre de pages dans le PDF              |
| X-Processing-Time-Ms  | Durée de traitement en ms                |
| X-Output-Size-Bytes   | Taille du PDF généré en bytes            |
| X-Async-Job-Id        | ID du job si traitement asynchrone       |

### Exemple de requête

```bash
# 3 images → PDF A4, orientation auto, marges moyennes
curl -X POST http://localhost:8080/api/v1/convert/images-to-pdf \
  -F "files=@photo1.jpg" \
  -F "files=@photo2.png" \
  -F "files=@scan.webp" \
  -F "pageSize=A4" \
  -F "orientation=auto" \
  -F "margin=medium" \
  -F "fitMode=fit" \
  -F "order=2,0,1" \
  -o "document_kovixel.pdf"
```

### Configuration

```yaml
kovixel:
  conversion:
    image-to-pdf:
      max-images: 50                 # Limite images par requête synchrone
      async-threshold-bytes: 52428800 # 50 MB → bascule en job asynchrone
      max-image-bytes: 20971520       # 20 MB par image
      default-jpeg-quality: 85
      default-page-size: A4
      xmp-metadata-enabled: true     # Métadonnées XMP dans le PDF généré
```

### Variables d'environnement

Aucune variable d'environnement supplémentaire requise.
L'outil Images → PDF fonctionne entièrement en local (PDFBox + TwelveMonkeys).
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7
  Config    Engine     API        Métriques  Tests      Frontend   Docs
```

> **PROMPT 3 (API)** peut être développé dès PROMPT 2 validé.
> **PROMPT 4 (Métriques)** peut être intégré directement dans PROMPT 2.
> **PROMPT 6 (Frontend)** peut démarrer dès PROMPT 3 validé.
> **PROMPT 5 (Tests)** s'exécute en dernier (valide tout le backend).

---

## Critères de validation finale

### Backend
- [ ] `mvn test` passe (ImageToPdfEngineTest, ImageDecoderTest, ControllerTest)
- [ ] 1 JPEG → PDF 1 page, Content-Type: application/pdf
- [ ] 5 PNG → PDF 5 pages, headers X-Images-Count=5 et X-Total-Pages=5
- [ ] WEBP assemblé correctement (TwelveMonkeys enregistré)
- [ ] PNG ARGB (transparence) → page avec fond blanc (ou transparent si demandé)
- [ ] `order=2,0,1` → les pages sont dans l'ordre demandé
- [ ] `fitMode=fit` sur petite image → image non agrandie au-delà de sa taille originale
- [ ] `orientation=auto` + image paysage → page PDF en mode paysage
- [ ] `pageSize=auto` → la page prend les dimensions de l'image
- [ ] `jpegQuality=30` vs `jpegQuality=95` → différence de taille significative
- [ ] `addPageNumbers=true` → texte "1", "2"... visible dans le PDF
- [ ] 51 images avec maxImages=50 → HTTP 400
- [ ] Image 25 MB avec maxImageBytes=20 MB → HTTP 400
- [ ] order invalide "0,0,1" (doublon) → HTTP 400
- [ ] Total > 50 MB → HTTP 202 + jobId (mode async)
- [ ] `curl /actuator/health` expose `images_to_pdf: UP`
- [ ] `curl /actuator/metrics/kovixel.conversion.images_to_pdf.total` retourne des valeurs

### Frontend
- [ ] Glisser-déposer multi-fichiers fonctionne
- [ ] Previews des images affichées dans la grille
- [ ] Réordonnancement par drag-and-drop change l'ordre d'envoi
- [ ] Sélecteur de format de page (A4, Letter, A3, auto) actif
- [ ] Orientation "auto" → le tooltip explique le comportement
- [ ] Slider qualité JPEG visible uniquement si fichier JPEG sélectionné
- [ ] Barre de progression 3 phases visible lors de l'upload
- [ ] Après succès : badge "X images · Y pages · Z KB" visible
- [ ] Bouton "Télécharger le PDF" déclenche le téléchargement automatique
- [ ] Route `/tools/convert/images-to-pdf` charge le composant dédié
- [ ] L'outil apparaît dans le catalogue des outils Kovixel

