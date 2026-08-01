# ANTIBOT_ROADMAP — Protection anti-bot Kovixel

> Étude approfondie + plan d'implémentation — 2026-07-19
> Objectif : une protection de qualité équivalente aux leaders du marché (Cloudflare Bot
> Management, DataDome, Kasada), adaptée au modèle produit Kovixel : **outils accessibles
> sans compte** (argument commercial central), backends coûteux (Claude, Adobe, Gotenberg,
> Ollama/GPU, Tesseract), plans payants FREE → PRO → PRO+ → TEAM → ENTERPRISE.

---

## 0. Philosophie et principe directeur

**Approche invisible par défaut** — le CAPTCHA systématique est un échec produit :

```
Requête → Collecte de signaux → Score de risque (0–100) → Décision
                                                            ├─ 0–29   ALLOW      (rien, invisible)
                                                            ├─ 30–59  MONITOR    (laisse passer, trace, resserre les quotas)
                                                            ├─ 60–84  CHALLENGE  (Turnstile invisible → interactif si échec)
                                                            └─ 85–100 BLOCK      (403/429, blocage progressif)
```

Trois invariants non négociables :

1. **Un humain légitime ne voit jamais rien** tant que son score reste bas.
2. **Aucune couche n'est un point de défaillance unique** : si Redis, le scoring ou le
   fournisseur de challenge tombe, on dégrade en mode « quotas seuls » (fail-open contrôlé),
   jamais en blocage de tout le trafic.
3. **Chaque décision est explicable et auditable** : un score porte la liste des signaux qui
   l'ont produit ; on peut rejouer/comprendre tout blocage a posteriori.

---

## 1. État des lieux — ce qui existe déjà

| Brique | État | Fichier(s) |
|---|---|---|
| Rate limit login/register (IP, Redis) | ✅ | `AuthRateLimitFilter` (5/min, 3/min) |
| Rate limit invitations publiques (IP) | ✅ | `InvitationRateLimitFilter` (20/5 par min) |
| Rate limit checkout (par compte) | ✅ | `CheckoutRateLimitFilter` (5/min) |
| Quotas anonymes par IP + **plafonds globaux journaliers** | ✅ | `AnonymousQuotaFilter`, `ANON_GLOBAL_LIMIT_*` |
| Résolution IP fail-closed derrière proxy de confiance | ✅ | `ClientIpResolver`, `KOVIXEL_TRUSTED_PROXIES` |
| Session invité opaque signée HMAC-SHA256 | ✅ | `GuestSessionService` (cookie `HttpOnly/Secure/Strict`) |
| Auth JWT + refresh rotation + 2FA + blacklist | ✅ | sous-système auth complet |
| CORS strict, cookies durcis, headers | ✅ | `SecurityConfig`, nginx |
| WAF | ❌ | — |
| Réputation IP (VPN/proxy/datacenter) | ❌ | — |
| Fingerprinting navigateur | ❌ | — |
| Défi JavaScript / proof-of-work | ❌ | — |
| Détection comportementale | ❌ | — |
| Challenge adaptatif (CAPTCHA conditionnel) | ❌ | — |
| Moteur de score centralisé | ❌ | signaux dispersés, pas de corrélation |
| Monitoring anti-abus / blocage progressif | ❌ | logs `warn` épars, pas d'agrégation |

**Diagnostic** : les fondations volumétriques (rate limit, quotas) sont bonnes mais
**réactives et unidimensionnelles** (IP seule). Un attaquant avec un pool d'IPs résidentielles
passe intégralement sous le radar. Il manque la couche d'**intelligence** : corréler les
signaux, distinguer un humain d'un script, et n'escalader la friction que sur le risque.

---

## 2. Architecture cible

### 2.1 Défense en profondeur — 5 couches

