# Kovixel — Feuille de route Console Super-Admin (plateforme)

> Objectif : donner à l'équipe Kovixel (pas aux clients) une console de pilotage global —
> provisionnement des comptes Équipe/Enterprise closés par les ventes, support/dépannage,
> visibilité d'exploitation, interventions manuelles — avec une rigueur de contrôle d'accès et
> d'audit au moins équivalente à celle des références du marché (Salesforce, GitHub, Stripe).
> Dépend de `TEAM_ADMIN_ROADMAP.md` (le modèle `Organization` est ce que cette console supervise).
> Complète `SSO_SAML_ROADMAP.md` (la vérification de domaine y est gérée depuis cette console).

**Périmètre — à ne pas confondre avec la console d'administration d'organisation :**

| | Console **Organisation** (`TEAM_ADMIN_ROADMAP.md`) | Console **Super-Admin** (ce document) |
|---|---|---|
| Public | Le client (`OWNER`/`ADMIN` d'une org) | Le staff Kovixel uniquement |
| Portée | Une seule organisation, la sienne | Toutes les organisations, tous les utilisateurs |
| Création de membres | Self-service, par le client lui-même | **Ne crée jamais les membres d'une équipe** — crée uniquement le tout premier compte (l'`OWNER`) d'un client provenant d'une vente, qui invite ensuite lui-même son équipe |
| Exemple d'action | Inviter un collègue, changer son rôle | Provisionner un nouveau client Enterprise, dépanner un compte, suspendre un abus |

---

## Table des matières

