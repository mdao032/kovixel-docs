# KOVIXEL — Plan d'Action Adapté à l'État Réel du Projet
# github.com/mdao032/kovixel — Analysé le 23 avril 2026

---

## ÉTAT ACTUEL DU PROJET (audit pom.xml + README)

```
✅ DÉJÀ EN PLACE                    ❌ MANQUANT
─────────────────────────────────   ─────────────────────────────────
Spring Boot 3.4.3 + Java 21        Spring AI (aucune dép. IA)
Spring Security + JWT (jjwt 0.12.5) Redis / Spring Cache
Apache PDFBox 3.0.7                 RabbitMQ / Spring AMQP
MapStruct 1.6.3 + Lombok            Flyway (migrations SQL)
spring-retry + spring-aspects       pgvector extension
PostgreSQL + JPA                    Testcontainers (tests)
SpringDoc OpenAPI 2.8.5             Apache POI / iText
spring-boot-configuration-processor
```

**Architecture actuelle** : Monolith unique — package `com.kovixel`
**Profils** : dev / prod (EnvironmentProperties déjà configurée)
**Base de données** : `kovixel_db` sur PostgreSQL localhost:5432

---

## STRATÉGIE : MONOLITH D'ABORD, MICROSERVICES PLUS TARD

> **Ne pas éclater en microservices maintenant.**
> Votre monolith bien structuré en couches peut absorber tout le trafic
> jusqu'à ~100K utilisateurs/jour. Microservices = complexité prématurée.
> On structure les packages comme si c'était des microservices → migration facile plus tard.

```
Package structure cible dans com.kovixel :

com.kovixel/
├── config/          (SecurityConfig, SpringAiConfig, RedisConfig...)  ← existant partiel
├── core/            (PDF merge, split, compress)
│   ├── controller/
│   ├── service/
│   └── model/
├── ai/              ← TOUT LE TRAVAIL À FAIRE
│   ├── summary/     ✅ (à vérifier/compléter)
│   ├── qna/         ← Étape 2
│   ├── extraction/  ← Étape 3
│   └── workflow/    ← Étape 5
├── user/            (auth existante à compléter)
│   ├── controller/
│   ├── service/
│   └── model/
├── shared/
│   ├── exception/   (GlobalExceptionHandler)
│   ├── dto/
│   └── util/
└── infra/
    ├── queue/       ← Étape 4
    └── cache/       ← Étape 4
```

---

## ÉTAPE 0 — FONDATIONS (à faire AVANT tout le reste)

**Durée : 1 jour | Priorité : CRITIQUE**

### Prompt 0.1 — Audit et nettoyage de la sécurité existante

```
Analyse mon projet Spring Boot (com.kovixel).
Le JWT est déjà configuré avec jjwt 0.12.5 et Spring Security est présent.

1. Montre-moi la configuration Spring Security actuelle 
   (tous les fichiers SecurityConfig, filtres JWT, etc.)

2. Si Spring Security bloque tous les endpoints par défaut :
   - Assure-toi que Swagger UI (/swagger-ui/**, /v3/api-docs/**) est public
   - Assure-toi que les endpoints de santé (/actuator/health) sont publics
   - Les endpoints /api/** doivent nécessiter un JWT valide
   - Ajoute CORS pour autoriser localhost:3000 (futur frontend)

3. Crée un endpoint public de test :
   GET /api/v1/health → { "status": "UP", "version": "0.0.1" }

4. Documente exactement comment générer un token JWT pour tester les 
   endpoints protégés avec Swagger UI (ajouter le bouton Authorize).
```

### Prompt 0.2 — Ajout de Flyway pour les migrations SQL

```
Ajoute Flyway au projet Kovixel pour gérer les migrations de base de données.

1. Ajoute la dépendance dans pom.xml :
   <dependency>
     <groupId>org.flywaydb</groupId>
     <artifactId>flyway-core</artifactId>
   </dependency>
   <dependency>
     <groupId>org.flywaydb</groupId>
     <artifactId>flyway-database-postgresql</artifactId>
   </dependency>

2. Configure Flyway dans application.yml :
   spring.flyway.enabled=true
   spring.flyway.locations=classpath:db/migration
   spring.flyway.baseline-on-migrate=true (car la DB existe déjà)

3. Crée le répertoire src/main/resources/db/migration/

4. Crée V1__init_users_table.sql avec les tables users et roles 
   si elles n'existent pas encore (base sur les entities JPA existantes)

5. Configure spring.jpa.hibernate.ddl-auto=validate en dev 
   (Flyway gère le schéma, plus Hibernate)
```

### Prompt 0.3 — Gestionnaire d'exceptions global

