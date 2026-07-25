# Politique de Sécurité des Systèmes d'Information (PSSI) — Chiffrement des données

**ROADMAP_CHIFFREMENT.md Sprint E-8.1.** Périmètre : mesures cryptographiques protégeant les
fichiers utilisateurs, les secrets d'authentification et les métadonnées sensibles chez Kovixel.
Ce document reflète l'implémentation réelle (Sprints E-1 à E-7), pas un objectif théorique — chaque
affirmation ci-dessous est vérifiable dans le code cité.

Dernière mise à jour : 2026-07-25.

## 1. Algorithmes autorisés (liste blanche)

| Usage | Algorithme | Implémentation |
|---|---|---|
| Chiffrement symétrique (fichiers, secrets TOTP, titres) | AES-256-GCM (AEAD, tag 128 bits) | `com.kovixel.common.crypto.CryptoService` |
| Dérivation de clé | HKDF-SHA256 (RFC 5869) | `com.kovixel.common.crypto.HkdfService` — implémentation maison (`javax.crypto.Mac`), pas de dépendance externe (ADR-003) |
| Hash de mot de passe | BCrypt, coût 12 | `SecurityConfig.passwordEncoder()` |
| Signature JWT | HS256 | `JwtService` |
| Hash d'intégrité (titre, recherche) | SHA-256 | `EncryptionKeyService` (dérivation de salt), `Document.titleHash` |

**Interdits** : tout algorithme non listé ci-dessus ne doit jamais être introduit sans mise à jour
de ce document et revue de code dédiée. En particulier : AES-CBC sans HMAC séparé (oracle de
padding, cf. ADR-002), MD5/SHA-1 pour toute fonction de sécurité, RC4, DES/3DES.

## 2. Modèle de clés et durées de vie

Architecture en **envelope encryption** (ADR-001) : Master Key (MK) → Key Encryption Key (KEK,
dérivée par HKDF) → Data Encryption Key (DEK, unique par fichier/secret, chiffrée par la KEK).

