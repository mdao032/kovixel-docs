

# 📋 Extraire Tableaux : Roadmap d'implémentation Pro/Ultra-Pro

> **Contexte** : L'outil "Extraire Tableaux" est un outil distinct de PDF→Excel.
> Il se concentre sur l'**extraction de données structurées** avec scoring de confiance,
> bounding boxes, formats de sortie riches (JSON, HTML, Markdown, CSV, XLSX)
> et une **prévisualisation interactive** des tableaux détectés dans le PDF.
>
> **Différences clés par rapport à PDF→Excel :**
> - Sortie JSON avec métadonnées complètes (position, confiance, cellules fusionnées)
> - Sortie HTML et Markdown prêts à l'emploi
> - Endpoint de prévisualisation (positions des tableaux sans extraction complète)
> - Sélection interactive des tableaux côté frontend
> - Score de confiance par tableau (0–100 %)
> - Détection des cellules fusionnées et des en-têtes multi-niveaux
>
> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.
> Chaque prompt est autonome et cite les fichiers à modifier.
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Requête POST /api/v1/convert/extract-tables
  params: file, format, pages, strategy, confidenceThreshold, tableIndices,
          includeMetadata, cleanData, detectMergedCells, detectMultiHeaders
        │
        ▼
  ┌────────────────────────────────────────────────────────┐
  │  TableExtractionOptions (DTO + validation Bean)        │
  │  format, pageRange, strategy, confidenceThreshold,     │
  │  tableIndices, includeMetadata, cleanData               │
  └────────────────────────────────────────────────────────┘
        │
        ├─ Fichier > 10 MB ──► Job Asynchrone (AiJobService)
        │                       └─ GET /api/v1/jobs/{jobId}/result → fichier
        │
        └─ Fichier ≤ 10 MB ──► Extraction Synchrone
                │
                ▼
        ┌──────────────────────────────────────────────────────┐
        │  TableExtractionRouter                               │
        │  (routing par plan + stratégie + disponibilité)      │
        └──────────────────────────────────────────────────────┘
                │
                ├─ PRO/ENTERPRISE ──► Adobe PDF Extract API
                │    (réutilise AdobeExtractClient + adapter de métadonnées)
                │    └─ Fallback → TableExtractionEngine (Tabula)
                │
                └─ FREE/ANONYMOUS ──► TableExtractionEngine
                                       ├─ SpreadsheetAlgorithm (rulings visibles)
                                       ├─ BasicAlgorithm (alignement spatial)
                                       └─ Fallback → PDFBox positionnel

        ▼
  TableExtractionPostProcessor :
    ├─ Score de confiance (0.0–1.0) par tableau
    ├─ Filtrage par seuil de confiance (confidenceThreshold)
    ├─ Détection des cellules fusionnées (colspan / rowspan)
    ├─ Détection des en-têtes multi-niveaux (2+ lignes d'en-tête)
    ├─ Nettoyage des données (trim, normalisation Unicode, dé-duplication)
    └─ Enrichissement des métadonnées (BoundingBox, page, type de tableau)

        ▼
  TableOutputFactory → format sélectionné :
    JSON     → structure détaillée + métadonnées optionnelles
    HTML     → <table> avec classes kovixel-table, colspan/rowspan
    MARKDOWN → tableaux GitHub-flavored (GFM)
    CSV      → archive ZIP (un fichier par tableau, UTF-8 BOM)
    XLSX     → réutilise ExcelOutputBuilder existant (conversion des ExtractedTable → TableData)

Endpoint de prévisualisation (GET uniquement, sans extraction complète) :
  POST /api/v1/convert/extract-tables/preview
  → Retourne uniquement les BoundingBox + métadonnées (pas les données)
  → Utilisé par le frontend pour dessiner les overlays sur le PDF
```

---

## Comparatif moteurs

| Moteur               | Qualité   | Plan requis | Forces                                              |
|----------------------|-----------|-------------|-----------------------------------------------------|
| Adobe PDF Extract API| ★★★★★    | PRO         | OCR natif, cellules fusionnées, en-têtes complexes  |
| Tabula Spreadsheet   | ★★★★☆    | FREE        | Précis sur tableaux avec rulings                    |
| Tabula Basic         | ★★★☆☆    | FREE        | Alignement spatial sans lignes visibles             |
| PDFBox positionnel   | ★★☆☆☆    | FREE        | Fallback texte brut                                 |

## Comparatif formats de sortie

| Format   | MIME type                      | Métadonnées | Cellules fusionnées | Cas d'usage optimal                        |
|----------|--------------------------------|-------------|---------------------|--------------------------------------------|
| JSON     | application/json               | ✅ Complètes | ✅ colspan/rowspan  | Intégration API, traitement programmatique |
| HTML     | text/html                      | ✅ data-*    | ✅ colspan/rowspan  | Intégration web, copy-paste                |
| MARKDOWN | text/markdown                  | ❌           | ❌ Non supporté     | Documentation, GitHub, README              |
| CSV      | application/zip                | ❌           | ❌ Aplaties         | Tableurs, Python, R, Data Science          |
| XLSX     | application/vnd.openxmlformats | ✅ Feuille   | ✅ MergedRegion     | Microsoft Excel, reporting                 |

---

## PROMPT 1 — Configuration & Types partagés

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/TableOutputFormat.java`
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionOptions.java`
- `src/main/java/com/kovixel/core/conversion/table/ExtractedTable.java`
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionResult.java`

```
1. Dans ConversionProperties.java, ajoute une section imbriquée `table` :

   @NestedConfigurationProperty
   private Table table = new Table();

   @Data
   public static class Table {
       /** Nombre maximum de pages traitées par requête synchrone. Défaut : 100 */
       private int maxPages = 100;

       /** Nombre maximum de tableaux extraits par requête. Défaut : 100 */
       private int maxTables = 100;

       /** Seuil en bytes au-delà duquel le traitement est asynchrone. Défaut : 10 MB */
       private long asyncThresholdBytes = 10L * 1024 * 1024;

       /** Nombre minimum de lignes pour conserver un tableau. Défaut : 2 */
       private int minTableRows = 2;

       /** Nombre minimum de colonnes pour conserver un tableau. Défaut : 2 */
       private int minTableCols = 2;

       /**
        * Seuil de confiance minimal (0.0–1.0).
        * Les tableaux avec un score inférieur sont écartés. Défaut : 0.4
        */
       private double defaultConfidenceThreshold = 0.4;

       /** Active la détection des cellules fusionnées. Défaut : true */
       private boolean mergedCellsDetectionEnabled = true;

       /** Active la détection des en-têtes multi-niveaux. Défaut : true */
       private boolean multiLevelHeadersEnabled = true;

       /** Active Adobe PDF Extract pour les utilisateurs PRO. Défaut : true */
       private boolean adobeExtractEnabled = true;

       /** Active la prévisualisation (endpoint /preview). Défaut : true */
       private boolean previewEnabled = true;
   }

2. Dans application.yml, sous kovixel.conversion, ajoute :

   table:
     max-pages: 100
     max-tables: 100
     async-threshold-bytes: 10485760  # 10 MB
     min-table-rows: 2
     min-table-cols: 2
     default-confidence-threshold: 0.4
     merged-cells-detection-enabled: true
     multi-level-headers-enabled: true
     adobe-extract-enabled: true
     preview-enabled: true

3. Dans application-dev.yml :

   table:
     async-threshold-bytes: 2097152  # 2 MB en dev pour tester l'async
     adobe-extract-enabled: false
     default-confidence-threshold: 0.3  # Moins strict en dev pour les tests

4. Crée TableOutputFormat.java (enum) :

   public enum TableOutputFormat {
       JSON    ("json",  "application/json",                                              false),
       HTML    ("html",  "text/html;charset=UTF-8",                                      false),
       MARKDOWN("md",    "text/markdown;charset=UTF-8",                                  false),
       CSV     ("zip",   "application/zip",                                              true),
       XLSX    ("xlsx",  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", false);

       private final String extension;
       private final String mimeType;
       private final boolean isArchive;  // true = ZIP

       // static fromString(String) avec fallback JSON
       // static fromStringStrict(String) avec IllegalArgumentException
       // boolean supportsMetadata() : true pour JSON, HTML, XLSX
       // boolean supportsMergedCells() : true pour JSON, HTML, XLSX
   }

5. Crée TableExtractionOptions.java (record) :

   public record TableExtractionOptions(
       TableOutputFormat format,          // format de sortie
       ExtractionStrategy strategy,       // réutilise l'enum existant de excel/
       PageSelection pages,               // sélection de pages
       double confidenceThreshold,        // seuil de confiance [0.0–1.0]
       List<Integer> tableIndices,        // null = tous, [0,2] = tableaux 0 et 2 uniquement
       boolean includeMetadata,           // inclure bounding boxes + scores dans la sortie
       boolean cleanData,                 // trim, normalisation Unicode
       boolean detectMergedCells,         // détection colspan/rowspan
       boolean detectMultiLevelHeaders,   // en-têtes sur plusieurs lignes
       String outputFilename              // nom de base du fichier résultat
   ) {
       // factory : static TableExtractionOptions defaults()
       // factory : static TableExtractionOptions previewOnly() → format=JSON, includeMetadata=true
       // validation dans le constructeur compact :
       //   Objects.requireNonNull(format, "format is required")
       //   if (confidenceThreshold < 0 || confidenceThreshold > 1) throw IllegalArgumentException
   }

6. Crée ExtractedTable.java (record) — modèle central d'un tableau extrait :

   public record ExtractedTable(
       int tableIndex,           // index global dans le document (0-based)
       int page,                 // numéro de page PDF (1-based)
       double confidence,        // score de confiance [0.0–1.0]
       String detectedType,      // "FINANCIAL" | "DATA" | "SCHEDULE" | "FORM" | "UNKNOWN"
       List<HeaderRow> headers,  // liste des lignes d'en-tête (1 = simple, 2+ = multi-niveau)
       List<DataRow> rows,       // lignes de données (hors en-tête)
       int columnCount,
       BoundingBox bounds,       // position dans la page PDF (coordonnées PDF)
       List<MergedCell> mergedCells  // cellules fusionnées (colspan/rowspan)
   ) {
       /** Coordonnées d'un tableau dans la page PDF (unités PDF points, origine bas-gauche) */
       public record BoundingBox(double x1, double y1, double x2, double y2, double pageWidth, double pageHeight) {
           /** Convertit en pourcentages relatifs (utile pour le frontend CSS overlay) */
           public double leftPct()   { return x1 / pageWidth  * 100; }
           public double topPct()    { return (pageHeight - y2) / pageHeight * 100; }
           public double widthPct()  { return (x2 - x1)      / pageWidth  * 100; }
           public double heightPct() { return (y2 - y1)      / pageHeight * 100; }
       }

       public record HeaderRow(int rowIndex, List<String> cells) {}
       public record DataRow(int rowIndex, List<String> cells)   {}

       /**
        * Représente une cellule fusionnée (ex : colspan=3 signifie que la cellule
        * occupe 3 colonnes à partir de la colonne startCol).
        */
       public record MergedCell(int startRow, int startCol, int endRow, int endCol) {}

       /** Nombre de lignes de données (hors en-têtes). */
       public int rowCount() { return rows.size(); }

       /** true si le tableau possède au moins une ligne d'en-tête détectée. */
       public boolean hasHeaders() { return !headers.isEmpty(); }
   }

7. Crée TableExtractionResult.java (record) :

   public record TableExtractionResult(
       List<ExtractedTable> tables,        // tableaux extraits (filtrés par confiance)
       List<ExtractedTable> allTables,     // TOUS les tableaux (avant filtrage, pour debug)
       TableOutputFormat format,
       String engine,                      // "ADOBE_EXTRACT" | "TABULA" | "PDFBOX"
       int totalTablesDetected,            // avant filtrage par confiance
       int totalTablesExported,            // après filtrage
       int totalRowsExtracted,
       int totalPagesAnalyzed,
       double averageConfidence,           // moyenne des scores des tableaux exportés
       long durationMs,
       byte[] outputBytes                  // contenu du fichier généré (JSON, HTML, ZIP, etc.)
   ) {}
```

---

## PROMPT 2 — Moteur d'extraction principal (TableExtractionEngine)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionEngine.java`
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionException.java`

**Fichiers à modifier :**
- `pom.xml` (vérifier que technology.tabula:tabula est présente)

```
Crée TableExtractionEngine.java — moteur Tabula enrichi avec scoring de confiance
et extraction des bounding boxes (coordonnées PDF réelles).

Classe TableExtractionEngine :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  List<ExtractedTable> extract(byte[] pdfBytes, TableExtractionOptions options)

Logique d'extraction (par ordre de priorité) :

  1. Ouvrir le PDF : PDDocument doc = Loader.loadPDF(pdfBytes)
  2. Résoudre les pages à traiter via PageSelectionParser (réutiliser l'existant image/)
     - Valider que nombre de pages ≤ props.getTable().getMaxPages()
  3. Pour chaque page, déterminer l'algorithme selon options.strategy() :
     a. AUTO ou RULING → SpreadsheetExtractionAlgorithm
        Si 0 table trouvée et AUTO → tenter BasicExtractionAlgorithm
     b. STREAM  → BasicExtractionAlgorithm uniquement
     c. TEXT    → extraction PDFBox positionnelle (voir ci-dessous)
  4. Pour chaque tableau trouvé (technology.tabula.Table) :
     a. Extraire les données : List<List<RectangularTextContainer>> cells
     b. Extraire la bounding box : table.getBoundingBox()
        → Convertir en ExtractedTable.BoundingBox
        → Récupérer pageWidth et pageHeight via PDPage.getMediaBox()
     c. Calculer le score de confiance (voir méthode calculateConfidence)
  5. Valider que nombre de tableaux ≤ props.getTable().getMaxTables()
  6. Retourner la liste des ExtractedTable (non encore filtrés par confiance)

Méthode calculateConfidence(technology.tabula.Table table) : double
  Score basé sur les heuristiques suivantes (chaque critère ajoute ou retire des points) :

  BASE SCORE : 0.5

  Bonus :
  + 0.15 si la table a des rulings (SpreadsheetAlgorithm l'a extraite via lignes visibles)
  + 0.10 si la première ligne semble être un en-tête (voir TableExtractionPostProcessor)
  + 0.10 si le nombre de colonnes est uniforme sur toutes les lignes
  + 0.05 si le tableau a ≥ 4 lignes de données
  + 0.05 si ≥ 3 colonnes
  + 0.05 si les valeurs sont homogènes (même type par colonne à ≥ 70 %)

  Malus :
  - 0.10 si > 30 % des cellules sont vides
  - 0.15 si le nombre de colonnes varie entre les lignes (table malformée)
  - 0.20 si le tableau est plus large que haut (risque faux positif sur du texte multi-colonnes)

  Clamp final : Math.max(0.0, Math.min(1.0, score))

Méthode extractWithPdfBoxFallback(PDDocument doc, int pageIndex) : List<ExtractedTable>
  - Utilise PDFTextStripper avec setSortByPosition(true)
  - Découpe sur 2+ espaces consécutifs (colonnes) et sauts de ligne (lignes)
  - Filtre les "tables" avec < minTableRows ou < minTableCols
  - Confidence fixe : 0.3 (extraction positionnelle, moins précise)
  - BoundingBox : null (PDFBox ne retourne pas de coordonnées de tableau)

Erreurs :
  - Si trop de pages → KovixelException(VALIDATION_ERROR, HTTP 400)
  - Si trop de tableaux → KovixelException(VALIDATION_ERROR, HTTP 400)
  - Si PDF corrompu → TableExtractionException extends RuntimeException

Crée TableExtractionException extends RuntimeException avec constructeur(String, Throwable).
```

---

## PROMPT 3 — Post-processeur intelligent (TableExtractionPostProcessor)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionPostProcessor.java`

```
Crée TableExtractionPostProcessor.java — enrichit les ExtractedTable bruts
avant la génération du fichier de sortie.

Classe TableExtractionPostProcessor :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties

Méthode principale :
  List<ExtractedTable> process(List<ExtractedTable> rawTables, TableExtractionOptions options)

Étapes dans l'ordre :

  1. NETTOYAGE DES DONNÉES (si options.cleanData()) :
     Pour chaque cellule de chaque tableau :
     - String.trim()
     - Remplacer les séquences d'espaces multiples par un espace simple
     - Normalisation Unicode : Normalizer.normalize(value, Form.NFC)
     - Remplacer les caractères de contrôle (\u0000–\u001F sauf \t, \n) par ""
     - Convertir les tirets longs (—, –) en tiret simple "-" (option cleanData uniquement)

  2. DÉTECTION DES EN-TÊTES MULTI-NIVEAUX (si options.detectMultiLevelHeaders() && props.table.multiLevelHeadersEnabled) :

     Algorithme de détection :
     a. Analyser les 3 premières lignes du tableau brut
     b. Ligne d'en-tête NIVEAU 1 (obligatoire si détecté) :
        - Aucune valeur numérique pure dans la ligne
        - Valeurs courtes (< 50 chars) ou présence de mots-clés communs
          (N°, ID, CODE, NOM, DATE, TOTAL, MONTANT, PRIX, QTÉ, REF, DÉSIGNATION...)
     c. Ligne d'en-tête NIVEAU 2 (optionnel) :
        - La ligne suivant la ligne de niveau 1 est aussi non-numérique
        - Ses valeurs ressemblent à des sous-catégories (plus longues ou plus spécifiques)
        - Les colonnes de la ligne L2 sont alignées avec celles de la ligne L1
          (ou certaines cellules de L1 sont fusionnées sur plusieurs colonnes de L2)
     → Construire List<ExtractedTable.HeaderRow> depuis les lignes détectées
     → Le reste est List<ExtractedTable.DataRow>

  3. DÉTECTION DES CELLULES FUSIONNÉES (si options.detectMergedCells() && props.table.mergedCellsDetectionEnabled) :

     Heuristique pour Tabula (qui n'expose pas directement les fusions) :
     - Parcourir chaque ligne ; si une cellule est vide alors que les cellules
       adjacentes de la ligne précédente ou suivante ne le sont pas → possible fusion
     - Détecter les répétitions verticales : même valeur sur N lignes consécutives
       dans la même colonne → rowspan = N
     - Détecter les cellules vides à droite d'une cellule non vide → colspan potentiel
     → Construire List<ExtractedTable.MergedCell>
     Note : Cette détection est heuristique pour Tabula.
             Adobe Extract API retourne les fusions directement depuis structuredData.json.

  4. DÉTECTION DU TYPE DE TABLEAU :

     FINANCIAL : ≥ 2 colonnes avec ≥ 70 % de valeurs numériques ou devise
                 ET (présence de "total", "montant", "prix", "amount", "€", "$", "£" dans les en-têtes)
     FORM      : ≤ 3 colonnes ET colonne 0 = labels textuels longs (> 15 chars)
                 ET colonne 1 = valeurs mixtes courtes → formulaire/fiche
     SCHEDULE  : ≥ 1 colonne avec ≥ 60 % de valeurs parsables comme dates
                 ET présence de mots-clés ("date", "jour", "semaine", "période", "deadline")
     DATA      : cas général (tableau de données sans type dominant)
     UNKNOWN   : < minTableRows ou < minTableCols après nettoyage

  5. FILTRAGE PAR CONFIANCE :
     - Écarter les tableaux dont table.confidence() < options.confidenceThreshold()
     - Logger en DEBUG : "Tableau {index} écarté : confiance {score} < seuil {threshold}"

  6. FILTRAGE PAR INDICES (si options.tableIndices() != null && !empty) :
     - Conserver uniquement les tableaux dont tableIndex est dans options.tableIndices()

  7. RECALCUL DES INDICES :
     - Réindexer les tableaux conservés (tableIndex = 0, 1, 2, ...)
     - Conserver l'index original dans les métadonnées de ExtractedTable pour traçabilité

Méthode utilitaire parseDate(String value) : boolean — tente 10 formats communs.
Méthode utilitaire isNumericOrCurrency(String value) : boolean.
Méthode utilitaire containsHeaderKeyword(String value) : boolean.
```

---

## PROMPT 4 — Générateurs multi-formats (TableOutputFactory)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/TableOutputFactory.java`
- `src/main/java/com/kovixel/core/conversion/table/output/JsonTableWriter.java`
- `src/main/java/com/kovixel/core/conversion/table/output/HtmlTableWriter.java`
- `src/main/java/com/kovixel/core/conversion/table/output/MarkdownTableWriter.java`

**Fichiers à modifier :**
- `pom.xml` (vérifier présence de jackson-databind pour JSON)

```
Crée les writers de sortie pour les 3 nouveaux formats (JSON, HTML, Markdown).
CSV et XLSX délèguent à l'infrastructure existante (ExcelOutputBuilder).

────────────────────────────────────────────────────────────────────
TableOutputFactory.java — façade de dispatch
────────────────────────────────────────────────────────────────────

Classe TableOutputFactory :
- Annotée @Component, @Slf4j
- Injecte : JsonTableWriter, HtmlTableWriter, MarkdownTableWriter, ExcelOutputBuilder

Méthode principale :
  byte[] write(List<ExtractedTable> tables, TableExtractionOptions options) throws IOException

Dispatch selon options.format() :
  JSON     → jsonWriter.write(tables, options)
  HTML     → htmlWriter.write(tables, options)
  MARKDOWN → markdownWriter.write(tables, options)
  CSV      → délègue à ExcelOutputBuilder en convertissant ExtractedTable → TableData
             avec format CSV (réutilise la logique de archives ZIP existante)
  XLSX     → délègue à ExcelOutputBuilder en convertissant ExtractedTable → TableData

Méthode privée toTableData(ExtractedTable table) : TableData
  Conversion : ExtractedTable → TableData (type utilisé par ExcelOutputBuilder)
  - headers → première entrée de rows si hasHeaders()
  - rows    → les DataRow
  - hasHeader → table.hasHeaders()
  - detectedType → table.detectedType()
  - colTypes → List.of(ColumnType.TEXT) × columnCount (types non détectés dans ce flow)

────────────────────────────────────────────────────────────────────
JsonTableWriter.java
────────────────────────────────────────────────────────────────────

Classe JsonTableWriter :
- Annotée @Component, @Slf4j
- Injecte ObjectMapper (Spring auto-configure)

Méthode : byte[] write(List<ExtractedTable> tables, TableExtractionOptions options)

Structure JSON générée (toujours un objet racine, jamais un tableau nu) :

{
  "extraction": {
    "totalTables": 3,
    "generatedAt": "2025-06-01T10:30:00Z",
    "version": "1.0"
  },
  "tables": [
    {
      "index": 0,
      "page": 2,
      "confidence": 0.87,
      "type": "FINANCIAL",
      "columnCount": 5,
      "rowCount": 12,
      "hasHeaders": true,
      "headers": [                        // présent si hasHeaders
        { "rowIndex": 0, "cells": ["N°", "Produit", "Qté", "Prix HT", "Total TTC"] }
      ],
      "multiLevelHeaders": false,         // true si 2+ lignes d'en-tête
      "rows": [
        { "rowIndex": 1, "cells": ["1", "Ordinateur portable", "2", "899.00", "1078.80"] },
        ...
      ],
      "mergedCells": [                    // présent si detectMergedCells=true et cellules détectées
        { "startRow": 0, "startCol": 3, "endRow": 0, "endCol": 4 }
      ],
      "bounds": {                         // présent si includeMetadata=true
        "x1": 56.7, "y1": 320.4, "x2": 538.9, "y2": 521.6,
        "pageWidth": 595.3, "pageHeight": 841.9,
        "leftPct": 9.53, "topPct": 37.95, "widthPct": 80.98, "heightPct": 23.94
      }
    }
  ]
}

Si options.includeMetadata() = false : omettre les champs "bounds" et "confidence" dans la sortie.
Utiliser ObjectMapper.writerWithDefaultPrettyPrinter() pour une sortie lisible.
Encodage : UTF-8.

────────────────────────────────────────────────────────────────────
HtmlTableWriter.java
────────────────────────────────────────────────────────────────────

Classe HtmlTableWriter :
- Annotée @Component

Méthode : byte[] write(List<ExtractedTable> tables, TableExtractionOptions options)

Structure HTML générée :

<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="generator" content="Kovixel Table Extractor">
  <title>Tableaux extraits</title>
  <style>
    /* CSS minimal embarqué — classes préfixées kovixel- pour éviter les conflits */
    .kovixel-table-wrapper { margin: 2em 0; font-family: Arial, sans-serif; }
    .kovixel-table-meta    { font-size: 0.85em; color: #6b7280; margin-bottom: 0.5em; }
    .kovixel-table         { border-collapse: collapse; width: 100%; }
    .kovixel-table th      { background: #1e40af; color: white; padding: 8px 12px; text-align: left; }
    .kovixel-table td      { border: 1px solid #e5e7eb; padding: 6px 10px; }
    .kovixel-table tr:nth-child(even) td { background: #f0f4ff; }
    .kovixel-badge-financial { color: #065f46; background: #d1fae5; border-radius: 4px; padding: 2px 8px; }
    .kovixel-badge-schedule  { color: #1e3a5f; background: #dbeafe; border-radius: 4px; padding: 2px 8px; }
    .kovixel-badge-form      { color: #4c1d95; background: #ede9fe; border-radius: 4px; padding: 2px 8px; }
  </style>
</head>
<body>

Pour chaque ExtractedTable :
  <div class="kovixel-table-wrapper" data-table-index="0" data-page="2" data-confidence="0.87">
    <div class="kovixel-table-meta">
      Tableau 1 — Page 2 — <span class="kovixel-badge-financial">Données financières</span>
      — 12 lignes × 5 colonnes
      [si includeMetadata : · Confiance : 87 %]
    </div>
    <table class="kovixel-table">
      <thead>
        <tr>
          <th scope="col" [colspan si mergedCell]>N°</th>
          ...
        </tr>
      </thead>
      <tbody>
        <tr>
          <td [rowspan si mergedCell]>1</td>
          ...
        </tr>
      </tbody>
    </table>
  </div>

</body>
</html>

Règles de génération HTML :
- Échapper systématiquement les caractères HTML dans les cellules (< > & " ')
  via HtmlUtils.htmlEscape(value) (Spring Web)
- Appliquer colspan/rowspan depuis mergedCells si detectMergedCells=true
- Si la table a 2 lignes d'en-tête → 2 <tr> dans <thead>
- Encodage : UTF-8 avec BOM pour compatibilité Excel "Ouvrir dans le navigateur"

────────────────────────────────────────────────────────────────────
MarkdownTableWriter.java
────────────────────────────────────────────────────────────────────

Classe MarkdownTableWriter :
- Annotée @Component

Méthode : byte[] write(List<ExtractedTable> tables, TableExtractionOptions options)

Structure Markdown générée (GitHub Flavored Markdown) :

# Tableaux extraits

_Généré par Kovixel · {date}_

---

## Tableau 1 · Page 2 · Données financières

| N° | Produit | Qté | Prix HT | Total TTC |
|----|---------|-----|---------|-----------|
| 1  | Ordinateur portable | 2 | 899.00 | 1 078.80 |
...

---

Règles Markdown :
- Largeur des colonnes alignée sur le contenu maximal de la colonne
  (pour une meilleure lisibilité dans les éditeurs de texte)
- Caractères | et \ dans les cellules → échapper avec \| et \\
- Sauts de ligne dans les cellules → remplacer par espace (Markdown ne supporte pas)
- Si detectMergedCells : ajouter une note *(\*) Certaines cellules sont fusionnées dans l'original*
- Si 0 table : générer un message d'avertissement en italic + code block du texte brut
- Encodage : UTF-8 sans BOM
```

---

## PROMPT 5 — Adaptateur Adobe Extract pour ExtractedTable

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/excel/AdobeExtractClient.java`

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/AdobeTableExtractAdapter.java`

```
Crée AdobeTableExtractAdapter.java — adaptateur qui réutilise AdobeExtractClient
pour retourner des ExtractedTable (avec métadonnées riches) au lieu de TableData.

CONTEXTE : AdobeExtractClient.extractTables() retourne déjà List<TableData>
en parsant les XLSX de réponse Adobe. Le structuredData.json contient des
métadonnées supplémentaires (bounds, confidence, merged cells) non exploitées.
Cet adaptateur les exploite.

Classe AdobeTableExtractAdapter :
- Annotée @Component, @Slf4j
- Injecte AdobeExtractClient, ObjectMapper (Jackson)

Méthode principale :
  List<ExtractedTable> extractTables(byte[] pdfBytes, TableExtractionOptions options)

  1. Appelle AdobeExtractClient avec les options correspondantes
     (réutilise le flux : token → asset → job → poll → ZIP)
  2. Dézippe le ZIP de réponse Adobe
  3. Parse structuredData.json :

     Structure du structuredData.json Adobe (relevant pour les tableaux) :
     {
       "elements": [
         {
           "Path": "//Document/Sect[1]/Table[1]",
           "Page": 2,
           "Bounds": [56.7, 320.4, 538.9, 521.6],  // [x1, y1, x2, y2] en points PDF
           "Attributes": {
             "HeaderRows": 1,
             "ColumnCount": 5,
             "RowCount": 13,
             "MergedCells": [
               { "RowSpan": 1, "ColSpan": 2, "RowIndex": 0, "ColIndex": 3 }
             ]
           }
         }
       ]
     }

  4. Pour chaque élément de type "Table" dans elements :
     a. Lire les fichiers tables/fileoutpart{N}Table{M}.xlsx dans le ZIP
     b. Parser le XLSX avec Apache POI → extraire les lignes/cellules
     c. Construire ExtractedTable avec :
        - confidence = 0.95 (Adobe Extract a toujours une haute confiance)
        - bounds = BoundingBox depuis element.Bounds[]
          (récupérer pageWidth/pageHeight depuis PDFBox sur le PDF original)
        - mergedCells = depuis element.Attributes.MergedCells
        - headers = premières HeaderRows lignes (depuis element.Attributes.HeaderRows)
        - detectedType = détecter depuis les données (heuristique simple)

  5. Retourner la liste des ExtractedTable

Méthode isConfigured() : délègue à adobeExtractClient.isConfigured()

En cas d'erreur → logger WARN + lancer TableExtractionException (pas AdobeExtractException)
pour que le Router puisse faire le fallback correctement.
```

---

## PROMPT 6 — Router multi-moteur (TableExtractionRouter)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionRouter.java`

```
Crée TableExtractionRouter.java — orchestre le choix du moteur d'extraction,
le post-traitement et la génération de la sortie.

Classe TableExtractionRouter :
- Annotée @Component, @Slf4j
- Injecte : ConversionProperties, AdobeTableExtractAdapter, TableExtractionEngine,
            TableExtractionPostProcessor, TableOutputFactory,
            UserRepository, MeterRegistry

Méthode principale :
  TableExtractionResult route(byte[] pdfBytes, TableExtractionOptions options, Long userId)

Logique de routage :

  long startMs = System.currentTimeMillis();

  1. Résoudre le plan utilisateur (FREE si userId=null)

  2. Sélectionner le moteur et extraire les ExtractedTable bruts :

     Si plan = PRO ou ENTERPRISE
        ET props.table.adobeExtractEnabled
        ET adobeTableExtractAdapter.isConfigured() :

        String engine = "ADOBE_EXTRACT";
        try {
            rawTables = adobeTableExtractAdapter.extractTables(pdfBytes, options);
        } catch (TableExtractionException e) {
            log.warn("Basculement ADOBE_EXTRACT→TABULA : {}", e.getMessage());
            meterRegistry.counter("kovixel.conversion.extract_tables.fallback",
                "from", "ADOBE_EXTRACT", "to", "TABULA",
                "reason", e.getClass().getSimpleName()).increment();
            engine = "TABULA";
            rawTables = tableExtractionEngine.extract(pdfBytes, options);
        }

     Sinon :
        engine = "TABULA";
        rawTables = tableExtractionEngine.extract(pdfBytes, options);

        // Fallback PDFBox si 0 table trouvée avec stratégie AUTO
        if (rawTables.isEmpty() && options.strategy() == ExtractionStrategy.AUTO) {
            log.debug("0 tableau détecté avec Tabula, tentative PDFBox positionnel...");
            engine = "PDFBOX";
            rawTables = tableExtractionEngine.extractWithPdfBoxFallback(pdfBytes, options);
        }

  3. Post-traitement :
     List<ExtractedTable> allTables = rawTables;  // conservation avant filtrage
     List<ExtractedTable> tables = postProcessor.process(rawTables, options);

  4. Génération de la sortie :
     byte[] outputBytes = outputFactory.write(tables, options);

  5. Calculer les statistiques :
     double avgConfidence = tables.stream()
         .mapToDouble(ExtractedTable::confidence)
         .average().orElse(0.0);
     int totalRows = tables.stream().mapToInt(ExtractedTable::rowCount).sum();
     int totalPages = /* nombre de pages uniques dans tables */;
     long durationMs = System.currentTimeMillis() - startMs;

  6. Enregistrer les métriques (voir PROMPT 8)

  7. Retourner :
     new TableExtractionResult(
         tables, allTables, options.format(), engine,
         allTables.size(), tables.size(), totalRows, totalPages,
         avgConfidence, durationMs, outputBytes
     )

Méthode previewRoute(byte[] pdfBytes, TableExtractionOptions previewOptions, Long userId) :
  TableExtractionResult
  → Identique à route() mais :
    a. Forcer options.format() = JSON (la sortie preview est toujours JSON)
    b. Forcer options.includeMetadata() = true (on veut les bounds pour l'overlay)
    c. Ne PAS appeler outputFactory.write() → générer uniquement le JSON de métadonnées
       (bounds, confidence, type, page — PAS les données lignes/colonnes)
    d. Retourner TableExtractionResult avec outputBytes = JSON de métadonnées uniquement
  → Cette méthode est rapide car elle évite la génération du fichier de sortie final.
```

---

## PROMPT 7 — Endpoint API enrichi

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Ajoute les deux endpoints de l'outil "Extraire Tableaux" dans ConversionController.java.

────────────────────────────────────────────────────────────────────
Endpoint principal :
────────────────────────────────────────────────────────────────────

@PostMapping("/api/v1/convert/extract-tables")
@Operation(summary = "Extraire Tableaux — JSON, HTML, Markdown, CSV, XLSX")
@CheckQuota(feature = FeatureType.CONVERSION)
public ResponseEntity<?> extractTables(
    @RequestParam("file")                         MultipartFile file,
    @RequestParam(defaultValue = "json")          String format,
    @RequestParam(defaultValue = "auto")          String strategy,
    @RequestParam(required = false)               String pages,
    @RequestParam(defaultValue = "0.4")           double confidenceThreshold,
    @RequestParam(required = false)               List<Integer> tableIndices,
    @RequestParam(defaultValue = "true")          boolean includeMetadata,
    @RequestParam(defaultValue = "true")          boolean cleanData,
    @RequestParam(defaultValue = "true")          boolean detectMergedCells,
    @RequestParam(defaultValue = "true")          boolean detectMultiLevelHeaders,
    @AuthenticationPrincipal UserDetails userDetails) throws Exception

Validation :
  - format              → TableOutputFormat.fromStringStrict(format) [sinon 400]
  - strategy            → ExtractionStrategy.fromString(strategy)    [AUTO si inconnu]
  - pages               → PageSelectionParser.parse(pages)           [réutilise l'existant]
  - confidenceThreshold → doit être dans [0.0, 1.0] sinon 400
  - tableIndices        → si présent, doit contenir uniquement des entiers >= 0

Seuil async : file.getSize() > props.getTable().getAsyncThresholdBytes()
  → soumettre un job asynchrone, retourner HTTP 202 + { jobId, pollUrl }

Flow synchrone :
  1. Valider les paramètres
  2. Construire TableExtractionOptions
  3. tableExtractionRouter.route(file.getBytes(), options, resolveUserIdOptional(userDetails))
  4. Construire la réponse HTTP

Réponse :
  - HTTP 200 + outputBytes
  - Content-Type selon format.getMimeType()
  - Nom de fichier : "{baseName}_tables.{ext}" ou "{baseName}_tables.zip" si CSV

Headers de réponse :
  X-Extraction-Engine:         ADOBE_EXTRACT | TABULA | PDFBOX
  X-Tables-Detected:           nombre de tableaux détectés (avant filtrage)
  X-Tables-Exported:           nombre de tableaux dans le fichier de sortie (après filtrage)
  X-Total-Rows:                nombre total de lignes extraites
  X-Pages-Analyzed:            nombre de pages analysées
  X-Average-Confidence:        score moyen de confiance (ex : "0.82")
  X-Processing-Time-Ms:        durée en ms
  Content-Disposition:         attachment; filename="..."
  X-Async-Job-Id:              présent uniquement si async

Si 0 tableau exporté après filtrage :
  - Retourner HTTP 200 avec un fichier de sortie contenant un message d'avertissement
    (JSON : { "tables": [], "warning": "..." }, HTML : message rouge, Markdown : message italic)
  - Header X-Warning: "NO_TABLES_FOUND — essayer un seuil de confiance plus bas ou une autre stratégie"

────────────────────────────────────────────────────────────────────
Endpoint de prévisualisation :
────────────────────────────────────────────────────────────────────

@PostMapping("/api/v1/convert/extract-tables/preview")
@Operation(summary = "Prévisualisation des tableaux détectés (positions uniquement, sans données)")
@CheckQuota(feature = FeatureType.CONVERSION)
public ResponseEntity<Map<String, Object>> extractTablesPreview(
    @RequestParam("file")                         MultipartFile file,
    @RequestParam(defaultValue = "auto")          String strategy,
    @RequestParam(required = false)               String pages,
    @RequestParam(defaultValue = "0.3")           double confidenceThreshold,
    @AuthenticationPrincipal UserDetails userDetails) throws Exception

Vérifie que props.table.previewEnabled = true (sinon 503).
Construit TableExtractionOptions.previewOnly() avec les paramètres.
Appelle tableExtractionRouter.previewRoute().

Réponse JSON :
{
  "totalDetected": 3,
  "processingTimeMs": 420,
  "tables": [
    {
      "index": 0,
      "page": 2,
      "confidence": 0.87,
      "type": "FINANCIAL",
      "rowCount": 12,
      "columnCount": 5,
      "bounds": {
        "leftPct": 9.53, "topPct": 37.95,
        "widthPct": 80.98, "heightPct": 23.94
      }
    }
  ]
}

Cet endpoint est utilisé par le frontend pour dessiner les overlays sur le PDF
AVANT que l'utilisateur choisisse les tableaux à exporter.
```

---

## PROMPT 8 — Métriques & Health Indicator

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/table/TableExtractionRouter.java`
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`

```
1. Dans TableExtractionRouter, ajoute les métriques Micrometer complètes APRÈS
   la construction de TableExtractionResult :

   // ── Compteur global ──────────────────────────────────────────────────────
   Counter.builder("kovixel.conversion.extract_tables.total")
       .tag("engine",  result.engine())
       .tag("format",  options.format().name())
       .tag("plan",    plan.name())
       .tag("status",  result.totalTablesExported() > 0 ? "TABLES_FOUND" : "NO_TABLES")
       .register(meterRegistry)
       .increment();

   // ── Timer de durée ───────────────────────────────────────────────────────
   Timer.builder("kovixel.conversion.extract_tables.duration")
       .tag("engine", result.engine())
       .tag("format", options.format().name())
       .register(meterRegistry)
       .record(result.durationMs(), TimeUnit.MILLISECONDS);

   // ── Distribution : tableaux détectés ─────────────────────────────────────
   DistributionSummary.builder("kovixel.conversion.extract_tables.tables_detected")
       .tag("engine", result.engine())
       .register(meterRegistry)
       .record(result.totalTablesDetected());

   // ── Distribution : confiance moyenne ─────────────────────────────────────
   DistributionSummary.builder("kovixel.conversion.extract_tables.avg_confidence")
       .tag("engine", result.engine())
       .register(meterRegistry)
       .record(result.averageConfidence());

   // ── Stratégie réellement utilisée ────────────────────────────────────────
   Counter.builder("kovixel.conversion.extract_tables.strategy_used")
       .tag("requested", options.strategy().name())
       .tag("actual",    result.engine())
       .register(meterRegistry)
       .increment();

2. Dans ConversionEngineHealthIndicator, ajoute :

   // ── TableExtractionEngine (Tabula) ───────────────────────────────────────
   details.put("table.tabula", "UP");
   details.put("table.tabula.algorithms", "SPREADSHEET, BASIC, PDFBOX_FALLBACK");

   // ── Adobe Extract (pour les tableaux) ─────────────────────────────────────
   if (props.getTable().isAdobeExtractEnabled()) {
       boolean adobeConfigured = props.getAdobe().isConfigured();
       details.put("table.adobe.extract", adobeConfigured ? "UP" : "DOWN");
       details.put("table.adobe.extract.note",
           adobeConfigured ? "Credentials présents" : "ADOBE_CLIENT_ID/SECRET manquants");
   } else {
       details.put("table.adobe.extract", "DISABLED");
   }

   // ── Endpoint preview ──────────────────────────────────────────────────────
   details.put("table.preview",
       props.getTable().isPreviewEnabled() ? "ENABLED" : "DISABLED");
```

---

## PROMPT 9 — Frontend Angular : composant dédié

**Fichiers à créer :**
- `kovixel-ui/src/app/features/tools/extract-tables/extract-tables.component.ts`
- `kovixel-ui/src/app/features/tools/extract-tables/extract-tables.component.html`
- `kovixel-ui/src/app/features/tools/extract-tables/extract-tables.component.css`

**Fichiers à modifier :**
- `kovixel-ui/src/app/app.routes.ts`
- `kovixel-ui/src/app/core/config/tools-config.ts` (si existant)
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
Crée un composant Angular DÉDIÉ pour "Extraire Tableaux" avec une UX premium
et une prévisualisation interactive des tableaux détectés.

────────────────────────────────────────────────────────────────────
ExtractTablesComponent (standalone, OnPush)
────────────────────────────────────────────────────────────────────

Signaux :
  // État global
  selectedFile          = signal<File | null>(null)
  state                 = signal<'idle'|'selected'|'previewing'|'uploading'|'success'|'error'>('idle')
  uploadProgress        = signal(0)
  errorMessage          = signal('')

  // Options d'extraction
  selectedFormat        = signal<'json'|'html'|'md'|'csv'|'xlsx'>('json')
  selectedStrategy      = signal<string>('auto')
  confidenceThreshold   = signal<number>(40)   // 0–100 (affiché en %, stocké en 0–1)
  includeMetadata       = signal<boolean>(true)
  cleanData             = signal<boolean>(true)
  detectMergedCells     = signal<boolean>(true)
  detectMultiHeaders    = signal<boolean>(true)
  pageMode              = signal<'all'|'single'|'range'>('all')
  singlePage            = signal<number>(1)
  rangeFrom             = signal<number>(1)
  rangeTo               = signal<number>(10)

  // Prévisualisation
  previewTables         = signal<PreviewTable[]>([])
  selectedTableIndices  = signal<Set<number>>(new Set())
  isPreviewLoading      = signal<boolean>(false)

  // Résultats
  tablesDetected        = signal<number | null>(null)
  tablesExported        = signal<number | null>(null)
  totalRows             = signal<number | null>(null)
  averageConfidence     = signal<number | null>(null)
  engine                = signal<string | null>(null)
  resultBlob            = signal<Blob | null>(null)
  resultFilename        = signal<string>('')

Interface PreviewTable :
  index: number
  page: number
  confidence: number          // 0.0–1.0
  type: string
  rowCount: number
  columnCount: number
  bounds: { leftPct, topPct, widthPct, heightPct }
  isSelected: boolean

────────────────────────────────────────────────────────────────────
Template (sections dans l'ordre d'affichage)
────────────────────────────────────────────────────────────────────

╔═══════════════════════════════════════════════════════════════════╗
║  1. DROP ZONE                                                     ║
║  Zone glisser-déposer PDF — identique aux autres composants       ║
║  Drag & drop ou clic → selectedFile + state='selected'            ║
║  Après sélection → lancer automatiquement la prévisualisation     ║
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║  2. PRÉVISUALISATION (visible quand state = 'previewing' ou       ║
║     previewTables.length > 0)                                     ║
║                                                                   ║
║  ┌──────────────────────────────────────────────────────────┐    ║
║  │  🔍 X tableaux détectés dans ce PDF                      │    ║
║  │                                                          │    ║
║  │  [Tableau 1 — Page 2 — Données financières  [87%] ☑]    │    ║
║  │  [Tableau 2 — Page 3 — Données             [72%] ☑]    │    ║
║  │  [Tableau 3 — Page 5 — Planning            [45%] ☐]    │    ║
║  │                                                          │    ║
║  │  ○ Tout sélectionner  ○ Désélectionner tout              │    ║
║  └──────────────────────────────────────────────────────────┘    ║
║                                                                   ║
║  - Badge coloré selon le type (FINANCIAL=vert, SCHEDULE=bleu...  ║
║  - Barre de confiance visuelle (couleur : vert >70%, orange >40%,║
║    rouge <40%)                                                    ║
║  - Clic sur un tableau → toggle sélection                        ║
║  - Badge "Exclu (confiance faible)" si confidence < threshold    ║
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║  3. OPTIONS D'EXPORT (visible quand state = 'selected')           ║
║                                                                   ║
║  FORMAT DE SORTIE — 5 chips :                                     ║
║  ┌──────┐ ┌──────┐ ┌──────┐ ┌─────┐ ┌──────┐                   ║
║  │ JSON │ │ HTML │ │  MD  │ │ CSV │ │ XLSX │                   ║
║  └──────┘ └──────┘ └──────┘ └─────┘ └──────┘                   ║
║  Tooltip JSON : "Données structurées — idéal pour l'intégration" ║
║  Tooltip HTML : "Tableaux prêts à intégrer dans vos pages web"   ║
║  Tooltip MD   : "Markdown GitHub-flavored — README, docs"        ║
║  Tooltip CSV  : "Archive ZIP — un fichier CSV par tableau"       ║
║  Tooltip XLSX : "Microsoft Excel — avec styles et en-têtes"      ║
║                                                                   ║
║  SEUIL DE CONFIANCE :                                            ║
║  ──────────────────────────────────────── 40%                    ║
║  [     Slider 0–100% avec affichage en temps réel     ]          ║
║  ← Inclure plus de tableaux    Exclure les incertains →          ║
║                                                                   ║
║  OPTIONS AVANCÉES (section repliable) :                          ║
║  ☑ Inclure les métadonnées (position, confiance)                 ║
║  ☑ Nettoyer les données (trim, normalisation)                    ║
║  ☑ Détecter les cellules fusionnées (colspan/rowspan)            ║
║  ☑ Détecter les en-têtes multi-niveaux                           ║
║                                                                   ║
║  STRATÉGIE D'EXTRACTION :                                        ║
║  ○ Auto (recommandé)  ○ Rulings  ○ Stream  ○ Texte               ║
║                                                                   ║
║  SÉLECTION DE PAGES :                                            ║
║  ● Toutes les pages  ○ Page spécifique [_]  ○ Plage [_] à [_]   ║
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║  4. BOUTON D'ACTION                                               ║
║  [🗄 Extraire {N} tableau(x) sélectionné(s) · Format: JSON]      ║
║  Désactivé si aucun tableau sélectionné                          ║
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║  5. ÉTAT UPLOADING                                                ║
║  Barre de progression 3 phases :                                  ║
║  ⬤───○───○  Envoi du fichier...                                  ║
║  ⬤───⬤───○  Extraction en cours...                              ║
║  ⬤───⬤───⬤  Génération du fichier...                            ║
╚═══════════════════════════════════════════════════════════════════╝

╔═══════════════════════════════════════════════════════════════════╗
║  6. ÉTAT SUCCESS                                                  ║
║                                                                   ║
║  ✅ Extraction réussie                                            ║
║                                                                   ║
║  📊 3 tableaux exportés sur 4 détectés                           ║
║  📝 156 lignes · 🤖 TABULA · ⭐ Confiance moy. : 78%            ║
║  ⚡ 1.2s                                                          ║
║                                                                   ║
║  [↓ Télécharger tables.json (12 KB)]                             ║
║                                                                   ║
║  [🔄 Changer de format]  [📋 Autre fichier]                      ║
╚═══════════════════════════════════════════════════════════════════╝

Si 0 tableaux exportés après filtrage :
╔═══════════════════════════════════════════════════════════════════╗
║  ⚠ Aucun tableau exporté                                         ║
║  4 tableaux ont été détectés mais tous sont en dessous du seuil  ║
║  de confiance (40%). Essayez :                                   ║
║  • Baisser le seuil de confiance                                 ║
║  • Changer la stratégie → "Stream" ou "Texte"                   ║
║  [🔄 Baisser le seuil à 20%]  [↓ Tout exporter quand même]      ║
╚═══════════════════════════════════════════════════════════════════╝

────────────────────────────────────────────────────────────────────
ConversionService Angular — nouvelles méthodes
────────────────────────────────────────────────────────────────────

Dans conversion.service.ts, ajoute :

  // Prévisualisation (avant l'extraction complète)
  previewTables(
    file: File,
    strategy: string = 'auto',
    pages: string = 'all',
    confidenceThreshold: number = 0.3
  ): Observable<PreviewResponse>
  → POST /api/v1/convert/extract-tables/preview
  → responseType: 'json'

  // Extraction complète
  extractTables(
    file: File,
    format: 'json' | 'html' | 'md' | 'csv' | 'xlsx' = 'json',
    strategy: string = 'auto',
    pages: string = 'all',
    confidenceThreshold: number = 0.4,
    tableIndices: number[] | null = null,
    includeMetadata: boolean = true,
    cleanData: boolean = true,
    detectMergedCells: boolean = true,
    detectMultiLevelHeaders: boolean = true
  ): Observable<HttpEvent<Blob>>
  → POST /api/v1/convert/extract-tables avec tous les paramètres
  → responseType: 'blob', observe: 'events', reportProgress: true
  → Lire les headers :
      X-Tables-Detected, X-Tables-Exported, X-Total-Rows,
      X-Average-Confidence, X-Extraction-Engine, X-Processing-Time-Ms

Dans app.routes.ts, ajoute AVANT la route générique :
  {
    path: 'tools/convert/extract-tables',
    loadComponent: () =>
      import('./features/tools/extract-tables/extract-tables.component')
        .then(m => m.ExtractTablesComponent),
    data: { title: 'Extraire Tableaux' }
  }

Dans tools-config.ts (si existant), mets à jour :
  description: 'Détectez et exportez les tableaux en JSON, HTML, Markdown, CSV ou Excel.'
  longDescription: 'Prévisualisez les tableaux détectés, sélectionnez-les interactivement,
                    ajustez le seuil de confiance et exportez dans le format de votre choix.
                    Utilise Tabula (FREE) ou Adobe Extract API (PRO) avec scoring de confiance,
                    détection des cellules fusionnées et en-têtes multi-niveaux.'
```

---

## PROMPT 10 — Tests complets

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/table/TableExtractionEngineTest.java`
- `src/test/java/com/kovixel/core/conversion/table/TableExtractionPostProcessorTest.java`
- `src/test/java/com/kovixel/core/conversion/table/TableOutputFactoryTest.java`
- `src/test/java/com/kovixel/core/conversion/table/TableExtractionRouterTest.java`

```
────────────────────────────────────────────────────────────────────
TableExtractionEngineTest (JUnit 5 + Mockito)
────────────────────────────────────────────────────────────────────

PDF de test : générer un mini-PDF avec PDFBox contenant un tableau simple :
  static byte[] buildTestPdfWithTable() {
      PDDocument doc = new PDDocument();
      PDPage page = new PDPage(PDRectangle.A4);
      doc.addPage(page);
      // Ajouter du texte tabulaire avec PDPageContentStream (simuler 2 colonnes × 3 lignes)
      // Utiliser une police standard et des positions X fixes pour simuler l'alignement
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      doc.save(out); doc.close();
      return out.toByteArray();
  }

@Test extractsTablesFromSimplePdf()
  - PDF 1 page avec tableau → résultat non vide
  - Vérifie : ≥ 1 ExtractedTable, confidence > 0.0

@Test returnsEmptyListForPdfWithoutTables()
  - PDF 1 page avec texte libre (sans tableau)
  - Vérifie : résultat vide (pas d'exception)

@Test respectsMaxPagesLimit()
  - props.table.maxPages = 2 ; PDF 5 pages → KovixelException HTTP 400

@Test calculateConfidenceIsInRange()
  - Pour tout PDF, la confiance de chaque ExtractedTable doit être dans [0.0, 1.0]

@Test strategyTextUsesPdfBoxFallback()
  - options.strategy() = TEXT → extractWithPdfBoxFallback() est appelé (pas Tabula)
  - Vérifier que la confidence est 0.3 (valeur fixe pour PDFBox)

────────────────────────────────────────────────────────────────────
TableExtractionPostProcessorTest (JUnit 5 — tests purs, sans PDF)
────────────────────────────────────────────────────────────────────

Builder d'ExtractedTable pour les tests :
  static ExtractedTable buildTable(List<List<String>> rawRows) {
      // Crée un ExtractedTable avec headers vides, confidence=0.8, page=1...
  }

@Test cleansDataWhenEnabled()
  - Cellule "  hello  world  " → "hello world" (trim + espaces multiples)
  - Cellule "\u0001corrupted" → "corrupted" (caractère de contrôle supprimé)

@Test doesNotCleanDataWhenDisabled()
  - options.cleanData() = false → cellule inchangée

@Test detectsSimpleHeaderRow()
  - Première ligne : ["N°", "Produit", "Quantité", "Prix HT", "Total TTC"]
  - Lignes suivantes : [["1", "Laptop", "2", "899.00", "1078.80"], ...]
  - Vérifie : hasHeaders = true, headers.size() = 1

@Test detectsMultiLevelHeaders()
  - Ligne 1 : ["Produit", "", "Tarifs", ""]
  - Ligne 2 : ["Nom", "Référence", "HT", "TTC"]
  - Lignes données : [["Laptop", "REF001", "899", "1078"]]
  - Vérifie : hasHeaders = true, headers.size() = 2

@Test filtersTablesBelowConfidenceThreshold()
  - 3 tableaux avec confidence 0.8, 0.5, 0.3 ; threshold = 0.4
  - Vérifie : 2 tableaux retournés (0.8 et 0.5), le 0.3 écarté

@Test filtersTablesByIndices()
  - 4 tableaux ; options.tableIndices() = [0, 2]
  - Vérifie : 2 tableaux retournés (les index 0 et 2)

@Test detectsFinancialTableType()
  - Tableau avec colonnes : ["Produit", "Prix HT €", "TVA", "Total TTC"]
  - Données : [["Laptop", "899.00", "179.80", "1078.80"], ...]
  - Vérifie : detectedType = "FINANCIAL"

@Test detectsScheduleTableType()
  - Tableau avec colonnes : ["Date", "Événement", "Lieu"]
  - Données : [["01/06/2025", "Réunion", "Paris"], ...]
  - Vérifie : detectedType = "SCHEDULE"

@Test detectsMergedCellsHeuristic()
  - Lignes : [["A", "B", "C"], ["A", "", ""], ["", "D", "E"]]
  - Vérifie : mergedCells non vide (au moins une fusion détectée)

────────────────────────────────────────────────────────────────────
TableOutputFactoryTest (JUnit 5)
────────────────────────────────────────────────────────────────────

@Test writesValidJson()
  - 2 tableaux → JSON valide parsable avec Jackson
  - Vérifie : champ "tables" est un array de taille 2
  - Vérifie : chaque table a "index", "page", "rows"

@Test includesMetadataInJsonWhenEnabled()
  - options.includeMetadata() = true → champ "bounds" présent
  - options.includeMetadata() = false → champ "bounds" absent

@Test writesValidHtml()
  - 2 tableaux → HTML contenant 2 éléments <table>
  - Vérifie : les valeurs des cellules sont correctement échappées (< → &lt;)
  - Vérifie : les en-têtes sont dans <thead>

@Test writesValidMarkdown()
  - 1 tableau 3×2 → Markdown avec ligne de séparation (---|---|---...)
  - Vérifie : les | dans les cellules sont échappés en \|

@Test handlesPipeInCellValue()
  - Cellule contenant "A | B" → "A \| B" dans Markdown
  - Cellule contenant "A | B" → "A | B" dans HTML (HTML le supporte nativement)

@Test buildsEmptyTableWarningJson()
  - Liste vide → JSON avec champ "warning" et "tables": []

@Test csvZipContainsOneCsvPerTable()
  - 3 tableaux → format CSV → ZIP avec 3 fichiers CSV + manifest.csv

────────────────────────────────────────────────────────────────────
TableExtractionRouterTest (Mockito, @ExtendWith(MockitoExtension.class))
────────────────────────────────────────────────────────────────────

@Test freePlanUsesTabula()
  - userId = null (anonyme) → TableExtractionEngine appelé
  - AdobeTableExtractAdapter non appelé

@Test proWithAdobeConfiguredUsesAdobe()
  - plan = PRO, adobeExtractEnabled = true, isConfigured = true
  - AdobeTableExtractAdapter.extractTables() appelé

@Test adobeFailureFallsBackToTabula()
  - Adobe lève TableExtractionException
  - TableExtractionEngine.extract() appelé ensuite
  - Métrique "kovixel.conversion.extract_tables.fallback" incrémentée

@Test tabulaZeroTablesTriggersAutoFallbackToPdfBox()
  - Tabula retourne une liste vide
  - options.strategy() = AUTO → extractWithPdfBoxFallback() appelé ensuite
  - engine dans le résultat = "PDFBOX"

@Test routerCallsPostProcessorAndOutputFactory()
  - Vérifier que TableExtractionPostProcessor.process() ET TableOutputFactory.write()
    sont bien appelés exactement une fois

@Test previewRouteReturnsOnlyMetadataJson()
  - previewRoute() ne doit pas appeler TableOutputFactory.write()
  - Le JSON retourné ne doit pas contenir de champ "rows" (données)
```

---

## PROMPT 11 — Documentation & Variables d'environnement

**Fichiers à modifier :**
- `README.md` (section "Extraire Tableaux")
- `.env.example`

```
Dans README.md, ajoute une section "## Extraire Tableaux" :

### Moteurs d'extraction

| Moteur              | Qualité   | Plan requis | Forces                                             |
|---------------------|-----------|-------------|----------------------------------------------------|
| Adobe Extract API   | ★★★★★    | PRO         | OCR, cellules fusionnées, en-têtes multi-niveaux   |
| Tabula Spreadsheet  | ★★★★☆    | FREE        | Précis sur tableaux avec lignes visibles           |
| Tabula Basic        | ★★★☆☆    | FREE        | Tableaux alignés par espacements                   |
| PDFBox positionnel  | ★★☆☆☆    | FREE        | Fallback texte brut                                |

### Formats de sortie

| Format   | Description                         | Cas d'usage optimal                         |
|----------|-------------------------------------|---------------------------------------------|
| json     | Données structurées + métadonnées   | Intégration API, traitement programmatique  |
| html     | Tableaux HTML avec CSS              | Intégration web, emails, documentation      |
| md       | Markdown GitHub-flavored            | README, docs GitHub/GitLab, Notion          |
| csv      | Archive ZIP (un CSV par tableau)    | Python, R, Data Science, tableurs           |
| xlsx     | Microsoft Excel avec styles         | Reporting, analyse métier                   |

### Paramètres API

| Paramètre              | Type          | Défaut | Description                                  |
|------------------------|---------------|--------|----------------------------------------------|
| file                   | File          | —      | PDF à analyser (multipart)                   |
| format                 | String        | json   | Format : json, html, md, csv, xlsx           |
| strategy               | String        | auto   | Stratégie : auto, ruling, stream, text       |
| pages                  | String        | all    | Sélection : all, 3, 2-7                      |
| confidenceThreshold    | double        | 0.4    | Seuil de confiance [0.0–1.0]                 |
| tableIndices           | int[]         | null   | Index des tableaux à exporter (null = tous)  |
| includeMetadata        | boolean       | true   | Inclure bounding boxes + scores              |
| cleanData              | boolean       | true   | Normalisation Unicode + trim                 |
| detectMergedCells      | boolean       | true   | Détection colspan/rowspan                    |
| detectMultiLevelHeaders| boolean       | true   | En-têtes sur plusieurs lignes                |

### Endpoint de prévisualisation

`POST /api/v1/convert/extract-tables/preview`

Retourne uniquement les positions (bounding boxes) des tableaux détectés,
sans les données. Utilisé par le frontend pour afficher les overlays sur le PDF.
Paramètres : file, strategy, pages, confidenceThreshold.

### Headers de réponse

| Header                  | Description                                      |
|-------------------------|--------------------------------------------------|
| X-Extraction-Engine     | ADOBE_EXTRACT \| TABULA \| PDFBOX                |
| X-Tables-Detected       | Nombre de tableaux détectés (avant filtrage)     |
| X-Tables-Exported       | Nombre de tableaux dans le fichier (après filtre)|
| X-Total-Rows            | Nombre total de lignes extraites                 |
| X-Pages-Analyzed        | Nombre de pages analysées                        |
| X-Average-Confidence    | Score moyen de confiance (ex : "0.82")           |
| X-Processing-Time-Ms    | Durée de traitement en ms                        |
| X-Warning               | Présent si aucun tableau exporté (NO_TABLES_FOUND)|

### Score de confiance

Le score de confiance (0.0–1.0) évalue la probabilité qu'un élément détecté
soit réellement un tableau structuré :

| Score     | Interprétation                               |
|-----------|----------------------------------------------|
| ≥ 0.80    | Tableau certain (lignes visibles, homogène)  |
| 0.60–0.79 | Tableau probable (bien structuré)            |
| 0.40–0.59 | Tableau possible (vérification recommandée)  |
| < 0.40    | Faux positif probable (exclu par défaut)     |

### Variables d'environnement

Aucune variable supplémentaire requise pour le plan FREE.
Pour le plan PRO, les credentials Adobe sont réutilisés :

  ADOBE_CLIENT_ID=your_adobe_client_id_here
  ADOBE_CLIENT_SECRET=your_adobe_client_secret_here

### Comportement si aucun tableau n'est exporté

- Le fichier de sortie contient un avertissement explicite
- Header `X-Warning: NO_TABLES_FOUND` présent dans la réponse
- Conseils : baisser le seuil de confiance, changer de stratégie
- Le fichier JSON contiendra toujours `"tables": []` (jamais une erreur 500)
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10 → PROMPT 11
  Config    Engine    PostProc   Outputs    Adobe      Router     Endpoint   Métriques  Frontend  Tests        Docs
```

> **Parallélisables :**
> - PROMPT 4 (formats de sortie) peut être développé en parallèle de PROMPT 5 (Adobe)
>   car ils sont indépendants l'un de l'autre.
> - PROMPT 9 (Frontend) peut démarrer dès PROMPT 7 (Endpoint) validé.
> - PROMPT 8 (Métriques) peut être intégré directement dans PROMPT 6 (Router).
> - PROMPT 10 (Tests) peut être écrit en TDD : créer les tests en parallèle de chaque prompt.

---

## Critères de validation finale

### Backend
- [ ] `mvn test` passe sans erreur (Engine, PostProcessor, Factory, Router)
- [ ] PDF avec tableau structuré → JSON avec confiance > 0.5 et lignes correctes
- [ ] PDF sans tableau → JSON `{ "tables": [], "warning": "..." }` (pas d'erreur 500)
- [ ] `format=html` → HTML valide avec `<table>` + `<thead>` + classes CSS `kovixel-`
- [ ] `format=md` → Markdown avec séparateurs `---` et `|` correctement échappés
- [ ] `format=csv` → ZIP avec un CSV par tableau + `manifest.csv`
- [ ] `detectMergedCells=true` → JSON contient `"mergedCells"` non vide sur un PDF adapté
- [ ] `confidenceThreshold=0.9` → seuls les tableaux très fiables sont exportés
- [ ] `tableIndices=[0,2]` → seuls les tableaux 0 et 2 sont exportés
- [ ] PDF > 10 MB → HTTP 202 + `{ jobId, pollUrl }`
- [ ] `POST /preview` → JSON avec `bounds.leftPct` et `bounds.topPct` (sans les données)
- [ ] Plan PRO + Adobe configuré → `X-Extraction-Engine: ADOBE_EXTRACT`
- [ ] Adobe échoue → fallback Tabula automatique (log `WARN` visible)
- [ ] `curl /actuator/health` expose `table.tabula: "UP"` et `table.adobe.extract: ...`
- [ ] `curl /actuator/metrics/kovixel.conversion.extract_tables.tables_detected` retourne des valeurs

### Frontend
- [ ] Route `/tools/convert/extract-tables` charge le composant dédié
- [ ] Drop zone → sélection d'un fichier → appel automatique à `/preview`
- [ ] Liste des tableaux prévisualisés avec badge type + barre de confiance colorée
- [ ] Slider de seuil de confiance → filtre en temps réel les tableaux listés
- [ ] Bouton "Extraire" désactivé si aucun tableau sélectionné
- [ ] 5 chips de format (JSON/HTML/MD/CSV/XLSX) avec tooltips corrects
- [ ] Après extraction : badge `X exportés · Y lignes · Confiance moy. 78%`
- [ ] 0 tableaux exportés → message avec bouton "Baisser le seuil à 20%"
- [ ] Options avancées (merged cells, multi-level headers) dans section repliable

