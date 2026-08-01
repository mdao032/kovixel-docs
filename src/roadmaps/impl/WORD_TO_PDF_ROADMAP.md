# 📋 Word → PDF : Roadmap d'implémentation Pro/Ultra-Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.
>
> **Contexte** : Le projet dispose déjà de `ConversionProperties`, `GotenbergClient`,
> `AdobePdfServicesClient`, `ConversionRouter` (PDF→DOCX) et `LibreOfficeConfig`.
> Cette roadmap réutilise ces composants et en crée de nouveaux dédiés à Word→PDF.

---

## Vue d'ensemble de l'architecture cible

```
Requête de conversion (DOCX / XLSX / PPTX / ODT / RTF…)
        │
        ▼
  ┌──────────────────────────────────────────────────────┐
  │  kovixel.word-to-pdf.force-adobe=true/false           │
  │  (bascule globale dans application.yml)              │
  └──────────────────────────────────────────────────────┘
        │
        ├─ force-adobe=true ──► Adobe PDF Services CreatePDF (TOUS les utilisateurs)
        │                       │ Si Adobe down/erreur
        │                       └──────────────────────────────────────────────┐
        │                                                                      │
        └─ force-adobe=false                                                   │
               │                                                               │
               ▼                                                               ▼
         Utilisateur PRO/ENTERPRISE ?                                          │
              ├─ OUI ──► Adobe PDF Services CreatePDF (9.5/10)                │
              │          │ Si Adobe down/erreur                                │
              │          └─────────────────────────────────────────────────►  │
              │                                                                │
              └─ NON ──► Gotenberg + polices MS (9/10) ◄──────────────────────┘
                         (Gotenberg/LibreOffice est EXCELLENT pour Office→PDF)
                         │ Si Gotenberg down/erreur
                         │
                         └──► LibreOffice local (7.5/10 · fallback ultime)
```

> **Pourquoi Gotenberg est prioritaire pour les FREE ?**  
> LibreOffice (via Gotenberg) est le moteur de référence pour la conversion Office→PDF.
> Contrairement à PDF→Word (sens inverse difficile), Word→PDF est une opération
> native pour LibreOffice : fidélité typographique excellente avec les polices MS installées.

---

## Formats d'entrée supportés

| Format | Extension | MIME Type                          | Notes                          |
|--------|-----------|------------------------------------|--------------------------------|
| Word   | .docx     | application/vnd.openxmlformats-officedocument.wordprocessingml.document | Priorité |
| Word   | .doc      | application/msword                 | Ancien format, supporté        |
| Word   | .odt      | application/vnd.oasis.opendocument.text | OpenDocument Text         |
| Word   | .rtf      | application/rtf                    | Rich Text Format               |
| Excel  | .xlsx     | application/vnd.openxmlformats-officedocument.spreadsheetml.sheet | Tous onglets |
| Excel  | .xls      | application/vnd.ms-excel           | Ancien format Excel            |
| Excel  | .ods      | application/vnd.oasis.opendocument.spreadsheet | OpenDocument Calc |
| PowerPoint | .pptx | application/vnd.openxmlformats-officedocument.presentationml.presentation | |
| PowerPoint | .ppt  | application/vnd.ms-powerpoint     | Ancien format PPT              |
| PowerPoint | .odp  | application/vnd.oasis.opendocument.presentation | OpenDocument Impress |

---

## PROMPT 1 — Configuration & Feature Flag

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

