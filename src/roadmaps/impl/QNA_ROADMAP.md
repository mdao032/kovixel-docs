# Roadmap — Outil "Questions / PDF" (Q&A)

> **Objectif** : Transformer l'outil Q&A en un assistant de lecture de PDF de très grande qualité,
> accessible aux anonymes, moderne dans ses interactions, précis dans ses réponses et cohérent
> avec l'écosystème Kovixel.

---

## État actuel (baseline)

### Ce qui existe
- Pipeline RAG complet : ingestion → chunking (800 tokens, 100 overlap) → embeddings OpenAI → pgvector → Claude
- Session unique par document par utilisateur, persistée en base
- Historique des messages (USER / ASSISTANT) chargé automatiquement
- Score de confiance basé sur la similarité cosinus moyenne des chunks
- Accordéon des sources (extraits de chunks ayant servi à la réponse)
- Quota `@CheckQuota(feature = FeatureType.QNA)` — réservé aux utilisateurs inscrits uniquement
- Composant Angular avec sidebar sélection de document, zone de chat, auto-scroll

### Ce qui manque (gaps critiques)
| Gap | Impact |
|-----|--------|
| Accès refusé aux anonymes (JWT obligatoire) | Conversion nulle |
| Claude + OpenAI pour TOUS les utilisateurs | Coût non maîtrisé |
| Pas de streaming SSE | UX perçue comme lente |
| Pas de détection PDF vide / scan | Erreur opaque pour l'utilisateur |
| Contexte multi-turn absent du prompt RAG | Réponses incohérentes en conversation |
| TOP_K = 5 fixe, pas de seuil de similarité | Chunks non pertinents injectés |
| Suggestions de questions absentes | Démarrage difficile, outil perçu comme vide |
| Un seul session par doc par user | Impossible de démarrer une nouvelle conversation |

---

## Architecture cible

```
Anonyme / FREE  ─→  nomic-embed-text (Ollama local, 768 dims)  +  qwen3 (Ollama local)
PRO             ─→  nomic-embed-text (Ollama local, 768 dims)  +  Claude Sonnet (cloud)
ENTERPRISE      ─→  nomic-embed-text (Ollama local, 768 dims)  +  Claude Opus (cloud)
```

> **Choix structurant** : embeddings unifiés (nomic-embed-text, 768 dims) pour tous les plans.
> Cela évite la complexité d'une double colonne pgvector et concentre le différentiel de qualité
> là où il compte vraiment : le modèle de génération.

---

## Quotas

| Dimension | Anonyme (IP) | FREE (compte) | PRO | ENTERPRISE |
|-----------|-------------|--------------|-----|------------|
| Documents ingérés / jour | 2 | 5 | 20 | ∞ |
| Questions / jour | 10 | 40 | 200 | ∞ |
| Questions / document / jour | 5 | 15 | ∞ | ∞ |
| Reset | Minuit UTC | Minuit UTC | Minuit UTC | — |

Le quota "questions/document" empêche l'épuisement du quota journalier sur un seul PDF.
Les deux compteurs (global + par document) coexistent via Redis avec des clés distinctes :
- `qna:anon:{ip}:daily` → compteur global
- `qna:anon:{ip}:doc:{documentId}:daily` → compteur par document

---

## Phases d'implémentation

---

### Phase 1 — Fondations & Accès (priorité CRITIQUE)
**Durée estimée : 3–4 jours**

Objectif : rendre l'outil accessible aux anonymes et supprimer la dépendance aux API cloud payantes pour les utilisateurs sans compte.

---

#### 1.1 — Accès anonyme + quota dual

**Fichiers à modifier**
- `SecurityConfig.java` — ajouter les endpoints Q&A aux `PUBLIC_ENDPOINTS`
- `AnonymousQuotaFilter.java` — étendre `QUOTA_ENFORCED_PATHS`
- `AnonymousQuotaService.java` — ajouter la méthode `checkAndIncrementQna(ip, documentId)`
- `QnaController.java` — rendre `@AuthenticationPrincipal` optionnel, passer `userId = null` si absent
- `QnaServiceImpl.java` — retirer l'assertion d'authentification obligatoire

**Endpoints à publier dans `PUBLIC_ENDPOINTS`**
```java
"/api/v1/documents/*/ask",
"/api/v1/documents/*/sessions/*/history"
```

