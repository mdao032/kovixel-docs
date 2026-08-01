# 📋 Compresser PDF : Roadmap d'implémentation Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
POST /api/v1/pdf/compress?level=EBOOK
        │
        ▼
  ┌────────────────────────────────────────────────────────┐
  │  kovixel.compression.force-ghostscript=true/false        │
  │  (bascule globale dans application.properties)          │
  └────────────────────────────────────────────────────────┘
        │
        ├─ force-ghostscript=true ──► Ghostscript (TOUS les utilisateurs)
        │
        └─ force-ghostscript=false
               │
               ▼
         Utilisateur PRO/ENTERPRISE ?
              ├─ OUI ──► Ghostscript local  (meilleure compression structurelle)
              │          │ Si absent ou erreur ──────────────────────────────┐
              │                                                               │
              └─ NON ──► PdfBoxCompressor  (embarqué Java, toujours dispo) ◄─┘
                         │ Si erreur critique
                         └──► KovixelException SERVICE_UNAVAILABLE

        ▼ (pour les deux chemins)
  ┌────────────────────────────────────────────────────────┐
  │  CompressionResult                                      │
  │  { compressedBytes, originalSize, compressedSize,       │
  │    ratio, engine, level, durationMs }                   │
  └────────────────────────────────────────────────────────┘
        │
        ▼
  Headers HTTP de réponse :
  X-Original-Size, X-Compressed-Size,
  X-Compression-Ratio, X-Compression-Engine
```

### Moteurs et niveaux de qualité

| Moteur              | Score | Niveaux supportés              | Disponibilité           |
|---------------------|-------|-------------------------------|-------------------------|
| Ghostscript local   | 9/10  | SCREEN · EBOOK · PRINTER · PREPRESS | Installé sur le host  |
| PdfBoxCompressor    | 7/10  | SCREEN · EBOOK · PRINTER      | Toujours (embarqué)     |

### Niveaux de compression

| Niveau    | DPI images | Usage cible                          | Réduction typique |
|-----------|-----------|--------------------------------------|-------------------|
| `SCREEN`  | 72 dpi    | Email, partage web, aperçu rapide    | 60–85 %           |
| `EBOOK`   | 150 dpi   | Lecture écran, archives, partage     | 40–70 %           |
| `PRINTER` | 300 dpi   | Impression qualité, archivage légal  | 10–30 %           |
| `PREPRESS`| 300 dpi+  | Pré-impression, profils ICC (PRO)    | 5–15 %            |

---

## PROMPT 1 — Configuration & CompressionProperties

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

```
Dans application.yml, ajoute une section dédiée à la compression PDF :

kovixel:
  compression:
    # ── Bascule globale Ghostscript ───────────────────────────────────────────
    # true  → tous les utilisateurs passent par Ghostscript (si disponible)
    # false → routing par plan : PRO=Ghostscript, FREE=PdfBoxCompressor
    force-ghostscript: false

    # ── Seuils de traitement ─────────────────────────────────────────────────
    # Taille max acceptée en synchrone (20 MB). Au-delà → job asynchrone.
    max-sync-bytes: 20971520        # 20 MB

    # Taille max absolue acceptée (100 MB). Au-delà → HTTP 413.
    max-file-bytes: 104857600       # 100 MB

    # ── Moteur Ghostscript ────────────────────────────────────────────────────
    ghostscript:
      enabled: true
      # Chemin vers l'exécutable (utilise le PATH système si "gs")
      executable: ${GHOSTSCRIPT_PATH:gs}
      # Timeout en secondes pour l'exécution du processus
      timeout-seconds: 120
      # Active le niveau PREPRESS (PRO uniquement)
      prepress-enabled: true

    # ── Moteur PdfBoxCompressor (fallback embarqué) ───────────────────────────
    pdfbox:
      # Qualité JPEG lors de la recompression des images (0.0–1.0)
      jpeg-quality: 0.75
      # Supprime les métadonnées XMP/Info non essentielles
      strip-metadata: true
      # Sous-ensemble les polices embarquées (réduit leur taille)
      font-subsetting: true

Dans application-dev.yml, surcharge pour le développement local :

kovixel:
  compression:
    force-ghostscript: false
    ghostscript:
      enabled: true           # Ghostscript généralement disponible en dev
      executable: gs          # ou "gswin64c" sur Windows

