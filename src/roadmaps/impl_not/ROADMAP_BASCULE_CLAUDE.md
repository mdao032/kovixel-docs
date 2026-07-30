# Roadmap Bascule vers Claude — Abandon d'Ollama en production

> **Statut :** Proposition technique v1.0
> **Date :** 2026-07-27
> **Audience :** Équipe backend, direction (impact coût direct)
> **Portée :** Remplace l'architecture IA locale (Ollama, `qwen3` + `nomic-embed-text`) par une
> architecture 100% API cloud (Claude pour la génération, un fournisseur d'embeddings cloud pour
> le RAG). Ne modifie ni `ROADMAP_CHIFFREMENT.md` ni `ROADMAP_CAPACITE_INITIALE.md`, mais en
> dépend : cette bascule réduit mécaniquement la charge que la Correction 3 (répliques + load
> balancer) doit absorber, puisqu'elle retire un composant CPU/RAM lourd (Ollama) du serveur.

---

## Table des matières

1. [Contexte et décision](#1-contexte-et-décision)
2. [État des lieux — ce qu'Ollama fait réellement aujourd'hui](#2-état-des-lieux--ce-quollama-fait-réellement-aujourdhui)
3. [Analyse financière](#3-analyse-financière)
4. [Architecture cible](#4-architecture-cible)
5. [Roadmap par sprints](#5-roadmap-par-sprints)
6. [Migration du schéma vectoriel](#6-migration-du-schéma-vectoriel)
7. [Filet de sécurité financier](#7-filet-de-sécurité-financier)
8. [Décisions d'architecture (ADR)](#8-décisions-darchitecture-adr)
9. [Risques et mitigations](#9-risques-et-mitigations)
10. [Critères de sortie](#10-critères-de-sortie)

---

## 1. Contexte et décision

Kovixel utilise aujourd'hui Ollama (modèles `qwen3:7b`/`qwen3:1.7b` pour la génération,
`nomic-embed-text` pour les embeddings RAG) comme moteur IA par défaut pour **100% du trafic
gratuit et anonyme**, Claude n'étant sollicité que par les utilisateurs payants ayant explicitement
opté pour le mode `CLOUD` (`ProcessingMode.CLOUD`, consentement RGPD requis,
`User.processingModeConsentAt`).

Ce choix (documenté dans `OLLAMA_QWEN_ROADMAP.md`) reposait sur deux arguments empilés :
1. **RGPD/marketing** : "vos données ne quittent jamais notre infrastructure" — un différenciateur
   concurrentiel explicite face à SmallPDF/iLovePDF (qui envoient tout à OpenAI).
2. **Coût à grande échelle** : au-delà d'environ 50 000 résumés/jour, un GPU auto-hébergé devient
   moins cher que l'API Claude payée au token (analyse chiffrée dans le roadmap Ollama d'origine).

**Ce qui a changé** : l'examen des options d'hébergement GPU (dédié, ou à la demande via un
service tiers type RunPod) a révélé que faire tourner Ollama en production nécessite soit un VPS
CPU (débit d'inférence trop faible pour un usage concurrent réel dès quelques dizaines
d'utilisateurs simultanés), soit un GPU tiers — qui **casse déjà** l'argument n°1 ("ne quitte
jamais notre infra", puisque les données transitent par l'infrastructure GPU d'un tiers pour le
calcul). Une fois cet argument neutralisé, il ne reste que l'argument n°2 — qui ne s'applique pas
avant 50 000 résumés/jour, un ordre de grandeur très supérieur au volume de lancement réel.

**Décision** : abandonner Ollama en production, migrer 100% de la génération vers Claude (avec un
choix de modèle par plan tarifaire pour maîtriser le coût, cf. §4), et adopter un fournisseur
d'embeddings cloud pour le pipeline RAG (Claude n'ayant pas d'API d'embeddings — vérifié, aucune
n'existe chez Anthropic à ce jour). Le retour à un modèle auto-hébergé reste possible plus tard, si
le volume réel approche le seuil de rentabilité identifié dans le roadmap Ollama d'origine — cette
bascule n'est pas présentée comme irréversible, seulement comme la bonne option au stade actuel.

---

## 2. État des lieux — ce qu'Ollama fait réellement aujourd'hui

*(À reconfirmer précisément avant implémentation — les références ci-dessous proviennent d'une
revue de code menée pendant la préparation de ce document, pas d'une lecture exhaustive ligne à
ligne de chaque fichier.)*

| Composant | Rôle actuel | Fichier |
|---|---|---|
| `AiRoutingService.resolve(userId)` | Route vers Ollama pour : anonymes (`qwen3:1.7b`), plan FREE (`qwen3:7b`, jamais Claude), et plans payants en mode `LOCAL` (défaut). Ne route vers Claude que si `processingMode == CLOUD` — avec **fallback automatique vers Ollama** si l'appel Claude échoue. | `com.kovixel.ai.routing.AiRoutingService` |
| `ProcessingMode` (enum `LOCAL`/`CLOUD`) | Porté par `User.processingMode` (défaut `LOCAL`) + `User.processingModeConsentAt`. Bascule vers `CLOUD` interdite pour FREE, exige un consentement explicite enregistré (`UserServiceImpl`). | `com.kovixel.user.entity.User`, `ProcessingMode` |
| `EmbeddingModel` (Spring AI) | Fournit les embeddings du pipeline RAG — utilisé uniquement par `QnaServiceImpl` et `DocumentIngestionService` (résumé/extraction/traduction ne dépendent PAS des embeddings). Configuré sur `nomic-embed-text` via Ollama, 768 dimensions. | `QnaServiceImpl`, `DocumentIngestionService` |
| Schéma pgvector | `vector_store`/`document_chunks` en `vector(768)`, index HNSW — câblé en dur sur ce format par une migration destructive antérieure. | `V17__local_embeddings_migration.sql` |
| `ClaudeAiService` | Implémente déjà `AiProviderService` (`summarize()`, `generateResponse()`) — c'est le point d'intégration Claude existant, à généraliser plutôt qu'à recréer. | `com.kovixel.ai.claude.ClaudeAiService` *(nom de package à confirmer)* |
| `docker-compose.yml` | Services `ollama` + `ollama-puller` (téléchargement des modèles au démarrage). | `kovixel/docker-compose.yml` |
| **Piste à vérifier avant de choisir un fournisseur d'embeddings** | Un commentaire dans `application-prod.yml` ("Ne jamais réactiver l'embedding OpenAI (1536d) sans une nouvelle migration de schéma correspondante") suggère qu'**un chemin d'intégration OpenAI embeddings a peut-être déjà existé dans le code avant la migration V17 vers Ollama** — à vérifier en premier (historique git, dépendances Spring AI déjà présentes dans `pom.xml`) avant d'intégrer un nouveau fournisseur (Voyage AI) depuis zéro : réactiver un chemin dormant est moins de travail que d'en construire un nouveau. | — |

---

## 3. Analyse financière

Estimation à un volume de lancement (~500 utilisateurs actifs/jour, ~150 utilisateurs déclenchant
une action IA/jour) — hypothèses détaillées, à ajuster avec de la télémétrie réelle dès qu'elle
existe :

| Action | Volume/jour | Coût unitaire (Haiku 4.5) | Coût/jour |
|---|---|---|---|
| Résumé | 100 | ~0,0055 $ | 0,55 $ |
| Q&A (par question) | 300 | ~0,0025 $ | 0,75 $ |
| Extraction | 50 | ~0,0040 $ | 0,20 $ |
| Traduction | 30 | ~0,0120 $ | 0,36 $ |
| **Total génération** | | | **~1,86 $/jour → ~56 $/mois** |
| Embeddings (Voyage/OpenAI, ~0,02 $/M tokens) | ~0,5M tokens/jour | | **< 1 $/mois** |

Avec Sonnet 4.6 (qualité supérieure, ~3x le prix de Haiku) au lieu de Haiku partout :
**~170 $/mois** au même volume.

**Plafond du pire cas** (quota FREE actuel — 10 conversions/24 résumés/10 Q&A par jour et par
utilisateur — saturé par tous les utilisateurs gratuits, hypothèse déjà pessimiste) : de l'ordre
de **150 à 800 $/mois**, borné, jamais illimité. Voir §7 pour le mécanisme qui garantit ce plafond
en pratique, pas seulement en théorie.

**Comparaison** : un VPS GPU dédié (ou un service à la demande type RunPod) pour faire tourner
Ollama à ce volume coûterait significativement plus cher qu'un budget de 56-170 $/mois, en plus de
la complexité opérationnelle (cold start, gestion de modèle, casse déjà l'argument RGPD "100%
local"). Le point de bascule vers un modèle auto-hébergé reste ~50 000 résumés/jour
(cf. `OLLAMA_QWEN_ROADMAP.md`), très supérieur au volume de lancement.

---

## 4. Architecture cible

- **Génération** : Claude pour 100% des utilisateurs (anonymes, FREE, payants) — plus de
  distinction `LOCAL`/`CLOUD` par plan. Répartition suggérée par modèle :
  - Anonymes + FREE → **Haiku 4.5** (coût maîtrisé, volume potentiellement élevé et non garanti
    de convertir).
  - PRO/PRO_PLUS/TEAM/ENTERPRISE → **Sonnet 4.6** (qualité supérieure, justifiée par le revenu
    associé).
  - Le choix du modèle par plan doit rester configurable (`application.yml`), pas câblé en dur —
    pour pouvoir l'ajuster sans redéploiement si le ratio coût/conversion évolue.
- **Embeddings (RAG)** : un fournisseur cloud à choisir entre Voyage AI (`voyage-4-lite`,
  0,02 $/M tokens, 200M tokens gratuits à l'inscription, partenaire recommandé par Anthropic) et
  OpenAI (`text-embedding-3-small`, même prix) — **décision conditionnée à la vérification du
  point "chemin OpenAI dormant" du §2** avant de choisir.
- **Suppression** : services `ollama`/`ollama-puller` du `docker-compose.yml`, dépendance au
  modèle local dans `AiRoutingService`, champ `ProcessingMode`/`processingModeConsentAt` (ou
  conservation en `@Deprecated` le temps de la transition — cf. Sprint C-2).
- **Filet de sécurité** : limite de dépense dure côté console Anthropic (cf. §7), pas une option
  facultative — condition de mise en production de cette bascule.

---

## 5. Roadmap par sprints

### Sprint C-1 — Migration des embeddings vers un fournisseur cloud — TERMINÉ 2026-07-27

**Confirmation ADR-C2** : le chemin OpenAI embeddings était bien dormant, pas à construire —
dépendance `spring-ai-starter-model-openai` déjà présente dans `pom.xml`, config déjà préparée
(`spring.ai.openai.embedding.enabled: false`, commentaire explicite "ne jamais réactiver sans
nouvelle migration"). Réactivé plutôt qu'intégré Voyage AI depuis zéro, comme anticipé.

- Migration `V75__migrate_embeddings_to_openai.sql` — miroir exact inverse de `V17` (768→1536
  au lieu de 1536→768), même procédure (purge index/chunks, ré-ingestion via `ingested=false`).
- `application.yml`/`application-dev.yml`/`application-prod.yml` : `spring.ai.openai.embedding.enabled: true`
  (modèle `text-embedding-3-small`), `spring.ai.ollama.*` commenté (pas supprimé — réservé au
  Sprint C-4 pour limiter le diff de ce sprint au strict changement d'embeddings),
  `vectorstore.pgvector.dimensions: 1536`.
- Le flag mort `kovixel.ai.ollama.local-embeddings-enabled` (`OllamaProperties`, jamais lu ailleurs
  dans le code) laissé tel quel — nettoyage cosmétique reporté au Sprint C-4.
- Aucun test n'était couplé à la dimension d'embedding (768) ou à `EmbeddingModel` directement —
  aucune adaptation de test nécessaire.
- **Vérification** : suite complète Maven — 1455 tests, 1 seul échec (le même
  `AuthControllerTest.refresh_missingCookie_returns401` pré-existant, sans rapport).

### Sprint C-1 (détail original)

**Objectif :** remplacer `nomic-embed-text`/Ollama par un fournisseur cloud, sans changer le
pipeline RAG lui-même (`QnaServiceImpl`, `DocumentIngestionService` restent inchangés au-delà de
la configuration `EmbeddingModel`).

**Tâches :**
- Vérifier le chemin OpenAI embeddings dormant évoqué au §2 (historique git autour de la migration
  V17, dépendances Spring AI dans `pom.xml`) — réactiver s'il existe plutôt que d'intégrer Voyage
  AI depuis zéro.
- Choisir la dimension du nouveau modèle d'embedding (1536 pour OpenAI `text-embedding-3-small`,
  autre valeur pour Voyage — à vérifier dans leur documentation au moment de l'implémentation) et
  écrire une migration Flyway destructive (même schéma que V17) : `ALTER COLUMN embedding TYPE
  vector(N)`, suppression des index HNSW existants (dimension incompatible), recréation après
  migration des données.
- Marquer tous les documents `ingested=false` pour forcer une ré-ingestion complète (même
  mécanisme que V17).
- Adapter `application.yml`/`application-prod.yml` (`spring.ai.<provider>.embedding.*` au lieu de
  `spring.ai.ollama.embedding.*`).
- Tests : `DocumentIngestionServiceTest`/`QnaServiceImplTest` existants doivent continuer de
  passer avec le nouveau `EmbeddingModel` mocké de la même façon (l'interface Spring AI
  `EmbeddingModel` ne change pas, seule l'implémentation sous-jacente change).

**Risque principal** : le volume de tokens à ré-embedder dépend du nombre de documents déjà
ingérés en base — à chiffrer avant de lancer la migration (coût ponctuel, pas récurrent, mais à
ne pas découvrir après coup).

### Sprint C-2 — Généralisation de Claude pour la génération — TERMINÉ 2026-07-27

- **Rayon d'impact réel plus large qu'anticipé** : 25 fichiers référençaient
  `AiRoutingService`/`ProcessingMode` (cartographie complète faite avant modification) — dont un
  endpoint REST authentifié (`PUT /me/processing-mode`), la logique de consentement RGPD
  associée (`UserServiceImpl.updateProcessingMode`, FREE interdit CLOUD/consentement requis pour
  CLOUD), deux colonnes d'entité (`processing_mode`, `processing_mode_consent_at`), et un usage
  collatéral dans `OcrEngineFactory` (choix Tesseract vs Claude Vision) qui n'a rien à voir avec
  Ollama — découplé du routing de génération plutôt que supprimé (Tesseract reste pertinent :
  pas de GPU, pas de coût, aucune des raisons ayant motivé l'abandon d'Ollama).
- `AiRoutingService` : Haiku (anonyme/FREE) / Sonnet (PRO/PRO_PLUS/TEAM/ENTERPRISE), plus de
  fallback. `ClaudeAiService.forModel(String)` ajouté (même convention que l'ancien
  `OllamaAiService.forModel()`) — sélectionne le modèle par appel via
  `AnthropicChatOptions.builder().model(...)`, sans dupliquer de bean `ChatClient`.
- `AiRoutingDecision` simplifié (record à 3 champs, `processingMode`/`isLocal()` retirés).
  `ProcessingMode` (enum), `OllamaAiService`, `OllamaHealthIndicator`, `ProcessingModeRequest`
  supprimés. `OllamaHealthChecker`/`OllamaProperties` laissés tels quels (non consommés ailleurs,
  suppression complète reportée au Sprint C-4 pour ne pas élargir davantage ce sprint).
- Migration `V76__drop_processing_mode.sql` — retire les 2 colonnes de `kovixel_users`.
- Frontend : `AiEngineInfo`/`AiEngineInfoResponse` simplifiés en tandem (plus de champ
  `processingMode`/`local`) — aucune UI ne consommait l'endpoint de bascule LOCAL/CLOUD (jamais
  câblé côté frontend), donc pas de composant à retirer au-delà du modèle.
- Tests : `AiRoutingServiceTest` réécrit intégralement (nouvelle logique, plus de fallback),
  `OllamaAiServiceTest` supprimé (classe testée n'existe plus), `AiHistoryServiceImplTest`/
  `SummaryStrategyTest` adaptés (constructeur `AiRoutingDecision` à 3 arguments).
- **Vérification** : suite Maven complète (1443 tests, 1 seul échec pré-existant sans rapport),
  `tsc --noEmit` et suite Vitest frontend (372 tests, mêmes 10 échecs pré-existants confirmés
  sans rapport) sans régression.

### Sprint C-2 (détail original)

**Objectif :** faire disparaître la distinction `LOCAL`/`CLOUD` — Claude devient le seul chemin de
génération, pour tous les plans.

**Tâches :**
- `AiRoutingService.resolve(userId)` : simplifier pour retourner directement le modèle Claude
  approprié au plan (Haiku pour anonyme/FREE, Sonnet pour le reste), supprimer la branche Ollama
  et le fallback associé.
- Décider du sort de `ProcessingMode`/`processingModeConsentAt` : soit suppression complète
  (migration Flyway retirant la colonne — vérifier qu'aucune fonctionnalité produit n'en dépend
  encore ailleurs), soit conservation en `@Deprecated` sans effet le temps de valider qu'aucun
  appelant externe (mobile, intégration future) ne s'y fie.
- `ClaudeAiService` (déjà existant) : vérifier qu'il supporte bien la sélection de modèle
  (Haiku vs Sonnet) par paramètre plutôt qu'un modèle unique câblé en dur.
- Mettre à jour la documentation Swagger/OpenAPI des endpoints IA si elle mentionne le mode
  `LOCAL`/`CLOUD`.

### Sprint C-3 — Filet de sécurité financier — TERMINÉ 2026-07-27

- **Découverte et correction d'un vrai trou de sécurité financière** : `TranslationServiceImpl`
  n'avait **aucun plafond de volume quotidien** pour les utilisateurs authentifiés — seul le
  nombre de pages par requête était borné (`PAGE_LIMIT_FREE=20`). `QuotaService` n'était même pas
  injecté dans la classe. Avant Claude (quand la traduction passait par Ollama, coût marginal
  nul), ce n'était pas un problème ; désormais chaque traduction coûte un appel Claude réel, un
  utilisateur FREE authentifié pouvait déclencher un nombre illimité de traductions par jour.
  Corrigé : `PlanConfig.maxTranslationsPerDay` ajouté (FREE=5, PRO=100, PRO_PLUS=500,
  TEAM/ENTERPRISE=illimité — alignés sur les autres fonctionnalités IA du même plan),
  `TranslationServiceImpl` vérifie désormais `quotaService.checkAndIncrementQuota(userId,
  FeatureType.TRANSLATION)` pour les utilisateurs authentifiés (même schéma que Qna/
  ExtractionServiceImpl). Confirmé au passage que Qna/ExtractionServiceImpl transmettent déjà
  correctement `clientIp` via le payload du job async (Correction 2) — pas de régression là.
- `ClaudeMetrics` (nouveau, `com.kovixel.ai.provider`) : compteurs Micrometer
  `kovixel.ai.claude.calls`/`kovixel.ai.claude.errors{type}`. `ClaudeAiService.classifyError()`
  distingue `quota_exceeded` (mots-clés "credit balance"/"spend limit"/"budget" dans le corps de
  réponse HTTP), `rate_limit` (429), `server_error` (5xx/overloaded), `client_error`, `other` —
  classification tolérante par mots-clés (Spring AI n'expose pas de type d'exception Anthropic
  dédié), le comportement dégradé (503 générique) reste identique quelle que soit la
  classification, qui n'alimente que la métrique.
- Nouvelle alerte Prometheus `ClaudeBudgetExceeded` (`docker/prometheus/alerts.yml`) —
  `increase(kovixel_ai_claude_errors_total{type="quota_exceeded"}[10m]) > 0` — signal précoce
  avant qu'un utilisateur ne remonte une erreur.
- **Limite de dépense dure côté console Anthropic** : action manuelle hors périmètre de ce repo
  (aucune API pour l'automatiser) — reste la condition de mise en production de cette roadmap,
  documentée en §7, à réaliser par l'équipe avant l'ouverture au public.
- Tests : `ClaudeAiServiceTest` (6, classification d'erreur — la chaîne fluente `ChatClient`
  elle-même n'est pas mockée, jugé disproportionné, cf. leçon `ROADMAP_CAPACITE_INITIALE.md`
  Correction 2 sur les tests d'intégration fragiles), `TranslationServiceImplTest` (3, nouveau —
  premier test unitaire de cette classe, ciblé sur le point de contrôle quota).
- **Vérification finale (2026-07-27)** : suite complète — 1452 tests, 1 seul échec pré-existant
  sans rapport.

### Sprint C-3 (détail original)

**Objectif :** rendre le plafond de dépense réel, pas seulement théorique (cf. §7).

**Tâches :**
- Configurer une limite de dépense dure sur la console Anthropic (montant à définir avec la
  direction — pas une tâche technique, une décision produit).
- Vérifier le comportement de l'application quand l'API Claude refuse une requête pour cause de
  plafond atteint (code d'erreur spécifique Anthropic) — doit dégrader proprement (message
  utilisateur clair), pas planter ou boucler en retry.
- Ajouter une métrique/alerte (Prometheus, déjà en place depuis `RESILIENCE_ROADMAP.md` Phase 2)
  sur le taux d'erreurs "quota Anthropic dépassé" — signal d'alerte précoce avant que ça devienne
  visible pour les utilisateurs.
- Revoir les quotas FREE actuels (`10/j conversions, 5/j résumés IA, 10/j Q&A` d'après la page
  d'accueil) à la lumière du coût réel désormais chiffré — resserrer si le pire cas calculé (§3)
  dépasse ce que l'activité peut absorber sans conversion payante.

### Sprint C-4 — Nettoyage infrastructure et marketing — TERMINÉ 2026-07-30

**Objectif :** retirer ce qui n'est plus utilisé, aligner la promesse produit sur la réalité.

**Réalisé :**
- Services `ollama`/`ollama-puller` retirés de `docker-compose.yml` et `docker-compose.infra.yml`
  (services, `depends_on`, volume `ollama_data`) ; répertoire `docker/ollama/` supprimé.
- Variables `OLLAMA_URL`/`OLLAMA_MODEL`/`OLLAMA_EMBEDDING_MODEL` retirées des deux `.env.example`
  (kovixel/ et racine) et des configs Spring (`application.yml`, `application-dev.yml` —
  y compris un second bloc `kovixel.ai.ollama`/`models` obsolète oublié au Sprint C-2 avec
  d'anciens noms de propriété `anonymous/free/pro/enterprise` —, `application-prod.yml`).
- `OllamaHealthChecker`/`OllamaProperties` (morts depuis le Sprint C-2, plus aucun consommateur)
  et leur test supprimés.
- Références Ollama obsolètes nettoyées dans une dizaine de javadocs/commentaires backend
  (`DocumentIngestionService`, `QnaServiceImpl`, `AiProviderService`, `SummaryResponse`, `Summary`,
  `SummaryPromptBuilder`, `SpringAiConfig`, `HealthStatusMetrics`, `OcrTextEnhancer`, `OcrStrategy`,
  `GeminiService`) — cosmétique, aucun changement de comportement.
- Frontend : entrée `ollama` retirée de `ai-engine-badge.component.ts` (badge partagé),
  `summary.component.ts` (map de métadonnées moteur), `summary.model.ts` (type `engine`) et
  `tools-config.ts` (texte marketing + mots-clés de recherche) ; règles CSS `.engine-badge-ollama`
  mortes retirées de `styles.css` ; test Vitest correspondant mis à jour (`gemini` au lieu
  d'`ollama`).
- Aucune promesse marketing "100% local" trouvée sur la landing page (`trust-section.component.ts`
  n'affirme qu'une conformité RGPD générique, déjà honnête) — condition de sortie déjà satisfaite,
  pas de changement de copy nécessaire.
- `DPIA_ANALYSE_IMPACT_VIE_PRIVEE.md` et `REGISTRE_TRAITEMENTS.md` mis à jour : la fiche
  "Analyse IA des documents" reflète désormais Claude (génération) + OpenAI (embeddings RAG) comme
  sous-traitants, base légale passée de "consentement explicite" (choix local/cloud) à "exécution
  du contrat" (plus de mode local alternatif) ; le droit d'opposition basé sur `ProcessingMode.LOCAL`
  a été marqué retiré (champ supprimé du code au Sprint C-2).

**Tâches :**
- Retirer les services `ollama`/`ollama-puller` de `docker-compose.yml` (et de
  `docker-compose.infra.yml` si présents).
- Retirer les variables d'environnement associées (`OLLAMA_URL`, `OLLAMA_MODEL`,
  `OLLAMA_EMBEDDING_MODEL`) des fichiers de config et `.env.example`.
- Revoir la mention "100% local"/RGPD native sur la landing page
  (`kovixel-ui/src/app/features/home/trust-section.component.ts` et ailleurs) — remplacer par une
  formulation honnête sur la localisation réelle des traitements (ex. si le fournisseur
  d'embeddings/Claude a des engagements de traitement de données conformes RGPD sans pour autant
  être "sur notre propre infrastructure").
- Mettre à jour `DPIA_ANALYSE_IMPACT_VIE_PRIVEE.md` et `REGISTRE_TRAITEMENTS.md`
  (`kovixel-docs/src/compliance/`) : la fiche "Analyse IA des documents" doit refléter le nouveau
  sous-traitant (Anthropic + fournisseur d'embeddings) au lieu du traitement local — c'est un
  changement de base légale/sous-traitance qui doit être documenté, pas juste un détail technique.

---

## 6. Migration du schéma vectoriel

À détailler précisément au moment du Sprint C-1 (dimension exacte selon le fournisseur choisi),
mais le schéma général suit le précédent `V17__local_embeddings_migration.sql` :

1. Sauvegarde de la base avant migration (une migration destructive de colonne vectorielle n'est
   pas réversible sans backup).
2. `ALTER TABLE document_chunks DROP COLUMN embedding` (l'ancienne dimension 768 est incompatible
   avec toute nouvelle dimension) — ou création d'une nouvelle colonne en parallèle le temps de la
   transition si une bascule progressive sans interruption est préférée à un big-bang.
3. Suppression puis recréation des index HNSW sur la nouvelle colonne.
4. `documents.ingested = false` sur toutes les lignes → re-déclenche l'ingestion via le mécanisme
   `AiJobType.INGEST` déjà existant (`AiJobProcessor.handleIngest`, ROADMAP_CAPACITE_INITIALE.md
   Correction 2) — profite de l'infrastructure de jobs asynchrones déjà en place, pas besoin d'un
   nouveau mécanisme de ré-ingestion en masse.

---

## 7. Filet de sécurité financier

Reprend directement l'inquiétude soulevée pendant la préparation de cette roadmap : que se
passe-t-il si l'usage grossit sans que les abonnements/la publicité suivent ?

1. **Le coût est un coût variable, borné par les quotas existants** — pas un engagement fixe. Le
   pire cas calculable (§3) n'est jamais illimité tant que les quotas FREE restent en place et
   correctement dimensionnés.
2. **La limite de dépense dure côté Anthropic est la condition de mise en production** de cette
   roadmap, pas une amélioration optionnelle — une fois le plafond atteint, l'API refuse les
   appels plutôt que de continuer à facturer.
3. **Le comportement dégradé doit être testé explicitement** (Sprint C-3) : un refus de l'API
   Claude pour cause de plafond ne doit jamais se traduire par une erreur 500 générique côté
   utilisateur, mais par un message clair ("service temporairement indisponible").
4. **Option de repli plus radicale, si nécessaire** : lancer sans plan gratuit IA du tout (accès
   restreint/liste d'attente), valider la conversion payante d'abord, ouvrir le FREE ensuite une
   fois que les premiers abonnements couvrent le coût. Hors périmètre technique de cette roadmap
   (décision produit), mais mentionné ici car directement lié au risque financier documenté.

---

## 8. Décisions d'architecture (ADR)

### ADR-C1 : Claude pour 100% de la génération, plus de distinction LOCAL/CLOUD

**Contexte** : le mode `LOCAL` (Ollama) existait pour garantir qu'aucune donnée ne quitte
l'infrastructure Kovixel — un argument RGPD/marketing, pas seulement technique.

**Décision** : abandonner cette distinction, router tout le monde vers Claude.

**Raisons** : l'argument "ne quitte jamais notre infra" ne tenait déjà plus dès qu'un GPU tiers
(RunPod ou équivalent) devenait nécessaire pour faire tourner Ollama à un débit acceptable en
production. Le second argument (coût à grande échelle) ne s'applique qu'au-delà de ~50 000
résumés/jour — très supérieur au volume actuel. Réversible : si le volume approche ce seuil,
réintroduire un mode auto-hébergé redevient une option, pas une nécessité immédiate.

### ADR-C2 : Fournisseur d'embeddings — vérifier l'existant avant d'en choisir un nouveau

**Contexte** : Claude n'a pas d'API d'embeddings (vérifié — Anthropic recommande Voyage AI comme
partenaire, ne propose rien en natif). Le pipeline RAG a donc besoin d'un fournisseur distinct de
Claude, quel que soit le choix fait pour la génération.

**Décision** : avant d'intégrer Voyage AI (ou tout autre fournisseur) depuis zéro, vérifier si un
chemin OpenAI embeddings existe déjà en dormant dans le code (indice : commentaire dans
`application-prod.yml` mentionnant explicitement ce cas). Réactiver un chemin existant coûte moins
cher en développement qu'en construire un nouveau.

**Raisons** : cohérent avec la discipline déjà établie sur ce projet (toujours vérifier l'état réel
du code avant d'implémenter, cf. corrections apportées à `ROADMAP_CHIFFREMENT.md` v1.0 avant son
implémentation).

### ADR-C3 : Migration destructive plutôt que double-écriture progressive

**Contexte** : changer de fournisseur d'embeddings change la dimension du vecteur stocké — les
anciens embeddings (768d, Ollama) sont incompatibles avec le nouveau format.

**Décision** : suivre le précédent `V17` (migration destructive : purge + ré-ingestion complète)
plutôt qu'une double-écriture progressive (garder les deux colonnes le temps de la transition).

**Raisons** : la ré-ingestion est déjà automatisée via l'infrastructure de jobs asynchrones
(`AiJobType.INGEST`), le volume de documents à re-traiter est un coût ponctuel identifiable avant
la migration (pas un risque caché), et une double-écriture ajouterait de la complexité transitoire
pour un bénéfice marginal (le service RAG peut tolérer une fenêtre de ré-ingestion, les documents
existants restent consultables, seul le Q&A sur un document pas encore ré-ingéré serait
temporairement indisponible — acceptable pour ce volume).

---

## 9. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Volume de ré-ingestion sous-estimé (coût ponctuel Sprint C-1) | Facture ponctuelle plus élevée que prévu | Chiffrer le nombre de documents/chunks existants avant de lancer la migration, pas après |
| Chemin OpenAI dormant inexistant (ADR-C2 invalidée) | Sprint C-1 plus long que prévu (nouvelle intégration Voyage AI depuis zéro) | Vérification en tout premier, avant tout autre travail du sprint — n'engage aucun coût si elle échoue tôt |
| Dérive de coût malgré les quotas (usage réel très différent des hypothèses §3) | Dépense mensuelle imprévue | Limite de dépense dure Anthropic (§7) — filet de sécurité indépendant de la justesse des hypothèses |
| Régression qualité perçue (Haiku moins bon que qwen3:7b sur certains cas) | Insatisfaction utilisateurs FREE | Comparer qualitativement Haiku vs l'ancien Ollama sur un échantillon de documents réels avant bascule complète, ajuster vers Sonnet pour FREE si nécessaire (impact coût à recalculer) |
| Promesse marketing "100% local" désormais fausse si non corrigée | Risque de communication trompeuse | Sprint C-4 traite explicitement ce point — condition de sortie, pas une tâche optionnelle |

---

## 10. Critères de sortie

- [ ] Fournisseur d'embeddings choisi et intégré (Sprint C-1), migration Flyway destructive
  exécutée, ré-ingestion complète confirmée (aucun document bloqué en `ingested=false` de façon
  permanente).
- [ ] `AiRoutingService` simplifié — un seul chemin de génération (Claude), plus de dépendance à
  Ollama dans le code applicatif (Sprint C-2).
- [ ] Limite de dépense dure configurée côté Anthropic, comportement dégradé testé et confirmé
  propre (Sprint C-3).
- [ ] Services `ollama`/`ollama-puller` retirés de l'infrastructure, variables d'environnement
  associées nettoyées (Sprint C-4).
- [ ] Mention marketing "100% local" révisée sur la landing page, `DPIA`/`REGISTRE_TRAITEMENTS`
  mis à jour pour refléter le nouveau sous-traitant IA (Sprint C-4).
- [ ] Suite de tests complète (backend + frontend) sans régression après chaque sprint, suivant la
  discipline déjà établie sur ce projet (compilation, tests ciblés, suite complète, aucune
  régression silencieuse).
