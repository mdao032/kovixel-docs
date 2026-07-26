# Roadmap Capacité Initiale — 3 corrections avant mise en charge

> **Statut :** Proposition technique v1.0
> **Date :** 2026-07-26
> **Audience :** Équipe backend
> **Portée :** Ciblée et tactique — 3 corrections identifiées lors d'une revue de capacité de
> l'architecture actuelle, à traiter **avant** tout test de charge ou mise en staging avec trafic
> réel. Ne remplace pas `SCALE_AND_QUALITY_ROADMAP.md` (feuille de route de scalabilité complète,
> horizon 1-12 mois) — ce document est un sous-ensemble immédiat, gratuit en infrastructure,
> destiné à repousser le plafond de capacité de l'architecture mono-instance actuelle avant d'y
> investir de l'argent (hébergement, tests de charge outillés).

---

## Table des matières

1. [Contexte et diagnostic](#1-contexte-et-diagnostic)
2. [Correction 1 — Dimensionnement du pool de connexions PostgreSQL](#correction-1--dimensionnement-du-pool-de-connexions-postgresql)
3. [Correction 2 — Traitement IA asynchrone](#correction-2--traitement-ia-asynchrone)
4. [Correction 3 — Duplication de l'instance applicative derrière un load balancer](#correction-3--duplication-de-linstance-applicative-derrière-un-load-balancer)
5. [Critères de sortie globaux](#5-critères-de-sortie-globaux)

---

## 1. Contexte et diagnostic

Aucun test de charge n'a jamais été exécuté sur Kovixel. L'estimation de capacité ci-dessous est
une **inférence à partir de la configuration existante**, pas une mesure — mais les trois plafonds
identifiés sont vérifiables directement dans le code et bloquent toute discussion sérieuse
d'hébergement à 100k+ utilisateurs/jour tant qu'ils ne sont pas levés.

| Contrainte constatée | Emplacement | Effet |
|---|---|---|
| Pool de connexions PostgreSQL limité à 20 | `application-prod.yml` (`spring.datasource.hikari.maximum-pool-size: 20`) | Plafond dur : 20 requêtes DB simultanées, tous endpoints confondus |
| Appels IA synchrones sur le thread HTTP | Services de résumé/Q&A/extraction/traduction (appels Anthropic Claude bloquants) | Un thread Tomcat (200 par défaut) est immobilisé plusieurs secondes par appel IA — le vrai goulot caché |
| Une seule instance applicative, sans load balancer | `docker-compose.yml` (un seul conteneur `kovixel-app`, aucun reverse proxy devant plusieurs répliques) | Aucune redondance, aucun scaling horizontal possible en l'état |

Estimation de capacité actuelle (ordre de grandeur, non mesuré) : quelques milliers à ~10-15k
utilisateurs actifs/jour en usage étalé, et de l'ordre de quelques dizaines à ~150-200 utilisateurs
simultanés avant mise en file d'attente perceptible — bien en-deçà de la cible de 100k/jour.

---

## Correction 1 — Dimensionnement du pool de connexions PostgreSQL

**Objectif :** lever le plafond artificiel de 20 connexions simultanées, qui n'a aucune
justification technique documentée (valeur par défaut jamais révisée).

**Tâches :**
- Mesurer le nombre de connexions PostgreSQL réellement disponibles côté serveur
  (`max_connections`, actuellement valeur par défaut de l'image `pgvector/pgvector:pg16` — à
  vérifier et augmenter si nécessaire, en laissant une marge pour les connexions d'administration).
- Relever `spring.datasource.hikari.maximum-pool-size` à une valeur cohérente avec cette capacité
  serveur (ex. 50-100 selon le nombre d'instances applicatives prévues après la Correction 3 — le
  pool est **par instance**, donc `max-pool-size × nombre d'instances ≤ max_connections serveur`).
- Ajuster `minimum-idle` en conséquence et surveiller `HikariPool` via les métriques Actuator déjà
  exposées (`/actuator/metrics`, cf. Sprint E-6/E-7 de `ROADMAP_CHIFFREMENT.md` pour le pattern de
  métriques Micrometer déjà en place).

**Effort :** quelques heures — changement de configuration, pas de code applicatif. Risque faible :
augmenter un pool ne casse rien, seul le risque de sous-dimensionner le `max_connections` serveur
en face doit être vérifié avant de monter la valeur.

**Critère de sortie :** le pool ne sature plus sous une charge simulée modeste (quelques centaines
de requêtes/minute) — pas d'erreur `connection is not available, request timed out`.

---

## Correction 2 — Traitement IA asynchrone

**Objectif :** ne plus bloquer un thread HTTP (et potentiellement une connexion DB) pendant toute
la durée d'un appel à l'API Claude/Anthropic (résumé, Q&A, extraction, traduction) — c'est le
goulot le plus sévère identifié, car un appel IA peut prendre plusieurs secondes contre quelques
millisecondes pour une requête CRUD classique.

**Tâches :**
- Identifier tous les endpoints synchrones qui attendent une réponse IA en ligne (résumé,
  Q&A, extraction, traduction — cf. `PUBLIC_ENDPOINTS` dans `SecurityConfig.java` pour la liste des
  routes concernées : `/api/v1/documents/summarize`, `/api/v1/documents/*/ask`,
  `/api/v1/documents/*/extract`, `/api/v1/documents/*/translate`).
- Faire basculer ces endpoints vers un modèle asynchrone : le client déclenche le job IA (réponse
  immédiate avec un identifiant de job), puis interroge le statut (polling) ou reçoit une
  notification (WebSocket/SSE) — le projet a déjà un précédent direct avec `AiJob`
  (`V8__create_ai_jobs.sql`, présent selon la revue Sprint E-1/E-6 de `ROADMAP_CHIFFREMENT.md`) :
  étendre ce mécanisme existant plutôt qu'en recréer un nouveau.
- S'assurer que l'exécuteur dédié au traitement IA est isolé du pool HTTP principal (même logique
  que `fileAuditExecutor` introduit au Sprint E-6 de `ROADMAP_CHIFFREMENT.md` — un exécuteur dédié
  par famille de traitement, pour ne jamais saturer le pool partagé `processingExecutor`).
- Adapter le frontend (`kovixel-ui`) pour gérer l'état "en cours de traitement" au lieu d'une
  attente bloquante sur la requête HTTP.

**Effort :** important — c'est un changement de contrat d'API (synchrone → asynchrone), touchant
le frontend en plus du backend. À planifier comme un sprint à part entière, pas une config rapide.

**Critère de sortie :** aucun thread HTTP n'attend une réponse d'API IA externe ; un pic de 50
requêtes IA simultanées ne dégrade pas le temps de réponse des autres endpoints (conversion,
authentification, etc.).

---

## Correction 3 — Duplication de l'instance applicative derrière un load balancer

**Objectif :** éliminer le point de défaillance unique et permettre un premier palier de scaling
horizontal, sans passer par un orchestrateur complet (Kubernetes) à ce stade.

**Tâches :**
- Dupliquer le conteneur `kovixel-app` (2 répliques minimum) dans `docker-compose.yml` ou
  l'équivalent de l'environnement de staging choisi.
- Ajouter un load balancer devant (Nginx, Traefik, ou l'ALB si l'hébergement AWS est retenu) —
  vérifier au passage que `server.forward-headers-strategy: framework` (déjà positionné en prod
  depuis le Sprint E-7 de `ROADMAP_CHIFFREMENT.md`) restitue correctement le schéma d'origine
  derrière ce nouveau load balancer.
- Confirmer que l'application est bien **stateless** entre répliques : sessions JWT sans état
  côté serveur (déjà le cas, `SessionCreationPolicy.STATELESS` dans `SecurityConfig`), pas de cache
  en mémoire locale qui diffère d'une instance à l'autre (vérifier `AnonymousQuotaService`,
  `TokenBlacklistService` — doivent déjà reposer sur Redis partagé, pas sur un état local ; à
  confirmer explicitement lors de l'implémentation).
- Health checks par instance (`/actuator/health`, déjà public dans `SecurityConfig`) pour que le
  load balancer retire automatiquement une instance défaillante.

**Effort :** modéré — surtout de la configuration d'infrastructure, sous réserve que la
vérification de statelessness ci-dessus ne révèle pas de mauvaise surprise (auquel cas il faudrait
d'abord migrer l'état concerné vers Redis/PostgreSQL).

**Critère de sortie :** l'arrêt volontaire d'une instance en cours de fonctionnement ne provoque
aucune erreur côté utilisateur (basculement transparent sur l'autre instance).

---

**Correction 2 — statut (2026-07-26) : terminée.**
- Backend : migration V74 (ajoute `TRANSLATION` à l'enum `ai_job_type` — et corrige au passage
  `CONVERSION`, jamais ajoutée depuis sa création en Java, un bug pré-existant qui aurait fait
  échouer toute conversion asynchrone réelle en prod). `AiJobProcessor.handleSummary()` implémenté
  (remplace un placeholder mort) et `handleTranslation()` ajouté. Les 4 endpoints
  (`/summarize`, `/ask`, `/extract`, `/translate`) soumettent désormais un job (202 + jobId) au
  lieu de bloquer le thread HTTP sur l'appel Claude. Nouveau endpoint public
  `GET /api/v1/jobs/{jobId}/anonymous` (résumé/Q&A/extraction/traduction restent utilisables sans
  compte — le polling doit l'être aussi).
- **Piège découvert et corrigé** : le quota anonyme (par IP) est vérifié à l'intérieur de
  `QnaServiceImpl`/`ExtractionServiceImpl`/`TranslationServiceImpl` en utilisant le paramètre
  `clientIp` — en contexte async, cette IP n'existe plus nativement. Résolu en la faisant voyager
  dans le payload du job (`QnaJobPayload`/`ExtractionJobPayload`/`TranslationJobPayload`), pas en
  la remplaçant par une chaîne vide (ce qui aurait mélangé tous les anonymes dans un seul quota
  incohérent).
- **Limite connue acceptée** : le rejet pour quota dépassé (429 `ANONYMOUS_QUOTA_EXCEEDED`)
  survient maintenant à l'intérieur du job (statut `FAILED`), plus comme une erreur HTTP
  synchrone — l'intercepteur frontend qui ouvre la modal "créer un compte" sur ce cas précis ne se
  déclenche donc plus pour ces 3 endpoints (il affiche un message d'erreur générique à la place).
  Corriger proprement demanderait de propager un code d'erreur structuré depuis le job FAILED vers
  ce même intercepteur — non fait dans cette passe, documenté comme dette.
- **Limite connue, hors scope** : dans `qna.component.ts`, l'upload d'un fichier PDF réutilise déjà
  `SummaryService.summarize()` pour obtenir un `documentId` — ce flux était partiellement préparé
  pour l'async (branche `isSummaryJob`) mais ne gère pas l'attente pour les visiteurs invités
  (aucun rafraîchissement automatique après completion). Existait avant Correction 2 sous une
  forme jamais exercée ; devient visible maintenant que `summarize()` est toujours async.
- Frontend : `JobPollingService`/`JobProgressComponent`/`jobs.component.ts` corrigés
  (`RUNNING` → `PROCESSING`, alignement sur l'enum backend réel — bug pré-existant jamais exercé
  tant que ce modèle ne servait qu'à la page "Traitements" des conversions). Nouveau
  `getPublicJob()` pour le polling anonyme. Bug latent corrigé au passage : `job.result` est une
  chaîne JSON (colonne `TEXT` côté backend), pas un objet déjà typé — `onJobCompleted()` dans les
  4 composants (et `document-detail.component.ts`, qui réutilise aussi ces services) le parse
  désormais avec `JSON.parse()`.
- Tests : `AiJobProcessorTest` (5, nouveaux — SUMMARY/TRANSLATION + transmission correcte de l'IP
  pour QNA/EXTRACTION), `AiJobServiceImplTest` (2, nouveaux), 3 nouveaux tests de contrôleur
  (Qna/Extraction/Translation/Summary, 8 au total), plus mise à jour du test d'intégration
  pré-existant `com.kovixel.ai.qna.QnaControllerTest` (au contrat 202 désormais, les tests
  d'erreurs métier — document introuvable/pas propriétaire — retirés car cette logique vit
  maintenant dans le job, pas testable au niveau contrôleur). Suite Vitest frontend : 2 tests
  pré-existants mis à jour pour refléter le nouveau contrat (plus de réponse synchrone,
  `job.result` en JSON string).
- **Vérification finale (2026-07-26)** : suite Maven complète — 1455 tests, 1 seul échec (le même
  `AuthControllerTest.refresh_missingCookie_returns401` pré-existant, sans rapport) ; `tsc --noEmit`
  et suite Vitest frontend (372+ tests) sans erreur liée à Correction 2 (10 échecs pré-existants
  confirmés sans rapport : intercepteurs, AuthService, page d'accueil — fichiers non touchés).

**Correction 3 — statut (2026-07-26) : implémentée, non vérifiée en conditions réelles.**
- **Statelessness vérifiée avant duplication** (tâche explicite de la roadmap) : sessions JWT
  sans état serveur (`SessionCreationPolicy.STATELESS`), quotas anonymes/rate-limit/blacklist de
  tokens tous adossés à Redis partagé (`AnonymousQuotaService`, `AuthRateLimitFilter`,
  `InvitationRateLimitFilter`, `CheckoutRateLimitFilter`, `TokenBlacklistService`) — aucun état
  local en mémoire trouvé qui aurait bloqué la duplication.
- `docker-compose.yml` : `kovixel-app` scindé en deux services `kovixel-app-1`/`kovixel-app-2`
  (config commune factorisée via une ancre YAML `&kovixel-app-common`, volume `uploads_data`
  partagé entre les deux — pas de split de stockage). Nouveau service `kovixel-lb` (Nginx,
  `docker/nginx-lb/nginx.conf`) : failover passif (`max_fails`/`fail_timeout` +
  `proxy_next_upstream`), transmet `X-Forwarded-For`/`X-Forwarded-Proto` (dont dépendent
  `ClientIpResolver` et le `forward-headers-strategy` du Sprint E-7).
  `kovixel-ui` (`API_URL`) et Prometheus (scrape par instance, pas via le LB, pour garder les
  métriques par réplique) mis à jour en conséquence.
- **Piège trouvé et corrigé en marge** : le propre Nginx embarqué de `kovixel-ui`
  (`kovixel-ui/docker/nginx.conf.template`, utilisé pour le routage `/api/*` dans son image
  Docker — indépendant de la variable `API_URL` du serveur SSR Node) avait aussi
  `server kovixel-app:8080` en dur. Sans cette correction, la suppression du service `kovixel-app`
  aurait cassé tout le routage API du frontend en silence.
- **Config Nginx statique plutôt qu'un service scalé** : Nginx open-source ne re-résout pas un
  nom DNS Docker à plusieurs IP dynamiquement en cours de fonctionnement — deux services nommés
  explicitement (`kovixel-app-1`/`-2`) dans l'upstream évitent ce piège, au prix de devoir éditer
  `docker/nginx-lb/nginx.conf` si le nombre de répliques change (acceptable à cette échelle ;
  revoir avec un vrai orchestrateur — Kubernetes, ECS — si le nombre de répliques doit devenir
  dynamique).
- **Non vérifié en conditions réelles** : aucun daemon Docker disponible dans cette session pour
  lancer `docker-compose up` et confirmer concrètement que l'arrêt d'une réplique reste invisible
  côté utilisateur — validation YAML (`docker-compose config`) et relecture manuelle de
  `nginx.conf` uniquement. **À vérifier avant mise en production** : `docker-compose up -d`,
  couper `kovixel-app-1` en pleine requête, confirmer qu'aucune erreur n'apparaît côté client et
  que Prometheus voit bien les deux instances (`up{job="kovixel-backend"}`).

## 5. Critères de sortie globaux

- [x] Pool de connexions PostgreSQL dimensionné et documenté (valeur justifiée, pas un défaut) —
  PostgreSQL `max_connections=200` (`docker-compose.yml`/`docker-compose.infra.yml`), Hikari
  `maximum-pool-size=60`/`minimum-idle=15` en prod (configurable via `DB_POOL_MAX_SIZE`/
  `DB_POOL_MIN_IDLE`), dimensionné pour jusqu'à 3 répliques applicatives sans dépasser le plafond
  serveur. Changement de configuration pur, aucun code applicatif touché, aucun test existant
  n'assertait sur l'ancienne valeur.
- [x] Endpoints IA rendus asynchrones, aucun thread HTTP bloqué sur un appel externe — résumé,
  Q&A, extraction, traduction soumettent tous un job (202 + jobId), polling via
  `GET /api/v1/jobs/{jobId}` (ou `/anonymous`). Limite connue : UX du rejet quota anonyme
  dégradée (message générique au lieu de la modal d'inscription), documentée ci-dessus.
- [~] Au moins 2 instances applicatives actives derrière un load balancer, statelessness
  confirmée — implémenté (`kovixel-app-1`/`kovixel-app-2` + `kovixel-lb`), non vérifié en
  conditions réelles faute de daemon Docker disponible dans cette session (voir détail ci-dessus).
- [ ] Un test de charge basique (k6 ou Gatling, quelques centaines d'utilisateurs simulés) exécuté
  après ces 3 corrections, pour remplacer l'estimation par une mesure réelle avant toute décision
  d'hébergement à grande échelle.

**Roadmap capacité initiale (Corrections 1 à 3) considérée complète** sous réserve de la
vérification Docker réelle de la Correction 3 (ci-dessus) et du test de charge final, qui
nécessitent tous deux un environnement d'exécution non disponible dans cette session.
