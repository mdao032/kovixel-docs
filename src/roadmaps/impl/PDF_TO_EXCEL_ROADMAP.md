# 📋 PDF → Excel : Roadmap d'implémentation Pro/Ultra-Pro

> **Contexte** : Un endpoint `/api/v1/convert/pdf-to-excel` existe déjà (Tabula + fallback
> PDFBox positionnel). Cette roadmap industrialise l'extraction, ajoute un router multi-moteur,
> des paramètres de personnalisation, plusieurs formats de sortie et un frontend premium.
>
> **Instructions** : Exécuter les prompts dans l'ordre.
> Chaque prompt est autonome et cite les fichiers à modifier.
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Requête POST /api/v1/convert/pdf-to-excel
  params: file, format, pages, detectHeaders, strategy, sheetPerPage
        │
        ▼
  ┌──────────────────────────────────────────────────────────┐
  │  ExcelExtractionOptions (DTO de validation)              │
  │  format, pageRange, strategy, headerDetection, options   │
  └──────────────────────────────────────────────────────────┘
        │
        ├─ Fichier > 8 MB ──► Job Asynchrone (AiJobService)
        │                     └─ GET /api/v1/jobs/{jobId}/result → XLSX
        │
        └─ Fichier ≤ 8 MB ──► Conversion Synchrone
                │
                ▼
        ┌───────────────────────────────────────────────────────┐
        │  ExcelConversionRouter                                │
        │  (routing par plan + stratégie + disponibilité)       │
        └───────────────────────────────────────────────────────┘
                │
                ├─ PRO/ENTERPRISE ──► Adobe PDF Extract API
                │                    └─ Fallback → Tabula amélioré
                │
                └─ FREE/ANONYMOUS ──► Tabula amélioré
                                      ├─ SpreadsheetAlgorithm (rulings visibles)
                                      ├─ BasicAlgorithm (alignement spatial)
                                      └─ Fallback → PDFBox positionnel amélioré

        ▼
  Post-traitement (ExcelPostProcessor) :
    ├─ Détection automatique des types de colonnes (texte, nombre, date, devise)
    ├─ Détection des lignes d'en-tête (freeze, gras, couleur)
    ├─ Fusion intelligente des tableaux proches (même page, colonnes identiques)
    ├─ Nommage automatique des feuilles (page X — tableau Y — sujet détecté)
    └─ Feuille "Résumé" avec métadonnées de l'extraction

        ▼
  Output selon format :
    XLSX → Apache POI (défaut)
    CSV  → une archive ZIP (un fichier par tableau)
    ODS  → OpenDocument Spreadsheet via ODFDOM
```

---

## Formats de sortie et moteurs

| Moteur                | Qualité  | Plan requis | Type de PDF optimal         |
|-----------------------|----------|-------------|------------------------------|
| Adobe PDF Extract API | ★★★★★   | PRO         | Tous types, PDF natif        |
| Tabula Spreadsheet    | ★★★★☆   | FREE        | Tableaux avec rulings        |
| Tabula Basic          | ★★★☆☆   | FREE        | Tableaux sans rulings        |
| PDFBox positionnel    | ★★☆☆☆   | FREE        | Fallback texte pur           |

| Format de sortie | MIME type                          | Dépendance     |
|------------------|------------------------------------|----------------|
| XLSX             | application/vnd.openxmlformats...  | Apache POI     |
| CSV (ZIP)        | application/zip                    | Java stdlib    |
| ODS              | application/vnd.oasis.opendocument | ODFDOM         |

---

## PROMPT 1 — Configuration & types partagés

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/ExcelOutputFormat.java`
- `src/main/java/com/kovixel/core/conversion/excel/ExtractionStrategy.java`
- `src/main/java/com/kovixel/core/conversion/excel/ExcelExtractionOptions.java`
- `src/main/java/com/kovixel/core/conversion/excel/ExcelExtractionResult.java`

