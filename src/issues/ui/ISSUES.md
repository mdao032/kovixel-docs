# Analyse des problèmes — Kovixel

> Répertoire établi le 28/04/2026. Les issues sont classées par sévérité : **CRITIQUE → HAUTE → MOYENNE**.  
> Aucune correction n'a été appliquée — ce document sert de backlog de travail.
>
> **Mise à jour 2026-07-11** — Ce fichier couvre le **frontend** (#1–#25) et le **produit / pricing** (#44–#48).
> Les issues **backend & sécurité** (#26–#35) et **cohérence & configuration** (#36–#43) vivent dans
> `../kovixel/ISSUES.md` (repo backend). Rapport de synthèse global : `../RAPPORT_ANALYSE_CRITIQUE.md`.
> La numérotation est volontairement non contiguë ici pour rester alignée avec le fichier backend.

---

# A. Frontend (kovixel-ui)

## 🔴 CRITIQUE — Bugs cassants

---

### #1 — ✅ RÉSOLU — `withFetch()` dans `app.config.ts` casse la gestion des erreurs HTTP

**Statut (2026-07-11) :** Corrigé — `withFetch()` n'est plus présent dans `app.config.ts` (vérifié : ni dans
l'import `@angular/common/http`, ni dans l'appel à `provideHttpClient`). Le code est déjà dans l'état "Attendu"
décrit ci-dessous. Aucune action requise ; conservé ici pour traçabilité.

**Fichier :** `src/app/app.config.ts` · ligne ~68  
**Symptôme (avant fix) :** Le message d'erreur backend (ex : "Email ou mot de passe incorrect") n'est jamais affiché. Les composants login/register tombent toujours sur le message de fallback ("Identifiants incorrects…").

**Cause :** Quand `withFetch()` est activé dans `provideHttpClient`, Angular renvoie le corps des réponses d'erreur comme une **string brute** au lieu d'un objet JSON parsé. `err.error` est donc une string, et `err.error?.message` vaut toujours `undefined`.

```typescript
// ❌ État historique (déjà corrigé)
provideHttpClient(
  withFetch(),
  withInterceptors([authInterceptor, errorInterceptor, cacheInterceptor])
),

// ✅ Attendu
provideHttpClient(
  withInterceptors([authInterceptor, errorInterceptor, cacheInterceptor])
),
```

---

### #2 — ✅ RÉSOLU — Routes `/tools/convert/*` dans `DashboardComponent` → 404

**Statut (2026-07-11) :** Corrigé — testé en conditions réelles dans le navigateur (dev server) : les 4 routes
(`/tools/convert/pdf-to-word`, `/compress`, `/split`, `/merge`) rendent chacune le bon outil, sans 404.
`app.routes.ts` déclare désormais une route générique `tools/convert/:slug` → `ToolPageComponent`, qui résout
le slug par correspondance (`endsWith`) contre `TOOLS_CONFIG`. Aucune action requise ; conservé pour traçabilité.

**Fichier :** `src/app/features/dashboard/dashboard.component.ts` · `quickTools` array  
**Symptôme (avant fix) :** Les 4 boutons "Accès rapide" du dashboard pointaient vers des routes qui n'existaient pas.

**Cause (historique) :** Les `quickTools` contiennent des routes comme `/tools/convert/pdf-to-word`, `/tools/convert/compress`, etc. Or `app.routes.ts` ne déclarait qu'un seul chemin `/tools/convert` (sans sous-routes). La correction appliquée dans `home.component.ts` (navigate vers `/tools/convert` pour tous les outils `convert/*`) n'avait **pas** été reportée ici.

```typescript
// ❌ État actuel — ces routes n'existent pas
{ label: 'PDF → Word',  route: '/tools/convert/pdf-to-word', ... },
{ label: 'Compresser',  route: '/tools/convert/compress',    ... },
{ label: 'Diviser',     route: '/tools/convert/split',       ... },
{ label: 'Fusionner',   route: '/tools/convert/merge',       ... },

// ✅ Attendu
{ label: 'PDF → Word',  route: '/tools/convert', ... },
// (idem pour les autres)
```

---

### #3 — ✅ RÉSOLU — `filteredDocs` computed ne réagit pas aux changements de `docSearch` dans `QnaComponent`

**Statut (2026-07-11) :** Corrigé — `docSearch` est déjà un `signal('')` (ligne 593), lu via `this.docSearch()`
dans le `computed()` (ligne 596) et mis à jour via `docSearch.set($event)` dans le template (ligne 84). Une
seule déclaration dans le fichier, pas de string parallèle qui masquerait le signal. Le code est déjà dans
l'état "Attendu" décrit ci-dessous. Non re-testé visuellement en live (la barre de recherche est conditionnée
à `@if (!isGuest())` et nécessite backend + session authentifiée + documents existants), mais le câblage
signal → computed → template est sans ambiguïté correct. Aucune action requise ; conservé pour traçabilité.

