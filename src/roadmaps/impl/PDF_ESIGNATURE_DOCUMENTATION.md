# Documentation — Outil « Signature Électronique PDF »

> **Version :** 1.0 — Sprint 4 complet
> **Date :** 2026-06-21
> **Statut :** Production

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Fonctionnalités](#2-fonctionnalités)
3. [Architecture technique](#3-architecture-technique)
4. [Modes de signature](#4-modes-de-signature)
5. [Types de champs](#5-types-de-champs)
6. [Coordonnées et placement](#6-coordonnées-et-placement)
7. [Signature numérique PAdES-B](#7-signature-numérique-pades-b)
8. [Piste d'audit](#8-piste-daudit)
9. [QR code de vérification](#9-qr-code-de-vérification)
10. [API Reference](#10-api-reference)
11. [Sécurité et confidentialité](#11-sécurité-et-confidentialité)
12. [Limites par plan](#12-limites-par-plan)
13. [Guide d'utilisation (UX)](#13-guide-dutilisation-ux)
14. [Workflow multi-signataires (à venir)](#14-workflow-multi-signataires-à-venir)

---

## 1. Vue d'ensemble

L'outil **Signature Électronique PDF** de Kovixel permet d'apposer une ou plusieurs
signatures sur n'importe quel document PDF, avec un placement libre et précis sur toutes
les pages. Il est conçu pour atteindre le niveau de qualité des leaders du marché
(DocuSign, HelloSign, Adobe Sign) tout en restant accessible en plan gratuit.

### Ce que l'outil offre

| Capacité | Kovixel | iLovePDF | SmallPDF | HelloSign |
|----------|---------|----------|----------|-----------|
| Dessin à la main (canvas) | ✅ FREE | ✅ | ✅ | ✅ |
| Signature typée (6 polices cursives) | ✅ FREE | ❌ | ✅ | ✅ |
| Upload image de signature | ✅ FREE | ✅ | ✅ | ✅ |
| Placement drag & drop libre | ✅ FREE | ❌ position fixe | ❌ position fixe | ✅ |
| Aperçu PDF réel (PDF.js) | ✅ | ❌ | ❌ | ✅ |
| Champs Initiales distincts | ✅ FREE | ❌ | ❌ | ✅ |
| Champ Date automatique | ✅ FREE | ❌ | ❌ | ✅ |
| Champ Texte libre | ✅ PRO | ❌ | ❌ | ✅ |
| Case à cocher | ✅ PRO | ❌ | ❌ | ✅ |
| Couleur de signature libre | ✅ FREE | ❌ | ❌ | ❌ |
| Signature cryptographique PAdES-B | ✅ PRO | ❌ | ❌ | ✅ |
| Piste d'audit téléchargeable (PDF) | ✅ PRO | ❌ | ❌ | ✅ |
| QR code de vérification | ✅ PRO | ❌ | ❌ | ❌ |

---

## 2. Fonctionnalités

### Modes de création de signature
- **DRAW** : dessin à la souris ou au doigt sur un canvas interactif avec lissage quadratique
- **UPLOAD** : importation d'une image PNG ou JPG existante
- **TYPE** : saisie de texte converti en signature cursive (6 polices embarquées)

### Types de champs placés sur le PDF
- `SIGNATURE` — image de signature en taille réelle
- `INITIALS` — paraphe (image à 40 % de la taille signature)
- `DATE` — date de traitement injectée automatiquement (3 formats)
- `TEXT` — texte libre saisi par l'utilisateur (PRO)
- `CHECKBOX` — case cochée (✓) pour formulaires de consentement (PRO)

### Placement
- Aperçu des vraies pages PDF via **PDF.js** — pas de canvas générique
- Placement drag & drop sur n'importe quelle zone de n'importe quelle page
- Redimensionnement par poignée (curseur ↔)
- Navigation entre pages avec indicateur de progression

### Qualité de l'image de signature
- Modes DRAW et UPLOAD : PNG intégré tel quel, fond transparent conservé
- Mode TYPE : génération AWT `BufferedImage` 600×180 px, fond transparent,
  rendu antialiasé, 6 polices TTF embarquées dans le JAR

### Sprint 4 — Fonctionnalités avancées
- **Signature numérique PAdES-B** (PKCS#12 / X.509) avec BouncyCastle CMS
- **Piste d'audit PDF** téléchargeable avec hash SHA-256 du document
- **QR code** de vérification intégré en bas de la dernière page
- **Multi-signataires** : infrastructure DB prête (tables `pdf_sign_workflows`,
  `pdf_sign_workflow_steps`) — orchestration email en cours de développement

---

## 3. Architecture technique

### Pipeline asynchrone

```
Client Angular
  │
  ├── POST /api/v1/pdf/esignature (multipart)
  │     └── 202 Accepted { jobId }
  │
  ├── GET /api/v1/pdf/esignature/{jobId}/result   (polling toutes les 2s)
  │     └── { status: "PENDING" | "PROCESSING" | "COMPLETED" | "FAILED" }
  │
  └── GET /api/v1/pdf/esignature/{jobId}/download
        └── PDF signé (Content-Disposition: attachment)
```

### Stockage

| Donnée | Emplacement | Durée |
|--------|-------------|-------|
| PDF source | MinIO `pdf-esignature/source/{docId}/…` | Jusqu'à expiration |
| Image signature temp | MinIO `pdf-esignature/signatures/{jobId}/signature.png` | Supprimée immédiatement après traitement |
| PDF signé | MinIO `pdf-esignature/output/{jobId}/{nom}_signé.pdf` | 24h / 7j / 30j selon plan |
| Piste d'audit | MinIO `pdf-esignature/audit/{jobId}/audit_trail.pdf` | Même TTL que PDF signé |
| Certificat PKCS#12 | Redis `pdf:esig:cert:{jobId}` | TTL 30 min maximum — supprimé immédiatement après usage |

### Packages Java

```
com.kovixel.pdfesignature
  ├── config/
  │     └── BouncyCastleProviderConfig.java    ← @PostConstruct enregistre BC provider
  ├── controller/
  │     └── PdfEsignatureController.java
  ├── dto/
  │     ├── PdfEsignatureRequest.java
  │     ├── SignatureFieldDto.java
  │     ├── PdfEsignatureJobResponse.java
  │     └── PdfEsignatureResultResponse.java
  ├── entity/
  │     ├── PdfEsignatureResult.java
  │     ├── PdfSignWorkflow.java
  │     └── PdfSignWorkflowStep.java
  ├── repository/
  │     ├── PdfEsignatureResultRepository.java
  │     ├── PdfSignWorkflowRepository.java
  │     └── PdfSignWorkflowStepRepository.java
  ├── scheduler/
  │     └── PdfEsignatureCleanupJob.java       ← TTL 24h/7j/30j selon plan
  ├── service/
  │     ├── PdfEsignatureService.java           (interface)
  │     ├── PdfEsignatureServiceImpl.java
  │     ├── PdfCertificateRedisService.java     (interface)
  │     └── PdfCertificateRedisServiceImpl.java
  └── strategy/
        └── PdfEsignatureStrategy.java          (implements ProcessingStrategy)
```

### Composants Angular

```
features/tools/pdf-esignature/
  ├── pdf-esignature.component.ts   ← composant principal (4 étapes)
  ├── pdf-esignature.routes.ts
  ├── signature-canvas/
  │     └── signature-canvas.component.ts   ← canvas DRAW (pointer events + lissage)
  └── field-placer/
        └── field-placer.component.ts       ← overlay PDF.js + CdkDrag + resize

core/
  ├── models/pdf-esignature.model.ts
  ├── services/pdf-esignature.service.ts
  └── services/pdf-render.service.ts        ← wrapper PDF.js (lazy import, SSR-safe)
```

### Dépendances techniques clés

| Dépendance | Version | Usage |
|------------|---------|-------|
| Apache PDFBox | 3.0.7 | Lecture, écriture, signature PDF |
| BouncyCastle (`bcpkix-jdk18on`) | 1.78.1 | CMS PKCS#7, PAdES-B |
| ZXing core + javase | 3.5.3 | Génération QR code |
| pdfjs-dist | 4.10.38 | Rendu des pages PDF dans Angular |
| `@angular/cdk` | 21.x | CdkDrag pour le placement des champs |

---

## 4. Modes de signature

### DRAW — Dessin à la main

L'utilisateur dessine sa signature sur un canvas interactif avec :
- **Pointer Events** (`pointerdown`, `pointermove`, `pointerup`) pour compatibilité
  souris, stylet et tactile
- **`setPointerCapture`** pour ne pas perdre le tracé hors du canvas
- **Lissage quadratique** : interpolation `quadraticCurveTo` entre les points pour
  un trait fluide et naturel (pas de lignes droites saccadées)
- **Historique d'annulation** (`ImageData[]` limité à 30 états) via bouton « Effacer »
- Fond blanc intégré (le PNG emporte le fond — comportement attendu sur PDF blanc)
- Couleur configurable par le preset ou le sélecteur libre

```
Flux : canvas → PNG Blob → multipart signatureFile → MinIO temp → PDImageXObject → PDF
```

### UPLOAD — Image importée

L'utilisateur importe une image depuis son appareil :
- **Formats acceptés** : PNG, JPG uniquement (SVG exclus — PDFBox ne supporte pas SVG)
- **Taille maximale** : 5 MB
- **Fond transparent (PNG)** : conservé tel quel dans le PDF — idéal pour les signatures
  scannées sur fond blanc ou les logos d'entreprise
- **Fond blanc (JPG)** : visible dans le PDF (comportement attendu)

```
Flux : fichier → FileReader → preview local → multipart signatureFile → MinIO temp → PDF
```

### TYPE — Signature typée

L'utilisateur saisit son nom/prénom, le backend génère une image PNG cursive :
- Rendu **AWT `BufferedImage`** 600×180 px en `TYPE_INT_ARGB` (fond transparent)
- Antialiasage bilinéaire activé (`VALUE_ANTIALIAS_ON`, `VALUE_RENDER_QUALITY`)
- **6 polices TTF embarquées** dans le JAR (`src/main/resources/fonts/`) — aucune
  dépendance système, rendu identique sur tous les serveurs

| Clé `SignatureFont` | Apparence | Cas d'usage |
|---------------------|-----------|-------------|
| `DANCING_SCRIPT` | Cursive fluide, équilibrée ← **défaut** | Usage général |
| `GREAT_VIBES` | Élégante, fins et déliés | Contrats formels, luxe |
| `PACIFICO` | Arrondie, moderne | Bons, commandes décontractées |
| `SATISFY` | Rapide, naturelle | Devis, approbations |
| `ALLURA` | Fine, précise, verticale | Correspondance formelle |
| `ALEX_BRUSH` | Ferme, masculine | Documents juridiques |

```
Flux : signatureText + signatureFont → AWT BufferedImage → PNG bytes → PDImageXObject → PDF
```

---

## 5. Types de champs

### SIGNATURE

Image de la signature à la taille exacte du champ placé par l'utilisateur.

```java
cs.drawImage(sigImage, xPt, yPt, wPt, hPt);
```

### INITIALS

Même image de signature mais à **40 % de la largeur** — pour les paraphes compacts
en bas de chaque page par exemple.

```java
float iW = wPt * 0.40f;
cs.drawImage(sigImage, xPt, yPt, iW, hPt);
```

### DATE

Date de traitement injectée automatiquement en Helvetica 10 pt, sans intervention
de l'utilisateur.

```java
String label = LocalDate.now().format(DateTimeFormatter.ofPattern(fmt));
// fmt = "dd/MM/yyyy" | "MM/dd/yyyy" | "yyyy-MM-dd"
```

| Format | Exemple |
|--------|---------|
| `dd/MM/yyyy` | 21/06/2026 |
| `MM/dd/yyyy` | 06/21/2026 |
| `yyyy-MM-dd` | 2026-06-21 |

### TEXT (PRO)

Texte libre saisi par l'utilisateur lors du placement du champ. Le contenu du champ
`label` est rendu en Helvetica 10 pt à la couleur de signature choisie.

Exemples d'usage : « Approuvé », « Lu et accepté », mention manuscrite, numéro de référence.

### CHECKBOX (PRO)

Case cochée (✓) dessinée via des opérations de tracé PDFBox :
- Un rectangle bordé de la couleur de signature
- Une coche en deux segments (`moveTo / lineTo`) dans le rectangle

```java
// Boite
cs.addRect(x, y, size, size);
cs.stroke();
// Coche
cs.moveTo(x + pad, y + size * 0.5f);
cs.lineTo(midX, midY);
cs.lineTo(x + size - pad, y + size - pad);
cs.stroke();
```

Idéal pour les formulaires de consentement, acceptations de CGU, cases de validation.

---

## 6. Coordonnées et placement

### Système de coordonnées

Angular (PDF.js) utilise une origine **haut-gauche** en pixels.
PDFBox utilise une origine **bas-gauche** en points (1 pt = 1/72 pouce).

Les champs sont transmis en **pourcentage** (0–100 %) pour être indépendants de la
résolution du canvas et de la taille réelle du PDF.

```
Angular (canvas PDF.js, origine haut-gauche) :
  xPx = xPct / 100 × canvasWidth
  yPx = yPct / 100 × canvasHeight       ← depuis le haut

PDFBox (origine bas-gauche, en points) :
  xPt = xPct      / 100 × pageWidthPt
  wPt = widthPct  / 100 × pageWidthPt
  hPt = heightPct / 100 × pageHeightPt
  yPt = pageHeightPt - (yPct / 100 × pageHeightPt) - hPt   ← Y inversé
```

### Exemple de champ JSON

```json
{
  "page": 2,
  "xPct": 12.5,
  "yPct": 78.3,
  "widthPct": 25.0,
  "heightPct": 8.5,
  "type": "SIGNATURE",
  "label": "Signature du client"
}
```

### Validation

| Règle | Comportement si invalide |
|-------|--------------------------|
| `page` hors plage du PDF | 422 — message d'erreur précis |
| `xPct`, `yPct` hors [0, 100] | 400 — coordonnées invalides |
| `widthPct`, `heightPct` ≤ 0 ou > 100 | 400 |
| Liste vide | 400 — au moins 1 champ requis |
| JSON malformé | 400 — JSON invalide |

---

## 7. Signature numérique PAdES-B

> Disponible en plan **PRO** et **ENTERPRISE**. Requiert un certificat PKCS#12 (.p12 / .pfx).

### Qu'est-ce que PAdES-B ?

PAdES (PDF Advanced Electronic Signatures) est le standard européen de signature
numérique pour les PDF, défini par l'ETSI et reconnu par le règlement eIDAS.
Le niveau **PAdES-B** (Basic) garantit :

- L'authenticité du signataire (certificat X.509)
- L'intégrité du document (aucune modification non détectée)
- La non-répudiation (impossible de nier avoir signé)

### Implémentation technique

```
1. Toutes les signatures visuelles + QR code + audit trail → signedBytes1
2. Chargement du PKCS#12 depuis Redis (TTL 30 min)
3. Extraction de la PrivateKey + chaîne de certificats
4. PDDocument.addSignature(PDSignature, SignatureInterface)
5. SignatureInterface.sign(content) :
     → CMSSignedDataGenerator (BouncyCastle)
     → SHA256withRSA ContentSigner
     → CMSSignedData (PKCS#7 Detached)
     → bytes encodés DER
6. PDDocument.saveIncremental(baos) → signedBytes2
     ↑ Le document original est préservé, la signature est en mise à jour incrémentale
```

La mise à jour incrémentale (`saveIncremental`) est requise par PAdES : les octets
originaux ne sont pas réécrits, ce qui garantit la validité des byte ranges de la
signature.

### Paramètres de la signature PDF

```java
sig.setFilter(PDSignature.FILTER_ADOBE_PPKLITE);
sig.setSubFilter(PDSignature.SUBFILTER_ADBE_PKCS7_DETACHED);
sig.setName(opts.signerName());
sig.setReason("Signature electronique Kovixel");
sig.setLocation("France");
sig.setSignDate(Calendar.getInstance());
```

### Sécurité du certificat

Le fichier `.p12` et le mot de passe associé ne sont **jamais écrits en base de données**.
Ils transitent uniquement par Redis avec un TTL de **30 minutes** sous la clé
`pdf:esig:cert:{jobId}`, et sont supprimés immédiatement après usage par le worker.

```
Client → HTTPS → Backend → Redis (TTL 30 min)
                                   ↓
                 Worker lit le certificat → signe → supprime la clé Redis
```

---

## 8. Piste d'audit

Une piste d'audit PDF est générée automatiquement pour chaque document signé. Elle est stockée comme **PDF séparé** dans MinIO — elle n'est **pas** incluse dans le PDF signé. Le PDF signé contient uniquement le contenu du document et le QR code de vérification.

Elle est disponible via `GET /api/v1/pdf/esignature/{jobId}/audit-trail`.

### Contenu de la piste d'audit

```
┌─────────────────────────────────────────────────────────────────┐
│  PISTE D'AUDIT - Kovixel                                        │
├─────────────────────────────────────────────────────────────────┤
│  DOCUMENT                                                       │
│  Nom du fichier          : contrat_client.pdf                   │
│  Nombre de pages         : 5 (dont 2 signée(s))                 │
│  SHA-256                 : 3f9a8b1c2d4e5f6a7b8c9d0e1f2a3b4c…   │
│  Identifiant             : KVX-4291                             │
│  Date de signature       : 21/06/2026 14:35:22 UTC              │
├─────────────────────────────────────────────────────────────────┤
│  SIGNATAIRE                                                     │
│  Mode de signature       : Dessin manuel                        │
│  Nom du signataire       : Jean Dupont                          │
│  Email du signataire     : jean.dupont@acme.com                 │
├─────────────────────────────────────────────────────────────────┤
│  SIGNATURE NUMÉRIQUE (si applicable)                            │
│  Type                    : PAdES-B (PKCS#7 Detached)            │
│  Algorithme              : SHA-256 with RSA                     │
│  Certification           : NOT_CERTIFIED                        │
├─────────────────────────────────────────────────────────────────┤
│  STATUT                                                         │
│  Résultat                : COMPLÉTÉ                             │
│  Champs signés           : 2                                    │
│  Générée le              : 21/06/2026 14:35:23                  │
└─────────────────────────────────────────────────────────────────┘
```

Le **SHA-256** est calculé sur le document après toutes les signatures visuelles
(avant la signature PAdES). Il permet de vérifier ultérieurement que le contenu
n'a pas été altéré.

### Stockage

```
MinIO : pdf-esignature/audit/{jobId}/audit_trail.pdf
TTL   : identique au PDF signé (24h FREE, 7j PRO, 30j ENTERPRISE)
```

---

## 9. QR code de vérification

Un QR code est automatiquement ajouté en bas à droite de la **dernière page** du PDF signé.
Il pointe vers la page de vérification publique :

```
https://kovixel.com/verify/{jobId}
```

La page `/verify/{jobId}` (en cours de développement) affichera :
- Nom du signataire
- Date et heure de signature
- Mode de signature utilisé
- Hash SHA-256 du document

La page ne révèle **jamais** le contenu du PDF lui-même.

### Implémentation

```java
QRCodeWriter writer = new QRCodeWriter();
BitMatrix matrix = writer.encode(
    "https://kovixel.com/verify/" + jobId,
    BarcodeFormat.QR_CODE, 60, 60
);
BufferedImage qrImage = MatrixToImageWriter.toBufferedImage(matrix);
```

Le QR code est rendu en 60×60 pt (environ 2,1 cm) avec une marge de 14 pt par rapport
aux bords de la page.

---

## 10. API Reference

### `POST /api/v1/pdf/esignature`

Soumet un PDF à signer. Retourne immédiatement un `jobId` pour le suivi.

**Content-Type :** `multipart/form-data`

| Champ | Type | Requis | Description |
|-------|------|--------|-------------|
| `file` | `MultipartFile` | ✅ | PDF à signer (max 10 MB FREE) |
| `signatureMode` | `String` | ✅ | `DRAW` \| `UPLOAD` \| `TYPE` |
| `fieldsJson` | `String` | ✅ | JSON des champs à placer |
| `signatureColor` | `String` | — | Couleur hex `#RRGGBB` (défaut `#1a1a2e`) |
| `signatureFile` | `MultipartFile` | DRAW/UPLOAD | PNG ou JPG, max 5 MB |
| `signatureText` | `String` | TYPE | Texte de la signature (max 200 car.) |
| `signatureFont` | `String` | — | Voir énumération `SignatureFont` |
| `certificateFile` | `MultipartFile` | PRO | Certificat PKCS#12 (.p12/.pfx), max 2 MB |
| `certificatePassword` | `String` | PRO | Mot de passe du certificat |
| `certificationLevel` | `String` | — | `NOT_CERTIFIED` \| `CERTIFIED_NO_CHANGES` |
| `signerName` | `String` | — | Nom du signataire (max 200 car.) |
| `signerEmail` | `String` | — | Email du signataire (max 320 car.) |

**Réponse 202 :**
```json
{
  "jobId": 4291,
  "documentId": 882,
  "status": "PENDING",
  "message": "Signature en cours — suivre via /api/v1/pdf/esignature/4291/result"
}
```

---

### `GET /api/v1/pdf/esignature/{jobId}/result`

Statut du traitement. Appeler en polling (toutes les 2 s côté Angular).

**Réponse — En cours :**
```json
{
  "jobId": 4291,
  "status": "PENDING"
}
```

**Réponse — Terminé :**
```json
{
  "jobId": 4291,
  "status": "COMPLETED",
  "downloadUrl": "/api/v1/pdf/esignature/4291/download",
  "outputFileName": "contrat_client_signé.pdf",
  "outputSizeBytes": 148320,
  "processingMs": 1243,
  "expiresAt": "2026-06-22T14:35:23Z",
  "signatureMode": "DRAW",
  "fieldsCount": 3,
  "pagesSigned": 2,
  "sourcePageCount": 5,
  "isDigitallySigned": true,
  "auditTrailUrl": "/api/v1/pdf/esignature/4291/audit-trail"
}
```

**Réponse — Échoué :**
```json
{
  "jobId": 4291,
  "status": "FAILED",
  "errorMessage": "Ce PDF est protégé par mot de passe — déverrouillez-le d'abord."
}
```

---

### `GET /api/v1/pdf/esignature/{jobId}/download`

Télécharge le PDF signé.

**Réponse :** `200 application/pdf` avec `Content-Disposition: attachment; filename="…_signé.pdf"`

---

### `GET /api/v1/pdf/esignature/{jobId}/audit-trail`

Télécharge la piste d'audit PDF (uniquement si disponible — champ `auditTrailUrl` présent).

**Réponse :** `200 application/pdf` avec `Content-Disposition: attachment; filename="audit_trail_{jobId}.pdf"`

**Erreur si absente :** `404` — `Aucune piste d'audit disponible pour ce document`

---

### Énumération `SignatureFont`

| Valeur | Police | Usage recommandé |
|--------|--------|------------------|
| `DANCING_SCRIPT` | Dancing Script | Usage général ← **défaut** |
| `GREAT_VIBES` | Great Vibes | Contrats haut de gamme |
| `PACIFICO` | Pacifico | Documents modernes |
| `SATISFY` | Satisfy | Devis, commandes |
| `ALLURA` | Allura | Correspondance formelle |
| `ALEX_BRUSH` | Alex Brush | Documents juridiques |

### Format `fieldsJson`

```json
[
  {
    "page": 1,
    "xPct": 12.5,
    "yPct": 78.3,
    "widthPct": 25.0,
    "heightPct": 8.5,
    "type": "SIGNATURE",
    "label": "Signature du client"
  },
  {
    "page": 1,
    "xPct": 65.0,
    "yPct": 78.3,
    "widthPct": 20.0,
    "heightPct": 4.0,
    "type": "DATE",
    "dateFormat": "dd/MM/yyyy"
  },
  {
    "page": 3,
    "xPct": 80.0,
    "yPct": 90.0,
    "widthPct": 10.0,
    "heightPct": 5.0,
    "type": "CHECKBOX",
    "label": "Lu et accepté"
  }
]
```

---

## 11. Sécurité et confidentialité

### Principes généraux

1. **Image de signature jamais stockée durablement** : les fichiers `signature.png`
   sont supprimés immédiatement après leur intégration dans le PDF par le worker.
   Un job de nettoyage de sécurité passe 12 min après le démarrage de l'app
   (`PdfEsignatureCleanupJob`) pour supprimer toute clé orpheline.

2. **Certificat PKCS#12 jamais en base de données** : le fichier `.p12` et son mot
   de passe transitent uniquement par Redis avec un TTL de 30 minutes maximum.
   La clé est supprimée en premier dans le worker, avant tout autre traitement.
   Si le worker échoue avant la suppression, le TTL Redis assure la destruction.

3. **Mot de passe du certificat exclu des logs** : `@ToString.Exclude` sur le champ
   `certificatePassword` du DTO — jamais visible dans les logs Spring.

4. **Transport chiffré** : HTTPS obligatoire en production. Le multipart est transmis
   intégralement sur canal sécurisé.

### Cycle de vie des données

```
Soumission → Job créé
    ├── sigImage → MinIO temp → supprimée immédiatement par le worker
    ├── certificat → Redis TTL 30min → supprimé immédiatement par le worker
    └── PDF signé → MinIO output → supprimé après TTL (24h / 7j / 30j)

Audit trail :  MinIO pdf-esignature/audit/ → même TTL que le PDF signé
```

### Cas d'erreur couverts

| Cas | Code HTTP | Message |
|-----|-----------|---------|
| PDF protégé par mot de passe | 422 | Déverrouillez-le d'abord |
| Fichier non-PDF | 415 | Seuls les fichiers PDF sont acceptés |
| PDF corrompu | 400 | Fichier PDF invalide ou corrompu |
| PDF vide (0 pages) | 400 | Le fichier PDF est vide |
| Image signature absente (DRAW/UPLOAD) | 400 | Image de signature requise |
| Texte absent (TYPE) | 400 | Texte de signature requis |
| Image signature > 5 MB | 413 | Taille maximale dépassée |
| PDF > limite plan | 413 | Avec rappel de la limite |
| Champ hors plage de pages | 400 | Message précis avec le nb de pages |
| JSON champs malformé | 400 | Format JSON invalide |
| Quota journalier dépassé | 429 | Via QuotaService |

---

## 12. Limites par plan

| Limite | FREE | PRO | ENTERPRISE |
|--------|------|-----|------------|
| Taille max PDF | 10 MB | 50 MB | 200 MB |
| Taille max image signature | 5 MB | 5 MB | 5 MB |
| Taille max certificat | 2 MB | 2 MB | 2 MB |
| Jobs par jour | 10 (quota partagé) | 200 | Illimité |
| Rétention du PDF signé | 24 heures | 7 jours | 30 jours |
| Mode DRAW | ✅ | ✅ | ✅ |
| Mode UPLOAD | ✅ | ✅ | ✅ |
| Mode TYPE (6 polices) | ✅ | ✅ | ✅ |
| Couleur de signature libre | ✅ | ✅ | ✅ |
| Champ SIGNATURE | ✅ | ✅ | ✅ |
| Champ INITIALS | ✅ | ✅ | ✅ |
| Champ DATE (3 formats) | ✅ | ✅ | ✅ |
| Champ TEXT | ❌ | ✅ | ✅ |
| Champ CHECKBOX | ❌ | ✅ | ✅ |
| Signature numérique PAdES-B | ❌ | ✅ | ✅ |
| Piste d'audit téléchargeable | ❌ | ✅ | ✅ |
| QR code de vérification | ❌ | ✅ | ✅ |
| Certificat PKCS#12 personnel | ❌ | ✅ | ✅ |
| Multi-signataires (à venir) | ❌ | ✅ | ✅ |

> Le quota `PDF_ESIGNATURE` partage `maxConversionsPerDay` avec les autres outils PDF
> dans `PlanConfig.limitFor()`.

---

## 13. Guide d'utilisation (UX)

### Étape 1 — Upload du PDF

- Glisser-déposer ou clic pour ouvrir le sélecteur de fichiers
- Formats acceptés : `.pdf`, `application/pdf`
- Validation immédiate côté frontend (type MIME via PDF.js)
- Le nombre de pages est lu par PDF.js et affiché

### Étape 2 — Créer la signature

**Onglet DRAW (Dessiner)**
- Canvas blanc 100 % largeur, hauteur proportionnelle
- Tracer avec la souris, le doigt ou un stylet
- Bouton « Effacer » pour recommencer (jusqu'à 30 annulations)
- La couleur sélectionnée s'applique au tracé en temps réel

**Onglet UPLOAD (Importer)**
- Clic sur la zone → sélecteur de fichiers PNG ou JPG
- Aperçu immédiat de l'image importée

**Onglet TYPE (Taper)**
- Champ texte : nom, prénom, paraphe
- Grille de 6 polices cursives cliquables
- Aperçu navigateur (texte stylisé en italic — le vrai rendu est produit par le serveur)

**Couleur de signature**
- 4 presets : bleu marine, noir, bleu royal, rouge
- Sélecteur de couleur libre (`<input type="color">`)

**Signature numérique (PRO — optionnel)**
- Toggle « Appliquer une signature numérique (PKCS#12) »
- Nom et email du signataire
- Upload du fichier `.p12` / `.pfx`
- Saisie du mot de passe (masqué)

### Étape 3 — Placer les champs

- La vraie page PDF est rendue via PDF.js
- 5 boutons de champs : Signature, Initiales, Date, Texte, Case
- Chaque champ est draggable (CdkDrag) et redimensionnable
- Navigation entre pages avec les boutons Préc. / Suiv.
- Tous les champs placés sont affichés avec un code couleur :
  - Violet = Signature
  - Vert = Initiales
  - Orange = Date
  - Bleu = Texte
  - Rose = Case à cocher

> **Champ Texte** : une fenêtre de saisie (`window.prompt`) demande le texte à afficher
> lors du clic sur le bouton « Texte ».

### Étape 4 — Résultat

- Badge vert « Signature numérique PAdES-B appliquée » si applicable
- Statistiques : mode, nb champs, pages signées, taille, temps de traitement
- Bouton principal : télécharger le PDF signé
- Bouton secondaire : télécharger la piste d'audit (si disponible)
- Bouton tertiaire : recommencer avec un nouveau document
- Rappel de la date d'expiration

---

## 14. Workflow multi-signataires (à venir)

L'infrastructure de base est en place (Sprint 4). La fonctionnalité complète sera
livrée dans un sprint dédié.

### Infrastructure existante

```sql
-- Tables créées en V47
pdf_sign_workflows (
    id, creator_id, document_key,
    status,          -- PENDING | IN_PROGRESS | COMPLETED | EXPIRED
    expires_at, created_at
)

pdf_sign_workflow_steps (
    id, workflow_id, step_order,
    signer_email, signer_name,
    status,          -- PENDING | SIGNED | DECLINED
    signed_at, job_id,
    access_token,    -- Token unique envoyé par email (expire dans 7j)
    token_expires_at, created_at
)
```

Entités JPA et repositories Spring Data disponibles :
`PdfSignWorkflow`, `PdfSignWorkflowStep`, `PdfSignWorkflowRepository`,
`PdfSignWorkflowStepRepository`

### Flux prévu

```
1. Le créateur upload le PDF, place les champs de chaque signataire,
   saisit les emails dans l'ordre
2. Kovixel crée un workflow et envoie un email à Signataire 1
   (lien sécurisé avec token unique : kovixel.com/sign/{token})
3. Signataire 1 ouvre la page, voit ses champs, signe, valide
4. Kovixel avance le workflow et envoie l'email à Signataire 2
5. Après la dernière signature : PDF final assemblé, disponible au créateur
6. Piste d'audit PDF globale générée (tous les signataires + dates + modes)
```

### À implémenter

- Endpoint `POST /api/v1/pdf/esignature/workflow` — créer un workflow
- Endpoint `GET /api/v1/pdf/esignature/workflow/{workflowId}/status`
- Endpoint `GET /api/v1/pdf/sign/{token}` — page publique signataire
- Page Angular `features/tools/pdf-esignature-sign/` — interface du signataire externe
- Page Angular `features/verify/` — page publique `/verify/{jobId}`
- Intégration JavaMailSender pour les notifications email aux signataires
