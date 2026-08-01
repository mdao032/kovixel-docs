# 📋 PDF → Word : Roadmap d'implémentation Pro/Ultra-Pro

> **Instructions** : Exécuter les prompts ci-dessous **dans l'ordre**.  
> Chaque prompt est autonome et cite les fichiers à modifier.  
> Aucune étape ne doit être sautée — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Requête de conversion
        │
        ▼
  ┌─────────────────────────────────────────────────┐
  │  kovixel.conversion.force-adobe=true/false        │
  │  (bascule globale dans application.properties)   │
  └─────────────────────────────────────────────────┘
        │
        ├─ force-adobe=true ──► Adobe PDF Services (TOUS les utilisateurs)
        │
        └─ force-adobe=false
               │
               ▼
         Utilisateur PRO/ENTERPRISE ?
              ├─ OUI ──► Adobe PDF Services API  (9.5/10)
              │          │ Si Adobe down/erreur ──────────────────┐
              │                                                   │
              └─ NON ──► Gotenberg + polices MS  (8.5/10) ◄──────┘
                         │ Si Gotenberg down/erreur
                         │
                         └──► LibreOffice local  (6/10 · fallback ultime)
```

---

## PROMPT 1 — Configuration & Feature Flag

**Fichiers à modifier :**
- `src/main/resources/application.yml`
- `src/main/resources/application-dev.yml`
- Créer `src/main/java/com/kovixel/core/conversion/ConversionProperties.java`

```
Dans application.yml, ajoute une section dédiée à la conversion PDF→Word :

