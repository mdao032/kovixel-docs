# Roadmap — Politique de Mot de Passe Robuste

> **Contexte** : Kovixel est un SaaS de traitement de documents potentiellement sensibles (contrats, factures, données RH). La politique de mot de passe est une ligne de défense critique, en particulier pour les comptes sans 2FA actif. Ce document suit les recommandations NIST SP 800-63B (2017, mis à jour 2024), OWASP ASVS v4.0, et les exigences RGPD.

---

## État actuel

| Élément | État |
|---|---|
| Longueur minimale | 8 caractères (`@Size(min=8)`) |
| Règles de complexité | Affichées dans l'UI mais **non appliquées** côté backend |
| Hachage | bcrypt (Spring Security — à vérifier : cost factor) |
| Rate limiting | ✅ `AuthRateLimitFilter` en place |
| Lockout compte | ✅ `AccountLockService` en place |
| 2FA | ✅ TOTP disponible |
| Historique mots de passe | ❌ Absent |
| Détection de compromission | ❌ Absent |
| Notification changement | ❌ Absente |
| Indicateur de force | ❌ Absent (UI affiche des règles statiques) |
| Réutilisation anciens MDP | ❌ Non contrôlée |
| Expiration forcée | ❌ Non implémentée (correct — voir §5) |

---

## 1. Politique de longueur et de complexité

### Recommandation : abandon des règles de complexité traditionnelles

Les règles "1 majuscule + 1 chiffre + 1 symbole" sont contre-productives :
- Elles poussent vers des patterns prévisibles : `Kovixel1!`, `Motdepasse2024@`
- Un dictionnaire d'attaque avec règles de mutation les casse en quelques minutes
- Elles rendent les passphrases (très sûres) moins utilisables

**NIST SP 800-63B §5.1.1 — Mémorized Secret Authenticators :**
> *"Verifiers SHOULD NOT impose other composition rules (e.g., requiring mixtures of different character types) on memorized secrets."*

### Règles cibles

| Règle | Valeur | Justification |
|---|---|---|
| Longueur minimale | **12 caractères** | Standard de facto post-2022, compromis sécurité/UX |
| Longueur maximale | **128 caractères** | Permet les passphrases longues, protège contre DoS bcrypt |
| Complexité obligatoire | **Aucune** | NIST, OWASP — longueur > complexité |
| Caractères autorisés | Tous (Unicode, espaces, emoji) | NIST §5.1.1 : ne pas restreindre le charset |
| Espaces | Autorisés, **non trimés** | Un espace en début/fin fait partie du mot de passe |
| Liste noire | **Oui** — voir §2 | Compense l'absence de règles de complexité |

### Implémentation backend

```java
// RegisterRequest.java / ChangePasswordRequest.java
@NotBlank
@Size(min = 12, max = 128, message = "Le mot de passe doit contenir entre 12 et 128 caractères")
@NotCommonPassword // annotation custom — voir §2
private String password;
```

### Implémentation frontend

Remplacer le texte statique par un **indicateur de force dynamique** (voir §6).  
Message d'aide : *"12 caractères minimum — une phrase de passe est idéale (ex: monchienadorteici)"*

---

## 2. Liste noire — Mots de passe communs et compromis

### 2a. Liste de mots de passe courants (local)

Bloquer les mots de passe les plus fréquents sans appel réseau.

**Implémentation :**
```
src/main/resources/security/common-passwords.txt  ← 10 000 lignes (SecList top-10k)
```

```java
@Component
public class CommonPasswordValidator implements ConstraintValidator<NotCommonPassword, String> {
    private Set<String> blacklist;

    @PostConstruct
    void load() throws IOException {
        try (var is = getClass().getResourceAsStream("/security/common-passwords.txt")) {
            blacklist = new BufferedReader(new InputStreamReader(is))
                .lines().collect(Collectors.toSet());
        }
    }

    @Override
    public boolean isValid(String value, ConstraintValidatorContext ctx) {
        return value == null || !blacklist.contains(value.toLowerCase());
    }
}
```