```
Crée un GlobalExceptionHandler complet pour Kovixel.

Dans le package com.kovixel.shared.exception :

1. KovixelException.java (RuntimeException de base)
   - message, errorCode (enum), httpStatus

2. ErrorCode.java (enum)
   - DOCUMENT_NOT_FOUND, AI_SERVICE_ERROR, PLAN_LIMIT_EXCEEDED,
     INVALID_FILE_TYPE, FILE_TOO_LARGE, PROCESSING_ERROR

3. GlobalExceptionHandler.java (@RestControllerAdvice)
   - @ExceptionHandler(KovixelException.class) → ErrorResponse avec code + message
   - @ExceptionHandler(MethodArgumentNotValidException.class) → erreurs de validation
   - @ExceptionHandler(MultipartException.class) → fichier trop grand
   - @ExceptionHandler(Exception.class) → fallback 500

4. ErrorResponse.java (DTO)
   - timestamp, status, errorCode, message, path

Format JSON cohérent pour tous les cas d'erreur.
```

---

## ÉTAPE 1 — SPRING AI + RÉSUMÉ PDF (base du projet)

**Durée : 1-2 jours | Priorité : HAUTE**

### Prompt 1.1 — Intégration Spring AI dans le projet existant

```
Ajoute Spring AI au projet Kovixel existant (Spring Boot 3.4.3, Java 21).

1. Dans pom.xml, ajoute le BOM Spring AI et les dépendances :

   Dans <dependencyManagement> :
   <dependency>
     <groupId>org.springframework.ai</groupId>
     <artifactId>spring-ai-bom</artifactId>
     <version>1.0.0</version>
     <type>pom</type>
     <scope>import</scope>
   </dependency>

   Dans <dependencies> :
   <!-- Anthropic Claude -->
   <dependency>
     <groupId>org.springframework.ai</groupId>
     <artifactId>spring-ai-anthropic-spring-boot-starter</artifactId>
   </dependency>
   <!-- Vector Store PostgreSQL + pgvector (pour la suite) -->
   <dependency>
     <groupId>org.springframework.ai</groupId>
     <artifactId>spring-ai-pgvector-store-spring-boot-starter</artifactId>
   </dependency>

2. Dans application.yml (profil dev), ajoute :
   spring:
     ai:
       anthropic:
         api-key: ${ANTHROPIC_API_KEY}
         chat:
           options:
             model: claude-sonnet-4-5
             max-tokens: 4096
             temperature: 0.3

3. Crée SpringAiConfig.java dans com.kovixel.config :
   - Bean ChatClient avec un system prompt Kovixel par défaut
   - Bean EmbeddingModel (pour la suite)

4. Crée .env.example à la racine avec :
   ANTHROPIC_API_KEY=your_key_here
   DB_PASSWORD=postgres

5. Mets à jour le README.md avec les instructions pour configurer 
   la clé API Anthropic.
```

### Prompt 1.2 — Service de résumé PDF complet

```
Implémente (ou complète si elle existe déjà) la feature de résumé PDF.

Dans com.kovixel.ai.summary :

1. SummaryController.java
   POST /api/v1/documents/summarize
   - Accepte un MultipartFile (PDF uniquement, max 20MB)
   - Valide le type MIME (application/pdf)
   - Retourne SummaryResponse immédiatement (sans job async pour l'instant)

   GET /api/v1/documents/{documentId}/summary
   - Récupère un résumé existant depuis la base

2. SummaryService.java
   - Extrait le texte du PDF avec PDFBox (déjà dans le projet !)
   - Si le texte > 100 000 chars : tronque intelligemment (intro + conclusion)
   - Appelle Claude via le ChatClient Spring AI avec un prompt structuré :
     * Résumé exécutif (3-5 phrases)
     * Points clés (5-10 bullets)
     * Thèmes principaux
     * Langage de détection automatique
   - Sauvegarde en base (entity Document + Summary)
   - Utilise @Retryable (spring-retry déjà présent !) pour les appels IA

3. Document.java et Summary.java (entities JPA)
   Document : id (UUID), fileName, fileSize, contentHash (SHA-256), uploadedAt, userId
   Summary : id, documentId, content (TEXT), language, model, tokensUsed, createdAt

4. SummaryResponse.java (DTO avec MapStruct mapper)

5. Migration Flyway V2__create_documents_summary.sql

Utilise le SHA-256 du contenu PDF comme clé d'idempotence :
si le même PDF est uploadé deux fois, retourne le résumé existant.
```

---

## ÉTAPE 2 — Q&A SUR LES DOCUMENTS (RAG)

**Durée : 3-4 jours | Priorité : HAUTE — feature virale**

### Prompt 2.1 — Activation de pgvector sur PostgreSQL

```
Prépare la base de données PostgreSQL pour le RAG avec pgvector.

1. Crée la migration Flyway V3__enable_pgvector.sql :

   -- Active l'extension pgvector
   CREATE EXTENSION IF NOT EXISTS vector;
   
   -- Table pour les chunks de documents
   CREATE TABLE document_chunks (
       id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
       document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
       content TEXT NOT NULL,
       embedding vector(1536),  -- dimension pour text-embedding-3-small
       chunk_index INTEGER NOT NULL,
       metadata JSONB,
       created_at TIMESTAMP DEFAULT NOW()
   );
   
   -- Index pour la recherche par similarité cosinus
   CREATE INDEX ON document_chunks 
   USING ivfflat (embedding vector_cosine_ops)
   WITH (lists = 100);
   
   -- Index sur document_id pour les suppressions
   CREATE INDEX idx_chunks_document_id ON document_chunks(document_id);

2. Vérifie dans application.yml que la config pgvector est correcte :
   spring:
     ai:
       vectorstore:
         pgvector:
           index-type: IVFFLAT
           distance-type: COSINE_DISTANCE
           dimensions: 1536

3. Documente comment activer pgvector sur une install PostgreSQL locale :
   Commande : CREATE EXTENSION vector; (dans psql en tant que superuser)
   Et comment vérifier : SELECT * FROM pg_extension WHERE extname = 'vector';
```

