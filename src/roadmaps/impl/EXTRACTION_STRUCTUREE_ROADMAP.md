# Roadmap — Outil "Extraction Structurée" (Kovixel)

> **Objectif** : Délivrer un outil d'extraction de données structurées depuis des PDFs,
> de qualité production, cohérent avec les patterns établis sur l'outil Q&A.
> Accessible aux utilisateurs anonymes (quota IP) et authentifiés (plan FREE/PRO/ENTERPRISE).

---

## État de l'art (audit 2026-06-13)

### Ce qui existe et compile ✅
| Couche | Fichier | État |
|--------|---------|------|
| DB | `V7__create_extraction_tables.sql` | ✅ Tables + seeds 4 templates |
| Entity | `ExtractionTemplate`, `ExtractionResultEntity` | ✅ |
| Repo | `ExtractionTemplateRepository`, `ExtractionResultRepository` | ✅ minimal |
| DTO | `ExtractionRequest`, `ExtractionResponse`, `ExtractionField`, `ExtractionTemplateResponse` | ✅ |
| Controller | `ExtractionController` (4 endpoints) | ✅ compilé |
| Service | `ExtractionServiceImpl` | ✅ compilé mais architecture incorrecte |
| Export | `ExportService` (JSON / CSV / XLSX) | ✅ complet |
| Frontend service | `extraction.service.ts` | ✅ minimal |
| Frontend model | `extraction.model.ts` | ⚠️ incomplet |
| Frontend composant | `ExtractionComponent` | ⚠️ partiel, bugs encodage |

### Problèmes critiques identifiés ❌
**Backend :**
- `ExtractionServiceImpl` appelle Claude en dur (`ChatClient`) — sans routing IA (`AiRoutingService`)
- `@CheckQuota` bloque toute extraction sans userId → incompatible avec l'accès anonyme
- Pas de vérification d'ownership du document (n'importe quel user peut extraire n'importe quel doc)
- `getExtractionHistory()` sans ownership check
- Pas de support accès anonyme (extraction endpoints absents de `SecurityConfig.PUBLIC_ENDPOINTS`)
- Cache key incorrecte pour les extractions custom fields
- `ExtractionResultEntity` sans champ `userId` (impossible de filtrer par user)

