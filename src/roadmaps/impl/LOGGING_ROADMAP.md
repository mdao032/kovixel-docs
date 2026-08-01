# Logging Applicatif — Analyse & Roadmap

> **Date de rédaction :** 2026-06-17  
> **Scope :** Backend Spring Boot (Kovixel)  
> **Stack :** Spring Boot 3.4.3 · Logback (inclus via starter) · PostgreSQL · Flyway

---

## 1. Diagnostic de l'infrastructure actuelle

### Ce qui existe

| Élément | État |
|---|---|
| Configuration YAML dev/prod | ✅ Présente (basique) |
| `@Slf4j` adoption | ✅ ~60 classes couvertes |
| Pattern console horodaté | ✅ Défini |
| Différenciation dev (DEBUG) / prod (WARN) | ✅ Oui |
| GlobalExceptionHandler avec logs | ✅ Oui |
| AuthRateLimitFilter avec logs | ✅ Oui |

### Ce qui manque (critique)

| Problème | Impact |
|---|---|
| Aucun appender fichier | Tous les logs prod sont perdus au redémarrage |
| Pas de `logback-spring.xml` | Impossible de configurer rolling, async, multi-appenders |
| Aucun MDC (correlation-ID) | Impossible de tracer une requête de bout en bout dans les logs |
| Pas de niveau par sous-package | `com.kovixel.ai` et `com.kovixel.core` au même niveau |
| Pas de filtre HTTP de traçage | Requêtes entrantes non journalisées |
| 9 fichiers `hs_err_pid*.log` à la racine | Crashes JVM non surveillés |

### Conclusion

L'infrastructure est adéquate pour **le développement local** (console lisible, niveaux différenciés). Elle est **insuffisante pour la production** : aucun fichier de log n'est créé, une panne ou un bug en production laisse zéro trace exploitable après redémarrage.

---

## 2. Objectifs

1. **Fichiers journaliers** — un fichier par jour, nommé `kovixel-YYYY-MM-DD.log`
2. **Rétention 30 jours** — suppression automatique au-delà, compression `.gz` pour les jours passés
3. **Traçabilité des requêtes** — chaque ligne de log contient `requestId`, `userId`, `method`, `path`
4. **Séparation des niveaux** — fichier complet (INFO+) + fichier erreurs uniquement (ERROR+)
5. **Zéro impact sur les performances** — appender asynchrone (I/O hors du thread HTTP)
6. **Configuration par profil** — dev = console seule, prod = console + fichiers

---

## 3. Architecture de logging proposée

```
┌─────────────────────────────────────────────────────────────────────┐
│  Request HTTP entrante                                               │
│  ↓                                                                  │
│  [RequestTracingFilter]  ──→  MDC.put(requestId, userId, path…)    │
│  ↓                                                                  │
│  Business Logic / Services / IA / Conversion                       │
│  ↓                                                                  │
│  SLF4J Logger (@Slf4j)                                              │
│  ↓                                                                  │
│  Logback Root Appender                                              │
│       ├── [PROFIL DEV]   ConsoleAppender (coloré, verbeux)         │
│       └── [PROFIL PROD]  AsyncAppender                             │
│                               ├── ConsoleAppender (structured)     │
│                               ├── RollingFileAppender (INFO+)      │
│                               │     kovixel-YYYY-MM-DD.log         │
│                               │     rétention : 30 jours / 500 MB  │
│                               └── RollingFileAppender (ERROR only) │
│                                     kovixel-error-YYYY-MM-DD.log   │
│                                     rétention : 90 jours           │
└─────────────────────────────────────────────────────────────────────┘
```

**Emplacement des fichiers en prod :**

```
/var/log/kovixel/
├── kovixel-2026-06-17.log          ← fichier du jour (actif)
├── kovixel-2026-06-16.log.gz       ← J-1, compressé
├── kovixel-2026-06-15.log.gz
├── …                               ← jusqu'à J-30
├── kovixel-error-2026-06-17.log    ← erreurs du jour
└── kovixel-error-2026-06-16.log.gz
```

---

## 4. Configuration `logback-spring.xml`