### Prompt 2.2 — Pipeline d'ingestion de documents

```
Crée le pipeline d'ingestion de documents pour alimenter le vector store.

Dans com.kovixel.ai.qna :

1. DocumentIngestionService.java (@Service)
   
   Méthode : ingestDocument(UUID documentId)
   
   Algorithme :
   a. Charge le PDF depuis le Document en base (ou depuis le stockage)
   b. Extrait le texte complet avec PDFBox (déjà dispo dans le projet)
   c. Découpe en chunks :
      - Taille : 800 tokens max (~3200 chars)
      - Overlap : 100 tokens (~400 chars) pour conserver le contexte
      - Stratégie : coupe sur les fins de phrases (. ! ?)
   d. Génère les embeddings par batch de 10 avec Spring AI EmbeddingModel
   e. Sauvegarde dans la table document_chunks
   f. Met à jour le Document avec ingested=true + ingestedAt
   
   Utilise @Retryable pour les appels d'embedding (spring-retry déjà là !)

2. TextChunker.java (utilitaire)
   - Méthode chunk(String text, int chunkSize, int overlap) : List<String>
   - Respect des fins de phrases
   - Filtre les chunks vides ou trop courts (<50 chars)

3. Ajoute une colonne à la migration :
   V4__add_ingestion_fields.sql :
   ALTER TABLE documents ADD COLUMN ingested BOOLEAN DEFAULT FALSE;
   ALTER TABLE documents ADD COLUMN ingested_at TIMESTAMP;

Note : pour l'instant, on stocke le contenu PDF en mémoire (pas de S3).
On ajoutera le stockage fichiers à l'Étape 6.
```

### Prompt 2.3 — Service Q&A avec sessions de conversation

```
Crée le service de Q&A complet sur des documents PDF.

Dans com.kovixel.ai.qna :

1. QnaService.java
   
   Méthode : askQuestion(QnaRequest request) : QnaResponse
   
   request contient : documentId, question, sessionId (nullable)
   
   Algorithme RAG :
   a. Si le document n'est pas encore ingéré : appelle ingestDocument() d'abord
   b. Génère l'embedding de la question avec EmbeddingModel
   c. Recherche les 5 chunks les plus proches dans PostgreSQL :
      SELECT content FROM document_chunks 
      WHERE document_id = :documentId
      ORDER BY embedding <=> :queryEmbedding 
      LIMIT 5
   d. Construit le prompt RAG :
      - System : "Tu es un assistant qui répond uniquement à partir du contexte fourni..."
      - Context : les 5 chunks concaténés
      - Question : la question de l'utilisateur
   e. Appelle Claude via ChatClient
   f. Sauvegarde la question + réponse dans qna_messages
   g. Retourne QnaResponse : { answer, sources, sessionId, confidence }

2. QnaController.java
   POST /api/v1/documents/{documentId}/ask
   Body : { "question": "...", "sessionId": "..." }
   
   GET /api/v1/documents/{documentId}/sessions/{sessionId}/history
   → Retourne l'historique complet de la session

3. QnaSession.java (entity) : id (UUID), documentId, userId, createdAt, lastActivityAt
   QnaMessage.java (entity) : id, sessionId, role (USER/ASSISTANT), content, createdAt

4. Migration V5__create_qna_tables.sql avec les 2 tables

5. Dans QnaController, ajoute la validation :
   - Question max 500 caractères (@Size)
   - Document doit exister (@Valid)
   - L'utilisateur doit posséder le document (vérif userId)

Le sessionId est généré côté serveur si null (UUID.randomUUID()).
Inclus un test d'intégration simple avec @SpringBootTest.
```

---

## ÉTAPE 3 — EXTRACTION DE DONNÉES STRUCTURÉES 

**Durée : 2-3 jours | ROI direct pour les entreprises**

### Prompt 3.1 — Moteur d'extraction avec schémas