**Fichier :** `src/app/features/qna/qna.component.ts`  
**Symptôme (avant fix) :** La barre de recherche de documents dans la sidebar du Q&A ne filtrait jamais les résultats après le premier rendu.

**Cause (historique) :** `docSearch` était une **plain string** (propriété de classe), pas un signal. La fonction `computed()` d'Angular ne peut tracker que des **lectures de signaux**. Quand `docSearch` changeait via `[(ngModel)]`, le computed `filteredDocs` ne se recalculait pas.

```typescript
// ❌ État historique (déjà corrigé)
docSearch = '';  // plain string — invisible pour computed()

readonly filteredDocs = computed(() => {
  const q = this.docSearch.toLowerCase(); // ← pas tracké par Angular signals
  return this.documents().filter((d) => d.name.toLowerCase().includes(q));
});

// ✅ Attendu
docSearch = signal('');

readonly filteredDocs = computed(() => {
  const q = this.docSearch().toLowerCase();
  return this.documents().filter((d) => d.name.toLowerCase().includes(q));
});
```

---

## 🟠 HAUTE PRIORITÉ — Problèmes fonctionnels

---

### #4 — ✅ RÉSOLU — `KovixelPreloadingStrategy` vérifie de mauvais chemins de routes

**Statut (2026-07-11) :** Corrigé — `PRELOAD_ROUTES` contient déjà `['documents', 'tools/summary', 'tools/convert']`,
qui correspond exactement aux `path:` déclarés dans `app.routes.ts` (`tools/summary` l.122, `tools/convert` l.147,
`documents` l.239). Le code est déjà dans l'état "Attendu" décrit ci-dessous. Vérification faite par
correspondance de chaînes (preuve non ambiguë) ; non re-confirmé au niveau réseau — le dev server Vite sert
des chunks à la demande avec des hashes qui ne se recoupent pas fiablement aux noms de composants pour ce
type de vérification. Aucune action requise ; conservé pour traçabilité.

**Fichier :** `src/app/core/preloading/kovixel-preloading.strategy.ts`  
**Symptôme (avant fix) :** Les routes `summary` et `conversion` n'étaient jamais préchargées en arrière-plan.

**Cause (historique) :** La stratégie vérifiait `routePath` contre `['documents', 'summary', 'conversion']`. Mais dans `app.routes.ts`, les enfants du layout app-shell ont pour `path` : `'tools/summary'` et `'tools/convert'`. Seul `'documents'` correspondait réellement.

```typescript
// ❌ État historique (déjà corrigé)
const PRELOAD_ROUTES = new Set(['documents', 'summary', 'conversion']);

// ✅ État actuel
const PRELOAD_ROUTES = new Set(['documents', 'tools/summary', 'tools/convert']);
```

---

### #5 — ✅ RÉSOLU — APIs DOM utilisées sans garde `isPlatformBrowser` dans `SummaryComponent`

**Statut (2026-07-11) :** Corrigé — tous les guards `isPlatformBrowser(this.platformId)` sont présents (lignes 910,
918, 961, 1005 dont `copyToClipboard`). Aucune action requise.

**Fichier :** `src/app/features/summary/summary.component.ts`  
**Méthodes concernées :** `copyToClipboard()`, `downloadTxt()`

**Cause :** `navigator.clipboard.writeText()` et `document.createElement('a')` sont appelés directement. En contexte SSR (server-side rendering), ces APIs n'existent pas et lèveront une `ReferenceError`. Bien que `"ssr": false` soit configuré en développement, la configuration de production peut activer le SSR.

```typescript
// ❌ État actuel
async copyToClipboard(): Promise<void> {
  await navigator.clipboard.writeText(content); // ← crash SSR
}

// ✅ Attendu
async copyToClipboard(): Promise<void> {
  if (!isPlatformBrowser(inject(PLATFORM_ID))) return;
  await navigator.clipboard.writeText(content);
}
```