| Clé | Portée | Durée de vie | Rotation |
|---|---|---|---|
| Master Key (MK) | Globale, une par version | **1 an maximum** (recommandation ; aucune rotation forcée automatique n'existe — décision opérationnelle, cf. `docs/encryption/KEY_ROTATION.md`) | Manuelle, via le runbook `KEY_ROTATION.md` — modèle dual-key (version courante + `current-1`), `EncryptionRotationJob` re-wrappe les eDEK par lots de 50 toutes les 30s |
| Key Encryption Key (KEK) | Par fichier (ancrée sur `storageKey`, ADR-005), par utilisateur (TOTP, ancrée sur `userId`), ou globale (titres de document) | Dérivée à la demande depuis la MK — jamais stockée | Suit la version de la MK dont elle dérive |
| Data Encryption Key (DEK) | Unique par fichier | Durée de vie du document (crypto-shredding à expiration, cf. §4) | Jamais rotée elle-même — seule son enveloppe (eDEK, chiffrée par la KEK) est re-chiffrée lors d'une rotation de MK |

**Limite connue et documentée (dette assumée)** : `EncryptionRotationJob` ne re-wrappe que les
`file_encryption_keys`. Les secrets TOTP et les titres de document chiffrés sous une ancienne
version de MK ne sont PAS automatiquement re-chiffrés (migration paresseuse pour les TOTP à la
reconnexion ; aucun mécanisme équivalent pour les titres). `KEY_ROTATION.md` §5 recommande de
garder `ENCRYPTION_MASTER_KEY_LEGACY` configuré indéfiniment tant qu'un job de re-chiffrement des
titres n'existe pas. Voir `rotation-status` (`GET /api/v1/admin/encryption/rotation-status`) pour
le suivi (`totpOutdatedVersionCount`, `safeToRevokeLegacyKey`).

## 3. Processus de rotation obligatoire

Déclencheurs qui **imposent** une rotation de la MK (pas seulement recommandée) :
- Suspicion ou confirmation de compromission (voir §5 — Gestion des incidents).
- Départ d'un membre de l'équipe ayant eu accès à `ENCRYPTION_MASTER_KEY` en clair (variable
  d'environnement, jamais committée — cf. audit `.gitignore` Sprint E-7).
- Échéance de 1 an sans rotation (politique préventive).

Procédure complète : `docs/encryption/KEY_ROTATION.md` (génération, dual-key, supervision via
`rotation-status`, révocation de l'ancienne clé). Ne jamais reculer `ENCRYPTION_KEK_VERSION` — la
bonne procédure de rollback est une rotation en avant (§6 du runbook).

## 4. Fin de vie des données (crypto-shredding)

Rétention différenciée par plan tarifaire (`RetentionPolicy`, Sprint E-5) :

| Plan | Rétention après upload | Rétention après dernier accès |
|---|---|---|
| Invité (sans compte) | 2 heures | — |
| FREE | 24 heures | 24 heures |
| PRO / PRO_PLUS | 30 jours | 90 jours |
| TEAM / ENTERPRISE | 365 jours | 730 jours |

Suppression en deux phases (`DocumentCleanupJob`) : révocation immédiate de la clé de chiffrement
à expiration (le fichier devient instantanément illisible — crypto-shredding, RGPD Art. 17), puis
suppression physique des octets 48h plus tard (`kovixel.encryption.physical-deletion-delay-hours`,
marge de sécurité contre un besoin de restauration exceptionnel).

## 5. Gestion des incidents — clé compromise

En cas de suspicion de compromission de `ENCRYPTION_MASTER_KEY` (fuite dans un log, accès non
autorisé à l'environnement de production, employé quittant l'entreprise avec accès aux secrets) :

1. **Rotation immédiate**, sans attendre l'échéance annuelle — suivre `KEY_ROTATION.md` en
   priorité absolue. Ne pas attendre que `EncryptionRotationJob` traite le lot habituel : le
   process tourne déjà toutes les 30s par lots de 50, la vitesse de re-chiffrement dépend
   uniquement du volume de fichiers actifs.
2. **Ne pas révoquer l'ancienne clé avant confirmation à 100%** (`rotation-status.completion`) —
   une révocation prématurée rend les fichiers non encore rotés définitivement illisibles pour
   leurs propriétaires légitimes (pas seulement pour l'attaquant).
3. **Évaluer l'obligation de notification RGPD** (Art. 33 — notification à la CNIL sous 72h si
   risque pour les droits des personnes ; Art. 34 — notification aux personnes concernées si
   risque élevé). Cette évaluation dépend de la nature de la compromission (clé seule, sans accès
   aux fichiers chiffrés eux-mêmes = risque résiduel faible du fait de l'envelope encryption —
   ADR-001 : la base de données et le stockage fichier contiennent des informations différentes,
   un attaquant qui compromet l'un ne peut pas déchiffrer sans l'autre).
4. **Révoquer les accès** (rotation des credentials DB/MinIO/Redis, cf.
   `docs/encryption/INFRASTRUCTURE_HARDENING.md` §5) en parallèle de la rotation de la MK — une
   compromission de MK s'accompagne souvent d'une compromission plus large de l'environnement.
5. **Documenter l'incident** (chronologie, cause racine, mesures correctives) — obligatoire pour
   toute démarche de certification ultérieure (ISO 27001 A.16, SOC 2 CC7).

## 6. Portée et limites de ce document

Ce PSSI couvre le chiffrement applicatif (Sprints E-1 à E-6). Le durcissement infrastructure
(TLS, PostgreSQL SSL, Redis TLS, MinIO KMS — Sprint E-7) est **partiellement implémenté** : voir
`docs/encryption/INFRASTRUCTURE_HARDENING.md` pour l'état exact et les prérequis ops restants
avant un déploiement en production. Ce PSSI ne remplace pas un audit de sécurité externe (Sprint
E-8.4) ; il documente ce qui existe pour le rendre auditable.
