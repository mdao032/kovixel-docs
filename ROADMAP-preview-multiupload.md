# Roadmap — Aperçu fichier + Multi-upload

**Périmètre :** deux fonctionnalités conçues ensemble pour former un seul bloc cohérent.  
**Objectif qualité :** égal ou supérieur à ILovePDF, SmallPDF, Adobe Acrobat Online.  
**Standard de référence :** ILovePDF pour la fluidité du multi-upload, DocuSign pour la qualité du preview.

---

## Contexte & couplage des deux sprints

Le preview de fichier et le multi-upload partagent le même composant fondamental :
la **vignette de prévisualisation par fichier**. Concevoir le preview seul
sans penser au multi-upload produit une architecture qu'on devra refactorer ensuite.
Les deux sprints sont donc définis ensemble, même s'ils sont implémentés séquentiellement.

---

## Sprint A — Aperçu de la première page après sélection

### Objectif

Après qu'un utilisateur dépose ou sélectionne un fichier, la dropzone se transforme :
au lieu du simple nom + taille, on affiche une vignette visuelle de la première page.
L'utilisateur voit immédiatement qu'il a choisi le bon document avant de lancer
le traitement.

---

### Décision critique : taille de fichier et sécurité mémoire

PDF.js charge l'intégralité du fichier dans un `ArrayBuffer` avant tout rendu.
Un PDF de 300 Mo sur un mobile (1–2 Go RAM) crash le tab du navigateur.
Le seuil doit donc être **dynamique** selon le device :

| Contexte | Seuil PDF.js | Au-delà |
|---|---|---|
| Desktop (largeur ≥ 768 px) | ≤ 50 Mo | Backend thumbnail |
| Mobile (largeur < 768 px) | ≤ 10 Mo | Backend thumbnail |

Détection recommandée : `window.innerWidth < 768` (simple, sans UA sniffing).

Cette logique s'applique **quelle que soit la taille autorisée par le plan** :
un utilisateur PRO+ peut uploader 500 Mo, mais on ne tente jamais PDF.js sur ce volume.

---

### Stratégie par type de fichier (Option C — Hybride)

| Format | Méthode | Seuil client-side | Fallback |
|---|---|---|---|
| **Image** (JPG, PNG, WebP, GIF) | `URL.createObjectURL` + `<img>` | ≤ 20 Mo | Icône stylisée |
| **PDF** | PDF.js (`pdfjs-dist`, lazy-loadé) | Desktop ≤ 50 Mo / Mobile ≤ 10 Mo | Backend thumbnail |
| **DOCX / PPTX** | `docx-preview` (lazy-loadé) | ≤ 5 Mo | Icône stylisée MIME |
| **XLSX** | — | — | Icône stylisée MIME |
| **Autres** | — | — | Icône générique |

**Lazy-loading :** les deux libs (pdfjs-dist ~3 Mo, docx-preview ~500 Ko) ne sont chargées
que lors du premier fichier correspondant. Aucun impact sur le temps de chargement initial.

```typescript
// Exemple : chargement à la demande
const { getDocument, GlobalWorkerOptions } = await import('pdfjs-dist');
GlobalWorkerOptions.workerSrc = '/assets/pdf.worker.min.js';
```

---

### Backend — Endpoint thumbnail pour fichiers lourds

**Route :** `POST /api/v1/preview/thumbnail`