```
Crée le système d'extraction de données structurées depuis les PDFs.

Dans com.kovixel.ai.extraction :

1. ExtractionService.java
   
   Méthode : extract(UUID documentId, ExtractionRequest request) : ExtractionResult
   
   request contient : templateId (nullable) ou fields (List<ExtractionField>)
   
   ExtractionField : { name, description, type (STRING/NUMBER/DATE/BOOLEAN/LIST), required }
   
   Algorithme :
   a. Charge le texte du document (depuis chunks ou re-extraction PDFBox)
   b. Si templateId → charge le template prédéfini depuis la base
   c. Construit un prompt qui demande à Claude de répondre UNIQUEMENT en JSON :
      "Extrais les données suivantes du document. 
       Réponds UNIQUEMENT avec un JSON valide, sans markdown ni explication.
       Champs à extraire : [...]"
   d. Force claude-sonnet avec temperature=0 pour la précision
   e. Parse le JSON retourné et valide les champs requis
   f. Sauvegarde le résultat en base (entity ExtractionResult)
   g. Retourne ExtractionResult : { fields: Map<String,Object>, confidence, rawJson }

2. Templates prédéfinis (seeds en base via Flyway) :
   - INVOICE : numero, date, montant_ht, tva, montant_ttc, vendeur, client
   - CONTRACT : parties, date_debut, date_fin, objet, valeur_contrat
   - CV_RESUME : nom, email, telephone, competences (list), experiences (list)
   - MEDICAL : patient, date, diagnostic, medicaments (list), medecin

3. ExtractionController.java
   POST /api/v1/documents/{documentId}/extract
   Body : { "templateId": "INVOICE" } ou { "fields": [...] }
   
   GET /api/v1/extraction-templates → liste des templates disponibles
   
   GET /api/v1/documents/{documentId}/extractions → historique des extractions

4. Migration V6__create_extraction_tables.sql :
   - extraction_templates (id, name, description, fields_schema JSONB)
   - extraction_results (id, document_id, template_id, result JSONB, created_at)
   + INSERT des 4 templates prédéfinis

Utilise @Retryable avec maxAttempts=3 pour les appels Claude.
```

### Prompt 3.2 — Export multi-format

```
Ajoute l'export des résultats d'extraction en plusieurs formats.

1. Ajoute dans pom.xml :
   <!-- Excel -->
   <dependency>
     <groupId>org.apache.poi</groupId>
     <artifactId>poi-ooxml</artifactId>
     <version>5.3.0</version>
   </dependency>
   <!-- CSV -->
   <dependency>
     <groupId>com.opencsv</groupId>
     <artifactId>opencsv</artifactId>
     <version>5.9</version>
   </dependency>

2. ExportService.java (com.kovixel.ai.extraction)
   
   - toJson(ExtractionResult) : byte[] → JSON formaté
   - toCsv(ExtractionResult) : byte[] → CSV avec en-têtes
   - toExcel(ExtractionResult) : byte[] → XLSX avec :
     * En-tête coloré (bleu Kovixel #2563EB)
     * Colonnes auto-dimensionnées
     * Feuille "Résultat" + feuille "Métadonnées"
   
3. Ajoute dans ExtractionController :
   GET /api/v1/extractions/{extractionId}/export?format=json|csv|xlsx
   
   Retourne ResponseEntity<byte[]> avec les bons headers :
   - Content-Type approprié
   - Content-Disposition: attachment; filename="extraction_[id].[ext]"

Test : crée un test unitaire qui génère un Excel et vérifie 
que les données sont dans les bonnes cellules.
```

---

## ÉTAPE 4 — CACHE REDIS + JOBS ASYNC 

**Durée : 2 jours | Réduction de 70% des coûts IA**

### Prompt 4.1 — Intégration Redis

```
Ajoute Redis pour cacher les réponses IA coûteuses dans Kovixel.

1. Dans pom.xml :
   <dependency>
     <groupId>org.springframework.boot</groupId>
     <artifactId>spring-boot-starter-data-redis</artifactId>
   </dependency>
   <dependency>
     <groupId>org.springframework.boot</groupId>
     <artifactId>spring-boot-starter-cache</artifactId>
   </dependency>

2. RedisConfig.java (com.kovixel.config)
   - RedisCacheManager avec TTL par cache :
     * "summaries" : 7 jours
     * "extractions" : 7 jours  
     * "qna" : 24 heures
   - Sérialisation JSON (GenericJackson2JsonRedisSerializer)
   - Pas de Java serialization (ne fonctionne pas en upgrade)

3. Dans application.yml :
   spring:
     cache:
       type: redis
     data:
       redis:
         host: ${REDIS_HOST:localhost}
         port: ${REDIS_PORT:6379}
         password: ${REDIS_PASSWORD:}

4. Annote les méthodes existantes :
   - SummaryService.summarize() → @Cacheable(value="summaries", key="#contentHash")
   - ExtractionService.extract() → @Cacheable(value="extractions", key="#documentId+#templateId")
   - @CacheEvict sur toutes les méthodes de suppression de document

5. CacheKeyGenerator.java : génère des clés de cache basées sur SHA-256
   du contenu PDF (pour l'idempotence entre uploads du même fichier)

6. Mets à jour docker-compose.yml pour ajouter Redis :
   redis:
     image: redis:7-alpine
     ports: ["6379:6379"]
```

### Prompt 4.2 — Traitement asynchrone des jobs IA