```
1. Dans ConversionProperties.java, ajoute une section imbriquée `excel` :

   @NestedConfigurationProperty
   private Excel excel = new Excel();

   @Data
   public static class Excel {
       /** Nombre maximum de pages traitées par requête synchrone. Défaut : 100 */
       private int maxPages = 100;

       /** Nombre maximum de tableaux extraits par requête. Défaut : 50 */
       private int maxTables = 50;

       /** Seuil en bytes au-delà duquel le traitement est asynchrone. Défaut : 8 MB */
       private long asyncThresholdBytes = 8L * 1024 * 1024;

       /** Nombre minimum de lignes pour qu'un tableau soit conservé. Défaut : 2 */
       private int minTableRows = 2;

       /** Nombre minimum de colonnes pour qu'un tableau soit conservé. Défaut : 2 */
       private int minTableCols = 2;

       /**
        * Active la détection automatique des en-têtes de tableaux.
        * Analyse la première ligne pour déterminer si elle est un en-tête. Défaut : true
        */
       private boolean headerDetectionEnabled = true;

       /**
        * Active la détection des types de colonnes (texte, nombre, date, devise).
        * Défaut : true
        */
       private boolean columnTypeDetectionEnabled = true;

       /**
        * Active la fusion des tableaux consécutifs ayant les mêmes colonnes. Défaut : false
        */
       private boolean tableMergeEnabled = false;

       /**
        * Active l'Adobe PDF Extract API pour les utilisateurs PRO. Défaut : true
        */
       private boolean adobeExtractEnabled = true;
   }

2. Dans application.yml, sous kovixel.conversion, ajoute :

   excel:
     max-pages: 100
     max-tables: 50
     async-threshold-bytes: 8388608  # 8 MB
     min-table-rows: 2
     min-table-cols: 2
     header-detection-enabled: true
     column-type-detection-enabled: true
     table-merge-enabled: false
     adobe-extract-enabled: true

3. Dans application-dev.yml :

   excel:
     async-threshold-bytes: 2097152  # 2 MB en dev pour tester l'async facilement
     adobe-extract-enabled: false    # Désactivé en dev (pas de credentials)

4. Crée ExcelOutputFormat.java (enum) :

   public enum ExcelOutputFormat {
       XLSX("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", false),
       CSV ("csv",  "application/zip",                                                   true),
       ODS ("ods",  "application/vnd.oasis.opendocument.spreadsheet",                   false);

       private final String extension;
       private final String mimeType;
       private final boolean isArchive;  // true = plusieurs fichiers → ZIP

       // méthode statique fromString(String) avec fallback XLSX
       // méthode statique fromStringStrict(String) avec IllegalArgumentException
   }

5. Crée ExtractionStrategy.java (enum) :

   public enum ExtractionStrategy {
       /**
        * AUTO : essaie SpreadsheetAlgorithm d'abord, puis BasicAlgorithm.
        * C'est la stratégie par défaut.
        */
       AUTO,

       /**
        * RULING : SpreadsheetExtractionAlgorithm uniquement.
        * Optimal pour les tableaux avec lignes visibles (factures, rapports).
        */
       RULING,

       /**
        * LATTICE : alias de RULING (terminologie Camelot).
        */
       LATTICE,

       /**
        * STREAM : BasicExtractionAlgorithm uniquement.
        * Optimal pour les tableaux sans lignes, alignés par espace blanc.
        */
       STREAM,

       /**
        * TEXT : extraction texte positionnelle PDFBox.
        * Fallback ultime pour les PDFs sans structure de tableau détectable.
        */
       TEXT;

       public static ExtractionStrategy fromString(String value) {
           if (value == null || value.isBlank()) return AUTO;
           try { return valueOf(value.trim().toUpperCase()); }
           catch (IllegalArgumentException e) { return AUTO; }
       }
   }

6. Crée ExcelExtractionOptions.java (record) :

   public record ExcelExtractionOptions(
       ExcelOutputFormat format,       // format de sortie
       ExtractionStrategy strategy,    // stratégie d'extraction
       PageSelection pages,            // sélection de pages (réutilise l'existant image/)
       boolean detectHeaders,          // détection auto des en-têtes
       boolean detectColumnTypes,      // détection des types (nombre, date, devise)
       boolean mergeTables,            // fusionner les tableaux identiques adjacents
       boolean sheetPerPage,           // une feuille par page (vs. une feuille par tableau)
       String outputFilename           // nom de base du fichier résultat
   ) {
       // méthode factory : static ExcelExtractionOptions defaults()
       // validation dans le constructeur compact (format non null, etc.)
   }

7. Crée ExcelExtractionResult.java (record) :

   public record ExcelExtractionResult(
       byte[] workbookBytes,           // contenu du fichier généré (XLSX, ODS ou ZIP CSV)
       ExcelOutputFormat format,
       String engine,                  // "ADOBE_EXTRACT" | "TABULA" | "PDFBOX"
       int totalTablesFound,           // nombre de tableaux détectés
       int totalSheetsGenerated,       // nombre de feuilles/fichiers créés
       int totalRowsExtracted,         // total lignes extraites (toutes feuilles)
       long durationMs,
       List<TableSummary> tables       // métadonnées de chaque tableau extrait
   ) {
       public record TableSummary(
           int page,
           int tableIndex,
           int rows,
           int cols,
           String detectedType,  // "FINANCIAL" | "DATA" | "SCHEDULE" | "UNKNOWN"
           String sheetName
       ) {}
   }
```

---

## PROMPT 2 — Moteur Tabula amélioré (TabulaExcelEngine)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/TabulaExcelEngine.java`
- `src/main/java/com/kovixel/core/conversion/excel/TableData.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionService.java`