**Frontend :**
- Caractères français cassés dans le template (`"Slectionnez"`, `"prcdentes"`, `"Rsultat"`)
- `reloadDocs()` appelé inconditionnellement dans `ngOnInit()` → popup login pour les guests
- `ExtractionRequest` model ne supporte que `templateId` — pas de champs custom
- `ExtractionResult` sans `confidence`, `model`, `tokensUsed` dans le modèle TS
- `ExtractionTemplate.fieldsSchema` est `string[]` au lieu de `ExtractionField[]`
- Pas d'upload PDF intégré dans le composant
- Pas de constructeur de champs custom (mode avancé)
- Historique chargé uniquement en mémoire (pas d'appel `GET /extractions` au chargement)

---

## Architecture cible

```
POST /api/v1/documents/{documentId}/extract          → anonyme + auth (quota IP anonymes)
GET  /api/v1/documents/{documentId}/extractions       → auth requis
GET  /api/v1/extraction-templates                     → public (lecture seule)
GET  /api/v1/extractions/{extractionId}/export        → auth requis

Routing IA :
  anonyme / FREE  → Ollama qwen3:7b   (prompt extraction optimisé)
  PRO/ENTERPRISE  → Claude Sonnet     (fallback Ollama si indisponible)

Quota anonyme (Redis) :
  qna:anon:{ip}:extract:daily:{date}       → 3 extractions / jour / IP
  qna:anon:{ip}:extract:doc:{docId}:{date} → 2 extractions / jour / IP / doc
```

---

## Phase 1 — Socle & Corrections critiques (Backend)

> **Durée estimée** : 1–2 jours  
> **Priorité** : Bloquante — rien d'autre ne peut être livré sans cette phase

### 1.1 Accès anonyme & Security

- [ ] **`SecurityConfig.java`** — Ajouter `extraction` aux endpoints publics :
  ```java
  "/api/v1/documents/*/extract",
  "/api/v1/extraction-templates",
  ```
  `GET /extractions/{id}/export` reste protégé (auth requise).

- [ ] **`AnonymousQuotaService.java`** — Ajouter les méthodes :
  ```java
  void checkAndIncrementExtraction(String clientIp, String documentId);
  // Quota global : 3/jour/IP + quota par doc : 2/jour/IP/doc
  // Clés Redis :
  //   qna:anon:{ip}:extract:daily:{date}
  //   qna:anon:{ip}:extract:doc:{documentId}:{date}
  ```

### 1.2 Controller — Signature anonyme-compatible

- [ ] **`ExtractionController.java`** — Refactoring complet :
  ```java
  @PostMapping("/api/v1/documents/{documentId}/extract")
  public ResponseEntity<ExtractionResponse> extract(
      @PathVariable UUID documentId,
      @Valid @RequestBody ExtractionRequest request,
      @AuthenticationPrincipal UserDetails userDetails,   // null pour anonymes
      HttpServletRequest httpRequest) {

      Long userId = resolveUserId(userDetails);
      String clientIp = resolveIp(httpRequest);
      return ResponseEntity.status(HttpStatus.CREATED)
          .body(extractionService.extract(documentId, request, userId, clientIp));
  }
  ```
  - Ajouter `resolveUserId()` et `resolveIp()` (même pattern que `QnaController`)
  - Supprimer l'injection directe de `ExtractionResultRepository` dans le controller
    (uniquement dans le service)
  - Déplacer la logique d'export dans un endpoint dédié ou un service

- [ ] **`ExtractionService.java`** — Mettre à jour l'interface :
  ```java
  ExtractionResponse extract(UUID documentId, ExtractionRequest request,
                              Long userId, String clientIp);
  List<ExtractionResponse> getExtractionHistory(UUID documentId, Long userId);
  List<ExtractionTemplateResponse> listTemplates();
  ```

### 1.3 Service — AI routing & logique métier correcte

- [ ] **`ExtractionServiceImpl.java`** — Refactoring complet :

  **Injection :**
  ```java
  private final AiRoutingService aiRoutingService;          // NOUVEAU
  private final AnonymousQuotaService anonymousQuotaService; // NOUVEAU
  // Supprimer : ChatClient (injecté via AiRoutingDecision)
  ```

  **Suppression de `@CheckQuota`** — remplacer par quota manuel :
  ```java
  public ExtractionResponse extract(..., Long userId, String clientIp) {
      if (userId == null) {
          anonymousQuotaService.checkAndIncrementExtraction(clientIp, documentId.toString());
      }
      // ...
  }
  ```

  **Ownership check** :
  ```java
  private SummaryDocument loadDocument(UUID documentId, Long userId) {
      if (userId == null) {
          return documentRepository.findById(documentId)
              .orElseThrow(() -> new KovixelException(DOCUMENT_NOT_FOUND, NOT_FOUND, "..."));
      }
      return documentRepository.findByIdAndUserId(documentId, userId)
          .orElseThrow(() -> new KovixelException(ACCESS_DENIED, FORBIDDEN, "..."));
  }
  ```

  **AI routing** :
  ```java
  private String callAiForExtraction(String text, List<ExtractionField> fields, Long userId) {
      AiRoutingDecision decision = aiRoutingService.resolve(userId);
      // ... utiliser decision.chatClient() ou decision.model()
  }
  ```

  **`getExtractionHistory()` avec ownership** :
  ```java
  public List<ExtractionResponse> getExtractionHistory(UUID documentId, Long userId) {
      if (userId == null) throw new KovixelException(ACCESS_DENIED, UNAUTHORIZED, "...");
      loadDocument(documentId, userId); // throws si pas owner
      return resultRepository.findByDocumentIdOrderByCreatedAtDesc(documentId)...;
  }
  ```

  **Cache key** — distinguer template vs custom :
  ```java
  // key = docId + templateId OU docId + hash(fields)
  @Cacheable(value = "extractions",
      key = "#documentId + ':' + (#request.templateId() != null
             ? #request.templateId()
             : T(java.util.Objects).hash(#request.fields()))")
  ```

### 1.4 Validation & Request

- [ ] **`ExtractionRequest.java`** — Ajouter validation :
  ```java
  public record ExtractionRequest(
      @Size(max = 50) String templateId,
      @Size(max = 20) @Valid List<ExtractionField> fields,
      @Size(max = 200) String customInstruction  // NOUVEAU — instruction libre optionnelle
  ) {}
  ```

- [ ] **`ExtractionField.java`** — Ajouter validation :
  ```java
  public record ExtractionField(
      @NotBlank @Size(max = 100) String name,
      @NotBlank @Size(max = 300) String description,
      @Pattern(regexp = "STRING|NUMBER|DATE|BOOLEAN|LIST") String type,
      boolean required
  ) {}
  ```

### 1.5 Migration DB

- [ ] **`V22__add_userid_to_extraction_results.sql`** — Ajouter `user_id` sur la table :
  ```sql
  ALTER TABLE extraction_results
      ADD COLUMN IF NOT EXISTS user_id BIGINT
          CONSTRAINT fk_extraction_user REFERENCES users(id) ON DELETE SET NULL;

  CREATE INDEX IF NOT EXISTS idx_extraction_results_user_id
      ON extraction_results (user_id);
  ```

- [ ] **`ExtractionResultEntity.java`** — Ajouter champ `userId` :
  ```java
  @Column(name = "user_id")
  private Long userId;
  ```

- [ ] **`ExtractionResultRepository.java`** — Ajouter méthodes :
  ```java
  List<ExtractionResultEntity> findByDocumentIdAndUserIdOrderByCreatedAtDesc(
      UUID documentId, Long userId);
  Optional<ExtractionResultEntity> findByIdAndUserId(UUID id, Long userId);
  ```

### 1.6 Export — Sécurisation

- [ ] **`ExtractionController.java`** — Endpoint export :
  ```java
  @GetMapping("/api/v1/extractions/{extractionId}/export")
  public ResponseEntity<byte[]> export(
      @PathVariable UUID extractionId,
      @RequestParam(defaultValue = "json") String format,
      @AuthenticationPrincipal UserDetails userDetails) {

      Long userId = resolveUserId(userDetails);
      if (userId == null) throw new KovixelException(ACCESS_DENIED, UNAUTHORIZED, "...");
      ExtractionResultEntity entity = resultRepository.findByIdAndUserId(extractionId, userId)
          .orElseThrow(...);
      // ... reste inchangé
  }
  ```

---

## Phase 2 — Frontend : Corrections & Complétude

> **Durée estimée** : 1–2 jours  
> **Priorité** : Haute — expérience utilisateur directement impactée

### 2.1 Modèles TypeScript

- [ ] **`extraction.model.ts`** — Refactoring complet :
  ```typescript
  export interface ExtractionField {
    name: string;
    description: string;
    type: 'STRING' | 'NUMBER' | 'DATE' | 'BOOLEAN' | 'LIST';
    required: boolean;
  }

  export interface ExtractionTemplate {
    id: string;
    name: string;
    description: string;
    fields: ExtractionField[];   // était string[]
  }

  export interface ExtractionRequest {
    templateId?: string;
    fields?: ExtractionField[];           // NOUVEAU — mode custom
    customInstruction?: string;           // NOUVEAU
  }

  export interface ExtractionResult {
    id: string;
    documentId: string;                   // NOUVEAU
    templateName: string;
    fields: Record<string, unknown>;
    confidence: number;                   // NOUVEAU
    model?: string;                       // NOUVEAU
    tokensUsed?: number;                  // NOUVEAU
    cached: boolean;                      // NOUVEAU
    createdAt: string;
  }

  export type ExportFormat = 'json' | 'csv' | 'xlsx';
  ```

### 2.2 Service TypeScript

- [ ] **`extraction.service.ts`** — Compléter :
  ```typescript
  getHistory(documentId: string): Observable<ExtractionResult[]> {
    return this.http.get<ExtractionResult[]>(
      `${this.base}/documents/${documentId}/extractions`
    );
  }
  ```

### 2.3 Composant — Corrections critiques

- [ ] **Encodage** — Corriger tous les caractères français cassés :
  - `"Slectionnez"` → `"Sélectionnez"`
  - `"prcdentes"` → `"précédentes"`
  - `"Rsultat"` → `"Résultat"`
  - `"Slectionnez un template d'extraction"` → `"Sélectionnez un template d'extraction"`
  *(Cause probable : problème d'encodage du fichier source ou de l'éditeur — sauvegarder en UTF-8)*

- [ ] **Guest protection** — Même pattern que `QnaComponent` :
  ```typescript
  readonly isGuest = this.authService.isGuest;

  ngOnInit(): void {
    this.extractionService.getTemplates().subscribe(...);
    if (!this.isGuest()) this.reloadDocs();   // ← guard ajouté
    const docId = this.route.snapshot.queryParamMap.get('docId');
    if (docId) this.selectedDocId.set(docId);
  }

  reloadDocs(): void {
    if (this.isGuest()) return;   // ← guard ajouté
    // ...
  }
  ```

- [ ] **Chargement historique réel** — Charger depuis l'API au `selectDocument()` :
  ```typescript
  selectDocument(id: string): void {
    this.selectedDocId.set(id);
    this.currentResult.set(null);
    if (!this.isGuest()) this.loadHistory(id);
  }

  private loadHistory(docId: string): void {
    this.extractionService.getHistory(docId).subscribe({
      next:  (items) => this.extractionHistory.set(items),
      error: ()      => {},
    });
  }
  ```

- [ ] **Icônes SVG** — Remplacer les emojis (`🧾`, `📄`, `👤`, `🏥`) par des icônes SVG
  cohérentes avec le design system (même style que le reste de l'app).

- [ ] **Upload intégré** — Même widget que `QnaComponent` :
  - Input `#fileInput` caché + méthodes `triggerUpload()`, `startUpload()`, `onDrop()`, etc.
  - Upload via `SummaryService.summarize()`, puis `selectDocument(res.documentId)`
  - Visible en état "aucun document" + bouton compact dans le header du sélecteur de document

- [ ] **Confidence visuelle** — Afficher la confiance de l'extraction :
  ```html
  <!-- Dans la table résultat, après l'en-tête -->
  <div class="flex items-center gap-2 mb-3">
    <kov-badge [variant]="confidenceVariant(currentResult()!.confidence)">
      Confiance {{ (currentResult()!.confidence * 100).toFixed(0) }}%
    </kov-badge>
    <span class="text-xs" style="color:var(--text-muted)">
      Modèle : {{ currentResult()!.model ?? 'IA' }}
    </span>
  </div>
  ```

- [ ] **Cache badge** — Afficher un badge "Depuis le cache" si `cached: true`.

### 2.4 Mode champs custom (interface avancée)

- [ ] **Toggle template / custom** — Ajouter un onglet/switch :
  ```
  [ Templates prédéfinis ] [ Champs personnalisés ]
  ```

- [ ] **Constructeur de champs** — Formulaire simple (pas drag-and-drop à ce stade) :
  ```
  +---------------------------------------------+
  | Nom du champ      Type       Requis  [✕]     |
  | _____________ [STRING ▼]   [□]               |
  | Description : ________________________________|
  +---------------------------------------------+
  [ + Ajouter un champ ]
  ```
  - Validation : 1–20 champs, nom unique, description obligatoire
  - Bouton "Lancer l'extraction" activé dès qu'au moins 1 champ est défini

- [ ] **Instruction libre** — Champ texte optionnel :
  ```
  [ Instruction complémentaire (optionnel, max 200 chars) ]
  ```
  Exemples : "Retourne les montants en euros", "Ignore les mentions légales"

---

## Phase 3 — Enrichissement IA & UX avancée

> **Durée estimée** : 2–3 jours  
> **Priorité** : Moyenne — valeur ajoutée différenciante

### 3.1 Confidence par champ (backend)

- [ ] **Prompt amélioré** — Demander au LLM de retourner la confiance par champ :
  ```
  Réponds TOUJOURS en JSON strict :
  {
    "fields": {
      "nom_champ": { "value": ..., "confidence": 0.0–1.0, "found": true/false }
    }
  }
  ```

- [ ] **`ExtractionResponse`** — Ajouter `fieldDetails` :
  ```java
  public record FieldDetail(Object value, Double confidence, Boolean found) {}
  // ExtractionResponse : ajouter Map<String, FieldDetail> fieldDetails
  ```

- [ ] **Migration** — Ajouter colonne `field_details jsonb` sur `extraction_results`.

- [ ] **Frontend** — Afficher la confiance par ligne dans la table résultat :
  ```
  | Champ     | Valeur           | Confiance |
  |-----------|------------------|-----------|
  | numero    | INV-2024-001     | ████ 95%  |
  | montant   | 1 250,00 €       | ███░ 80%  |
  | date      | —                | ░░░░ 10%  | ← non trouvé
  ```

### 3.2 Extraction multi-documents (batch)

- [ ] **Endpoint** :
  ```
  POST /api/v1/extractions/batch
  Body: { documentIds: UUID[], templateId: string }
  ```
- [ ] **Service** — Lancer l'extraction en parallèle (CompletableFuture) sur chaque document.
- [ ] **Réponse** — Retourner un résumé + les `extractionId` individuels.
- [ ] **Frontend** — Sélecteur multi-document + table de résultats agrégés.

### 3.3 Templates personnalisés sauvegardés (user)

- [ ] **Migration** — Ajouter `user_id` optionnel sur `extraction_templates` :
  ```sql
  ALTER TABLE extraction_templates ADD COLUMN IF NOT EXISTS user_id BIGINT;
  -- user_id NULL = template système (INVOICE, CONTRACT, etc.)
  -- user_id SET = template utilisateur
  ```

- [ ] **Endpoints** :
  ```
  POST   /api/v1/extraction-templates        → créer un template perso
  PUT    /api/v1/extraction-templates/{id}   → modifier (owner uniquement)
  DELETE /api/v1/extraction-templates/{id}   → supprimer (owner uniquement)
  GET    /api/v1/extraction-templates        → systèmes + templates du user
  ```

- [ ] **Frontend** — Section "Mes templates" dans le panneau de sélection.
  - Bouton "Sauvegarder comme template" après une extraction custom réussie.

### 3.4 Indicateur moteur IA

- [ ] **Response header** — `X-Ai-Engine: ollama:qwen3:7b` ou `X-Ai-Engine: claude:claude-sonnet-4-6`
- [ ] **Frontend** — Badge discret sous le bouton "Lancer l'extraction" :
  ```
  Propulsé par [Ollama local] ou [Claude IA]
  ```

### 3.5 Export amélioré

- [ ] **PDF export** — Générer un PDF formaté via Apache PDFBox ou iText :
  - En-tête Kovixel, tableau des champs, métadonnées, score de confiance
- [ ] **Copier JSON** — Bouton "Copier en JSON" (clipboard API) sans téléchargement.

---

## Phase 4 — Tests, Performance & Production

> **Durée estimée** : 1–2 jours  
> **Priorité** : Haute avant mise en production

### 4.1 Tests backend

- [ ] **`ExtractionControllerTest.java`** (`@WebMvcTest`) :
  - `extract_validTemplateRequest_returns201`
  - `extract_validCustomFields_returns201`
  - `extract_emptyFieldsAndNoTemplate_returns400`
  - `extract_documentNotFound_returns404`
  - `extract_notOwner_returns403`
  - `listTemplates_returns200WithFourTemplates`
  - `export_invalidFormat_defaultsToJson`
  - `export_unauthorized_returns401`

- [ ] **`ExtractionServiceImplTest.java`** (unit) :
  - Mock du `AiRoutingService` et du `ChatClient`
  - Tester la résolution ownership (null userId vs authenticated)
  - Tester le quota anonyme
  - Tester la confidence calculation
  - Tester `buildFieldsDescription()` et `cleanJsonResponse()`

### 4.2 Tests frontend

- [ ] **`ExtractionComponent` spec** :
  - Rendu correct en mode guest (pas d'appel `getAll()`)
  - Sélection de template → bouton enabled
  - Extraction réussie → table affichée + badge confidence
  - Extraction échouée → message d'erreur
  - Export déclenche le téléchargement
  - Mode custom : ajout/suppression de champs, validation

### 4.3 Performance & Cache

- [ ] **Cache extraction** — Vérifier que le `@Cacheable` fonctionne correctement
  et que `@CacheEvict` est appelé si le document est re-résumé.

- [ ] **Index DB** — S'assurer que l'index sur `(document_id, user_id)` est créé
  pour les requêtes fréquentes d'historique.

- [ ] **Timeout** — Ajouter un timeout sur l'appel IA (même pattern que `SummaryService`) :
  ```java
  @Value("${kovixel.extraction.timeout-seconds:60}")
  private int timeoutSeconds;
  ```

### 4.4 Observabilité

- [ ] **Logs structurés** — Ajouter MDC (`userId`, `documentId`, `template`, `durationMs`)
  sur chaque extraction.

- [ ] **Métriques** — `extraction.duration_ms`, `extraction.confidence.avg`,
  `extraction.fields.filled_ratio` via Micrometer.

---

## Récapitulatif par phase

| Phase | Durée est. | Fichiers principaux touchés | Priorité |
|-------|------------|-----------------------------|----------|
| **1 — Backend socle** | 1–2 j | `SecurityConfig`, `ExtractionController`, `ExtractionService[Impl]`, `AnonymousQuotaService`, `V22__*.sql`, `ExtractionResultEntity`, `ExtractionResultRepository` | 🔴 Critique |
| **2 — Frontend corrections** | 1–2 j | `extraction.model.ts`, `extraction.service.ts`, `extraction.component.ts` | 🔴 Critique |
| **3 — Enrichissement IA** | 2–3 j | `ExtractionServiceImpl` (prompt), `ExtractionResponse`, migration V23, `extraction.component.ts` (batch, templates perso) | 🟡 Haute |
| **4 — Tests & Prod** | 1–2 j | `ExtractionControllerTest`, `ExtractionServiceImplTest`, `extraction.component.spec.ts` | 🟠 Importante |

**Total estimé : 5–9 jours selon le périmètre retenu.**

---

## Ordre d'implémentation recommandé

```
1. V22 migration (userId on extraction_results)
2. AnonymousQuotaService — méthodes extraction
3. SecurityConfig — publier POST /extract + GET /templates
4. ExtractionServiceImpl — AI routing + ownership + quota anonyme
5. ExtractionController — signature userId/clientIp
6. ExtractionResultRepository — nouvelles méthodes
7. Tests backend (Phase 4.1)
8. extraction.model.ts — modèles complets
9. extraction.service.ts — getHistory()
10. extraction.component.ts — corrections encodage + guest guard + upload + custom fields + UI polish
11. Tests frontend (Phase 4.2)
12. Phase 3 (enrichissements) si périmètre validé
```

---

## Points d'attention & décisions à valider

| Sujet | Décision suggérée | À confirmer |
|-------|-------------------|-------------|
| Accès anonyme extraction | ✅ Oui — quota 3/jour/IP (même pattern Q&A) | |
| Quota custom fields vs template | Même quota pour les deux | |
| Cache pour custom fields | Oui — key = hash des fields | |
| Batch extraction (multi-docs) | Phase 3 uniquement | |
| Export PDF | Phase 3 — dépendance iText/PDFBox | |
| Templates perso utilisateur | Phase 3 — migration schema requise | |
| Per-field confidence | Phase 3 — change le prompt et le schéma de réponse | |

---

*Document généré le 2026-06-13 — Kovixel Extraction Structurée*
