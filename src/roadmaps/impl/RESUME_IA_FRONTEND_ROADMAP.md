# 🤖 Résumé IA — Roadmap Frontend (Angular)

> **Contexte** : Le composant `SummaryComponent` existant (`features/summary/summary.component.ts`)
> est une base fonctionnelle mais très minimale : upload, spinner, affichage Markdown brut.
> Ce roadmap le transforme en outil IA **professionnel et premium** avec choix du mode de résumé,
> focus métier, longueur cible, sections structurées, badge moteur IA, export multi-format
> et historique des résumés passés.
>
> **Périmètre** : Frontend **uniquement** (`kovixel-ui`).
> Les endpoints backend (`/api/v1/documents/summarize`) existent déjà.
> La connexion back → front sera finalisée dans un roadmap dédié.
>
> **Stack** : Angular 18+, standalone components, `ChangeDetectionStrategy.OnPush`,
> Signals (`signal`, `computed`), Tailwind CSS + design tokens CSS `var(--)`,
> `ngx-markdown`, composants partagés `kov-*`.
>
> **Instructions** : Exécuter les prompts **dans l'ordre**.
> Chaque prompt cite exactement les fichiers à créer ou modifier.
> Ne pas sauter d'étape — chacune est un prérequis de la suivante.

---

## Vue d'ensemble de l'architecture cible

```
Route : /tools/summary
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  SummaryShellComponent  (conteneur principal, layout)           │
│  features/summary/summary.component.ts  ← refonte complète     │
└────────────────────────┬────────────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
  ┌──────────────┐ ┌───────────┐ ┌────────────────────┐
  │  Step 1      │ │  Step 2   │ │  Step 3 — Résultat │
  │  Upload +    │ │ Génération│ │  sections + export │
  │  Options     │ │ + polling │ │  + historique      │
  └──────────────┘ └───────────┘ └────────────────────┘

Modèle enrichi (summary.model.ts) :
  SummaryOptions   → paramètres envoyés au backend
  SummaryResponse  → réponse enrichie (sections, engine, tokens, duration)
  SummaryHistory   → liste de résumés passés (localStorage)

Service enrichi (summary.service.ts) :
  summarize(file, options) → Observable<SummaryResult>
  getSummary(documentId)   → Observable<SummaryResponse>
  getHistory()             → SummaryHistoryEntry[]   (localStorage)
  saveToHistory(entry)     → void
  clearHistory()           → void
```

---

## Comparatif : avant / après

| Dimension              | Avant (existant)              | Après (ce roadmap)                         |
|------------------------|-------------------------------|---------------------------------------------|
| Mode de résumé         | Unique (fixe côté backend)    | 5 modes : Standard, Exécutif, Bullet, Détaillé, Personnalisé |
| Longueur               | Non configurable              | 3 cibles : Court (150), Moyen (400), Long (800 mots) |
| Focus métier           | Aucun                         | 6 focus : Général, Financier, Juridique, Médical, Technique, Libre |
| Langue de sortie       | Détectée auto (non affichée)  | Choisie par l'utilisateur (FR, EN, ES, DE, auto) |
| Affichage résultat     | Markdown brut                 | Sections structurées + onglets + metadata rich |
| Badge moteur IA        | Absent                        | Claude ☁️ / Gemini ☁️ / Ollama 🔒 local    |
| Export                 | Copier + .txt                 | Copier, .txt, .md, imprimer                 |
| Historique             | Absent                        | 10 derniers résumés (localStorage)          |
| UX états               | 5 états basiques              | 7 états avec transitions et skeleton        |
| Métriques affichées    | Aucune                        | Durée, tokens, mots, langue, moteur         |

---

## PROMPT 1 — Modèle de données enrichi

**Fichiers à modifier :**
- `src/app/core/models/summary.model.ts`

```
Remplace entièrement summary.model.ts par le contenu suivant.

─────────────────────────────────────────────────────────────────────
// Modes de résumé disponibles
export type SummaryMode =
  | 'standard'      // Résumé équilibré — points clés + contexte  (défaut FREE)
  | 'executive'     // 5 lignes max, orienté décision             (PRO)
  | 'bullets'       // Liste de bullet points uniquement           (FREE)
  | 'detailed'      // Analyse approfondie multi-sections          (PRO)
  | 'custom';       // Instruction libre de l'utilisateur          (PRO)

// Focus métier de l'analyse
export type SummaryFocus =
  | 'general'       // Tout le document                           (défaut)
  | 'financial'     // Chiffres, finances, résultats
  | 'legal'         // Clauses, obligations, risques juridiques
  | 'medical'       // Diagnostic, traitement, conclusions
  | 'technical'     // Architecture, spécifications, méthodes
  | 'custom';       // Instruction libre

// Longueur cible du résumé
export type SummaryLength = 'short' | 'medium' | 'long';
// short  ≈ 150 mots · medium ≈ 400 mots · long ≈ 800 mots

// Langue de sortie
export type SummaryOutputLanguage = 'auto' | 'fr' | 'en' | 'es' | 'de' | 'it' | 'pt';

// Paramètres envoyés au backend lors de la génération
export interface SummaryOptions {
  mode:            SummaryMode;
  focus:           SummaryFocus;
  length:          SummaryLength;
  outputLanguage:  SummaryOutputLanguage;
  customInstruction?: string;   // si mode='custom' ou focus='custom'
}

// Valeurs par défaut (FREE)
export const DEFAULT_SUMMARY_OPTIONS: SummaryOptions = {
  mode:           'standard',
  focus:          'general',
  length:         'medium',
  outputLanguage: 'auto',
};

// Une section structurée du résumé
export interface SummarySection {
  title:   string;     // ex : "Résumé exécutif", "Points clés", "Thèmes"
  content: string;     // contenu Markdown de la section
  icon?:   string;     // emoji ou nom d'icône Lucide
}

// Réponse complète du backend (enrichie)
export interface SummaryResponse {
  summaryId:    string;
  documentId:   string;
  fileName:     string;
  fileSize:     number;
  content:      string;           // contenu Markdown complet (fallback si pas de sections)
  sections?:    SummarySection[]; // sections structurées parsées (optionnel côté front)
  language:     string;           // langue détectée du document (ISO 639-1 : "fr", "en"…)
  model:        string;           // modèle utilisé : "claude-sonnet-4-5", "qwen3:7b"…
  engine?:      'claude' | 'gemini' | 'ollama';  // provider
  tokensUsed?:  number;
  durationMs?:  number;
  wordCount?:   number;
  cached:       boolean;
  createdAt:    string;           // ISO 8601
  // Options utilisées pour générer ce résumé
  mode?:        SummaryMode;
  focus?:       SummaryFocus;
  length?:      SummaryLength;
}

// Réponse async (job)
export interface SummaryJobResponse {
  jobId: string;
}

export type SummaryResult = SummaryResponse | SummaryJobResponse;

export function isSummaryJob(r: SummaryResult): r is SummaryJobResponse {
  return 'jobId' in r;
}

// Entrée d'historique stockée en localStorage
export interface SummaryHistoryEntry {
  summaryId:   string;
  documentId:  string;
  fileName:    string;
  fileSize:    number;
  language:    string;
  mode:        SummaryMode;
  wordCount:   number;
  engine?:     string;
  createdAt:   string;
  preview:     string;   // 120 premiers caractères du contenu
}
─────────────────────────────────────────────────────────────────────

Points importants :
- Tous les types sont exportés individuellement (pas de namespace).
- DEFAULT_SUMMARY_OPTIONS est exporté pour être réutilisé dans le composant.
- SummarySection permet d'afficher le résumé en onglets au lieu d'un bloc Markdown unique.
- engine est optionnel : si le backend ne l'expose pas encore, le badge n'est pas affiché.
- SummaryHistoryEntry ne stocke jamais le content complet (poids localStorage).
```

