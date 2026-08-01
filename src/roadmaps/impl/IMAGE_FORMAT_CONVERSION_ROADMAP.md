# IMAGE FORMAT CONVERSION — ROADMAP D'IMPLÉMENTATION

> **Objectif :** Outil de conversion image→image de niveau enterprise, concurrent direct de
> Squoosh, CloudConvert et iLovePDF, intégré nativement dans l'architecture Kovixel existante.

---

## 1. Positionnement Concurrentiel

### 1.1 Analyse des leaders du marché (2025)

| Fonctionnalité        | iLovePDF | Smallpdf | CloudConvert  | Adobe Express | **Kovixel (cible)** |
|-----------------------|----------|----------|---------------|---------------|----------------------|
| JPEG/PNG/WebP I/O     | ⚠️ Limité | ✅ Oui   | ✅ Oui        | ✅ Oui        | ✅ **Oui**           |
| AVIF output           | ❌ Non   | ❌ Non   | ✅ Premium    | ❌ Non        | ✅ **PRO/ENTERPRISE**|
| HEIC input            | ❌ Non   | ❌ Non   | ✅ Premium    | ❌ Non        | ✅ **Tous plans**    |
| SVG rasterisation     | ❌ Non   | ❌ Non   | ✅ Oui        | ❌ Non        | ✅ **Oui**           |
| Qualité granulaire    | ❌ 3 niveaux | ❌ 3 niveaux | ✅ 1-100 | ❌ 3 niveaux | ✅ **1-100**         |
| Resize intégré        | ✅ Oui   | ✅ Oui   | ✅ Oui        | ✅ Oui        | ✅ **Oui**           |
| Batch (≥10 fichiers)  | ❌ Non   | ❌ Non   | ✅ API only   | ❌ Non        | ✅ **Phase 3**       |
| EXIF preservation     | ❌ Non   | ❌ Non   | ⚠️ Partiel   | ❌ Non        | ✅ **Option**        |
| JPEG progressif       | ❌ Non   | ❌ Non   | ✅ Oui        | ❌ Non        | ✅ **Oui**           |
| WebP lossless         | ❌ Non   | ❌ Non   | ✅ Oui        | ❌ Non        | ✅ **Oui**           |
| Async queue           | ❌ Non   | ❌ Non   | ✅ Oui        | ⚠️ >500 MB  | ✅ **>10 MB**        |
| Before/after preview  | ❌ Non   | ❌ Non   | ❌ Non        | ❌ Non        | ✅ **Phase 3**       |

### 1.2 Différenciateurs Kovixel
1. **Qualité slider 1–100** par format — pas juste Low/Medium/High
2. **AVIF output** (seul concurrent grand public = CloudConvert, plan premium)
3. **EXIF stripping par défaut** + option preservation (conformité RGPD explicite)
4. **JPEG progressif** et **WebP/AVIF lossless** accessibles dans l'UI
5. **Resize simultané** sans outil supplémentaire (width + height + fit mode)
6. **Before/after slider** inline (Phase 3) — identique à Squoosh, unique parmi les SaaS

---

## 2. Matrice de Formats

### 2.1 Phase 1 — Core (Semaines 1–2)

Moteur : **Java ImageIO natif + TwelveMonkeys 3.11.0** (déjà en `pom.xml`)

| Input ↓ / Output → | JPEG            | PNG             | WebP            | TIFF            | BMP             | GIF             |
|---------------------|-----------------|-----------------|-----------------|-----------------|-----------------|-----------------|
| **JPEG**            | —               | ✅              | ✅              | ✅              | ✅              | ✅              |
| **PNG**             | ✅              | —               | ✅              | ✅              | ✅              | ✅              |
| **WebP**            | ✅              | ✅              | —               | ✅              | ✅              | ✅              |
| **TIFF**            | ✅              | ✅              | ✅              | —               | ✅              | ✅              |
| **BMP**             | ✅              | ✅              | ✅              | ✅              | —               | ✅              |
| **GIF**             | ✅ (frame 0)    | ✅ (frame 0)    | ✅ (frame 0)    | ✅              | ✅              | —               |

> **GIF animé :** Java ImageIO ne décode que le frame 0. Le mode batch GIF→WebP animé est traité en Phase 3 via ffmpeg.

### 2.2 Phase 2 — Formats Premium (Semaines 3–4)

Moteurs : **ffmpeg** (ProcessBuilder), **ImageMagick** (system call), **Apache Batik 1.17**

| Input ↓ / Output →  | JPEG | PNG  | WebP | AVIF              | Toute autre       |
|----------------------|------|------|------|-------------------|-------------------|
| **HEIC/HEIF**        | ✅   | ✅   | ✅   | ❌                | ❌                |
| **SVG**              | ✅   | ✅   | ❌   | ❌                | ❌                |
| **AVIF** (input)     | ✅   | ✅   | ✅   | —                 | ✅ (via ImageIO)  |
| **→ AVIF** (output)  | ✅   | ✅   | ✅   | —                 | ❌                |

> **Note HEIC :** Format accepté uniquement en **input**. Kovixel convertit et ne stocke jamais le
> HEIC original (voir §14 Sécurité). Mention légale obligatoire dans les CGU (brevet HEVC/Apple).

### 2.3 Phase 3 — Advanced (Semaines 5–6)