Dans ConversionProperties.java, ajoute une classe imbriquée Compression
(comme les classes Adobe, Gotenberg, Image existantes) avec tous les champs
ci-dessus, annotations @Data et @NestedConfigurationProperty.
Ajoute le champ compression dans la classe racine ConversionProperties.
```

---

## PROMPT 2 — GhostscriptCompressor

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/compression/GhostscriptCompressor.java`
- `src/main/java/com/kovixel/core/compression/GhostscriptUnavailableException.java`

```
Crée un composant Spring qui délègue la compression PDF à l'exécutable
Ghostscript installé sur le système hôte.

Classe GhostscriptCompressor :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties pour lire executable, timeout, prepress-enabled

Méthode principale :
  byte[] compress(byte[] pdfBytes, CompressionLevel level)

  Flux d'exécution :
  1. Créer deux fichiers temporaires (Files.createTempFile) : input.pdf, output.pdf
  2. Écrire les bytes PDF dans le fichier temporaire d'entrée
  3. Construire la commande Ghostscript :
       gs -sDEVICE=pdfwrite
          -dCompatibilityLevel=1.4
          -dPDFSETTINGS=/{ghostscriptProfile(level)}
          -dNOPAUSE -dBATCH -dQUIET
          -sOutputFile={outputFile}
          {inputFile}
     Profils Ghostscript par niveau :
       SCREEN   → /screen
       EBOOK    → /ebook
       PRINTER  → /printer
       PREPRESS → /prepress  (si prepress-enabled=true, sinon /printer)
  4. Exécuter via ProcessBuilder avec timeout configuré
  5. Vérifier exitCode == 0, sinon lancer GhostscriptUnavailableException
  6. Lire le fichier de sortie et retourner les bytes
  7. Supprimer les fichiers temporaires dans le bloc finally
  8. Logger : niveau, taille initiale, taille finale, ratio, durée (ms), exitCode

Méthode isAvailable() : boolean
  - Exécuter "gs --version" avec timeout 3 secondes
  - Retourner true si exitCode == 0
  - Résultat mis en cache volatile 60 secondes (simple champ + timestamp)
  - En cas d'exception → retourner false sans relancer

Méthode buildCommand(CompressionLevel level, Path input, Path output) : List<String>
  (méthode package-private pour testabilité)

Gestion d'erreurs :
  - Si le fichier de sortie est vide ou < 100 bytes → relancer avec niveau supérieur
    (SCREEN → EBOOK si résultat invalide), puis logger WARN
  - Si Ghostscript non disponible (IOException au démarrage du process)
    → lancer GhostscriptUnavailableException
  - Si timeout → lancer GhostscriptUnavailableException avec message explicite

Crée GhostscriptUnavailableException extends RuntimeException.
```

---

## PROMPT 3 — PdfBoxCompressor (refactorisation + enrichissement)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/compression/PdfBoxCompressor.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`

```
Extrait et enrichit la logique de compression de PdfManipulationService
dans une classe dédiée PdfBoxCompressor.

Classe PdfBoxCompressor :
- Annotée @Component, @Slf4j
- Injecte ConversionProperties pour lire jpeg-quality, strip-metadata, font-subsetting

Méthode principale :
  byte[] compress(byte[] pdfBytes, CompressionLevel level)

  Opérations à appliquer dans l'ordre (chacune est optionnelle selon les propriétés) :

  1. RECOMPRESSION DES IMAGES (existant, à déplacer depuis PdfManipulationService)
     → Parcourir toutes les PDImageXObject de chaque page
     → Calculer scale = Math.min(1.0f, level.dpi / 300.0f)
     → Recompresser en JPEG avec jpeg-quality configurable via Thumbnailator
     → Logger le nombre d'images recompressées

  2. NETTOYAGE DES MÉTADONNÉES (nouveau, si strip-metadata=true)
     → Supprimer doc.getDocumentInformation() : Author, Subject, Keywords, Creator,
       Producer (remplacer Producer par "Kovixel")
     → Supprimer les métadonnées XMP si présentes : doc.getDocumentCatalog().setMetadata(null)

  3. SOUS-ENSEMBLE DES POLICES (nouveau, si font-subsetting=true)
     → Pour chaque PDFont dans chaque page :
       Si la police est une PDType0Font ou PDTrueTypeFont avec encodage complet
       → Appliquer subset embedding : conserver uniquement les glyphes utilisés
       (utiliser PDFont.willBeSubset() et PDFont.subset() si disponible dans PDFBox 3.x)

  4. OPTIMISATION DES STREAMS INTERNES
     → Appliquer doc.save() avec CompressParameters.DEFAULT_COMPRESS
       (active la compression Flate sur les streams du document)

  5. SUPPRESSION DES OBJETS ORPHELINS
     → Appeler doc.getDocument().getXrefTable() pour détecter les objets non référencés
       (PDFBox gère ceci automatiquement à la sauvegarde)

Mise à jour PdfManipulationService :
  - Dans la méthode compress(byte[] pdf, CompressionLevel level) :
    → Déléguer à pdfBoxCompressor.compress(pdf, level)
    → Supprimer le code inline de compression (compressImages)
  - Garder la méthode privée compressImages() commentée pour référence

Méthode getEstimatedReduction(CompressionLevel level) : int
  Retourne le pourcentage de réduction typique estimé (pour l'UI) :
  SCREEN=70, EBOOK=55, PRINTER=20, PREPRESS=10
```

