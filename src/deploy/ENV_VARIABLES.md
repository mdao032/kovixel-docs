# Référence des variables d'environnement

> Source de vérité : `kovixel/.env.example`. Ce document explique le **pourquoi** de
> chaque groupe de variables et ce qui casse si elles manquent — le fichier
> `.env.example` reste la référence pour la syntaxe exacte à copier.
>
> Depuis la correction infra du 2026-07-30, `docker-compose.yml` transmet
> **l'intégralité** de `kovixel/.env` au conteneur applicatif via `env_file:` — toute
> variable ajoutée à `.env.example`/`.env` est automatiquement disponible côté
> Spring Boot, sans modification de `docker-compose.yml` nécessaire (sauf variable
> dont le nom ou la valeur diffère entre l'intérieur et l'extérieur du réseau
> Docker — ex. `MINIO_ENDPOINT`, `SPRING_DATASOURCE_URL`).

## Obligatoires — l'application refuse de démarrer sans elles (profil `prod`)

| Variable | Rôle | Où l'obtenir |
|---|---|---|
| `ANTHROPIC_API_KEY` | Génération IA (résumé, Q&A, extraction, traduction) | console.anthropic.com |
| `OPENAI_API_KEY` | Embeddings RAG (`text-embedding-3-small`) — chat désactivé | platform.openai.com |
| `DB_PASSWORD` | Mot de passe PostgreSQL | `openssl rand -hex 32` |
| `JWT_SECRET` | Signature HMAC-256 des JWT | `openssl rand -hex 32` |
| `ENCRYPTION_MASTER_KEY` | Chiffrement des fichiers/titres/secrets TOTP au repos | `openssl rand -hex 32` — **ne jamais régénérer une fois des données réelles chiffrées** |
| `REDIS_PASSWORD` | Auth Redis (cache IA, quotas, blacklist tokens, PKCS#12 e-signature) | `openssl rand -hex 32` |
| `MINIO_ROOT_PASSWORD` | Stockage objet des fichiers PDF (profil `prod`) | `openssl rand -hex 32` |
| `GRAFANA_PASSWORD` | Compte admin Grafana | `openssl rand -base64 24` |

`scripts/03-generate-secrets.sh` génère tout ce tableau automatiquement.

## Obligatoires mais avec une valeur par défaut acceptable en staging

| Variable | Défaut | À changer en prod ? |
|---|---|---|
| `CORS_ALLOWED_ORIGINS` | `https://app.kovixel.com` | Oui — domaine réel de l'environnement |
| `APP_BASE_URL` | `https://app.kovixel.com` | Oui — utilisé dans les liens d'emails transactionnels |
| `KOVIXEL_COOKIE_SECURE` | — | `true` dès que le HTTPS est actif (sinon les cookies de session ne sont jamais posés par le navigateur) |

## Tiers requis pour des fonctionnalités spécifiques (dégradation gracieuse sinon)

| Variable(s) | Fonctionnalité désactivée si absente |
|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET`, `MICROSOFT_CLIENT_ID` | Connexion OAuth (email/mot de passe reste disponible) |
| `ADOBE_CLIENT_ID` / `_SECRET` | Conversions PRO (Gotenberg/Tabula couvrent le tier FREE) |
| `MAIL_HOST` / `MAIL_USERNAME` / `MAIL_SMTP_PASSWORD` | Emails transactionnels (vérification, reset mot de passe) — **indisponible ⇒ inscription cassée en pratique**, à ne jamais laisser vide hors dev (MailHog) |
| `STRIPE_*` | Paiement — sans impact si l'environnement ne teste pas la facturation |
| `MAXMIND_LICENSE_KEY` | Signal ASN datacenter (antibot) — dégradé en neutre, jamais bloquant |
| `TURNSTILE_SITE_KEY` / `_SECRET_KEY` | Challenge adaptatif antibot — fail-closed tant que désactivé via `ANTIBOT_CHALLENGE_ENABLED=false` |

## Sécurité / conformité — à ne pas ignorer en staging non plus

| Variable | Pourquoi |
|---|---|
| `BACKUP_ENCRYPTION_KEY` | Sans elle, les backups PostgreSQL automatiques échouent silencieusement à se chiffrer — vérifier les logs de `BackupService` après le premier backup planifié |
| `PDF_ESIGNATURE_CERT_ENCRYPTION_KEY` | Chiffrement des certificats PKCS#12 en transit dans Redis (30 min) — fonctionnalité e-signature cassée sans elle |
| `PLATFORM_ADMIN_ALLOWED_EMAILS` | Défense en profondeur pour les rôles plateforme — vide = pas de restriction, à définir dès que la console Super Admin est utilisée |
| `ORIGIN_LOCKDOWN_ENABLED` / `ORIGIN_AUTH_SECRET` | Verrou d'origine Cloudflare — **laisser à `false` tant que `CLOUDFLARE_RUNBOOK.md` n'a pas été exécuté**, sinon nginx refuse tout le trafic direct |

## Spécifique à l'environnement (à ne jamais copier tel quel entre staging et prod)

- `SPRING_PROFILES_ACTIVE` — `prod` pour staging ET prod (voir [README.md](README.md) principe 3). Ne jamais `dev` sur un VPS.
- `DB_PASSWORD`, `MINIO_ROOT_PASSWORD`, `REDIS_PASSWORD`, `GRAFANA_PASSWORD` — uniques par environnement, jamais réutilisés entre staging et prod.
- `MINIO_ENDPOINT` — forcé à `http://minio:9000` par `docker-compose.yml` lui-même (résolution DNS interne), la valeur dans `.env` ne sert que hors conteneur.

## Où sont réellement consommées ces variables ?

- `kovixel/src/main/resources/application.yml` — valeurs par défaut/communes.
- `kovixel/src/main/resources/application-prod.yml` — overrides du profil `prod` (staging + prod).
- `kovixel/docker-compose.yml` — variables recomposées/renommées pour le réseau Docker interne (section `environment:` de `kovixel-app-1`), tout le reste passe par `env_file: .env`.

Pour une variable non listée ici : `grep -rn "NOM_VARIABLE" kovixel/src/main/resources/*.yml kovixel/docker-compose.yml` reste la vérité terrain la plus rapide à consulter — ce document résume l'intention, pas l'exhaustivité ligne à ligne.
