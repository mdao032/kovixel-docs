🚀 Plan kovixel-ui — Application Angular 19+ (Palette Violette)
Stack recommandée
Couche	Technologie	Raison
Framework	Angular 19+ (Standalone + Signals)	SSR natif, performances, écosystème
Styles	TailwindCSS v3	Rapidité, purge CSS, design system cohérent
Icônes	Lucide Angular	Légères, cohérentes, tree-shakeable
Notifications	ngx-toastr	Mature, accessible
Markdown	ngx-markdown	Affichage résumés IA
HTTP	Angular HttpClient + interceptors	Natif
Formulaires	ReactiveFormsModule	Validation typée
DnD	@angular/cdk/drag-drop	Natif Angular, performant
Routing	Angular Router + PreloadingStrategy	Lazy loading optimal
SSR	Angular Universal	SEO + First Paint rapide
Architecture du projet
kovixel-ui/
├── src/
│   ├── app/
│   │   ├── core/
│   │   │   ├── interceptors/   (auth, error, cache)
│   │   │   ├── guards/         (auth, guest)
│   │   │   ├── layouts/        (app-shell, auth-layout)
│   │   │   ├── models/         (interfaces TypeScript)
│   │   │   └── services/       (auth, document, quota, job-polling...)
│   │   ├── features/
│   │   │   ├── auth/           (login, register)
│   │   │   ├── dashboard/
│   │   │   ├── documents/      (list, upload, detail)
│   │   │   ├── summary/
│   │   │   ├── qna/
│   │   │   ├── extraction/
│   │   │   ├── conversion/
│   │   │   ├── subscription/
│   │   │   ├── settings/
│   │   │   └── not-found/
│   │   ├── shared/
│   │   │   ├── components/     (button, card, badge, spinner, dropzone, modal...)
│   │   │   └── pipes/          (file-size, truncate)
│   │   ├── app.config.ts
│   │   └── app.routes.ts
│   ├── environments/
│   └── styles.css
├── tailwind.config.js
└── proxy.conf.json
Plan d'action — 7 étapes
Étape 1 — Initialisation & Configuration ✅
Ce qui est généré : Workspace Angular 19, TailwindCSS violet, SSR, proxy dev, ESLint, environments

Tu es un expert Angular 19. Génère la configuration complète d'un nouveau projet Angular 19 nommé "kovixel-ui" avec les caractéristiques suivantes :

STACK :
- Angular 19+ (standalone components UNIQUEMENT, pas de NgModules)
- Angular SSR (Universal) activé
- TailwindCSS v3 avec PostCSS
- @angular/cdk (pas Material complet, uniquement CDK pour accessibilité)
- ngx-toastr pour les notifications
- lucide-angular pour les icônes
- ngx-markdown pour le rendu des résumés IA

FICHIERS À GÉNÉRER :
1. package.json avec toutes les dépendances et scripts (start, build, build:ssr, serve:ssr, lint, test)
2. tailwind.config.js avec le design system violet de Kovixel :
   - primary: { 50:'#f5f3ff', 100:'#ede9fe', 200:'#ddd6fe', 300:'#c4b5fd', 400:'#a78bfa', 500:'#8b5cf6', 600:'#7c3aed', 700:'#6d28d9', 800:'#5b21b6', 900:'#4c1d95' }
   - neutral, success, warning, error en complément
   - fontFamily: ['Inter', 'sans-serif'] (google fonts)
