# File Validation Roadmap — Kovixel
**Version:** 1.0 · **Auteur:** Audit automatisé · **Date:** 2026-06-23  
**Périmètre:** Validation de tous les fichiers entrants dans `kovixel-all/kovixel`

---

## Table des matières

1. [Résumé exécutif](#1-résumé-exécutif)
2. [Taxonomie de validation](#2-taxonomie-de-validation)
3. [État actuel — cartographie par outil](#3-état-actuel--cartographie-par-outil)
4. [Analyse des risques](#4-analyse-des-risques)
5. [Architecture cible](#5-architecture-cible)
6. [Plan d'implémentation](#6-plan-dimplémentation)
7. [Spécifications techniques par composant](#7-spécifications-techniques-par-composant)
8. [Critères d'acceptation](#8-critères-dacceptation)
9. [Métriques de succès](#9-métriques-de-succès)

---

## 1. Résumé exécutif

### Constat

L'audit du codebase (juin 2026) révèle une validation des fichiers **hétérogène et incomplète** : un seul outil (Word→PDF) dispose d'une validation robuste par magic bytes via `OfficeFileValidator`. Les 13 autres outils opèrent avec des vérifications partielles basées sur le `Content-Type` HTTP — un champ trivialement falsifiable par n'importe quel client.

### Risques principaux identifiés

| Sévérité | Nombre | Exemples |
|---|---|---|
| 🔴 Critique | 4 | Absence de magic bytes PDF, page-range OOB, fichiers 0-octet non rejetés systématiquement, Compress/Rotate sans aucune validation |
| 🟠 Élevé | 4 | ZIP bombs, pixel bombs, indices hors bornes (tableaux/images), PDF chiffré non détecté sur 7 outils |
| 🟡 Moyen | 5 | Macros Office non détectées, DRM, cross-validation params/fichier absente, limites pages non enforced sur 4 outils |
| 🟢 Faible | 3 | Uniformisation des codes HTTP, audit logging des rejets, configuration centralisée |

### Objectif de la roadmap

Déployer une **validation en pipeline à 6 couches**, fail-fast, centralisée et entièrement testable, apportant à Kovixel un niveau de défense en profondeur équivalent aux standards de l'industrie (Smallpdf, ILovePDF, Adobe Acrobat Services).

---

## 2. Taxonomie de validation

Les validations s'exécutent en séquence ordonnée. Chaque couche échoue immédiatement et court-circuite les suivantes.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     PIPELINE DE VALIDATION                          │
│                                                                     │
│  Requête HTTP                                                       │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 0 — Transport         [< 1 ms]                       │   │
│  │  • Présence du fichier                                       │   │
│  │  • Nombre de fichiers (batch min/max)                        │   │
│  │  • multipart/form-data bien formé                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 1 — Taille            [< 1 ms]                       │   │
│  │  • 0 octet → rejet immédiat                                  │   │
│  │  • Trop petit (< seuil minimal par type)                     │   │
│  │  • Trop grand (limite absolue serveur)                       │   │
│  │  • Trop grand pour le plan utilisateur                       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 2 — Format déclaré vs réel  [< 1 ms]                │   │
│  │  • Magic bytes (signature binaire)                           │   │
│  │  • Extension dans la liste blanche                           │   │
│  │  • Détection de format déguisé (EXE → .pdf, etc.)           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 3 — Intégrité structurelle  [5–50 ms]               │   │
│  │  • Fichier tronqué / corrompu                                │   │
│  │  • PDF chiffré / DRM                                         │   │
│  │  • Nombre de pages (0 pages → rejet)                         │   │
│  │  • Nombre de pages > limite par plan/outil                   │   │
│  │  • Décompression bomb (ZIP, DEFLATE)                         │   │
│  │  • Dimension image extrême (pixel bomb)                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 4 — Cohérence sémantique  [50–500 ms]               │   │
│  │  • Fichier valide mais sans contenu utile pour l'outil       │   │
│  │    (PDF sans texte pour Q&A, sans images pour extract-img)   │   │
│  │  • Cross-validation : paramètres vs fichier réel             │   │
│  │    (plages de pages, indices de tableaux, indices d'images)  │   │
│  │  • Résolution DPI trop faible pour OCR                       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ COUCHE 5 — Quota & plan        [< 5 ms, Redis]             │   │
│  │  • Quota journalier (conversions, Q&A, OCR pages…)          │   │
│  │  • Feature non disponible sur le plan                        │   │
│  └─────────────────────────────────────────────────────────────┘   │
│       │ PASS                                                        │
│       ▼                                                             │
│  Traitement métier                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. État actuel — cartographie par outil

### Légende

| Symbole | Signification |
|---|---|
| ✅ | Implémenté correctement |
| ⚠️ | Partiel ou insuffisant |
| ❌ | Absent |

### Matrice de couverture

| Outil | C0 Transport | C1 Taille | C2 Magic bytes | C3 Structure | C4 Sémantique | C5 Quota |
|---|---|---|---|---|---|---|
| **PDF Split** | ✅ | ✅ plan | ❌ | ⚠️ pages (dans resolvePageRanges) | ❌ bounds OOB | ✅ AOP |
| **PDF Merge** | ✅ min/max | ✅ plan+total | ❌ | ❌ | ❌ | ✅ AOP |
| **PDF Compress** | ✅ | ✅ absolu | ❌ | ❌ | ❌ | ✅ AOP |
| **PDF Rotate** | ✅ | ⚠️ absolu seulement | ❌ | ⚠️ pages (dans handler) | ❌ | ✅ AOP |
| **PDF Lock** | ✅ | ✅ plan | ❌ | ✅ validateAndCountPages | ❌ | ✅ AOP |
| **PDF Unlock** | ✅ | ✅ plan | ❌ | ✅ validateAndCountPages | ❌ | ✅ AOP |
| **PDF Watermark** | ✅ | ✅ plan | ❌ | ✅ validatePdf | ❌ | ✅ AOP |
| **PDF Page Numbers** | ✅ | ✅ plan | ❌ | ✅ validatePdf | ❌ | ✅ AOP |
| **PDF eSignature** | ✅ | ✅ plan | ❌ | ⚠️ validatePdf | ❌ | ✅ AOP |
| **OCR** | ✅ | ✅ plan | ❌ | ✅ pageCount (0 + >200) | ⚠️ quota pages | ✅ AOP |
| **Résumé IA** | ✅ | ✅ plan | ❌ | ✅ EMPTY/ENCRYPTED | ✅ IMAGE_ONLY | ✅ AOP |
| **Q&A (ingest)** | ⚠️ | ⚠️ | ❌ | ⚠️ | ⚠️ | ✅ |
| **Q&A (question)** | N/A | N/A | N/A | N/A | ⚠️ doc existant? | ✅ |
| **Traduction IA** | ✅ | ✅ plan | ❌ | ⚠️ | ❌ | ✅ |
| **Word→PDF** | ✅ | ✅ absolu | ✅ ZIP/OLE2/RTF | ✅ extension | ❌ macros | ✅ AOP |
| **Excel→PDF** | ✅ | ✅ | ⚠️ mutualisé Office | ✅ extension | ❌ | ✅ AOP |
| **Images→PDF** | ✅ | ✅ nb+total | ⚠️ `image/*` seulement | ⚠️ OOM catch | ❌ pixel bomb | ✅ AOP |
| **PDF→Image** | ✅ | ⚠️ | ❌ | ❌ pages | ❌ | ✅ AOP |
| **Extract Images** | ✅ | ✅ absolu | ❌ | ❌ | ⚠️ indices>=0 | ✅ AOP |
| **Extract Tables** | ✅ | ⚠️ async seulement | ❌ | ❌ | ⚠️ indices>=0 | ✅ AOP |

### Ce qui fonctionne bien aujourd'hui

- **`OfficeFileValidator`** — Seule classe de validation robuste : extension whitelist + magic bytes ZIP/OLE2/RTF + taille. Modèle à généraliser.
- **`PdfExtractor.classify()`** — Enum `EMPTY / ENCRYPTED / IMAGE_ONLY / TEXT_EXTRACTABLE`. Utilisé uniquement par Résumé IA et Q&A.
- **`QuotaService` + `AnonymousQuotaService`** — Quota Redis atomique (INCR), TTL minuit UTC, fail-open si Redis indisponible.
- **Quota AOP (`@CheckQuota`)** — Coupe transversale propre, appliquée uniformément sur les endpoints.
- **`ImageDecoder`** — Détection magic bytes pour 6 formats image (JPEG, PNG, GIF, WEBP, TIFF, BMP).
- **`GlobalExceptionHandler`** — Capture `MaxUploadSizeExceededException` Spring avant le controller.

### Ce qui est absent ou insuffisant

- **Magic bytes PDF** : Le header `%PDF` (0x25 0x50 0x44 0x46) n'est jamais vérifié. Un fichier EXE, HTML ou XML renommé `.pdf` avec le bon `Content-Type` passe l'entrée de 13 outils.
- **Compress & Rotate** : Aucune pré-validation avant chargement PDFBox.
- **Merge** : Tailles vérifiées, mais aucune validation de la structure PDF de chaque fichier avant fusion.
- **Cross-validation paramètres ↔ fichier** : `tableIndices`, `imageIndices`, plages `pages=1-N` sont validés >= 0 uniquement. Aucune vérification que les indices existent dans le fichier réel.
- **Fichier vide (0 octet)** : Géré par `OfficeFileValidator` et `OcrServiceImpl`, absent sur 11 autres outils.
- **Zip bomb** : Aucune protection. Un fichier DOCX (ZIP) de 1 KB qui décompresse en 2 GB n'est pas détecté.
- **Pixel bomb** : Capturé seulement par `OutOfMemoryError` catch dans `ImageToPdfEngine`. Pas de vérification de dimensions.
- **Q&A — ingest** : Validation minimale non documentée, à auditer.

---

## 4. Analyse des risques

### Risques critiques 🔴

#### R-01 — Absence de magic bytes PDF

**Impact :** Un attaquant envoie un fichier EXE/HTML/JavaScript renommé `.pdf` avec `Content-Type: application/pdf`. Il passe tous les contrôles et entre dans PDFBox. PDFBox lève une exception interne après avoir consommé des ressources CPU/mémoire.

**Probabilité :** Élevée (bypass trivial).  
**Outils affectés :** Split, Merge, Compress, Rotate, Lock, Unlock, Watermark, Page Numbers, eSignature, OCR, Q&A, Traduction, PDF→Image (13 outils).  
**Correction :** Ajouter `PdfFileValidator` avec vérification `%PDF` en < 1 ms avant tout traitement.

---

#### R-02 — Indices hors bornes (OOB) non validés

**Impact :** Un utilisateur envoie `tableIndices=[0, 999]` sur un PDF contenant 2 tableaux. Le traitement tente d'accéder à l'index 999, produisant soit un `IndexOutOfBoundsException` non géré, soit un résultat silencieusement incomplet.

**Probabilité :** Élevée (usage normal erroné ou intentionnel).  
**Outils affectés :** Extract Tables, Extract Images, Split (plages pages), Rotate (plages pages), PDF→Image (plages pages).  
**Correction :** Cross-validation dans `FileValidationContext` après ouverture du fichier (couche 4).

---

#### R-03 — Compress et Rotate sans aucune pré-validation

**Impact :** Absence totale de contrôle avant chargement PDFBox. Un fichier corrompu de 100 MB force PDFBox à allouer de la mémoire et échouer en cours de traitement (coût CPU + mémoire vs. rejet immédiat à l'entrée).

**Probabilité :** Moyenne.  
**Outils affectés :** Compress, Rotate.  
**Correction :** Ajouter appel `PdfFileValidator` en entrée des handlers.

---

#### R-04 — Fichiers 0-octet non rejetés systématiquement

**Impact :** Un `MultipartFile` vide (0 octet) passe les contrôles de 11 outils et provoque des exceptions non prévues profondément dans le code de traitement.

**Probabilité :** Élevée (bugs client, interruption réseau).  
**Correction :** Couche 1 universelle, fail-fast < 1 ms.

---

### Risques élevés 🟠

#### R-05 — ZIP bomb via merge de fichiers DOCX/XLSX

**Impact :** Un fichier DOCX de 50 KB (limite DOCX = limite Word→PDF = 50 MB compressé) peut se décompresser en plusieurs gigaoctets. Sans limite de taille décompressée, le serveur consomme toute la mémoire disponible.

**Correction :** Limiter la taille décompressée en lecture streaming (vérifier le ratio taille-compressée / taille-décompressée ≤ 100).

---

#### R-06 — Pixel bomb (image extrêmement grande)

**Impact :** Une image JPEG de 500 KB représentant un bitmap 100 000 × 100 000 pixels est acceptée par Images→PDF. `ImageIO.read()` alloue ~40 GB en mémoire.

**Situation actuelle :** Seul `OutOfMemoryError` est capturé (comportement non déterministe selon le GC).  
**Correction :** Vérifier les dimensions en lecture partielle des headers image (JPEG SOF, PNG IHDR) avant décodage complet.

---

#### R-07 — PDF chiffré non détecté sur 7 outils

**Impact :** Compress, Rotate, Merge, PDF→Image, Extract Tables, Extract Images, Traduction acceptent un PDF protégé par mot de passe. PDFBox lève `InvalidPasswordException` en cours de traitement. Le message d'erreur retourné peut exposer des détails internes.

**Correction :** Ajouter détection `isEncrypted()` en couche 3 pour tous les outils.

---

#### R-08 — PDF à 0 pages non détecté sur la majorité des outils

**Impact :** Un PDF structurellement valide mais vide passe Compress, Rotate, Merge, Watermark, eSignature sans rejet préalable.

**Correction :** Couche 3 universelle `pageCount == 0 → HTTP 422`.

---

### Risques moyens 🟡

#### R-09 — Macros Office non détectées

Les fichiers DOCX/XLSX peuvent contenir des macros VBA exécutées lors de l'ouverture par LibreOffice (fallback conversion). Bien que l'environnement serveur soit sandboxé, la détection préventive est recommandée.

**Correction :** Lecture du flux ZIP : si `vbaProject.bin` ou `xl/vbaProject.bin` présent → rejet avec HTTP 415.

---

#### R-10 — Limite de pages non enforced strictement sur 4 outils

PDF→Image (`maxPages=50`), PDF→Excel (`maxPages=100`), Extract Tables (`maxPages=100`), Extract Images — les limites sont configurées mais pas enforced avant traitement. Un PDF de 1 000 pages passe la validation et consomme des ressources importantes.

**Correction :** Lire `doc.getNumberOfPages()` en couche 3 avant tout traitement asynchrome ou synchrone.

---

#### R-11 — Cross-validation absente pour plages de pages

Un utilisateur qui demande `pages=45-50` sur un PDF de 3 pages reçoit soit une réponse vide, soit une erreur obscure de PDFBox.

**Correction :** Après ouverture PDF (couche 3), valider que toutes les plages demandées sont dans `[1, doc.getNumberOfPages()]`.

---

## 5. Architecture cible

### Vue d'ensemble

```
┌───────────────────────────────────────────────────────────────────┐
│                     FileValidationPipeline                        │
│                                                                   │
│  FileValidationContext {                                          │
│    byte[] content                                                 │
│    String originalFilename                                        │
│    String declaredContentType                                     │
│    UserPlan plan                                                   │
│    ToolType tool         ← SPLIT, MERGE, OCR, QNA, ...           │
│    Map<String, Object> params  ← pages, indices, mode...          │
│  }                                                                │
│                                                                   │
│  execute(context) {                                               │
│    for validator in validators:                                   │
│      result = validator.validate(context)                         │
│      if result.isFailure(): throw KovixelException(result)        │
│  }                                                                │
└───────────────────────────────────────────────────────────────────┘
           │
           ├── TransportValidator        (C0)
           ├── FileSizeValidator         (C1) — plan-aware
           ├── MagicBytesValidator       (C2) — format-aware
           ├── PdfStructureValidator     (C3) — PDF tools only
           ├── ImageStructureValidator   (C3) — image tools only
           ├── OfficeStructureValidator  (C3) — office tools only
           ├── ZipBombValidator          (C3) — office + merge
           ├── PdfSemanticValidator      (C4) — Q&A, OCR, Summary
           ├── PageRangeBoundsValidator  (C4) — split, rotate, extract
           └── (QuotaValidator existant ne change pas — C5)
```

### Interface `FileValidator`

```java
package com.kovixel.common.validation;

public interface FileValidator {
    /**
     * Exécute la validation. Lance une {@link KovixelException} si invalide.
     *
     * @param ctx contexte complet de la validation
     */
    void validate(FileValidationContext ctx);

    /**
     * Retourne true si ce validator doit s'exécuter pour l'outil donné.
     * Permet aux validators spécialisés (PDF, image) de s'auto-exclure.
     */
    default boolean appliesTo(ToolType tool) { return true; }
}
```

### `FileValidationContext`

```java
package com.kovixel.common.validation;

public record FileValidationContext(
        byte[]              content,
        String              originalFilename,
        String              declaredContentType,
        UserPlan            plan,
        ToolType            tool,
        Map<String, Object> params            // plages pages, indices, etc.
) {
    /** Taille en octets. */
    public long sizeBytes() { return content == null ? 0 : content.length; }

    /** Extension en minuscules, sans point. "pdf", "docx", etc. */
    public String extension() {
        if (originalFilename == null || !originalFilename.contains(".")) return "";
        return originalFilename.substring(originalFilename.lastIndexOf('.') + 1).toLowerCase();
    }

    /** Premiers N octets pour la détection magic bytes. */
    public byte[] header(int n) {
        if (content == null) return new byte[0];
        return Arrays.copyOf(content, Math.min(n, content.length));
    }
}
```

### `ToolType` enum

```java
public enum ToolType {
    PDF_SPLIT, PDF_MERGE, PDF_COMPRESS, PDF_ROTATE,
    PDF_LOCK, PDF_UNLOCK, PDF_WATERMARK, PDF_PAGE_NUMBERS, PDF_ESIGNATURE,
    PDF_TO_IMAGE, PDF_TO_EXCEL,
    IMAGES_TO_PDF,
    WORD_TO_PDF, EXCEL_TO_PDF,
    OCR,
    EXTRACT_IMAGES, EXTRACT_TABLES,
    AI_SUMMARY, AI_QNA_INGEST, AI_QNA_ASK, AI_TRANSLATION;

    /** Outils qui traitent un PDF en entrée. */
    public static final Set<ToolType> PDF_TOOLS = EnumSet.of(
        PDF_SPLIT, PDF_MERGE, PDF_COMPRESS, PDF_ROTATE,
        PDF_LOCK, PDF_UNLOCK, PDF_WATERMARK, PDF_PAGE_NUMBERS, PDF_ESIGNATURE,
        PDF_TO_IMAGE, PDF_TO_EXCEL, OCR, EXTRACT_IMAGES, EXTRACT_TABLES,
        AI_SUMMARY, AI_QNA_INGEST, AI_TRANSLATION
    );

    /** Outils qui traitent des fichiers Office en entrée. */
    public static final Set<ToolType> OFFICE_TOOLS = EnumSet.of(
        WORD_TO_PDF, EXCEL_TO_PDF
    );

    /** Outils qui traitent des images en entrée. */
    public static final Set<ToolType> IMAGE_TOOLS = EnumSet.of(IMAGES_TO_PDF);
}
```

---

## 6. Plan d'implémentation

### Phase 1 — Fondations critiques (Sprint 1, ~5 jours)

**Objectif :** Fermer les 4 risques critiques. Aucune régression.

#### PROMPT 1 — Infrastructure `FileValidationPipeline`

Créer les classes de base :
- `FileValidationContext` (record)
- `ToolType` (enum)
- `FileValidator` (interface)
- `FileValidationPipeline` (service Spring, liste ordonnée de validators)
- `ValidationResult` (sealed : `Success` / `Failure(ErrorCode, String message)`)

**Package :** `com.kovixel.common.validation`  
**Tests :** `FileValidationPipelineTest` — pipeline vide, pipeline avec un validator qui échoue, ordre d'exécution.

---

#### PROMPT 2 — `TransportValidator` + `FileSizeValidator` (C0 + C1)

**`TransportValidator` :**
- `content == null || content.length == 0` → `HTTP 400 VALIDATION_ERROR` : _"Aucun fichier reçu ou fichier vide."_
- Extension absente du nom de fichier → `HTTP 400`

**`FileSizeValidator` :**
- Taille < seuil minimal par type (`MIN_PDF_BYTES = 67`, `MIN_IMAGE_BYTES = 4`, `MIN_OFFICE_BYTES = 512`) → `HTTP 422`
- Taille > limite absolue serveur (`MAX_UPLOAD_BYTES = 500 MB`) → `HTTP 413`
- Taille > `PlanConfig.forPlan(plan).maxFileSizeMbConversion() * MB` → `HTTP 413` avec message indiquant le plan

**Migration :** Supprimer les vérifications `content == null` et `fileBytes.length / MB > maxFileMb` dans les 8 ServiceImpl qui les dupliquent.  
**Tests :** 8 cas (null, 0 octet, < minimum, OK, > plan, > absolu).

---

#### PROMPT 3 — `MagicBytesValidator` (C2)

Registre de signatures par `ToolType` :

```java
// PDF — %PDF
PDF_MAGIC    = { 0x25, 0x50, 0x44, 0x46 }          // ← manquant actuellement

// Images
JPEG_MAGIC   = { 0xFF, 0xD8, 0xFF }
PNG_MAGIC    = { 0x89, 0x50, 0x4E, 0x47 }
GIF_MAGIC    = { 0x47, 0x49, 0x46, 0x38 }
WEBP_MAGIC   = { 0x52, 0x49, 0x46, 0x46 }           // + offset 8 : WEBP
TIFF_LE      = { 0x49, 0x49, 0x2A, 0x00 }
TIFF_BE      = { 0x4D, 0x4D, 0x00, 0x2A }
BMP_MAGIC    = { 0x42, 0x4D }

// Office
ZIP_MAGIC    = { 0x50, 0x4B, 0x03, 0x04 }           // DOCX, XLSX, PPTX, ODS…
OLE2_MAGIC   = { 0xD0, 0xCF, 0x11, 0xE0 }           // DOC, XLS, PPT (legacy)
RTF_MAGIC    = { 0x7B, 0x5C, 0x72, 0x74 }           // {\rt

// Formats dangereux à blacklister
EXE_MAGIC    = { 0x4D, 0x5A }                       // MZ — Windows PE
ELF_MAGIC    = { 0x7F, 0x45, 0x4C, 0x46 }           // ELF — Linux binary
```

**Comportement :**
1. Vérifier que les magic bytes du fichier correspondent au format attendu par l'outil.
2. Si magic bytes correspondent à un format dangereux (EXE, ELF) → `HTTP 415` avec log WARN.
3. Si magic bytes inconnus mais extension et Content-Type cohérents → accepter avec log DEBUG.

**Migration :** Unifier avec `OfficeFileValidator` (qui est la seule impl existante avec magic bytes). `OfficeFileValidator` délègue à `MagicBytesValidator` ou est réécrit pour l'utiliser.  
**Tests :** 15 cas (PDF valide, EXE déguisé en PDF, image pour outil PDF, chaque magic connu).

---

#### PROMPT 4 — `PdfStructureValidator` (C3)

Remplace les appels dispersés à `validatePdf()` / `validateAndCountPages()`.

**Vérifications en ordre :**
1. Ouvrir avec PDFBox (`PDDocument.load(content)`)
2. `doc.isEncrypted()` → `HTTP 422 PROCESSING_ERROR` : _"Le PDF est protégé par un mot de passe. Retirez la protection avant de continuer."_
3. `doc.getNumberOfPages() == 0` → `HTTP 422` : _"Le PDF ne contient aucune page."_
4. `doc.getNumberOfPages() > maxPages` (selon outil) → `HTTP 422` : _"Le PDF dépasse la limite de N pages pour cet outil."_

**Intégration :** Appelé par `FileValidationPipeline` pour tous les `ToolType.PDF_TOOLS`.  
**Migration :** Supprimer les appels inline à `validatePdf()`, `validateAndCountPages()`, `isEncrypted()` dans les 8 ServiceImpl + ConversionController.

**Tests :** 6 cas (PDF valide, PDF 0 pages, PDF chiffré, PDF > limite, PDF corrompu, faux PDF).

---

#### PROMPT 5 — Intégration dans les handlers prioritaires

Brancher `FileValidationPipeline.validate(ctx)` dans les handlers des outils **sans aucune validation** :

- `POST /api/v1/pdf/compress` (handler `compressPdf`)
- `POST /api/v1/pdf/rotate` (handler `rotatePdf`)
- `POST /api/v1/pdf/merge` (handler `mergePdfs`, par fichier)
- `POST /api/v1/pdf/split` (handler `splitPdf`)
- `POST /api/v1/convert/extract-tables` (handler `extractTables`)
- `POST /api/v1/convert/extract-images` (handler `extractImages`)

Pattern d'intégration dans `ConversionController` :

```java
// Avant :
byte[] pdf = file.getBytes();
// ... traitement direct

// Après :
byte[] pdf = file.getBytes();
fileValidationPipeline.validate(FileValidationContext.forPdfTool(
    pdf, file.getOriginalFilename(), file.getContentType(), plan, ToolType.PDF_COMPRESS
));
// ... traitement (garanti : fichier valide, taille OK, magic bytes OK, structure OK)
```

---

### Phase 2 — Standardisation et cross-validation (Sprint 2, ~4 jours)

**Objectif :** Éliminer les risques élevés R-05 à R-08 et les incohérences.

#### PROMPT 6 — `ZipBombValidator` (C3)

Applique aux outils Office (Word→PDF, Excel→PDF) et aux fichiers DOCX/XLSX lors du Merge.

**Algorithme :** Lire le ZIP en streaming (sans tout décompresser). Accumuler `totalUncompressedSize`. Si `totalUncompressedSize / compressedSize > RATIO_MAX (100)` ou `totalUncompressedSize > MAX_UNCOMPRESSED (500 MB)` → `HTTP 422`.

```java
// Lecture streaming — ne décompresse pas entièrement
try (ZipInputStream zis = new ZipInputStream(new ByteArrayInputStream(content))) {
    ZipEntry entry;
    long totalUncompressed = 0;
    while ((entry = zis.getNextEntry()) != null) {
        totalUncompressed += entry.getSize() >= 0
            ? entry.getSize()
            : countBytes(zis, MAX_UNCOMPRESSED);
        if (totalUncompressed > MAX_UNCOMPRESSED) throw fileTooLarge(...);
    }
}
```

---

#### PROMPT 7 — `PixelBombValidator` + limites dimensions image (C3)

Lire uniquement les headers des formats image (sans décodage complet) pour extraire `width` et `height`.

| Format | Offset width/height |
|---|---|
| JPEG | SOF0/SOF1/SOF2 marker (scan partielle) |
| PNG | IHDR : bytes [16-23] |
| BMP | BITMAPINFOHEADER : bytes [18-25] |
| WEBP | VP8 bitstream : bytes [26-29] |
| TIFF | Tags 256/257 |

**Limites :** `MAX_IMAGE_WIDTH_PX = 20_000`, `MAX_IMAGE_HEIGHT_PX = 20_000` (400 MP max → ~1.6 GB en ARGB, sûr).  
**Supprime :** le `catch (OutOfMemoryError)` dans `ImageToPdfEngine` (qui ne devrait pas être nécessaire).

---

#### PROMPT 8 — `PageRangeBoundsValidator` (C4)

Validator qui s'exécute **après** ouverture du PDF (le nombre de pages est connu).

**Cas couverts :**
- Split : `pages=1-50` sur PDF de 3 pages → erreur avec message _"La plage 1-50 dépasse le nombre de pages du document (3)."_
- Rotate : indices de pages hors bornes
- PDF→Image : plages hors bornes
- Extract Tables : `tableIndices=[0, 99]` → les indices seront vérifiés après extraction (impossible avant) → **avertissement** dans la réponse, pas erreur bloquante
- Extract Images : idem Extract Tables

**Implémentation :** `PageRangeBoundsValidator` reçoit `pageCount` via `FileValidationContext.enrichedData()`.

---

#### PROMPT 9 — `PdfSemanticValidator` (C4)

Généralise ce qui existe dans `SummaryServiceImpl` (classification PDF) à tous les outils qui ont besoin de contenu.

```java
// Outils concernés et leur contrainte sémantique :
AI_QNA_INGEST    → rejet si EMPTY ou ENCRYPTED
AI_SUMMARY       → rejet si EMPTY, ENCRYPTED, IMAGE_ONLY (déjà fait)
AI_TRANSLATION   → rejet si EMPTY ou ENCRYPTED
OCR              → accepte IMAGE_ONLY (c'est son rôle), rejette EMPTY
EXTRACT_TABLES   → warning (pas erreur) si aucun tableau
EXTRACT_IMAGES   → warning (pas erreur) si aucune image
```

**Réutilise :** `PdfExtractor.classify()` existant.  
**Supprime :** les vérifications inline dans `SummaryServiceImpl`, `QnaServiceImpl`.

---

#### PROMPT 10 — `MacroDetectionValidator` (C3, outils Office)

Inspecter le ZIP d'un fichier DOCX/XLSX/PPTX pour détecter la présence de macros VBA.

**Entrées ZIP suspectes :**
- `word/vbaProject.bin` (DOCX avec macros)
- `xl/vbaProject.bin` (XLSM)
- `ppt/vbaProject.bin` (PPTM)

**Comportement :** Log WARN + `HTTP 415` avec message _"Les fichiers contenant des macros (XLSM, DOCM, PPTM) ne sont pas acceptés pour des raisons de sécurité."_

---

### Phase 3 — Observabilité et config centralisée (Sprint 3, ~3 jours)

#### PROMPT 11 — `ValidationAuditLogger`

Intercepteur sur `FileValidationPipeline` qui log chaque rejet :

```
WARN [ValidationAudit] tool=PDF_SPLIT user=anon ip=1.2.3.4 
     validator=MagicBytesValidator reason=INVALID_MAGIC_BYTES
     filename=document.pdf declared_ct=application/pdf actual_magic=4D5A
     size=45678 duration_ms=1
```

Métriques Micrometer :
- `kovixel.validation.reject` (Counter, tags: `tool`, `validator`, `reason`)
- `kovixel.validation.duration` (Timer, tag: `tool`)

---

#### PROMPT 12 — `ValidationProperties` — configuration centralisée

```yaml
kovixel:
  validation:
    # Couche 1 — Taille minimale par type (octets)
    min-pdf-bytes: 67
    min-image-bytes: 4
    min-office-bytes: 512
    # Couche 1 — Limite absolue serveur
    max-upload-bytes: 524288000  # 500 MB
    # Couche 3 — Zip bomb
    zip-bomb-ratio-max: 100
    zip-bomb-uncompressed-max: 524288000  # 500 MB
    # Couche 3 — Pixel bomb
    image-max-width-px: 20000
    image-max-height-px: 20000
    # Couche 3 — Pages max par outil (override ConversionProperties)
    pdf-tools-max-pages:
      PDF_SPLIT: 500
      PDF_MERGE: 500
      PDF_COMPRESS: 500
      PDF_ROTATE: 500
      PDF_LOCK: 500
      PDF_UNLOCK: 500
      PDF_WATERMARK: 500
      PDF_PAGE_NUMBERS: 500
      PDF_ESIGNATURE: 500
      PDF_TO_IMAGE: 50
      PDF_TO_EXCEL: 100
      OCR: 200
      EXTRACT_IMAGES: 500
      EXTRACT_TABLES: 100
      AI_SUMMARY: 500
      AI_QNA_INGEST: 500
      AI_TRANSLATION: 200
    # Couche 3 — Macros
    reject-office-macros: true
    # Couche 4 — Sémantique
    reject-image-only-pdf-for-qna: true
    reject-image-only-pdf-for-summary: true
```

---

#### PROMPT 13 — Migration et nettoyage

Supprimer tous les doublons de validation issus des ServiceImpl maintenant couverts par le pipeline :

| Code à supprimer | Remplacé par |
|---|---|
| `ct == null || !ct.contains("pdf")` dans 7 services | `MagicBytesValidator` |
| `fileBytes.length / MB > maxFileMb` dans 8 services | `FileSizeValidator` |
| `validatePdf(fileBytes)` dans 5 services | `PdfStructureValidator` |
| `validateAndCountPages(fileBytes)` dans 2 services | `PdfStructureValidator` |
| `pdfExtractor.classify()` dans 2 services | `PdfSemanticValidator` |

**Assurer :** Tous les `private void validatePdf(byte[])` dans les ServiceImpl deviennent des appels à `fileValidationPipeline.validate(ctx)`.

---

### Phase 4 — Tests et couverture (Sprint 4, ~3 jours)

#### PROMPT 14 — Suite de tests `FileValidationPipelineIT`

Tests d'intégration couvrant tous les validators en combinaison :

```java
// Classe de test unique avec scénarios end-to-end
@SpringBootTest
class FileValidationPipelineIT {

    // Scénarios positifs (fichiers légitimes)
    void pdf_valid_passesAllLayers()
    void office_docx_valid_passesAllLayers()
    void image_jpeg_valid_passesAllLayers()

    // C0 — Transport
    void null_content_rejected_400()
    void zero_bytes_rejected_400()

    // C1 — Taille
    void pdf_below_minimum_bytes_rejected_422()
    void pdf_exceeds_plan_limit_rejected_413()
    void pdf_exceeds_absolute_limit_rejected_413()

    // C2 — Magic bytes
    void exe_disguised_as_pdf_rejected_415()
    void html_disguised_as_pdf_rejected_415()
    void correct_pdf_magic_accepted()
    void jpeg_sent_to_pdf_tool_rejected_415()

    // C3 — Structure
    void encrypted_pdf_rejected_422()
    void zero_pages_pdf_rejected_422()
    void too_many_pages_pdf_rejected_422()
    void zip_bomb_rejected_422()
    void pixel_bomb_image_rejected_422()
    void office_with_macros_rejected_415()

    // C4 — Sémantique
    void image_only_pdf_for_qna_rejected_422()
    void image_only_pdf_for_ocr_accepted()  // OCR est justement fait pour ça
    void page_range_out_of_bounds_rejected_422()
    void page_range_within_bounds_accepted()
}
```

#### Fichiers de test à créer (`src/test/resources/fixtures/validation/`)

```
valid.pdf               — PDF texte 3 pages
valid_encrypted.pdf     — PDF protégé par mot de passe
valid_0pages.pdf        — PDF structurellement valide, 0 pages
valid_image_only.pdf    — PDF scanné (IMAGE_ONLY)
exe_as_pdf.bin          — EXE renommé .pdf (MZ header)
zip_bomb.docx           — ZIP avec ratio 200:1
pixel_bomb.jpg          — JPEG 20001×20001 pixels (headers seulement)
macro_enabled.docx      — DOCX avec vbaProject.bin
valid.docx              — DOCX sans macros
valid.jpg               — JPEG valide
valid.png               — PNG valide
```

---

## 7. Spécifications techniques par composant

### `PdfFileValidator` — Spec détaillée

**Seuils minimaux :**
- Un PDF valide minimal (header `%PDF-1.x` + `%%EOF`) fait au minimum 67 octets.
- Refuser tout fichier < 67 octets comme non-PDF.

**Magic bytes PDF extended :**
```
Positions 0-3 : 25 50 44 46 (%PDF)
Positions 4-7 : 2D 31 2E    (-1.)  suivi de chiffre version 0-9
```

**Tolérances :**
- Certains générateurs PDF ajoutent un BOM UTF-8 avant `%PDF`. Tolérer `EF BB BF 25 50 44 46`.
- Les PDF linéarisés peuvent avoir `%PDF` à un offset > 0 si précédé de commentaires. Chercher `%PDF` dans les 1 024 premiers octets.

**PDFBox error mapping :**

| Exception PDFBox | HTTP | Code erreur | Message utilisateur |
|---|---|---|---|
| `InvalidPasswordException` | 422 | `PROCESSING_ERROR` | Le PDF est protégé par un mot de passe. |
| `IOException` (truncated) | 422 | `PROCESSING_ERROR` | Le fichier PDF est corrompu ou tronqué. |
| `IOException` (invalid header) | 415 | `INVALID_FILE_TYPE` | Le fichier n'est pas un PDF valide. |

---

### `MagicBytesValidator` — Registre complet

```java
sealed interface MagicSignature {
    record Prefix(byte[] bytes) implements MagicSignature {}
    record PrefixWithOffset(byte[] bytes, int offset) implements MagicSignature {}
    record CompositeAnd(MagicSignature a, MagicSignature b) implements MagicSignature {}
}

Map<FileFormat, List<MagicSignature>> SIGNATURES = Map.of(
    PDF,   List.of(new Prefix(PDF_MAGIC)),
    JPEG,  List.of(new Prefix(JPEG_MAGIC)),
    PNG,   List.of(new Prefix(PNG_MAGIC)),
    GIF,   List.of(new Prefix(GIF_MAGIC)),
    WEBP,  List.of(new CompositeAnd(
               new Prefix(RIFF_MAGIC),
               new PrefixWithOffset(WEBP_MARKER, 8))),
    TIFF,  List.of(new Prefix(TIFF_LE), new Prefix(TIFF_BE)),
    BMP,   List.of(new Prefix(BMP_MAGIC)),
    ZIP,   List.of(new Prefix(ZIP_MAGIC)),   // DOCX/XLSX/PPTX/ODS/ODT
    OLE2,  List.of(new Prefix(OLE2_MAGIC)),  // DOC/XLS/PPT
    RTF,   List.of(new Prefix(RTF_MAGIC))
);

// Formats interdits (blacklist)
Set<MagicSignature> DANGEROUS = Set.of(
    new Prefix(EXE_MAGIC),  // Windows PE
    new Prefix(ELF_MAGIC),  // Linux ELF
    new Prefix(SCRIPT_MAGIC) // #!/
);
```

---

### Codes HTTP — Référence standardisée

| Situation | HTTP | Code interne | Quand |
|---|---|---|---|
| Aucun fichier / 0 octet | 400 | `VALIDATION_ERROR` | C0 |
| Taille > plan | 413 | `FILE_TOO_LARGE` | C1 |
| Taille > limite serveur | 413 | `FILE_TOO_LARGE` | C1 |
| Format non accepté (PDF attendu, image reçue) | 415 | `INVALID_FILE_TYPE` | C2 |
| Fichier exécutable déguisé | 415 | `INVALID_FILE_TYPE` | C2 |
| PDF corrompu / tronqué | 422 | `PROCESSING_ERROR` | C3 |
| PDF chiffré | 422 | `PROCESSING_ERROR` | C3 |
| PDF vide (0 pages) | 422 | `PROCESSING_ERROR` | C3 |
| PDF trop long (> limite outil) | 422 | `PROCESSING_ERROR` | C3 |
| ZIP bomb | 422 | `PROCESSING_ERROR` | C3 |
| Pixel bomb | 413 | `FILE_TOO_LARGE` | C3 |
| Macros Office détectées | 415 | `INVALID_FILE_TYPE` | C3 |
| PDF sans texte pour Q&A | 422 | `PDF_IMAGE_ONLY` | C4 |
| Plages de pages hors bornes | 400 | `VALIDATION_ERROR` | C4 |
| Quota dépassé | 429 | `QUOTA_EXCEEDED` | C5 |
| Feature non disponible (plan) | 402 | `PLAN_LIMIT_EXCEEDED` | C5 |

---

## 8. Critères d'acceptation

### Phase 1 ✅ (DONE quand)

- [ ] Un fichier EXE renommé `.pdf` envoyé à `/api/v1/pdf/split` reçoit HTTP 415 en < 5 ms
- [ ] Un fichier PDF de 0 octet reçoit HTTP 400 sur tous les endpoints
- [ ] Un PDF chiffré reçoit HTTP 422 sur Compress et Rotate (actuellement : exception PDFBox non gérée)
- [ ] Compress et Rotate valident le format avant tout chargement PDFBox
- [ ] Les tests `FileValidationPipelineTest` (C0+C1+C2+C3) passent à 100%

### Phase 2 ✅ (DONE quand)

- [ ] Un DOCX contenant `vbaProject.bin` reçoit HTTP 415 sur Word→PDF
- [ ] Une image 25 000×25 000 px est rejetée HTTP 413 avant décodage complet
- [ ] `pages=1-50` sur un PDF de 3 pages reçoit HTTP 400 avec message indiquant "3 pages disponibles"
- [ ] Un PDF `IMAGE_ONLY` envoyé à Q&A reçoit HTTP 422 avec code `PDF_IMAGE_ONLY`
- [ ] Un DOCX ZIP de 100 KB qui se décompresse en 20 GB est rejeté HTTP 422

### Phase 3 ✅ (DONE quand)

- [ ] Chaque rejet produit une entrée de log `ValidationAudit` avec `tool`, `validator`, `reason`, `ip`, `filename_hash`, `size`
- [ ] Le counter Micrometer `kovixel.validation.reject` est incrémenté à chaque rejet
- [ ] Toutes les limites de validation sont dans `ValidationProperties` et `application.yml`
- [ ] Aucune constante de validation hardcodée dans les ServiceImpl

### Phase 4 ✅ (DONE quand)

- [ ] Couverture de `FileValidationPipelineIT` ≥ 95% des branches de chaque validator
- [ ] 0 test existant en régression
- [ ] Tous les fixtures de test (`valid.pdf`, `exe_as_pdf.bin`, etc.) en `src/test/resources/fixtures/validation/`

---

## 9. Métriques de succès

### KPIs post-déploiement (à mesurer sur Grafana/Prometheus)

| Métrique | Baseline attendue | Alerte si |
|---|---|---|
| `kovixel.validation.reject{validator=MagicBytesValidator}` | < 0.5% des requêtes | > 2% (attaque probable) |
| `kovixel.validation.reject{validator=FileSizeValidator}` | < 5% des requêtes | > 15% |
| `kovixel.validation.reject{validator=ZipBombValidator}` | ~0 | Toute occurrence (alerte sécurité) |
| `kovixel.validation.duration{p99}` | < 50 ms (C0-C2), < 200 ms (C3-C4) | > 500 ms |
| Taux d'erreur 5xx sur les endpoints PDF | Actuellement non mesuré | > 0.1% (régression) |

### Sécurité — objectifs

- **0** fichier exécutable traité par PDFBox après Phase 1
- **0** `OutOfMemoryError` lié à une image en production après Phase 2
- **0** exception `IndexOutOfBoundsException` liée à des paramètres OOB après Phase 2

---

## Annexe A — Inventory des fichiers à modifier

### Nouveaux fichiers (à créer)

```
src/main/java/com/kovixel/common/validation/
  ├── FileValidationContext.java
  ├── FileValidator.java
  ├── FileValidationPipeline.java
  ├── ValidationProperties.java
  ├── ToolType.java
  ├── validators/
  │   ├── TransportValidator.java
  │   ├── FileSizeValidator.java
  │   ├── MagicBytesValidator.java
  │   ├── PdfStructureValidator.java
  │   ├── ImageStructureValidator.java
  │   ├── OfficeStructureValidator.java
  │   ├── ZipBombValidator.java
  │   ├── PixelBombValidator.java
  │   ├── MacroDetectionValidator.java
  │   ├── PdfSemanticValidator.java
  │   └── PageRangeBoundsValidator.java
  └── audit/
      └── ValidationAuditLogger.java

src/test/java/com/kovixel/common/validation/
  ├── FileValidationPipelineTest.java
  ├── FileValidationPipelineIT.java
  └── validators/
      ├── MagicBytesValidatorTest.java
      ├── FileSizeValidatorTest.java
      ├── PdfStructureValidatorTest.java
      ├── ZipBombValidatorTest.java
      ├── PixelBombValidatorTest.java
      └── MacroDetectionValidatorTest.java

src/test/resources/fixtures/validation/
  ├── valid.pdf
  ├── valid_encrypted.pdf
  ├── valid_0pages.pdf
  ├── valid_image_only.pdf
  ├── exe_as_pdf.bin
  ├── zip_bomb.docx
  ├── pixel_bomb_header.jpg
  ├── macro_enabled.docx
  ├── valid.docx
  ├── valid.jpg
  └── valid.png
```

### Fichiers existants à modifier

```
src/main/java/com/kovixel/core/conversion/ConversionController.java
  → Brancher FileValidationPipeline dans compress, rotate, split,
    merge, extractTables, extractImages, imagesToPdf, pdfToImage

src/main/java/com/kovixel/pdflock/service/PdfLockServiceImpl.java
  → Supprimer validatePdf() + MIME check inline

src/main/java/com/kovixel/pdfunlock/service/PdfUnlockServiceImpl.java
  → Supprimer validateAndCountPages() + MIME check inline

src/main/java/com/kovixel/pdfwatermark/service/PdfWatermarkServiceImpl.java
  → Supprimer validatePdf() + MIME check inline

src/main/java/com/kovixel/pdfpagenumber/service/PdfPageNumberServiceImpl.java
  → Supprimer validatePdf() + MIME check inline

src/main/java/com/kovixel/pdfesignature/service/PdfEsignatureServiceImpl.java
  → Supprimer MIME check inline + taille inline

src/main/java/com/kovixel/ocr/service/OcrServiceImpl.java
  → Supprimer MIME check + validatePdf + pageCount inline

src/main/java/com/kovixel/ai/summary/service/SummaryServiceImpl.java
  → Supprimer validateFile() + classify() inline

src/main/java/com/kovixel/core/conversion/wordtopdf/OfficeFileValidator.java
  → Déléguer magic bytes detection à MagicBytesValidator
  → Déléguer zip bomb detection à ZipBombValidator

src/main/resources/application.yml
  → Ajouter section kovixel.validation.*
```

---

## Annexe B — Décisions d'architecture

| Décision | Choix | Justification |
|---|---|---|
| Pattern de validation | Pipeline (Chain of Responsibility) plutôt qu'AOP | Plus explicite, plus debuggable, contexte riche partageable entre validators |
| Activation par outil | `validator.appliesTo(ToolType)` plutôt qu'annotation | Pas de magie Spring AOP, visible dans le code, testable sans Spring |
| Fail-fast | Premier validator qui échoue lève immédiatement | Coût minimal, pas d'accumulation d'erreurs inutile |
| Magic bytes | Vérification des 16 premiers octets en mémoire | Suffisant pour tous les formats, pas besoin de lire le fichier entier |
| Zip bomb | Streaming (ZipInputStream) sans décompression complète | Protège contre l'OOM sans coût CPU prohibitif |
| Pixel bomb | Lecture partielle des headers image seulement | Pas besoin de `ImageIO.read()` complet pour connaître les dimensions |
| Logs | Audit logger séparé du logger applicatif | Permet une analyse sécurité indépendante (SIEM, alerting) |
| Tests | Fixtures binaires réelles (pas générés programmatiquement) | Les générateurs programmatiques peuvent ne pas reproduire les magic bytes corrects |

---

*Roadmap générée à partir de l'audit exhaustif du codebase Kovixel · Kovixel Engineering · 2026-06-23*
