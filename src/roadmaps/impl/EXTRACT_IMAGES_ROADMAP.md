
# 📋 Extraire Images : Roadmap d'implémentation Pro/Ultra-Pro

> **Contexte** : L'outil "Extraire Images" extrait les **images embarquées** dans un PDF
> (images intégrées en tant que ressources XObject dans le document)
> — il est **fondamentalement différent** de PDF→Images qui *rasterise les pages* en images.
>
> **Différences clés par rapport à PDF→Images :**
> - Extraction des `PDImageXObject` (JPEG, PNG, TIFF, JBIG2, CCITTFax) tels qu'ils sont stockés
>   dans le PDF, dans leur résolution native — aucun rendu de page, aucune perte de qualité
> - Déduplication automatique (même image répétée sur N pages → exportée une seule fois)
> - Filtrage par dimensions minimales (évite les micro-images décoratives)
> - Manifeste JSON complet : page, position bounding-box, dimensions, format, taille, hash SHA-256
> - Endpoint de prévisualisation `/preview` pour lister les images avant de les télécharger
> - Sélection fine par index, par page ou par format
>
> **Bibliothèque principale :** Apache PDFBox (déjà dans le projet) via `PDResources` /
> `PDImageXObject`. Aucune dépendance supplémentaire requise pour le plan FREE.
>
> **Instructions** : Exécuter les PROMPTs dans l'ordre.
> Chaque PROMPT est autonome et cite les fichiers à modifier.
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Requête POST /api/v1/extract/images
  params: file, format, minWidth, minHeight, minSizeKb,
          pages, imageIndices, deduplication, includeMetadata, quality
        │
        ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  ImageExtractionOptions (record + validation constructeur)       │
  │  format, pages, filters (dims, size), deduplication,            │
  │  imageIndices, includeMetadata, quality, outputFilename          │
  └─────────────────────────────────────────────────────────────────┘
        │
        ├─ Fichier > 20 MB ──► Job Asynchrone (AiJobService)
        │                       └─ GET /api/v1/jobs/{jobId}/result → ZIP
        │
        └─ Fichier ≤ 20 MB ──► Extraction Synchrone
                │
                ▼
        ┌──────────────────────────────────────────────────────────────┐
        │  ImageExtractionEngine (PDFBox)                              │
        │  Parcourt PDDocument → pages → PDResources → XObjects         │
        │  → filtre PDImageXObject (ignore les Form XObjects)          │
        └──────────────────────────────────────────────────────────────┘
                │
                ▼
        RawExtractedImage (avant déduplication + filtrage) :
          ├─ index global (0-based, ordre de découverte)
          ├─ page (1-based)
          ├─ xObjectName (COSName interne)
          ├─ rawBytes[]  (bytes bruts du flux image)
          ├─ colorSpace  ("RGB", "CMYK", "GRAY", "INDEXED", "LAB")
          ├─ widthPx, heightPx (dimensions natives)
          ├─ bitsPerComponent
          ├─ nativeFormat (JPEG, PNG, TIFF, JBIG2, CCITT, RAW)
          ├─ isSoftMask   (true = canal alpha/transparence)
          ├─ hasSoftMask  (true = image avec canal alpha associé)
          └─ boundingBox  (position dans la page, coordonnées PDF points)

        ▼
  ImageExtractionPostProcessor :
    ├─ 1. Conversion de format (si options.format() != ORIGINAL)
    │      → réencode les images en JPEG ou PNG via TwelveMonkeys/PDFBox
    ├─ 2. Déduplication SHA-256 (si options.deduplication() = true)
    │      → groupe les images identiques ; conserve la 1ère occurrence
    ├─ 3. Filtrage par dimensions (minWidth, minHeight)
    ├─ 4. Filtrage par taille de fichier (minSizeKb)
    ├─ 5. Filtrage par indices sélectionnés (imageIndices)
    ├─ 6. Filtrage soft masks (isSoftMask = true → ignorés par défaut)
    └─ 7. Tri : par page croissante, puis par index dans la page

        ▼
  ImageExtractionResult :
    ├─ List<ExtractedImage> images       (après filtrage)
    ├─ List<ExtractedImage> allImages    (avant filtrage, pour debug/preview)
    ├─ int totalFound                    (avant dédup + filtrage)
    ├─ int totalAfterDedup              (après déduplication)
    ├─ int totalExported                (après tous les filtres)
    ├─ int pagesAnalyzed
    ├─ long totalOutputSizeBytes
    ├─ String engine                    ("PDFBOX")
    └─ long durationMs

        ▼
  ZIP archive (toujours) :
    images/img_001_p01_800x600.jpg     ← nom structuré + dimensions
    images/img_002_p01_200x150.png
    images/img_003_p02_1920x1080.jpg
    ...
    manifest.json                      (présent si includeMetadata = true)

  manifest.json :
    {
      "extraction": { "totalFound": 12, "totalExported": 9, "pagesAnalyzed": 5, ... },
      "images": [
        {
          "index": 0, "filename": "img_001_p01_800x600.jpg",
          "page": 1, "widthPx": 800, "heightPx": 600,
          "nativeFormat": "JPEG", "exportFormat": "JPEG",
          "sizeBytes": 45231, "sha256": "a3f...",
          "colorSpace": "RGB", "bitsPerComponent": 8,
          "bounds": { "x1": 56.7, "y1": 320.4, "x2": 456.7, "y2": 620.4,
                      "pageWidth": 595.3, "pageHeight": 841.9 },
          "isDuplicate": false, "duplicateOf": null
        },
        ...
      ]
    }
```

---

## Comparatif moteurs d'extraction

| Moteur              | Qualité   | Plan requis | Forces                                                      |
|---------------------|-----------|-------------|-------------------------------------------------------------|
| PDFBox natif        | ★★★★★    | FREE        | Extraction native sans décodage, qualité originale 100 %    |
| TwelveMonkeys       | ★★★★☆    | FREE        | Ré-encodage de format (CMYK→RGB, JBIG2→PNG, CCITTFax→PNG)  |
| Ghostscript         | ★★★★☆    | PRO (opt.)  | Extraction CMYK haute fidélité, profils ICC                 |

> PDFBox est le moteur principal et suffit pour 95 % des cas.
> TwelveMonkeys est utilisé uniquement si une conversion de format est demandée
> ou si le format natif ne peut être renvoyé directement (JBIG2, CCITTFax).

## Comparatif formats de sortie

| Format exporté | MIME type    | Qualité    | Compatibilité | Cas d'usage optimal                          |
|----------------|--------------|------------|---------------|----------------------------------------------|
| ORIGINAL       | varies       | ★★★★★    | ★★★★☆        | Qualité maximale, format natif du PDF        |
| JPEG           | image/jpeg   | ★★★★☆    | ★★★★★        | Photos, compression forte, partage web       |
| PNG            | image/png    | ★★★★★    | ★★★★★        | Transparence, texte, graphiques, lossless    |

## Comparatif avec les concurrents

| Fonctionnalité                   | Smallpdf   | ILovePDF   | Adobe Acrobat | **Kovixel**     |
|----------------------------------|:----------:|:----------:|:-------------:|:---------------:|
| Extraction images embarquées     | ✅          | ✅          | ✅             | ✅               |
| Format natif (pas de resampling) | ❌          | ❌          | ✅             | ✅               |
| Déduplication automatique        | ❌          | ❌          | ❌             | ✅               |
| Manifeste JSON + métadonnées     | ❌          | ❌          | ❌             | ✅               |
| Filtrage par dimensions mini     | ❌          | ❌          | ❌             | ✅               |
| Prévisualisation avant télécharg.| ❌          | ❌          | ✅ (desktop)  | ✅ (web)         |
| Sélection fine par index/page    | ❌          | ❌          | ✅ (desktop)  | ✅               |
| Position bounding-box dans page  | ❌          | ❌          | ❌             | ✅               |
| Noms structurés (img_N_pP_WxH)   | ❌          | ❌          | ❌             | ✅               |
| Traitement asynchrone > 20 MB    | ❌          | ❌          | ❌             | ✅               |
| Transparence (soft masks)        | ❌          | partiel     | ✅             | ✅               |

---

## PROMPT 1 — Configuration & Types partagés

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionFormat.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionOptions.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/RawExtractedImage.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/ExtractedImage.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionResult.java`

