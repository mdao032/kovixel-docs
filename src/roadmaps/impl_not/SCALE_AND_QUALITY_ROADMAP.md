# Kovixel — Feuille de route Scalabilité & Qualité Concurrentielle

> **Objectif :** Faire de Kovixel un concurrent crédible et supérieur à iLovePDF, Smallpdf, Adobe Acrobat, DocuSign et Notion AI sur les marchés européens, en combinant qualité d'exécution, fiabilité enterprise et différenciation IA.

---

## Table des matières

1. [Benchmark concurrentiel actuel](#1-benchmark-concurrentiel-actuel)
2. [Phase 1 — Fondations solides](#2-phase-1--fondations-solides-1-2-mois) *(1–2 mois)*
3. [Phase 2 — Scalabilité horizontale](#3-phase-2--scalabilité-horizontale-2-4-mois) *(2–4 mois)*
4. [Phase 3 — Différenciation produit](#4-phase-3--différenciation-produit-4-6-mois) *(4–6 mois)*
5. [Phase 4 — Grade Enterprise](#5-phase-4--grade-enterprise-6-12-mois) *(6–12 mois)*
6. [Phase 5 — Innovation IA](#6-phase-5--innovation-ia-12-mois) *(12 mois+)*
7. [Métriques de succès](#7-métriques-de-succès)
8. [Matrice risques / effort](#8-matrice-risques--effort)

---

## 1. Benchmark concurrentiel actuel

| Dimension | Kovixel aujourd'hui | iLovePDF | Smallpdf | Adobe Acrobat | Notion AI |
|---|---|---|---|---|---|
| Outils PDF de base | ✓ Complets | ✓ Complets | ✓ Complets | ✓ Complets | ✗ |
| IA intégrée (résumé, Q&A) | ✓ Différenciant | ✗ | Partiel | Partiel | ✓ |
| E-signature légale | ✓ PAdES-B | Via tiers | Via tiers | Adobe Sign (€€) | ✗ |
| API publique | ✗ | ✓ | ✓ | ✓ | ✓ |
| Intégrations (Drive, Zapier) | ✗ | Partiel | ✓ | ✓ | ✓ |
| SSO / SAML | ✗ | ✗ | ✓ | ✓ | ✓ |
| Circuit breakers / résilience | ✗ | N/A | N/A | N/A | N/A |
| Multi-région | ✗ | ✓ | ✓ | ✓ | ✓ |
| Collaboration temps réel | ✗ | ✗ | ✓ | ✓ | ✓ |
| Mobile app native | ✗ | ✓ | ✓ | ✓ | ✓ |
| SOC 2 / ISO 27001 | ✗ | ✓ | ✓ | ✓ | ✓ |

**Conclusion :** Kovixel est déjà supérieur sur l'IA et la signature. Les lacunes critiques sont la résilience backend, les intégrations, l'API publique et la certification de sécurité.

---

## 2. Phase 1 — Fondations solides *(1–2 mois)*

> Ces items éliminent des risques de production immédiats et sont prérequis à tout scaling.

### 2.1 Circuit Breakers sur toutes les dépendances externes

**Pourquoi :** Sans circuit breaker, une panne de Gotenberg, Adobe ou Claude remplit les 200 threads Tomcat en 90 secondes et coupe l'application entière. iLovePDF et Smallpdf ont des SLA > 99,9 %.

**Ce qui est concerné :** Gotenberg, Adobe PDF Services, Claude API, Ollama, OpenAI, Brevo SMTP.

**Implémentation :**
```xml
<!-- pom.xml — version explicite requise : Spring Boot BOM ne gère pas Resilience4j -->
<dependency>
  <groupId>io.github.resilience4j</groupId>
  <artifactId>resilience4j-spring-boot3</artifactId>
  <version>2.2.0</version>
</dependency>
```

```yaml
# application.yml
resilience4j.circuitbreaker:
  instances:
    gotenberg:
      slidingWindowSize: 10
      failureRateThreshold: 50
      waitDurationInOpenState: 30s
      permittedNumberOfCallsInHalfOpenState: 3
    adobe:
      slidingWindowSize: 5
      failureRateThreshold: 60
      waitDurationInOpenState: 60s
    claude:
      slidingWindowSize: 20
      failureRateThreshold: 40
      waitDurationInOpenState: 15s
    ollama:
      slidingWindowSize: 5
      failureRateThreshold: 80
      waitDurationInOpenState: 10s
```

**Critères d'acceptation :**
- [ ] `@CircuitBreaker(name = "gotenberg", fallbackMethod = "fallbackConversion")` sur tous les appels Gotenberg
- [ ] `@CircuitBreaker(name = "claude")` sur tous les appels LLM (résumé, Q&A, traduction)
- [ ] Endpoint `/actuator/health` expose l'état de chaque circuit breaker
- [ ] Test : simuler Gotenberg down → les autres outils continuent de fonctionner
- [ ] Métriques circuit breaker disponibles dans Prometheus (`resilience4j_circuitbreaker_state`)

---

### 2.2 Q&A et Traduction passent en asynchrone

**Pourquoi :** Un appel LLM Claude dure 10–30 secondes. En mode synchrone, 20 utilisateurs simultanés sur Q&A consomment 20 threads Tomcat pendant 20s chacun. À 200 utilisateurs, saturation. Le pattern `@Async` + polling est déjà en place pour l'OCR et le résumé — l'appliquer aux deux outils restants.

**Fichiers à modifier :**
- `QnaService` / `QnaController` → réponse 202 + `jobId`
- `TranslationService` / `TranslationController` → réponse 202 + `jobId`
- `ProcessingJob.JobType` → ajouter `AI_QNA` (ne pas utiliser `QNA_SYNC` — nom contradictoire) et `TRANSLATION`

> ⚠️ **Changement cassant pour le frontend Angular** : la réponse synchrone devient 202 + polling. Le composant Angular Q&A et traduction doit être mis à jour pour appeler `GET /api/v1/jobs/{jobId}` en polling (pattern déjà utilisé pour OCR — le réutiliser).

**Critères d'acceptation :**
- [ ] `POST /api/v1/documents/{id}/ask` répond en < 200ms avec `{"jobId": "...", "status": "PENDING"}`
- [ ] `GET /api/v1/jobs/{jobId}` retourne le statut et le résultat quand disponible
- [ ] `POST /api/v1/documents/{id}/translate` idem
- [ ] Frontend Angular mis à jour pour le polling (breaking change coordonné)
- [ ] Thread Tomcat libéré immédiatement après la réponse 202

---

### 2.3 Scaling des thread pools et RestTemplate global

**Pourquoi :** `aiJobExecutor` est limité à 20 threads max avec queue 100 — soit 100 jobs en attente avant rejet. En production avec 500 utilisateurs actifs, cette limite est atteinte en quelques minutes lors d'une charge normale.

**Implémentation :**

```java
// AsyncConfig.java
@Bean(name = "aiJobExecutor")
public Executor aiJobExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(10);         // 5 → 10
    executor.setMaxPoolSize(50);          // 20 → 50
    executor.setQueueCapacity(500);       // 100 → 500
    // CallerRunsPolicy : import java.util.concurrent.ThreadPoolExecutor
    executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
    executor.setAwaitTerminationSeconds(120);
    // MDC propagation dans les threads @Async — OBLIGATOIRE pour le tracing
    executor.setTaskDecorator(new MdcTaskDecorator());
    executor.initialize();
    return executor;
}
// MdcTaskDecorator : copie le MDC (traceId, userId) du thread appelant → thread exécutant
```

```xml
<!-- pom.xml — requis pour HttpComponentsClientHttpRequestFactory (Spring Boot 3.x n'inclut plus httpclient4) -->
<dependency>
  <groupId>org.apache.httpcomponents.client5</groupId>
  <artifactId>httpclient5</artifactId>
</dependency>
```

```java
// RestTemplateConfig.java — timeout GLOBAL pour appels HTTP génériques uniquement
// ⚠️ NE PAS utiliser ce bean pour Gotenberg (WebClient dédié), Adobe (SDK propre),
//    Ollama (RestTemplate dédié 600s) — ils ont leurs propres clients configurés.
@Bean
public RestTemplate restTemplate() {
    HttpComponentsClientHttpRequestFactory factory = new HttpComponentsClientHttpRequestFactory();
    factory.setConnectTimeout(Duration.ofSeconds(5));
    factory.setReadTimeout(Duration.ofSeconds(45));
    return new RestTemplate(factory);
}
```

**Critères d'acceptation :**
- [ ] `aiJobExecutor` configuré : core=10, max=50, queue=500, `ThreadPoolExecutor.CallerRunsPolicy`
- [ ] `MdcTaskDecorator` implémenté et câblé sur `aiJobExecutor` et `processingExecutor`
- [ ] `processingExecutor` configuré : core=8, max=16, queue=200
- [ ] `RestTemplate` global avec connect=5s, read=45s (Gotenberg/Ollama/Adobe non affectés)
- [ ] Test de charge : 200 jobs soumis en parallèle → 0 rejection
- [ ] Métriques thread pool exposées via Micrometer (`executor.pool.size`, `executor.queue.remaining`)

---

### 2.4 pgvector — index HNSW production

**Pourquoi :** Sans index sur la colonne `embedding`, chaque recherche sémantique (Q&A) effectue un full table scan. Avec 10 000 documents × 50 chunks = 500 000 vecteurs : chaque requête Q&A prend plusieurs secondes, consomme CPU, et ne scale pas.

**Flyway migration V51 :**
```sql
-- V51__add_hnsw_index_document_chunks.sql
--
-- ⚠️ ATTENTION : CREATE INDEX CONCURRENTLY ne peut pas s'exécuter dans une transaction.
-- Deux options :
--   Option A (recommandée) : créer une Java migration @NonTransactional dans Flyway
--   Option B : ajouter spring.flyway.mixed=true dans application.yml ET exécuter
--              cette migration seule (un seul statement par fichier)
--
-- ⚠️ Vérifier le nom réel de la table dans les migrations existantes :
--    Spring AI pgvector utilise "vector_store" par défaut. Si la migration Flyway
--    a créé la table sous un autre nom, adapter la ligne ON ci-dessous.
--
-- HNSW est retenu pour tous les environnements (meilleur recall, adapté dev+prod).
-- Mettre à jour application-prod.yml : index-type: HNSW (était IVFFLAT — inutile
-- puisque initialize-schema: false, mais cohérence avec la migration).

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_document_chunks_embedding_hnsw
    ON document_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON INDEX idx_document_chunks_embedding_hnsw
    IS 'Index HNSW pgvector. Recall ~95%, latence <10ms sur 1M vecteurs.';
```

**Critères d'acceptation :**
- [ ] Nom de table vérifié dans les migrations Flyway existantes avant d'écrire V51
- [ ] Migration V51 exécutée via Java migration `@NonTransactional` (ou `spring.flyway.mixed=true`)
- [ ] `EXPLAIN ANALYZE` sur une requête Q&A montre `Index Scan using idx_document_chunks_embedding_hnsw`
- [ ] Latence recherche sémantique < 50ms pour 500 000 vecteurs (mesurée via `Timer` Micrometer)
- [ ] Paramètre `ef_search` ajustable via `application.yml` pour le tuning recall/latence

---

### 2.5 Tests de charge (Gatling)

**Pourquoi :** Impossible de savoir si une optimisation fonctionne sans mesure. iLovePDF et Smallpdf publient des SLA — Kovixel doit viser 99,5 % en phase initiale.

**Scénarios Gatling :**
```scala
// src/gatling/simulations/LoadTest.scala
// ⚠️ Pseudo-code illustratif — les méthodes uploadPdf(), pollJobUntilComplete(),
//    ingestDocument(), askQuestion() sont à implémenter via http(...) chainé dans
//    src/gatling/scala/kovixel/helper/PdfActions.scala

object Scenarios {
  // ⚠️ Auth rate limit : 5 req/min/IP pour login, 3/min pour register.
  //    Le scénario auth doit utiliser des tokens JWT pré-générés (feeder)
  //    pour les scénarios de charge — ne pas faire de login à chaque virtual user.
  val authScenario = scenario("Auth — refresh token uniquement")
    .exec(refreshToken).pause(1)

  val pdfConversionScenario = scenario("PDF → Word (async poll)")
    .exec(uploadPdf(5.MB)).exec(pollJobUntilComplete(timeout = 120.s))

  val aiQnaScenario = scenario("Q&A RAG (async poll)")
    .exec(askQuestion).repeat(5)(askQuestion)
}

class SpikeTest extends Simulation {
  setUp(
    authScenario.inject(rampUsers(500).during(30.seconds)),
    pdfConversionScenario.inject(rampUsers(50).during(60.seconds)),
    aiQnaScenario.inject(rampUsers(20).during(60.seconds))
  ).assertions(
    global.responseTime.percentile(95).lt(3000),    // p95 < 3s hors LLM (202 initial)
    global.successfulRequests.percent.gt(99)         // exclure 429 attendus du taux d'échec
  )
}
```

**Critères d'acceptation :**
- [ ] Suite Gatling intégrée dans `pom.xml` (plugin `gatling-maven-plugin`)
- [ ] Feeder de tokens JWT pré-générés pour éviter de déclencher le rate limit auth
- [ ] 3 scénarios : refresh auth, conversion async, Q&A async
- [ ] Objectifs p95 : réponse 202 < 500ms, poll résultat < 5s, Q&A résultat < 15s
- [ ] Rapport HTML généré dans `target/gatling/`
- [ ] CI bloque si assertions échouent

---

### 2.6 Observabilité complète (OpenTelemetry + Grafana)

**Pourquoi :** Sans traces distribuées, diagnostiquer une lenteur en production prend des heures. Grafana/Prometheus sont déjà partiellement câblés — il faut les compléter.

**Dashboards Grafana à créer :**

| Dashboard | Panels |
|---|---|
| **Kovixel — Overview** | RPS, erreurs 5xx, p50/p95/p99, uptime |
| **Thread Pools** | `aiJobExecutor` active/queued/rejected, `processingExecutor` idem |
| **Circuit Breakers** | État (CLOSED/OPEN/HALF_OPEN) par service externe |
| **Payment** | Checkouts créés/h, webhooks traités, taux échec paiement |
| **IA Performance** | Latence par provider (Claude/Ollama/OpenAI), tokens/s, coût estimé |
| **Database** | HikariCP connections actives, query latence p95, slow queries |

**OpenTelemetry via Micrometer Tracing (approche correcte pour Spring Boot 3.x) :**
```xml
<!-- ⚠️ Ne pas utiliser opentelemetry-spring-boot-starter directement —
     il entre en conflit avec l'auto-configuration Micrometer de Spring Boot 3.x.
     Utiliser le bridge Micrometer → OTEL à la place. -->
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-tracing-bridge-otel</artifactId>
</dependency>
<dependency>
  <groupId>io.opentelemetry</groupId>
  <artifactId>opentelemetry-exporter-otlp</artifactId>
</dependency>
```

```yaml
# application.yml — export vers Jaeger ou Grafana Tempo
management.tracing:
  enabled: true
  sampling.probability: 1.0   # 100% en dev, 0.1 en prod
otel.exporter.otlp.endpoint: http://localhost:4317
```

**Critères d'acceptation :**
- [ ] Trace distribuée visible HTTP → controller → service → DB/LLM dans Grafana Tempo ou Jaeger
- [ ] `traceId` (format W3C `traceparent`) inclus dans toutes les réponses d'erreur JSON
- [ ] Dashboard Grafana "Kovixel Overview" opérationnel en < 5 minutes après déploiement
- [ ] Alertes configurées : p95 > 5s, error rate > 1%, circuit breaker OPEN
- [ ] `traceId` propagé dans les threads `@Async` via `MdcTaskDecorator` (voir §2.3)

---

## 3. Phase 2 — Scalabilité horizontale *(2–4 mois)*

> Passage de "1 instance qui tient bien" à "N instances qui scalent".

### 3.1 Queue externe — RabbitMQ ou Kafka

**Pourquoi :** Le `ThreadPoolTaskExecutor` est in-process — si le serveur redémarre, tous les jobs `PENDING` sont perdus. Avec une queue externe, les jobs survivent au redémarrage et peuvent être traités par n'importe quelle instance.

**Architecture cible :**
```
Controller → [POST /jobs] → JobService → RabbitMQ queue "kovixel.jobs.ai"
                                              ↓
                                    AiJobConsumer (N instances)
                                              ↓
                                    ProcessingOrchestrator
```

**Choix :** RabbitMQ (plus simple à opérer, déjà dans l'écosystème Spring) pour la v1, Kafka si besoin de replay ou event sourcing plus tard.

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
```

**Critères d'acceptation :**
- [ ] Jobs AI (`SUMMARY`, `QA` (ingest), `OCR`, `TRANSLATION`, `AI_QNA`) envoyés dans RabbitMQ
- [ ] Restart de l'application → jobs en attente reprennent sans perte
- [ ] Dead Letter Queue pour jobs échoués > 3 tentatives
- [ ] Dashboard RabbitMQ Management exposé (port 15672 en dev)
- [ ] Migration sans downtime : le `ThreadPoolTaskExecutor` reste en fallback si RabbitMQ indisponible

---

### 3.2 Kubernetes — Helm Chart

**Pourquoi :** Un seul `docker-compose` ne peut pas scaler horizontalement. Kubernetes permet N replicas de l'app + auto-scaling sur CPU/RPS.

**Structure `kovixel-helm/` :**
```
kovixel-helm/
├── Chart.yaml
├── values.yaml              # dev defaults
├── values-prod.yaml         # prod overrides
└── templates/
    ├── deployment.yaml      # app + replicas
    ├── service.yaml
    ├── ingress.yaml         # nginx-ingress + TLS
    ├── hpa.yaml             # HorizontalPodAutoscaler
    ├── configmap.yaml
    ├── secret.yaml          # External Secrets Operator
    └── pdb.yaml             # PodDisruptionBudget
```

**HPA configuré :**
```yaml
# hpa.yaml
spec:
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: kovixel_ai_job_queue_size
        target:
          averageValue: "50"   # scale si > 50 jobs en queue par pod
```

**Critères d'acceptation :**
- [ ] `helm install kovixel ./kovixel-helm` déploie l'app complète (app + Redis via subchart)
- [ ] ⚠️ PostgreSQL via service managé (RDS, Cloud SQL, Supabase) — PAS via StatefulSet Kubernetes : la persistance des données critiques ne doit pas reposer sur un StatefulSet sans opérateur dédié
- [ ] HPA sur CPU (seuil 70%) fonctionnel ; HPA sur `kovixel_ai_job_queue_size` nécessite **Prometheus Adapter** ou **KEDA** pour exposer la métrique Micrometer à l'API Kubernetes — ajouter `kedacore/keda` au Helm chart
- [ ] HPA scale de 2 à 6 pods automatiquement sous charge
- [ ] Rolling update sans downtime (readiness probe sur `/actuator/health`)
- [ ] PodDisruptionBudget garantit minAvailable=1 pendant maintenance
- [ ] Tests de chaos : kill 1 pod → 0 erreur côté utilisateur

---

### 3.3 CDN pour assets et fichiers résultats

**Pourquoi :** Actuellement, chaque téléchargement de fichier résultat (PDF compressé, Word converti, etc.) passe par le serveur Spring Boot. Avec un CDN (Cloudflare ou AWS CloudFront), les fichiers sont servis depuis un edge node proche de l'utilisateur, libérant les threads app.

**Architecture :**
```
MinIO (S3-compatible) → presigned URL → utilisateur (téléchargement direct, sans passer par app)
Angular dist          → Cloudflare CDN → utilisateur (assets statiques)
```

> ⚠️ **Presigned URLs et CDN** : les presigned URLs MinIO/S3 sont uniques par requête (incluent timestamp + signature). Cloudflare ne peut pas les mettre en cache. Pour les fichiers résultats, le gain vient du **téléchargement direct MinIO → client** (zéro thread app consommé), pas du CDN. Pour un vrai CDN sur les fichiers, utiliser **Cloudflare R2** (S3-compatible, intégré nativement au réseau Cloudflare).

**Implémentation :**
- Générer des presigned URLs MinIO (TTL configurable) pour le téléchargement direct
- Assets Angular compilés (hashed) servis via Cloudflare CDN avec cache immuable
- Envisager migration MinIO → R2 pour CDN natif sur les fichiers résultats

**Critères d'acceptation :**
- [ ] Téléchargement de fichier résultat via presigned URL directement (0 passage par app)
- [ ] TTL presigned URL configurable (`kovixel.storage.download-url-ttl-minutes`)
- [ ] Assets frontend avec `Cache-Control: public, max-age=31536000, immutable` sur les hashes
- [ ] Temps de téléchargement d'un fichier 10 MB < 2s depuis Europe

---

### 3.4 PostgreSQL — Read Replica et connexions

**Pourquoi :** HikariCP 20 connexions en prod est insuffisant pour > 500 utilisateurs actifs. Les lectures (historique, job status, bibliothèque) peuvent être routées vers un replica pour soulager le primaire.

**Implémentation :**
```yaml
# application-prod.yml — ajout read replica
kovixel.datasource:
  primary:
    url: jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}
    hikari.maximum-pool-size: 30
  readonly:
    url: jdbc:postgresql://${DB_HOST_READONLY}:5432/${DB_NAME}
    hikari.maximum-pool-size: 20
```

```java
// Annotation + AOP requis pour le routing effectif
// L'annotation seule ne route PAS — il faut un Aspect + AbstractRoutingDataSource

@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
@Transactional(readOnly = true)
public @interface ReadOnly {}

// ReadOnlyDataSourceAspect.java — à créer
@Aspect
@Component
public class ReadOnlyDataSourceAspect {
    @Around("@annotation(ReadOnly)")
    public Object routeToReplica(ProceedingJoinPoint pjp) throws Throwable {
        DataSourceContextHolder.setReadOnly(true);
        try { return pjp.proceed(); }
        finally { DataSourceContextHolder.clear(); }
    }
}

// RoutingDataSource.java — à créer (étend AbstractRoutingDataSource)
// determineCurrentLookupKey() → lit DataSourceContextHolder.isReadOnly()
```

**Critères d'acceptation :**
- [ ] `ReadOnlyDataSourceAspect` + `RoutingDataSource` implémentés et testés
- [ ] Requêtes `@ReadOnly` routées vers le replica (vérifiable via logs slow-query sur le primaire)
- [ ] HikariCP primaire : 30 connexions ; replica : 20 connexions
- [ ] Failover automatique si replica indisponible → primaire (RoutingDataSource fallback)
- [ ] Métriques Hikari séparées par data source dans Grafana

---

### 3.5 Redis Cluster + Sessions distribuées

**Pourquoi :** Redis en standalone est un SPOF. Si Redis tombe, le rate limiting et le cache disparaissent. Avec Redis Cluster (ou Redis Sentinel), la disponibilité est maintenue.

**Critères d'acceptation :**
- [ ] Redis Sentinel configuré en dev/staging (1 master, 2 replicas)
- [ ] Redis Cluster en production (3 shards minimum)
- [ ] Blacklist JWT et rate limiting survivent à la perte d'1 nœud Redis
- [ ] TTL des clés de rate limiting cohérent après failover

---

## 4. Phase 3 — Différenciation produit *(4–6 mois)*

> Ce sont les features qui font que les utilisateurs choisissent Kovixel au lieu d'iLovePDF.

### 4.1 API publique REST v1

**Pourquoi :** iLovePDF, Smallpdf et Adobe ont tous une API publique. Les développeurs et intégrateurs représentent un canal d'acquisition important et créent de la rétention (switching cost élevé).

**Endpoints v1 :**
```
POST   /api/public/v1/conversions          → soumet une conversion
GET    /api/public/v1/conversions/{id}     → statut + résultat
POST   /api/public/v1/documents/summarize  → résumé IA
POST   /api/public/v1/documents/extract    → extraction structurée
GET    /api/public/v1/usage                → quota consommé
POST   /api/public/v1/webhooks             → enregistrer un webhook (callback)
DELETE /api/public/v1/webhooks/{id}
```

**Authentification :** API Key (bearer token) + scopes (read, write, ai)

**Rate limiting API publique :**
```
FREE    : 100 req/jour
Pro     : 5 000 req/jour
Pro+    : 25 000 req/jour
Team    : 100 000 req/jour
```

**Webhooks :**
```json
{
  "event": "conversion.completed",
  "jobId": "job_abc123",
  "status": "COMPLETED",
  "downloadUrl": "https://files.kovixel.com/...",
  "expiresAt": "2026-06-25T12:00:00Z"
}
```

**Critères d'acceptation :**
- [ ] Page documentation API (Swagger/Redoc) sur `api.kovixel.com/docs`
- [ ] SDK officiel Node.js publié sur npm (`@kovixel/sdk`)
- [ ] SDK Python publié sur PyPI (`kovixel-sdk`)
- [ ] Webhooks avec signature HMAC-SHA256 (même pattern que Stripe)
- [ ] ⚠️ **Protection SSRF obligatoire sur les URLs de webhook** : rejeter les IPs RFC 1918 (10.x, 172.16.x, 192.168.x), localhost, ::1, et les IPs du cluster Kubernetes avant d'effectuer le callback
- [ ] Dashboard développeur : API keys, usage, logs de webhooks
- [ ] Idempotency-Key supporté (déduplication Redis sur 24h, clé = `idempotency:{apiKey}:{idempotencyKey}`)
- [ ] Rate limiting par API key via Redis (compteur par jour, reset à minuit UTC)

---

### 4.2 Intégrations (Google Drive, Dropbox, OneDrive, Zapier)

**Pourquoi :** Smallpdf propose Google Drive natif. C'est une friction énorme de devoir télécharger un fichier depuis Drive puis le re-uploader. Ces intégrations éliminent ce friction et augmentent la rétention.

**Intégrations prioritaires :**

| Intégration | Valeur | Effort |
|---|---|---|
| Google Drive (import + export) | Très haute | Moyen |
| Dropbox (import + export) | Haute | Moyen |
| OneDrive / SharePoint | Haute | Moyen |
| Zapier (trigger + action) | Haute | Faible |
| Make (ex-Integromat) | Moyenne | Faible |
| Slack (partage résultat) | Moyenne | Faible |
| Microsoft Teams | Moyenne | Moyen |

**Architecture Google Drive :**
```
OAuth2 (Google) → access_token stocké chiffré en DB
GET /api/v1/integrations/google-drive/files  → liste fichiers Drive
POST /api/v1/integrations/google-drive/import → importe dans Kovixel
POST /api/v1/integrations/google-drive/export → exporte depuis Kovixel
```

**Critères d'acceptation :**
- [ ] Connexion Google Drive via OAuth2 en < 3 clics
- [ ] Import d'un PDF depuis Drive → conversion → export résultat vers Drive
- [ ] Access tokens chiffrés en DB (AES-256)
- [ ] Révocation propre via `/api/v1/integrations/google-drive/disconnect`
- [ ] Trigger Zapier : "Quand un document est traité sur Kovixel → envoyer vers Slack"
- [ ] Action Zapier : "Quand un fichier arrive dans Dropbox → convertir via Kovixel"

---

### 4.3 Batch processing (ZIP → ZIP)

**Pourquoi :** Les entreprises traitent des centaines de fichiers. Uploader un par un est intolérable. La concurrence (iLovePDF Pro) propose du batch. C'est un argument de vente fort pour les plans Équipe/Enterprise.

**API batch :**
```
POST /api/v1/batch
  Content-Type: multipart/form-data
  files: [file1.pdf, file2.pdf, ..., file50.pdf]
  operation: PDF_TO_WORD | COMPRESS | OCR | SUMMARIZE
  options: { ... }

→ 202 { "batchId": "batch_xyz", "jobCount": 50 }

GET /api/v1/batch/{batchId}
→ { "status": "PROCESSING", "completed": 23, "total": 50, "failedCount": 0 }

GET /api/v1/batch/{batchId}/download
→ ZIP contenant tous les résultats
```

**Critères d'acceptation :**
- [ ] Upload d'un ZIP → extraction → traitement individuel de chaque fichier
- [ ] Traitement parallèle (max 10 fichiers simultanés par batch)
- [ ] Téléchargement ZIP résultat signé (presigned URL S3)
- [ ] Rapport CSV dans le ZIP (fichier, statut, erreur éventuelle)
- [ ] Limite batch : 50 fichiers (Pro), 200 (Pro+), 500 (Équipe)

---

### 4.4 Collaboration et annotations en temps réel

**Pourquoi :** Adobe Acrobat et Smallpdf proposent des commentaires collaboratifs. C'est une fonctionnalité clé pour les équipes. Elle justifie le plan Équipe et augmente l'engagement.

**Features :**
- Annotations sur PDF (surlignage, commentaire, flèche)
- Partage de document via lien (lecture seule ou édition)
- Commentaires avec threads (répondre à un commentaire)
- Notifications en temps réel (WebSocket)
- Mentions @utilisateur

**Stack :**
- WebSocket (Spring WebSocket + STOMP) pour les notifications
- Annotations stockées en DB (table `document_annotations`)
- Partage via token signé (TTL configurable)

**Critères d'acceptation :**
- [ ] Partager un lien vers un document en lecture seule
- [ ] 2 utilisateurs voient les annotations en temps réel (WebSocket)
- [ ] Annotations exportables dans le PDF final via **PDFBox `PDAnnotation`** (iText n'est pas dans les dépendances — PDFBox 3.0.7 déjà présent supporte les annotations PDF nativement)
- [ ] Contrôle d'accès : propriétaire, éditeur, lecteur

---

### 4.5 Bibliothèque de documents — Vault IA

**Pourquoi :** Actuellement les documents sont traités puis supprimés. Un vault persistant transforme Kovixel d'un outil ponctuel en espace de travail quotidien (rétention × 10).

**Features :**
- Bibliothèque personnelle avec dossiers et tags
- Recherche full-text + sémantique sur tous les documents ingérés
- Historique des versions d'un document
- Assistant IA transversal : "Quel est le montant total des factures du T1 ?" (sur toute la bibliothèque)
- Suppression automatique selon la politique du plan (30j, 1 an, illimité)

**Critères d'acceptation :**
- [ ] `GET /api/v1/vault/documents` → liste paginée avec filtres
- [ ] Recherche sémantique cross-documents via pgvector
- [ ] Gestion des dossiers et tags (drag & drop côté Angular)
- [ ] Conformité RGPD : suppression totale sur demande en < 24h

---

### 4.6 Templates d'extraction intelligents

**Pourquoi :** Les utilisateurs répètent les mêmes extractions (factures, contrats, bulletins de paie). Les templates réduisent la friction et créent de la valeur récurrente.

**Features :**
- Templates prédéfinis : Facture, Contrat, Bulletin de paie, Devis, CV
- Création de template personnalisé via interface visuelle (définir les champs à extraire)
- Application en batch sur plusieurs documents
- Export Webhook : résultats envoyés vers CRM/ERP via webhook

**Critères d'acceptation :**
- [ ] 5 templates prédéfinis fonctionnels avec > 90 % de précision
- [ ] Interface drag-and-drop pour définir des zones d'extraction
- [ ] Application de template sur batch de 20 documents en < 2 min

---

## 5. Phase 4 — Grade Enterprise *(6–12 mois)*

> Ce qui ouvre les grands comptes, le secteur public, et justifie des prix x3.

### 5.1 SSO — SAML 2.0 et OIDC

**Pourquoi :** Aucune grande entreprise ou administration ne déploiera Kovixel sans SSO. C'est un prérequis bloquant pour les deals Enterprise.

**Providers supportés :** Okta, Azure AD, Google Workspace, Keycloak, ADFS

**Implémentation :**
```xml
<dependency>
  <groupId>org.springframework.security</groupId>
  <artifactId>spring-security-saml2-service-provider</artifactId>
</dependency>
```

**Critères d'acceptation :**
- [ ] Connexion via SAML 2.0 (IdP-initiated et SP-initiated)
- [ ] Connexion via OIDC (Authorization Code Flow)
- [ ] Provisionnement automatique des utilisateurs (SCIM 2.0)
- [ ] Mapping des groupes IdP vers les rôles Kovixel (admin, membre)
- [ ] Test validé avec Okta, Azure AD et Keycloak

---

### 5.2 SOC 2 Type II et ISO 27001

**Pourquoi :** Sans certification, les services juridiques des grandes entreprises bloquent l'achat. C'est le ticket d'entrée pour les contrats > 50 000 €/an.

**Contrôles requis :**

| Domaine | Action |
|---|---|
| Contrôle d'accès | MFA obligatoire pour les admins, revue trimestrielle des accès |
| Chiffrement | AES-256 au repos, TLS 1.3 en transit, rotation des clés |
| Audit trail | Log immuable de toutes les actions admin (table `audit_log`) |
| Gestion des incidents | Runbook pour chaque type d'incident, RTO < 4h, RPO < 1h |
| Vulnérabilités | DAST (OWASP ZAP) en CI, dépendances scannées (Snyk/Dependabot) |
| Formation | Sensibilisation sécurité annuelle pour tous les contributeurs |
| Business continuity | Plan de continuité testé trimestriellement |

**Critères d'acceptation :**
- [ ] Rapport de pentest externe réalisé et remédiation complète
- [ ] `audit_log` table avec retention 7 ans, tamper-proof (hash chaîné)
- [ ] Scan SAST (SonarQube) intégré en CI avec quality gate
- [ ] DAST (OWASP ZAP) hebdomadaire en staging
- [ ] Politique de gestion des vulnérabilités documentée (SLA : critique < 24h, haute < 7j)
- [ ] Audit SOC 2 Type II commandé

---

### 5.3 Multi-région (EU-West + EU-Central)

**Pourquoi :** RGPD impose la résidence des données en Europe pour les clients français/allemands/belges. La latence depuis Paris vers un datacenter Londres est acceptable, mais une région Frankfurt améliore l'expérience DE/AT/CH.

**Architecture :**
```
Cloudflare (GeoDNS)
    ├── EU-West (Paris / Dublin) → cluster Kubernetes primaire
    └── EU-Central (Frankfurt)  → cluster Kubernetes secondaire
```

**Données :**
- PostgreSQL : réplication synchrone au sein d'une région, asynchrone cross-région
- Redis : instance par région (rate limiting local)
- MinIO : réplication cross-région pour les fichiers utilisateurs

**Critères d'acceptation :**
- [ ] `X-Region: eu-west` ou `X-Region: eu-central` dans les réponses
- [ ] Sélection de région configurable par compte Enterprise
- [ ] Latence p95 < 200ms depuis Paris et Frankfurt
- [ ] Données ne quittent pas l'UE (certified)
- [ ] Failover cross-région en < 5 minutes (testé trimestriellement)

---

### 5.4 White-labeling et déploiement on-premises

**Pourquoi :** Certains clients (banques, hôpitaux, administrations) ne peuvent pas envoyer leurs données vers un SaaS externe. Le déploiement on-prem + white-label ouvre un segment à forte valeur.

**Offre :**
- Docker Compose "all-in-one" (app + PostgreSQL + Redis + MinIO + Ollama)
- Helm Chart pour Kubernetes on-prem
- Personnalisation logo, couleurs, domaine
- Support dédié SLA

**Critères d'acceptation :**
- [ ] `docker-compose up` produit une instance Kovixel complète en < 5 min
- [ ] Variables de white-label : `KOVIXEL_BRAND_NAME`, `KOVIXEL_LOGO_URL`, `KOVIXEL_PRIMARY_COLOR`
- [ ] Licence `kovixel-enterprise-license.key` validée au démarrage
- [ ] Mise à jour via `helm upgrade` sans perte de données

---

### 5.5 Audit trail complet et DLP

**Pourquoi :** Les entreprises réglementées (finance, santé, juridique) ont besoin de savoir qui a accédé à quoi, quand, et depuis où.

**Table `kovixel_audit_log` :**
```sql
CREATE TABLE kovixel_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    event_time      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- ON DELETE SET NULL obligatoire : la suppression RGPD d'un user ne doit pas
    -- effacer ses logs d'audit (obligation légale de rétention 7 ans)
    user_id         BIGINT REFERENCES kovixel_users(id) ON DELETE SET NULL,
    user_email      VARCHAR(255),           -- conservé même si user supprimé
    action          VARCHAR(100) NOT NULL,  -- 'DOCUMENT_VIEWED', 'FILE_DOWNLOADED', etc.
    resource_type   VARCHAR(50),
    resource_id     VARCHAR(255),
    ip_address      INET,
    user_agent      TEXT,
    outcome         VARCHAR(20),            -- 'SUCCESS', 'FAILURE', 'DENIED'
    metadata        JSONB,
    hash            VARCHAR(64)             -- SHA-256(id||event_time||action||hash_précédent)
    -- ⚠️ Le hash chaîné doit être calculé dans une transaction avec SELECT...FOR UPDATE
    --    sur la dernière ligne pour éviter les race conditions en multi-instances.
    --    Utiliser un advisory lock PostgreSQL ou sérialiser via un service dédié.
);

CREATE INDEX ON kovixel_audit_log (user_id, event_time DESC);
CREATE INDEX ON kovixel_audit_log (event_time DESC);
```

**DLP (Data Loss Prevention) :**
- Détection de PII dans les documents uploadés (numéros de CB, NSS, IBAN)
- Alerte admin si PII détecté dans un document partagé publiquement
- Masquage automatique optionnel

**Critères d'acceptation :**
- [ ] Chaque action sensible (upload, download, share, delete, login) loggée
- [ ] FK `ON DELETE SET NULL` : suppression RGPD d'un user conserve ses logs d'audit
- [ ] Hash chaîné avec advisory lock PostgreSQL pour éviter les race conditions multi-pods
- [ ] Hash vérifié au démarrage — alerte si tamper détecté
- [ ] Export CSV de l'audit trail disponible pour les admins Enterprise
- [ ] API REST pour intégration SIEM : `GET /api/v1/admin/audit-log?since=...`
- [ ] Rétention configurable par plan (30j, 1 an, 7 ans)

---

### 5.6 SLA contractuel et support Enterprise

| Niveau | Disponibilité | Temps réponse | Canal |
|---|---|---|---|
| Pro | 99,5 % | Email 48h | Email |
| Pro+ | 99,9 % | Email 24h | Email + Chat |
| Équipe | 99,9 % | 8h ouvré | Email + Chat + Slack dédié |
| Enterprise | 99,95 % | 4h 24/7 | Slack dédié + CSM dédié |

**Critères d'acceptation :**
- [ ] Status page publique (`status.kovixel.com`) avec uptime temps réel
- [ ] Incident postmortem publié < 48h après chaque incident majeur
- [ ] Alertes PagerDuty configurées pour on-call
- [ ] Runbook pour chaque type d'incident documenté dans Confluence/Notion

---

## 6. Phase 5 — Innovation IA *(12 mois+)*

> Les features qui créent une rupture et rendent Kovixel irremplaçable.

### 6.1 Assistant IA transversal — Chat avec toute sa bibliothèque

**Pourquoi :** NotionAI, Google NotebookLM permettent de dialoguer avec un corpus. Kovixel peut proposer la même chose mais sur des documents PDF professionnels, avec une précision supérieure grâce au RAG multimodal.

**"Demande à Kovixel" :**
- "Quel est le CA cumulé des 3 contrats uploadés ce mois-ci ?"
- "Compare les clauses de résiliation de ces 5 contrats"
- "Génère un résumé exécutif de tous mes rapports Q1 2026"

**Stack :**
- RAG multi-documents via pgvector (index sur toute la bibliothèque utilisateur)
- Claude pour la synthèse et la comparaison
- Citations avec numéro de page et document source

---

### 6.2 Agents IA — Pipelines de traitement automatisés

**Pourquoi :** Les utilisateurs avancés veulent automatiser des workflows complexes sans code.

**Exemples d'agents :**
- Agent "Comptabilité" : reçoit une facture → extrait montant/TVA/fournisseur → exporte vers Google Sheets → archive dans Dropbox
- Agent "Juridique" : analyse un contrat → identifie clauses risquées → génère un rapport → notifie l'équipe sur Slack
- Agent "RH" : reçoit des CVs → extrait compétences → score par rapport à la fiche de poste → crée un tableau comparatif

**Stack :**
- Spring AI Tool Calling (function calling Claude)
- DSL YAML pour définir un pipeline (no-code)
- Exécution async avec état persistent

---

### 6.3 Traitement multimodal — Comprendre les images et graphiques dans les PDF

**Pourquoi :** La majorité des PDF de rapports et présentations contiennent des graphiques, tableaux en image, et schémas. Les LLMs actuels ignorent ce contenu.

**Features :**
- Extraction et description des graphiques (Claude Vision)
- Interprétation des tableaux en image (pas juste OCR, mais compréhension)
- Génération de commentaires sur des slides

---

### 6.4 Application mobile (iOS + Android)

**Pourquoi :** iLovePDF, Smallpdf et Adobe ont des apps natives à > 4,5 étoiles sur les stores. L'absence de mobile pénalise l'acquisition (70% du trafic web est mobile).

**MVP mobile :**
- Scan de document (caméra → PDF)
- Upload et déclenchement d'un outil
- Notifications push quand un job est terminé
- Bibliothèque et téléchargement

**Stack :** Flutter (iOS + Android en une codebase) + API Kovixel existante

---

### 6.5 Extension navigateur (Chrome + Firefox)

**Pourquoi :** Capture une audience qui ne reviendra jamais sur le site mais peut devenir utilisatrice via l'extension.

**Features :**
- Clic droit sur un PDF dans le navigateur → "Traiter avec Kovixel"
- Résumé IA d'une page web (converti en PDF via l'extension)
- Annoter un PDF directement dans le navigateur

---

### 6.6 Veille documentaire et alertes

**Pourquoi :** Les professionnels du droit, de la finance et de la conformité lisent des dizaines de documents similaires. Kovixel peut apprendre leurs patterns et proactivement alerter.

**Features :**
- "Alerte si un nouveau document correspond à ce profil"
- "Notifie-moi si la clause X est présente dans ce contrat"
- Digest hebdomadaire : "Voici les 5 documents les plus pertinents uploadés cette semaine"

---

## 7. Métriques de succès

### KPIs techniques

| Métrique | Aujourd'hui | Phase 1 | Phase 2 | Phase 4 |
|---|---|---|---|---|
| Disponibilité (uptime) | N/A | 99,5 % | 99,9 % | 99,95 % |
| p95 conversion PDF→Word | ~15s | < 10s | < 5s | < 3s |
| p95 Q&A (async) | Sync bloquant | < 500ms (202) | < 500ms | < 500ms |
| Résultat Q&A | ~20s | < 15s | < 10s | < 8s |
| Jobs perdus au restart | 100 % | 100 % | 0 % (RabbitMQ) | 0 % |
| Concurrence max (1 instance) | ~200 users | ~500 users | N instances | N instances |
| Tests de charge | Aucun | Gatling CI | Gatling CI | Gatling CI + chaos |

### KPIs produit

| Métrique | Objectif 6 mois | Objectif 12 mois | Objectif 24 mois |
|---|---|---|---|
| Utilisateurs actifs mensuels | 5 000 | 25 000 | 150 000 |
| MRR | 5 000 € | 30 000 € | 200 000 € |
| Taux de conversion free→payant | 3 % | 6 % | 8 % |
| NPS | > 40 | > 55 | > 65 |
| Intégrations actives | 0 | 3 (Drive, Dropbox, Zapier) | 10+ |
| Clients Enterprise | 0 | 5 | 30 |

---

## 8. Matrice risques / effort

```
IMPACT
  ^
  │  [Q&A Async]★  [Circuit Breakers]★
  │  [RabbitMQ]★   [API Publique]
  │  [pgvector HNSW]★
  │               [SSO/SAML]         [Multi-région]
  │  [Kubernetes]  [Intégrations]
  │               [Batch processing]
  │                                  [SOC 2]
  │               [Mobile App]
  │                                  [Agents IA]
  +─────────────────────────────────────────────────> EFFORT
    Faible        Moyen              Élevé
```

★ = Phase 1 (priorité immédiate, fort ROI, faible effort relatif)

### Ordre de priorité recommandé

| Priorité | Item | Raison |
|---|---|---|
| 🔴 P0 | Circuit breakers | Risque de production immédiat |
| 🔴 P0 | Q&A + Traduction async | Blocage de threads majeur |
| 🔴 P0 | pgvector index HNSW | Performance critique en production |
| 🟡 P1 | Thread pools scaling | Prévention de rejet de jobs |
| 🟡 P1 | Tests de charge Gatling | Validation de toutes les optimisations |
| 🟡 P1 | Observabilité Grafana | Visibilité en production |
| 🟢 P2 | RabbitMQ | Persistence des jobs |
| 🟢 P2 | Kubernetes Helm | Scaling horizontal |
| 🟢 P2 | API publique | Canal d'acquisition développeurs |
| 🟢 P2 | Intégrations (Drive, Zapier) | Rétention et acquisition |
| 🔵 P3 | SSO / SAML | Deals Enterprise |
| 🔵 P3 | SOC 2 | Deals Enterprise |
| 🔵 P3 | Audit trail + DLP | Conformité |
| 🔵 P3 | Multi-région | Conformité RGPD + performance |

---

*Dernière mise à jour : 2026-06-24*
*Auteur : Kovixel Engineering*