```
Dans application.yml, ajoute une section dédiée à la conversion Word→PDF
SOUS la section kovixel.conversion existante (ne pas dupliquer les clés existantes) :

kovixel:
  word-to-pdf:
    # ── Bascule globale Adobe PDF Services ───────────────────────────────────
    # true  → tous les utilisateurs passent par Adobe CreatePDF
    # false → routing par plan (défaut) : PRO=Adobe, FREE=Gotenberg, fallback=LibreOffice
    force-adobe: false

    # ── Formats acceptés ──────────────────────────────────────────────────────
    # Liste des extensions autorisées (en minuscules, sans point)
    allowed-extensions:
      - docx
      - doc
      - odt
      - rtf
      - xlsx
      - xls
      - ods
      - pptx
      - ppt
      - odp

    # ── Taille max du fichier source (en bytes) ───────────────────────────────
    max-file-size-bytes: 52428800   # 50 MB

    # ── Adobe PDF Services ────────────────────────────────────────────────────
    adobe:
      # Réutilise ADOBE_CLIENT_ID / ADOBE_CLIENT_SECRET de la section conversion
      timeout-seconds: 120
      max-retries: 2

    # ── Gotenberg ─────────────────────────────────────────────────────────────
    gotenberg:
      timeout-seconds: 60
      # Paramètres LibreOffice avancés passés à Gotenberg
      landscape: false
      page-ranges: ""        # vide = toutes les pages

    # ── LibreOffice local (fallback) ──────────────────────────────────────────
    libreoffice:
      timeout-seconds: 90

Dans application-dev.yml, ajoute la surcharge dev :

kovixel:
  word-to-pdf:
    force-adobe: false
    adobe:
      timeout-seconds: 30
    gotenberg:
      timeout-seconds: 30

Dans ConversionProperties.java, ajoute une inner class WordToPdfProperties
annotée @ConfigurationProperties(prefix = "kovixel.word-to-pdf") avec :
- boolean forceAdobe
- List<String> allowedExtensions
- long maxFileSizeBytes
- AdobeWordProps adobe (timeoutSeconds, maxRetries)
- GotenbergWordProps gotenberg (timeoutSeconds, landscape, pageRanges)
- LibreOfficeWordProps libreoffice (timeoutSeconds)

Enregistre la classe comme bean Spring (@EnableConfigurationProperties ou @Configuration).
Ajoute une méthode isExtensionAllowed(String extension) → boolean.
```

---

## PROMPT 2 — Validation & sanitisation des fichiers Office

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/wordtopdf/OfficeFileValidator.java`

```
Crée un composant Spring @Component OfficeFileValidator qui valide et sanitise
les fichiers Office avant conversion.

