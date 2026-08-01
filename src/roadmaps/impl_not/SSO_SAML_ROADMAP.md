# Kovixel — Feuille de route SSO / SAML Enterprise

> Objectif : permettre à une organisation cliente de connecter son fournisseur d'identité
> (Okta, Azure AD/Entra ID, Google Workspace...) pour que ses employés se connectent à Kovixel
> avec leurs identifiants d'entreprise, sans jamais devenir soi-même un maillon faible côté
> cryptographie SAML. Fonctionnalité **sur demande** (pas self-service), au tarif Enterprise —
> décision produit déjà actée. Dépend de `TEAM_ADMIN_ROADMAP.md` (notion d'organisation).

---

## Table des matières

1. [Contexte & état des lieux](#1-contexte--état-des-lieux)
2. [SAML vs OIDC — quelle techno prioriser](#2-saml-vs-oidc--quelle-techno-prioriser)
3. [Choix de bibliothèque](#3-choix-de-bibliothèque)
4. [Modèle multi-tenant](#4-modèle-multi-tenant)
5. [Provisioning : JIT puis SCIM](#5-provisioning--jit-puis-scim)
6. [Sécurité SAML — non négociable](#6-sécurité-saml--non-négociable)
7. [Application de la politique SSO](#7-application-de-la-politique-sso)
8. [Backend — flux détaillé](#8-backend--flux-détaillé)
9. [Phasage](#9-phasage)
10. [Stratégie de tests](#10-stratégie-de-tests)
11. [Variables d'environnement](#11-variables-denvironnement)
12. [Checklist mise en production](#12-checklist-mise-en-production)

---

## 1. Contexte & état des lieux

### Ce qui existe déjà (et qui sert de socle)

| Composant | Fichier | Réutilisable pour SSO ? |
|-----------|---------|--------------------------|
| Validation OAuth2 (Google/Apple/Microsoft) | `user/service/OAuthTokenValidator.java` | ⚠️ Partiellement — c'est de l'**OIDC**, un protocole différent de SAML, mais la rigueur de validation (issuer, audience, expiration, JWKS distant) est le niveau à reproduire |
| Find-or-create utilisateur par identité externe | `user/service/OAuthService.java` | ✅ Le pattern (résolution par `provider`+`providerId`, puis par email vérifié) est directement transposable |
| Enum des providers | `user/entity/AuthProvider.java` (`LOCAL, GOOGLE, APPLE, MICROSOFT`) | ✅ À étendre avec `SAML` |
| Correctif email non vérifié | `OAuthService.handleOAuthLogin` (refuse la liaison si `emailVerified == false`) | ✅ **Principe directement applicable au SAML** — voir §6 |
| Organisation / appartenance | `TEAM_ADMIN_ROADMAP.md` | ❌ Prérequis, pas encore construit |

**Ce que Kovixel n'a pas** : aucune dépendance SAML dans `pom.xml`, aucun concept de
configuration d'identité **par tenant** (l'OAuth2 actuel utilise un client ID Kovixel unique et
global pour tous les utilisateurs — le SSO Enterprise, lui, exige une configuration différente
par organisation cliente, avec son propre IdP).

---

## 2. SAML vs OIDC — quelle techno prioriser

| Critère | SAML 2.0 | OIDC (OAuth2 + couche identité) |
|---------|----------|-----------------------------------|
| Âge / complexité | Ancien (2005), XML, signatures XML complexes | Moderne (2014), JSON/JWT, plus simple à valider |
| Surface d'attaque | Élevée — XML Signature Wrapping, XXE, parsing XML | Plus faible — JWT signé, bibliothèques matures |
| Support IdP | Universel (tous les IdP Enterprise le supportent) | Universel aussi côté IdP modernes (Okta, Azure AD, Google) |
| Coché sur les grilles d'achat Enterprise | ✅ Quasi systématique ("SAML support" = ligne de checklist procurement) | Parfois listé séparément, parfois considéré équivalent |
| Kovixel a déjà de l'expérience dessus | ❌ | ✅ (`OAuthTokenValidator`, JWKS, nimbus-jose-jwt déjà en dépendance) |

**Décision : OIDC en premier (Phase 1), SAML en complément (Phase 2).**
Beaucoup de demandes "SSO/SAML" sont en réalité satisfaites par une app Enterprise OIDC chez
Okta/Azure AD/Google — techniquement plus simple, plus sûr, et Kovixel a déjà tout l'outillage
(`nimbus-jose-jwt`, validation JWKS). Le SAML reste nécessaire pour les IdP legacy qui l'exigent
explicitement (ADFS, certains Okta/Azure AD configurés en mode SAML uniquement) ou pour cocher
la case procurement — mais ne doit pas bloquer la Phase 1.

---

## 3. Choix de bibliothèque

**Ne jamais réimplémenter la cryptographie SAML soi-même** — les attaques XML Signature
Wrapping (XSW) contre des implémentations SAML maison ou mal auditées sont une classe de faille
connue et récurrente dans l'industrie.

| Option | Avantage | Inconvénient |
|--------|----------|---------------|
| **`spring-security-saml2-service-provider`** ✅ | Maintenu par le projet Spring Security (déjà une dépendance directe de Kovixel via `SecurityConfig`), API `RelyingPartyRegistration` pensée pour le multi-tenant, validation de signature/audience/replay gérée par la bibliothèque | Documentation plus counte que OneLogin, quelques limitations sur le SP-initiated multi-IdP dynamique |
| `com.onelogin:java-saml` | Très utilisé, bien documenté | Bibliothèque tierce indépendante de l'écosystème Spring déjà en place — plus de code de glue |
| Implémentation maison (OpenSAML brut) | Contrôle total | **À exclure** — surface d'attaque cryptographique bien trop risquée pour un gain qui n'en justifie pas le coût |

**Décision : `spring-security-saml2-service-provider`.** Cohérent avec `SecurityConfig` /
`JwtAuthFilter` déjà en place, maintenu par la même organisation que Spring Security dont
Kovixel dépend déjà, et pensé nativement pour enregistrer plusieurs IdP (un par organisation).

---

## 4. Modèle multi-tenant

Chaque organisation cliente configure son propre IdP. Nouvelle table (dépend de
`organizations`, définie dans `TEAM_ADMIN_ROADMAP.md`) :

> **Numérotation indicative** — voir la note dans `TEAM_ADMIN_ROADMAP.md` §4 : SSO est la
> dernière des trois roadmaps à implémenter (sur demande client réelle), donc son numéro de
> migration réel sera très probablement postérieur à celui de `SUPER_ADMIN_ROADMAP.md`, pas V59
> comme écrit ci-dessous par simple ordre de rédaction.

```sql
-- V59 (après les migrations V53-V58 de TEAM_ADMIN_ROADMAP.md — numéro indicatif, voir ci-dessus)
CREATE TABLE organization_sso_config (
    id                  BIGSERIAL    PRIMARY KEY,
    organization_id     BIGINT       NOT NULL UNIQUE REFERENCES organizations(id) ON DELETE CASCADE,
    protocol            VARCHAR(10)  NOT NULL,          -- OIDC | SAML
    -- OIDC
    oidc_issuer_uri     TEXT,
    oidc_client_id      TEXT,
    oidc_client_secret  TEXT,                            -- chiffré au repos (AES-GCM, même
                                                           -- pattern que le certificat PAdES
                                                           -- en Redis — clé hors base)
    -- SAML
    saml_idp_entity_id  TEXT,
    saml_idp_metadata_url TEXT,                           -- ou saml_idp_metadata_xml si upload direct
    saml_idp_cert       TEXT,                              -- certificat X.509 de l'IdP
    -- Commun
    domain              VARCHAR(255) NOT NULL,             -- ex. "entreprise.com" — voir §7
    enforce_sso         BOOLEAN      NOT NULL DEFAULT FALSE,
    enabled             BOOLEAN      NOT NULL DEFAULT FALSE,
    verified_at         TIMESTAMPTZ,                        -- vérification de propriété du domaine (DNS TXT)
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_org_sso_domain ON organization_sso_config (domain);
```

L'URL ACS (Assertion Consumer Service) et l'Entity ID SP sont **générés par organisation** :
`https://app.kovixel.com/api/v1/sso/saml/{orgPublicId}/acs` — jamais une URL générique
partagée entre tenants (isolation stricte, même logique que le scoping par `organizationId`
introduit dans `TEAM_ADMIN_ROADMAP.md`).

---

## 5. Provisioning : JIT puis SCIM

| Mode | Description | Phase |
|------|--------------|-------|
| **JIT (Just-In-Time)** | Au premier login SSO réussi, si l'utilisateur n'existe pas encore chez Kovixel, il est créé automatiquement et ajouté à `organization_members` avec le rôle par défaut `MEMBER` | Phase 1 (MVP) |
| **SCIM 2.0** | L'IdP pousse lui-même les créations/modifications/suppressions de comptes vers Kovixel (`/scim/v2/Users`) — un employé retiré de l'annuaire d'entreprise perd l'accès **immédiatement**, sans attendre une désactivation manuelle côté Kovixel | Phase 3 (Enterprise avancé) |

Le JIT suffit pour la majorité des demandes Enterprise initiales. Le SCIM est un chantier
distinct (nouveau protocole, nouveau contrôleur `/scim/v2/**`, authentification par bearer
token dédié par organisation) à ne construire qu'une fois une vraie demande client formulée.

---

## 6. Sécurité SAML — non négociable

Ces règles reprennent et étendent la rigueur déjà appliquée dans `OAuthTokenValidator`
(validation issuer/audience/expiration) et dans le correctif `OAuthService` sur l'email non
vérifié :

1. **Validation de signature obligatoire, jamais désactivable** — aucune configuration ne doit
   permettre de démarrer en mode "signature non vérifiée", même en développement. C'est la
   protection principale contre les assertions forgées.
2. **Validation stricte de l'audience et du destinataire** (`Audience`, `Recipient`,
   `InResponseTo`) — une assertion émise pour une autre organisation ou un autre service ne doit
   jamais être acceptée. Directement analogue à la vérification `issuer`/`audience` déjà faite
   pour Google/Apple/Microsoft dans `OAuthTokenValidator.validate()`.
3. **Protection anti-rejeu** : cache des `Assertion ID` déjà consommés (Redis, TTL = durée de
   validité de l'assertion, même infrastructure que `AnonymousQuotaService`/
   `PdfCertificateRedisService`) — une assertion SAML interceptée ne doit pas être rejouable.
4. **Tolérance d'horloge bornée** (`NotBefore`/`NotOnOrAfter`, ±5 minutes) — ni trop stricte
   (faux rejets sur dérive d'horloge légitime), ni trop laxiste (fenêtre de rejeu élargie).
5. **`emailVerified` : même garde-fou que pour OAuth.** Si l'IdP ne certifie pas explicitement
   l'email (rare en SAML Enterprise, mais possible avec des IdP mal configurés), refuser la
   liaison à un compte LOCAL existant — **exactement le correctif déjà livré sur
   `OAuthService.handleOAuthLogin`**. Ne pas réintroduire cette faille sur un nouveau protocole
   sous prétexte que "c'est différent du flow OAuth".
6. **Single Logout (SLO)** — optionnel en Phase 1, mais si implémenté : invalider la session
   Kovixel (réutiliser `TokenBlacklistService`) en plus de rediriger vers l'IdP, jamais l'un
   sans l'autre.
7. **Secrets IdP chiffrés au repos** (`oidc_client_secret`, futurs secrets SAML) — même
   principe que le certificat PKCS#12 de signature déjà chiffré en Redis (AES-GCM, clé hors
   base de données).

---

## 7. Application de la politique SSO

Une fois `enforce_sso = true` pour une organisation :

- Toute tentative de connexion par mot de passe pour un email du **domaine vérifié** de cette
  organisation est **refusée**, avec redirection explicite vers le flux SSO — sinon le SSO
  n'est qu'une option de confort et pas un contrôle d'accès réel (un employé quitté pourrait
  encore se connecter par mot de passe si son compte local n'est pas désactivé).
- La vérification de domaine (`verified_at`, DNS TXT) est un **prérequis** avant d'activer
  `enforce_sso` — sans elle, n'importe qui pourrait revendiquer un domaine qui ne lui appartient
  pas et forcer le SSO d'une organisation tierce (déni de service ciblé). Le champ
  `organization_sso_config.domain`/`verified_at` est **mutualisé** avec la demande de jonction
  décrite dans `TEAM_ADMIN_ROADMAP.md` §9.2 — mêmes données, deux usages distincts et non
  interchangeables : `enforce_sso` bloque automatiquement le mot de passe (aucune validation
  humaine), la demande de jonction exige toujours l'approbation explicite d'un `OWNER`/`ADMIN`
  (décision produit tranchée : pas d'auto-jonction immédiate même sur domaine vérifié).
- Les comptes déjà existants en `LOCAL` sur ce domaine doivent être migrés explicitement (liaison
  au premier login SSO réussi, avec le même garde-fou `emailVerified` que §6.5) — jamais une
  bascule automatique et silencieuse.

---

## 8. Backend — flux détaillé

Package proposé : `com.kovixel.sso` (nouveau module).

### Flux OIDC (Phase 1)

1. `GET /api/v1/sso/oidc/{orgPublicId}/authorize` → construit l'URL d'autorisation vers
   `oidc_issuer_uri` avec `client_id`, `redirect_uri`, `state` signé (anti-CSRF), `nonce`.
2. `GET /api/v1/sso/oidc/{orgPublicId}/callback` → échange le code contre un token, valide le
   token (issuer, audience, signature — réutilise le pattern `OAuthTokenValidator`), résout ou
   crée l'utilisateur (JIT), émet les tokens Kovixel (`JwtService`, cookie RT `HttpOnly`, même
   flux que `AuthController` existant).

### Flux SAML (Phase 2)

1. `GET /api/v1/sso/saml/{orgPublicId}/login` → génère et signe une `AuthnRequest`, redirige
   vers `saml_idp_entity_id`.
2. `POST /api/v1/sso/saml/{orgPublicId}/acs` → reçoit la `Response` SAML (POST binding),
   valide selon §6, résout ou crée l'utilisateur (JIT), émet les tokens Kovixel.

Dans les deux cas, le point de sortie est identique : un `User` résolu/créé, une entrée
`organization_members` garantie, puis remise dans le même pipeline d'émission de JWT que
l'authentification classique — **aucun raccourci de sécurité spécifique au SSO** dans la
génération des tokens Kovixel eux-mêmes.

---

## 9. Phasage

| Phase | Livrable | Dépend de |
|-------|----------|-----------|
| **0** | `organization_sso_config` (V59), vérification de domaine DNS TXT | `TEAM_ADMIN_ROADMAP.md` Phase 1 |
| **1** | SSO OIDC de bout en bout (1 organisation pilote, IdP Okta ou Azure AD en test) | Phase 0 |
| **2** | SSO SAML 2.0 (`spring-security-saml2-service-provider`), JIT provisioning | Phase 1 |
| **3** | Application de la politique (`enforce_sso`), migration des comptes LOCAL existants | Phase 2 |
| **4** | SCIM 2.0 (provisioning/déprovisioning automatique) | Phase 3, sur demande client réelle |

---

## 10. Stratégie de tests

- **Unitaires** : validation de signature (assertion valide/invalide/expirée/rejouée), refus
  systématique si `emailVerified == false` (même suite d'esprit que `OAuthServiceTest`
  §"liaison de compte OAuth sans exiger email_verified").
- **Isolation multi-tenant** : une assertion émise pour l'org A ne doit jamais être acceptée
  sur l'endpoint ACS de l'org B — test anti-IDOR dédié, même famille que
  `JobAccessGuardTest`/`OrgAccessGuardTest`.
- **IdP de test** : utiliser un IdP SAML/OIDC de test self-hosted (ex. `simplesamlphp` en
  conteneur Docker de dev) pour les tests d'intégration, ne jamais dépendre d'un vrai tenant
  Okta/Azure AD en CI.
- **Politique d'enforcement** : vérifier qu'un login par mot de passe est bien rejeté une fois
  `enforce_sso = true`, et que la redirection SSO est bien proposée à la place.

---

## 11. Variables d'environnement

| Variable | Description |
|----------|-------------|
| `SSO_SAML_KEYSTORE_PATH` | Keystore contenant la clé privée SP (signature des `AuthnRequest`) |
| `SSO_SAML_KEYSTORE_PASSWORD` | Mot de passe du keystore — obligatoire, sans défaut (même
  traitement fail-fast que `JWT_SECRET`/`REDIS_PASSWORD`) |
| `SSO_ASSERTION_REPLAY_CACHE_TTL_SECONDS` | TTL Redis du cache anti-rejeu (§6.3) |

---

## 12. Checklist mise en production

- [ ] `spring-security-saml2-service-provider` ajouté et son wiring isolé de la
      `SecurityConfig` principale (ne doit pas affaiblir la chaîne de filtres existante)
- [ ] Validation de signature testée avec une assertion volontairement forgée (doit échouer)
- [ ] Cache anti-rejeu vérifié sous charge concurrente
- [ ] Vérification de domaine DNS TXT opérationnelle avant toute activation d'`enforce_sso`
- [ ] Secrets IdP (`oidc_client_secret`, clé privée SP SAML) chiffrés au repos, jamais en clair
      en base ni en logs
- [ ] Test de bout en bout avec au moins un IdP réel (Okta **et** Azure AD — les implémentations
      SAML varient assez d'un IdP à l'autre pour ne pas se fier à un seul)
- [ ] Page pricing/documentation mise à jour pour confirmer "SSO/SAML disponible sur demande"
      une fois livré (cf. `kovixel-ui/ISSUES.md` #44)

---

*Feuille de route créée le 2026-07-12 — Version 1.0*
