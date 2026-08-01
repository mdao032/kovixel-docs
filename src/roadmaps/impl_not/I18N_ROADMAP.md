# Roadmap — Internationalisation (i18n) de Kovixel

> **Kovixel** · Spring Boot 3.4.3 + Angular 18 · Juin 2026
>
> Objectif : transformer Kovixel en produit mondial first-class — 15 langues, support RTL complet, pipeline de traduction industrialisé, performance optimale — avec une architecture partageable entre web, desktop et mobile.

---

## 1. Langues Cibles

### 1.1 Catalogue des langues (15 locales)

| # | Locale | Langue | Région principale | Direction | Priorité |
|---|--------|--------|-------------------|-----------|----------|
| 1 | `fr` | Français | France, Belgique, Québec, Afrique | LTR | Existant |
| 2 | `en` | English | USA, UK, Global | LTR | **P0** |
| 3 | `es` | Español | Espagne, Amérique latine | LTR | **P1** |
| 4 | `de` | Deutsch | Allemagne, Autriche, Suisse | LTR | **P1** |
| 5 | `pt-BR` | Português (Brasil) | Brésil | LTR | **P1** |
| 6 | `it` | Italiano | Italie, Suisse | LTR | **P2** |
| 7 | `nl` | Nederlands | Pays-Bas, Belgique | LTR | **P2** |
| 8 | `pl` | Polski | Pologne | LTR | **P2** |
| 9 | `tr` | Türkçe | Turquie | LTR | **P2** |
| 10 | `ru` | Русский | Russie, Europe de l'Est | LTR | **P2** |
| 11 | `ar` | العربية | MENA | **RTL** | **P3** |
| 12 | `he` | עברית | Israël | **RTL** | **P3** |
| 13 | `ja` | 日本語 | Japon | LTR (vertical opt.) | **P3** |
| 14 | `zh-CN` | 中文（简体） | Chine continentale | LTR | **P3** |
| 15 | `ko` | 한국어 | Corée du Sud | LTR | **P3** |

> **Expansion possible (P4)** : `pt-PT`, `sv`, `da`, `fi`, `cs`, `hu`, `uk`, `th`, `vi`, `id`

### 1.2 Stratégie de fallback

```
zh-TW → zh-CN → en
pt-PT → pt-BR → en
es-MX → es    → en
       ↕
[toute locale inconnue] → en (langue de référence globale)
```

---

## 2. État des Lieux

### 2.1 Ce qui existe

| Composant | État i18n |
|-----------|-----------|
| Angular frontend | Chaînes en dur en français dans les templates et composants |
| Spring Boot backend | Messages d'erreur en français (`KovixelException`, `ErrorCode`) |
| Données AI (résumés, extractions) | Produites dans la langue du contenu source |
| Emails transactionnels | Non implémentés (roadmap auth) |
| Base de données | Données textuelles non localisées (templates, plans) |

### 2.2 Volume estimé des chaînes

| Zone | Chaînes estimées |
|------|-----------------|
| Navigation, menus, boutons | ~120 |
| Formulaires (labels, placeholders, erreurs) | ~180 |
| Messages d'état, notifications, toasts | ~90 |
| Pages marketing / onboarding | ~200 |
| Emails transactionnels | ~80 |
| Messages d'erreur API (backend) | ~60 |
| **Total** | **~730 chaînes** |

---

## 3. Architecture Technique

### 3.1 Vue d'ensemble

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         KOVIXEL i18n STACK                              │
├───────────────────┬──────────────────────┬──────────────────────────────┤
│   WEB (Angular)   │  DESKTOP (Electron)  │   MOBILE (Capacitor/Flutter) │
│                   │                      │                              │
│  @ngx-translate   │  Réutilise le bundle │  ngx-translate (Capacitor)  │
│  +ICU messages    │  Angular i18n        │  flutter_localizations+arb  │
│  +Intl API        │  via IPC bridge      │  (Flutter natif)            │
├───────────────────┴──────────────────────┴──────────────────────────────┤
│                      SHARED TRANSLATION LAYER                           │
│                                                                         │
│   📁 i18n/                                                              │
│     ├── en/  (source of truth)                                          │
│     │    ├── common.json    ← boutons, actions génériques               │
│     │    ├── auth.json      ← login, register, sessions                 │
│     │    ├── documents.json ← upload, liste, PDF viewer                 │
│     │    ├── summary.json   ← résumés IA                                │
│     │    ├── extraction.json← extraction structurée                     │
│     │    ├── qna.json       ← Q&A IA                                    │
│     │    ├── billing.json   ← abonnements, plans                        │
│     │    ├── settings.json  ← profil, sécurité                          │
│     │    └── errors.json    ← messages d'erreur                         │
│     ├── fr/ (mêmes fichiers traduits)                                   │
│     ├── es/                                                             │
│     └── ...                                                             │
│                                                                         │
│   TMS : Crowdin (sync automatique via GitHub Actions)                   │
├─────────────────────────────────────────────────────────────────────────┤
│                         BACKEND (Spring Boot)                           │
│   messages_{locale}.properties  ← erreurs, emails, notifications        │
│   LocaleResolver (Accept-Language) · Intl formatting beans              │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Choix de la librairie Angular : `@ngx-translate` vs Angular built-in i18n