---

### #6 — ✅ RÉSOLU — Outils PRO sélectionnables sans blocage dans `ConversionComponent`

**Statut (2026-07-11) :** Corrigé — `(click)="isLocked(tool) ? showUpsell(tool) : selectTool(tool)"` (ligne 51),
et `selectTool()` revérifie `isLocked()` en interne (ligne 146). Aucune action requise.

**Fichier :** `src/app/features/conversion/conversion.component.ts`  
**Symptôme (avant fix) :** Un utilisateur FREE pouvait cliquer sur un outil PRO (Word→PDF, Excel→PDF), voir le panneau de conversion s'ouvrir, et soumettre le formulaire. Il obtenait une erreur 402, mais l'UX était trompeuse.

**Cause :** `isLocked(tool)` ne fait qu'appliquer `opacity-70` via CSS. Le `(click)="selectTool(tool)"` n'est pas conditionnel. La bannière d'upsell s'affiche **en dessous** du panneau déjà ouvert, pas à la place.

```typescript
// ❌ État actuel
[ngClass]="[..., isLocked(tool) ? 'opacity-70' : 'cursor-pointer']"
(click)="selectTool(tool)"

// ✅ Attendu — empêcher la sélection si verrouillé
(click)="isLocked(tool) ? null : selectTool(tool)"
// + ajouter pointer-events-none sur le bouton quand verrouillé
```

---

### #7 — ✅ RÉSOLU — Typo CSS dans le template de `DashboardComponent`

**Statut (2026-07-11) :** Corrigé — toutes les occurrences de `var(--text-secondary)` dans le fichier sont
correctement fermées (parenthèse présente). Aucune action requise.

**Fichier :** `src/app/features/dashboard/dashboard.component.ts` · section "Essayez aussi" (suggestedTools)  
**Symptôme (avant fix) :** La couleur du texte de description des outils suggérés n'était pas appliquée.

**Cause :** La valeur CSS `var(--text-secondary` est tronquée — il manque la parenthèse fermante `)`.

```html
<!-- ❌ État actuel — parenthèse CSS manquante, le style est ignoré -->
style="color: var(--text-secondary"

<!-- ✅ Attendu -->
style="color: var(--text-secondary)"
```

---

### #8 — ✅ RÉSOLU — `GuestUpgradeService.requestLogin('session_expired')` — reason inconnue → mauvais message modal

**Statut (2026-07-11) :** Corrigé — `'session_expired'` fait désormais partie du type `UpgradeReason` et possède
sa propre entrée dans `REASON_CONFIG` (ligne 48). Aucune action requise.

**Fichiers :** `src/app/core/interceptors/error.interceptor.ts` · `src/app/shared/components/guest-upgrade-modal/guest-upgrade-modal.component.ts`  
**Symptôme (avant fix) :** Quand un guest accédait à une route protégée et recevait un 401, le modal s'ouvrait avec le message "Vous avez atteint votre limite gratuite" (fallback `quota_reached`) au lieu d'un message de reconnexion adapté.

**Cause :** `error.interceptor.ts` appelle `guestUpgrade.requestLogin('session_expired')`, mais `'session_expired'` n'est pas dans `REASON_CONFIG` (`UpgradeReason = 'quota_reached' | 'pro_feature' | 'save_required'`). Le modal retombe sur `this.reason()` par défaut = `'quota_reached'`.

```typescript
// ❌ État actuel — reason non déclarée
guestUpgrade.requestLogin('session_expired');

// ✅ Attendu — ajouter 'session_expired' dans UpgradeReason + REASON_CONFIG,
//            ou utiliser un reason existant plus proche sémantiquement
guestUpgrade.requestLogin('quota_reached');
```

---

## 🟡 MOYENNE — Incohérences et code mort

---

### #9 — ✅ RÉSOLU — `auth.routes.ts` — fichier mort, jamais importé

**Statut (2026-07-11) :** Corrigé — le fichier a été supprimé du projet. Aucune action requise.

**Fichier (historique) :** `src/app/features/auth/auth.routes.ts`  
**Cause :** Ce fichier déclarait `AUTH_ROUTES` mais `app.routes.ts` définit directement les routes `login` et `register` sous le layout auth-layout, sans jamais importer `AUTH_ROUTES`. Le fichier était trompeur.