---

## PROMPT 2 — Service enrichi

**Fichiers à modifier :**
- `src/app/core/services/summary.service.ts`

```
Remplace entièrement summary.service.ts par le contenu suivant.

─────────────────────────────────────────────────────────────────────
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';
import { tap } from 'rxjs/operators';
import { environment } from '../../../environments/environment';
import {
  SummaryResponse,
  SummaryResult,
  SummaryOptions,
  SummaryHistoryEntry,
  DEFAULT_SUMMARY_OPTIONS,
  isSummaryJob,
} from '../models/summary.model';

const HISTORY_KEY     = 'kov_summary_history';
const HISTORY_MAX     = 10;

@Injectable({ providedIn: 'root' })
export class SummaryService {
  private readonly http = inject(HttpClient);
  private readonly base = `${environment.apiUrl}/v1/documents`;

  /**
   * Upload un fichier PDF et génère son résumé.
   * Les options (mode, focus, length, outputLanguage) sont passées
   * en query params ou formData selon l'implémentation backend.
   * Pour l'instant on les passe en formData pour rester compatible
   * avec l'endpoint existant qui ne les lit pas encore (forward-compatible).
   *
   * Retourne SummaryResponse (sync) ou { jobId } (async).
   */
  summarize(file: File, options: SummaryOptions = DEFAULT_SUMMARY_OPTIONS): Observable<SummaryResult> {
    const fd = new FormData();
    fd.append('file', file, file.name);
    // Forward-compatible : ajout des options dès maintenant
    fd.append('mode',            options.mode);
    fd.append('focus',           options.focus);
    fd.append('length',          options.length);
    fd.append('outputLanguage',  options.outputLanguage);
    if (options.customInstruction) {
      fd.append('customInstruction', options.customInstruction);
    }
    return this.http.post<SummaryResult>(`${this.base}/summarize`, fd).pipe(
      tap((res) => {
        if (!isSummaryJob(res)) {
          this.saveToHistory(res as SummaryResponse, options);
        }
      }),
    );
  }

  getSummary(documentId: string): Observable<SummaryResponse> {
    return this.http.get<SummaryResponse>(`${this.base}/${documentId}/summary`);
  }

  // ── Historique localStorage ────────────────────────────────────────────────

  getHistory(): SummaryHistoryEntry[] {
    try {
      const raw = localStorage.getItem(HISTORY_KEY);
      return raw ? (JSON.parse(raw) as SummaryHistoryEntry[]) : [];
    } catch {
      return [];
    }
  }

  saveToHistory(res: SummaryResponse, options: SummaryOptions): void {
    try {
      const history  = this.getHistory();
      const entry: SummaryHistoryEntry = {
        summaryId:  res.summaryId,
        documentId: res.documentId,
        fileName:   res.fileName ?? '',
        fileSize:   res.fileSize ?? 0,
        language:   res.language ?? 'unknown',
        mode:       options.mode,
        wordCount:  this.countWords(res.content),
        engine:     res.engine,
        createdAt:  res.createdAt ?? new Date().toISOString(),
        preview:    (res.content ?? '').slice(0, 120).replace(/#+\s*/g, '').trim(),
      };
      // Dé-duplication par summaryId
      const filtered = history.filter((h) => h.summaryId !== entry.summaryId);
      // Plus récent en premier, max HISTORY_MAX entrées
      localStorage.setItem(HISTORY_KEY, JSON.stringify([entry, ...filtered].slice(0, HISTORY_MAX)));
    } catch {
      // localStorage peut être désactivé (mode privé, quota)
    }
  }

  clearHistory(): void {
    localStorage.removeItem(HISTORY_KEY);
  }

  removeFromHistory(summaryId: string): void {
    const filtered = this.getHistory().filter((h) => h.summaryId !== summaryId);
    localStorage.setItem(HISTORY_KEY, JSON.stringify(filtered));
  }

  private countWords(text: string): number {
    return (text ?? '').trim().split(/\s+/).filter(Boolean).length;
  }
}
─────────────────────────────────────────────────────────────────────

Vérifications :
- tap() enregistre dans l'historique uniquement pour les réponses synchrones.
- Les options sont incluses en FormData dès maintenant (forward-compatible).
- getHistory() ne lève jamais d'exception (try/catch).
- Les méthodes saveToHistory, clearHistory, removeFromHistory sont publiques
  pour être appelées depuis le composant.
```

---

## PROMPT 3 — Refonte du composant — Squelette, signaux & types

**Fichiers à modifier :**
- `src/app/features/summary/summary.component.ts`

