# Kovixel — Feuille de route Console d'administration, Rôles & Facturation par siège

> Objectif : donner à Kovixel un modèle multi-utilisateurs de niveau production — organisations,
> rôles, invitations, facturation par siège Stripe et console d'administration — sans jamais
> rouvrir les failles de contrôle d'accès déjà corrigées sur le modèle individuel (cf. audit
> sécurité 2026-07-11/12, correctifs IDOR sur `ProcessingJob`/`Document`). Ce document est le
> prérequis de `SSO_SAML_ROADMAP.md`, qui s'appuie sur la notion d'organisation définie ici.

---

## Table des matières

1. [Contexte & état des lieux](#1-contexte--état-des-lieux)
2. [Ce que font les géants du marché](#2-ce-que-font-les-géants-du-marché)
3. [Décisions d'architecture](#3-décisions-darchitecture)
4. [Modèle de données](#4-modèle-de-données)
5. [Backend — services & contrôleurs](#5-backend--services--contrôleurs)
6. [Sécurité — ne pas rouvrir l'IDOR](#6-sécurité--ne-pas-rouvrir-lidor)
7. [Facturation par siège (Stripe)](#7-facturation-par-siège-stripe)
8. [Console d'administration (frontend)](#8-console-dadministration-frontend)
9. [Ce qui fait la différence "niveau géants"](#9-ce-qui-fait-la-différence-niveau-géants)
10. [Phasage](#10-phasage)
11. [Stratégie de tests](#11-stratégie-de-tests)
12. [Variables d'environnement](#12-variables-denvironnement)
13. [Checklist mise en production](#13-checklist-mise-en-production)

---

## 1. Contexte & état des lieux

### Ce qui existe déjà

| Composant | Fichier | Statut |
|-----------|---------|--------|
| Plans utilisateur | `user/entity/UserPlan.java` | ✅ `TEAM`/`ENTERPRISE` définis, jamais peuplés par une logique d'équipe |
| Rôle système | `user/entity/Role.java` | ⚠️ `USER`/`ADMIN` — un rôle **global** (staff Kovixel), pas un rôle d'organisation. `ADMIN` est amené à devenir `PLATFORM_ADMIN` (+ nouveau `PLATFORM_SUPPORT`) une fois `SUPER_ADMIN_ROADMAP.md` implémenté — ne pas s'étonner si ce nom a changé au moment de lire cette section |
| Abonnement | `subscription/entity/Subscription.java` | ⚠️ **1 abonnement = 1 `userId`** — aucune notion d'entité collective |
| Paiement récurrent | `payment/service/StripeService.java` + webhooks | ✅ Checkout, portail, webhooks idempotents déjà en place (voir `PAYMENT_ROADMAP.md`) |
| Contrôle d'accès individuel | `common/security/{OwnerContext,CurrentOwnerResolver,JobAccessGuard}.java` | ✅ Pattern solide, à **étendre**, pas à contourner (voir §6) |
| Tokens à usage unique signés | `user/service/EmailVerificationService.java` | ✅ Pattern de référence pour les invitations (hash stocké, jamais le token brut) |
| Console d'administration d'organisation | — | ❌ Aucun code |
| Notion d'organisation/équipe | — | ❌ Aucune entité |
| Facturation par siège | — | ❌ `Subscription` ne gère qu'une quantité de 1 |

### Ce qu'il reste à construire

- Une entité `Organization` de premier niveau, avec adhésion multi-utilisateurs
- Des rôles **scopés à l'organisation** (distincts du `Role` système existant)
- Un flux d'invitation sécurisé (token signé, expirant, email)
- Une facturation Stripe pilotée par le nombre de sièges actifs
- Une console d'administration (membres, rôles, facturation, journal d'audit)

---

## 2. Ce que font les géants du marché

| Capacité | Google Workspace | Microsoft 365 | Slack | Notion | Linear | GitHub Orgs |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| Rôles multiples (pas juste admin/membre) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Facturation par siège, proratisée | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Invitation par email, expirante | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Journal d'audit des actions admin | ✅ | ✅ | ✅ (payant) | ✅ | ✅ | ✅ |
| Vérification de domaine (auto-jonction) | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Transfert de propriété | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Politique de session forcée (déconnexion globale) | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| SCIM (provisioning automatique) | ✅ | ✅ | ✅ (Enterprise) | ✅ (Enterprise) | ❌ | ✅ (Enterprise) |

**Constat** : le socle non négociable est *rôles + sièges + invitations + audit*. Le reste
(vérification de domaine, SCIM, politique de session) relève du tiers "Enterprise" et peut être
phasé plus tard — voir §9 et le lien avec `SSO_SAML_ROADMAP.md`.

---

## 3. Décisions d'architecture

### 3.1 — Organisation comme entité de premier niveau

**Comparatif :**

| Approche | Avantage | Inconvénient |
|----------|----------|---------------|
| Étendre `User` avec un `teamId` | Simple, peu de migration | Un utilisateur ne peut appartenir qu'à **une seule** équipe ; casse dès qu'un consultant rejoint 2 clients |
| **Nouvelle entité `Organization` + table de jonction `organization_members`** ✅ | Modèle standard (many-to-many), extensible aux rôles, scalable | Plus de migrations, plus de code au départ |

**Décision : `Organization` + `organization_members`.** C'est le modèle utilisé par tous les
acteurs cités en §2, et le seul qui n'impose pas de refonte le jour où un utilisateur doit
appartenir à plusieurs organisations.

### 3.2 — Propriété des ressources (jobs, documents)

Le correctif IDOR déjà livré introduit `OwnerContext(userId, guestSessionId)` et
`CurrentOwnerResolver`, consommés par `JobAccessGuard`/`DocumentServiceImpl`. Deux options pour
que les ressources deviennent partageables au niveau équipe :

| Option | Détail |
|--------|--------|
| A. `OwnerContext` reste binaire (user OU invité), le partage passe par une table `resource_shares` séparée | Isole le changement, mais duplique la logique de contrôle d'accès dans une 2ᵉ classe |
| **B. Étendre `OwnerContext` avec un `orgId` optionnel, et `owns()` vérifie aussi l'appartenance à l'org propriétaire** ✅ | Un seul point de vérité pour "qui peut accéder à quoi" — cohérent avec le principe déjà posé en phase IDOR |

**Décision : option B.** `OwnerContext` devient `record OwnerContext(Long userId, String
guestSessionId, Long orgId)`. `ProcessingJob`/`Document` gagnent une colonne `organization_id`
nullable (un job reste possédé par un individu **ou** par une organisation, jamais les deux à la
fois — même logique d'exclusivité que `userId`/`guestSessionId` aujourd'hui).
`CurrentOwnerResolver` résout l'org active de la requête (header `X-Organization-Id` validé
contre l'appartenance réelle du user, jamais fait confiance en aveugle).

### 3.3 — Rôles

| Rôle | Peut | Ne peut pas |
|------|------|-------------|
| `OWNER` | Tout ADMIN + supprimer l'organisation, transférer la propriété, résilier l'abonnement | — |
| `ADMIN` | Inviter/retirer des membres, changer les rôles (sauf OWNER), voir la facturation | Supprimer l'org, transférer la propriété |
| `BILLING` | Voir/gérer la facturation uniquement (portail Stripe) | Inviter, gérer les membres, utiliser les outils au nom de l'org |
| `MEMBER` | Utiliser les outils Kovixel dans le contexte de l'org | Toute action d'administration |

Ce `OrganizationRole` est **indépendant** du `Role` système (staff Kovixel, ex. pour
`/api/v1/admin/**` — voir `SUPER_ADMIN_ROADMAP.md` §3.1 pour sa granularité exacte, amenée à
évoluer indépendamment de ce document). Ne pas les confondre ni les fusionner : l'un décrit "que
peut faire ce membre dans son organisation", l'autre "que peut faire ce compte sur la
plateforme entière".

### 3.4 — Facturation

Voir §7. Décision : **une `Subscription` par organisation**, `quantity` Stripe = nombre de
membres actifs (invitations en attente **non facturées** tant qu'elles ne sont pas acceptées).

---

## 4. Modèle de données

Prochaine migration disponible : **V53** (dernière migration du dépôt : V52, correctif IDOR).

> **Numérotation indicative.** V53-V58 sont correctes pour une implémentation démarrant
> immédiatement. Les numéros cités dans `SSO_SAML_ROADMAP.md` (V59) et
> `SUPER_ADMIN_ROADMAP.md` (V60-V64, dont `organization_join_requests` ci-dessous) supposent un
> ordre de rédaction (Team → SSO → Super-Admin) qui **n'est pas** l'ordre d'implémentation
> recommandé (Team → Super-Admin → reste de Team → SSO en dernier, sur demande — voir l'échange
> "dans quel ordre les implémenter"). En pratique, les migrations de `SUPER_ADMIN_ROADMAP.md`
> seront très probablement appliquées avant celles de SSO. Prendre le prochain numéro Flyway
> disponible au moment de l'implémentation réelle, pas celui écrit ici.

### V53 — `organizations`

```sql
CREATE TABLE organizations (
    id            BIGSERIAL       PRIMARY KEY,
    -- Identifiant opaque exposé par l'API — jamais le BIGSERIAL séquentiel (cf. audit IDOR V2).
    public_id     UUID            NOT NULL DEFAULT gen_random_uuid(),
    name          VARCHAR(200)    NOT NULL,
    slug          VARCHAR(100)    NOT NULL UNIQUE,
    owner_id      BIGINT          NOT NULL REFERENCES kovixel_users(id),
    plan          VARCHAR(20)     NOT NULL DEFAULT 'TEAM',  -- TEAM | ENTERPRISE
    created_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_organizations_public_id ON organizations (public_id);
CREATE UNIQUE INDEX idx_organizations_slug      ON organizations (slug);
```

### V54 — `organization_members`

```sql
CREATE TABLE organization_members (
    id              BIGSERIAL    PRIMARY KEY,
    organization_id BIGINT       NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id         BIGINT       NOT NULL REFERENCES kovixel_users(id) ON DELETE CASCADE,
    role            VARCHAR(20)  NOT NULL,  -- OWNER | ADMIN | BILLING | MEMBER
    joined_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    invited_by      BIGINT       REFERENCES kovixel_users(id),
    CONSTRAINT uq_org_member UNIQUE (organization_id, user_id)
);
CREATE INDEX idx_org_members_user ON organization_members (user_id);
CREATE INDEX idx_org_members_org  ON organization_members (organization_id);
```

### V55 — `organization_invitations`

Suit le pattern déjà établi par `EmailVerificationService` : **seul le hash SHA-256 du token est
persisté**, jamais le token brut (qui ne transite que dans l'URL de l'email, une seule fois).

```sql
CREATE TABLE organization_invitations (
    id              BIGSERIAL    PRIMARY KEY,
    public_id       UUID         NOT NULL DEFAULT gen_random_uuid(),
    organization_id BIGINT       NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    email           VARCHAR(320) NOT NULL,
    role            VARCHAR(20)  NOT NULL,
    token_hash      VARCHAR(64)  NOT NULL,   -- SHA-256 hex, jamais le token brut
    invited_by      BIGINT       NOT NULL REFERENCES kovixel_users(id),
    expires_at      TIMESTAMPTZ  NOT NULL,
    accepted_at     TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX idx_org_invitations_public_id ON organization_invitations (public_id);
CREATE INDEX idx_org_invitations_email ON organization_invitations (email) WHERE accepted_at IS NULL;
```

### V56 — `organization_audit_log` (append-only)

```sql
CREATE TABLE organization_audit_log (
    id              BIGSERIAL    PRIMARY KEY,
    organization_id BIGINT       NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    actor_user_id   BIGINT       REFERENCES kovixel_users(id),
    action          VARCHAR(50)  NOT NULL,  -- MEMBER_INVITED, MEMBER_REMOVED, ROLE_CHANGED, ...
    target_user_id  BIGINT       REFERENCES kovixel_users(id),
    metadata        JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_org_audit_org_date ON organization_audit_log (organization_id, created_at DESC);
```

Aucun `UPDATE`/`DELETE` applicatif sur cette table — c'est ce qui en fait un vrai journal
d'audit (même garantie que ce qu'exigerait un futur audit SOC 2, voir `ISSUES.md` #48).

### V57 — extension `processing_jobs` / `documents`

```sql
ALTER TABLE processing_jobs ADD COLUMN organization_id BIGINT REFERENCES organizations(id);
ALTER TABLE documents       ADD COLUMN organization_id BIGINT REFERENCES organizations(id);
CREATE INDEX idx_processing_jobs_org ON processing_jobs (organization_id) WHERE organization_id IS NOT NULL;
CREATE INDEX idx_documents_org       ON documents (organization_id) WHERE organization_id IS NOT NULL;
```

### V58 — `organization_subscriptions` (au lieu d'étendre `subscriptions`)

Ne pas surcharger `Subscription` (déjà conçue pour 1 utilisateur, avec des champs Stripe
spécifiques) avec des champs conditionnels. Table dédiée, même forme que `Subscription` :

```sql
CREATE TABLE organization_subscriptions (
    id                     BIGSERIAL   PRIMARY KEY,
    organization_id        BIGINT      NOT NULL UNIQUE REFERENCES organizations(id),
    stripe_customer_id     VARCHAR(255),
    stripe_subscription_id VARCHAR(255),
    stripe_price_id        VARCHAR(255),
    stripe_status          VARCHAR(50),
    seat_count             INTEGER     NOT NULL DEFAULT 0,
    billing_interval       VARCHAR(20),
    current_period_start   TIMESTAMPTZ,
    current_period_end     TIMESTAMPTZ,
    cancel_at_period_end   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ
);
```

---

## 5. Backend — services & contrôleurs

Package proposé : `com.kovixel.organization` (nouveau module, même structure que
`com.kovixel.subscription` : `entity/`, `repository/`, `service/`, `controller/`, `dto/`).

### 5.1 — `OrganizationService`

| Méthode | Description |
|---------|--------------|
| `create(User owner, String name)` | Crée l'org, ajoute le créateur en `OWNER` |
| `inviteMember(orgPublicId, email, role, inviter)` | Vérifie que `inviter` est OWNER/ADMIN, génère un token (`UUID.randomUUID()` × 2 concaténés — même génération que `EmailVerificationService`), stocke le hash, envoie l'email |
| `acceptInvitation(token)` | Résout par hash, vérifie `expires_at`/`revoked_at`/`accepted_at IS NULL`, crée le `User` si inexistant ou lie le compte existant, insère `organization_members` |
| `changeRole(orgPublicId, targetUserId, newRole, actor)` | Interdit de rétrograder le dernier `OWNER` ; interdit à un `ADMIN` de toucher un `OWNER` |
| `removeMember(orgPublicId, targetUserId, actor)` | Décrémente le siège Stripe (voir §7) |
| `transferOwnership(orgPublicId, newOwnerId, currentOwner)` | Exige le mot de passe courant ou une 2FA si activée — action irréversible et sensible |
| `listMembers(orgPublicId, requester)` | Retourne uniquement si `requester` est membre de l'org |
| `requestToJoin(orgPublicId, user)` | Vérifie que le domaine de l'email de `user` correspond à `organization_sso_config.domain` avec `verified_at IS NOT NULL` pour cet org ; crée une `organization_join_requests` en `PENDING` ; notifie les `OWNER`/`ADMIN` |
| `reviewJoinRequest(orgPublicId, requestId, approve, reviewer)` | Réservé `ADMIN`/`OWNER` ; si approuvé, insère `organization_members` (rôle `MEMBER`) de façon atomique avec le passage à `APPROVED` |

Chaque méthode écrit une ligne dans `organization_audit_log` (voir V56) — sans exception,
y compris les échecs de tentative (ex. un ADMIN qui tente de toucher un OWNER doit être tracé,
pas juste rejeté silencieusement).

### 5.2 — Endpoints REST

Tous sous `/api/v1/organizations`, tous authentifiés (aucun n'est `permitAll`) :

```
POST   /api/v1/organizations                                   → create
GET    /api/v1/organizations/{orgId}                           → détail (membre uniquement)
GET    /api/v1/organizations/{orgId}/members                   → liste
POST   /api/v1/organizations/{orgId}/invitations                → invite
GET    /api/v1/organizations/invitations/{token}                → prévisualiser (email/org/rôle, sans authentification)
POST   /api/v1/organizations/invitations/{token}/accept          → accepter
DELETE /api/v1/organizations/{orgId}/invitations/{invitationId} → révoquer une invitation en attente
PATCH  /api/v1/organizations/{orgId}/members/{userId}/role      → changer un rôle
DELETE /api/v1/organizations/{orgId}/members/{userId}           → retirer un membre
POST   /api/v1/organizations/{orgId}/transfer-ownership         → transférer la propriété
GET    /api/v1/organizations/{orgId}/audit-log                  → journal (paginé, OWNER/ADMIN uniquement)
POST   /api/v1/organizations/{orgId}/join-requests                → demander à rejoindre (domaine vérifié requis)
GET    /api/v1/organizations/{orgId}/join-requests                → lister les demandes en attente (ADMIN/OWNER)
POST   /api/v1/organizations/{orgId}/join-requests/{requestId}/approve → approuver (ADMIN/OWNER)
POST   /api/v1/organizations/{orgId}/join-requests/{requestId}/reject  → rejeter (ADMIN/OWNER)
```

`{orgId}` est le **`public_id` (UUID)**, jamais le `BIGSERIAL` — même règle que pour
`ProcessingJob.publicId` établie lors du correctif IDOR. Le token d'invitation dans l'URL
est lui-même opaque (UUID généré côté client à partir du hash), jamais énumérable.

---

## 6. Sécurité — ne pas rouvrir l'IDOR

Le correctif IDOR livré sur `ProcessingJob`/`Document` a une seule vraie leçon : **un guard
centralisé, pas des vérifications éparpillées dans chaque contrôleur.** Ce principe s'applique
ici à l'identique :

- **`OrgAccessGuard`** (même famille que `JobAccessGuard`) : `requireRole(orgPublicId,
  OrganizationRole minRole)` charge l'org, vérifie l'appartenance ET le rang du rôle, lève 404
  (pas 403) si l'appelant n'est pas membre — un attaquant ne doit pas pouvoir distinguer "org
  inexistante" de "org à laquelle je n'appartiens pas" (même raisonnement que pour les jobs).
- **Jamais de confiance dans un header/claim client** pour l'org active — `X-Organization-Id`
  (ou équivalent) est toujours re-vérifié côté serveur contre `organization_members`, exactement
  comme `CurrentOwnerResolver` ne fait jamais confiance à un id de session invité sans validation
  de signature.
- **Tests anti-IDOR dès la Phase 1**, sur le modèle de `JobAccessGuardTest`/
  `DocumentServiceImplTest` : un membre de l'org A ne doit jamais lire/modifier une ressource de
  l'org B, un `MEMBER` ne doit jamais réussir une action réservée à `ADMIN`/`OWNER`.
- **Tokens d'invitation** : hash stocké (jamais le brut), TTL court (7 jours), révocables,
  usage unique (`accepted_at` posé de façon atomique — `UPDATE ... WHERE accepted_at IS NULL`
  pour éviter une double-acceptation en cas de requêtes concurrentes).
- **Dernier `OWNER` protégé** : impossible de le rétrograder ou de le retirer sans transfert de
  propriété préalable — sinon une org peut se retrouver sans administrateur.

---

## 7. Facturation par siège (Stripe)

S'appuie sur `StripeService`/`StripeServiceImpl` déjà en place (voir `PAYMENT_ROADMAP.md` §6-7).

- **Un `price` Stripe unique "par siège"** (`STRIPE_PRICE_TEAM_SEAT_MONTHLY` /
  `..._YEARLY`), souscrit avec `quantity` = nombre de membres **actifs** (invitations en
  attente non comptées).
- **Ajout de membre** (invitation acceptée) → `stripe.subscriptionItems.update(quantity:
  currentQuantity + 1, proration_behavior: 'create_prorations')` — Stripe calcule le prorata
  automatiquement, pas de calcul maison.
- **Retrait de membre** → décrément symétrique. Option produit à trancher : proration
  immédiate (remboursement au prorata) ou "le siège reste dû jusqu'à la fin de la période" (plus
  simple, plus courant en pratique B2B — GitHub/Slack fonctionnent ainsi).
- **Un seul webhook Stripe par org**, pas par membre — réutilise `WebhookDispatcher` existant,
  ajoute un handler pour `customer.subscription.updated` côté `organization_subscriptions`.
- **Facture unique pour l'organisation**, envoyée au titulaire `BILLING`/`OWNER` — pas une
  facture par membre.

---

## 8. Console d'administration (frontend)

Nouveau module Angular `features/organization/`, dans la continuité de la structure existante
(`features/subscription/`, `features/dashboard/`).

| Route | Composant | Accès |
|-------|-----------|-------|
| `/org/:slug/members` | `OrgMembersListComponent` | Tout membre (lecture) |
| `/org/:slug/members` (actions invite/retire/rôle) | idem | ADMIN/OWNER (masqué sinon) |
| `/org/:slug/billing` | `OrgBillingComponent` | BILLING/OWNER |
| `/org/:slug/audit-log` | `OrgAuditLogComponent` | ADMIN/OWNER |
| `/org/invite/:token` | `AcceptInvitationComponent` | Public (page d'atterrissage email) |

**`OrgRoleGuard`** (Angular route guard) : masque l'UI selon le rôle — **jamais une garantie de
sécurité**, seulement du confort d'affichage. Le vrai contrôle est toujours `OrgAccessGuard`
côté backend (§6) ; le guard frontend n'existe que pour ne pas afficher des boutons qui
échoueraient de toute façon.

---

## 9. Ce qui fait la différence "niveau géants"

Au-delà du socle (rôles/sièges/invitations), ce qui distingue une implémentation "startup" d'une
implémentation au niveau des références du marché :

1. **Journal d'audit complet et immuable** (V56) — déjà intégré au modèle de données, pas un
   ajout après-coup.
2. **Demande de jonction par domaine vérifié**, avec **validation obligatoire d'un
   `OWNER`/`ADMIN`** — décision produit tranchée explicitement (pas d'auto-jonction immédiate :
   un compte compromis ou un stagiaire ne doit pas pouvoir rejoindre l'organisation de plein
   droit simplement parce qu'il possède une adresse du domaine). Le champ `domain`/`verified_at`
   n'est **pas** une table séparée : il vit dans `organization_sso_config` (V59, voir
   `SSO_SAML_ROADMAP.md` §4), mutualisé avec le forçage SSO (`enforce_sso`) — un domaine vérifié
   sert aux deux usages, qui restent des mécanismes distincts (voir tableau ci-dessous).

   | | Forçage SSO (`enforce_sso`) | Demande de jonction |
   |---|---|---|
   | Effet d'un domaine vérifié | Bloque la connexion par mot de passe pour ce domaine | Permet à un nouvel inscrit `@domaine` de **demander** à rejoindre l'org |
   | Validation humaine | Aucune (automatique par construction) | **Obligatoire** — un `OWNER`/`ADMIN` doit approuver |
   | Table dédiée | `organization_sso_config` (SSO V59) | `organization_join_requests` (nouvelle, voir §4) |

   Nouvelle migration **V64** (après `SUPER_ADMIN_ROADMAP.md` V60-V63, puisqu'elle dépend de
   `organization_sso_config` défini par SSO) :

   ```sql
   CREATE TABLE organization_join_requests (
       id              BIGSERIAL    PRIMARY KEY,
       public_id       UUID         NOT NULL DEFAULT gen_random_uuid(),
       organization_id BIGINT       NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
       user_id         BIGINT       NOT NULL REFERENCES kovixel_users(id) ON DELETE CASCADE,
       status          VARCHAR(20)  NOT NULL DEFAULT 'PENDING',  -- PENDING | APPROVED | REJECTED | EXPIRED
       reviewed_by     BIGINT       REFERENCES kovixel_users(id),
       created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
       reviewed_at     TIMESTAMPTZ,
       CONSTRAINT uq_join_request UNIQUE (organization_id, user_id)
   );
   CREATE INDEX idx_join_requests_pending ON organization_join_requests (organization_id) WHERE status = 'PENDING';
   ```

   À l'approbation : insertion dans `organization_members` avec le rôle par défaut `MEMBER`
   (même règle que le JIT SSO, `SSO_SAML_ROADMAP.md` §5) + entrée `organization_audit_log`
   (§4). Un `OWNER`/`ADMIN` est notifié (email + badge dans `OrgMembersListComponent`, §8) à
   chaque nouvelle demande en attente.
3. **Politique de session forcée** : un OWNER peut invalider toutes les sessions actives des
   membres (ex. départ d'un employé) — s'appuie sur `TokenBlacklistService`/
   `RefreshTokenService` déjà existants, il suffit d'étendre la révocation par `userId` à une
   révocation par lot (liste des membres de l'org).
4. **Export RGPD** : un OWNER peut exporter la liste des membres + leurs données d'usage —
   complète l'export individuel déjà attendu par le RGPD.
5. **SCIM** : hors périmètre de cette roadmap, dépend du socle SSO — voir
   `SSO_SAML_ROADMAP.md` §5.

---

## 10. Phasage

| Phase | Livrable | Dépend de |
|-------|----------|-----------|
| **0** | Migrations V53-V58, entités JPA, repositories | — |
| **1** | `OrganizationService` (create/invite/accept/list), `OrgAccessGuard`, tests anti-IDOR | Phase 0 |
| **2** | Rôles complets (change/remove/transfer), journal d'audit | Phase 1 |
| **3** | Facturation par siège Stripe (souscription, webhook, prorata) | Phase 2 |
| **4** | Console d'administration frontend (membres, rôles, facturation) | Phase 3 |
| **5** | Durcissement "niveau géants" : vérification de domaine, politique de session, export RGPD | Phase 4 |

Chaque phase doit être livrée avec sa couverture de tests avant de passer à la suivante — ne
pas répéter le pattern observé lors de l'audit V2 (fonctionnalité livrée, contrôle d'accès
oublié).

---

## 11. Stratégie de tests

- **Unitaires** : `OrganizationServiceTest`, `OrgAccessGuardTest` (mêmes scénarios que
  `JobAccessGuardTest` : membre légitime OK, membre d'une autre org rejeté en 404, rôle
  insuffisant rejeté, dernier OWNER protégé).
- **Invitations** : token expiré rejeté, token déjà accepté rejeté (pas de double-acceptation
  même en cas de course), token révoqué rejeté, hash jamais loggé en clair.
- **Facturation** : webhook Stripe simulé (stripe-mock, déjà utilisé pour `PAYMENT_ROADMAP.md`)
  → vérifier que `seat_count` reste synchronisé avec `organization_members` après ajout/retrait
  concurrent de plusieurs membres.
- **Frontend** : `OrgMembersListComponent` masque les actions admin pour un `MEMBER` (vitest +
  Testing Library, même pattern que les specs existantes).
- **Demandes de jonction** : une demande sur un domaine non vérifié est rejetée avant même
  création en base ; un `MEMBER` ne peut pas approuver/rejeter une demande (réservé
  `ADMIN`/`OWNER`) ; double-approbation concurrente ne crée jamais deux `organization_members`
  (même exigence d'atomicité que l'acceptation d'invitation).

---

## 12. Variables d'environnement

| Variable | Description | Exemple |
|----------|-------------|---------|
| `STRIPE_PRICE_TEAM_SEAT_MONTHLY` | Price ID Stripe — siège mensuel | `price_1Pxx...` |
| `STRIPE_PRICE_TEAM_SEAT_YEARLY` | Price ID Stripe — siège annuel | `price_1Pxx...` |
| `ORG_INVITATION_TTL_HOURS` | Durée de vie d'une invitation | `168` (7 jours) |

---

## 13. Checklist mise en production

### Backend
- [ ] Migrations V53-V58 validées sur une copie de la base prod
- [ ] `OrgAccessGuard` appliqué sur **tous** les endpoints `/api/v1/organizations/**` sans
      exception (revue de code dédiée, comme pour le correctif IDOR)
- [ ] Tests anti-IDOR organisationnels verts (équivalent `JobOwnershipIT`)
- [ ] Webhook Stripe organisation testé avec des événements simulés (ajout/retrait concurrent)

### Frontend
- [ ] Guards de rôle testés sur les 4 rôles (`OWNER`/`ADMIN`/`BILLING`/`MEMBER`)
- [ ] Page d'acceptation d'invitation testée avec token expiré/révoqué/déjà utilisé

### Produit
- [ ] Politique tranchée : proration immédiate ou "siège dû jusqu'à fin de période" au retrait
      d'un membre (§7)
- [ ] Page pricing mise à jour pour ne plus décrire ces fonctionnalités comme "à venir" une fois
      livrées (cf. `kovixel-ui/ISSUES.md` #44)

---

*Feuille de route créée le 2026-07-12 — Version 1.0*