Méthodes :

  void validate(byte[] content, String originalFilename, WordToPdfProperties props)
    - Vérifie que content n'est pas vide/null → KovixelException BAD_REQUEST
    - Vérifie que la taille ≤ maxFileSizeBytes → KovixelException PAYLOAD_TOO_LARGE
    - Extrait l'extension depuis originalFilename
    - Vérifie que l'extension est dans allowedExtensions → KovixelException BAD_REQUEST
    - Effectue une vérification des magic bytes (4 premiers octets) :
        PK\x03\x04 → fichier ZIP (docx, xlsx, pptx sont des ZIP) ✓
        \xD0\xCF\x11\xE0 → fichier OLE2 (doc, xls, ppt) ✓
        {RTF ou \{\\rtf → fichier RTF ✓
        Sinon → log WARN mais ne pas rejeter (ODT/ODS peuvent varier)
    - Log les informations : filename, extension, size, magicBytes

  String resolveExtension(String originalFilename)
    - Extrait l'extension en lowercase depuis le nom de fichier
    - Si pas d'extension → lève KovixelException BAD_REQUEST

  String resolveMimeType(String extension)
    - Retourne le MIME type correct selon l'extension (utilise une Map statique)
    - Utilisé pour le Content-Type de la réponse

Annotée @Component, @Slf4j.
Ne pas utiliser Apache Tika (trop lourd) — validation par magic bytes et extension suffisante.
```

---

## PROMPT 3 — Client Gotenberg pour Word→PDF

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/gotenberg/GotenbergClient.java`

```
Dans le GotenbergClient existant, ajoute une méthode dédiée Word→PDF :

  byte[] convertOfficeToPdf(byte[] officeContent, String filename,
                             WordToPdfProperties.GotenbergWordProps config)

  Implémentation :
  - Appelle POST {base-url}/forms/libreoffice/convert/
  - Content-Type: multipart/form-data
  - Part "files": le fichier Office avec le filename ORIGINAL (ex: "document.docx")
    → IMPORTANT : Gotenberg détecte le format via l'extension du nom de fichier !
  - Part "landscape": "true" | "false" selon config.isLandscape()
  - Part "nativePdfFormat": "PDF/A-1a" (pour une meilleure compatibilité)
  - Si config.getPageRanges() n'est pas vide → Part "nativePageRanges": valeur
  - Timeout configurable via config.getTimeoutSeconds()
  - Si réponse vide ou taille < 500 bytes → lance GotenbergServiceException
    avec message "Résultat PDF trop petit, conversion probablement échouée"
  - Log : filename, taille source, durée, taille résultat
  - Retourne les bytes du PDF

  Ajoute également :
  boolean isLibreOfficeAvailable()
    - GET {base-url}/health → vérifie que libreoffice est dans les routes actives
    - Fallback : retourne isAvailable() si la réponse ne contient pas ce détail
```

---

## PROMPT 4 — Client Adobe PDF Services pour Word→PDF

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/adobe/AdobePdfServicesClient.java`

```
Dans AdobePdfServicesClient, ajoute une méthode dédiée à la conversion Word→PDF
en utilisant l'opération "createpdf" de l'API Adobe PDF Services REST v3.

Flux Adobe CreatePDF :
1. POST /token           → obtenir access_token (cache existant, réutiliser)
2. POST /assets          → uploader le fichier Office → assetID + uploadUri
3. PUT  {uploadUri}      → uploader les bytes avec Content-Type exact du format Office
4. POST /operation/createpdf → créer le job
                            Body JSON :
                            {
                              "assetID": "<assetID>",
                              "outputFormat": "pdf"
                            }
                            → obtenir jobUri (Location header)
5. GET  {jobUri}         → polling jusqu'à status=done (max timeout-seconds, intervalle 3s)
6. GET  {downloadUri}    → télécharger le PDF résultant

Méthode à ajouter :
  byte[] convertOfficeToPdf(byte[] officeContent, String filename, String mimeType,
                              WordToPdfProperties.AdobeWordProps config)
  - Réutilise le cache du token OAuth2 (méthode getAccessToken() existante)
  - Gère le retry sur 429 avec backoff exponentiel (max config.getMaxRetries())
  - Lance AdobeServiceException sur erreur 5xx ou timeout polling
  - Log : jobId, durée totale, taille résultante
  - Annotée @Slf4j (déjà présent sur la classe)

Ajoute dans AdobeJobResponse le champ String mimeType (optionnel, pour CreatePDF).
```

---

## PROMPT 5 — Orchestrateur WordToPdfRouter

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/wordtopdf/WordToPdfRouter.java`

```
Crée la classe WordToPdfRouter qui orchestre la conversion Office→PDF
selon le plan utilisateur et les feature flags.

Classe WordToPdfRouter :
- Injecte : WordToPdfProperties, AdobePdfServicesClient, GotenbergClient,
            LibreOfficeConfig, OfficeFileValidator, UserRepository, MeterRegistry
- Annotée @Component, @Slf4j

Méthode principale :
  byte[] route(byte[] officeBytes, String filename, Long userId)

Logique de routage EXACTE :

  1. Valider via OfficeFileValidator.validate(officeBytes, filename, props)

  2. Résoudre le plan (FREE si userId=null)

  3. Si kovixel.word-to-pdf.force-adobe=true
     → Tenter Adobe → si AdobeServiceException → Tenter Gotenberg → si GotenbergServiceException → LibreOffice
     → Logger chaque basculement en WARN avec le motif

  4. Si force-adobe=false
     a. Plan PRO ou ENTERPRISE :
        → Tenter Adobe → si échec → Tenter Gotenberg → si échec → LibreOffice
     b. Plan FREE ou ANONYMOUS :
        → Tenter Gotenberg → si GotenbergServiceException → LibreOffice

  5. LibreOffice local (fallback ultime) :
     → Utilise LibreOfficeConfig pour vérifier la disponibilité
     → Lance la conversion via ProcessBuilder (réutiliser le pattern de ConversionRouter)
     → Si non disponible → KovixelException SERVICE_UNAVAILABLE

Chaîne de fallback tryAdobeThenFallback(bytes, filename, mimeType, plan) :
  - Timer.Sample pour mesure de durée par moteur
  - Sur succès → recordSuccess(ENGINE_ADOBE, plan)
  - Sur AdobeServiceException → recordFallback("ADOBE", "GOTENBERG", e) puis tryGotenbergThenFallback

Chaîne de fallback tryGotenbergThenFallback(bytes, filename, plan) :
  - Sur succès → recordSuccess(ENGINE_GOTENBERG, plan)
  - Sur GotenbergServiceException → recordFallback("GOTENBERG", "LIBREOFFICE", e) puis runLibreOffice

Métriques Micrometer (même pattern que ConversionRouter PDF→DOCX) :
  kovixel.conversion.word_to_pdf.total       (engine, plan, status=SUCCESS|ERROR)
  kovixel.conversion.word_to_pdf.duration    (engine) — Timer
  kovixel.conversion.word_to_pdf.fallback_total (from, to, reason)
  kovixel.conversion.word_to_pdf.file_size   (format=DOCX|XLSX|PPTX|etc) — DistributionSummary

LibreOffice local — implémentation via ProcessBuilder :
  - Commande : soffice --headless --norestore --nofirststartwizard --nologo
                --convert-to pdf --outdir {outDir} {inputFile}
  - Pas de --infilter (inutile pour Office→PDF, contrairement à PDF→DOCX)
  - Profil unique par conversion (-env:UserInstallation=...) pour concurrence
  - Timeout : props.getLibreoffice().getTimeoutSeconds()
  - Nettoyer le répertoire temporaire dans le bloc finally
```

---

## PROMPT 6 — Endpoint REST & intégration ConversionService

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionController.java`

```
Intègre le WordToPdfRouter dans ConversionService et expose l'endpoint REST.

Dans ConversionService.java :

  Injecte WordToPdfRouter (constructeur).

  Remplace la méthode officeToPdf() existante par :

  @CheckQuota(feature = FeatureType.CONVERSION)
  public byte[] wordToPdf(byte[] content, String filename) {
      return timed(
          resolveExtension(filename).toUpperCase(), "PDF", content.length,
          () -> wordToPdfRouter.route(content, filename, resolveCurrentUserId())
      );
  }

  Conserve également officeToPdf(byte[] content, String extension) comme méthode
  dépréciée (@Deprecated) qui délègue à wordToPdf pour compatibilité ascendante.

  Ajoute une méthode privée resolveExtension(String filename) qui extrait
  l'extension du nom de fichier.

Dans ConversionController.java :

  Remplace / enrichis l'endpoint existant POST /api/convert/office-to-pdf par :

  @Operation(
    summary = "Convertit un fichier Office (Word/Excel/PowerPoint) en PDF",
    description = """
      Formats d'entrée supportés : DOCX, DOC, XLSX, XLS, PPTX, PPT, ODT, ODS, ODP, RTF.
      
      **Plans** :
      - FREE : conversion via Gotenberg (LibreOffice + polices MS) — excellent rendu
      - PRO/ENTERPRISE : conversion via Adobe PDF Services + fallback Gotenberg
      
      **Taille max** : 50 MB  
      **Timeout** : 120s (Adobe), 60s (Gotenberg), 90s (LibreOffice local)
      """
  )
  @PostMapping(value = "/api/convert/word-to-pdf", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
  @CheckQuota(feature = FeatureType.CONVERSION)
  ResponseEntity<byte[]> wordToPdf(
      @RequestPart("file") MultipartFile file,
      @AuthenticationPrincipal UserDetails userDetails
  )

  Implémentation de l'endpoint :
  - Lire les bytes du fichier
  - Appeler conversionService.wordToPdf(bytes, file.getOriginalFilename())
  - Headers de réponse :
      Content-Type: application/pdf
      Content-Disposition: attachment; filename="<nom_sans_extension>.pdf"
      X-Conversion-Engine: (récupéré si disponible via MDC ou header custom)
  - Si fichier > ASYNC_THRESHOLD_BYTES (10 MB) → déléguer en job async via AiJobService
    (même pattern que les autres conversions asynchrones du controller)
  - Gestion d'erreur unifiée : catch KovixelException → relancer, catch Exception → wrapper

  Garde AUSSI l'ancien endpoint /api/convert/office-to-pdf en @Deprecated
  qui redirige vers /api/convert/word-to-pdf (pour compatibilité frontend).
```

---

## PROMPT 7 — Health Indicator & métriques enrichies

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionEngineHealthIndicator.java`

```
Enrichis ConversionEngineHealthIndicator (déjà existant) pour inclure
le statut du moteur Word→PDF.

Dans la méthode health() existante, ajoute les détails suivants au composant "word-to-pdf" :

  Map<String, Object> wordToPdfDetails = Map.of(
      "gotenberg", gotenbergClient.isAvailable() ? "UP" : "DOWN",
      "gotenberg-libreoffice", gotenbergClient.isLibreOfficeAvailable() ? "UP" : "DOWN",
      "adobe", adobeWordToPdfEnabled ? "UP" : "DISABLED",
      "libreoffice-local", libreOfficeConfig.isAvailable() ? "UP" : "DOWN",
      "active-engine-free", resolveActiveEngineFree(),
      "active-engine-pro", resolveActiveEnginePro()
  );

  Méthodes privées à ajouter :
    String resolveActiveEngineFree() → "GOTENBERG" si up, sinon "LIBREOFFICE", sinon "UNAVAILABLE"
    String resolveActiveEnginePro()  → "ADOBE" si configuré, sinon resolveActiveEngineFree()

  Le composant global est DOWN si TOUS les moteurs sont DOWN/UNAVAILABLE.
  Sinon DEGRADED si fallback utilisé, UP si moteur primaire disponible.

Ajoute un endpoint info Actuator custom si pas déjà présent :

  @Component("wordToPdfInfoContributor")
  class WordToPdfInfoContributor implements InfoContributor {
    void contribute(Info.Builder builder) :
      builder.withDetail("word-to-pdf", Map.of(
          "supported-formats", List.of("docx","doc","odt","rtf","xlsx","xls","ods","pptx","ppt","odp"),
          "max-file-size-mb", props.getMaxFileSizeBytes() / 1_048_576,
          "engines", Map.of("free", "GOTENBERG+MS_FONTS", "pro", "ADOBE+GOTENBERG+LIBREOFFICE")
      ));
  }
```

---

## PROMPT 8 — Tests unitaires & d'intégration

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/wordtopdf/WordToPdfRouterTest.java`
- `src/test/java/com/kovixel/core/conversion/wordtopdf/OfficeFileValidatorTest.java`
- `src/test/java/com/kovixel/core/conversion/wordtopdf/WordToPdfGotenbergIntegrationTest.java`

```
Crée des tests complets pour le système de conversion Word→PDF.

WordToPdfRouterTest (tests unitaires avec Mockito) :

  @ExtendWith(MockitoExtension.class)
  Mocks : AdobePdfServicesClient, GotenbergClient, LibreOfficeConfig,
          OfficeFileValidator, UserRepository, MeterRegistry

  Tests à écrire :
  - test_forceAdobe_routesViaAdobe_forFreeUser()
    → force-adobe=true, userId=null → appel adobeClient.convertOfficeToPdf
  - test_proUser_routesViaAdobe()
    → plan PRO, force-adobe=false → appel adobeClient.convertOfficeToPdf
  - test_freeUser_routesViaGotenberg()
    → plan FREE, force-adobe=false → appel gotenbergClient.convertOfficeToPdf
  - test_adobeFailure_fallbackToGotenberg_forProUser()
    → Adobe lève AdobeServiceException → fallback Gotenberg appelé
  - test_gotenbergFailure_fallbackToLibreOffice()
    → Gotenberg lève GotenbergServiceException → LibreOffice appelé
  - test_allEnginesFailed_throwsServiceUnavailable()
    → Adobe + Gotenberg échouent + LibreOffice non disponible → KovixelException SERVICE_UNAVAILABLE
  - test_fallbackMetric_incrementedOnAdobeFailure()
    → vérifier que kovixel.conversion.word_to_pdf.fallback_total est incrémenté
  - test_validatorCalledBeforeRouting()
    → OfficeFileValidator.validate() est toujours appelé en premier
  - test_unsupportedExtension_throwsBadRequest()
    → fichier .exe → KovixelException BAD_REQUEST

OfficeFileValidatorTest (tests unitaires purs) :

  Tests :
  - test_validDocx_passes()
  - test_validXlsx_passes()
  - test_emptyContent_throws()
  - test_tooLargeFile_throws()
  - test_unsupportedExtension_throws()
  - test_magicBytesZip_docxDetectedCorrectly()
  - test_magicBytesOLE2_docDetectedCorrectly()
  - test_magicBytesRtf_detectedCorrectly()
  - test_noExtension_throws()

WordToPdfGotenbergIntegrationTest (WireMock) :

  @WireMockTest
  Tests :
  - test_convertDocxToPdf_success()
    → Mock POST /forms/libreoffice/convert/ → HTTP 200 + body PDF simulé (>500 bytes)
    → Vérifie que le filename dans le multipart est bien "document.docx"
    → Vérifie que le Content-Type retourné est application/pdf
  - test_convertXlsxToPdf_success()
    → Mock retourne un PDF valide pour un .xlsx
  - test_gotenbergTimeout_throwsGotenbergServiceException()
    → Mock délai > timeout configuré → GotenbergServiceException
  - test_tooSmallResponse_throwsGotenbergServiceException()
    → Mock body < 500 bytes → GotenbergServiceException
  - test_isLibreOfficeAvailable_true()
    → Mock GET /health → HTTP 200 → retourne true
  - test_isLibreOfficeAvailable_false_on503()
    → Mock GET /health → HTTP 503 → retourne false

Ajoute dans pom.xml si absent (scope test) :
  - com.github.tomakehurst:wiremock-standalone (version compatible Java 21)
  - org.mockito:mockito-core (normalement déjà présent)
```

---

## PROMPT 9 — Documentation, variables d'environnement & API Swagger

**Fichiers à modifier / créer :**
- `README.md` (section "Configuration Conversion Word→PDF")
- `.env.example`
- `docker-compose.yml` (aucun changement requis — Gotenberg déjà configuré)

```
Documente la configuration complète du système de conversion Word→PDF.

Dans README.md, ajoute une section "## Configuration Conversion Word→PDF" avec :

  ### Formats supportés

  | Format      | Extension(s)        | Moteur recommandé  |
  |-------------|---------------------|--------------------|
  | Word        | .docx, .doc, .odt   | Gotenberg / Adobe  |
  | Excel       | .xlsx, .xls, .ods   | Gotenberg / Adobe  |
  | PowerPoint  | .pptx, .ppt, .odp   | Gotenberg / Adobe  |
  | Texte riche | .rtf                | Gotenberg / Adobe  |

  ### Variables d'environnement

  | Variable              | Description                          | Obligatoire     |
  |-----------------------|--------------------------------------|-----------------|
  | ADOBE_CLIENT_ID       | Client ID Adobe PDF Services         | PRO users only  |
  | ADOBE_CLIENT_SECRET   | Client Secret Adobe PDF Services     | PRO users only  |
  | GOTENBERG_URL         | URL du service Gotenberg             | Oui             |

  ### Feature flags (application.yml)

  | Propriété                                  | Défaut  | Description                               |
  |--------------------------------------------|---------|-------------------------------------------|
  | kovixel.word-to-pdf.force-adobe             | false   | Force Adobe pour TOUS les utilisateurs    |
  | kovixel.word-to-pdf.allowed-extensions      | [liste] | Extensions de fichier autorisées          |
  | kovixel.word-to-pdf.max-file-size-bytes     | 52428800| Taille max du fichier source (50 MB)      |
  | kovixel.word-to-pdf.gotenberg.landscape     | false   | Mode paysage pour la conversion           |
  | kovixel.word-to-pdf.gotenberg.page-ranges   | ""      | Plages de pages (ex: "1-3,5") — vide=all |

  ### Qualité de conversion par moteur

  | Moteur              | Score  | Forces                                          | Limites                      |
  |---------------------|--------|-------------------------------------------------|------------------------------|
  | Adobe PDF Services  | 9.5/10 | Fidélité parfaite, polices embarquées, métadata | Coût API, quota mensuel      |
  | Gotenberg + MS Fonts| 9.0/10 | Gratuit, rapide, polices MS, fiable             | Dépendance Docker            |
  | LibreOffice local   | 7.5/10 | Toujours disponible, gratuit                    | Rendu parfois approximatif   |

  > **Note** : Contrairement à PDF→Word (sens inverse complexe), Word→PDF est une
  > opération native pour LibreOffice. Le score de Gotenberg est donc 9/10 (meilleur
  > que pour PDF→Word). Les utilisateurs FREE bénéficient d'une excellente qualité.

Dans .env.example, ajoute si absent :
  # Word to PDF — Adobe PDF Services (requis pour les utilisateurs PRO)
  ADOBE_CLIENT_ID=your_adobe_client_id_here
  ADOBE_CLIENT_SECRET=your_adobe_client_secret_here

  # Gotenberg (commun à toutes les conversions)
  GOTENBERG_URL=http://gotenberg:3000
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9
  Config    Validator  Gotenberg   Adobe      Router     Service/API  Health     Tests       Docs
```

> **Parallélisations possibles :**
> - PROMPT 3 (Gotenberg) et PROMPT 4 (Adobe) sont indépendants → peuvent s'exécuter en parallèle
> - PROMPT 7 (Health) et PROMPT 8 (Tests) sont indépendants du même niveau → parallélisables
> - PROMPT 9 (Docs) peut s'écrire à tout moment après PROMPT 1

---

## Différences clés avec PDF→Word (ConversionRouter existant)

| Aspect                   | PDF→Word (existant)              | Word→PDF (cette roadmap)              |
|--------------------------|----------------------------------|---------------------------------------|
| Moteur FREE primaire     | Gotenberg (conversion difficile) | Gotenberg (conversion native/excellente)|
| Moteur PRO primaire      | Adobe PDF Services               | Adobe PDF Services                    |
| Classe Router            | `ConversionRouter`               | `WordToPdfRouter` (nouveau)           |
| Validation fichier       | Non (PDF toujours valide)        | `OfficeFileValidator` (magic bytes)   |
| Formats d'entrée         | PDF uniquement                   | 10 formats Office                     |
| Métrique principale      | `kovixel.conversion.pdf_to_word.` | `kovixel.conversion.word_to_pdf.`      |
| Réutilisation            | —                                | Réutilise GotenbergClient, AdobeClient|
| `--infilter`             | `writer_pdf_import` (essentiel)  | Non requis (conversion native)        |

---

## Critères de validation finale

- [ ] `mvn test` passe sans erreur (tous les tests unitaires et d'intégration)
- [ ] `docker-compose up` démarre sans erreur
- [ ] Conversion DOCX→PDF fonctionne pour un utilisateur FREE (Gotenberg)
- [ ] Conversion DOCX→PDF fonctionne pour un utilisateur PRO (Adobe)
- [ ] Conversion XLSX→PDF et PPTX→PDF fonctionnent (test manuel)
- [ ] Fichier `.exe` uploadé → HTTP 400 Bad Request
- [ ] Fichier > 50 MB → HTTP 413 Payload Too Large
- [ ] Basculement automatique Adobe→Gotenberg lors d'un `docker stop gotenberg` (test manuel)
- [ ] `curl /actuator/health` expose `{ word-to-pdf: { gotenberg: "UP", adobe: "UP|DISABLED" } }`
- [ ] `curl /actuator/metrics/kovixel.conversion.word_to_pdf.total` retourne des valeurs
- [ ] Flag `force-adobe=true` fait passer un utilisateur FREE par Adobe
- [ ] L'ancien endpoint `/api/convert/office-to-pdf` redirige correctement (compatibilité)
- [ ] Swagger UI affiche le nouvel endpoint avec les formats supportés documentés
```