---

## PROMPT 4 — CompressionResult & Headers de réponse

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/compression/CompressionResult.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Crée un record Java qui encapsule le résultat d'une compression
avec toutes les métadonnées utiles.

Record CompressionResult :

  public record CompressionResult(
      byte[]           compressedBytes,
      long             originalSizeBytes,
      long             compressedSizeBytes,
      double           compressionRatio,     // ex: 0.65 = 65% de réduction
      String           engine,               // "GHOSTSCRIPT" | "PDFBOX"
      CompressionLevel level,
      long             durationMs,
      boolean          improved              // false si compressé > original
  ) {
      /** Retourne true si la compression a effectivement réduit la taille. */
      public boolean improved() { return compressedSizeBytes < originalSizeBytes; }

      /** Résumé loggable. */
      public String summary() {
          return String.format(
              "engine=%s level=%s %d→%d bytes (%.1f%% réduit) en %d ms",
              engine, level, originalSizeBytes, compressedSizeBytes,
              compressionRatio * 100, durationMs
          );
      }
  }

Mise à jour ConversionController :
  Dans la méthode POST /api/v1/pdf/compress :
  1. Recevoir le résultat sous forme de CompressionResult (au lieu de byte[])
  2. Si CompressionResult.improved() == false :
     → Retourner quand même le fichier original avec header X-Compression-Skipped: true
     → Logger WARN : "Compression ignorée — fichier déjà optimisé"
  3. Ajouter les headers suivants sur la réponse HTTP :
       X-Original-Size:       {originalSizeBytes}
       X-Compressed-Size:     {compressedSizeBytes}
       X-Compression-Ratio:   {compressionRatio arrondi à 2 décimales}
       X-Compression-Engine:  {engine}
       X-Compression-Level:   {level}
       X-Processing-Time-Ms:  {durationMs}
  4. Paramètre de requête supplémentaire :
       ?level=SCREEN|EBOOK|PRINTER|PREPRESS (défaut: EBOOK)
     Valider que PREPRESS n'est accessible qu'aux plans PRO/ENTERPRISE
     → sinon HTTP 403 avec message explicite

Le frontend Angular pourra lire ces headers pour afficher le ratio de réduction
dans l'UI de l'outil (ex : "65% de réduction — 12.4 MB → 4.3 MB").
```

---

## PROMPT 5 — CompressionRouter (orchestrateur)

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/compression/CompressionRouter.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/PdfManipulationService.java`