```
Remplace la déclaration du composant (class + signaux + types internes + imports)
en gardant le même sélecteur 'kov-summary' et le même fichier.
NE PAS encore écrire le template — c'est l'objet des PROMPT 4 à 6.
Écrire uniquement la classe TypeScript avec tous les signaux, computed et méthodes.

─────────────────────────────────────────────────────────────────────
TYPES INTERNES (en tête de fichier, avant @Component)

type Step = 'upload' | 'options' | 'generating' | 'polling' | 'result' | 'error';

// Mode d'affichage du résultat (onglets)
type ResultTab = 'full' | 'sections' | 'metadata';

const LANG_FLAGS: Record<string, string> = {
  fr: '🇫🇷', en: '🇬🇧', es: '🇪🇸', de: '🇩🇪', it: '🇮🇹', pt: '🇵🇹', auto: '🌐',
};

const ENGINE_LABELS: Record<string, { label: string; icon: string; badge: string }> = {
  claude:  { label: 'Claude',  icon: '☁️', badge: 'bg-violet-500/20 text-violet-300 border-violet-500/30' },
  gemini:  { label: 'Gemini',  icon: '☁️', badge: 'bg-blue-500/20 text-blue-300 border-blue-500/30'     },
  ollama:  { label: 'Local 🔒', icon: '🔒', badge: 'bg-green-500/20 text-green-300 border-green-500/30'  },
};

const MODE_INFO: Record<SummaryMode, { label: string; desc: string; icon: string; isPro: boolean }> = {
  standard:  { label: 'Standard',    desc: 'Points clés équilibrés',       icon: '📄', isPro: false },
  bullets:   { label: 'Bullet Points',desc: 'Liste concise d\'actions',    icon: '🔵', isPro: false },
  executive: { label: 'Exécutif',     desc: 'Décision en 5 lignes max',    icon: '⚡', isPro: true  },
  detailed:  { label: 'Détaillé',     desc: 'Analyse approfondie',         icon: '🔍', isPro: true  },
  custom:    { label: 'Personnalisé', desc: 'Instruction libre',            icon: '✏️', isPro: true  },
};

const FOCUS_INFO: Record<SummaryFocus, { label: string; icon: string }> = {
  general:   { label: 'Général',     icon: '📋' },
  financial: { label: 'Financier',   icon: '💰' },
  legal:     { label: 'Juridique',   icon: '⚖️' },
  medical:   { label: 'Médical',     icon: '🏥' },
  technical: { label: 'Technique',   icon: '🔧' },
  custom:    { label: 'Personnalisé',icon: '✏️' },
};

─────────────────────────────────────────────────────────────────────
IMPORTS du composant

import {
  Component, ChangeDetectionStrategy, inject,
  signal, computed, PLATFORM_ID,
} from '@angular/core';
import { RouterLink }              from '@angular/router';
import { NgClass, DatePipe, isPlatformBrowser } from '@angular/common';
import { FormsModule }             from '@angular/forms';
import { MarkdownModule }          from 'ngx-markdown';
import { SummaryService }          from '../../core/services/summary.service';
import {
  SummaryResponse, SummaryOptions, SummaryMode, SummaryFocus,
  SummaryLength, SummaryOutputLanguage, SummaryHistoryEntry,
  DEFAULT_SUMMARY_OPTIONS, isSummaryJob,
} from '../../core/models/summary.model';
import { CardComponent }           from '../../shared/components/card/card.component';
import { SpinnerComponent }        from '../../shared/components/spinner/spinner.component';
import { FileDropzoneComponent }   from '../../shared/components/file-dropzone/file-dropzone.component';
import { JobProgressComponent }    from '../../shared/components/job-progress/job-progress.component';
import { FileSizePipe }            from '../../shared/pipes/file-size.pipe';

─────────────────────────────────────────────────────────────────────
CLASSE DU COMPOSANT

export class SummaryComponent {
  private readonly summaryService = inject(SummaryService);
  private readonly platformId     = inject(PLATFORM_ID);

  // ── État principal ───────────────────────────────────────────────────────
  readonly step         = signal<Step>('upload');
  readonly selectedFile = signal<File | null>(null);
  readonly summary      = signal<SummaryResponse | null>(null);
  readonly pollingJobId = signal<string | null>(null);
  readonly errorMsg     = signal('');

  // ── Options de génération ────────────────────────────────────────────────
  readonly selectedMode   = signal<SummaryMode>('standard');
  readonly selectedFocus  = signal<SummaryFocus>('general');
  readonly selectedLength = signal<SummaryLength>('medium');
  readonly selectedLang   = signal<SummaryOutputLanguage>('auto');
  readonly customInstruction = signal('');
  readonly showCustomInput   = computed(() =>
    this.selectedMode() === 'custom' || this.selectedFocus() === 'custom'
  );

  // ── Résultat ─────────────────────────────────────────────────────────────
  readonly activeTab   = signal<ResultTab>('full');
  readonly copied      = signal(false);
  readonly showHistory = signal(false);
  readonly history     = signal<SummaryHistoryEntry[]>([]);

  // ── Computed helpers ─────────────────────────────────────────────────────
  readonly wordCount = computed(() =>
    (this.summary()?.content ?? '').trim().split(/\s+/).filter(Boolean).length
  );
  readonly engineInfo = computed(() => {
    const e = this.summary()?.engine;
    return e ? ENGINE_LABELS[e] : null;
  });
  readonly hasSections = computed(() =>
    (this.summary()?.sections ?? []).length > 0
  );
  readonly currentOptions = computed<SummaryOptions>(() => ({
    mode:              this.selectedMode(),
    focus:             this.selectedFocus(),
    length:            this.selectedLength(),
    outputLanguage:    this.selectedLang(),
    customInstruction: this.customInstruction() || undefined,
  }));

  // ── Step list ────────────────────────────────────────────────────────────
  readonly stepList = [
    { key: 'upload'     as Step, label: 'Document' },
    { key: 'options'    as Step, label: 'Options' },
    { key: 'generating' as Step, label: 'Génération' },
    { key: 'result'     as Step, label: 'Résultat' },
  ];
  currentStepIndex(): number {
    const map: Record<Step, number> = {
      upload: 0, options: 1, generating: 2, polling: 2, result: 3, error: 3,
    };
    return map[this.step()] ?? 0;
  }
  stepIndex(key: Step): number {
    return this.stepList.findIndex(s => s.key === key);
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  onFileSelected(files: File[]): void {
    if (files.length > 0) {
      this.selectedFile.set(files[0]);
      // Auto-avance vers les options après sélection
      this.step.set('options');
    }
  }

  generate(): void {
    const file = this.selectedFile();
    if (!file) return;
    this.step.set('generating');
    this.summaryService.summarize(file, this.currentOptions()).subscribe({
      next: (res) => {
        if (isSummaryJob(res)) {
          this.pollingJobId.set(res.jobId);
          this.step.set('polling');
        } else {
          this.summary.set(res as SummaryResponse);
          this.step.set('result');
          this.refreshHistory();
        }
      },
      error: (err) => {
        this.errorMsg.set(err?.error?.message ?? 'Impossible de générer le résumé.');
        this.step.set('error');
      },
    });
  }

  onJobCompleted(job: unknown): void {
    const result = (job as { result?: SummaryResponse }).result;
    if (result) {
      this.summary.set(result);
      this.step.set('result');
      this.refreshHistory();
    }
  }

  onJobFailed(msg: string): void {
    this.errorMsg.set(msg);
    this.step.set('error');
  }

  async copyToClipboard(): Promise<void> {
    if (!isPlatformBrowser(this.platformId)) return;
    const content = this.summary()?.content ?? '';
    await navigator.clipboard.writeText(content);
    this.copied.set(true);
    setTimeout(() => this.copied.set(false), 2000);
  }

  downloadAs(format: 'txt' | 'md'): void {
    if (!isPlatformBrowser(this.platformId)) return;
    const content  = this.summary()?.content ?? '';
    const mime     = format === 'md' ? 'text/markdown;charset=utf-8' : 'text/plain;charset=utf-8';
    const blob     = new Blob([content], { type: mime });
    const url      = URL.createObjectURL(blob);
    const a        = document.createElement('a');
    const base     = this.summary()?.fileName?.replace(/\.pdf$/i, '') ?? 'resume';
    a.href         = url;
    a.download     = `${base}-resume.${format}`;
    a.click();
    URL.revokeObjectURL(url);
  }

  print(): void {
    if (!isPlatformBrowser(this.platformId)) return;
    window.print();
  }

  reset(): void {
    this.step.set('upload');
    this.selectedFile.set(null);
    this.summary.set(null);
    this.pollingJobId.set(null);
    this.errorMsg.set('');
    this.activeTab.set('full');
    // On conserve les options sélectionnées pour le prochain document
  }

  refreshHistory(): void {
    this.history.set(this.summaryService.getHistory());
  }

  removeHistory(summaryId: string): void {
    this.summaryService.removeFromHistory(summaryId);
    this.refreshHistory();
  }

  clearHistory(): void {
    this.summaryService.clearHistory();
    this.history.set([]);
  }

  toggleHistory(): void {
    if (!this.showHistory()) this.refreshHistory();
    this.showHistory.update(v => !v);
  }

  langFlag(lang: string): string {
    return LANG_FLAGS[lang?.toLowerCase()] ?? '🌐';
  }
  modeInfo(mode: SummaryMode) { return MODE_INFO[mode]; }
  focusInfo(focus: SummaryFocus) { return FOCUS_INFO[focus]; }
}
─────────────────────────────────────────────────────────────────────

Décorations Angular :
  @Component({
    selector: 'kov-summary',
    standalone: true,
    changeDetection: ChangeDetectionStrategy.OnPush,
    imports: [
      NgClass, RouterLink, DatePipe, FormsModule,
      MarkdownModule, CardComponent, SpinnerComponent,
      FileDropzoneComponent, JobProgressComponent, FileSizePipe,
    ],
    template: `...`,  // rempli aux PROMPT 4, 5 et 6
  })

IMPORTANT : après ce prompt, le composant compile mais le template est vide (à écrire).
Vérifier avec ng build --configuration=development que zéro erreur TypeScript.
```

---

## PROMPT 4 — Template : Step 1 Upload + Step 2 Options

**Fichiers à modifier :**
- `src/app/features/summary/summary.component.ts` (section `template`)