**Comportement :**
- Accepte un PDF en multipart (ou un chunk des premiers Mo)
- Rend uniquement la **page 0** via PDFBox `PDFRenderer.renderImageWithDPI(0, 96)`
- Retourne un PNG 200 × 280 px (400 × 560 à 2x pour les écrans Retina)
- Traitement : 15–40 ms (une seule page, pas tout le document)
- Authentification : accès anonyme autorisé (l'aperçu ne divulgue rien de plus
  que ce que l'utilisateur vient de choisir)
- Cache Redis : clé = `preview:{sha256(premiers 64 Ko du fichier)}`, TTL 1h

**Plan de validation côté backend :**
1. Taille max acceptée en entrée : 2 Go (limite HTTP)
2. PDFBox utilise un `RandomAccess` en streaming → n'alloue pas tout en RAM
3. Timeout endpoint : 10 s max (sinon placeholder côté frontend)

---

### Nouvelle architecture frontend

```
kovixel-ui/src/app/shared/
  components/
    file-preview/
      file-preview.component.ts        ← composant principal (réutilisé partout)
      file-preview.component.html
    preview-placeholder/
      preview-placeholder.component.ts ← icônes de fallback par MIME
  services/
    file-preview.service.ts            ← logique PDF.js, détection device, fallback backend
```

**API du composant `FilePreviewComponent` :**

```typescript
@Input()  file: File;
@Input()  maxWidth: number = 200;          // largeur en px
@Input()  maxHeight: number = 280;         // hauteur en px
@Input()  clickToExpand: boolean = false;  // modale agrandie au clic (Phase 2)
@Output() previewReady = new EventEmitter<'ok' | 'placeholder' | 'error'>();
```

**États internes :**
```
IDLE → LOADING → READY
               ↘ PLACEHOLDER (fallback)
               ↘ ERROR
```

---

### UX — Dropzone transformée

**Avant sélection (état actuel) :**
```
┌──────────────────────────────────────┐
│                                      │
│   ☁  Glissez votre fichier ici       │
│      ou  [ Parcourir ]               │
│                                      │
└──────────────────────────────────────┘
```

**Après sélection (nouvel état) :**
```
┌──────────────────────────────────────┐
│  ┌──────────┐                        │
│  │          │  rapport-q3.pdf        │
│  │  aperçu  │  2,4 Mo · PDF · 12 p. │
│  │  page 1  │                        │
│  │          │  ↺ Changer le fichier  │
│  └──────────┘                        │
└──────────────────────────────────────┘
```

Pendant le rendu PDF (< 2 s) :
```
│  ┌──────────┐
│  │ ░░░░░░░░ │  ← skeleton animé
│  │ ░░░░░░░░ │
│  │ ░░░░░░░░ │
│  └──────────┘
```

**Spécifications visuelles de la vignette :**
- Ombre portée légère (effet "document physique") : `box-shadow: 0 4px 16px rgba(0,0,0,0.18)`
- Border-radius : 4px (look document)
- Ratio : 1/√2 (format A4) si PDF/DOCX, natif si image
- Fond blanc même en dark mode (le document lui-même est blanc)

---

### Gestion mémoire (point critique)

```typescript
// Obligatoire pour éviter les fuites mémoire
ngOnDestroy() {
  if (this.objectUrl) URL.revokeObjectURL(this.objectUrl);
  if (this.pdfDocument) this.pdfDocument.destroy();
}
```

---

### Accessibilité

- `<img alt="Aperçu page 1 de {filename}">` sur le canvas converti
- Focus visible sur "Changer le fichier"
- `aria-live="polite"` sur la zone de statut du rendu

---

## Sprint B — Multi-upload et traitement par lot

### Objectif

Permettre aux utilisateurs de déposer plusieurs fichiers à la fois, de les voir
tous en vignette, de les traiter en séquence (ou en parallèle), et de télécharger
les résultats individuellement ou groupés en ZIP.

---

### Limites par plan

À ajouter dans `PlanConfig.java` :

```java
int maxBatchFiles();
```

| Plan | `maxBatchFiles` | Notes |
|---|---|---|
| Anonyme | 1 | Pas de batch — UX inchangée |
| FREE | 3 | Limité par quota journalier |
| PRO | 20 | Soumis au quota 200/jour |
| PRO_PLUS | 50 | Quota illimité |
| TEAM | -1 (illimité) | Quota org |
| ENTERPRISE | -1 (illimité) | Sur contrat |

Ces limites sont imposées **à la fois côté frontend** (UI désactivée) et
**côté backend** (validation au moment du submit).

---

### Architecture de traitement

**Phase B.1 — Séquentiel (MVP)**

Le client envoie les fichiers un par un aux endpoints existants, sans aucun
changement backend. La logique de séquencement est entièrement côté frontend.

```
[File 1] ──→ API ──→ résultat 1
[File 2]       ──→ API ──→ résultat 2
[File 3]             ──→ API ──→ résultat 3
```

**Phase B.2 — Concurrent (qualité production)**

Max 3 requêtes simultanées, configurable par plan :
- FREE : 1 concurrent (pour ne pas saturer le quota)
- PRO+ : 3 concurrent

```
[File 1] ──→ API ─────────┐
[File 2] ──→ API ──────┐  │ → tous complétés
[File 3] ──→ API ──┐   │  │
                   └───┴──┘
```

---

### Architecture frontend

```
kovixel-ui/src/app/shared/
  components/
    multi-file-dropzone/
      multi-file-dropzone.component.ts   ← remplace file-dropzone pour les outils
                                           qui supportent le multi
    file-queue-item/
      file-queue-item.component.ts       ← vignette + barre de progression par fichier
    batch-result/
      batch-result.component.ts          ← résultats groupés + téléchargement ZIP
  services/
    file-queue.service.ts                ← machine d'état de la file, séquencement
```

**`FileQueueService` — machine d'état par fichier :**

```typescript
type FileStatus = 'pending' | 'processing' | 'done' | 'error';

interface QueueItem {
  file: File;
  status: FileStatus;
  progress: number;           // 0–100
  resultUrl?: string;         // URL de téléchargement du résultat
  resultBlob?: Blob;
  error?: string;
}
```

---

### UX — Dropzone multi-fichiers

**Sélection :**
```
┌──────────────────────────────────────────────────────────┐
│  📂 Glissez vos fichiers ici ou [ Sélectionner ] · max 20│
│                                                          │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐        │
│  │ aperçu │  │ aperçu │  │ aperçu │  │ + Ajouter        │
│  │  [1]   │  │  [2]   │  │  [3]   │  │        │        │
│  │doc1.pdf│  │doc2.pdf│  │img.png │  │        │        │
│  │ 1,2 Mo │  │ 845 Ko │  │ 200 Ko │  └────────┘        │
│  │   ✕    │  │   ✕    │  │   ✕    │                    │
│  └────────┘  └────────┘  └────────┘                    │
│                                                          │
│  [ Convertir 3 fichiers → ]                             │
└──────────────────────────────────────────────────────────┘
```

**Pendant le traitement :**
```
│  ┌────────┐  ┌────────┐  ┌────────┐
│  │ aperçu │  │ aperçu │  │ aperçu │
│  │  [1]   │  │  [2]   │  │  [3]   │
│  │████░░░░│  │████████│  │░░░░░░░░│
│  │  48%   │  │  ✅ OK  │  │ Attente│
│  │        │  │ ↓ DL   │  │        │
│  └────────┘  └────────┘  └────────┘
│
│  2 / 3 fichiers traités
│  [ ↓ Télécharger tout (.zip) ]    ← disponible dès le 1er résultat
```

**Après traitement complet :**
```
│  ✅ 3 fichiers convertis avec succès
│  [ ↓ Télécharger tout (.zip) ]
│  [ ↺ Nouveau lot ]
```

---

### Gestion des erreurs au milieu d'un lot

Si un fichier échoue (ex. PDF corrompu) :
- Les autres fichiers continuent de se traiter
- Le fichier en erreur affiche un message + bouton "Réessayer"
- Le résumé final indique "2 / 3 fichiers traités (1 erreur)"
- Le ZIP inclut uniquement les fichiers traités avec succès

Si le quota journalier est atteint en cours de lot :
- La file s'arrête proprement
- Les fichiers déjà traités restent disponibles au téléchargement
- Bandeau : "Quota journalier atteint — passez à PRO pour traiter plus de fichiers"

---

### Téléchargement ZIP — côté client

Utilisation de `JSZip` (~100 Ko) pour assembler le ZIP dans le navigateur.
Pas de nouvel endpoint backend. Les blobs de résultats sont déjà en mémoire.

```typescript
import JSZip from 'jszip';

async downloadAll(items: QueueItem[]): Promise<void> {
  const zip = new JSZip();
  for (const item of items.filter(i => i.status === 'done')) {
    zip.file(item.resultFilename, item.resultBlob!);
  }
  const blob = await zip.generateAsync({ type: 'blob' });
  // trigger download
}
```

---

### Responsive (mobile)

- 2 colonnes de vignettes sur mobile (< 640 px)
- 3–4 colonnes sur tablette/desktop
- Scroll horizontal uniquement si le nombre de fichiers dépasse l'espace visible
- La barre de progression reste lisible sur une vignette de 120 px de large

---

## Benchmarks qualité cibles

| Critère | Cible | Référence marché |
|---|---|---|
| Preview PDF < 50 Mo (desktop) | < 1 s | ILovePDF : ~1,5 s |
| Preview PDF 50–100 Mo via backend | < 2 s | SmallPDF : ~2–3 s |
| Preview image | < 200 ms | Standard natif |
| Traitement 3 fichiers séquentiel | ≤ 3 × temps unitaire + 200 ms overhead | — |
| Assemblage ZIP 10 fichiers | < 500 ms client-side | — |
| Mémoire (après destroy) | 0 fuite (revokeObjectURL + pdfDoc.destroy) | — |
| Mobile 3G — preview PDF 5 Mo | < 3 s (avec skeleton) | — |
| Accessibilité | WCAG 2.1 AA | — |
| Grille responsive | 2 col mobile / 4 col desktop | ILovePDF |

---

## Séquence d'implémentation recommandée

```
Sprint A.1  FilePreviewService (logique taille + device, PDF.js, image)
Sprint A.2  FilePreviewComponent (canvas, skeleton, placeholder)
Sprint A.3  Backend /preview/thumbnail (PDFBox, cache Redis)
Sprint A.4  Intégration dans le composant file-dropzone existant
Sprint A.5  Tests : mobile crash, grands fichiers, formats exotiques, mémoire

Sprint B.1  Ajout maxBatchFiles dans PlanConfig + enforcement backend
Sprint B.2  FileQueueService (machine d'état, séquencement)
Sprint B.3  FileQueueItemComponent (vignette + progress bar)
Sprint B.4  MultiFileDropzoneComponent
Sprint B.5  BatchResultComponent + JSZip
Sprint B.6  Intégration sur les outils compatibles (conversion, compression, merge…)
Sprint B.7  Tests : quota mi-lot, erreur fichier, responsive, perf 20 fichiers
```

---

## Ce qui n'est PAS dans ce périmètre

- Réorganisation des fichiers par drag-and-drop dans la grille (Phase 3)
- Preview de la page N (autre que page 1) — Phase 3
- Preview en temps réel pendant upload réseau — hors scope
- Déduplication de fichiers identiques dans un lot — Phase 3
- Endpoint batch côté backend — Phase 3 (séquentiel suffit pour le MVP)