**Logique de quota dual dans `AnonymousQuotaService`**
```
checkAndIncrementQna(ip, documentId):
  1. Vérifier redis key qna:anon:{ip}:daily          (limite: 10)
  2. Vérifier redis key qna:anon:{ip}:doc:{docId}:daily  (limite: 5)
  3. Si l'un ou l'autre est dépassé → lever AnonymousQuotaExceededException avec le détail
  4. Incrémenter les deux compteurs avec TTL jusqu'à minuit UTC
```

**Headers de réponse à ajouter**
```
X-RateLimit-Questions-Remaining: 7
X-RateLimit-Doc-Questions-Remaining: 3
X-RateLimit-Reset: 1749081600
```

**Message d'erreur 429**
```json
{
  "status": 429,
  "errorCode": "QNA_QUOTA_EXCEEDED",
  "message": "Limite atteinte (10 questions/jour pour les visiteurs). Créez un compte gratuit pour continuer.",
  "resetAt": "2026-06-14T00:00:00Z",
  "upgradeUrl": "/auth/register"
}
```
Quand c'est le quota par document : `"Limite atteinte pour ce document (5 questions/jour). Essayez un autre PDF ou créez un compte."`

---

#### 1.2 — Service d'embedding switchable

**Nouveau fichier : `EmbeddingService.java` (interface)**
```java
package com.kovixel.ai.embedding;

public interface EmbeddingService {
    float[] embed(String text);
    int getDimension();        // 768 pour nomic, 1536 pour OpenAI
    String getModelName();
}
```

**Implémentation locale : `OllamaEmbeddingService.java`**
```java
// POST {ollamaBaseUrl}/api/embeddings
// Body: { "model": "nomic-embed-text", "prompt": "{text}" }
// Retourne: { "embedding": [float, float, ...] } (768 dims)
// Timeout: 30s
// Modèle Ollama à puller : nomic-embed-text
```

**Implémentation cloud : `OpenAiEmbeddingService.java`**
```java
// Conserver l'appel existant à text-embedding-3-small (1536 dims)
// Utilisé uniquement si activé explicitement (pas dans le plan actuel)
// Garder pour référence / migration future
```

**Routing de l'embedding dans `QnaServiceImpl`**
```java
// Tous les plans → OllamaEmbeddingService (nomic-embed-text, 768 dims)
// OpenAiEmbeddingService → désactivé pour l'instant, kept for future
EmbeddingService embeddingService = ollamaEmbeddingService;
```

**Migration BDD : nouvelle colonne pgvector 768 dims**
```sql
-- V8__migrate_embeddings_768.sql
ALTER TABLE document_chunks
  DROP COLUMN embedding,
  ADD COLUMN embedding VECTOR(768),
  ADD COLUMN embedding_model VARCHAR(64) DEFAULT 'nomic-embed-text';

CREATE INDEX ON document_chunks USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);
```

> ⚠️ Les chunks existants (1536 dims) doivent être supprimés et re-ingérés.
> Ajouter une migration qui vide `document_chunks` et reset le flag `ingested` dans `summary_documents`.

---

#### 1.3 — Routing IA par plan (génération)

**Fichiers à modifier**
- `QnaServiceImpl.java` — remplacer l'appel direct `chatClient` par `AiRoutingService.resolveByEmail(userEmail)`
- `AiRoutingService.java` — vérifier que le plan `ANONYMOUS` route vers Ollama (déjà le cas pour le résumé)

**Prompt système RAG** (remplacer le prompt actuel)
```
Tu es un assistant expert en analyse de documents.
Réponds à la question de l'utilisateur en te basant UNIQUEMENT sur les extraits du document fournis.
Si la réponse n'est pas présente dans les extraits, réponds exactement :
{"found": false, "answer": "Cette information ne figure pas dans le document fourni.", "followups": []}
Si la réponse est présente, réponds avec le JSON suivant :
{"found": true, "answer": "...", "followups": ["question1", "question2", "question3"]}

Règles :
- Réponse en {outputLanguage}
- Pas d'invention, pas d'extrapolation hors contexte
- Les follow-ups sont 3 questions pertinentes que l'utilisateur pourrait poser ensuite
- Longueur de réponse adaptée à la complexité de la question
```

**Structure de réponse LLM attendue**
```json
{
  "found": true,
  "answer": "Le contrat prend fin le 31 décembre 2026...",
  "followups": [
    "Quelles sont les conditions de renouvellement ?",
    "Y a-t-il des pénalités en cas de rupture anticipée ?",
    "Qui sont les parties signataires ?"
  ]
}
```

**Parser la réponse dans `QnaResponseParser.java`** (nouveau fichier)
```java
// Extraire le JSON de la réponse brute (même logique que SummaryResponseParser)
// Si parsing échoue → found=true, answer=rawResponse, followups=[]
// Si found=false → retourner directement le message "non trouvé"
```