```
Ajoute le template Angular pour les deux premières étapes.
Le template global est un div racine avec 3 zones :
  A) En-tête + indicateur de steps
  B) @switch (step()) avec chaque étape
  C) Panneau historique (slide-in conditionnel)

─────────────────────────────────────────────────────────────────────
STRUCTURE GLOBALE DU TEMPLATE

<div class="p-4 sm:p-6 max-w-3xl mx-auto space-y-5 min-h-full">

  <!-- ══ EN-TÊTE ═══════════════════════════════════════════════ -->
  <div class="flex items-start justify-between gap-4">
    <div>
      <h1 class="text-xl sm:text-2xl font-bold tracking-tight"
          style="color:var(--text-primary)">
        ✨ Résumé IA
      </h1>
      <p class="text-sm mt-0.5 leading-relaxed" style="color:var(--text-muted)">
        Générez un résumé intelligent et structuré de vos documents PDF.
      </p>
    </div>
    <!-- Bouton Historique (visible uniquement si step=result ou depuis upload) -->
    @if (step() !== 'generating' && step() !== 'polling') {
      <button
        class="flex items-center gap-1.5 rounded-xl px-3 py-1.5 text-xs font-medium transition border"
        [style]="showHistory()
          ? 'background:var(--color-primary-subtle);color:var(--color-primary-light);border-color:var(--border-hover)'
          : 'background:var(--bg-elevated);color:var(--text-muted);border-color:var(--border)'"
        (click)="toggleHistory()">
        🕐 Historique
        @if (history().length > 0) {
          <span class="rounded-full px-1.5 py-0.5 text-[10px] font-bold"
                style="background:var(--color-primary);color:white">
            {{ history().length }}
          </span>
        }
      </button>
    }
  </div>

  <!-- ══ STEPPER ════════════════════════════════════════════════ -->
  <div class="flex items-center gap-2 sm:gap-3">
    @for (s of stepList; track s.key; let i = $index) {
      <div class="flex items-center gap-1.5">
        <div class="w-6 h-6 sm:w-7 sm:h-7 rounded-full flex items-center justify-center text-xs font-bold transition-all duration-300"
             [style.background]="stepIndex(s.key) < currentStepIndex()
               ? 'var(--color-primary)'
               : stepIndex(s.key) === currentStepIndex()
                 ? 'var(--color-primary-subtle)'
                 : 'var(--bg-elevated)'"
             [style.color]="stepIndex(s.key) < currentStepIndex()
               ? 'white'
               : stepIndex(s.key) === currentStepIndex()
                 ? 'var(--color-primary-light)'
                 : 'var(--text-muted)'"
             [style.box-shadow]="stepIndex(s.key) === currentStepIndex()
               ? '0 0 0 3px var(--color-primary-subtle)' : 'none'">
          @if (stepIndex(s.key) < currentStepIndex()) { ✓ } @else { {{ i + 1 }} }
        </div>
        <span class="text-xs hidden sm:block transition-colors"
              [style.color]="stepIndex(s.key) === currentStepIndex()
                ? 'var(--color-primary-light)'
                : stepIndex(s.key) < currentStepIndex()
                  ? 'var(--text-secondary)'
                  : 'var(--text-muted)'"
              [style.font-weight]="stepIndex(s.key) === currentStepIndex() ? '600' : '400'">
          {{ s.label }}
        </span>
      </div>
      @if (i < stepList.length - 1) {
        <div class="flex-1 h-px max-w-[32px] sm:max-w-[48px] transition-all duration-500"
             [style.background]="stepIndex(s.key) < currentStepIndex()
               ? 'var(--color-primary)' : 'var(--border)'">
        </div>
      }
    }
  </div>

  <!-- ══ CONTENU PRINCIPAL (par step) ══════════════════════════ -->
  @switch (step()) {

    <!-- ─── STEP 1 : UPLOAD ─────────────────────────────────── -->
    @case ('upload') {
      <kov-card padding="lg">
        <div class="space-y-4">
          <div>
            <h2 class="text-base font-semibold mb-1" style="color:var(--text-primary)">
              📂 Choisissez votre document
            </h2>
            <p class="text-xs" style="color:var(--text-muted)">
              PDF uniquement · max 20 MB · Toutes langues supportées
            </p>
          </div>
          <kov-file-dropzone
            accept=".pdf"
            [multiple]="false"
            [maxSizeMb]="20"
            label="Glissez votre PDF ici ou cliquez pour parcourir"
            (filesSelected)="onFileSelected($event)"
          />
        </div>
      </kov-card>

      <!-- Aperçu rapide du fichier sélectionné (si retour en arrière) -->
      @if (selectedFile()) {
        <div class="flex items-center justify-between p-3 rounded-xl border"
             style="background:var(--bg-elevated);border-color:var(--border)">
          <div class="flex items-center gap-2.5 min-w-0">
            <span class="text-lg shrink-0">📄</span>
            <div class="min-w-0">
              <p class="text-sm font-medium truncate" style="color:var(--text-primary)">
                {{ selectedFile()!.name }}
              </p>
              <p class="text-xs" style="color:var(--text-muted)">
                {{ selectedFile()!.size | fileSize }}
              </p>
            </div>
          </div>
          <button class="btn-primary text-sm shrink-0 ml-3" (click)="step.set('options')">
            Continuer →
          </button>
        </div>
      }
    }

    <!-- ─── STEP 2 : OPTIONS ─────────────────────────────────── -->
    @case ('options') {
      <kov-card padding="lg">
        <div class="space-y-5">
          <div>
            <h2 class="text-base font-semibold mb-0.5" style="color:var(--text-primary)">
              ⚙️ Paramètres du résumé
            </h2>
            <p class="text-xs" style="color:var(--text-muted)">
              Personnalisez le résumé selon vos besoins.
            </p>
          </div>

          <!-- Fichier sélectionné (rappel) -->
          <div class="flex items-center gap-2 p-2.5 rounded-lg border"
               style="background:var(--bg-surface);border-color:var(--border-subtle)">
            <span>📄</span>
            <span class="text-sm truncate flex-1" style="color:var(--text-secondary)">
              {{ selectedFile()?.name }}
            </span>
            <button class="text-xs underline shrink-0"
                    style="color:var(--text-muted)"
                    (click)="step.set('upload')">
              Changer
            </button>
          </div>

          <!-- ── MODE DE RÉSUMÉ ── -->
          <div>
            <label class="block text-xs font-semibold mb-2 uppercase tracking-wide"
                   style="color:var(--text-muted)">Mode de résumé</label>
            <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
              @for (entry of modeEntries; track entry.key) {
                <button
                  class="relative flex flex-col gap-1 rounded-xl p-3 text-left border transition-all duration-200"
                  [style]="selectedMode() === entry.key
                    ? 'background:var(--color-primary-subtle);border-color:var(--color-primary);color:var(--color-primary-light)'
                    : 'background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)'"
                  (click)="selectedMode.set(entry.key)">
                  <!-- Badge PRO -->
                  @if (entry.value.isPro) {
                    <span class="absolute top-1.5 right-1.5 text-[9px] font-bold px-1.5 py-0.5 rounded-full"
                          style="background:var(--color-primary);color:white;opacity:0.9">PRO</span>
                  }
                  <span class="text-base">{{ entry.value.icon }}</span>
                  <span class="text-xs font-semibold">{{ entry.value.label }}</span>
                  <span class="text-[10px] leading-tight" style="color:var(--text-muted)">
                    {{ entry.value.desc }}
                  </span>
                </button>
              }
            </div>
          </div>

          <!-- ── FOCUS MÉTIER ── -->
          <div>
            <label class="block text-xs font-semibold mb-2 uppercase tracking-wide"
                   style="color:var(--text-muted)">Focus métier</label>
            <div class="flex flex-wrap gap-2">
              @for (entry of focusEntries; track entry.key) {
                <button
                  class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium border transition-all duration-150"
                  [style]="selectedFocus() === entry.key
                    ? 'background:var(--color-primary-subtle);border-color:var(--color-primary);color:var(--color-primary-light)'
                    : 'background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)'"
                  (click)="selectedFocus.set(entry.key)">
                  <span>{{ entry.value.icon }}</span>
                  {{ entry.value.label }}
                </button>
              }
            </div>
          </div>

          <!-- ── LONGUEUR ── -->
          <div>
            <label class="block text-xs font-semibold mb-2 uppercase tracking-wide"
                   style="color:var(--text-muted)">Longueur cible</label>
            <div class="flex gap-2">
              @for (opt of lengthOptions; track opt.key) {
                <button
                  class="flex-1 rounded-lg py-2 text-xs font-medium border transition-all duration-150 text-center"
                  [style]="selectedLength() === opt.key
                    ? 'background:var(--color-primary-subtle);border-color:var(--color-primary);color:var(--color-primary-light)'
                    : 'background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)'"
                  (click)="selectedLength.set(opt.key)">
                  <span class="block font-bold">{{ opt.label }}</span>
                  <span class="block text-[10px]" style="color:var(--text-muted)">{{ opt.desc }}</span>
                </button>
              }
            </div>
          </div>

          <!-- ── LANGUE DE SORTIE ── -->
          <div>
            <label class="block text-xs font-semibold mb-2 uppercase tracking-wide"
                   style="color:var(--text-muted)">Langue de sortie</label>
            <div class="flex flex-wrap gap-2">
              @for (lang of langOptions; track lang.key) {
                <button
                  class="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium border transition-all duration-150"
                  [style]="selectedLang() === lang.key
                    ? 'background:var(--color-primary-subtle);border-color:var(--color-primary);color:var(--color-primary-light)'
                    : 'background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)'"
                  (click)="selectedLang.set(lang.key)">
                  {{ lang.flag }} {{ lang.label }}
                </button>
              }
            </div>
          </div>

          <!-- ── INSTRUCTION PERSONNALISÉE (si mode=custom ou focus=custom) ── -->
          @if (showCustomInput()) {
            <div>
              <label class="block text-xs font-semibold mb-1.5 uppercase tracking-wide"
                     style="color:var(--text-muted)">Instruction personnalisée</label>
              <textarea
                class="w-full rounded-xl px-3 py-2 text-sm resize-none border focus:outline-none transition"
                style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-primary);min-height:72px"
                placeholder="Ex : Concentre-toi sur les clauses de résiliation et les pénalités…"
                maxlength="500"
                [(ngModel)]="customInstructionValue"
                (ngModelChange)="customInstruction.set($event)">
              </textarea>
              <p class="text-right text-[10px] mt-0.5" style="color:var(--text-muted)">
                {{ customInstruction().length }}/500
              </p>
            </div>
          }

        </div>
      </kov-card>

      <!-- Boutons de navigation -->
      <div class="flex items-center justify-between gap-3">
        <button
          class="rounded-xl px-4 py-2 text-sm border transition"
          style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-muted)"
          (click)="step.set('upload')">
          ← Retour
        </button>
        <button
          class="btn-primary flex items-center gap-2 text-sm"
          [disabled]="!selectedFile()"
          (click)="generate()">
          ✨ Générer le résumé
        </button>
      </div>
    }

  } <!-- fin @switch step 1 & 2 -->

</div>

─────────────────────────────────────────────────────────────────────

GETTERS supplémentaires à ajouter dans la classe (pour le template) :

  readonly modeEntries    = Object.entries(MODE_INFO)  as [SummaryMode,   typeof MODE_INFO[SummaryMode]][]; 
  readonly focusEntries   = Object.entries(FOCUS_INFO) as [SummaryFocus,  typeof FOCUS_INFO[SummaryFocus]][];
  readonly customInstructionValue = '';  // ngModel bridge (voir note)

  readonly lengthOptions: { key: SummaryLength; label: string; desc: string }[] = [
    { key: 'short',  label: 'Court',  desc: '~150 mots' },
    { key: 'medium', label: 'Moyen',  desc: '~400 mots' },
    { key: 'long',   label: 'Long',   desc: '~800 mots' },
  ];

  readonly langOptions: { key: SummaryOutputLanguage; flag: string; label: string }[] = [
    { key: 'auto', flag: '🌐', label: 'Auto'      },
    { key: 'fr',   flag: '🇫🇷', label: 'Français'  },
    { key: 'en',   flag: '🇬🇧', label: 'Anglais'   },
    { key: 'es',   flag: '🇪🇸', label: 'Espagnol'  },
    { key: 'de',   flag: '🇩🇪', label: 'Allemand'  },
  ];

Note sur ngModel : utiliser un getter/setter ou FormsModule avec
[(ngModel)]="customInstructionValue" qui appelle customInstruction.set(value).
Alternative : utiliser (input) event sans FormsModule pour rester puriste signaux.
```