---

### #10 — ✅ RÉSOLU — `dashboard.routes.ts` — fichier mort, jamais utilisé

**Statut (2026-07-11) :** Corrigé — le fichier a été supprimé du projet. Aucune action requise.

**Fichier (historique) :** `src/app/features/dashboard/dashboard.routes.ts`  
**Cause :** Déclarait `DASHBOARD_ROUTES` mais `app.routes.ts` utilise `loadComponent` directement pour le dashboard, jamais `loadChildren` avec ces routes.

---

### #11 — ✅ RÉSOLU — `recentJobs` chargé dans `DashboardComponent` mais jamais affiché

**Statut (2026-07-11) :** Corrigé — `recentJobs` et l'appel `jobService.getMyJobs` ont été retirés de
`dashboard.component.ts`, plus aucune trace ni appel orphelin. Aucune action requise.

**Fichier (historique) :** `src/app/features/dashboard/dashboard.component.ts`  
**Cause :** `ngOnInit` exécutait `jobService.getMyJobs(0, 3)` et peuplait `recentJobs` signal, mais aucune section du template ne rendait ce signal. La requête HTTP était effectuée inutilement.

---

### #12 — ✅ RÉSOLU — `usageLines` signal déclaré dans `SubscriptionComponent` mais jamais alimenté

**Statut (2026-07-11) :** Corrigé — `usageLines`/`UsageLine` n'existent plus dans `subscription.component.ts`.
Aucune action requise.

**Fichier (historique) :** `src/app/features/subscription/subscription.component.ts`  
**Cause :** `readonly usageLines = signal<UsageLine[]>([])` était déclaré avec son interface `UsageLine`, mais n'était jamais mis à jour et n'apparaissait dans aucune partie du template.

---

### #13 — ✅ RÉSOLU — `JobsComponent` — composant stub non implémenté

**Statut (2026-07-11) :** Corrigé — le composant fait désormais 239 lignes avec un état loading (skeleton),
un état erreur avec retry, et un rendu réel de la liste via `JobService`. Ce n'est plus un placeholder.
Aucune action requise.

**Fichier :** `src/app/features/jobs/jobs.component.ts`  
**Cause (historique) :** Le composant ne contenait qu'un placeholder `[ JobsComponent — à implémenter ]`. Il était accessible via la route `/jobs` et visible dans la navigation sidebar — l'utilisateur pouvait y accéder et ne voir qu'une page vide.

---

### #14 — ✅ RÉSOLU — Mélange de stratégies de binding d'icônes Lucide (`[name]` vs `[img]`)

**Statut (2026-07-11) :** Corrigé. `dashboard.component.ts` et `subscription.component.ts` utilisaient déjà
uniformément `[img]="IconObject"`. Le dernier foyer du risque, `shared/components/tool-page-shell/tool-page-shell.component.ts`
(composant non utilisé ailleurs dans le code — 0 appelant trouvé pour le sélecteur `kov-tool-page-shell`,
donc aucune régression possible côté appelants), a été corrigé :
- `@Input({ required: true }) toolIcon!: string` → `@Input({ required: true }) toolIcon!: any` (objet icône Lucide, plus une string).
- Template : `<lucide-icon [name]="toolIcon" ...>` → `<lucide-icon [img]="toolIcon" ...>`.
- JSDoc d'usage mis à jour : `toolIcon="file-text"` → `[toolIcon]="FileTextIcon"`.

Rebuild Angular vérifié sans erreur de compilation après chaque édition. Toutes les icônes du projet passent
désormais uniformément par `[img]="IconObject"` — le binding `[name]="string"` dépendant du provider global
`LUCIDE_ICONS` a été éliminé. Aucune action supplémentaire requise.

**Fichier corrigé :** `src/app/shared/components/tool-page-shell/tool-page-shell.component.ts`

**Risque (historique) :** Le binding `[name]="string"` nécessite que l'icône soit enregistrée dans le provider global `LUCIDE_ICONS`. Si une icône est ajoutée dans un composant mais pas dans `app.config.ts`, elle reste silencieusement invisible. Le binding `[img]="IconObject"` est plus robuste car il ne dépend pas du provider global.

---