3. src/environments/environment.ts et environment.prod.ts avec apiUrl
4. proxy.conf.json → /api/* → http://localhost:8080
5. angular.json modifié pour activer SSR et proxy en développement
6. tsconfig.json strict mode activé (noImplicitAny, strictNullChecks, strictPropertyInitialization)
7. .eslintrc.json configuré pour Angular standalone
8. src/styles.css avec les @tailwind directives + variables CSS globales (--color-primary, --color-primary-dark, etc.) + import Inter depuis Google Fonts
9. src/app/app.config.ts avec provideRouter (withPreloading), provideHttpClient (withInterceptors, withFetch), provideAnimations, provideClientHydration

COMPORTEMENTS ATTENDUS :
- Lazy loading activé sur toutes les routes dès le départ
- HTTP interceptors slots prêts (AUTH + ERROR + CACHE)
- Strict TypeScript actif
- SSR: transferState configuré pour éviter les double-appels API
Étape 2 — Core : Auth, Intercepteurs, Guards, Layouts ✅
Ce qui est généré : AuthService (signals), JWT interceptor, error interceptor, guards, AppShell responsive, AuthLayout

Tu es un expert Angular 19 standalone avec signals. Génère la couche CORE du projet kovixel-ui.

CONTEXTE BACKEND :
- POST /api/v1/auth/register → body: { email, password } → { token: string }
- POST /api/v1/auth/login    → body: { email, password } → { token: string }
- JWT stocké en localStorage clé "kovixel_token"
- Header: Authorization: Bearer <token>
- Token JWT payload: { sub: email, id: userId, plan: 'FREE'|'PRO'|'ENTERPRISE', exp }

FICHIERS À GÉNÉRER :

1. src/app/core/models/user.model.ts
   - Interface User { id: number, email: string, plan: UserPlan }
   - Enum UserPlan { FREE, PRO, ENTERPRISE }
   - Interface AuthResponse { token: string }
   - Interfaces LoginRequest, RegisterRequest

2. src/app/core/services/auth.service.ts
   - currentUser = signal<User | null>(null)
   - isAuthenticated = computed(() => !!currentUser())
   - userPlan = computed(() => currentUser()?.plan ?? UserPlan.FREE)
   - login(req): Observable<void> → POST, stocke token, décode JWT base64 (sans lib), met signal
   - register(req): Observable<void>
   - logout(): void → clear localStorage + signal + navigate('/login')
   - initFromStorage(): void → décode token stocké au démarrage dans APP_INITIALIZER

3. src/app/core/interceptors/auth.interceptor.ts (functional interceptor)
   - Injecte Authorization: Bearer token sur toutes les requêtes sauf /auth/

4. src/app/core/interceptors/error.interceptor.ts (functional interceptor)
   - 401 → logout + navigate('/login')
   - 403 → toast "Accès refusé" + navigate('/dashboard')
   - 429 → toast "Quota dépassé — passez à PRO" avec lien /subscription
   - 402 → toast "Fonctionnalité PRO requise" avec lien /subscription
   - 5xx → toast "Erreur serveur, veuillez réessayer"
   - Extrait le champ "message" de la réponse backend si disponible

5. src/app/core/interceptors/cache.interceptor.ts (functional interceptor)
   - Cache en mémoire (Map) pour GET /api/v1/quota/me (TTL 30s)
   - Invalide le cache sur les mutations (POST/PUT/DELETE sur même ressource)

6. src/app/core/guards/auth.guard.ts (functional)
   - Vérifie isAuthenticated(), sinon redirectTo: '/login'

7. src/app/core/guards/guest.guard.ts (functional)
   - Si authentifié → redirectTo: '/dashboard'

8. src/app/core/layouts/app-shell/app-shell.component.ts (standalone, OnPush)
   Sidebar fixe (w-64) + main content :
   SIDEBAR :
   - Logo Kovixel (SVG + texte, couleur white) sur fond bg-gray-950
   - Navigation items avec icônes lucide: Dashboard, Documents, Résumé, Q&A, Extraction, Conversion, Abonnement
   - Item actif: bg-violet-700 rounded-lg text-white
   - Item inactif: text-gray-400 hover:text-white hover:bg-gray-800 rounded-lg
   - Badge plan en bas (FREE=gray, PRO=violet, ENTERPRISE=amber)
   - Bouton Déconnexion en bas avec icône LogOut
   TOPBAR :
   - Titre page courante (depuis ActivatedRoute)
   - Avatar utilisateur + email + dropdown logout
   - Indicateur quota: mini progress bar violette (si > 80% → orange, > 95% → rouge)
   RESPONSIVE :
   - Mobile (< md): sidebar en drawer (CDK Overlay ou translate-x CSS)
   - Bouton hamburger dans topbar pour toggle

9. src/app/core/layouts/auth-layout/auth-layout.component.ts (standalone, OnPush)
   - Fond: bg-gradient-to-br from-violet-950 via-violet-900 to-purple-900
   - Carte blanche centrée max-w-md mx-auto, rounded-2xl, shadow-2xl, p-8
   - Logo Kovixel en haut de la carte (icône violet sur fond violet-100)
   - <router-outlet> dans la carte

10. src/app/app.routes.ts
    Routes complètes avec lazy loading :
    - / → redirect /dashboard
    - /login, /register → AuthLayout, canActivate: guestGuard
    - (AppShell wrapper, canActivate: authGuard) :
      /dashboard, /documents, /documents/:id, /summary, /qna, /extraction, /conversion, /jobs, /subscription, /settings
    - ** → not-found (lazy)

DESIGN Sidebar : bg-gray-950, transitions duration-200, logo 'N' violet-600 dans un cercle
Étape 3 — Design System & Composants Partagés ✅
Ce qui est généré : 10 composants réutilisables (Button, Card, Badge, Spinner, ProgressBar, FileDropzone, Modal, Alert, Table, JobProgress)

Tu es un expert Angular 19 + TailwindCSS. Génère la bibliothèque de composants UI partagés pour kovixel-ui. Tous les composants sont standalone, ChangeDetectionStrategy.OnPush, entièrement typés TypeScript.

DESIGN TOKENS Kovixel :
- Primary: violet-600=#7C3AED (default), violet-700=#6D28D9 (hover), violet-800=#5B21B6 (active)
- Fond app: bg-gray-50 | Cards: bg-white | Sidebar: bg-gray-950
- Texte: gray-900 (titre), gray-600 (body), gray-400 (placeholder)
- Border: border-gray-200 | Radius: rounded-lg (cards), rounded-xl (modals), rounded-full (badges)
- Shadow: shadow-sm (cards), shadow-md (hover), shadow-xl (modals)

COMPOSANTS À GÉNÉRER dans src/app/shared/components/ :

1. button/button.component.ts
   @Input variant: 'primary'|'secondary'|'ghost'|'danger' = 'primary'
   @Input size: 'sm'|'md'|'lg' = 'md'
   @Input loading = false (affiche spinner inline, désactive le bouton)
   @Input disabled = false
   @Input fullWidth = false
   Classes CSS par variant et size via HostBinding ou ngClass conditionnel
   - primary: bg-violet-600 hover:bg-violet-700 text-white shadow-sm
   - secondary: bg-white border border-gray-300 text-gray-700 hover:bg-gray-50
   - ghost: text-gray-600 hover:bg-gray-100 hover:text-gray-900
   - danger: bg-red-600 hover:bg-red-700 text-white

2. card/card.component.ts
   @Input padding: 'sm'|'md'|'lg' = 'md'
   @Input hoverable = false (ajoute hover:shadow-md cursor-pointer transition)
   @Input border = true
   Template: bg-white rounded-xl shadow-sm + padding conditionnel + <ng-content>

3. badge/badge.component.ts
   @Input variant: 'free'|'pro'|'enterprise'|'success'|'warning'|'error'|'info'|'pending'
   Inline span avec rounded-full px-2.5 py-0.5 text-xs font-medium
   - free: bg-gray-100 text-gray-600
   - pro: bg-violet-100 text-violet-700 font-semibold
   - enterprise: bg-amber-100 text-amber-700
   - success: bg-green-100 text-green-700
   - warning: bg-yellow-100 text-yellow-700
   - error: bg-red-100 text-red-700
   - pending: bg-blue-100 text-blue-700 (animate-pulse)

4. spinner/spinner.component.ts
   @Input size: 'xs'|'sm'|'md'|'lg' = 'md'
   @Input color: 'primary'|'white'|'gray' = 'primary'
   SVG cercle avec stroke-dasharray + animation CSS spin
   Couleurs: primary=violet-600, white=#fff, gray=gray-400

5. progress-bar/progress-bar.component.ts
   @Input value: number (0-100)
   @Input label: string = ''
   @Input showPercent = true
   @Input animated = true (transition-all duration-700 ease-out)
   Couleur auto: 0-79%=violet, 80-94%=yellow-500, 95-100%=red-500
   @Input color: 'primary'|'success'|'warning'|'danger' = 'primary' (override auto)
   Barre arrondie h-2 bg-gray-200 overflow-hidden

6. file-dropzone/file-dropzone.component.ts
   @Input accept = '.pdf' (ex: '.pdf,.docx')
   @Input multiple = false
   @Input maxSizeMb = 50
   @Input label = 'Glissez votre fichier ici ou cliquez pour parcourir'
   @Output filesSelected = new EventEmitter<File[]>()
   État interne: isDragging signal, selectedFiles signal<File[]>
   - Zone: border-2 border-dashed rounded-xl p-8 text-center cursor-pointer
   - Idle: border-gray-300 bg-gray-50 hover:border-violet-400 hover:bg-violet-50
   - Dragging: border-violet-500 bg-violet-50 scale-[1.02] transition
   - Fichiers sélectionnés: liste avec icône PDF + nom + taille (FileSize pipe) + bouton supprimer
   - Validation: type MIME + taille, affiche erreur inline en rouge sous la zone

7. modal/modal.component.ts
   @Input isOpen = false
   @Input title = ''
   @Input size: 'sm'|'md'|'lg'|'xl' = 'md'
   @Input closable = true
   @Output closed = new EventEmitter<void>()
   - Backdrop: fixed inset-0 bg-black/50 backdrop-blur-sm (CDK Overlay OU ngIf+transition)
   - Panel: bg-white rounded-2xl shadow-2xl max-h-[90vh] overflow-y-auto
   - Tailles: sm=max-w-sm, md=max-w-md, lg=max-w-lg, xl=max-w-2xl
   - Animation: slide-in du bas (transform + opacity) sur 200ms
   - Fermeture: clic backdrop + touche Escape (HostListener)
   - Header: titre + bouton X, body: <ng-content select="[modal-body]">, footer: <ng-content select="[modal-footer]">

8. alert/alert.component.ts
   @Input type: 'success'|'error'|'warning'|'info' = 'info'
   @Input message: string
   @Input title: string = ''
   @Input dismissible = false
   @Output dismissed = new EventEmitter<void>()
   Icône lucide (CheckCircle/XCircle/AlertTriangle/Info) + message + X optionnel

9. empty-state/empty-state.component.ts
   @Input icon: string (lucide icon name)
   @Input title: string
   @Input description: string
   @Input actionLabel: string = ''
   @Output actionClicked = new EventEmitter<void>()
   Centré, icône grande en violet-200, titre gray-900, description gray-500, bouton optionnel

10. src/app/shared/pipes/file-size.pipe.ts  (1024 → "1 KB", 1048576 → "1 MB")
11. src/app/shared/pipes/time-ago.pipe.ts   ("il y a 3 minutes", "il y a 2 jours")
12. src/app/shared/pipes/truncate.pipe.ts   (maxLength + ellipsis)
13. src/app/shared/index.ts                 (barrel export de tout)
Étape 4 — Pages Auth, Dashboard & Documents ✅
Ce qui est généré : Login/Register, Dashboard avec KPIs et quotas, liste/upload/détail documents

Tu es un expert Angular 19 + TailwindCSS. Génère les pages Auth, Dashboard et Documents pour kovixel-ui.

MODÈLES TypeScript à définir dans core/models/ :
- DocumentResponse { id: string, name: string, fileSize: number, contentType: string, createdAt: string, status: 'PENDING'|'READY'|'FAILED', ingested: boolean }
- QuotaStatusResponse { plan: UserPlan, summaryUsed: number, summaryLimit: number, qnaUsed: number, qnaLimit: number, conversionUsed: number, conversionLimit: number, maxFileSizeMb: number }
- JobResponse { jobId: string, type: string, status: 'PENDING'|'RUNNING'|'DONE'|'FAILED', createdAt: string, completedAt?: string }

SERVICES à générer dans core/services/ :

document.service.ts :
- getAll(): Observable<DocumentResponse[]>  → GET /api/v1/documents
- getById(id): Observable<DocumentResponse> → GET /api/v1/documents/{id}
- upload(file: File): Observable<HttpEvent<DocumentResponse>> → POST /api/v1/documents (multipart)
- delete(id): Observable<void>               → DELETE /api/v1/documents/{id}

quota.service.ts :
- getMyQuota(): Observable<QuotaStatusResponse> → GET /api/v1/quota/me
- quota = signal<QuotaStatusResponse|null>(null)
- loadQuota(): void (appelle API + met signal à jour)
- isNearLimit(feature: 'summary'|'qna'|'conversion'): computed (> 80%)
- isAtLimit(feature): computed (>= 100% ou used >= limit)

job.service.ts :
- getMyJobs(page, size): Observable<any> → GET /api/v1/jobs/my
- getJob(jobId): Observable<JobResponse>  → GET /api/v1/jobs/{jobId}

PAGES À GÉNÉRER :

1. src/app/features/auth/login/login.component.ts + template inline
   - ReactiveForm: email (required, email validator), password (required, minLength 8)
   - État loading = signal(false), error = signal<string|null>(null)
   - Submit: call authService.login(), navigate('/dashboard'), catch → error.set(msg)
   - Design: AuthLayout, titre "Bon retour !", sous-titre, form, lien register
   - Animations: shake du formulaire sur erreur (keyframe CSS)

2. src/app/features/auth/register/register.component.ts + template inline
   - ReactiveForm: email, password, confirmPassword
   - Validator custom: passwordsMatch (confirmPassword === password)
   - Conditions password visibles (8 chars, 1 majuscule, 1 chiffre) avec icônes check/x

3. src/app/features/dashboard/dashboard.component.ts + template inline
   Services injectés: documentService, quotaService, jobService
   Signaux: documents = signal<DocumentResponse[]>([]), quota = signal<...>(null), recentJobs = signal<JobResponse[]>([])
   
   ngOnInit: charge les 3 sources en parallèle (forkJoin), met à jour les signaux
   
   TEMPLATE SECTIONS :
   a) Hero row: "Bonjour [email]" + date + bouton "Uploader un PDF" (violet, icône Upload)
   b) 4 KPI Cards (bg-white rounded-xl shadow-sm, icône colorée dans cercle) :
      - Documents : count total, icône FileText violet
      - Résumés : quota.summaryUsed, icône Sparkles blue
      - Questions : quota.qnaUsed, icône MessageSquare green
      - Conversions : quota.conversionUsed, icône RefreshCw orange
   c) Section Quotas (3 ProgressBar côte à côte) avec titre "Utilisation aujourd'hui"
      Afficher badge plan + lien "Passer à PRO" si plan FREE et > 70% d'un quota
   d) Documents récents : table 5 lignes (nom, taille|FileSize pipe, date|timeAgo, statut badge, actions)
   e) Jobs récents : liste 3 derniers jobs (type, statut, durée)
   
   Utiliser @defer pour les sections b) et c) avec placeholder skeleton (animate-pulse)

4. src/app/features/documents/document-list/document-list.component.ts + template
   - documents = signal<DocumentResponse[]>([])
   - searchQuery = signal(''), statusFilter = signal<string|null>(null)
   - filteredDocuments = computed(() => filter documents by search + status)
   - Barre d'actions: input search (debounce 300ms), filtre statut (dropdown), bouton "Nouveau document"
   - Dropzone drag-drop permanente en haut (FileDropzoneComponent, visible si liste vide ou toujours affiché selon UX)
   - Table: nom (tronqué 40 chars), taille, date upload (timeAgo), badge statut, menu actions (Voir/Résumé/Q&A/Extraction/Supprimer)
   - Suppression: modal confirmation avant DELETE
   - Pagination: 10 par page, client-side

5. src/app/features/documents/document-upload/document-upload.component.ts + template
   - Modal (ModalComponent) contenant FileDropzoneComponent
   - Après sélection fichier: affiche barre de progression (HttpEventType.UploadProgress)
   - État: idle | uploading | processing | done | error
   - @Output uploadComplete = new EventEmitter<DocumentResponse>()

6. src/app/features/documents/document-detail/document-detail.component.ts + template
   - Charge le document via documentId de l'URL
   - Tabs [Infos, Résumé, Q&A, Extraction] avec @defer { loadComponent } sur chaque tab
   - Tab Infos: nom, taille, date, statut, bouton Supprimer
   - Breadcrumb: Documents > [nom fichier tronqué]
Étape 5 — Pages IA : Résumé, Q&A & Extraction ✅
Ce qui est généré : Interfaces IA avec polling async, chat Q&A conversationnel, extraction avec templates et export

Tu es un expert Angular 19. Génère les pages IA de kovixel-ui : Résumé, Q&A et Extraction.

ENDPOINTS BACKEND :

RÉSUMÉ :
- POST /api/v1/documents/summarize (multipart: file) → SummaryResponse { id, documentId, content, language, createdAt } OU { jobId: UUID }
- GET /api/v1/documents/{documentId}/summary → SummaryResponse

Q&A :
- POST /api/v1/documents/{documentId}/qna/ask → body: { question, sessionId? } → QnaResponse { sessionId, answer, sources: string[], confidence: number }
- GET /api/v1/documents/{documentId}/qna/sessions/{sessionId}/history → QnaMessage[]

EXTRACTION :
- GET /api/v1/extraction-templates → ExtractionTemplate[] [{ id, name, description, fieldsSchema }]
- POST /api/v1/documents/{documentId}/extract → body: { templateId? } → ExtractionResult { id, fields: Record<string,any>, createdAt }
- GET /api/v1/extractions/{id}/export?format=json|csv|xlsx → Blob (fichier)

JOBS POLLING :
- GET /api/v1/jobs/{jobId} → { jobId, status: 'PENDING'|'RUNNING'|'DONE'|'FAILED', result? }
Pattern RxJS: interval(2000).pipe(switchMap(() => jobService.getJob(jobId)), takeWhile(j => !['DONE','FAILED'].includes(j.status), true))

SERVICES :

summary.service.ts :
- summarize(file: File): Observable<SummaryResponse | { jobId: string }>
- getSummary(documentId): Observable<SummaryResponse>

qna.service.ts :
- ask(documentId, request): Observable<QnaResponse>
- getHistory(documentId, sessionId): Observable<QnaMessage[]>
- getSessionId(documentId): string|null → localStorage: kovixel_qna_{documentId}
- saveSessionId(documentId, sessionId): void

extraction.service.ts :
- getTemplates(): Observable<ExtractionTemplate[]>
- extract(documentId, request): Observable<ExtractionResult>
- exportResult(extractionId, format): Observable<Blob>
- triggerDownload(blob: Blob, filename: string): void

job-polling.service.ts :
- poll(jobId): Observable<JobStatusResponse> (RxJS interval + switchMap + takeWhile)
- Sans polling (passe directement le résultat si status=DONE à la réception)

PAGES :

1. src/app/features/summary/summary.component.ts + template
   Steps (wizard 3 étapes) :
   Step 1 — Upload: FileDropzoneComponent (accept=".pdf")
   Step 2 — Génération: bouton "Générer le résumé" → état loading avec progress indéterminé
   Step 3 — Résultat: 
     - Contenu en markdown (ngx-markdown) dans une card
     - Métadonnées: langue détectée (flag emoji), mots estimés, date
     - Actions: Copier (clipboard API), Télécharger .txt, Poser une question (→ Q&A)
   
   Si jobId retourné → affiche JobProgressComponent, subscribe poll, affiche résultat quand DONE

2. src/app/features/qna/qna.component.ts + template
   Layout 2 colonnes :
   - Colonne gauche (w-64): sélecteur de document (liste scrollable avec search)
   - Colonne principale: interface chat
   
   CHAT :
   - Messages utilisateur: bulle droite bg-violet-600 text-white rounded-2xl rounded-tr-sm max-w-[80%]
   - Réponses IA: bulle gauche bg-white border border-gray-200 rounded-2xl rounded-tl-sm
   - Confidence badge sur chaque réponse (vert > 0.8, jaune 0.5-0.8, rouge < 0.5)
   - Sources: accordéon collapsible sous chaque réponse
   - Skeleton 3 lignes pendant loading (animate-pulse)
   - Scroll automatique vers le bas après chaque message (ViewChild + scrollIntoView)
   
   INPUT AREA :
   - Textarea autoresize (max 4 lignes), placeholder "Posez une question sur ce document..."
   - Bouton envoyer (disabled si vide ou loading)
   - Raccourci Ctrl+Enter pour envoyer
   - Limite visuelle 500 chars avec compteur
   
   Session: au changement de document → charge l'historique du sessionId stocké

3. src/app/features/extraction/extraction.component.ts + template
   
   Sélection document (si pas de documentId en route param)
   
   MODE TEMPLATE (par défaut):
   - Grid 2x2 de cards template (INVOICE/CONTRACT/CV_RESUME/MEDICAL)
   - Chaque card: icône colorée, nom, description courte, champs listés en tags
   - Card sélectionnée: border-violet-500 bg-violet-50 ring-2
   
   RÉSULTAT :
   - Table 2 colonnes (Champ | Valeur) avec alternance bg-gray-50
   - Valeurs null affichées en "—" gris
   - Actions export: 3 boutons [JSON] [CSV] [XLSX] avec icônes download
   
   HISTORIQUE :
   - Accordéon: liste des extractions précédentes (template, date, bouton re-télécharger)

4. src/app/shared/components/job-progress/job-progress.component.ts
   @Input jobId: string
   @Output completed = new EventEmitter<any>() (émet result quand DONE)
   @Output failed = new EventEmitter<string>() (émet errorMessage quand FAILED)
   
   Affichage :
   - PENDING: icône Clock + "En attente..." + spinner gris
   - RUNNING: icône Cpu (animate-spin violet) + "Traitement en cours..." + barre indéterminée violette
   - DONE: icône CheckCircle vert + "Terminé !" + fadeOut après 2s
   - FAILED: icône XCircle rouge + message erreur
   
   Démarre le polling en ngOnInit, stopOnDestroy avec takeUntilDestroyed()
Étape 6 — Page Conversion PDF
Ce qui est généré : Grille de 9 outils de conversion, formulaires dynamiques, gestion du download de fichiers binaires

Tu es un expert Angular 19 + TailwindCSS + @angular/cdk. Génère la page Conversion PDF pour kovixel-ui.

ENDPOINTS (multipart/form-data → byte[] OU { jobId } si > 10MB) :
- POST /api/v1/convert/pdf-to-word
- POST /api/v1/convert/pdf-to-images?format=png|jpg&dpi=150|300
- POST /api/v1/convert/pdf-to-excel
- POST /api/v1/convert/images-to-pdf (files[])
- POST /api/v1/convert/word-to-pdf  [PRO]
- POST /api/v1/convert/excel-to-pdf [PRO]
- POST /api/v1/pdf/merge (files[] multi-PDF)
- POST /api/v1/pdf/split?pages=1-3,4-6
- POST /api/v1/pdf/compress?level=SCREEN|EBOOK|PRINTER

SERVICE conversion.service.ts :
- Méthode par endpoint, retourne Observable<Blob | { jobId: string }>
- downloadBlob(blob: Blob, filename: string): void → URL.createObjectURL + <a> click + revoke
- Enum ConversionType: PDF_TO_WORD | PDF_TO_IMAGES | PDF_TO_EXCEL | IMAGES_TO_PDF | WORD_TO_PDF | EXCEL_TO_PDF | MERGE | SPLIT | COMPRESS
- Interface ConversionTool { type, title, description, icon, accept, multiple, proOnly, outputFormat }

PAGES :

1. src/app/features/conversion/conversion.component.ts + template (page principale)
   
   tools: ConversionTool[] = [...] (9 outils définis)
   
   LAYOUT :
   - Header: titre "Outils de conversion PDF" + description
   - Grille responsive: grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4
   - Chaque tool card :
     * Icône colorée (cercle 48px) + titre + description
     * Badge "PRO" en rouge si proOnly ET plan FREE
     * hover:shadow-md hover:border-violet-300 transition-all cursor-pointer
     * Clic → selectedTool = tool → ouvre ConversionPanelComponent (section expandable sous la grille, pas de modal)
   
   - Section résultats en bas (si result disponible)

2. src/app/features/conversion/components/conversion-panel.component.ts + template
   @Input tool: ConversionTool
   @Output close = new EventEmitter()
   
   Rendu dynamique selon ConversionType :
   - PDF_TO_IMAGES: FileDropzone + RadioGroup (PNG/JPG) + RadioGroup (72/150/300 DPI)
   - SPLIT: FileDropzone + Input pages range + helper text "ex: 1-3, 5, 7-9"
   - COMPRESS: FileDropzone + 3 cards SCREEN/EBOOK/PRINTER (visuel icône + label + description taille)
   - MERGE: FileDropzone (multiple=true) + liste avec CDK DragDrop pour réordonner
   - Autres: FileDropzone simple + bouton Convertir
   
   État: idle | loading | success | error (signal<ConversionState>)
   Bouton Convertir: disabled si pas de fichier ou loading

3. src/app/features/conversion/components/conversion-result.component.ts
   @Input filename: string
   @Input blob: Blob
   @Input type: string
   @Output newConversion = new EventEmitter()
   
   - Carte verte (bg-green-50 border-green-200): ✓ "Conversion réussie !"
   - Nom fichier + taille résultat (FileSize pipe)
   - Bouton "Télécharger" (appelle downloadBlob)
   - Bouton "Nouvelle conversion" (émet newConversion)
   - Si images: préview thumbnails en grille (si Blob = image)

4. IMPORTANT - Gestion blob dans Angular SSR :
   - Utiliser isPlatformBrowser avant tout URL.createObjectURL
   - Interface PLATFORM_ID injection

DESIGN par catégorie :
- PDF tools: icônes violet (FileText, Scissors, Minimize2, GitMerge)
- Office export: icônes blue (FileWord, FileSpreadsheet, FilePresentation)
- Image: icônes green (Image, Images)
- Compression levels card: bg-white hover:bg-violet-50, selected=bg-violet-100 border-violet-500 ring-2
Étape 7 — Abonnements, Paramètres & Optimisations
Ce qui est généré : Page pricing/plans, settings utilisateur, optimisations performance (SSR, preloading, Web Worker)

Tu es un expert Angular 19 performance + UX. Génère les pages Subscription/Settings et les optimisations pour kovixel-ui.

ENDPOINTS :
- GET /api/v1/subscriptions/me (ou /user/{id}) → { plan, status, startDate, endDate }
- POST /api/v1/subscriptions → { plan }
- GET /api/v1/usage/me?period=MONTH → UsageSummaryResponse { byFeature: [{feature, calls, costUsd}...] }

PAGES :

1. src/app/features/subscription/subscription.component.ts + template
   
   PLANS section (3 cards) :
   - FREE: bg-white border-gray-200, badge "Actuel" si plan = FREE
   - PRO: bg-violet-600 text-white (highlighted), badge "Plus populaire" ruban violet-900
     * border-violet-600 ring-2 ring-violet-600 ring-offset-2 scale-[1.02]
   - ENTERPRISE: bg-gray-950 text-white
   
   Features matrix per plan :
   FREE: 10 résumés/j, 10 questions/j, 2 extractions/j, fichiers < 10MB, pas de LibreOffice
   PRO: 200 résumés/j, 500 questions/j, 50 extractions/j, fichiers < 100MB, LibreOffice ✓, cache ✓
   ENTERPRISE: Illimité tout, 500MB, support dédié, API access
   
   Boutons: "Passer à PRO" (→ intégration Stripe future, pour l'instant toast "Bientôt disponible")
   
   UTILISATION section :
   - Tableau usage du mois (par feature: appels, coût estimé USD)
   
   MON ABONNEMENT section :
   - Plan actuel, date début, bouton "Annuler" (modal confirmation)

2. src/app/features/settings/settings.component.ts + template
   Tabs [Compte, Sécurité, Danger Zone] :
   - Compte: affichage email (read-only), préférence notifications
   - Sécurité: form changement MDP (ancien + nouveau + confirmer)
   - Danger Zone: "Supprimer mon compte" bg-red-50 border-red-200, double confirmation (saisir email + bouton rouge)

3. src/app/features/not-found/not-found.component.ts + template
   Illustration: grand "404" en text-violet-200 font-black text-[180px]
   Titre: "Page introuvable", description, bouton "Retour au dashboard"

OPTIMISATIONS À IMPLÉMENTER :

4. src/app/core/preloading/kovixel-preloading.strategy.ts
   Implémente PreloadingStrategy
   Précharge: 'documents', 'summary', 'conversion' après authentification
   Ignore les autres routes (QA, extraction → on-demand)

5. Mise à jour app.config.ts :
   - withPreloading(KovixelPreloadingStrategy)
   - withComponentInputBinding() pour passer les route params comme @Input
   - provideClientHydration(withEventReplay())
   - APP_INITIALIZER: charge authService.initFromStorage() + quotaService.loadQuota() au démarrage

6. src/app/features/dashboard/dashboard.component.ts UPDATE :
   Ajouter les blocs @defer avec @loading et @placeholder :
   @defer (on idle) { <quota-section> } @placeholder { <quota-skeleton> }
   @defer (on viewport) { <recent-jobs> } @placeholder { <skeleton> }

7. Toutes les images/icônes :
   - SVG inline pour les icônes critiques above-the-fold
   - loading="lazy" sur tous les <img>
   - Générer un script generate-icons.ts qui extrait les icônes lucide utilisées

8. src/app/shared/directives/track-by.directive.ts
   Directive *appTrackBy="item.id" (wrapper de trackBy pour les ngFor)

9. docker/nginx.conf pour le déploiement SSR :
   - Proxy /api/* → backend:8080
   - Serve static files avec cache-control immutable
   - Compression gzip
   - HTTP/2 push hints pour les bundles critiques
   
10. Mise à jour docker-compose.yml du projet kovixel (backend) :
    Ajouter le service kovixel-ui :
    image: node:22-alpine (build) → nginx:alpine (serve)
    build context: ./kovixel-ui
    ports: 80:80
    environment: API_URL=http://kovixel-app:8080
Commandes de démarrage
# Créer le projet
ng new kovixel-ui --routing --style=css --ssr --standalone

# Installer les dépendances
npm install -D tailwindcss postcss autoprefixer
npm install lucide-angular ngx-toastr ngx-markdown

# Initialiser Tailwind
npx tailwindcss init

# Développement (avec proxy vers backend)
ng serve --proxy-config proxy.conf.json

# Build production SSR
npm run build:ssr