| Critère | `@ngx-translate` (choix retenu) | Angular built-in i18n |
|---------|--------------------------------|----------------------|
| Chargement | Runtime (lazy HTTP) | Build-time (N builds) |
| Changement de langue | Sans rechargement | Rechargement obligatoire |
| Bundle par langue | ~30-50 KB gzippé | 1 build par locale |
| ICU plurals | Via `@ngx-translate/message-format` | Natif |
| Scalabilité (15 langues) | ✅ Optimal | ❌ 15 builds CI |
| SSR/Angular Universal | ✅ Compatible | ✅ Compatible |
| Capacitor/mobile | ✅ Réutilisable | ❌ Friction |

> **Décision** : `@ngx-translate/core` + `@ngx-translate/http-loader` + `@ngx-translate/message-format` (ICU)

---

## 4. Format des Clés de Traduction

### 4.1 Convention de nommage

```
{namespace}.{feature}.{element}[.{variant}]
```

```json
// en/common.json
{
  "actions": {
    "save": "Save",
    "cancel": "Cancel",
    "delete": "Delete",
    "confirm": "Confirm",
    "back": "Back",
    "loading": "Loading..."
  },
  "pagination": {
    "of": "{{current}} of {{total}}",
    "items": "{count, plural, =0 {No items} one {1 item} other {# items}}"
  },
  "dates": {
    "today": "Today",
    "yesterday": "Yesterday",
    "daysAgo": "{days, plural, one {# day ago} other {# days ago}}"
  }
}

// en/auth.json
{
  "login": {
    "title": "Welcome back",
    "subtitle": "Sign in to your account",
    "email": { "label": "Email address", "placeholder": "you@example.com" },
    "password": { "label": "Password", "forgot": "Forgot your password?" },
    "submit": "Sign in",
    "oauth": {
      "divider": "Or continue with",
      "google": "Continue with Google",
      "apple": "Continue with Apple",
      "microsoft": "Continue with Microsoft"
    },
    "noAccount": "Don't have an account?",
    "register": "Create an account"
  },
  "errors": {
    "invalidCredentials": "Invalid email or password",
    "accountLocked": "Your account has been locked. Try again in {minutes} minutes.",
    "tooManyAttempts": "{remaining, plural, one {# attempt} other {# attempts}} remaining before lockout"
  }
}
```

### 4.2 Pluriels & Variables (format ICU)

```json
// Format ICU — supporté par @ngx-translate/message-format
{
  "documents": {
    "count": "{count, plural, =0 {No documents} one {1 document} other {# documents}}",
    "quota": "You have used {used} of {total} documents this month",
    "upload": {
      "maxSize": "File must not exceed {size, number, ::compact-short} MB"
    }
  },
  "extraction": {
    "fields": "{count, plural, one {1 field extracted} other {# fields extracted}}",
    "confidence": "{level, select, high {High confidence} medium {Medium confidence} low {Low confidence} other {Unknown}}"
  }
}
```

### 4.3 Règles de nommage des clés

- **Toujours en anglais** (même fichier `en/` = source de vérité)
- **Jamais de valeurs imbriquées > 4 niveaux**
- **Pas d'abréviation** : `documents.upload.success` non `docs.upl.ok`
- **Préfixer les erreurs** : `errors.{code}` — mappé sur `ErrorCode` backend
- **Jamais de clés dynamiques** : `status.${state}` est interdit — utiliser ICU `select`

---

## 5. Frontend Angular — Implémentation

### 5.1 Installation

```bash
npm install @ngx-translate/core @ngx-translate/http-loader
npm install @ngx-translate/message-format        # ICU plurals
npm install @angular/localize                     # Intl API support
```

### 5.2 Configuration `app.config.ts`

```typescript
import { TranslateModule, TranslateLoader } from '@ngx-translate/core';
import { TranslateMessageFormatCompiler } from '@ngx-translate/message-format';
import { HttpClient } from '@angular/common/http';
import { TranslateHttpLoader } from '@ngx-translate/http-loader';

export function HttpLoaderFactory(http: HttpClient) {
  return new TranslateHttpLoader(http, '/assets/i18n/', '.json');
}

// app.config.ts
export const appConfig: ApplicationConfig = {
  providers: [
    provideHttpClient(withInterceptors([authInterceptor])),

    importProvidersFrom(
      TranslateModule.forRoot({
        defaultLanguage: 'en',
        loader: {
          provide: TranslateLoader,
          useFactory: HttpLoaderFactory,
          deps: [HttpClient],
        },
        compiler: {
          provide: TranslateCompiler,
          useClass: TranslateMessageFormatCompiler,
        },
        missingTranslationHandler: {
          provide: MissingTranslationHandler,
          useClass: KovixelMissingTranslationHandler,  // Log + fallback vers en
        },
      })
    ),
  ],
};
```

### 5.3 I18nService — Service global