| Fonctionnalité                | Moteur                         |
|-------------------------------|--------------------------------|
| ICO output (16/32/48/64 px)   | ffmpeg multi-résolution        |
| GIF animé → WebP animé        | ffmpeg `-vf format=rgba`       |
| Batch (jusqu'à 20 fichiers)   | ZIP résultat, toujours async   |
| PDF single-page → image       | PDFBox existant (`ImageConversionRouter`) |
| Before/after slider UI        | Canvas ou CSS clip-path Angular |

---

## 3. Dépendances Maven

### 3.1 Déjà présentes — aucun ajout pour Phase 1

```xml
<!-- TwelveMonkeys : WebP (read+write via JNI libwebp), TIFF, BMP -->
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
<!-- Resize / crop -->
<dependency>
    <groupId>net.coobird</groupId>
    <artifactId>thumbnailator</artifactId>
    <version>0.4.20</version>
</dependency>
```

> **Contrainte WebP :** TwelveMonkeys 3.11.0 appelle `libwebp` via JNI. Le `.so`/`.dll`/`.dylib`
> doit être disponible sur l'hôte. Dockerfile Phase 1 : `apt-get install -y libwebp7`.
> Si absent au démarrage, le `ImageWriter` WebP ne sera pas enregistré → fallback PNG loggué.

### 3.2 À ajouter — Phase 2 (SVG via Apache Batik)

```xml
<dependency>
    <groupId>org.apache.xmlgraphics</groupId>
    <artifactId>batik-transcoder</artifactId>
    <version>1.17</version>
</dependency>
<dependency>
    <groupId>org.apache.xmlgraphics</groupId>
    <artifactId>batik-codec</artifactId>
    <version>1.17</version>
</dependency>
```

> **Conflit xalan :** Batik 1.17 tire `xalan:xalan` en transitive. Si conflit avec Spring Boot 3 :
> ```xml
> <dependency>
>     <groupId>org.apache.xmlgraphics</groupId>
>     <artifactId>batik-transcoder</artifactId>
>     <version>1.17</version>
>     <exclusions>
>         <exclusion><groupId>xalan</groupId><artifactId>xalan</artifactId></exclusion>
>         <exclusion><groupId>xalan</groupId><artifactId>serializer</artifactId></exclusion>
>     </exclusions>
> </dependency>
> ```

### 3.3 HEIC — Via ImageMagick système (pas de dépendance Maven)

```dockerfile
# Dockerfile — Phase 2
RUN apt-get update && apt-get install -y \
    libwebp7 \
    ffmpeg \
    imagemagick \
    libheif-dev \
    && rm -rf /var/lib/apt/lists/*
```

> **ImageMagick 6 vs 7 :** La commande est `convert` (IM6) ou `magick` (IM7). Détecter
> à l'initialisation avec `which magick` → IM7, sinon `which convert` → IM6.
> Utiliser un `ImageMagickCommandResolver` au démarrage (voir §4.8).

### 3.4 AVIF — Via ffmpeg (pas de dépendance Maven)

```
Encodeur recommandé : libsvtav1 (SVT-AV1) — rapide, bonne qualité
Fallback           : libaom-av1 — meilleure qualité, 5–10× plus lent

Vérifier que ffmpeg est compilé avec libsvtav1 :
  ffmpeg -encoders 2>/dev/null | grep svtav1
  Si absent → fallback libaom avec preset 8
```

---

## 4. Architecture Backend

### 4.1 Structure de package

```
com.kovixel.core.conversion.imageformat
├── config/
│   └── ImageConvertProperties.java        ← @ConfigurationProperties
├── controller/
│   └── ImageConvertController.java        ← POST /api/v1/convert/image
├── dto/
│   ├── ImageConvertOptions.java           ← record (params utilisateur)
│   └── ImageConvertResult.java            ← record (résultat + métriques)
├── engine/
│   ├── ImageConvertEngine.java            ← interface Strategy
│   ├── ImageConvertException.java         ← RuntimeException interne moteur
│   ├── ImageIoConvertEngine.java          ← Phase 1 (ImageIO + TwelveMonkeys)
│   ├── FfmpegConvertEngine.java           ← Phase 2 (AVIF, ICO Phase 3)
│   ├── ImageMagickConvertEngine.java      ← Phase 2 (HEIC)
│   └── BatikConvertEngine.java            ← Phase 2 (SVG → JPEG/PNG)
├── format/
│   ├── ImageConvertFormat.java            ← enum des formats
│   └── ResizeFitMode.java                 ← enum FIT/FILL/STRETCH/CROP
├── router/
│   └── ImageFormatRouter.java             ← sélection moteur + contrôle plan
├── service/
│   ├── ImageConvertService.java           ← façade sync/async
│   ├── ExifTransferService.java           ← Phase 2 (EXIF preservation)
│   └── ImageMagickCommandResolver.java    ← détecte IM6 vs IM7 au démarrage
└── strategy/
    └── ImageConvertStrategy.java          ← ProcessingStrategy (async jobs)
```

> **Attention au nommage :** `ImageConversionRouter.java` **existe déjà** dans
> `core.conversion.pdftoimages` (routage Adobe/PDFBox/Ghostscript pour PDF→images).
> Le nouveau routeur s'appelle **`ImageFormatRouter`** pour éviter toute confusion.

---

### 4.2 Enum `ImageConvertFormat`

```java
// com.kovixel.core.conversion.imageformat.format.ImageConvertFormat

public enum ImageConvertFormat {

    //         formatId  mimeType              ext     needsNative  phase2+
    JPEG ("jpeg", "image/jpeg",    "jpg",  false, false),
    PNG  ("png",  "image/png",     "png",  false, false),
    WEBP ("webp", "image/webp",    "webp", true,  false),  // TwelveMonkeys JNI
    GIF  ("gif",  "image/gif",     "gif",  false, false),
    TIFF ("tiff", "image/tiff",    "tiff", true,  false),  // TwelveMonkeys
    BMP  ("bmp",  "image/bmp",     "bmp",  true,  false),  // TwelveMonkeys

    // Phase 2
    AVIF ("avif", "image/avif",    "avif", true,  true),   // output only, ffmpeg
    HEIC ("heic", "image/heic",    "heic", true,  true),   // input only, ImageMagick
    SVG  ("svg",  "image/svg+xml", "svg",  false, true),   // input only, Batik

    // Phase 3
    ICO  ("ico",  "image/x-icon",  "ico",  true,  true);   // output only, ffmpeg

    private final String  formatId;
    private final String  mimeType;
    private final String  defaultExtension;
    private final boolean requiresNativeLib;
    private final boolean phase2OrLater;

    // Constructeur + getters omis pour brièveté

    public static ImageConvertFormat fromString(String value) {
        return Arrays.stream(values())
                .filter(f -> f.formatId.equalsIgnoreCase(value))
                .findFirst()
                .orElseThrow(() -> new KovixelException(ErrorCode.VALIDATION_ERROR,
                        HttpStatus.BAD_REQUEST, "Format non supporté : " + value));
    }

    /** HEIC et SVG ne peuvent pas être produits en output. */
    public boolean isOutputSupported() {
        return this != HEIC && this != SVG;
    }

    /** ICO ne peut pas être accepté en input. */
    public boolean isInputSupported() {
        return this != ICO;
    }
}
```

---

### 4.3 Record `ImageConvertOptions`

```java
// com.kovixel.core.conversion.imageformat.dto.ImageConvertOptions

public record ImageConvertOptions(

    ImageConvertFormat targetFormat,

    int quality,
    // JPEG  : 1–100 qualité LOSSY (ou progressive si progressive=true)
    // WebP  : 1–100 qualité LOSSY (ou lossless si lossless=true)
    // AVIF  : 1–100 → mappé en CRF 0–63 inversé (100=CRF 0=meilleure qualité)
    // TIFF  : ignoré (compression LZW sans perte)
    // PNG   : ignoré (PNG est toujours sans perte)
    // BMP   : ignoré (pas de compression)

    Integer targetWidth,     // null = pas de redimensionnement
    Integer targetHeight,    // null = pas de redimensionnement
                             // Si un seul fourni → ratio conservé automatiquement

    ResizeFitMode fitMode,   // FIT (défaut), FILL, STRETCH, CROP

    boolean preserveExif,    // false (défaut) = strip EXIF (RGPD)
    boolean progressive,     // JPEG seulement : encodage progressif
    boolean lossless,        // WebP/AVIF seulement : mode sans perte
    String  backgroundColor  // "#FFFFFF" — remplace transparence (PNG→JPEG)

) {
    public static ImageConvertOptions defaults(ImageConvertFormat targetFormat) {
        return new ImageConvertOptions(
            targetFormat, 85, null, null, ResizeFitMode.FIT,
            false, false, false, "#FFFFFF"
        );
    }

    public static ImageConvertOptions fromRequest(
            String targetFormatStr, int quality,
            Integer width, Integer height, String fitMode,
            boolean preserveExif, boolean progressive,
            boolean lossless, String backgroundColor) {
        return new ImageConvertOptions(
            ImageConvertFormat.fromString(targetFormatStr),
            quality, width, height,
            ResizeFitMode.fromString(fitMode),
            preserveExif, progressive, lossless, backgroundColor
        );
    }
}
```

---

### 4.4 Record `ImageConvertResult`

```java
// com.kovixel.core.conversion.imageformat.dto.ImageConvertResult

public record ImageConvertResult(
    byte[] outputBytes,
    ImageConvertFormat outputFormat,
    String outputFilename,
    long inputSizeBytes,
    long outputSizeBytes,
    int outputWidth,
    int outputHeight,
    String engineUsed,
    long processingTimeMs
) {}
```

---

### 4.5 Interface `ImageConvertEngine`

```java
// com.kovixel.core.conversion.imageformat.engine.ImageConvertEngine

public interface ImageConvertEngine {

    Set<ImageConvertFormat> supportedInputFormats();
    Set<ImageConvertFormat> supportedOutputFormats();

    ImageConvertResult convert(byte[] inputBytes, ImageConvertFormat sourceFormat,
                               ImageConvertOptions options) throws ImageConvertException;

    default String engineName() {
        return this.getClass().getSimpleName();
    }
}
```

---

### 4.6 `ImageIoConvertEngine` — Phase 1

Gère toutes les paires des 6 formats core : JPEG, PNG, WebP, TIFF, BMP, GIF.

```java
// com.kovixel.core.conversion.imageformat.engine.ImageIoConvertEngine

@Component
public class ImageIoConvertEngine implements ImageConvertEngine {

    private static final Set<ImageConvertFormat> SUPPORTED_IO =
        Set.of(JPEG, PNG, WEBP, TIFF, BMP, GIF);

    @Override public Set<ImageConvertFormat> supportedInputFormats()  { return SUPPORTED_IO; }
    @Override public Set<ImageConvertFormat> supportedOutputFormats() { return SUPPORTED_IO; }

    @Override
    public ImageConvertResult convert(byte[] inputBytes, ImageConvertFormat sourceFormat,
                                      ImageConvertOptions options) throws ImageConvertException {
        long start = System.currentTimeMillis();
        try {
            // 1. Décoder via ImageIO (SPI : Java natif + TwelveMonkeys auto-enregistrés)
            BufferedImage src = ImageIO.read(new ByteArrayInputStream(inputBytes));
            if (src == null) {
                throw new ImageConvertException("Format non décodable : " + sourceFormat);
            }

            // 2. Redimensionnement via Thumbnailator (si demandé)
            BufferedImage resized = applyResize(src, options);

            // 3. Gestion transparence → fond opaque si target ne supporte pas l'alpha
            BufferedImage prepared = prepareColorModel(resized, options);

            // 4. Encoder vers le format cible
            byte[] outputBytes = encode(prepared, options);

            return new ImageConvertResult(
                outputBytes, options.targetFormat(),
                "converted." + options.targetFormat().getDefaultExtension(),
                inputBytes.length, outputBytes.length,
                prepared.getWidth(), prepared.getHeight(),
                engineName(), System.currentTimeMillis() - start
            );

        } catch (IOException e) {
            throw new ImageConvertException("Erreur de conversion ImageIO : " + e.getMessage(), e);
        }
    }

    private BufferedImage applyResize(BufferedImage src,
                                      ImageConvertOptions opts) throws IOException {
        if (opts.targetWidth() == null && opts.targetHeight() == null) return src;

        Thumbnails.Builder<BufferedImage> builder = Thumbnails.of(src);

        if (opts.targetWidth() != null && opts.targetHeight() != null) {
            builder.size(opts.targetWidth(), opts.targetHeight());
            switch (opts.fitMode()) {
                case FILL    -> builder.crop(Positions.CENTER);
                case STRETCH -> builder.keepAspectRatio(false);
                default      -> builder.keepAspectRatio(true);  // FIT (défaut)
            }
        } else if (opts.targetWidth() != null) {
            builder.width(opts.targetWidth()).keepAspectRatio(true);
        } else {
            builder.height(opts.targetHeight()).keepAspectRatio(true);
        }

        return builder.asBufferedImage();
    }

    private BufferedImage prepareColorModel(BufferedImage src, ImageConvertOptions opts) {
        // Formats sans canal alpha : JPEG, BMP, GIF
        // TIFF supporte l'alpha (RGBA TIFF valide via TwelveMonkeys) — ne pas aplatir
        boolean targetSupportsAlpha = switch (opts.targetFormat()) {
            case PNG, WEBP, TIFF -> true;
            default              -> false;
        };

        if (!targetSupportsAlpha && src.getColorModel().hasAlpha()) {
            Color bg = parseHexColor(opts.backgroundColor());
            BufferedImage flat = new BufferedImage(
                src.getWidth(), src.getHeight(), BufferedImage.TYPE_INT_RGB);
            Graphics2D g = flat.createGraphics();
            g.setColor(bg);
            g.fillRect(0, 0, src.getWidth(), src.getHeight());
            g.drawImage(src, 0, 0, null);
            g.dispose();
            return flat;
        }
        return src;
    }

    private byte[] encode(BufferedImage img, ImageConvertOptions opts) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        switch (opts.targetFormat()) {
            case JPEG -> encodeJpeg(img, opts, baos);
            case PNG  -> {
                if (!ImageIO.write(img, "png", baos))
                    throw new ImageConvertException("Aucun ImageWriter PNG disponible");
            }
            case WEBP -> encodeWebp(img, opts, baos);
            case TIFF -> encodeTiff(img, baos);
            case BMP  -> {
                if (!ImageIO.write(img, "bmp", baos))
                    throw new ImageConvertException("Aucun ImageWriter BMP disponible");
            }
            case GIF  -> encodeGif(img, baos);
            default   -> throw new ImageConvertException(
                "ImageIoConvertEngine ne gère pas " + opts.targetFormat());
        }
        return baos.toByteArray();
    }

    private void encodeGif(BufferedImage img, ByteArrayOutputStream baos) throws IOException {
        // Java ImageIO GIF writer exige IndexColorModel (256 couleurs max).
        // Thumbnailator gère la quantification des couleurs RGB → indexed.
        Thumbnails.of(img)
                  .size(img.getWidth(), img.getHeight())
                  .keepAspectRatio(false)
                  .outputFormat("gif")
                  .toOutputStream(baos);
    }

    private void encodeJpeg(BufferedImage img, ImageConvertOptions opts,
                            ByteArrayOutputStream baos) throws IOException {
        ImageWriter writer = ImageIO.getImageWritersByFormatName("jpeg").next();
        ImageWriteParam params = writer.getDefaultWriteParam();
        params.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
        params.setCompressionQuality(opts.quality() / 100f);
        if (opts.progressive()) {
            params.setProgressiveMode(ImageWriteParam.MODE_DEFAULT);
        }
        try (ImageOutputStream ios = ImageIO.createImageOutputStream(baos)) {
            writer.setOutput(ios);
            writer.write(null, new IIOImage(img, null, null), params);
        } finally {
            writer.dispose();
        }
    }

    private void encodeWebp(BufferedImage img, ImageConvertOptions opts,
                            ByteArrayOutputStream baos) throws IOException {
        // TwelveMonkeys WebPImageWriter (SPI auto-enregistré)
        Iterator<ImageWriter> writers = ImageIO.getImageWritersByMIMEType("image/webp");
        if (!writers.hasNext()) {
            throw new ImageConvertException("libwebp non disponible — fallback PNG recommandé");
        }
        ImageWriter writer = writers.next();
        ImageWriteParam params = writer.getDefaultWriteParam();
        if (params.canWriteCompressed()) {
            params.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
            params.setCompressionType(opts.lossless() ? "Lossless" : "Lossy");
            if (!opts.lossless()) {
                params.setCompressionQuality(opts.quality() / 100f);
            }
        }
        try (ImageOutputStream ios = ImageIO.createImageOutputStream(baos)) {
            writer.setOutput(ios);
            writer.write(null, new IIOImage(img, null, null), params);
        } finally {
            writer.dispose();
        }
    }

    private void encodeTiff(BufferedImage img, ByteArrayOutputStream baos) throws IOException {
        // TwelveMonkeys TIFFImageWriter (SPI auto-enregistré) — compression LZW sans perte
        ImageWriter writer = ImageIO.getImageWritersByFormatName("tiff").next();
        try (ImageOutputStream ios = ImageIO.createImageOutputStream(baos)) {
            writer.setOutput(ios);
            writer.write(img);
        } finally {
            writer.dispose();
        }
    }

    private Color parseHexColor(String hex) {
        try { return Color.decode(hex); }
        catch (NumberFormatException e) { return Color.WHITE; }
    }
}
```

---

### 4.7 `FfmpegConvertEngine` — Phase 2 (AVIF) + Phase 3 (ICO)

```java
// com.kovixel.core.conversion.imageformat.engine.FfmpegConvertEngine

@Component
@RequiredArgsConstructor   // ← Lombok génère le constructeur pour `props`
public class FfmpegConvertEngine implements ImageConvertEngine {

    private final ImageConvertProperties props;

    // Phase 1 : JPEG/PNG/WebP en input suffisent pour → AVIF
    // Phase 3 : ajouter TIFF, BMP, GIF dans supportedInput
    @Override
    public Set<ImageConvertFormat> supportedInputFormats() {
        return Set.of(JPEG, PNG, WEBP, TIFF, BMP, GIF);
    }

    @Override
    public Set<ImageConvertFormat> supportedOutputFormats() {
        return Set.of(AVIF); // Phase 3 : + ICO
    }

    @Override
    public ImageConvertResult convert(byte[] inputBytes, ImageConvertFormat sourceFormat,
                                      ImageConvertOptions options) throws ImageConvertException {
        long start = System.currentTimeMillis();
        Path tempDir = null;
        try {
            tempDir = Files.createTempDirectory("kovixel-fc-");
            Path inputFile  = tempDir.resolve("input." + sourceFormat.getDefaultExtension());
            Path outputFile = tempDir.resolve("output." + options.targetFormat().getDefaultExtension());
            Files.write(inputFile, inputBytes);

            List<String> cmd = buildCommand(inputFile, outputFile, options);
            Process process = new ProcessBuilder(cmd)
                    .redirectErrorStream(true)
                    .start();

            boolean finished = process.waitFor(
                props.getFfmpegTimeoutSeconds(), TimeUnit.SECONDS);
            if (!finished) {
                process.destroyForcibly();
                throw new ImageConvertException(
                    "ffmpeg timeout après " + props.getFfmpegTimeoutSeconds() + "s");
            }
            if (process.exitValue() != 0) {
                String err = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
                throw new ImageConvertException("ffmpeg exit " + process.exitValue() + " : " + err);
            }

            byte[] outputBytes = Files.readAllBytes(outputFile);

            // Dimensions depuis le fichier produit
            int w = 0, h = 0;
            try {
                BufferedImage check = ImageIO.read(outputFile.toFile());
                if (check != null) { w = check.getWidth(); h = check.getHeight(); }
            } catch (Exception ignored) {}

            return new ImageConvertResult(outputBytes, options.targetFormat(),
                "converted." + options.targetFormat().getDefaultExtension(),
                inputBytes.length, outputBytes.length, w, h,
                engineName(), System.currentTimeMillis() - start);

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ImageConvertException("ffmpeg execution error", e);
        } finally {
            cleanupTempDir(tempDir);
        }
    }

    private List<String> buildCommand(Path input, Path output,
                                       ImageConvertOptions opts) {
        List<String> cmd = new ArrayList<>(List.of("ffmpeg", "-y", "-i", input.toString()));

        // Resize si demandé (scale filter : -1 = ratio conservé)
        if (opts.targetWidth() != null || opts.targetHeight() != null) {
            int w = opts.targetWidth()  != null ? opts.targetWidth()  : -1;
            int h = opts.targetHeight() != null ? opts.targetHeight() : -1;
            cmd.addAll(List.of("-vf", "scale=" + w + ":" + h));
        }

        if (opts.targetFormat() == AVIF) {
            int crf = mapQualityToCrf(opts.quality()); // 85 → CRF 9
            // Préférer libsvtav1 (SVT-AV1, rapide) ; fallback libaom-av1 si absent.
            // Détecter à l'initialisation via FfmpegEncoderDetector (voir §4.14 config).
            String encoder = props.isAvifEncoderSvt() ? "libsvtav1" : "libaom-av1";
            List<String> encArgs = props.isAvifEncoderSvt()
                ? List.of("-c:v", encoder, "-crf", String.valueOf(crf), "-preset", "6", "-pix_fmt", "yuv420p")
                : List.of("-c:v", encoder, "-crf", String.valueOf(crf), "-cpu-used", "8", "-pix_fmt", "yuv420p");
            cmd.addAll(encArgs);
        }

        cmd.add(output.toString());
        return cmd;
    }

    // quality 1–100 → CRF 63–0 (inversé : 100 = meilleure qualité = CRF 0)
    private int mapQualityToCrf(int quality) {
        return Math.round((100f - quality) * 63f / 100f);
    }

    private void cleanupTempDir(Path dir) {
        if (dir == null) return;
        try {
            Files.walk(dir)
                .sorted(Comparator.reverseOrder())
                .forEach(p -> { try { Files.deleteIfExists(p); } catch (IOException ignored) {} });
        } catch (IOException ignored) {}
    }
}
```

---

### 4.8 `ImageMagickConvertEngine` — Phase 2 (HEIC → *)

```java
// com.kovixel.core.conversion.imageformat.engine.ImageMagickConvertEngine

@Component
public class ImageMagickConvertEngine implements ImageConvertEngine {

    private final ImageConvertProperties props;
    private final ImageMagickCommandResolver cmdResolver;

    @Override
    public Set<ImageConvertFormat> supportedInputFormats() { return Set.of(HEIC); }

    @Override
    public Set<ImageConvertFormat> supportedOutputFormats() {
        return Set.of(JPEG, PNG, WEBP);
    }

    @Override
    public ImageConvertResult convert(byte[] inputBytes, ImageConvertFormat sourceFormat,
                                      ImageConvertOptions options) throws ImageConvertException {
        long start = System.currentTimeMillis();
        Path tempDir = null;
        try {
            tempDir = Files.createTempDirectory("kovixel-heic-");
            Path inputFile  = tempDir.resolve("input.heic");
            Path outputFile = tempDir.resolve(
                "output." + options.targetFormat().getDefaultExtension());
            Files.write(inputFile, inputBytes);

            // cmdResolver retourne "magick" (IM7) ou "convert" (IM6)
            List<String> cmd = new ArrayList<>(List.of(
                cmdResolver.getConvertCommand(),
                inputFile.toString()
            ));
            if (options.targetFormat() == JPEG) {
                cmd.addAll(List.of("-quality", String.valueOf(options.quality())));
            }
            if (options.targetWidth() != null && options.targetHeight() != null) {
                String resize = options.targetWidth() + "x" + options.targetHeight();
                String flag   = options.fitMode() == ResizeFitMode.FILL ? resize + "^" : resize;
                cmd.addAll(List.of("-resize", flag));
            }
            cmd.add(outputFile.toString());

            Process process = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            boolean done = process.waitFor(props.getImagemagickTimeoutSeconds(), TimeUnit.SECONDS);
            if (!done) {
                process.destroyForcibly();
                throw new ImageConvertException("ImageMagick HEIC timeout");
            }
            if (process.exitValue() != 0) {
                String err = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
                throw new ImageConvertException("ImageMagick exit " + process.exitValue() + " : " + err);
            }

            byte[] outputBytes = Files.readAllBytes(outputFile);
            return new ImageConvertResult(outputBytes, options.targetFormat(),
                "converted." + options.targetFormat().getDefaultExtension(),
                inputBytes.length, outputBytes.length, 0, 0,
                engineName(), System.currentTimeMillis() - start);

        } catch (IOException | InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ImageConvertException("ImageMagick execution error", e);
        } finally {
            cleanupTempDir(tempDir);
        }
    }

    // Identique à FfmpegConvertEngine — extraire dans TempFileUtils (voir §15)
    private void cleanupTempDir(Path dir) {
        if (dir == null) return;
        try {
            Files.walk(dir)
                .sorted(Comparator.reverseOrder())
                .forEach(p -> { try { Files.deleteIfExists(p); } catch (IOException ignored) {} });
        } catch (IOException ignored) {}
    }
}
```

> **Refactoring recommandé :** Extraire `cleanupTempDir()` dans
> `com.kovixel.core.conversion.imageformat.util.TempFileUtils` (classe utilitaire statique) pour
> éviter la duplication entre `FfmpegConvertEngine` et `ImageMagickConvertEngine`.
> Ajouter `TempFileUtils.java` à la liste §15.

```java
// com.kovixel.core.conversion.imageformat.service.ImageMagickCommandResolver

@Component
public class ImageMagickCommandResolver {

    private final String convertCommand;

    public ImageMagickCommandResolver() {
        // Détecte ImageMagick 7 (magick) ou 6 (convert) au démarrage
        this.convertCommand = detectCommand();
    }

    private String detectCommand() {
        // Timeout obligatoire : sans lui, waitFor() peut bloquer le démarrage Spring
        // si ImageMagick n'est pas installé et que le processus ne termine jamais.
        try {
            Process process = new ProcessBuilder("magick", "-version")
                .redirectErrorStream(true).start();
            boolean done = process.waitFor(5, TimeUnit.SECONDS);
            return (done && process.exitValue() == 0) ? "magick" : "convert";
        } catch (Exception e) {
            return "convert";
        }
    }

    public String getConvertCommand() { return convertCommand; }
}
```

---

### 4.9 `BatikConvertEngine` — Phase 2 (SVG → JPEG/PNG)

```java
// com.kovixel.core.conversion.imageformat.engine.BatikConvertEngine

@Component
public class BatikConvertEngine implements ImageConvertEngine {

    @Override
    public Set<ImageConvertFormat> supportedInputFormats() { return Set.of(SVG); }

    @Override
    public Set<ImageConvertFormat> supportedOutputFormats() { return Set.of(JPEG, PNG); }

    @Override
    public ImageConvertResult convert(byte[] inputBytes, ImageConvertFormat sourceFormat,
                                      ImageConvertOptions options) throws ImageConvertException {
        long start = System.currentTimeMillis();
        try {
            ByteArrayOutputStream baos = new ByteArrayOutputStream();
            TranscoderInput  input  = new TranscoderInput(new ByteArrayInputStream(inputBytes));
            TranscoderOutput output = new TranscoderOutput(baos);

            Transcoder transcoder = switch (options.targetFormat()) {
                case PNG  -> new PNGTranscoder();
                case JPEG -> {
                    JPEGTranscoder t = new JPEGTranscoder();
                    t.addTranscodingHint(JPEGTranscoder.KEY_QUALITY, options.quality() / 100f);
                    yield t;
                }
                default -> throw new ImageConvertException(
                    "BatikConvertEngine ne supporte pas la sortie " + options.targetFormat());
            };

            if (options.targetWidth() != null) {
                transcoder.addTranscodingHint(SVGAbstractTranscoder.KEY_WIDTH,
                    (float) options.targetWidth());
            }
            if (options.targetHeight() != null) {
                transcoder.addTranscodingHint(SVGAbstractTranscoder.KEY_HEIGHT,
                    (float) options.targetHeight());
            }

            transcoder.transcode(input, output);

            byte[] result = baos.toByteArray();
            return new ImageConvertResult(result, options.targetFormat(),
                "converted." + options.targetFormat().getDefaultExtension(),
                inputBytes.length, result.length, 0, 0,
                engineName(), System.currentTimeMillis() - start);

        } catch (TranscoderException e) {
            throw new ImageConvertException("Batik SVG transcoding error : " + e.getMessage(), e);
        }
    }
}
```

---

### 4.10 `ImageFormatRouter`

```java
// com.kovixel.core.conversion.imageformat.router.ImageFormatRouter

@Component
@RequiredArgsConstructor
public class ImageFormatRouter {

    private final List<ImageConvertEngine> engines;
    private static final Logger log = LoggerFactory.getLogger(ImageFormatRouter.class);

    public ImageConvertResult route(byte[] inputBytes, ImageConvertFormat sourceFormat,
                                    ImageConvertOptions options, UserPlan plan) {

        // Restriction plan : AVIF réservé PRO/ENTERPRISE
        if (options.targetFormat() == AVIF && plan == UserPlan.FREE) {
            throw new KovixelException(ErrorCode.PLAN_RESTRICTION, HttpStatus.FORBIDDEN,
                "La conversion AVIF est réservée aux plans PRO et supérieurs.");
        }

        // Vérifications format
        if (!sourceFormat.isInputSupported()) {
            throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                "Le format " + sourceFormat + " n'est pas accepté en entrée.");
        }
        if (!options.targetFormat().isOutputSupported()) {
            throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                "Le format " + options.targetFormat() + " n'est pas disponible en sortie.");
        }

        ImageConvertEngine engine = selectEngine(sourceFormat, options.targetFormat());
        try {
            return engine.convert(inputBytes, sourceFormat, options);
        } catch (ImageConvertException e) {
            // Tentative fallback vers ImageIoConvertEngine si disponible
            ImageConvertEngine ioEngine = findImageIoEngine();
            if (!(engine instanceof ImageIoConvertEngine) && ioEngine != null
                    && ioEngine.supportedInputFormats().contains(sourceFormat)
                    && ioEngine.supportedOutputFormats().contains(options.targetFormat())) {
                log.warn("Fallback ImageIO pour {} → {} après échec de {} : {}",
                    sourceFormat, options.targetFormat(), engine.engineName(), e.getMessage());
                try {
                    return ioEngine.convert(inputBytes, sourceFormat, options);
                } catch (ImageConvertException fallbackEx) {
                    throw new KovixelException(ErrorCode.CONVERSION_ERROR,
                        HttpStatus.INTERNAL_SERVER_ERROR, fallbackEx.getMessage());
                }
            }
            throw new KovixelException(ErrorCode.CONVERSION_ERROR,
                HttpStatus.INTERNAL_SERVER_ERROR, e.getMessage());
        }
    }

    private ImageConvertEngine selectEngine(ImageConvertFormat src, ImageConvertFormat target) {
        return engines.stream()
                .filter(e -> e.supportedInputFormats().contains(src))
                .filter(e -> e.supportedOutputFormats().contains(target))
                .findFirst()
                .orElseThrow(() -> new KovixelException(ErrorCode.VALIDATION_ERROR,
                    HttpStatus.BAD_REQUEST,
                    "Conversion " + src.getFormatId() + " → " + target.getFormatId()
                        + " non supportée."));
    }

    private ImageConvertEngine findImageIoEngine() {
        return engines.stream()
                .filter(e -> e instanceof ImageIoConvertEngine)
                .findFirst().orElse(null);
    }
}
```

---

### 4.11 `ImageConvertService`

```java
// com.kovixel.core.conversion.imageformat.service.ImageConvertService

@Service
@RequiredArgsConstructor
public class ImageConvertService {

    private final ImageFormatRouter          router;
    private final FileValidationPipeline     validationPipeline;
    private final ImageConvertProperties     props;
    private final UserRepository             userRepository;
    private final ProcessingJobRepository    jobRepository;
    private final ProcessingOrchestrator     orchestrator;
    private final MeterRegistry             meterRegistry;
    private final ObjectMapper              objectMapper;

    public ResponseEntity<?> convert(MultipartFile file, ImageConvertOptions options,
                                     String userEmail) throws IOException {
        byte[] bytes = file.getBytes();

        User user = userRepository.findByEmail(userEmail)
                .orElseThrow(() -> new KovixelException(ErrorCode.USER_NOT_FOUND,
                        HttpStatus.UNAUTHORIZED, "Utilisateur introuvable."));

        // Validation pipeline (taille, magic bytes, pixel bomb, etc.)
        validationPipeline.validate(FileValidationContext.forImageConvert(
                bytes, file.getOriginalFilename(), file.getContentType(),
                user.getPlan(), ToolType.IMAGE_CONVERT));

        // Détection automatique du format source
        ImageConvertFormat sourceFormat = detectSourceFormat(bytes, file.getOriginalFilename());

        // AVIF encoding + fichiers > seuil → job async
        boolean async = options.targetFormat() == AVIF && props.isAvifAlwaysAsync()
                || bytes.length > props.getAsyncThresholdBytes();

        if (async) {
            return processAsync(bytes, sourceFormat, options, user);
        }

        return processSync(bytes, sourceFormat, options, user);
    }

    private ResponseEntity<byte[]> processSync(byte[] bytes, ImageConvertFormat src,
                                               ImageConvertOptions opts, User user) {
        long start = System.currentTimeMillis();
        ImageConvertResult result = router.route(bytes, src, opts, user.getPlan());
        long totalMs = System.currentTimeMillis() - start;

        recordMetrics(result, src, opts.targetFormat(), user.getPlan(), totalMs, "sync");

        return ResponseEntity.ok()
                .contentType(MediaType.parseMediaType(opts.targetFormat().getMimeType()))
                .header("Content-Disposition",
                    "attachment; filename=\"" + result.outputFilename() + "\"")
                .header("X-Source-Format",      src.getFormatId())
                .header("X-Target-Format",      opts.targetFormat().getFormatId())
                .header("X-Input-Size-Bytes",   String.valueOf(result.inputSizeBytes()))
                .header("X-Output-Size-Bytes",  String.valueOf(result.outputSizeBytes()))
                .header("X-Output-Width-Px",    String.valueOf(result.outputWidth()))
                .header("X-Output-Height-Px",   String.valueOf(result.outputHeight()))
                .header("X-Engine-Used",         result.engineUsed())
                .header("X-Processing-Time-Ms", String.valueOf(totalMs))
                .body(result.outputBytes());
    }

    private ResponseEntity<Map<String, Object>> processAsync(byte[] bytes,
                                                              ImageConvertFormat src,
                                                              ImageConvertOptions opts,
                                                              User user) throws IOException {
        String inputData = objectMapper.writeValueAsString(Map.of(
            "sourceFormat", src.getFormatId(),
            "options",      opts
        ));

        ProcessingJob job = jobRepository.save(ProcessingJob.builder()
                .jobType(JobType.IMAGE_CONVERT)
                .status(JobStatus.PENDING)
                .userId(user.getId())
                .inputData(inputData)
                .build());

        orchestrator.process(job.getId(), null, bytes);

        return ResponseEntity.accepted()
                .header("X-Job-Id", String.valueOf(job.getId()))
                .body(Map.of(
                    "jobId",   job.getId(),
                    "status",  "PENDING",
                    "message", "Conversion démarrée. Suivez l'avancement via GET /api/v1/jobs/{jobId}."
                ));
    }

    private ImageConvertFormat detectSourceFormat(byte[] bytes, String filename) {
        // Priorité 1 : magic bytes (MagicBytesDetector existant + nouvelles signatures §5.2)
        ImageConvertFormat detected = MagicBytesDetector.detectImageConvertFormat(bytes);
        if (detected != null) return detected;

        // Priorité 2 : extension du fichier
        if (filename != null && filename.contains(".")) {
            String ext = filename.substring(filename.lastIndexOf('.') + 1).toLowerCase();
            try { return ImageConvertFormat.fromString(ext); }
            catch (KovixelException ignored) {}
        }

        throw new KovixelException(ErrorCode.VALIDATION_ERROR, HttpStatus.BAD_REQUEST,
                "Impossible de détecter le format source de l'image.");
    }

    private void recordMetrics(ImageConvertResult result, ImageConvertFormat src,
                                ImageConvertFormat target, UserPlan plan,
                                long durationMs, String mode) {
        meterRegistry.timer("image.convert.duration",
                "source_format", src.getFormatId(),
                "target_format", target.getFormatId(),
                "plan", plan.name(), "mode", mode)
                .record(durationMs, TimeUnit.MILLISECONDS);

        meterRegistry.counter("image.convert.total",
                "source_format", src.getFormatId(),
                "target_format", target.getFormatId(),
                "status", "success")
                .increment();

        if (result.inputSizeBytes() > 0) {
            double ratio = (double) result.outputSizeBytes() / result.inputSizeBytes();
            meterRegistry.summary("image.convert.compression.ratio",
                    "target_format", target.getFormatId())
                    .record(ratio);
        }
    }
}
```

---

### 4.12 `ImageConvertController`

```java
// com.kovixel.core.conversion.imageformat.controller.ImageConvertController

@RestController
@RequestMapping("/api/v1/convert")
@RequiredArgsConstructor
@Tag(name = "Image Conversion", description = "Conversion d'images entre formats")
public class ImageConvertController {

    private final ImageConvertService imageConvertService;

    @PostMapping(value = "/image", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @Operation(summary = "Convertir une image d'un format à un autre",
               description = "Supporte JPEG/PNG/WebP/TIFF/BMP/GIF (Phase 1) + AVIF/HEIC/SVG (Phase 2). "
                           + "Fichiers >10 MB ou format AVIF : réponse 202 + jobId.")
    @CheckQuota(feature = FeatureType.CONVERSION)
    public ResponseEntity<?> convertImage(

        @RequestPart("file")
        @Parameter(description = "Image source (multipart/form-data)", required = true)
        MultipartFile file,

        @RequestParam("targetFormat")
        @Parameter(description = "Format de sortie : jpeg, png, webp, tiff, bmp, gif, avif")
        String targetFormat,

        @RequestParam(defaultValue = "85")
        @Min(1) @Max(100)
        @Parameter(description = "Qualité 1–100 (JPEG/WebP/AVIF). Ignoré pour PNG/BMP/TIFF/GIF.")
        int quality,

        @RequestParam(required = false)
        @Positive
        @Parameter(description = "Largeur de sortie en pixels. Null = pas de resize.")
        Integer width,

        @RequestParam(required = false)
        @Positive
        @Parameter(description = "Hauteur de sortie en pixels. Null = pas de resize.")
        Integer height,

        @RequestParam(defaultValue = "fit")
        @Parameter(description = "Mode de redimensionnement : fit, fill, stretch, crop")
        String fitMode,

        @RequestParam(defaultValue = "false")
        @Parameter(description = "Conserver les métadonnées EXIF. "
                               + "false (défaut) = stripping (conformité RGPD).")
        boolean preserveExif,

        @RequestParam(defaultValue = "false")
        @Parameter(description = "JPEG progressif (meilleur chargement réseau, légèrement plus grand).")
        boolean progressive,

        @RequestParam(defaultValue = "false")
        @Parameter(description = "Mode sans perte pour WebP ou AVIF.")
        boolean lossless,

        @RequestParam(defaultValue = "#FFFFFF")
        @Parameter(description = "Couleur de fond (#RRGGBB) pour PNG/WebP avec transparence → JPEG.")
        String backgroundColor,

        @AuthenticationPrincipal UserDetails userDetails

    ) throws IOException {

        ImageConvertOptions options = ImageConvertOptions.fromRequest(
            targetFormat, quality, width, height, fitMode,
            preserveExif, progressive, lossless, backgroundColor);

        return imageConvertService.convert(file, options, userDetails.getUsername());
    }
}
```

---

### 4.13 `ImageConvertStrategy` — Async job

```java
// com.kovixel.core.conversion.imageformat.strategy.ImageConvertStrategy

@Component
@RequiredArgsConstructor
public class ImageConvertStrategy implements ProcessingStrategy {

    private final ImageFormatRouter router;
    private final ObjectMapper     objectMapper;
    private final UserRepository   userRepository;

    @Override
    public JobType getSupportedType() { return JobType.IMAGE_CONVERT; }

    @Override
    public boolean needsRawBytes() { return true; }

    @Override
    public String processBytes(String inputData, Long userId, byte[] rawBytes,
                               Long jobId, Long documentId) {
        try {
            ConvertJobInput input = objectMapper.readValue(inputData, ConvertJobInput.class);
            UserPlan plan = userRepository.findById(userId)
                    .map(User::getPlan).orElse(UserPlan.FREE);

            ImageConvertResult result = router.route(
                rawBytes, input.sourceFormat(), input.options(), plan);

            // CRITIQUE : stocker le binaire en MinIO pour que GET /download puisse le servir.
            // Utiliser DocumentStorageService (ou équivalent) selon le pattern des stratégies
            // existantes (PDF_LOCK, PDF_WATERMARK, etc.) qui écrivent en MinIO et retournent la clé.
            String storageKey = documentStorageService.storeJobResult(
                jobId, result.outputBytes(),
                result.outputFormat().getMimeType(),
                result.outputFilename());

            return objectMapper.writeValueAsString(Map.of(
                "storageKey",       storageKey,           // clé MinIO pour GET /download
                "outputSizeBytes",  result.outputSizeBytes(),
                "outputFormat",     result.outputFormat().getFormatId(),
                "outputWidth",      result.outputWidth(),
                "outputHeight",     result.outputHeight(),
                "engineUsed",       result.engineUsed(),
                "processingTimeMs", result.processingTimeMs()
            ));
        } catch (Exception e) {
            throw new KovixelException(ErrorCode.CONVERSION_ERROR,
                HttpStatus.INTERNAL_SERVER_ERROR, "Async image convert failed : " + e.getMessage());
        }
    }

    // record interne — Jackson désérialise les records Java 21 si :
    //   (a) le flag Maven `-parameters` est actif dans maven-compiler-plugin, OU
    //   (b) chaque champ est annoté @JsonProperty("nom")
    // Vérifier dans pom.xml : <compilerArg>-parameters</compilerArg> (souvent déjà présent
    // pour Spring MVC). Si absent, ajouter @JsonProperty sur chaque champ du record.
    record ConvertJobInput(
        @JsonProperty("sourceFormat") ImageConvertFormat sourceFormat,
        @JsonProperty("options")      ImageConvertOptions options
    ) {}
}
```

---

### 4.14 `ImageConvertProperties`

```java
// com.kovixel.core.conversion.imageformat.config.ImageConvertProperties

@Component
@ConfigurationProperties(prefix = "kovixel.conversion.image-convert")
@Getter @Setter
public class ImageConvertProperties {
    private long    maxFileBytes             = 20_971_520L;   // 20 MB
    private long    asyncThresholdBytes      = 10_485_760L;   // 10 MB
    private boolean avifAlwaysAsync          = true;
    private boolean avifEncoderSvt           = true;          // true=libsvtav1, false=libaom-av1
    private int     defaultQuality           = 85;
    private int     ffmpegTimeoutSeconds     = 30;
    private int     imagemagickTimeoutSeconds = 10;
    private long    batikTimeoutMs           = 5_000L;
    private int     maxOutputWidthPx         = 10_000;
    private int     maxOutputHeightPx        = 10_000;
}
```

---

## 5. Pipeline de Validation

### 5.1 Étendre `ImageStructureValidator`

```java
// Ajouter dans ImageStructureValidator (extension Phase 2)
// Mettre la liste blanche en Map<ToolType, Set<String>> pour éviter de modifier la Phase 1

private static final Set<String> ALLOWED_EXTENSIONS_IMAGE_CONVERT = Set.of(
    "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "bmp",   // Phase 1
    "avif", "heic", "heif", "svg"                                  // Phase 2
);
```

### 5.2 Étendre `MagicBytesValidator` — signatures Phase 2

```java
// Méthodes à ajouter dans MagicBytesDetector (ou utilitaire similaire)

// AVIF : ISO Base Media File Format — 'ftyp' à l'offset 4, sous-type 'avif'/'avis'
public static boolean isAvif(byte[] b) {
    return b.length > 11
        && b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p'
        && ((b[8]=='a' && b[9]=='v' && b[10]=='i' && b[11]=='f')
         || (b[8]=='a' && b[9]=='v' && b[10]=='i' && b[11]=='s'));
}

// HEIC : même structure ISOBMFF, sous-type 'heic'/'heis'/'mif1'/'msf1'
public static boolean isHeic(byte[] b) {
    return b.length > 11
        && b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p'
        && ((b[8]=='h' && b[9]=='e' && b[10]=='i' && b[11]=='c')
         || (b[8]=='m' && b[9]=='i' && b[10]=='f' && b[11]=='1'));
}

// SVG : XML ou balise <svg directement (texte, pas de magic bytes binaires)
// IMPORTANT : vérifier SVG EN DERNIER dans la chaîne de détection.
// Un JPEG avec commentaire EXIF contenant "<?xml" déclencherait un faux positif
// si SVG est vérifié avant les signatures binaires (FF D8 FF pour JPEG, etc.).
public static boolean isSvg(byte[] b) {
    String header = new String(b, 0, Math.min(b.length, 100), StandardCharsets.UTF_8);
    return header.contains("<svg") || (header.contains("<?xml") && header.contains("svg"));
}
```

### 5.3 `PixelBombValidator` — inchangé

Le validateur existant (max 20 000 × 20 000 px) s'applique automatiquement à `IMAGE_CONVERT`
via `FileValidationContext.forImageConvert()`.

### 5.4 `FileValidationContext` — nouvelle factory method

```java
// Ajouter dans FileValidationContext

public static FileValidationContext forImageConvert(byte[] bytes, String filename,
                                                     String contentType, UserPlan plan,
                                                     ToolType toolType) {
    return FileValidationContext.builder()
            .fileBytes(bytes)
            .originalFilename(filename)
            .contentType(contentType)
            .userPlan(plan)
            .toolType(toolType)
            .expectedTypes(Set.of(FileType.IMAGE))  // + FileType.IMAGE_ADVANCED en Phase 2
            .build();
}
```

### 5.5 Ajouter `IMAGE_CONVERT` au `ToolType` enum

```java
// Dans ToolType.java (ou équivalent)
IMAGE_CONVERT("image-convert", FeatureType.CONVERSION)
```

---

## 6. Configuration `application.yml`

```yaml
kovixel:
  conversion:
    image-convert:
      max-file-bytes: 20971520          # 20 MB — limite input
      async-threshold-bytes: 10485760   # 10 MB → job async automatique
      avif-always-async: true            # AVIF encoding = toujours async (>500ms)
      avif-encoder-svt: true             # true=libsvtav1 (rapide), false=libaom-av1 (meilleure qualité)
      default-quality: 85
      ffmpeg-timeout-seconds: 30
      imagemagick-timeout-seconds: 10
      batik-timeout-ms: 5000
      max-output-width-px: 10000        # Protection resize DoS
      max-output-height-px: 10000
```

---

## 7. Async Pattern — `ProcessingJob`

### 7.1 Ajouter `IMAGE_CONVERT` à `JobType`

```java
// Dans ProcessingJob.JobType (ou JobType.java dédié)
IMAGE_CONVERT,  // Conversion image→image (JPEG→WebP, PNG→AVIF, HEIC→JPEG, etc.)
```

> **Aucune migration Flyway requise** pour cet ajout : `ProcessingJob` utilise
> `@Enumerated(EnumType.STRING)` → la colonne `job_type` est un `VARCHAR`, pas un
> type PostgreSQL natif `ENUM`.

### 7.2 Enregistrement automatique

`ProcessingOrchestrator` découvre `ImageConvertStrategy` via injection de `List<ProcessingStrategy>`.
Aucune modification de l'orchestrateur n'est nécessaire si le pattern existant est respecté
(implémentation de `ProcessingStrategy` + annotation `@Component`).

---

## 8. EXIF / Métadonnées

### 8.1 Comportement par défaut

```
preserveExif = false (défaut) :
  → BufferedImage decode via ImageIO strips l'EXIF automatiquement
  → Supprime : localisation GPS, appareil photo, dates, données personnelles
  → Conformité RGPD native sans action supplémentaire

preserveExif = true (option explicite utilisateur) :
  → Utiliser ExifTransferService (Phase 2) pour copier les tags JPEG→JPEG
  → Limité au format JPEG (PNG/WebP ne supportent pas EXIF standard)
```

### 8.2 `ExifTransferService` — Phase 2

Dépendance à ajouter si absente de `pom.xml` :

```xml
<dependency>
    <groupId>com.drewnoakes</groupId>
    <artifactId>metadata-extractor</artifactId>
    <version>2.19.0</version>
</dependency>
```

```java
// com.kovixel.core.conversion.imageformat.service.ExifTransferService

@Component
public class ExifTransferService {

    public byte[] transferExif(byte[] sourceBytes, byte[] targetBytes,
                               ImageConvertFormat targetFormat) throws IOException {
        if (targetFormat != JPEG) {
            return targetBytes; // EXIF non-standard pour PNG/WebP — skip silencieux
        }
        // Lecture des tags EXIF depuis la source
        Metadata metadata = ImageMetadataReader.readMetadata(
            new ByteArrayInputStream(sourceBytes));

        // Réécriture dans le JPEG de sortie via Apache Commons Imaging
        // (metadata-extractor est lecture seule → utiliser commons-imaging pour write)
        // Phase 2 : implémenter via ExifRewriter d'Apache Commons Imaging
        return targetBytes; // placeholder Phase 1
    }
}
```

---

## 9. Métriques Micrometer

```java
// Timers — durée de conversion par paire de formats + moteur + plan
meterRegistry.timer("image.convert.duration",
    "source_format", "jpeg",
    "target_format", "webp",
    "engine",        "ImageIoConvertEngine",
    "plan",          "FREE",
    "mode",          "sync")
    .record(durationMs, TimeUnit.MILLISECONDS);

// Counters — conversions réussies / erreurs
meterRegistry.counter("image.convert.total",
    "source_format", src.getFormatId(),
    "target_format", target.getFormatId(),
    "status",        "success").increment();

meterRegistry.counter("image.convert.total",
    "status", "error",
    "engine", engineName).increment();

// DistributionSummary — taille des fichiers + ratio de compression
meterRegistry.summary("image.convert.input.bytes",  "target_format", "avif").record(inputSize);
meterRegistry.summary("image.convert.output.bytes", "target_format", "avif").record(outputSize);
meterRegistry.summary("image.convert.compression.ratio",
    "target_format", target.getFormatId()).record(outputSize / (double) inputSize);
```

### Alertes Grafana recommandées

```
image.convert.duration.p99 > 5000ms    → alerte moteur lent (ffmpeg/Batik)
image.convert.total{status="error"} rate > 5%  → alerte taux d'erreur
image.convert.compression.ratio > 2.0  → AVIF ou WebP produisant des fichiers plus grands
```

---

## 10. Migration Flyway V51

### 10.1 Schéma — aucun changement obligatoire

`JobType.IMAGE_CONVERT` est ajouté dans le Java (enum `EnumType.STRING`) — pas de migration DDL.

### 10.2 Migration optionnelle — index monitoring (recommandée Phase 2)

```java
// src/main/java/com/kovixel/db/migration/V51__add_image_convert_job_index.java
//
// ⚠️ CHEMIN OBLIGATOIRE : src/main/java/ (pas src/main/resources/)
// Les migrations Java Flyway doivent être des classes compilées, pas des fichiers texte.
// Flyway les charge via classpath, pas depuis resources.
//
// Vérifier spring.flyway.locations dans application.yml :
//   locations: classpath:db/migration,com/kovixel/db/migration
// (le second chemin pointe vers le package Java compilé)
//
// Migration Java requise car CREATE INDEX CONCURRENTLY ne peut pas s'exécuter
// dans une transaction Flyway (sinon : org.flywaydb.core.api.FlywayException).

@SuppressWarnings("unused")
public class V51__add_image_convert_job_index extends BaseJavaMigration {

    @Override
    public Integer getChecksum() { return 51_001; }

    @Override
    public boolean canExecuteInTransaction() { return false; } // CONCURRENTLY interdit en tx

    @Override
    public void migrate(Context context) throws Exception {
        try (Statement stmt = context.getConnection().createStatement()) {
            stmt.execute("""
                CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_processing_jobs_image_convert
                ON processing_jobs (user_id, created_at DESC)
                WHERE job_type = 'IMAGE_CONVERT'
                """);
        }
    }
}
```

> **Prérequis :** Vérifier que `spring.flyway.locations` inclut le package Java des migrations
> (`classpath:db/migration` pour les SQL + `com.kovixel.db.migration` pour les Java, ou configurer
> `spring.flyway.mixed=true` si SQL et Java coexistent dans le même chemin).

---

## 11. Frontend Angular

### 11.1 Interface TypeScript

```typescript
// src/app/tools/image-convert/image-convert.model.ts

export type ImageConvertFormat =
    'jpeg' | 'png' | 'webp' | 'tiff' | 'bmp' | 'gif' | 'avif';

export type ResizeFitMode = 'fit' | 'fill' | 'stretch' | 'crop';

export interface ImageConvertParams {
    targetFormat:     ImageConvertFormat;
    quality:          number;        // 1–100
    width?:           number;
    height?:          number;
    fitMode:          ResizeFitMode;
    preserveExif:     boolean;
    progressive:      boolean;
    lossless:         boolean;
    backgroundColor:  string;        // "#FFFFFF"
}

export interface ImageConvertResponse {
    // Réponse sync (200)     : binaire dans body, headers X-*
    // Réponse async (202)    : JSON avec jobId
    jobId?:   number;
    status?:  'PENDING' | 'PROCESSING' | 'COMPLETED' | 'FAILED';
    message?: string;
}
```

### 11.2 Layout de l'outil

```
┌─────────────────────────────────────────────────────┐
│  [Zone de dépôt drag-and-drop]                      │
│  "Déposez votre image ici ou cliquez pour choisir"  │
│  Formats acceptés : JPEG, PNG, WebP, TIFF, BMP,     │
│  GIF (+ HEIC, SVG en Phase 2)                       │
└─────────────────────────────────────────────────────┘
         ↓ (après upload)
┌─────────────────────────────────────────────────────┐
│  Aperçu source   │  Format : JPEG                   │
│  [miniature]     │  Dimensions : 1920 × 1080 px     │
│                  │  Taille : 2,4 MB                 │
└─────────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────┐
│  FORMAT DE SORTIE                                   │
│  [● JPEG] [○ PNG] [○ WebP] [○ TIFF] [○ BMP]        │
│  [○ GIF]  [○ AVIF 🔒PRO]                           │
│                                                     │
│  QUALITÉ (JPEG/WebP/AVIF) ————————————●—— 85       │
│                                                     │
│  REDIMENSIONNEMENT                                  │
│  Largeur [____] px  Hauteur [____] px               │
│  Mode : [• fit] [fill] [stretch] [crop]             │
│                                                     │
│  OPTIONS AVANCÉES ▼                                 │
│  ☐ JPEG progressif    ☐ Sans perte (WebP/AVIF)     │
│  ☐ Conserver EXIF ⚠️RGPD                           │
│  Fond opaque : [●]  #FFFFFF                         │
└─────────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────┐
│  [  Convertir  ]   Taille estimée : ~890 KB        │
└─────────────────────────────────────────────────────┘
         ↓ (résultat)
┌─────────────────────────────────────────────────────┐
│  AVANT ←———————|———————→ APRÈS  (slider Phase 3)   │
│                                                     │
│  Avant : 2,4 MB JPEG 1920×1080                     │
│  Après : 890 KB WebP 1920×1080  (-62,9%)           │
│  Moteur : ImageIoConvertEngine — 42ms              │
│                                                     │
│  [  Télécharger  ]   [  Recommencer  ]             │
└─────────────────────────────────────────────────────┘
```

### 11.3 Service Angular

```typescript
// src/app/tools/image-convert/image-convert.service.ts

@Injectable({ providedIn: 'root' })
export class ImageConvertService {

    constructor(private http: HttpClient) {}

    convert(file: File, params: ImageConvertParams): Observable<HttpResponse<Blob>> {
        const formData = new FormData();
        formData.append('file', file);
        Object.entries(params).forEach(([key, value]) => {
            if (value !== undefined && value !== null) {
                formData.append(key, String(value));
            }
        });

        // ⚠️ responseType: 'blob' est correct pour la réponse binaire synchrone (200).
        // Pour la réponse async (202 JSON), le body est aussi reçu comme Blob —
        // utiliser response.text() pour parser le JSON selon le status HTTP.
        return this.http.post('/api/v1/convert/image', formData, {
            observe: 'response',
            responseType: 'blob'
        });
    }

    /** Parse la réponse : binaire (200) ou JSON async (202). */
    handleConvertResponse(response: HttpResponse<Blob>): Observable<Blob | { jobId: number }> {
        if (response.status === 202) {
            // Lire le Blob comme texte pour extraire le JSON
            return from(response.body!.text()).pipe(
                map(text => JSON.parse(text) as { jobId: number })
            );
        }
        return of(response.body!); // Blob binaire (200)
    }

    // Polling pour les jobs async (202 Accepted)
    pollJobStatus(jobId: number): Observable<any> {
        return interval(2000).pipe(
            switchMap(() => this.http.get<any>(`/api/v1/jobs/${jobId}`)),
            takeWhile(r => r.status === 'PENDING' || r.status === 'PROCESSING', true),
            filter(r => r.status === 'COMPLETED' || r.status === 'FAILED')
        );
    }
}
```

### 11.4 Gestion des headers de réponse

```typescript
// Dans le composant, après la réponse sync (200)
const inputBytes   = +response.headers.get('X-Input-Size-Bytes');
const outputBytes  = +response.headers.get('X-Output-Size-Bytes');
const outputWidth  = +response.headers.get('X-Output-Width-Px');
const outputHeight = +response.headers.get('X-Output-Height-Px');
const engineUsed   = response.headers.get('X-Engine-Used');
const durationMs   = +response.headers.get('X-Processing-Time-Ms');

this.compressionRatio = ((1 - outputBytes / inputBytes) * 100).toFixed(1) + '%';
```

### 11.5 Exposition CORS des headers custom

Les headers `X-*` doivent être ajoutés à `Access-Control-Expose-Headers`, sinon Angular
ne peut pas les lire (`response.headers.get(...)` retourne `null` dans le navigateur).

```java
// Dans CorsConfig.java ou SecurityConfig.java (section .cors())
CorsConfiguration config = new CorsConfiguration();
config.setExposedHeaders(List.of(
    "X-Source-Format",
    "X-Target-Format",
    "X-Input-Size-Bytes",
    "X-Output-Size-Bytes",
    "X-Output-Width-Px",
    "X-Output-Height-Px",
    "X-Engine-Used",
    "X-Processing-Time-Ms",
    "X-Job-Id"
));
```

> Si `X-Job-Id` est déjà exposé par d'autres endpoints (async PDF), vérifier qu'il n'est
> pas en doublon. Sinon, ajouter uniquement les headers manquants à la liste existante.

---

## 12. Tests

### 12.1 Tests unitaires — `ImageIoConvertEngineTest`

```java
@ExtendWith(MockitoExtension.class)
class ImageIoConvertEngineTest {

    final ImageIoConvertEngine engine = new ImageIoConvertEngine();

    @Test
    @DisplayName("PNG (transparent) → JPEG : alpha aplati sur fond blanc")
    void convert_pngWithAlpha_toJpeg_flattensOnWhiteBackground() throws Exception {
        byte[] pngAlpha = createPngWithAlpha(200, 200);

        ImageConvertResult result = engine.convert(pngAlpha, PNG,
            new ImageConvertOptions(JPEG, 80, null, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"));

        BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(result.outputBytes()));
        assertThat(decoded).isNotNull();
        assertThat(decoded.getColorModel().hasAlpha()).isFalse();
        assertThat(result.outputFormat()).isEqualTo(JPEG);
    }

    @Test
    @DisplayName("JPEG → WebP qualité 60 : sortie plus petite que l'entrée")
    void convert_jpegToWebp_quality60_outputSmallerThanInput() throws Exception {
        byte[] jpeg = loadTestResource("test-photo.jpg"); // fichier de test dans resources

        ImageConvertResult result = engine.convert(jpeg, JPEG,
            new ImageConvertOptions(WEBP, 60, null, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"));

        assertThat(result.outputSizeBytes()).isLessThan(result.inputSizeBytes());
    }

    @Test
    @DisplayName("JPEG 1920×1080 → resize 800px large : ratio conservé → 800×450")
    void convert_jpegResize_widthOnly_preservesAspectRatio() throws Exception {
        byte[] jpeg = createTestJpeg(1920, 1080);

        ImageConvertResult result = engine.convert(jpeg, JPEG,
            new ImageConvertOptions(JPEG, 85, 800, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"));

        assertThat(result.outputWidth()).isEqualTo(800);
        assertThat(result.outputHeight()).isEqualTo(450);
    }

    @Test
    @DisplayName("JPEG progressive : sortie décodable et de format JPEG")
    void convert_jpegProgressive_outputIsValidJpeg() throws Exception {
        byte[] jpeg = createTestJpeg(400, 300);

        ImageConvertResult result = engine.convert(jpeg, JPEG,
            new ImageConvertOptions(JPEG, 75, null, null, ResizeFitMode.FIT,
                false, true, false, "#FFFFFF"));

        assertThat(result.outputBytes()).isNotEmpty();
        assertThat(ImageIO.read(new ByteArrayInputStream(result.outputBytes()))).isNotNull();
    }

    @Test
    @DisplayName("GIF → PNG : frame 0 converti, fichier PNG valide")
    void convert_gifToPng_convertsFrame0() throws Exception {
        byte[] gif = loadTestResource("test-animated.gif");

        ImageConvertResult result = engine.convert(gif, GIF,
            new ImageConvertOptions(PNG, 85, null, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"));

        assertThat(result.outputFormat()).isEqualTo(PNG);
        assertThat(ImageIO.read(new ByteArrayInputStream(result.outputBytes()))).isNotNull();
    }

    @Test
    @DisplayName("Format target non géré par ImageIo → ImageConvertException")
    void convert_avifTarget_throwsImageConvertException() {
        byte[] jpeg = new byte[]{(byte)0xFF, (byte)0xD8, (byte)0xFF, (byte)0xE0};

        assertThatThrownBy(() -> engine.convert(jpeg, JPEG,
                new ImageConvertOptions(AVIF, 85, null, null, ResizeFitMode.FIT,
                    false, false, false, "#FFFFFF")))
                .isInstanceOf(ImageConvertException.class);
    }
}
```

### 12.2 Tests d'intégration — `ImageConvertControllerTest`

```java
@WebMvcTest(ImageConvertController.class)
@DisplayName("ImageConvertController — Tests HTTP")
class ImageConvertControllerTest {

    @Autowired MockMvc mockMvc;
    @MockitoBean ImageConvertService        imageConvertService;

    // Security mocks — pattern identique à CheckoutControllerTest et WebhookControllerTest
    @MockitoBean CheckoutRateLimitFilter       checkoutRateLimitFilter;
    @MockitoBean JwtService                    jwtService;
    @MockitoBean UserDetailsService            userDetailsService;
    @MockitoBean AnonymousQuotaService         anonymousQuotaService;
    @MockitoBean TokenBlacklistService         tokenBlacklistService;
    @MockitoBean RedisTemplate<String, String> redisTemplate;
    @MockitoBean JpaMetamodelMappingContext     jpaMetamodelMappingContext;

    @BeforeEach
    void setUpFilter() throws Exception {
        doAnswer(inv -> {
            inv.<FilterChain>getArgument(2).doFilter(
                    inv.getArgument(0), inv.getArgument(1));
            return null;
        }).when(checkoutRateLimitFilter)
          .doFilter(any(ServletRequest.class), any(ServletResponse.class), any(FilterChain.class));
    }

    @Test
    @DisplayName("POST /convert/image — non authentifié → 401")
    void convertImage_unauthenticated_returns401() throws Exception {
        mockMvc.perform(multipart("/api/v1/convert/image")
                        .file(new MockMultipartFile("file", "img.jpg", "image/jpeg", new byte[100]))
                        .param("targetFormat", "png")
                        .with(csrf()))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @WithMockUser(username = "user@kovixel.com")
    @DisplayName("POST /convert/image — quality=0 → 400 (Bean Validation)")
    void convertImage_qualityZero_returns400() throws Exception {
        mockMvc.perform(multipart("/api/v1/convert/image")
                        .file(new MockMultipartFile("file", "img.jpg", "image/jpeg", new byte[100]))
                        .param("targetFormat", "png")
                        .param("quality", "0")
                        .with(csrf()))
                .andExpect(status().isBadRequest());
    }

    @Test
    @WithMockUser(username = "user@kovixel.com")
    @DisplayName("POST /convert/image — JPEG→PNG valide → 200 + Content-Type image/png")
    void convertImage_jpegToPng_returns200WithPng() throws Exception {
        byte[] fakeOutput = new byte[]{(byte)0x89, 0x50, 0x4E, 0x47}; // PNG magic
        when(imageConvertService.convert(any(), any(), any()))
                .thenReturn(ResponseEntity.ok()
                        .contentType(MediaType.IMAGE_PNG)
                        .header("X-Source-Format", "jpeg")
                        .header("X-Target-Format", "png")
                        .header("X-Input-Size-Bytes",  "2048")
                        .header("X-Output-Size-Bytes", "1024")
                        .body(fakeOutput));

        mockMvc.perform(multipart("/api/v1/convert/image")
                        .file(new MockMultipartFile("file", "img.jpg", "image/jpeg", new byte[100]))
                        .param("targetFormat", "png")
                        .with(csrf()))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.IMAGE_PNG))
                .andExpect(header().string("X-Source-Format", "jpeg"))
                .andExpect(header().string("X-Target-Format", "png"));
    }

    @Test
    @WithMockUser(username = "user@kovixel.com")
    @DisplayName("POST /convert/image — format AVIF → 202 Accepted + X-Job-Id")
    void convertImage_avifTarget_returns202WithJobId() throws Exception {
        when(imageConvertService.convert(any(), any(), any()))
                .thenReturn(ResponseEntity.accepted()
                        .header("X-Job-Id", "99")
                        .body(Map.of("jobId", 99L, "status", "PENDING",
                                     "message", "Conversion démarrée.")));

        mockMvc.perform(multipart("/api/v1/convert/image")
                        .file(new MockMultipartFile("file", "img.jpg", "image/jpeg", new byte[100]))
                        .param("targetFormat", "avif")
                        .with(csrf()))
                .andExpect(status().isAccepted())
                .andExpect(header().string("X-Job-Id", "99"));
    }

    @Test
    @WithMockUser(username = "user@kovixel.com")
    @DisplayName("POST /convert/image — width=0 (non positif) → 400")
    void convertImage_widthZero_returns400() throws Exception {
        mockMvc.perform(multipart("/api/v1/convert/image")
                        .file(new MockMultipartFile("file", "img.jpg", "image/jpeg", new byte[100]))
                        .param("targetFormat", "png")
                        .param("width", "0")
                        .with(csrf()))
                .andExpect(status().isBadRequest());
    }
}
```

### 12.3 Tests unitaires — `ImageFormatRouterTest`

```java
@ExtendWith(MockitoExtension.class)
class ImageFormatRouterTest {

    @Mock ImageIoConvertEngine imageIoEngine;
    @Mock FfmpegConvertEngine  ffmpegEngine;

    ImageFormatRouter router;

    @BeforeEach
    void setUp() {
        when(imageIoEngine.supportedInputFormats()).thenReturn(
            Set.of(JPEG, PNG, WEBP, TIFF, BMP, GIF));
        when(imageIoEngine.supportedOutputFormats()).thenReturn(
            Set.of(JPEG, PNG, WEBP, TIFF, BMP, GIF));
        when(ffmpegEngine.supportedInputFormats()).thenReturn(
            Set.of(JPEG, PNG, WEBP, TIFF, BMP, GIF));
        when(ffmpegEngine.supportedOutputFormats()).thenReturn(Set.of(AVIF));

        router = new ImageFormatRouter(List.of(imageIoEngine, ffmpegEngine));
    }

    @Test
    @DisplayName("JPEG → WEBP : sélectionne ImageIoConvertEngine")
    void route_jpegToWebp_selectsImageIoEngine() throws Exception {
        when(imageIoEngine.convert(any(), eq(JPEG), any()))
            .thenReturn(mockResult(WEBP));

        router.route(new byte[]{1}, JPEG,
            new ImageConvertOptions(WEBP, 80, null, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"), UserPlan.FREE);

        verify(imageIoEngine).convert(any(), eq(JPEG), any());
        verifyNoInteractions(ffmpegEngine);
    }

    @Test
    @DisplayName("PNG → AVIF : utilisateur FREE → KovixelException 403 PLAN_RESTRICTION")
    void route_avifTargetFreeUser_throwsForbidden() {
        assertThatThrownBy(() -> router.route(new byte[]{1}, PNG,
                new ImageConvertOptions(AVIF, 70, null, null, ResizeFitMode.FIT,
                    false, false, false, "#FFFFFF"), UserPlan.FREE))
                .isInstanceOf(KovixelException.class)
                .extracting(e -> ((KovixelException) e).getStatus())
                .isEqualTo(HttpStatus.FORBIDDEN);
    }

    @Test
    @DisplayName("PNG → AVIF : utilisateur PRO → sélectionne FfmpegConvertEngine")
    void route_avifTargetProUser_selectsFfmpegEngine() throws Exception {
        when(ffmpegEngine.convert(any(), eq(PNG), any()))
            .thenReturn(mockResult(AVIF));

        router.route(new byte[]{1}, PNG,
            new ImageConvertOptions(AVIF, 70, null, null, ResizeFitMode.FIT,
                false, false, false, "#FFFFFF"), UserPlan.PRO);

        verify(ffmpegEngine).convert(any(), eq(PNG), any());
        verifyNoInteractions(imageIoEngine);
    }

    @Test
    @DisplayName("Paire source/target non supportée → KovixelException 400")
    void route_unsupportedPair_throws400() {
        assertThatThrownBy(() -> router.route(new byte[]{1}, HEIC,
                new ImageConvertOptions(JPEG, 85, null, null, ResizeFitMode.FIT,
                    false, false, false, "#FFFFFF"), UserPlan.PRO))
                .isInstanceOf(KovixelException.class)
                .extracting(e -> ((KovixelException) e).getStatus())
                .isEqualTo(HttpStatus.BAD_REQUEST);
    }

    private ImageConvertResult mockResult(ImageConvertFormat fmt) {
        return new ImageConvertResult(new byte[]{1}, fmt, "converted." + fmt.getDefaultExtension(),
            1000L, 500L, 100, 100, "MockEngine", 10L);
    }
}
```

---

## 13. Sécurité

### 13.1 Injection commande (ProcessBuilder)

```
RÈGLE : ne jamais interpoler de valeur utilisateur brute dans les commandes ProcessBuilder.

Les seules valeurs utilisateur dans les moteurs sont :
  - quality   : int (Spring @Min(1) @Max(100) → garanti numérique)
  - width     : Integer (Spring @Positive → garanti numérique)
  - height    : Integer (Spring @Positive → garanti numérique)
  - targetFormat : enum validé via fromString() → garanti valeur connue

Les chemins fichiers utilisent UNIQUEMENT des Path dans un tempDir UUID :
  tempDir.resolve("input." + format.getDefaultExtension())
           ↑ enum (valeur contrôlée), pas de donnée utilisateur
```

### 13.2 SSRF — Non applicable

L'outil accepte uniquement des fichiers `multipart` (pas d'URL en input). Aucune requête sortante
vers une URL fournie par l'utilisateur.