**Source :** [SecLists/Passwords/Common-Credentials/10-million-password-list-top-10000.txt](https://github.com/danielmiessler/SecLists)

### 2b. Détection de mots de passe compromis — Have I Been Pwned (optionnel, Phase 2)

L'API HIBP k-anonymity permet de vérifier si un mot de passe figure dans une fuite de données **sans transmettre le mot de passe en clair** :

```
SHA1(password) = "A94A8FE5CCB19BA61C4C0873D391E987982FBBD3"
Prefix envoyé  = "A94A8" (5 premiers chars)
HIBP renvoie   = tous les suffixes correspondants + compteurs
```

**Quand appeler :** à l'inscription et au changement de mot de passe, de façon asynchrone.  
**Si compromis :** avertir l'utilisateur sans bloquer (bloquer = UX trop agressive pour un premier check).  
**Dépendance :** appel réseau externe — prévoir timeout court (2s) et fallback silencieux.

```java
// HibpService.java
public boolean isCompromised(String password) {
    String sha1 = sha1Hex(password).toUpperCase();
    String prefix = sha1.substring(0, 5);
    String suffix = sha1.substring(5);
    // GET https://api.pwnedpasswords.com/range/{prefix}
    // Recherche suffix dans la réponse
}
```

---

## 3. Historique des mots de passe — Prévention de la réutilisation

### Faut-il bloquer la réutilisation des anciens mots de passe ?

**Oui**, avec nuance :

| Position | Argument |
|---|---|
| **Pour bloquer** | Un utilisateur compromis qui change de mot de passe ne doit pas revenir à l'ancien. Évite les cycles "Password1 → Password2 → Password1". |
| **Contre (excessif)** | Bloquer les 20 derniers MDP pousse à des incréments : `Kovixel2024` → `Kovixel2025`. |
| **NIST** | Recommande de vérifier contre les mots de passe précédemment utilisés **et** les mots de passe compromis. Pas de nombre précis imposé. |

**Recommandation : bloquer les 5 derniers mots de passe.**

C'est suffisant pour casser les cycles sans frustrer l'utilisateur légitime.

### Schéma de données

```sql
-- V_next__add_password_history.sql
CREATE TABLE password_history (
    id          BIGSERIAL PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hash        VARCHAR(60) NOT NULL,  -- bcrypt, jamais le MDP clair
    created_at  TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_pwhistory_user ON password_history(user_id, created_at DESC);
```

### Service

```java
@Service
public class PasswordHistoryService {
    // Vérifie si le nouveau MDP correspond à l'un des N derniers hashes
    public boolean isReused(User user, String rawPassword) {
        return repository.findLastN(user.getId(), 5).stream()
            .anyMatch(h -> passwordEncoder.matches(rawPassword, h.getHash()));
    }

    // À appeler après chaque changement de MDP réussi
    @Transactional
    public void record(User user, String newHash) {
        repository.save(new PasswordHistory(user, newHash));
        repository.deleteOldest(user.getId(), 5); // ne garder que les 5 derniers
    }
}
```

---

## 4. Processus de changement de mot de passe

### Règles de sécurité

1. **Exiger le mot de passe actuel** — même pour un utilisateur authentifié (protège contre les sessions volées).
2. **Invalider toutes les autres sessions** après changement — le refresh token actuel est renouvelé, les autres sont révoqués en Redis et en base.
3. **Vérifier l'historique** — appeler `PasswordHistoryService.isReused()` avant de valider.
4. **Envoyer une notification email** — alerte immédiate si le compte est compromis et que l'attaquant change le mot de passe.
5. **Logger l'événement** — dans `auth_events` avec IP + user-agent (sans le mot de passe).

### Flux complet

```
POST /api/v1/users/me/password
  { currentPassword, newPassword }
       │
       ├─ 1. Vérifier currentPassword (bcrypt.matches)
       ├─ 2. Valider newPassword (longueur, liste noire, historique)
       ├─ 3. Encoder et sauvegarder le nouveau hash
       ├─ 4. Enregistrer dans password_history
       ├─ 5. Révoquer tous les refresh tokens sauf le courant
       ├─ 6. Émettre AuthEvent PASSWORD_CHANGED (async)
       └─ 7. Envoyer email de notification (async)
```

### Cas comptes OAuth (Google, Microsoft)

Les utilisateurs OAuth n'ont pas de mot de passe. Si un utilisateur OAuth veut définir un mot de passe (pour activer la double connexion locale) :
- Endpoint dédié : `POST /api/v1/users/me/set-password` (sans `currentPassword`)
- Marquer `provider = LOCAL` ou introduire un champ `hasLocalPassword = true`
- Envoyer un email de confirmation

---

## 5. Expiration forcée du mot de passe

### Recommandation : NON à l'expiration périodique

**NIST SP 800-63B §5.1.1 :**
> *"Verifiers SHOULD NOT require that memorized secrets be changed arbitrarily (e.g., periodically)."*

**Pourquoi :** L'expiration forcée (ex: tous les 90 jours) génère :
- Des mots de passe faibles par fatigue : `Ete2024!` → `Automne2024!`
- Une fausse impression de sécurité
- De la friction inutile pour l'utilisateur

**Exception valide — forcer le changement si :**
- Le mot de passe figure dans une fuite détectée (HIBP)
- Compromission confirmée du compte
- Reset administrateur (ex: support client)
- Premier login après reset par email

Implémenter un champ `must_change_password BOOLEAN DEFAULT FALSE` sur l'entité `User`, vérifié au moment de l'émission du JWT.

---

## 6. Indicateur de force en temps réel (frontend)

Remplacer le texte statique par un vrai indicateur calculé côté client.

**Bibliothèque recommandée : [zxcvbn](https://github.com/zxcvbn-ts/zxcvbn)** (Dropbox, 400k downloads/semaine)
- Score 0–4 basé sur l'entropie réelle, pas des règles arbitraires
- Détecte les substitutions communes (`p@$$w0rd`), les séquences clavier (`qwerty`), les dates
- Léger (~400 KB, tree-shakeable)
- Retourne un `feedback.suggestions` localisable en français

```typescript
// password-strength.component.ts
import { zxcvbn, zxcvbnOptions } from '@zxcvbn-ts/core';
import * as langFr from '@zxcvbn-ts/language-fr';

const result = zxcvbn(password);
// result.score : 0 (très faible) → 4 (très fort)
// result.feedback.suggestions : ["Ajoutez des mots de plus.", ...]
// result.crackTimesDisplay.offlineSlowHashing1e4PerSecond : "siècles"
```

**UX recommandée :**
- Barre de progression colorée (rouge → orange → jaune → vert)
- Message adaptatif basé sur `feedback.suggestions`
- Temps estimé de crack affiché (rassurant quand il dit "siècles")
- Déblocage du bouton Submit seulement si score ≥ 2

---

## 7. Sécurité du flux de réinitialisation (reset password)

Le reset par email est souvent le maillon faible — c'est l'équivalent d'un bypass de mot de passe.

### Points critiques à vérifier / renforcer

| Point | État actuel | Recommandation |
|---|---|---|
| Durée de validité du token | À vérifier | **15 minutes maximum** |
| Usage unique | ✅ `usedAt` en base | Conserver |
| Token opaque vs JWT | À vérifier | Token aléatoire 256 bits (non devinable) |
| Enumeration protection | À vérifier | Répondre `200 OK` même si l'email n'existe pas |
| Ancien token invalidé | À vérifier | Invalider tout token reset précédent à l'émission d'un nouveau |
| Notification de reset | À vérifier | Email *"Vous avez demandé un reset"* même si email inconnu |
| Révocation sessions post-reset | ❌ Probable | Révoquer tous les refresh tokens après reset réussi |
| HTTPS only | ✅ prod | Lien dans l'email doit pointer vers HTTPS uniquement |

### Protection contre l'énumération d'emails

```java
// PasswordResetService.java
public void requestReset(String email) {
    // Ne jamais révéler si l'email existe ou non
    userRepository.findByEmail(email.toLowerCase())
        .ifPresent(user -> {
            // invalider les tokens précédents
            tokenRepository.invalidatePreviousTokens(user.getId());
            // générer et envoyer
            sendResetEmail(user);
        });
    // Réponse identique dans tous les cas → pas d'énumération
}
```

---

## 8. Durcissement du hachage bcrypt

### Vérifier le cost factor actuel

```java
// Chercher dans SecurityConfig ou là où BCryptPasswordEncoder est instancié
new BCryptPasswordEncoder()        // cost = 10 (défaut)
new BCryptPasswordEncoder(12)      // cost = 12 (recommandé 2024)
new BCryptPasswordEncoder(14)      // cost = 14 (élevé, ~1s sur serveur moyen)
```

**Recommandation : cost factor 12** — equilibre entre sécurité et performance (≈ 250ms/hash sur un serveur moderne, acceptable pour login/register).

### Migration progressive si le cost factor change

Ne pas rehacher tous les mots de passe en batch (opération lourde et risquée).  
Utiliser la **migration au premier login** :

```java
public void login(String email, String rawPassword) {
    User user = findByEmail(email);
    if (passwordEncoder.matches(rawPassword, user.getPassword())) {
        // Si le hash utilise un ancien cost factor, rehacher silencieusement
        if (passwordEncoder.upgradeEncoding(user.getPassword())) {
            user.setPassword(passwordEncoder.encode(rawPassword));
            userRepository.save(user);
        }
        // ...login normal
    }
}
```

Spring Security's `DelegatingPasswordEncoder` gère cela nativement.

---

## 9. Audit, monitoring et alertes

### Événements à logger (dans `auth_events`)

| Événement | Niveau | Alerte |
|---|---|---|
| `PASSWORD_CHANGED` | INFO | Email à l'utilisateur |
| `PASSWORD_RESET_REQUESTED` | INFO | — |
| `PASSWORD_RESET_USED` | INFO | Email à l'utilisateur |
| `PASSWORD_COMMON_REJECTED` | WARN | — (stats seulement) |
| `PASSWORD_REUSE_REJECTED` | WARN | — |
| `PASSWORD_COMPROMISED_DETECTED` | WARN | Email à l'utilisateur |
| `BRUTE_FORCE_DETECTED` | ERROR | Alerte ops |

### Métriques à exposer (Micrometer)

```java
Counter.builder("kovixel.auth.password.rejected")
    .tag("reason", "common|reuse|length|compromised")
    .register(meterRegistry);
```

---

## 10. Conformité RGPD

| Exigence | Application |
|---|---|
| Pas de stockage en clair | ✅ bcrypt — jamais le MDP en clair |
| Droit à l'oubli | Suppression cascade `password_history` si le compte est supprimé |
| Journaux d'accès | Conserver les `auth_events` PASSWORD_CHANGED minimum 1 an |
| Notification de violation | Si breach confirmé, notifier les utilisateurs concernés sous 72h (art. 33 RGPD) |
| Minimisation des données | Ne jamais logger le mot de passe, même tronqué |

---

## Roadmap d'implémentation

### Phase 1 — Fondations (priorité haute)

| # | Tâche | Fichiers concernés |
|---|---|---|
| 1.1 | Passer `@Size(min=8)` à `@Size(min=12, max=128)` | `RegisterRequest`, `ResetPasswordRequest`, `ChangePasswordRequest` |
| 1.2 | Créer `CommonPasswordValidator` + liste noire 10k | Nouveau fichier + `common-passwords.txt` |
| 1.3 | Vérifier et passer bcrypt cost factor à 12 | `SecurityConfig` |
| 1.4 | Mettre à jour le message UI | `register.component.ts` |
| 1.5 | Synchroniser la validation frontend ↔ backend | Validator Angular réutilisant les mêmes règles |

### Phase 2 — Robustesse (priorité moyenne)

| # | Tâche | Fichiers concernés |
|---|---|---|
| 2.1 | Migration Flyway `password_history` | Nouveau `V_next__add_password_history.sql` |
| 2.2 | `PasswordHistoryService` — vérification 5 derniers | Nouveau service |
| 2.3 | Intégrer la vérification dans changement de MDP | `AuthService`, `PasswordResetService` |
| 2.4 | Révocation sessions post-changement | `RefreshTokenService` |
| 2.5 | Notification email changement de MDP | `AuthEventService` |
| 2.6 | Champ `must_change_password` sur `User` | Entité + migration Flyway |
| 2.7 | Audit des tokens de reset (invalidation précédents) | `PasswordResetService` |

### Phase 3 — Excellence (priorité basse)

| # | Tâche | Fichiers concernés |
|---|---|---|
| 3.1 | Intégration HIBP k-anonymity (async, fallback silencieux) | Nouveau `HibpService` |
| 3.2 | Indicateur de force zxcvbn côté Angular | Nouveau composant `PasswordStrengthComponent` |
| 3.3 | Endpoint `set-password` pour comptes OAuth | `UserController`, `AuthService` |
| 3.4 | Migration progressive cost factor (upgradeEncoding) | `AuthService.login()` |
| 3.5 | Métriques Micrometer sur rejets de MDP | `CommonPasswordValidator`, `PasswordHistoryService` |

---

## Récapitulatif des décisions clés

| Question | Décision | Raison |
|---|---|---|
| Longueur minimale | **12 caractères** | Standard de facto, compromis sécurité/UX |
| Complexité obligatoire | **Non** | NIST — longueur > complexité, évite les patterns prévisibles |
| Expiration périodique | **Non** | NIST — génère de la fatigue et des mots de passe faibles |
| Réutilisation anciens MDP | **Bloquer les 5 derniers** | Casse les cycles sans frustrer l'utilisateur |
| Indicateur de force | **zxcvbn** | Basé sur l'entropie réelle, pas des règles arbitraires |
| Vérification compromission | **HIBP k-anonymity** | Sécurité sans exposer le mot de passe |
| Notification changement | **Oui — email immédiat** | Alerte critique si compte compromis |
| Révocation sessions | **Oui — toutes sauf courante** | Protège contre les sessions volées |

---

*Références : NIST SP 800-63B (2017/2024) · OWASP ASVS v4.0 · OWASP Password Storage Cheat Sheet · RGPD Art. 32*