```
Crée la classe CompressionRouter qui contient toute la logique de routage
selon le plan utilisateur et les feature flags.

Classe CompressionRouter :
- Annotée @Component, @Slf4j
- Injecte : ConversionProperties, GhostscriptCompressor, PdfBoxCompressor,
            MeterRegistry (Micrometer)

Méthode principale :
  CompressionResult route(byte[] pdfBytes, CompressionLevel level, Long userId)

Logique de routage EXACTE :

  1. Valider le niveau PREPRESS :
     Si level == PREPRESS et plan != PRO/ENTERPRISE
     → forcer level = PRINTER, logger INFO

  2. Si kovixel.compression.force-ghostscript=true :
     → Tenter Ghostscript → si GhostscriptUnavailableException → PdfBoxCompressor
     → Logger chaque basculement en WARN avec le motif

  3. Si force-ghostscript=false :
     a. Récupérer le plan (FREE si userId=null)
     b. Si plan = PRO ou ENTERPRISE :
        → Tenter Ghostscript → si GhostscriptUnavailableException → PdfBoxCompressor
     c. Si plan = FREE ou ANONYMOUS :
        → Utiliser directement PdfBoxCompressor (pas de dépendance externe)

  4. Dans tous les cas :
     a. Mesurer la durée via System.nanoTime()
     b. Construire et retourner le CompressionResult avec toutes les métadonnées
     c. Si le résultat est plus lourd que l'original (fichiers déjà compressés) :
        → Retourner CompressionResult avec improved=false et les bytes ORIGINAUX
        → Logger INFO : "Aucun gain — fichier déjà optimisé, retour original"

Métriques à enregistrer après chaque appel (voir PROMPT 7 pour les détails) :
  - kovixel.compression.total (tags: engine, level, plan, status)
  - kovixel.compression.duration (Timer, tags: engine, level)
  - kovixel.compression.ratio (DistributionSummary, valeur = compressionRatio * 100)
  - kovixel.compression.fallback_total (si basculement Ghostscript→PdfBox)

Mise à jour PdfManipulationService :
  Dans compress(byte[] pdf, CompressionLevel level) :
  → Déléguer à compressionRouter.route(pdf, level, null)
  → Retourner result.compressedBytes()
  (Conserve la signature existante pour la compatibilité des appels internes)
```

---

## PROMPT 6 — Frontend Angular : affichage du résultat enrichi

**Fichiers à modifier :**
- `kovixel-ui/src/app/features/tools/tool-page.component.ts`
- `kovixel-ui/src/app/core/services/conversion.service.ts`

```
Mets à jour le frontend pour exploiter les headers de réponse renvoyés
par l'API de compression.

Dans conversion.service.ts :
  Crée une interface CompressionMeta :
    interface CompressionMeta {
      originalSize:     number;   // X-Original-Size
      compressedSize:   number;   // X-Compressed-Size
      compressionRatio: number;   // X-Compression-Ratio (ex: 0.65)
      engine:           string;   // X-Compression-Engine (interne, non affiché)
      level:            string;   // X-Compression-Level
      durationMs:       number;   // X-Processing-Time-Ms
      skipped:          boolean;  // X-Compression-Skipped
    }

  Crée la méthode compressPdf(file: File, level = 'EBOOK') retournant
  Observable<{ blob: Blob; meta: CompressionMeta }> :
  - Utilise HttpClient avec observe: 'response' pour accéder aux headers
  - Extrait tous les headers X-* et les retourne dans l'objet meta

Dans tool-page.component.ts, pour le slug 'convert/compress' :
  Après une conversion réussie, afficher un bloc de résultat enrichi :

  ┌────────────────────────────────────────────────────────┐
  │ ✅  Compression réussie                                 │
  │                                                         │
  │  Taille originale  →  Taille finale     Réduction       │
  │     12.4 MB        →    4.3 MB         🟢 65%           │
  │                                                         │
  │  [████████████░░░░░░░] Barre de progression visuelle    │
  │                                                         │
  │  [↓ Télécharger le PDF compressé]                       │
  │  [🔄 Compresser un autre fichier]                       │
  └────────────────────────────────────────────────────────┘

  Code couleur du badge de réduction :
  - > 50% → vert  (bg: rgba(34,197,94,0.15), text: #16a34a)
  - 20–50% → amber (bg: rgba(245,158,11,0.15), text: #d97706)
  - < 20%  → bleu  (bg: rgba(59,130,246,0.15), text: #2563eb)

  Si skipped=true (fichier déjà optimisé) :
  - Afficher un message d'info : "Ce fichier est déjà optimisé, aucun gain possible."
  - Proposer quand même le téléchargement

  Utiliser des signaux Angular (signal/computed) pour les valeurs :
    readonly compressionMeta = signal<CompressionMeta | null>(null);
    readonly compressionReductionPct = computed(() => {
      const m = this.compressionMeta();
      return m ? Math.round(m.compressionRatio * 100) : 0;
    });
    readonly reductionColorClass = computed(() => {
      const pct = this.compressionReductionPct();
      if (pct > 50) return 'badge--green';
      if (pct > 20) return 'badge--amber';
      return 'badge--blue';
    });
```

