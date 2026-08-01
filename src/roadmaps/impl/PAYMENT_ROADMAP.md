# Kovixel — Feuille de route Module Paiement

> Objectif : intégrer un module de paiement récurrent de niveau production — abonnements,
> webhooks idempotents, portail client, dunning automatique et conformité PCI DSS SAQ-A —
> sans jamais faire transiter de données de carte bancaire par les serveurs Kovixel.

---

## Table des matières

1. [Contexte & état des lieux](#1-contexte--état-des-lieux)
2. [Choix du prestataire de paiement](#2-choix-du-prestataire-de-paiement)
3. [Catalogue Stripe — Produits & Prix](#3-catalogue-stripe--produits--prix)
4. [Architecture système](#4-architecture-système)
5. [Phase 1 — Base de données](#5-phase-1--base-de-données)
6. [Phase 2 — Stripe Checkout](#6-phase-2--stripe-checkout)
7. [Phase 3 — Webhooks & cycle de vie](#7-phase-3--webhooks--cycle-de-vie)
8. [Phase 4 — Portail client](#8-phase-4--portail-client)
9. [Phase 5 — Dunning & gestion des échecs](#9-phase-5--dunning--gestion-des-échecs)
10. [Phase 6 — Frontend Angular](#10-phase-6--frontend-angular)
11. [Phase 7 — Facturation & conformité fiscale](#11-phase-7--facturation--conformité-fiscale)
12. [Phase 8 — Monitoring & alertes](#12-phase-8--monitoring--alertes)
13. [Sécurité & conformité PCI DSS](#13-sécurité--conformité-pci-dss)
14. [Stratégie de tests](#14-stratégie-de-tests)
15. [Variables d'environnement](#15-variables-denvironnement)
16. [Checklist mise en production](#16-checklist-mise-en-production)

---

## 1. Contexte & état des lieux

### Ce qui existe déjà

| Composant | Fichier | Statut |
|-----------|---------|--------|
| Plans utilisateur | `user/entity/UserPlan.java` | ✅ `FREE / PRO / PRO_PLUS / TEAM / ENTERPRISE` |
| Config par plan | `user/entity/PlanConfig.java` | ✅ Limites, quotas, features flags |
| Entité abonnement | `subscription/entity/Subscription.java` | ✅ Modèle de base présent |
| Pricing cible | `PRICING_ROADMAP.md` | ✅ Plans, prix, matrice fonctionnelle |
| Intégration Stripe | — | ❌ Aucun code |
| Webhooks | — | ❌ Aucun endpoint |
| Portail client | — | ❌ Non implémenté |
| Migrations Flyway | V1 → V47 | ✅ Jusqu'à V47 inclus |

### Ce qu'il reste à construire

- Mapper `UserPlan` sur des Price IDs Stripe (mensuel / annuel)
- Créer un flux **Checkout → Webhook → Upgrade** de bout en bout
- Gérer les renouvellements, échecs de paiement, downgrades
- Exposer un portail de facturation libre-service
- Garantir la conformité RGPD, TVA EU et PCI DSS SAQ-A

---

## 2. Choix du prestataire de paiement

### Comparatif

| Critère | **Stripe** ✅ | Paddle | Lemon Squeezy | PayPal |
|---------|--------------|--------|---------------|--------|
| Abonnements récurrents | ✅ Natif | ✅ | ✅ | Limité |
| Checkout hébergé (PCI SAQ-A) | ✅ | ✅ | ✅ | ✅ |
| Webhooks fiables + retry | ✅ Excellent | ✅ | ✅ | ✗ Fragile |
| Portail client natif | ✅ | ✅ | Partiel | ✗ |
| TVA EU automatique | ✅ Stripe Tax | ✅ (Merchant of Record) | ✅ (MoR) | ✗ |
| API + SDK Java | ✅ Mature | Limité | ✗ | ✅ |
| Stripe-mock (tests) | ✅ | ✗ | ✗ | ✗ |
| Déjà référencé dans le projet | ✅ PRICING_ROADMAP | ✗ | ✗ | ✗ |
| Frais transactionnels (EU) | 1,5 % + 0,25 € | 5 % + 0,50 € | 5 % + 0,50 € | 3,4 % + 0,35 € |
| Frais abonnement | 0,5 %/mois (optionnel) | Inclus | Inclus | — |

**Décision : Stripe.**  
Déjà mentionné dans `PRICING_ROADMAP.md`, API Java mature, stripe-mock pour les tests,
Checkout hébergé = PCI SAQ-A, TVA EU via Stripe Tax. Les frais légèrement supérieurs à
Paddle/Lemon Squeezy sont compensés par la liberté de contrôle du flux et l'écosystème
d'outils de développement.

---

## 3. Catalogue Stripe — Produits & Prix

### Mapping UserPlan → Stripe Products

```
Produit Stripe "Kovixel PRO"
  ├─ Price: price_pro_monthly    → 9,00 € / mois (recurring)
  └─ Price: price_pro_yearly     → 87,00 € / an  (recurring, ~7,25 €/mois)

Produit Stripe "Kovixel PRO+"
  ├─ Price: price_pro_plus_monthly  → 14,00 € / mois (recurring)
  └─ Price: price_pro_plus_yearly   → 132,00 € / an  (recurring, ~11 €/mois)

Produit Stripe "Kovixel TEAM"
  ├─ Price: price_team_monthly      → 12,00 € / user / mois (recurring, metered)
  └─ Price: price_team_yearly       → 115,20 € / user / an
```

### Configuration YAML (`application.yml`)

```yaml
kovixel:
  stripe:
    secret-key: ${STRIPE_SECRET_KEY}
    webhook-secret: ${STRIPE_WEBHOOK_SECRET}
    price-ids:
      pro-monthly:       ${STRIPE_PRICE_PRO_MONTHLY}
      pro-yearly:        ${STRIPE_PRICE_PRO_YEARLY}
      pro-plus-monthly:  ${STRIPE_PRICE_PRO_PLUS_MONTHLY}
      pro-plus-yearly:   ${STRIPE_PRICE_PRO_PLUS_YEARLY}
      team-monthly:      ${STRIPE_PRICE_TEAM_MONTHLY}
      team-yearly:       ${STRIPE_PRICE_TEAM_YEARLY}
    trial-days: 14
    grace-period-days: 3
```

### Période d'essai

- **14 jours gratuits** sur PRO et PRO+ — aucune carte requise au démarrage
- Si aucun moyen de paiement ajouté à J+14 : downgrade automatique vers FREE
- Sur le Dashboard Stripe : `trial_period_days: 14` dans les paramètres Subscription

---

## 4. Architecture système

```
┌─────────────────────────────────────────────────────────────────────┐
│                          NAVIGATEUR                                  │
│                                                                     │
│  Angular SPA                                                        │
│  ├─ /pricing           → POST /api/checkout/session                │
│  ├─ /checkout/success  → lecture session_id + polling statut       │
│  └─ /account/billing   → POST /api/portal/session                  │
└────────────────────────┬────────────────────────────────────────────┘
                         │ HTTPS
┌────────────────────────▼────────────────────────────────────────────┐
│                    SPRING BOOT (Kovixel API)                        │
│                                                                     │
│  StripeConfig                 → com.stripe.Stripe.apiKey            │
│  CheckoutController           → POST /api/checkout/session          │
│  PortalController             → POST /api/portal/session            │
│  WebhookController            → POST /api/webhook/stripe            │
│  WebhookDispatcher            → router d'événements + idempotence  │
│  SubscriptionService          → upgrade / downgrade UserPlan        │
│  GracePeriodScheduler         → @Scheduled, cron quotidien          │
│  PaymentMetrics               → Micrometer counters + timers        │
└────────────────────────┬────────────────────────────────────────────┘
                         │ stripe-java SDK (TLS)
┌────────────────────────▼────────────────────────────────────────────┐
│                        STRIPE                                        │
│  Checkout Sessions  │  Subscriptions  │  Customer Portal            │
│  Webhooks (retry 3j)│  Stripe Tax     │  Invoices                   │
└─────────────────────────────────────────────────────────────────────┘
```

**Invariants de sécurité :**
- Aucune donnée de carte ne transite par Kovixel (PCI DSS SAQ-A)
- Tous les montants viennent de Stripe — jamais du client
- Chaque webhook est vérifié via `Stripe.constructEvent()` (signature HMAC-SHA256)
- Chaque événement est traité une seule fois (`kovixel_payment_events` + contrainte unique)

---

## 5. Phase 1 — Base de données

### Migration V48 — Extension `subscriptions`

```sql
-- V48__extend_subscriptions_stripe.sql
ALTER TABLE subscriptions
    ADD COLUMN stripe_customer_id     VARCHAR(255),
    ADD COLUMN stripe_subscription_id VARCHAR(255),
    ADD COLUMN stripe_price_id        VARCHAR(255),
    ADD COLUMN stripe_status          VARCHAR(50),   -- active | trialing | past_due | canceled
    ADD COLUMN billing_interval       VARCHAR(10),   -- monthly | yearly
    ADD COLUMN trial_end              TIMESTAMPTZ,
    ADD COLUMN current_period_start   TIMESTAMPTZ,
    ADD COLUMN current_period_end     TIMESTAMPTZ,
    ADD COLUMN cancel_at_period_end   BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN grace_period_until     TIMESTAMPTZ;

CREATE UNIQUE INDEX idx_sub_stripe_id
    ON subscriptions (stripe_subscription_id)
    WHERE stripe_subscription_id IS NOT NULL;

CREATE INDEX idx_sub_stripe_customer
    ON subscriptions (stripe_customer_id);

COMMENT ON COLUMN subscriptions.stripe_status IS
    'Statut Stripe: active, trialing, past_due, canceled, unpaid, incomplete';
COMMENT ON COLUMN subscriptions.grace_period_until IS
    'Si past_due: date limite avant downgrade automatique vers FREE';
```

### Migration V49 — Table d'idempotence des webhooks

```sql
-- V49__create_payment_events.sql
CREATE TABLE kovixel_payment_events (
    id             BIGSERIAL PRIMARY KEY,
    stripe_event_id VARCHAR(255) NOT NULL,
    event_type     VARCHAR(100) NOT NULL,
    processed_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    payload_hash   VARCHAR(64),
    CONSTRAINT uq_stripe_event_id UNIQUE (stripe_event_id)
);

CREATE INDEX idx_payment_events_type ON kovixel_payment_events (event_type);
CREATE INDEX idx_payment_events_processed ON kovixel_payment_events (processed_at);

COMMENT ON TABLE kovixel_payment_events IS
    'Idempotence des webhooks Stripe — chaque stripe_event_id ne peut être traité qu une seule fois';
```

### Migration V50 — Table des factures

```sql
-- V50__create_invoices.sql
CREATE TABLE kovixel_invoices (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT       NOT NULL REFERENCES kovixel_users(id),
    stripe_invoice_id   VARCHAR(255) NOT NULL UNIQUE,
    stripe_customer_id  VARCHAR(255) NOT NULL,
    amount_paid         INTEGER      NOT NULL, -- en centimes
    currency            VARCHAR(3)   NOT NULL DEFAULT 'eur',
    status              VARCHAR(50)  NOT NULL, -- paid | open | void | uncollectible
    invoice_url         TEXT,                  -- lien vers la facture Stripe
    invoice_pdf         TEXT,                  -- PDF téléchargeable
    period_start        TIMESTAMPTZ,
    period_end          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_invoices_user    ON kovixel_invoices (user_id);
CREATE INDEX idx_invoices_created ON kovixel_invoices (created_at DESC);
```

---

## 6. Phase 2 — Stripe Checkout

### Dépendance Maven

```xml
<dependency>
    <groupId>com.stripe</groupId>
    <artifactId>stripe-java</artifactId>
    <version>26.10.0</version>
</dependency>
```

### Configuration Spring

```java
// StripeConfig.java
@Configuration
public class StripeConfig {

    @Value("${kovixel.stripe.secret-key}")
    private String secretKey;

    @PostConstruct
    public void init() {
        Stripe.apiKey = secretKey;
        Stripe.setAppInfo("Kovixel", "1.0.0", "https://kovixel.com");
    }
}
```

### Endpoint Checkout

```java
// POST /api/checkout/session
@PostMapping("/api/checkout/session")
public ResponseEntity<CheckoutSessionResponse> createSession(
        @AuthenticationPrincipal KovixelUser user,
        @Valid @RequestBody CheckoutRequest request) {

    String customerId = ensureStripeCustomer(user);

    SessionCreateParams params = SessionCreateParams.builder()
        .setMode(SessionCreateParams.Mode.SUBSCRIPTION)
        .setCustomer(customerId)
        .setSuccessUrl(appBaseUrl + "/checkout/success?session_id={CHECKOUT_SESSION_ID}")
        .setCancelUrl(appBaseUrl + "/pricing")
        .addLineItem(SessionCreateParams.LineItem.builder()
            .setPrice(request.priceId())
            .setQuantity(1L)
            .build())
        .setSubscriptionData(SessionCreateParams.SubscriptionData.builder()
            .setTrialPeriodDays(14L)
            .build())
        .setAutomaticTax(SessionCreateParams.AutomaticTax.builder()
            .setEnabled(true)
            .build())
        .setLocale(SessionCreateParams.Locale.FR)
        .build();

    Session session = Session.create(params);
    return ResponseEntity.ok(new CheckoutSessionResponse(session.getUrl()));
}
```

```java
// Création ou récupération du Customer Stripe (idempotent)
private String ensureStripeCustomer(KovixelUser user) {
    if (user.getSubscription().getStripeCustomerId() != null) {
        return user.getSubscription().getStripeCustomerId();
    }
    CustomerCreateParams params = CustomerCreateParams.builder()
        .setEmail(user.getEmail())
        .setName(user.getDisplayName())
        .putMetadata("kovixel_user_id", String.valueOf(user.getId()))
        .build();
    Customer customer = Customer.create(params);
    subscriptionRepository.setStripeCustomerId(user.getId(), customer.getId());
    return customer.getId();
}
```

> ⚠️ **Anti-pattern à éviter** : ne jamais upgrader le plan sur la page `/checkout/success`.
> Le navigateur peut recharger la page, bookmarker l'URL, ou ne jamais l'atteindre.
> **L'upgrade se fait uniquement via le webhook** `checkout.session.completed`.

---

## 7. Phase 3 — Webhooks & cycle de vie

### Endpoint webhook (exclu du filtre JWT)

```java
// POST /api/webhook/stripe — exclu de SecurityFilterChain
@PostMapping(value = "/api/webhook/stripe", consumes = MediaType.APPLICATION_JSON_VALUE)
public ResponseEntity<Void> handleWebhook(
        HttpServletRequest request,
        @RequestBody String payload) {

    String sigHeader = request.getHeader("Stripe-Signature");
    Event event;
    try {
        event = Webhook.constructEvent(payload, sigHeader, webhookSecret);
    } catch (SignatureVerificationException e) {
        log.warn("Webhook — signature invalide : {}", e.getMessage());
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).build();
    }

    dispatcher.dispatch(event);
    return ResponseEntity.ok().build();
}
```

### WebhookDispatcher avec idempotence

```java
@Service
@Slf4j
@RequiredArgsConstructor
public class WebhookDispatcher {

    private final PaymentEventRepository eventRepo;

    public void dispatch(Event event) {
        // Idempotence : ignorer si déjà traité
        if (eventRepo.existsByStripeEventId(event.getId())) {
            log.debug("Webhook — déjà traité : {}", event.getId());
            return;
        }

        try {
            route(event);
            eventRepo.save(new PaymentEvent(event.getId(), event.getType()));
        } catch (Exception e) {
            log.error("Webhook — erreur traitement {} : {}", event.getId(), e.getMessage(), e);
            throw e; // Stripe retry automatique si on répond 5xx
        }
    }

    private void route(Event event) {
        switch (event.getType()) {
            case "checkout.session.completed"       -> handleCheckoutCompleted(event);
            case "customer.subscription.updated"    -> handleSubscriptionUpdated(event);
            case "customer.subscription.deleted"    -> handleSubscriptionDeleted(event);
            case "invoice.payment_succeeded"        -> handlePaymentSucceeded(event);
            case "invoice.payment_failed"           -> handlePaymentFailed(event);
            case "customer.subscription.trial_will_end" -> handleTrialWillEnd(event);
            default -> log.debug("Webhook — événement non géré : {}", event.getType());
        }
    }
}
```

### Handlers d'événements

| Événement Stripe | Action Kovixel |
|-----------------|----------------|
| `checkout.session.completed` | Lier `stripe_subscription_id` au user, upgrader `UserPlan` |
| `customer.subscription.updated` | Mettre à jour `stripe_status`, `current_period_*`, `cancel_at_period_end` |
| `customer.subscription.deleted` | Downgrade vers FREE immédiat |
| `invoice.payment_succeeded` | Enregistrer dans `kovixel_invoices`, réinitialiser `grace_period_until` |
| `invoice.payment_failed` | Calculer `grace_period_until = now + 3j`, notifier par email |
| `customer.subscription.trial_will_end` | Email J−3 : "Votre essai se termine dans 3 jours" |

---

## 8. Phase 4 — Portail client

Le portail Stripe Customer Portal permet à l'utilisateur de gérer son abonnement,
mettre à jour sa carte, télécharger ses factures — sans développement d'interface ad hoc.

```java
// POST /api/portal/session
@PostMapping("/api/portal/session")
public ResponseEntity<PortalSessionResponse> createPortalSession(
        @AuthenticationPrincipal KovixelUser user) {

    String customerId = user.getSubscription().getStripeCustomerId();
    if (customerId == null) {
        throw new KovixelException(HttpStatus.BAD_REQUEST,
                "Aucun abonnement actif trouvé.");
    }

    com.stripe.model.billingportal.Session session =
        com.stripe.model.billingportal.Session.create(
            com.stripe.param.billingportal.SessionCreateParams.builder()
                .setCustomer(customerId)
                .setReturnUrl(appBaseUrl + "/account/billing")
                .build());

    return ResponseEntity.ok(new PortalSessionResponse(session.getUrl()));
}
```

**Configuration du portail (Stripe Dashboard) :**
- Autoriser : mise à jour du moyen de paiement, annulation d'abonnement, downgrade
- Factures : affichage des 12 derniers mois
- Branding : logo Kovixel, couleurs `#7c3aed` (brand violet)

---

## 9. Phase 5 — Dunning & gestion des échecs

### Calendrier de relance Stripe (configurable dans le Dashboard)

| Délai | Tentative | Action Kovixel |
|-------|-----------|----------------|
| J+0   | 1ère tentative | Email "Paiement en échec — vérifiez votre carte" |
| J+3   | 2ème tentative | Email de rappel, `stripe_status = past_due` |
| J+5   | 3ème tentative | Email "Dernier avertissement" |
| J+7   | 4ème tentative | Annulation automatique si échec → `subscription.deleted` |

### Grace Period Scheduler

```java
@Component
@Slf4j
@RequiredArgsConstructor
public class GracePeriodScheduler {

    private final SubscriptionRepository subRepo;
    private final UserRepository userRepo;
    private final NotificationService notifier;

    @Scheduled(cron = "0 0 3 * * *") // chaque nuit à 03:00
    public void downgradeExpiredGracePeriods() {
        List<Subscription> expired = subRepo.findExpiredGracePeriods(Instant.now());
        for (Subscription sub : expired) {
            log.info("Grace period expirée — downgrade FREE : userId={}", sub.getUserId());
            userRepo.updatePlan(sub.getUserId(), UserPlan.FREE);
            sub.clearGracePeriod();
            subRepo.save(sub);
            notifier.sendPlanDowngradedEmail(sub.getUserId());
        }
        log.info("GracePeriodScheduler — {} compte(s) downgradé(s)", expired.size());
    }
}
```

### Comportement lors du downgrade FREE

| Ressource | Comportement |
|-----------|-------------|
| Documents existants | Conservés en lecture seule (accès illimité) |
| Stockage au-delà de 10 MB | Quota bloquant les nouvelles conversions uniquement |
| Clés API (PRO+) | Révoquées mais listées pour réactivation |
| Accès outils IA | Quotas FREE immédiatement appliqués |
| Historique au-delà de 7 jours | Masqué (récupérable si réabonnement sous 30 jours) |

---

## 10. Phase 6 — Frontend Angular

### Flux utilisateur complet

```
/pricing
  └─ [Choisir un plan] → POST /api/checkout/session
       └─ redirect vers session.url (Stripe Checkout)
            ├─ Succès → redirect /checkout/success?session_id=xxx
            │    └─ SuccessComponent : polling GET /api/user/plan (max 10s)
            │         └─ Afficher "Abonnement activé !" + redirect /dashboard
            └─ Annulation → redirect /pricing

/account/billing
  └─ [Gérer mon abonnement] → POST /api/portal/session
       └─ redirect vers portal_url (Stripe Customer Portal)
            └─ Retour → /account/billing
```

### Services Angular

```typescript
// payment.service.ts
@Injectable({ providedIn: 'root' })
export class PaymentService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = inject(API_BASE_URL);

  createCheckoutSession(priceId: string): Observable<{ url: string }> {
    return this.http.post<{ url: string }>(
      `${this.baseUrl}/checkout/session`,
      { priceId }
    );
  }

  createPortalSession(): Observable<{ url: string }> {
    return this.http.post<{ url: string }>(
      `${this.baseUrl}/portal/session`,
      {}
    );
  }

  pollUserPlan(maxAttempts = 10): Observable<UserPlan> {
    return interval(1000).pipe(
      take(maxAttempts),
      switchMap(() => this.http.get<{ plan: UserPlan }>(`${this.baseUrl}/user/me`)),
      map(r => r.plan),
      first(plan => plan !== 'FREE'),
      timeout(12000)
    );
  }
}
```

### Guard plan requis

```typescript
// plan-required.guard.ts
export const planRequiredGuard = (minPlan: UserPlan): CanActivateFn =>
  () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    const userPlan = auth.currentUser()?.plan ?? 'FREE';

    if (planRank(userPlan) >= planRank(minPlan)) return true;

    router.navigate(['/pricing'], {
      queryParams: { required: minPlan, returnUrl: router.url }
    });
    return false;
  };

// Dans app.routes.ts :
{ path: 'tools/ocr', canActivate: [planRequiredGuard('PRO_PLUS')], ... }
```

### Composants à créer

| Composant | Route | Description |
|-----------|-------|-------------|
| `PricingPageComponent` | `/pricing` | Tableau comparatif + CTA Checkout |
| `CheckoutSuccessComponent` | `/checkout/success` | Animation + polling plan |
| `BillingPageComponent` | `/account/billing` | Résumé abonnement + bouton portail |
| `PlanBadgeComponent` | Partout | Badge `FREE / PRO / PRO+` dans le header |
| `UpgradeDialogComponent` | Dialog | Overlay "Passez PRO" quand quota dépassé |

---

## 11. Phase 7 — Facturation & conformité fiscale

### Stripe Tax (TVA automatique EU)

Activé au niveau de la Checkout Session (`automatic_tax.enabled: true`).
Stripe calcule la TVA selon l'adresse de facturation du client.

| Pays | Taux TVA | Notes |
|------|----------|-------|
| France | 20 % | Taux standard services numériques |
| Allemagne | 19 % | |
| Espagne | 21 % | |
| Belgique | 21 % | |
| Luxembourg | 17 % | Siège social Kovixel potentiel |
| Suisse | 8,1 % | Hors UE — règles OSS différentes |
| Entreprises UE (B2B) | 0 % | Auto-liquidation si numéro TVA valide |

**Configuration Stripe Dashboard :**
- Activer Stripe Tax dans les paramètres
- Définir l'origine fiscale (adresse du siège Kovixel)
- Activer la collecte du numéro de TVA intracommunautaire pour les clients B2B

### Données RGPD dans `kovixel_invoices`

- Conserver les factures **10 ans** (obligation légale comptable)
- `invoice_url` et `invoice_pdf` pointent vers Stripe — données card jamais stockées
- Droit à l'oubli : anonymiser `user_id` → `NULL` (conserver la facture, supprimer l'identifiant)

### Mentions légales obligatoires (page /pricing)

- Prix TTC affichés pour les particuliers, HT pour les pros
- Conditions Générales de Vente (CGV) — lien obligatoire avant paiement
- Politique de remboursement : 14 jours droit de rétractation (Directive EU 2011/83)
- "L'abonnement se renouvelle automatiquement. Annulable à tout moment."

---

## 12. Phase 8 — Monitoring & alertes

### Métriques Micrometer

```java
@Component
@RequiredArgsConstructor
public class PaymentMetrics {

    private final MeterRegistry registry;

    public void recordCheckoutCreated(String plan) {
        registry.counter("kovixel.payment.checkout.created",
            "plan", plan).increment();
    }

    public void recordSubscriptionActivated(String plan, String interval) {
        registry.counter("kovixel.payment.subscription.activated",
            "plan", plan, "interval", interval).increment();
    }

    public void recordPaymentFailed(String plan) {
        registry.counter("kovixel.payment.failed",
            "plan", plan).increment();
    }

    public void recordWebhookProcessed(String eventType, boolean success) {
        registry.counter("kovixel.webhook.processed",
            "type", eventType,
            "success", String.valueOf(success)).increment();
    }

    public Timer.Sample startWebhookTimer() {
        return Timer.start(registry);
    }

    public void stopWebhookTimer(Timer.Sample sample, String eventType) {
        sample.stop(registry.timer("kovixel.webhook.duration", "type", eventType));
    }
}
```

### KPIs Grafana

| Métrique | Alerte | Seuil |
|----------|--------|-------|
| `kovixel.payment.checkout.created` / h | Chute soudaine | < 50 % de la moyenne J-7 |
| `kovixel.payment.subscription.activated` | Taux conversion < 2 % | Sur 24h glissantes |
| `kovixel.payment.failed` | Pic d'échecs | > 5 % des transactions |
| `kovixel.webhook.duration` p99 | Lenteur | > 2 s |
| `kovixel.webhook.processed{success=false}` | Erreur webhook | > 0 sur 5 min |
| MRR (calculé) | Chute MRR | > 10 % en 24h |

### Alertes Slack (AlertManager)

```yaml
# alerting_rules.yml
groups:
  - name: payment
    rules:
      - alert: PaymentWebhookErrors
        expr: rate(kovixel_webhook_processed_total{success="false"}[5m]) > 0
        for: 2m
        labels:
          severity: critical
          channel: "#alerts-paiement"
        annotations:
          summary: "Erreurs webhook Stripe détectées"
          description: "{{ $value }} erreurs/s sur les webhooks Stripe"

      - alert: HighPaymentFailureRate
        expr: |
          rate(kovixel_payment_failed_total[1h])
          / rate(kovixel_payment_checkout_created_total[1h]) > 0.05
        for: 10m
        labels:
          severity: warning
          channel: "#alerts-paiement"
```

---

## 13. Sécurité & conformité PCI DSS

### Niveau de conformité

| Scénario | Niveau PCI DSS | Questionnaire |
|----------|---------------|---------------|
| Kovixel avec Stripe Checkout hébergé | **SAQ-A** | ~22 questions |
| Kovixel avec formulaire de carte propre | SAQ-D | ~300 questions + audit externe |

**Kovixel utilise Stripe Checkout hébergé → PCI DSS SAQ-A uniquement.**
Aucune donnée de carte ne touche les serveurs Kovixel.

### Vérification signature webhook

```java
// Dans WebhookController — NE JAMAIS sauter cette étape
Event event = Webhook.constructEvent(
    payload,          // corps brut — NE PAS parser en JSON avant
    sigHeader,        // header "Stripe-Signature"
    webhookSecret     // depuis env STRIPE_WEBHOOK_SECRET
);
// Si SignatureVerificationException → HTTP 400 (ne pas retry)
```

### Mesures complémentaires

| Mesure | Implémentation |
|--------|---------------|
| HTTPS obligatoire | HSTS en-tête, redirect HTTP→HTTPS |
| Idempotence webhook | Table `kovixel_payment_events` + contrainte UNIQUE |
| Pas de logging des données sensibles | `stripe_secret_key` jamais dans les logs |
| Rate limiting endpoint checkout | 5 req/min par user (Spring Security + Redis) |
| Audit trail | Chaque changement de plan loggé dans `kovixel_audit_log` |
| Secrets gestion | Variables d'env ou Vault — jamais dans le code |

---

## 14. Stratégie de tests

### Tests unitaires

| Classe | Ce qui est testé |
|--------|----------------|
| `WebhookDispatcher` | Idempotence (doublon ignoré), routing événements |
| `SubscriptionService` | Upgrade, downgrade, grace period |
| `GracePeriodScheduler` | Downgrade des abonnements expirés |
| `CheckoutController` | Validation `priceId`, customer existant réutilisé |
| `StripeSignatureFilter` | Rejet requêtes sans signature valide |

### Infrastructure de test (stripe-mock)

```yaml
# docker-compose.test.yml
services:
  stripe-mock:
    image: stripe/stripe-mock:latest
    ports:
      - "12111:12111"
    environment:
      STRIPE_MOCK_PORT: "12111"
```

```java
// StripeTestConfig.java (profil "test")
@TestConfiguration
@Profile("test")
public class StripeTestConfig {
    @PostConstruct
    public void useStripeMock() {
        Stripe.overrideApiBase("http://localhost:12111");
        Stripe.apiKey = "sk_test_123"; // valeur bidon pour stripe-mock
    }
}
```

### Scénarios de test end-to-end

| Scénario | Carte test Stripe | Résultat attendu |
|----------|------------------|-----------------|
| Paiement réussi | `4242 4242 4242 4242` | Plan upgradé via webhook |
| Carte refusée | `4000 0000 0000 9995` | Checkout error, plan inchangé |
| 3DS requis | `4000 0027 6000 3184` | Redirection 3DS, plan upgradé après auth |
| Paiement en échec (dunning) | `4000 0000 0000 0341` | `past_due`, grace period activée |
| Abonnement annulé | Via Customer Portal | Downgrade FREE webhook |
| Essai expiré (14j) | — | Email J−3 + downgrade si pas de CB |
| Doublon webhook | Même `event_id` × 2 | Second appel ignoré silencieusement |

### Commandes utiles

```bash
# Lancer stripe-mock
docker compose -f docker-compose.test.yml up stripe-mock

# Écouter les webhooks en local (Stripe CLI)
stripe listen --forward-to localhost:8080/api/webhook/stripe

# Déclencher un événement manuellement
stripe trigger checkout.session.completed
stripe trigger invoice.payment_failed
stripe trigger customer.subscription.trial_will_end
```

---

## 15. Variables d'environnement

| Variable | Description | Exemple |
|----------|-------------|---------|
| `STRIPE_SECRET_KEY` | Clé secrète Stripe (live ou test) | `sk_live_...` |
| `STRIPE_WEBHOOK_SECRET` | Secret de signature webhook | `whsec_...` |
| `STRIPE_PRICE_PRO_MONTHLY` | Price ID PRO mensuel | `price_1PxB...` |
| `STRIPE_PRICE_PRO_YEARLY` | Price ID PRO annuel | `price_1PxC...` |
| `STRIPE_PRICE_PRO_PLUS_MONTHLY` | Price ID PRO+ mensuel | `price_1PxD...` |
| `STRIPE_PRICE_PRO_PLUS_YEARLY` | Price ID PRO+ annuel | `price_1PxE...` |
| `STRIPE_PRICE_TEAM_MONTHLY` | Price ID TEAM mensuel / user | `price_1PxF...` |
| `STRIPE_PRICE_TEAM_YEARLY` | Price ID TEAM annuel / user | `price_1PxG...` |
| `APP_BASE_URL` | URL publique de l'application | `https://kovixel.com` |

**Ne jamais commiter ces variables dans le dépôt git.**  
Utiliser `.env.local` (développement) ou un gestionnaire de secrets (production).

---

## 16. Checklist mise en production

### Stripe Dashboard

- [ ] Créer les Produits et Prix en mode **live** (répéter les IDs dans les env vars)
- [ ] Activer **Stripe Tax** et renseigner l'adresse du siège social
- [ ] Configurer le **Customer Portal** (logo, couleurs, options)
- [ ] Activer la **collection du numéro de TVA** pour les clients B2B
- [ ] Configurer le calendrier de **dunning** (J+3, J+5, J+7)
- [ ] Vérifier les emails automatiques Stripe (échec, reçu, essai)
- [ ] Enregistrer le endpoint webhook production (`/api/webhook/stripe`) dans le Dashboard
- [ ] Copier le `STRIPE_WEBHOOK_SECRET` du Dashboard dans les secrets de production

### Backend

- [ ] Flyway migrations V48, V49, V50 exécutées sans erreur
- [ ] `STRIPE_SECRET_KEY` en live injecté via le gestionnaire de secrets
- [ ] Endpoint `/api/webhook/stripe` exclu du filtre JWT dans `SecurityFilterChain`
- [ ] `GracePeriodScheduler` activé (Spring `@EnableScheduling`)
- [ ] Logs de paiement filtrés (aucune donnée sensible exposée)
- [ ] Rate limiting activé sur `/api/checkout/session`
- [ ] Tests d'intégration stripe-mock verts en CI

### Frontend

- [ ] `environment.prod.ts` pointe vers l'API de production
- [ ] Page `/pricing` : mention CGV + politique de remboursement visible
- [ ] `CheckoutSuccessComponent` : polling robuste avec timeout et état d'erreur
- [ ] `PlanBadgeComponent` réactif aux changements de plan (signal Angular)
- [ ] Test manuel du flux complet avec une carte `4242 4242 4242 4242` en mode test

### Monitoring

- [ ] Dashboard Grafana `payment-overview` créé et partagé (#team-tech)
- [ ] Alertes AlertManager configurées et testées (webhook errors, payment failures)
- [ ] Runbook "Incident paiement" rédigé dans la documentation interne
- [ ] Slack `#alerts-paiement` connecté à AlertManager
- [ ] MRR calculé et visible dans Stripe Dashboard + Grafana

---

*Feuille de route générée le 2026-06-24 — Version 1.0*