```
Implémente un système de jobs asynchrones pour les opérations IA longues.

Dans com.kovixel.infra.queue :

1. AiJob.java (entity JPA)
   Champs :
   - id UUID, type (SUMMARY/INGEST/QNA/EXTRACTION)
   - status (PENDING/PROCESSING/DONE/FAILED)
   - documentId UUID, userId UUID
   - payload TEXT (JSON serialisé)
   - result TEXT (JSON résultat)
   - errorMessage TEXT
   - attempts INTEGER (default 0, max 3)
   - createdAt, startedAt, completedAt TIMESTAMP

2. AiJobService.java
   - submitJob(AiJobType, UUID documentId, Object payload) : UUID jobId
     → Sauvegarde en base avec status PENDING
     → Publie sur ApplicationEvent Spring (pas RabbitMQ pour l'instant)
     → Retourne le jobId immédiatement
   
   - getJobStatus(UUID jobId) : JobStatusResponse
     → { jobId, status, result (si DONE), errorMessage (si FAILED), progress }

3. AiJobProcessor.java (@Component)
   - @Async + @EventListener(AiJobEvent.class)
   - Dispatch vers le bon service (SummaryService, ExtractionService...)
   - Met à jour le status en base
   - @Retryable(maxAttempts=3) sur les appels IA
   - En cas d'échec définitif : status=FAILED + log l'erreur

4. JobController.java
   POST /api/v1/jobs → soumet un job async
   GET /api/v1/jobs/{jobId} → status + résultat (polling)
   GET /api/v1/jobs/my → liste des jobs de l'utilisateur (paginée)

5. Migration V7__create_ai_jobs.sql

6. Active @EnableAsync dans la classe principale ou une @Configuration.
   ThreadPoolTaskExecutor avec : corePoolSize=5, maxPoolSize=20, queueCapacity=100

Note : on utilise des ApplicationEvents Spring (pas RabbitMQ) pour rester simple.
RabbitMQ sera ajouté quand le trafic nécessitera plusieurs instances.
```

---

## ÉTAPE 5 — GESTION DES PLANS & QUOTAS 

**Durée : 2 jours | Obligatoire avant le lancement public**

### Prompt 5.1 — Système de plans freemium

```
Implémente le système de plans et de quotas pour Kovixel.
La sécurité JWT est déjà en place, on s'appuie dessus.

Dans com.kovixel.user :

1. UserPlan.java (enum) : FREE, PRO, ENTERPRISE
   
   PlanConfig.java (record) :
   - maxSummariesPerDay (FREE=5, PRO=100, ENTERPRISE=-1)
   - maxQnaPerDay (FREE=10, PRO=500, ENTERPRISE=-1)
   - maxExtractionsPerDay (FREE=2, PRO=50, ENTERPRISE=-1)
   - maxFileSizeMb (FREE=10, PRO=100, ENTERPRISE=500)
   - workflowsEnabled (FREE=false, PRO=true, ENTERPRISE=true)

2. Ajoute dans la table users (migration V8__add_plan_to_users.sql) :
   ALTER TABLE users ADD COLUMN plan VARCHAR(20) DEFAULT 'FREE';
   ALTER TABLE users ADD COLUMN plan_expires_at TIMESTAMP;

3. QuotaService.java
   - checkAndIncrementQuota(UUID userId, FeatureType feature) : void
     → Lit le compteur depuis Redis : "quota:{userId}:{feature}:{date}"
     → Si >= limite du plan : lance PlanLimitExceededException
     → Sinon : INCR atomique sur Redis (expire à minuit)
   
   - getRemainingQuota(UUID userId) : QuotaStatusResponse
     → Retourne les quotas restants par feature

4. QuotaCheckAspect.java (@Aspect)
   - @Before sur toute méthode annotée avec @CheckQuota(feature=FeatureType.SUMMARY)
   - Injecte QuotaService et appelle checkAndIncrementQuota()
   - spring-aspects est déjà dans le projet !

5. Annote les méthodes des services :
   @CheckQuota(feature = FeatureType.SUMMARY) sur SummaryService.summarize()
   @CheckQuota(feature = FeatureType.QNA) sur QnaService.askQuestion()
   @CheckQuota(feature = FeatureType.EXTRACTION) sur ExtractionService.extract()

6. Gestion de l'erreur dans GlobalExceptionHandler :
   PlanLimitExceededException → HTTP 429 avec body :
   { "errorCode": "PLAN_LIMIT_EXCEEDED", "feature": "SUMMARY", 
     "limit": 5, "upgradeUrl": "/pricing" }
```

### Prompt 5.2 — Tracking d'usage et métriques

```
Ajoute le tracking d'usage pour analytics et facturation future.

1. UsageRecord.java (entity JPA)
   Champs : id, userId, feature, tokensUsed, costUsd (calculé), 
            documentId, createdAt, planAtTime, responseTimeMs

2. UsageService.java
   - recordUsage(UsageRecord) : async (ne doit pas ralentir la réponse)
   - getMyUsage(UUID userId, Period period) : UsageSummaryResponse
     → Total par feature, tokens consommés, coût estimé

3. Ajoute dans SummaryService, QnaService, ExtractionService :
   Après chaque appel Claude réussi :
   usageService.recordUsage(UsageRecord.builder()
       .userId(userId)
       .feature(FeatureType.SUMMARY)
       .tokensUsed(response.getMetadata().getUsage().getTotalTokens())
       .costUsd(calculateCost(tokensUsed))
       .build());

4. UsageController.java
   GET /api/v1/usage/me → usage du jour / mois
   GET /api/v1/usage/me/history?period=MONTH → historique

5. Migration V9__create_usage_records.sql

Formule coût : claude-sonnet-4-5 = $3/M tokens input + $15/M tokens output
Stocke en micro-dollars (Long) pour éviter les float.
```