**Emplacement :** `src/main/resources/logback-spring.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration scan="true" scanPeriod="30 seconds">

  <!-- ── Propriétés ──────────────────────────────────────────────── -->
  <springProperty name="LOG_DIR"   source="logging.file.path"   defaultValue="/var/log/kovixel"/>
  <springProperty name="APP_NAME"  source="spring.application.name" defaultValue="kovixel"/>
  <springProperty name="LOG_LEVEL" source="logging.level.root"  defaultValue="INFO"/>

  <!-- Patterns -->
  <property name="CONSOLE_PATTERN"
            value="%d{HH:mm:ss.SSS} %highlight(%-5level) %cyan(%logger{30}) [%X{requestId:-—}] [%X{userId:-guest}] — %msg%n"/>
  <property name="FILE_PATTERN"
            value="%d{yyyy-MM-dd HH:mm:ss.SSS} %-5level %logger{50} [%thread] [%X{requestId:-—}] [%X{userId:-guest}] [%X{httpMethod:-} %X{httpPath:-}] — %msg%n"/>

  <!-- ── Appenders ───────────────────────────────────────────────── -->

  <!-- Console (dev & prod) -->
  <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <pattern>${CONSOLE_PATTERN}</pattern>
      <charset>UTF-8</charset>
    </encoder>
  </appender>

  <!-- Fichier principal : tous niveaux INFO+ (profil prod uniquement) -->
  <springProfile name="prod">
    <appender name="FILE_ALL" class="ch.qos.logback.core.rolling.RollingFileAppender">
      <file>${LOG_DIR}/${APP_NAME}.log</file>
      <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
        <!-- Rotation quotidienne, compression automatique -->
        <fileNamePattern>${LOG_DIR}/${APP_NAME}-%d{yyyy-MM-dd}.log.gz</fileNamePattern>
        <!-- Rétention : 30 jours -->
        <maxHistory>30</maxHistory>
        <!-- Taille totale max (filet de sécurité) -->
        <totalSizeCap>500MB</totalSizeCap>
        <cleanHistoryOnStart>true</cleanHistoryOnStart>
      </rollingPolicy>
      <encoder>
        <pattern>${FILE_PATTERN}</pattern>
        <charset>UTF-8</charset>
      </encoder>
      <!-- N'écrit que INFO et au-dessus -->
      <filter class="ch.qos.logback.classic.filter.ThresholdFilter">
        <level>INFO</level>
      </filter>
    </appender>

    <!-- Fichier erreurs uniquement : ERROR+ — rétention longue (audit) -->
    <appender name="FILE_ERROR" class="ch.qos.logback.core.rolling.RollingFileAppender">
      <file>${LOG_DIR}/${APP_NAME}-error.log</file>
      <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
        <fileNamePattern>${LOG_DIR}/${APP_NAME}-error-%d{yyyy-MM-dd}.log.gz</fileNamePattern>
        <maxHistory>90</maxHistory>
        <totalSizeCap>200MB</totalSizeCap>
        <cleanHistoryOnStart>true</cleanHistoryOnStart>
      </rollingPolicy>
      <encoder>
        <pattern>${FILE_PATTERN}</pattern>
        <charset>UTF-8</charset>
      </encoder>
      <filter class="ch.qos.logback.classic.filter.LevelFilter">
        <level>ERROR</level>
        <onMatch>ACCEPT</onMatch>
        <onMismatch>DENY</onMismatch>
      </filter>
    </appender>

    <!-- AsyncAppender : enveloppe les deux FileAppenders pour éviter tout blocage I/O -->
    <appender name="ASYNC_FILE" class="ch.qos.logback.classic.AsyncAppender">
      <queueSize>2048</queueSize>
      <discardingThreshold>0</discardingThreshold>
      <includeCallerData>false</includeCallerData>
      <neverBlock>true</neverBlock>
      <appender-ref ref="FILE_ALL"/>
      <appender-ref ref="FILE_ERROR"/>
    </appender>
  </springProfile>

  <!-- ── Niveaux par package ─────────────────────────────────────── -->

  <!-- Framework — minimiser le bruit -->
  <logger name="org.springframework"            level="WARN"/>
  <logger name="org.springframework.security"   level="WARN"/>
  <logger name="org.springframework.web"        level="WARN"/>
  <logger name="org.springframework.boot"       level="INFO"/>
  <logger name="org.hibernate"                  level="WARN"/>

  <!-- SQL lisible uniquement en dev -->
  <springProfile name="dev">
    <logger name="org.hibernate.SQL"               level="DEBUG"/>
    <logger name="org.hibernate.orm.jdbc.bind"     level="TRACE"/>
  </springProfile>
  <springProfile name="prod">
    <logger name="org.hibernate.SQL"               level="WARN"/>
  </springProfile>

  <!-- Application — niveaux métier -->
  <logger name="com.kovixel"                    level="INFO"/>
  <logger name="com.kovixel.ai"                 level="INFO"/>
  <logger name="com.kovixel.ai.provider"        level="WARN"/>   <!-- éviter dump tokens IA -->
  <logger name="com.kovixel.core"               level="INFO"/>
  <logger name="com.kovixel.common.security"    level="INFO"/>
  <logger name="com.kovixel.user"               level="INFO"/>
  <logger name="com.kovixel.storage"            level="WARN"/>

  <!-- Librairies tierces -->
  <logger name="io.minio"                        level="WARN"/>
  <logger name="org.apache.poi"                  level="WARN"/>
  <logger name="reactor.netty"                   level="WARN"/>
  <logger name="io.netty"                        level="WARN"/>

  <!-- ── Root logger ────────────────────────────────────────────── -->

  <!-- Dev : console uniquement -->
  <springProfile name="dev">
    <root level="INFO">
      <appender-ref ref="CONSOLE"/>
    </root>
  </springProfile>

  <!-- Prod : console + fichiers asynchrones -->
  <springProfile name="prod">
    <root level="INFO">
      <appender-ref ref="CONSOLE"/>
      <appender-ref ref="ASYNC_FILE"/>
    </root>
  </springProfile>

</configuration>
```