```typescript
@Injectable({ providedIn: 'root' })
export class I18nService {
  private readonly translate = inject(TranslateService);
  private readonly _locale = signal<string>('en');
  readonly locale = this._locale.asReadonly();

  // RTL locales
  private readonly RTL_LOCALES = new Set(['ar', 'he', 'fa', 'ur']);
  readonly isRtl = computed(() => this.RTL_LOCALES.has(this._locale()));

  // Formatters Intl (réutilisés, pas recréés à chaque appel)
  private _dateFormatter: Intl.DateTimeFormat | null = null;
  private _numberFormatter: Intl.NumberFormat | null = null;
  private _currencyFormatter: Map<string, Intl.NumberFormat> = new Map();

  readonly SUPPORTED_LOCALES: LocaleDescriptor[] = [
    { code: 'en', label: 'English',         flag: '🇬🇧', dir: 'ltr' },
    { code: 'fr', label: 'Français',        flag: '🇫🇷', dir: 'ltr' },
    { code: 'es', label: 'Español',         flag: '🇪🇸', dir: 'ltr' },
    { code: 'de', label: 'Deutsch',         flag: '🇩🇪', dir: 'ltr' },
    { code: 'pt-BR', label: 'Português',   flag: '🇧🇷', dir: 'ltr' },
    { code: 'it', label: 'Italiano',        flag: '🇮🇹', dir: 'ltr' },
    { code: 'nl', label: 'Nederlands',      flag: '🇳🇱', dir: 'ltr' },
    { code: 'pl', label: 'Polski',          flag: '🇵🇱', dir: 'ltr' },
    { code: 'tr', label: 'Türkçe',          flag: '🇹🇷', dir: 'ltr' },
    { code: 'ru', label: 'Русский',         flag: '🇷🇺', dir: 'ltr' },
    { code: 'ar', label: 'العربية',          flag: '🇸🇦', dir: 'rtl' },
    { code: 'he', label: 'עברית',           flag: '🇮🇱', dir: 'rtl' },
    { code: 'ja', label: '日本語',           flag: '🇯🇵', dir: 'ltr' },
    { code: 'zh-CN', label: '中文（简体）', flag: '🇨🇳', dir: 'ltr' },
    { code: 'ko', label: '한국어',           flag: '🇰🇷', dir: 'ltr' },
  ];

  init(): void {
    // 1. Locale persistée par l'utilisateur
    const saved = localStorage.getItem('kovixel_locale');
    // 2. Préférence navigateur
    const browser = navigator.language.split('-')[0];
    // 3. Fallback
    const locale = saved ?? this.resolveLocale(browser) ?? 'en';
    this.setLocale(locale);
  }

  setLocale(code: string): void {
    const resolved = this.resolveLocale(code) ?? 'en';
    this._locale.set(resolved);
    this.translate.use(resolved);
    localStorage.setItem('kovixel_locale', resolved);
    document.documentElement.lang = resolved;
    document.documentElement.dir = this.isRtl() ? 'rtl' : 'ltr';
    this._dateFormatter = null;     // Invalider le cache
    this._numberFormatter = null;
    this._currencyFormatter.clear();
  }

  formatDate(date: Date | string, style: 'short' | 'medium' | 'long' = 'medium'): string {
    this._dateFormatter ??= new Intl.DateTimeFormat(this._locale(), {
      dateStyle: style,
    });
    return this._dateFormatter.format(new Date(date));
  }

  formatNumber(value: number): string {
    this._numberFormatter ??= new Intl.NumberFormat(this._locale());
    return this._numberFormatter.format(value);
  }

  formatCurrency(value: number, currency = 'EUR'): string {
    if (!this._currencyFormatter.has(currency)) {
      this._currencyFormatter.set(currency,
        new Intl.NumberFormat(this._locale(), { style: 'currency', currency })
      );
    }
    return this._currencyFormatter.get(currency)!.format(value);
  }

  formatFileSize(bytes: number): string {
    return new Intl.NumberFormat(this._locale(), {
      notation: 'compact',
      style: 'unit',
      unit: 'megabyte',
      unitDisplay: 'short',
    }).format(bytes / 1_048_576);
  }

  private resolveLocale(code: string): string | undefined {
    const exact = this.SUPPORTED_LOCALES.find(l => l.code === code);
    if (exact) return exact.code;
    const prefix = this.SUPPORTED_LOCALES.find(l => l.code.startsWith(code));
    return prefix?.code;
  }
}
```

### 5.4 Lazy Loading des traductions par namespace

Pour éviter de charger un seul gros fichier JSON (~30 KB), utiliser le chargement par namespace :

```typescript
// Chargement à la demande dans chaque feature module
export function loadTranslations(ns: string[]): CanActivateFn {
  return () => {
    const translate = inject(TranslateService);
    const locale = inject(I18nService).locale();
    return forkJoin(ns.map(n =>
      translate.getTranslation(`${locale}/${n}`)
    )).pipe(map(() => true));
  };
}

// Dans les routes
{
  path: 'extraction',
  canActivate: [loadTranslations(['common', 'documents', 'extraction'])],
  loadComponent: () => import('./features/extraction/extraction.component')
}
```

### 5.5 Pipe personnalisé avec cache de traduction