---

## ÉTAPE 6 — STOCKAGE FICHIERS & PRODUCTION <---------------------- CONTINUER A PARTIR D'ICI

**Durée : 2 jours**

### Prompt 6.1 — Stockage de fichiers

```
Ajoute le stockage de fichiers PDF pour Kovixel.
Pour le dev local : stockage sur disque.
Pour la prod : MinIO (S3-compatible, auto-hébergeable).

1. Dans pom.xml :
   <dependency>
     <groupId>io.minio</groupId>
     <artifactId>minio</artifactId>
     <version>8.5.7</version>
   </dependency>

2. FileStorageService.java (interface)
   - store(MultipartFile file, String key) : String (URL/path)
   - retrieve(String key) : InputStream
   - delete(String key) : void

3. LocalFileStorageService.java (@Profile("dev"))
   - Stocke dans ${STORAGE_PATH:./uploads}
   - Retourne le chemin relatif

4. MinioFileStorageService.java (@Profile("prod"))
   - Bucket : "kovixel-documents"
   - Clé : "{userId}/{documentId}/{fileName}"
   - Génère des URLs pré-signées (valides 1 heure)

5. Mets à jour Document.java :
   - Ajoute storageKey (chemin/clé du fichier)
   - Ajoute storageUrl (URL d'accès)

6. Dans SummaryService et DocumentIngestionService :
   - Utilise FileStorageService.retrieve() au lieu de re-parser 
     le MultipartFile (qui n'est plus disponible)

7. Mets à jour docker-compose.yml avec MinIO :
   minio:
     image: minio/minio
     command: server /data --console-address ":9001"
     ports: ["9000:9000", "9001:9001"]
     environment:
       MINIO_ROOT_USER: kovixel
       MINIO_ROOT_PASSWORD: kovixel123
```

### Prompt 6.2 — Docker Compose complet et README

```
Crée un docker-compose.yml complet pour lancer tout l'environnement Kovixel en local.

1. docker-compose.yml avec :
   
   postgres:
     image: ankane/pgvector:latest  # PostgreSQL + pgvector préinstallé
     environment: POSTGRES_DB=kovixel_db, POSTGRES_PASSWORD=postgres
     volumes: [postgres_data:/var/lib/postgresql/data]
     ports: ["5432:5432"]
   
   redis:
     image: redis:7-alpine
     ports: ["6379:6379"]
   
   minio:
     image: minio/minio
     command: server /data --console-address ":9001"
     ports: ["9000:9000", "9001:9001"]
   
   kovixel-app:
     build: .
     environment:
       - SPRING_PROFILES_ACTIVE=dev
       - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
       - SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/kovixel_db
       - SPRING_DATA_REDIS_HOST=redis
     depends_on: [postgres, redis, minio]
     ports: ["8080:8080"]

2. Dockerfile multi-stage pour Spring Boot :
   Stage 1 : maven:3.9-eclipse-temurin-21 → mvn package -DskipTests
   Stage 2 : eclipse-temurin:21-jre-alpine → COPY le jar
   ENTRYPOINT avec --enable-preview (car le projet l'utilise)
   Utilisateur non-root pour la sécurité

3. .env.example :
   ANTHROPIC_API_KEY=sk-ant-...
   DB_PASSWORD=postgres
   REDIS_PASSWORD=
   MINIO_ROOT_PASSWORD=kovixel123

4. Mets à jour README.md avec :
   ## Démarrage rapide
   1. cp .env.example .env (et renseigner ANTHROPIC_API_KEY)
   2. docker-compose up -d
   3. Swagger UI : http://localhost:8080/swagger-ui/index.html
   4. MinIO Console : http://localhost:9001 (kovixel/kovixel123)
```

---

## ORDRE D'EXÉCUTION RECOMMANDÉ DANS CLAUDE CODE

```
SEMAINE 1 (fondations solides)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Jour 1 : Prompt 0.1 → 0.2 → 0.3 (sécurité + Flyway + exceptions)
Jour 2 : Prompt 1.1 → 1.2 (Spring AI + résumé complet)
Jour 3 : Tests + debug + vérification Swagger

SEMAINE 2 (feature virale)
━━━━━━━━━━━━━━━━━━━━━━━━━━
Jour 1-2 : Prompt 2.1 → 2.2 (pgvector + ingestion)
Jour 3-4 : Prompt 2.3 (Q&A complet)
Jour 5 : Tests + fine-tuning des prompts RAG

SEMAINE 3 (monétisation)
━━━━━━━━━━━━━━━━━━━━━━━━
Jour 1-2 : Prompt 3.1 → 3.2 (extraction + export)
Jour 3 : Prompt 4.1 (Redis cache)
Jour 4 : Prompt 5.1 → 5.2 (plans + quotas)
Jour 5 : Prompt 6.2 (Docker + déploiement)

SEMAINE 4 (polish + launch)
━━━━━━━━━━━━━━━━━━━━━━━━━━━
Tests d'intégration complets, fix bugs, déploiement staging
```