```
1. Dans ConversionProperties.java, ajoute une section imbriquée `imageExtract`
   APRÈS la section `table` existante :

   /** Configuration de l'outil "Extraire Images". */
   @NestedConfigurationProperty
   private ImageExtract imageExtract = new ImageExtract();

   @Data
   public static class ImageExtract {

       /**
        * Taille maximale du fichier PDF source (en bytes).
        * Défaut : 50 MB
        */
       private long maxFileSizeBytes = 50L * 1024 * 1024;

       /**
        * Nombre maximum d'images pouvant être extraites par requête synchrone.
        * Au-delà → job asynchrone.
        * Défaut : 500
        */
       private int maxImages = 500;

       /**
        * Seuil en bytes au-delà duquel le traitement est délégué à un job asynchrone.
        * Défaut : 20 MB
        */
       private long asyncThresholdBytes = 20L * 1024 * 1024;

       /**
        * Largeur minimale par défaut (px) pour inclure une image.
        * Valeur 0 = aucun filtre. Défaut : 10 px
        */
       private int defaultMinWidthPx = 10;

       /**
        * Hauteur minimale par défaut (px) pour inclure une image.
        * Valeur 0 = aucun filtre. Défaut : 10 px
        */
       private int defaultMinHeightPx = 10;

       /**
        * Taille minimale par défaut (en KB) pour inclure une image.
        * Valeur 0 = aucun filtre. Défaut : 0 KB
        */
       private int defaultMinSizeKb = 0;

       /**
        * Active la déduplication SHA-256 par défaut.
        * Les images identiques ne sont exportées qu'une seule fois.
        * Défaut : true
        */
       private boolean deduplicationEnabledByDefault = true;

       /**
        * Exclut les soft masks (canaux alpha) de l'export par défaut.
        * Les soft masks sont des images internes de transparence rarement
        * utiles à l'utilisateur final.
        * Défaut : true
        */
       private boolean excludeSoftMasksByDefault = true;

       /**
        * Qualité JPEG pour la ré-encodage (0-100), utilisée uniquement
        * si l'option format=JPEG est sélectionnée.
        * Défaut : 90
        */
       private int defaultJpegQuality = 90;

       /**
        * Active l'endpoint de prévisualisation
        * (POST /api/v1/extract/images/preview).
        * Défaut : true
        */
       private boolean previewEnabled = true;
   }

2. Dans application.yml, sous kovixel.conversion, ajoute :

   image-extract:
     max-file-size-bytes: 52428800       # 50 MB
     max-images: 500
     async-threshold-bytes: 20971520     # 20 MB
     default-min-width-px: 10
     default-min-height-px: 10
     default-min-size-kb: 0
     deduplication-enabled-by-default: true
     exclude-soft-masks-by-default: true
     default-jpeg-quality: 90
     preview-enabled: true

3. Dans application-dev.yml, surcharge locale :

   image-extract:
     async-threshold-bytes: 2097152      # 2 MB en dev pour tester l'async
     max-images: 100

4. Crée ImageExtractionFormat.java (enum) dans le package imageextract :

   public enum ImageExtractionFormat {
       ORIGINAL ("original", null,         "varies"),
       JPEG     ("jpeg",     "image/jpeg", ".jpg"),
       PNG      ("png",      "image/png",  ".png");

       private final String slug;
       private final String mimeType;   // null = ORIGINAL (varie selon l'image)
       private final String extension;  // null = ORIGINAL (extension native)

       // static fromString(String) : case-insensitive, fallback ORIGINAL
       // static fromStringStrict(String) : lève IllegalArgumentException si inconnu
       // boolean requiresReencoding() : true si != ORIGINAL
   }

5. Crée ImageExtractionOptions.java (record) :

   public record ImageExtractionOptions(
       ImageExtractionFormat format,      // format de sortie : ORIGINAL, JPEG, PNG
       PageSelection         pages,       // sélection de pages (réutilise PageSelection existant)
       int                   minWidthPx,  // filtre : largeur minimale en pixels (0 = désactivé)
       int                   minHeightPx, // filtre : hauteur minimale en pixels (0 = désactivé)
       int                   minSizeKb,   // filtre : taille minimale en KB (0 = désactivé)
       boolean               deduplication,    // true = dédupliquer par SHA-256
       boolean               excludeSoftMasks, // true = exclure les soft masks
       List<Integer>         imageIndices,     // null = toutes, [0,2,5] = images 0,2,5 uniquement
       boolean               includeMetadata,  // true = inclure manifest.json dans le ZIP
       int                   jpegQuality,      // 1-100, ignoré si format != JPEG
       String                outputFilename    // nom de base du ZIP résultat
   ) {
       public ImageExtractionOptions {
           if (format == null) format = ImageExtractionFormat.ORIGINAL;
           if (pages == null)  pages  = new PageSelection.All();
           if (minWidthPx < 0)  throw new IllegalArgumentException("minWidthPx doit être >= 0");
           if (minHeightPx < 0) throw new IllegalArgumentException("minHeightPx doit être >= 0");
           if (minSizeKb < 0)   throw new IllegalArgumentException("minSizeKb doit être >= 0");
           if (jpegQuality < 1 || jpegQuality > 100)
               throw new IllegalArgumentException("jpegQuality doit être entre 1 et 100");
       }

       // Factories :
       public static ImageExtractionOptions defaults() { ... } // valeurs par défaut
       public static ImageExtractionOptions previewOnly() {    // pour l'endpoint /preview
           return new ImageExtractionOptions(ORIGINAL, All, 0, 0, 0, true, true, null, true, 90, "preview");
       }
   }

6. Crée RawExtractedImage.java (record) — image extraite AVANT post-traitement :

   public record RawExtractedImage(
       int    rawIndex,           // index de découverte brut (0-based, ordre de parcours)
       int    page,               // numéro de page PDF (1-based)
       String xObjectName,        // nom COSName interne (ex : "Im0", "Image14")
       byte[] rawBytes,           // flux image brut (sans ré-encodage)
       String nativeFormat,       // "JPEG", "PNG", "TIFF", "JBIG2", "CCITT", "RAW"
       String colorSpace,         // "RGB", "CMYK", "GRAY", "INDEXED", "LAB", "UNKNOWN"
       int    widthPx,
       int    heightPx,
       int    bitsPerComponent,   // 1, 2, 4, 8, 16
       boolean isSoftMask,        // true = image de transparence (canal alpha)
       boolean hasSoftMask,       // true = image accompagnée d'un soft mask associé
       double  x1, double y1, double x2, double y2,    // bounding box (coordonnées PDF)
       double  pageWidthPt, double pageHeightPt         // dimensions de la page en points
   ) {
       // Utilitaires :
       // long sizeBytes()     { return rawBytes.length; }
       // String sha256()      { return Hex.encodeHexString(DigestUtils.sha256(rawBytes)); }
       // boolean isSmallIcon(int minW, int minH) { return widthPx < minW || heightPx < minH; }

       // Pourcentages relatifs pour le manifeste JSON :
       // double leftPct()   { return x1 / pageWidthPt * 100; }
       // double topPct()    { return (pageHeightPt - y2) / pageHeightPt * 100; }
       // double widthPct()  { return (x2 - x1) / pageWidthPt * 100; }
       // double heightPct() { return (y2 - y1) / pageHeightPt * 100; }
   }

7. Crée ExtractedImage.java (record) — image APRÈS post-traitement (dédup, filtre, encode) :

   public record ExtractedImage(
       int     index,             // index dans la liste exportée (0-based)
       int     rawIndex,          // index de découverte d'origine (pour traçabilité)
       int     page,
       String  exportFilename,    // ex : "img_001_p01_800x600.jpg"
       byte[]  exportBytes,       // bytes du fichier exporté (format final)
       String  exportFormat,      // "JPEG", "PNG", "TIFF", etc.
       String  nativeFormat,      // format d'origine dans le PDF
       String  colorSpace,
       int     widthPx,
       int     heightPx,
       int     bitsPerComponent,
       long    exportSizeBytes,   // = exportBytes.length
       String  sha256,            // hash des bytes bruts (avant ré-encodage)
       boolean isDuplicate,       // true si c'est une occurrence de duplication
       Integer duplicateOf,       // rawIndex de l'image originale si isDuplicate = true
       // Bounding box :
       double  x1, double y1, double x2, double y2,
       double  pageWidthPt, double pageHeightPt
   ) {
       // Méthodes utilitaires similaires à RawExtractedImage (leftPct, topPct, widthPct, heightPct)
   }

8. Crée ImageExtractionResult.java (record) :

   public record ImageExtractionResult(
       List<ExtractedImage> images,       // images exportées (après tous les filtres)
       List<RawExtractedImage> allRaw,    // TOUTES les images brutes trouvées (avant filtrage)
       int    totalFound,                 // = allRaw.size()
       int    totalAfterDedup,            // après déduplication (avant filtres dims/size)
       int    totalExported,              // = images.size()
       int    pagesAnalyzed,
       long   totalOutputSizeBytes,       // somme de exportSizeBytes
       String engine,                     // "PDFBOX" (toujours)
       long   durationMs,
       byte[] zipBytes                    // le ZIP final à renvoyer au client
   ) {}
```