```
Crée TabulaExcelEngine.java — moteur principal pour les utilisateurs FREE.

Classe TabulaExcelEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  ExcelExtractionResult extract(byte[] pdfBytes, ExcelExtractionOptions options)

Logique d'extraction :

  1. Ouvre le PDF avec PDDocument doc = Loader.loadPDF(pdfBytes)
  2. Résout les pages à traiter selon options.pages() (réutilise PageSelectionParser)
     - Valide que le nombre de pages ≤ props.getExcel().getMaxPages()
  3. Pour chaque page, tente l'extraction selon options.strategy() :
     a. AUTO ou RULING → SpreadsheetExtractionAlgorithm (tableaux avec rulings)
        Si 0 table trouvée et AUTO → tenter BasicExtractionAlgorithm
     b. STREAM → BasicExtractionAlgorithm uniquement
     c. TEXT → passer directement au fallback PDFBox positionnel
  4. Filtre les tableaux (minTableRows, minTableCols depuis props)
  5. Retourne une List<TableData> enrichie

Méthode privée extractWithPdfBoxFallback(PDDocument, Sheet) :
  - Utilise PDFTextStripper avec setSortByPosition(true)
  - Découpe sur 2+ espaces consécutifs (heuristique colonnes)
  - Parse les valeurs numériques (Double) pour utiliser setCellValue(double)

Méthode buildWorkbook(List<TableData>, ExcelExtractionOptions) : byte[]
  - Crée un XSSFWorkbook Apache POI
  - Pour chaque tableau → crée une feuille Excel :
    * Si sheetPerPage=true → une feuille par page (toutes tables de la page regroupées)
    * Sinon → une feuille par tableau : "Tableau 1", "Tableau 2", ...
  - Ajoute une feuille "Résumé" en première position
  - Applique les styles : headerStyle (bleu, gras, blanc), altRowStyle (bleu clair)
  - autoSizeColumn sur toutes les colonnes (max 30 colonnes)

Record TableData :
  record TableData(
      int page,
      int tableIndex,
      List<List<String>> rows,
      boolean hasHeader,         // détecté par l'analyseur (PROMPT 3)
      String detectedType,       // "FINANCIAL" | "DATA" | "SCHEDULE" | "UNKNOWN"
      List<ColumnType> colTypes  // détecté par l'analyseur (PROMPT 3)
  ) {}

  enum ColumnType { TEXT, INTEGER, DECIMAL, DATE, CURRENCY, PERCENTAGE, BOOLEAN }

Dans ConversionService.java :
  - Injecte TabulaExcelEngine tabulaEngine
  - Délègue pdfToExcel(byte[] pdf) à tabulaEngine.extract() avec ExcelExtractionOptions.defaults()
  - Conserve la signature existante pour la compatibilité ascendante :
    public byte[] pdfToExcel(byte[] pdf)
    → appelle tabulaEngine.extract(pdf, ExcelExtractionOptions.defaults()).workbookBytes()

Erreurs :
  - Si trop de pages → KovixelException(VALIDATION_ERROR, HTTP 400)
  - Si trop de tableaux → KovixelException(VALIDATION_ERROR, HTTP 400)
  - Si erreur POI → KovixelException(PROCESSING_ERROR, HTTP 422)
```

---

## PROMPT 3 — Analyseur intelligent de tableaux

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/TableAnalyzer.java`

```
Crée TableAnalyzer.java — enrichit les TableData avec de l'intelligence.

Classe TableAnalyzer :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties
- Méthode principale : List<TableData> analyze(List<TableData> rawTables, ExcelExtractionOptions options)

1. Détection des en-têtes (si options.detectHeaders() && props.excel.headerDetectionEnabled) :

   Heuristiques (en ordre de priorité) :
   a. La première ligne contient des mots courts (< 4 chars) ou des abréviations courantes
      (N°, ID, QTY, REF, CODE, NOM, DATE, TOTAL, MONTANT, PRIX, DESC...)
   b. La première ligne a des valeurs différentes des lignes suivantes (toutes les lignes 2-5
      ont des patterns similaires entre elles mais différents de la ligne 1)
   c. Aucune valeur de la première ligne n'est purement numérique
   → Si au moins 2 heuristiques vraies → hasHeader = true