```typescript
// Préférer le pipe async pour les chaînes dynamiques
// Pour les chaînes statiques dans des templates complexes, utiliser translateInstant

@Pipe({ name: 'localDate', pure: false, standalone: true })
export class LocalDatePipe implements PipeTransform {
  private readonly i18n = inject(I18nService);
  transform(value: Date | string, style: 'short' | 'medium' | 'long' = 'medium'): string {
    return this.i18n.formatDate(value, style);
  }
}
```

### 5.6 Composant Language Switcher

```html
<!-- Dans le header -->
<button
  [matMenuTriggerFor]="langMenu"
  class="flex items-center gap-2 text-sm font-medium"
  [attr.aria-label]="'settings.language.change' | translate">
  <span>{{ currentLocale()?.flag }}</span>
  <span>{{ currentLocale()?.label }}</span>
  <mat-icon>expand_more</mat-icon>
</button>

<mat-menu #langMenu="matMenu">
  <button
    *ngFor="let locale of i18n.SUPPORTED_LOCALES"
    mat-menu-item
    (click)="i18n.setLocale(locale.code)"
    [class.font-semibold]="locale.code === i18n.locale()">
    <span class="mr-2">{{ locale.flag }}</span>
    <span [dir]="locale.dir">{{ locale.label }}</span>
    <mat-icon *ngIf="locale.code === i18n.locale()" class="ml-auto">check</mat-icon>
  </button>
</mat-menu>
```

### 5.7 Support RTL — Angular + Tailwind

```typescript
// effect dans AppComponent pour sync RTL
constructor() {
  const i18n = inject(I18nService);
  effect(() => {
    const isRtl = i18n.isRtl();
    document.documentElement.setAttribute('dir', isRtl ? 'rtl' : 'ltr');
    document.documentElement.setAttribute('lang', i18n.locale());
  });
}
```

```css
/* tailwind.config.js — activer le plugin RTL */
plugins: [
  require('tailwindcss-rtl'),   // ou plugin natif Tailwind v4 `@variant rtl`
],

/* Usage dans les templates :
   margin-left → ml-4 ms-4 (margin-inline-start — RTL-safe)
   padding-right → pr-4 pe-4 (padding-inline-end — RTL-safe)
   text-left → text-start (RTL-safe)
*/
```

```css
/* globals.css — polices spécifiques CJK et Arabic */
@font-face {
  font-family: 'Kovixel';
  src: url('/fonts/inter-var.woff2') format('woff2');
  unicode-range: U+0000-00FF, U+0131, U+0152-0153; /* Latin */
}

/* CJK — charger via Google Fonts avec display=swap pour perf */
[lang="ja"] { font-family: 'Noto Sans JP', sans-serif; }
[lang="zh-CN"] { font-family: 'Noto Sans SC', sans-serif; }
[lang="ko"] { font-family: 'Noto Sans KR', sans-serif; }
[lang="ar"] { font-family: 'Noto Sans Arabic', sans-serif; }
[lang="he"] { font-family: 'Noto Sans Hebrew', sans-serif; }
```

---

## 6. Backend Spring Boot — Implémentation

### 6.1 Structure des fichiers de messages

```
resources/
  i18n/
    messages.properties          ← fallback (English)
    messages_fr.properties
    messages_es.properties
    messages_de.properties
    messages_pt_BR.properties
    messages_it.properties
    messages_nl.properties
    messages_pl.properties
    messages_tr.properties
    messages_ru.properties
    messages_ar.properties
    messages_he.properties
    messages_ja.properties
    messages_zh_CN.properties
    messages_ko.properties
```

```properties
# messages.properties (source de vérité — anglais)
error.ACCESS_DENIED=Access denied
error.RESOURCE_NOT_FOUND=Resource not found: {0}
error.QUOTA_EXCEEDED=Quota exceeded. You have used all {0} {1} for today.
error.INVALID_CREDENTIALS=Invalid email or password
error.ACCOUNT_LOCKED=Account locked. Try again in {0} minutes.
error.DOCUMENT_TOO_LARGE=Document exceeds the maximum size of {0} MB

email.verify.subject=Verify your Kovixel email address
email.verify.body=Click the link below to verify your email address. This link expires in 24 hours.
email.welcome.subject=Welcome to Kovixel, {0}!

quota.unit.summaries=summaries
quota.unit.extractions=extractions
quota.unit.questions=questions
quota.unit.conversions=conversions
```

### 6.2 Configuration Spring Boot

```java
@Configuration
public class LocaleConfig {

    @Bean
    public LocaleResolver localeResolver() {
        // Priorité : 1. paramètre ?lang=fr  2. Accept-Language header  3. fr par défaut
        var resolver = new AcceptHeaderLocaleResolver();
        resolver.setDefaultLocale(Locale.ENGLISH);
        resolver.setSupportedLocales(List.of(
            Locale.ENGLISH, Locale.FRENCH, new Locale("es"),
            Locale.GERMAN, new Locale("pt", "BR"), Locale.ITALIAN,
            new Locale("nl"), new Locale("pl"), new Locale("tr"),
            new Locale("ru"), new Locale("ar"), new Locale("he"),
            Locale.JAPANESE, Locale.SIMPLIFIED_CHINESE, Locale.KOREAN
        ));
        return resolver;
    }

    @Bean
    public MessageSource messageSource() {
        var source = new ReloadableResourceBundleMessageSource();
        source.setBasename("classpath:i18n/messages");
        source.setDefaultEncoding("UTF-8");
        source.setCacheSeconds(3600);          // Reload en dev (hot reload)
        source.setUseCodeAsDefaultMessage(false);
        source.setFallbackToSystemLocale(false); // Ne pas utiliser le locale JVM
        return source;
    }

    @Bean
    public LocalValidatorFactoryBean validator(MessageSource messageSource) {
        var factory = new LocalValidatorFactoryBean();
        factory.setValidationMessageSource(messageSource);  // @Valid errors localisées
        return factory;
    }
}
```

