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

## 5. Critères de sortie globaux

- [ ] Pool de connexions PostgreSQL dimensionné et documenté (valeur justifiée, pas un défaut).
- [ ] Endpoints IA rendus asynchrones, aucun thread HTTP bloqué sur un appel externe.
- [ ] Au moins 2 instances applicatives actives derrière un load balancer, statelessness confirmée.
- [ ] Un test de charge basique (k6 ou Gatling, quelques centaines d'utilisateurs simulés) exécuté
  après ces 3 corrections, pour remplacer l'estimation par une mesure réelle avant toute décision
  d'hébergement à grande échelle.