---

## PROMPT 5 — Template : Step Génération + Step Résultat

**Fichiers à modifier :**
- `src/app/features/summary/summary.component.ts` (compléter le `@switch`)

```
Ajoute dans le @switch les cases 'generating', 'polling', 'result' et 'error'.

─────────────────────────────────────────────────────────────────────
CASE 'generating' — Spinner avec phases animées

@case ('generating') {
  <kov-card padding="lg">
    <div class="flex flex-col items-center gap-5 py-10 text-center">
      <div class="relative">
        <kov-spinner size="lg" color="primary" />
        <!-- Halo animé -->
        <div class="absolute inset-0 rounded-full animate-ping opacity-20"
             style="background:var(--color-primary)"></div>
      </div>
      <div>
        <p class="text-base font-semibold" style="color:var(--text-primary)">
          Génération en cours…
        </p>
        <p class="text-sm mt-1" style="color:var(--text-muted)">
          L'IA analyse votre document et construit le résumé.
        </p>
      </div>
      <!-- Phases séquentielles -->
      <div class="flex flex-col gap-2 w-full max-w-xs text-left">
        @for (phase of generatingPhases; track phase.label; let i = $index) {
          <div class="flex items-center gap-2.5 text-xs"
               style="color:var(--text-muted)">
            <span class="w-4 h-4 rounded-full flex items-center justify-center shrink-0"
                  style="background:var(--color-primary-subtle)">
              {{ phase.icon }}
            </span>
            {{ phase.label }}
          </div>
        }
      </div>
    </div>
  </kov-card>
}

─────────────────────────────────────────────────────────────────────
CASE 'polling' — Composant job-progress existant

@case ('polling') {
  @if (pollingJobId()) {
    <kov-card padding="lg">
      <kov-job-progress
        [jobId]="pollingJobId()!"
        (completed)="onJobCompleted($event)"
        (failed)="onJobFailed($event)"
      />
    </kov-card>
  }
}

─────────────────────────────────────────────────────────────────────
CASE 'result' — Résultat enrichi

@case ('result') {
  @if (summary()) {

    <!-- ─ Barre de métadonnées ──────────────────────────────── -->
    <div class="flex flex-wrap items-center gap-3 px-1">

      <!-- Langue détectée -->
      <span class="flex items-center gap-1 text-xs" style="color:var(--text-muted)">
        {{ langFlag(summary()!.language) }}
        <strong style="color:var(--text-secondary)">
          {{ summary()!.language?.toUpperCase() }}
        </strong>
      </span>

      <!-- Nombre de mots -->
      <span class="text-xs" style="color:var(--text-muted)">
        📝 ~{{ wordCount() }} mots
      </span>

      <!-- Durée si disponible -->
      @if (summary()!.durationMs) {
        <span class="text-xs" style="color:var(--text-muted)">
          ⚡ {{ (summary()!.durationMs! / 1000).toFixed(1) }}s
        </span>
      }

      <!-- Tokens si disponibles -->
      @if (summary()!.tokensUsed) {
        <span class="text-xs" style="color:var(--text-muted)">
          🔢 ~{{ summary()!.tokensUsed }} tokens
        </span>
      }

      <!-- Badge moteur IA -->
      @if (engineInfo()) {
        <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-semibold border"
              [class]="engineInfo()!.badge">
          {{ engineInfo()!.icon }} {{ engineInfo()!.label }}
        </span>
      }

      <!-- Badge "Depuis le cache" -->
      @if (summary()!.cached) {
        <span class="inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-semibold border"
              style="background:var(--success-light);color:var(--success-text);border-color:var(--success-border)">
          ⚡ Résultat depuis le cache
        </span>
      }

      <!-- Mode utilisé -->
      @if (summary()!.mode) {
        <span class="text-xs" style="color:var(--text-muted)">
          {{ modeInfo(summary()!.mode!)?.icon }}
          {{ modeInfo(summary()!.mode!)?.label }}
        </span>
      }

      <!-- Date -->
      <span class="text-xs ml-auto hidden sm:block" style="color:var(--text-muted)">
        {{ summary()!.createdAt | date:'d MMM yyyy à HH:mm' }}
      </span>
    </div>

    <!-- ─ Onglets (Full / Sections) si sections disponibles ─── -->
    @if (hasSections()) {
      <div class="flex gap-1 border-b" style="border-color:var(--border)">
        @for (tab of resultTabs; track tab.key) {
          <button
            class="px-3 py-2 text-xs font-medium border-b-2 transition-colors"
            [style.border-color]="activeTab() === tab.key ? 'var(--color-primary)' : 'transparent'"
            [style.color]="activeTab() === tab.key ? 'var(--color-primary-light)' : 'var(--text-muted)'"
            (click)="activeTab.set(tab.key)">
            {{ tab.label }}
          </button>
        }
      </div>
    }

    <!-- ─ Contenu selon onglet ────────────────────────────── -->
    <kov-card padding="lg">
      @if (!hasSections() || activeTab() === 'full') {
        <!-- Markdown complet -->
        <markdown
          class="prose prose-sm max-w-none leading-relaxed"
          style="color:var(--text-primary)"
          [data]="summary()!.content"
        />
      } @else if (activeTab() === 'sections' && hasSections()) {
        <!-- Sections structurées -->
        <div class="space-y-5">
          @for (section of summary()!.sections; track section.title) {
            <div class="space-y-2">
              <h3 class="flex items-center gap-2 text-sm font-semibold"
                  style="color:var(--color-primary-light)">
                @if (section.icon) { <span>{{ section.icon }}</span> }
                {{ section.title }}
              </h3>
              <markdown
                class="prose prose-sm max-w-none leading-relaxed"
                style="color:var(--text-primary)"
                [data]="section.content"
              />
            </div>
          }
        </div>
      }
    </kov-card>

    <!-- ─ Actions ─────────────────────────────────────────── -->
    <div class="flex flex-wrap gap-2">
      <!-- Copier -->
      <button
        class="inline-flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-medium border transition-all"
        [style]="copied()
          ? 'background:var(--success-light);border-color:var(--success-border);color:var(--success-text)'
          : 'background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)'"
        (click)="copyToClipboard()">
        {{ copied() ? '✅ Copié !' : '📋 Copier' }}
      </button>

      <!-- Télécharger .txt -->
      <button
        class="inline-flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-medium border transition"
        style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)"
        (click)="downloadAs('txt')">
        ⬇ .txt
      </button>

      <!-- Télécharger .md -->
      <button
        class="inline-flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-medium border transition"
        style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)"
        (click)="downloadAs('md')">
        ⬇ .md
      </button>

      <!-- Imprimer -->
      <button
        class="inline-flex items-center gap-1.5 rounded-xl px-3 py-2 text-xs font-medium border transition"
        style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-secondary)"
        (click)="print()">
        🖨 Imprimer
      </button>

      <!-- Poser une question (lien vers Q&A) -->
      <a [routerLink]="['/tools/qna']"
         [queryParams]="{ docId: summary()!.documentId }"
         class="btn-primary inline-flex items-center gap-1.5 text-xs ml-auto">
        💬 Poser une question
      </a>
    </div>

    <!-- Nouveau résumé -->
    <div class="text-center">
      <button
        class="text-xs underline transition"
        style="color:var(--text-muted)"
        (click)="reset()">
        ↺ Analyser un autre document
      </button>
    </div>

  } <!-- fin @if summary -->
}

─────────────────────────────────────────────────────────────────────
CASE 'error'

@case ('error') {
  <kov-card padding="md">
    <div class="flex items-start gap-3">
      <span class="text-2xl shrink-0">❌</span>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold" style="color:var(--color-error)">
          Erreur lors de la génération
        </p>
        <p class="text-xs mt-1 leading-relaxed" style="color:var(--text-muted)">
          {{ errorMsg() }}
        </p>
      </div>
    </div>
    <div class="flex gap-2 mt-4">
      <button class="btn-primary text-sm" (click)="generate()">
        🔄 Réessayer
      </button>
      <button
        class="rounded-xl px-3 py-2 text-xs border transition"
        style="background:var(--bg-elevated);border-color:var(--border);color:var(--text-muted)"
        (click)="reset()">
        Nouveau document
      </button>
    </div>
  </kov-card>
}

─────────────────────────────────────────────────────────────────────
GETTERS supplémentaires à ajouter dans la classe :

  readonly generatingPhases = [
    { icon: '📄', label: 'Extraction du texte…' },
    { icon: '🧠', label: 'Analyse sémantique…'  },
    { icon: '✍️',  label: 'Rédaction du résumé…' },
  ];

  readonly resultTabs = [
    { key: 'full'     as ResultTab, label: '📄 Résumé complet' },
    { key: 'sections' as ResultTab, label: '📑 Par sections'   },
  ];
```

