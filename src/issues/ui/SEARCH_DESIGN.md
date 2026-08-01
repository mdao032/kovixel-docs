# Kovixel — Moteur de Recherche Intelligent (Tools Catalog)

## Contexte

La barre de recherche du catalogue d'outils (`kov-tools-catalog`) était une simple correspondance `String.includes()`, sans scoring, sans tolérance aux fautes, sans hiérarchisation des résultats.

---

## Architecture retenue

```
src/app/
├── core/
│   ├── config/
│   │   └── tools-config.ts        ← Ajout du champ keywords[] par outil
│   └── utils/
│       └── tools-search.ts        ← Moteur de recherche pur (zero dépendance)
└── features/
    └── tools/
        └── tools-catalog.component.ts  ← Intégration : search + command palette
```

---

## Les 5 Couches

### Couche 1 — Scoring de pertinence

Chaque résultat reçoit un score numérique. Les résultats sont triés par score décroissant.

| Correspondance | Points |
|---|---|
| Nom = requête exacte | 100 |
| Nom commence par la requête | 80 |
| Nom contient la requête | 60 |
| Nom fuzzy-match | 45 |
| Mot-clé exact | 55 |
| Mot-clé contient | 40 |
| Mot-clé fuzzy | 25 |
| Description courte contient | 35 |
| Description courte fuzzy | 18 |
| Description longue contient | 15 |
| Description longue fuzzy | 8 |
| Catégorie exacte | 30 |

### Couche 2 — Mots-clés / Alias par outil

Chaque outil dispose d'un champ `keywords: string[]` dans `tools-config.ts`.  
Exemples :

```typescript
// PDF → Word
keywords: ['docx', 'doc', 'word', 'microsoft', 'éditable', 'modifiable']

// Compresser
keywords: ['réduire', 'taille', 'poids', 'optimiser', 'alléger', 'email']

// Résumé IA
keywords: ['résumer', 'synthèse', 'summary', 'abstract', 'tldr', 'points clés']
```

### Couche 3 — Multi-mots + tolérance aux fautes (Levenshtein)

- La requête est découpée en tokens (`"pdf word"` → `["pdf", "word"]`)
- **Tous les tokens** doivent matcher pour qu'un outil apparaisse
- Tolérance via distance de Levenshtein :
  - Token de 4-5 chars : ≤ 1 faute  (`"wrod"` trouve `"word"`)
  - Token de 6+ chars  : ≤ 2 fautes (`"copresser"` trouve `"compresser"`)
  - Token < 4 chars    : exact uniquement

```
Algorithme : O(m×n) espace O(n) — implémenté sans dépendance externe (~20 lignes)
```

### Couche 4 — Surbrillance des correspondances

La fonction `buildSegments(text, tokens)` retourne un tableau de `Segment[]` :

```typescript
interface Segment { text: string; match: boolean; }

// "PDF vers Word" avec token "word" →
[
  { text: "PDF vers ",  match: false },
  { text: "Word",       match: true  },
]
```

Le template affiche les segments `match: true` dans un `<mark class="search-mark">`.

### Couche 5 — Raccourcis catégories

Taper un raccourci dans la barre filtre instantanément par catégorie :

| Raccourci | Catégorie |
|---|---|
| `@ia` ou `@ai` | IA |
| `@convert` | Convertir |
| `@compress` | Compresser |
| `@extract` | Extraire |

---

## Command Palette (Ctrl+K)

Interface style "macOS Spotlight / GitHub Command Palette".

```
┌─────────────────────────────────────────────────────┐
│  🔍  Rechercher un outil...                    Esc  │
├─────────────────────────────────────────────────────┤
│  OUTILS DISPONIBLES                                 │
│  ────────────────────────────────────────────────── │
│  🔄  Word → PDF          Convertissez Word en PDF   │ ← item actif
│  🔄  PDF → Word          PDF en document éditable   │
│  ⚡  Compresser PDF       Réduisez la taille...      │
│  ✨  Résumé IA            Résumé intelligent...      │
│  ...                                                │
├─────────────────────────────────────────────────────┤
│  ↑↓ naviguer   ↵ ouvrir   Esc fermer               │
└─────────────────────────────────────────────────────┘
```

### Comportement

| Action | Résultat |
|---|---|
| `Ctrl+K` | Ouvre la palette |
| `Ctrl+K` (palette ouverte) | Ferme la palette |
| `Esc` | Ferme la palette |
| `↑` / `↓` | Navigate entre les résultats |
| `↵` | Ouvre l'outil sélectionné |
| Clic backdrop | Ferme la palette |
| Hover résultat | Sélectionne visuellement |

### Résultats par défaut (query vide)

Affiche les outils disponibles triés par badge : POPULAR → FAST → NEW → autres.

### Résultats avec query

Utilise le même moteur `searchTools()` que le catalogue, max 8 résultats,  
avec surbrillance dans le nom et la description.

---

## API du moteur (`tools-search.ts`)

```typescript
// Recherche principale
searchTools(tools: Tool[], query: string, opts?: SearchOptions): SearchResult[]

// Segmentation pour surbrillance
buildSegments(text: string, tokens: string[]): Segment[]

// Détection de raccourci catégorie
parseCategoryShortcut(query: string): ToolCategory | null
```

---

## Réactivité (Angular Signals)

- `query` est un **signal** (`signal<string>('')`) → `filteredResults` computed est correctement invalidé à chaque frappe
- `paletteQuery` est un signal séparé pour la palette
- Pas de `debounce` nécessaire (17 outils, traitement < 1ms)

---

## Fichiers modifiés

| Fichier | Changements |
|---|---|
| `tools-config.ts` | Ajout `keywords?: string[]` sur `Tool` + valeurs pour chaque outil |
| `tools-search.ts` | **Nouveau** — moteur de recherche pur |
| `tools-catalog.component.ts` | Intégration moteur + signals + palette + highlights |