---

## PROMPT 7 — Métriques, Health & Observabilité

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/compression/CompressionHealthIndicator.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`
- `src/main/java/com/kovixel/core/compression/CompressionRouter.java`

```
Enrichis l'observabilité du système de compression.

Métriques Micrometer à enregistrer dans CompressionRouter :

  kovixel.compression.total
    Type : Counter
    Tags : engine=GHOSTSCRIPT|PDFBOX, level=SCREEN|EBOOK|PRINTER|PREPRESS,
           plan=FREE|PRO|ENTERPRISE|ANONYMOUS, status=SUCCESS|ERROR|SKIPPED
    Incrémenter après chaque tentative.

  kovixel.compression.duration
    Type : Timer
    Tags : engine=GHOSTSCRIPT|PDFBOX, level=SCREEN|EBOOK|PRINTER|PREPRESS
    Enregistrer la durée de chaque appel moteur (pas seulement les succès).

  kovixel.compression.ratio
    Type : DistributionSummary
    Tags : engine=GHOSTSCRIPT|PDFBOX, level=SCREEN|EBOOK|PRINTER|PREPRESS
    Valeur : compressionRatio * 100 (ex: 65.0 pour 65%)
    Permet de calculer le ratio moyen en production.

  kovixel.compression.bytes_saved
    Type : DistributionSummary
    Tags : engine, level
    Valeur : originalSize - compressedSize
    Permet de calculer les MB économisés au total.

  kovixel.compression.fallback_total
    Type : Counter
    Tags : from=GHOSTSCRIPT, to=PDFBOX, reason=<exception.class.simpleName>
    Incrémenter à chaque basculement.

Crée CompressionHealthIndicator implements HealthIndicator :
  @Component
  public class CompressionHealthIndicator implements HealthIndicator {
    - Injecte GhostscriptCompressor
    - Dans health() :
      * Appeler ghostscriptCompressor.isAvailable()
      * Si available → Health.up().withDetail("ghostscript", "UP")
      * Si not available → Health.degraded().withDetail("ghostscript", "DOWN (fallback PdfBox actif)")
      * Ajouter : withDetail("pdfbox", "UP") (toujours disponible)
    - NE PAS retourner Health.down() — PdfBoxCompressor est toujours le fallback
      (le service reste fonctionnel même sans Ghostscript)
  }

Enrichis ConversionEngineHealthIndicator existant :
  - Ajouter un detail "compression" : { ghostscript: UP/DOWN, pdfbox: UP }
  - Ne pas casser les checks existants (gotenberg, adobe)
```

---

## PROMPT 8 — Tests & Documentation

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/compression/CompressionRouterTest.java`
- `src/test/java/com/kovixel/core/compression/GhostscriptCompressorTest.java`
- `src/test/java/com/kovixel/core/compression/PdfBoxCompressorTest.java`

**Fichiers à modifier / créer :**
- `README.md` (section "## Configuration Compression PDF")
- `.env.example`