---

## PROMPT 6 — Panneau Historique (slide-in)

**Fichiers à modifier :**
- `src/app/features/summary/summary.component.ts` (ajouter APRÈS le `@switch` dans le template)

```
Ajoute le panneau historique en bas du template principal (après le @switch).
Il est visible uniquement quand showHistory() = true.

─────────────────────────────────────────────────────────────────────

<!-- ══ PANNEAU HISTORIQUE ══════════════════════════════════════ -->
@if (showHistory()) {
  <div class="rounded-2xl border overflow-hidden"
       style="background:var(--bg-elevated);border-color:var(--border)">

    <!-- En-tête du panneau -->
    <div class="flex items-center justify-between px-4 py-3 border-b"
         style="border-color:var(--border)">
      <h3 class="text-sm font-semibold" style="color:var(--text-primary)">
        🕐 Résumés récents
      </h3>
      <div class="flex items-center gap-2">
        @if (history().length > 0) {
          <button
            class="text-[10px] underline"
            style="color:var(--text-muted)"
            (click)="clearHistory()">
            Tout effacer
          </button>
        }
        <button
          class="text-lg leading-none"
          style="color:var(--text-muted)"
          (click)="showHistory.set(false)">×
        </button>
      </div>
    </div>

    <!-- Liste -->
    @if (history().length === 0) {
      <div class="px-4 py-8 text-center text-xs" style="color:var(--text-muted)">
        Aucun résumé dans l'historique.
      </div>
    } @else {
      <ul class="divide-y" style="--tw-divide-opacity:1;border-color:var(--border-subtle)">
        @for (entry of history(); track entry.summaryId) {
          <li class="px-4 py-3 hover:bg-[var(--bg-card-hover)] transition-colors">
            <div class="flex items-start gap-3">
              <!-- Infos -->
              <div class="flex-1 min-w-0">
                <p class="text-xs font-medium truncate" style="color:var(--text-primary)">
                  {{ langFlag(entry.language) }} {{ entry.fileName || 'Document sans nom' }}
                </p>
                <p class="text-[10px] mt-0.5 line-clamp-2 leading-relaxed"
                   style="color:var(--text-muted)">
                  {{ entry.preview }}…
                </p>
                <div class="flex flex-wrap items-center gap-2 mt-1.5">
                  <!-- Mode badge -->
                  <span class="text-[9px] font-medium px-1.5 py-0.5 rounded-full border"
                        style="background:var(--color-primary-subtle);color:var(--color-primary-light);border-color:var(--border)">
                    {{ modeInfo(entry.mode)?.icon }} {{ modeInfo(entry.mode)?.label }}
                  </span>
                  <!-- Mots -->
                  <span class="text-[10px]" style="color:var(--text-muted)">
                    ~{{ entry.wordCount }} mots
                  </span>
                  <!-- Date -->
                  <span class="text-[10px]" style="color:var(--text-muted)">
                    {{ entry.createdAt | date:'d MMM HH:mm' }}
                  </span>
                </div>
              </div>
              <!-- Supprimer -->
              <button
                class="shrink-0 text-xs px-2 py-1 rounded-lg border transition"
                style="background:var(--bg-card);border-color:var(--border);color:var(--text-muted)"
                (click)="removeHistory(entry.summaryId)"
                title="Supprimer de l'historique">
                🗑
              </button>
            </div>
          </li>
        }
      </ul>
    }
  </div>
}

─────────────────────────────────────────────────────────────────────

Note : ngOnInit (ou afterViewInit) doit appeler refreshHistory() si step=result au
chargement (navigation directe vers /tools/summary?docId=...).
Ajouter dans ngOnInit :
  this.history.set(this.summaryService.getHistory());
```