### #15 — ✅ RÉSOLU — Sélecteurs `app-*` au lieu de la convention `kov-*`

**Statut (2026-07-11) :** Corrigé — les deux composants utilisent désormais `selector: 'kov-guest-upgrade-modal'`
et `selector: 'kov-guest-banner'`. Aucune action requise.

**Fichiers :**  
- `src/app/shared/components/guest-upgrade-modal/guest-upgrade-modal.component.ts` (historique : `selector: 'app-guest-upgrade-modal'`)  
- `src/app/shared/components/guest-banner/guest-banner.component.ts` (historique : `selector: 'app-guest-banner'`)

**Cause (historique) :** Tous les autres composants du projet utilisent le préfixe `kov-`. Ces deux composants utilisaient le préfixe `app-` par défaut Angular, ce qui cassait la cohérence du projet.

---

### #16 — ✅ RÉSOLU — Mélange incohérent de Tailwind pur vs variables CSS personnalisées

**Statut (2026-07-11) :** Corrigé — `login.component.ts` (et par extension `register.component.ts`, même pattern)
utilise désormais les variables CSS Kovixel (`var(--text-primary)`, `var(--text-muted)`, `var(--field-bg)`, etc.),
aucune classe Tailwind de couleur brute (`bg-violet-600`, `text-gray-900`, `border-gray-300`) trouvée. Aucune action requise.

**Pages auth (historique)** (`login.component.ts`, `register.component.ts`) : utilisaient du Tailwind pur (`bg-violet-600`, `text-gray-900`, `border-gray-300`).  
**Pages app** (`dashboard.component.ts`, `subscription.component.ts`, `app-shell.component.ts`) : utilisent les variables CSS Kovixel (`var(--color-brand-navy)`, `var(--text-secondary)`, `var(--surface-2)`).

---

### #17 — ✅ RÉSOLU — `icons` object défini dans `HomeComponent` mais jamais utilisé

**Statut (2026-07-11) :** Corrigé — plus aucune trace de l'objet `icons`/`FileText`/`Image` mort dans
`home.component.ts` (le composant a été refactorisé en sous-composants de section). Aucune action requise.

**Fichier (historique) :** `src/app/features/home/home.component.ts`  
**Cause :** `protected readonly icons = { FileText, Image, ... }` était déclaré dans la classe mais le template utilisait uniquement `[name]="tool.icon"` (binding par string), jamais `[img]="icons.FileText"`. L'objet était du code mort.

---

### #18 — ✅ RÉSOLU — `authGuard` ne préserve pas l'URL de retour après connexion

**Statut (2026-07-11) :** Corrigé — le guard construit `router.createUrlTree(['/login'], { queryParams: { returnUrl: state.url } })`,
et `login.component.ts` lit bien `route.snapshot.queryParamMap.get('returnUrl')` (2 emplacements : login direct
et post-2FA). Aucune action requise.

**Fichier :** `src/app/core/guards/auth.guard.ts`  
**Symptôme (avant fix) :** Un utilisateur non connecté cliquant sur `/documents` était redirigé vers `/login`. Après connexion, il atterrissait sur `/dashboard` et non sur `/documents`.

---

### #19 — ✅ RÉSOLU — Type `BlobOrJob` dupliqué avec `ConversionResult`

**Statut (2026-07-11) :** Corrigé — `BlobOrJob` n'existe plus dans `conversion.service.ts` ; `ConversionResult`
est importé du modèle et utilisé partout. Aucune action requise.

**Fichiers (historique) :** `src/app/core/services/conversion.service.ts` et `src/app/core/models/conversion.model.ts`  
**Cause :** `conversion.service.ts` déclarait localement `type BlobOrJob = Blob | ConversionJobResponse`, tandis que `conversion.model.ts` exporte `ConversionResult = Blob | ConversionJobResponse`. C'étaient deux définitions identiques.

---

### #20 — ✅ RÉSOLU — Imports inutilisés dans plusieurs composants

**Statut (2026-07-11) :** Corrigé — `ActivatedRoute` n'apparaît plus dans `summary.component.ts`, `HostListener`
n'apparaît plus dans `qna.component.ts`. Les deux imports ont été retirés. Aucune action requise.

| Fichier | Import inutilisé (historique) |
|---|---|
| `summary.component.ts` | `ActivatedRoute` (importé depuis `@angular/router`, jamais injecté) |
| `qna.component.ts` | `HostListener` (importé depuis `@angular/core`, jamais utilisé comme décorateur dans ce composant) |