---

## PROMPT 2 — Moteur d'extraction (ImageExtractionEngine)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionEngine.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionException.java`

**Dépendances pom.xml à vérifier :**
- `org.apache.pdfbox:pdfbox` (déjà présente)
- `org.apache.commons:commons-imaging` (pour décoder JBIG2/CCITTFax si absent de PDFBox)
- `com.twelvemonkeys.imageio:imageio-jpeg` (déjà utilisé dans ImageIoConfig existant)
- `commons-codec:commons-codec` (pour DigestUtils.sha256)

```
Crée ImageExtractionEngine.java — moteur PDFBox d'extraction des images embarquées.

Classe ImageExtractionEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  List<RawExtractedImage> extract(byte[] pdfBytes, ImageExtractionOptions options)

Algorithme d'extraction :

  1. Ouvrir le PDF :
     try (PDDocument doc = Loader.loadPDF(pdfBytes)) {

  2. Résoudre la sélection de pages via PageSelectionParser.resolve(options.pages(), doc.getNumberOfPages())
     → Valider que la liste de pages n'est pas vide

  3. Compteur global rawIndex = 0;

  4. Pour chaque numéro de page dans la sélection de pages (1-based) :
     PDPage page = doc.getPage(pageIndex);  // pageIndex = page - 1
     PDResources resources = page.getResources();
     PDRectangle mediaBox = page.getMediaBox();

     Pour chaque xObjectName dans resources.getXObjectNames() :
       PDXObject xObj = resources.getXObject(xObjectName);

       if (!(xObj instanceof PDImageXObject image)) continue;  // ignorer les Form XObjects

       // Récupérer la matrice de transformation (position dans la page)
       // Utiliser PDFStreamEngine/PDPageContentStream pour obtenir les vraies coordonnées :
       // La bounding box est calculée depuis la CTM (Current Transformation Matrix)
       // de l'image dans le flux de la page (via drawObject operators).
       // Si la position exacte n'est pas disponible (XObject partagé entre pages),
       // utiliser null pour les bounds (sera null dans le manifeste).
       double[] bounds = extractImageBounds(doc, page, xObjectName.getName());

       // Extraire le flux natif :
       // PDFBox expose les bytes bruts via image.getCOSStream().toByteArray() —
       // ce sont les bytes compressés SELON le filtre du stream (DCTDecode=JPEG, etc.)
       // Pour obtenir les bytes DÉCODÉS (pixels), on utilise image.getImage()
       // Pour obtenir les bytes natifs tels qu'encodés dans le PDF :
       //   - JPEG (DCTDecode)  → image.getCOSObject().createRawInputStream()
       //   - PNG  (FlateDecode) → image.getImage() puis ré-encoder en PNG
       //   - TIFF (CCITTFacsimileDecoder) → image.getImage() puis ré-encoder en TIFF
       //   - JBIG2 (JBIG2Decode) → image.getImage() puis ré-encoder en PNG (perte format)
       //   - RAW  (aucun filtre) → image.getImage() puis ré-encoder

       String nativeFormat = detectNativeFormat(image);
       byte[] rawBytes     = extractRawBytes(image, nativeFormat);
       String colorSpace   = detectColorSpace(image);
       boolean isSoftMask  = detectIsSoftMask(xObjectName, resources);
       boolean hasSoftMask = image.getCOSObject().containsKey(COSName.SMASK);

       RawExtractedImage raw = new RawExtractedImage(
           rawIndex++, page (1-based),
           xObjectName.getName(),
           rawBytes, nativeFormat, colorSpace,
           image.getWidth(), image.getHeight(), image.getBitsPerComponent(),
           isSoftMask, hasSoftMask,
           bounds != null ? bounds[0] : 0, bounds != null ? bounds[1] : 0,
           bounds != null ? bounds[2] : 0, bounds != null ? bounds[3] : 0,
           mediaBox.getWidth(), mediaBox.getHeight()
       );

       result.add(raw);

     }
  }

  5. Valider que result.size() <= props.getImageExtract().getMaxImages()
     → Si dépassement → KovixelException(VALIDATION_ERROR, HTTP 400)

  6. Retourner result (avant déduplication/filtrage — fait dans PostProcessor)

────────────────────────────────────────────────────────────────────
Méthode detectNativeFormat(PDImageXObject image) : String
  Lire les filtres du COSStream :
  - COSName.DCT_DECODE ou DCT_DECODE_ABBREVIATION → "JPEG"
  - COSName.FLATE_DECODE ou FLATE_DECODE_ABBREVIATION → "PNG" (si CS=DeviceRGB/Gray)
  - COSName.JBIG2_DECODE → "JBIG2"
  - COSName.CCITTFAX_DECODE → "CCITT"
  - COSName.JPX_DECODE → "JPX"   (JPEG 2000)
  - Aucun filtre → "RAW"

Méthode extractRawBytes(PDImageXObject image, String nativeFormat) : byte[]
  Si nativeFormat == "JPEG" :
    // Extraire les bytes DCT bruts (vrais bytes JPEG, sans décodage)
    try (InputStream is = image.getCOSObject().createRawInputStream()) {
        return is.readAllBytes();
    }
    // NOTE : Pour les JPEG embarqués en CMYK (Adobe, etc.), PDFBox peut retourner
    // les bytes avec un en-tête JPEG non standard. Gérer le cas dans PostProcessor.

  Si nativeFormat == "PNG", "JBIG2", "CCITT", "JPX", "RAW" :
    // Décoder en BufferedImage puis ré-encoder dans le format approprié
    BufferedImage bi = image.getImage();
    return ImageUtils.encodeToOriginalOrPng(bi, nativeFormat);

Méthode detectColorSpace(PDImageXObject image) : String
  PDColorSpace cs = image.getColorSpace();
  if (cs instanceof PDDeviceRGB || cs instanceof PDICCBased { isRGB })  → "RGB"
  if (cs instanceof PDDeviceCMYK || cs instanceof PDICCBased { isCMYK }) → "CMYK"
  if (cs instanceof PDDeviceGray) → "GRAY"
  if (cs instanceof PDIndexed)    → "INDEXED"
  if (cs instanceof PDLab)        → "LAB"
  else → "UNKNOWN"

Méthode detectIsSoftMask(COSName name, PDResources resources) : boolean
  Parcourir les XObjects du document et vérifier si cette image est référencée
  en tant que SMask d'une autre image.
  Alternative simple : vérifier si image.isStencil() → true indique un masque binaire.

Méthode extractImageBounds(PDDocument doc, PDPage page, String xObjectName) : double[]
  Analyser le flux de contenu de la page via PDFStreamEngine :
  - Sous-classer PDFStreamEngine, implémenter processOperator("Do", ...)
  - Quand l'opérande correspond au xObjectName : récupérer la CTM
    (getCurrentTransformationMatrix()) → construire la bounding box
  - Convertir les coordonnées PDF (origine bas-gauche) en coordonnées standard (origine haut-gauche)
  - Retourner double[] { x1, y1, x2, y2 } ou null si non trouvé

Crée ImageExtractionException extends RuntimeException
  avec constructeur(String message, Throwable cause).
```

---

## PROMPT 3 — Post-processeur (ImageExtractionPostProcessor)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionPostProcessor.java`
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageUtils.java`

```
Crée ImageExtractionPostProcessor.java — filtre, déduplique, convertit et nomme les images.

Classe ImageExtractionPostProcessor :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  List<ExtractedImage> process(List<RawExtractedImage> rawImages, ImageExtractionOptions options)