---

## PROMPT 7 — Mise à jour tools-config.ts

**Fichiers à modifier :**
- `src/app/core/config/tools-config.ts`

```
Mets à jour l'entrée slug='summary' dans TOOLS_CONFIG avec les nouvelles valeurs.

Remplacer l'objet existant slug:'summary' par :

  {
    slug:            'summary',
    name:            'Résumé IA',
    description:     'Résumé intelligent et structuré — 5 modes, focus métier, multi-langue',
    longDescription: 'Notre IA (Claude / Gemini / Ollama) analyse votre PDF et génère un résumé '
                   + 'professionnel : Standard, Exécutif, Bullet Points, Détaillé ou Personnalisé. '
                   + 'Choisissez le focus (Général, Financier, Juridique, Médical, Technique), '
                   + 'la longueur cible (Court ~150, Moyen ~400, Long ~800 mots) et la langue de sortie. '
                   + 'Export en .txt ou .md, copie presse-papier, historique local.',
    category:        'ai',
    icon:            Sparkles,
    badge:           'POPULAR',
    badgeSecondary:  'NEW',
    estimatedTime:   '~15 secondes',
    isPro:           false,
    isAvailable:     true,
    backendEndpoint: '/api/v1/documents/summarize',
    keywords:        [
      'résumer', 'synthèse', 'summary', 'abstract', 'tldr', 'points clés',
      'llm', 'claude', 'gemini', 'ollama', 'analyse', 'executive', 'bullet',
      'juridique', 'financier', 'médical', 'technique', 'multilingue',
    ],
  },
```

---

## PROMPT 8 — Route dédiée (protection optionnelle)

**Fichiers à modifier :**
- `src/app/app.routes.ts`

```
La route /tools/summary est déjà déclarée et utilise un soft authGuard.
Aucun changement de route n'est nécessaire à cette étape.

Vérifier uniquement que la route est AVANT les routes génériques 'tools/:slug'
et 'tools/convert/:slug'. C'est déjà le cas dans le fichier existant.

En revanche, ajouter dans le data de la route tools/summary le champ
description (pour les meta SEO) :

  data: {
    title:       'Résumé IA',
    description: 'Générez un résumé structuré de votre PDF en quelques secondes.',
    guestFeature: 'summary',
  }

Aucune modification de chemin n'est requise.
```

---

## PROMPT 9 — Tests unitaires

**Fichiers à créer :**
- `src/app/features/summary/summary.component.spec.ts`
- `src/app/core/services/summary.service.spec.ts` (si inexistant)

```
Crée les tests unitaires du composant et du service avec Vitest (vitest.config.mts).

─────────────────────────────────────────────────────────────────────
SummaryComponent tests :

import { TestBed } from '@angular/core/testing';
import { SummaryComponent } from './summary.component';
import { SummaryService } from '../../core/services/summary.service';
import { of, throwError } from 'rxjs';
import { DEFAULT_SUMMARY_OPTIONS } from '../../core/models/summary.model';

const MOCK_RESPONSE = {
  summaryId: 'abc-123', documentId: 'doc-456',
  fileName: 'test.pdf', fileSize: 12345,
  content: '## Summary\nTest content here.',
  language: 'fr', model: 'claude-sonnet-4-5',
  engine: 'claude', cached: false,
  createdAt: new Date().toISOString(),
};

describe('SummaryComponent', () => {

  let component: SummaryComponent;
  let serviceSpy: { summarize: ReturnType<typeof vi.fn>; getHistory: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    serviceSpy = {
      summarize:   vi.fn().mockReturnValue(of(MOCK_RESPONSE)),
      getHistory:  vi.fn().mockReturnValue([]),
    };
    TestBed.configureTestingModule({
      imports: [SummaryComponent],
      providers: [{ provide: SummaryService, useValue: serviceSpy }],
    });
    component = TestBed.createComponent(SummaryComponent).componentInstance;
  });

  it('should start at step upload', () => {
    expect(component.step()).toBe('upload');
  });

  it('should advance to options after file selection', () => {
    const file = new File(['dummy'], 'test.pdf', { type: 'application/pdf' });
    component.onFileSelected([file]);
    expect(component.step()).toBe('options');
    expect(component.selectedFile()).toBe(file);
  });

  it('should go to generating then result on successful summarize', () => {
    const file = new File(['dummy'], 'test.pdf', { type: 'application/pdf' });
    component.selectedFile.set(file);
    component.generate();
    expect(serviceSpy.summarize).toHaveBeenCalledWith(file, DEFAULT_SUMMARY_OPTIONS);
    // Sync response → result immédiat
    expect(component.step()).toBe('result');
    expect(component.summary()).toEqual(MOCK_RESPONSE);
  });

  it('should go to polling when jobId is returned', () => {
    serviceSpy.summarize.mockReturnValue(of({ jobId: 'job-789' }));
    const file = new File(['dummy'], 'test.pdf', { type: 'application/pdf' });
    component.selectedFile.set(file);
    component.generate();
    expect(component.step()).toBe('polling');
    expect(component.pollingJobId()).toBe('job-789');
  });

  it('should go to error on API failure', () => {
    serviceSpy.summarize.mockReturnValue(throwError(() => ({
      error: { message: 'Service unavailable' }
    })));
    const file = new File(['dummy'], 'test.pdf', { type: 'application/pdf' });
    component.selectedFile.set(file);
    component.generate();
    expect(component.step()).toBe('error');
    expect(component.errorMsg()).toBe('Service unavailable');
  });

  it('should reset correctly', () => {
    component.summary.set(MOCK_RESPONSE as any);
    component.step.set('result');
    component.reset();
    expect(component.step()).toBe('upload');
    expect(component.summary()).toBeNull();
  });

  it('should compute wordCount from content', () => {
    component.summary.set({ ...MOCK_RESPONSE, content: 'hello world test' } as any);
    expect(component.wordCount()).toBe(3);
  });

  it('should compute engineInfo for claude', () => {
    component.summary.set({ ...MOCK_RESPONSE, engine: 'claude' } as any);
    expect(component.engineInfo()?.label).toBe('Claude');
  });

  it('should compute correct currentOptions from signals', () => {
    component.selectedMode.set('executive');
    component.selectedFocus.set('financial');
    const opts = component.currentOptions();
    expect(opts.mode).toBe('executive');
    expect(opts.focus).toBe('financial');
  });
});

─────────────────────────────────────────────────────────────────────
SummaryService tests :

describe('SummaryService', () => {

  it('should save to history after successful summarize', () => {
    // Mock localStorage
    const store: Record<string, string> = {};
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation((k, v) => { store[k] = v; });
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation((k) => store[k] ?? null);
    // ... test avec HttpClientTestingModule
  });

  it('should not throw if localStorage is unavailable', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    // saveToHistory ne doit pas propager l'erreur
    expect(() => service.saveToHistory(MOCK_RESPONSE as any, DEFAULT_SUMMARY_OPTIONS)).not.toThrow();
  });

  it('getHistory should return empty array if localStorage empty', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockReturnValue(null);
    expect(service.getHistory()).toEqual([]);
  });
});
```