```
TESTS

CompressionRouterTest (tests unitaires avec Mockito) :
  @ExtendWith(MockitoExtension.class)

  - force-ghostscript=true + Ghostscript disponible → moteur = GHOSTSCRIPT
  - force-ghostscript=true + Ghostscript indisponible → fallback PDFBOX
  - force-ghostscript=false + plan PRO → moteur = GHOSTSCRIPT
  - force-ghostscript=false + plan FREE → moteur = PDFBOX (pas de tentative Ghostscript)
  - force-ghostscript=false + plan PRO + Ghostscript down → fallback PDFBOX
  - level=PREPRESS + plan FREE → niveau rétrogradé à PRINTER automatiquement
  - Résultat plus lourd que l'original → CompressionResult.improved() == false,
    bytes retournés = bytes originaux
  - La métrique kovixel.compression.fallback_total est incrémentée lors d'un fallback
  Utiliser un SimpleMeterRegistry pour les tests de métriques.

GhostscriptCompressorTest (tests d'intégration, @EnabledOnOs / @ConditionalOnGhostscript) :
  - isAvailable() : true si gs présent dans le PATH, false sinon
  - compress() avec un PDF de test réel (src/test/resources/sample.pdf) :
    * Vérifier que le résultat est un PDF valide (magic bytes %PDF)
    * Vérifier que la taille est < originale pour un PDF avec images
  - buildCommand() : vérifier que le profil /screen est utilisé pour SCREEN,
    /ebook pour EBOOK, /printer pour PRINTER et PREPRESS (si prepress-enabled=false)
  - Timeout : mock ProcessBuilder avec délai > timeout → GhostscriptUnavailableException
  Annoter la classe avec @EnabledIf("ghostscript.available") ou @Disabled si
  Ghostscript n'est pas disponible dans l'environnement CI.

PdfBoxCompressorTest (tests unitaires purs) :
  - compress() retourne un PDF valide (magic bytes %PDF)
  - compress() avec niveau SCREEN produit un fichier plus petit que PRINTER
    (sur un PDF de test avec des images haute résolution)
  - strip-metadata=true → champs Author/Subject supprimés dans le résultat
  - strip-metadata=false → champs Author/Subject conservés
  - PDF sans images → compress() retourne un résultat sans erreur
    (ne pas cracher sur un PDF texte pur)
  Utiliser un PDF synthétique généré par PDFBox dans le @BeforeAll.

DOCUMENTATION

Dans README.md, ajoute une section "## Configuration Compression PDF" :

  ### Variables d'environnement

  | Variable           | Description                          | Obligatoire |
  |--------------------|--------------------------------------|-------------|
  | GHOSTSCRIPT_PATH   | Chemin vers l'exécutable Ghostscript | Non (défaut: gs) |

  ### Feature flags (application.yml)

  | Propriété                                   | Défaut  | Description                           |
  |---------------------------------------------|---------|---------------------------------------|
  | kovixel.compression.force-ghostscript        | false   | Force Ghostscript pour tous les users |
  | kovixel.compression.ghostscript.enabled      | true    | Active/désactive le moteur Ghostscript|
  | kovixel.compression.ghostscript.prepress-enabled | true | Active le niveau PREPRESS (PRO only) |
  | kovixel.compression.pdfbox.jpeg-quality      | 0.75    | Qualité JPEG des images recompressées |
  | kovixel.compression.pdfbox.strip-metadata    | true    | Supprime les métadonnées non essentielles |

  ### Installation de Ghostscript

  Ubuntu/Debian :
    apt-get install -y ghostscript

  macOS (Homebrew) :
    brew install ghostscript

  Docker (dans le Dockerfile de l'application) :
    RUN apt-get update && apt-get install -y ghostscript && rm -rf /var/lib/apt/lists/*

Dans .env.example, ajoute :
  GHOSTSCRIPT_PATH=gs

Dans docker-compose.yml, assure-toi que le service kovixel-api
installe Ghostscript dans son Dockerfile ou via un script d'entrypoint.
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8
  Config    Ghostscript  PdfBox    Result+    Router    Frontend    Métriques   Tests+
                         refacto   Headers               UI                     Docs
```

> **Note** : PROMPT 2 et PROMPT 3 peuvent être exécutés en parallèle —
> les deux compresseurs sont indépendants. Le router (PROMPT 5) nécessite les deux.

---

## Critères de validation finale

- [ ] `mvn test` passe sans erreur
- [ ] `docker-compose up` démarre sans erreur
- [ ] Compression EBOOK fonctionne avec un utilisateur FREE (PdfBoxCompressor)
- [ ] Compression EBOOK fonctionne avec un utilisateur PRO (Ghostscript)
- [ ] Basculement automatique Ghostscript→PdfBox si `gs` est retiré du PATH
- [ ] `curl /actuator/health` expose `{ compression: { ghostscript: "UP", pdfbox: "UP" } }`
- [ ] `curl /actuator/metrics/kovixel.compression.total` retourne des valeurs
- [ ] Headers X-Original-Size, X-Compressed-Size, X-Compression-Ratio présents dans la réponse
- [ ] Flag `force-ghostscript=true` fait passer un utilisateur FREE par Ghostscript
- [ ] Un PDF de test (12 MB, images 300 dpi) compressé en SCREEN pèse < 5 MB
- [ ] Un PDF texte pur compressé ne génère pas d'erreur (improved=false, original retourné)
- [ ] Le frontend affiche correctement le ratio de réduction avec la bonne couleur

