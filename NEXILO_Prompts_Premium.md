# KOVIXEL — Prompts Claude Code · Refonte Premium
# Basé sur kovixel-ui (Next.js · violet) + kovixel (Spring Boot)
# Fichier de référence — exécuter prompt par prompt dans l'agent IA Claude (IntelliJ ou VS Code)

---

## MODE D'EMPLOI

1. **Ouvre Claude Code** dans ton IDE (IntelliJ ou VS Code)
2. **Colle un prompt à la fois**, dans l'ordre des phases
3. **Valide visuellement** avant de passer au suivant
4. **Committe** après chaque phase : `git commit -m "feat: phase X - ..."`
5. Les prompts sont **auto-suffisants** : Claude Code lira ton code existant avant d'agir

---

## CONTEXTE À COLLER UNE FOIS AU DÉBUT DE CHAQUE SESSION

```
Contexte projet Kovixel :
- Frontend : Next.js 14 App Router, TypeScript, Tailwind CSS, palette violet
- Backend : Spring Boot 3.4 Java 21, port 8080, API prefix /api/v1
- Fonctionnalités backend actives : résumé PDF, Q&A RAG, auth JWT
- Style : dark theme, violet (#7c3aed primaire), glassmorphism, font Syne (display) + Outfit (body)
- Repo frontend : kovixel-ui | Repo backend : kovixel
- Objectif : SaaS premium à forte conversion (style Stripe / Vercel / Notion)
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 1 — AUDIT & FONDATIONS
## ═══════════════════════════════════════════════════════════

### PROMPT 1.1 — Audit complet du projet existant

```
Analyse le projet Next.js kovixel-ui dans son état actuel.

Dresse un rapport précis de :
1. Structure des fichiers et dossiers (src/app/, components/, hooks/, lib/)
2. Routes existantes (pages créées)
3. Composants UI déjà implémentés
4. Configuration Tailwind (couleurs custom, fonts, animations)
5. Dépendances installées dans package.json
6. Ce qui est déjà branché sur l'API backend (/api/v1/*)
7. Ce qui est statique / mocké (pas encore branché)

Produis une liste "Ce qui existe ✅ / Ce qui manque ❌" 
que je puisse utiliser comme checklist pour la suite.

NE modifie rien pour l'instant — audit uniquement.
```

---

### PROMPT 1.2 — Réorganisation de l'architecture des routes

```
Réorganise l'architecture des routes Next.js 14 (App Router) de kovixel-ui
selon ce plan cible :

ROUTES PUBLIQUES (sans auth) :
  /                    → Landing marketing (à créer)
  /tools               → Grille de tous les outils (déplacer depuis /)
  /tools/[tool]        → Outil individuel (drag & drop + résultat)
  /pricing             → Tarifs (à créer)
  /auth/login          → Login (renommer si besoin)
  /auth/register       → Inscription (à créer si absent)

ROUTES PROTÉGÉES (avec auth JWT) :
  /dashboard           → Vue principale après login
  /documents           → Liste des documents
  /documents/[id]      → Détail document (résumé + Q&A + extraction)
  /upload              → Upload dédié
  /settings            → Paramètres utilisateur

Actions à effectuer :
1. Crée les dossiers manquants dans src/app/
2. Dans chaque dossier manquant, crée un fichier page.tsx avec un placeholder :
   - Un <h1> indiquant le nom de la page
   - Un commentaire // TODO: implémenter avec les prompts suivants
3. Crée src/app/(public)/layout.tsx et src/app/(protected)/layout.tsx
   pour séparer les layouts auth/no-auth
4. Crée src/middleware.ts pour protéger les routes /dashboard, /documents, /upload, /settings
   via le JWT stocké dans les cookies (next/server)
5. NE touche pas au code existant des composants — seulement la structure de routes

Montre-moi l'arborescence finale avant d'écrire quoi que ce soit.
```

---

### PROMPT 1.3 — Système de design tokens global

```
Crée le système de design tokens complet pour Kovixel dans src/lib/design-tokens.ts.

Ce fichier est la SOURCE DE VÉRITÉ de toute l'UI — tout le reste s'y référera.

Inclus :