### 6.3 Messages d'erreur localisés dans KovixelException

```java
// Modifier KovixelException pour accepter des args de message
@Getter
public class KovixelException extends RuntimeException {
    private final ErrorCode errorCode;
    private final HttpStatus status;
    private final Object[] messageArgs;   // Arguments pour le MessageSource

    public KovixelException(ErrorCode errorCode, HttpStatus status, Object... args) {
        super(errorCode.name());
        this.errorCode = errorCode;
        this.status = status;
        this.messageArgs = args;
    }
}

// Dans GlobalExceptionHandler :
@ExceptionHandler(KovixelException.class)
public ResponseEntity<ErrorResponse> handleKovixelException(
        KovixelException ex, Locale locale) {

    String message = messageSource.getMessage(
        "error." + ex.getErrorCode().name(),
        ex.getMessageArgs(),
        ex.getMessage(),   // fallback si clé absente
        locale
    );

    return ResponseEntity
        .status(ex.getStatus())
        .body(new ErrorResponse(ex.getErrorCode().name(), message));
}
```

### 6.4 Contenu IA localisé

Kovixel produit des résumés, extractions et réponses Q&A via IA. Il faut instruire le modèle de répondre dans la langue de l'utilisateur :

```java
// Dans AiProviderService ou les services appelants :
private String buildSystemPromptWithLocale(String basePrompt, Locale locale) {
    if (locale == null || Locale.ENGLISH.getLanguage().equals(locale.getLanguage())) {
        return basePrompt;
    }
    String langName = locale.getDisplayLanguage(Locale.ENGLISH);  // "French", "German", etc.
    return basePrompt + "\n\nIMPORTANT: Respond in " + langName + " language. " +
           "All extracted data, summaries, and explanations must be in " + langName + ".";
}
```

Le locale est transmis depuis le header `Accept-Language` → `LocaleContextHolder.getLocale()` → propagé aux services AI.

### 6.5 Formatage des données numériques / dates en réponse API

```java
// Convention : l'API retourne TOUJOURS des données brutes non formatées
// - Dates : ISO-8601 string "2026-06-13T10:30:00Z" → formatage côté frontend
// - Montants : Long en centimes ou BigDecimal brut
// - Nombres : primitifs Java
// Le frontend formate avec Intl API selon la locale choisie
// Exception : les messages textuels (erreurs, labels) sont localisés côté backend
```

---

## 7. Pipeline de Traduction — Translation Management System (TMS)

### 7.1 Recommandation : Crowdin

Crowdin est la référence SaaS (utilisé par JetBrains, GitLab, Notion, etc.) :

| Fonctionnalité | Crowdin |
|----------------|---------|
| Sync GitHub (push/pull) | ✅ GitHub Action native |
| Machine Translation (DeepL, Google) | ✅ Intégré |
| Glossaire produit | ✅ "Kovixel", "Extraction Structurée" ne doivent pas être traduits |
| Revue par des humains | ✅ Workflow approval |
| In-context editor (preview UI) | ✅ |
| Screenshots contextuels | ✅ Lier chaque clé à la capture d'écran du composant |
| Plurals ICU | ✅ Éditeur adapté |
| Format JSON | ✅ |
| Prix | Gratuit jusqu'à 50K mots, ~$25/mois ensuite |