### 13.3 Pixel Bomb — couvert par `PixelBombValidator` existant

Limite max : 20 000 × 20 000 px (configurée dans `application.yml`). S'applique automatiquement
à `IMAGE_CONVERT` via `FileValidationContext.forImageConvert()`.

### 13.4 Fichiers temporaires — nettoyage garanti

```java
// Pattern obligatoire dans FfmpegConvertEngine et ImageMagickConvertEngine
Path tempDir = null;
try {
    tempDir = Files.createTempDirectory("kovixel-fc-");
    // ... traitement ...
} finally {
    cleanupTempDir(tempDir); // TOUJOURS exécuté même en cas d'exception
}
```

### 13.5 HEIC — mention légale CGU

```
Ajouter dans les CGU Kovixel :
"La conversion de fichiers HEIC/HEIF utilise des technologies soumises à des droits de propriété
intellectuelle détenus par des tiers (MPEG LA, Apple Inc.). Kovixel convertit les fichiers HEIC
uniquement vers des formats ouverts (JPEG, PNG, WebP) et ne stocke aucun fichier HEIC original."
```

### 13.6 Content-Type spoofing

La détection du format source s'appuie en **priorité 1 sur les magic bytes** (pas sur le
`Content-Type` HTTP ni l'extension du fichier) via `MagicBytesDetector`. Le Content-Type déclaré
est ignoré pour la détection du format.