kovixel:
  conversion:
    # ── Bascule globale Adobe PDF Services ───────────────────────────────────
    # true  → tous les utilisateurs (visiteurs, free, pro) passent par Adobe
    # false → routing par plan (défaut) : PRO=Adobe, FREE=Gotenberg, fallback=LibreOffice
    force-adobe: false

    # ── Adobe PDF Services ────────────────────────────────────────────────────
    adobe:
      enabled: true
      client-id: ${ADOBE_CLIENT_ID:}
      client-secret: ${ADOBE_CLIENT_SECRET:}
      # Timeout en secondes pour les appels Adobe (upload + poll + download)
      timeout-seconds: 180
      # Nombre max de tentatives en cas d'erreur temporaire Adobe
      max-retries: 2

    # ── Gotenberg ─────────────────────────────────────────────────────────────
    gotenberg:
      enabled: true
      base-url: ${GOTENBERG_URL:http://gotenberg:3000}
      timeout-seconds: 90
      # Active l'injection des polices Microsoft dans le conteneur Gotenberg
      ms-fonts-enabled: true

    # ── LibreOffice local (fallback ultime) ───────────────────────────────────
    libreoffice:
      timeout-seconds: 120

Dans application-dev.yml, surcharge pour le développement local :

kovixel:
  conversion:
    force-adobe: false
    adobe:
      enabled: false          # Désactivé en dev par défaut (pas de crédentials)
    gotenberg:
      base-url: http://localhost:3000

Crée la classe ConversionProperties.java annotée @ConfigurationProperties(prefix = "kovixel.conversion")
avec les champs correspondants (records Java ou classe avec @Getter Lombok).
Enregistre-la dans la configuration Spring Boot (@EnableConfigurationProperties).
```

---

## PROMPT 2 — Polices Microsoft dans Gotenberg

**Fichiers à modifier / créer :**
- `docker-compose.yml`
- Créer `docker/gotenberg/Dockerfile.gotenberg`
- Créer `docker/gotenberg/fonts/README.md`

```
Crée un Dockerfile personnalisé pour Gotenberg qui installe les polices Microsoft
(nécessaires pour la fidélité des documents Office en PDF→DOCX).

Fichier : docker/gotenberg/Dockerfile.gotenberg

  FROM gotenberg/gotenberg:8

  USER root

  # Installe les polices Microsoft TrueType (Arial, Times New Roman, Verdana, etc.)
  # et les polices de substitution pour les polices propriétaires non disponibles
  RUN apt-get update && apt-get install -y --no-install-recommends \
      ttf-mscorefonts-installer \
      fonts-liberation \
      fonts-open-sans \
      fontconfig \
      && fc-cache -f -v \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*

  USER gotenberg

Dans docker-compose.yml, remplace le service gotenberg existant par :

  gotenberg:
    build:
      context: ./docker/gotenberg
      dockerfile: Dockerfile.gotenberg
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      GOTENBERG_CHROMIUM_DISABLE_ROUTES: "true"
      GOTENBERG_LIBREOFFICE_DISABLE_ROUTES: "false"
      GOTENBERG_LOG_LEVEL: "warn"
    networks:
      - kovixel-network

Ajoute un healthcheck sur le service gotenberg :
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 60s
```

---

## PROMPT 3 — Client Adobe PDF Services

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/adobe/AdobePdfServicesClient.java`
- `src/main/java/com/kovixel/core/conversion/adobe/AdobeTokenResponse.java`
- `src/main/java/com/kovixel/core/conversion/adobe/AdobeJobResponse.java`

```
Crée un client HTTP Adobe PDF Services qui implémente la conversion PDF→DOCX
en utilisant l'API REST Adobe PDF Services v3 (https://developer.adobe.com/document-services/docs/).

Flux de conversion Adobe PDF Services :
1. POST /token         → obtenir un access_token JWT (OAuth2 client_credentials)
2. POST /assets        → uploader le fichier PDF → obtenir un assetID + uploadUri
3. PUT  {uploadUri}    → uploader les bytes du PDF vers l'URI pré-signée S3
4. POST /operation/exportpdf → créer le job de conversion (assetID, targetFormat=docx)
                            → obtenir un jobUri (Location header)
5. GET  {jobUri}       → polling jusqu'à status=done (max 180s, intervalle 3s)
6. GET  {downloadUri}  → télécharger le DOCX résultant

Classe AdobePdfServicesClient :
- Injecte ConversionProperties pour lire client-id, client-secret, timeout
- Utilise WebClient (Spring WebFlux) pour les appels HTTP
- Implémente un cache du token (validité 24h, refresh automatique 5min avant expiry)
- Méthode principale : byte[] convertPdfToDocx(byte[] pdfBytes)
- En cas d'erreur HTTP 429 (rate limit) → retry avec backoff exponentiel (max 2 fois)
- En cas d'erreur HTTP 5xx → lance AdobeServiceException (exception custom)
- Log le jobId, la durée totale et la taille du fichier résultant
- Annotée @Component, @Slf4j

Crée AdobeTokenResponse record avec : accessToken, tokenType, expiresIn
Crée AdobeJobResponse record avec : status, downloadUri, error

Ajoute la dépendance spring-boot-starter-webflux dans pom.xml si elle n'est pas déjà présente.
```

---

## PROMPT 4 — Client Gotenberg amélioré

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/gotenberg/GotenbergClient.java`

```
Crée un client dédié Gotenberg pour la conversion PDF→DOCX.

Classe GotenbergClient :
- Injecte ConversionProperties pour lire base-url, timeout
- Utilise WebClient Spring WebFlux
- Méthode : byte[] convertPdfToDocx(byte[] pdfBytes)
  * Appelle POST {base-url}/forms/libreoffice/convert/
  * Content-Type: multipart/form-data
  * Part "files": le PDF avec filename="document.pdf"
  * Timeout configurable (default: 90s)
  * Si réponse vide ou taille < 100 bytes → lance GotenbergServiceException
  * Si timeout ou erreur réseau → lance GotenbergServiceException
- Méthode isAvailable() : boolean
  * GET {base-url}/health → true si HTTP 200, false sinon (timeout 3s)
  * Résultat mis en cache 30s (Caffeine ou simple volatile + timestamp)
- Annotée @Component, @Slf4j

Crée GotenbergServiceException extends RuntimeException.
```

---

## PROMPT 5 — Orchestrateur ConversionRouter

**Fichiers à créer :**
- `src/main/java/com/kovixel/core/conversion/ConversionRouter.java`

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionService.java`

```
Crée la classe ConversionRouter qui contient toute la logique de routage
PDF→DOCX selon le plan et les feature flags.

Classe ConversionRouter :
- Injecte : ConversionProperties, AdobePdfServicesClient, GotenbergClient,
            LibreOfficeConfig, UserRepository, AuthService (ou SecurityContext)
- Méthode principale : byte[] route(byte[] pdfBytes, Long userId)

Logique de routage EXACTE :

  1. Si kovixel.conversion.force-adobe=true
     → Tenter Adobe → si échec → Tenter Gotenberg → si échec → LibreOffice local
     → Logger chaque basculement avec le motif (WARN level)

  2. Si force-adobe=false
     a. Récupérer le plan de l'utilisateur (FREE si userId=null)
     b. Si plan = PRO ou ENTERPRISE :
        → Tenter Adobe → si AdobeServiceException → Tenter Gotenberg → si échec → LibreOffice
     c. Si plan = FREE ou ANONYMOUS :
        → Tenter Gotenberg → si GotenbergServiceException → LibreOffice

  3. LibreOffice local (fallback ultime, toujours disponible si installé) :
     → Utiliser la méthode existante dans ConversionService
     → Si LibreOffice non disponible → lancer KovixelException SERVICE_UNAVAILABLE

Chaque niveau de fallback doit :
  - Enregistrer une métrique Micrometer : kovixel.conversion.fallback
    avec tags : from=ADOBE|GOTENBERG, to=GOTENBERG|LIBREOFFICE, reason=<exception.class.simpleName>
  - Logger en WARN : "Basculement {from}→{to} : {reason}"

Dans ConversionService.pdfToWord(byte[] pdf) :
  - Remplacer le corps de la méthode par un simple appel au router :
    return conversionRouter.route(pdf, resolveCurrentUserId());
  - Conserver l'annotation @CheckQuota
```

---

## PROMPT 6 — Métriques & Observabilité

**Fichiers à modifier :**
- `src/main/java/com/kovixel/core/conversion/ConversionService.java`
- `src/main/java/com/kovixel/core/conversion/ConversionRouter.java`

```
Enrichis les métriques Micrometer pour la conversion PDF→Word.

Métriques à ajouter / compléter :

  kovixel.conversion.pdf_to_word.total
    Tags : engine=ADOBE|GOTENBERG|LIBREOFFICE, plan=FREE|PRO|ENTERPRISE, status=SUCCESS|ERROR
    Incrémenter dans ConversionRouter après chaque tentative (réussie ou non).

  kovixel.conversion.pdf_to_word.duration
    Type : Timer
    Tags : engine=ADOBE|GOTENBERG|LIBREOFFICE
    Enregistrer la durée de chaque tentative, pas seulement la réussie.

  kovixel.conversion.pdf_to_word.fallback_total
    Tags : from, to, reason
    Incrémenter à chaque basculement (déjà défini au PROMPT 5, ici on formalise le nom).

  kovixel.conversion.pdf_to_word.adobe_quota_remaining
    Type : Gauge (si l'API Adobe expose le quota restant dans les headers)
    Lire le header X-RateLimit-Remaining si présent dans la réponse Adobe.

Ajoute un endpoint Actuator custom (ou enrichis /actuator/metrics) pour exposer :
  - Le moteur actuellement utilisé par plan (info endpoint)
  - Le statut de disponibilité de chaque moteur (health indicator)

Crée ConversionEngineHealthIndicator implements HealthIndicator :
  - Vérifie Gotenberg via GotenbergClient.isAvailable()
  - Vérifie Adobe via un appel GET /token (ou un endpoint ping Adobe)
  - Expose : { gotenberg: UP/DOWN, adobe: UP/DOWN/DISABLED }
  - Enregistrée comme bean Spring @Component
```

---

## PROMPT 7 — Tests d'intégration

**Fichiers à créer :**
- `src/test/java/com/kovixel/core/conversion/ConversionRouterTest.java`
- `src/test/java/com/kovixel/core/conversion/AdobePdfServicesClientTest.java`
- `src/test/java/com/kovixel/core/conversion/GotenbergClientTest.java`

```
Crée des tests unitaires et d'intégration pour le système de routage.

ConversionRouterTest (tests unitaires avec Mockito) :
  - Teste que force-adobe=true route vers Adobe pour un utilisateur FREE
  - Teste que force-adobe=false + plan PRO route vers Adobe
  - Teste que force-adobe=false + plan FREE route vers Gotenberg
  - Teste le fallback Adobe→Gotenberg quand AdobeServiceException est levée
  - Teste le fallback Gotenberg→LibreOffice quand GotenbergServiceException est levée
  - Teste que la métrique kovixel.conversion.pdf_to_word.fallback_total est incrémentée
  Utilise @ExtendWith(MockitoExtension.class), mock tous les clients externes.

GotenbergClientTest (tests avec WireMock) :
  - Teste la conversion réussie (mock HTTP 200 avec body DOCX simulé)
  - Teste le timeout (mock délai > timeout configuré)
  - Teste le fallback sur réponse vide (body < 100 bytes)
  - Teste isAvailable() : true sur /health 200, false sur /health 503
  Utilise WireMock (@WireMockTest ou WireMockServer).

AdobePdfServicesClientTest (tests avec WireMock) :
  - Teste le flux complet : token → upload → job → poll → download
  - Teste le retry sur erreur 429 (rate limit)
  - Teste le cache du token (second appel ne doit pas re-appeler /token)
  - Teste l'expiration du token (refresh automatique)
  Utilise WireMock pour simuler l'API Adobe.

Ajoute dans pom.xml (scope test) :
  - wiremock-spring-boot ou com.github.tomakehurst:wiremock-jre8
  - org.mockito:mockito-core (déjà présent normalement)
```

---

## PROMPT 8 — Documentation & Variables d'environnement

**Fichiers à modifier / créer :**
- `README.md` (section "Configuration Conversion PDF→Word")
- `.env.example`
- `docker-compose.yml` (variables d'environnement Adobe)

```
Documente la configuration complète du système de conversion PDF→Word.

Dans README.md, ajoute une section "## Configuration Conversion PDF→Word" avec :

  ### Variables d'environnement requises

  | Variable              | Description                          | Obligatoire     |
  |-----------------------|--------------------------------------|-----------------|
  | ADOBE_CLIENT_ID       | Client ID Adobe PDF Services         | PRO users only  |
  | ADOBE_CLIENT_SECRET   | Client Secret Adobe PDF Services     | PRO users only  |
  | GOTENBERG_URL         | URL du service Gotenberg             | Oui             |

  ### Feature flags (application.properties)

  | Propriété                               | Défaut  | Description                              |
  |-----------------------------------------|---------|------------------------------------------|
  | kovixel.conversion.force-adobe           | false   | Force Adobe pour TOUS les utilisateurs   |
  | kovixel.conversion.adobe.enabled         | true    | Active/désactive le moteur Adobe         |
  | kovixel.conversion.gotenberg.enabled     | true    | Active/désactive le moteur Gotenberg     |
  | kovixel.conversion.gotenberg.ms-fonts-enabled | true | Active les polices MS dans Gotenberg |

  ### Qualité de conversion par moteur

  | Moteur         | Score | Forces                                     | Limites                    |
  |----------------|-------|--------------------------------------------|----------------------------|
  | Adobe Services | 9.5/10| Polices, images, tableaux, codes-barres    | Coût API, quota mensuel    |
  | Gotenberg+MS   | 8.5/10| Gratuit, rapide, polices MS disponibles    | Dépendance Docker          |
  | LibreOffice    | 6/10  | Toujours disponible, gratuit               | Rendu parfois approximatif |

Dans .env.example :
  ADOBE_CLIENT_ID=your_adobe_client_id_here
  ADOBE_CLIENT_SECRET=your_adobe_client_secret_here
  GOTENBERG_URL=http://gotenberg:3000

Dans docker-compose.yml, passe les variables Adobe au service kovixel-api :
  environment:
    ADOBE_CLIENT_ID: ${ADOBE_CLIENT_ID:-}
    ADOBE_CLIENT_SECRET: ${ADOBE_CLIENT_SECRET:-}
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 4 → PROMPT 5 → PROMPT 3 → PROMPT 6 → PROMPT 7 → PROMPT 8
   Config      Docker      Gotenberg    Router      Adobe       Métriques   Tests       Docs
```

> **Note** : PROMPT 3 (Adobe) peut être exécuté en parallèle de PROMPT 4 (Gotenberg)  
> car les deux clients sont indépendants. Le router (PROMPT 5) nécessite les deux.

---

## Critères de validation finale

- [ ] `mvn test` passe sans erreur
- [ ] `docker-compose up` démarre sans erreur
- [ ] Conversion PDF→DOCX fonctionne avec un utilisateur FREE (Gotenberg)
- [ ] Conversion PDF→DOCX fonctionne avec un utilisateur PRO (Adobe)
- [ ] Basculement automatique Adobe→Gotenberg lors d'un `docker stop gotenberg` (test manuel)
- [ ] `curl /actuator/health` expose `{ gotenberg: "UP", adobe: "UP" }`
- [ ] `curl /actuator/metrics/kovixel.conversion.pdf_to_word.total` retourne des valeurs
- [ ] Flag `force-adobe=true` fait passer un utilisateur FREE par Adobe

