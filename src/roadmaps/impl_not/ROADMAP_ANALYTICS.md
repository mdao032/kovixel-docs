# Roadmap Analytics & Métriques — Kovixel

> **Statut :** Proposition technique v1.1  
> **Auteur :** Architecture Kovixel  
> **Date :** 2026-06-19  
> **Audience :** Équipe backend, équipe produit, direction

---

## Table des matières

1. [Préambule & vision](#1-préambule--vision)
2. [État des lieux — fondation existante](#2-état-des-lieux--fondation-existante)
3. [North Star Metric & framework AARRR](#3-north-star-metric--framework-aarrr)
4. [Les trois couches analytics](#4-les-trois-couches-analytics)
5. [Architecture technique](#5-architecture-technique)
6. [Roadmap par sprints](#6-roadmap-par-sprints)
7. [Migrations Flyway](#7-migrations-flyway)
8. [Décisions d'architecture (ADR)](#8-décisions-darchitecture-adr)
9. [Risques et mitigations](#9-risques-et-mitigations)
10. [KPIs de la roadmap](#10-kpis-de-la-roadmap)
11. [Conformité RGPD](#11-conformité-rgpd)
12. [Glossaire](#12-glossaire)

---

## 1. Préambule & vision

Un produit qu'on ne mesure pas est un produit qu'on ne peut pas améliorer. Kovixel traite des documents, génère des résumés, répond à des questions, extrait des données structurées — mais aujourd'hui, **aucune de ces actions n'est consolidée en indicateurs exploitables.**

On ignore :
- Quels outils sont réellement utilisés et lesquels sont ignorés
- Si les utilisateurs qui s'inscrivent reviennent le lendemain
- D'où viennent les utilisateurs géographiquement
- Quel outil génère le plus de valeur perçue

Cette roadmap construit l'infrastructure qui permet de répondre à ces questions, de manière progressive, sans overhead sur les performances utilisateur, et en conformité RGPD native.

**Périmètre de cette roadmap :**
- **A — Pilotage interne** (fondation) : dashboard admin, métriques business, surveillance opérationnelle
- **B — Stats utilisateur** (extension) : page "Mes statistiques" dans le profil
- **C — Reporting avancé** (futur) : hors périmètre v1, mentionné pour anticiper l'architecture

---

## 2. État des lieux — fondation existante

Kovixel dispose d'une **infrastructure partielle et sous-exploitée** qui réduit significativement le travail à faire.

### 2.1 Ce qui existe et peut être valorisé

| Table / Composant | Données disponibles | Exploitabilité analytics |
|-------------------|--------------------|-----------------------|
| `usage_records` (V10) | Feature usage par utilisateur + quotas | ✅ Compteurs par outil, DAU partiel |
| `processing_jobs` (V1) | Chaque job avec timing, statut, userId | ✅ Durée de traitement, taux d'erreur |
| `ai_jobs` (V8) | Jobs IA avec timing, statut | ✅ Perf modèles, taux succès IA |
| `auth_events` (V28) | Tous les logins avec IP + user_agent | ✅ Acquisition, device, géolocalisation |
| `qna_sessions` / `qna_messages` (V6) | Sessions Q&A complètes | ✅ Engagement Q&A, messages/session |
| `summary_documents` (V3) | Résumés générés | ✅ Volume résumés, langues |
| `extraction_results` (V7) | Extractions par template | ✅ Volume, templates populaires |
| `translations` (V23) | Traductions avec paires de langues | ✅ Volume, langues cibles |
| `kovixel_users` | Plan, provider, createdAt | ✅ Distribution plans, providers, cohortes |

### 2.2 Ce qui manque

| Lacune | Impact | Sprint |
|--------|--------|--------|
| Aucune géolocalisation des utilisateurs | Impossible de voir l'audience géographique | A-1 |
| Aucune table d'événements unifiée | Données en silos, requêtes complexes | A-1 |
| Aucune pré-agrégation | Chaque requête dashboard = scan complet de la base | A-2 |
| Aucun compteur live (Redis) | Impossible d'afficher des chiffres "temps réel" | A-2 |
| Aucune API analytics | Le frontend n'a nulle part où lire ces données | A-3 |
| Aucun tracking frontend | Pages vues, sessions, funnel d'inscription invisibles | A-4 |
| Aucune page de stats utilisateur | L'utilisateur ne voit pas la valeur accumulée | A-5/A-7 |
| Aucun dashboard admin | Le pilotage se fait à l'aveugle | A-6 |
| Aucun tracking des dépassements de quota | Les signaux de conversion FREE→PRO sont invisibles | A-1 |
| Aucune distribution des formats de fichier en entrée | Impossible de prioriser le support de formats (PDF scannés, PPTX...) | A-1 |
| Aucune mesure d'abandon de funnel par outil | La friction UX est invisible (outil ouvert mais non utilisé) | A-4 |
| Aucun tracking des partages de documents | Coefficient viral impossible à mesurer | A-4 |
| Aucune mesure de consommation de stockage | Impossible de prévoir les coûts infra Minio/S3 | A-2 |
| Aucun détail des types d'erreur | Le taux global masque les causes réelles (timeout vs format vs API IA) | A-1 |

### 2.3 Estimation du travail économisé par la fondation existante

Les tables `usage_records`, `processing_jobs` et `auth_events` représentent environ **40% des données nécessaires** aux métriques clés. La roadmap construit le reste et expose intelligemment l'existant.

---

## 3. North Star Metric & framework AARRR

### 3.1 North Star Metric

> **"Nombre d'utilisateurs actifs ayant utilisé au moins 2 outils distincts dans le mois (MAU multi-outil)"**

**Pourquoi ce choix :** La valeur de Kovixel est son écosystème d'outils — pas un outil pris isolément. Un utilisateur qui ne fait que de la conversion PDF peut aller sur ilovePDF gratuitement. Celui qui combine Résumé + Q&A + Extraction construit une dépendance cognitive au produit que les concurrents mono-feature ne peuvent pas répliquer. Ce chiffre capte la **stickiness réelle** du produit.

Quand cette métrique croît, tout le reste suit : rétention, conversion FREE→PRO, LTV.

**Variante avancée :** "Utilisateurs ayant utilisé ≥ 2 outils distincts sur le **même document** dans le mois" — indicateur encore plus fort d'une utilisation intégrée. Calculable dès que le `document_id` est inclus dans les propriétés JSONB des événements `TOOL_USED`.

### 3.2 Framework AARRR appliqué à Kovixel

| Étape | Question | Métrique principale | Source de données |
|-------|----------|--------------------|--------------------|
| **Acquisition** | Qui vient et d'où ? | Nouveaux inscrits / semaine, par provider et continent | `auth_events` + `user_geo` (à créer) |
| **Activation** | Obtiennent-ils de la valeur rapidement ? | % utilisateurs ayant utilisé un outil dans les 48h suivant l'inscription | `usage_records` + `kovixel_users.createdAt` |
| **Rétention** | Reviennent-ils ? | DAU/MAU, taux de rétention J+7 et J+30 | `analytics_daily_snapshots` (à créer) |
| **Referral** | En parlent-ils ? | Hors périmètre v1 (pas de système de parrainage) | — |
| **Revenue** | Paient-ils ? | Taux de conversion FREE→PRO, churn mensuel | `kovixel_users.plan` |

### 3.3 Métriques opérationnelles (non-AARRR)

Ces métriques pilotent la qualité produit, pas la croissance :

| Métrique | Cible | Alerte si |
|----------|-------|----------|
| Taux de succès par outil | > 95% | < 90% |
| Durée de traitement moyenne (PDF conversion) | < 30s | > 60s |
| Durée de traitement moyenne (Summary) | < 45s | > 90s |
| Taux de réponse Q&A sans source | < 20% | > 35% |
| Taux d'erreur global | < 2% | > 5% |
| Taux de dépassement de quota (users FREE/mois) | < 10% | > 25% → opportunité upsell critique |
| Erreurs `TIMEOUT` par outil | < 1% | > 2% → problème de capacité |
| Erreurs `AI_API_ERROR` | < 0.5% | > 1% → provider IA dégradé |
| Taux d'abandon de funnel (outil ouvert / outil terminé) | < 30% | > 50% → friction UX à investiguer |

---

## 4. Les trois couches analytics

### Couche 1 — Métriques produit (usage par outil)

Répond à : *"Quels outils utilisent-ils, combien de fois, avec quel succès ?"*

| Outil | Métriques à capturer |
|-------|---------------------|
| **Upload document** | Nb/jour, taille moy., type MIME (`application/pdf`, `image/*`, `application/vnd.openxmlformats-officedocument.*`...), taux d'échec, Go total stockés |
| **Conversion PDF** | Nb par type, durée moy., taux succès, taille input/output, format en entrée (`pdf`, `docx`, `pptx`...), flag `is_scanned` (PDF scanné = OCR requis), type d'erreur (`TIMEOUT`, `UNSUPPORTED_FORMAT`, `FILE_TOO_LARGE`, `AI_API_ERROR`) |
| **Résumé IA** | Nb générations, langue source du document, durée, modèle IA utilisé, mots générés, type d'erreur |
| **Q&A** | Nb sessions, messages/session, score de confiance moyen **par modèle IA**, taux sans réponse, taux réutilisation session, type d'erreur |
| **Extraction** | Nb extractions, par template, taux de champs remplis, format d'export (`CSV`, `JSON`, `XLSX`), type d'erreur |
| **Traduction** | Nb traductions, paires de langues, volume de mots, durée, type d'erreur |
| **Aperçu document** | Nb ouvertures, type de fichier prévisualisé |
| **Partage document** | Nb partages par méthode (`copy_link`, `email`, `native_share`), outil source du partage |
| **Dépassement de quota** | Nb hits par outil et par plan, distribution par tier (FREE / PRO proche limite) |
| **Consommation stockage** | Go total stockés, par plan, par utilisateur (top 10), évolution mensuelle |

### Couche 2 — Métriques utilisateurs (audience & rétention)

Répond à : *"Qui sont-ils, d'où viennent-ils, restent-ils ?"*

- Acquisition : nouveaux inscrits par jour/semaine/mois, par provider OAuth, par continent/pays
- Activation : délai inscription → premier usage outil (time-to-value)
- Rétention : DAU, WAU, MAU, cohortes J+1/J+7/J+30
- Plans : distribution FREE/PRO/ENTERPRISE, évolution dans le temps
- North Star : MAU multi-outil (≥ 2 outils dans le mois)
- Adoption par outil : % des utilisateurs inscrits ayant utilisé chaque outil **au moins une fois** (reach / découvrabilité) — distinct de la fréquence, révèle les outils ignorés malgré leur existence
- Re-engagement : taux d'utilisateurs redevenus actifs après > 30j d'inactivité (cible pour futures campagnes email)

### Couche 3 — Métriques trafic (navigation frontend)

Répond à : *"Comment naviguent-ils dans l'application ?"*

- Pages vues par page, sessions par jour/mois
- Durée de session, taux de rebond
- Devices : desktop/mobile/tablette
- Sources d'entrée : direct, organique, référent
- Funnel : landing → inscription → premier outil → deuxième outil
- Abandon de funnel par outil : ratio `tool_started` / `tool_completed` — détecte la friction UX avant qu'elle n'atteigne le support

**Solution retenue pour la Couche 3 : Umami (auto-hébergé)**  
Sans cookies, sans bandeau de consentement, RGPD natif. Un seul conteneur Docker. Script léger (< 2kB). Dashboard intégré.

---

## 5. Architecture technique

### 5.1 Vue d'ensemble

```
┌──────────────────────────────────────────────────────────────────────────┐
│  FRONTEND Angular                                                          │
│  ├── Umami script → Umami Docker (pages vues, sessions, devices)           │
│  ├── Dashboard admin Angular → /api/v1/admin/analytics/*                   │
│  └── Page stats utilisateur → /api/v1/me/stats                            │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ HTTP (JWT)
┌──────────────────────────────▼───────────────────────────────────────────┐
│  BACKEND Spring Boot                                                       │
│                                                                            │
│  AnalyticsEventService (async)                                             │
│  ├── Instrumentation: DocumentController, SummaryService, QnaService...    │
│  └── Persiste → analytics_events (PostgreSQL)                             │
│                                                                            │
│  GeoIpService (MaxMind GeoLite2 embedded)                                  │
│  └── Résolution IP → pays/continent à l'inscription → user_geo            │
│                                                                            │
│  Redis (déjà présent)                                                      │
│  └── Compteurs live: docs_today, active_users, tool_{name}_today          │
│                                                                            │
│  AnalyticsAggregationJob (cron 02h00)                                      │
│  ├── Lit analytics_events + usage_records + processing_jobs               │
│  └── Écrit → analytics_daily_snapshots                                    │
│                                                                            │
│  AnalyticsAdminController → /api/v1/admin/analytics/*                     │
│  AnalyticsUserController  → /api/v1/me/stats                              │
└──────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Stratégie temps réel vs différé

Le choix est volontairement à deux vitesses pour équilibrer fraîcheur et charge :

| Type de donnée | Fraîcheur | Stockage | Justification |
|----------------|-----------|----------|---------------|
| Compteurs live (docs/today, outil X/today) | Temps réel | Redis INCR | Ultra-léger, atomic, pas de lock DB |
| KPIs agrégés (DAU, MAU, rétention) | J-1 | `analytics_daily_snapshots` | Pré-calculés la nuit, lecture O(1) |
| Événements bruts | Immédiat | `analytics_events` | Async, jamais sur le chemin critique |
| Géolocalisation | À l'inscription | `user_geo` | Une seule fois, jamais recalculé |
| Trafic frontend | ~30s de lag | Umami | Géré par Umami nativement |

**Conséquence pratique :** une requête utilisateur (ex: générer un résumé) n'attend jamais l'analytics. L'événement est émis de façon asynchrone après la réponse HTTP.

### 5.3 Tables principales

#### `analytics_events` — flux d'événements bruts

```sql
CREATE TABLE analytics_events (
    id              BIGSERIAL       PRIMARY KEY,
    event_type      VARCHAR(50)     NOT NULL,
    -- ex: TOOL_USED, DOC_UPLOADED, USER_REGISTERED, PLAN_CHANGED

    user_id         BIGINT          REFERENCES kovixel_users(id) ON DELETE SET NULL,
    tool_name       VARCHAR(50),
    -- ex: PDF_TO_WORD, SUMMARY, QNA, EXTRACTION, TRANSLATION, PREVIEW

    properties      JSONB,
    -- Données variables par type d'événement :
    -- TOOL_USED (succès) : { "duration_ms": 4200, "file_size_bytes": 204800, "input_format": "application/pdf",
    --                        "is_scanned": false, "success": true, "language": "fr", "model": "claude", "output_words": 312,
    --                        "document_id": 42 }
    -- TOOL_USED (échec)  : { "duration_ms": 1200, "success": false, "error_code": "TIMEOUT" }
    --                       error_code : TIMEOUT | UNSUPPORTED_FORMAT | FILE_TOO_LARGE | AI_API_ERROR | QUOTA_EXCEEDED
    -- DOC_UPLOADED        : { "content_type": "application/pdf", "file_size_bytes": 1048576 }
    -- USER_REGISTERED     : { "provider": "GOOGLE", "plan": "FREE" }
    -- QUOTA_REACHED       : { "tool_name": "SUMMARY", "plan": "FREE", "limit": 10, "period": "2026-06" }
    -- DOCUMENT_SHARED     : { "method": "copy_link" }  -- copy_link | email | native_share

    country_code    CHAR(2),        -- ISO 3166-1 alpha-2, copié de user_geo au moment de l'event
    continent_code  VARCHAR(2),     -- EU, NA, AS, AF, OC, SA
    device_type     VARCHAR(10),    -- DESKTOP, MOBILE, TABLET (déduit du User-Agent)
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);
```

#### `analytics_daily_snapshots` — agrégats pré-calculés

```sql
CREATE TABLE analytics_daily_snapshots (
    id              BIGSERIAL   PRIMARY KEY,
    snapshot_date   DATE        NOT NULL,
    metric_name     VARCHAR(100) NOT NULL,
    -- ex: dau, mau, tool_usage, new_users, retention_d7, multi_tool_users
    
    dimension       VARCHAR(100),
    -- Valeur de découpe : nom de l'outil, code pays, plan, provider...
    -- NULL = métrique globale (pas de découpe)

    value           BIGINT      NOT NULL,
    computed_at     TIMESTAMP   NOT NULL DEFAULT NOW(),
    
    UNIQUE(snapshot_date, metric_name, COALESCE(dimension, ''))
);
```

Exemples de lignes :
```
snapshot_date | metric_name                  | dimension              | value
2026-07-01    | dau                          | NULL                   | 142
2026-07-01    | tool_usage                   | SUMMARY                | 89
2026-07-01    | tool_usage                   | PDF_TO_WORD            | 234
2026-07-01    | tool_success_rate            | SUMMARY                | 97   -- en % × 100
2026-07-01    | tool_error_type              | SUMMARY:TIMEOUT        | 2
2026-07-01    | tool_error_type              | PDF_TO_WORD:UNSUPPORTED| 5
2026-07-01    | file_format_dist             | SUMMARY:pdf            | 71
2026-07-01    | file_format_dist             | SUMMARY:docx           | 18
2026-07-01    | new_users                    | EU                     | 18
2026-07-01    | new_users                    | NA                     | 7
2026-07-01    | multi_tool_users_mau         | NULL                   | 63
2026-07-01    | multi_tool_same_doc_mau      | NULL                   | 29
2026-07-01    | plan_distribution            | FREE                   | 891
2026-07-01    | plan_distribution            | PRO                    | 47
2026-07-01    | quota_hits                   | SUMMARY                | 34
2026-07-01    | quota_hits                   | QNA                    | 12
2026-07-01    | storage_gb_total             | NULL                   | 24  -- en Go × 10 (précision décimale)
2026-07-01    | storage_gb_per_plan          | FREE                   | 18
2026-07-01    | re_engagement_rate           | NULL                   | 8   -- en %
```

#### `user_geo` — géolocalisation à l'inscription

```sql
CREATE TABLE user_geo (
    user_id         BIGINT      PRIMARY KEY
                                REFERENCES kovixel_users(id) ON DELETE CASCADE,
    country_code    CHAR(2),    -- "FR", "US", "DE"...
    country_name    VARCHAR(100),
    continent_code  VARCHAR(2), -- "EU", "NA", "AS", "AF", "OC", "SA"
    continent_name  VARCHAR(50),
    is_eu           BOOLEAN     NOT NULL DEFAULT FALSE,
    located_at      TIMESTAMP   NOT NULL DEFAULT NOW()
    -- Note : l'IP source n'est pas stockée (confidentialité — on garde seulement le résultat)
);
```

### 5.4 Redis — compteurs live

Clés Redis dédiées à l'analytics (préfixe `kov:analytics:`):

```
kov:analytics:live:docs_processed:{date}     → INCR à chaque document traité
kov:analytics:live:tool:{toolName}:{date}    → INCR à chaque usage d'outil
kov:analytics:live:active_users:{date}       → SADD userId (set = unique users)
kov:analytics:live:new_users:{date}          → INCR à chaque inscription
kov:analytics:live:quota_hits:{date}         → INCR à chaque dépassement de quota
kov:analytics:live:storage_bytes_total       → INCRBY à chaque upload, DECRBY à chaque suppression (valeur absolue courante, pas de date)
```

- TTL : 48h (assez pour le job nightly de persistance + une nuit de marge)
- Le job d'agrégation nocturne lit ces valeurs Redis, les persiste dans `analytics_daily_snapshots`, puis les laisse expirer naturellement

### 5.5 GeoIP — MaxMind GeoLite2

**Bibliothèque :** `com.maxmind.geoip2:geoip2:4.2.0`  
**Base de données :** GeoLite2-Country.mmdb (~6 MB, gratuit, compte MaxMind requis)  
**Mode d'intégration :** fichier embarqué dans les ressources de l'application

Flux de géolocalisation :
1. Utilisateur s'inscrit → `AuthService.register()` extrait l'IP depuis `X-Forwarded-For`
2. `GeoIpService.locate(ip)` → pays + continent en ~1ms (base locale, zéro appel réseau)
3. Résultat persisté dans `user_geo` de façon asynchrone
4. IP non stockée — seul le résultat (pays, continent) est conservé

Cas particuliers :
- IP privée (127.0.0.1, 10.x, 192.168.x) → `country_code = null`, géo ignorée (env dev)
- IP inconnue de la base → `Optional.empty()`, pas de crash

**Mise à jour de la base GeoLite2 :**  
Job mensuel (`@Scheduled(cron = "0 3 1 * *")`) qui télécharge la nouvelle version depuis l'API MaxMind et recharge le reader en mémoire sans redémarrage.

### 5.6 Calcul "temps économisé" (pour le dashboard utilisateur)

Kovixel crée de la valeur en économisant du temps cognitif. Exposer ce chiffre à l'utilisateur est un levier de rétention fort (pattern utilisé par Grammarly, Notion, Google Workspace).

| Outil | Temps économisé estimé |
|-------|----------------------|
| PDF → Word | 25 min (recopie manuelle évitée) |
| Résumé IA | 20 min (lecture complète évitée) |
| Q&A (par session) | 15 min (recherche manuelle dans le document) |
| Extraction | 30 min (saisie manuelle de données structurées) |
| Traduction | 20 min (traduction manuelle estimée) |
| Conversion image | 10 min |

Ces estimations sont conservatrices et configurables via constantes. La formule est affichée avec un `~` pour marquer l'approximation : *"Vous avez économisé ~3h ce mois"*.

---

## 6. Roadmap par sprints

### Vue d'ensemble

```
Sprint A-1  ████████████████  Fondations : events + GeoIP           2 semaines
Sprint A-2  ████████████      Agrégation & compteurs Redis           1.5 semaine
Sprint A-3  ████████          API analytics admin                    1 semaine
Sprint A-4  ████████          Trafic frontend (Umami)                1 semaine
Sprint A-5  ████████          Stats utilisateur (backend)            1 semaine
Sprint A-6  ████████████████  Dashboard admin Angular                2 semaines
Sprint A-7  ████████          Dashboard utilisateur Angular          1 semaine
Sprint A-8  ░░░░░░░░░░░░░░░░  Alertes & rapports automatiques        Continu

Total estimation : ~10.5 semaines
```

---

### Sprint A-1 — Fondations : capture d'événements & GeoIP (2 semaines)

**Objectif :** Poser les rails sur lesquels tout le reste s'appuie. Instrumenter les outils existants sans modifier leur logique métier.

**Pourquoi en premier :** Sans événements capturés, il n'y a rien à agréger, rien à afficher, rien à piloter.

#### Tâches

**A-1.1 — Dépendance GeoIP**

Ajouter dans `pom.xml` :
```xml
<dependency>
    <groupId>com.maxmind.geoip2</groupId>
    <artifactId>geoip2</artifactId>
    <version>4.2.0</version>
</dependency>
```

Télécharger `GeoLite2-Country.mmdb` et le placer dans `src/main/resources/geoip/`.  
Ajouter dans `.gitignore` : les fichiers `.mmdb` ne doivent pas être commités (licence MaxMind).  
Ajouter dans `application.yml` :
```yaml
geoip:
  database-path: classpath:geoip/GeoLite2-Country.mmdb
  maxmind-license-key: ${MAXMIND_LICENSE_KEY:}  # Pour les updates automatiques
```

**A-1.2 — `GeoIpService.java`**

Nouveau service : `com.kovixel.analytics.geo.GeoIpService`

Responsabilités :
- `locate(String ipAddress) → Optional<GeoLocation>`
- `isEuCountry(String countryCode) → boolean` (liste des 27 pays UE, utile pour RGPD)
- `extractIp(HttpServletRequest request) → String` (X-Forwarded-For → X-Real-IP → remote addr)
- `isPrivateIp(String ip) → boolean` (127.x, 10.x, 192.168.x, ::1 → ignorer en dev)

Données de sortie `GeoLocation` :
```java
public record GeoLocation(
    String countryCode,     // "FR"
    String countryName,     // "France"
    String continentCode,   // "EU"
    String continentName,   // "Europe"
    boolean isEu
) {}
```

**A-1.3 — Migrations Flyway**

`V38__create_analytics_events.sql` et `V39__create_user_geo.sql` (voir section 7).

**A-1.4 — `AnalyticsEventService.java`**

Nouveau service : `com.kovixel.analytics.AnalyticsEventService`

Pattern identique à `AuthEventService` — entièrement asynchrone, jamais bloquant :
```java
@Service
@RequiredArgsConstructor
public class AnalyticsEventService {

    private final AnalyticsEventRepository eventRepo;
    private final UserGeoRepository userGeoRepo;

    @Async("processingExecutor")  // Même pool que les autres jobs async
    public void track(AnalyticsEvent event) {
        try {
            eventRepo.save(event);
        } catch (Exception e) {
            // Ne jamais laisser l'analytics briser le flux utilisateur
            log.warn("Analytics tracking failed for event {}: {}", event.getEventType(), e.getMessage());
        }
    }

    @Async("processingExecutor")
    public void geolocateUser(Long userId, String ipAddress) {
        if (isPrivateIp(ipAddress)) return;  // Env dev, pas de géo
        geoIpService.locate(ipAddress).ifPresent(geo ->
            userGeoRepo.save(UserGeo.fromGeoLocation(userId, geo))
        );
    }
}
```

**A-1.5 — Types d'événements définis**

Enum `AnalyticsEventType` :
```java
public enum AnalyticsEventType {
    // Cycle de vie utilisateur
    USER_REGISTERED, USER_LOGGED_IN, USER_PLAN_CHANGED,

    // Documents
    DOCUMENT_UPLOADED, DOCUMENT_DELETED, DOCUMENT_PREVIEW_OPENED, DOCUMENT_SHARED,

    // Outils IA
    TOOL_USED,    // Le type d'outil est dans properties.tool_name

    // Friction & conversion
    QUOTA_REACHED,    // Utilisateur ayant atteint sa limite de plan → signal upsell direct

    // Sessions Q&A
    QNA_SESSION_STARTED, QNA_MESSAGE_SENT
}
```

Propriétés JSONB standardisées par type d'événement :
```json
// TOOL_USED (succès)
{
  "tool_name": "SUMMARY",
  "document_id": 42,
  "duration_ms": 4200,
  "file_size_bytes": 204800,
  "input_format": "application/pdf",
  "is_scanned": false,
  "success": true,
  "language": "fr",
  "model": "claude",
  "output_words": 312
}

// TOOL_USED (échec)
{
  "tool_name": "PDF_TO_WORD",
  "document_id": 51,
  "duration_ms": 1200,
  "file_size_bytes": 5242880,
  "input_format": "application/pdf",
  "is_scanned": true,
  "success": false,
  "error_code": "TIMEOUT"
}

// QUOTA_REACHED
{
  "tool_name": "SUMMARY",
  "plan": "FREE",
  "limit": 10,
  "period": "2026-06"
}

// DOCUMENT_SHARED
{
  "method": "copy_link",
  "tool_context": "SUMMARY"
}
```

**A-1.6 — Instrumentation des services existants**

Ajouter des appels à `AnalyticsEventService.track()` dans :

| Point d'instrumentation | Fichier | Événement émis |
|------------------------|---------|---------------|
| `AuthService.register()` | `AuthService.java` | `USER_REGISTERED` + `geolocateUser()` |
| `DocumentService.create()` | `DocumentServiceImpl.java` | `DOCUMENT_UPLOADED` |
| `SummaryService.generate()` | Après génération | `TOOL_USED` (SUMMARY) |
| `QnaService.ask()` | Après réponse | `TOOL_USED` (QNA) |
| `ExtractionService.extract()` | Après extraction | `TOOL_USED` (EXTRACTION) |
| `ConversionController` | Après chaque conversion | `TOOL_USED` (PDF_TO_WORD, etc.) |
| `TranslationService` | Après traduction | `TOOL_USED` (TRANSLATION) |
| `QuotaService.checkAndIncrement()` | Quand le quota est atteint (avant refus) | `QUOTA_REACHED` + Redis INCR |
| `DocumentController` share endpoint | Après partage réussi (appelé par le frontend) | `DOCUMENT_SHARED` |

**Règle impérative** : les appels `track()` sont toujours **après** la logique métier et **jamais** dans un bloc `try-catch` principal. Ils ne peuvent pas provoquer d'erreur visible pour l'utilisateur.

**A-1.7 — Tests unitaires**

- `GeoIpService` : IP française → pays=FR, continent=EU, isEu=true ✓
- `GeoIpService` : IP privée → `Optional.empty()` ✓
- `AnalyticsEventService` : exception lors de la sauvegarde → swallowed silently ✓
- `AnalyticsEvent` builder : JSONB properties correctement sérialisées ✓

**Critères de sortie Sprint A-1 :**
- [ ] `analytics_events` alimentée à chaque usage outil (vérifiable en base)
- [ ] `user_geo` alimentée pour tout nouvel inscrit avec IP non-privée
- [ ] Zéro régression sur les flux existants (tests d'intégration verts)
- [ ] Aucune exception analytics visible pour l'utilisateur
- [ ] Overhead mesuré : < 2ms sur le chemin critique (l'async rend cela transparent)

---

### Sprint A-2 — Agrégation & compteurs Redis (1,5 semaine)

**Objectif :** Transformer le flux d'événements bruts en indicateurs pré-calculés lisibles en millisecondes.

#### Tâches

**A-2.1 — Migration Flyway `V40__create_analytics_daily_snapshots.sql`**

Voir section 7. Inclut les index nécessaires pour les requêtes dashboard.

**A-2.2 — Compteurs Redis**

Nouveau service : `com.kovixel.analytics.LiveCounterService`

```java
@Service
@RequiredArgsConstructor
public class LiveCounterService {

    private final StringRedisTemplate redis;
    private static final String PREFIX = "kov:analytics:live:";
    private static final Duration TTL  = Duration.ofHours(48);

    public void incrementTool(String toolName) {
        String key = PREFIX + "tool:" + toolName + ":" + LocalDate.now();
        redis.opsForValue().increment(key);
        redis.expire(key, TTL);
    }

    public void incrementDocs() {
        String key = PREFIX + "docs_processed:" + LocalDate.now();
        redis.opsForValue().increment(key);
        redis.expire(key, TTL);
    }

    public void markUserActive(Long userId) {
        String key = PREFIX + "active_users:" + LocalDate.now();
        redis.opsForSet().add(key, userId.toString());
        redis.expire(key, TTL);
    }

    public long getLiveCount(String metric) {
        String key = PREFIX + metric + ":" + LocalDate.now();
        String val = redis.opsForValue().get(key);
        return val != null ? Long.parseLong(val) : 0L;
    }

    public long getActiveUsersToday() {
        String key = PREFIX + "active_users:" + LocalDate.now();
        Long size = redis.opsForSet().size(key);
        return size != null ? size : 0L;
    }
}
```

Les appels à `LiveCounterService` sont ajoutés dans `AnalyticsEventService.track()` **au même moment** que la persistance en base — un seul point d'entrée.

**A-2.3 — `AnalyticsAggregationJob.java`**

Job planifié : `com.kovixel.analytics.AnalyticsAggregationJob`

Exécution : `@Scheduled(cron = "0 0 2 * * *")` — chaque nuit à 2h00 (hors heures de pointe).

Métriques calculées et persistées :

```
POUR la date d'hier (J-1) :

1.  dau (NULL)                     → COUNT(DISTINCT user_id) FROM analytics_events WHERE date = J-1
2.  new_users (NULL)               → COUNT FROM kovixel_users WHERE DATE(createdAt) = J-1
3.  new_users (par continent)      → GROUP BY continent_code FROM user_geo JOIN ci-dessus
4.  tool_usage (par outil)         → COUNT FROM analytics_events WHERE event_type=TOOL_USED, GROUP BY tool_name
5.  tool_success_rate (par outil)  → AVG((properties->>'success')::boolean) GROUP BY tool_name
6.  tool_avg_duration (par outil)  → AVG((properties->>'duration_ms')::bigint) GROUP BY tool_name
7.  tool_error_type (outil × type) → COUNT WHERE success=false, GROUP BY tool_name, properties->>'error_code'
8.  file_format_dist (outil × fmt) → COUNT FROM analytics_events WHERE event_type=TOOL_USED,
                                       GROUP BY tool_name, properties->>'input_format'
9.  plan_distribution (par plan)   → COUNT FROM kovixel_users GROUP BY plan
10. multi_tool_users_mau (NULL)    → COUNT users avec ≥ 2 tools distincts dans les 30j glissants
11. multi_tool_same_doc_mau (NULL) → COUNT users avec ≥ 2 tools distincts sur le même document_id dans les 30j
12. activation_rate (NULL)         → % inscrits J-2 ayant utilisé un outil avant J-1
13. re_engagement_rate (NULL)      → % users inactifs > 30j redevenus actifs dans la semaine
14. quota_hits (par outil)         → COUNT FROM analytics_events WHERE event_type=QUOTA_REACHED,
                                       GROUP BY properties->>'tool_name'
15. storage_gb_total (NULL)        → lu depuis Redis kov:analytics:live:storage_bytes_total / 1e9
16. storage_gb_per_plan (par plan) → JOIN kovixel_users GROUP BY plan (calculé depuis documents table)
17. tool_adoption_rate (par outil) → COUNT(DISTINCT user_id WHERE tool_name = X dans les 90j glissants)
                                       / COUNT(kovixel_users WHERE is_test_account = FALSE)
                                       -- distingue les outils sous-découverts (faible %) des outils peu fréquents mais connus

+ Persistance des compteurs Redis → snapshots avant expiration des clés
```

Propriétés du job :
- **Idempotent** : si relancé, écrase les snapshots existants du même jour (UPSERT)
- **Rattrapable** : si une nuit est ratée, le job peut être déclenché manuellement avec une date en paramètre
- **Observabilité** : log structuré à chaque métrique calculée, durée totale du job

**A-2.4 — `AnalyticsAggregationScheduler`**

Endpoint admin pour déclencher manuellement le job :
```
POST /api/v1/admin/analytics/aggregate?date=2026-07-01
→ Lance le calcul pour la date fournie (catchup si nuit ratée)
```

**Critères de sortie Sprint A-2 :**
- [ ] Snapshots peuplés pour chaque métrique définie ci-dessus
- [ ] Job exécuté et validé sur les données de test existantes
- [ ] Compteurs Redis cohérents avec les counts PostgreSQL (écart < 1%)
- [ ] Relance manuelle du job testée et fonctionnelle
- [ ] Performance : job complet < 5 minutes sur un volume de test

---

### Sprint A-3 — API analytics admin (1 semaine)

**Objectif :** Exposer toutes les métriques via une API REST sécurisée, consommable par le dashboard Angular.

#### Tâches

**A-3.1 — `AnalyticsAdminController.java`**

Nouveau controller : `com.kovixel.analytics.controller.AnalyticsAdminController`

Endpoints :

```
GET /api/v1/admin/analytics/overview
→ KPIs du jour : DAU live, docs traités, outil le plus utilisé, nouveaux inscrits
→ Données : mix Redis (live) + dernier snapshot PostgreSQL

GET /api/v1/admin/analytics/tools?from=2026-06-01&to=2026-06-30
→ Usage par outil : count, taux succès, durée moy., taux d'adoption (distinct users / total users), évolution sur la période
→ Données : analytics_daily_snapshots

GET /api/v1/admin/analytics/users?period=30d
→ Acquisition, rétention, MAU, North Star metric, distribution plans
→ Données : analytics_daily_snapshots + kovixel_users

GET /api/v1/admin/analytics/geo
→ Répartition par pays et continent (top 10 pays)
→ Données : user_geo (JOIN kovixel_users)

GET /api/v1/admin/analytics/retention?cohort=2026-06-01
→ Courbe de rétention pour la cohorte de la semaine donnée (J+1, J+7, J+14, J+30)
→ Données : analytics_events + kovixel_users

GET /api/v1/admin/analytics/errors?from=2026-06-01&to=2026-06-30
→ Répartition des erreurs par outil et par type (TIMEOUT, UNSUPPORTED_FORMAT, AI_API_ERROR...)
→ Données : analytics_daily_snapshots (metric: tool_error_type)

GET /api/v1/admin/analytics/quota-hits?period=30d
→ Utilisateurs FREE ayant atteint leur limite, par outil et par semaine → leads upsell qualifiés
→ Données : analytics_events (QUOTA_REACHED) + analytics_daily_snapshots

GET /api/v1/admin/analytics/storage
→ Consommation de stockage totale et par plan, évolution sur 6 mois
→ Données : Redis (live) + analytics_daily_snapshots (metric: storage_gb_total, storage_gb_per_plan)

GET /api/v1/admin/analytics/funnel?tool=SUMMARY&from=2026-06-01&to=2026-06-30
→ Taux d'abandon par outil : ratio tool_started / tool_completed (données Umami exportées)
→ Données : Umami API (events custom tool_started / tool_completed)
```

**A-3.2 — Sécurisation**

Tous les endpoints `/api/v1/admin/**` sont protégés par `ROLE_ADMIN` dans `SecurityConfig` :
```java
.requestMatchers("/api/v1/admin/**").hasRole("ADMIN")
```

Le rôle `ADMIN` existe déjà dans l'enum `User.role`. Pas de migration nécessaire.

**A-3.3 — Format de réponse**

Toutes les réponses suivent un format unifié :
```json
{
  "period": { "from": "2026-06-01", "to": "2026-06-30" },
  "generatedAt": "2026-06-19T14:32:00Z",
  "data": { ... }
}
```

**A-3.4 — Cache API**

Responses du dashboard mises en cache Redis (TTL 1h) pour éviter des requêtes lourdes répétées :
```java
@Cacheable(value = "analytics", key = "#endpoint + ':' + #period")
```

**Critères de sortie Sprint A-3 :**
- [ ] Tous les endpoints répondent correctement avec des données de test
- [ ] Sécurisation ROLE_ADMIN vérifiée (test 401/403)
- [ ] Réponse overview < 100ms (grâce au cache + snapshots pré-calculés)
- [ ] Documentation OpenAPI générée pour tous les endpoints analytics

---

### Sprint A-4 — Trafic frontend avec Umami (1 semaine)

**Objectif :** Capturer les métriques de navigation frontend sans aucun cookie, sans bandeau de consentement, en conformité RGPD native.

#### Tâches

**A-4.1 — Déploiement Umami**

Umami est une application Node.js avec PostgreSQL. Deux options de déploiement :

**Option A (recommandée) : base PostgreSQL séparée**
```yaml
# docker-compose.yml (extrait)
umami:
  image: ghcr.io/umami-software/umami:postgresql-latest
  environment:
    DATABASE_URL: postgresql://umami_user:${UMAMI_DB_PASS}@postgres-umami:5432/umami_db
    APP_SECRET: ${UMAMI_SECRET}
  ports:
    - "3000:3000"
```

**Option B : base Kovixel existante** (schema séparé `umami` dans le même Postgres) — acceptable en dev, déconseillé en prod (isolation des données).

**A-4.2 — Intégration Angular**

Dans `kovixel-ui/src/index.html` :
```html
<script defer 
        src="https://analytics.kovixel.com/script.js"
        data-website-id="${UMAMI_WEBSITE_ID}">
</script>
```

Variable d'environnement dans `environment.ts` :
```typescript
export const environment = {
  umamiWebsiteId: '...',
  umamiEnabled: true,
};
```

Service Angular `UmamiService` pour les événements custom :
```typescript
@Injectable({ providedIn: 'root' })
export class UmamiService {
  track(eventName: string, data?: Record<string, unknown>): void {
    if (typeof window !== 'undefined' && (window as any).umami) {
      (window as any).umami.track(eventName, data);
    }
  }
}
```

**A-4.3 — Événements custom à tracker**

| Événement Umami | Déclenché dans | Données |
|----------------|---------------|---------|
| `tool_started` | Ouverture du panneau outil (avant soumission) | `{ tool: 'summary' }` |
| `tool_completed` | Traitement réussi côté frontend (réponse reçue) | `{ tool: 'summary' }` |
| `document_uploaded` | Upload réussi | `{ file_type: 'pdf' }` |
| `plan_page_viewed` | Visite page tarification | — |
| `quota_reached_ui` | Affichage du message "quota atteint" | `{ tool: 'summary', plan: 'FREE' }` |
| `share_used` | Clic sur une option du menu Partager | `{ method: 'copy_link' \| 'email' \| 'native_share' }` |
| `registration_started` | Ouverture formulaire d'inscription | — |
| `registration_completed` | Inscription réussie | `{ provider: 'google' }` |

Le ratio `tool_started` / `tool_completed` donne directement le **taux d'abandon par outil** sans requête backend.

**A-4.4 — Données Umami disponibles sans configuration supplémentaire**

Dès que le script est en place, Umami capture automatiquement :
- Pages vues (toutes les routes Angular)
- Sessions (durée, pages/session, rebond)
- Pays et ville (via IP, anonymisé — pas de tracking individuel)
- Device (mobile/tablet/desktop) et OS
- Navigateur
- Sources de trafic (referrer)

**Critères de sortie Sprint A-4 :**
- [ ] Umami self-hosted opérationnel et accessible sur `analytics.kovixel.com`
- [ ] Script chargé dans Angular, pages vues trackées (vérifiable dans dashboard Umami)
- [ ] Événements custom déclenchés et visibles
- [ ] Zéro cookie posé (vérification via devtools)
- [ ] Aucun bandeau de consentement requis (validé RGPD)

---

### Sprint A-5 — Stats utilisateur personnel — backend (1 semaine)

**Objectif :** Préparer les données personnelles de chaque utilisateur pour leur future exposition dans le profil. Backend uniquement — le front attend le Sprint A-7.

#### Tâches

**A-5.1 — `AnalyticsUserController.java`**

Nouveau controller : `com.kovixel.analytics.controller.AnalyticsUserController`

```
GET /api/v1/me/stats
→ Statistiques personnelles de l'utilisateur authentifié (JWT)

Réponse :
{
  "period": "2026-06",
  "documentsUploaded": 14,
  "toolsUsed": {
    "SUMMARY": 8,
    "QNA": 12,
    "PDF_TO_WORD": 3,
    "EXTRACTION": 2
  },
  "distinctToolsUsed": 4,
  "totalProcessingTime": 47200,  // ms
  "estimatedTimeSavedMinutes": 210,
  "planInfo": {
    "currentPlan": "FREE",
    "quotaUsed": { "SUMMARY": 8, "QNA": 12 },
    "quotaLimit": { "SUMMARY": 10, "QNA": 20 }
  },
  "memberSince": "2026-04-12",
  "isMultiToolUser": true
}
```

**A-5.2 — Calcul "temps économisé"**

Service `TimeSavedCalculatorService` avec constantes configurables :
```java
@Component
public class TimeSavedCalculatorService {
    private static final Map<String, Integer> MINUTES_SAVED = Map.of(
        "SUMMARY",      20,
        "QNA",          15,
        "EXTRACTION",   30,
        "PDF_TO_WORD",  25,
        "TRANSLATION",  20,
        "PREVIEW",       5
    );

    public int calculate(Map<String, Long> toolUsageCounts) {
        return toolUsageCounts.entrySet().stream()
            .mapToInt(e -> MINUTES_SAVED.getOrDefault(e.getKey(), 0) * e.getValue().intValue())
            .sum();
    }
}
```

**A-5.3 — Historique 30 jours**

```
GET /api/v1/me/stats/history?period=30d
→ Activité quotidienne sur 30 jours (pour graphique "sparkline" dans le dashboard utilisateur)

[
  { "date": "2026-06-01", "actionsCount": 3, "toolsUsed": ["SUMMARY", "QNA"] },
  { "date": "2026-06-02", "actionsCount": 0, "toolsUsed": [] },
  ...
]
```

**Critères de sortie Sprint A-5 :**
- [ ] `/api/v1/me/stats` retourne des données correctes pour les comptes de test
- [ ] Calcul "temps économisé" cohérent et non-absurde
- [ ] Sécurité : un utilisateur ne peut accéder qu'à ses propres stats (userId du JWT)
- [ ] Performance : réponse < 200ms

---

### Sprint A-6 — Dashboard admin Angular (2 semaines)

**Objectif :** Interface de pilotage interne. Accès ROLE_ADMIN uniquement.

#### Tâches

**A-6.1 — Route admin**

Nouvelle route dans Angular : `/admin/analytics`  
Guard : `AdminGuard` (vérifie `user.role === 'ADMIN'`)

**A-6.2 — Composant `kov-admin-analytics`**

Structure de la page :

```
┌─────────────────────────────────────────────────────┐
│  KPIs LIVE (cartes, données Redis + dernier snapshot) │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐ │
│  │ 142 DAU  │ │ 891 Users│ │ 47 PRO   │ │ 63 MAU  │ │
│  │ (+12%)   │ │ (+8 auj.)│ │ (5.3%)   │ │ multi   │ │
│  └──────────┘ └──────────┘ └──────────┘ └─────────┘ │
├─────────────────────────────────────────────────────┤
│  ACQUISITION — Nouveaux inscrits (graphique 30j)     │
│  OUTILS — Bar chart usage par outil                  │
├────────────────────────┬────────────────────────────┤
│  GÉOGRAPHIE            │  PLANS                      │
│  Carte + top 5 pays    │  Donut FREE/PRO/ENTERPRISE  │
├────────────────────────┴────────────────────────────┤
│  RÉTENTION — Courbe J+1/J+7/J+14/J+30               │
├─────────────────────────────────────────────────────┤
│  OUTILS — Tableau détaillé                           │
│  Outil | Count | Succès | Durée moy | Erreurs        │
└─────────────────────────────────────────────────────┘
```

**A-6.3 — Sélecteur de période**

Boutons de sélection rapide : `7j` `30j` `90j` + sélecteur de dates custom.  
Toutes les cartes se rafraîchissent à la sélection.

**A-6.4 — Bibliothèque de graphiques**

Recommandation : **Chart.js** via `ng2-charts` (déjà couramment utilisé avec Angular, léger).

Graphiques à implémenter :
- Ligne : acquisition quotidienne (30j)
- Barres : usage par outil
- Anneau : distribution des plans
- Ligne : courbe de rétention par cohorte

**A-6.5 — Actualisation automatique**

Dashboard rafraîchi toutes les 5 minutes via `interval(300_000)` RxJS.  
Compteurs live (Redis) rafraîchis toutes les 60 secondes.

**Critères de sortie Sprint A-6 :**
- [ ] Dashboard accessible sur `/admin/analytics` (protégé ROLE_ADMIN)
- [ ] Tous les KPIs affichés avec données réelles (pas de mocks)
- [ ] Graphiques fonctionnels (acquisition, outils, rétention, géo)
- [ ] Sélecteur de période opérationnel
- [ ] Responsive (lisible sur tablette pour les admins en déplacement)

---

### Sprint A-7 — Dashboard utilisateur Angular (1 semaine)

**Prérequis :** Système de rôles/profil utilisateur implémenté (hors périmètre de cette roadmap).

**Objectif :** Montrer à l'utilisateur la valeur qu'il tire de Kovixel, renforcer la rétention.

#### Tâches

**A-7.1 — Section "Mes statistiques" dans le profil**

Nouveau composant `kov-user-stats`, intégré dans la page profil existante (ou une route `/profile/stats`).

Contenu :
```
┌─────────────────────────────────────────────────────┐
│  📊 Votre activité ce mois                           │
│  ┌──────────┐ ┌───────────────┐ ┌────────────────┐  │
│  │ 14 docs  │ │ ~3h30 économ. │ │ 4 outils util. │  │
│  │ traités  │ │ ce mois       │ │ sur 6          │  │
│  └──────────┘ └───────────────┘ └────────────────┘  │
│                                                      │
│  Utilisation par outil (barres horizontales)         │
│  Résumé IA     ████████ 8                            │
│  Q&A           ████████████ 12                       │
│  Conversion    ███ 3                                 │
│  Extraction    ██ 2                                  │
│                                                      │
│  Quota restant ce mois                               │
│  Résumés  [████████░░] 8/10                          │
│  Q&A      [████████████░░░░░░░░] 12/20              │
└─────────────────────────────────────────────────────┘
```

**A-7.2 — "Sparkline" activité 30 jours**

Mini-graphique montrant les jours d'activité sur le dernier mois (vert = actif, gris = inactif).  
Données depuis `GET /api/v1/me/stats/history`.

**Critères de sortie Sprint A-7 :**
- [ ] Page stats accessible et correctement protégée (propres données uniquement)
- [ ] "Temps économisé" affiché avec le `~` d'approximation
- [ ] Quota restant cohérent avec la réalité (cross-check `usage_records`)
- [ ] Accessible mobile (design responsive)

---

### Sprint A-8 — Alertes & rapports automatiques (continu)

**Objectif :** Passer d'un dashboard passif (je vais regarder) à un système actif (on me prévient).

#### Tâches

**A-8.1 — Alertes métier**

Service `AnalyticsAlertService` exécuté après chaque job d'agrégation :

| Condition | Alerte | Canal |
|-----------|--------|-------|
| DAU < 80% du DAU moyen des 7 derniers jours | Chute d'activité inhabituelle | Email admin |
| Taux d'erreur d'un outil > 5% | Outil dégradé — vérifier logs | Email admin |
| Erreurs `TIMEOUT` > 2% sur un outil | Problème de performance ou capacité | Email admin |
| Erreurs `AI_API_ERROR` > 1% | Provider IA dégradé | Email admin |
| Erreurs `UNSUPPORTED_FORMAT` > 3% | Format non géré fréquent → documenter ou supporter | Email admin |
| 0 nouvel inscrit depuis 48h | Acquisition stoppée | Email admin |
| Taux de succès global < 95% | Performance dégradée | Email admin |
| MAU multi-outil en baisse 2 semaines consécutives | North Star en danger | Email admin |
| > 25% des utilisateurs FREE atteignent leur quota/mois | Opportunité upsell critique | Email admin |
| Stockage total > 80% de la capacité configurée | Capacité Minio/S3 à surveiller | Email admin |
| Taux d'abandon d'un outil > 50% (tool_started sans tool_completed) | Friction UX majeure | Email admin |

**A-8.2 — Rapport hebdomadaire automatique**

Email envoyé chaque lundi à 8h00 à l'adresse admin :

```
Kovixel — Rapport de la semaine du 16 au 22 juin 2026

📈 Croissance : +23 nouveaux utilisateurs (+8% vs semaine précédente)
👥 Utilisateurs actifs : 142 DAU moyen | 534 MAU
🌟 North Star : 63 utilisateurs multi-outils (+5 vs S-1)
🔧 Outil le plus utilisé : Q&A (312 sessions)
✅ Taux de succès global : 97.3%
⏱  Durée de traitement moy. : 4.2s

Continuer à surveiller : taux d'activation (38%) en dessous de la cible (50%)
```

**A-8.3 — Archivage des snapshots**

Les snapshots de plus de 2 ans sont archivés dans une table `analytics_snapshots_archive` (même structure), les données source étant purgées de `analytics_daily_snapshots` pour maintenir les performances.

---

## 7. Migrations Flyway

| Version | Fichier | Sprint | Description |
|---------|---------|--------|-------------|
| V38 | `V38__create_analytics_events.sql` | A-1 | Table d'événements bruts |
| V39 | `V39__create_user_geo.sql` | A-1 | Géolocalisation utilisateurs |
| V40 | `V40__create_analytics_daily_snapshots.sql` | A-2 | Agrégats quotidiens |
| V41 | `V41__add_test_account_flag.sql` | A-1 (pré-requis) | Flag exclusion comptes de test des métriques |

### V38 — `analytics_events`

```sql
CREATE TABLE analytics_events (
    id              BIGSERIAL       PRIMARY KEY,
    event_type      VARCHAR(50)     NOT NULL,
    user_id         BIGINT          REFERENCES kovixel_users(id) ON DELETE SET NULL,
    tool_name       VARCHAR(50),
    properties      JSONB,
    country_code    CHAR(2),
    continent_code  VARCHAR(2),
    device_type     VARCHAR(10),
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ae_user_id      ON analytics_events (user_id, created_at DESC);
CREATE INDEX idx_ae_event_type   ON analytics_events (event_type, created_at DESC);
CREATE INDEX idx_ae_tool_name    ON analytics_events (tool_name, created_at DESC)
    WHERE tool_name IS NOT NULL;
CREATE INDEX idx_ae_created_at   ON analytics_events (created_at DESC);
CREATE INDEX idx_ae_properties   ON analytics_events USING GIN (properties);

-- Rétention : 6 mois (purge automatique via job mensuel)
-- Les agrégats dans analytics_daily_snapshots sont conservés indéfiniment
```

### V39 — `user_geo`

```sql
CREATE TABLE user_geo (
    user_id         BIGINT          PRIMARY KEY
                                    REFERENCES kovixel_users(id) ON DELETE CASCADE,
    country_code    CHAR(2),
    country_name    VARCHAR(100),
    continent_code  VARCHAR(2),
    continent_name  VARCHAR(50),
    is_eu           BOOLEAN         NOT NULL DEFAULT FALSE,
    located_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ug_country_code   ON user_geo (country_code);
CREATE INDEX idx_ug_continent_code ON user_geo (continent_code);
CREATE INDEX idx_ug_is_eu          ON user_geo (is_eu);
```

### V41 — `is_test_account` sur `kovixel_users`

```sql
ALTER TABLE kovixel_users
    ADD COLUMN is_test_account BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX idx_ku_is_test ON kovixel_users (is_test_account)
    WHERE is_test_account = TRUE;

COMMENT ON COLUMN kovixel_users.is_test_account IS
    'Exclut ce compte de toutes les requêtes analytics (comptes internes, CI, démonstrations).';
```

**Règle d'application :** toutes les requêtes de l'`AnalyticsAggregationJob` et des controllers analytics ajoutent systématiquement `WHERE ku.is_test_account = FALSE`. Sans cette clause, les comptes de test internes gonflent artificiellement les métriques d'acquisition et de rétention.

### V40 — `analytics_daily_snapshots`

```sql
CREATE TABLE analytics_daily_snapshots (
    id              BIGSERIAL       PRIMARY KEY,
    snapshot_date   DATE            NOT NULL,
    metric_name     VARCHAR(100)    NOT NULL,
    dimension       VARCHAR(100),
    value           BIGINT          NOT NULL,
    computed_at     TIMESTAMP       NOT NULL DEFAULT NOW(),
    UNIQUE(snapshot_date, metric_name, COALESCE(dimension, ''))
);

CREATE INDEX idx_ads_date_metric  ON analytics_daily_snapshots (snapshot_date DESC, metric_name);
CREATE INDEX idx_ads_metric       ON analytics_daily_snapshots (metric_name, snapshot_date DESC);
```

---

## 8. Décisions d'architecture (ADR)

### ADR-001 : PostgreSQL vs base de données temps-série

**Décision :** PostgreSQL existant pour les métriques, pas de TimescaleDB ou ClickHouse.

**Contexte :** Les bases de données temps-série (InfluxDB, TimescaleDB, ClickHouse) sont optimisées pour les écritures à haute fréquence et les aggregations sur de longues périodes.

**Raisons du choix PostgreSQL :**
- Kovixel est en phase dev/pré-prod : les volumes sont très faibles (< 10 000 événements/jour au lancement)
- Zéro nouvelle infrastructure, zéro courbe d'apprentissage
- La pré-agrégation nocturne (`analytics_daily_snapshots`) rend les requêtes dashboard O(1) — plus besoin d'agréger à la volée
- Migration vers TimescaleDB est une extension PostgreSQL : si le besoin arrive, la migration est transparente (même API, même JDBC driver)

**Point de déclenchement pour migrer :** > 1 million d'événements/jour en base, ou requêtes d'agrégation > 2s malgré les index.

### ADR-002 : Umami vs Google Analytics vs PostHog

**Décision :** Umami self-hosted pour le tracking frontend.

**Analyse comparative :**

| Critère | Google Analytics 4 | PostHog | Umami |
|---------|-------------------|---------|-------|
| RGPD sans consentement | ❌ | ⚠️ (configurable) | ✅ |
| Auto-hébergeable | ❌ | ✅ | ✅ |
| Coût | Gratuit (données → Google) | Gratuit self-hosted | Gratuit |
| Features | Très riche | Très riche (funnel, replay) | Essentiel |
| Complexité infra | Nulle | Élevée | Faible (1 container) |
| Cohérence message sécurité | ❌ (données US) | ✅ | ✅ |

**Raison du choix :** Umami est cohérent avec le positionnement sécurité/confidentialité de Kovixel, ne nécessite pas de bandeau de consentement (atout UX et légal), et couvre tous les besoins de la Couche 3 pour un produit en phase de croissance.

PostHog est une excellente option B si les besoins en session replay et funnel d'analyse avancée deviennent nécessaires.

### ADR-003 : Événements asynchrones vs synchrones

**Décision :** Tous les appels analytics sont asynchrones (`@Async`).

**Raison :** Un utilisateur qui génère un résumé ne doit jamais attendre que l'événement analytics soit écrit en base. Le chemin critique (traitement IA → réponse JSON) ne doit jamais être rallongé par de l'instrumentation. En cas de panne de la base analytics, le produit continue de fonctionner normalement.

**Implémentation :** Pool de threads dédié `analyticsExecutor` (séparé du `processingExecutor` des jobs IA), avec queue bornée pour éviter la saturation mémoire.

### ADR-004 : GeoIP à l'inscription uniquement vs à chaque événement

**Décision :** Géolocalisation effectuée **une seule fois**, à l'inscription, stockée dans `user_geo`.

**Raison :** 
- La géo d'un utilisateur ne change pas souvent
- Résoudre l'IP à chaque événement multiplierait le coût par le nombre d'événements
- L'IP de l'inscription est la plus représentative du profil de l'utilisateur (pas affectée par les VPN occasionnels)
- Confidentialité : on ne stocke pas l'IP, uniquement le pays/continent résolu

**Exception :** Si un utilisateur change de pays (détection : pays de connexion différent du pays enregistré pendant > 30 jours), `user_geo` est mis à jour.

### ADR-005 : Clé de dimension flexible dans `analytics_daily_snapshots`

**Décision :** Table de snapshots avec une colonne `dimension` flexible (VARCHAR) plutôt qu'une colonne par dimension.

**Alternatives envisagées :**
- Table par type de métrique → prolifération de tables, migrations à chaque nouvelle métrique
- JSONB unique → requêtes complexes, pas de UNIQUE constraint sur dimensions

**Avantages du design retenu :**
- Ajout d'une nouvelle métrique = zéro migration Flyway
- Requête dashboard uniforme : `WHERE metric_name = 'tool_usage' AND dimension = 'SUMMARY'`
- UNIQUE constraint garantit l'idempotence du job d'agrégation

---

## 9. Risques et mitigations

| Risque | Probabilité | Impact | Mitigation |
|--------|------------|--------|------------|
| **Base GeoLite2 obsolète** (mise à jour mensuelle ratée) | Moyenne | Faible (géo légèrement imprécise) | Job de mise à jour avec alerte si échec. Monitoring de la date de la DB. |
| **Perte des compteurs Redis** (redémarrage) | Faible | Faible (pertes partielles du compteur du jour) | TTL 48h + persistance Redis AOF. Job nightly lit Redis **avant** expiration. |
| **Job d'agrégation qui rate une nuit** | Faible | Moyen (jour manquant dans les snapshots) | Job idempotent + endpoint de recalcul manuel + alerte mail si le job ne tourne pas. |
| **Performances dégradées** sur `analytics_events` à grande échelle | Faible court terme | Moyen long terme | Partitionnement par mois (PostgreSQL `PARTITION BY RANGE`) activable sans migration applicative. Purge à 6 mois. |
| **Données analytics biaisées** par les comptes de test internes | Moyenne | Moyen | Filtrer les userId marqués `is_test_account` (champ à ajouter sur `kovixel_users`). |
| **Umami unavailable** | Faible | Faible (le script échoue silencieusement) | `async defer` = le script Umami ne bloque jamais le chargement Angular. |
| **Dashboard admin accessible** à un non-admin | Infime (Spring Security) | Critique | Tests d'intégration de sécurité automatisés (`@WithMockUser(roles="USER")` → 403). |
| **Coûts de stockage imprévus** (fichiers non supprimés, gros fichiers) | Moyenne | Moyen | Compteur Redis `storage_bytes_total` en temps réel, alerte à 80% capacité. Politique de purge des documents inactifs > 6 mois. |

---

## 10. KPIs de la roadmap

Ces indicateurs mesurent le succès de la roadmap elle-même (méta-niveau).

| KPI | Cible | Mesure |
|-----|-------|--------|
| Couverture d'instrumentation | 100% des outils tracés | Count event_types distincts dans analytics_events |
| Fraîcheur des snapshots | Snapshot J-1 disponible avant 4h00 | Alerte si `computed_at > 04:00` pour J-1 |
| Précision géo | > 95% des inscrits géolocalisés (hors env dev) | `COUNT(*) FROM user_geo / COUNT(*) FROM kovixel_users` |
| Latence API analytics | < 150ms (p99) | Métriques Micrometer sur les endpoints `/analytics/*` |
| Disponibilité Umami | > 99.5% | Health check + monitoring uptime |
| Faux négatifs sur alertes | < 5% de fausses alertes / mois | Revue manuelle mensuelle |

---

## 11. Conformité RGPD

### Ce qui est conforme nativement

| Traitement | Base légale | Mesure technique |
|-----------|------------|-----------------|
| Géolocalisation à l'inscription | Intérêt légitime (amélioration du service) | Seul le pays est stocké, pas l'IP |
| Tracking des outils utilisés | Contrat (fourniture du service) | Données liées au compte, pseudonymisées |
| Analytics frontend (Umami) | Pas de traitement de données personnelles | Pas de cookies, pas d'IP, pas de fingerprint |
| Rapports agrégés | Statistiques anonymes | Pas de données individuelles dans les snapshots |

### Ce qui nécessite attention

- **`analytics_events.user_id`** : donnée personnelle (identifiant). Doit être supprimé ou mis à NULL lors d'une demande de suppression de compte (cascade déjà configurée avec `ON DELETE SET NULL`).
- **`user_geo`** : supprimée automatiquement via `ON DELETE CASCADE` sur `kovixel_users`.
- **Rétention** : `analytics_events` purgée à 6 mois (événements bruts). Les snapshots agrégés (anonymes) sont conservés indéfiniment.
- **Droit d'accès** : `/api/v1/me/stats` permet à l'utilisateur de voir ses propres données analytics — conforme Art. 15 RGPD.

### Ce que cette roadmap n'introduit PAS

- Aucun cookie analytics (Umami est cookieless)
- Aucun tracking cross-site
- Aucune revente ou partage de données avec des tiers
- Aucun fingerprinting navigateur

---

## 12. Glossaire

| Terme | Définition |
|-------|-----------|
| **DAU** | Daily Active Users. Nombre d'utilisateurs distincts ayant effectué au moins une action dans la journée. |
| **MAU** | Monthly Active Users. Même définition sur 30 jours glissants. |
| **North Star Metric** | Métrique unique qui capture le mieux la valeur créée pour les utilisateurs. Pour Kovixel : MAU multi-outil. |
| **AARRR** | Framework produit : Acquisition, Activation, Rétention, Referral, Revenue. Cadre de lecture des métriques. |
| **Cohorte** | Groupe d'utilisateurs ayant effectué une action commune au même moment (ex: inscrits la semaine du 1er juin). |
| **Rétention J+7** | Pourcentage d'utilisateurs d'une cohorte encore actifs 7 jours après leur inscription. |
| **Time-to-value** | Délai entre l'inscription et la première utilisation d'un outil. Indicateur d'activation. |
| **North Star en danger** | MAU multi-outil en baisse 2 semaines consécutives → intervention produit nécessaire. |
| **Pré-agrégation** | Calcul anticipé des métriques (la nuit) pour que le dashboard les lise instantanément sans calcul à la volée. |
| **GeoLite2** | Base de données de géolocalisation IP de MaxMind. Gratuite, auto-hébergée, mise à jour mensuelle. |
| **Umami** | Outil d'analytics web open source, sans cookies, RGPD-natif. Alternative à Google Analytics. |
| **Cookieless** | Analytics fonctionnant sans déposer de cookies — aucun consentement requis en droit européen. |
| **Sparkline** | Mini-graphique compact sans axes, représentant une tendance temporelle (ex: activité des 30 derniers jours). |
| **Stickiness** | Rapport DAU/MAU. Mesure à quel point les utilisateurs reviennent régulièrement. Cible Kovixel : > 20%. |
| **Temps économisé** | Estimation du temps manuel évité grâce à Kovixel. Affiché à l'utilisateur pour renforcer la valeur perçue. |
| **QUOTA_REACHED** | Événement déclenché quand un utilisateur atteint sa limite de plan. Signal de conversion FREE→PRO le plus direct. |
| **Taux d'abandon** | Ratio `tool_started` / `tool_completed`. Mesure la fraction d'utilisateurs qui ouvrent un outil sans aller au bout. Tracé via Umami. |
| **Re-engagement** | Retour d'un utilisateur inactif depuis > 30 jours. Cible privilégiée pour les futures campagnes email de rétention. |
| **is_scanned** | Flag indiquant qu'un PDF est scanné (image numérisée) plutôt que natif (texte extractible). Les PDFs scannés requièrent OCR et ont un taux d'erreur structurellement plus élevé. |
| **Coefficient viral** | Nombre de nouveaux utilisateurs générés en moyenne par un utilisateur via le partage. Précurseur mesurable : taux d'utilisation de chaque méthode du bouton Partager. |
| **document_id dans JSONB** | Champ optionnel présent dans `TOOL_USED.properties`. Permet de corréler les outils utilisés sur le même document et de calculer le North Star variante "multi-outil même document". |

---

*Fin du document — Version 1.2 — 2026-06-19 (révision : ajout taux d'adoption par outil, migration V41 is_test_account)*
