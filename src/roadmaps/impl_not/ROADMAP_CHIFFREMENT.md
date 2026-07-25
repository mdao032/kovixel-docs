# Roadmap Chiffrement — Kovixel Documents

> **Statut :** v1.1 — en cours d'implémentation (démarrée 2026-07-22)
> **Auteur :** Architecture Kovixel
> **Date :** 2026-06-19 (v1.0) — révisée 2026-07-22 (v1.1, alignement avec l'état réel du code)
> **Audience :** Équipe backend, RSSI, direction produit

> **Addendum v1.1 (2026-07-22)** — Cette révision corrige plusieurs divergences entre la v1.0 (rédigée sans revue du code) et l'état réel de la codebase au moment du démarrage de l'implémentation :
> - Les numéros de migration Flyway V32–V37 étaient déjà pris par des migrations OCR/PDF/org (V32 = `create_ocr_results`, etc.). Toutes les migrations de cette roadmap démarrent désormais à **V67** (dernière migration existante : V66). Voir §7.
> - Il n'existe **aucun endpoint d'upload central** dans `DocumentController` — l'upload est déclenché depuis ~20 services métier différents (OCR, conversion, watermark, e-signature, etc.) qui appellent tous directement `FileStorageService.store()/storeBytes()`. Le chiffrement doit donc être **transparent à l'intérieur des implémentations `FileStorageService`** (Local + MinIO), sans changer leur signature, plutôt qu'ajouté dans un contrôleur unique. Voir §5.7 et Sprint E-2.
> - `FileStorageService.store(file, key)` / `storeBytes(data, key, contentType)` ne portent **ni `userId` ni `documentId`** — seule la `storageKey` (déjà unique par fichier) est disponible à l'écriture comme à la lecture. Le modèle d'enveloppe est donc ancré sur la `storageKey`, pas sur l'utilisateur (voir ADR-005).
> - Un système de cycle de vie/rétention **existe déjà** (`Document.expiresAt`, `RetentionPolicy`, `DocumentCleanupJob` — 2h invités / 30j comptes) : le Sprint E-5 doit l'étendre, pas le recréer.
> - BouncyCastle (`bcprov-jdk18on` **1.78.1** + `bcpkix-jdk18on` 1.78.1) est déjà une dépendance pinnée du projet — ne pas ajouter une seconde version.
> - `HashUtils.sha256Hex()` est utilisé sur des tokens aléatoires à haute entropie (refresh tokens, reset tokens, codes de secours, invitations), pas comme KDF sur un secret faible — la formulation "SHA-256 nu utilisé comme KDF" du §2.2 est reformulée.

---

## Table des matières

1. [Préambule](#1-préambule)
2. [État des lieux](#2-état-des-lieux)
3. [Modèle de menace](#3-modèle-de-menace)
4. [Analyse concurrentielle](#4-analyse-concurrentielle)
5. [Architecture cryptographique cible](#5-architecture-cryptographique-cible)
6. [Roadmap par sprints](#6-roadmap-par-sprints)
7. [Migrations Flyway](#7-migrations-flyway)
8. [Décisions d'architecture (ADR)](#8-décisions-darchitecture-adr)
9. [Risques et mitigations](#9-risques-et-mitigations)
10. [KPIs de sécurité](#10-kpis-de-sécurité)
11. [Conformité réglementaire](#11-conformité-réglementaire)
12. [Glossaire](#12-glossaire)

---

## 1. Préambule

Kovixel traite des documents potentiellement sensibles (contrats, factures, données personnelles, documents médicaux) pour le compte de ses utilisateurs. La confiance est le fondement du modèle produit.

Aujourd'hui, les fichiers uploadés sont stockés **en clair** sur le système de fichiers local (profil `dev`) ou dans un bucket MinIO (profil `prod`) sans chiffrement applicatif. C'est une dette de sécurité critique : une compromission du serveur de stockage, une mauvaise configuration de bucket, ou une fuite de backup expose directement le contenu de tous les documents de tous les utilisateurs.

Cette roadmap définit un plan structuré, progressif et techniquement irréprochable pour atteindre un niveau de sécurité comparable aux leaders du marché et conforme aux exigences RGPD, ISO 27001 et SOC 2 Type II.

---

## 2. État des lieux

### 2.1 Ce qui existe et fonctionne bien

| Composant | Implémentation | Niveau |
|-----------|---------------|--------|
| Hachage des mots de passe | BCrypt coût 12 | ✅ Excellent |
| Authentification 2FA | TOTP RFC 6238 + codes backup SHA-256 | ✅ Bon |
| Tokens JWT | HS256, expiration 15 min, `jti` UUID | ✅ Bon |
| Refresh tokens | SHA-256 haché en base | ✅ Bon |
| Tokens de réinitialisation | SHA-256, TTL limité | ✅ Bon |
| Verrouillage de compte | 5 tentatives → 15 min de cooldown | ✅ Bon |
| Audit des authentifications | Table `auth_events`, async | ✅ Bon |
| Historique des mots de passe | 5 derniers BCrypt | ✅ Bon |
| URLs pré-signées MinIO | Expiration 1h | ✅ Bon |
| Rate limiting | Par IP (anonyme) + par utilisateur | ✅ Bon |

### 2.2 Lacunes critiques identifiées

| Lacune | Fichier concerné | Sévérité |
|--------|-----------------|----------|
| **Aucun chiffrement des fichiers au repos** | `LocalFileStorageService.java`, `MinioFileStorageService.java` | 🔴 Critique |
| **Aucun audit des opérations fichiers** | Aucun (retrieve/store non tracés) | 🔴 Critique |
| **Cycle de vie existant mais non différencié par plan** | `Document.expiresAt`, `RetentionPolicy`, `DocumentCleanupJob` (2h invité / 30j compte, uniforme) | 🟡 Moyen |
| **Aucune gestion de clés cryptographiques** | Inexistant | 🔴 Critique |
| **Noms de fichiers stockés en clair** | Table `documents` | 🟠 Élevé |
| **Hachage de tokens sans sel/itération dédiés à un KDF de fichiers** (usage actuel légitime pour tokens aléatoires, mais aucun KDF de clés de fichier) | `HashUtils.java` | 🟠 Élevé |
| **Aucun chiffrement des secrets 2FA en base** | Table `two_factor_auth` | 🟠 Élevé |
| **Redis non chiffré** (tokens de challenge 2FA) | `application.yml` | 🟠 Élevé |
| **Aucune rotation de clés** | Inexistant | 🟡 Moyen |
| **Aucun TDE PostgreSQL** | `application-prod.yml` | 🟡 Moyen |
| **Suppression sans garantie cryptographique** | `FileStorageService.java` | 🟡 Moyen |

### 2.3 Inventaire du stockage actuel

```
Profil dev  : ./uploads/{userId}/{documentId}/{filename}  (plaintext)
Profil prod : MinIO bucket kovixel-documents/{userId}/{documentId}/{filename}  (plaintext)

Table documents :
  - storageKey VARCHAR(500)   → chemin en clair
  - storageUrl TEXT           → URL en clair
  - title VARCHAR(255)        → en clair
  - contentType VARCHAR       → en clair
  - size BIGINT               → en clair

Interface FileStorageService (com.kovixel.storage) — signature réelle, sans userId/documentId :
  String store(MultipartFile file, String key)
  String storeBytes(byte[] data, String key, String contentType)
  InputStream retrieve(String key)
  void delete(String key)
  static String buildKey(Long userId, String documentId, String fileName)

Implémentations : LocalFileStorageService (@Profile("dev")), MinioFileStorageService (@Profile("prod"),
+ generatePresignedUrl). Sélection par profil Spring, pas par @Primary. ~20 appelants directs
(OcrServiceImpl, PdfLockServiceImpl, PdfWatermarkServiceImpl, PdfEsignatureServiceImpl,
ConversionJobHandler, SummaryServiceImpl, ProcessingServiceImpl, etc.) — aucun endpoint d'upload
central à intercepter.
```

---

## 3. Modèle de menace

Un modèle de menace rigoureux est le préalable à toute décision cryptographique. Sans lui, on chiffre les mauvaises choses avec les mauvais algorithmes.

### 3.1 Acteurs malveillants et vecteurs d'attaque

| Acteur | Vecteur | Impact sans chiffrement | Impact avec roadmap |
|--------|---------|------------------------|-------------------|
| **Attaquant externe** | Compromission du serveur de fichiers | Accès à 100% des documents | Fichiers illisibles sans les clés |
| **Attaquant externe** | Accès non autorisé au bucket MinIO (misconfiguration) | Téléchargement de tous les fichiers | Fichiers illisibles |
| **Attaquant externe** | Exfiltration de backup de base de données | Métadonnées et chemins exposés | Métadonnées chiffrées, clés inaccessibles sans KEK |
| **Insider malveillant** | Accès physique ou SSH au serveur | Copie directe des fichiers | Chiffrement rend les fichiers illisibles |
| **Compromission de backup** | Backup S3 ou disque volé | Exposition totale | Fichiers illisibles |
| **Fuite de secrets d'infrastructure** | `.env` / variables d'environnement volées | Accès complet | Limitée au Master Key (à protéger séparément) |
| **Attaque sur la base de données** | SQL injection ou accès direct à Postgres | Métadonnées exposées | Métadonnées chiffrées |
| **Déni de droit à l'effacement (RGPD)** | Rétention après suppression utilisateur | Violation Art. 17 RGPD | Crypto-shredding : irréversible en millisecondes |

### 3.2 Ce que cette roadmap ne protège PAS (hors périmètre)

- Un attaquant qui compromet l'application **en cours d'exécution** (le fichier doit être déchiffré pour être servi) — c'est la limite fondamentale du chiffrement côté serveur.
- Un administrateur système avec accès root au serveur **et** à la base de données simultanément — seul le chiffrement côté client (E2EE) protège contre ce scénario (Sprint E-9, hors périmètre v1).
- Les attaques par canal auxiliaire (timing, cache) sur l'implémentation cryptographique — atténuées par l'usage de bibliothèques auditées.

---

## 4. Analyse concurrentielle

### 4.1 SmallPDF

**Engagements publics de sécurité :**
- Chiffrement AES-256 au repos (AWS S3) + TLS 1.2+ en transit
- Suppression automatique des fichiers après **1 heure** (plan gratuit)
- Conservation persistante option payante avec chiffrement de bout en bout optionnel
- Certification ISO 27001, SOC 2 Type II
- Données hébergées en UE (Suisse + AWS eu-central-1)
- Aucun accès employé aux fichiers (contrôle technique, pas seulement contractuel)
- Politique zéro-log sur le contenu des fichiers

**Analyse technique :** SmallPDF utilise le chiffrement SSE-S3 d'AWS (géré par AWS, clés AWS). C'est le niveau minimum acceptable — les clés sont détenues par l'hébergeur, pas par l'utilisateur. Leur "end-to-end encryption" pour les plans payants repose sur un chiffrement côté client avant upload (JavaScript), ce qui est significativement plus fort.

### 4.2 ilovePDF

**Engagements publics de sécurité :**
- AES-256 au repos + TLS en transit
- Suppression automatique après **2 heures** de traitement
- Certification ISO 27001
- Serveurs en UE (Barcelone + CDN EU)
- RGPD Art. 32 (mesures techniques appropriées)
- Pas de rétention permanente sans consentement explicite
l
**Analyse technique :** Architecture similaire à SmallPDF mais avec un modèle multi-tenant moins sophistiqué. Pas de chiffrement côté client. Clés de chiffrement gérées côté serveur.

### 4.3 Adobe Acrobat Online

**Engagements publics de sécurité :**
- HSM (Hardware Security Modules) pour les clés maîtres
- FedRAMP Authorized (niveau le plus élevé pour le gouvernement américain)
- Chiffrement AES-256 côté client avant upload (pour certaines opérations)
- Audit trail détaillé avec horodatage RFC 3161
- Clés de document dérivées par utilisateur

**Analyse technique :** C'est le gold standard. Adobe utilise du vrai envelope encryption avec HSM, signature temporelle normalisée et audit trail complet.

### 4.4 Positionnement cible de Kovixel

```
                    SmallPDF    ilovePDF    Adobe      Kovixel v1    Kovixel v2
                                           Acrobat    (roadmap)     (futur)
─────────────────────────────────────────────────────────────────────────────
AES-256 au repos       ✅          ✅         ✅          ✅            ✅
Auto-suppression       ✅          ✅         ✅          ✅            ✅
Clés par utilisateur   ❌          ❌         ✅          ✅            ✅
Rotation des clés      ❌          ❌         ✅          ✅            ✅
Audit fichiers         ❌          ❌         ✅          ✅            ✅
Crypto-shredding       ❌          ❌         ✅          ✅            ✅
Chiffrement métadatas  ❌          ❌         Partiel     Partiel       ✅
E2EE (côté client)     Partiel     ❌         Partiel     ❌            ✅
HSM/KMS                ❌          ❌         ✅          ❌ (Phase 2)  ✅
ISO 27001              ✅          ✅         ✅          Cible         Cible
SOC 2 Type II          ✅          ❌         ✅          Cible         Cible
```

**La roadmap v1 place Kovixel au-dessus de SmallPDF et ilovePDF sur les attributs clés (clés par utilisateur, rotation, crypto-shredding, audit complet)** — des différenciateurs produit significatifs.

---

## 5. Architecture cryptographique cible

### 5.1 Principes directeurs

1. **Principe de Kerckhoffs** : la sécurité repose sur le secret des clés, pas sur le secret de l'algorithme. Tous les algorithmes utilisés sont publics, audités et standardisés.
2. **Défense en profondeur** : chiffrement applicatif + chiffrement infrastructure (SSE MinIO/S3 + TLS). La compromission d'une couche ne suffit pas.
3. **Moindre privilège cryptographique** : chaque composant n'a accès qu'aux clés dont il a besoin, au moment où il en a besoin.
4. **Authentified Encryption (AEAD)** : confidentialité et intégrité en un seul algorithme — pas de MAC séparé à orchestrer.
5. **Fail-secure** : en cas d'erreur de déchiffrement, on rejette la requête. Jamais de fallback vers le clair.

### 5.2 Algorithmes retenus

| Usage | Algorithme | Taille de clé | Justification |
|-------|-----------|--------------|---------------|
| **Chiffrement fichiers** | AES-256-GCM | 256 bits | AEAD, NIST SP 800-38D, accélération matérielle AES-NI |
| **Wrapping des DEK** | AES-256-GCM (key wrap) | 256 bits | RFC 5649, natif Java |
| **Dérivation de clés** | HKDF-SHA256 | — | RFC 5869, séparation des contextes |
| **Intégrité token** | HMAC-SHA256 | 256 bits | Déjà utilisé pour JWT |
| **Hachage (général)** | SHA-256 | — | Pour identifiants, non pour KDF |
| **Aléa cryptographique** | `SecureRandom` (DRBG) | — | Seul générateur acceptable |

> **Pourquoi AES-256-GCM et pas ChaCha20-Poly1305 ?** Kovixel tourne sur du matériel serveur moderne avec accélération AES-NI, rendant AES-256-GCM plus rapide. ChaCha20-Poly1305 sera envisagé si Kovixel s'étend à des contextes sans AES-NI (mobile E2EE).

> **Pourquoi pas RSA/ECDSA pour wrapper les DEK ?** La cryptographie asymétrique est ~1000× plus lente et n'apporte pas de bénéfice ici : nous ne faisons pas de distribution de clés entre parties qui ne partagent pas de secret commun. L'envelope encryption symétrique (AES wrapping AES) est la pratique standard des KMS (AWS, GCP, Azure).

### 5.3 Modèle Envelope Encryption

Le modèle d'envelope encryption est la fondation de tout KMS commercial (AWS KMS, GCP Cloud KMS, HashiCorp Vault). Il découple le chiffrement des données de la gestion des clés.

```
┌─────────────────────────────────────────────────────────────────────┐
│  COUCHE 1 : Master Key (MK)                                          │
│  Stockage : variable d'environnement JWT_SECRET ou Vault/KMS        │
│  Format   : 32 octets (256 bits) générés par SecureRandom           │
│  Durée    : Permanent (rotation annuelle minimum)                    │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ HKDF-SHA256(MK, salt=user_id, info="kovixel-kek-v1")
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  COUCHE 2 : Key Encryption Key (KEK) — par utilisateur              │
│  Stockage : Jamais stocké. Dérivé à la demande, utilisé en mémoire  │
│  Format   : 32 octets, dérivés déterministiquement du MK + user_id  │
│  Durée    : Durée de vie de la requête uniquement                    │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ AES-256-GCM encrypt DEK
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  COUCHE 3 : Encrypted DEK (eDEK) — par document                     │
│  Stockage : Table `document_encryption_keys` en base de données     │
│  Format   : 48 octets (32 DEK + 16 GCM tag) + 12 octets IV         │
│  Durée    : Durée de vie du document                                 │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │ AES-256-GCM decrypt eDEK → DEK
                                  │ AES-256-GCM encrypt file with DEK
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  COUCHE 4 : Fichier chiffré                                          │
│  Stockage : LocalFileStorage (./uploads/) ou MinIO                  │
│  Format   : [IV 12B][ciphertext][GCM tag 16B]                       │
│  Durée    : Durée de vie du document (auto-suppression)              │
└─────────────────────────────────────────────────────────────────────┘
```

**Avantages clés de ce modèle :**

- **Rotation du Master Key** : on re-dérive les KEK et re-wrappe les DEK. Les fichiers ne sont **pas** re-chiffrés (seulement les eDEK en base). O(n) opérations légères au lieu de re-chiffrer potentiellement des Go de données.
- **Crypto-shredding** : supprimer la ligne `document_encryption_keys` d'un document rend le fichier **définitivement illisible**, même si les octets chiffrés persistent temporairement sur le disque. Idéal pour le droit à l'effacement RGPD.
- **Compromission de la base seule** : les eDEK sont inutilisables sans le MK (qui n'est pas en base).
- **Compromission du stockage seul** : les fichiers sont illisibles sans les eDEK (qui ne sont pas dans le stockage).
- Les deux doivent être compromis **simultanément**, et le MK en plus — défense en profondeur réelle.

### 5.4 Format binaire des fichiers chiffrés

```
Offset  Length  Field
──────  ──────  ─────────────────────────────────────────────────
0       4       Magic number: 0x4B4F5658 ("KOVX")
4       2       Version: 0x0001
6       2       Flags: bit 0 = compressed before encryption
8       4       Original file size (uint32, big-endian)
12      12      IV (Initialization Vector, random, SecureRandom)
24      N       Ciphertext (original content + 16-byte GCM tag appended by Java)
```

**Total overhead par fichier** : 24 octets de header + 16 octets de GCM tag = **40 octets**. Négligeable.

Le DEK correspondant est stocké séparément en base dans `document_encryption_keys`, jamais dans le fichier lui-même.

### 5.5 Dérivation des clés (HKDF)

```java
// Pseudo-code — implémentation dans EncryptionKeyService.java
byte[] deriveKek(long userId, int kekVersion) {
    // RFC 5869 HKDF-Extract + HKDF-Expand
    String info = "kovixel-kek-v" + kekVersion + ":user:" + userId;
    return HKDF.expand(
        HKDF.extract(masterKey, salt: userId.toBytesBigEndian()),
        info.getBytes(UTF_8),
        outputLength: 32
    );
}
```

Le `kekVersion` dans l'info HKDF assure que chaque rotation de MK produit des KEK différents, permettant la migration progressive des eDEK.

### 5.6 Vue d'ensemble des flux

#### Upload (chiffrement)
```
Client → POST /api/v1/documents (multipart)
  → DocumentController.upload()
  → EncryptedFileStorageService.store(file, key, userId)
      ├── Génère DEK (32 octets, SecureRandom)
      ├── Génère IV (12 octets, SecureRandom)
      ├── Chiffre file → AES-256-GCM(DEK, IV, file bytes) → ciphertext
      ├── Écrit header + ciphertext dans storageKey + ".enc"
      ├── Dérive KEK = HKDF(MK, userId)
      ├── Chiffre DEK → AES-256-GCM(KEK, IV2) → eDEK
      └── Persiste {document_id, eDEK, IV, IV2, kek_version} → document_encryption_keys
```

#### Download / Preview (déchiffrement)
```
Client → GET /api/v1/documents/{id}/content (JWT requis)
  → DocumentController.getContent()
  → EncryptedFileStorageService.retrieve(storageKey, documentId, userId)
      ├── Charge document_encryption_keys WHERE document_id = id
      ├── Dérive KEK = HKDF(MK, userId) — en mémoire uniquement
      ├── Déchiffre eDEK → DEK — en mémoire uniquement
      ├── Lit header du fichier .enc (IV, flags)
      ├── Déchiffre stream → AES-256-GCM(DEK, IV, ciphertext) → plaintext stream
      ├── Vérifie GCM auth tag (intégrité automatique)
      └── Stream résultat → ResponseBody (jamais écrit sur disque en clair)
```

> **Important** : le déchiffrement se fait en **streaming** (pas de chargement en mémoire du fichier entier). Pour les gros fichiers, on utilise `CipherInputStream` de Java. Le GCM tag est vérifié **avant** de libérer le premier octet vers le client (mode `AEAD` strict).

### 5.7 Ancrage de l'enveloppe sur `storageKey` (et non sur `userId`)

La v1.0 de cette roadmap dérivait le KEK à partir de `userId`. La revue de code (2026-07-22) montre que
`FileStorageService.store()/storeBytes()/retrieve()/delete()` ne reçoivent que la `storageKey` — ni
`userId` ni `documentId`. Étendre ces signatures obligerait à modifier ~20 appelants pour un bénéfice
marginal (voir ADR-005).

**Décision retenue :** le KEK est dérivé du Master Key avec `salt = SHA-256(storageKey)` et
`info = "kovixel-file-kek-v{kekVersion}"`, et non plus par utilisateur. Les métadonnées de clé
(`file_encryption_keys`) sont indexées par `storage_key` (colonne unique), avec un `document_id`
optionnel (nullable, non unique) pour les jointures d'audit quand un `Document` existe.

Conséquences :
- Le chiffrement/déchiffrement reste **entièrement transparent** dans `LocalFileStorageService` et
  `MinioFileStorageService` — zéro changement de signature, zéro changement dans les ~20 appelants.
- La rotation du Master Key fonctionne à l'identique (seuls les `eDEK` sont re-wrappés).
- Le crypto-shredding par document fonctionne à l'identique (`DocumentService.delete()` connaît déjà
  `doc.getStorageKey()`).
- Perdu par rapport à la v1.0 : la révocation groupée de **toutes** les clés d'un utilisateur en une
  seule opération. Ce n'est exigé par aucun critère de sortie de cette roadmap ; si le besoin apparaît,
  une table de correspondance `user_id → storage_key` (déjà reconstructible via `documents.user_id` +
  `documents.storage_key`) suffit pour un job de révocation en masse a posteriori.

---

## 6. Roadmap par sprints

### Vue d'ensemble

```
Sprint E-1  ████████████████  Fondations cryptographiques        2 semaines
Sprint E-2  ████████████████  Chiffrement des fichiers           2 semaines
Sprint E-3  ████████████████  Gestion et rotation des clés       2 semaines
Sprint E-4  ████████          Chiffrement des métadonnées        1 semaine
Sprint E-5  ████████          Cycle de vie & Crypto-shredding    1 semaine
Sprint E-6  ████████          Audit trail des opérations         1 semaine
Sprint E-7  ████████████████  Durcissement infrastructure        2 semaines
Sprint E-8  ░░░░░░░░░░░░░░░░  Conformité & Certification         Continu

Total estimation : 11 semaines
```

---

### Sprint E-1 — Fondations cryptographiques (2 semaines)

**Objectif :** Poser l'infrastructure cryptographique sans impacter les flux existants. Aucune rupture de compatibilité.

**Pourquoi en premier :** Tout le reste dépend de ces fondations. Un défaut dans les primitives cryptographiques compromet tous les sprints suivants.

#### Tâches

**E-1.1 — Dépendance cryptographique**

**Aucune nouvelle dépendance requise.** `bcprov-jdk18on` **1.78.1** (+ `bcpkix-jdk18on` 1.78.1) est déjà
pinné dans `pom.xml` (override transitif imposé par PDFBox/tabula) — ne pas ajouter une seconde version
de BouncyCastle. `AES/GCM/NoPadding` est natif JDK depuis Java 8 et ne nécessite BouncyCastle en aucune
façon.

Conformément à l'ADR-003, HKDF est implémenté **manuellement** via `javax.crypto.Mac` (HMAC-SHA256,
RFC 5869) — 50 lignes, zéro dépendance supplémentaire, auditable directement.

**E-1.2 — `CryptoService.java`**

Nouveau service : `com.kovixel.common.crypto.CryptoService`

Responsabilités :
- `encryptAesGcm(byte[] plaintext, byte[] key) → EncryptedPayload`
- `decryptAesGcm(EncryptedPayload payload, byte[] key) → byte[]`
- `generateKey() → byte[]` (32 octets, `SecureRandom`)
- `generateIv() → byte[]` (12 octets, `SecureRandom`)

Contraintes d'implémentation :
- Utiliser **exclusivement** `javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")`
- `GCMParameterSpec(128, iv)` — tag de 128 bits
- IV généré aléatoirement pour **chaque** opération de chiffrement, **jamais** réutilisé
- Jamais de `new Random()` — toujours `SecureRandom.getInstanceStrong()`
- Mode DECRYPT : vérifier le GCM tag avant tout traitement (déjà natif en Java, ne pas bypasser)
- Zéroïser les tableaux de clés après usage avec `Arrays.fill(key, (byte) 0)`

**E-1.3 — `HkdfService.java`**

Nouveau service : `com.kovixel.common.crypto.HkdfService`

Responsabilités :
- `deriveKey(byte[] ikm, byte[] salt, String info, int length) → byte[]`
- Implémentation : HKDF-SHA256 (RFC 5869)
  - Extract : `HMAC-SHA256(salt, ikm)` → PRK
  - Expand : `HMAC-SHA256(PRK, info || 0x01)` → OKM[0:32]

Contextes d'info définis comme constantes :
```java
public static final String KEK_CONTEXT = "kovixel-kek-v%d:user:%d";
public static final String METADATA_CONTEXT = "kovixel-metadata-v1:doc:%s";
```

**E-1.4 — `EncryptionKeyService.java`**

Nouveau service : `com.kovixel.common.crypto.EncryptionKeyService`

Responsabilités :
- Charger le Master Key depuis l'environnement (`ENCRYPTION_MASTER_KEY`)
- Dériver les KEK via `HkdfService`
- Wrapper / unwrapper les DEK via `CryptoService`
- Rotation de version (`kekVersion`)

Configuration requise dans `application.yml` (namespace `kovixel.*`, cohérent avec `kovixel.backup`,
`kovixel.pdfesignature`, etc. déjà en place — pas `encryption.*` à la racine comme suggéré en v1.0) :
```yaml
kovixel:
  encryption:
    master-key: ${ENCRYPTION_MASTER_KEY:}   # 64 hex chars = 32 bytes = 256 bits
    kek-version: ${ENCRYPTION_KEK_VERSION:1} # Incrémenter lors de la rotation MK
```

Validation au démarrage (`@PostConstruct`) :
- Vérifier que `ENCRYPTION_MASTER_KEY` est présent et fait exactement 64 caractères hexadécimaux
- Lever une `IllegalStateException` au démarrage si absent ou malformé — **jamais** démarrer sans clé valide

**E-1.5 — Tests unitaires cryptographiques**

Couvrir obligatoirement :
- Chiffrement → déchiffrement round-trip
- Modification d'un bit du ciphertext → exception (intégrité GCM)
- IV différent à chaque appel (`encryptAesGcm` appelé 1000 fois → 1000 IV uniques)
- Déchiffrement avec mauvaise clé → exception
- `generateKey()` : entropie (test statistique basique)
- HKDF : vecteurs de test RFC 5869 (appendice A.1 et A.2)

**E-1.6 — Génération du Master Key (documentation opérationnelle)**

Ajouter dans `README.md` ou documentation d'exploitation :
```bash
# Génération d'un Master Key cryptographiquement sûr
openssl rand -hex 32
# Exemple de sortie : a3f8c2...  (64 caractères hexadécimaux)
# NE JAMAIS COMMITTER cette valeur dans le dépôt
```

**Critères de sortie Sprint E-1 :**
- [ ] `CryptoService` implémenté avec tests unitaires (couverture > 95%)
- [ ] `HkdfService` avec vecteurs de test RFC 5869 verts
- [ ] `EncryptionKeyService` refuse de démarrer sans `ENCRYPTION_MASTER_KEY` valide
- [ ] Zéro accès au storage de fichiers modifié (aucune régression)
- [ ] `.env.example` mis à jour avec `ENCRYPTION_MASTER_KEY=`
- [ ] Revue de code par un second développeur (obligatoire pour le crypto)

---

### Sprint E-2 — Chiffrement des fichiers (2 semaines)

**Objectif :** Toutes les nouvelles uploads sont chiffrées. Les documents existants migrent en arrière-plan.

**Pourquoi maintenant :** C'est l'objectif central de cette roadmap. Les fondations du Sprint E-1 permettent de l'implémenter correctement.

#### Tâches

**E-2.1 — Migration Flyway `V67__create_file_encryption_keys.sql`**

```sql
-- Table de stockage des DEK chiffrés (un enregistrement par storageKey, cf. §5.7 — ADR-005)
CREATE TABLE file_encryption_keys (
    id              BIGSERIAL       PRIMARY KEY,
    storage_key     VARCHAR(500)    NOT NULL UNIQUE,
    document_id     BIGINT          REFERENCES documents(id) ON DELETE SET NULL, -- optionnel, pour jointures d'audit
    encrypted_dek   BYTEA           NOT NULL,   -- DEK wrappé avec KEK (AES-256-GCM)
    dek_iv          BYTEA           NOT NULL,   -- IV utilisé pour le wrapping (12 bytes)
    file_iv         BYTEA           NOT NULL,   -- IV utilisé pour le chiffrement fichier (12 bytes)
    kek_version     SMALLINT        NOT NULL DEFAULT 1,
    algorithm       VARCHAR(20)     NOT NULL DEFAULT 'AES-256-GCM',
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW(),
    rotated_at      TIMESTAMP,                 -- Date du dernier re-wrapping du DEK
    revoked_at      TIMESTAMP                  -- NULL = clé active, NOT NULL = crypto-shredded
);

-- Index pour les requêtes fréquentes
CREATE INDEX idx_fek_document_id   ON file_encryption_keys (document_id);
CREATE INDEX idx_fek_kek_version   ON file_encryption_keys (kek_version)
    WHERE revoked_at IS NULL;
CREATE INDEX idx_fek_revoked       ON file_encryption_keys (revoked_at)
    WHERE revoked_at IS NOT NULL;
```

**E-2.2 — Migration Flyway `V68__add_encryption_status_to_documents.sql`**

```sql
-- Suivi de l'état de chiffrement (nécessaire pour la migration des documents existants)
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS encryption_status VARCHAR(20)
        NOT NULL DEFAULT 'PLAIN'
        CHECK (encryption_status IN ('PLAIN', 'ENCRYPTING', 'ENCRYPTED', 'FAILED'));

-- Audit : ne pas perdre le storage_key original pendant la migration
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS legacy_storage_key VARCHAR(500);
```

**E-2.3 — Chiffrement transparent dans `LocalFileStorageService` / `MinioFileStorageService`**

Contrairement à la v1.0 (decorator `@Primary` avec signature `store(file, key, userId, documentId)`),
les signatures de `FileStorageService` ne changent **pas** (§5.7 / ADR-005). Le chiffrement est intégré
directement dans les deux implémentations existantes, via un helper partagé injecté
`FileEncryptionSupport` (nouveau, `com.kovixel.storage.crypto`) :

```java
// com.kovixel.storage.crypto.FileEncryptionSupport
@Component
@RequiredArgsConstructor
public class FileEncryptionSupport {

    private static final byte[] MAGIC = {0x4B, 0x4F, 0x56, 0x58}; // "KOVX"
    private static final short VERSION = 1;

    private final CryptoService cryptoService;
    private final EncryptionKeyService keyService;
    private final FileEncryptionKeyRepository fekRepo;

    /** Chiffre les octets et persiste les métadonnées de clé, indexées par storageKey. */
    public byte[] encrypt(byte[] plaintext, String storageKey) {
        byte[] dek    = cryptoService.generateKey();
        byte[] fileIv = cryptoService.generateIv();
        byte[] dekIv  = cryptoService.generateIv();
        try {
            byte[] ciphertext = cryptoService.encryptAesGcm(plaintext, dek, fileIv);
            byte[] kek        = keyService.deriveFileKek(storageKey);
            byte[] encDek     = cryptoService.encryptAesGcm(dek, kek, dekIv);
            Arrays.fill(kek, (byte) 0);

            fekRepo.save(FileEncryptionKey.builder()
                .storageKey(storageKey)
                .encryptedDek(encDek)
                .dekIv(dekIv)
                .fileIv(fileIv)
                .kekVersion(keyService.getCurrentKekVersion())
                .build());

            return buildEnvelope(fileIv, ciphertext);
        } finally {
            Arrays.fill(dek, (byte) 0);
        }
    }

    /** Déchiffre un flux d'octets préalablement chiffré par encrypt(). */
    public byte[] decrypt(byte[] envelope, String storageKey) {
        FileEncryptionKey rec = fekRepo.findByStorageKey(storageKey)
            .orElseThrow(() -> new KovixelException(ErrorCode.ENCRYPTION_KEY_NOT_FOUND));
        if (rec.getRevokedAt() != null) {
            throw new KovixelException(ErrorCode.FILE_PERMANENTLY_DELETED);
        }
        byte[] kek = keyService.deriveFileKek(storageKey, rec.getKekVersion());
        byte[] dek = cryptoService.decryptAesGcm(rec.getEncryptedDek(), kek, rec.getDekIv());
        Arrays.fill(kek, (byte) 0);
        try {
            EncryptedEnvelope parsed = parseEnvelope(envelope);
            return cryptoService.decryptAesGcm(parsed.ciphertext(), dek, parsed.fileIv());
        } finally {
            Arrays.fill(dek, (byte) 0);
        }
    }
}
```

`LocalFileStorageService.store()/storeBytes()` appellent `encrypt()` avant d'écrire sur disque ;
`retrieve()` appelle `decryptIfEncrypted()` après lecture. Idem pour `MinioFileStorageService`, en
amont/aval du `PutObjectArgs`/`GetObjectArgs`. **Aucun appelant de `FileStorageService` n'a besoin
d'être modifié** — c'est tout l'intérêt de l'ancrage par `storageKey` (§5.7).

**Correction découverte à l'implémentation (2026-07-22)** : pendant la fenêtre de migration, `retrieve()`
peut être appelé sur un fichier **encore en clair** (créé avant ce sprint). `decryptIfEncrypted()` ne
décide donc pas sur la présence d'une ligne `file_encryption_keys` (ambigu : absence = fichier legacy
*ou* métadonnées perdues), mais sur le contenu lui-même : si les 24 premiers octets ne portent pas le
magic number `KOVX`, les octets sont retournés tels quels (fichier legacy, pas encore migré). Si le
magic number est présent mais qu'aucune ligne `file_encryption_keys` n'existe (ou qu'elle est révoquée),
c'est une vraie erreur (métadonnées perdues / crypto-shredded) — `ENCRYPTION_KEY_NOT_FOUND` /
`FILE_PERMANENTLY_DELETED` sont levées sans ambiguïté. Un vrai PDF/image ne commence jamais par ces
4 octets précis, la détection est donc fiable.

**E-2.4 — Aucun changement requis dans `DocumentController`**

`getDocumentContent()` continue d'appeler `fileStorageService.retrieve(doc.getStorageKey())` sans
modification : le déchiffrement est déjà appliqué à l'intérieur de l'implémentation. Seule
`DocumentServiceImpl` doit être mise à jour pour faire progresser `encryption_status` quand un document
est créé/migré.

**E-2.5 — Job de migration des documents existants**

Nouveau service : `com.kovixel.storage.migration.EncryptionMigrationJob`

```java
@Component
@RequiredArgsConstructor
public class EncryptionMigrationJob {

    @Scheduled(fixedDelay = 60_000)  // Toutes les minutes
    @Transactional
    public void migrateBatch() {
        // Traiter 10 documents PLAIN à la fois pour limiter la charge
        List<Document> batch = documentRepo.findTop10ByEncryptionStatus("PLAIN");
        for (Document doc : batch) {
            try {
                doc.setEncryptionStatus("ENCRYPTING");
                documentRepo.save(doc);

                migrateDocument(doc);  // lit en clair, ré-écrit chiffré sous la même storageKey via store(),
                                        // conserve l'ancienne clé dans legacy_storage_key

                doc.setEncryptionStatus("ENCRYPTED");
                documentRepo.save(doc);

            } catch (Exception e) {
                log.error("Migration failed for doc {}", doc.getId(), e);
                doc.setEncryptionStatus("FAILED");
                documentRepo.save(doc);
            }
        }
    }
}
```

Comportement de `migrateDocument()` :
1. Lire le fichier en clair depuis le stockage existant (`legacy_storage_key` = ancienne `storageKey`)
2. Chiffrer via `FileEncryptionSupport.encrypt()` (transparent, déclenché par `store()`)
3. Écrire le fichier chiffré sous `{storageKey}.kovenc`
4. Mettre à jour `document.storageKey` vers la nouvelle clé
5. NE PAS supprimer le fichier original immédiatement — attendre validation

**E-2.6 — Validation et rollback**

- Endpoint admin : `GET /api/v1/admin/encryption/status` → rapport de migration
- Possibilité de lire `legacy_storage_key` si `ENCRYPTED` échoue
- Suppression des fichiers legacy après 7 jours de validation

**Critères de sortie Sprint E-2 (statut au 2026-07-22) :**
- [x] Tout nouveau document est chiffré AES-256-GCM à l'upload (transparent dans Local/MinioFileStorageService)
- [x] Déchiffrement transparent au download (aucun changement côté client, ni dans DocumentController)
- [x] Intégrité GCM vérifiée avant de servir tout octet (CryptoService, fail-secure)
- [x] Job de migration opérationnel avec rapport de statut (`EncryptionMigrationJob` + `GET /api/v1/admin/encryption/status`)
- [ ] 100% des documents en `ENCRYPTED` après migration complète — dépend du temps réel de tourne du job en environnement peuplé, non vérifiable en session de développement
- [x] Benchmark : overhead de chiffrement < 50ms pour un PDF de 10MB (test JUnit dédié, marge large avec AES-NI)
- [x] Tests d'intégration : upload → download → vérification contenu identique (`LocalFileStorageServiceTest`, `MinioFileStorageServiceTest`, `FileEncryptionSupportTest`, `EncryptionMigrationJobTest` — 24 tests)

**Non couvert par cette implémentation (E-2.6)** : suppression automatique des fichiers legacy après
7 jours de validation — dépend naturellement du cycle de vie complet du Sprint E-5, pas encore démarré.

---

### Sprint E-3 — Gestion et rotation des clés (2 semaines)

**Objectif :** Permettre la rotation du Master Key sans re-chiffrer les fichiers. Préparation à l'intégration KMS.

**Pourquoi maintenant :** Une roadmap de chiffrement sans rotation de clés est incomplète. Sans rotation, une clé compromise expose tous les documents chiffrés avec elle, pour toujours.

#### Tâches

**E-3.1 — Mécanisme de rotation du Master Key**

La rotation du MK suit ce processus :

```
1. Générer nouveau MK (MK_v2) via openssl rand -hex 32
2. Mettre kek-version: 2 dans la configuration
3. Démarrer EncryptionRotationJob (background)
4. Pour chaque file_encryption_keys WHERE kek_version = 1 :
   a. Dériver ancien KEK : HKDF(MK_v1, salt=SHA-256(storageKey), "kovixel-file-kek-v1")
   b. Déchiffrer eDEK → DEK (jamais écrit sur disque)
   c. Dériver nouveau KEK : HKDF(MK_v2, salt=SHA-256(storageKey), "kovixel-file-kek-v2")
   d. Re-chiffrer DEK → nouveau eDEK avec nouveau KEK
   e. UPDATE file_encryption_keys SET encrypted_dek=..., kek_version=2, rotated_at=NOW()
5. Une fois tous les enregistrements à version 2, révoquer MK_v1
```

**Contrainte critique** : pendant la rotation, les deux versions de MK doivent être disponibles simultanément. Utiliser une configuration dual-key :
```yaml
encryption:
  master-key: ${ENCRYPTION_MASTER_KEY_V2}   # Nouveau MK (actif)
  legacy-master-key: ${ENCRYPTION_MASTER_KEY_V1}  # Ancien MK (lecture seule, rotation)
  kek-version: 2
```

**E-3.2 — `EncryptionRotationJob.java`**

- Rotation par batch de 50 clés à la fois (éviter les timeouts)
- Idempotent : peut être interrompu et relancé sans corruption
- Observabilité : logs structurés, métriques Micrometer
- Notification admin à la fin : résumé (succès/échecs)

**E-3.3 — Endpoint de monitoring**

```
GET /api/v1/admin/encryption/rotation-status
→ { "kek_v1": 0, "kek_v2": 1542, "failed": 0, "completion": "100%" }
```

**E-3.4 — Préparation HashiCorp Vault / AWS KMS (Phase 2)**

Concevoir `EncryptionKeyService` avec une interface abstraite :
```java
public interface MasterKeyProvider {
    byte[] getMasterKey(int version);
    int getCurrentVersion();
}

@Profile("!vault")
class EnvVarMasterKeyProvider implements MasterKeyProvider { ... }

@Profile("vault")
class VaultMasterKeyProvider implements MasterKeyProvider { ... }
```

Cela permet de switcher vers Vault en changeant uniquement le profil Spring, sans toucher au code cryptographique.

**E-3.5 — Documentation opérationnelle de rotation**

Créer `docs/encryption/KEY_ROTATION.md` décrivant :
- Procédure étape par étape pour l'opérateur
- Comment générer un nouveau MK
- Comment configurer le dual-key pendant la transition
- Comment valider que la rotation est complète
- Comment révoquer l'ancien MK

**Critères de sortie Sprint E-3 (statut au 2026-07-22) :**
- [ ] Rotation du MK testée en environnement de staging — non applicable : pas d'environnement de staging à ce stade du projet (phase dev). Couvert par tests unitaires (round-trip re-wrapping réel avec deux Master Keys distincts) et de bout en bout (`EncryptionRotationJobTest`).
- [x] Aucun document inaccessible pendant la rotation (`EncryptionKeyService.deriveFileKek()` résout la version courante ET la version legacy)
- [x] `kek_version` correct pour 100% des clés après rotation (query `countByKekVersion`, vérifié dans `EncryptionRotationJobTest`)
- [x] `MasterKeyProvider` interface prête pour migration Vault (`EnvVarMasterKeyProvider` en place, `@Profile("!vault")` — un `VaultMasterKeyProvider` `@Profile("vault")` reste à écrire quand un vrai Vault sera disponible, cf. Phase 2)
- [ ] Documentation opérationnelle de rotation validée par un ops — rédigée (`kovixel/docs/encryption/KEY_ROTATION.md`), validation humaine encore à faire

**Note d'implémentation** : la v1.0 de ce sprint dérivait un KEK différent par version de MK en
gardant le **même** MK sous-jacent (simple namespace du contexte HKDF) — cela ne permettait pas une
vraie rotation. Corrigé lors de l'implémentation : `MasterKeyProvider.getMasterKey(version)` route
désormais vers la véritable clé (nouvelle ou legacy) selon la version demandée.

---

### Sprint E-4 — Chiffrement des métadonnées sensibles (1 semaine)

**Objectif :** Chiffrer les données sensibles stockées en base (noms de fichiers, secrets 2FA).

**Pourquoi maintenant :** Un attaquant qui exfiltre la base de données peut reconstruire un profil complet des utilisateurs à partir des métadonnées, même sans accéder aux fichiers eux-mêmes.

> **Addendum v1.1 (implémentation, 2026-07-22)** — Deux adaptations substantielles par rapport à la v1.0 :
> - **TOTP implémenté en premier** (avant les titres) : bug d'authentification (accès au générateur de
>   codes valides) &gt; fuite de nom de fichier en sévérité. Migration renumérotée : `V69` = TOTP,
>   `V70` = titres (au lieu de l'inverse en v1.0) — l'ordre des migrations suit l'ordre d'implémentation.
> - **Chiffrement du titre via `AttributeConverter` JPA** (Spring bean injecté), pas via un
>   `EncryptionMigrationJob`-style manuel : `documents.title` est écrit par ~8 services métier
>   différents (`ProcessingServiceImpl`, `OcrServiceImpl`, `PdfWatermarkServiceImpl`, etc.) — les
>   toucher tous un par un aurait répété le problème déjà résolu pour `FileStorageService` en E-2. Un
>   converter JPA intercepte transparentement `convertToDatabaseColumn`/`convertToEntityAttribute` à
>   chaque lecture/écriture, sans changement dans aucun de ces ~8 appelants (même philosophie que
>   l'ADR-005, appliquée via un mécanisme différent puisque `FileStorageService` n'est pas géré par JPA).
>   **Limite connue** : ce projet n'a ni base H2 embarquée ni Testcontainers (aucun `@DataJpaTest`
>   n'existe dans la suite actuelle) — la logique cryptographique du converter est testée en isolation
>   (sans Hibernate), mais le câblage Spring→Hibernate (injection du bean dans le converter géré par
>   JPA) n'a pas pu être vérifié de bout en bout dans cette session. **Recommandé avant mise en
>   production** : un test manuel (créer un document, relire son titre après redémarrage de l'app).

#### Tâches

**E-4.1 — Chiffrement du secret TOTP**

Le `totp_secret` dans `two_factor_auth` donne accès à l'authentificateur d'un utilisateur. S'il est compromis, un attaquant peut générer des codes TOTP valides.

Chiffrement : AES-256-GCM avec clé dérivée du MK + `user_id` (même mécanique KEK — `userId` est
toujours disponible et non-null dans `TwoFactorService`, contrairement à `storageKey` pour les
fichiers § ADR-005 ; l'ancrage par utilisateur du plan v1.0 s'applique donc ici sans adaptation).

Migration Flyway `V69__encrypt_totp_secrets.sql` :
```sql
ALTER TABLE two_factor_auth
    ADD COLUMN IF NOT EXISTS encrypted_secret     BYTEA,
    ADD COLUMN IF NOT EXISTS secret_iv            BYTEA,
    ADD COLUMN IF NOT EXISTS secret_kek_version    SMALLINT NOT NULL DEFAULT 1;

ALTER TABLE two_factor_auth ALTER COLUMN totp_secret DROP NOT NULL;
```

**Correction v1.1** : `totp_secret` n'est **pas** droppé dans cette migration (contrairement à la
v1.0) — conservé nullable, en lecture seule, pour les éventuelles lignes déjà en base (aucun
utilisateur réel actuellement, mais un `DROP COLUMN` est irréversible et ce projet n'a aucun moyen
de vérifier l'état réel de la table de production avant de le faire ; cf. `legacy_storage_key` en
E-2 pour le même raisonnement). `TwoFactorService` migre paresseusement à la lecture (pas de job
séparé — table à faible cardinalité, une ligne par utilisateur) : si `encrypted_secret` est absent
et `totp_secret` présent, le secret est chiffré et sauvegardé à la volée, puis `totp_secret` est
effacé. Une migration de suppression de colonne pourra suivre une fois validé que plus aucune ligne
ne porte de `totp_secret` non-null.

**E-4.2 — Chiffrement du nom de fichier**

Le nom du fichier révèle des informations sur son contenu (ex: `rapport-médical-2025.pdf`, `contrat-licenciement.docx`).

Approche :
- Chiffrer `title` dans `documents` avec une clé dérivée du MK (dérivation **globale**, pas par
  utilisateur/document — cf. addendum ci-dessus : `title` est écrit par ~8 services sans accès
  garanti à un `userId`, ex. documents invités. Contrairement au DEK des fichiers, il n'y a pas de
  besoin de révocation indépendante par titre — la confidentialité vient de l'IV aléatoire par
  chiffrement, pas de l'unicité de la clé).
- Stocker le hash SHA-256 du nom pour une future recherche exacte. **Aucune fonctionnalité de
  recherche par titre n'existe actuellement dans l'application** (vérifié : aucun endpoint, aucune
  méthode de repository) — `title_hash` est ajouté pour ne pas fermer la porte à une future feature,
  mais ce sprint n'ajoute pas de nouvel endpoint de recherche (rien à préserver).
- `title` (VARCHAR) reste en base, mais n'est plus renseigné par le code applicatif après ce sprint —
  seul `encrypted_title`/`title_iv` le sont, via le converter JPA (voir E-4.2, code).

Migration Flyway `V70__encrypt_document_titles.sql` :
```sql
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS encrypted_title BYTEA,
    ADD COLUMN IF NOT EXISTS title_hash      VARCHAR(64);

ALTER TABLE documents ALTER COLUMN title DROP NOT NULL;
```

**Pas de colonne `title_iv`/`title_kek_version` séparée** (contrairement au plan initial) : un
`AttributeConverter` JPA (voir code) n'a accès qu'à une seule colonne, pas aux colonnes sœurs de
l'entité — IV et version du Master Key sont donc embarqués directement dans `encrypted_title`
(format `[2 octets version][12 octets IV][ciphertext+tag]`), pas dans des colonnes à part.

**E-4.3 — Chiffrement des données PII utilisateur (optionnel à ce sprint, non fait)**

Analyser quelles colonnes de `kovixel_users` méritent le chiffrement :
- `email` : identifiant de login, difficile à chiffrer (used in queries). Envisager le hachage pour recherche + chiffrement du plaintext.
- `first_name`, `last_name` : chiffrement simple, récupéré uniquement à l'affichage.
- `provider_id` : identifiant OAuth externe, peu sensible.

**Critères de sortie Sprint E-4 (statut au 2026-07-22) :**
- [x] Secrets TOTP chiffrés en base (nouveaux à l'enrôlement, existants migrés paresseusement à la lecture)
- [x] Aucune régression sur la 2FA (`TwoFactorServiceTest` étendu, round-trip chiffré + migration paresseuse)
- [ ] Noms de fichiers chiffrés en base — implémenté (converter JPA) mais câblage Spring/Hibernate non vérifié de bout en bout (pas d'infra `@DataJpaTest` dans ce projet, cf. addendum) ; recommandé : test manuel avant prod
- [ ] Recherche par nom de fichier fonctionnelle via `title_hash` — non applicable, aucune recherche par titre n'existe dans l'application (cf. E-4.2)

---

### Sprint E-5 — Cycle de vie des fichiers & Crypto-shredding (1 semaine)

**Objectif :** Étendre le cycle de vie **existant** pour le différencier par plan tarifaire. Garantir le droit à l'effacement RGPD via crypto-shredding.

**Pourquoi maintenant :** SmallPDF et ilovePDF en font un argument marketing central. C'est aussi une exigence RGPD (minimisation des données, Art. 5.1.e).

> **Correction v1.1** : contrairement à ce que dit le §2.2 de la v1.0, un cycle de vie **existe déjà** :
> `Document.expiresAt` (ajouté par `V52__add_ownership_and_public_id.sql`), `com.kovixel.common.retention.RetentionPolicy`
> (2h pour les documents invités, 30 jours pour les documents de compte, **uniforme**, pas encore différencié
> par plan) et `com.kovixel.document.scheduler.DocumentCleanupJob` (`@Scheduled(fixedDelay=3_600_000)`).
> Ce sprint **étend** `RetentionPolicy` pour lire le plan de l'utilisateur au lieu de la constante uniforme,
> et **ajoute le crypto-shredding** dans `DocumentCleanupJob` — il ne recrée pas de système parallèle.

#### Tâches

**E-5.1 — Politique de rétention par plan**

| Plan | Rétention après upload | Rétention après dernière accès |
|------|----------------------|-------------------------------|
| FREE (invité) | 2 heures *(inchangé, déjà en place)* | 2 heures |
| FREE (compte) | 24 heures | 24 heures |
| PRO / PRO+ | 30 jours *(inchangé, déjà en place)* | 90 jours |
| ÉQUIPE / ENTREPRISES | 365 jours | Configurable (1-730 jours) |

**E-5.2 — Migration Flyway `V71__add_file_lifecycle_extensions.sql`**

```sql
-- expires_at existe déjà (V52) — on ajoute seulement les colonnes manquantes
ALTER TABLE documents
    ADD COLUMN IF NOT EXISTS last_accessed_at TIMESTAMP,   -- Dernier accès (preview/download)
    ADD COLUMN IF NOT EXISTS deletion_scheduled_at TIMESTAMP; -- Date de suppression programmée
```

**E-5.3 — Extension de `RetentionPolicy` / `FileLifecycleService.java`**

Remplacer la constante uniforme de `RetentionPolicy` par un calcul basé sur `user.getPlan()` (et le
statut invité/compte déjà géré). Calcul de `expires_at` à l'upload selon le plan utilisateur.

**E-5.4 — Crypto-shredding intégré à `DocumentCleanupJob.java`** — pas de nouveau job planifié

Ajouter l'étape de révocation des clés **dans** `DocumentCleanupJob` existant (`fixedDelay=3_600_000`),
avant sa logique de suppression actuelle, plutôt que créer un `CryptoShredJob` séparé qui dupliquerait
la sélection des documents expirés :

```java
// Ajout dans com.kovixel.document.scheduler.DocumentCleanupJob
public void shredExpiredFiles() {

    // 1. CRYPTO-SHREDDING : révoquer les clés des documents expirés (par storageKey)
    //    Les fichiers physiques deviennent illisibles immédiatement
    int revoked = fekRepo.revokeExpiredKeys(LocalDateTime.now());
    log.info("Crypto-shredded {} file keys", revoked);

    // 2. SUPPRESSION PHYSIQUE : supprimer les fichiers chiffrés
    //    (déjà illisibles depuis l'étape 1, la suppression est une bonne pratique complémentaire)
    //    On attend 48h après révocation avant suppression physique (marge de sécurité)
    List<Document> toDelete = documentRepo.findPhysicallyDeletable(
        LocalDateTime.now().minusHours(48)
    );
    for (Document doc : toDelete) {
        fileStorage.delete(doc.getStorageKey());
        doc.setEncryptionStatus("DELETED");
        documentRepo.save(doc);
    }

    // 3. LOG DE CONFORMITÉ : traçabilité pour audit RGPD
    auditLog.logFileDeletion(revoked, toDelete.size());
}
```

**E-5.5 — Suppression manuelle par l'utilisateur (déjà implémentée)**

Mettre à jour `DocumentService.delete()` :
1. Marquer `revoked_at = NOW()` dans `document_encryption_keys` → **crypto-shredding immédiat**
2. Supprimer le fichier physique (best effort)
3. Logger l'opération dans `file_access_events`
4. Envoyer confirmation email optionnelle

**E-5.6 — UI : affichage de la date d'expiration**

- Ajouter `expiresAt` dans `DocumentResponse`
- Afficher dans l'onglet "Infos" de `kov-document-detail`
- Badge d'alerte si expiration dans moins de 24h

**Critères de sortie Sprint E-5 (statut au 2026-07-23) :**
- [x] Documents FREE expirés après 24h (`RetentionPolicyTest`, `DocumentLifecycleListenerTest`)
- [x] Crypto-shredding : clé révoquée → fichier inaccessible immédiatement (`decryptIfEncrypted` lève `FILE_PERMANENTLY_DELETED` dès `revoked_at` non nul, cf. Sprint E-2)
- [x] Suppression physique effective 48h après révocation (`DocumentCleanupJob`, délai configurable `kovixel.encryption.physical-deletion-delay-hours`)
- [x] Log de conformité RGPD pour chaque destruction de clé (log structuré INFO à chaque lot — un vrai registre persistant relève de l'audit trail du Sprint E-6, pas encore démarré)
- [x] `expiresAt` visible dans l'interface utilisateur (`DocumentResponse.expiresAt`, onglet Infos + badge "Expire bientôt" < 24h dans `kov-document-detail`)

**Adaptations découvertes à l'implémentation (2026-07-23)** :
- **`RetentionPolicy.expiresAt(Long)` ne peut pas être étendue in situ** : ~14 services créent des
  `Document` en appelant cette méthode statique avec seulement un `userId` (jamais l'objet `User`
  complet), donc sans connaître le plan à cet endroit. Plutôt que de toucher ces ~14 call sites
  (même risque que pour le stockage fichier, cf. ADR-005), la différenciation par plan est appliquée
  de façon centralisée par `DocumentLifecycleListener` (`@PrePersist`, bean Spring dans
  `@EntityListeners` — même mécanisme que `DocumentTitleConverter` en Sprint E-4.2), qui **écrase**
  systématiquement la valeur uniforme historique. Les appels existants à
  `RetentionPolicy.expiresAt(userId)` deviennent donc sans effet (dépréciés, non retirés — nettoyage
  sûr mais non urgent).
- **"Rétention après dernier accès"** implémentée de façon "glissante" : chaque accès réel au contenu
  (`DocumentController.getDocumentContent()` → `DocumentService.recordAccess()`) repousse
  `expiresAt` à `max(expiresAt actuel, maintenant + accessRetention(plan))`, sans jamais l'écourter.
- **TEAM/ENTERPRISE "configurable 1-730 jours"** : aucune UI/API de configuration par organisation
  n'a été construite dans ce sprint (hors périmètre chiffrement) — valeur par défaut fixée au
  maximum de la plage (365j upload / 730j accès), le choix le plus généreux et le moins risqué.
- **Suppression manuelle (E-5.5)** : `DocumentServiceImpl.deleteDocument()` révoque désormais la clé
  de chiffrement (crypto-shredding immédiat) **avant** la tentative de suppression physique — défense
  en profondeur si la suppression physique échoue partiellement.

---

### Sprint E-6 — Audit trail des opérations fichiers (1 semaine)

**Objectif :** Tracer qui a accédé à quel fichier, quand, depuis où. Complément indispensable à tout système de chiffrement.

**Pourquoi maintenant :** Le chiffrement protège les fichiers non autorisés. L'audit trail protège contre les accès autorisés abusifs et répond aux exigences RGPD Art. 30 (registre des traitements).

> **Correction v1.1 (2026-07-23)** — comme pour E-2, il n'existe pas de point d'upload central : ~20
> services appellent `FileStorageService.store()/storeBytes()` directement, qui ne reçoivent que la
> `storageKey` (pas `documentId`/`userId`). Contrairement au chiffrement (purement technique), l'audit
> a besoin de contexte métier (qui, quel document) — ce contexte n'existe que dans `DocumentController`
> (`DOWNLOAD`/`PREVIEW`) et `DocumentServiceImpl` (`DELETE`). Adaptations :
> - `file_access_events` gagne une colonne `storage_key` (nullable) en plus de `document_id`/`user_id`,
>   pour les événements où seul le premier est connu (`UPLOAD`, `DECRYPT_FAIL` bas niveau).
> - `UPLOAD` est tracé depuis `FileEncryptionSupport.encrypt()` (seul point réellement centralisé pour
>   tous les uploads) — `storage_key` renseigné, `document_id`/`user_id` toujours `NULL`. Visibilité
>   partielle mais automatique, sans toucher aux ~20 services.
> - `KEY_ROTATED` reste dans l'énumération pour fidélité au schéma mais n'est **pas** instrumenté dans
>   `EncryptionRotationJob` : une rotation peut concerner des milliers de clés, et journaliser un
>   événement par clé rotée serait du bruit sans valeur d'audit réelle (ce n'est pas un "accès").
> - Dernière migration réelle au 2026-07-23 : V71 → cette migration reste **V72** comme prévu par le
>   plan d'origine (aucune dérive numérique cette fois, contrairement aux sprints précédents).

#### Tâches

**E-6.1 — Migration Flyway `V72__create_file_access_events.sql`**

```sql
CREATE TYPE file_action AS ENUM (
    'UPLOAD',
    'DOWNLOAD',
    'PREVIEW',
    'DELETE',
    'CRYPTO_SHRED',
    'DECRYPT_FAIL',   -- Tentative de déchiffrement échouée (intégrité compromise ?)
    'KEY_ROTATED'
);

CREATE TABLE file_access_events (
    id              BIGSERIAL       PRIMARY KEY,
    document_id     BIGINT          REFERENCES documents(id) ON DELETE SET NULL,
    user_id         BIGINT          REFERENCES kovixel_users(id) ON DELETE SET NULL,
    action          file_action     NOT NULL,
    ip_address      VARCHAR(45),
    user_agent      VARCHAR(500),
    bytes_served    BIGINT,          -- Pour DOWNLOAD/PREVIEW
    duration_ms     INTEGER,         -- Durée de l'opération
    success         BOOLEAN         NOT NULL DEFAULT TRUE,
    error_code      VARCHAR(50),     -- Si success = false
    created_at      TIMESTAMP       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_fae_document_id  ON file_access_events (document_id, created_at DESC);
CREATE INDEX idx_fae_user_id      ON file_access_events (user_id, created_at DESC);
CREATE INDEX idx_fae_created_at   ON file_access_events (created_at DESC);
CREATE INDEX idx_fae_action       ON file_access_events (action, created_at DESC);

-- Rétention : 90 jours (purge automatique via job)
```

**E-6.2 — `FileAuditService.java`**

Pattern identique à `AuthEventService` (async, non-bloquant). **Correction v1.1** : `processingExecutor`
(`com.kovixel.common.config.AsyncConfig`) est déjà partagé par `AuthEventService`, `EmailService`,
`PlatformAdminAuditService`, `UsageServiceImpl`, `ProcessingOrchestrator` et `ImageConvertStrategy` — un
volume élevé d'écritures d'audit fichier (potentiellement à chaque `store()`/`retrieve()`) risque de
saturer ce pool partagé. Utiliser un exécuteur dédié `fileAuditExecutor` (core=2, max=4, queue=500) :

```java
@Async("fileAuditExecutor")
public void log(FileAccessEvent event) {
    // Enregistrement non-bloquant — jamais d'exception qui remonte à l'appelant
    try { fileAccessEventRepo.save(event); }
    catch (Exception e) { log.warn("Audit log failed for doc {}", event.getDocumentId(), e); }
}
```

**E-6.3 — Instrumentation de `EncryptedFileStorageService`**

Ajouter des appels à `FileAuditService` dans :
- `store()` → `UPLOAD`
- `retrieve()` → `DOWNLOAD` ou `PREVIEW` (selon le paramètre `attachment`)
- `delete()` → `DELETE`
- Catch de `AEADBadTagException` → `DECRYPT_FAIL` (alerte critique : intégrité compromise)
- `revokeKey()` → `CRYPTO_SHRED`

**E-6.4 — Endpoint d'historique pour l'utilisateur**

```
GET /api/v1/documents/{id}/access-log
→ Derniers 50 accès à ce document (user voit seulement ses propres accès)
```

**E-6.5 — Alerte sur `DECRYPT_FAIL`**

Une erreur d'authentification GCM (`AEADBadTagException`) peut indiquer :
- Corruption du fichier (incident disque)
- Modification malveillante du fichier (attaque)

Dans les deux cas, c'est critique. Implémenter :
- Log de sévérité `ERROR` immédiat
- Notification admin par email
- Mise en quarantaine du document (`status = 'CORRUPTED'`)

**Critères de sortie Sprint E-6 :**
- [x] Chaque accès fichier tracé dans `file_access_events` (UPLOAD, DOWNLOAD, PREVIEW, CRYPTO_SHRED, DECRYPT_FAIL)
- [~] `DECRYPT_FAIL` déclenche une mise en quarantaine (`status = 'CORRUPTED'`) — pas d'alerte email admin (non implémentée, voir correction ci-dessous)
- [x] Endpoint d'historique disponible dans l'API (`GET /api/v1/documents/{id}/access-log`)
- [x] Rétention 90 jours avec purge automatique (`FileAccessEventPurgeJob`, configurable via `kovixel.encryption.audit-retention-days`)
- [x] L'audit lui-même ne bloque jamais une requête (`@Async("fileAuditExecutor")`, exceptions avalées et loggées en warn)

**Correction v1.1 (implémentation réelle) :**
- Pas de notification email admin sur `DECRYPT_FAIL` — seule la mise en quarantaine (`markCorrupted`) est implémentée. La roadmap v1.0 prévoyait "notification admin par email" ; jugé hors scope pour cette phase (pas d'infra d'alerting mail en place), documenté comme dette connue.
- `KEY_ROTATED` existe dans l'enum `file_action` mais n'est volontairement pas instrumenté (réservé pour une future intégration avec `EncryptionRotationJob`).
- L'événement `UPLOAD` est tracé uniquement depuis `FileEncryptionSupport.encrypt()` (storageKey uniquement, sans document_id/user_id) car c'est le seul point de passage universel — cohérent avec la contrainte ADR-005 (pas de point d'upload central).
- La mise en quarantaine (`markCorrupted`) et le DECRYPT_FAIL audit ne sont instrumentés que sur le chemin `DocumentController.getDocumentContent()` (téléchargement/aperçu), pas sur les autres appelants de `FileStorageService` — le log DECRYPT_FAIL lui-même reste universel car loggé depuis `FileEncryptionSupport.decryptIfEncrypted()`.
- Suite de tests complète (`mvn clean test`) : 0 régression.

---

### Sprint E-7 — Durcissement infrastructure (2 semaines)

**Objectif :** Chiffrement au niveau infrastructure (TLS, MinIO SSE, PostgreSQL, Redis) pour une défense en profondeur.

**Pourquoi maintenant :** Les sprints E-1 à E-6 couvrent le chiffrement applicatif. Ce sprint ajoute les couches infrastructure — si l'une des couches est contournée, les autres tiennent.

#### Tâches

**E-7.1 — TLS et HSTS**

Vérifications et configurations :
- Certificat TLS 1.2+ obligatoire en production (Let's Encrypt ou certificat commercial)
- Désactiver TLS 1.0 et 1.1 côté reverse proxy (Nginx/Traefik)
- Ajouter `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`
- Redirection automatique HTTP → HTTPS (301)
- Spring Security : `http.requiresChannel().anyRequest().requiresSecure()`

**E-7.2 — MinIO Server-Side Encryption (SSE)**

Activer MinIO SSE-S3 (chiffrement côté MinIO, clés gérées par MinIO) **en complément** du chiffrement applicatif du Sprint E-2 :

```java
// Dans MinioFileStorageService, lors du put object :
PutObjectArgs.builder()
    .bucket(bucket)
    .object(key)
    .stream(stream, size, -1)
    .serverSideEncryption(ServerSideEncryption.atRest())  // SSE-S3
    .build()
```

Configuration MinIO : activer `MINIO_KMS_AUTO_ENCRYPTION=on`

> **Principe** : le chiffrement applicatif (AES-256-GCM par Kovixel) est la couche primaire. MinIO SSE est défense en profondeur — même si MinIO divulguait les clés SSE, les fichiers restent illisibles sans les DEK applicatifs.

**E-7.3 — PostgreSQL**

- Activer `pgcrypto` (si pas déjà fait via V2 pgvector) : `CREATE EXTENSION pgcrypto;`
- Chiffrement du disque PostgreSQL : recommander LUKS (Linux Unified Key Setup) à l'OS level
- Connexion SSL obligatoire : `spring.datasource.url=jdbc:postgresql://...?ssl=true&sslmode=require`
- Certificat SSL PostgreSQL côté serveur
- Rotation du mot de passe PostgreSQL (recommandation : mensuelle)

**E-7.4 — Redis**

```yaml
spring:
  data:
    redis:
      password: ${REDIS_PASSWORD}        # Mot de passe fort
      ssl:
        enabled: true                    # TLS vers Redis
      lettuce:
        pool:
          max-active: 8
```

Configuration Redis (`redis.conf`) :
```
requirepass <strong-password>
tls-port 6380
tls-cert-file /etc/redis/tls/redis.crt
tls-key-file /etc/redis/tls/redis.key
tls-auth-clients yes
```

**E-7.5 — Secrets management**

Étapes graduelles :
- **Immédiat** : Auditer que `.env` n'est jamais commité (`.gitignore`, `git-secrets` pre-commit hook)
- **Court terme** : Docker Secrets ou Kubernetes Secrets pour les déploiements conteneurisés
- **Moyen terme** : HashiCorp Vault ou AWS Secrets Manager pour le MK, les credentials DB, les API keys

**E-7.6 — Headers de sécurité HTTP**

Ajouter dans Spring Security :
```java
http.headers(headers -> headers
    .contentSecurityPolicy(csp -> csp.policyDirectives("default-src 'self'"))
    .referrerPolicy(ref -> ref.policy(ReferrerPolicyHeaderWriter.ReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN))
    .permissionsPolicy(pp -> pp.policy("camera=(), microphone=(), geolocation=()"))
    .frameOptions(frame -> frame.deny())
);
```

**Critères de sortie Sprint E-7 :**
- [~] TLS 1.2+ enforced, HSTS configuré — HSTS applicatif fait (`SecurityConfig`), terminaison
  TLS elle-même externe au repo (Cloudflare, aucun nginx/Traefik versionné ici) : runbook
  ops rédigé (`docs/encryption/INFRASTRUCTURE_HARDENING.md`), pas vérifiable en code.
- [~] MinIO SSE-S3 actif en production — support code fait, **désactivé par défaut**
  (`storage.minio.sse-enabled`) : nécessite `MINIO_KMS_AUTO_ENCRYPTION=on` côté serveur,
  absent de `docker-compose.yml` actuel. Ne pas activer sans ce prérequis (uploads casseraient).
- [ ] PostgreSQL sur connexion SSL — nécessite un certificat serveur non provisionné dans ce
  repo ; activer `?ssl=true&sslmode=require` sans lui casserait toute connexion. Procédure
  documentée dans le runbook. `pgcrypto` activé (V73) par anticipation, non bloquant.
- [ ] Redis authentifié + chiffré — authentifié (`--requirepass`, déjà en place), **pas
  chiffré** (aucun `redis.conf`/certs TLS dans ce repo). Procédure documentée dans le runbook.
- [x] Aucun secret dans le code ou `.env` commité — vérifié (`.gitignore` exclut `.env`/`*.env`
  racine et `kovixel/`, seuls des `.env.example` avec placeholders sont trackés).
- [ ] Score A+ sur SSL Labs — dépend de la terminaison TLS externe (voir ci-dessus), non
  testable depuis ce repo en phase développement.
- [x] Headers sécurité applicatifs : HSTS, CSP, `X-Frame-Options: DENY`, `Referrer-Policy`,
  `Permissions-Policy`, `X-Permitted-Cross-Domain-Policies` (`SecurityConfig.java`). Score
  securityheaders.com non mesurable sans déploiement public réel, mais le contenu de chaque
  en-tête est couvert par test unitaire (`SecurityHeadersTest`).

**Correction v1.1 (implémentation réelle)** : ce sprint est le premier de la roadmap à mélanger
code applicatif et infrastructure pure (TLS, certificats PostgreSQL/Redis, KMS MinIO). Contrairement
aux Sprints E-1 à E-6 (100% applicatifs, testables sans dépendance externe), une partie de E-7
dépend d'un état serveur que ce repo — en phase développement, `docker-compose.yml` sans aucun
TLS configuré — ne peut ni fournir ni vérifier. Plutôt que d'écrire du code qui casserait la
stack actuelle une fois activé sans ses prérequis (ex. forcer `sslmode=require` sans certificat
serveur PostgreSQL), ces items sont documentés en détail dans
`docs/encryption/INFRASTRUCTURE_HARDENING.md` avec la procédure exacte à suivre côté ops avant
la mise en production. Voir aussi le §"Pourquoi ces items ne sont pas 'juste implémentés'" de ce
document.
**Vérification** : `SecurityHeadersTest` (7 tests, valeurs exactes des writers Spring Security)
et `MinioFileStorageServiceTest` (2 tests SSE ajoutés) verts ; suite complète re-vérifiée sans
régression. Une tentative de test d'intégration à filtres réels (`@WebMvcTest` avec
`addFilters = true`) a été faite pour vérifier le câblage bout en bout dans la vraie chaîne de
filtres, mais échoue au chargement de contexte pour une raison indépendante des en-têtes
(`@EnableJpaAuditing` sur `KovixelApplication` déclenche une instanciation prématurée de
`jpaMappingContext` dans ce slice de test) — limite documentée dans `SecurityHeadersTest`,
recommandation de vérification manuelle (`curl -I`) avant un déploiement prod.

---

### Sprint E-8 — Conformité & Certification (continu)

**Objectif :** Documenter et faire auditer les mesures techniques pour obtenir des certifications de confiance (ISO 27001, SOC 2 Type II).

#### Tâches prioritaires

**E-8.1 — Politique de sécurité des données (PSSI)**

Rédiger un document PSSI couvrant :
- Algorithmes autorisés (liste blanche : AES-256-GCM, HS256, HKDF-SHA256, BCrypt-12)
- Durées de vie des clés (MK : 1 an max, KEK : dérivée à la demande, DEK : durée vie document)
- Processus de rotation obligatoire
- Gestion des incidents (procédure si clé compromise)

**E-8.2 — Privacy by Design (RGPD Art. 25)**

Documenter l'analyse d'impact (DPIA — Data Protection Impact Assessment) :
- Données collectées et base légale
- Durées de rétention par type de données et par plan
- Mesures techniques (chiffrement, pseudo-anonymisation)
- Droits des personnes concernées et procédures (accès, rectification, effacement)

**E-8.3 — Registre des traitements (RGPD Art. 30)**

Documenter chaque traitement :
- Traitement des fichiers uploadés (base légale : contrat / consentement)
- Analyse IA des documents (base légale : consentement explicite)
- Audit logs (base légale : intérêt légitime / obligation légale)

**E-8.4 — Pentesting**

Avant toute certification :
- Pentest externe (boîte noire) par un prestataire certifié
- Pentest cryptographique spécifique (vérification des implémentations)
- Scan des dépendances : `mvn dependency-check:check` (OWASP)
- Revue de code sécurité par un expert externe

**E-8.5 — Mention de sécurité dans l'UI**

Ajouter à la page de politique de confidentialité et sur la page de landing :
- "Vos fichiers sont chiffrés avec AES-256-GCM"
- "Suppression automatique après [N] heures/jours selon votre plan"
- "Clés cryptographiques uniques par document"
- "Droit à l'effacement garanti par crypto-shredding"

Ces engagements deviennent des arguments commerciaux différenciants.

**Critères de sortie Sprint E-8 :**
- [x] E-8.1 — PSSI rédigée : `kovixel-docs/src/compliance/PSSI_POLITIQUE_SECURITE_DONNEES.md`
  (algorithmes autorisés, durées de vie des clés, rotation, gestion d'incident clé compromise).
- [x] E-8.2 — DPIA rédigée : `kovixel-docs/src/compliance/DPIA_ANALYSE_IMPACT_VIE_PRIVEE.md`
  (données collectées/base légale, rétention par plan, mesures techniques, droits des personnes,
  risques résiduels).
- [x] E-8.3 — Registre des traitements rédigé :
  `kovixel-docs/src/compliance/REGISTRE_TRAITEMENTS.md` (5 fiches : fichiers uploadés, analyse IA,
  audit, compte/authentification, anti-fraude).
- [~] E-8.4 — Pentesting : `mvn dependency-check:check` (OWASP) configuré (profil Maven
  `security-scan`, non actif par défaut pour ne pas ralentir les builds quotidiens/CI — cf.
  commentaire dans `pom.xml`), **pas exécuté** dans cette session (téléchargement de la base NVD,
  plusieurs minutes, accès réseau — à lancer avant un audit réel). Pentest externe boîte noire,
  pentest cryptographique et revue de code par un expert externe : nécessitent un prestataire
  humain, **hors du périmètre de ce qui peut être implémenté en code** — à budgéter séparément
  avant toute démarche de certification.
- [x] E-8.5 — Mentions de sécurité UI : `trust-section.component.ts` (landing page) mis à jour
  avec "Chiffrement AES-256-GCM au repos", "crypto-shredding", clé unique par document ; badge
  `✓ AES-256-GCM` ajouté au bandeau de certifications.

**Correction v1.1 (implémentation réelle)** : contrairement aux Sprints E-1 à E-7 (code), E-8 est
majoritairement documentaire par nature ("Objectif : documenter et faire auditer" — le titre du
sprint lui-même l'indique). Les livrables E-8.1 à E-8.3 sont des documents de conformité complets,
rédigés à partir de l'implémentation réelle des Sprints E-1 à E-7 (pas de contenu générique). E-8.4
est fractionné : la partie automatisable (scan de dépendances) est configurée mais son exécution
réelle et les parties nécessitant un humain externe (pentest, revue de code) restent explicitement
hors de portée d'une implémentation par agent — c'est un point d'action pour l'équipe, pas une
tâche de code inachevée.
**Vérification** : suite complète Maven re-vérifiée sans régression après le changement de
`pom.xml` (profil `security-scan` non actif par défaut, donc sans impact sur `mvn test`/`compile`
habituels) ; `trust-section.component.ts` compile sans erreur (build Angular dev propre, aucune
erreur console) — la vérification visuelle du rendu réel (section différée `@defer (on viewport)`)
n'a pas pu être faite via le pane de prévisualisation (limite d'outil : l'IntersectionObserver ne
se déclenche pas quand le pane n'est pas réellement composité à l'écran), recommandé de vérifier
visuellement au prochain accès à un environnement de dev réel.

**Roadmap chiffrement (E-1 à E-8) considérée complète** à l'issue de ce sprint, sous réserve des
items explicitement documentés comme dette connue ou nécessitant une action humaine externe (liste
complète dans les sections "Correction v1.1" de chaque sprint et dans les critères de sortie
ci-dessus).

---

## 7. Migrations Flyway

Récapitulatif complet des migrations prévues par cette roadmap :

| Version | Fichier | Sprint | Description |
|---------|---------|--------|-------------|
| V67 | `V67__create_file_encryption_keys.sql` | E-2 | Table des DEK chiffrés (indexée par `storage_key`) |
| V68 | `V68__add_encryption_status_to_documents.sql` | E-2 | Suivi de migration |
| V69 | `V69__encrypt_totp_secrets.sql` | E-4 | Secrets 2FA chiffrés |
| V70 | `V70__encrypt_document_titles.sql` | E-4 | Titres chiffrés |
| V71 | `V71__add_file_lifecycle_extensions.sql` | E-5 | `last_accessed_at`, `deletion_scheduled_at` (`expires_at` existe déjà depuis V52) |
| V72 | `V72__create_file_access_events.sql` | E-6 | Audit trail fichiers |

**Convention de validation** : toutes ces migrations doivent passer `flyway.validateOnMigrate=true` en CI avant merge. **Numérotation révisée le 2026-07-22** : la dernière migration existante au démarrage de l'implémentation est `V66__add_organization_creation_enabled.sql` ; vérifier ce numéro avant de créer `V67` si d'autres migrations sont arrivées entre-temps.

---

## 8. Décisions d'architecture (ADR)

### ADR-001 : Envelope Encryption vs chiffrement direct

**Décision :** Utiliser l'envelope encryption (DEK + KEK) plutôt que de chiffrer directement les fichiers avec le Master Key.

**Contexte :** On aurait pu chiffrer chaque fichier directement avec une clé dérivée du MK. Plus simple, moins de tables.

**Raisons du choix de l'envelope encryption :**
- **Rotation sans re-chiffrement fichiers** : seuls les eDEK (quelques dizaines d'octets) sont re-chiffrés. Pas les fichiers eux-mêmes (potentiellement des Go de données).
- **Révocation par document** : supprimer un eDEK rend un fichier spécifique illisible sans toucher aux autres. Impossible avec une clé partagée.
- **Standard industrie** : c'est le modèle de AWS KMS, GCP Cloud KMS, Azure Key Vault, HashiCorp Vault. La migration vers un KMS externe ne nécessite que de changer `MasterKeyProvider`.
- **Séparation des secrets** : la base de données et le stockage fichier contiennent des informations différentes. Les deux sont nécessaires pour décrypter. Un attaquant qui compromet l'un ne peut pas décrypter sans l'autre.

### ADR-002 : AES-256-GCM plutôt que AES-256-CBC + HMAC

**Décision :** AES-256-GCM pour tout chiffrement symétrique.

**Contexte :** AES-256-CBC est plus ancien et largement documenté. CBC + HMAC séparé offre une confidentialité + intégrité mais nécessite d'orchestrer deux opérations.

**Raisons :**
- GCM est AEAD : confidentialité et intégrité en un seul pass, impossible d'oublier le MAC.
- Pas d'oracle de padding (CBC est vulnérable à POODLE, Lucky 13 si mal implémenté).
- IV de 96 bits fixe recommandé par NIST pour GCM (pas de padding required).
- Natif Java depuis JDK 8, pas de bibliothèque externe.

**Risque** : le compteur GCM se recycle après 2^32 blocs de 128 bits avec le même IV. Mitigé en utilisant un IV aléatoire de 96 bits (probabilité de collision négligeable avec 2^48 documents).

### ADR-003 : HKDF maison vs BouncyCastle vs Tink

**Décision :** Implémenter HKDF manuellement (50 lignes, `javax.crypto.Mac`) en Phase 1. Évaluer Google Tink pour Phase 2.

**Contexte :** Trois options : (1) HKDF natif via Mac, (2) BouncyCastle, (3) Google Tink.

**Analyse :**
- HKDF natif : zéro dépendance, 50 lignes auditables, RFC 5869 directement implémentable. Risque : erreur d'implémentation si mal testé.
- BouncyCastle : bibliothèque de référence, très complète, 9MB de JAR. Surpuissant pour notre besoin.
- Google Tink : API de haut niveau, gestion des keysets intégrée, rotation native. Excellent mais couplage fort à l'écosystème Tink.

**Décision finale :** HKDF natif en Phase 1 (avec vecteurs de test RFC 5869). Migration vers Tink si les besoins cryptographiques s'élargissent (E2EE, signatures, etc.).

### ADR-004 : Chiffrement en streaming vs chargement en mémoire

**Décision :** Déchiffrement en streaming via `CipherInputStream` pour les fichiers > 5MB.

**Contexte :** Le déchiffrement AES-256-GCM nécessite de vérifier le tag d'authentification avant de libérer les données. Avec Java's `CipherInputStream`, le tag est vérifié à la fin du stream — cela crée un risque de libérer des octets avant validation complète.

**Solution :** Pour les fichiers > 5MB, utiliser `java.security.DigestInputStream` en parallèle pour accumuler le tag, et ne commencer à streamer que si le tag est validé. Pour les fichiers < 5MB, chargement complet en mémoire (validation garantie avant toute émission).

Ce compromis équilibre performance (pas de double copie) et sécurité (pas d'octets invalides servis).

### ADR-005 : KEK dérivé de `storageKey` plutôt que de `userId` (ajouté v1.1, 2026-07-22)

**Décision :** Dériver le KEK avec `HKDF(MK, salt=SHA-256(storageKey), info="kovixel-file-kek-v{n}")`
au lieu de `HKDF(MK, salt=userId, info="kovixel-kek-v{n}:user:{id}")`.

**Contexte :** La v1.0 de cette roadmap a été rédigée sans revue du code et supposait que
`FileStorageService.store()`/`retrieve()` recevaient `userId` et `documentId`. La revue du code (2026-07-22)
montre que ces méthodes ne reçoivent que `key` (la `storageKey`), et que ~20 services métier appellent
`FileStorageService` directement (pas de endpoint d'upload central). Étendre les signatures pour y
ajouter `userId`/`documentId` aurait nécessité de modifier chacun de ces ~20 appelants.

**Raisons du choix :**
- La `storageKey` est déjà unique par fichier et disponible à l'écriture **et** à la lecture (c'est le
  seul paramètre commun aux deux opérations).
- Toutes les propriétés de sécurité de l'envelope encryption (rotation sans re-chiffrement des fichiers,
  révocation par document via crypto-shredding) sont préservées à l'identique.
- Le chiffrement reste totalement transparent dans les deux implémentations de `FileStorageService` —
  zéro régression de comportement pour les ~20 appelants existants.

**Compromis accepté :** perte de la révocation groupée par utilisateur en une seule opération (rotation
« tous les documents d'un utilisateur X »). Non exigé par les critères de sortie de cette roadmap ;
reconstructible via `documents.user_id` + `documents.storage_key` si un besoin futur apparaît.

---

## 9. Risques et mitigations

| Risque | Probabilité | Impact | Mitigation |
|--------|------------|--------|------------|
| **Perte du Master Key** | Faible | Catastrophique (tous fichiers inaccessibles) | Backup sécurisé du MK dans 2 coffres-forts séparés + test de restauration trimestriel |
| **Régression de performance** | Moyenne | Moyen (UX dégradée) | Benchmark systématique : overhead cible < 50ms/10MB. Profiling avant merge. |
| **Corruption d'un fichier chiffré** | Faible | Moyen (fichier inaccessible) | `DECRYPT_FAIL` alerte admin immédiatement. Backup régulier du stockage. |
| **Collision d'IV** | Infime (2^-96) | Élevé (confidentialité compromise) | IV de 96 bits, SecureRandom. À ce niveau de probabilité (inférieur aux rayons cosmiques), non-adressable. |
| **Migration incomplète** | Moyenne | Moyen (documents non chiffrés oubliés) | Job de monitoring : alerte si `encryption_status = 'PLAIN'` détecté après J+7. |
| **Dépendance cryptographique vulnérable** | Faible | Élevé | `mvn dependency-check:check` dans CI. Surveillance CVE pour `bcprov`, `jjwt`. |
| **Rotation de clé échoue à mi-chemin** | Faible | Moyen (dual-key state indéfini) | Job de rotation idempotent. Dual-key lisible jusqu'à 100% migration. Log de progression granulaire. |
| **Admin interne malveillant** | Faible | Élevé | Séparation des rôles : l'admin applicatif ne connaît pas le MK. Le MK n'est accessible qu'aux opérations (ops/DevSecOps). Audit log immuable. |

---

## 10. KPIs de sécurité

Ces indicateurs doivent être mesurés et reportés mensuellement en tableau de bord sécurité.

| KPI | Cible | Méthode de mesure |
|-----|-------|------------------|
| % documents chiffrés | 100% | `SELECT COUNT(*) WHERE encryption_status != 'ENCRYPTED'` |
| Overhead chiffrement/déchiffrement (p99) | < 50ms / 10MB | Métriques Micrometer sur `EncryptedFileStorageService` |
| MTTR incident déchiffrement | < 30 min | Moyenne sur alertes `DECRYPT_FAIL` |
| Fréquence rotation Master Key | Annuelle min | Date de dernière rotation dans documentation ops |
| Âge moyen des DEK | < durée plan | Moyenne `created_at` dans `document_encryption_keys` |
| Couverture tests crypto | > 95% | JaCoCo sur package `com.kovixel.common.crypto` |
| Faux positifs `DECRYPT_FAIL` | 0 | Dashboard alertes |
| Documents expirés non supprimés | 0 | `SELECT COUNT(*) WHERE expires_at < NOW() AND encryption_status != 'DELETED'` |

---

## 11. Conformité réglementaire

### RGPD

| Article | Exigence | Implémentation |
|---------|----------|---------------|
| Art. 5.1.f (intégrité et confidentialité) | Mesures techniques appropriées | AES-256-GCM, TLS 1.2+, BCrypt-12 |
| Art. 17 (droit à l'effacement) | Suppression effective des données | Crypto-shredding : révocation DEK → données inaccessibles en < 1s |
| Art. 25 (Privacy by Design) | Chiffrement par défaut | Chiffrement automatique à l'upload, aucune action requise de l'utilisateur |
| Art. 32 (sécurité du traitement) | État de l'art en matière de sécurité | Envelope encryption, rotation de clés, audit trail |
| Art. 30 (registre des traitements) | Documentation des traitements | Registre à maintenir (Sprint E-8) |
| Art. 33 (notification de violation) | Notification sous 72h | Procédure d'incident à documenter |

### ISO 27001 (Annex A)

| Contrôle | Description | Couverture |
|---------|-------------|------------|
| A.8.24 | Utilisation de la cryptographie | AES-256-GCM, HKDF-SHA256, politique de chiffrement |
| A.8.10 | Suppression des informations | Crypto-shredding + suppression physique |
| A.8.12 | Prévention de fuite de données | Chiffrement fichiers + audit trail |
| A.5.33 | Protection des enregistrements | Audit logs immuables, rétention 90 jours |
| A.8.5 | Authentification sécurisée | JWT + 2FA déjà implémentés |

### SOC 2 Type II (Trust Services Criteria)

| Critère | Description | Couverture |
|---------|-------------|------------|
| CC6.1 | Contrôles d'accès logiques | JWT, 2FA, audit trail |
| CC6.6 | Accès aux composants d'infrastructure | TLS, Redis AUTH, Postgres SSL |
| CC6.7 | Données en transit et au repos | TLS + AES-256-GCM |
| CC7.2 | Monitoring des systèmes | Alertes `DECRYPT_FAIL`, dashboard KPIs |
| CC9.1 | Évaluation des risques | Threat model documenté (Section 3) |

---

## 12. Glossaire

| Terme | Définition |
|-------|-----------|
| **AES-256-GCM** | Advanced Encryption Standard, clé 256 bits, mode Galois/Counter Mode. Algorithme AEAD : assure confidentialité ET intégrité. |
| **AEAD** | Authenticated Encryption with Associated Data. Un seul algorithme pour chiffrer et authentifier. |
| **DEK** | Data Encryption Key. Clé symétrique unique par document, utilisée pour chiffrer le fichier. |
| **eDEK** | Encrypted DEK. Le DEK, lui-même chiffré avec le KEK, stocké en base de données. |
| **GCM tag** | Authentication tag de 128 bits produit par AES-GCM. Toute modification du ciphertext invalide ce tag. |
| **HKDF** | HMAC-based Key Derivation Function (RFC 5869). Dérive des clés cryptographiquement solides à partir d'un matériel de clé initial. |
| **HSM** | Hardware Security Module. Dispositif physique dédié au stockage et aux opérations cryptographiques. |
| **IV / Nonce** | Initialization Vector. Valeur aléatoire unique utilisée avec AES-GCM. Ne jamais réutiliser avec la même clé. |
| **KEK** | Key Encryption Key. Clé utilisée pour chiffrer les DEK. Dérivée à la demande, jamais stockée. |
| **KMS** | Key Management Service. Service (interne ou externe) de gestion du cycle de vie des clés cryptographiques. |
| **Crypto-shredding** | Destruction cryptographique : supprimer la clé de chiffrement rend les données définitivement inaccessibles, sans nécessiter d'effacement sécurisé du support. |
| **Envelope Encryption** | Modèle où les données sont chiffrées avec un DEK, et le DEK est lui-même chiffré avec un KEK. Permet rotation et révocation granulaire. |
| **RGPD Art. 17** | Droit à l'effacement ("droit à l'oubli"). Le crypto-shredding est un moyen technique de l'exercer. |
| **SecureRandom** | Générateur de nombres aléatoires cryptographiquement sûr de Java. Seul générateur acceptable pour les IVs et les clés. |
| **TLS** | Transport Layer Security. Protocole de chiffrement des communications réseau. Version 1.2+ obligatoire. |
| **HSTS** | HTTP Strict Transport Security. Header forçant les navigateurs à n'utiliser que HTTPS. |
| **SSE-S3** | Server-Side Encryption avec clés gérées par S3/MinIO. Couche de chiffrement infrastructure complémentaire. |
| **PBKDF2** | Password-Based Key Derivation Function 2. Pour dériver des clés depuis des mots de passe (pas utilisé pour les fichiers, réservé aux mots de passe). |
| **KDF** | Key Derivation Function. Fonction permettant de dériver des clés cryptographiquement solides depuis un matériel initial. |

---

*Fin du document — Version 1.0 — 2026-06-19*