```
┌──────────────────────────────────────────────────────────────────────┐
│ COUCHE 0 — Edge (Cloudflare)                                         │
│  WAF managé, DDoS L3/L4/L7, TLS fingerprint (JA4), bot score edge,   │
│  rate limit edge grossier, Turnstile (même écosystème)               │
├──────────────────────────────────────────────────────────────────────┤
│ COUCHE 1 — nginx (origin)                                            │
│  Coupe-circuit local : limit_req zones, refus si header Cloudflare   │
│  absent (origin lockdown), masquage chemins sensibles                │
├──────────────────────────────────────────────────────────────────────┤
│ COUCHE 2 — Filtres Spring (existant, à raccorder)                    │
│  AuthRateLimit, InvitationRateLimit, AnonymousQuota, Checkout        │
├──────────────────────────────────────────────────────────────────────┤
│ COUCHE 3 — RiskEngine (nouveau, cœur du système)                     │
│  Agrège TOUS les signaux → score → décision ALLOW/MONITOR/           │
│  CHALLENGE/BLOCK. Filtre unique sur les endpoints protégés.          │
├──────────────────────────────────────────────────────────────────────┤
│ COUCHE 4 — Observabilité & riposte                                   │
│  Métriques Prometheus, détection de pics, blocage progressif,        │
│  console PLATFORM_ADMIN (allowlist/blocklist, kill-switch, replay)   │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Le RiskEngine — cœur du système

Nouveau module `com.kovixel.antibot` :

```
antibot/
├── RiskEngine.java              // agrégation des signaux → RiskAssessment
├── RiskAssessment.java          // score 0–100 + décision + signaux contributifs
├── RiskDecision.java            // enum ALLOW / MONITOR / CHALLENGE / BLOCK
├── RiskContext.java             // requête normalisée (ip, userId, fingerprint, path…)
├── signal/
│   ├── RiskSignal.java          // interface : evaluate(RiskContext) → SignalScore
│   ├── IpReputationSignal.java
│   ├── VelocitySignal.java      // vitesse multi-fenêtre (min/h/jour) multi-clé
│   ├── FingerprintSignal.java
│   ├── BehavioralSignal.java
│   ├── JsChallengeSignal.java   // PoW token présent/valide ?
│   ├── AccountSignal.java       // âge du compte, email jetable, plan, historique
│   └── ConsistencySignal.java   // cohérence headers/TLS/UA/fingerprint
├── challenge/
│   ├── TurnstileService.java    // vérif token siteverify + cache anti-rejeu
│   └── PowChallengeService.java // proof-of-work maison (fallback + friction graduée)
├── filter/
│   └── RiskEvaluationFilter.java // s'insère après JwtAuthFilter
├── admin/                        // console PLATFORM_ADMIN
└── config/AntibotProperties.java // seuils, poids, kill-switch — tout en config à chaud
```

Principes de conception :

- **Chaque signal est indépendant, pondéré, court-circuitable** (kill-switch par signal via
  config). Un signal en erreur rend `0` (neutre), jamais une exception bloquante.
- **Budget latence : ≤ 5 ms P99** pour l'évaluation complète sur le chemin de requête.
  Tout ce qui est lent (réputation IP externe, analyse comportementale) est pré-calculé
  asynchrone et lu en cache Redis au moment de la décision.
- **Le score est propagé** dans le MDC + `PlatformAdminAuditLog` pour tout ce qui dépasse
  MONITOR → chaque blocage est rejouable et explicable.
- **Seuils et poids en configuration**, modifiables sans redéploiement (console admin) —
  le tuning est permanent, jamais figé dans le code.

---

## 3. Les composants en détail

### 3.1 WAF — Cloudflare en frontal (build vs buy tranché : buy)

Écrire un WAF maison est le seul point où l'égalité avec les géants est irréaliste en
solo — eux voient le trafic de millions de sites. On achète la couche edge, on construit
l'intelligence applicative (qui, elle, exige la connaissance métier que Cloudflare n'a pas).

- **Cloudflare (plan Free puis Pro ~25 $/mois)** devant `app.kovixel.com` :
  - WAF managé (OWASP Core Ruleset + règles Cloudflare), protection DDoS incluse.
  - **Bot Fight Mode** (Free) / **Super Bot Fight Mode** (Pro) : premier tri des bots
    connus au edge, gratuit en signal.
  - Headers transmis à l'origin : `CF-Connecting-IP` (→ intégrer à `ClientIpResolver`),
    `cf-bot-score` si plan supérieur plus tard.
  - Rate limit edge grossier (ex. 100 req/10 s/IP sur `/api/`) : coupe les floods avant
    même l'origin.
- **Origin lockdown** : nginx ne répond qu'au trafic Cloudflare (allowlist IP Cloudflare +
  header secret `X-Origin-Auth` posé par un Transform Rule). Sans ça, un attaquant qui
  découvre l'IP origin contourne toute la couche 0.
- Alternative souveraineté (si dépendance Cloudflare refusée) : **Coraza** (WAF OSS,
  successeur ModSecurity) en module nginx + Anubis/PoW. Coût d'exploitation nettement
  supérieur, à ne choisir qu'en connaissance de cause.

### 3.2 Rate limiting multi-dimensionnel (évolution de l'existant)

L'existant limite par IP **ou** par compte, jamais en croisé. Cible :

- **Clés multiples simultanées** : IP, compte, session invité, fingerprint, sous-réseau
  (/24 IPv4, /56 IPv6 — contre la rotation d'IP dans un même bloc), ASN.
- **Fenêtres multiples par clé** : minute (burst), heure (soutenu), jour (volume) —
  aligné sur la demande produit « quotas de conversions par minute, heure et jour ».
- **Implémentation** : sliding window sur Redis en script **Lua atomique** (l'increment
  + expire actuel a une course bénigne ; en Lua elle disparaît et on ajoute le sliding
  window précis multi-fenêtre à coût constant).
- **Quotas adaptatifs pilotés par le score** : un client en MONITOR voit ses quotas
  divisés (×0.5), un client vérifié par challenge récent les voit relevés. Le rate
  limiting devient un **actionneur** du RiskEngine, pas seulement un garde-fou statique.
- Les 3 filtres existants restent (défense en profondeur) mais publient leurs événements
  au RiskEngine (un 429 auth récent = signal de risque pour les autres endpoints).

### 3.3 Réputation IP

- **Base locale, pas d'appel externe sur le chemin de requête** :
  - **MaxMind GeoLite2-ASN + GeoIP2** (gratuit) : ASN → détection datacenter (AWS, GCP,
    OVH, Hetzner… ≈ 95 % des bots simples), pays.
  - Listes OSS rafraîchies par job quotidien : FireHOL, Spamhaus DROP, listes Tor exit
    nodes, plages VPN commerciales connues.
  - Option payante ciblée (phase 2) : IPQualityScore / ipinfo **en lookup asynchrone**
    uniquement pour les IPs déjà suspectes (coût maîtrisé).
- **Cache Redis** `iprep:{ip}` (TTL 24 h) : `{asnType: RESIDENTIAL|DATACENTER|VPN|TOR|MOBILE, score}`.
- **Politique produit** (décision à valider) : un VPN ne doit **pas** être bloqué seul —
  beaucoup d'utilisateurs légitimes (et la cible pro !) sont derrière VPN d'entreprise.
  Datacenter + anonyme + volume = risque fort ; VPN + compte payant ancien = neutre.
  C'est exactement ce que le scoring pondéré permet et qu'une règle binaire raterait.

### 3.4 Fingerprinting navigateur

Deux niveaux complémentaires :

**a) Réseau/protocole (côté serveur, infalsifiable par JS)** :
- **JA4/JA4H** (TLS + HTTP fingerprint) exposé par Cloudflare, sinon calculable sur nginx.
  Détecte `curl`, `python-requests`, Go http, les TLS stacks d'automatisation — même avec
  un User-Agent parfaitement maquillé.
- **Cohérence headers** : ordre des headers, `Accept-Language` absent, UA Chrome sans
  `sec-ch-ua`, HTTP/1.1 là où un vrai Chrome parle HTTP/2 → signaux forts et gratuits.

**b) Client (JS, module Angular `antibot-collector`)** :
- Canvas/WebGL/AudioContext hash, fonts, screen, timezone, `navigator.webdriver`,
  détection CDP (Chrome DevTools Protocol — Puppeteer/Playwright), incohérences
  headless connues (plugins vides, permissions, `chrome` object).
- Base : **FingerprintJS OSS** (MIT) + sondes anti-headless maison (les sondes maison
  sont importantes : les fingerprints OSS sont connus des frameworks d'évasion, les
  sondes custom non publiées non).
- Le fingerprint (hash + composantes) part avec chaque requête sensible dans un header
  `X-KVX-FP` signé côté serveur à la première présentation (même mécanique HMAC que
  `GuestSessionService` — on sait le refaire).
- **Signaux dérivés** : fingerprint absent sur endpoint outillé = client non-navigateur ;
  même fingerprint sur N IPs = ferme de bots ; N fingerprints sur 1 IP = rotation
  d'identité ; entropie anormalement commune = template d'évasion.

**RGPD/CNIL** : le fingerprinting à seule fin de sécurité/anti-fraude relève de
l'intérêt légitime (pas de consentement requis comme pour la pub), mais exige :
mention explicite dans la politique de confidentialité, minimisation (hash, pas de
composantes brutes en base), rétention courte (30 j max), pas d'usage cross-service.
À documenter dans le registre des traitements.

### 3.5 Défi JavaScript / Proof-of-Work

Vérifie que le client exécute réellement du JS, avec un coût CPU qui change l'économie
de l'attaque :

- Au chargement de l'app Angular : le collector demande un challenge
  (`GET /api/v1/antibot/challenge` → nonce + difficulté), le résout en Web Worker
  (SHA-256 partiel, ~50–200 ms sur un navigateur normal, invisible), et obtient un
  **jeton de travail** signé (validité 30 min, lié au fingerprint + IP).
- Les endpoints gourmands exigent ce jeton. Absent → +40 au score (pas un blocage sec :
  un vieux navigateur sans Worker doit pouvoir retomber sur le challenge interactif).
- **Difficulté adaptative** : score MONITOR → difficulté ×8 (friction invisible mais
  coût de ferme multiplié) ; c'est le mécanisme Anubis/Friendly Captcha, éprouvé.
- Anti-rejeu : nonce à usage unique (Redis `SETNX`, TTL).

### 3.6 Détection comportementale

Le signal le plus difficile à contrefaire à grande échelle :

- Le collector Angular bufferise des **événements agrégés** (pas de tracking individuel
  précis — RGPD) : cadence et entropie des mouvements souris, vitesse/courbure (les bots
  font des lignes droites ou des courbes de Bézier trop parfaites), rythme de frappe,
  scroll, temps entre arrivée sur la page et déclenchement d'une conversion, ordre des
  actions (un humain choisit un fichier AVANT de cliquer Convertir…).
- Envoi par batch (`POST /api/v1/antibot/telemetry`, sendBeacon) → **scoring asynchrone**
  côté serveur (features simples + seuils au début ; pas de ML au départ — les
  heuristiques bien choisies attrapent 90 % des cas et sont explicables).
- Résultat en cache `behav:{fingerprint}` lu par le RiskEngine.
- **Absence de télémétrie** alors que le client prétend être un navigateur = signal en soi.
- Phase ultérieure (quand il y aura du volume de données) : modèle léger type
  isolation forest entraîné sur les distributions réelles Kovixel.

### 3.7 Challenge adaptatif — Cloudflare Turnstile

Choix tranché : **Turnstile** (vs reCAPTCHA Enterprise / hCaptcha Enterprise) —
gratuit jusqu'à 1 M vérifs/mois, sans image à cliquer (mode invisible/managed),
conforme RGPD (pas de cookie publicitaire, argument produit pour une cible EU),
même écosystème que la couche edge. reCAPTCHA Enterprise en fallback documenté si
besoin d'un second fournisseur.

Flux :

```
Score 60–84 → API répond 403 {errorCode: "CHALLENGE_REQUIRED", challengeType: "turnstile"}
→ L'intercepteur Angular affiche le widget (managed/invisible d'abord, interactif si doute)
→ Token soumis à POST /api/v1/antibot/challenge/verify (siteverify côté serveur, anti-rejeu)
→ Succès : "jeton de confiance" signé (TTL 30 min, lié fingerprint+IP), score fortement réduit
→ La requête d'origine est rejouée automatiquement par l'intercepteur — l'utilisateur
  ne perd jamais son travail (fichier déjà uploadé, options choisies)