---

## DÉPENDANCES À AJOUTER AU pom.xml (résumé)

```xml
<!-- Spring AI BOM (dans dependencyManagement) -->
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-bom</artifactId>
  <version>1.0.0</version>
  <type>pom</type>
  <scope>import</scope>
</dependency>

<!-- Spring AI Anthropic -->
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-anthropic-spring-boot-starter</artifactId>
</dependency>

<!-- Spring AI pgvector -->
<dependency>
  <groupId>org.springframework.ai</groupId>
  <artifactId>spring-ai-pgvector-store-spring-boot-starter</artifactId>
</dependency>

<!-- Redis + Cache -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-cache</artifactId>
</dependency>

<!-- Flyway -->
<dependency>
  <groupId>org.flywaydb</groupId>
  <artifactId>flyway-core</artifactId>
</dependency>
<dependency>
  <groupId>org.flywaydb</groupId>
  <artifactId>flyway-database-postgresql</artifactId>
</dependency>

<!-- Apache POI (Excel) -->
<dependency>
  <groupId>org.apache.poi</groupId>
  <artifactId>poi-ooxml</artifactId>
  <version>5.3.0</version>
</dependency>

<!-- OpenCSV -->
<dependency>
  <groupId>com.opencsv</groupId>
  <artifactId>opencsv</artifactId>
  <version>5.9</version>
</dependency>

<!-- MinIO (stockage fichiers) -->
<dependency>
  <groupId>io.minio</groupId>
  <artifactId>minio</artifactId>
  <version>8.5.7</version>
</dependency>

<!-- Testcontainers (tests d'intégration) -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-testcontainers</artifactId>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>postgresql</artifactId>
  <scope>test</scope>
</dependency>
```

---

## MIGRATIONS FLYWAY (ordre)

```
V1__init_users_table.sql         ← tables users/roles existantes
V2__create_documents_summary.sql ← documents + summaries
V3__enable_pgvector.sql          ← extension + document_chunks
V4__add_ingestion_fields.sql     ← documents.ingested
V5__create_qna_tables.sql        ← qna_sessions + qna_messages
V6__create_extraction_tables.sql ← extraction_templates + results
V7__create_ai_jobs.sql           ← ai_jobs
V8__add_plan_to_users.sql        ← users.plan
V9__create_usage_records.sql     ← usage_records
```

---

## CONSEIL CRITIQUE

> **Commencez AUJOURD'HUI par le Prompt 0.1** dans Claude Code (IntelliJ).
>
> Votre projet a une bonne base (JWT ✅, PDFBox ✅, spring-retry ✅).
> Le principal manque c'est Spring AI — une fois ajouté (Prompt 1.1),
> les features IA s'enchaînent rapidement.
>
> La feature Q&A (Étape 2) est votre **levier viral** : quand un utilisateur
> peut "parler" à son document, il le partage immédiatement.
> C'est ça qui génère les millions d'utilisateurs, pas le résumé.

---


########################################## SPRING CORE CONVERSIONS ########################################

## Prompt C.1 — Moteur de conversion PDF
Dans mon projet Spring Boot Kovixel (com.kovixel.core.conversion),
implémente le moteur de conversion de fichiers PDF.

1. Dans pom.xml, ajoute :
   <!-- PDF ↔ Word -->
   <dependency>
     <groupId>org.apache.poi</groupId>
     <artifactId>poi-ooxml</artifactId>
     <version>5.3.0</version>
   </dependency>
   <dependency>
     <groupId>fr.opensagres.xdocreport</groupId>
     <artifactId>fr.opensagres.poi.xwpf.converter.pdf</artifactId>
     <version>2.0.4</version>
   </dependency>

   <!-- PDF ↔ Image (PDFBox déjà présent ✅) -->
   <!-- PDFBox 3.0.7 gère le rendu en image nativement -->

   <!-- PDF Compress / Merge / Split -->
   <!-- PDFBox suffit pour ces opérations -->

   <!-- Word/Excel → PDF via LibreOffice en mode headless (le plus fiable) -->
   <!-- Pas de dépendance Maven — appel système ProcessBuilder -->

2. ConversionService.java (com.kovixel.core.conversion)

   Méthodes :
   - pdfToWord(byte[] pdf) : byte[]
     → PDFBox extrait le texte et la structure
     → Apache POI reconstruit le .docx
     
   - pdfToImages(byte[] pdf, String format, int dpi) : List<byte[]>
     → PDFBox PDDocument.renderImageWithDPI()
     → format : PNG (défaut, sans perte) ou JPG (plus léger)
     → dpi : 150 (web), 300 (impression)
     
   - pdfToExcel(byte[] pdf) : byte[]
     → PDFBox extrait les tableaux (PDFTextStripper avec régions)
     → Apache POI génère le .xlsx
     
   - imagesToPdf(List<MultipartFile> images) : byte[]
     → PDFBox PDDocument + PDImageXObject
     → Supporte JPG, PNG, WEBP
     
   - wordToPdf(byte[] docx) : byte[]
     → LibreOffice headless : 
       ProcessBuilder("libreoffice", "--headless", "--convert-to", "pdf", file)
     → Meilleure fidélité que toute lib Java pure
     
   - excelToPdf(byte[] xlsx) : byte[]   (même approche LibreOffice)
   - pptToPdf(byte[] pptx) : byte[]     (même approche LibreOffice)

