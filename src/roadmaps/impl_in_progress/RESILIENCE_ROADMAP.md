# Kovixel — Roadmap Résilience & Disaster Recovery

> **Objectif :** Atteindre un niveau de résilience équivalent aux standards de l'industrie
> (AWS RDS, Supabase, PlanetScale) sur une infrastructure Docker self-hosted.
>
> **Statut (2026-07-22) :** Phase 1 ✅ complète (7/10 atteint). Phase 2 🟡 code prêt sauf WAL
> archiving et canal de notification d'alerte (décisions utilisateur, hors scope), non vérifié
> en conditions réelles (pas de Docker dans l'environnement d'implémentation). Phase 3 ❌ pas
> commencée — voir §5, deux items bloqués sur de l'infra externe non provisionnable depuis le
> code (second site MinIO, load balancer/bascule Cloudflare).
>
> ~~**Statut initial :** Score résilience 3/10 — toute la couche de persistance durable était
> absente, un crash disque ou un `docker rm -v` = perte totale irréversible des données.~~

---

## Table des matières

1. [État des lieux](#1-état-des-lieux)
2. [Cibles RTO / RPO](#2-cibles-rto--rpo)
3. [Phase 1 — Fondations (Backup + Repair)](#3-phase-1--fondations)
4. [Phase 2 — Observabilité & Alerting](#4-phase-2--observabilité--alerting)
5. [Phase 3 — Haute disponibilité](#5-phase-3--haute-disponibilité)
6. [Runbooks Disaster Recovery](#6-runbooks-disaster-recovery)
7. [Décisions d'architecture](#7-décisions-darchitecture)

---

## 1. État des lieux

### 1.1 Ce qui fonctionne bien

| Couche | Mécanisme | Niveau |
|---|---|---|
| Moteurs de conversion | Fallback Adobe → Gotenberg → LibreOffice → PdfBox | ✅ Production-grade |
| IA | Fallback Ollama → Claude API automatique | ✅ Production-grade |
| Transactions | `@Transactional` ACID PostgreSQL 16 sur toutes les entités | ✅ Production-grade |
| Health checks | Spring Actuator + `ConversionEngineHealthIndicator`, `OllamaHealthIndicator` | ✅ Production-grade |
| Retry réseau | Backoff exponentiel 1s→2s→4s sur `status=0` dans `authInterceptor` | ✅ Production-grade |
| Schema | 50 migrations Flyway versionnées, `validate-on-migrate=true` en prod | ✅ Production-grade |

### 1.2 Lacunes critiques

| Couche | Situation actuelle | Impact |
|---|---|---|
| **PostgreSQL** | Volume Docker local, zéro backup automatique | Perte totale sur crash disque |
| **MinIO** | Volume Docker local, pas de versioning, pas de réplication | Perte totale de tous les fichiers utilisateurs |
| **Flyway** | Pas d'endpoint repair admin, pas de backup pré-migration | Downtime indéfini sur migration échouée |
| **Redis** | Aucune persistance documentée (RDB/AOF) | Déconnexion simultanée de tous les utilisateurs |
| **Monitoring** | Prometheus exposé sur `/actuator/metrics` mais non scrapé | Aucune alerte sur défaillance backup |
| **Runbooks** | Aucune procédure DR documentée ni testée | RTO inconnu, panique garantie en incident P0 |

### 1.3 Scénarios de panne détaillés

#### Scénario A — Corruption / perte du volume PostgreSQL
```
Déclencheur : crash disque, docker rm -v accidentel, corruption bloc
├─ pg_checksums désactivé par défaut → corruption silencieuse possible plusieurs jours
├─ Aucun pg_dump disponible → zéro point de restauration
├─ docker-compose down && up → base vide, uniquement les extensions de init.sql
├─ Flyway rejoue les 50 migrations → schéma reconstruit
└─ TOUTES les données utilisateurs (kovixel_users, documents, jobs, subscriptions,
   invoices, signatures, extractions...) sont perdues définitivement.
```

#### Scénario B — Migration Flyway échoue en production (V51+)
```
Déclencheur : DDL partiel, timeout, contrainte FK violée à mi-chemin
├─ Flyway écrit le statut FAILED dans flyway_schema_history
├─ validate-on-migrate=true bloque TOUS les démarrages d'instance suivants
├─ Nouvelle instance Docker → refuse de démarrer immédiatement
├─ DOWNTIME TOTAL : toute l'application est indisponible
├─ Sans backup pré-migration, impossible de revenir à V50
└─ Résolution : flyway repair manuel via accès shell → durée imprévisible
```

#### Scénario C — Perte du volume MinIO
```
Déclencheur : crash disque, suppression accidentelle de minio_data
├─ Bucket kovixel-documents : tous les fichiers physiques disparus
├─ La base de données conserve les metadata (document_id, file_key, taille…)
├─ L'application fonctionne mais toutes les URLs de téléchargement → 404
├─ FileCleanupScheduler tente de supprimer des fichiers inexistants → erreurs
└─ Pas de versioning → un PUT qui écrase un fichier = irrécupérable même avant crash
```

#### Scénario D — Checksum Flyway altéré
```
Déclencheur : reformatage IDE d'un fichier .sql déjà exécuté, correction de typo
├─ validate-on-migrate=true détecte le mismatch de checksum au démarrage
├─ Application refuse de démarrer en production
└─ Résolution : flyway repair en accès shell → aucun endpoint admin disponible
```

#### Scénario E — Redis crash (déconnexion globale)
```
Déclencheur : OOM, crash conteneur, restart
├─ Cache quota/tools/subscription perdu → rechargement automatique depuis PG ✅
├─ MAIS : toutes les sessions utilisateurs invalidées → déconnexion globale simultanée
├─ Rate limiting (checkout, auth) remis à zéro → fenêtre d'exploitation temporaire
└─ AOF non activé → l'état Redis est entièrement volatile
```

---

## 2. Cibles RTO / RPO

| Couche | RTO actuel | RPO actuel | RTO cible Phase 1 | RPO cible Phase 1 |
|---|---|---|---|---|
| PostgreSQL | ∞ (perte totale) | ∞ (0 backup) | **< 30 min** | **< 24h** |
| MinIO / Fichiers | ∞ (perte totale) | ∞ (pas de versioning) | **< 1h** | **< 24h** |
| Flyway (schéma) | Heures (manuel) | N/A (idempotent) | **< 5 min** | N/A |
| Redis / Cache | Secondes (auto-reload) | Acceptable | Secondes | Acceptable |
| Application | < 2 min (Docker restart) | N/A (stateless) | < 1 min | N/A |

> **Phase 2 upgrade :** PostgreSQL WAL archiving → RPO < 5 min (Point-in-Time Recovery)

---

## 3. Phase 1 — Fondations

> **Délai estimé :** 2–3 jours de développement
> **Impact :** Passe le score de résilience de 3/10 à **7/10**

---

### ⚠️ PRÉ-REQUIS OBLIGATOIRES (à implémenter avant tout le reste)

Ces deux correctifs sont des dépendances bloquantes découvertes lors de la validation
du roadmap. Sans eux, les endpoints admin ne fonctionneront pas et le backup échouera
silencieusement au démarrage.

---

#### PRÉ-REQUIS 1 — Ajouter `postgresql-client` dans le Dockerfile

**Problème :** `eclipse-temurin:21-jre-jammy` (image runtime) ne contient pas les
outils client PostgreSQL. La commande `pg_dump` n'est pas disponible dans le container
applicatif. Sans ce paquet, tout le système de backup planté dès la première exécution.

**Fichier :** `kovixel/Dockerfile`

Dans le bloc `apt-get install` existant (stage `runtime`), ajouter `postgresql-client` :

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client \        # ← NOUVEAU : pg_dump, pg_restore, psql
      libreoffice-writer \
      libreoffice-calc \
      # ... reste inchangé
```

`postgresql-client` dans Ubuntu 22.04 (jammy) installe les outils compatibles
PostgreSQL 14 par défaut. Pour forcer pg16 (cohérent avec le serveur) :

```dockerfile
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         lsb-release curl gnupg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] \
         https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
```

> **Note :** la version du client (`pg_dump`) doit être ≥ à la version du serveur (pg16).
> Un client pg14 dumpant un serveur pg16 génère une erreur de version.

---

#### PRÉ-REQUIS 2 — Mapper `Role` → `GrantedAuthority` dans `UserDetailsServiceImpl`

**Problème :** `UserDetailsServiceImpl.loadUserByUsername()` retourne actuellement
`new ArrayList<>()` comme liste d'authorities. Le champ `User.role` (enum `Role.ADMIN`
/ `Role.USER`) n'est jamais converti en `GrantedAuthority`. Résultat :
`.hasRole("ADMIN")` dans `SecurityConfig` bloque **tout le monde** y compris les
vrais admins, car le Spring Security `hasRole("ADMIN")` cherche `ROLE_ADMIN` dans
la liste des granted authorities — liste qui est vide.

**Fichier :** `common/security/UserDetailsServiceImpl.java`

```java
@Override
public UserDetails loadUserByUsername(String username) throws UsernameNotFoundException {
    User user = userRepository.findByEmail(username)
            .orElseThrow(() -> new UsernameNotFoundException("User not found: " + username));

    // Mapper Role enum → ROLE_USER / ROLE_ADMIN (convention Spring Security)
    List<GrantedAuthority> authorities = new ArrayList<>();
    if (user.getRole() != null) {
        authorities.add(new SimpleGrantedAuthority("ROLE_" + user.getRole().name()));
    }

    return new org.springframework.security.core.userdetails.User(
            user.getEmail(),
            user.getPassword() != null ? user.getPassword() : "",
            authorities   // ← était new ArrayList<>()
    );
}
```

Imports à ajouter :
```java
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import java.util.List;
```

> **Impact collatéral :** Ce fix est non-breaking pour les utilisateurs `Role.USER`
> car les routes existantes n'utilisent pas `hasRole()`. Il active uniquement la
> possibilité d'utiliser les routes `/api/v1/admin/**` pour les utilisateurs ADMIN.

---

### 3.1 Backup PostgreSQL automatique

#### 3.1.1 Nouveau package : `com.kovixel.infra.backup`

```
src/main/java/com/kovixel/infra/backup/
├── BackupProperties.java              ← @ConfigurationProperties("kovixel.backup")
├── BackupRecord.java                  ← entité JPA (table kovixel_backup_records)
├── BackupRecordRepository.java        ← Spring Data JPA
├── BackupService.java                 ← orchestration pg_dump + chiffrement + upload
├── BackupHealthIndicator.java         ← Spring Actuator health indicator
└── BackupAdminController.java         ← REST admin
```

#### 3.1.2 `BackupProperties` et enregistrement

**Fichier :** `infra/backup/BackupProperties.java`
```java
@ConfigurationProperties(prefix = "kovixel.backup")
@Validated
public class BackupProperties {
    private boolean enabled = true;
    private String cron = "0 0 2 * * *";
    @Min(1) @Max(365)
    private int retentionDays = 30;
    private String bucket = "kovixel-backups";
    private String encryptionKey;   // base64, 32 bytes décodés → AES-256
    private String pgDumpPath = "pg_dump";
    private long maxDurationMs = 1_800_000L;
    // getters/setters ou @Data Lombok
}
```

**Enregistrement dans `KovixelApplication.java`** (liste explicite déjà en place) :
```java
@EnableConfigurationProperties({ EnvironmentProperties.class, BackupProperties.class })
```

#### 3.1.3 `BackupService` — spécifications

**Stratégie :**
- `@Scheduled(cron = "#{@backupProperties.cron}")` — configurable par env var
- `pg_dump` via `ProcessBuilder` (même pattern que `GhostscriptCompressor.java`)
- Format : `--format=custom --compress=9` → restaurable avec `pg_restore`
- Chiffrement : AES-256-GCM via `javax.crypto` — IV aléatoire 12 bytes (GCM standard)
- L'IV est **concaténé en préfixe du fichier** : `[12 bytes IV][ciphertext+auth_tag]`
- Destination : bucket `kovixel-backups`, clé `db/YYYY/MM/kovixel_YYYYMMDD_HHmmss.dump.enc`
- Rétention : lifecycle policy MinIO (configurée au démarrage)
- Checksum SHA-256 du fichier chiffré stocké dans `BackupRecord.checksum_sha256`

**Flux complet :**
```
1. Créer fichier temporaire dans /tmp/kovixel-backup-{uuid}.dump
2. Construire commande pg_dump avec PGPASSWORD dans l'environnement du ProcessBuilder
3. pg_dump --host --port --username --format=custom --compress=9 --no-password --dbname
4. Lire le .dump → chiffrer AES-256-GCM → écrire [IV|ciphertext] dans .dump.enc
5. Calculer SHA-256 de .dump.enc
6. Upload MinIO : kovixel-backups/db/YYYY/MM/kovixel_{timestamp}.dump.enc
7. Persister BackupRecord (statut SUCCESS, taille, checksum, durée, version Flyway)
8. Supprimer les deux fichiers temporaires (bloc finally — garanti même sur erreur)
9. Si erreur à n'importe quelle étape : persister BackupRecord FAILED + log ERROR
```

**Connexion pg_dump :**
```
Env : PGPASSWORD=${DB_PASSWORD}

pg_dump \
  --host=${DB_HOST} \
  --port=${DB_PORT} \
  --username=${DB_USERNAME} \
  --format=custom \
  --compress=9 \
  --no-password \
  --dbname=${DB_NAME} \
  --file=/tmp/kovixel-backup-{uuid}.dump
```

Le mot de passe est transmis via la variable d'environnement `PGPASSWORD` injectée
dans `ProcessBuilder.environment()` — jamais en argument CLI (évite l'exposition
dans `ps aux`).

**Récupération de la version Flyway courante (pour `BackupRecord.flyway_version`) :**
```java
// Injecter Flyway dans BackupService
@Autowired private Flyway flyway;

// Dans la méthode de backup :
MigrationInfo current = flyway.info().current();
String flywayVersion = (current != null) ? current.getVersion().getVersion() : "unknown";
```

#### 3.1.4 Chiffrement AES-256-GCM — détail d'implémentation

```java
// CHIFFREMENT (dans BackupService)
byte[] keyBytes = Base64.getDecoder().decode(backupProperties.getEncryptionKey());
// keyBytes doit être exactement 32 bytes (AES-256)

SecretKey secretKey = new SecretKeySpec(keyBytes, "AES");
byte[] iv = new byte[12]; // GCM standard : 12 bytes
new SecureRandom().nextBytes(iv);

Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
cipher.init(Cipher.ENCRYPT_MODE, secretKey, new GCMParameterSpec(128, iv));

byte[] encrypted = cipher.doFinal(plainBytes);

// Format fichier .enc : [12 bytes IV][encrypted+auth_tag]
try (FileOutputStream fos = new FileOutputStream(encFile)) {
    fos.write(iv);        // 12 bytes préfixe
    fos.write(encrypted); // ciphertext + 16 bytes GCM auth tag
}

// DÉCHIFFREMENT (outil de restauration — voir Runbook 1)
byte[] fileBytes = Files.readAllBytes(encFile.toPath());
byte[] iv = Arrays.copyOfRange(fileBytes, 0, 12);
byte[] ciphertext = Arrays.copyOfRange(fileBytes, 12, fileBytes.length);

Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
cipher.init(Cipher.DECRYPT_MODE, secretKey, new GCMParameterSpec(128, iv));
byte[] decrypted = cipher.doFinal(ciphertext);
```

> **⚠️ Note :** Ce format (Java AES/GCM/NoPadding) est **incompatible** avec la commande
> `openssl enc -d -aes-256-gcm`. Les runbooks de restauration utilisent donc un script
> Java standalone (`BackupDecryptTool.java`) ou Python — jamais openssl directement.

**Format de la clé `BACKUP_ENCRYPTION_KEY` :**
- Valeur : string Base64 encodant exactement **32 bytes** (256 bits)
- Génération : `openssl rand -base64 32`
- Stockage : dans le gestionnaire de secrets (1Password, Vault) — **jamais dans MinIO**
- La perte de cette clé = backups irrécupérables

#### 3.1.5 `BackupRecord` — entité JPA

Migration Flyway **V51__create_backup_records.sql** :

```sql
CREATE TABLE IF NOT EXISTS kovixel_backup_records (
    id              BIGSERIAL PRIMARY KEY,
    type            VARCHAR(20)  NOT NULL DEFAULT 'FULL',      -- FULL | PRE_MIGRATION | MANUAL
    trigger_source  VARCHAR(20)  NOT NULL DEFAULT 'SCHEDULED', -- SCHEDULED | MANUAL | PRE_MIGRATION
    status          VARCHAR(20)  NOT NULL,                      -- PENDING | SUCCESS | FAILED
    started_at      TIMESTAMPTZ  NOT NULL,
    completed_at    TIMESTAMPTZ,
    duration_ms     BIGINT,
    file_key        VARCHAR(512),                               -- clé MinIO kovixel-backups
    file_size_bytes BIGINT,
    checksum_sha256 VARCHAR(64),                               -- SHA-256 du fichier chiffré
    error_message   TEXT,
    flyway_version  VARCHAR(20),                               -- version Flyway au moment du backup
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_backup_records_status      ON kovixel_backup_records(status);
CREATE INDEX idx_backup_records_started_at  ON kovixel_backup_records(started_at DESC);
CREATE INDEX idx_backup_records_type        ON kovixel_backup_records(type);
```

#### 3.1.6 `BackupAdminController` — endpoints REST

Sécurité : `hasRole('ADMIN')` — nécessite le PRÉ-REQUIS 2 (UserDetailsServiceImpl fix).
Règle SecurityConfig : `.requestMatchers("/api/v1/admin/**").hasRole("ADMIN")`.

```
POST   /api/v1/admin/backups/trigger
  Body  : { "reason": "pre-deployment" }         (optionnel)
  Return: { "backupId": 42, "status": "PENDING" }
  Note  : exécution asynchrone via @Async pour ne pas bloquer le thread HTTP

GET    /api/v1/admin/backups
  Params: ?page=0&size=20&status=SUCCESS
  Return: Page<BackupRecordDto>

GET    /api/v1/admin/backups/latest
  Return: BackupRecordDto (dernier backup SUCCESS)

GET    /api/v1/admin/backups/{id}
  Return: BackupRecordDto détaillé

GET    /api/v1/admin/backups/health
  Return: { "lastSuccess": "2025-06-26T02:00:00Z", "hoursSince": 22.5, "status": "OK" }
```

#### 3.1.7 `BackupHealthIndicator`

Extends `AbstractHealthIndicator` (même pattern que `ConversionEngineHealthIndicator`).

- **UP** : dernier backup SUCCESS il y a moins de 25h
- **DEGRADED** : dernier backup SUCCESS il y a 25–48h (alerte silencieuse, app OK)
- **DOWN** : aucun backup SUCCESS dans les 48 dernières heures ou backup jamais effectué

> `DEGRADED` est un `Status` custom déjà utilisé dans le projet
> (`ConversionEngineHealthIndicator`). Utiliser le même pattern pour la cohérence.

Exposé via `/actuator/health/backup` (inclus automatiquement dans l'exposition existante
`management.endpoints.web.exposure.include: health,info,metrics,prometheus`).

#### 3.1.8 Backup pré-migration automatique

**Fichier de placement :** `com.kovixel.infra.flyway.FlywayConfig.java` (nouveau, voir §3.3)

```java
@Bean
public FlywayMigrationStrategy flywayMigrationStrategy(BackupService backupService) {
    return flyway -> {
        MigrationInfo[] pending = flyway.info().pending();
        if (pending.length > 0) {
            log.info("Flyway : {} migration(s) en attente — backup préventif lancé", pending.length);
            try {
                backupService.triggerBackupSync(BackupTriggerSource.PRE_MIGRATION);
            } catch (Exception e) {
                // Non-bloquant : log WARN mais la migration est quand même appliquée
                log.warn("Backup pré-migration échoué — migration appliquée quand même", e);
            }
        }
        flyway.migrate();
    };
}
```

> `triggerBackupSync()` est une variante **synchrone** de `triggerBackup()` (sans `@Async`)
> pour bloquer le thread de démarrage jusqu'à la fin du backup avant de migrer.

---

### 3.2 MinIO — versioning et bucket de backups

#### 3.2.1 Activation du versioning sur `kovixel-documents`

MinIO Java SDK 8.5.7 (version utilisée dans le projet) supporte `SetBucketVersioningArgs`.

À ajouter dans le `@PostConstruct` existant de `MinioFileStorageService` :

```java
// Après la création du bucket kovixel-documents (bloc existant) :
minioClient.setBucketVersioning(SetBucketVersioningArgs.builder()
    .bucket(bucket)
    .config(new VersioningConfiguration(VersioningConfiguration.Status.ENABLED, null))
    .build());
```

Imports nécessaires (SDK 8.5.7) :
```java
import io.minio.SetBucketVersioningArgs;
import io.minio.messages.VersioningConfiguration;
```

**Impact sur `FileCleanupScheduler` :**
Après activation du versioning, `removeObject` sans `versionId` crée un "delete marker"
(l'objet reste récupérable). Pour une suppression définitive des fichiers expirés,
utiliser :
```java
// Supprimer toutes les versions d'un objet (nettoyage complet)
minioClient.removeObject(RemoveObjectArgs.builder()
    .bucket(bucket)
    .object(fileKey)
    .versionId(null)  // supprime la version courante → crée un delete marker
    .build());
```
Pour une suppression physique complète, lister et supprimer chaque version via
`ListObjectsArgs.builder().includeVersions(true)`. **À évaluer selon la politique
de rétention choisie.**

#### 3.2.2 Création du bucket `kovixel-backups` avec lifecycle

MinIO Java SDK 8.5.7 — API lifecycle :

```java
import io.minio.SetBucketLifecycleArgs;
import io.minio.messages.LifecycleConfiguration;
import io.minio.messages.LifecycleRule;
import io.minio.messages.Expiration;
import io.minio.messages.RuleFilter;
import io.minio.messages.Status;

// Créer kovixel-backups si absent
String backupBucket = backupProperties.getBucket();
if (!minioClient.bucketExists(BucketExistsArgs.builder().bucket(backupBucket).build())) {
    minioClient.makeBucket(MakeBucketArgs.builder().bucket(backupBucket).build());
}

// Lifecycle : expiration automatique à retentionDays jours pour les backups DB
LifecycleRule rule = new LifecycleRule(
    Status.ENABLED,
    null,
    new Expiration((ZonedDateTime) null, backupProperties.getRetentionDays(), null),
    new RuleFilter("db/"),
    "backup-db-expiry",
    null, null, null
);
minioClient.setBucketLifecycle(SetBucketLifecycleArgs.builder()
    .bucket(backupBucket)
    .config(new LifecycleConfiguration(List.of(rule)))
    .build());
```

> Ce code est à placer dans un nouveau `@PostConstruct` de `MinioFileStorageService`
> ou dans un `MinioInitService` dédié injecté uniquement quand `kovixel.backup.enabled=true`.

#### 3.2.3 Nouvelles variables d'environnement

À ajouter dans `.env.example` (racine `kovixel-all`) :

```bash
# ── Backup ───────────────────────────────────────────────────────────────────
BACKUP_ENABLED=true
BACKUP_CRON=0 0 2 * * *
BACKUP_RETENTION_DAYS=30
BACKUP_BUCKET=kovixel-backups
BACKUP_ENCRYPTION_KEY=       # openssl rand -base64 32  → exactement 32 bytes en base64
PG_DUMP_PATH=pg_dump          # chemin complet si non dans PATH
```

À ajouter dans `application.yml` (base, avec valeurs par défaut) :

```yaml
kovixel:
  backup:
    enabled:          ${BACKUP_ENABLED:true}
    cron:             "${BACKUP_CRON:0 0 2 * * *}"
    retention-days:   ${BACKUP_RETENTION_DAYS:30}
    bucket:           ${BACKUP_BUCKET:kovixel-backups}
    encryption-key:   ${BACKUP_ENCRYPTION_KEY:}
    pg-dump-path:     ${PG_DUMP_PATH:pg_dump}
    max-duration-ms:  ${BACKUP_MAX_DURATION_MS:1800000}
```

À ajouter dans `application-dev.yml` :
```yaml
kovixel:
  backup:
    enabled: false   # pas de backup automatique en développement
```

---

### 3.3 Flyway Admin Controller

#### 3.3.1 Nouveau fichier : `com.kovixel.infra.flyway.FlywayConfig.java`

Ce fichier `@Configuration` porte deux responsabilités :
1. Le bean `FlywayMigrationStrategy` (backup pré-migration)
2. L'import de `FlywayAdminController`

```java
package com.kovixel.infra.flyway;

import com.kovixel.infra.backup.BackupService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.springframework.boot.autoconfigure.flyway.FlywayMigrationStrategy;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Slf4j
@Configuration
@RequiredArgsConstructor
public class FlywayConfig {

    @Bean
    public FlywayMigrationStrategy flywayMigrationStrategy(BackupService backupService) {
        return flyway -> {
            MigrationInfo[] pending = flyway.info().pending();
            if (pending.length > 0) {
                log.info("Flyway : {} migration(s) en attente — backup préventif lancé", pending.length);
                try {
                    backupService.triggerBackupSync(BackupTriggerSource.PRE_MIGRATION);
                } catch (Exception e) {
                    log.warn("Backup pré-migration échoué — migration appliquée quand même", e);
                }
            }
            flyway.migrate();
        };
    }
}
```

#### 3.3.2 `FlywayAdminController` — endpoints

```
GET    /api/v1/admin/flyway/status
  Return: {
    "currentVersion": "50",
    "pendingMigrations": 0,
    "failedMigrations": [],
    "resolvedMigrations": 50,
    "checksumMismatches": []
  }

POST   /api/v1/admin/flyway/repair
  ⚠️  Déclenche un backup automatique AVANT le repair (opération irréversible)
  Return: {
    "repaired": true,
    "repairedChecksums": ["V23__add_rotation_columns"],
    "deletedFailedMigrations": []
  }

POST   /api/v1/admin/flyway/validate
  Return: { "valid": true, "errors": [] }

GET    /api/v1/admin/flyway/history
  Return: List<MigrationInfoDto> (toutes les migrations avec statuts, checksums, durées)
```

#### 3.3.3 Intégration SecurityConfig

```java
// Dans SecurityConfig.securityFilterChain — ajouter AVANT .anyRequest() :
.authorizeHttpRequests(auth -> auth
    .requestMatchers(PUBLIC_ENDPOINTS).permitAll()
    .requestMatchers("/api/v1/admin/**").hasRole("ADMIN")  // ← NOUVEAU (nécessite PRÉ-REQUIS 2)
    .anyRequest().authenticated()
)
```

---

### 3.4 Redis — persistance AOF

Redis est utilisé pour :
- Cache quota/subscription/tools → perte acceptable (rechargement PG automatique)
- **Refresh token blacklist** → perte = tokens révoqués redeviennent valides (sécurité)
- **Rate limiting counters** auth/checkout → perte = fenêtre d'exploitation temporaire

**Recommandation :** Activer **AOF** avec `appendfsync everysec`.
- Durabilité : perte maximale 1 seconde de données
- Overhead perf : < 5% (un fsync par seconde vs immédiat)
- Volume `redis_data` déjà configuré → l'AOF y est persisté automatiquement

**Fichier :** `docker-compose.yml`, service `redis` :
```yaml
redis:
  image: redis:7-alpine
  container_name: kovixel-redis
  command: redis-server --appendonly yes --appendfsync everysec
  volumes:
    - redis_data:/data
  # ... reste inchangé
```

---

### 3.5 Résumé complet des fichiers Phase 1

#### Nouveaux fichiers (à créer)

```
kovixel/Dockerfile
  → Ajouter : postgresql-client-16 (PRÉ-REQUIS 1)

kovixel/src/main/java/com/kovixel/common/security/UserDetailsServiceImpl.java
  → Modifier : mapper Role → SimpleGrantedAuthority (PRÉ-REQUIS 2)

kovixel/src/main/java/com/kovixel/infra/backup/
  BackupProperties.java
  BackupRecord.java
  BackupRecordRepository.java
  BackupService.java
  BackupHealthIndicator.java
  BackupAdminController.java

kovixel/src/main/java/com/kovixel/infra/flyway/
  FlywayConfig.java           ← FlywayMigrationStrategy bean
  FlywayAdminController.java
  FlywayStatusDto.java
  MigrationInfoDto.java

kovixel/src/main/resources/db/migration/
  V51__create_backup_records.sql
```

#### Fichiers existants à modifier

```
kovixel/KovixelApplication.java
  → @EnableConfigurationProperties({ EnvironmentProperties.class, BackupProperties.class })

kovixel/common/security/SecurityConfig.java
  → Ajouter avant .anyRequest() : .requestMatchers("/api/v1/admin/**").hasRole("ADMIN")

kovixel/storage/MinioFileStorageService.java
  → @PostConstruct : activer versioning kovixel-documents
  → @PostConstruct : créer kovixel-backups + lifecycle policy

kovixel/src/main/resources/application.yml
  → Ajouter : kovixel.backup.* properties

kovixel/src/main/resources/application-prod.yml
  → (hérité de application.yml, aucune surcharge nécessaire sauf BACKUP_ENABLED=true)

kovixel/src/main/resources/application-dev.yml
  → Ajouter : kovixel.backup.enabled: false

kovixel/docker-compose.yml
  → Redis command : --appendonly yes --appendfsync everysec

kovixel-all/.env.example
  → Ajouter les 6 variables BACKUP_*
```

---

## 4. Phase 2 — Observabilité & Alerting 🟡 CODE PRÊT (sauf WAL archiving), NON VÉRIFIÉ EN RÉEL

> **Délai estimé :** 3–5 jours
> **Impact :** Score résilience → **9/10**

**État (2026-07-22)** : Prometheus/Grafana/métriques/alertes faits. **WAL archiving (§4.4)
explicitement reporté** — décision utilisateur, hors scope de cette passe (le plus gros
morceau d'ingénierie de la phase, image Postgres custom ou sidecar `mc`). **Canal de
notification (Alertmanager → Slack/email/PagerDuty) volontairement non branché** — décision
utilisateur, les alertes restent visibles manuellement (Prometheus `/alerts` + dashboard
Grafana) sans jamais notifier personne automatiquement.

Deux dépendances silencieuses découvertes en implémentant, absentes de la version 1.1 de ce
document :
- `micrometer-registry-prometheus` manquait du `pom.xml` — `/actuator/prometheus` était déjà
  listé dans `management.endpoints.web.exposure.include` mais restait inerte sans ce starter.
- `/actuator/prometheus` n'était **pas** dans `SecurityConfig.PUBLIC_ENDPOINTS` — un scraper
  Prometheus ne peut pas s'authentifier par JWT, le scrape aurait échoué en 401. Ajouté aux
  endpoints publics, acceptable car `kovixel-app` ne publie aucun port sur l'hôte (seuls les
  conteneurs de `kovixel-network` peuvent l'atteindre, jamais l'internet public) — documenté
  en commentaire dans `SecurityConfig.java` avec le risque si ça changeait un jour.

Fichiers créés :
- `com.kovixel.infra.backup.BackupMetrics` — les 4 métriques §4.3 (`last_success.timestamp`,
  `size.bytes`, `duration.ms`, `total`), câblées dans `BackupService.performBackup()`. Gauges
  pré-remplies au démarrage depuis `BackupRecordRepository` (sans ça, un redémarrage ferait
  retomber la gauge à epoch 0 → fausse alerte `BackupMissing` juste après chaque déploiement).
- `com.kovixel.infra.observability.HealthStatusMetrics` — pont générique
  `HealthIndicator → kovixel_health_status{indicator=...}` (gauge pull, 1=UP/0.5=DEGRADED-ou-
  inconnu/0=DOWN). Spring Boot Actuator n'exporte PAS les indicateurs de santé en métriques
  Prometheus par défaut (`/actuator/health` reste du JSON) — sans ce pont, les alertes
  DatabaseDown/MinioDown/ConversionDegraded n'auraient eu aucun signal. Découvre automatiquement
  tous les beans `HealthIndicator` du contexte, aucun câblage supplémentaire pour un futur
  indicateur.
- `com.kovixel.infra.flyway.FlywayMetrics` — `kovixel_flyway_migrations{state="pending"|"failed"}`
  (alerte FlywayFailed).
- `com.kovixel.storage.MinioHealthIndicator` — n'existait pas du tout avant (`BackupHealthIndicator`/
  `ConversionEngineHealthIndicator`/`OllamaHealthIndicator` existaient, pas MinIO). `bucketExists`
  plutôt qu'un ping réseau — valide connectivité + auth + présence du bucket en un aller-retour.
- `src/test/java/.../DbHealthIndicatorBeanNameTest.java` — **vérifié empiriquement** (pas deviné)
  que Spring Boot enregistre le health indicator DB sous le nom de bean `dbHealthContributor`
  (`ApplicationContextRunner` + `DataSourceHealthContributorAutoConfiguration`) : ce nom exact est
  la valeur du label `indicator` utilisée par l'alerte `DatabaseDown` dans `alerts.yml` — un
  changement de version Spring Boot qui le renommerait casserait l'alerte silencieusement sans
  ce garde-fou.
- `docker/prometheus/prometheus.yml` + `alerts.yml` (7 règles §4.2, labels `indicator` vérifiés,
  pas de `rule_files` orphelin), `docker/grafana/provisioning/{datasources,dashboards}/*.yml`
  (auto-provisioning, rien à configurer manuellement dans l'UI Grafana), `docker/grafana/dashboards/
  resilience-overview.json` (7 panneaux : heures depuis dernier backup, taille backup, migrations
  Flyway pending/failed, espace disque hôte, table santé globale, historique backups 30j — JSON
  validé syntaxiquement, **rendu Grafana non vérifié visuellement**, pas de Docker dans cet
  environnement).
- `docker-compose.yml` : services `prometheus`/`grafana`/`node-exporter` (ce dernier absent du
  document original — nécessaire pour l'alerte `DiskSpaceLow` et le panneau disque, sans lui
  aucune métrique disque hôte n'existe).

Tests : 24 tests neufs (`BackupMetricsTest`, `HealthStatusMetricsTest`, `FlywayMetricsTest`,
`MinioHealthIndicatorTest`, `DbHealthIndicatorBeanNameTest`), suite complète 1312 tests/1 échec
(préexistant, sans rapport — `AuthControllerTest.refresh_missingCookie_returns401`).

**Non vérifié dans cet environnement** (pas de Docker disponible ici) : le rendu réel du
dashboard Grafana, le scrape Prometheus effectif, l'évaluation réelle des règles d'alerte contre
du trafic vivant. Code compilé + testé unitairement, config YAML/JSON validée syntaxiquement —
la vérification bout-en-bout reste à faire une fois `docker-compose up` lancé par l'opérateur.

### 4.1 Prometheus + Grafana

Ajouter dans `docker-compose.yml` :

```yaml
prometheus:
  image: prom/prometheus:latest
  volumes:
    - ./docker/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
  ports:
    - "9090:9090"
  networks:
    - kovixel-network

grafana:
  image: grafana/grafana:latest
  volumes:
    - grafana_data:/var/lib/grafana
    - ./docker/grafana/dashboards:/etc/grafana/provisioning/dashboards
  ports:
    - "3001:3000"
  environment:
    GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
  networks:
    - kovixel-network
```

`docker/prometheus/prometheus.yml` :
```yaml
scrape_configs:
  - job_name: kovixel-backend
    scrape_interval: 15s
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: ['kovixel-app:8080']
```

### 4.2 Alertes critiques à configurer

| Alerte | Condition | Sévérité |
|---|---|---|
| `BackupMissing` | `kovixel_backup_last_success_hours > 25` | P0 CRITICAL |
| `DatabaseDown` | Spring Actuator `db` status DOWN | P0 CRITICAL |
| `MinioDown` | MinIO health live endpoint 503 | P0 CRITICAL |
| `FlywayFailed` | Flyway migrations FAILED count > 0 | P1 HIGH |
| `DiskSpaceLow` | Espace libre < 15% sur le volume hôte | P1 HIGH |
| `BackupSizeDrop` | Taille backup < 50% de la moyenne 7j | P1 HIGH |
| `ConversionDegraded` | `ConversionEngineHealthIndicator` = DEGRADED | P2 MEDIUM |

### 4.3 Métriques custom Micrometer

Dans `BackupService`, publier via `MeterRegistry` injecté :
```
kovixel.backup.last_success.timestamp   (gauge — epoch secondes)
kovixel.backup.size.bytes               (gauge — taille du dernier backup)
kovixel.backup.duration.ms              (timer — durée d'exécution)
kovixel.backup.total                    (counter — par tag status=SUCCESS|FAILED)
```

### 4.4 PostgreSQL WAL Archiving (PITR — RPO < 5 min)

Dans `docker-compose.yml`, service `postgres` :
```yaml
postgres:
  image: pgvector/pgvector:pg16
  command: >
    postgres
    -c wal_level=replica
    -c archive_mode=on
    -c archive_command='mc cp %p minio/kovixel-backups/wal/%f'
    -c archive_timeout=300
```

Nécessite une image PostgreSQL custom avec `mc` (MinIO client) installé, ou un
sidecar container dédié à l'archivage WAL (pattern plus propre).

**Restore PITR :**
```bash
# 1. Restaurer le dernier backup full (voir Runbook 1)
# 2. Rejouer les WAL jusqu'à l'instant T cible
# recovery.signal file + postgresql.conf :
restore_command = 'mc cp minio/kovixel-backups/wal/%f %p'
recovery_target_time = '2025-06-26 14:35:00'
```

### 4.5 Dashboard Grafana "Resilience Overview"

Panneaux :
- **Statut backup** : dernier backup réussi (timestamp + taille)
- **Historique 30j** : timeline SUCCESS/FAILED par jour
- **Espace disque hôte** : volumes postgres_data, minio_data, redis_data
- **Flyway** : version courante, migrations pending/failed
- **Health globale** : tous les health indicators Spring en temps réel
- **WAL archiving lag** (Phase 2) : délai d'archivage WAL en secondes

---

## 5. Phase 3 — Haute disponibilité

> **Délai estimé :** 1–2 semaines
> **Impact :** Score résilience → **10/10** — niveau AWS RDS / Supabase

### 5.1 MinIO multi-région (Cross-Region Replication)

```bash
mc alias set siteB https://backup.kovixel.com $MINIO_ACCESS $MINIO_SECRET
mc replicate add kovixel-minio/kovixel-documents \
  --remote-bucket kovixel-documents \
  --remote-endpoint siteB \
  --replicate "delete,delete-marker,existing-objects"
```

Ou migration vers **AWS S3** comme stockage primaire avec CRR automatique.

### 5.2 PostgreSQL Streaming Replication (Primary-Replica)

- Primary : `kovixel-postgres` (lecture/écriture)
- Replica : `kovixel-postgres-replica` (lecture seule, lag < 1s)
- Basculement manuel via `pg_promote` ou automatique via Patroni

```yaml
# datasource secondaire pour les queries @Transactional(readOnly=true)
spring.datasource.replica.url: jdbc:postgresql://postgres-replica:5432/kovixel_db
```

Hikari dual-pool avec routing `AbstractRoutingDataSource` selon `@Transactional(readOnly)`.

### 5.3 Blue-Green Deployments

```
State A (running V50) → State B (running V51)

1. Backup automatique pré-migration (déjà en Phase 1)
2. Appliquer V51 (rétrocompatible avec V50 : colonnes addées, pas supprimées)
3. Démarrer instance B → attendre health check OK
4. Switcher le load balancer (0 downtime)
5. Conserver instance A 15 min en standby
6. Si V51 défaillante : rollback LB → instance A toujours opérationnelle
```

**Contrainte :** toutes les migrations Flyway doivent être **rétrocompatibles** :
- Ajouter une colonne nullable ✅ | Supprimer une colonne ❌ (2 déploiements)
- Renommer une colonne ❌ (new column + migrate data + drop old = 3 déploiements)

### 5.4 Redis Sentinel / Cluster

```yaml
spring.data.redis:
  sentinel:
    master: mymaster
    nodes: redis-sentinel-1:26379,redis-sentinel-2:26379,redis-sentinel-3:26379
```

---

## 6. Runbooks Disaster Recovery

> Ces procédures doivent être **testées mensuellement** en environnement staging.
> Tous les container names sont issus de `docker-compose.yml` :
> `kovixel-postgres`, `kovixel-redis`, `kovixel-minio`, `kovixel-app`.

---

### Runbook 1 — Restauration PostgreSQL depuis backup

**Durée estimée :** 20–30 minutes | **RTO cible :** < 30 minutes

```bash
# ── PRÉ-REQUIS ──────────────────────────────────────────────────────────────
# Avoir accès à : serveur Docker, credentials MinIO, variable BACKUP_ENCRYPTION_KEY

# ── ÉTAPE 1 : Identifier le backup à restaurer ──────────────────────────────
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.kovixel.com/api/v1/admin/backups/latest
# → noter file_key, checksum_sha256, started_at

# ── ÉTAPE 2 : Télécharger le backup depuis MinIO ────────────────────────────
# Option A : depuis la console MinIO (http://localhost:9001)
# Option B : via mc CLI
mc alias set kovixel http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
mc cp kovixel/kovixel-backups/db/2025/06/kovixel_20250626_020000.dump.enc /tmp/

# ── ÉTAPE 3 : Vérifier le checksum ──────────────────────────────────────────
sha256sum /tmp/kovixel_20250626_020000.dump.enc
# Comparer avec le checksum_sha256 retourné en étape 1

# ── ÉTAPE 4 : Déchiffrer le backup (script Java standalone) ─────────────────
# ⚠️ Le format AES-256-GCM Java (IV 12b préfixé) est INCOMPATIBLE avec openssl enc.
# Utiliser le script fourni : kovixel/tools/backup-decrypt.py

python3 kovixel/tools/backup-decrypt.py \
  --key "$BACKUP_ENCRYPTION_KEY" \
  --input /tmp/kovixel_20250626_020000.dump.enc \
  --output /tmp/kovixel_20250626_020000.dump

# ── ÉTAPE 5 : Arrêter l'application ─────────────────────────────────────────
docker-compose stop kovixel-app

# ── ÉTAPE 6 : Copier le dump DANS le container PostgreSQL ──────────────────
# pg_restore doit s'exécuter depuis l'intérieur du container ou via docker exec
docker cp /tmp/kovixel_20250626_020000.dump kovixel-postgres:/tmp/restore.dump

# ── ÉTAPE 7 : Recréer la base et restaurer ──────────────────────────────────
docker exec -i kovixel-postgres psql -U postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='kovixel_db';"
docker exec -i kovixel-postgres psql -U postgres \
  -c "DROP DATABASE IF EXISTS kovixel_db;"
docker exec -i kovixel-postgres psql -U postgres \
  -c "CREATE DATABASE kovixel_db;"

docker exec -i kovixel-postgres pg_restore \
  --username=postgres \
  --dbname=kovixel_db \
  --no-owner \
  --verbose \
  /tmp/restore.dump

# ── ÉTAPE 8 : Vérifier la restauration ──────────────────────────────────────
docker exec -i kovixel-postgres psql -U postgres -d kovixel_db \
  -c "SELECT COUNT(*) FROM kovixel_users;"
docker exec -i kovixel-postgres psql -U postgres -d kovixel_db \
  -c "SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1;"
docker exec -i kovixel-postgres psql -U postgres -d kovixel_db \
  -c "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"

# ── ÉTAPE 9 : Nettoyer et redémarrer ────────────────────────────────────────
docker exec kovixel-postgres rm /tmp/restore.dump
docker-compose start kovixel-app
docker-compose logs -f kovixel-app   # surveiller les logs
curl http://localhost:8080/api/v1/health   # attendre { "status": "UP" }

# ── ÉTAPE 10 : Documenter l'incident ────────────────────────────────────────
# - Horodatage début/fin incident et restauration
# - Backup utilisé (id, timestamp, taille)
# - Données perdues estimées (delta depuis le backup)
# - Cause racine et actions correctives
```

---

### Runbook 2 — Migration Flyway échouée en production

**Durée estimée :** 5–15 minutes avec backup disponible

```bash
# ── DIAGNOSTIC ──────────────────────────────────────────────────────────────
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.kovixel.com/api/v1/admin/flyway/status
# Chercher "failedMigrations" et "checksumMismatches"

# ── OPTION A : Repair simple (checksum mismatch ou FAILED récupérable) ──────
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.kovixel.com/api/v1/admin/flyway/repair
# → déclenche un backup avant le repair, puis retourne { "repaired": true }
# Relancer l'application si elle était arrêtée

# ── OPTION B : Rollback complet (migration irrécupérable) ───────────────────
# 1. Identifier le backup pré-migration
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  "https://api.kovixel.com/api/v1/admin/backups?triggerSource=PRE_MIGRATION&size=5"

# 2. Suivre Runbook 1 avec ce backup
# 3. Corriger le script de migration fautif (kovixel/src/main/resources/db/migration/)
# 4. Redéployer

# ── OPTION C : Aucune instance ne tourne (impossible d'appeler l'API) ────────
# Ajouter temporairement dans application-prod.yml :
#   spring.flyway.validate-on-migrate: false
# Démarrer l'app → se connecter → repair via API → redémarrer avec validate=true
# ⚠️ Ne laisser validate-on-migrate=false que le temps du repair (< 5 min)
```

---

### Runbook 3 — Perte du volume MinIO

```bash
# ── DIAGNOSTIC ──────────────────────────────────────────────────────────────
curl http://localhost:9000/minio/health/live
# 200 = MinIO OK structurellement ; tester un GET sur un document connu pour confirmer

# ── SI VERSIONING ACTIVÉ (Phase 1 implémentée) ───────────────────────────────
# Les objets supprimés ont un "delete marker" → récupérable
# Via console MinIO : naviguer vers le bucket → activer "Show deleted objects"
# Via mc :
mc ls --versions kovixel/kovixel-documents/{userId}/{documentId}/
mc cp --version-id {versionId} \
  kovixel/kovixel-documents/{userId}/{documentId}/{file} \
  /tmp/recovered_file

# ── SI VERSIONING NON ACTIVÉ ─────────────────────────────────────────────────
# Fichiers perdus définitivement.
# Action : notifier les utilisateurs affectés.
# La base de données garde les metadata → l'app reste fonctionnelle sans les fichiers.

# ── RECRÉATION AUTOMATIQUE ───────────────────────────────────────────────────
# Au restart, le @PostConstruct de MinioFileStorageService recrée automatiquement :
# - le bucket kovixel-documents avec versioning activé
# - le bucket kovixel-backups avec lifecycle policy
docker-compose restart kovixel-app
```

---

### Runbook 4 — Checksum Flyway altéré (application ne démarre pas)

```bash
# ── SYMPTÔME ─────────────────────────────────────────────────────────────────
# Logs : "Validate failed: Migrations have failed validation"
# "Migration checksum mismatch for migration version X"

# ── SI UNE INSTANCE EST ENCORE EN COURS ──────────────────────────────────────
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.kovixel.com/api/v1/admin/flyway/repair

# ── AUCUNE INSTANCE NE TOURNE ─────────────────────────────────────────────────
# Ajouter temporairement dans application-prod.yml :
#   spring.flyway.validate-on-migrate: false
# Démarrer → se connecter → repair via API
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.kovixel.com/api/v1/admin/flyway/repair
# Supprimer la ligne validate-on-migrate=false → redémarrer
```

---

### Runbook 5 — Redis crash (déconnexion globale)

```bash
# ── IMPACT ───────────────────────────────────────────────────────────────────
# Tous les utilisateurs déconnectés (sessions/tokens invalidés)
# Rate limiting (checkout, auth) remis à zéro → fenêtre d'exploitation < 60s

# ── RÉSOLUTION ───────────────────────────────────────────────────────────────
docker-compose restart kovixel-redis
# Avec AOF activé (Phase 1) : Redis recharge l'état en < 10 secondes
# L'application Spring reconnecte automatiquement

# ── VÉRIFICATION ─────────────────────────────────────────────────────────────
docker exec -it kovixel-redis redis-cli PING    # → PONG
curl http://localhost:8080/actuator/health       # → redis: UP

# ── COMMUNICATION UTILISATEURS ────────────────────────────────────────────────
# "Déconnexion temporaire suite à une maintenance — veuillez vous reconnecter"
# Durée d'impact typique : 30–60 secondes
```

---

### Outil de déchiffrement : `tools/backup-decrypt.py`

```python
#!/usr/bin/env python3
"""
Déchiffrement des backups Kovixel (AES-256-GCM, format Java javax.crypto).
Format fichier .enc : [12 bytes IV][ciphertext + 16 bytes GCM auth tag]

Usage:
  python3 backup-decrypt.py --key <base64_key> --input backup.dump.enc --output backup.dump
"""
import argparse, base64, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def decrypt(key_b64: str, input_path: str, output_path: str):
    key = base64.b64decode(key_b64)
    if len(key) != 32:
        sys.exit(f"Erreur : la clé doit être de 32 bytes (AES-256), trouvé {len(key)} bytes")

    with open(input_path, 'rb') as f:
        data = f.read()

    iv = data[:12]
    ciphertext_with_tag = data[12:]

    aesgcm = AESGCM(key)
    try:
        plaintext = aesgcm.decrypt(iv, ciphertext_with_tag, None)
    except Exception as e:
        sys.exit(f"Échec du déchiffrement (clé incorrecte ou fichier corrompu) : {e}")

    with open(output_path, 'wb') as f:
        f.write(plaintext)
    print(f"✓ Déchiffrement réussi → {output_path} ({len(plaintext):,} bytes)")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--key',    required=True, help='Clé AES-256 encodée en base64')
    parser.add_argument('--input',  required=True, help='Fichier .dump.enc source')
    parser.add_argument('--output', required=True, help='Fichier .dump destination')
    args = parser.parse_args()
    decrypt(args.key, args.input, args.output)
```

Dépendance Python : `pip install cryptography`

> Ce script est à placer dans `kovixel/tools/backup-decrypt.py` et committé dans le dépôt.
> Il constitue la procédure de restauration offline — ne pas le stocker uniquement dans MinIO.

---

## 7. Décisions d'architecture

### ADR-001 — pg_dump vs WAL streaming pour Phase 1

**Décision :** pg_dump daily (Phase 1), WAL archiving (Phase 2)

**Contexte :** WAL archiving offre PITR à la minute mais nécessite une image Docker
PostgreSQL customisée avec `mc` (MinIO client) et une configuration `postgresql.conf`
non triviale. pg_dump est simple, éprouvé, livrable rapidement.

**Conséquences :** RPO Phase 1 = 24h. Acceptable pour un MVP. WAL planifié Phase 2.

---

### ADR-002 — Chiffrement AES-256-GCM des backups

**Décision :** Chiffrement systématique avant upload MinIO

**Contexte :** Les backups contiennent des données personnelles RGPD, hashes bcrypt,
références Stripe. Un accès non autorisé au bucket ne doit pas exposer les données.

**Mise en œuvre :** Clé AES-256 (32 bytes) en base64 dans `BACKUP_ENCRYPTION_KEY`.
Format fichier : `[12 bytes IV][ciphertext+auth_tag_16b]` (Java AES/GCM/NoPadding).
Déchiffrement via `tools/backup-decrypt.py` (compatible format Java).

**Conséquences :** La clé doit être sauvegardée séparément des backups (1Password/Vault).
Perte de la clé = backups irrécupérables.

---

### ADR-003 — Bucket séparé `kovixel-backups`

**Décision :** Bucket dédié (pas un répertoire dans `kovixel-documents`)

**Raisons :** lifecycle policies différentes (30j vs user-driven) ; permissions séparées ;
isolation contre `FileCleanupScheduler` ; comptabilisation stockage distincte.

---

### ADR-004 — Sécurité endpoints `/api/v1/admin/**`

**Décision :** `hasRole('ADMIN')` via `Role.ADMIN` de l'entité `User`

**Pré-requis :** fix de `UserDetailsServiceImpl` (PRÉ-REQUIS 2) pour mapper le rôle
en `SimpleGrantedAuthority("ROLE_ADMIN")`. Sans ce fix, `hasRole` bloque tout le monde.

---

### ADR-005 — Backup pré-migration non-bloquant vs bloquant

**Décision :** Le backup pré-migration est **synchrone** (bloque le démarrage) mais
**non-bloquant sur erreur** (exception catchée → log WARN → migration quand même lancée).

**Justification :** Bloquer complètement sur erreur backup aggraverait un incident.
Mais rendre le backup asynchrone (`@Async`) risquerait que la migration parte avant la
fin du backup — ce qui annulerait son utilité. Compromis : synchrone + non-bloquant sur échec.

**Conséquence :** L'opérateur doit surveiller `BackupHealthIndicator` et vérifier le
dernier backup avant chaque déploiement de migration.

---

### ADR-006 — `postgresql-client-16` dans l'image runtime

**Décision :** Ajouter `postgresql-client-16` via le dépôt PGDG officiel dans le Dockerfile

**Contexte :** `eclipse-temurin:21-jre-jammy` ne contient pas les outils client PG.
Le dépôt apt Ubuntu `jammy` inclut `postgresql-client` (version 14 par défaut) mais
un client pg14 ne peut pas dumper un serveur pg16 — la version doit correspondre.

**Conséquences :** Légère augmentation de la taille de l'image (~10 MB). Nécessite
une étape `curl | gpg` supplémentaire dans le Dockerfile pour le dépôt PGDG.

---

*Document créé le 2026-06-27 — Version 1.1 (post-validation)*
*Corrections v1.1 : pg_dump absent Dockerfile, hasRole inopérant, incompatibilité AES-GCM/openssl,*
*FlywayConfig placement, BackupProperties registration, pg_restore via docker exec.*
*À mettre à jour après chaque phase complétée et après chaque test DR.*