1. [Contexte & état des lieux](#1-contexte--état-des-lieux)
2. [Le modèle chez les géants du marché](#2-le-modèle-chez-les-géants-du-marché)
3. [Décisions d'architecture](#3-décisions-darchitecture)
4. [Modèle de données](#4-modèle-de-données)
5. [Backend — services & contrôleurs](#5-backend--services--contrôleurs)
6. [Sécurité — le rôle le plus puissant du système](#6-sécurité--le-rôle-le-plus-puissant-du-système)
7. [Console frontend](#7-console-frontend)
8. [Ce qui fait la différence "niveau géants"](#8-ce-qui-fait-la-différence-niveau-géants)
9. [Phasage](#9-phasage)
10. [Stratégie de tests](#10-stratégie-de-tests)
11. [Variables d'environnement](#11-variables-denvironnement)
12. [Checklist mise en production](#12-checklist-mise-en-production)

---

## 1. Contexte & état des lieux

### Ce qui existe déjà

| Composant | Fichier | Statut |
|-----------|---------|--------|
| Rôle plateforme | `user/entity/Role.java` (`USER`/`ADMIN`) | ✅ Existe, protège déjà `/api/v1/admin/**` dans `SecurityConfig` |
| Contrôleurs admin (ops) | `infra/backup/BackupAdminController.java` (`/api/v1/admin/backups/**`), `infra/flyway/FlywayAdminController.java` (`/api/v1/admin/flyway/**`) | ✅ Pattern déjà établi — API pure, sans UI dédiée |
| Journalisation d'événements | `user/entity/{AuthEvent,AuthEventType}.java`, `user/service/AuthEventService.java` | ✅ Pattern de référence : écriture **async** (`@Async("processingExecutor")`), échec de log qui n'impacte jamais le flux principal — à répliquer pour l'audit super-admin (§4), sans réutiliser directement cette table (sémantique différente : événements d'auth d'un utilisateur ≠ actions d'un admin sur un tiers) |
| 2FA | `user/service/TwoFactorService.java`, `user/entity/TwoFactorAuth.java` | ✅ Existe déjà pour les comptes utilisateurs — **à rendre obligatoire** pour tout compte `Role.ADMIN` (voir §6, ajout non demandé explicitement mais indispensable vu le pouvoir de ce rôle) |
| Révocation de session | `user/service/{RefreshTokenService,TokenBlacklistService}.java` | ✅ Révocation par utilisateur déjà en place — réutilisable telle quelle pour une suspension de compte déclenchée depuis la console (§5) |
| Notion d'organisation | — | ❌ Prérequis de `TEAM_ADMIN_ROADMAP.md`, Phase 0-1 |
| Provisionnement manuel de client | — | ❌ Aujourd'hui : CTA "Nous contacter" (mailto) → création manuelle en base par un développeur |
| Console UI (toute confondue) | — | ❌ Aucune — tout ce qui existe en §1 est de l'API brute |
| Journal d'audit des actions admin | — | ❌ Aucun |
| Usurpation d'identité pour le support | — | ❌ Aucune |

### Pourquoi maintenant

La page pricing (`pricing.component.ts`) affiche déjà "Sur devis" + CTA "Nous contacter" pour
Équipe et Enterprise — le parcours *vente assistée* est donc déjà le modèle produit assumé,
seul l'outillage manque. Construire cette console, c'est fermer une boucle déjà ouverte, pas
ajouter un nouveau choix produit.

---

## 2. Le modèle chez les géants du marché

| Capacité | Salesforce | GitHub | Stripe (interne) | AWS |
|----------|:---:|:---:|:---:|:---:|
| Rôle plateforme distinct du rôle client | ✅ | ✅ (`Site Admin` ≠ `Org Owner`) | ✅ | ✅ |
| Provisionnement manuel des comptes Enterprise | ✅ | ✅ | ✅ | ✅ |
| Usurpation d'identité pour le support | ✅ | ✅ (loggée) | ✅ (loggée) | ✅ (très encadrée) |
| **Consentement client requis pour l'usurpation** | ✅ ("Login Access Policies") | ❌ | Partiel | N/A |
| Audit exhaustif de toute action admin | ✅ | ✅ | ✅ | ✅ (obligatoire, souvent horodaté à la seconde) |
| Séparation Support (lecture) / Admin (action) | ✅ | ✅ | ✅ | ✅ |
| 2FA obligatoire pour le rôle plateforme | ✅ | ✅ | ✅ | ✅ (souvent MFA matériel) |
| Accès temporaire/expirant ("break-glass") | Partiel | Partiel | ✅ | ✅ (référence du secteur) |

**Constat** : aucun de ces acteurs ne traite le rôle plateforme comme "un compte utilisateur avec
juste un flag en plus". C'est un système d'accès à part entière, avec son propre niveau de
friction (2FA obligatoire, audit systématique, parfois consentement du client concerné). C'est
le niveau que ce document vise — voir §6 et §8 pour le traduire en décisions concrètes.

---

## 3. Décisions d'architecture

### 3.1 — Granularité du rôle plateforme

`Role.ADMIN` existant est binaire (staff ou pas). Ce n'est pas suffisant : un chargé de support
qui doit pouvoir *voir* un compte client pour l'aider n'a pas besoin de pouvoir *suspendre un
abonnement* ou *supprimer une organisation*. Confondre les deux, c'est donner à toute personne
qui répond aux tickets un pouvoir bien supérieur à son besoin réel — exactement l'anti-pattern
que Salesforce/Stripe évitent (§2).

| Option | Détail |
|--------|--------|
| Garder `Role.ADMIN` unique, tout ou rien | Simple, mais viole le principe du moindre privilège dès qu'il y a plus d'une personne côté staff |
| **Étendre `Role` avec `PLATFORM_SUPPORT` (lecture + usurpation encadrée) et `PLATFORM_ADMIN` (tout SUPPORT + actions destructives/facturation)** ✅ | Reprend exactement la distinction Stripe/GitHub, cohérent avec le pattern déjà posé pour `OrganizationRole` dans `TEAM_ADMIN_ROADMAP.md` (`MEMBER` < `ADMIN` < `OWNER`) |

**Décision : deux rôles plateforme, hiérarchiques.** `ADMIN` existant devient `PLATFORM_ADMIN`
(migration de valeur d'enum) ; `PLATFORM_SUPPORT` est ajouté en dessous. `/api/v1/admin/backups/**`
et `/api/v1/admin/flyway/**` (déjà en place) restent réservés à `PLATFORM_ADMIN` — ce sont des
actions d'infrastructure, jamais du ressort du support.

### 3.2 — Provisionnement d'un nouveau client

Décidé dans l'échange précédent : **ne pas** créer le compte du premier admin client avec un mot
de passe défini par le super-admin (régression de sécurité — un membre du staff Kovixel ne doit
jamais connaître ni fixer le mot de passe d'un client). Le formulaire de provisionnement
déclenche exactement le même mécanisme que le self-service :
`OrganizationService.create(...)` + `inviteMember(role=OWNER)` (§5 de `TEAM_ADMIN_ROADMAP.md`),
avec le token d'invitation envoyé par email au contact désigné. Le super-admin ne fait que
**déclencher** le flux existant, jamais le court-circuiter.

### 3.3 — Usurpation d'identité (impersonation)

C'est la fonctionnalité la plus sensible de toute cette roadmap — celle qui, mal implémentée,
rouvrirait exactement la classe de faille corrigée lors du correctif IDOR de ce projet (accès à
une ressource sans contrôle de propriété légitime).

| Option | Détail |
|--------|--------|
| Émettre un JWT normal "au nom de" l'utilisateur ciblé | ❌ À exclure — indistinguable d'une vraie session de l'utilisateur, aucune trace dans les tokens eux-mêmes, aucun garde-fou possible en aval |
| **Jeton d'impersonation dédié**, claims `actingAsUserId` + `impersonatedByAdminId` + `expiresAt` court (15 min), distinct des JWT normaux | ✅ Le backend peut distinguer une requête "impersonée" d'une requête normale à tout moment, et refuser certaines actions en mode impersoné (voir §6) |

**Décision : jeton dédié, court, marqué.** `JwtService` (déjà en place) gagne une méthode
`generateImpersonationToken(User target, Long adminId)` qui embarque ces claims. `JwtAuthFilter`
reconnaît ce type de jeton et construit un `KovixelUserDetails` avec un flag `impersonated =
true`, propagé jusqu'à `CurrentOwnerResolver` pour que toute la chaîne de contrôle d'accès déjà
en place (`OwnerContext`, `JobAccessGuard`, `OrgAccessGuard`) continue de fonctionner sans
modification — l'usurpation se comporte comme l'utilisateur ciblé pour la lecture, mais reste
identifiable comme telle pour l'audit et les restrictions (§6).

---

## 4. Modèle de données

Prochaine migration disponible après `SSO_SAML_ROADMAP.md` (V59) : **V60**.

### V60 — extension du rôle plateforme

```sql
-- Role.ADMIN existant devient PLATFORM_ADMIN ; nouveau PLATFORM_SUPPORT en dessous.
UPDATE kovixel_users SET role = 'PLATFORM_ADMIN' WHERE role = 'ADMIN';
-- (l'enum Java est mis à jour en parallèle : USER, PLATFORM_SUPPORT, PLATFORM_ADMIN)
```

### V61 — `platform_admin_audit_log` (append-only)

Même esprit que `organization_audit_log` (`TEAM_ADMIN_ROADMAP.md` V56), mais scope
plateforme — jamais fusionné avec `auth_events` (sémantique différente : ici c'est **un membre
du staff qui agit sur un tiers**, pas un utilisateur qui agit sur son propre compte).

```sql
CREATE TABLE platform_admin_audit_log (
    id              BIGSERIAL    PRIMARY KEY,
    admin_user_id   BIGINT       NOT NULL REFERENCES kovixel_users(id),
    action          VARCHAR(50)  NOT NULL,  -- ORG_PROVISIONED, IMPERSONATION_STARTED,
                                             -- IMPERSONATION_ENDED, SUBSCRIPTION_OVERRIDDEN,
                                             -- ORG_SUSPENDED, USER_SESSION_REVOKED, ...
    target_org_id   BIGINT       REFERENCES organizations(id),
    target_user_id  BIGINT       REFERENCES kovixel_users(id),
    ip_address      VARCHAR(45),
    metadata        JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_platform_audit_admin  ON platform_admin_audit_log (admin_user_id, created_at DESC);
CREATE INDEX idx_platform_audit_target ON platform_admin_audit_log (target_org_id, created_at DESC);
```

Aucun `UPDATE`/`DELETE` applicatif — append-only, comme `organization_audit_log`.

### V62 — `impersonation_sessions`

Nécessaire pour limiter la durée de vie réelle d'une usurpation même si le JWT court-circuite
son expiration (ex. compromission du poste de l'admin), et pour l'écran "sessions
d'usurpation actives" côté console.

```sql
CREATE TABLE impersonation_sessions (
    id              BIGSERIAL    PRIMARY KEY,
    public_id       UUID         NOT NULL DEFAULT gen_random_uuid(),
    admin_user_id   BIGINT       NOT NULL REFERENCES kovixel_users(id),
    target_user_id  BIGINT       NOT NULL REFERENCES kovixel_users(id),
    reason          TEXT         NOT NULL,   -- justification obligatoire, saisie par l'admin
    started_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ  NOT NULL,
    ended_at        TIMESTAMPTZ,
    revoked_by      BIGINT       REFERENCES kovixel_users(id)  -- révocation anticipée possible
);
CREATE INDEX idx_impersonation_active ON impersonation_sessions (target_user_id) WHERE ended_at IS NULL;
```

`JwtAuthFilter` vérifie, à chaque requête avec un jeton d'impersonation, que la session
correspondante existe toujours et n'est ni expirée ni révoquée — pas seulement la validité
cryptographique du JWT (défense en profondeur, même logique que la vérification du
`revocation timestamp` déjà faite pour les JWT normaux via `TokenBlacklistService`).

### V63 — `organization_provisioning_requests` (traçabilité commerciale)

Ajout d'expert non demandé explicitement mais qui comble un manque réel : sans ça, un CTA "Nous
contacter" qui arrive par email n'a aucune trace côté produit tant qu'il n'est pas provisionné —
impossible de mesurer le taux de conversion "demande → client actif".

```sql
CREATE TABLE organization_provisioning_requests (
    id              BIGSERIAL    PRIMARY KEY,
    contact_email   VARCHAR(320) NOT NULL,
    company_name    VARCHAR(200),
    requested_plan  VARCHAR(20)  NOT NULL,  -- TEAM | ENTERPRISE
    source          VARCHAR(50),             -- pricing_page, sales_call, ...
    status          VARCHAR(20)  NOT NULL DEFAULT 'PENDING',  -- PENDING | PROVISIONED | DECLINED
    organization_id BIGINT       REFERENCES organizations(id),  -- rempli une fois provisionné
    handled_by      BIGINT       REFERENCES kovixel_users(id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    handled_at      TIMESTAMPTZ
);
```

---

## 5. Backend — services & contrôleurs

Package proposé : `com.kovixel.platformadmin` (même famille que `infra.backup`/`infra.flyway`,
tous déjà sous l'égide de `/api/v1/admin/**`).

### 5.1 — Endpoints

```
GET    /api/v1/admin/organizations                      → liste paginée, filtrable par plan/statut
GET    /api/v1/admin/organizations/{orgId}               → détail (membres, abonnement, usage)
POST   /api/v1/admin/organizations/provision              → déclenche OrganizationService.create()
                                                              + inviteMember(OWNER) — jamais de
                                                              création directe de compte avec mdp
POST   /api/v1/admin/organizations/{orgId}/suspend        → suspend (accès coupé, données conservées)
POST   /api/v1/admin/organizations/{orgId}/subscription/override
                                                            → ajuste un abonnement (essai prolongé,
                                                              siège offert) — toujours audité (§4)
GET    /api/v1/admin/users                                 → recherche globale (email, id) — PLATFORM_SUPPORT+
POST   /api/v1/admin/users/{userId}/impersonate            → ouvre une impersonation_sessions,
                                                              retourne le jeton dédié (§3.3)
DELETE /api/v1/admin/impersonation-sessions/{sessionId}    → révocation anticipée
POST   /api/v1/admin/users/{userId}/revoke-sessions        → réutilise RefreshTokenService/
                                                              TokenBlacklistService existants
GET    /api/v1/admin/audit-log                              → journal plateforme, paginé, filtrable
GET    /api/v1/admin/metrics/overview                       → MRR, orgs actives, usage agrégé
```

`{orgId}`/`{userId}` : identifiants opaques (`public_id`), jamais la PK séquentielle — même
règle non négociable qu'ailleurs dans le projet depuis le correctif IDOR.

### 5.2 — `PlatformAdminAuditService`

Réplique le pattern `AuthEventService` (§1) : écriture asynchrone
(`@Async("processingExecutor")`), échec de journalisation qui **ne bloque jamais** l'action
elle-même (mais qui alerte — voir §6, un audit qui échoue silencieusement sur ce périmètre est
lui-même un signal à surveiller, contrairement aux événements d'auth grand public).

---

## 6. Sécurité — le rôle le plus puissant du système

C'est le rôle qui, s'il est compromis, donne accès à *toutes* les organisations — la barre de
rigueur doit être strictement supérieure à tout ce qui existe ailleurs dans Kovixel.

1. **2FA obligatoire, sans exception, pour `PLATFORM_SUPPORT` et `PLATFORM_ADMIN`.** Réutilise
   `TwoFactorService` déjà en place — ajout d'un check au login : `role != USER &&
   !twoFactorEnabled` → connexion refusée avec message explicite, pas de contournement possible.
   (Ajout d'expert : rien dans l'échange ne le demandait explicitement, mais laisser un compte au
   pouvoir plateforme protégé par un simple mot de passe serait la faille la plus critique de
   toute cette roadmap.)
2. **Un `PLATFORM_ADMIN`/`PLATFORM_SUPPORT` ne peut jamais usurper un autre compte
   `PLATFORM_SUPPORT`/`PLATFORM_ADMIN`.** Empêche l'escalade interne et l'espionnage entre
   membres du staff — vérification explicite dans `impersonate()` avant même de vérifier le rôle
   cible.
3. **Justification obligatoire à l'ouverture d'une impersonation** (`reason`, V62) — pas de
   texte libre optionnel, un champ requis, visible dans l'audit. Aligné avec la discipline déjà
   appliquée dans ce projet (ex. `ValidationAuditLogger`, `AuthEventService`) où chaque
   événement sensible porte un contexte exploitable.
4. **Restrictions en mode impersoné** — même en tant qu'"utilisateur cible", un jeton
   d'impersonation ne doit **jamais** pouvoir : changer le mot de passe, activer/désactiver la
   2FA, modifier l'email, supprimer le compte, initier un paiement. `JwtAuthFilter`/un
   `ImpersonationGuard` dédié bloque ces routes spécifiquement quand `impersonated = true` —
   liste blanche stricte de ce qui reste autorisé (consultation, reproduction d'un bug), pas
   liste noire (plus sûr par construction : tout est interdit sauf ce qui est explicitement
   permis).
5. **`OrgAccessGuard`/`JobAccessGuard` existants ne changent pas** — l'impersonation passe par le
   même `CurrentOwnerResolver`, donc par les mêmes guards déjà durcis lors du correctif IDOR.
   Aucun chemin de contournement parallèle à créer.
6. **Rate limiting et alerting sur les actions sensibles** — un volume anormal d'impersonations
   ou de suspensions déclenchées par un même compte admin sur une courte période doit alerter
   (réutilise l'esprit d'`AuthRateLimitFilter` déjà en place pour le login).
7. **Tous les ids exposés sont opaques** (`public_id`), sans exception — même règle que partout
   ailleurs depuis l'audit IDOR.
8. **Liste blanche d'emails plateforme, indépendante de la base** (`PLATFORM_ADMIN_ALLOWED_EMAILS`,
   `AuthService.isPlatformEmailAllowed`). Constat : le rôle et le flag 2FA (point 1) vivent tous
   deux dans `kovixel_users` — un attaquant avec un accès en écriture direct sur la base (hors
   applicatif) peut faire `UPDATE ... SET role='PLATFORM_ADMIN', two_factor_enabled=true` et
   contourner intégralement les deux protections ci-dessus, puisqu'elles vivent dans la ressource
   qu'il contrôle déjà. La liste blanche est volontairement stockée **hors base**, dans la config
   de déploiement (variable d'env) : compromettre la DB ne suffit plus, il faut *aussi* compromettre
   les secrets de déploiement pour obtenir un accès effectif. CSV d'emails, vérifié au login juste
   après le check 2FA (même placement, même raisonnement anti-énumération). Vide = désactivée
   (opt-in — ne change rien pour qui ne la configure pas) ; n'affecte jamais `Role.USER`.

---

## 7. Console frontend

Nouveau module Angular `features/platform-admin/`, accessible uniquement aux comptes
`PLATFORM_SUPPORT`/`PLATFORM_ADMIN` (guard de route + vérification serveur systématique, jamais
la première seule comme garantie).

| Route | Composant | Accès minimum |
|-------|-----------|----------------|
| `/platform-admin/organizations` | `PlatformOrgListComponent` | `PLATFORM_SUPPORT` |
| `/platform-admin/organizations/provision` | `ProvisionOrgFormComponent` | `PLATFORM_ADMIN` |
| `/platform-admin/organizations/:id` | `PlatformOrgDetailComponent` | `PLATFORM_SUPPORT` |
| `/platform-admin/users` | `PlatformUserSearchComponent` | `PLATFORM_SUPPORT` |
| `/platform-admin/audit-log` | `PlatformAuditLogComponent` | `PLATFORM_ADMIN` |
| `/platform-admin/metrics` | `PlatformMetricsComponent` | `PLATFORM_SUPPORT` |

**Bannière d'impersonation** : dès qu'un jeton d'impersonation est actif, un bandeau fixe,
non-fermable, de couleur distincte ("Vous consultez le compte de {email} — Fin dans {mm:ss} —
Quitter") reste visible sur toute l'application, y compris en dehors de la console admin
elle-même (le staff navigue dans le produit "comme" le client). C'est la mesure UX qui évite le
piège classique : un admin qui oublie qu'il est en mode impersoné et agit par réflexe sur son
propre compte pendant qu'il croit encore être "lui-même".

---

## 8. Ce qui fait la différence "niveau géants"

1. **Consentement client à l'impersonation** (modèle Salesforce "Login Access Policies") — en V1
   la justification obligatoire (§6.3) suffit, mais en V2, laisser un `OWNER` d'organisation
   activer/désactiver dans sa propre console (`TEAM_ADMIN_ROADMAP.md`) si le support Kovixel est
   autorisé à se connecter en son nom, avec une durée maximale qu'il définit lui-même. Peu
   d'éditeurs à la taille de Kovixel le proposent — un vrai différenciateur de confiance B2B.
2. **Fenêtre d'impersonation courte et auto-expirante** (15 min, §3.3) — déjà au niveau AWS/Stripe,
   au-dessus de la moyenne du marché où 24h non révoquées sont encore fréquentes.
3. **Séparation Support/Admin dès le premier jour** (§3.1) — beaucoup de startups ne
   l'introduisent qu'après un incident ; ici c'est posé dans le modèle de données dès la
   conception.
4. **Journal d'audit non désactivable et jamais mélangé aux données produit** — table dédiée
   (`platform_admin_audit_log`), jamais un simple champ `notes` quelque part.
5. **Traçabilité commerciale intégrée** (§4, V63) — la plupart des outils internes séparent
   totalement CRM et provisioning technique ; les relier ici évite la ressaisie et donne une
   vraie mesure du taux de conversion "Nous contacter" → client actif.

---

## 9. Phasage

| Phase | Livrable | Dépend de |
|-------|----------|-----------|
| **0** | Migrations V60-V63, extension `Role` (`PLATFORM_SUPPORT`/`PLATFORM_ADMIN`), 2FA obligatoire | `TEAM_ADMIN_ROADMAP.md` Phase 1 |
| **1** | Provisionnement de client (formulaire → `OrganizationService`), liste/détail organisations | Phase 0 |
| **2** | Journal d'audit plateforme, recherche utilisateur globale, révocation de session | Phase 1 |
| **3** | Usurpation d'identité (jeton dédié, bannière, restrictions, `impersonation_sessions`) | Phase 2 |
| **4** | Facturation manuelle (override d'abonnement, suspension), métriques d'exploitation | Phase 3 |
| **5** | Consentement client à l'impersonation (§8.1), alerting sur usage anormal | Phase 4 |

---

## 10. Stratégie de tests

- **`PlatformAccessGuardTest`** : un `PLATFORM_SUPPORT` ne peut jamais atteindre les endpoints
  réservés `PLATFORM_ADMIN` (suspension, provisioning) — même famille que `JobAccessGuardTest`/
  `OrgAccessGuardTest`.
- **Impersonation** : un jeton d'impersonation expiré/révoqué est rejeté même s'il est
  cryptographiquement valide (vérification de `impersonation_sessions.ended_at`) ; les routes de
  la liste blanche §6.4 sont bloquées en mode impersoné (changement de mot de passe, suppression
  de compte...) ; un `PLATFORM_ADMIN` ne peut pas usurper un autre compte à pouvoir plateforme.
- **Audit** : chaque action de `PlatformAdminAuditService` produit bien une ligne, y compris pour
  les tentatives refusées (un `PLATFORM_SUPPORT` qui tente une action `PLATFORM_ADMIN` doit être
  tracé, pas seulement rejeté silencieusement).
- **2FA** : un compte `PLATFORM_SUPPORT`/`PLATFORM_ADMIN` sans 2FA activée ne peut pas se
  connecter, quel que soit le mot de passe.

---

## 11. Variables d'environnement

| Variable | Description |
|----------|--------------|
| `IMPERSONATION_TOKEN_TTL_MINUTES` | Durée de vie du jeton d'usurpation (défaut recommandé : 15) |
| `PLATFORM_ADMIN_AUDIT_ALERT_WEBHOOK` | Webhook (Slack/email) notifié en cas d'échec de journalisation d'une action sensible |

---

## 12. Checklist mise en production

### Sécurité
- [ ] 2FA vérifiée comme réellement bloquante pour tout compte `PLATFORM_SUPPORT`/`PLATFORM_ADMIN`
      (test manuel : désactiver la 2FA d'un compte de test, confirmer le refus de connexion)
- [ ] Impersonation testée de bout en bout : bannière visible, restrictions actives, expiration
      effective y compris sur un jeton copié manuellement après la fin de session
- [ ] Un compte `PLATFORM_ADMIN` ne peut pas usurper un autre compte à pouvoir plateforme (test
      négatif explicite, pas juste un oubli de cas)
- [ ] Journal d'audit vérifié non désactivable depuis aucune configuration ni feature flag

### Backend
- [ ] Tous les endpoints `/api/v1/admin/**` listés en §5.1 utilisent des `public_id`, jamais de
      PK séquentielle
- [ ] `PlatformAdminAuditService` testé en situation de panne (DB indisponible) — l'action
      principale continue, l'alerte se déclenche

### Produit
- [ ] Formulaire de provisionnement reproduit exactement le parcours self-service (aucun champ
      "mot de passe" quelque part dans ce flux)
- [ ] Décision tranchée : suspension d'organisation = coupure d'accès immédiate ou délai de
      grâce (cohérence à vérifier avec `GracePeriodScheduler` déjà existant pour les impayés)

---

*Feuille de route créée le 2026-07-12 — Version 1.0*