```

Règles d'or UX : jamais de challenge sur un utilisateur payant sauf score ≥ 85 ;
jamais deux challenges en 30 min pour le même client vérifié ; le challenge ne fait
jamais perdre l'état du formulaire.

### 3.8 Politique par endpoint (friction proportionnelle au coût)

| Catégorie | Endpoints | Anonyme | Politique |
|---|---|---|---|
| IA cloud (Claude/Adobe) | qna, extract, translate CLOUD | ✅ aujourd'hui | Seuils de challenge les plus bas ; **quotas anonymes réduits** ; option produit à trancher : réserver l'IA cloud aux comptes (gratuits inclus) |
| IA locale (Ollama/GPU, OCR) | summarize, ocr | ✅ | Challenge à score moyen, quotas min/h/j |
| Conversion (Gotenberg/CPU) | convert, pdf tools | ✅ | Rate limit multi-fenêtre, challenge seulement à score élevé |
| Auth | login, register, reset | ✅ | Existant + PoW obligatoire sur register (coupe le credential stuffing et les comptes de masse) |
| Comptes/paiement | checkout, org | ❌ | Existant + signaux compte (âge, email jetable via liste locale) |

« Authentification obligatoire pour les fonctionnalités gourmandes » est ici décliné en
**friction graduée** plutôt qu'en mur binaire : l'accès sans compte est un argument
commercial Kovixel qu'on protège — mais un anonyme à risque moyen sur un endpoint Claude
doit soit se vérifier (challenge), soit se connecter. Décision produit à valider en §6.

### 3.9 Surveillance, pics et blocage progressif

- **Métriques Prometheus** : `antibot_score_bucket`, `antibot_decision_total{decision}`,
  `antibot_challenge_total{result}`, taux de 429/403 par endpoint, coût backends
  payants par heure.
- **Détection de pics** (job 1 min, bases Redis) : volume global par endpoint vs
  baseline horaire glissante (×N = alerte), nouvelles IPs/fingerprints par minute,
  taux d'échec de challenge, dépenses API cloud anormales → **alerte + resserrage
  automatique temporaire des seuils** (mode "sous attaque" : difficulté PoW ×32,
  seuil CHALLENGE abaissé, quotas anonymes ÷4 — activable aussi manuellement).
- **Blocage progressif** (jamais de bannissement définitif automatique) :
  1er dépassement → 429 fenêtre courte ; récidive → CHALLENGE systématique 1 h ;
  persistance → BLOCK 24 h (IP+fingerprint) ; l'humain piégé par erreur a toujours
  la sortie challenge.
- **Console PLATFORM_ADMIN** (réutilise le sous-système super-admin existant) :
  vue des scores/décisions récentes avec signaux contributifs, allowlist/blocklist
  manuelles (IP, ASN, fingerprint, email), kill-switch par signal, réglage des seuils
  à chaud, mode "sous attaque". Toute action tracée dans `PlatformAdminAuditLog`.

---

## 4. Ce que les géants ont et qu'on ne réplique pas (assumé)

Lucidité nécessaire pour viser juste :

- **Effet réseau** : DataDome/Cloudflare corrèlent les attaques sur des milliers de
  clients. Compensation : la couche edge Cloudflare nous en donne une partie, et nos
  signaux maison sont spécifiques à notre trafic (avantage du défenseur local).
- **ML massif temps réel** : hors de portée au départ. Compensation : heuristiques
  pondérées explicables, puis ML léger quand les données existent.
- **Équipe de réponse 24/7** : compensé par le resserrage automatique "sous attaque"
  + alerting + kill-switchs simples utilisables en mobile à 3 h du matin.

---

## 5. Roadmap d'implémentation

> Chaque sprint livre une valeur autonome ; l'ordre optimise le ratio protection/effort.
> Estimations pour un dev senior + revue.

### Sprint 1 — Fondations : RiskEngine + rate limiting multi-dimensionnel *(1,5 sem)* ✅ FAIT
- ✅ Module `antibot` : `RiskEngine`, `RiskContext`, `RiskAssessment`, `RiskDecision`,
  interface `RiskSignal` (seuils/poids en `@Value`, pas de classe `@ConfigurationProperties`
  séparée — choix fait pour rester cohérent avec le reste de la codebase et éviter
  l'incertitude de résolution de bean dans les `@WebMvcTest`).
- ✅ `RiskEvaluationFilter` branché en tout dernier de la chaîne (après `AnonymousQuotaFilter`)
  en **mode shadow strict** : calcule, trace (log + MDC + métriques), n'agit JAMAIS
  (`chain.doFilter()` inconditionnel, y compris si `RiskEngine` lève une exception ou
  retourne `null`).
- ✅ Script Lua Redis (`antibot_sliding_window.lua`) : sliding window counter approximé
  (technique Cloudflare/Kong), multi-fenêtre (min/h/j), multi-dimension (IP, compte,
  gsid, sous-réseau /24 IPv4 · /56 IPv6) — `VelocitySignal`. ASN reporté au Sprint 3
  (dépend de `IpReputationSignal`, pas encore construit).
- ✅ Raccord des 3 filtres existants (`AuthRateLimitFilter`, `InvitationRateLimitFilter`,
  `CheckoutRateLimitFilter`) → `RiskEventPublisher.recordViolation()` → lu par
  `ViolationHistorySignal`.
- ✅ Métriques Micrometer (`AntibotMetrics` : `kovixel.antibot.decision`,
  `kovixel.antibot.score`) + logs structurés (score/décision dans le MDC).
- ✅ 54 tests unitaires nouveaux (RiskEngine, VelocitySignal, ViolationHistorySignal,
  RiskEventPublisher, RiskEvaluationFilter, IpSubnetUtil) + mise à jour des 9
  `@WebMvcTest` impactés par le nouveau filtre global. Suite complète : 1048 tests,
  0 régression (1 échec pré-existant sans rapport, `AuthControllerTest.refresh_missingCookie`).
- **Livrable : scoring shadow en prod (à déployer), dashboards de distribution des scores
  à construire côté Sprint 7.**

### Sprint 2 — Edge : Cloudflare + durcissement nginx *(1 sem, parallélisable)* 🟡 CODE PRÊT, BASCULE MANUELLE EN ATTENTE
- ✅ Origin lockdown : `set_real_ip_from`/`real_ip_header CF-Connecting-IP` (module
  `ngx_http_realip_module`) + verrou par plage IP Cloudflare (`geo`/`map`, toggle
  `ORIGIN_LOCKDOWN_ENABLED`, désactivé par défaut) + secret partagé `X-Origin-Auth`
  (`ORIGIN_AUTH_SECRET`, fail-open si non configuré) dans
  `kovixel-ui/docker/nginx.conf.template` (résolu par `envsubst` au démarrage du
  conteneur — voir `start.sh`/`Dockerfile`).
  **Révision par rapport au plan initial** : la traduction IP se fait entièrement côté
  nginx (`real_ip_header`) — `ClientIpResolver` n'a pas eu besoin d'être modifié, il
  fait déjà confiance à X-Real-IP/X-Forwarded-For posés par le reverse proxy configuré.
- ✅ **Bug trouvé et corrigé au passage** : `KOVIXEL_TRUSTED_PROXIES` n'était jamais
  transmis à `kovixel-app` dans `docker-compose.yml` — toutes les requêtes
  apparaissaient comme venant de l'IP du conteneur nginx, ce qui rendait **tous les
  signaux IP du Sprint 1 (VelocitySignal, quotas anonymes, rate-limit) inopérants**
  dans ce déploiement. Corrigé (`172.16.0.0/12`, sûr car `kovixel-app` n'a aucun port
  publié sur l'hôte).
- ✅ Zones `limit_req` nginx (`origin_general` 30r/s, `origin_api` 20r/s) en
  coupe-circuit local, indépendant de Cloudflare et du RiskEngine applicatif.
- ✅ Runbook complet (`kovixel-ui/docker/CLOUDFLARE_RUNBOOK.md`) : création compte
  Cloudflare, bascule DNS, mode TLS (Flexible vs Full strict — décision documentée),
  Bot Fight Mode, WAF, Transform Rule pour le secret, activation du verrou,
  vérification post-bascule, rollback, maintenance périodique des plages IP.
- ⏳ **Reste à faire par l'opérateur (hors périmètre code — nécessite un compte
  Cloudflare et l'accès au registrar du domaine)** : exécuter le runbook — création du
  compte, bascule des nameservers, activation Bot Fight Mode/WAF, Transform Rule, puis
  `ORIGIN_LOCKDOWN_ENABLED=true` + `ORIGIN_AUTH_SECRET=...` en prod.
- **Livrable : code et config prêts pour la bascule ; DDoS et bots grossiers seront
  coupés au edge dès l'exécution du runbook.**

### Sprint 3 — Réputation IP *(1 sem)* ✅ FAIT (compte MaxMind à créer par l'opérateur)
- ✅ `MaxMindAsnService` + `MaxMindUpdateJob` : lit une base GeoLite2-ASN locale (chemin
  configurable), rechargement à chaud après chaque mise à jour hebdomadaire (téléchargement
  + extraction tar.gz via Commons Compress + remplacement atomique du fichier). Dégradé en
  neutre (signal désactivé, jamais bloquant) si `MAXMIND_LICENSE_KEY` n'est pas configurée —
  compte gratuit sur maxmind.com, action manuelle de l'opérateur (comme Cloudflare Sprint 2).
- ✅ `DatacenterAsnRegistry` : liste curée d'ASN cloud/hébergement connus (AWS, GCP, Azure,
  OVH, Hetzner, DigitalOcean, etc.), extensible sans redéploiement via
  `ANTIBOT_EXTRA_DATACENTER_ASNS`.
- ✅ `IpBlocklistUpdateJob`/`IpBlocklistService` : rafraîchissement quotidien FireHOL level1 +
  Spamhaus DROP/EDROP (CIDR, aucun compte requis) + liste des nœuds de sortie Tor. Gardé
  **en mémoire** (pas Redis) — ces listes sont petites (quelques centaines d'entrées), un
  scan linéaire in-process est largement suffisant et évite une dépendance supplémentaire ;
  chaque instance télécharge indépendamment (acceptable, mise à jour quotidienne peu fréquente).
- ✅ `IpReputationSignal` : blocklist (score 95) > Tor (80) > ASN datacenter (40) > neutre —
  le max des trois catégories, pas un cumul (un VPN d'entreprise légitime peut être à la
  fois "datacenter" et inoffensif ; c'est au RiskEngine de corroborer avec les autres
  signaux, pas à celui-ci de trancher seul).
- ✅ Tests : fixture de test officielle MaxMind (`GeoLite2-ASN-Test.mmdb`, 12 Ko, réel format
  .mmdb lu par un test — pas un mock) + tar.gz construit en mémoire pour tester
  l'extraction/atomicité + 31 tests au total sur ce sprint, aucune régression sur les 65
  tests du module antibot ni sur la suite complète.
- ⏳ **Reste à faire par l'opérateur** : créer un compte gratuit sur maxmind.com, générer une
  License Key, la mettre dans `MAXMIND_LICENSE_KEY`. Sans ça, le signal ASN reste désactivé
  (blocklist OSS et Tor fonctionnent déjà sans aucune action, aucun compte requis).
- **Livrable : tout datacenter (une fois la clé fournie)/Tor/IP sur liste connue anonyme est
  visible dans le score shadow dès ce sprint pour Tor/OSS ; ASN datacenter dès la clé fournie.**

### Sprint 4 — Fingerprinting + défi JS *(2 sem)* ✅ FAIT (enforcement register désactivé par défaut)
- ✅ **Backend** : `PowChallengeService` (nonce Redis usage unique, difficulté configurable —
  zéros hexadécimaux en tête de SHA-256, défaut 3 ≈ 4096 tentatives), `FingerprintTokenService`
  (signe le fingerprint brut, même mécanique HMAC que `GuestSessionService`),
  `FingerprintCorrelationService` (sets Redis IP↔fingerprint), `AntibotChallengeController`
  (3 endpoints publics : `/challenge`, `/challenge/verify`, `/fingerprint`).
- ✅ `ConsistencySignal` : User-Agent absent, HeadlessChrome (score max — aucun vrai
  navigateur ne s'annonce ainsi), Chrome/Edge sans sec-ch-ua, Accept-Language absent.
  **Écart assumé par rapport au plan initial** : pas de contrôle de version de protocole
  (HTTP/1.1 vs HTTP/2) — derrière nginx (et Cloudflare une fois le Sprint 2 basculé),
  l'app voit systématiquement du HTTP/1.1 côté origin quel que soit le client réel ; ce
  serait un faux signal permanent dans cette topologie, pas un signal réel.
- ✅ `JsChallengeSignal` (jeton de travail absent/invalide) + `FingerprintSignal` (absence
  modérée ; corrélation IP↔fingerprint anormale — ferme de bots ou rotation — score fort).
- ✅ `RiskContext` étendu (User-Agent, Accept-Language, sec-ch-ua, fingerprint validé, jeton
  de travail validé) — 2e constructeur conservé pour la compatibilité des tests Sprint 1-3.
- ✅ `PowEnforcementFilter` : bloque réellement `POST /auth/register` sans preuve de travail
  valide (428) — **seule application de décision réelle de ce sprint**, tout le reste du
  RiskEngine restant en mode shadow. Désactivé par défaut
  (`ANTIBOT_POW_ENFORCE_ON_REGISTER=false`), même logique que `ORIGIN_LOCKDOWN_ENABLED`
  (Sprint 2) : à activer une fois le flux frontend vérifié en conditions réelles.
- ✅ **Frontend** : `AntibotService` (orchestration), Web Worker `pow-solver.worker.ts`
  (résolution SHA-256 via Web Crypto natif — pas d'implémentation maison, coût CPU
  invisible côté utilisateur), `antibotInterceptor` (attache `X-KVX-FP` partout,
  `X-KVX-WT` uniquement sur l'inscription avec timeout de secours 5s pour ne jamais
  bloquer indéfiniment si le jeton n'arrive jamais). Démarre en tâche de fond au
  bootstrap (`APP_INITIALIZER`), jamais en SSR.
- ✅ Fingerprinting : FingerprintJS OSS + sondes maison volontairement modestes en v1
  (`navigator.webdriver`, plugins/langues vides) — à réviser périodiquement (Sprint 8).
- ✅ Tests : 117 tests backend (dont solveur PoW réel en Java simulant le client),
  13 tests frontend Vitest (Worker mocké, FingerprintJS mocké, timeout de secours vérifié).
  Vérifié en navigateur réel (FingerprintJS se charge, les deux appels réseau partent
  correctement) — pas de vérification bout-en-bout complète possible (Docker indisponible
  dans cet environnement, pas de Redis/Postgres pour faire tourner le backend réel).
- **Livrable : les clients non-navigateur et headless sont identifiés dans le score shadow
  dès ce sprint ; l'inscription sera protégée dès l'activation de l'enforcement (après
  vérification en conditions réelles).**

### Sprint 5 — Activation + challenge adaptatif Turnstile *(1,5 sem)* ✅ FAIT (enforcement désactivé par défaut)
- ✅ **Backend** : `TurnstileService` (siteverify via `RestTemplate`, form-encodé) — **fail-CLOSED**
  délibérément (contrairement à la dégradation neutre des autres signaux) : une panne
  siteverify refuse la vérification plutôt que de délivrer un jeton de confiance sans
  contrôle réel, ce qui reviendrait à désactiver silencieusement tout le challenge pendant
  la panne. Anti-rejeu géré nativement par Cloudflare (jeton Turnstile à usage unique),
  pas de suivi Redis dupliqué.
- ✅ `TrustTokenService` — même mécanique HMAC que `FingerprintTokenService`/`GuestSessionService`,
  jeton lié IP+fingerprint (TTL configurable, 30 min par défaut). `RiskContext` étendu
  (`hasValidTrustToken`) : un jeton valide fait traiter la requête comme `ALLOW`, quel que
  soit le score — jamais deux challenges en 30 min pour le même client vérifié (règle d'or
  UX §3.7).
- ✅ `AntibotChallengeController` : nouvel endpoint `POST /turnstile/verify` (siteverify +
  émission du jeton de confiance).
- ✅ `RiskEvaluationFilter` : application réelle de BLOCK et CHALLENGE, chacune derrière son
  propre interrupteur désactivé par défaut (`kovixel.antibot.enforcement.block-enabled` /
  `challenge-enabled`), même logique que `ORIGIN_LOCKDOWN_ENABLED` (Sprint 2) et
  `ANTIBOT_POW_ENFORCE_ON_REGISTER` (Sprint 4). BLOCK est global (un score ≥ 85 est quasi
  certain) ; CHALLENGE se déploie **endpoint par endpoint** via une liste de préfixes de
  chemin configurable (`challenge-path-prefixes`, vide par défaut = shadow uniquement même
  si le flag est actif) — en commençant par l'IA cloud comme prévu, sans redéploiement pour
  étendre la liste.
- ✅ **Frontend** : `AntibotChallengeService` (orchestration, dédoublonne les challenges
  concurrents via un `Subject` partagé), `AntibotChallengeModalComponent` (widget Turnstile
  chargé dynamiquement, monté une seule fois dans `AppComponent`), `antibotInterceptor`
  étendu : attache `X-KVX-TT`, intercepte les 403 `CHALLENGE_REQUIRED`, affiche le widget et
  **rejoue automatiquement la requête d'origine** une fois le jeton obtenu (un seul rejeu,
  pas de boucle si le second essai échoue encore).
- ✅ Tests : 141 tests backend (dont `TurnstileServiceTest`/`TrustTokenServiceTest` neufs +
  enforcement BLOCK/CHALLENGE/jeton de confiance dans `RiskEvaluationFilterTest`), 32 tests
  frontend Vitest neufs (service de challenge, modal avec `window.turnstile` mocké,
  intercepteur avec rejeu). `ng build` vérifié sans erreur — pas de vérification bout-en-bout
  en navigateur réel (Docker indisponible dans cet environnement, et un vrai compte
  Cloudflare Turnstile serait nécessaire).
- **Écarts assumés par rapport au plan initial** :
  - *Calibration des seuils réels* — non faite : aucune donnée de production shadow
    n'existe encore dans cet environnement (Sprint 1-4 n'ont jamais tourné en trafic réel).
    Les seuils par défaut (monitor 30 / challenge 60 / block 85) sont inchangés ; à
    recalibrer une fois du trafic réel observé.
  - *Quotas adaptatifs pilotés par le score* — non fait, reporté (nécessite de relier
    `QuotaService`/`AnonymousQuotaFilter` au score du `RiskEngine`, hors scope de ce sprint
    pour rester focalisé sur la boucle challenge).
  - *Activation effective en prod* — le code est prêt mais **désactivé par défaut** des deux
    côtés (`ANTIBOT_BLOCK_ENABLED`/`ANTIBOT_CHALLENGE_ENABLED` à `false`, `TURNSTILE_SITE_KEY`/
    `TURNSTILE_SECRET_KEY` vides) : à activer une fois un vrai compte Cloudflare Turnstile
    créé et le flux vérifié en conditions réelles, même logique que Sprint 2/4.
- **Livrable : la boucle complète évaluer → laisser passer → challenger est prête, testée,
  et activable sans redéploiement — l'activation effective en prod reste une action
  opérateur distincte (clés Turnstile + interrupteurs), volontairement pas déclenchée ici.**

### Sprint 6 — Comportemental *(1,5 sem)* ✅ FAIT
- ✅ **Backend** : `BehavioralTelemetryController` (`POST /antibot/telemetry`, public) reçoit des
  lots de télémétrie agrégée — le jeton de fingerprint est porté dans le corps (pas l'en-tête
  `X-KVX-FP` habituel) car `navigator.sendBeacon` ne permet pas de personnaliser les en-têtes
  HTTP. `BehavioralScoringService` calcule un score heuristique (absence totale d'interaction
  sur une session non triviale, mouvements de souris anormalement rectilignes, frappe clavier
  anormalement régulière, action quasi instantanée après chargement) et le met en cache
  (`antibot:behav:{fingerprint}`, TTL configurable). `BehavioralSignal` le relit pour le
  RiskEngine — le signal le plus difficile à contrefaire à grande échelle.
- ✅ `AccountSignal` : âge du compte (compte très récent = suspicion forte, ex. création de
  masse), `DisposableEmailRegistry` (domaines jetables curés + extensibles par config, même
  logique que `DatacenterAsnRegistry`), historique de violations 429 scopé au compte
  (indépendant de l'IP — `RiskEventPublisher` étendu avec un userId optionnel, alimenté par
  `CheckoutRateLimitFilter` qui connaît déjà l'utilisateur authentifié). Une projection JPA
  légère (`UserRepository.findAccountSummaryById`) évite de charger l'entité complète.
- ✅ **Frontend** : `BehavioralTelemetryService` — cadence/rectilinéarité des mouvements souris,
  variance des intervalles de frappe, comptage de scroll, temps avant première interaction ;
  jamais de coordonnées ou de touches individuelles conservées au-delà du calcul immédiat
  (RGPD). Envoi par lots (20s) et à la fermeture/masquage de page via `sendBeacon`, jamais
  bloquant. Démarré en tâche de fond au bootstrap, comme `AntibotService`.
- ✅ Tests : 190 tests backend antibot (47 nouveaux), 10 tests frontend Vitest neufs
  (dont la détection d'une fuite de listeners `window`/`document` entre instances de service —
  corrigée via `OnDestroy`, sans impact en production où le service vit avec la page mais
  nécessaire pour l'isolation des tests).
- ✅ Revalidation avant Sprint 7 : (1) `AccountSignal` retournait toujours "compte créé il y a
  moins de {new-threshold-hours}h" même quand c'est le seuil very-new (plus strict) qui avait
  déclenché le score — texte techniquement vrai mais trompeur pour l'explicabilité (deux comptes
  à des scores très différents affichaient la même raison). Fixé pour reporter le seuil qui a
  réellement déclenché. (2) Les seuils de détection de `BehavioralScoringService` (durée min de
  session, nombre min d'échantillons souris/clavier, seuils de rectilinéarité/variance/latence)
  étaient codés en dur alors que le reste du RiskEngine (VelocitySignal, AccountSignal,
  FingerprintSignal...) externalise systématiquement ce type de seuil via `@Value` — contredisait
  la note "à recalibrer une fois le trafic réel observé" déjà écrite dans ce document. Externalisés
  sous `kovixel.antibot.behavioral.*` (seuls les scores bruts 0-100 restent en dur, comme pour
  tous les autres signaux).
- **Écart assumé** : "absence de télémétrie = signal en soi" (roadmap §3.6) non implémenté —
  daterait la première apparition du fingerprint pour distinguer une absence suspecte d'une
  visite légitimement très récente (pas encore eu le temps d'envoyer un lot), ce qui risquerait
  de pénaliser à tort des utilisateurs rapides et légitimes sans données réelles pour calibrer
  correctement le seuil. L'architecture additive du RiskEngine couvre déjà ce cas indirectement
  (un bot sans télémétrie ET avec d'autres signaux dégradés est détecté par ailleurs). Pas de
  télémétrie sur l'ordre des actions (ex. "choisir un fichier avant de cliquer Convertir") —
  nécessiterait une instrumentation spécifique par fonctionnalité, hors scope de cette
  première version générique.
- **Livrable : les fermes qui passent le fingerprinting tombent sur le comportemental.**

### Sprint 7 — Riposte et exploitation *(1,5 sem)* ✅ FAIT
- ✅ `AntibotRuntimeConfigService` : seuils/poids/kill-switches par signal et mode "sous
  attaque" ajustables à chaud (Redis, fallback sur `application.yml` si absent/panne) —
  `RiskEngine` les consulte à chaque évaluation. Mode "sous attaque" : difficulté PoW majorée
  (`PowChallengeService`, +2 par défaut — dans l'esprit du "×32" du roadmap, la difficulté
  étant exponentielle), seuil CHALLENGE abaissé (`RiskEngine`), quotas anonymes divisés
  (`AnonymousQuotaService`, ÷4 par défaut, jamais un plafond désactivé transformé en plafond
  actif). Auto-expiration au bout de 6h (défaut) pour ne jamais dégrader indéfiniment en cas
  d'oubli de désactivation manuelle.
- ✅ `ManualListService` : allowlist/blocklist IP, fingerprint, email (ASN déjà couvert par
  `DatacenterAsnRegistry.extra-datacenter-asns` depuis le Sprint 3, pas dupliqué). Vérifiées
  par `RiskEvaluationFilter` en tête de `enforce()`, avant même le jeton de confiance —
  précédence : allowlist > blocklist > jeton de confiance > blocage progressif > score.
- ✅ `ProgressiveEnforcementService` : échelle de blocage progressif par IP — 2 rejets 429
  (comptés via `RiskEventPublisher`, déjà le point de collecte central) → CHALLENGE
  systématique STICKY 1h ; 5 rejets → BLOCK STICKY 24h. Jamais de bannissement automatique
  permanent ; un jeton de confiance valide outrepasse aussi l'escalade (l'humain piégé garde
  toujours la sortie challenge). Désactivé par défaut (`kovixel.antibot.progressive.enabled`).
- ✅ `SpikeDetectionJob` (toutes les minutes) : volume `/api/**` et fingerprints distincts vs
  baseline glissante 60 min — alerte toujours (log + métrique Micrometer
  `kovixel.antibot.spike`), l'activation AUTOMATIQUE du mode "sous attaque" reste désactivée
  par défaut (`auto-activate-enabled=false`) : une heuristique non calibrée sur du trafic réel
  ne doit pas pouvoir dégrader unilatéralement l'expérience anonyme sans supervision humaine.
- ✅ Console PLATFORM_ADMIN (`/api/v1/admin/antibot/**`, réutilise `PlatformAccessGuard` +
  `PlatformAdminAuditLog` existants) : lecture PLATFORM_SUPPORT+, mutations PLATFORM_ADMIN.
  Seuils/poids/kill-switches à chaud, activation/désactivation du mode sous attaque, listes
  manuelles (ajout/retrait), décisions récentes explicables (`RecentDecisionsService`, ring
  buffer Redis borné à 200 entrées — donnée opérationnelle éphémère, pas de nouvelle table).
  Toute mutation tracée dans `PlatformAdminAuditLog`. Frontend : nouvel onglet "Antibot" dans
  la console Super-Admin existante (`AntibotConsoleComponent`).
- ✅ Tests : 276 tests backend antibot (86 nouveaux), 20 tests frontend Vitest neufs.
- **Écarts assumés** : pas de suivi du taux d'échec de challenge ni des dépenses API cloud
  anormales dans `SpikeDetectionJob` (nécessiteraient respectivement de nouveaux compteurs
  succès/échec au niveau siteverify/PoW et une intégration avec le suivi de facturation
  existant, hors scope) ; pas de canal d'alerte sortant (Slack/PagerDuty) — même limite déjà
  assumée pour `PlatformAdminAuditService` (log + métrique, webhook à brancher par l'outillage
  d'observabilité, pas construit ici).
- **Livrable : le système s'exploite et se pilote sans redéploiement** — seuils/poids/
  kill-switches à chaud, mode sous attaque manuel ou automatique (désactivé par défaut),
  blocage progressif désactivé par défaut, listes manuelles opérationnelles dès maintenant.

### Sprint 8 — Durcissement continu *(récurrent)* 🟡 PROCESS PRÊT, RED TEAM/ML NON FAITS
- ✅ **Revue mensuelle** : runbook `ANTIBOT_MONTHLY_REVIEW_RUNBOOK.md` — checklist faux positifs
  (plaintes, taux de challenge sur payants via `decisions/recent`), ajustement des poids/seuils
  à chaud (`AntibotAdminController`, sans redéploiement), suivi des volumes/pics
  (`kovixel.antibot.*`), rotation des sondes anti-headless maison, et deux tests manuels légers
  en attendant le red team automatisé. **Décision produit** : lancée sans tooling automatisé
  pour l'instant (voir ci-dessous) — à exécuter dès qu'il y a du trafic de production réel,
  jusque-là rien à mesurer.
- ⏳ **Red team interne** (Playwright + stealth plugins, curl-impersonate, pools de proxys
  résidentiels simulés) : reporté délibérément — nouvelle stack Node hors du repo Maven actuel,
  et non vérifiable bout-en-bout dans cet environnement de développement (pas de Docker/Redis
  pour faire tourner le RiskEngine réel contre les probes). À reprendre quand un environnement
  permet de le valider en conditions réelles.
- ⏳ **ML léger sur la télémétrie comportementale** : non applicable, volume de données réel
  insuffisant (aucun trafic de production dans cet environnement) — cf. §6 du runbook.
- **Livrable : le processus de durcissement continu est documenté et exécutable dès le premier
  trafic réel ; l'automatisation red team reste un chantier distinct, non commencé.**

**Total build initial : ~10 semaines.** Ordre de dépendance strict : S1 avant S3–S6 ;
S2 indépendant ; S5 exige S1+S4.

> Hypothèse de l'estimation : un dev senior **dédié à temps plein** à ce chantier, pas en
> parallèle du reste du backlog produit. En temps partagé (ex. 50 % du temps), compter la
> durée calendaire en conséquence (~20 semaines) — le ratio d'effort par sprint reste lui
> inchangé.

---

## 6. Décisions à valider avant Sprint 1

1. **Cloudflare devant app.kovixel.com** — oui/non (sinon variante Coraza, +2 sem et
   moins bon niveau edge).
2. **IA cloud (Claude/Adobe) réservée aux comptes ?** Recommandation : garder l'accès
   anonyme mais avec quotas serrés + seuil de challenge bas ; re-trancher aux premières
   données de coût réelles.
3. **Budget mensuel** : ~0–25 $ (Cloudflare Pro) + 0 $ (Turnstile, MaxMind GeoLite2,
   listes OSS) au départ ; IPQualityScore optionnel plus tard (~50 $/mois).
4. **RGPD** : valider la mention fingerprinting/télémétrie dans la politique de
   confidentialité + registre des traitements (intérêt légitime, rétention 30 j).

---

## 7. KPIs de succès

| KPI | Cible |
|---|---|
| Taux de challenge sur utilisateurs payants | < 0,1 % des sessions |
| Faux positifs (humains bloqués sans issue) | ≈ 0 (le challenge est toujours une sortie) |
| Latence ajoutée P99 (RiskEngine, chemin requête) | ≤ 5 ms |
| Part du trafic bot sur endpoints IA cloud | mesurée S1, ÷10 après S5 |
| Coût API cloud dû aux anonymes | plafonné et alerté |
| Temps de réaction à un pic d'abus | < 1 min (auto) |
| Explicabilité | 100 % des BLOCK avec signaux contributifs consultables |