---

## 14. Plan d'Implémentation Phase par Phase

### Phase 1 — Core (Semaines 1–2) — MVP Production

| Tâche | Fichier(s) | Durée |
|---|---|---|
| `ImageConvertFormat` enum + `ResizeFitMode` enum | `format/` | 0,5j |
| `ImageConvertOptions` record + `ImageConvertResult` record | `dto/` | 0,5j |
| `ImageConvertEngine` interface + `ImageConvertException` | `engine/` | 0,5j |
| `ImageConvertProperties` + section `application.yml` | `config/` | 0,5j |
| **`ImageIoConvertEngine`** (JPEG/PNG/WebP/TIFF/BMP/GIF) | `engine/` | 2j |
| **`ImageFormatRouter`** (sélection moteur + contrôle plan) | `router/` | 1j |
| **`ImageConvertService`** (sync/async dispatch) | `service/` | 1j |
| **`ImageConvertController`** + Bean Validation | `controller/` | 1j |
| Ajouter `IMAGE_CONVERT` à `JobType` + `ImageConvertStrategy` | Existant + `strategy/` | 1j |
| Étendre `FileValidationContext` + `ToolType` | Existants | 0,5j |
| `ImageStructureValidator` — Phase 1 (extensions existantes) | Existant | 0,5j |
| Tests unitaires : Engine, Router | `*Test.java` | 2j |
| Tests intégration contrôleur | `ImageConvertControllerTest.java` | 1j |
| Dockerfile : `apt-get install -y libwebp7` | `Dockerfile` | 0,5j |
| **Total Phase 1** | | **~12j** |