1. COULEURS (violet + neutres dark)
   - Palette violet : 50 à 950 (hex précis)
   - Surfaces dark : bg-base (#030014), bg-surface, bg-elevated, bg-card
   - Borders : avec opacité rgba
   - Texte : primary, secondary, muted, disabled
   - Sémantiques : success (green), warning (amber), danger (red), info (blue)

2. TYPOGRAPHIE
   - Font display : Syne (headings, logo, hero)
   - Font body : Outfit (texte courant)
   - Font mono : JetBrains Mono (code, stats)
   - Scale : xs(11) sm(13) md(15) lg(17) xl(20) 2xl(24) 3xl(30) 4xl(36) 5xl(48) 6xl(64)

3. ESPACEMENTS
   - Scale : 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64

4. BORDER RADIUS
   - sm(6px), md(10px), lg(16px), xl(24px), 2xl(32px), full(9999px)

5. OMBRES
   - violet-sm, violet-md, violet-lg, violet-glow, card, none

6. ANIMATIONS (durations + easings)
   - fast(150ms), normal(250ms), slow(400ms), verySlow(600ms)
   - easing: spring, smooth, snappy

7. BREAKPOINTS
   - sm(640), md(768), lg(1024), xl(1280), 2xl(1536)

Exporte aussi des helpers Tailwind className comme :
  export const tw = {
    cardBase: "...",
    btnPrimary: "...",
    btnGhost: "...",
    inputBase: "...",
    badge: { violet: "...", green: "...", amber: "...", red: "..." },
    glassMorphism: "...",
    textGradient: "...",
  }

Ensuite, mets à jour tailwind.config.ts pour que tous ces tokens
soient disponibles en tant que classes Tailwind.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 2 — LANDING PAGE MARKETING
## ═══════════════════════════════════════════════════════════

### PROMPT 2.1 — Hero Section (section 1/8)

```
Crée le composant HeroSection dans src/components/landing/HeroSection.tsx.

CONTEXTE : C'est la première chose que l'utilisateur voit.
Objectif : Capturer l'attention en < 3 secondes et pousser à l'action.

CONTENU :
- Badge animé : "✦ Propulsé par l'IA · 100% sécurisé"
- Titre principal (h1) :
  "Transformez vos documents
   en quelques secondes."
  → Le mot "documents" en dégradé violet animé
- Sous-titre :
  "Convertissez, compressez, résumez et interrogez vos PDFs.
   Sans inscription. Sans friction. Sans limite."
- Deux CTAs :
  [Commencer gratuitement →] (bouton violet primary, grand, avec glow)
  [Voir les outils ↓]        (ghost, scroll vers la section tools)
- Social proof immédiat sous les CTAs :
  "✓ +10 000 fichiers traités aujourd'hui  ·  ✓ Aucun stockage  ·  ✓ Gratuit"

VISUEL HERO :
- Crée une animation CSS pure représentant un PDF qui se transforme :
  → apparaît à gauche (icône PDF avec glow violet)
  → flèches animées vers la droite
  → 3 icônes résultats : Word, Résumé IA, Données extraites
  → effet de particules violettes subtiles autour
- Place ce visuel à droite du texte (layout 50/50 sur desktop, empilé mobile)

ANIMATIONS D'ENTRÉE :
- Badge : fadeIn + slideDown delay 0ms
- H1 : fadeIn + slideUp delay 100ms mot par mot (stagger)
- Sous-titre : fadeIn delay 300ms
- CTAs : fadeIn + scale delay 500ms
- Visuel : fadeIn + float delay 200ms
- Social proof : fadeIn delay 700ms

TECH : framer-motion pour les animations, Tailwind pour le style.
Dark background avec mesh gradient violet derrière le hero.
Responsive : mobile-first.
```

---

### PROMPT 2.2 — Social Proof & Statistiques (section 2/8)

```
Crée le composant SocialProofSection dans src/components/landing/SocialProofSection.tsx.

LAYOUT : Bande horizontale pleine largeur entre le hero et la section tools.

CONTENU :
Ligne 1 — Stats animées au scroll (CountUp quand visible) :
  [ +47 000 ]     [ +180 ]      [ 99.9% ]      [ < 3s ]
  fichiers traités  formats      uptime          temps moyen
  ce mois

Ligne 2 — Logos de confiance (placeholder SVG) :
  "Ils nous font confiance"
  [Logo 1] [Logo 2] [Logo 3] [Logo 4] [Logo 5]
  → logos en opacity 40% par défaut, 70% au hover
  → défilement infini horizontal (marquee CSS) sur mobile

STYLE :
- Fond : légèrement différent du hero (bg-surface avec border top et bottom en violet/10)
- Stats : chiffres en font-display bold très grand (48px), label en small muted
- Séparateur visuel entre chaque stat : ligne verticale violet/20

ANIMATION :
- CountUp : utilise l'Intersection Observer pour déclencher le compteur
  quand la section entre dans le viewport
- Duration : 2s avec easing expo-out
- Implémente le CountUp en vanilla JS (pas de lib externe)
```

---

### PROMPT 2.3 — Grille des outils Preview (section 3/8)

```
Crée le composant ToolsPreviewSection dans src/components/landing/ToolsPreviewSection.tsx.

OBJECTIF : Montrer tous les outils disponibles de façon visuelle et interactive.
Un utilisateur doit pouvoir cliquer sur un outil et être immédiatement opérationnel.

STRUCTURE :

1. En-tête section :
   Badge "Tous les outils"
   Titre : "Tout ce dont vos documents ont besoin"
   Filtre par catégorie (tabs) :
   [Tous] [Convertir] [Compresser] [IA] [Extraire]
   → filtre animé avec framer-motion layout

2. Grille d'outils (4 colonnes desktop, 2 tablette, 1 mobile) :

   CATÉGORIE "Convertir" :
   - PDF → Word       (icône: FileText→FileEdit)   badge: RAPIDE
   - PDF → Images     (icône: FileText→Image)       badge: -
   - PDF → Excel      (icône: FileText→Table)        badge: -
   - Word → PDF       (icône: FileEdit→FileText)    badge: -
   - Excel → PDF      (icône: Table→FileText)        badge: -
   - Images → PDF     (icône: Image→FileText)        badge: -

   CATÉGORIE "Compresser" :
   - Compresser PDF   (icône: Minimize2)             badge: POPULAIRE
   - Fusionner PDF    (icône: Merge)                 badge: -
   - Diviser PDF      (icône: Scissors)              badge: -
   - Rotation PDF     (icône: RotateCw)              badge: -

   CATÉGORIE "IA" :
   - Résumé IA        (icône: Sparkles)              badge: IA · PRO
   - Q&A document     (icône: MessageSquare)          badge: IA · PRO
   - Extraction data  (icône: Database)               badge: IA · PRO
   - Traduction IA    (icône: Languages)              badge: IA · BIENTÔT

   CATÉGORIE "Extraire" :
   - Extraire images  (icône: ImageDown)              badge: -
   - Extraire texte   (icône: AlignLeft)              badge: -
   - Extraire tableau (icône: Table2)                 badge: PRO

3. Chaque ToolCard :
   - Icône (Lucide) dans un carré violet/15 avec border violet/20
   - Nom de l'outil (font-semibold)
   - Description courte (1 ligne, text-muted)
   - Badge dans le coin (NEW / PRO / RAPIDE / BIENTÔT / POPULAIRE)
   - Au HOVER :
     * border passe à violet/40
     * icône prend un glow violet
     * translateY(-4px) avec transition spring
     * apparition d'une flèche → en bas à droite
   - Au CLIC : router.push vers /tools/[tool-slug]

4. CTA bas de section :
   "Voir tous les outils →" → /tools

TECH : framer-motion (AnimatePresence pour le filtre), Lucide icons, Tailwind.
```

---

### PROMPT 2.4 — Section IA Différenciation (section 4/8)

```
Crée le composant AiSection dans src/components/landing/AiSection.tsx.

OBJECTIF : C'est la section qui différencie Kovixel des concurrents.
Elle doit créer un effet "wow" sur l'IA.

LAYOUT : 2 colonnes. Gauche = texte. Droite = démo visuelle animée.

CONTENU GAUCHE :
- Badge : "⚡ Boosté par l'Intelligence Artificielle"
- Titre : "Votre PDF devient une source de connaissances"
- Sous-titre : "Plus qu'un convertisseur — un assistant documentaire."
- 3 features avec icône + texte :
  ◆ Résumé automatique
    "Obtenez l'essentiel d'un document de 100 pages en 30 secondes."
  ◆ Interrogez vos données
    "Posez des questions en langage naturel. L'IA trouve les réponses."
  ◆ Extraction structurée
    "Extrayez automatiquement les données de vos factures, contrats, CV."
- CTA : [Essayer gratuitement →] → /auth/register

CONTENU DROITE (animation CSS/framer-motion) :
Simule un vrai écran de chat Q&A avec un PDF :

1. Une fausse fenêtre d'app (rounded-2xl, border violet, glassmorphism)
2. Header : "Rapport_annuel_2024.pdf · 142 pages"
3. Zone de chat :
   Message USER (bulles droite) : "Quel est le chiffre d'affaires du Q3 ?"
   → apparaît avec animation slide-in-right
   Message AI (bulles gauche avec badge "Kovixel IA") :
   → texte qui s'écrit caractère par caractère (typing effect)
   → "Le chiffre d'affaires du Q3 2024 est de 4,2M€,
      soit une hausse de 23% par rapport à Q3 2023..."
4. En bas : input avec placeholder "Posez votre question…"
5. Cette animation tourne en boucle (3 questions différentes)
   avec un léger fondu entre chaque cycle

STYLE : Fond de la section avec un gradient violet très subtil différent des autres sections.
```

---

### PROMPT 2.5 — Section Confiance & Sécurité (section 5/8)

```
Crée le composant TrustSection dans src/components/landing/TrustSection.tsx.

OBJECTIF : Rassurer l'utilisateur sur la sécurité de ses données.
C'est CRUCIAL pour un outil qui traite des documents professionnels.

LAYOUT : Grille 3 colonnes desktop, 1 colonne mobile.

CONTENU :

Titre section : "Vos documents entre de bonnes mains"

3 cartes de confiance :

🔒 Suppression automatique
"Vos fichiers sont définitivement supprimés de nos serveurs
après traitement. Aucun stockage permanent."
→ Icône : Shield (Lucide)

⚡ Sans inscription
"Utilisez tous les outils de base instantanément,
sans créer de compte. Juste uploader et convertir."
→ Icône : Zap

🔐 Traitement sécurisé
"Transfert chiffré (TLS 1.3). Traitement isolé.
Conformité RGPD."
→ Icône : Lock

En bas : bandeau de certifications/garanties :
"✓ HTTPS  ·  ✓ TLS 1.3  ·  ✓ RGPD  ·  ✓ Données en France  ·  ✓ Open Source"

STYLE :
- Fond légèrement différent (bg-elevated)
- Cards avec un léger border vert (success) pour l'effet rassurant
- Icônes dans un cercle vert/15 avec border vert/20
- Titre de chaque card en vert clair
```

---

### PROMPT 2.6 — Section Pricing Preview (section 6/8)

```
Crée le composant PricingPreviewSection dans src/components/landing/PricingPreviewSection.tsx.

OBJECTIF : Montrer les tarifs directement sur la landing pour accélérer la conversion.

LAYOUT : 3 colonnes (FREE · PRO · ENTERPRISE), toggle mensuel/annuel (-20%).

Plans :

FREE (gratuit) :
- 10 conversions / jour
- Outils de base (convert, compress, merge, split)
- Fichiers jusqu'à 10 MB
- Support communauté
→ CTA : [Commencer gratuitement]

PRO (9€/mois ou 7€/mois annuel) :
- Conversions illimitées
- Tous les outils IA (résumé, Q&A, extraction)
- Fichiers jusqu'à 100 MB
- Traitement prioritaire
- Support email
→ CTA : [Démarrer l'essai 14 jours] (highlight — badge "POPULAIRE")
→ "Aucune CB requise"

ENTERPRISE (sur devis) :
- Tout PRO +
- API access
- White-label
- SLA garanti 99.9%
- Déploiement on-premise
→ CTA : [Nous contacter]

DESIGN :
- Card PRO : border violet fort (2px), léger glow violet, badge "POPULAIRE" en amber
- Toggle mensuel/annuel : pill animé (framer-motion)
- Chaque feature avec icône ✓ en violet
- Lien "Comparer tous les plans →" vers /pricing

TECH : useState pour toggle, framer-motion pour les transitions de prix.
```

---

### PROMPT 2.7 — CTA Final & Footer (sections 7 et 8/8)

```
Crée deux composants :

A) CtaSection dans src/components/landing/CtaSection.tsx

Section d'appel à l'action finale avant le footer.

CONTENU :
- Fond : gradient violet fort (from-violet-950 to-violet-900) avec particules CSS
- Titre grand (48px) : "Prêt à transformer vos documents ?"
- Sous-titre : "Rejoignez +10 000 professionnels qui gagnent du temps chaque jour."
- 2 CTAs :
  [Créer un compte gratuit] (blanc sur violet — inversé)
  [Voir une démo]          (ghost blanc)
- 3 micro-arguments en ligne :
  "✓ Gratuit pour toujours  ·  ✓ Aucune CB  ·  ✓ Annulable à tout moment"


B) Footer dans src/components/layout/Footer.tsx

STRUCTURE (4 colonnes) :

Col 1 — Brand :
Logo Kovixel + tagline courte
"La plateforme documentaire intelligente."
Liens réseaux sociaux (Twitter/X, GitHub, LinkedIn)

Col 2 — Produit :
- Outils
- Tarifs
- API (bientôt)
- Changelog

Col 3 — Entreprise :
- À propos
- Contact
- Blog (bientôt)
- Carrières (bientôt)

Col 4 — Légal :
- Confidentialité
- Conditions d'utilisation
- RGPD
- Cookies

BOTTOM BAR :
"© 2026 Kovixel. Tous droits réservés."  |  "Fabriqué avec ♥ en France"

STYLE :
- Fond : bg-surface avec border top violet/20
- Liens : text-muted → text-primary au hover avec underline violet
- Responsive : 2 colonnes tablette, 1 mobile
```

---

### PROMPT 2.8 — Assemblage de la Landing Page

```
Assemble tous les composants créés dans src/app/page.tsx (ou (public)/page.tsx).

La page / doit composer dans l'ordre :

import HeroSection         from '@/components/landing/HeroSection'
import SocialProofSection  from '@/components/landing/SocialProofSection'
import ToolsPreviewSection from '@/components/landing/ToolsPreviewSection'
import AiSection           from '@/components/landing/AiSection'
import TrustSection        from '@/components/landing/TrustSection'
import PricingPreviewSection from '@/components/landing/PricingPreviewSection'
import CtaSection          from '@/components/landing/CtaSection'
import Footer              from '@/components/layout/Footer'

Ajoute aussi :
1. Un composant Navbar fixe en haut :
   - Logo Kovixel (gauche)
   - Liens navigation : Outils · Tarifs · À propos (centre, hidden mobile)
   - Boutons : [Connexion] [Commencer] (droite)
   - Fond transparent → glassmorphism au scroll (useEffect + addEventListener scroll)
   - Hamburger menu mobile (drawer latéral framer-motion)

2. Un ScrollProgress bar en haut de la page (fine ligne violette qui progresse)

3. Un bouton "Retour en haut" qui apparaît après 300px de scroll

4. Optimisations perf :
   - Chaque section dans un <section> avec id pour le scrollspy
   - Les sections sous le fold en lazy loading (dynamic() import)
   - metadata Next.js complète (title, description, og:image, twitter:card)

Assure-toi que la page est 100% responsive et fonctionne parfaitement sur mobile.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 3 — PAGE /tools (ORIENTÉE ACTION)
## ═══════════════════════════════════════════════════════════

### PROMPT 3.1 — Page /tools avec filtre et recherche

```
Crée la page src/app/tools/page.tsx — page utilitaire pure, sans distractions.

OBJECTIF : L'utilisateur arrive ici, trouve son outil en < 5 secondes, et l'utilise.

STRUCTURE :

1. Header minimaliste (pas le Navbar marketing) :
   - Logo Kovixel (petit, lien vers /)
   - Titre : "Tous les outils"
   - Compteur : "18 outils disponibles"

2. Barre de recherche (en haut, bien visible) :
   - Placeholder : "Rechercher un outil… (ex: PDF vers Word)"
   - Icône loupe à gauche
   - Raccourci clavier : Ctrl+K ou Cmd+K (focus automatique)
   - Résultats filtrés en temps réel (pas d'API, filtrage côté client)
   - Si 0 résultats : "Aucun outil trouvé pour '[query]' — suggérer un outil ?"

3. Filtre par catégorie (tabs) :
   [Tous (18)] [Convertir (6)] [Compresser (4)] [IA (4)] [Extraire (3)] [Autres (1)]
   → Soulignement animé (layoutId framer-motion)
   → Filtre les cards en temps réel

4. Grille d'outils :
   - Même ToolCard que la landing, mais :
     * Plus grande (plus d'espace)
     * Ajoute une ligne de description plus détaillée
     * Ajoute "Temps estimé : ~3 secondes" en bas de chaque card
     * PRO tools : overlay semi-transparent + "Débloquer avec PRO →"
   - Transition de filtre : AnimatePresence + layout framer-motion

5. État de chargement :
   - Skeleton de 12 cards pendant le premier rendu (shimmer violet)

Importe la liste des outils depuis src/lib/tools-config.ts
(crée ce fichier avec tous les outils définis comme tableau de constantes)

Type Tool :
  {
    slug: string
    name: string
    description: string
    longDescription: string
    category: 'convert' | 'compress' | 'ai' | 'extract'
    icon: LucideIcon
    badge?: 'NEW' | 'PRO' | 'FAST' | 'POPULAR' | 'SOON'
    estimatedTime: string
    isPro: boolean
    isAvailable: boolean
    backendEndpoint: string
  }
```

---

### PROMPT 3.2 — Page /tools/[tool] avec Upload & Résultat

```
Crée la page src/app/tools/[tool]/page.tsx — l'outil individuel.

OBJECTIF : Upload → Résultat en < 5 secondes. Zéro friction.

PARAMÈTRE : [tool] = le slug de l'outil (ex: "pdf-to-word", "compress", "summarize")

STRUCTURE :

1. Breadcrumb : Accueil → Outils → [Nom de l'outil]

2. Header de l'outil :
   - Grande icône dans un carré violet gradient (64px)
   - Titre : nom de l'outil
   - Description courte + badge (FREE / PRO / FAST)
   - "Traite jusqu'à 50 MB · Résultat en ~3 secondes · Supprimé après traitement"

3. Zone principale — DropZone :

   ÉTAT 1 — En attente d'upload :
   - Grande zone de drop (dashed border violet, height: 280px)
   - Icône Upload animée (float animation)
   - "Glissez votre fichier ici"
   - "ou [parcourir vos fichiers]" (lien)
   - Formats acceptés affichés : "PDF, DOCX, XLSX..."
   - Animation : quand un fichier passe au-dessus → border devient solid violet
     avec un effet de glow pulsant (drag-over state)

   ÉTAT 2 — Fichier sélectionné :
   - Preview : icône du fichier + nom + taille
   - Barre de progression (0%)
   - Bouton [Convertir maintenant →] (violet, grand)
   - Lien [Changer de fichier]

   ÉTAT 3 — En traitement :
   - Barre de progression animée (violet, 0% → 100%)
   - Messages rotatifs pendant l'attente :
     "Analyse du document..."
     "Traitement en cours..."
     "Optimisation du résultat..."
   - Spinner violet au centre

   ÉTAT 4 — Résultat prêt :
   - Animation de succès (check vert pulsant)
   - Nom du fichier résultat
   - Bouton [⬇ Télécharger] (grand, vert)
   - Bouton [Traiter un autre fichier]
   - Si outil IA (résumé) : afficher le résultat directement dans la page
     (pas juste télécharger)

   ÉTAT 5 — Erreur :
   - Icône erreur rouge
   - Message d'erreur clair (venant du backend)
   - Bouton [Réessayer]

4. Section "Outils similaires" (3 cards en bas)

LOGIQUE BACKEND :
- Lit la config de l'outil depuis tools-config.ts (backendEndpoint)
- Appelle le bon endpoint Spring Boot (/api/v1/convert/*, /api/v1/pdf/*)
- Gère le multipart/form-data upload avec onUploadProgress
- Déclenche le téléchargement automatique du blob résultat

TECH : react-dropzone, axios avec onUploadProgress, framer-motion pour les transitions d'état.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 4 — MICRO-INTERACTIONS & ANIMATIONS SIGNATURE
## ═══════════════════════════════════════════════════════════

### PROMPT 4.1 — Animation Upload Signature (effet identitaire Kovixel)

```
Crée l'animation signature de Kovixel dans src/components/ui/FileTransformAnimation.tsx.

C'est l'animation qui joue PENDANT le traitement d'un fichier.
Elle doit être MÉMORABLE et UNIQUE — l'identité visuelle forte de Kovixel.

ANIMATION (étapes, durée totale ~3 secondes) :

Phase 1 — Apparition du fichier (0 → 0.5s) :
- Icône PDF apparaît au centre, scale 0 → 1 avec spring bounce
- Un halo violet pulse autour

Phase 2 — Scan/Analyse (0.5 → 1.5s) :
- Une ligne de scan horizontale violet traverse le fichier de haut en bas
  (comme un scanner de sécurité)
- Des particules violettes s'échappent du fichier sur les côtés
- L'icône PDF vibre légèrement

Phase 3 — Transformation (1.5 → 2.5s) :
- L'icône PDF se "fragmente" (effet pixel/dissolve CSS)
- Les fragments se reforment en icône du format cible (Word, Image, etc.)
- Animation de rotation 360° avec blur pendant la transition

Phase 4 — Complétion (2.5 → 3s) :
- L'icône du format cible apparaît, scale 1 → 1.1 → 1 (bounce)
- Un check vert explose en confetti/particules autour
- Le texte "Prêt !" apparaît en dessous avec fadeIn

IMPLÉMENTATION :
- Utilise uniquement CSS animations + framer-motion (pas de canvas ni WebGL)
- Les particules sont des divs absolus avec animation keyframes aléatoire
- Passe les props : fromFormat (string), toFormat (string), onComplete (callback)
- Accepte un mode "loop" pour afficher pendant un traitement long

Intègre cette animation dans la DropZone de /tools/[tool] (ÉTAT 3).
```

---

### PROMPT 4.2 — Micro-interactions globales

```
Implémente les micro-interactions dans toute l'application kovixel-ui.

1. CURSOR PERSONNALISÉ (desktop uniquement) :
   Crée src/components/ui/CustomCursor.tsx
   - Cercle violet translucide qui suit la souris avec lag (lerp)
   - Au hover sur les boutons/liens → s'agrandit et change de couleur
   - Au hover sur les zones drag & drop → se transforme en "+"
   Ajoute-le dans le layout root

2. BOUTONS — améliore tous les boutons existants :
   - Au hover : légère élévation (translateY -2px) + glow violet
   - Au clic : scale 0.96 (press feedback)
   - Ripple effect : cercle qui s'expand depuis le point de clic
   Crée un hook useRipple.ts pour réutiliser facilement

3. CARDS — améliore toutes les cards :
   - Hover lift : translateY -4px + box-shadow violet
   - Effet spotlight : le gradient violet suit la souris sur la card
     (mousemove → calcul position → CSS custom property)
   Crée un hook useSpotlight.ts

4. CHAMPS INPUT :
   - Focus : border violet + glow subtil + label qui monte (floating label)
   - Error : shake animation (keyframes translateX)
   - Success : border vert + checkmark qui apparaît à droite

5. NAVIGATION :
   - Lien actif dans le sidebar : indicateur animé qui glisse (layoutId)
   - Page transitions : fade + slide entre les routes
     (ajoute dans le layout via AnimatePresence)

6. NOTIFICATIONS (toasts) :
   - Améliore react-hot-toast avec un style Kovixel custom
   - Apparaît par le bas droite avec slide + bounce
   - Fond glassmorphism violet
   - Icône animée selon le type (success/error/loading)

7. SCROLL :
   - Reveal au scroll : sections apparaissent avec fadeUp au scroll
     (créé un hook useScrollReveal.ts avec IntersectionObserver)
   - Parallax subtil sur le hero background (useScroll framer-motion)
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 5 — PAGE /pricing COMPLÈTE
## ═══════════════════════════════════════════════════════════

### PROMPT 5.1 — Page Pricing complète

```
Crée la page src/app/pricing/page.tsx complète.

STRUCTURE :

1. Header :
   - Badge : "Transparent et sans surprise"
   - Titre : "Un tarif simple. Tous les outils."
   - Sous-titre : "Commencez gratuitement. Passez en PRO quand vous êtes prêt."
   - Toggle Mensuel / Annuel avec badge "-20%"

2. Cards de pricing (3 colonnes) :
   
   FREE (0€) :
   ✓ 10 conversions / jour
   ✓ Formats de base (PDF ↔ Word, Images, Compress)
   ✓ Fichiers jusqu'à 10 MB
   ✓ Sans inscription pour les outils de base
   ✗ Outils IA
   ✗ Fichiers > 10 MB
   ✗ Traitement prioritaire
   → CTA : [Commencer gratuitement]

   PRO (9€/mois ou 87€/an) — HIGHLIGHT :
   Tout FREE, plus :
   ✓ Conversions illimitées
   ✓ Résumé IA
   ✓ Q&A sur vos documents
   ✓ Extraction de données
   ✓ Fichiers jusqu'à 100 MB
   ✓ Traitement prioritaire
   ✓ Support email < 24h
   ✓ Historique 30 jours
   → CTA : [Démarrer l'essai 14 jours]
   → "Annulable à tout moment · Aucune CB requise pour l'essai"

   ENTERPRISE (sur devis) :
   Tout PRO, plus :
   ✓ Conversions illimitées + API
   ✓ Fichiers jusqu'à 1 GB
   ✓ SLA 99.9% garanti
   ✓ Déploiement on-premise
   ✓ White-label
   ✓ Support dédié 24/7
   ✓ Formation équipe
   → CTA : [Nous contacter]

3. FAQ (accordion animé) :
   Q: Est-ce que je peux annuler à tout moment ?
   Q: Mes fichiers sont-ils stockés après traitement ?
   Q: Puis-je changer de plan ?
   Q: L'essai PRO est-il vraiment sans CB ?
   Q: Y a-t-il des limites sur l'API Enterprise ?
   Q: Acceptez-vous les paiements par virement ?

4. CTA bas de page :
   "Des questions ? Contactez-nous — réponse sous 24h"
   [hello@kovixel.io]

5. Tableau comparatif complet (expandable)

TECH : useState pour le toggle annuel/mensuel avec animation prix,
@radix-ui/react-accordion pour la FAQ.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 6 — AUTH PAGES & ONBOARDING
## ═══════════════════════════════════════════════════════════

### PROMPT 6.1 — Pages Login & Register premium

```
Crée les pages d'authentification dans kovixel-ui.

A) src/app/auth/login/page.tsx

LAYOUT : 2 colonnes (60% visuel gauche / 40% form droite) sur desktop.
         Plein écran formulaire sur mobile.

COLONNE GAUCHE (visuel) :
- Fond violet gradient sombre
- Animation : simulation de l'outil en action (PDF qui se transforme)
- Quote/testimonial tournant :
  "Kovixel m'a fait gagner 2h par semaine sur la gestion de mes documents."
  — Marie L., Consultante
- Logos de features clés : "IA · Sécurisé · Rapide"

COLONNE DROITE (formulaire) :
- Logo Kovixel (petit, en haut)
- Titre : "Bon retour parmi nous"
- Sous-titre : "Connectez-vous pour accéder à vos documents."
- Champ Email (floating label, icône Mail)
- Champ Mot de passe (floating label, icône Lock, toggle visibilité)
- Lien "Mot de passe oublié ?" (droite)
- Bouton [Connexion] (plein width, violet, grand)
- Séparateur "ou"
- Bouton [Continuer avec Google] (ghost, avec logo Google SVG)
- Lien : "Pas encore de compte ? Créer un compte →"

GESTION DES ÉTATS :
- Loading : bouton avec spinner, champs disabled
- Erreur : messages inline sous chaque champ (shake animation)
  + toast d'erreur global
- Succès : animation de checkmark + redirect /dashboard

B) src/app/auth/register/page.tsx

Même layout que login, mais :
- Titre : "Créez votre compte gratuit"
- Champs : Prénom + Nom · Email · Mot de passe · Confirmer MDP
- Indicateur force du mot de passe (barre colorée)
- Checkbox : "J'accepte les conditions d'utilisation" (requis)
- CTA : [Créer mon compte gratuitement]
- Lien : "Déjà un compte ? Se connecter →"

BRANCHEMENT BACKEND :
- POST /api/v1/auth/register → stocke le JWT dans un cookie httpOnly
  (utilise une Next.js API route /api/auth pour proxy le cookie)
- POST /api/v1/auth/login → idem
- Redirect vers /dashboard après succès
- Gestion des erreurs backend (email déjà utilisé, etc.)
```

---

### PROMPT 6.2 — Onboarding après inscription

```
Crée un flow d'onboarding après la première inscription dans kovixel-ui.

Fichier : src/app/onboarding/page.tsx

LOGIQUE : Affiché UNE SEULE FOIS après register (flag hasCompletedOnboarding en localStorage).
Si déjà vu → redirect /dashboard.

STRUCTURE (stepper vertical ou horizontal, 3 étapes) :

ÉTAPE 1 — "Bienvenue sur Kovixel" (délai 0ms)
  - Animation confetti violet au chargement
  - "Bonjour [Prénom] ! Votre compte est créé ✨"
  - "Voyons comment tirer le meilleur de Kovixel en 2 minutes."
  - Bouton [Commencer →]

ÉTAPE 2 — "Essayez votre premier outil" (délai 200ms)
  - "Convertissez un PDF maintenant — ça prend 10 secondes"
  - Mini DropZone intégrée (version compacte)
  - Ou : [Passer cette étape] (lien discret)
  - Si fichier traité → animation de succès + confetti

ÉTAPE 3 — "Choisissez votre plan" (délai 200ms)
  - Version compacte des 3 pricing cards (FREE / PRO / ENTERPRISE)
  - Pré-sélectionné sur FREE
  - Bouton [Continuer avec FREE] ou [Essayer PRO 14 jours]
  - "Vous pouvez changer à tout moment dans les paramètres."

COMPLÉTION :
  - Animation finale (étoiles violettes qui explosent)
  - Redirect automatique vers /dashboard après 1.5s
  - Message : "Votre espace est prêt. Bienvenue !"

TECH : framer-motion AnimatePresence pour les transitions entre étapes,
useSearchParams pour éventuellement pré-remplir des infos.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 7 — DASHBOARD & DOCUMENTS (AMÉLIORATIONS)
## ═══════════════════════════════════════════════════════════

### PROMPT 7.1 — Dashboard enrichi

```
Améliore la page /dashboard existante dans kovixel-ui.

Analyse d'abord le dashboard actuel et identifie ce qui existe.

AMÉLIORATIONS À APPORTER :

1. WIDGET D'UPLOAD RAPIDE :
   Ajoute en haut du dashboard une mini-zone de drop permanente :
   "Glissez un fichier ici pour le traiter instantanément →"
   (plus petit que la page upload, juste 80px de hauteur)
   → Au drop : modal qui demande "Que voulez-vous faire ?" avec les outils

2. STATS AMÉLIORÉES :
   - Ajoute une sparkline (mini graphique) sur chaque stat card
     montrant l'évolution sur 7 jours
   - Implémente un mini graphe avec des divs CSS (pas de lib chart)
   - Données mockées pour l'instant (remplacer par API quand dispo)

3. RECENT ACTIVITY FEED :
   À droite des docs récents, ajoute un fil d'activité :
   "Il y a 5 min · Rapport_2024.pdf → Résumé généré"
   "Il y a 1h · Facture_oct.pdf → Converti en Word"
   "Hier · CV_candidat.pdf → Données extraites"
   → avec icônes colorées selon le type d'action

4. EMPTY STATE :
   Si aucun document → afficher un empty state engageant :
   - Illustration SVG custom (document avec étoiles violettes)
   - "Votre espace est vide — commencez maintenant"
   - 3 boutons d'action : [Uploader un PDF] [Essayer un outil] [Voir le tutoriel]

5. KEYBOARD SHORTCUTS :
   Crée un hook useKeyboardShortcuts.ts :
   - Ctrl+U : ouvrir l'upload
   - Ctrl+K : ouvrir la barre de recherche
   - Ctrl+/ : afficher la liste des raccourcis (modal)
   Ajoute un indicateur discret en bas de page : "[?] Raccourcis clavier"
```

---

### PROMPT 7.2 — Page Document améliorée (résumé + Q&A + extraction)

```
Améliore la page /documents/[id] existante dans kovixel-ui.

Analyse d'abord le code existant de cette page.

AMÉLIORATIONS :

1. HEADER DOCUMENT :
   - Ajoute une preview miniature du PDF (première page)
     via react-pdf ou une img avec l'URL de preview du backend
   - Breadcrumb animé
   - Métadonnées enrichies : pages, langue détectée, taille, date upload
   - Actions rapides en haut à droite :
     [⬇ Télécharger l'original] [🗑 Supprimer] [↗ Partager]

2. ONGLET RÉSUMÉ (amélioration) :
   - Affiche le résumé en sections distinctes (non juste du texte brut) :
     • Résumé exécutif (3-5 phrases, mise en avant)
     • Points clés (liste avec puces violettes)
     • Thèmes principaux (badges colorés)
   - Boutons d'export du résumé : [Copier] [PDF] [Word]
   - Si le résumé n'est pas généré : état vide engageant avec CTA clair

3. ONGLET Q&A (amélioration) :
   - Ajoute des "questions suggérées" au chargement :
     chips cliquables en haut de la zone de chat
   - Affiche les sources (extraits de texte) sous chaque réponse IA
     dans un accordion
   - Bouton "Nouvelle conversation" pour remettre à zéro la session
   - Export de la conversation en PDF

4. ONGLET EXTRACTION (amélioration) :
   - Preview en temps réel du schéma sélectionné (liste des champs attendus)
   - Résultat affiché dans un tableau structuré (pas juste du JSON brut)
   - Indicateur de confiance par champ (barre colorée)

5. TRANSITIONS entre onglets :
   AnimatePresence avec slide horizontal (tab gauche → droite)
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 8 — PERFORMANCE & SCALABILITÉ FRONTEND
## ═══════════════════════════════════════════════════════════

### PROMPT 8.1 — Optimisations performance Next.js

```
Optimise kovixel-ui pour supporter des centaines de milliers d'utilisateurs simultanés.

Analyse le projet et applique les optimisations suivantes :

1. CODE SPLITTING & LAZY LOADING :
   - Wrape toutes les sections landing (sauf Hero) dans dynamic() avec ssr:false
   - Wrape framer-motion dans dynamic() (évite le SSR inutile)
   - Wrape react-pdf dans dynamic() avec loading skeleton

2. IMAGE OPTIMIZATION :
   - Utilise next/image partout (remplace toutes les <img>)
   - Ajoute des placeholders blur
   - Formats : WebP/AVIF automatique

3. FONTS OPTIMIZATION :
   - Vérifie que Syne et Outfit sont chargés via next/font/google
     avec display: 'swap' et preload: true
   - Supprime tout @import dans les CSS (cause CLS)

4. CACHING STRATEGY :
   - Ajoute des headers de cache dans next.config.js pour les assets statiques
   - Configure le revalidate dans les Server Components
   - Ajoute staleTime dans React Query (60s minimum)

5. BUNDLE ANALYSIS :
   - Installe @next/bundle-analyzer
   - Ajoute le script "analyze": "ANALYZE=true next build" dans package.json
   - Documente les imports lourds à surveiller

6. CORE WEB VITALS :
   - LCP (Largest Contentful Paint) : assure que le H1 hero est SSR
   - CLS (Cumulative Layout Shift) : ajoute des dimensions explicites aux images
   - FID/INP : assure que les event handlers ne bloquent pas le main thread

7. ERROR BOUNDARIES :
   Crée src/components/ui/ErrorBoundary.tsx
   - Wrape chaque section majeure
   - Fallback UI violet élégant (pas juste le texte d'erreur par défaut)

8. LOADING STATES :
   - Crée src/app/loading.tsx (skeleton global)
   - Crée src/app/error.tsx (page d'erreur stylisée)
   - Crée src/app/not-found.tsx (404 avec lien de retour)

9. ACCESSIBILITÉ :
   - Ajoute aria-label sur tous les boutons icon-only
   - Assure que le contrast ratio est > 4.5:1 sur tous les textes
   - Ajoute skip-to-content link en haut du layout
   - Vérifie la navigation clavier sur les modals et menus
```

---

### PROMPT 8.2 — PWA & Expérience mobile

```
Transforme kovixel-ui en Progressive Web App (PWA).

1. MANIFEST :
   Crée public/manifest.json :
   {
     "name": "Kovixel",
     "short_name": "Kovixel",
     "description": "La plateforme documentaire intelligente",
     "start_url": "/",
     "display": "standalone",
     "background_color": "#030014",
     "theme_color": "#7c3aed",
     "icons": [
       { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
       { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
     ]
   }

2. META TAGS (dans layout.tsx) :
   - apple-mobile-web-app-capable
   - apple-mobile-web-app-status-bar-style : black-translucent
   - apple-touch-icon
   - theme-color : #7c3aed

3. MOBILE NAVIGATION :
   - Sur mobile, cache le sidebar et remplace par une bottom navigation bar
     (Dashboard · Outils · Upload · Profil)
   - Bottom nav avec badge sur "Upload" (action principale)
   - Transitions slide entre les pages (pas juste fade)

4. TOUCH GESTURES :
   - Swipe left/right pour naviguer entre les onglets du document
   - Swipe down pour refresh (pull-to-refresh)
   - Long press sur une document card → menu contextuel

5. OFFLINE :
   - Page offline.html élégante si pas de réseau
   - Cache le dashboard (liste des documents) pour consultation offline
   - Ajoute un banner "Hors ligne — certaines fonctions indisponibles"
     quand navigator.onLine = false
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 9 — INTÉGRATIONS BACKEND MANQUANTES
## ═══════════════════════════════════════════════════════════

### PROMPT 9.1 — Branchement complet API Spring Boot

```
Vérifie et complète le branchement entre kovixel-ui et l'API Spring Boot (kovixel).

L'API backend tourne sur http://localhost:8080.
Le proxy Next.js (/api/*) redirige vers le backend.

VÉRIFIE et BRANCHE ces endpoints s'ils ne sont pas encore branchés :

AUTH :
□ POST /api/v1/auth/login       → page login
□ POST /api/v1/auth/register    → page register
□ POST /api/v1/auth/refresh     → refresh automatique du token (interceptor axios)
□ GET  /api/v1/users/me         → récupération du user connecté

DOCUMENTS :
□ GET  /api/v1/documents        → liste paginée (dashboard + /documents)
□ POST /api/v1/documents/upload → upload avec progress bar
□ GET  /api/v1/documents/{id}   → détail
□ DEL  /api/v1/documents/{id}   → suppression

RÉSUMÉ :
□ POST /api/v1/documents/{id}/summarize → lancement résumé
□ GET  /api/v1/documents/{id}/summary   → récupération résumé

Q&A :
□ POST /api/v1/documents/{id}/ask       → question
□ GET  /api/v1/documents/{id}/sessions/{sessionId}/history

CONVERSIONS :
□ POST /api/v1/convert/pdf-to-word
□ POST /api/v1/convert/pdf-to-images
□ POST /api/v1/pdf/merge
□ POST /api/v1/pdf/compress
□ POST /api/v1/pdf/split

USAGE :
□ GET /api/v1/usage/me → quotas et limites par plan

POUR CHAQUE ENDPOINT NON BRANCHÉ :
1. Crée ou met à jour la fonction dans src/lib/services.ts
2. Crée ou met à jour le hook React Query dans src/hooks/useQueries.ts
3. Connecte le hook au composant UI correspondant
4. Gère les états loading / error / empty dans l'UI
5. Ajoute un toast de succès/erreur approprié

Présente un tableau récapitulatif ✅ / ❌ / 🔄 avant de commencer.
```

---

## ═══════════════════════════════════════════════════════════
## PHASE 10 — TESTS & QUALITÉ
## ═══════════════════════════════════════════════════════════

### PROMPT 10.1 — Tests des composants critiques

```
Crée les tests des composants les plus critiques de kovixel-ui.

Setup : utilise Vitest + Testing Library (si pas déjà installé, ajoute-les).

TESTS À CRÉER :

1. src/__tests__/components/DropZone.test.tsx
   - Test : drag & drop d'un fichier valide → état "fichier sélectionné"
   - Test : drag & drop d'un fichier invalide → message d'erreur
   - Test : click "parcourir" → input file activé
   - Test : bouton "Convertir" → call API avec le bon fichier

2. src/__tests__/components/ToolCard.test.tsx
   - Test : render avec les bonnes props
   - Test : hover → classes CSS correctes
   - Test : click → navigation vers /tools/[slug]
   - Test : outil PRO → overlay visible pour user FREE

3. src/__tests__/lib/services.test.ts
   - Mock axios
   - Test : authService.login → stocke le token
   - Test : documentService.upload → appelle le bon endpoint avec FormData
   - Test : jobService.poll → appelle jusqu'à status DONE

4. src/__tests__/hooks/useQueries.test.tsx
   - Test : useDocuments → retourne les données ou un état loading

5. src/__tests__/app/landing.test.tsx
   - Test : la page / rend tous les composants attendus
   - Test : le CTA hero redirige vers /auth/register
   - Test : le filtre /tools filtre les cards correctement

Lance les tests avec : npm run test
Configure le script dans package.json : "test": "vitest"
```

---

## ═══════════════════════════════════════════════════════════
## RÉCAPITULATIF — ORDRE D'EXÉCUTION
## ═══════════════════════════════════════════════════════════

```
SEMAINE 1 — Fondations
  Jour 1 : Prompt 1.1 (audit) + 1.2 (routes) + 1.3 (design tokens)
  Jour 2 : Prompt 2.1 (hero) + 2.2 (social proof)
  Jour 3 : Prompt 2.3 (tools preview) + 2.4 (section IA)
  Jour 4 : Prompt 2.5 (confiance) + 2.6 (pricing preview) + 2.7 (CTA + footer)
  Jour 5 : Prompt 2.8 (assemblage landing) · Test visuel complet

SEMAINE 2 — Features clés
  Jour 1 : Prompt 3.1 (/tools page)
  Jour 2 : Prompt 3.2 (/tools/[tool] page avec DropZone)
  Jour 3 : Prompt 4.1 (animation signature upload)
  Jour 4 : Prompt 4.2 (micro-interactions globales)
  Jour 5 : Prompt 5.1 (/pricing page)

SEMAINE 3 — Auth + Dashboard + Backend
  Jour 1 : Prompt 6.1 (login + register)
  Jour 2 : Prompt 6.2 (onboarding)
  Jour 3 : Prompt 7.1 (dashboard amélioré)
  Jour 4 : Prompt 7.2 (document detail amélioré)
  Jour 5 : Prompt 9.1 (branchement API complet)

SEMAINE 4 — Polish + Performance
  Jour 1-2 : Prompt 8.1 (optimisations perf)
  Jour 3 : Prompt 8.2 (PWA mobile)
  Jour 4-5 : Prompt 10.1 (tests) + correction des bugs
```

---

## RÈGLE D'OR POUR CHAQUE PROMPT

> Avant de coller un prompt, dis toujours à Claude Code :
> **"Lis d'abord le fichier [nom_du_fichier_concerné] avant d'agir."**
>
> Claude Code lira ton code existant et s'adaptera exactement
> à ta structure — il ne repartira jamais de zéro.

---

*Kovixel — Prompts Premium v1.0 · 30 avril 2026*
*Frontend : kovixel-ui (Next.js 14 · Violet · Dark) · Backend : kovixel (Spring Boot 3.4)*