---

### #21 — ✅ RÉSOLU — `notificationsEnabled` dans `SettingsComponent` non persisté

**Statut (2026-07-11) :** Corrigé — `notificationsEnabled` est un signal, et `setNotifications(value)` persiste
désormais via `localStorage.setItem(this.NOTIF_KEY, String(value))` (sous garde `isPlatformBrowser`). Aucune action requise.

**Fichier :** `src/app/features/settings/settings.component.ts`  
**Symptôme (avant fix) :** Le toggle "Recevoir les notifications par email" n'avait aucun effet persistant.

---

### #22 — ✅ RÉSOLU — `document-detail.component.ts` utilise `@Input()` (ancien style décorateur)

**Statut (2026-07-11) :** Corrigé — le composant utilise désormais `readonly id = input<string>()` (functional
input signal, ligne 1010), plus de décorateur `@Input()`. Aucune action requise.

**Fichier :** `src/app/features/documents/document-detail/document-detail.component.ts`  
**Cause (historique) :** Importait `Input` depuis `@angular/core` et utilisait le style décorateur `@Input()`, contrairement au reste du codebase qui a migré vers `input()` signal (functional inputs).

---

### #23 — ✅ RÉSOLU — `memoryCache` module-level dans `cache.interceptor.ts` — risque SSR

**Statut (2026-07-11) :** Corrigé — tous les accès (lecture et écriture) à `memoryCache` sont désormais gardés
par `if (isBrowser)` ; côté serveur (SSR), le code passe exclusivement par `TransferState` et ne touche jamais
`memoryCache`. Le singleton module-level ne pose donc plus de risque de fuite de données entre utilisateurs/requêtes.
Aucune action requise.

**Fichier :** `src/app/core/interceptors/cache.interceptor.ts`  
**Cause (historique) :** `const memoryCache = new Map<string, CacheEntry>()` est déclaré au niveau module. Sans garde SSR, ce singleton aurait été partagé entre toutes les requêtes entrantes et potentiellement entre tous les utilisateurs.

---

### #24 — ✅ RÉSOLU — `question` dans `QnaComponent` est une plain string (incohérence OnPush)

**Statut (2026-07-11) :** Corrigé — `readonly question = signal('')` (ligne 604). Aucune action requise.

**Fichier :** `src/app/features/qna/qna.component.ts`  
**Cause (historique) :** `question = ''` était une propriété de classe (non-signal) utilisée avec `[(ngModel)]` et `{{ question.length }}` dans le template avec `ChangeDetectionStrategy.OnPush` — incohérent avec le pattern signals du reste du codebase et fragile.

---

### #25 — ✅ RÉSOLU — `conversion.service.ts` — `ConversionResult` non utilisé en retour de méthode