> **Alternative open-source auto-hébergée** : [Tolgee](https://tolgee.io) (Spring Boot + PostgreSQL, exportable en JSON, context-aware in-app editor)

### 7.2 GitHub Actions — Sync automatique

```yaml
# .github/workflows/i18n-sync.yml
name: i18n Sync

on:
  push:
    branches: [main]
    paths: ['kovixel-ui/src/assets/i18n/en/**']   # Déclencheur : modification des sources EN

jobs:
  upload-sources:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Upload English source to Crowdin
        uses: crowdin/github-action@v2
        with:
          upload_sources: true
          upload_translations: false
          source: 'kovixel-ui/src/assets/i18n/en/**/*.json'
          translation: 'kovixel-ui/src/assets/i18n/%locale%/%original_file_name%'
        env:
          CROWDIN_PROJECT_ID: ${{ secrets.CROWDIN_PROJECT_ID }}
          CROWDIN_PERSONAL_TOKEN: ${{ secrets.CROWDIN_PERSONAL_TOKEN }}

  download-translations:
    runs-on: ubuntu-latest
    # Déclenchée manuellement ou par webhook Crowdin (100% traduit)
    if: github.event_name == 'workflow_dispatch'
    steps:
      - uses: actions/checkout@v4
      - uses: crowdin/github-action@v2
        with:
          upload_sources: false
          download_translations: true
          create_pull_request: true
          pull_request_title: 'chore(i18n): update translations from Crowdin'
          pull_request_labels: 'i18n, automated'
        env:
          CROWDIN_PROJECT_ID: ${{ secrets.CROWDIN_PROJECT_ID }}
          CROWDIN_PERSONAL_TOKEN: ${{ secrets.CROWDIN_PERSONAL_TOKEN }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 7.3 Workflow de traduction

```
1. Développeur ajoute une clé en anglais (en/feature.json)
   ↓
2. Push sur main → GitHub Action uploade vers Crowdin
   ↓
3. Crowdin MT (DeepL) pré-traduit automatiquement
   ↓
4. Traducteur humain (professionnel ou communauté) révise et approuve
   ↓
5. Crowdin webhook ou Action manuelle télécharge → PR automatique
   ↓
6. Code review + merge → déploiement
```

### 7.4 Glossaire Kovixel (non-traduisibles)

Les termes suivants ne doivent **jamais** être traduits :

```
Kovixel, Dashboard, AI, PDF, CSV, XLSX, JSON, INVOICE, CV, QnA, OCR
```

Les termes suivants ont des traductions fixes par langue :

| FR | EN | ES | DE |
|----|----|----|-----|
| Extraction Structurée | Structured Extraction | Extracción Estructurada | Strukturierte Extraktion |
| Résumé Intelligent | Smart Summary | Resumen Inteligente | Intelligente Zusammenfassung |
| Questions & Réponses | Questions & Answers | Preguntas y Respuestas | Fragen & Antworten |

---

## 8. SEO & Performance

### 8.1 URLs et hreflang

```
Option A — Sous-dossiers (recommandé) :
  https://app.kovixel.com/en/dashboard
  https://app.kovixel.com/fr/dashboard
  https://app.kovixel.com/ar/dashboard

Option B — Sous-domaines :
  https://en.kovixel.com/dashboard
  https://fr.kovixel.com/dashboard

Option C — Accept-Language uniquement (sans signal URL)
```

**Choix recommandé : Option A (sous-dossiers)** pour Angular SPA + SSR.

```html
<!-- index.html — hreflang pour le SEO multi-langue -->
<link rel="alternate" hreflang="en" href="https://app.kovixel.com/en/" />
<link rel="alternate" hreflang="fr" href="https://app.kovixel.com/fr/" />
<link rel="alternate" hreflang="es" href="https://app.kovixel.com/es/" />
<link rel="alternate" hreflang="ar" href="https://app.kovixel.com/ar/" />
<link rel="alternate" hreflang="x-default" href="https://app.kovixel.com/en/" />
```

### 8.2 Performance — Chargement des traductions

```
Budget par fichier de traduction : < 15 KB gzippé par namespace
Total par locale (9 namespaces) : < 50 KB gzippé

Stratégie de préchargement :
1. Détecter la locale au plus tôt (APP_INITIALIZER)
2. Précharger `common.json` en priorité (boutons, navigation)
3. Charger `auth.json` uniquement sur les pages non-auth
4. Charger les namespaces métier (extraction, summary) en lazy dans les routes
```

```typescript
// APP_INITIALIZER — détecter et charger les traductions de base avant le premier rendu
export function initI18n(i18n: I18nService, translate: TranslateService): () => Promise<void> {
  return async () => {
    i18n.init();
    translate.setDefaultLang('en');
    await firstValueFrom(translate.use(i18n.locale()));
  };
}

// app.config.ts
{
  provide: APP_INITIALIZER,
  useFactory: initI18n,
  deps: [I18nService, TranslateService],
  multi: true,
}
```

### 8.3 Polices CJK — Optimisation

Les polices CJK (japonais, chinois, coréen) font plusieurs MB. Utiliser le **subsetting** via Google Fonts avec `text=` param ou unicode-range CSS :

```html
<!-- Charger uniquement si locale CJK active -->
<!-- Dans I18nService.setLocale(), injecter dynamiquement le link -->
<link
  rel="stylesheet"
  href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP&display=swap"
  media="print"
  onload="this.media='all'"
/>
```

---

## 9. Tests d'Internationalisation

### 9.1 Pseudo-localisation

Avant de recevoir les vraies traductions, tester avec de la pseudo-localisation :

```typescript
// En dev, remplacer les chaînes par [Ĥéĺĺö Ŵöŕĺď] pour détecter :
// - UI trop étroite (le français est 20% plus long que l'anglais)
// - Chaînes hardcodées non passées par translate pipe
// - Problèmes d'encoding

// Outil : @sindresorhus/make-synchronous ou yaspeller
// Script : scripts/pseudo-localize.mjs — génère un locale xtd/ de pseudo-traductions
```

### 9.2 Tests de mise en page (Layout Tests)

```
Langues testées en priorité pour le layout :
- Allemand (expansif : +20-35% vs EN)
- Arabe (RTL, densité différente)
- Japonais (caractères larges, pas de wordwrap standard)

Breakpoints à tester par locale :
- Mobile 375px
- Tablette 768px
- Desktop 1280px
- Widescreen 1920px
```

### 9.3 Checklist de validation par langue

```
□ Toutes les chaînes affichées passent par translate pipe
□ Pas de texte tronqué (overflow hidden masqué)
□ Boutons et labels pas coupés
□ RTL : icônes et flèches inversées (arrow-left → arrow-right)
□ RTL : formulaires alignés à droite
□ Dates formatées selon la locale (MM/DD/YYYY vs DD/MM/YYYY vs YYYY年MM月)
□ Nombres : séparateurs décimaux et milliers corrects (1,000.50 vs 1.000,50)
□ Devises : symbole avant ou après (€50 vs 50 €)
□ Pluriels : cas zéro, un, deux, peu, beaucoup (langues slaves et arabes)
□ Emails transactionnels dans la bonne langue
□ Changement de langue sans rechargement de page
□ Persistance de la préférence de langue après logout
```

### 9.4 Tests automatisés

```typescript
// Cypress/Playwright — tester chaque locale critique
describe('i18n smoke tests', () => {
  const locales = ['en', 'fr', 'ar', 'ja'];

  for (const locale of locales) {
    it(`renders login page correctly in ${locale}`, () => {
      cy.visit(`/${locale}/login`);
      cy.get('html').should('have.attr', 'lang', locale);
      cy.get('[data-testid=login-title]').should('be.visible');
      // RTL check
      if (['ar', 'he'].includes(locale)) {
        cy.get('html').should('have.attr', 'dir', 'rtl');
      }
    });
  }
});
```

---

## 10. Desktop — Electron (Phase Future)

Lorsque Kovixel Desktop sera développé avec Electron + Angular :

```
Architecture :
  Electron Main Process (Node.js) — pas de texte UI direct
  Electron Renderer (Angular) — réutilise 100% la couche i18n Angular

Points spécifiques Desktop :
1. Détection locale système : app.getLocale() → Electron → I18nService.init()
2. Menu natif (File, Edit, View...) → doit être traduit séparément
   via Electron Menu API (pas de Angular translate)
3. Notifications système (Notification API) → localiser côté Main Process
4. Dialogue de fichier (dialog.showOpenDialog) → titre en locale locale
```

```javascript
// main.js — Electron
const { app, Menu } = require('electron');

function buildLocalizedMenu(locale) {
  const messages = require(`./i18n/${locale}/electron.json`);
  return Menu.buildFromTemplate([
    {
      label: messages['menu.file'],
      submenu: [
        { label: messages['menu.file.newDocument'], accelerator: 'CmdOrCtrl+N' },
        { label: messages['menu.file.quit'], role: 'quit' },
      ]
    },
    // ...
  ]);
}

app.on('ready', () => {
  const locale = app.getLocale().split('-')[0] ?? 'en';
  Menu.setApplicationMenu(buildLocalizedMenu(locale));
});
```

```
Fichiers additionnels pour Desktop :
  i18n/{locale}/electron.json  ← menus natifs uniquement
  i18n/{locale}/notifications.json ← push notifications système
```

---

## 11. Mobile — Capacitor ou Flutter (Phase Future)

### Option A — Capacitor (Angular partagé, recommandé si l'app reste Angular)

```
Avantage : 100% du code Angular + i18n partagé avec le web
Architecture : Angular 18 → Capacitor → iOS/Android WebView

Points spécifiques :
- @ngx-translate fonctionne sans modification dans Capacitor
- Détection locale : window.navigator.language (identique au web)
- OU utiliser @capacitor/device → Device.getLanguageCode()
- Polices CJK : à inclure dans l'APK/IPA (pas de Google Fonts CDN sur mobile)
  → Utiliser @capacitor/filesystem pour charger les polices depuis les assets
- Notifications push (FCM/APNs) : template de message localisé côté backend
```

```typescript
// Dans I18nService.init() pour Capacitor :
import { Device } from '@capacitor/device';

async initMobile(): Promise<void> {
  const info = await Device.getLanguageCode();
  const locale = info.value.split('-')[0];
  this.setLocale(this.resolveLocale(locale) ?? 'en');
}
```

### Option B — Flutter (si app native distincte)

```dart
// pubspec.yaml
dependencies:
  flutter_localizations:
    sdk: flutter
  intl: ^0.19.0

// Générer les fichiers ARB depuis les JSON Crowdin :
// Script de conversion : scripts/json-to-arb.mjs
// En sortie : lib/l10n/app_en.arb, app_fr.arb, app_es.arb, ...

// main.dart
MaterialApp(
  locale: _appLocale,
  supportedLocales: const [
    Locale('en'), Locale('fr'), Locale('es'), Locale('de'),
    Locale('pt', 'BR'), Locale('ar'), Locale('ja'), Locale('zh', 'CN'),
  ],
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
);
```

```
Partage de traductions Web ↔ Flutter :
  Source JSON (en/fr/...) → scripts/json-to-arb.mjs → ARB Flutter
  Crowdin supporte le format ARB nativement — un seul projet TMS pour les deux
```

---

## 12. Ordre d'Implémentation

### Sprint 0 — Fondations (1-2 jours)
1. Installer `@ngx-translate/core`, `@ngx-translate/http-loader`, `@ngx-translate/message-format`
2. Créer la structure `assets/i18n/en/*.json` avec les 9 namespaces
3. Configurer `app.config.ts` + `APP_INITIALIZER` + `I18nService`
4. Extraire toutes les chaînes hardcodées Angular → clés JSON
5. Remplacer dans les templates : `"Connexion"` → `{{ 'auth.login.submit' | translate }}`
6. Ajouter `{{ 'auth.login.submit' | translate }}` dans les composants
7. Créer `fr/` en copiant `en/` + traduction manuelle (c'est la langue actuelle)
8. Vérifier : passer de `en` à `fr` sans rechargement

### Sprint 1 — Backend (1 jour)
9. Créer la structure `i18n/messages*.properties`
10. Configurer `LocaleConfig` + `LocalValidatorFactoryBean`
11. Modifier `GlobalExceptionHandler` pour localiser les messages d'erreur
12. Tester : header `Accept-Language: de` → erreurs en allemand

### Sprint 2 — Langues P1 (1-2 semaines via TMS)
13. Configurer projet Crowdin + glossaire
14. Uploader `en/` comme source
15. MT DeepL → révision humaine pour EN, ES, DE, PT-BR
16. Configurer GitHub Action pour sync automatique
17. Ajouter le Language Switcher dans le header
18. Tests layout pour DE (le plus expansif)

### Sprint 3 — RTL (3-4 jours)
19. Audit CSS : remplacer `margin-left/right` par `margin-inline-*`
20. Configurer `tailwindcss-rtl`
21. Tester en arabe et hébreu : layout, formulaires, icônes
22. Polices Arabic/Hebrew via Google Fonts (chargement conditionnel)
23. Tests Playwright RTL automatisés

### Sprint 4 — Langues P2 + CJK (2-3 semaines via TMS)
24. IT, NL, PL, TR, RU via Crowdin
25. JA, ZH-CN, KO — attention aux polices et au wrapping de texte
26. Tests layout CJK (sans espaces entre caractères)
27. Pseudo-localisation pour détecter les textes oubliés

### Sprint 5 — Optimisation & Qualité (1 semaine)
28. Audit complet des clés manquantes (script de validation JSON)
29. Lazy loading par namespace dans les routes
30. Optimisation polices CJK (subset + preload conditionnel)
31. Tests automatisés multi-locale (Playwright)
32. Documentation traducteurs (Crowdin style guide)

### Sprint 6 — Desktop / Mobile (Phase ultérieure)
33. Electron : menus natifs localisés
34. Capacitor : `Device.getLanguageCode()` + polices embarquées
35. Script de conversion JSON→ARB si Flutter envisagé

---

## 13. Checklist Go-Live par Langue

```
Pour chaque nouvelle langue, cocher avant de l'activer en production :

□ Fichiers JSON 100% traduits et approuvés dans Crowdin
□ Backend messages.properties traduit
□ Templates email traduits
□ Tests layout validés (mobile + desktop)
□ Polices chargées correctement
□ RTL validé si applicable
□ hreflang ajouté dans index.html
□ Entrée ajoutée dans SUPPORTED_LOCALES du I18nService
□ Ajoutée dans la liste des locales Spring Boot (LocaleConfig)
□ Mention dans les changelogs et communication produit
```

---

## 14. Variables d'Environnement & Configuration

```bash
# Crowdin TMS
CROWDIN_PROJECT_ID=<id-projet>
CROWDIN_PERSONAL_TOKEN=<token>

# Feature flag i18n (optionnel — pour rollout progressif par locale)
I18N_ENABLED_LOCALES=en,fr,es,de   # Locales visibles dans le switcher
I18N_BETA_LOCALES=ja,zh-CN,ko      # Locales en bêta (hidden par défaut)
```

```typescript
// environment.ts
export const environment = {
  enabledLocales: ['en', 'fr', 'es', 'de', 'pt-BR'],
  betaLocales: ['it', 'nl', 'pl', 'tr', 'ru', 'ar', 'he', 'ja', 'zh-CN', 'ko'],
};
```

---

## 15. Références Techniques

| Sujet | Référence |
|-------|-----------|
| @ngx-translate | https://github.com/ngx-translate/core |
| @ngx-translate/message-format (ICU) | https://github.com/larscom/ngx-translate-message-format-compiler |
| Tailwind RTL plugin | https://github.com/20lives/tailwindcss-rtl |
| Crowdin GitHub Action | https://github.com/crowdin/github-action |
| Tolgee (self-hosted TMS) | https://tolgee.io |
| ICU Message Format | https://unicode-org.github.io/icu/userguide/format_parse/messages/ |
| Intl API MDN | https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl |
| Google Fonts CJK subsetting | https://fonts.google.com/noto |
| Spring Boot i18n | https://docs.spring.io/spring-boot/reference/features/internationalization.html |
| Capacitor Device API | https://capacitorjs.com/docs/apis/device |
| Flutter Localizations | https://docs.flutter.dev/accessibility-and-internationalization/internationalization |
| CLDR Plural Rules | https://cldr.unicode.org/index/cldr-spec/plural-rules |
| hreflang guide | https://developers.google.com/search/docs/specialty/international/localization-vs-internationalization |