**`QnaResponse.java` — ajouter les champs**
```java
private boolean foundInDocument;    // false → réponse "non trouvé"
private List<String> followups;     // 0–3 suggestions de questions suivantes
```

---

### Phase 2 — Streaming SSE
**Durée estimée : 1–2 jours**

Objectif : tokens Claude affichés progressivement côté Angular dès qu'ils arrivent (expérience ChatGPT).

---

#### 2.1 — Endpoint SSE backend

**`QnaController.java` — nouvel endpoint**
```java
@GetMapping(
    value = "/{documentId}/ask/stream",
    produces = MediaType.TEXT_EVENT_STREAM_VALUE
)
public Flux<ServerSentEvent<String>> askStream(
        @PathVariable UUID documentId,
        @RequestParam String question,
        @RequestParam(required = false) UUID sessionId,
        @AuthenticationPrincipal UserDetails userDetails) {

    // 1. Valider la question (max 500 chars)
    // 2. Résoudre session + chunks (synchrone, avant streaming)
    // 3. Construire le prompt RAG
    // 4. Appeler chatClient.stream(prompt)
    // 5. Retourner flux de ServerSentEvent<String>
    //    - event: "token"   data: "mot "
    //    - event: "done"    data: {"sessionId":"...", "confidence":0.87, "followups":[...]}
    //    - event: "error"   data: {"message":"..."}
}
```

**Format SSE**
```
event: token
data: Le contrat

event: token
data:  prend fin

event: token
data:  le 31 décembre 2026

event: done
data: {"sessionId":"uuid","confidence":0.87,"sources":["..."],"followups":["...","...","..."]}
```

**`QnaServiceImpl.java` — nouvelle méthode**
```java
public Flux<String> streamAnswer(UUID documentId, QnaRequest request, Long userId) {
    // Steps 1-4 identiques à askQuestion() (sync)
    // Step 5 : chatClient.stream() au lieu de call()
    // Persister la réponse complète en base à la fin du flux (dans le onComplete)
}
```

**Gestion de la persistance en fin de stream**
```java
// Accumuler les tokens dans un StringBuilder
// Dans doOnComplete() : sauvegarder QnaMessage (USER + ASSISTANT) et toucher session.lastActivityAt
// Dans doOnError() : ne pas sauvegarder, retourner event "error"
```

---

#### 2.2 — Consommation SSE côté Angular

**`QnaService.ts` — nouvelle méthode**
```typescript
askStream(documentId: string, request: QnaRequest): Observable<QnaStreamEvent> {
  return new Observable(observer => {
    const params = new URLSearchParams({
      question: request.question,
      ...(request.sessionId ? { sessionId: request.sessionId } : {})
    });
    const es = new EventSource(
      `${this.base}/${documentId}/ask/stream?${params}`,
      { withCredentials: true }
    );
    es.addEventListener('token', e => observer.next({ type: 'token', data: e.data }));
    es.addEventListener('done',  e => observer.next({ type: 'done',  data: JSON.parse(e.data) }));
    es.addEventListener('error', e => { observer.error(e); es.close(); });
    return () => es.close();
  });
}
```

**`QnaStreamEvent` model**
```typescript
type QnaStreamEvent =
  | { type: 'token'; data: string }
  | { type: 'done';  data: { sessionId: string; confidence: number; sources: string[]; followups: string[] } }
  | { type: 'error'; data: { message: string } };
```

**`QnaComponent.ts` — affichage progressif**
```typescript
// Quand l'utilisateur envoie une question :
// 1. Ajouter le message USER immédiatement (optimistic)
// 2. Ajouter un message ASSISTANT vide avec isStreaming = true
// 3. S'abonner à askStream()
// 4. Sur chaque token → concaténer à assistantMessage.content + trigger scroll
// 5. Sur done → isStreaming = false, injecter confidence + followups + sources
// 6. Sur error → afficher le message d'erreur dans le bubble assistant

// Signal à ajouter :
readonly streamingMessageId = signal<string | null>(null);
```

**Curseur animé dans le template**
```html
@if (msg.isStreaming) {
  <span class="inline-block w-2 h-4 bg-current animate-pulse ml-0.5 rounded-sm"></span>
}
```

---

### Phase 3 — Détection PDF invalide
**Durée estimée : 1 jour**

Objectif : messages d'erreur clairs pour PDF vide, scanné (images uniquement) et protégé.
S'applique à **Q&A ET Résumé IA** (même `PdfExtractor`).