### Phase 2 — Formats Premium (Semaines 3–4)

| Tâche | Fichier(s) | Durée |
|---|---|---|
| Ajouter `batik-transcoder:1.17` + `batik-codec:1.17` au `pom.xml` | `pom.xml` | 0,5j |
| **`BatikConvertEngine`** (SVG → JPEG/PNG) | `engine/` | 2j |
| **`FfmpegConvertEngine`** (→ AVIF) | `engine/` | 2j |
| **`ImageMagickConvertEngine`** (HEIC → *) + `ImageMagickCommandResolver` | `engine/` + `service/` | 2j |
| `MagicBytesValidator` — signatures AVIF, HEIC, SVG | Existant | 1j |
| `ImageStructureValidator` — extensions Phase 2 | Existant | 0,5j |
| `ExifTransferService` (EXIF preservation JPEG→JPEG) | `service/` | 1j |
| `FileValidationContext` — `FileType.IMAGE_ADVANCED` | Existant | 0,5j |
| Dockerfile : `apt-get install -y ffmpeg imagemagick libheif-dev` | `Dockerfile` | 0,5j |
| Migration `V51__add_image_convert_job_index.java` | `db/migration/` | 0,5j |
| Tests Phase 2 (engines ffmpeg/ImageMagick/Batik, routes PRO) | `*Test.java` | 2j |
| **Total Phase 2** | | **~13j** |

