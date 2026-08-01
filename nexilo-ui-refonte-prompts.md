# Kovixel-UI — Guide de refonte UI/UX
## Série de prompts étape par étape

> **Objectif** : Transformer kovixel-ui en une application sans connexion obligatoire (modèle freemium à la SmallPDF/ILovePDF), avec une UI minimaliste, fluide et premium, ancrée dans les couleurs du logo Kovixel (bleu #3B6BF0 → violet #7B3FF5, navy #1A1F5E).

---

## 🎨 Design System de référence

**Palette issue du logo :**
| Token | Hex | Usage |
|-------|-----|-------|
| `brand-blue` | `#3B6BF0` | Primaire gauche du gradient |
| `brand-violet` | `#7B3FF5` | Primaire droite du gradient |
| `brand-navy` | `#1A1F5E` | Texte de marque, dark bg |
| `brand-gradient` | `linear-gradient(135deg, #3B6BF0, #7B3FF5)` | CTAs, accents forts |
| `surface-0` | `#FFFFFF` | Cards, fonds clairs |
| `surface-1` | `#F7F8FC` | Fond de page |
| `surface-2` | `#EEEEF6` | Hover states, séparateurs |
| `text-primary` | `#1A1F5E` | Titres |
| `text-secondary` | `#6B7280` | Descriptions |

**Typographie :** DM Sans (titres) + Inter (corps) — Google Fonts

---

## ÉTAPE 1 — Nouveau Design System & Tailwind Config

**Ce que ça remplace :** la palette violette générique de la config initiale  
**Fichiers modifiés :** `tailwind.config.js`, `src/styles.css`

```
Tu es un expert Angular 19 + TailwindCSS v3.

Mets à jour le design system de kovixel-ui pour qu'il reflète exactement les couleurs du logo Kovixel.

NOUVELLE PALETTE (remplace l'ancienne palette "primary" violette) :

tailwind.config.js — extend.colors :
  brand: {
    blue:    '#3B6BF0',
    violet:  '#7B3FF5',
    navy:    '#1A1F5E',
    gradient: 'linear-gradient(135deg, #3B6BF0 0%, #7B3FF5 100%)',
  },
  surface: {
    0: '#FFFFFF',
    1: '#F7F8FC',
    2: '#EEEEF6',
    3: '#E2E3F0',
  },
  text: {
    primary:   '#1A1F5E',
    secondary: '#6B7280',
    muted:     '#9CA3AF',
  }

FONTS (Google Fonts) :
  fontFamily: {
    display: ['"DM Sans"', 'sans-serif'],
    body:    ['"Inter"', 'sans-serif'],
  }

EFFETS :
  boxShadow: {
    'card':   '0 1px 3px 0 rgba(59,107,240,0.08), 0 1px 2px -1px rgba(59,107,240,0.06)',
    'card-hover': '0 4px 16px 0 rgba(59,107,240,0.14)',
    'brand':  '0 4px 24px 0 rgba(123,63,245,0.3)',
  }

src/styles.css :
- @import depuis Google Fonts pour DM Sans (400,500,600,700) et Inter (400,500)
- Variables CSS globales :
  --gradient-brand: linear-gradient(135deg, #3B6BF0 0%, #7B3FF5 100%);
  --gradient-brand-soft: linear-gradient(135deg, rgba(59,107,240,0.1) 0%, rgba(123,63,245,0.1) 100%);
  --shadow-card: 0 1px 3px 0 rgba(59,107,240,0.08), 0 1px 2px -1px rgba(59,107,240,0.06);
  --shadow-brand: 0 4px 24px 0 rgba(123,63,245,0.3);

Ajoute une classe utilitaire .btn-brand :
  background: var(--gradient-brand);
  color: white;
  transition: opacity 0.15s ease, box-shadow 0.15s ease;
  &:hover { opacity: 0.92; box-shadow: var(--shadow-brand); }

Ajoute .card-kovixel :
  background: white;
  border: 1px solid theme('colors.surface.2');
  border-radius: 12px;
  box-shadow: var(--shadow-card);
  transition: box-shadow 0.2s ease, border-color 0.2s ease;
  &:hover { box-shadow: var(--shadow-card-hover); border-color: rgba(59,107,240,0.3); }
```

---

## ÉTAPE 2 — Architecture Guest/Auth : accès sans connexion obligatoire

**Ce que ça change :** la route `/` n'exige plus d'être connecté ; l'utilisateur peut utiliser les outils directement  
**Fichiers modifiés :** `app.routes.ts`, guards, `auth.service.ts`

```
Tu es un expert Angular 19 standalone + signals.

Refactorise la gestion des accès dans kovixel-ui pour adopter un modèle freemium
"guest-first" à la image de smallpdf.com et ilovepdf.com.

NOUVEAU COMPORTEMENT :
- Les pages outils (conversion, summary, qna, extraction) sont accessibles SANS connexion
- La connexion devient optionnelle et incitative (bandeau, modal "déverrouiller plus")
- Seules les fonctionnalités PRO ou les actions qui dépassent un quota guest déclenchent une invite de connexion

MODIFICATIONS :

1. src/app/core/services/auth.service.ts
   Ajoute le concept de GuestSession :
   - isGuest = computed(() => !currentUser())
   - guestQuota = signal<GuestQuota>({ conversionsUsed: 0, conversionsLimit: 3, summariesUsed: 0, summariesLimit: 2 })
   - Interface GuestQuota { conversionsUsed, conversionsLimit, summariesUsed, summariesLimit }
   - incrementGuestUsage(feature: 'conversion'|'summary'|'qna'|'extraction'): boolean
     → retourne true si l'action est autorisée, false si le quota guest est atteint
     → stocke le compteur dans localStorage clé "kovixel_guest_quota"
   - resetGuestQuota(): void (vidé au login)

2. src/app/core/guards/auth.guard.ts
   Crée deux versions :
   - authGuard (existant) → redirige /login si non authentifié (pour pages profil, settings, subscription)
   - softAuthGuard (nouveau) → laisse TOUJOURS passer, mais injecte dans un token
     REQUIRES_AUTH_HINT = true dans la route data si l'utilisateur est guest

3. src/app/app.routes.ts
   Restructure les routes :
   ROUTES PUBLIQUES (aucun guard) :
   - / → redirect /tools
   - /tools → landing + grille des outils (accessible à tous)
   - /tools/convert → conversion (softAuthGuard, guest quota 3/jour)
   - /tools/summary → résumé (softAuthGuard, guest quota 2/jour)
   - /tools/qna → Q&A (softAuthGuard, guest quota 2/jour)
   - /tools/extraction → extraction (softAuthGuard, guest quota 2/jour)
   ROUTES AUTH-ONLY (authGuard strict) :
   - /dashboard → tableau de bord personnel
   - /documents → bibliothèque de documents
   - /subscription, /settings → compte

   ROUTES AUTH :
   - /login, /register → guestGuard (si déjà connecté → /dashboard)

4. src/app/core/interceptors/error.interceptor.ts
   Cas 401 sur les routes soft :
   - Ne pas rediriger /login automatiquement
   - À la place : émettre un event via un GuestUpgradeService.requestLogin(reason: string)
   → Ce service expose un signal loginRequested = signal<string|null>(null)
   → Les composants s'y abonnent pour afficher une modal "Connectez-vous pour continuer"
```

---

## ÉTAPE 3 — Nouvelle page d'accueil (Home / Tools Grid)

**Ce que ça remplace :** la redirection directe vers /login  
**Fichiers créés :** `src/app/features/home/home.component.ts`

```
Tu es un expert Angular 19 + TailwindCSS + animation CSS.

Crée la nouvelle page d'accueil de kovixel-ui : src/app/features/home/home.component.ts

INSPIRATION : smallpdf.com, ilovepdf.com — accès direct aux outils, sans friction.

STRUCTURE DE LA PAGE :

1. HERO SECTION
   - Fond : bg-surface-1 avec un léger motif de points (radial-gradient subtle)
   - Titre (DM Sans, 48px bold, couleur brand-navy) :
     "Vos documents, simplement."
   - Sous-titre (Inter, 18px, text-secondary) :
     "Convertissez, résumez et analysez vos fichiers — sans inscription requise."
   - CTA principal : bouton avec gradient brand, "Choisir un outil ↓"
   - Bandeau de confiance sous le CTA (icônes lucide inline) :
     ✓ Aucune inscription  ✓ Fichiers supprimés après traitement  ✓ 100% navigateur

2. GRILLE DES OUTILS (section #tools)
   - Titre section : "Que voulez-vous faire ?" (DM Sans 28px, navy)
   - Grid : grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4, gap-4
   - Chaque ToolCard :
     * Fond blanc, border surface-2, border-radius 12px
     * Icône lucide dans un cercle 48px avec fond gradient brand (10% opacity) + icône brand-blue
     * Titre (DM Sans 15px semibold, navy)
     * Description courte (Inter 13px, text-secondary)
     * Si la fonctionnalité est PRO et l'utilisateur est guest : badge "PRO" pill gradient brand
     * Hover : translateY(-2px), shadow-card-hover, border brand-blue/30
     * Clic → navigate vers /tools/{slug}
   
   OUTILS À AFFICHER (avec leur slug et icône lucide) :
   { title: 'PDF → Word',       slug: 'convert/pdf-to-word',   icon: 'FileText',    desc: 'Convertissez un PDF en document Word éditable' }
   { title: 'PDF → Images',     slug: 'convert/pdf-to-images', icon: 'Image',       desc: 'Exportez chaque page en PNG ou JPEG haute qualité' }
   { title: 'PDF → Excel',      slug: 'convert/pdf-to-excel',  icon: 'Table',       desc: 'Extrayez les tableaux en feuille de calcul' }
   { title: 'Images → PDF',     slug: 'convert/images-to-pdf', icon: 'Images',      desc: 'Assemblez plusieurs images en un seul PDF' }
   { title: 'Fusionner PDFs',   slug: 'convert/merge',         icon: 'GitMerge',    desc: 'Combinez plusieurs PDFs en un seul fichier' }
   { title: 'Diviser un PDF',   slug: 'convert/split',         icon: 'Scissors',    desc: 'Extrayez des pages spécifiques' }
   { title: 'Compresser PDF',   slug: 'convert/compress',      icon: 'Minimize2',   desc: 'Réduisez la taille sans perte de qualité' }
   { title: 'Résumer',          slug: 'summary',               icon: 'Sparkles',    desc: 'Résumé intelligent par IA en quelques secondes', pro: false }
   { title: 'Questions / PDF',  slug: 'qna',                   icon: 'MessageSquare', desc: 'Posez des questions à votre document', pro: false }
   { title: 'Extraction',       slug: 'extraction',            icon: 'Layers',      desc: 'Extrayez informations clés structurées', pro: false }
   { title: 'Word → PDF',       slug: 'convert/word-to-pdf',   icon: 'FileText',    desc: 'Conversion fidèle de Word vers PDF', pro: true }
   { title: 'Excel → PDF',      slug: 'convert/excel-to-pdf',  icon: 'FileSpreadsheet', desc: 'Exportez vos tableurs en PDF', pro: true }

3. BANDEAU INCITATION (si isGuest())
   - Fond gradient brand (10% opacité), border brand-blue/20, border-radius 12px
   - Texte : "Créez un compte gratuit pour sauvegarder vos fichiers et accéder à plus de conversions."
   - Bouton secondaire "S'inscrire gratuitement" → /register
   - Bouton tertiaire "Se connecter" → /login

ANIMATIONS :
- Les ToolCards entrent avec staggered fadeInUp (animation-delay: index * 40ms)
- Keyframe : @keyframes fadeInUp { from { opacity:0; transform:translateY(12px) } to { opacity:1; transform:translateY(0) } }
```

---

## ÉTAPE 4 — Modal "Connexion requise" (GuestUpgrade)

**Ce que ça crée :** la modal qui s'affiche quand un guest dépasse son quota ou tente une action PRO  
**Fichiers créés :** `src/app/shared/components/guest-upgrade-modal/`

```
Tu es un expert Angular 19 standalone + TailwindCSS.

Crée le composant src/app/shared/components/guest-upgrade-modal/guest-upgrade-modal.component.ts

Ce composant est une modal légère (overlay + carte centrée) qui s'affiche quand :
- Un utilisateur guest atteint son quota d'utilisation gratuite
- Un utilisateur guest tente une action PRO

INPUTS :
@Input() reason: 'quota_reached' | 'pro_feature' | 'save_required' = 'quota_reached'

TEMPLATE :
- Overlay : bg-navy/50 backdrop-blur-sm, fixed inset-0, z-50
- Carte (max-w-sm, bg-white, rounded-2xl, shadow-brand, p-8) :
  * Logo Kovixel en haut (SVG inline, gradient brand, 40px)
  * Icône de raison (Zap pour quota, Crown pour pro, Save pour save)
  * Titre dynamique selon reason :
    quota_reached : "Vous avez atteint votre limite gratuite"
    pro_feature   : "Fonctionnalité réservée aux membres"
    save_required : "Sauvegardez vos fichiers"
  * Description (13px, text-secondary) :
    quota_reached : "Créez un compte gratuit pour continuer — c'est rapide et sans carte bancaire."
    pro_feature   : "Passez à un compte PRO pour accéder à cette fonctionnalité."
  * Avantages (liste 3 items avec icônes check, text-brand-blue) :
    ✓ Historique de vos conversions
    ✓ Fichiers sauvegardés 30 jours
    ✓ Quota quotidien augmenté
  * Bouton primaire gradient brand : "Créer un compte gratuit" → /register
  * Bouton secondaire : "Se connecter" → /login
  * Lien texte "Continuer sans compte →" (si reason != 'pro_feature') → @Output() dismiss

COMPORTEMENT :
- Apparition : scale de 0.95 → 1 + opacity 0 → 1 (150ms ease-out)
- Disparition sur clic overlay ou dismiss
- S'abonner à GuestUpgradeService.loginRequested signal dans AppShellComponent
  (afficher cette modal globalement depuis le shell)
```

---

## ÉTAPE 5 — Refonte du Layout Principal (AppShell)

**Ce que ça remplace :** la sidebar sombre bg-gray-950 de l'étape 2 originale  
**Fichiers modifiés :** `src/app/core/layouts/app-shell/app-shell.component.ts`

```
Tu es un expert Angular 19 + TailwindCSS.

Refonds entièrement le AppShellComponent de kovixel-ui avec un design minimaliste et premium.

NOUVEAU DESIGN :

TOPBAR (fixe, h-14, bg-white/95 backdrop-blur, border-b border-surface-2, shadow-sm) :
  - Logo gauche : icône N gradient brand 28px + texte "kovixel" (DM Sans 18px bold, brand-navy)
  - Navigation centrale (desktop) : liens texte plats (DM Sans 14px, text-secondary)
    → Outils | Documents | Tarifs
    → Actif : text-brand-blue, border-b-2 border-brand-blue
  - Droite :
    * Si guest : bouton "Se connecter" (outline, brand-blue) + bouton "S'inscrire" (gradient brand, pill)
    * Si connecté : badge plan (FREE/PRO) + avatar initiales (cercle gradient brand, 32px) + dropdown

SIDEBAR (seulement pour les pages connectées : /dashboard, /documents, /settings) :
  - w-56, bg-surface-1, border-r border-surface-2
  - Logo : réplique de la topbar
  - Nav items (icon + label) :
    * bg-transparent text-text-secondary par défaut
    * Actif : bg-gradient-brand (opacity 8%) text-brand-blue font-medium, bar latérale 3px brand-blue
    * Hover : bg-surface-2
  - Bas sidebar : badge quota (progress bar gradient brand) + bouton logout

MAIN LAYOUT :
  - Pages publiques (/tools, /tools/*) : topbar uniquement, pas de sidebar, full-width
  - Pages authentifiées : topbar + sidebar + main area

PAGE TRANSITIONS :
  Angular Router animation :
  - fadeSlideIn : opacity 0→1 + translateY(6px→0), durée 180ms ease-out
  - Appliqué sur le <router-outlet>

MOBILE (< 768px) :
  - Topbar uniquement
  - Menu hamburger → drawer (translate-x) qui recouvre bg-navy/50
  - Pas de sidebar sur mobile, navigation dans le drawer
```

---

## ÉTAPE 6 — Refonte de la Zone de Drop (FileDropzone)

**Ce que ça améliore :** le composant dropzone partagé, central dans l'UX  
**Fichiers modifiés :** `src/app/shared/components/dropzone/`

```
Tu es un expert Angular 19 standalone + TailwindCSS + animations CSS.

Refonds entièrement le composant FileDropzone de kovixel-ui.

DESIGN :
- Fond : bg-surface-1
- Border : 2px dashed surface-3, border-radius 16px
- Hauteur min : 200px
- Zone centrale :
  * Icône UploadCloud (lucide, 48px, brand-blue, légère animation de rebond au hover)
  * Titre : "Déposez votre fichier ici" (DM Sans 16px, navy)
  * Sous-titre : "ou cliquez pour sélectionner" (Inter 13px, text-secondary)
  * Formats acceptés en bas : badge pills bg-surface-2 text-text-secondary text-xs

ÉTATS :
  idle : tel que décrit ci-dessus
  
  dragover :
  - Border : 2px solid brand-blue
  - Fond : gradient brand (5% opacity)
  - L'icône UploadCloud monte légèrement (translateY -4px)
  - Texte change : "Relâchez pour déposer !"

  file-selected :
  - Border solid brand-blue/30
  - Affiche une preview card en bas :
    * Icône fichier (File) + nom tronqué + taille (pipe FileSize) + bouton X
    * Si PDF : affiche badge "PDF" brand-violet
    * Si image : miniature 40x40px

  loading :
  - Overlay brand gradient (30% opacity) avec spinner circulaire brand
  - Texte : "Traitement en cours..."
  - Barre de progression linéaire gradient brand en bas de la zone

  error :
  - Border 2px solid #EF4444
  - Fond rouge 5% opacity
  - Message d'erreur inline (Inter 13px, red-600) avec icône AlertCircle

  success :
  - Border 2px solid #10B981
  - Icône CheckCircle verte + "Fichier traité avec succès !"

ANIMATIONS :
@keyframes bounceUp { 0%,100%{transform:translateY(0)} 50%{transform:translateY(-6px)} }
→ appliqué sur l'icône UploadCloud au hover
```

---

## ÉTAPE 7 — Refonte des pages Outils (Tool Page Shell)

**Ce que ça crée :** un shell générique qui encapsule chaque page outil avec une UX cohérente  
**Fichiers créés :** `src/app/shared/components/tool-page-shell/`

```
Tu es un expert Angular 19 + TailwindCSS.

Crée un composant générique ToolPageShellComponent qui encapsule la mise en page
de chaque page outil dans kovixel-ui.

INPUTS :
@Input() toolTitle: string            // ex: "PDF → Word"
@Input() toolDescription: string      // courte description
@Input() toolIcon: string             // nom icône lucide
@Input() proOnly: boolean = false

LAYOUT (max-w-2xl mx-auto px-4 py-8) :
  1. HEADER :
     - Breadcrumb : "Outils / PDF → Word" (text-sm, text-secondary, lucide ChevronRight)
     - Icône (48px cercle gradient brand 10% + icône brand-blue) + Titre (DM Sans 24px, navy)
     - Description (Inter 15px, text-secondary)
     - Si proOnly ET isGuest : badge "PRO" + texte "Connectez-vous pour accéder" 
       avec bouton pill "Créer un compte" gradient brand

  2. SLOT PRINCIPAL (ng-content) :
     - Carte blanche (bg-white, rounded-2xl, border surface-2, shadow-card, p-6)
     - Contient le FileDropzone + options spécifiques à l'outil

  3. BANDEAU RÉSULTAT :
     - Affiché quand le traitement est terminé
     - Carte bg-emerald-50 border-emerald-200 rounded-xl p-4
     - Icône CheckCircle vert + "Conversion réussie !" (DM Sans 15px)
     - Nom du fichier + taille + bouton "Télécharger" (gradient brand)
     - Bouton secondaire "Nouvelle conversion" (outline)

  4. BANDEAU QUOTA GUEST (si isGuest ET quota utilisé > 0) :
     - Sous le slot principal
     - Texte subtil : "X conversions gratuites restantes aujourd'hui."
     - Si quota = 0 : remplacé par le CTA upgrade

RESPONSIVE :
  - Mobile : padding réduit, tout en colonne
  - Tablet+ : formulaire d'options en 2 colonnes si > 3 champs
```

---

## ÉTAPE 8 — Refonte du Dashboard (utilisateurs connectés)

**Ce que ça améliore :** le dashboard post-connexion  
**Fichiers modifiés :** `src/app/features/dashboard/dashboard.component.ts`

```
Tu es un expert Angular 19 + TailwindCSS.

Refonds le DashboardComponent de kovixel-ui.

LAYOUT (grid 12 colonnes, gap-4) :

ROW 1 — Bienvenue + Quota (col-span-12) :
  - Carte bg-gradient brand (5% opacité), border brand-blue/15 :
    "Bonjour [prénom] 👋" (DM Sans 20px)
    Sous-titre : "Voici votre activité du jour."
  - Côté droit : mini jauge quota (progress bar gradient brand, labels, % utilisé)

ROW 2 — Stats rapides (col-span-3 chacune) :
  4 cartes KPI identiques (bg-white, shadow-card) :
  - Conversions aujourd'hui / Résumés / Questions / Fichiers traités
  - Chiffre grand (DM Sans 28px, brand-blue) + label (Inter 12px, text-secondary)
  - Tendance : +X% (text-emerald-500 avec icône TrendingUp)

ROW 3 — Activité récente (col-span-8) + Accès rapide (col-span-4) :
  ACTIVITÉ RÉCENTE :
  - Liste des dernières conversions/actions (avatar outil + nom fichier + date relative)
  - État (badge pill) : "Succès" vert / "En cours" amber / "Erreur" rouge
  
  ACCÈS RAPIDE :
  - 4 boutons ToolCard miniatures (les outils les plus utilisés)
  - Lien "Voir tous les outils →"

ROW 4 — Outils recommandés @defer (on idle) :
  - Titre "Essayez aussi" + grille de 3 ToolCards

DESIGN TOKENS :
  - Toutes les cards : bg-white border-surface-2 rounded-xl shadow-card
  - Hover : shadow-card-hover border-brand-blue/20
  - Aucun élément bg-gray-950
```

---

## ÉTAPE 9 — Page Tarifs / Subscription (Freemium)

**Ce que ça remplace :** l'ancienne page subscription basée sur 3 plans  
**Fichiers modifiés :** `src/app/features/subscription/subscription.component.ts`

```
Tu es un expert Angular 19 + TailwindCSS.

Refonds la page Subscription de kovixel-ui dans l'esprit d'une page pricing freemium moderne.

LAYOUT :

HEADER :
  - Titre centré (DM Sans 36px, navy) : "Des outils puissants, un prix juste."
  - Toggle mensuel/annuel (pill toggle, -20% sur annuel)

CARDS PLANS (3 colonnes, gap-6) :

  GRATUIT (bg-white, border-surface-2) :
  - Badge : "Gratuit pour toujours"
  - Prix : "0 €"
  - Feature list (10 items, icônes check text-secondary)
  - Bouton outline "Commencer gratuitement"

  PRO (bg-white, border-2 border-brand-blue, ring-4 ring-brand-blue/10, scale-[1.02]) :
  - Badge gradient brand : "Le plus populaire"
  - Prix : "9 €/mois" (gros, DM Sans 40px, brand-navy)
  - Feature list (icônes check brand-blue)
  - Bouton gradient brand (shadow-brand) "Passer à PRO"

  ENTERPRISE (bg-brand-navy, text-white) :
  - Badge amber : "Sur devis"
  - Prix : "Sur mesure"
  - Feature list (icônes check white/70)
  - Bouton outline blanc "Nous contacter"

FEATURE COMPARISON TABLE (section en dessous) :
  - Tableau responsive : lignes = features, colonnes = plans
  - Header row gradient brand (10% opacity)
  - Check/Cross avec icônes lucide Check (brand-blue) / Minus (text-muted)
  - Alternance de fond surface-0 / surface-1 pour les lignes

SECTION USAGE (si connecté) :
  - Titre "Votre consommation ce mois"
  - ProgressBars par feature (gradient brand, labels, chiffres)
```

---

## ÉTAPE 10 — Micro-interactions & Polish final

**Ce que ça apporte :** les finitions qui différencient une UI correcte d'une UI premium

```
Tu es un expert Angular 19 + TailwindCSS + animations CSS.

Ajoute les micro-interactions et finitions pour polish final de kovixel-ui.

1. BOUTONS
   .btn-brand : déjà défini. Ajoute :
   - :active { transform: scale(0.98); transition: transform 0.08s; }
   - État loading : remplace le texte par un spinner circulaire 16px blanc + "Traitement..."
   - Classe .btn-brand.loading : pointer-events:none + opacity:0.85

2. TOOL CARDS (home)
   - Hover : transform:translateY(-2px), shadow-card-hover (déjà défini)
   - Clic : transform:scale(0.98) 80ms puis retour
   - Entrée page : staggered fadeInUp (déjà défini étape 3) — VÉRIFIER que l'animation ne rejoue pas au retour

3. TRANSITIONS DE ROUTE
   Ajoute dans app.routes.ts un RouteReuseStrategy par défaut.
   Animation Angular :
   trigger('routeAnim', [
     transition('* <=> *', [
       style({ opacity: 0, transform: 'translateY(6px)' }),
       animate('180ms ease-out', style({ opacity: 1, transform: 'translateY(0)' }))
     ])
   ])
   Appliqué sur le <div [@routeAnim]="outlet.activatedRouteData"> wrappant le <router-outlet>

4. LOADING SKELETON
   Crée un composant SkeletonComponent :
   - Prop : @Input() width = '100%', height = '16px', rounded = 'md'
   - Animation : pulse (opacity 0.5 → 1 → 0.5, 1.4s ease-in-out infinite)
   - Fond : bg-surface-2
   Utilisé dans : DashboardComponent (@defer placeholders), DocumentList

5. TOAST NOTIFICATIONS
   Personnalise ngx-toastr pour matcher le design system :
   - Success : bg-white border-l-4 border-emerald-500 text-navy shadow-card
   - Error :   bg-white border-l-4 border-red-500   text-navy shadow-card
   - Info :    bg-white border-l-4 border-brand-blue text-navy shadow-card
   - Warning : bg-white border-l-4 border-amber-500  text-navy shadow-card
   - Position : bottom-right, durée 3500ms
   - Custom CSS dans styles.css, classe .kovixel-toast

6. EMPTY STATES
   Crée EmptyStateComponent :
   - Icône lucide (64px, brand-blue/40)
   - Titre (DM Sans 18px, navy)
   - Description (Inter 14px, text-secondary)
   - Slot ng-content pour CTA optionnel
   Utilisé dans : DocumentList vide, Dashboard sans activité

7. FOCUS STATES (accessibilité)
   Global dans styles.css :
   :focus-visible {
     outline: 2px solid #3B6BF0;
     outline-offset: 2px;
     border-radius: 4px;
   }
```

---

## Checklist de validation finale

Avant de merger chaque étape, vérifier :

- [ ] La page `/` redirige vers `/tools` et non `/login`
- [ ] Un utilisateur non connecté peut réaliser 3 conversions et 2 résumés
- [ ] La modal GuestUpgrade s'affiche au dépassement du quota
- [ ] La sidebar n'apparaît que pour les routes authentifiées
- [ ] Toutes les couleurs utilisent le design system Kovixel (pas de violet générique)
- [ ] DM Sans utilisé pour les titres, Inter pour le corps
- [ ] Les cartes ont shadow-card et border surface-2
- [ ] Les boutons primaires ont le gradient brand
- [ ] Les animations respectent `prefers-reduced-motion`
- [ ] SSR : aucun `document`, `window`, `URL.createObjectURL` sans `isPlatformBrowser`

---

## Ordre d'exécution recommandé

```
Étape 1 → Étape 2 → Étape 3   (fondations : design + routing + home)
Étape 4 → Étape 5              (composants transversaux : modal + shell)
Étape 6 → Étape 7              (expérience outil : dropzone + shell outil)
Étape 8 → Étape 9              (pages connectées : dashboard + tarifs)
Étape 10                       (polish global)
```

> Chaque étape est autonome et peut être soumise indépendamment à votre outil de génération de code (Cursor, GitHub Copilot Workspace, Claude Code, etc.).
