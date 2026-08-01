# Roadmap OCR — Extraction de texte intelligente — Kovixel

> **Statut :** Proposition technique v1.0  
> **Auteur :** Architecture Kovixel  
> **Date :** 2026-06-19  
> **Audience :** Équipe backend, équipe produit, direction

---

## Table des matières

1. [Préambule & vision](#1-préambule--vision)
2. [État des lieux](#2-état-des-lieux)
3. [Ce qu'est un OCR de qualité en 2026](#3-ce-quest-un-ocr-de-qualité-en-2026)
4. [Architecture technique](#4-architecture-technique)
5. [Schéma de données](#5-schéma-de-données)
6. [Roadmap par sprints](#6-roadmap-par-sprints)
7. [Migrations Flyway](#7-migrations-flyway)
8. [Décisions d'architecture (ADR)](#8-décisions-darchitecture-adr)
9. [Risques et mitigations](#9-risques-et-mitigations)
10. [KPIs qualité](#10-kpis-qualité)
11. [Glossaire](#11-glossaire)

---

## 1. Préambule & vision

Un document PDF peut contenir deux types de contenu radicalement différents : du **texte natif** (sélectionnable, copiable, indexable) ou des **images** de texte (photos, numérisations, fax, photos de documents papier). Aujourd'hui, tous les outils IA de Kovixel — Résumé, Q&A, Extraction, Traduction — reçoivent le texte via `PdfExtractor.extract()` qui utilise PDFBox. Sur un PDF scanné, PDFBox retourne une chaîne vide ou quelques caractères parasites. L'outil échoue silencieusement, ou produit un résultat sans valeur.

**L'OCR est la couche fondatrice manquante.** Sans elle, Kovixel est inutilisable pour :
- Les contrats papier numérisés
- Les factures reçues par fax ou scan
- Les formulaires administratifs
- Les articles de presse scannés
- Les notes manuscrites photographiées
- Tout document venant d'un scanner ou d'un appareil photo

**Vision de cet outil :** Kovixel doit extraire du texte de haute qualité depuis n'importe quel document, quelle que soit son origine. Le résultat doit être directement exploitable — sans correction manuelle — par les outils IA aval et par l'utilisateur.

**Le différenciateur de qualité :** La chaîne OCR de Kovixel ne s'arrête pas à Tesseract. Elle combine prétraitement d'image, reconnaissance optique, et nettoyage par LLM pour produire un texte structuré (Markdown), avec un score de confiance par page, et un export en PDF interrogeable (texte invisible superposé sur l'image originale).

---

## 2. État des lieux

### 2.1 Ce qui existe déjà et peut être réutilisé

| Composant existant | Rôle actuel | Réutilisation pour OCR |
|-------------------|-------------|------------------------|
| `PdfExtractor.java` | Extrait texte PDFBox + classifie le PDF | ✅ `classify()` détecte déjà `IMAGE_ONLY` vs `TEXT_EXTRACTABLE` |
| `PdfContentType` enum | `TEXT_EXTRACTABLE`, `IMAGE_ONLY`, `EMPTY`, `ENCRYPTED` | ✅ Réutilisé tel quel comme point d'entrée du routing |
| `ProcessingStrategy` interface | Polymorphisme des traitements | ✅ `OcrStrategy implements ProcessingStrategy` |
| `ProcessingOrchestrator` | Gère le pipeline async | ✅ Routing automatique vers `OcrStrategy` via `JobType.OCR` |
| `AiRoutingService` | Résout provider/modèle selon plan et mode | ✅ Utilisé pour LLM post-processing (Ollama FREE / Claude PRO) |
| Pool `processingExecutor` | 4–8 threads async | ✅ OCR naturellement async, s'intègre directement |
| `FileStorageService` | Stocke/récupère fichiers binaires | ✅ Stocke les outputs OCR (TXT, MD, PDF searchable, DOCX) |
| `QuotaService` | Vérifie/incrémente quota par `FeatureType` | ✅ Ajouter `FeatureType.OCR`, définir limites par plan |
| `UsageRecord` | Trace coût et performance de chaque opération | ✅ Enregistrer les pages OCR traitées et temps de traitement |
| Spring AI (Anthropic, Ollama) | Providers LLM configurés | ✅ Utilisé pour le nettoyage LLM du texte extrait |
| `twelvemonkeys.imageio` | Support TIFF, WEBP, BMP | ✅ Formats d'image variés lors de la rasterisation |
| `pdfbox` 3.0.7 | Manipulation PDF | ✅ `PDFRenderer` pour rasteriser, `PDPageContentStream` pour overlay texte |

### 2.2 Ce qui manque (à construire intégralement)

| Composant | Description |
|-----------|-------------|
| `PdfPageRasterizer` | Convertit chaque page PDF en `BufferedImage` à 300 DPI |
| `ImagePreprocessor` | Améliore la qualité de l'image avant OCR (gris, binarisation, débruitage) |
| `OcrEngine` (interface) | Abstraction pour Tesseract ou Vision Cloud |
| `TesseractOcrEngine` | Moteur local via Tess4J 5.x |
| `CloudVisionOcrEngine` | Moteur cloud via Claude Vision (PRO/CLOUD mode) |
| `OcrTextEnhancer` | Nettoyage et structuration du texte brut par LLM |
| `OcrOutputService` | Génère TXT, Markdown, PDF searchable, DOCX |
| `OcrSearchablePdfBuilder` | Superpose une couche de texte invisible sur le PDF original |
| `OcrStrategy` | Implémentation `ProcessingStrategy` pour `JobType.OCR` |
| `OcrController` | `POST /api/v1/extract/text` |
| Composant Angular `OcrComponent` | Interface utilisateur de l'outil |
| Migration `V32__create_ocr_results.sql` | Table de résultats OCR |
| Migration `V33__add_ocr_plan_limits.sql` | Quotas pages OCR par plan |

### 2.3 Lacune critique identifiée par le code existant

```java
// PdfExtractor.java — comportement actuel sur un PDF scanné :
public String extract(byte[] fileBytes) {
    try (PDDocument document = Loader.loadPDF(fileBytes)) {
        PDFTextStripper stripper = new PDFTextStripper();
        String text = stripper.getText(document);
        text = text.replace("", "");
        return text;  // → "" pour un PDF scanné
    }
}
```

Un PDF scanné retourne une chaîne vide. `SummaryStrategy` l'envoie au LLM avec un prompt sur texte vide → le résumé répond "Le document ne contient pas de texte lisible." L'utilisateur ne comprend pas pourquoi son document "ne fonctionne pas".

Avec cet outil, ce cas sera détecté automatiquement avant même d'appeler la stratégie IA, et l'OCR sera déclenché en transparence.

---

## 3. Ce qu'est un OCR de qualité en 2026

### 3.1 L'erreur commune : OCR = Tesseract

Tesseract 5 (moteur LSTM) est excellent sur des images propres. Sur des scans réels — légèrement inclinés, avec bruit de fond, faible contraste, texte petit — le résultat brut est souvent inutilisable directement :

```
Tesseract brut :    "Ar-ticle 3.1 - Le vendeur s' eng age à livr er les biens"
Attendu :          "Article 3.1 - Le vendeur s'engage à livrer les biens"
```

Un outil "hautement qualitatif" ne peut pas s'arrêter à la sortie brute de Tesseract.

### 3.2 Le pipeline en 4 couches

```
┌──────────────────────────────────────────────────────────────────┐
│  Couche 1 — Classification                                        │
│  PdfExtractor.classify() → TEXT_EXTRACTABLE | IMAGE_ONLY | MIXED │
│  Si TEXT_EXTRACTABLE : sortie directe PDFBox (pas d'OCR)          │
└────────────────────┬─────────────────────────────────────────────┘
                     │ (pages IMAGE_ONLY seulement)
┌────────────────────▼─────────────────────────────────────────────┐
│  Couche 2 — Prétraitement image                                   │
│  PDFRenderer 300 DPI → grayscale → binarisation Otsu              │
│  → débruitage médian → redressement (Tesseract auto-deskew)       │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────┐
│  Couche 3 — Reconnaissance optique                                │
│  LOCAL  : TesseractOcrEngine → texte + HOCR (positions mots)      │
│  CLOUD  : CloudVisionOcrEngine → Claude Vision (multimodal)        │
└────────────────────┬─────────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────────┐
│  Couche 4 — Post-traitement LLM                                   │
│  Ollama (FREE) ou Claude Haiku (PRO) :                            │
│  → Corriger erreurs OCR contextuelles                             │
│  → Reconstruire la structure (titres, listes, tableaux)           │
│  → Sortie Markdown propre                                         │
└──────────────────────────────────────────────────────────────────┘
```

### 3.3 Pourquoi la Couche 4 change tout

Un LLM peut raisonner sur le contexte pour corriger des erreurs qu'un simple correcteur orthographique ne voit pas :

| Erreur Tesseract | Correction LLM |
|-----------------|----------------|
| `"s' eng age"` | `"s'engage"` — contexte légal |
| `"I0 000 €"` | `"10 000 €"` — chiffre 0 vs lettre O |
| `"M. Dupont Pierre"` | `"M. Pierre Dupont"` — prénom/nom inversé fréquent en scan |
| `"Art. 3.l"` | `"Art. 3.1"` — L minuscule vs chiffre 1 |
| Fragment de tableau | Tableau Markdown reconstruit |

**Coût du post-traitement LLM :**
- Ollama Qwen 7B local (FREE) : ~0€, latence +2–5s par page
- Claude Haiku (PRO, `claude-haiku-4-5`) : ~$0.003 par page, latence +1–2s

### 3.4 Outputs attendus

| Format | Cas d'usage | Comment |
|--------|-------------|---------|
| **Texte brut (.txt)** | Copier-coller rapide, import dans autre outil | Concaténation du texte de toutes les pages |
| **Markdown (.md)** | Lecture structurée, import Notion/Obsidian | Titres, listes, tableaux reconstruits par LLM |
| **PDF interrogeable (.pdf)** | Recherche dans le document original, archivage | Couche de texte invisible superposée sur le PDF original via HOCR |
| **Word (.docx)** | Édition dans Microsoft Word | Conversion du Markdown → DOCX via pipeline existant |

Le **PDF interrogeable** est l'output le plus demandé professionnellement. Le document conserve son apparence visuelle exacte, mais le texte devient sélectionnable, copiable, et indexable par les moteurs de recherche.

---

## 4. Architecture technique

### 4.1 Vue d'ensemble

```
POST /api/v1/extract/text
          │
          ▼
    OcrController
    ├── Quota check (FeatureType.OCR, pages-based)
    ├── Créer ProcessingJob (JobType.OCR)
    └── ProcessingService.submitAsync()
                │
                ▼ (async, processingExecutor)
    ProcessingOrchestrator
    └── OcrStrategy.process(fileBytes, userId, options)
                │
                ├── PdfExtractor.classifyPerPage(bytes)
                │   → Map<Integer, PdfContentType> (page → type)
                │
                ├── Pour pages TEXT_EXTRACTABLE :
                │   └── PDFTextStripper → text direct
                │
                ├── Pour pages IMAGE_ONLY :
                │   ├── PdfPageRasterizer.rasterize(page, 300dpi)
                │   ├── ImagePreprocessor.enhance(image)
                │   └── OcrEngine.recognize(image, language)
                │       ├── TesseractOcrEngine (LOCAL/FREE)
                │       └── CloudVisionOcrEngine (CLOUD/PRO)
                │
                ├── OcrTextEnhancer.enhance(rawText, userId)
                │   ├── LlmOcrEnhancer via Ollama (FREE)
                │   └── LlmOcrEnhancer via Claude Haiku (PRO)
                │
                ├── OcrOutputService.generate(enhancedText, hocr, originalPdf)
                │   ├── TxtExporter → /ocr/{docId}/result.txt
                │   ├── MarkdownExporter → /ocr/{docId}/result.md
                │   ├── SearchablePdfBuilder → /ocr/{docId}/searchable.pdf
                │   └── DocxExporter → via ConversionPipeline existant
                │
                └── OcrResultRepository.save(OcrResult)
                    + UsageRecord.save()
                    + Job COMPLETED
```

### 4.2 Composants détaillés

#### `PdfPageRasterizer.java`

Rasterise chaque page PDF en `BufferedImage` à 300 DPI (seuil minimum pour un OCR de qualité) :

```java
@Component
public class PdfPageRasterizer {

    public static final int DEFAULT_DPI = 300;
    public static final int HIGH_DPI    = 600;  // Pour petits textes, documents techniques

    public List<RasterizedPage> rasterize(byte[] pdfBytes, int dpi) throws IOException {
        try (PDDocument doc = Loader.loadPDF(pdfBytes)) {
            PDFRenderer renderer = new PDFRenderer(doc);
            List<RasterizedPage> pages = new ArrayList<>(doc.getNumberOfPages());
            for (int i = 0; i < doc.getNumberOfPages(); i++) {
                BufferedImage image = renderer.renderImageWithDPI(i, dpi, ImageType.GRAY);
                pages.add(new RasterizedPage(i, image, dpi));
            }
            return pages;
        }
    }

    public record RasterizedPage(int pageIndex, BufferedImage image, int dpi) {}
}
```

**Calcul mémoire :** une page A4 à 300 DPI en niveaux de gris = 2480 × 3508 × 1 octet ≈ **8,7 MB**. Pour un document de 20 pages : ~174 MB. Le traitement page par page (pas en parallèle sans limite) est obligatoire.

#### `ImagePreprocessor.java`

Améliorations appliquées en Java2D pur (aucune dépendance native supplémentaire) :

```java
@Component
public class ImagePreprocessor {

    public BufferedImage enhance(BufferedImage input) {
        BufferedImage gray = toGrayscale(input);
        BufferedImage enhanced = enhanceContrast(gray);
        return binarize(enhanced);
    }

    private BufferedImage toGrayscale(BufferedImage src) {
        // Conversion RGB → niveaux de gris si l'image est en couleur
        if (src.getType() == BufferedImage.TYPE_BYTE_GRAY) return src;
        BufferedImage gray = new BufferedImage(src.getWidth(), src.getHeight(), TYPE_BYTE_GRAY);
        Graphics2D g = gray.createGraphics();
        g.drawImage(src, 0, 0, null);
        g.dispose();
        return gray;
    }

    private BufferedImage enhanceContrast(BufferedImage gray) {
        // Étirement de l'histogramme : améliore le contraste des scans sous-exposés
        // Opération sur les valeurs de pixels : (pixel - min) * 255 / (max - min)
        ...
    }

    private BufferedImage binarize(BufferedImage gray) {
        // Seuillage adaptatif (Otsu) : convertit en noir et blanc
        // Meilleure séparation texte/fond que le seuil fixe
        // Résultat : BufferedImage TYPE_BYTE_BINARY
        ...
    }
}
```

**Note sur le redressement (deskew) :** Tesseract 5 dispose d'un module OSD (Orientation and Script Detection) natif qui détecte et corrige automatiquement l'inclinaison jusqu'à ±5°. La majorité des scans tombe dans cette plage. On ne duplique pas cette logique en Java.

#### `OcrEngine.java` — interface d'abstraction

```java
public interface OcrEngine {
    OcrPageResult recognize(BufferedImage image, String languageHint, int pageIndex);
}

public record OcrPageResult(
    int     pageIndex,
    String  rawText,      // Texte brut reconnu
    String  hocrContent,  // Format HOCR XML (positions des mots pour PDF searchable)
    float   confidence,   // Score moyen de confiance (0.0 → 100.0)
    String  detectedLanguage
) {}
```

#### `TesseractOcrEngine.java` — moteur local

**Dépendance :** `net.sourceforge.tess4j:tess4j:5.11.0`

```java
@Component
@ConditionalOnProperty(name = "kovixel.ocr.engine", havingValue = "tesseract", matchIfMissing = true)
public class TesseractOcrEngine implements OcrEngine {

    private final TesseractProperties props;

    @Override
    public OcrPageResult recognize(BufferedImage image, String languageHint, int pageIndex) {
        Tesseract tesseract = new Tesseract();
        tesseract.setDatapath(props.getTessdataPath());  // /usr/share/tessdata ou classpath
        tesseract.setLanguage(resolveLanguage(languageHint)); // "fra+eng" si auto
        tesseract.setOcrEngineMode(OcrEngineMode.LSTM_ONLY);  // Tesseract 5 LSTM
        tesseract.setPageSegMode(PageSegMode.AUTO_OSD);        // Détection orientation + colonnes
        tesseract.setVariable("tessedit_create_hocr", "1");    // Activer sortie HOCR

        String rawText = tesseract.doOCR(image);
        String hocr    = tesseract.doOCR(image, new File(props.getTessdataPath()),
                                          ITessAPI.TessPageIteratorLevel.RIL_WORD);

        float confidence = computeAverageConfidence(tesseract, image);

        return new OcrPageResult(pageIndex, rawText, hocr, confidence, detectedLanguage(tesseract));
    }

    private String resolveLanguage(String hint) {
        // "auto"  → "fra+eng+deu+spa+por+ita" (langues européennes courantes)
        // "fr"    → "fra"
        // "en"    → "eng"
        // "zh"    → "chi_sim" (chinois simplifié)
        return LANGUAGE_MAP.getOrDefault(hint, "fra+eng");
    }
}
```

**Langues Tesseract packagées dans le Docker :**  
`fra eng deu spa por ita ara chi_sim jpn rus` — couvre ~95% des cas d'usage.

#### `CloudVisionOcrEngine.java` — moteur cloud PRO

Utilise **Claude Vision** (API Anthropic multimodale via Spring AI), déjà intégré dans Kovixel :

```java
@Component
@ConditionalOnProperty(name = "kovixel.ocr.engine", havingValue = "cloud")
public class CloudVisionOcrEngine implements OcrEngine {

    private final ChatClient claudeClient;  // Spring AI, déjà configuré

    @Override
    public OcrPageResult recognize(BufferedImage image, String languageHint, int pageIndex) {
        byte[] imageBytes = toJpegBytes(image);
        Media media = new Media(MimeTypeUtils.IMAGE_JPEG, imageBytes);

        String prompt = """
            Transcris fidèlement tout le texte visible dans cette image de document.
            Instructions :
            - Conserve la structure exacte : titres, paragraphes, listes, tableaux
            - Format de sortie : Markdown
            - Ne corrige PAS le contenu, transcris ce qui est écrit
            - Si une partie est illisible, indique [ILLISIBLE]
            - Langue attendue : %s
            """.formatted(languageHint);

        String markdownText = claudeClient.prompt()
            .user(u -> u.text(prompt).media(media))
            .call()
            .content();

        // Claude Vision produit directement du Markdown structuré (pas de HOCR)
        // → PDF searchable non disponible dans ce mode (overlay approximatif uniquement)
        return new OcrPageResult(pageIndex, markdownText, null, 95.0f, languageHint);
    }
}
```

**Avantage de Claude Vision :** comprend la sémantique du document. Un tableau dans un scan n'est pas transcrit comme du texte brut mais reconstruit en tableau Markdown. Un titre est formaté `## Titre`. Le résultat est directement exploitable sans post-traitement LLM supplémentaire.

**Coût estimé :** ~$0.003–0.005 par page A4 (claude-haiku-4-5, ~1 200 tokens input image + 800 tokens output).

#### `OcrTextEnhancer.java` — nettoyage LLM

Appliqué uniquement sur le résultat de **TesseractOcrEngine** (Claude Vision produit déjà du Markdown propre) :

```java
@Component
public class OcrTextEnhancer {

    private final AiRoutingService aiRoutingService;

    private static final String ENHANCEMENT_PROMPT = """
        Le texte suivant a été extrait par OCR depuis un document scanné.
        Il peut contenir des erreurs de reconnaissance (lettres confondues, mots coupés, accents manquants).

        Tâches :
        1. Corrige les erreurs OCR évidentes en utilisant le contexte
        2. Reconstruis la structure du document (titres en ## ou ###, listes en -, tableaux en Markdown)
        3. Ne modifie PAS le sens ni le contenu — transcription fidèle uniquement
        4. Si une phrase est manifestement incomplète ou illisible, conserve-la entre [ILLISIBLE : ...]

        Texte à corriger :
        ---
        %s
        ---
        Retourne uniquement le texte corrigé en Markdown, sans commentaire.
        """;

    public String enhance(String rawOcrText, Long userId) {
        if (rawOcrText == null || rawOcrText.isBlank()) return rawOcrText;

        AiRoutingDecision decision = aiRoutingService.resolve(userId);
        String prompt = ENHANCEMENT_PROMPT.formatted(rawOcrText);

        return decision.provider().generate(prompt);
    }
}
```

#### `OcrSearchablePdfBuilder.java` — PDF interrogeable

Superpose une couche de texte invisible sur le PDF original en utilisant les positions HOCR :

```java
@Component
public class OcrSearchablePdfBuilder {

    public byte[] build(byte[] originalPdfBytes, List<OcrPageResult> pageResults) throws IOException {
        try (PDDocument doc = Loader.loadPDF(originalPdfBytes);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {

            for (OcrPageResult pageResult : pageResults) {
                if (pageResult.hocrContent() == null) continue;

                PDPage page = doc.getPage(pageResult.pageIndex());
                PDRectangle mediaBox = page.getMediaBox();

                List<HocrWord> words = HocrParser.parse(pageResult.hocrContent());

                try (PDPageContentStream cs = new PDPageContentStream(
                        doc, page, PDPageContentStream.AppendMode.APPEND, true, true)) {

                    cs.beginText();
                    cs.setFont(PDType1Font.HELVETICA, 1f);
                    cs.setTextRenderingMode(TextRenderingMode.NEITHER);  // Texte INVISIBLE

                    for (HocrWord word : words) {
                        // Conversion coordonnées image → coordonnées PDF
                        float pdfX = word.x() * mediaBox.getWidth()  / pageResult.imageWidth();
                        float pdfY = mediaBox.getHeight() - (word.y() * mediaBox.getHeight() / pageResult.imageHeight());
                        float fontSize = word.height() * mediaBox.getHeight() / pageResult.imageHeight();

                        cs.setTextMatrix(Matrix.getTranslateInstance(pdfX, pdfY));
                        cs.showText(word.text());
                    }

                    cs.endText();
                }
            }

            doc.save(out);
            return out.toByteArray();
        }
    }
}
```

Le PDF résultant est **visuellement identique** à l'original mais chaque mot est cliquable, sélectionnable, et indexé par les moteurs de recherche.

#### `OcrStrategy.java` — intégration dans l'orchestrateur

```java
@Component
public class OcrStrategy implements ProcessingStrategy {

    private final PdfExtractor         pdfExtractor;
    private final PdfPageRasterizer    rasterizer;
    private final ImagePreprocessor    preprocessor;
    private final OcrEngine            ocrEngine;          // Injecté selon mode LOCAL/CLOUD
    private final OcrTextEnhancer      textEnhancer;
    private final OcrOutputService     outputService;
    private final OcrResultRepository  resultRepo;

    @Override
    public JobType getSupportedType() { return JobType.OCR; }

    @Override
    public String process(byte[] fileBytes, Long userId, Map<String, String> options) {

        String languageHint = options.getOrDefault("language", "auto");
        boolean enhance     = !"false".equals(options.get("enhance"));  // LLM cleanup activé par défaut
        String outputFormat = options.getOrDefault("format", "markdown");

        // 1. Classification page par page
        Map<Integer, PdfContentType> pageTypes = pdfExtractor.classifyPerPage(fileBytes);
        int pageCount = pageTypes.size();

        List<OcrPageResult> allResults = new ArrayList<>(pageCount);
        StringBuilder fullRawText = new StringBuilder();

        // 2. Traitement page par page
        List<RasterizedPage> rasterized = rasterizer.rasterize(fileBytes, DEFAULT_DPI);

        for (Map.Entry<Integer, PdfContentType> entry : pageTypes.entrySet()) {
            int pageIdx = entry.getKey();
            PdfContentType type = entry.getValue();

            if (type == TEXT_EXTRACTABLE) {
                // Extraction directe PDFBox, pas d'OCR
                String pageText = pdfExtractor.extractPage(fileBytes, pageIdx);
                allResults.add(new OcrPageResult(pageIdx, pageText, null, 100.0f, "native"));
                fullRawText.append(pageText).append("\n\n");

            } else if (type == IMAGE_ONLY) {
                // OCR nécessaire
                BufferedImage enhanced = preprocessor.enhance(rasterized.get(pageIdx).image());
                OcrPageResult result = ocrEngine.recognize(enhanced, languageHint, pageIdx);
                allResults.add(result);
                fullRawText.append(result.rawText()).append("\n\n");

            } else if (type == ENCRYPTED) {
                throw new DocumentEncryptedException("Page " + pageIdx + " chiffrée — mot de passe requis");
            }
            // EMPTY → skip
        }

        // 3. Post-traitement LLM (si activé et si du texte Tesseract brut est présent)
        String finalText = fullRawText.toString();
        boolean hasLlmEnhancement = false;
        if (enhance && containsTesseractOutput(allResults)) {
            finalText = textEnhancer.enhance(finalText, userId);
            hasLlmEnhancement = true;
        }

        // 4. Génération des outputs
        OcrOutputs outputs = outputService.generate(finalText, allResults, fileBytes, outputFormat);

        // 5. Calcul métriques qualité
        float avgConfidence = computeAvgConfidence(allResults);
        List<Integer> lowConfPages = findLowConfidencePages(allResults, 70.0f);

        // 6. Persistance
        OcrResult ocrResult = OcrResult.builder()
            .documentId(documentId).userId(userId)
            .pageCount(pageCount)
            .contentType(determineGlobalType(pageTypes))
            .rawText(fullRawText.toString())
            .enhancedText(finalText)
            .avgConfidence(avgConfidence)
            .pageConfidences(buildPageConfidences(allResults))
            .lowConfidencePages(lowConfPages)
            .llmEnhanced(hasLlmEnhancement)
            .txtKey(outputs.txtKey()).markdownKey(outputs.markdownKey())
            .searchablePdfKey(outputs.searchablePdfKey()).docxKey(outputs.docxKey())
            .ocrEngine(ocrEngine.getEngineName())
            .build();

        resultRepo.save(ocrResult);
        return finalText;  // Retourné dans le ProcessedResult pour affichage frontend
    }
}
```

### 4.3 Routing LOCAL vs CLOUD

Le choix du moteur OCR suit le même modèle que le routing IA existant :

| Plan | Mode utilisateur | Moteur OCR | Post-processing LLM | Qualité |
|------|-----------------|------------|---------------------|---------|
| FREE | LOCAL (forcé) | Tesseract 5 LSTM | Ollama Qwen 7B | Bonne |
| PRO | LOCAL | Tesseract 5 LSTM | Claude Haiku | Très bonne |
| PRO | CLOUD | Claude Vision | Inclus dans Vision | Excellente |
| ENTERPRISE | CLOUD | Claude Vision | Inclus dans Vision | Excellente |

**Note sur les utilisateurs anonymes :** pas d'OCR anonyme. L'OCR est une opération coûteuse (CPU intensive ou API call). Quota uniquement pour les comptes enregistrés.

### 4.4 Gestion mémoire et async

**Règle :** TOUS les jobs OCR sont asynchrones, quelle que soit la taille du fichier.

Raison : l'OCR d'une seule page peut prendre 1–5 secondes selon la complexité. Un document de 10 pages = 10–50 secondes. Il n'y a pas de "petit fichier OCR rapide" comparable à une conversion synchrone.

Le polling existant (`GET /api/v1/processing/{jobId}`) est réutilisé tel quel. Un champ `progressPct` et `currentPage` sont ajoutés au `ProcessingJob` pour permettre une barre de progression côté frontend.

```java
// Mise à jour de progression dans OcrStrategy.process()
for (int pageIdx : pageTypes.keySet()) {
    // ... traitement page ...
    int pct = (pageIdx + 1) * 100 / pageCount;
    jobRepository.updateProgress(jobId, pct, pageIdx + 1, pageCount);
}
```

---

## 5. Schéma de données

### 5.1 Table `ocr_results`

```sql
CREATE TABLE ocr_results (
    id                  BIGSERIAL       PRIMARY KEY,
    document_id         BIGINT          NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    user_id             BIGINT          REFERENCES kovixel_users(id) ON DELETE SET NULL,

    -- Métadonnées du document source
    page_count          INT             NOT NULL,
    detected_language   VARCHAR(20),                   -- 'fra', 'eng', 'fra+eng', 'auto'
    content_type        VARCHAR(20)     NOT NULL,       -- TEXT_EXTRACTABLE, IMAGE_ONLY, MIXED

    -- Résultats texte
    raw_text            TEXT,                           -- Sortie brute Tesseract (avant LLM)
    enhanced_text       TEXT,                           -- Texte nettoyé par LLM (si applicable)

    -- Qualité OCR
    avg_confidence      DECIMAL(5,2),                  -- Score moyen (0.00 → 100.00)
    page_confidences    JSONB,                          -- [{"page":0,"confidence":87.3}, ...]
    low_confidence_pages INT[]          DEFAULT '{}',  -- Pages avec score < seuil (70%)

    -- Clés des fichiers générés dans le storage
    txt_key             VARCHAR(255),
    markdown_key        VARCHAR(255),
    searchable_pdf_key  VARCHAR(255),
    docx_key            VARCHAR(255),

    -- Métadonnées de traitement
    ocr_engine          VARCHAR(20)     NOT NULL,       -- TESSERACT, CLOUD_VISION
    llm_enhanced        BOOLEAN         NOT NULL DEFAULT FALSE,
    processing_ms       BIGINT,

    created_at          TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ocr_document_id  ON ocr_results (document_id);
CREATE INDEX idx_ocr_user_id      ON ocr_results (user_id, created_at DESC);
CREATE INDEX idx_ocr_confidence   ON ocr_results (avg_confidence) WHERE avg_confidence < 70;
```

### 5.2 Extension `ProcessingJob` pour la progression

```sql
-- V33__add_ocr_progress_to_processing_jobs.sql
ALTER TABLE processing_jobs
    ADD COLUMN progress_pct    INT     DEFAULT 0,
    ADD COLUMN current_page    INT     DEFAULT 0,
    ADD COLUMN total_pages     INT     DEFAULT 0;

COMMENT ON COLUMN processing_jobs.progress_pct   IS 'Pourcentage d''avancement du job (0-100)';
COMMENT ON COLUMN processing_jobs.current_page   IS 'Numéro de la page en cours de traitement';
COMMENT ON COLUMN processing_jobs.total_pages    IS 'Nombre total de pages à traiter';
```

---

## 6. Roadmap par sprints

### Vue d'ensemble

```
Sprint O-1  ████████████████  Fondations OCR (rasterizer, preprocessor, Tesseract)   2 semaines
Sprint O-2  ████████████      LLM post-processing & qualité                           1.5 semaine
Sprint O-3  ████████          Formats de sortie (TXT, MD, PDF searchable, DOCX)       1 semaine
Sprint O-4  ████████          Cloud Vision route (PRO/CLOUD) + Claude Vision          1 semaine
Sprint O-5  ████████          Intégration Kovixel (Strategy, Controller, Quotas)      1 semaine
Sprint O-6  ████████████      Frontend Angular (composant, UI, progression)           1.5 semaine
Sprint O-7  ████████          Hardening, tests, Dockerfile, documentation             1 semaine

Total estimation : ~9 semaines
```

---

### Sprint O-1 — Fondations OCR (2 semaines)

**Objectif :** Construire le pipeline technique de base — rasterisation, prétraitement, Tesseract — et valider la qualité sur des cas réels avant d'aller plus loin.

**Pourquoi en premier :** Valider la qualité du pipeline OCR brut est la précondition de tout le reste. Si Tesseract + prétraitement ne donnent pas des résultats acceptables (>75% de confiance sur des scans standards), il faut revoir les paramètres avant de construire les couches supérieures.

#### Tâches

**O-1.1 — Dépendance Tess4J**

Dans `pom.xml` :
```xml
<dependency>
    <groupId>net.sourceforge.tess4j</groupId>
    <artifactId>tess4j</artifactId>
    <version>5.11.0</version>
</dependency>
```

Tess4J 5.x encapsule Tesseract 5 via JNA (Java Native Access). La bibliothèque native Tesseract doit être installée dans le conteneur Docker.

**O-1.2 — Dockerfile — ajout Tesseract**

```dockerfile
# Dans le Dockerfile Kovixel backend
RUN apt-get update && apt-get install -y \
    tesseract-ocr \
    tesseract-ocr-fra \
    tesseract-ocr-eng \
    tesseract-ocr-deu \
    tesseract-ocr-spa \
    tesseract-ocr-por \
    tesseract-ocr-ita \
    tesseract-ocr-ara \
    tesseract-ocr-chi-sim \
    tesseract-ocr-jpn \
    tesseract-ocr-rus \
    && rm -rf /var/lib/apt/lists/*

# Vérification : tesseract --version → 5.x.x
```

Configuration dans `application.yml` :
```yaml
kovixel:
  ocr:
    engine: tesseract                    # tesseract | cloud
    tesseract:
      datapath: /usr/share/tessdata     # Chemin données langue Tesseract
      default-language: fra+eng         # Langues par défaut
      dpi: 300                          # DPI de rasterisation
      confidence-threshold: 70.0        # Seuil confidence pour alerte page
    max-file-size-mb: 50               # Taille max fichier (> 50 MB → refus)
    max-pages: 200                     # Pages max par job
    async-threshold-pages: 1           # Tous les OCR sont async (= 1 page suffit)
```

**O-1.3 — `PdfPageRasterizer.java`**

Nouveau composant : `com.kovixel.ocr.rasterizer.PdfPageRasterizer`

Responsabilités :
- `rasterize(byte[] pdfBytes, int dpi) → List<RasterizedPage>`
- `rasterizePage(byte[] pdfBytes, int pageIndex, int dpi) → RasterizedPage`
- Gestion mémoire : libérer `BufferedImage` après traitement via try-with-resources pattern

Tests :
- PDF 1 page → 1 `RasterizedPage` avec dimensions cohérentes
- PDF 10 pages → 10 `RasterizedPage`
- PDF chiffré → `DocumentEncryptedException`

**O-1.4 — `ImagePreprocessor.java`**

Nouveau composant : `com.kovixel.ocr.preprocessing.ImagePreprocessor`

Responsabilités :
- `enhance(BufferedImage) → BufferedImage`
- `toGrayscale(BufferedImage) → BufferedImage`
- `enhanceContrast(BufferedImage) → BufferedImage` (étirement histogramme)
- `binarize(BufferedImage) → BufferedImage` (seuillage Otsu simplifié)

Test de qualité : prendre un scan réel, comparer le texte Tesseract avant/après prétraitement. L'objectif est d'augmenter le score de confiance d'au moins 10 points sur un scan de qualité moyenne.

**O-1.5 — `TesseractOcrEngine.java`**

Nouveau composant : `com.kovixel.ocr.engine.TesseractOcrEngine`

Modes à tester :
- `OcrEngineMode.LSTM_ONLY` (Tesseract 5 — recommandé)
- `PageSegMode.AUTO_OSD` (détection automatique orientation + segmentation colonnes)
- Sortie HOCR activée pour le PDF searchable

**O-1.6 — Extension `PdfExtractor.classifyPerPage()`**

Améliorer la classification pour qu'elle opère **page par page** (pas uniquement au niveau document) :

```java
// Existant : classify(byte[]) → PdfContentType (document entier)
// À ajouter :
public Map<Integer, PdfContentType> classifyPerPage(byte[] pdfBytes) {
    // Pour chaque page : extraire texte, compter chars
    // < 50 chars ET présence d'images embarquées → IMAGE_ONLY
    // >= 50 chars → TEXT_EXTRACTABLE
    // Résultat : { 0: TEXT_EXTRACTABLE, 1: IMAGE_ONLY, 2: IMAGE_ONLY, ... }
}

public String extractPage(byte[] pdfBytes, int pageIndex) {
    // Extraction PDFBox sur une seule page (déjà possible avec setStartPage/setEndPage)
}
```

Permet de traiter les **PDFs mixtes** (certaines pages avec texte natif, d'autres scannées) sans OCR-iser ce qui n'en a pas besoin.

**O-1.7 — Tests de validation qualité (critiques)**

Créer un dossier `src/test/resources/ocr-samples/` avec :
- `scan-simple-fr.pdf` — document français clair
- `scan-incline-3deg.pdf` — scan légèrement incliné
- `scan-faible-contraste.pdf` — scan de mauvaise qualité
- `mixed-pdf.pdf` — 3 pages texte natif + 2 pages scannées

Métriques attendues :
- Confidence moyenne > 80% sur `scan-simple-fr.pdf`
- Texte extrait contient > 90% des mots réels (mesure manuelle sur les 3 premiers fichiers tests)

**Critères de sortie Sprint O-1 :**
- [ ] Tesseract installé et fonctionnel dans le Docker dev
- [ ] `TesseractOcrEngine` retourne un texte lisible sur les 4 samples de test
- [ ] `ImagePreprocessor` améliore la confiance de ≥10 points sur scan moyen qualité
- [ ] `classifyPerPage()` détecte correctement les pages mixtes
- [ ] Aucune fuite mémoire (vérification avec plusieurs PDFs 10+ pages en succession)

---

### Sprint O-2 — LLM post-processing & qualité (1,5 semaine)

**Objectif :** Transformer le texte brut Tesseract en texte propre et structuré. C'est le sprint qui fait la différence entre un "OCR basique" et un "OCR de qualité".

#### Tâches

**O-2.1 — `OcrTextEnhancer.java`**

Nouveau composant : `com.kovixel.ocr.enhancement.OcrTextEnhancer`

Le prompt de nettoyage est paramétrable selon le type de document détecté (legal, financial, general) — utiliser les mêmes catégories que `SummaryFocus` pour la cohérence.

Gestion du contexte LLM :
- Texte OCR > 32 000 tokens → découper en chunks de 4 000 mots, traiter séquentiellement, concaténer
- Marquer les frontières de chunk pour éviter les coupures de phrases

**O-2.2 — Score de confiance et détection des problèmes**

Service `OcrQualityAnalyzer` :
```java
public OcrQualityReport analyze(List<OcrPageResult> pages) {
    // Calcule : avgConfidence, minConfidence, pageConfidences[]
    // Identifie : lowConfidencePages (< 70%)
    // Détecte : nombreux [ILLISIBLE], ratio caractères spéciaux > 15% → page problématique
    // Recommandation : suggest 600 DPI si confidence < 60%
}
```

**O-2.3 — Détection automatique de langue**

Tesseract retourne la langue dominante via l'API. Pour les documents multilingues :
```java
// Pré-OCR avec "osd" (Orientation and Script Detection)
// → détecte la ou les langues présentes
// → relancer Tesseract avec les langues exactes
// → améliore significativement la précision
```

**O-2.4 — Gestion des PDFs mixtes dans `OcrStrategy`**

Pour un PDF avec pages texte natif + pages scannées :
- Pages texte natif : extraction PDFBox directe, confiance = 100%
- Pages scannées : pipeline Tesseract complet
- Fusion dans l'ordre des pages originales
- L'utilisateur reçoit un document cohérent, sans rupture visible entre les deux types

**O-2.5 — Progression dans le job**

Mise à jour de `ProcessingJob.progressPct` après chaque page traitée. Accessible via `GET /api/v1/processing/{jobId}` → champ `progress` dans la réponse existante.

**Critères de sortie Sprint O-2 :**
- [ ] Texte nettoyé par LLM clairement meilleur que le brut Tesseract (validé sur les samples de test)
- [ ] Détection de langue correcte sur les 4 samples
- [ ] Progression rapportée page par page dans le statut du job
- [ ] PDFs mixtes traités sans erreur

---

### Sprint O-3 — Formats de sortie (1 semaine)

**Objectif :** Générer les 4 formats attendus et les stocker via `FileStorageService`.

#### Tâches

**O-3.1 — `TxtExporter`** — Concaténation du texte enhanced, encodage UTF-8, clé stockage `ocr/{docId}/result.txt`

**O-3.2 — `MarkdownExporter`** — Le texte enhanced est déjà en Markdown (sortie LLM). Validation syntaxe basique, clé `ocr/{docId}/result.md`

**O-3.3 — `OcrSearchablePdfBuilder`**

C'est le format le plus technique et le plus valorisé.

Prérequis : sortie HOCR de Tesseract (`tessedit_create_hocr 1`).

Pipeline :
1. Charger le PDF original (PDFBox)
2. Parser le HOCR XML → liste de mots avec positions (bbox en pixels)
3. Pour chaque page OCR, ouvrir un `PDPageContentStream` en mode APPEND
4. Définir `TextRenderingMode.NEITHER` (invisible)
5. Positionner chaque mot à ses coordonnées PDF (transformation : espace image 300 DPI → espace PDF points)
6. Écrire le texte avec `cs.showText(word)`
7. Sauvegarder → PDF searchable

Test de validation :
- Ouvrir le PDF résultat dans un lecteur PDF
- Ctrl+A (tout sélectionner) → le texte doit être sélectionnable
- Ctrl+F (rechercher) → les mots doivent être trouvables

**O-3.4 — `DocxExporter`**

Réutiliser le pipeline de conversion existant :
1. Exporter le Markdown en `.md` (déjà fait)
2. Appeler le convertisseur Markdown → DOCX via pandoc (ou conversion en mémoire via xdocreport qui est déjà en dépendance)
3. Stocker sous `ocr/{docId}/result.docx`

**O-3.5 — `OcrOutputService`**

Façade orchestrant les 4 exporters :
```java
public record OcrOutputs(String txtKey, String markdownKey, String searchablePdfKey, String docxKey) {}

public OcrOutputs generate(String enhancedText, List<OcrPageResult> pages, byte[] originalPdf, String preferredFormat) {
    // Génère toujours TXT et MD (rapides)
    // Génère PDF searchable si des pages HOCR sont disponibles
    // Génère DOCX si preferredFormat == "docx"
}
```

**Critères de sortie Sprint O-3 :**
- [ ] TXT téléchargeable et correctement encodé UTF-8
- [ ] Markdown propre et structuré
- [ ] PDF searchable : Ctrl+F dans Adobe Reader trouve les mots OCR-isés
- [ ] DOCX ouvre sans erreur dans LibreOffice et Microsoft Word

---

### Sprint O-4 — Route Cloud Vision (1 semaine)

**Objectif :** Implémenter `CloudVisionOcrEngine` pour les utilisateurs PRO en mode CLOUD. Activer la sélection automatique du moteur selon le plan/mode.

#### Tâches

**O-4.1 — `CloudVisionOcrEngine` via Claude Vision (Spring AI)**

Voir section 4.2 pour l'implémentation.

Tests à valider :
- Même scan difficile qu'en O-1 → comparer confiance Tesseract vs Claude Vision
- Document avec tableau complexe → Tesseract produit du texte linéaire, Claude produit un tableau Markdown ✓
- Document multicolonne → Claude gère mieux la lecture dans l'ordre correct

**O-4.2 — `OcrEngineFactory`**

Sélection du moteur selon le contexte utilisateur :
```java
@Component
public class OcrEngineFactory {

    public OcrEngine resolve(Long userId) {
        AiRoutingDecision decision = aiRoutingService.resolve(userId);

        return switch (decision.mode()) {
            case CLOUD -> cloudVisionEngine;  // PRO/ENTERPRISE + CLOUD mode
            case LOCAL -> tesseractEngine;    // FREE ou LOCAL mode
        };
    }
}
```

**O-4.3 — Coût tracking pour Claude Vision**

Estimer le coût d'un appel Claude Vision et l'enregistrer dans `UsageRecord.costMicroUsd`. Utiliser le même système de pricing que les autres outils IA (tokens estimés via Spring AI usage metadata).

**O-4.4 — Comparaison qualité documentée**

Tests comparatifs sur 5 types de documents :

| Document | Tesseract confidence | Claude Vision quality | Verdict |
|----------|---------------------|-----------------------|---------|
| Scan simple, bonne qualité | ~90% | Excellent Markdown | Tesseract suffisant |
| Scan incliné, faible contraste | ~55% | Très bon | Claude nettement supérieur |
| Tableau complexe (formulaire) | ~72% | Tableau Markdown parfait | Claude supérieur |
| Document multicolonne (journal) | ~68% | Bon ordre de lecture | Claude supérieur |
| Document manuscrit (notes) | ~35% | Correct | Claude recommandé |

**Critères de sortie Sprint O-4 :**
- [ ] `CloudVisionOcrEngine` fonctionne et produit du Markdown structuré
- [ ] Sélection automatique moteur selon plan/mode validée
- [ ] Coûts trackés dans `UsageRecord`
- [ ] Tableau comparatif documenté (aide à la décision pour les utilisateurs)

---

### Sprint O-5 — Intégration Kovixel (1 semaine)

**Objectif :** Brancher les composants O-1 à O-4 dans l'architecture Kovixel existante. Migrations, quotas, API, tests d'intégration.

#### Tâches

**O-5.1 — Modifications enums**

```java
// ProcessingJob.java
public enum JobType {
    SUMMARY, QA, EXTRACTION, GENERATION, OCR  // ← ADD OCR
}

// FeatureType.java
public enum FeatureType {
    SUMMARY, QNA, EXTRACTION, INGEST, CONVERSION, TRANSLATION, OCR  // ← ADD OCR
}
```

**O-5.2 — Quotas OCR dans `PlanConfig`**

```java
// La limite OCR est en PAGES (pas en nombre de jobs)
// Un job de 5 pages consomme 5 unités de quota
static PlanConfig FREE = new PlanConfig(
    ...,
    maxOcrPagesPerMonth: 50      // ≈ 5-10 documents courts
);
static PlanConfig PRO = new PlanConfig(
    ...,
    maxOcrPagesPerMonth: 500     // ≈ 50 documents de 10 pages
);
static PlanConfig ENTERPRISE = new PlanConfig(
    ...,
    maxOcrPagesPerMonth: -1      // Illimité
);
```

`QuotaService.checkAndIncrementQuota(userId, FeatureType.OCR, pageCount)` — adapter la signature pour les quotas basés sur un volume (pages), pas un simple compteur.

**O-5.3 — Migrations Flyway**

- `V32__create_ocr_results.sql` (voir section 7)
- `V33__add_ocr_progress_to_processing_jobs.sql` (voir section 7)
- `V34__add_ocr_plan_limits.sql`

**O-5.4 — `OcrController.java`**

Nouveau controller : `com.kovixel.ocr.controller.OcrController`

```
POST /api/v1/extract/text
Content-Type: multipart/form-data
Paramètres :
  - file        : fichier PDF (max 50 MB, max 200 pages)
  - language    : "auto" | "fr" | "en" | "de" | "es" | "ar" | "zh" | ... (défaut: "auto")
  - enhance     : boolean (défaut: true — nettoyage LLM activé)
  - format      : "markdown" | "txt" | "searchable-pdf" | "docx" (défaut: "markdown")

Réponse 202 :
{
  "jobId": "uuid",
  "documentId": 42,
  "estimatedPages": 8,
  "message": "OCR en cours — résultat disponible via /api/v1/processing/{jobId}"
}
```

```
GET /api/v1/extract/text/{jobId}/result
→ OcrResultResponse : texte, confidence, pageConfidences, downloadUrls

GET /api/v1/extract/text/{jobId}/download?format=txt|md|pdf|docx
→ Téléchargement direct du fichier généré
```

**O-5.5 — Tests d'intégration**

- Upload PDF texte natif → résultat en < 5s, confiance = 100%
- Upload PDF scanné simple → OCR, confiance > 80%, texte cohérent
- Upload PDF scanné complexe → texte amélioré par LLM visible
- Upload > 200 pages → rejet 400 avec message clair
- Upload PDF chiffré → rejet 400 avec message clair
- Quota dépassé → rejet 429

**Critères de sortie Sprint O-5 :**
- [ ] `OcrStrategy` correctement enregistrée et invoquée par l'orchestrateur
- [ ] Quotas pages OCR fonctionnels
- [ ] Tous les endpoints répondent correctement
- [ ] Tests d'intégration verts (6/6 scénarios ci-dessus)
- [ ] Migrations Flyway V32–V34 appliquées proprement

---

### Sprint O-6 — Frontend Angular (1,5 semaine)

**Objectif :** Interface utilisateur de qualité pour l'outil OCR — expérience fluide, feedback en temps réel, résultat immédiatement exploitable.

#### Tâches

**O-6.1 — Activer l'outil dans `tools-config.ts`**

```typescript
{
  slug: 'extract/text',
  name: 'Extraire le texte',
  description: 'Convertit un PDF scanné en texte sélectionnable et téléchargeable.',
  category: 'extract',
  backendEndpoint: '/api/v1/extract/text',
  isPro: false,
  isAvailable: true,   // ← ACTIVER
  badge: undefined,    // ← Retirer le badge SOON
  icon: 'scan-text',
  keywords: ['ocr', 'scanner', 'scanné', 'texte', 'extraire', 'copier', 'markdown', 'searchable', 'document image'],
}
```

**O-6.2 — Composant `OcrComponent`**

Nouveau composant : `kovixel-ui/src/app/features/ocr/ocr.component.ts`

Suivre le pattern des outils existants (signals Angular, OnPush) :

```typescript
@Component({
  selector: 'kov-ocr',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class OcrComponent {
  readonly step       = signal<'upload' | 'options' | 'processing' | 'result' | 'error'>('upload');
  readonly file       = signal<File | null>(null);
  readonly options    = signal<OcrOptions>({ language: 'auto', enhance: true, format: 'markdown' });
  readonly jobId      = signal<string | null>(null);
  readonly progress   = signal<OcrProgress | null>(null);  // { pct, currentPage, totalPages }
  readonly result     = signal<OcrResult | null>(null);
  readonly error      = signal<string | null>(null);
  readonly activeTab  = signal<'text' | 'confidence'>('text');
}
```

**O-6.3 — Étape "options" (configuration)**

```
┌──────────────────────────────────────────────────┐
│  Options d'extraction                             │
│                                                  │
│  Langue du document                              │
│  ┌─────────────────────────────────────┐         │
│  │  Détection automatique ▼            │         │
│  └─────────────────────────────────────┘         │
│                                                  │
│  Format de sortie                                │
│  ○ Markdown (recommandé)                         │
│  ○ Texte brut (.txt)                             │
│  ○ PDF interrogeable                             │
│  ○ Word (.docx)                                  │
│                                                  │
│  ☑ Amélioration IA (corrige les erreurs OCR)     │
│    Utilise l'IA pour nettoyer le texte extrait   │
│    Résultats nettement meilleurs sur scans       │
│                                                  │
│  [Extraire le texte →]                           │
└──────────────────────────────────────────────────┘
```

**O-6.4 — Étape "processing" — barre de progression**

```
┌──────────────────────────────────────────────────┐
│  Extraction en cours...                          │
│                                                  │
│  [████████████████░░░░░░░░░░░░] 53%              │
│  Page 7 sur 13 — Reconnaissance optique          │
│                                                  │
│  Étape : Nettoyage IA du texte                   │
└──────────────────────────────────────────────────┘
```

Polling toutes les 2 secondes via `JobPollingService` existant. Afficher l'étape courante via `progress.currentPage`.

**O-6.5 — Étape "result" — affichage du résultat**

```
┌────────────────────────────────────────────────────────────────┐
│  Texte extrait (13 pages)          [Copier tout] [Télécharger ▼]│
│  Confiance moyenne : 87.3%  ████████████████░░░░              │
│                                                                │
│  Onglets : [Texte ●] [Qualité par page]                       │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ ## Article 3 — Dispositions générales                    │ │
│  │                                                          │ │
│  │ Le vendeur s'engage à livrer les biens conformément      │ │
│  │ aux spécifications définies à l'Annexe A...              │ │
│  │                                                          │ │
│  │ | Référence | Quantité | Prix unitaire |                 │ │
│  │ |-----------|----------|---------------|                 │ │
│  │ | REF-001   | 50       | 12,50 €       |                 │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                │
│  Télécharger :                                                 │
│  [Markdown .md]  [Texte .txt]  [PDF searchable]  [Word .docx] │
└────────────────────────────────────────────────────────────────┘
```

**O-6.6 — Onglet "Qualité par page"**

Pour chaque page, afficher le score de confiance et signaler les pages à problème :
```
Page 1  [██████████████████████] 95% ✓
Page 2  [██████████████████████] 91% ✓
Page 3  [████████████░░░░░░░░░░] 58% ⚠ Qualité faible — scan à retenter à 600 DPI
Page 4  [██████████████████████] 89% ✓
```

**O-6.7 — Intégration avec les autres outils IA**

Après une extraction réussie, proposer les outils suivants :
```
Ce texte peut maintenant être utilisé avec :
[Résumer ce document]  [Poser des questions]  [Extraire des données]
```

Ces boutons naviguent vers les outils correspondants avec le document déjà sélectionné.

**Critères de sortie Sprint O-6 :**
- [ ] Outil visible et actif dans le catalogue Kovixel
- [ ] Upload → options → progression → résultat : flux complet fonctionnel
- [ ] Barre de progression mise à jour en temps réel (polling 2s)
- [ ] Boutons de téléchargement (4 formats) fonctionnels
- [ ] Onglet "Qualité par page" affiche les scores et avertissements
- [ ] Intégration vers outils IA aval fonctionnelle
- [ ] Responsive (mobile : affichage en plein écran du résultat texte)

---

### Sprint O-7 — Hardening, tests, documentation (1 semaine)

**Objectif :** Robustesse, cas limites, performance, Dockerfile de prod validé.

#### Tâches

**O-7.1 — Cas limites à couvrir**

| Cas | Comportement attendu |
|-----|---------------------|
| PDF chiffré | 400 : "Document protégé par mot de passe — déverrouiller d'abord" |
| PDF vide (0 pages) | 400 : "Document vide" |
| PDF 201 pages | 400 : "Maximum 200 pages par extraction" |
| Fichier > 50 MB | 400 : "Fichier trop volumineux (max 50 MB)" |
| Image de très mauvaise qualité (confidence < 30%) | 200 + avertissement visible + suggestion rescanner à 600 DPI |
| PDF avec uniquement des images de logos/graphiques | Résultat vide avec message explicatif |
| Quota pages épuisé en milieu de traitement | Job échoue proprement, pages déjà traitées comptabilisées |
| Timeout Tesseract sur page très complexe (> 60s) | Page marquée [TIMEOUT] dans le résultat, traitement continue |

**O-7.2 — Tests de performance**

Benchmarks obligatoires avant release :
- PDF 1 page simple → < 5s (Tesseract) / < 3s (Cloud Vision)
- PDF 10 pages scan moyen → < 45s (Tesseract + LLM) / < 30s (Cloud Vision)
- PDF 50 pages → < 4 min (Tesseract + LLM) — hors limite plan FREE
- Mémoire peak pour 50 pages → < 800 MB heap (traitement page par page)

**O-7.3 — Monitoring et observabilité**

Métriques Micrometer à exposer :
```java
// Dans OcrStrategy.process()
Timer.Sample sample = Timer.start(meterRegistry);
// ... traitement ...
sample.stop(Timer.builder("kovixel.ocr.processing.duration")
    .tag("engine", ocrEngine.getEngineName())
    .tag("pages", String.valueOf(pageCount))
    .register(meterRegistry));

meterRegistry.counter("kovixel.ocr.pages.processed", "engine", engineName).increment(pageCount);
meterRegistry.gauge("kovixel.ocr.confidence.avg", avgConfidence);
```

**O-7.4 — Documentation utilisateur**

Dans le composant Angular, ajouter un tooltip "?" ou un modal d'aide expliquant :
- La différence entre PDF natif et PDF scanné
- Pourquoi certains PDFs semblent avoir du texte mais que l'OCR est quand même utile (PDF image)
- Comment améliorer la qualité : numériser en 300 DPI minimum, bonne luminosité, pas de rotation

**Critères de sortie Sprint O-7 :**
- [ ] Tous les cas limites retournent des erreurs claires (pas de 500)
- [ ] Benchmarks de performance validés
- [ ] Métriques Micrometer exposées et vérifiables
- [ ] Dockerfile de prod construit et testé avec Tesseract
- [ ] Aucune fuite mémoire sur traitement de 20 documents consécutifs

---

### Sprint O-8 — Qualité PDF searchable & résultat partiel (1 semaine)

**Objectif :** Produire un PDF interrogeable irréprochable et donner à l'utilisateur le contrôle sur la tolérance aux erreurs OCR.

**Décision produit :** Kovixel doit tenir sa promesse de "haute qualité irréprochable". Cela implique deux choses :
1. Le PDF searchable doit être visuellement identique à l'original, sans couche de texte corrompue
2. Avant de retourner un résultat, le système doit vérifier que l'extraction est réellement exploitable

#### Problème résolu

Les PDFs avec encodage de police non-standard (corporate PDFs, outils tiers) produisent du texte PDFBox correct visuellement mais avec un mapping Unicode garbled. L'OCR fallback récupère le bon texte, mais l'ancien `OcrSearchablePdfBuilder` laissait coexister le texte garbled ET l'overlay OCR dans le PDF final — résultat : double texte, sélection incohérente dans les lecteurs PDF.

#### Tâches implémentées

**O-8.1 — Stratégie B dans `OcrSearchablePdfBuilder`**

Pour les pages `hadGarbledEncoding=true` (TEXT_EXTRACTABLE + OCR fallback) :
1. Rasteriser la page originale en RGB 200 DPI avant toute modification (capture fidèle du rendu visuel)
2. `PDPageContentStream.AppendMode.OVERWRITE` : remplace tout le contenu de la page par l'image
3. `AppendMode.APPEND` : ajouter l'overlay OCR invisible par-dessus

**Résultat :** PDF visuellement identique (mêmes proportions, couleurs, mise en page) mais sans couche texte garbled. Ctrl+F, sélection et Ctrl+C fonctionnent avec le texte OCR correct.

**O-8.2 — Détection `hadGarbledEncoding` dans `OcrStrategy`**

Marquage `hadGarbledEncoding=true` sur le `OcrPageResult` des pages TEXT_EXTRACTABLE ayant déclenché le fallback OCR (heuristique `isTextReadable()` = false). Le builder PDF utilise ce flag pour déclencher la stratégie B.

**O-8.3 — Option `acceptPartial` (frontend + backend)**

Nouvelle option utilisateur dans l'étape Options :
- `false` (défaut) : le job **échoue complètement** si une page a une qualité OCR insuffisante (texte vide ou confidence < 20%) → message d'erreur explicite avec la liste des pages problématiques et la suggestion d'activer le mode partiel
- `true` : le job **réussit avec les pages lisibles** ; les pages échouées sont listées dans `failedPages` de la réponse et signalées dans l'UI par une alerte rouge

**Frontend :** toggle "Accepter le résultat partiel" dans l'étape Options (désactivé par défaut). Si des pages échouent avec `acceptPartial=true`, une alerte ⛔ liste les pages non extraites dans la vue résultat.

**O-8.4 — Message d'erreur pertinent pour les jobs FAILED**

`OcrResultResponse.errorMessage` est peuplé depuis `ProcessedResult.summary` (stocké par l'orchestrateur) quand `status=FAILED`. Le frontend affiche ce message à la place du générique "L'extraction OCR a échoué."

Exemples de messages clairs retournés à l'utilisateur :
- *"Qualité OCR insuffisante sur 2 page(s) : 3, 7. Le document est peut-être trop dégradé ou le scan trop faible en résolution. Activez l'option « Accepter le résultat partiel » pour récupérer les pages lisibles."*

**Migrations :**
- `V35__add_failed_pages_to_ocr_results.sql` : colonne `failed_pages TEXT` dans `ocr_results`

**Critères de sortie Sprint O-8 :**
- [x] PDF interrogeable : Ctrl+F fonctionnel, zéro texte garbled sélectionnable
- [x] Stratégie B appliquée sur toutes les pages à encodage corrompu
- [x] `acceptPartial=false` → job FAILED avec message précis listant les pages
- [x] `acceptPartial=true` → job COMPLETED avec `failedPages` peuplé
- [x] Frontend affiche l'alerte pages échouées dans la vue résultat
- [x] Message d'erreur backend transmis fidèlement au frontend

---

## 7. Migrations Flyway

| Version | Fichier | Sprint | Description |
|---------|---------|--------|-------------|
| V32 | `V32__create_ocr_results.sql` | O-5 | Table résultats OCR |
| V33 | `V33__add_ocr_progress_to_processing_jobs.sql` | O-5 | Colonnes progression OCR dans processing_jobs |
| V34 | `V34__add_ocr_to_job_type.sql` | O-5 | Enum OCR dans job_type |
| V35 | `V35__add_failed_pages_to_ocr_results.sql` | O-8 | Colonne failed_pages dans ocr_results |

### V32 — `ocr_results`

```sql
CREATE TABLE ocr_results (
    id                  BIGSERIAL       PRIMARY KEY,
    document_id         BIGINT          NOT NULL
                                        REFERENCES documents(id) ON DELETE CASCADE,
    user_id             BIGINT          REFERENCES kovixel_users(id) ON DELETE SET NULL,
    page_count          INT             NOT NULL,
    detected_language   VARCHAR(20),
    content_type        VARCHAR(20)     NOT NULL,
    raw_text            TEXT,
    enhanced_text       TEXT,
    avg_confidence      DECIMAL(5,2),
    page_confidences    JSONB,
    low_confidence_pages INT[]          DEFAULT '{}',
    txt_key             VARCHAR(255),
    markdown_key        VARCHAR(255),
    searchable_pdf_key  VARCHAR(255),
    docx_key            VARCHAR(255),
    ocr_engine          VARCHAR(20)     NOT NULL,
    llm_enhanced        BOOLEAN         NOT NULL DEFAULT FALSE,
    processing_ms       BIGINT,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ocr_document_id   ON ocr_results (document_id);
CREATE INDEX idx_ocr_user_id       ON ocr_results (user_id, created_at DESC);
CREATE INDEX idx_ocr_low_conf      ON ocr_results (avg_confidence)
    WHERE avg_confidence IS NOT NULL AND avg_confidence < 70;
```

### V33 — Progression dans `processing_jobs`

```sql
ALTER TABLE processing_jobs
    ADD COLUMN progress_pct  INT DEFAULT 0,
    ADD COLUMN current_page  INT DEFAULT 0,
    ADD COLUMN total_pages   INT DEFAULT 0;
```

### V34 — Limites OCR par plan

```sql
-- Si les limites sont stockées en base (sinon : modifier PlanConfig.java directement)
ALTER TABLE plan_limits
    ADD COLUMN max_ocr_pages_per_month INT NOT NULL DEFAULT 50;

UPDATE plan_limits SET max_ocr_pages_per_month = 50   WHERE plan = 'FREE';
UPDATE plan_limits SET max_ocr_pages_per_month = 500  WHERE plan = 'PRO';
UPDATE plan_limits SET max_ocr_pages_per_month = -1   WHERE plan = 'ENTERPRISE';
```

---

## 8. Décisions d'architecture (ADR)

### ADR-001 : Tess4J vs subprocess tesseract vs Gotenberg

**Décision :** Tess4J 5.x (JNA wrapper natif).

| Critère | Tess4J | Subprocess | Gotenberg |
|---------|--------|------------|-----------|
| Contrôle HOCR | ✅ Natif | ⚠️ Fichier tmp | ❌ Non exposé |
| Overhead HTTP | ✅ Aucun | ✅ Aucun | ❌ HTTP roundtrip |
| Intégration Spring | ✅ Simple | ⚠️ ProcessBuilder | ✅ REST client |
| Docker | ⚠️ libtesseract-dev requis | ⚠️ Idem | ✅ Container séparé |
| Progression page/page | ✅ Callback natif | ⚠️ Parsage stdout | ❌ Non |

Le format HOCR (positions des mots) est indispensable pour créer le PDF searchable. Seul Tess4J l'expose nativement dans le processus Java. C'est la raison principale du choix.

### ADR-002 : Claude Vision vs Google Cloud Vision

**Décision :** Claude Vision (via Spring AI déjà intégré) pour le mode CLOUD, Tesseract pour le mode LOCAL.

**Raison du choix Claude Vision :**
- Déjà configuré dans le projet (Spring AI Anthropic)
- Compréhension contextuelle supérieure pour les documents structurés
- Sortie Markdown directe (pas de post-processing LLM séparé)
- Pas de nouveau compte GCP / nouvelle infrastructure

**Limite de Claude Vision :** pas de sortie HOCR → le PDF searchable n'est pas disponible en mode Cloud Vision (ou uniquement via overlay approximatif non positionné). L'utilisateur est informé de cette limitation dans l'UI.

**Option B conservée :** Google Cloud Vision API peut être ajouté ultérieurement comme 3ème moteur (meilleure précision sur les scripts non-latins : arabe, chinois, japonais).

### ADR-003 : Quota basé sur les pages, pas sur les jobs

**Décision :** Le quota OCR est en **pages traitées par mois**, pas en nombre de jobs.

**Raison :** Un job d'une page et un job de 50 pages ont un coût radicalement différent (CPU, API cost, temps). Facturer au job serait soit trop généreux (50 pages = 1 consommé) soit trop restrictif (toujours 1 page mais quota à 50 jobs).

**Implémentation :** `QuotaService.checkAndIncrementQuota(userId, FeatureType.OCR, pageCount)` avec vérification avant et décompte après traitement.

### ADR-004 : Tous les jobs OCR sont asynchrones

**Décision :** Pas de traitement OCR synchrone, même pour 1 page.

**Raison :** Tesseract sur une page complexe peut prendre 3–8 secondes. Claude Vision sur une page : 2–4 secondes. Aucune opération HTTP ne doit bloquer plus de 2 secondes pour une bonne UX. Le polling existant (`GET /api/v1/processing/{jobId}`) gère déjà ce pattern correctement.

### ADR-005 : PDF searchable via HOCR — précision des coordonnées

**Décision :** Utiliser les coordonnées HOCR pour le placement du texte invisible. Accepter une imprécision de ±2% due aux transformations de coordonnées.

**Raison :** La précision absolue du positionnement est secondaire — l'important est que le texte soit présent dans le PDF pour la recherche. Les lecteurs PDF (Adobe, Chrome, Preview) tolèrent un décalage de quelques pixels entre le texte visible et le texte invisible sans impact sur la sélection.

**Transformation de coordonnées :**
- HOCR : `bbox x1 y1 x2 y2` en pixels à 300 DPI
- PDF : points (1 point = 1/72 pouce)
- Formule : `pdfX = hocrX * (72 / 300)`, `pdfY = pageHeight - hocrY * (72 / 300)`

---

## 9. Risques et mitigations

| Risque | Probabilité | Impact | Mitigation |
|--------|------------|--------|------------|
| **Qualité insuffisante sur scans très dégradés** (photocopies de photocopies, taches, texte coupé) | Haute | Moyen | Indiquer le score de confiance à l'utilisateur. Conseiller rescanner à meilleure qualité. Marquer [ILLISIBLE] dans le résultat. |
| **Tesseract non disponible dans l'image Docker de prod** | Moyenne | Critique | Health check au démarrage : `tesseract --version` → fail-fast si absent. |
| **Fuite mémoire sur grands documents** (20+ pages en parallèle) | Moyenne | Élevé | Traitement page par page, libération explicite de `BufferedImage` après usage, seuil de pages concurrentes = 1 par job. |
| **Timeout LLM sur très longs textes** (OCR d'un livre 200 pages) | Faible | Moyen | Chunking automatique au-delà de 4 000 mots. Timeout configurable (défaut 120s par chunk). |
| **PDF searchable cassé** (coordonnées HOCR incorrectes, encodage UTF-8 mal géré) | Faible | Moyen | Tests automatisés : ouvrir le PDF résultat avec PDFBox et vérifier que le texte overlay est lisible. |
| **Coût Claude Vision explosif** (utilisateur uploade 1 000 pages/mois) | Faible (quota) | Élevé | Quota pages/mois + monitoring coût par `UsageRecord`. Alerte admin si coût OCR Cloud > seuil mensuel. |
| **Langues non supportées par Tesseract installé** | Moyenne | Faible | Auto-détection → fallback sur `eng` si langue manquante. Message utilisateur : "Langue X non disponible, extraction en anglais." |
| **PDF chiffré traité par erreur** | Infime (PDFBox lève exception) | Faible | `PdfExtractor.classify()` retourne déjà `ENCRYPTED`. `OcrStrategy` retourne 400 explicite avant toute tentative. |

---

## 10. KPIs qualité

Ces indicateurs définissent ce que "hautement qualitatif" signifie concrètement pour cet outil.

### KPIs de résultat (qualité de l'extraction)

| KPI | Cible | Mesure |
|-----|-------|--------|
| Confidence moyenne sur scan standard (300 DPI, bonne qualité) | > 85% | `avg_confidence` dans `ocr_results` |
| Taux de pages à faible confidence (< 70%) | < 10% | `low_confidence_pages.length / page_count` |
| Amélioration post-LLM mesurée (mots corrigés) | > 5% des tokens | Comparaison `raw_text` vs `enhanced_text` par levenshtein |
| PDF searchable : mots trouvables via Ctrl+F | > 95% | Test automatisé sur corpus de scans de référence |
| Taux de jobs complétés avec succès | > 98% | `ocr_results` COUNT vs `processing_jobs` FAILED |

### KPIs de performance (expérience utilisateur)

| KPI | Cible | Alerte si |
|-----|-------|----------|
| Durée traitement : 1 page simple (Tesseract) | < 8s | > 15s |
| Durée traitement : 10 pages standard (Tesseract + LLM) | < 60s | > 2 min |
| Durée traitement : 1 page (Claude Vision) | < 5s | > 10s |
| Première mise à jour de progression reçue par le frontend | < 3s après soumission | > 8s |
| Mémoire heap peak pour job 20 pages | < 500 MB | > 800 MB |

### KPIs de couverture

| KPI | Cible |
|-----|-------|
| Types de documents testés et validés | Contrat, facture, formulaire, article, note manuscrite |
| Langues validées (test réel) | FR, EN, DE, ES, AR, ZH |
| Formats d'entrée testés | PDF natif, PDF scanné, PDF mixte, PDF protégé (→ rejet), PDF vide (→ rejet) |

---

## 11. Glossaire

| Terme | Définition |
|-------|-----------|
| **OCR** | Optical Character Recognition. Technologie qui convertit des images de texte en texte numérique éditable. |
| **Tesseract** | Moteur OCR open source développé par Google. Version 5.x utilise un réseau de neurones LSTM pour la reconnaissance. |
| **HOCR** | Format XML produit par Tesseract contenant le texte reconnu avec les coordonnées précises de chaque mot (bounding boxes). Indispensable pour créer le PDF searchable. |
| **PDF searchable** | PDF dont le contenu visuel est une image, mais qui contient une couche de texte invisible superposée, rendant le texte sélectionnable et indexable. |
| **Deskew** | Redressement d'un document numérisé légèrement incliné. Tesseract gère automatiquement les inclinaisons jusqu'à ±5°. |
| **Binarisation (Otsu)** | Conversion d'une image en niveaux de gris en image noir et blanc, en déterminant automatiquement le seuil optimal de séparation. Améliore la netteté du texte pour l'OCR. |
| **Tess4J** | Bibliothèque Java (wrapper JNA) encapsulant la bibliothèque native Tesseract. Permet d'utiliser Tesseract depuis Java sans appel système externe. |
| **JNA** | Java Native Access. Framework permettant d'appeler des bibliothèques natives (.so, .dll) depuis Java sans écrire de code JNI (Java Native Interface). |
| **Claude Vision** | Capacité multimodale de Claude à analyser des images. Utilisée en mode CLOUD pour transcrire et structurer le contenu de pages scannées directement en Markdown. |
| **PDF mixte** | PDF contenant à la fois des pages avec texte natif extractible (PDFBox suffit) et des pages scannées (OCR nécessaire). Kovixel traite les deux types en un seul job. |
| **PSM** | Page Segmentation Mode (Tesseract). Contrôle comment Tesseract segmente la page : `AUTO_OSD` détecte automatiquement l'orientation et le type de contenu (texte, tableau, multi-colonnes). |
| **OSD** | Orientation and Script Detection. Module Tesseract qui détecte l'orientation de la page (portrait/paysage, angle de rotation) et le type d'écriture (latin, arabe, CJK...). |
| **LLM post-processing** | Passage du texte OCR brut par un LLM (Ollama ou Claude Haiku) pour corriger les erreurs contextuellement et reconstruire la structure du document en Markdown. |
| **Confidence score** | Score de confiance Tesseract par mot (0–100). La moyenne par page indique la qualité de la reconnaissance. Un score < 70 signale une page difficile. |
| **TEXT_EXTRACTABLE** | Classification d'une page PDF dont le texte peut être extrait directement par PDFBox sans OCR (PDF natif avec couche texte). |
| **IMAGE_ONLY** | Classification d'une page PDF ne contenant que des images (scan), nécessitant OCR pour extraire le texte. |

---

*Dernière mise à jour — Version 1.1 — 2026-06-20 — Sprint O-8 : PDF searchable qualité + acceptPartial*