---

#### 3.1 — Classification dans `PdfExtractor.java`

**Enum à créer : `PdfContentType.java`**
```java
public enum PdfContentType {
    TEXT_EXTRACTABLE,   // PDF avec couche texte exploitable
    IMAGE_ONLY,         // Scan / PDF d'images (0 texte, pages non vides)
    EMPTY,              // PDF vide (0 pages ou pages sans contenu)
    ENCRYPTED           // PDF chiffré (extraction impossible)
}
```

**Méthode de classification dans `PdfExtractor`**
```java
public PdfContentType classify(byte[] pdfBytes) {
    try (PDDocument doc = Loader.loadPDF(pdfBytes)) {
        // Encrypted
        if (doc.isEncrypted()) return PdfContentType.ENCRYPTED;

        // Empty
        if (doc.getNumberOfPages() == 0) return PdfContentType.EMPTY;

        // Tenter extraction texte
        PDFTextStripper stripper = new PDFTextStripper();
        String text = stripper.getText(doc).strip();

        if (text.isEmpty()) {
            // Pages présentes mais 0 texte → très probablement un scan
            return PdfContentType.IMAGE_ONLY;
        }

        // Ratio texte/pages : si < 20 chars/page en moyenne → probablement scan
        double charsPerPage = (double) text.length() / doc.getNumberOfPages();
        if (charsPerPage < 20) return PdfContentType.IMAGE_ONLY;

        return PdfContentType.TEXT_EXTRACTABLE;
    } catch (InvalidPasswordException e) {
        return PdfContentType.ENCRYPTED;
    } catch (Exception e) {
        throw new RuntimeException("Erreur d'analyse du PDF", e);
    }
}
```

**Messages d'erreur par type**
```java
// Dans SummaryServiceImpl et QnaServiceImpl, appeler classify() en amont de extract()

switch (contentType) {
    case EMPTY ->
        throw new KovixelException(ErrorCode.INVALID_FILE_TYPE, HttpStatus.UNPROCESSABLE_ENTITY,
            "Ce PDF est vide (aucune page). Vérifiez le fichier et réessayez.");
    case ENCRYPTED ->
        throw new KovixelException(ErrorCode.INVALID_FILE_TYPE, HttpStatus.UNPROCESSABLE_ENTITY,
            "Ce PDF est protégé contre la copie. Déverrouillez-le d'abord puis réessayez.");
    case IMAGE_ONLY ->
        throw new KovixelException(ErrorCode.PDF_IMAGE_ONLY, HttpStatus.UNPROCESSABLE_ENTITY,
            "Ce PDF contient uniquement des images (scan ou photo). " +
            "La reconnaissance de texte (OCR) n'est pas encore disponible — " +
            "utilisez un PDF avec du texte sélectionnable.");
}
```

**Nouveau `ErrorCode` à ajouter**
```java
PDF_IMAGE_ONLY("PDF_IMAGE_ONLY", "Le PDF ne contient pas de texte extractible")
```

**Affichage côté Angular**
```typescript
// Dans le bloc error du composant, détecter errorCode === 'PDF_IMAGE_ONLY'
// Afficher une card dédiée avec icône 🖼 et message spécifique
// Ajouter un lien "En savoir plus sur l'OCR" (vers une future page)
```

---

### Phase 4 — Suggestions de questions intelligentes
**Durée estimée : 1–2 jours**

Objectif : l'utilisateur n'arrive jamais face à une zone de texte vide.

---

#### 4.1 — Questions de démarrage (pré-générées à l'ingestion)

**Table : `document_questions` (nouvelle migration `V9__document_questions.sql`)**
```sql
CREATE TABLE document_questions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES summary_documents(id) ON DELETE CASCADE,
    question    TEXT NOT NULL,
    source      VARCHAR(20) DEFAULT 'generated',  -- 'generated' | 'followup'
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ON document_questions (document_id);
```

