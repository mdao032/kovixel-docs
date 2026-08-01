# Roadmap — Authentification & Sécurité des Sessions

> **Kovixel** · Spring Boot 3.4.3 + Angular 18 · Juin 2026
>
> Objectif : passer d'un système JWT minimaliste à une infrastructure d'authentification de niveau production — session sécurisée, OAuth2 multi-provider (Google + Apple + Microsoft), protection avancée des comptes.

---

## 1. État des Lieux

### 1.1 Ce qui existe

| Composant | Fichier | Ce qu'il fait |
|-----------|---------|--------------|
| `AuthController` | `user/controller/AuthController.java` | `POST /register` + `POST /login` uniquement |
| `AuthService` | `user/service/AuthService.java` | Encode mdp, vérifie, émet JWT |
| `JwtService` | `common/security/JwtService.java` | Génération/validation HS256, 24h |
| `JwtAuthFilter` | `common/security/JwtAuthFilter.java` | Bearer token → SecurityContext |
| `SecurityConfig` | `common/security/SecurityConfig.java` | Stateless, BCrypt, CORS |
| `LoginComponent` | `features/auth/login/login.component.ts` | Formulaire + bouton Google (stub) |
| `RegisterComponent` | `features/auth/register/register.component.ts` | Formulaire email/mdp |
| `AuthService` (Angular) | `core/services/auth.service.ts` | JWT dans `localStorage`, decode maison |

### 1.2 Vulnérabilités & Lacunes Critiques

#### Sécurité JWT

| Problème | Sévérité | Détail |
|----------|----------|--------|
| Secret par défaut en dur dans le code | **Critique** | `@Value("${jwt.secret:404E63...}")` — si la var d'env n'est pas définie, le secret est connu de tous |
| Pas de `try/catch` dans `JwtAuthFilter` | **Haute** | Un token malformé (JWT corrompu ou encodé en base64 invalide) lève une exception non catchée → HTTP 500 au lieu de 401 |
| JWT stocké dans `localStorage` | **Haute** | Vulnérable à toute injection XSS — un script injecté peut extraire le token |
| Durée de vie 24h sans révocation | **Haute** | Un token volé reste valide 24h ; aucun mécanisme de logout côté serveur |
| Pas de claim `jti` | **Moyenne** | Impossible d'invalider un token individuel |
| Pas de claim `iss` | **Basse** | Facilite le risque de token replay entre services |
| HS256 symétrique | **Basse** | Partageable pour valider ET signer — RS256 préférable en multi-service |

#### Gestion des comptes

| Problème | Sévérité | Détail |
|----------|----------|--------|
| Pas de rate limiting sur `/login` | **Haute** | Brute force d'identifiants sans limite |
| Pas de verrouillage de compte | **Haute** | Attaque par dictionnaire sans protection |
| Pas de vérification e-mail | **Haute** | Compte activé immédiatement sans confirmer l'adresse |
| Pas de réinitialisation de mot de passe | **Haute** | `/forgot-password` lié dans le UI mais inexistant |
| Mdp minimum 6 chars (backend) vs 8 (frontend) | **Moyenne** | Incohérence — un mot de passe de 6 chars passe l'API mais pas le formulaire |
| Email non normalisé | **Basse** | `user@Example.COM` et `user@example.com` créent deux comptes distincts |
| `register()` sans `@Transactional` | **Basse** | Risque de demi-enregistrement si erreur entre `save()` et génération du token |

#### Fonctionnalités manquantes

| Fonctionnalité | Impact |
|----------------|--------|
| Refresh token | Nécessaire pour sessions longues sans risque de token 24h |
| Logout serveur | Impossible d'invalider une session active |
| OAuth2 Google (flux réel) | Bouton stub uniquement |
| OAuth2 Apple | Absent |
| OAuth2 Microsoft | Absent |
| Profil utilisateur | Pas de `firstName`, `lastName`, `provider`, `providerId` |
| Deux facteurs (2FA) | Absent |
| Audit log auth | Aucune traçabilité des connexions |
| Session management | Aucun listing des sessions actives |

---

## 2. Architecture Cible

### 2.1 Stratégie de Session

```
┌─────────────────────────────────────────────────────────────────┐
│  Access Token  : JWT HS256 · 15 minutes · stocké EN MÉMOIRE     │
│  Refresh Token : opaque UUID · 7 jours · HttpOnly SameSite=Strict│
│  Stockage RT   : Redis (TTL) + table PostgreSQL (audit/listing)  │
│  Révocation AT : Redis blacklist (jti → expiry)                  │
│  Révocation RT : Redis DEL + table revoked_at                    │
└─────────────────────────────────────────────────────────────────┘
```