Étapes dans l'ordre :

  1. EXCLUSION DES SOFT MASKS (si options.excludeSoftMasks()) :
     rawImages = rawImages.stream()
         .filter(img -> !img.isSoftMask())
         .toList();
     log.debug("Après exclusion soft masks : {} images", rawImages.size());

  2. DÉDUPLICATION PAR SHA-256 (si options.deduplication()) :
     Map<String, RawExtractedImage> seenHashes = new LinkedHashMap<>();
     List<String> duplicateHashes = new ArrayList<>();

     Pour chaque image :
       String hash = DigestUtils.sha256Hex(img.rawBytes());
       if (seenHashes.containsKey(hash)) :
           duplicateHashes.add(hash);  // image dupliquée, sera marquée
       else :
           seenHashes.put(hash, img);

     Les images dupliquées sont conservées dans allRaw pour le manifeste (isDuplicate=true),
     mais exclues de la liste exportée.
     Logger : "Déduplication : {} images uniques sur {} brutes"

  3. FILTRAGE PAR DIMENSIONS MINIMALES :
     Si options.minWidthPx() > 0 || options.minHeightPx() > 0 :
       filter(img -> img.widthPx() >= options.minWidthPx()
                  && img.heightPx() >= options.minHeightPx())

  4. FILTRAGE PAR TAILLE MINIMALE :
     Si options.minSizeKb() > 0 :
       filter(img -> img.sizeBytes() >= options.minSizeKb() * 1024L)

  5. FILTRAGE PAR INDICES SÉLECTIONNÉS :
     Si options.imageIndices() != null && !empty :
       filter par index dans la liste ordonnée actuelle
       (l'index est recalculé APRÈS les étapes 1-4 pour rester cohérent)

  6. CONVERSION DE FORMAT :
     Si options.format() == ORIGINAL :
       → Pas de ré-encodage, utiliser rawBytes directement
       → Extension selon nativeFormat : JPEG→.jpg, PNG→.png, TIFF→.tiff,
         JBIG2→.png (converti), CCITT→.tiff (converti), RAW→.png (converti), JPX→.jpg

     Si options.format() == JPEG :
       → Décoder en BufferedImage (via image.getImage() ou ImageIO.read(rawBytes))
       → Si colorSpace = "CMYK" : convertir CMYK→RGB avant encodage JPEG
         (AWT ne gère pas le JPEG CMYK en sortie nativement)
       → Encoder en JPEG avec quality = options.jpegQuality()
       → Extension : .jpg

     Si options.format() == PNG :
       → Décoder en BufferedImage
       → Si hasSoftMask : composer l'image avec son canal alpha (merge des pixels)
       → Encoder en PNG (lossless)
       → Extension : .png

  7. CONSTRUCTION DES NOMS DE FICHIERS :
     Nommer chaque image selon le pattern :
       img_{NNN}_{pPP}_{WxH}.{ext}
     Où :
       NNN = index padé sur 3 chiffres (001, 002, ...)
       PP  = numéro de page padé sur 2 chiffres (01, 02, ...)
       W   = largeur en pixels
       H   = hauteur en pixels
       ext = extension selon le format exporté

     Exemple : "img_003_p02_1920x1080.jpg"

  8. CALCUL DU SHA-256 FINAL :
     sha256 = DigestUtils.sha256Hex(img.rawBytes())  // hash des bytes BRUTS (avant conversion)

  9. TRI FINAL : par page (ASC), puis par rawIndex (ASC)

  10. CONSTRUCTION DE ExtractedImage :
      Pour chaque image retenue, construire le record ExtractedImage avec toutes les données.
      Marquer isDuplicate = false (les vraies images dupliquées ont été exclues à l'étape 2).

────────────────────────────────────────────────────────────────────
Crée ImageUtils.java :
- Annotée @UtilityClass (Lombok) ou classe avec constructeur privé
- Méthodes statiques utilitaires

  // Encode une BufferedImage en bytes JPEG avec la qualité donnée
  public static byte[] encodeJpeg(BufferedImage bi, int quality)

  // Encode une BufferedImage en bytes PNG
  public static byte[] encodePng(BufferedImage bi)

  // Lit un BufferedImage depuis des bytes (format auto-détecté par ImageIO)
  // Lance ImageExtractionException si échec
  public static BufferedImage decodeImage(byte[] bytes)

  // Convertit un espace colorimétrique CMYK → RGB
  // (nécessaire avant encoding JPEG avec AWT)
  public static BufferedImage cmykToRgb(BufferedImage cmyk)

  // Compose une image RGB avec son soft mask (canal alpha) → RGBA PNG
  public static BufferedImage applyAlphaMask(BufferedImage image, BufferedImage mask)

  // Retourne l'extension pour un nativeFormat donné
  public static String extensionForNativeFormat(String nativeFormat)
```

---

## PROMPT 4 — Construction du ZIP et manifeste JSON

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionZipBuilder.java`

```
Crée ImageExtractionZipBuilder.java — construit le ZIP final contenant les images
et optionnellement le manifeste JSON.

Classe ImageExtractionZipBuilder :
- Annotée @Component, @Slf4j
- Injecte ObjectMapper (Spring auto-configure Jackson)

Méthode principale :
  byte[] build(List<ExtractedImage> images, List<RawExtractedImage> allRaw,
               ImageExtractionResult result, ImageExtractionOptions options)
  throws IOException

Structure du ZIP :

  Pour chaque ExtractedImage :
    Entrée ZIP : "images/{exportFilename}"
    Content    : exportBytes
    Niveau de compression :
      - JPEG natif → STORED (déjà compressé, la compression ZIP n'aide pas)
      - PNG natif  → STORED (déjà compressé)
      - JPEG converti → STORED (idem)
      - PNG converti  → STORED (idem)
    → Utiliser ZipEntry.STORED pour toutes les images (performance + taille)

  Si options.includeMetadata() :
    Entrée ZIP : "manifest.json"
    Niveau de compression : DEFLATED (JSON = texte, se compresse bien)
    Contenu :

    {
      "extraction": {
        "version": "1.0",
        "generatedAt": "2025-06-23T10:30:00Z",
        "engine": "PDFBOX",
        "processingMs": 347,
        "totalFound": 12,
        "totalAfterDedup": 9,
        "totalExported": 7,
        "pagesAnalyzed": 5,
        "totalOutputSizeBytes": 284521,
        "options": {
          "format": "ORIGINAL",
          "deduplication": true,
          "minWidthPx": 50,
          "minHeightPx": 50,
          "minSizeKb": 0,
          "jpegQuality": 90
        }
      },
      "images": [
        {
          "index": 0,
          "rawIndex": 0,
          "filename": "img_001_p01_800x600.jpg",
          "page": 1,
          "widthPx": 800,
          "heightPx": 600,
          "nativeFormat": "JPEG",
          "exportFormat": "JPEG",
          "colorSpace": "RGB",
          "bitsPerComponent": 8,
          "sizeBytes": 45231,
          "sha256": "a3f4b2...",
          "isDuplicate": false,
          "duplicateOf": null,
          "hasSoftMask": false,
          "bounds": {
            "x1": 56.7, "y1": 320.4, "x2": 456.7, "y2": 620.4,
            "pageWidthPt": 595.3, "pageHeightPt": 841.9,
            "leftPct": 9.53, "topPct": 26.84, "widthPct": 67.20, "heightPct": 35.70
          }
        },
        {
          "index": null,
          "rawIndex": 3,
          "filename": null,
          "page": 1,
          "isDuplicate": true,
          "duplicateOf": 0,
          "sha256": "a3f4b2...",
          "widthPx": 800, "heightPx": 600,
          "note": "Image identique à img_001_p01_800x600.jpg (logo répété)"
        }
      ]
    }

    Note : les images dupliquées sont listées dans le manifeste avec isDuplicate=true
    mais ne sont PAS incluses comme fichiers dans le ZIP.
    Le champ "duplicateOf" pointe vers le rawIndex de l'original.

  Si 0 images exportées :
    - Le ZIP contient UNIQUEMENT manifest.json (avec "totalExported": 0 et un champ "warning")
    - manifest.json inclut le champ :
      "warning": "Aucune image exportée après application des filtres. ..."
    - Jamais une réponse HTTP 500 ou un ZIP vide.

  Si 1 seule image exportée ET !includeMetadata :
    → Retourner l'image directement (pas de ZIP) avec le bon Content-Type
    (optimisation UX : évite un ZIP d'un seul fichier)
    Note : signaler ce comportement dans les headers HTTP (voir PROMPT 5)

Méthode privée writeZip(Map<String, byte[]> entries) : byte[]
  Utiliser ZipOutputStream avec ByteArrayOutputStream.
```

---

## PROMPT 5 — Service orchestrateur (ImageExtractionService)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionService.java`

```
Crée ImageExtractionService.java — orchestre l'extraction, le post-traitement
et la construction du ZIP.

Classe ImageExtractionService :
- Annotée @Service, @Slf4j
- Injecte : ConversionProperties, ImageExtractionEngine, ImageExtractionPostProcessor,
            ImageExtractionZipBuilder, MeterRegistry

Méthode principale :
  ImageExtractionResult extract(byte[] pdfBytes, ImageExtractionOptions options)

Logique :
  long startMs = System.currentTimeMillis();
  String engine = "PDFBOX";

  1. Extraire les images brutes :
     List<RawExtractedImage> allRaw = engine.extract(pdfBytes, options);
     log.info("Extraction brute : {} images trouvées", allRaw.size());

  2. Post-traitement (dédup, filtre, encode) :
     List<ExtractedImage> images = postProcessor.process(allRaw, options);
     log.info("Après post-traitement : {} images retenues", images.size());

  3. Calculer les statistiques :
     int totalFound     = allRaw.size();
     int totalAfterDedup = /* allRaw.size() - nombre de doublons */
     int totalExported  = images.size();
     int pagesAnalyzed  = (int) allRaw.stream().map(RawExtractedImage::page).distinct().count();
     long totalOutputBytes = images.stream().mapToLong(ExtractedImage::exportSizeBytes).sum();
     long durationMs    = System.currentTimeMillis() - startMs;

  4. Construire le résultat intermédiaire (sans ZIP) :
     ImageExtractionResult partial = new ImageExtractionResult(
         images, allRaw, totalFound, totalAfterDedup, totalExported,
         pagesAnalyzed, totalOutputBytes, engine, durationMs, null
     );

  5. Construire le ZIP :
     byte[] zipBytes = zipBuilder.build(images, allRaw, partial, options);

  6. Enregistrer les métriques (voir PROMPT 7)

  7. Retourner le résultat final avec zipBytes.

Méthode previewExtract(byte[] pdfBytes, ImageExtractionOptions previewOptions) :
  ImageExtractionResult
  → Identique à extract() SAUF :
    a. Pas de buildZip() (coûteux)
    b. Pas de conversion de format (rawBytes non décodés)
    c. Retourner ImageExtractionResult avec zipBytes = null
    d. allRaw = même extraction complète (on a besoin des métadonnées)
    e. images = résultat du postProcessor SANS conversion (simuler la liste finale)
  → Cette méthode est rapide et utilisée par l'endpoint /preview.
```

---

## PROMPT 6 — Endpoint API

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Ajoute les deux endpoints "Extraire Images" dans ConversionController.java.
(Ou crée un ExtractController.java séparé si ConversionController est trop long.)

────────────────────────────────────────────────────────────────────
Endpoint principal :
────────────────────────────────────────────────────────────────────

@PostMapping("/api/v1/extract/images")
@Operation(summary = "Extraire les images embarquées d'un PDF")
@CheckQuota(feature = FeatureType.CONVERSION)
public ResponseEntity<?> extractImages(
    @RequestParam("file")                          MultipartFile file,
    @RequestParam(defaultValue = "original")       String format,
    @RequestParam(required = false)                String pages,
    @RequestParam(defaultValue = "10")             int minWidthPx,
    @RequestParam(defaultValue = "10")             int minHeightPx,
    @RequestParam(defaultValue = "0")              int minSizeKb,
    @RequestParam(defaultValue = "true")           boolean deduplication,
    @RequestParam(defaultValue = "true")           boolean excludeSoftMasks,
    @RequestParam(required = false)                List<Integer> imageIndices,
    @RequestParam(defaultValue = "true")           boolean includeMetadata,
    @RequestParam(defaultValue = "90")             int jpegQuality,
    @AuthenticationPrincipal UserDetails userDetails) throws Exception

Validation :
  - format      → ImageExtractionFormat.fromStringStrict(format) [sinon 400]
  - pages       → PageSelectionParser.parse(pages)               [null → All]
  - minWidthPx  → doit être >= 0
  - minHeightPx → doit être >= 0
  - minSizeKb   → doit être >= 0
  - jpegQuality → doit être dans [1, 100]
  - imageIndices → si présent, tous >= 0
  - file.getSize() > props.imageExtract.maxFileSizeBytes → HTTP 413

Seuil async : file.getSize() > props.getImageExtract().getAsyncThresholdBytes()
  → soumettre un job asynchrone, retourner HTTP 202 + { jobId, pollUrl }

Flow synchrone :
  1. Valider les paramètres
  2. Construire ImageExtractionOptions
  3. imageExtractionService.extract(file.getBytes(), options)
  4. Construire la réponse HTTP

Réponse (cas général — plusieurs images) :
  - HTTP 200
  - Content-Type: application/zip
  - Body: result.zipBytes()
  - Nom du fichier ZIP : "{baseName}_images.zip"

Réponse (cas spécial — 1 seule image ET !includeMetadata) :
  - HTTP 200
  - Content-Type: selon le format de l'image unique (image/jpeg, image/png...)
  - Body: image directe (pas de ZIP)
  - Header X-Direct-Image: "true"

Headers de réponse (TOUJOURS présents) :
  X-Images-Found:           nombre total trouvées dans le PDF (avant filtrage)
  X-Images-After-Dedup:     nombre après déduplication
  X-Images-Exported:        nombre dans le ZIP (après tous les filtres)
  X-Pages-Analyzed:         nombre de pages analysées
  X-Total-Output-Size:      taille totale des images exportées en bytes
  X-Extraction-Engine:      "PDFBOX"
  X-Processing-Time-Ms:     durée en ms
  Content-Disposition:      attachment; filename="{baseName}_images.zip"

Si 0 images exportées (après filtrage) :
  - HTTP 200 avec un ZIP contenant uniquement manifest.json
  - Header X-Warning: "NO_IMAGES_EXPORTED — voir manifest.json pour les détails"
  - Jamais HTTP 204 ou HTTP 404 : le client peut toujours lire le manifeste

────────────────────────────────────────────────────────────────────
Endpoint de prévisualisation :
────────────────────────────────────────────────────────────────────

@PostMapping("/api/v1/extract/images/preview")
@Operation(summary = "Lister les images détectées sans les extraire")
@CheckQuota(feature = FeatureType.CONVERSION)
public ResponseEntity<Map<String, Object>> extractImagesPreview(
    @RequestParam("file")                          MultipartFile file,
    @RequestParam(required = false)                String pages,
    @RequestParam(defaultValue = "0")              int minWidthPx,
    @RequestParam(defaultValue = "0")              int minHeightPx,
    @RequestParam(defaultValue = "0")              int minSizeKb,
    @RequestParam(defaultValue = "true")           boolean deduplication,
    @RequestParam(defaultValue = "true")           boolean excludeSoftMasks,
    @AuthenticationPrincipal UserDetails userDetails) throws Exception

Vérifier props.imageExtract.previewEnabled → sinon HTTP 503.
Construire ImageExtractionOptions.previewOnly() avec les paramètres.
Appelle imageExtractionService.previewExtract().

Réponse JSON :
{
  "totalFound": 12,
  "totalAfterDedup": 9,
  "totalExported": 7,
  "pagesAnalyzed": 5,
  "processingMs": 180,
  "images": [
    {
      "index": 0,
      "page": 1,
      "widthPx": 800,
      "heightPx": 600,
      "nativeFormat": "JPEG",
      "colorSpace": "RGB",
      "sizeBytes": 45231,
      "sha256": "a3f4b2...",
      "isDuplicate": false,
      "isSoftMask": false,
      "bounds": {
        "leftPct": 9.53, "topPct": 26.84,
        "widthPct": 67.20, "heightPct": 35.70
      },
      "thumbnailUrl": null
    }
  ]
}

Cet endpoint est utilisé par le frontend AVANT que l'utilisateur lance l'extraction
pour afficher la liste des images disponibles et permettre la sélection fine.
```

---

## PROMPT 7 — Métriques & Health Indicator

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/imageextract/ImageExtractionService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`

```
1. Dans ImageExtractionService.extract(), après la construction du résultat,
   ajouter les métriques Micrometer :

   // ── Compteur global ──────────────────────────────────────────────────────
   Counter.builder("kovixel.extract.images.total")
       .tag("engine", result.engine())
       .tag("format", options.format().name())
       .tag("status", result.totalExported() > 0 ? "IMAGES_FOUND" : "NO_IMAGES")
       .register(meterRegistry)
       .increment();

   // ── Timer de durée ───────────────────────────────────────────────────────
   Timer.builder("kovixel.extract.images.duration")
       .tag("engine", result.engine())
       .register(meterRegistry)
       .record(result.durationMs(), TimeUnit.MILLISECONDS);

   // ── Distribution : images trouvées ───────────────────────────────────────
   DistributionSummary.builder("kovixel.extract.images.found")
       .tag("engine", result.engine())
       .register(meterRegistry)
       .record(result.totalFound());

   // ── Distribution : images exportées ──────────────────────────────────────
   DistributionSummary.builder("kovixel.extract.images.exported")
       .register(meterRegistry)
       .record(result.totalExported());

   // ── Distribution : taux de déduplication ─────────────────────────────────
   if (options.deduplication() && result.totalFound() > 0) {
       double dedupRatio = 1.0 - (double) result.totalAfterDedup() / result.totalFound();
       DistributionSummary.builder("kovixel.extract.images.dedup_ratio")
           .register(meterRegistry)
           .record(dedupRatio);
   }

   // ── Taille totale exportée ────────────────────────────────────────────────
   DistributionSummary.builder("kovixel.extract.images.output_size_bytes")
       .baseUnit("bytes")
       .register(meterRegistry)
       .record(result.totalOutputSizeBytes());

2. Dans ConversionEngineHealthIndicator, ajoute après les métriques table :

   // ── ImageExtractionEngine (PDFBox) ────────────────────────────────────────
   details.put("extract.images", "UP");
   details.put("extract.images.engine", "PDFBOX");
   details.put("extract.images.preview",
       props.getImageExtract().isPreviewEnabled() ? "ENABLED" : "DISABLED");
   details.put("extract.images.maxImages",
       String.valueOf(props.getImageExtract().getMaxImages()));
```

---

## PROMPT 8 — Frontend Angular : composant dédié

**Fichiers à créer :**
- `kovixel-ui/src/app/features/tools/pdf-extract-images/pdf-extract-images.component.ts`
- `kovixel-ui/src/app/features/tools/pdf-extract-images/pdf-extract-images.routes.ts`

**Fichiers à modifier :**
- `kovixel-ui/src/app/app.routes.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
Crée PdfExtractImagesComponent — composant Angular standalone, OnPush.
Pattern identique aux autres outils : max-w-2xl, kov-card, stepper à 3 étapes.

────────────────────────────────────────────────────────────────────
Étapes (stepper) :
  1. Fichier       — Upload du PDF
  2. Aperçu        — Sélection des images à extraire (appel /preview)
  3. Résultat      — Téléchargement du ZIP
(+ états transitoires : processing, error)
────────────────────────────────────────────────────────────────────

Signaux :
  // Navigation
  currentStep = signal<'upload'|'preview'|'processing'|'result'|'error'>('upload')
  errorMsg    = signal<string | null>(null)

  // Fichier sélectionné
  selectedFile = signal<File | null>(null)

  // Aperçu (liste des images détectées)
  previewImages   = signal<PreviewImage[]>([])
  isPreviewLoading = signal(false)
  selectedIndices  = signal<Set<number>>(new Set())  // null = toutes

  // Options d'extraction
  outputFormat    = signal<'original'|'jpeg'|'png'>('original')
  minWidthPx      = signal(50)
  minHeightPx     = signal(50)
  deduplication   = signal(true)
  jpegQuality     = signal(90)
  includeMetadata = signal(true)
  showAdvanced    = signal(false)

  // Résultats
  imagesFound    = signal<number | null>(null)
  imagesExported = signal<number | null>(null)
  outputSizeBytes = signal<number | null>(null)
  processingMs   = signal<number | null>(null)
  resultBlob     = signal<Blob | null>(null)
  resultFilename = signal<string>('')
  hasWarning     = signal(false)  // true si 0 images exportées

Interface PreviewImage :
  index: number
  page: number
  widthPx: number
  heightPx: number
  nativeFormat: string   // "JPEG", "PNG", "TIFF", etc.
  colorSpace: string
  sizeBytes: number
  isDuplicate: boolean
  isSoftMask: boolean
  isSelected: boolean    // signal local de sélection

────────────────────────────────────────────────────────────────────
Template — 3 étapes visuelles
────────────────────────────────────────────────────────────────────

ÉTAPE 1 — UPLOAD :
╔══════════════════════════════════════════════════════════════════╗
║  📂 Sélectionnez votre PDF                                       ║
║  PDF uniquement · max 50 MB                                      ║
║                                                                  ║
║  [    Zone glisser-déposer / clic pour parcourir    ]           ║
║                                                                  ║
║  → À la sélection : affiche le nom du fichier + taille,         ║
║    bouton "Analyser les images →"                                ║
╚══════════════════════════════════════════════════════════════════╝

Au clic "Analyser" → appel POST /preview → currentStep = 'preview'

ÉTAPE 2 — APERÇU ET OPTIONS :
╔══════════════════════════════════════════════════════════════════╗
║  🔍 X images détectées dans ce PDF                               ║
║                                                                  ║
║  ┌──────────────────────────────────────────────────────────┐   ║
║  │  #1 · Page 1 · 800×600 · JPEG · RGB · 44 KB  [☑ Choisir]   ║
║  │  #2 · Page 1 · 200×150 · PNG  · RGB ·  8 KB  [☑ Choisir]   ║
║  │  #3 · Page 2 · 1920×1080 · JPEG · RGB · 320 KB [☑ Choisir]  ║
║  │  #4 · Page 2 · 800×600 · JPEG · RGB · 44 KB  [⚠ Doublon]   ║
║  │  #5 · Page 3 · 16×16 · PNG · RGB · 0.5 KB    [⚠ Trop petit]║
║  └──────────────────────────────────────────────────────────┘   ║
║                                                                  ║
║  ☑ Tout sélectionner  ☐ Désélectionner tout                     ║
║                                                                  ║
║  ── FORMAT D'EXPORT ──────────────────────────────────────────── ║
║  ○ Format d'origine    ○ Convertir en JPEG    ○ Convertir en PNG ║
║                                                                  ║
║  ── FILTRES ──────────────────────────────────────────────────── ║
║  Taille minimale :  [50] × [50] px                              ║
║                                                                  ║
║  ── OPTIONS AVANCÉES (repliable) ─────────────────────────────── ║
║  ☑ Dédupliquer (supprimer les images identiques)                ║
║  ☑ Inclure le manifeste JSON (positions, métadonnées)           ║
║  Qualité JPEG : [90] %  (visible si format = JPEG)             ║
╚══════════════════════════════════════════════════════════════════╝

Badges visuels dans la liste :
  - "Doublon" (orange) si isDuplicate = true
  - Format badge : JPEG (bleu), PNG (vert), TIFF (gris), JBIG2 (rouge)
  - Taille : affichée en Ko ou Mo selon la taille

Bouton d'action :
  [⬇ Extraire {N} image(s) sélectionnée(s) · {Format} · ~{taille estimée}]
  Désactivé si aucune image sélectionnée.

ÉTAPE 3 — RÉSULTAT (success) :
╔══════════════════════════════════════════════════════════════════╗
║  ✅ Extraction réussie                                           ║
║                                                                  ║
║  📸 7 images exportées sur 12 détectées                         ║
║  💾 Taille totale : 1.2 MB                                      ║
║  🔄 3 doublons supprimés · ⚡ 0.3s                              ║
║                                                                  ║
║  [⬇ Télécharger images.zip (1.2 MB)]                           ║
║                                                                  ║
║  [🔄 Changer les options]  [📂 Autre fichier]                   ║
╚══════════════════════════════════════════════════════════════════╝

Cas 0 images exportées :
╔══════════════════════════════════════════════════════════════════╗
║  ⚠ Aucune image exportée                                        ║
║  12 images ont été détectées mais toutes ont été filtrées.      ║
║  Essayez :                                                       ║
║  • Réduire la taille minimale (actuellement 50×50 px)           ║
║  • Décocher "Dédupliquer"                                       ║
║  [🔄 Modifier les filtres]   [⬇ Tout exporter sans filtre]      ║
╚══════════════════════════════════════════════════════════════════╝

────────────────────────────────────────────────────────────────────
ConversionService Angular — nouvelles méthodes à ajouter
────────────────────────────────────────────────────────────────────

// Prévisualisation (avant extraction)
extractImagesPreview(
  file: File,
  pages: string = 'all',
  minWidthPx: number = 0,
  minHeightPx: number = 0,
  minSizeKb: number = 0,
  deduplication: boolean = true,
  excludeSoftMasks: boolean = true
): Observable<PreviewResponse>
→ POST /api/v1/extract/images/preview
→ responseType: 'json'

// Extraction complète
extractImages(
  file: File,
  format: 'original' | 'jpeg' | 'png' = 'original',
  pages: string = 'all',
  minWidthPx: number = 10,
  minHeightPx: number = 10,
  minSizeKb: number = 0,
  deduplication: boolean = true,
  excludeSoftMasks: boolean = true,
  imageIndices: number[] | null = null,
  includeMetadata: boolean = true,
  jpegQuality: number = 90
): Observable<HttpEvent<Blob>>
→ POST /api/v1/extract/images
→ responseType: 'blob', observe: 'events', reportProgress: true
→ Lire les headers de réponse :
    X-Images-Found, X-Images-After-Dedup, X-Images-Exported,
    X-Pages-Analyzed, X-Total-Output-Size, X-Processing-Time-Ms,
    X-Direct-Image (si 1 image directe)

────────────────────────────────────────────────────────────────────
app.routes.ts — ajouter AVANT les routes génériques :
────────────────────────────────────────────────────────────────────

{
  path: 'tools/extract/images',
  loadComponent: () =>
    import('./features/tools/pdf-extract-images/pdf-extract-images.component')
      .then(m => m.PdfExtractImagesComponent),
  data: { title: 'Extraire Images PDF' }
}

────────────────────────────────────────────────────────────────────
tools-config.ts — mettre à jour extract/images :
────────────────────────────────────────────────────────────────────

{
  slug:            'extract/images',
  name:            'Extraire images',
  description:     'Récupérez toutes les images embarquées du PDF',
  longDescription: 'Extrait les images intégrées dans votre PDF dans leur résolution '
                 + 'd\'origine (JPEG reste JPEG, PNG reste PNG). '
                 + 'Déduplication automatique, filtrage par taille, '
                 + 'manifeste JSON avec position et métadonnées de chaque image. '
                 + 'Sélectionnez précisément les images à exporter avant de télécharger.',
  category:        'extract',
  icon:            ImageDown,
  badge:           'NEW',           // ← changer de SOON à NEW
  estimatedTime:   '~3 secondes',
  isPro:           false,
  isAvailable:     true,            // ← activer
  backendEndpoint: '/api/v1/extract/images',
  keywords:        ['images', 'jpg', 'jpeg', 'png', 'tiff', 'photos', 'zip',
                    'télécharger', 'embedded', 'intégré', 'extraction', 'ressource'],
}
```

---

## PROMPT 9 — Tests complets

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/imageextract/ImageExtractionEngineTest.java`
- `src/test/java/com/kovixel/core/conversion/imageextract/ImageExtractionPostProcessorTest.java`
- `src/test/java/com/kovixel/core/conversion/imageextract/ImageExtractionZipBuilderTest.java`
- `src/test/java/com/kovixel/core/conversion/imageextract/ImageExtractionServiceTest.java`

```
────────────────────────────────────────────────────────────────────
Utilitaires de test communs (classe TestPdfFactory) :
────────────────────────────────────────────────────────────────────

Méthodes statiques pour créer des PDFs de test :

  static byte[] pdfWithOneJpeg()
    → PDF 1 page avec 1 image JPEG 200×150 embarquée (PDFBox PDPageContentStream + PDImageXObject)

  static byte[] pdfWithMultipleImages()
    → PDF 2 pages : page 1 = 2 JPEG, page 2 = 1 PNG ; total 3 images

  static byte[] pdfWithDuplicateImage()
    → PDF 2 pages : même image JPEG sur les 2 pages (logo répété)

  static byte[] pdfWithSmallIcons()
    → PDF 1 page avec 5 images : 3 icônes 16×16, 2 photos 800×600

  static byte[] pdfWithNoImages()
    → PDF 1 page avec uniquement du texte

────────────────────────────────────────────────────────────────────
ImageExtractionEngineTest (JUnit 5)
────────────────────────────────────────────────────────────────────

@Test extractsJpegFromSimplePdf()
  - PDF 1 page + 1 JPEG → résultat contient 1 RawExtractedImage
  - nativeFormat = "JPEG", widthPx > 0, heightPx > 0, rawBytes non vide

@Test extractsMultipleImagesFromMultiPagePdf()
  - PDF 2 pages + 3 images → résultat.size() = 3
  - Les images de page 2 ont page = 2

@Test returnsEmptyListForPdfWithoutImages()
  - PDF sans image → résultat vide (pas d'exception)

@Test respectsPageSelection()
  - PDF 3 pages avec images sur toutes les pages
  - options.pages = SinglePage(2) → uniquement les images de la page 2

@Test respectsMaxImagesLimit()
  - props.imageExtract.maxImages = 2 ; PDF avec 5 images → KovixelException HTTP 400

@Test detectsNativeFormatCorrectly()
  - Vérifier que detectNativeFormat() retourne "JPEG" pour une image DCTDecode

────────────────────────────────────────────────────────────────────
ImageExtractionPostProcessorTest (JUnit 5)
────────────────────────────────────────────────────────────────────

@Test deduplicatesIdenticalImages()
  - 2 images avec rawBytes identiques → 1 seule image exportée
  - isDuplicate = false pour la première, true pour la deuxième

@Test noDeduplicationWhenDisabled()
  - options.deduplication = false → les 2 images identiques sont exportées

@Test filtersByMinDimensions()
  - Images : 800×600, 50×50, 16×16 ; minWidthPx=50, minHeightPx=50
  - Résultat : uniquement 800×600 et 50×50

@Test filtersByMinSize()
  - 3 images : 1 KB, 5 KB, 50 KB ; minSizeKb = 4
  - Résultat : 5 KB et 50 KB uniquement

@Test filtersBySoftMasks()
  - 1 image normale + 1 soft mask ; excludeSoftMasks = true
  - Résultat : uniquement l'image normale

@Test filtersBySelectedIndices()
  - 5 images ; imageIndices = [0, 2, 4]
  - Résultat : 3 images (indices 0, 2, 4)

@Test buildsStructuredFilename()
  - Image index 3, page 2, 800×600, format JPEG
  - exportFilename = "img_004_p02_800x600.jpg"

@Test convertsToJpeg()
  - Image PNG 100×100 ; options.format = JPEG
  - exportBytes ne sont pas les rawBytes originaux
  - ImageIO.read(exportBytes) retourne une image valide

@Test convertsToPng()
  - Image JPEG 200×150 ; options.format = PNG
  - exportBytes décodables comme PNG valide

@Test computesSha256()
  - Vérifier que sha256 = DigestUtils.sha256Hex(rawBytes) pour chaque image

────────────────────────────────────────────────────────────────────
ImageExtractionZipBuilderTest (JUnit 5)
────────────────────────────────────────────────────────────────────

@Test zipContainsImagesFolder()
  - 2 images → ZIP avec entrées "images/img_001_..." et "images/img_002_..."

@Test zipContainsManifestWhenMetadataEnabled()
  - includeMetadata = true → ZIP contient "manifest.json"
  - manifest.json valide (parsable par Jackson, champ "images" non null)

@Test zipHasNoManifestWhenMetadataDisabled()
  - includeMetadata = false → pas d'"manifest.json" dans le ZIP

@Test zipWithZeroImagesContainsManifestWithWarning()
  - Liste vide → ZIP contient manifest.json avec champ "warning" non null
  - "totalExported" = 0 dans le manifeste

@Test singleImageReturnedDirectlyWhenNoMetadata()
  - 1 image + includeMetadata = false → zipBytes = null, résultat direct

@Test jpegStoredUncompressed()
  - Images JPEG → entrées ZIP avec méthode STORED (pas DEFLATED)

────────────────────────────────────────────────────────────────────
ImageExtractionServiceTest (Mockito)
────────────────────────────────────────────────────────────────────

@Test serviceCallsEnginePostProcessorAndZipBuilder()
  - Vérifier que les 3 composants sont appelés dans l'ordre

@Test serviceReturnsDurationMs()
  - durationMs > 0 dans le résultat

@Test previewDoesNotCallZipBuilder()
  - previewExtract() → ZipBuilder jamais appelé

@Test serviceIncrementsMetrics()
  - Après extract(), les compteurs Micrometer sont incrémentés
```

---

## PROMPT 10 — Documentation & Variables d'environnement

**Fichiers à modifier :**
- `README.md`
- `.env.example`

```
Dans README.md, ajoute une section "## Extraire Images" :

### Fonctionnement

L'outil extrait les images **intégrées comme ressources** dans le document PDF
(images `PDImageXObject`) dans leur résolution native, sans perte de qualité.
À ne pas confondre avec PDF→Images qui convertit les *pages* en images.

### Moteur

Exclusivement **Apache PDFBox** — extraction native sans dépendance externe.
Les formats JBIG2 et CCITTFax sont convertis en PNG car ces formats ne sont
pas directement lisibles par la plupart des applications.

### Formats supportés

| Format natif  | Exporté comme  | Qualité  | Note                                    |
|---------------|---------------|----------|-----------------------------------------|
| JPEG (DCT)    | JPEG           | ★★★★★  | Extraction directe des bytes natifs     |
| PNG (Flate)   | PNG            | ★★★★★  | Extraction directe des bytes natifs     |
| TIFF          | TIFF           | ★★★★★  | Extraction directe                      |
| JBIG2         | PNG            | ★★★★☆  | Converti (perte du format propriétaire) |
| CCITTFax      | TIFF           | ★★★★☆  | Converti                                |
| JPX (JPEG2000)| JPEG           | ★★★★☆  | Converti                                |

### Paramètres API

| Paramètre          | Type     | Défaut   | Description                                |
|--------------------|----------|----------|--------------------------------------------|
| file               | File     | —        | PDF source (multipart)                     |
| format             | String   | original | original \| jpeg \| png                    |
| pages              | String   | all      | all, 3, 2-7                               |
| minWidthPx         | int      | 10       | Largeur minimale en pixels                 |
| minHeightPx        | int      | 10       | Hauteur minimale en pixels                 |
| minSizeKb          | int      | 0        | Taille minimale en KB (0=désactivé)        |
| deduplication      | boolean  | true     | Dédupliquer par SHA-256                   |
| excludeSoftMasks   | boolean  | true     | Exclure les masques de transparence        |
| imageIndices       | int[]    | null     | Indices à exporter (null=tous)             |
| includeMetadata    | boolean  | true     | Inclure manifest.json dans le ZIP          |
| jpegQuality        | int      | 90       | Qualité JPEG 1-100 (si format=jpeg)       |

### Headers de réponse

| Header                | Description                                          |
|-----------------------|------------------------------------------------------|
| X-Images-Found        | Nombre d'images brutes trouvées                      |
| X-Images-After-Dedup  | Nombre après déduplication                          |
| X-Images-Exported     | Nombre d'images dans le ZIP                         |
| X-Pages-Analyzed      | Nombre de pages analysées                            |
| X-Total-Output-Size   | Taille totale des images exportées (bytes)           |
| X-Processing-Time-Ms  | Durée de traitement                                  |
| X-Direct-Image        | "true" si une seule image renvoyée sans ZIP          |
| X-Warning             | "NO_IMAGES_EXPORTED" si aucune image exportée        |

### Déduplication

Le mécanisme de déduplication SHA-256 identifie les images identiques
(logos répétés sur chaque page, en-têtes d'entreprise, etc.) et n'exporte
chaque image unique qu'une seule fois. Le manifeste JSON liste toutes les
occurrences avec le champ `isDuplicate` et le `duplicateOf` correspondant.

### Manifest JSON

Inclus par défaut dans le ZIP sous le nom `manifest.json`, il contient :
- Statistiques globales (trouvées, déduplication, exportées)
- Pour chaque image : page, dimensions, format, taille, SHA-256, position bounding-box
- Coordonnées relatives en % de la page (leftPct, topPct, widthPct, heightPct)
- Pour les doublons : référence à l'image d'origine

### Variables d'environnement

Aucune variable d'environnement supplémentaire n'est requise.
L'outil fonctionne uniquement avec PDFBox (déjà dans le classpath).

### Comportement si aucune image n'est trouvée

- HTTP 200 avec un ZIP contenant uniquement manifest.json
- Header X-Warning: "NO_IMAGES_EXPORTED"
- Le manifeste contient le champ "warning" avec une explication
- Jamais HTTP 500 ou ZIP vide
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10
  Config    Engine   PostProc   ZipBuilder  Service   Endpoint  Métriques  Frontend   Tests       Docs
```

> **Parallélisables :**
> - PROMPT 3 (PostProcessor) peut être développé en parallèle de PROMPT 2 (Engine)
>   car il opère sur des `RawExtractedImage` déjà définis au PROMPT 1.
> - PROMPT 4 (ZipBuilder) est indépendant de PROMPT 2 et 3, démarre dès PROMPT 1 validé.
> - PROMPT 8 (Frontend) peut démarrer dès PROMPT 6 (Endpoint) validé.
> - PROMPT 9 (Tests) idéalement en TDD : écrire les tests en parallèle de chaque PROMPT.

---

## Critères de validation finale

### Backend

- [ ] `mvn test` passe sans erreur (Engine, PostProcessor, ZipBuilder, Service)
- [ ] PDF avec 3 images JPEG → ZIP contenant 3 fichiers `images/img_*.jpg` + `manifest.json`
- [ ] PDF avec logo répété sur 5 pages + `deduplication=true` → ZIP avec 1 seule image
- [ ] `minWidthPx=100` → images de moins de 100 px de large exclues du ZIP
- [ ] `format=jpeg` → toutes les images converties en JPEG même si nativement PNG
- [ ] `format=png` → toutes les images converties en PNG, JPEG inclus
- [ ] PDF sans image → ZIP avec `manifest.json` contenant `"warning"`, jamais HTTP 500
- [ ] PDF > 20 MB → HTTP 202 + `{ jobId, pollUrl }`
- [ ] `POST /preview` → JSON avec liste d'images + métadonnées en < 1 s (sans ZIP)
- [ ] `imageIndices=[0,2]` → seules les images 0 et 2 dans le ZIP
- [ ] 1 image + `includeMetadata=false` → image directe (pas de ZIP), `X-Direct-Image: true`
- [ ] `X-Images-Found`, `X-Images-Exported` présents dans tous les cas
- [ ] `curl /actuator/health` expose `extract.images: "UP"`
- [ ] `curl /actuator/metrics/kovixel.extract.images.total` retourne des valeurs

### Frontend

- [ ] Route `/tools/extract/images` charge le composant sans erreur
- [ ] Upload → appel automatique à `POST /preview` → liste des images affichée
- [ ] Chaque image dans la liste affiche : page, dimensions, format, taille
- [ ] Badge "Doublon" (orange) visible sur les images dupliquées
- [ ] Checkbox "Tout sélectionner" / "Désélectionner tout" fonctionnelles
- [ ] 3 chips de format (Original / JPEG / PNG) avec descriptions claires
- [ ] Filtre dimensions (minWidth × minHeight) mis à jour en temps réel dans la liste
- [ ] Options avancées (déduplication, manifeste, qualité JPEG) dans section repliable
- [ ] Bouton "Extraire" avec indication du nombre sélectionné et du format choisi
- [ ] State processing : spinner pendant l'upload + extraction
- [ ] State success : stats (exportées, taille, doublons supprimés, durée)
- [ ] État 0 images : message avec suggestions + bouton "Tout exporter sans filtre"
- [ ] Nom de fichier du ZIP inclus le nom du PDF source

### UX

- [ ] L'outil charge en < 200 ms (lazy loading)
- [ ] Extraction de 10 images JPEG < 1 s (PDFBox extraction directe)
- [ ] Extraction de 50 images JPEG < 3 s
- [ ] Manifeste JSON lisible et auto-descriptif (sans documentation externe)
- [ ] Les noms de fichiers sont informatifs : `img_001_p01_800x600.jpg`