**Génération dans `DocumentIngestionService.java` (fin d'ingestion)**
```java
// Après ingestion des chunks, si un résumé existe (Summary.sections non null) :
private void generateStarterQuestions(SummaryDocument doc, Summary summary) {
    if (summary == null || summary.getSections() == null) return;

    // Approche 1 (sans appel LLM) : dériver des questions depuis les titres de sections
    List<String> questions = summary.getSections().stream()
        .filter(s -> s.getTitle() != null && !s.getTitle().isBlank())
        .map(s -> deriveQuestionFromSection(s.getTitle(), s.getContent()))
        .filter(Objects::nonNull)
        .limit(4)
        .collect(Collectors.toList());

    // Approche 2 (avec appel LLM court) : demander à Ollama de générer 4 questions
    // depuis les 2000 premiers chars du texte extrait
    // → utiliser uniquement si sections vides ou insuffisantes
    if (questions.size() < 3) {
        questions = generateQuestionsFromText(doc.getExtractedText(), 4);
    }

    // Persister
    questions.stream()
        .map(q -> DocumentQuestion.builder()
            .documentId(doc.getId())
            .question(q)
            .source("generated")
            .build())
        .forEach(documentQuestionRepository::save);
}
```

**Prompt LLM pour la génération des questions de démarrage**
```
Tu analyses un document. À partir du texte fourni, génère exactement 4 questions pertinentes
qu'un utilisateur pourrait poser sur ce document.
Réponds UNIQUEMENT avec un tableau JSON de strings, sans aucun texte autour.
Format attendu : ["Question 1 ?", "Question 2 ?", "Question 3 ?", "Question 4 ?"]
Texte du document (extrait) :
{texte_2000_chars}
```

**Nouvel endpoint : `GET /{documentId}/questions/suggestions`**
```java
// Retourne les suggestions stockées en base (pas d'appel LLM à la volée)
// Si 0 suggestions en base → retourner liste vide (ne pas bloquer)
// Cache Redis 1 heure (même documentId → mêmes suggestions)
```

**Frontend `QnaComponent.ts`**
```typescript
// À la sélection d'un document → appeler getSuggestions(documentId)
// Afficher les suggestions comme des chips cliquables sous la zone de texte
// Au clic sur un chip → pré-remplir l'input + focus
// Masquer les chips dès que la conversation démarre (history.length > 0)
```

---

#### 4.2 — Follow-up suggestions (inline dans la réponse)

Implémenté dans la Phase 1.3 (champ `followups` dans la réponse LLM).

**Affichage côté Angular**
```typescript
// Après chaque réponse assistant, afficher les followups comme des chips
// Positionnés sous le message assistant (pas en bas de l'écran)
// Style : chips avec bord pointillé, couleur secondaire, légèrement plus petits que les suggestions de démarrage
// Au clic → pré-remplir l'input et envoyer immédiatement (UX fluide)
// Disparaissent dès que l'utilisateur tape sa propre question
```

**Template**
```html
@if (msg.followups?.length) {
  <div class="flex flex-wrap gap-2 mt-3">
    <span class="text-xs" style="color:var(--text-muted)">Continuer avec :</span>
    @for (q of msg.followups; track q) {
      <button
        class="text-xs px-3 py-1.5 rounded-lg border border-dashed transition hover:opacity-80"
        style="border-color:var(--border);color:var(--text-secondary)"
        (click)="sendQuestion(q)">
        {{ q }}
      </button>
    }
  </div>
}
```

---

### Phase 5 — Gestion avancée des conversations
**Durée estimée : 1–2 jours**

---

#### 5.1 — Multi-sessions par document

**`QnaSession.java` — ajouter un champ titre**
```java
private String title;   // Nullable, auto-généré depuis la 1ère question (tronqué à 60 chars)
```

**`QnaService.java` — nouveaux endpoints**
```
POST /{documentId}/sessions                             → Créer une nouvelle session vide
PATCH /{documentId}/sessions/{sessionId}               → Renommer une session
DELETE /{documentId}/sessions/{sessionId}              → Supprimer session + messages
GET /{documentId}/sessions                             → Lister toutes les sessions d'un doc
```

**Auto-génération du titre de session**
```java
// À la 1ère question d'une session, si title == null :
String title = question.length() > 60
    ? question.substring(0, 57) + "…"
    : question;
session.setTitle(title);
```

**Frontend : sidebar des sessions**
```typescript
// Quand un document est sélectionné :
// 1. Charger la liste des sessions (GET /{docId}/sessions)
// 2. Afficher la session la plus récente par défaut
// 3. Bouton "＋ Nouvelle conversation" → POST /{docId}/sessions
// 4. Chaque session dans la sidebar :
//    - Titre (ou "Conversation du {date}" si null)
//    - Date de dernière activité
//    - Bouton 🗑 supprimer (avec confirmation)
//    - Clic → charger l'historique de cette session
```

---

#### 5.2 — Contexte multi-turn dans le prompt RAG

**`QnaServiceImpl.java` — inclure l'historique récent**
```java
// Avant l'appel LLM, récupérer les N derniers messages de la session (max 6 = 3 tours)
List<QnaMessage> recentHistory = messageRepository
    .findTop6BySessionIdOrderByCreatedAtDesc(sessionId)
    .stream().sorted(Comparator.comparing(QnaMessage::getCreatedAt))
    .collect(Collectors.toList());

// Construire la section historique du prompt
String historySection = recentHistory.stream()
    .map(m -> m.getRole() == Role.USER
        ? "Utilisateur : " + m.getContent()
        : "Assistant : " + m.getContent())
    .collect(Collectors.joining("\n"));
```

**Prompt RAG complet avec historique**
```
[Système]
Tu es un assistant expert en analyse de documents.
Réponds UNIQUEMENT à partir des extraits du document fournis.
Si l'information n'est pas dans les extraits, indique-le clairement (found: false).
Réponds en {outputLanguage}.

[Historique de la conversation]
{historySection}
(vide si première question)

[Extraits du document les plus pertinents]
{chunk1}
---
{chunk2}
---
{chunk3}

[Question de l'utilisateur]
{question}

[Format de réponse attendu — JSON strict]
{"found": true|false, "answer": "...", "followups": ["...", "...", "..."]}
```

---

### Phase 6 — Qualité RAG
**Durée estimée : 2–3 jours**

---

#### 6.1 — Seuil de similarité + TOP_K dynamique

**`DocumentChunkRepository.java` — nouvelle query**
```java
@Query(value = """
    SELECT *, 1 - (embedding <=> CAST(:embedding AS vector)) AS similarity
    FROM document_chunks
    WHERE document_id = :documentId
      AND 1 - (embedding <=> CAST(:embedding AS vector)) >= :threshold
    ORDER BY embedding <=> CAST(:embedding AS vector)
    LIMIT :topK
    """, nativeQuery = true)
List<ChunkWithSimilarity> findRelevantChunks(
    UUID documentId, float[] embedding, float threshold, int topK);
```

**Configuration dans `application.yml`**
```yaml
kovixel:
  qna:
    similarity-threshold: 0.45    # Chunks en dessous → ignorés
    top-k-default: 5
    top-k-long-question: 7        # Si question > 100 chars
    top-k-short-question: 3       # Si question < 30 chars
```

**Logique de TOP_K dynamique**
```java
int topK = question.length() > 100 ? props.getTopKLong()
         : question.length() < 30  ? props.getTopKShort()
         : props.getTopKDefault();
```

**Gestion du cas "aucun chunk au-dessus du seuil"**
```java
if (chunks.isEmpty()) {
    return QnaResponse.builder()
        .foundInDocument(false)
        .answer("Je n'ai pas trouvé d'information pertinente sur ce sujet dans le document.")
        .confidence(0.0)
        .followups(List.of())
        .build();
    // Ne pas appeler Claude → économie de tokens
}
```

---

#### 6.2 — Numéros de page dans les sources

**`TextChunker.java` — stocker le numéro de page**
```java
// Lors du chunking, PDFBox permet de savoir sur quelle page se trouve chaque portion de texte
// Utiliser PDFTextStripper.setStartPage() / setEndPage() pour extraire page par page
// Stocker dans DocumentChunk.metadata : {"pageNumber": 3, "pageRange": "3-4"}
```

**Migration BDD**
```sql
-- Déjà présente : metadata JSONB dans document_chunks
-- Ajouter index GIN pour interrogation future
CREATE INDEX ON document_chunks USING gin(metadata);
```

**Affichage dans l'accordéon des sources**
```html
<!-- Dans le composant Angular, parser metadata.pageNumber -->
@if (source.pageNumber) {
  <span class="text-xs px-1.5 py-0.5 rounded bg-blue-50 text-blue-700">p. {{ source.pageNumber }}</span>
}
```

---

#### 6.3 — Recherche hybride (vector + full-text)

**Migration BDD**
```sql
-- V10__hybrid_search.sql
ALTER TABLE document_chunks ADD COLUMN content_tsv TSVECTOR
    GENERATED ALWAYS AS (to_tsvector('french', content)) STORED;

CREATE INDEX ON document_chunks USING gin(content_tsv);
```

**Query hybride (RRF — Reciprocal Rank Fusion)**
```sql
WITH vector_search AS (
    SELECT id, 1 - (embedding <=> CAST(:embedding AS vector)) AS score, ROW_NUMBER() OVER (
        ORDER BY embedding <=> CAST(:embedding AS vector)) AS rank
    FROM document_chunks
    WHERE document_id = :documentId
    LIMIT 20
),
text_search AS (
    SELECT id, ts_rank(content_tsv, query) AS score, ROW_NUMBER() OVER (
        ORDER BY ts_rank(content_tsv, query) DESC) AS rank
    FROM document_chunks, to_tsquery('french', :query) query
    WHERE document_id = :documentId AND content_tsv @@ query
    LIMIT 20
),
fused AS (
    SELECT
        COALESCE(v.id, t.id) AS id,
        (1.0 / (60 + COALESCE(v.rank, 20))) + (1.0 / (60 + COALESCE(t.rank, 20))) AS rrf_score
    FROM vector_search v
    FULL OUTER JOIN text_search t ON v.id = t.id
)
SELECT dc.*, f.rrf_score
FROM fused f JOIN document_chunks dc ON dc.id = f.id
ORDER BY f.rrf_score DESC
LIMIT :topK
```

---

### Phase 7 — UX avancée & polish
**Durée estimée : 2–3 jours**

---

#### 7.1 — Indicateur de progression à l'ingestion

**Backend — endpoint de statut**
```
GET /api/v1/documents/{documentId}/ingestion-status
Réponse : { "status": "not_started" | "in_progress" | "done" | "error", "chunkCount": 42 }
```

**Frontend — pendant la première question**
```typescript
// Si le document n'a pas encore été ingéré (détectable via le statut) :
// Afficher "📄 Analyse du document en cours…" avant le spinner "Claude réfléchit…"
// Sondage toutes les 2 secondes sur l'endpoint de statut jusqu'à "done"
// Puis déclencher l'appel Q&A

// Signal à ajouter :
readonly ingestionStep = signal<'idle' | 'ingesting' | 'thinking' | null>(null);
```

---

#### 7.2 — Rendu Markdown des réponses

**`QnaComponent.ts` — importer `MarkdownModule`** (déjà présent dans le projet pour le Résumé IA)
```typescript
// Ajouter MarkdownModule aux imports du composant standalone
// Dans le template, remplacer le <p>{{ msg.content }}</p>
// par <markdown [data]="msg.content" class="prose prose-sm max-w-none"></markdown>
// Pour le streaming, le composant Markdown doit re-rendre à chaque token (signal reactif)
```

---

#### 7.3 — Copie individuelle par message

```html
<!-- Sur chaque message assistant, bouton au hover -->
<div class="group relative">
  <div class="message-content">...</div>
  <button
    class="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition"
    (click)="copyMessage(msg.content)"
    title="Copier la réponse">
    📋
  </button>
</div>
```

---

#### 7.4 — Édition de la dernière question

```typescript
// Bouton "✏ Modifier" sur le dernier message USER (et uniquement le dernier)
// Au clic : remettre le contenu dans l'input, supprimer le dernier échange (USER + ASSISTANT)
// de l'affichage local (pas en base — on garde l'historique complet)
// L'utilisateur reformule et renvoie → nouvelle paire sauvegardée en base

readonly editingMessageId = signal<string | null>(null);
```

---

#### 7.5 — Raccourcis clavier

```typescript
// Dans QnaComponent, @HostListener sur document:keydown
// Ctrl+Enter ou Cmd+Enter → sendQuestion()
// Escape → fermer l'accordéon des sources si ouvert, sinon blur l'input
// ↑ → si input vide, rappeler la dernière question envoyée
// / → focus sur l'input depuis n'importe où dans le composant
```

---

#### 7.6 — Export de conversation (PDF / DOCX)

**Réutiliser l'infrastructure du Résumé IA**

**Nouveau service : `QnaExportService.java`**
```java
// PDF : construire un HTML structuré depuis les QnaMessage (USER en gris, ASSISTANT en blanc)
//       → GotenbergClient.convertHtmlToPdf()
// DOCX : XWPFDocument avec paragraphes alternés USER / ASSISTANT
//        → même pattern que SummaryDownloadServiceImpl

// Endpoint : GET /api/v1/documents/{documentId}/sessions/{sessionId}/export?format=pdf|docx
// Public : oui (même sessionId requis pour accéder)
```

**HTML template pour PDF export**
```html
<h1>{fileName} — Conversation</h1>
<p class="meta">{date}</p>

@for message in messages:
  <div class="message {message.role}">
    <span class="role-label">{USER: "Vous" | ASSISTANT: "Assistant"}</span>
    <div class="content">{message.content}</div>
    @if message.sources:
      <div class="sources">Sources : {sources}</div>
  </div>
```

---

### Phase 8 — Features premium (roadmap future)
**À planifier après validation des phases 1–7**

| Feature | Description | Complexité |
|---------|-------------|------------|
| **Q&A multi-documents** | Interroger plusieurs PDFs simultanément. pgvector search étendue à `document_id IN (...)`. Attribution de source par document dans la réponse. | Haute |
| **Citations exactes avec PDF viewer** | Identifier le passage exact du PDF cité, le surligner dans un viewer PDF.js embarqué. Nécessite de stocker les coordonnées de bounding box par chunk (PDFBox). | Très haute |
| **Partage de session (lien public)** | Token de partage opaque (UUID) → accès lecture seule à une session. Utile pour partager une analyse avec un tiers non inscrit. | Moyenne |
| **Mode comparaison** | Poser la même question sur deux documents et voir les réponses côte à côte. | Haute |
| **OCR (images → texte)** | Intégrer Tesseract ou un service cloud OCR pour les PDFs scannés. Débloquer les "PDF image only". | Haute |

---

## Matrice de priorité

```
                   Impact utilisateur
                   Faible          Fort
              ┌────────────────┬────────────────┐
Effort  Faible│  7.3 Copie msg │  1.1 Accès anon│
              │  7.5 Raccourcis│  2.x Streaming │
              │                │  3.x Détection │
              ├────────────────┼────────────────┤
       Élevé  │  6.3 Hybride   │  1.2/1.3 IA    │
              │  8.x Premium   │  4.x Questions │
              │                │  5.x Sessions  │
              └────────────────┴────────────────┘
```

## Ordre d'implémentation recommandé

```
Semaine 1 : Phase 1 (accès anon + quota + routing IA + embeddings)
Semaine 1 : Phase 3 (détection PDF — peu d'effort, visible immédiatement)
Semaine 2 : Phase 2 (streaming SSE — impact UX maximal)
Semaine 2 : Phase 4 (suggestions de questions)
Semaine 3 : Phase 5 (multi-sessions + contexte multi-turn)
Semaine 3 : Phase 6.1 + 6.2 (seuil similarité + pages)
Semaine 4 : Phase 7 (polish UX : Markdown, copie, édition, export)
Semaine 4+: Phase 6.3 (hybride) + Phase 8 (premium)
```

---

## Fichiers clés à créer / modifier

### Backend (nouveaux fichiers)
```
com.kovixel.ai.embedding.EmbeddingService               (interface)
com.kovixel.ai.embedding.OllamaEmbeddingService         (impl locale)
com.kovixel.ai.embedding.OpenAiEmbeddingService         (impl cloud, standby)
com.kovixel.ai.qna.dto.QnaStreamEvent                   (record SSE)
com.kovixel.ai.qna.parser.QnaResponseParser             (JSON → QnaResponse)
com.kovixel.ai.qna.entity.DocumentQuestion              (suggestions)
com.kovixel.ai.qna.repository.DocumentQuestionRepository
com.kovixel.ai.qna.service.QnaExportService             (interface export)
com.kovixel.ai.qna.service.QnaExportServiceImpl
com.kovixel.processing.utils.PdfContentType             (enum)
resources/db/migration/V8__migrate_embeddings_768.sql
resources/db/migration/V9__document_questions.sql
resources/db/migration/V10__hybrid_search.sql
```

### Backend (fichiers modifiés)
```
PdfExtractor.java                    → classify() + messages clairs
SummaryServiceImpl.java              → classify() avant extract()
QnaController.java                   → endpoint SSE + accès anonyme + export
QnaServiceImpl.java                  → routing IA + streaming + historique multi-turn + seuil
QnaService.java (interface)          → nouvelles signatures
DocumentIngestionService.java        → génération suggestions + statut
DocumentChunkRepository.java         → query hybride + seuil + top-k
QnaSessionRepository.java            → findByDocumentId(), findByIdAndUserId()
QnaResponse.java                     → foundInDocument, followups
QnaSession.java                      → title
AnonymousQuotaService.java           → checkAndIncrementQna()
SecurityConfig.java                  → PUBLIC_ENDPOINTS Q&A
```

### Frontend (nouveaux fichiers)
```
core/models/qna-stream.model.ts
```

### Frontend (fichiers modifiés)
```
features/qna/qna.component.ts       → streaming, suggestions, multi-sessions, Markdown, raccourcis
core/services/qna.service.ts        → askStream(), getSuggestions(), getSessions(), exportSession()
core/models/qna.model.ts            → QnaResponse.followups, QnaSession.title, QnaStreamEvent
```

---

*Roadmap créée le 2026-06-13 — à synchroniser avec l'avancement de l'implémentation.*