> **Note :** `scan="true" scanPeriod="30 seconds"` permet de modifier les niveaux en live sans redémarrer
> (utile lors d'un debug en production).

---

## 5. MDC — Traçabilité par requête

Un filtre HTTP injecte les métadonnées dans le `MDC` de Logback. Chaque log émis pendant le traitement de la requête hérite automatiquement de ces valeurs.

**Emplacement :** `src/main/java/com/kovixel/common/logging/RequestTracingFilter.java`

```java
package com.kovixel.common.logging;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.slf4j.MDC;
import org.springframework.core.annotation.Order;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.UUID;

@Component
@Order(1)               // Premier filtre exécuté
@Slf4j
public class RequestTracingFilter extends OncePerRequestFilter {

    private static final String REQUEST_ID = "requestId";
    private static final String USER_ID    = "userId";
    private static final String METHOD     = "httpMethod";
    private static final String PATH       = "httpPath";

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String requestId = UUID.randomUUID().toString().substring(0, 8); // court mais suffisant
        MDC.put(REQUEST_ID, requestId);
        MDC.put(METHOD,     request.getMethod());
        MDC.put(PATH,       request.getRequestURI());

        // Propagation à la réponse (utile pour le débogage côté client)
        response.setHeader("X-Request-Id", requestId);

        try {
            chain.doFilter(request, response);

            // userId disponible après l'auth Spring Security
            Authentication auth = SecurityContextHolder.getContext().getAuthentication();
            if (auth != null && auth.isAuthenticated() && !"anonymousUser".equals(auth.getPrincipal())) {
                MDC.put(USER_ID, auth.getName());
            }
        } finally {
            MDC.clear(); // CRITIQUE : évite les fuites entre threads (thread pool réutilisé)
        }
    }
}
```

**Exemple de log produit avec MDC :**

```
2026-06-17 14:32:11.482 INFO  com.kovixel.ai.summary.SummaryServiceImpl [http-nio-8080-exec-3] [a3f1b9c2] [user@example.com] [POST /api/v1/ai/summary] — Résumé généré en 1843ms, modèle=claude-sonnet-4-6, tokens=2847
```

---

## 6. Politique de rétention

| Type de fichier | Rétention | Taille max | Compression |
|---|---|---|---|
| Logs applicatifs complets (INFO+) | **30 jours** | 500 MB total | `.gz` automatique |
| Logs erreurs uniquement (ERROR) | **90 jours** | 200 MB total | `.gz` automatique |

**Justification du choix 30/90 jours :**

- **30 jours** couvre les incidents typiques (débogage post-déploiement, plaintes utilisateur décalées)
- **90 jours** pour les erreurs permet l'audit de sécurité et la détection de patterns (attaques, régressions)
- Au-delà, les logs ne sont plus exploitables opérationnellement sans outillage d'agrégation
- La compression `.gz` réduit la taille d'un log de texte de ~90% → impact disque minimal

**Paramétrage via `application-prod.yml` (variables externalisables) :**

```yaml
logging:
  file:
    path: /var/log/kovixel
  level:
    root: INFO
    com.kovixel: INFO
    com.kovixel.ai.provider: WARN
    org.springframework: WARN
    org.hibernate: WARN
```

---

## 7. Suppression des logs JVM crash existants

9 fichiers `hs_err_pidXXXX.log` sont présents à la racine du projet. Ce sont des dumps de crash JVM (OOM, SIGSEGV, etc.). **À ne pas supprimer sans les analyser** — ils indiquent des instabilités passées.

**Action immédiate :**

1. Lire les 2-3 plus récents pour identifier la cause (`grep "# Problematic frame" hs_err_*.log`)
2. Si la cause est connue et corrigée, archiver dans `logs/jvm-crashes/` puis gitignorer `*.log`
3. Ajouter à `.gitignore` :

```gitignore
# JVM crash dumps
hs_err_pid*.log
replay_pid*.log

# Logs applicatifs
logs/
*.log
```

---

## 8. Plan d'implémentation

### Phase 1 — Foundation (1–2h) ✅ Recommandée immédiatement

- [ ] Créer `src/main/resources/logback-spring.xml` (voir §4)
- [ ] Supprimer les clés `logging.pattern.*` des YAML (gérées par logback-spring.xml désormais)
- [ ] Créer `RequestTracingFilter.java` (voir §5)
- [ ] Ajouter `.gitignore` pour `*.log` et `logs/`
- [ ] Créer le dossier `/var/log/kovixel/` sur le serveur de prod (ou le configurer via env)

### Phase 2 — Logging métier enrichi (2–4h)

- [ ] Ajouter `log.info()` dans `JwtAuthFilter` (tentatives valides + rejets)
- [ ] Ajouter logs dans `AnonymousQuotaFilter` (quota atteint → `log.warn(...)`)
- [ ] Logger les conversions IA avec durée + modèle + tokens consommés
- [ ] Logger les erreurs de conversion de fichiers (PDF, images) avec type de fichier + taille
- [ ] Ajouter `log.debug()` dans les providers IA (désactivé en prod, activable à la demande)

### Phase 3 — Observabilité avancée (optionnel, futur)

**Logging JSON structuré (pour agrégation Elasticsearch / Datadog / Grafana Loki) :**

Ajouter la dépendance dans `pom.xml` :

```xml
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>8.0</version>
</dependency>
```

Remplacer l'encoder dans `FILE_ALL` :

```xml
<encoder class="net.logstash.logback.encoder.LogstashEncoder">
    <includeMdcKeyName>requestId</includeMdcKeyName>
    <includeMdcKeyName>userId</includeMdcKeyName>
    <includeMdcKeyName>httpMethod</includeMdcKeyName>
    <includeMdcKeyName>httpPath</includeMdcKeyName>
</encoder>
```

Sortie JSON par ligne (NDJSON) — indexable par tout outil d'agrégation :

```json
{"@timestamp":"2026-06-17T14:32:11.482Z","level":"INFO","logger":"com.kovixel.ai.summary.SummaryServiceImpl","message":"Résumé généré en 1843ms","requestId":"a3f1b9c2","userId":"user@example.com","httpMethod":"POST","httpPath":"/api/v1/ai/summary"}
```

**Recommandation :** activer JSON uniquement si un agrégateur est mis en place (Loki/Grafana en self-hosted, ou Datadog/Axiom en SaaS). Pour le moment, le format texte est plus lisible et suffisant.

---

## 9. Résumé des fichiers à créer / modifier

| Fichier | Action | Priorité |
|---|---|---|
| `src/main/resources/logback-spring.xml` | **Créer** | 🔴 Critique |
| `src/main/java/com/kovixel/common/logging/RequestTracingFilter.java` | **Créer** | 🔴 Critique |
| `src/main/resources/application-dev.yml` | Supprimer `logging.pattern.*` | 🟡 Moyen |
| `src/main/resources/application-prod.yml` | Nettoyer + ajouter `logging.file.path` | 🔴 Critique |
| `.gitignore` (racine kovixel/) | Ajouter `*.log`, `logs/` | 🟡 Moyen |
| `JwtAuthFilter.java` | Ajouter logs tentatives auth | 🟢 Utile |
| `AnonymousQuotaFilter.java` | Ajouter logs quota dépassé | 🟢 Utile |

---

## 10. Questions ouvertes

1. **Emplacement des logs en prod** — `/var/log/kovixel/` (Linux) ou dossier Docker volume ? La variable `logging.file.path` le rend configurable via env.
2. **Accès aux logs** — SSH direct, ou doit-on exposer un endpoint `/actuator/logfile` (déjà disponible via Spring Boot Actuator) ? Penser à le sécuriser si activé.
3. **Alerting** — Pas dans le scope de cette roadmap, mais à terme : alerter sur les `ERROR` en temps réel (webhook Slack, email) plutôt que de scanner les fichiers manuellement.