2. Détection des types de colonnes (si options.detectColumnTypes() && props.excel.columnTypeDetectionEnabled) :

   Pour chaque colonne (en excluant la ligne d'en-tête si détectée) :
   - Analyser les 10 premières valeurs non vides
   - CURRENCY : correspond à /^[\$€£¥]?\s*[\d\s,]+\.?\d{0,2}\s*[\$€£¥]?$/
   - PERCENTAGE : contient "%"
   - DATE : parse avec plusieurs formats (dd/MM/yyyy, MM/dd/yyyy, yyyy-MM-dd, etc.)
   - INTEGER : toutes les valeurs sont parsables comme long sans décimales
   - DECIMAL : toutes les valeurs sont parsables comme double
   - BOOLEAN : contient exclusivement oui/non, yes/no, true/false, 0/1, ✓/✗
   - TEXT : tout le reste
   → colTypes = [TEXT, DECIMAL, DATE, CURRENCY, ...]

3. Détection du type de tableau :

   FINANCIAL : ≥ 2 colonnes CURRENCY ou DECIMAL + présence de "total"|"montant"|"prix"|"amount"
   SCHEDULE  : ≥ 1 colonne DATE + colonnes TEXT
   DATA      : par défaut si aucun autre type détecté
   UNKNOWN   : < minTableRows ou < minTableCols

4. Fusion des tableaux adjacents (si options.mergeTables() && props.excel.tableMergeEnabled) :

   Condition de fusion : deux tableaux sur la même page ou pages consécutives
   avec le même nombre de colonnes ET les mêmes en-têtes (comparaison insensible à la casse)
   → Fusionner les lignes (sans dupliquer l'en-tête)
   → Conserver le page du premier tableau

5. Nommage automatique des feuilles Excel :

   Pattern : "{typeLabel} — Page {page}" ou "{typeLabel} — P{page}-T{index}"
   Avec : FINANCIAL→"Données financières", SCHEDULE→"Planning", DATA→"Données", UNKNOWN→"Tableau"
   Tronquer à 31 caractères (limite Excel) et remplacer les caractères interdits.

Méthode utilitaire parseDate(String) : LocalDate — tente 8 patterns communs.
Méthode utilitaire isCurrency(String) : boolean.
```

---

## PROMPT 4 — Support multi-formats de sortie

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/ExcelOutputBuilder.java`

**Fichiers à modifier :**
- `pom.xml` (dépendance ODFDOM)

```
Crée ExcelOutputBuilder.java — construit le fichier de sortie selon le format demandé.

Classe ExcelOutputBuilder :
- Annotée @Component, @Slf4j

Méthode principale :
  byte[] build(List<TableData> tables, ExcelExtractionOptions options) throws IOException

Selon options.format() :

  ── XLSX (défaut) ─────────────────────────────────────────────────────────────

  Crée un XSSFWorkbook avec :
  1. Feuille "Résumé" (index 0) :
     - Colonnes : Feuille | Page PDF | Lignes | Colonnes | Type | Moteur
     - Lien hypertexte vers chaque feuille de données
     - Style : fond vert pâle, titre en gras

  2. Pour chaque TableData → une feuille :
     - Si hasHeader=true :
         * Ligne d'en-tête gelée (createFreezePane(0, 1))
         * Fond bleu, texte blanc, gras
         * Filtres automatiques activés (setAutoFilter)
     - Valeurs typées selon colTypes :
         * DECIMAL / CURRENCY / PERCENTAGE → cell.setCellValue(double)
           + CellStyle avec DataFormat (#,##0.00 | #,##0.00€ | 0.00%)
         * DATE → cell.setCellValue(LocalDate) + DataFormat dd/MM/yyyy
         * BOOLEAN → cell.setCellValue(boolean)
         * TEXT → cell.setCellValue(String)
     - autoSizeColumn sur toutes les colonnes

  ── CSV (archive ZIP) ─────────────────────────────────────────────────────────

  Crée un ZipOutputStream contenant :
  - Un fichier CSV par tableau : "tableau_01_page_1.csv", "tableau_02_page_1.csv"...
  - Séparateur : ";" (convention européenne)
  - Encodage : UTF-8 avec BOM (pour Excel Windows)
  - Un fichier "manifest.csv" listant les fichiers et leurs métadonnées

  ── ODS (OpenDocument Spreadsheet) ───────────────────────────────────────────

  Utilise la bibliothèque ODFDOM (org.odftoolkit:odfdom-java) :
  - SpreadsheetDocument doc = SpreadsheetDocument.newSpreadsheetDocument()
  - Même structure que XLSX (feuilles, en-têtes, types)
  - Compatible avec LibreOffice Calc, Google Sheets

  Ajouter dans pom.xml (si ODS activé) :
  <dependency>
      <groupId>org.odftoolkit</groupId>
      <artifactId>odfdom-java</artifactId>
      <version>0.12.0</version>
  </dependency>
```

---

## PROMPT 5 — Client Adobe PDF Extract API

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/AdobeExtractClient.java`
- `src/main/java/com/kovixel/core/conversion/excel/AdobeExtractException.java`

```
Crée AdobeExtractClient.java — client Adobe PDF Extract API pour les tableaux.

Adobe PDF Extract API extrait des tableaux structurés depuis n'importe quel PDF
(natif, scanné avec OCR, complexe), avec détection des cellules fusionnées,
des en-têtes multi-niveaux et des types de données.

Documentation : https://developer.adobe.com/document-services/apis/pdf-extract/

Classe AdobeExtractClient :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties (réutilise adobe.clientId / adobe.clientSecret)

Méthode principale :
  List<TableData> extractTables(byte[] pdfBytes, ExcelExtractionOptions options)

Flux Adobe Extract API (similaire à PDF→DOCX mais endpoint différent) :
  1. POST /token (OAuth2 client_credentials) → access_token [cache 24h]
  2. POST /assets → assetID + uploadUri
  3. PUT {uploadUri} → upload binaire du PDF
  4. POST /operation/extractpdf :
     Body JSON :
     {
       "assetID": "...",
       "elementsToExtract": ["tables"],
       "tableOutputFormat": "xlsx",   // ou "csv"
       "renditionsToExtract": []
     }
     → Retourne Location header (jobUri)
  5. GET {jobUri} → polling (status=done|failed, intervalle 3s, timeout 180s)
  6. GET {content[tables].downloadUri} → ZIP contenant :
     - structuredData.json  (données tabulaires en JSON)
     - tables/fileoutpart0Table0.xlsx  (chaque tableau en XLSX)
  7. Dézipper le ZIP de réponse :
     - Parser structuredData.json pour récupérer les métadonnées (page, bounds)
     - Lire les fichiers tables/fileoutpart*.xlsx avec Apache POI
     - Convertir en List<TableData>

Gestion des erreurs :
  - isConfigured() : retourne false si clientId ou clientSecret vides
  - Timeout → AdobeExtractException("Adobe Extract — timeout dépassé")
  - HTTP 4xx → AdobeExtractException avec message lisible
  - ZIP vide ou sans tables → retourner une liste vide (pas d'exception)

Note : Adobe Extract API supporte nativement l'OCR des PDFs scannés,
les cellules fusionnées et les tableaux multi-pages.
```

---

## PROMPT 6 — Router multi-moteur (ExcelConversionRouter)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/excel/ExcelConversionRouter.java`

```
Crée ExcelConversionRouter.java — orchestre le choix du moteur d'extraction.

Classe ExcelConversionRouter :
- Annotée @Component, @Slf4j
- Injecte : ConversionProperties, AdobeExtractClient, TabulaExcelEngine,
            TableAnalyzer, ExcelOutputBuilder, UserRepository, MeterRegistry

Méthode principale :
  ExcelExtractionResult route(byte[] pdfBytes, ExcelExtractionOptions options, Long userId)

Logique de routage :

  1. Résoudre le plan utilisateur (FREE si userId=null)

  2. Si plan = PRO ou ENTERPRISE
       ET props.excel.adobeExtractEnabled
       ET adobeExtractClient.isConfigured() :
       → Tenter Adobe Extract API
       → Si AdobeExtractException → fallback Tabula (log WARN + métrique)

  3. Sinon (FREE, ANONYMOUS, ou Adobe non configuré) :
       → TabulaExcelEngine (moteur principal)
       → Si 0 tableau trouvé et stratégie=AUTO :
           → Relancer avec strategy=TEXT (fallback PDFBox positionnel)

  4. Dans tous les cas, après extraction des TableData :
       → TableAnalyzer.analyze() (types, headers, fusion)
       → ExcelOutputBuilder.build() (XLSX, CSV ou ODS)

  5. Enregistrer les métriques (voir PROMPT 8)

Métriques de fallback :
  Counter.builder("kovixel.conversion.pdf_to_excel.fallback")
      .tag("from",   "ADOBE_EXTRACT")
      .tag("to",     "TABULA")
      .tag("reason", e.getClass().getSimpleName() + ": " + truncate(e.getMessage(), 50))
      .register(meterRegistry)
      .increment();

Métriques de succès :
  Counter.builder("kovixel.conversion.pdf_to_excel.total")
      .tag("engine",  result.engine())
      .tag("format",  options.format().name())
      .tag("plan",    plan.name())
      .tag("tables",  result.totalTablesFound() == 0 ? "ZERO" :
                      result.totalTablesFound() < 5  ? "FEW" : "MANY")
      .register(meterRegistry)
      .increment();
```

---

## PROMPT 7 — Endpoint API enrichi

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Enrichis l'endpoint POST /api/v1/convert/pdf-to-excel avec tous les nouveaux paramètres.

Nouveau endpoint complet :

  @PostMapping("/api/v1/convert/pdf-to-excel")
  @Operation(summary = "PDF → Excel (XLSX, CSV, ODS) — extraction multi-moteur")
  @CheckQuota(feature = FeatureType.CONVERSION)
  public ResponseEntity<?> pdfToExcel(
      @RequestParam("file")                          MultipartFile file,
      @RequestParam(defaultValue = "xlsx")           String format,
      @RequestParam(defaultValue = "auto")           String strategy,
      @RequestParam(required = false)                String pages,
      @RequestParam(defaultValue = "true")           boolean detectHeaders,
      @RequestParam(defaultValue = "true")           boolean detectColumnTypes,
      @RequestParam(defaultValue = "false")          boolean mergeTables,
      @RequestParam(defaultValue = "false")          boolean sheetPerPage,
      @AuthenticationPrincipal UserDetails userDetails) throws Exception

Validation :
  - format   → ExcelOutputFormat.fromStringStrict(format) [sinon 400]
  - strategy → ExtractionStrategy.fromString(strategy) [AUTO si inconnu]
  - pages    → PageSelectionParser.parse(pages) [réutilise l'existant]

Seuil async : file.getSize() > props.getExcel().getAsyncThresholdBytes()
  → soumettre un job asynchrone, retourner HTTP 202 + { jobId, pollUrl }

Flow synchrone :
  1. Valider les paramètres
  2. Construire ExcelExtractionOptions
  3. excelRouter.route(file.getBytes(), options, resolveUserIdOptional(userDetails))
  4. Construire la réponse

Réponse :
  - HTTP 200 avec le fichier (XLSX, ODS, ou ZIP si CSV)
  - Nom de fichier : "{baseName}_kovixel.{ext}"

Headers de réponse :
  X-Conversion-Engine:     ADOBE_EXTRACT | TABULA | PDFBOX
  X-Tables-Found:          nombre de tableaux détectés
  X-Sheets-Generated:      nombre de feuilles créées
  X-Total-Rows:            nombre total de lignes extraites
  X-Processing-Time-Ms:    durée en ms
  Content-Disposition:     attachment; filename="..."
  X-Async-Job-Id:          présent uniquement si async

Feuille "Résumé" dans le XLSX — contenu minimal garanti :
  Si aucun tableau détecté → une feuille unique "Extraction" avec le texte brut du PDF
  + un message en rouge : "Aucun tableau structuré détecté. Voici le contenu textuel brut."
```

---

## PROMPT 8 — Métriques & Health Indicator

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`
- `src/main/java/com/kovixel/core/conversion/excel/ExcelConversionRouter.java`

```
1. Dans ExcelConversionRouter, ajoute les métriques complètes :

   // Timer par moteur
   Timer.builder("kovixel.conversion.pdf_to_excel.duration")
       .tag("engine", result.engine())
       .tag("format", options.format().name())
       .register(meterRegistry)
       .record(result.durationMs(), TimeUnit.MILLISECONDS);

   // Distribution du nombre de tableaux trouvés
   DistributionSummary.builder("kovixel.conversion.pdf_to_excel.tables_found")
       .tag("engine", result.engine())
       .register(meterRegistry)
       .record(result.totalTablesFound());

   // Distribution du nombre de lignes extraites
   DistributionSummary.builder("kovixel.conversion.pdf_to_excel.rows_extracted")
       .tag("engine", result.engine())
       .tag("format", options.format().name())
       .register(meterRegistry)
       .record(result.totalRowsExtracted());

   // Stratégie utilisée réellement
   Counter.builder("kovixel.conversion.pdf_to_excel.strategy_used")
       .tag("requested", options.strategy().name())
       .tag("actual",    result.engine())
       .register(meterRegistry)
       .increment();

2. Dans ConversionEngineHealthIndicator, ajoute :

   // Sonde Tabula (toujours disponible — lib Java embarquée)
   details.put("tabula", "UP");
   details.put("tabula.algorithms", "SPREADSHEET, BASIC, PDFBOX_FALLBACK");

   // Sonde Adobe Extract API
   if (props.getExcel().isAdobeExtractEnabled()) {
       boolean adobeConfigured = props.getAdobe().isConfigured();
       details.put("adobe.extract", adobeConfigured ? "UP" : "DOWN");
       details.put("adobe.extract.note",
           adobeConfigured ? "Credentials présents" : "ADOBE_CLIENT_ID/SECRET manquants");
   } else {
       details.put("adobe.extract", "DISABLED");
   }

   // Sonde ODS (ODFDOM disponible ?)
   try {
       Class.forName("org.odftoolkit.odfdom.doc.OdfSpreadsheetDocument");
       details.put("odfdom", "UP");
   } catch (ClassNotFoundException e) {
       details.put("odfdom", "DISABLED");
       details.put("odfdom.note", "Format ODS non disponible — ajouter odfdom-java dans pom.xml");
   }
```

---

## PROMPT 9 — Frontend : composant Angular dédié

**Fichiers à créer :**
- `kovixel-ui/src/app/features/tools/pdf-to-excel/pdf-to-excel.component.ts`

**Fichiers à modifier :**
- `kovixel-ui/src/app/app.routes.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts`
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
Crée un composant Angular DÉDIÉ pour PDF→Excel avec une UX premium.

Classe PdfToExcelComponent (standalone, OnPush) :

  Signaux :
    selectedFile       = signal<File | null>(null)
    state              = signal<'idle'|'selected'|'uploading'|'success'|'error'>('idle')
    uploadProgress     = signal(0)
    selectedFormat     = signal<'xlsx'|'csv'|'ods'>('xlsx')
    selectedStrategy   = signal<string>('auto')
    detectHeaders      = signal<boolean>(true)
    detectColumnTypes  = signal<boolean>(true)
    mergeTables        = signal<boolean>(false)
    sheetPerPage       = signal<boolean>(false)
    pageMode           = signal<'all'|'single'|'range'>('all')
    singlePage         = signal<number>(1)
    rangeFrom          = signal<number>(1)
    rangeTo            = signal<number>(10)
    // Résultats
    tablesFound        = signal<number | null>(null)
    sheetsGenerated    = signal<number | null>(null)
    totalRows          = signal<number | null>(null)
    engine             = signal<string | null>(null)
    resultBlob         = signal<Blob | null>(null)
    resultFilename     = signal<string>('')
    errorMessage       = signal<string>('')

  Template sections :

  1. DROP ZONE — zone glisser-déposer PDF (identique au composant générique)

  2. OPTIONS (visible quand state = 'selected') :

     FORMAT DE SORTIE — 3 chips :
     ┌──────┐ ┌──────┐ ┌──────┐
     │ XLSX │ │ CSV  │ │ ODS  │
     └──────┘ └──────┘ └──────┘
     Tooltip XLSX : "Microsoft Excel — recommandé"
     Tooltip CSV  : "Archive ZIP — un fichier par tableau"
     Tooltip ODS  : "OpenDocument — LibreOffice / Google Sheets"

     STRATÉGIE D'EXTRACTION — liste déroulante stylisée :
     ○ Auto (recommandé) — essaie les deux algorithmes
     ○ Rulings — tableaux avec lignes visibles (factures, rapports)
     ○ Stream  — tableaux sans lignes (alignés par espacement)
     ○ Texte   — extraction textuelle (PDF sans structure)

     OPTIONS AVANCÉES (section repliable) :
     ☑ Détecter les en-têtes automatiquement
     ☑ Détecter les types de colonnes (nombre, date, devise)
     ☐ Fusionner les tableaux identiques adjacents
     ☐ Une feuille Excel par page (au lieu d'une par tableau)

     SÉLECTION DE PAGES :
     ● Toutes les pages
     ○ Page spécifique : [__]
     ○ Plage : [__] à [__]

  3. ÉTAT UPLOADING — animation + barre de progression 3-phases

  4. ÉTAT SUCCESS :
     ┌────────────────────────────────────────────────────────┐
     │  ✅ Extraction réussie                                 │
     │                                                        │
     │  📊 X tableaux détectés · Y feuilles · Z lignes       │
     │  🤖 Moteur : TABULA  ·  ⚡ 1.4s                       │
     │                                                        │
     │  [↓ Télécharger le fichier Excel (X.xlsx)]            │
     │                                                        │
     │  ℹ Contenu : tableau financier (page 2), planning...  │
     └────────────────────────────────────────────────────────┘

     Si 0 tableaux détectés :
     ┌────────────────────────────────────────────────────────┐
     │  ⚠ Aucun tableau structuré détecté                    │
     │  Le fichier contient l'extraction textuelle brute.    │
     │  Essayez la stratégie "Texte" pour ce type de PDF.   │
     │  [↓ Télécharger quand même]   [🔄 Réessayer en Texte] │
     └────────────────────────────────────────────────────────┘

  Dans ConversionService Angular (conversion.service.ts) :
    pdfToExcel(
      file: File,
      format: 'xlsx' | 'csv' | 'ods' = 'xlsx',
      strategy: string = 'auto',
      pages = 'all',
      detectHeaders = true,
      detectColumnTypes = true,
      mergeTables = false,
      sheetPerPage = false
    ): Observable<HttpEvent<Blob>>
    → POST /api/v1/convert/pdf-to-excel avec tous les paramètres
    → responseType: 'blob', observe: 'events', reportProgress: true
    → Lire les headers X-Tables-Found, X-Sheets-Generated, X-Total-Rows, X-Conversion-Engine

  Dans app.routes.ts, ajoute AVANT la route générique :
    {
      path: 'tools/convert/pdf-to-excel',
      loadComponent: () =>
        import('./features/tools/pdf-to-excel/pdf-to-excel.component')
          .then(m => m.PdfToExcelComponent),
      data: { title: 'PDF → Excel' }
    }

  Dans tools-config.ts, mets à jour la description :
    description: 'Extrayez tableaux et données en XLSX, CSV ou ODS. Détection automatique.'
    longDescription: 'Utilise Tabula (FREE) ou Adobe Extract API (PRO) pour détecter
                      les tableaux, identifier les en-têtes, typer les colonnes (nombres,
                      dates, devises) et exporter en Excel, CSV ou ODS.'
```

---

## PROMPT 10 — Tests complets

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/excel/TabulaExcelEngineTest.java`
- `src/test/java/com/kovixel/core/conversion/excel/TableAnalyzerTest.java`
- `src/test/java/com/kovixel/core/conversion/excel/ExcelConversionRouterTest.java`
- `src/test/java/com/kovixel/core/conversion/excel/ExcelOutputBuilderTest.java`

```
TabulaExcelEngineTest (tests unitaires) :

  PDF de test : générer un mini-PDF avec un tableau simple via PDFBox :
    PDDocument doc = new PDDocument();
    PDPage page = new PDPage();
    doc.addPage(page);
    // Ajouter du texte tabulaire avec PDPageContentStream

  @Test extractsPngFromSimplePdf()
    - PDF 1 page sans tableau → résultat avec extraction texte (strategy=TEXT)
    - Vérifie : totalTablesFound = 0, workbookBytes non vide

  @Test respectsMaxPages()
    - props.excel.maxPages = 2 ; PDF 5 pages → KovixelException HTTP 400

  @Test pageRangeSelection()
    - PDF 5 pages ; pages=Range(2,4) → seules les pages 2 à 4 sont analysées

  @Test sheetPerPageGrouping()
    - 2 tableaux sur la même page ; sheetPerPage=true → 1 feuille (pas 2)

TableAnalyzerTest (tests unitaires) :

  @Test detectsHeaderRowFromKeywords()
    - Première ligne : ["N°", "Produit", "Quantité", "Prix HT", "Total TTC"]
    - Vérifie : hasHeader = true

  @Test detectsHeaderByNonNumericFirstRow()
    - Première ligne : ["Alpha", "Beta", "Gamma"] ; lignes suivantes : ["1.0", "2.5", "3.7"]
    - Vérifie : hasHeader = true

  @Test detectsColumnTypes()
    - Colonne : ["12.50€", "45.00€", "7.25€"] → CURRENCY
    - Colonne : ["01/01/2024", "15/03/2024"] → DATE
    - Colonne : ["ACTIF", "INACTIF", "EN COURS"] → TEXT

  @Test detectsFinancialTableType()
    - Tableau avec colonnes CURRENCY + mot "TOTAL" → detectedType = "FINANCIAL"

  @Test mergesAdjacentTablesWithSameHeaders()
    - Deux tableaux mêmes colonnes sur pages consécutives ; mergeTables=true
    - Vérifie : 1 seul tableau fusionné avec toutes les lignes

ExcelConversionRouterTest (Mockito) :

  @MockitoSettings(strictness = LENIENT)

  @Test freePlanUsesTabulaEngine()
    - userId=null → TabulaExcelEngine appelé, AdobeExtractClient non appelé

  @Test proWithAdobeConfiguredUsesAdobe()
    - plan=PRO, adobeExtractEnabled=true, isConfigured=true
    - AdobeExtractClient.extractTables() appelé

  @Test adobeFailureFallsBackToTabula()
    - Adobe lève AdobeExtractException → Tabula appelé
    - Métrique fallback enregistrée

  @Test routerCallsAnalyzerAndBuilder()
    - Vérifie que TableAnalyzer.analyze() ET ExcelOutputBuilder.build() sont appelés

ExcelOutputBuilderTest :

  @Test buildsXlsxWithHeaderStyle()
    - TableData avec hasHeader=true → première ligne en gras + fond bleu dans le XLSX
    - Ouvrir le XLSX avec Apache POI et vérifier le CellStyle de la ligne 0

  @Test buildsCsvZipWithOneCsvPerTable()
    - 3 tableaux → ZIP avec 3 fichiers CSV + manifest.csv

  @Test xlsxTypesNumbers()
    - Colonne ColumnType.DECIMAL → les cellules doivent avoir un CellType.NUMERIC

  @Test xlsxNoTablesShowsExtractedText()
    - List<TableData> vide → une feuille "Extraction" avec message d'avertissement
```

---

## PROMPT 11 — Documentation & Variables d'environnement

**Fichiers à modifier :**
- `README.md` (section "PDF → Excel")
- `.env.example`

```
Dans README.md, ajoute une section "## PDF → Excel" :

### Moteurs d'extraction

| Moteur              | Qualité   | Plan requis | Cas d'usage optimal                     |
|---------------------|-----------|-------------|------------------------------------------|
| Adobe Extract API   | ★★★★★    | PRO         | Tout type, cellules fusionnées, OCR      |
| Tabula Spreadsheet  | ★★★★☆    | FREE        | Tableaux avec lignes visibles            |
| Tabula Basic        | ★★★☆☆    | FREE        | Tableaux alignés par espacements         |
| PDFBox positionnel  | ★★☆☆☆    | FREE        | Fallback texte brut (pas de structure)   |

### Stratégies d'extraction

| Stratégie | Description                              | Recommandé pour              |
|-----------|------------------------------------------|------------------------------|
| auto      | Essaie tous les algorithmes (défaut)     | Usage général                |
| ruling    | Tableaux avec lignes visibles            | Factures, rapports formels   |
| stream    | Alignement spatial (sans lignes)         | Tableaux simples             |
| text      | Extraction texte brut                    | PDFs sans structure          |

### Formats de sortie

| Format | Description                      | Compatible avec              |
|--------|----------------------------------|------------------------------|
| xlsx   | Microsoft Excel (défaut)         | Excel, LibreOffice, Google   |
| csv    | Archive ZIP de fichiers CSV      | Tous tableurs, Python, R     |
| ods    | OpenDocument Spreadsheet         | LibreOffice, Google Sheets   |

### Paramètres API

| Paramètre         | Type    | Défaut | Description                               |
|-------------------|---------|--------|-------------------------------------------|
| file              | File    | —      | PDF à convertir (multipart)               |
| format            | String  | xlsx   | Format : xlsx, csv, ods                   |
| strategy          | String  | auto   | Stratégie : auto, ruling, stream, text    |
| pages             | String  | all    | Sélection : all, 3, 2-7                   |
| detectHeaders     | boolean | true   | Détection automatique des en-têtes        |
| detectColumnTypes | boolean | true   | Typage automatique des colonnes           |
| mergeTables       | boolean | false  | Fusionner les tableaux identiques         |
| sheetPerPage      | boolean | false  | Une feuille par page (vs. par tableau)    |

### Headers de réponse

| Header                | Description                              |
|-----------------------|------------------------------------------|
| X-Conversion-Engine   | ADOBE_EXTRACT \| TABULA \| PDFBOX        |
| X-Tables-Found        | Nombre de tableaux détectés              |
| X-Sheets-Generated    | Nombre de feuilles/fichiers créés        |
| X-Total-Rows          | Nombre total de lignes extraites         |
| X-Processing-Time-Ms  | Durée de traitement en ms                |
| X-Async-Job-Id        | ID du job si traitement asynchrone       |

### Variables d'environnement

Aucune variable supplémentaire requise pour le plan FREE.
Pour le plan PRO (Adobe Extract API), réutilise les credentials Adobe existants :

  ADOBE_CLIENT_ID=your_adobe_client_id_here
  ADOBE_CLIENT_SECRET=your_adobe_client_secret_here

### Comportement quand aucun tableau n'est détecté

Le fichier généré contiendra une feuille "Extraction" avec le contenu textuel brut du PDF.
Un message d'avertissement en rouge indique qu'aucun tableau structuré n'a été trouvé.
Conseil : essayer la stratégie "text" ou "stream" selon le type de PDF.
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10 → PROMPT 11
  Config    Tabula     Analyser   Formats    Adobe      Router     Endpoint   Métriques  Frontend  Tests        Docs
```

> **Parallélisables** : PROMPT 4 (formats) + PROMPT 5 (Adobe) peuvent être développés
> en parallèle après PROMPT 3, car ils sont indépendants.  
> PROMPT 9 (Frontend) peut démarrer dès PROMPT 7 (Endpoint) validé.  
> PROMPT 8 (Métriques) peut être intégré à PROMPT 6 directement.

---

## Critères de validation finale

### Backend
- [ ] `mvn test` passe sans erreur (TabulaExcelEngineTest, TableAnalyzerTest, RouterTest, BuilderTest)
- [ ] PDF avec tableau structuré → XLSX avec feuille de données + feuille Résumé
- [ ] PDF sans tableau → XLSX avec feuille "Extraction" + message d'avertissement
- [ ] `strategy=ruling` sur facture → tableau correctement extrait
- [ ] `strategy=stream` sur tableau sans lignes → tableau correctement extrait
- [ ] `detectHeaders=true` → première ligne en gras + freeze pane dans le XLSX
- [ ] `detectColumnTypes=true` → colonnes numériques stockées en double (pas en string)
- [ ] `format=csv` → ZIP avec un CSV par tableau + manifest.csv
- [ ] PDF > 8 MB → HTTP 202 + jobId
- [ ] Plan PRO + Adobe configuré → Adobe Extract API utilisé (header `X-Conversion-Engine: ADOBE_EXTRACT`)
- [ ] Adobe échoue → fallback Tabula automatique (log WARN visible)
- [ ] `curl /actuator/health` expose `tabula: UP` et `adobe.extract: UP|DOWN|DISABLED`
- [ ] `curl /actuator/metrics/kovixel.conversion.pdf_to_excel.tables_found` retourne des valeurs

### Frontend
- [ ] Route `/tools/convert/pdf-to-excel` charge le composant dédié
- [ ] Chips FORMAT : clic sur CSV → tooltip "Archive ZIP — un fichier par tableau"
- [ ] Après conversion : badge `X tableaux détectés · Y feuilles · Z lignes` visible
- [ ] 0 tableau détecté → message d'avertissement + bouton "Réessayer en Texte"
- [ ] Options avancées (detect headers, merge) visibles dans section repliable
- [ ] PDF > 8 MB → barre de progression avec polling async (pas de timeout)