3. PdfManipulationService.java

   - merge(List<byte[]> pdfs) : byte[]
     → PDFBox PDFMergerUtility
     
   - split(byte[] pdf, int[] pageRanges) : List<byte[]>
     → PDFBox Splitter
     → pageRanges : [[1,3],[4,6]] pour deux documents
     
   - compress(byte[] pdf, CompressionLevel level) : byte[]
     → SCREEN (72 dpi), EBOOK (150 dpi), PRINTER (300 dpi)
     → Recompresse les images embarquées avec Thumbnailator
     → Ratio attendu : 50-80% de réduction sur les PDFs scannés
     
   - rotate(byte[] pdf, int pageIndex, int degrees) : byte[]
     → PDFBox PDPage.setRotation()
     
   - extractPages(byte[] pdf, int from, int to) : byte[]

4. ConversionController.java
   
   POST /api/v1/convert/pdf-to-word
   POST /api/v1/convert/pdf-to-images     ?format=png&dpi=150
   POST /api/v1/convert/pdf-to-excel
   POST /api/v1/convert/images-to-pdf
   POST /api/v1/convert/word-to-pdf
   POST /api/v1/convert/excel-to-pdf
   POST /api/v1/convert/ppt-to-pdf
   
   POST /api/v1/pdf/merge                 (multipart, N fichiers)
   POST /api/v1/pdf/split                 ?pages=1-3,4-6
   POST /api/v1/pdf/compress              ?level=EBOOK
   POST /api/v1/pdf/rotate               ?page=1&degrees=90
   
   Tous les endpoints :
   - Acceptent multipart/form-data
   - Retournent le fichier converti en ResponseEntity<byte[]>
   - Content-Disposition: attachment; filename="converted.[ext]"
   - Limite : 50 MB (FREE), 200 MB (PRO) — via @CheckQuota
   - Traitement > 10 MB → job asynchrone (AiJobService)

5. LibreOfficeConfig.java
   - Vérifie que LibreOffice est installé au démarrage (@PostConstruct)
   - Si absent : log WARNING + désactive les conversions Word/Excel/PPT → PDF
   - Chemin configurable : ${LIBREOFFICE_PATH:/usr/bin/libreoffice}

6. ConversionJobHandler.java
   - Intègre avec AiJobService (Étape 4 du plan)
   - Les conversions lourdes (> 10 MB) sont traitées en async
   - Progress : PENDING → PROCESSING → DONE/FAILED
   - Le frontend poll GET /api/v1/jobs/{jobId}

7. Migration Flyway V10__create_conversions_table.sql :
   CREATE TABLE conversions (
     id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
     user_id UUID REFERENCES users(id),
     input_format VARCHAR(10),     -- "PDF", "DOCX", "XLSX"...
     output_format VARCHAR(10),
     input_size_bytes BIGINT,
     output_size_bytes BIGINT,
     status VARCHAR(20),
     file_key TEXT,                -- clé MinIO/S3 du résultat
     created_at TIMESTAMP DEFAULT NOW(),
     expires_at TIMESTAMP          -- auto-suppression après 24h
   );

8. FileCleanupScheduler.java (@Scheduled)
   - Supprime les fichiers convertis de MinIO après expires_at
   - Tourne toutes les heures
   - Log le volume libéré pour le tracking des coûts
   
### Prompt C.2 — Limites par plan et métriques
Pour les conversions Kovixel, intègre les limites de plan et les métriques.

1. Ajoute dans PlanConfig.java :
   - maxConversionsPerDay (FREE=10, PRO=200, ENTERPRISE=-1)
   - maxFileSizeMbConversion (FREE=10, PRO=100, ENTERPRISE=500)
   - libreOfficeEnabled (FREE=false, PRO=true)
     → Les conversions Word/Excel/PPT → PDF nécessitent LibreOffice
     → Feature PRO uniquement (coût CPU élevé)

2. Annote les méthodes ConversionService avec @CheckQuota

3. Métriques Micrometer :
   - kovixel.conversions.total (counter, tags: inputFormat, outputFormat, plan)
   - kovixel.conversions.duration (histogram — perf des conversions)
   - kovixel.conversions.file_size (histogram — taille des fichiers)
   - kovixel.storage.bytes_generated (counter — volume fichiers créés)

4. Ajoute dans UsageService :
   recordConversion(userId, inputFormat, outputFormat, inputSizeBytes, outputSizeBytes)
   → Visible dans GET /api/v1/usage/me (conversions du mois)
*Adapté à github.com/mdao032/kovixel — 23 avril 2026*
*Stack : Spring Boot 3.4.3 · Java 21 · Spring AI 1.0.0 · PostgreSQL + pgvector · Redis*