### Phase 3 — Advanced (Semaines 5–6)

| Tâche | Fichier(s) | Durée |
|---|---|---|
| ICO output (ffmpeg multi-résolution 16/32/48/64 px) | `FfmpegConvertEngine` extension | 1j |
| GIF animé → WebP animé (ffmpeg `-vf format=rgba`) | `FfmpegConvertEngine` extension | 1j |
| Batch conversion endpoint (jusqu'à 20 fichiers → ZIP) | Nouveau endpoint `/convert/images` | 2j |
| Before/after slider Angular (CSS clip-path ou Canvas) | `image-convert.component.ts` | 2j |
| Composant Angular complet (options, preview, download) | `image-convert.component.ts` | 3j |
| Tests E2E (Playwright) — conversions principales | `e2e/` | 2j |
| **Total Phase 3** | | **~11j** |

### Récapitulatif

```
Phase 1 (Core)    : ~12 jours → MVP JPEG/PNG/WebP/TIFF/BMP/GIF, sync + async
Phase 2 (Premium) : ~13 jours → AVIF + HEIC + SVG + EXIF
Phase 3 (Advanced): ~11 jours → Batch + ICO + GIF animé + Frontend complet
─────────────────────────────────────────────────────
Total estimé      : ~36 jours ouvrés (~7 semaines)
```

---

## 15. Récapitulatif des Fichiers

### Nouveaux fichiers à créer

```
src/main/java/com/kovixel/core/conversion/imageformat/
├── config/ImageConvertProperties.java
├── controller/ImageConvertController.java
├── dto/ImageConvertOptions.java
├── dto/ImageConvertResult.java
├── engine/ImageConvertEngine.java
├── engine/ImageConvertException.java
├── engine/ImageIoConvertEngine.java          ← Phase 1
├── engine/FfmpegConvertEngine.java           ← Phase 2
├── engine/ImageMagickConvertEngine.java      ← Phase 2
├── engine/BatikConvertEngine.java            ← Phase 2
├── format/ImageConvertFormat.java
├── format/ResizeFitMode.java
├── router/ImageFormatRouter.java
├── service/ImageConvertService.java
├── service/ExifTransferService.java          ← Phase 2
├── service/ImageMagickCommandResolver.java   ← Phase 2
├── strategy/ImageConvertStrategy.java
└── util/TempFileUtils.java                   ← Phase 1 (nettoyage tempDir partagé)

src/main/resources/db/migration/
└── V51__add_image_convert_job_index.java     ← Phase 2 (optionnel)

src/test/java/com/kovixel/core/conversion/imageformat/
├── ImageIoConvertEngineTest.java
├── ImageFormatRouterTest.java
├── ImageConvertServiceTest.java
└── ImageConvertControllerTest.java
```

### Fichiers existants à modifier

```
pom.xml
  └── Phase 2 : batik-transcoder:1.17, batik-codec:1.17

src/main/resources/application.yml
  └── Ajouter section kovixel.conversion.image-convert

src/main/java/com/kovixel/processing/entity/ProcessingJob.java (ou JobType.java)
  └── Ajouter IMAGE_CONVERT à l'enum JobType

src/main/java/com/kovixel/core/validation/ImageStructureValidator.java
  └── Phase 2 : ajouter extensions avif, heic, heif, svg

src/main/java/com/kovixel/core/validation/MagicBytesValidator.java (ou MagicBytesDetector.java)
  └── Phase 2 : ajouter signatures AVIF, HEIC, SVG

src/main/java/com/kovixel/core/validation/FileValidationContext.java
  └── Ajouter factory method forImageConvert()

src/main/java/com/kovixel/common/enums/ToolType.java (ou équivalent)
  └── Ajouter IMAGE_CONVERT

Dockerfile
  └── Phase 1 : apt-get install -y libwebp7
  └── Phase 2 : apt-get install -y ffmpeg imagemagick libheif-dev
```

---

## 16. Corrections appliquées lors de la validation

Liste des 14 issues détectées et corrigées dans ce fichier :

| # | Sévérité | Section | Problème | Correction |
|---|---|---|---|---|
| 1 | 🔴 Compilation | §4.7 | `FfmpegConvertEngine` sans constructeur pour `props` | Ajout `@RequiredArgsConstructor` |
| 2 | 🔴 Compilation | §4.8 | `cleanupTempDir()` référencée mais non définie | Méthode ajoutée inline + renvoi vers `TempFileUtils` |
| 3 | 🔴 Fonctionnel | §4.13 | Bytes convertis jamais stockés en MinIO → `GET /download` sans données | Ajout appel `documentStorageService.storeJobResult()` + retour `storageKey` |
| 4 | 🔴 Runtime | §4.6 | `ImageIO.write(img,"gif",baos)` échoue sur images RGB (exige `IndexColorModel`) | Remplacement par `encodeGif()` via Thumbnailator |
| 5 | 🔴 Implémentation | §10.2 | Chemin Flyway Java : `src/main/resources/…V51.java` → invalide | Corrigé en `src/main/java/com/kovixel/db/migration/` |
| 6 | 🟠 Runtime | §4.8 | `waitFor()` sans timeout → blocage démarrage si ImageMagick absent | Remplacé par `process.waitFor(5, TimeUnit.SECONDS)` |
| 7 | 🟠 UI | §11.3 | `responseType:'blob'` bloque parsing JSON de la réponse 202 | Ajout `handleConvertResponse()` avec lecture `blob.text()` |
| 8 | 🟠 Runtime | §4.13 | Records Java non désérialisés par Jackson sans flag `-parameters` | Ajout `@JsonProperty` sur champs de `ConvertJobInput` + note |
| 9 | 🟠 Correction | §4.6 | TIFF listée comme "sans alpha" — TwelveMonkeys supporte RGBA TIFF | TIFF ajouté à `targetSupportsAlpha = true` |
| 10 | 🟠 CORS | §11 | Headers `X-*` non exposés → `response.headers.get()` retourne null | Ajout §11.5 avec `config.setExposedHeaders(...)` |
| 11 | 🟡 Robustesse | §4.6 | `ImageIO.write()` retourne `boolean` ignoré | Check ajouté pour PNG et BMP |
| 12 | 🟡 Runtime | §4.7 | `libsvtav1` hardcodé, pas de fallback `libaom-av1` | Ajout `avifEncoderSvt` dans properties + logic conditionnelle |
| 13 | 🟡 Faux positif | §5.2 | `isSvg()` matche `<?xml` dans EXIF JPEG | Resserré à `<svg` ou `<?xml` + `svg` combinés, note d'ordre |
| 14 | 🟡 Format | §8.2 | XML `<dependency>` dans bloc code `java` | Extrait dans bloc `xml` séparé |