**Statut (2026-07-11) :** Corrigé — les 11 méthodes publiques du service retournent `Observable<ConversionResult>`
(0 occurrence de l'ancien `Observable<BlobOrJob>`). Aucune action requise.

**Fichier :** `src/app/core/services/conversion.service.ts`  
**Cause (historique) :** Toutes les méthodes publiques retournaient `Observable<BlobOrJob>` au lieu de `Observable<ConversionResult>` (type exporté du modèle), empêchant `isConversionJob()` d'être reconnu comme un type guard propre par TypeScript dans tous les contextes.

---

> **Sections B (Backend & Sécurité, #26–#35) et C (Cohérence & Configuration, #36–#43)
> déplacées vers `../kovixel/ISSUES.md`.** Ce fichier ne conserve que les issues
> frontend (#1–#25) et produit / pricing (#44–#48). Le rapport de synthèse global
> reste `../RAPPORT_ANALYSE_CRITIQUE.md`.

---

# D. Produit & Pricing

## 🟠 HAUTE PRIORITÉ

---

### #44 — Plans Team/Enterprise vendus mais non fonctionnels

**Fichiers :** `pricing.component.ts` (TEAM_PLANS) + `PlanConfig.java` (`TEAM`, `ENTERPRISE` définis) + modèle d'autorisation individuel.  
**Symptôme :** La page pricing promet console d'admin, gestion des rôles, **SSO/SAML (Okta/Azure AD/Google)**, facturation par siège, stockage 100 GB/user, intégrations Slack/Teams/Drive, SOC 2, white-label. Aucune de ces capacités n'existe côté backend (identité individuelle, pas de notion d'équipe/rôles/SSO).  
**Risque :** Perte de crédibilité B2B — sur-promesse. Le CTA « Nous contacter » (mailto) limite les dégâts, mais les features listées ne doivent pas apparaître comme livrées.  
**Correction :** Soit implémenter le socle équipe (rôles, sièges, SSO), soit marquer explicitement ces items « bientôt disponible » / retirer les non tenables.

---

### #45 — Domaine de contact incohérent : `kovixel.io` vs `kovixel.com`

**Fichier :** `pricing.component.ts` — CTA Équipe/Enterprise = `mailto:hello@kovixel.io` (et footer `hello@kovixel.io`).  
**Symptôme :** Le reste du projet utilise `kovixel.com` (`MAIL_FROM=noreply@kovixel.com`, `APP_BASE_URL=app.kovixel.com`).  
**Risque :** Emails de prospects perdus si `kovixel.io` n'est pas possédé/configuré.  
**Correction :** Unifier le domaine sur toute la stack.

---

## 🟡 MOYENNE

---

### #46 — Valeur du plan Pro insuffisamment démontrée dans l'UX

**Symptôme :** Le plan gratuit est très généreux (tous les outils, sans compte, 5-10 conversions/jour). Le `PlanConfig` définit bien des paliers, mais l'UI ne matérialise aucune restriction visible (watermark, batch, historique, priorité) qui donnerait une raison de payer.  
**Correction :** Rendre les bénéfices Pro tangibles (ex. filigrane sur le free, batch/historique/priorité réservés) et un comparateur clair.

---

### #47 — Absence de page confiance / sécurité / conformité

**Symptôme :** Aucune page ne documente rétention des documents, chiffrement au repos, hébergement, RGPD concret, mode IA local. C'est le premier réflexe d'un acheteur B2B et le principal frein à la conversion entreprise.  
**Correction :** Créer une page dédiée — les briques techniques (Ollama local, MinIO, e-signature) existent déjà et sont un argument différenciant.

---

### #48 — e-signature sans preuve de conformité affichée

**Fichier :** module `pdfesignature` (PAdES-B via BouncyCastle).  
**Symptôme :** Signature à valeur juridique proposée sans mention de conformité (eIDAS, horodatage qualifié, chaîne de certificats).  
**Correction :** Clarifier le niveau réel (cachet vs signature qualifiée) et l'afficher, sous peine de non-adoption entreprise.

---

## Résumé

> Périmètre de ce tableau : frontend (#1–#25) + produit / pricing (#44–#48). Pour le backend, voir `../kovixel/ISSUES.md`.

| Sévérité | Nb | Principaux impacts |
|---|---|---|
| 🔴 CRITIQUE | 0 (+3 résolus) | ~~Login cassé~~ (#1), ~~liens dashboard 404~~ (#2), ~~recherche Q&A morte~~ (#3) — **toutes résolues** |
| 🟠 HAUTE | 0 (+6 résolus) | ~~Préchargement mort~~ (#4), ~~crash SSR~~ (#5), ~~outils PRO non protégés~~ (#6), ~~CSS cassé~~ (#7), ~~mauvais message modal~~ (#8) — **toutes résolues**. Reste seulement **Team/Enterprise non fonctionnels** (#44, section Produit) |
| 🟡 MOYENNE | 1 (+16 résolus) | Résolues : #9–#25 (fichiers morts, code mort, icônes Lucide, persistance, signals, SSR cache…) — reste uniquement le lot Produit (#46–#48) |

> Vérification exhaustive effectuée le 2026-07-11 sur #5–#25 (grep ciblé + lecture de code) : les 21 issues
> frontend sont désormais résolues. #14 a nécessité un correctif réel (`tool-page-shell.component.ts`,
> composant sans appelant donc sans risque de régression), toutes les autres étaient déjà conformes.

**Frontend (#1–#25) : 100 % résolu.** Reste à traiter — section D uniquement : #44 → #47 → #46 → #45 → #48.

> Rappel : la priorité **sécurité / config avant toute prod** (#26 → #27 → #28 → #36 → #37 → #29 → #30) est suivie dans `../kovixel/ISSUES.md`.