**Principes directeurs :**
- L'Access Token (AT) a une durée courte (15 min) → l'impact d'un vol est limité
- Le Refresh Token (RT) ne passe jamais dans les headers ni dans le JS — uniquement cookie HttpOnly
- À chaque refresh, le RT est roté (l'ancien est révoqué, un nouveau est émis)
- Logout révoque le RT en Redis ET inscrit le jti de l'AT en blacklist jusqu'à son expiry

### 2.2 Flux OAuth2 Recommandé (Hybrid Flow)

```
Frontend                     Backend                    Provider (Google/Apple/MS)
   │                            │                              │
   │  Clique "Se connecter"      │                              │
   │──────────────────────────→ │                              │
   │                            │                              │
   │← Redirect to provider ──── │                              │
   │                            │                              │
   │  ←──────────────────────── Consent/Login ────────────────→│
   │  ←─────────────────────────────────── id_token / code ────│
   │                            │                              │
   │  POST /auth/oauth2/google  │                              │
   │  { idToken: "..." }        │                              │
   │──────────────────────────→ │                              │
   │                            │  Validate id_token (JWKS)   │
   │                            │──────────────────────────── →│
   │                            │← Email, sub, name ────────── │
   │                            │                              │
   │                            │  Upsert user + issue JWT+RT  │
   │← { token } + [RT cookie] ──│                              │
```

Pour Google : Google Identity Services (`google.accounts.id`) → `credential` (id_token) → `POST /auth/oauth2/google`
Pour Apple : Sign In with Apple JS SDK → `authorization.id_token` → `POST /auth/oauth2/apple`
Pour Microsoft : MSAL.js → `idToken` → `POST /auth/oauth2/microsoft`

---

## 3. Migrations DB

### V23 — Extensions de la table `kovixel_users`

```sql
-- Champs de profil
ALTER TABLE kovixel_users
  ADD COLUMN IF NOT EXISTS first_name        VARCHAR(100),
  ADD COLUMN IF NOT EXISTS last_name         VARCHAR(100),
  ADD COLUMN IF NOT EXISTS updated_at        TIMESTAMP,

-- Sécurité & état du compte
  ADD COLUMN IF NOT EXISTS email_verified    BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS account_locked    BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS failed_attempts   INT     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_failed_at    TIMESTAMP,
  ADD COLUMN IF NOT EXISTS last_login_at     TIMESTAMP,
  ADD COLUMN IF NOT EXISTS email_verify_token VARCHAR(64),
  ADD COLUMN IF NOT EXISTS email_verify_exp   TIMESTAMP,

-- OAuth2
  ADD COLUMN IF NOT EXISTS provider          VARCHAR(20) NOT NULL DEFAULT 'LOCAL',
  ADD COLUMN IF NOT EXISTS provider_id       VARCHAR(255);

-- Le mot de passe devient nullable : les comptes OAuth n'ont pas de mot de passe local
ALTER TABLE kovixel_users ALTER COLUMN password DROP NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_provider      ON kovixel_users (provider, provider_id);
CREATE INDEX IF NOT EXISTS idx_users_verify_token  ON kovixel_users (email_verify_token);
```

**Enum `AuthProvider`** : `LOCAL`, `GOOGLE`, `APPLE`, `MICROSOFT`

### V24 — Table `refresh_tokens`

```sql
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id          UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     BIGINT    NOT NULL REFERENCES kovixel_users(id) ON DELETE CASCADE,
  token_hash  CHAR(64)  NOT NULL UNIQUE,       -- SHA-256(raw_token) hex
  jti_at      VARCHAR(36),                      -- jti du dernier AT émis avec ce RT
  issued_at   TIMESTAMP NOT NULL,
  expires_at  TIMESTAMP NOT NULL,
  revoked_at  TIMESTAMP,
  device_hint VARCHAR(255),                     -- User-Agent tronqué
  ip_address  VARCHAR(45)
);

CREATE INDEX IF NOT EXISTS idx_rt_user_id    ON refresh_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_rt_expires    ON refresh_tokens (expires_at) WHERE revoked_at IS NULL;
```

---

## 4. Backend — Plan d'Implémentation

### Phase 1 — Fondations Sécurité (Priorité absolue)

#### 4.1 JwtService — Hardening

```java
// Remplacer le défaut hardcodé :
@Value("${jwt.secret}")          // PAS de valeur par défaut — fail-fast si absente
private String secretKey;

// Réduire la durée à 15 minutes :
@Value("${jwt.expiration:900000}")       // 15 min
private long jwtExpiration;

@Value("${jwt.refresh-expiration:604800000}") // 7 jours
private long jwtRefreshExpiration;

// Ajouter jti + iss + sub dans les claims :
private String buildToken(...) {
    return Jwts.builder()
        .id(UUID.randomUUID().toString())          // jti — identifiant unique du token
        .issuer("kovixel")                          // iss
        .subject(userDetails.getUsername())         // sub = email
        .claims(extraClaims)
        .issuedAt(new Date())
        .expiration(new Date(System.currentTimeMillis() + expiration))
        .signWith(getSignInKey(), Jwts.SIG.HS256)
        .compact();
}

// Exposer le jti pour la blacklist :
public String extractJti(String token) { return extractClaim(token, Claims::getId); }
public String extractIssuer(String token) { return extractClaim(token, Claims::getIssuer); }
```

#### 4.2 JwtAuthFilter — Protection contre les tokens invalides

```java
@Override
protected void doFilterInternal(...) {
    final String authHeader = request.getHeader("Authorization");
    if (authHeader == null || !authHeader.startsWith("Bearer ")) {
        filterChain.doFilter(request, response);
        return;
    }
    final String jwt = authHeader.substring(7);
    try {
        final String userEmail = jwtService.extractUsername(jwt);

        // Vérifier la blacklist Redis (logout / révocation)
        if (tokenBlacklistService.isBlacklisted(jwtService.extractJti(jwt))) {
            response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Token révoqué");
            return;
        }

        if (userEmail != null && SecurityContextHolder.getContext().getAuthentication() == null) {
            UserDetails userDetails = userDetailsService.loadUserByUsername(userEmail);
            if (jwtService.isTokenValid(jwt, userDetails)) {
                // ... set authentication
            }
        }
    } catch (ExpiredJwtException e) {
        // Token expiré → 401 propre (le client doit refresh)
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType("application/json;charset=UTF-8");
        response.getOutputStream().write("{\"errorCode\":\"TOKEN_EXPIRED\",\"message\":\"Token expiré\"}".getBytes());
        return;
    } catch (JwtException | IllegalArgumentException e) {
        // Token malformé ou signature invalide → 401
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType("application/json;charset=UTF-8");
        response.getOutputStream().write("{\"errorCode\":\"TOKEN_INVALID\",\"message\":\"Token invalide\"}".getBytes());
        return;
    }
    filterChain.doFilter(request, response);
}
```

#### 4.3 AuthService — Robustesse

```java
@Transactional                    // Manquant actuellement
public AuthResponse register(RegisterRequest request) {
    String email = request.getEmail().toLowerCase().trim();  // Normalisation

    if (userRepository.findByEmail(email).isPresent())
        throw new KovixelException(ErrorCode.CONFLICT, HttpStatus.CONFLICT,
                "Un compte existe déjà avec cet email");

    User user = User.builder()
        .email(email)
        .password(passwordEncoder.encode(request.getPassword()))
        .firstName(request.getFirstName())
        .lastName(request.getLastName())
        .role(Role.USER)
        .provider(AuthProvider.LOCAL)
        .emailVerified(false)     // Nécessite vérification
        .build();

    userRepository.save(user);
    emailVerificationService.sendVerificationEmail(user);   // Phase 4

    // Émettre AT + RT
    return issueTokenPair(user);
}

@Transactional
public AuthResponse login(LoginRequest request) {
    String email = request.getEmail().toLowerCase().trim();

    User user = userRepository.findByEmail(email)
        .orElseThrow(() -> new BadCredentialsException("Identifiants incorrects"));

    // Vérifier le verrouillage
    if (user.isAccountLocked())
        throw new KovixelException(ErrorCode.ACCOUNT_LOCKED, HttpStatus.FORBIDDEN,
                "Compte temporairement verrouillé. Réessayez dans 15 minutes.");

    // Vérifier le mot de passe
    if (!passwordEncoder.matches(request.getPassword(), user.getPassword())) {
        accountLockService.recordFailedAttempt(user);    // Phase 1
        throw new BadCredentialsException("Identifiants incorrects");
    }

    // Réinitialiser les tentatives après succès
    accountLockService.resetFailedAttempts(user);

    // Mettre à jour lastLoginAt
    user.setLastLoginAt(LocalDateTime.now());
    userRepository.save(user);

    return issueTokenPair(user);
}
```

#### 4.4 AccountLockService (nouveau)

```java
@Service
public class AccountLockService {
    private static final int MAX_ATTEMPTS = 5;
    private static final Duration LOCK_DURATION = Duration.ofMinutes(15);

    public void recordFailedAttempt(User user) {
        user.setFailedAttempts(user.getFailedAttempts() + 1);
        user.setLastFailedAt(LocalDateTime.now());
        if (user.getFailedAttempts() >= MAX_ATTEMPTS) {
            user.setAccountLocked(true);
            // Déverrouillage automatique : scheduled task ou vérification à la connexion
        }
        userRepository.save(user);
    }

    public boolean isLockExpired(User user) {
        if (!user.isAccountLocked()) return false;
        return user.getLastFailedAt() != null
            && user.getLastFailedAt().plus(LOCK_DURATION).isBefore(LocalDateTime.now());
    }
}
```

#### 4.5 Rate Limiting sur les endpoints Auth (Bucket4j + Redis)

```yaml
# application.yml
bucket4j:
  filters:
    - cache-name: rate-limit-auth
      url: /api/v1/auth/login.*
      rate-limits:
        - cache-key: "getRemoteAddr()"
          bandwidths:
            - capacity: 5
              time: 1
              unit: minutes
              refill-speed: intervally
```

Ou implémentation manuelle avec `RedisTemplate` + clé `ratelimit:auth:{ip}:{minute}`.

### Phase 2 — Refresh Tokens & Session Sécurisée

#### 4.6 RefreshTokenService

```java
@Service
public class RefreshTokenService {
    private static final Duration RT_TTL = Duration.ofDays(7);

    // Émet un refresh token opaque, stocke son hash SHA-256 en Redis + DB
    public String issueRefreshToken(User user, HttpServletRequest request) {
        String raw = UUID.randomUUID().toString().replace("-", "") +
                     UUID.randomUUID().toString().replace("-", "");   // 64 chars
        String hash = sha256Hex(raw);

        RefreshToken entity = RefreshToken.builder()
            .userId(user.getId())
            .tokenHash(hash)
            .issuedAt(Instant.now())
            .expiresAt(Instant.now().plus(RT_TTL))
            .deviceHint(truncateUserAgent(request.getHeader("User-Agent")))
            .ipAddress(resolveIp(request))
            .build();

        refreshTokenRepository.save(entity);

        // Redis : hash → userId, TTL 7 jours
        String key = "rt:" + hash;
        redisTemplate.opsForValue().set(key, String.valueOf(user.getId()), RT_TTL);

        return raw;    // Retourné en cookie HttpOnly — JAMAIS dans le body JSON
    }

    // Rotation : révoque l'ancien, émet un nouveau
    public String rotate(String rawOldToken, HttpServletRequest request) {
        String hash = sha256Hex(rawOldToken);
        RefreshToken old = refreshTokenRepository.findByTokenHash(hash)
            .orElseThrow(() -> new KovixelException(ErrorCode.INVALID_TOKEN, ...));

        if (old.getRevokedAt() != null || old.getExpiresAt().isBefore(Instant.now()))
            throw new KovixelException(ErrorCode.INVALID_TOKEN, ...);

        old.setRevokedAt(Instant.now());
        refreshTokenRepository.save(old);
        redisTemplate.delete("rt:" + hash);

        User user = userRepository.findById(old.getUserId()).orElseThrow();
        return issueRefreshToken(user, request);
    }

    // Révocation complète (logout)
    public void revokeAll(Long userId) {
        refreshTokenRepository.revokeAllByUserId(userId);
        // Purge Redis : SCAN pattern rt:* puis DEL pour chaque token de l'user
        // En pratique : les Redis keys expirent naturellement — la DB est l'autorité
    }
}
```

#### 4.7 TokenBlacklistService (révocation AT)

```java
@Service
public class TokenBlacklistService {
    // Blacklist Redis : clé "jbl:{jti}" avec TTL = remaining time du token
    public void blacklist(String jti, long remainingTtlMs) {
        redisTemplate.opsForValue().set("jbl:" + jti, "1",
                Duration.ofMillis(remainingTtlMs));
    }

    public boolean isBlacklisted(String jti) {
        return Boolean.TRUE.equals(redisTemplate.hasKey("jbl:" + jti));
    }
}
```

#### 4.8 AuthController — Nouveaux endpoints

```java
// POST /api/v1/auth/refresh
// Corps vide — lit le RT dans le cookie HttpOnly
@PostMapping("/refresh")
public ResponseEntity<AuthResponse> refresh(
        @CookieValue("kovixel_rt") String refreshToken,
        HttpServletRequest request,
        HttpServletResponse response) {
    return authService.refresh(refreshToken, request, response);
}

// POST /api/v1/auth/logout
@PostMapping("/logout")
public ResponseEntity<Void> logout(
        @CookieValue(value = "kovixel_rt", required = false) String refreshToken,
        @AuthenticationPrincipal UserDetails userDetails,
        @RequestHeader("Authorization") String authHeader) {
    authService.logout(refreshToken, authHeader);
    // Effacer le cookie RT
    ResponseCookie expired = ResponseCookie.from("kovixel_rt", "")
        .httpOnly(true).secure(true).sameSite("Strict")
        .path("/api/v1/auth").maxAge(0).build();
    response.addHeader(HttpHeaders.SET_COOKIE, expired.toString());
    return ResponseEntity.noContent().build();
}

// GET /api/v1/auth/me
@GetMapping("/me")
public ResponseEntity<UserResponse> me(@AuthenticationPrincipal UserDetails ud) {
    return ResponseEntity.ok(userService.getCurrentUser(ud.getUsername()));
}

// GET /api/v1/auth/sessions
@GetMapping("/sessions")
public ResponseEntity<List<SessionResponse>> sessions(@AuthenticationPrincipal UserDetails ud) {
    return ResponseEntity.ok(authService.getActiveSessions(ud.getUsername()));
}

// DELETE /api/v1/auth/sessions/{id}
@DeleteMapping("/sessions/{id}")
public ResponseEntity<Void> revokeSession(@PathVariable UUID id, ...) { ... }
```

#### 4.9 Cookie HttpOnly pour le Refresh Token

```java
// Dans issueTokenPair() :
ResponseCookie rtCookie = ResponseCookie.from("kovixel_rt", rawRefreshToken)
    .httpOnly(true)
    .secure(true)           // HTTPS uniquement en prod
    .sameSite("Strict")     // Protection CSRF
    .path("/api/v1/auth")   // Scope étroit — n'est envoyé qu'aux endpoints /auth
    .maxAge(Duration.ofDays(7))
    .build();
response.addHeader(HttpHeaders.SET_COOKIE, rtCookie.toString());
```

### Phase 3 — OAuth2 (Google + Apple + Microsoft)

#### 4.10 Dépendances à ajouter (pom.xml)

```xml
<!-- Validation des JWT providers (Google, Apple, Microsoft JWKS) -->
<dependency>
  <groupId>com.nimbusds</groupId>
  <artifactId>nimbus-jose-jwt</artifactId>
  <version>9.40</version>
</dependency>
<!-- OU Spring Security OAuth2 Resource Server (inclut JWKS validation) -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
</dependency>
```

#### 4.11 OAuthTokenValidator — Validation des id_token providers

```java
@Service
public class OAuthTokenValidator {

    // Google
    private static final String GOOGLE_JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs";
    private static final String GOOGLE_ISSUER_1 = "https://accounts.google.com";
    private static final String GOOGLE_ISSUER_2 = "accounts.google.com";

    // Apple
    private static final String APPLE_JWKS_URI  = "https://appleid.apple.com/auth/keys";
    private static final String APPLE_ISSUER     = "https://appleid.apple.com";

    // Microsoft (remplacer {tenantId} par "common" ou tenant spécifique)
    private static final String MS_JWKS_URI      = "https://login.microsoftonline.com/common/discovery/v2.0/keys";
    private static final String MS_ISSUER_PREFIX = "https://login.microsoftonline.com/";

    public OAuthUserInfo validateGoogle(String idToken, String expectedClientId) { ... }
    public OAuthUserInfo validateApple(String idToken, String expectedClientId) { ... }
    public OAuthUserInfo validateMicrosoft(String idToken, String expectedClientId) { ... }
}

// DTO résultat
public record OAuthUserInfo(
    String providerId,    // "sub" claim
    String email,
    String firstName,
    String lastName,
    boolean emailVerified
) {}
```

#### 4.12 OAuthService — Upsert utilisateur

```java
@Service
@Transactional
public class OAuthService {

    public AuthPair handleOAuthLogin(OAuthUserInfo info, AuthProvider provider,
                                     HttpServletRequest req, HttpServletResponse res) {
        String email = info.email().toLowerCase().trim();

        User user = userRepository.findByEmail(email).orElse(null);

        if (user == null) {
            // Nouvel utilisateur OAuth
            user = User.builder()
                .email(email)
                .firstName(info.firstName())
                .lastName(info.lastName())
                .role(Role.USER)
                .provider(provider)
                .providerId(info.providerId())
                .emailVerified(info.emailVerified())
                .build();
            userRepository.save(user);
        } else {
            // Utilisateur existant : link le provider si absent
            if (user.getProvider() == AuthProvider.LOCAL && user.getProviderId() == null) {
                user.setProvider(provider);
                user.setProviderId(info.providerId());
                user.setEmailVerified(true);   // Garanti par le provider
            }
            // Refuser si même email mais provider différent déjà lié
            else if (user.getProvider() != provider) {
                throw new KovixelException(ErrorCode.CONFLICT, HttpStatus.CONFLICT,
                    "Cet email est déjà associé à une connexion " + user.getProvider().name());
            }
        }

        user.setLastLoginAt(LocalDateTime.now());
        userRepository.save(user);
        return authService.issueTokenPair(user, req, res);
    }
}
```

#### 4.13 Endpoints OAuth2

```java
// POST /api/v1/auth/oauth2/google
@PostMapping("/oauth2/google")
public ResponseEntity<AuthResponse> googleLogin(
        @RequestBody @Valid OAuthLoginRequest req,   // { "idToken": "..." }
        HttpServletRequest request, HttpServletResponse response) {
    OAuthUserInfo info = oauthValidator.validateGoogle(
        req.idToken(), googleClientId);
    AuthPair pair = oauthService.handleOAuthLogin(info, AuthProvider.GOOGLE, request, response);
    return ResponseEntity.ok(new AuthResponse(pair.accessToken()));
}

// POST /api/v1/auth/oauth2/apple
@PostMapping("/oauth2/apple")
public ResponseEntity<AuthResponse> appleLogin(@RequestBody @Valid OAuthLoginRequest req, ...) {
    OAuthUserInfo info = oauthValidator.validateApple(req.idToken(), appleClientId);
    // Apple : le name n'est présent qu'au 1er login — le client doit le passer séparément
    AuthPair pair = oauthService.handleOAuthLogin(info, AuthProvider.APPLE, request, response);
    return ResponseEntity.ok(new AuthResponse(pair.accessToken()));
}

// POST /api/v1/auth/oauth2/microsoft
@PostMapping("/oauth2/microsoft")
public ResponseEntity<AuthResponse> microsoftLogin(@RequestBody @Valid OAuthLoginRequest req, ...) {
    OAuthUserInfo info = oauthValidator.validateMicrosoft(req.idToken(), msClientId);
    AuthPair pair = oauthService.handleOAuthLogin(info, AuthProvider.MICROSOFT, request, response);
    return ResponseEntity.ok(new AuthResponse(pair.accessToken()));
}
```

#### 4.14 Configuration OAuth2 (application.yml)

```yaml
kovixel:
  auth:
    jwt:
      secret: ${JWT_SECRET}           # Obligatoire — pas de défaut
      expiration: 900000              # 15 minutes
      refresh-expiration: 604800000   # 7 jours

    oauth2:
      google:
        client-id: ${GOOGLE_CLIENT_ID}
      apple:
        client-id: ${APPLE_CLIENT_ID}         # = com.kovixel.app (Service ID)
        team-id: ${APPLE_TEAM_ID}
        key-id: ${APPLE_KEY_ID}
        private-key: ${APPLE_PRIVATE_KEY}     # Clé ES256 encodée base64
      microsoft:
        client-id: ${MICROSOFT_CLIENT_ID}
        tenant-id: ${MICROSOFT_TENANT_ID:common}
```

### Phase 4 — Vérification Email & Réinitialisation Mot de Passe

#### 4.15 EmailVerificationService

```java
// Génère un token UUID sécurisé (64 chars hex), le stocke sur l'entité User
// avec une expiry de 24h, puis envoie l'email via JavaMailSender.
// Le lien : https://app.kovixel.com/verify-email?token=...

// Endpoints :
// POST /api/v1/auth/verify-email/send    → renvoie l'email
// GET  /api/v1/auth/verify-email/confirm?token=...  → vérifie le token, active le compte
```

#### 4.16 PasswordResetService

```java
// Token UUID 32 chars, TTL 1h, stocké dans Redis (pas en DB pour éviter la pollution)
// Clé Redis : "pwreset:{token}" → userId, TTL 3600s

// Endpoints :
// POST /api/v1/auth/forgot-password      { "email": "..." }
// POST /api/v1/auth/reset-password       { "token": "...", "newPassword": "..." }

// Sécurité :
// - Même délai de réponse si email inexistant (éviter l'énumération)
// - Token à usage unique (DEL Redis après vérification)
// - Invalide tous les refresh tokens de l'utilisateur au reset
```

### Phase 5 — Double Authentification (2FA / TOTP)

Disponible uniquement pour les plans **PRO** et **ENTERPRISE**.

```
Entités : 
  User.twoFactorEnabled (boolean)
  User.twoFactorSecret  (String — TOTP secret AES-chiffré en DB)

Flow login avec 2FA :
  1. Vérification email+mdp → réponse { "twoFactorRequired": true, "challengeToken": "..." }
  2. Saisie code TOTP → POST /api/v1/auth/2fa/verify { "challengeToken": "...", "code": "..." }
  3. Émission AT+RT

Bibliothèque : aerogear-otp-java ou warrenstrange/google-authenticator
Backup codes : 10 codes usage unique, SHA-256, stockés en DB
```

---

## 5. Frontend — Plan d'Implémentation

### Phase 1 — Sécurité Token

#### 5.1 Suppression du localStorage pour le JWT

```typescript
// AVANT (vulnérable XSS) :
localStorage.setItem('kovixel_token', token);

// APRÈS (en mémoire — disparaît à la fermeture de l'onglet) :
// Dans AuthService :
private _accessToken = signal<string | null>(null);

// Pour survivre à F5 : utilise sessionStorage OU le cookie RT pour reissue au chargement
// Stratégie recommandée : au démarrage de l'app, appeler silently POST /auth/refresh
// Si le cookie RT est présent → nouveau AT en mémoire → utilisateur "restauré"
```

#### 5.2 HTTP Interceptor — Auto-refresh

```typescript
// core/interceptors/auth.interceptor.ts
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const http = inject(HttpClient);

  const token = auth.accessToken();
  if (!token) return next(req);

  const authReq = req.clone({ setHeaders: { Authorization: `Bearer ${token}` } });

  return next(authReq).pipe(
    catchError((err: HttpErrorResponse) => {
      if (err.status === 401 && err.error?.errorCode === 'TOKEN_EXPIRED') {
        // Tenter un refresh silencieux
        return auth.silentRefresh().pipe(
          switchMap(() => {
            const retried = req.clone({
              setHeaders: { Authorization: `Bearer ${auth.accessToken()}` }
            });
            return next(retried);
          }),
          catchError(() => {
            auth.logout();
            return throwError(() => err);
          })
        );
      }
      return throwError(() => err);
    })
  );
};
```

#### 5.3 AuthService — Refactoring complet

```typescript
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly _accessToken = signal<string | null>(null);
  readonly accessToken = this._accessToken.asReadonly();

  // Appel silencieux au démarrage pour restaurer la session depuis le cookie RT
  initSession(): Observable<void> {
    return this.http.post<AuthResponse>(`${this.base}/refresh`, {}).pipe(
      tap(res => this._handleToken(res.token)),
      catchError(() => { this._accessToken.set(null); return of(void 0); })
    );
  }

  silentRefresh(): Observable<void> {
    return this.http.post<AuthResponse>(`${this.base}/refresh`, {}).pipe(
      tap(res => this._handleToken(res.token)),
      map(() => void 0)
    );
  }

  logout(): void {
    this.http.post(`${this.base}/logout`, {}).subscribe(); // Révoque RT côté serveur
    this._accessToken.set(null);
    this.currentUser.set(null);
    this.router.navigate(['/login']);
  }
}
```

### Phase 2 — OAuth2 Buttons

#### 5.4 Google Identity Services

```typescript
// Charger le SDK une fois dans index.html ou via script dynamique
// <script src="https://accounts.google.com/gsi/client" async defer></script>

loginWithGoogle(): void {
  (window as any).google.accounts.id.initialize({
    client_id: environment.googleClientId,
    callback: (response: { credential: string }) => {
      this.authService.loginWithOAuth('google', response.credential).subscribe({
        next: () => this.router.navigateByUrl('/dashboard'),
        error: err => this.globalError.set(err?.error?.message ?? 'Erreur Google')
      });
    }
  });
  (window as any).google.accounts.id.prompt();
}
```

#### 5.5 Sign In with Apple

```typescript
// SDK : https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js
loginWithApple(): void {
  (window as any).AppleID.auth.init({
    clientId: environment.appleClientId,
    scope: 'name email',
    redirectURI: `${environment.appUrl}/auth/apple/callback`,
    usePopup: true
  });

  (window as any).AppleID.auth.signIn().then((res: any) => {
    const idToken = res.authorization.id_token;
    const firstName = res.user?.name?.firstName ?? '';
    const lastName  = res.user?.name?.lastName  ?? '';
    // Apple envoie le name SEULEMENT au 1er login
    this.authService.loginWithOAuth('apple', idToken, { firstName, lastName }).subscribe(...);
  });
}
```

#### 5.6 Microsoft (MSAL.js)

```typescript
// npm install @azure/msal-browser @azure/msal-angular
// Configuration MSAL dans app.config.ts

loginWithMicrosoft(): void {
  this.msalService.loginPopup({ scopes: ['openid', 'profile', 'email'] })
    .subscribe(result => {
      const idToken = result.idToken;
      this.authService.loginWithOAuth('microsoft', idToken).subscribe({
        next: () => this.router.navigateByUrl('/dashboard'),
        error: err => this.globalError.set(err?.error?.message ?? 'Erreur Microsoft')
      });
    });
}
```

#### 5.7 LoginComponent — UI finale

```
┌────────────────────────────────────────────┐
│  [Email]                                   │
│  [Mot de passe]                [Oublié ?]  │
│  [   Se connecter   ]                      │
│  ────────────── ou ──────────────          │
│  [G] Continuer avec Google                 │
│  [🍎] Continuer avec Apple                 │
│  [⊞] Continuer avec Microsoft              │
│  Pas encore de compte ? Créer un compte →  │
└────────────────────────────────────────────┘
```

### Phase 3 — Pages manquantes

| Route | Composant | Priorité |
|-------|-----------|----------|
| `/forgot-password` | `ForgotPasswordComponent` | Haute |
| `/reset-password?token=` | `ResetPasswordComponent` | Haute |
| `/verify-email?token=` | `VerifyEmailComponent` | Haute |
| `/settings/security` | `SecuritySettingsComponent` | Moyenne |
| `/settings/sessions` | `SessionsComponent` | Moyenne |

---

## 6. Sécurité des Sessions — Matrice

| Menace | Protection |
|--------|-----------|
| Vol de JWT (XSS) | AT en mémoire seulement (signal Angular) ; durée 15 min |
| Vol de Refresh Token | Cookie HttpOnly SameSite=Strict ; HTTPS uniquement |
| CSRF | SameSite=Strict sur le cookie RT ; token CSRF si nécessaire |
| Brute force login | Bucket4j : 5 tentatives/min/IP ; verrouillage compte : 5 échecs → 15 min |
| Token replay | jti unique + blacklist Redis au logout |
| Session hijacking | RT invalide si IP change drastiquement (heuristique optionnelle) |
| Account takeover | Vérification email obligatoire ; 2FA disponible PRO+ |
| Énumération d'emails | Délai constant sur forgot-password (même si email inexistant) |
| Tokens OAuth2 forgés | Validation JWKS (signature vérifiée côté serveur) |
| Tokens OAuth2 rejoués | Vérification `exp`, `aud`, `iss` claims obligatoire |

---

## 7. Ordre d'Implémentation

### Sprint 1 — Hardening immédiat (backend) ✦ 1-2 jours
1. `JwtService` : supprimer défaut secret, ajouter `jti`/`iss`, réduire expiry à 15 min
2. `JwtAuthFilter` : try/catch complet → 401 au lieu de 500
3. `AuthService.register()` : `@Transactional`, normalisation email, min password 8 chars
4. V23 migration : extensions `kovixel_users`
5. `AccountLockService` : 5 tentatives → 15 min lock
6. Rate limiting Bucket4j sur `/login` et `/register`

### Sprint 2 — Refresh Tokens (backend + frontend) ✦ 2-3 jours
7. V24 migration : table `refresh_tokens`
8. `RefreshTokenService` + `TokenBlacklistService`
9. Endpoints : `POST /refresh`, `POST /logout`, `GET /me`, `GET /sessions`
10. Cookie HttpOnly dans `AuthController`
11. Angular `AuthService` : token en mémoire + `initSession()` + `silentRefresh()`
12. HTTP Interceptor : auto-refresh sur 401 TOKEN_EXPIRED
13. `AppInitializer` : appel `initSession()` au démarrage (restaurer session depuis RT)

### Sprint 3 — OAuth2 Google (complet) ✦ 1-2 jours
14. `OAuthTokenValidator.validateGoogle()` via Nimbus JOSE JWT
15. `OAuthService.handleOAuthLogin()`
16. `POST /api/v1/auth/oauth2/google`
17. Angular : Google Identity Services dans `LoginComponent`

### Sprint 4 — OAuth2 Apple + Microsoft ✦ 2-3 jours
18. `OAuthTokenValidator.validateApple()` (complexité : client assertion ES256)
19. `OAuthTokenValidator.validateMicrosoft()`
20. Endpoints Apple + Microsoft
21. Angular : Sign In with Apple + MSAL.js

### Sprint 5 — Email & Mot de Passe ✦ 2 jours
22. `EmailService` (JavaMailSender + template HTML)
23. `EmailVerificationService` + endpoints
24. `PasswordResetService` + endpoints
25. Pages Angular : `ForgotPasswordComponent`, `ResetPasswordComponent`, `VerifyEmailComponent`

### Sprint 6 — 2FA & Observabilité ✦ 2-3 jours
26. TOTP 2FA (PRO/ENTERPRISE uniquement)
27. Auth events audit log
28. `GET /sessions` + révocation distante
29. `SecuritySettingsComponent`

---

## 8. Checklist de Conformité RGPD / Sécurité

- [ ] Données de session chiffrées au repos (PostgreSQL TDE ou column-level pour `refresh_tokens`)
- [ ] Logs d'authentification anonymisés (IP tronquée : `1.2.3.x`)
- [ ] Rétention des `refresh_tokens` révoqués : purge après 30 jours
- [ ] Rétention des `failed_login` events : 90 jours maximum
- [ ] Mention explicite des providers OAuth2 dans les CGU et politique de confidentialité
- [ ] Lien de déconnexion de tous les appareils (RGPD Art. 17 — droit à l'effacement)
- [ ] Export des données personnelles : inclure les sessions dans l'export RGPD

---

## 9. Variables d'Environnement Requises

```bash
# JWT
JWT_SECRET=<256-bit hex, jamais valeur par défaut>

# OAuth2 — Google
GOOGLE_CLIENT_ID=xxx.apps.googleusercontent.com

# OAuth2 — Apple
APPLE_CLIENT_ID=com.kovixel.app
APPLE_TEAM_ID=XXXXXXXXXX
APPLE_KEY_ID=XXXXXXXXXX
APPLE_PRIVATE_KEY=<base64 de la clé ES256 .p8>

# OAuth2 — Microsoft
MICROSOFT_CLIENT_ID=<UUID app Azure>
MICROSOFT_TENANT_ID=common  # ou tenant spécifique

# Email
SMTP_HOST=smtp.provider.com
SMTP_PORT=587
SMTP_USERNAME=noreply@kovixel.com
SMTP_PASSWORD=<mot de passe SMTP>
APP_BASE_URL=https://app.kovixel.com

# Redis (déjà présent)
REDIS_HOST=...
REDIS_PASSWORD=...
```

---

## 10. Références Techniques

| Sujet | Référence |
|-------|-----------|
| Nimbus JOSE JWT | https://connect2id.com/products/nimbus-jose-jwt |
| Google Identity Services | https://developers.google.com/identity/gsi/web |
| Sign In with Apple | https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_js |
| MSAL.js (Microsoft) | https://github.com/AzureAD/microsoft-authentication-library-for-js |
| Bucket4j (rate limiting) | https://github.com/bucket4j/bucket4j |
| Spring Security OAuth2 Resource Server | https://docs.spring.io/spring-security/reference/servlet/oauth2/resource-server/ |
| OWASP Authentication Cheat Sheet | https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html |
| OWASP JWT Security | https://cheatsheetseries.owasp.org/cheatsheets/JSON_Web_Token_for_Java_Cheat_Sheet.html |