---

## PROMPT 10 — Polish UX & Accessibilité

**Fichiers à modifier :**
- `src/app/features/summary/summary.component.ts` (micro-corrections finales)

```
Applique les améliorations UX et accessibilité suivantes :

1. ARIA et focus management :
   - Chaque bouton de mode/focus doit avoir [attr.aria-pressed]="selectedMode() === key"
   - Ajouter role="tablist" sur les onglets résultat et role="tab" sur chaque onglet
   - Ajouter [attr.aria-selected]="activeTab() === tab.key" sur les onglets
   - Bouton "Générer le résumé" : ajouter [attr.aria-busy]="step() === 'generating'"

2. Keyboard navigation :
   - Les chips mode/focus/langue doivent être activables à la touche Enter/Space
   - Ajouter (keydown.enter)="selectedMode.set(entry.key)" sur chaque chip mode
   - Idem pour focus et langue

3. Scroll to result :
   Dans onJobCompleted() et dans l'abonnement generate(), après step.set('result') :
     if (isPlatformBrowser(this.platformId)) {
       setTimeout(() => {
         document.querySelector('[data-result-anchor]')?.scrollIntoView({
           behavior: 'smooth', block: 'start'
         });
       }, 100);
     }
   Ajouter data-result-anchor sur la barre de métadonnées au début du case 'result'.

4. Skeleton loading (optionnel si kov-skeleton est disponible) :
   Si le composant kov-skeleton (src/app/shared/components/skeleton/) existe,
   l'utiliser pendant 'generating' au lieu de la liste de phases statique.
   Afficher 3 lignes skeleton de largeur variable simulant le futur contenu.

5. Truncated preview dans l'historique :
   Limiter preview à 1 ligne sur mobile (text-ellipsis) et 2 lignes sur desktop
   via la classe "line-clamp-1 sm:line-clamp-2".

6. Prevent double-submit :
   Désactiver le bouton "Générer" quand step === 'generating' ou 'polling' :
     [disabled]="!selectedFile() || step() === 'generating' || step() === 'polling'"

7. Print styles :
   Dans styles.css, ajouter à la fin :
   @media print {
     .no-print, button, nav, header, [data-history-panel] { display: none !important; }
     .prose { color: #000 !important; }
     body { background: white !important; }
   }
```

---

## Ordre d'exécution recommandé

```
PROMPT 1 → PROMPT 2 → PROMPT 3 → PROMPT 4 → PROMPT 5 → PROMPT 6 → PROMPT 7 → PROMPT 8 → PROMPT 9 → PROMPT 10
  Modèle    Service   Composant  Template   Template   Historique  Config     Routes     Tests      Polish
            enrichi   signaux    Upload/    Génération  slide-in   tools                            UX/A11y
                      + types    Options    + Résultat
```

> **Parallélisables** :
> - PROMPT 7 (tools-config) peut être fait à n'importe quel moment après PROMPT 1.
> - PROMPT 8 (routes) est indépendant.
> - PROMPT 9 (tests) peut être écrit en TDD, en parallèle de PROMPT 3.
> - PROMPT 10 (polish) peut être découpé et intégré au fur et à mesure.

---

## Critères de validation finale

### Fonctionnel
- [ ] Route `/tools/summary` charge le composant `SummaryComponent`
- [ ] Step 1 → Drop zone accepte uniquement les PDF, max 20 MB
- [ ] Drop zone → sélection → avance automatiquement vers Step 2 (Options)
- [ ] Les 5 modes de résumé sont affichés, avec badge PRO sur executive/detailed/custom
- [ ] Les 6 focus sont affichés en chips, sélection mono
- [ ] Les 3 longueurs sont affichées, sélection mono
- [ ] Les 5 langues de sortie sont affichées, sélection mono
- [ ] `showCustomInput()` est `true` uniquement si mode=custom ou focus=custom
- [ ] Bouton "Générer" est désactivé si aucun fichier sélectionné
- [ ] Pendant la génération : spinner + 3 phases textuelles animées
- [ ] Résultat : barre de métadonnées complète (langue, mots, durée, tokens, moteur, cache)
- [ ] Badge moteur IA : Claude / Gemini / Ollama avec couleur distincte
- [ ] Onglets Full / Sections visibles uniquement si `summary.sections` est non vide
- [ ] 3 actions : Copier (feedback "Copié !"), .txt download, .md download
- [ ] Lien "Poser une question" → `/tools/qna?docId=<documentId>`
- [ ] Bouton "Réessayer" sur la step error appelle à nouveau `generate()`
- [ ] Historique s'ouvre en slide-in, affiche les 10 derniers résumés
- [ ] Chaque entrée d'historique affiche : nom, preview 2 lignes, mode, mots, date
- [ ] Suppression individuelle et "Tout effacer" fonctionnent
- [ ] `localStorage` indisponible → pas d'erreur visible

### Performance
- [ ] `ng build` sans erreur ni warning TypeScript
- [ ] `ChangeDetectionStrategy.OnPush` sur tout le composant
- [ ] Aucun subscribe sans unsubscribe (utiliser `takeUntilDestroyed` ou `async` pipe)
- [ ] Lazy loading conservé (`loadChildren` dans les routes)

### Accessibilité
- [ ] Boutons mode/focus activables au clavier (Enter/Space)
- [ ] `aria-pressed` sur les chips de sélection
- [ ] `role="tablist"` et `aria-selected` sur les onglets résultat
- [ ] Scroll automatique vers le résultat après génération

### UX
- [ ] Stepper visuel reflète exactement l'étape courante
- [ ] Retour possible entre Step 1 et Step 2 via bouton "← Retour"
- [ ] Options conservées entre deux résumés (pas de reset des signaux)
- [ ] `@media print` masque les boutons et affiche uniquement le contenu

