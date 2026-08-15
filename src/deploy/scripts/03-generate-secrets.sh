#!/usr/bin/env bash
# =============================================================================
# Kovixel — Génère un .env complet à partir de .env.example, avec des secrets
# aléatoires forts pour toutes les valeurs qui en ont besoin (JWT, chiffrement,
# Redis, MinIO, Grafana, backup, e-signature, verrou d'origine Cloudflare).
#
# NE remplit PAS les clés tierces (ANTHROPIC_API_KEY, OPENAI_API_KEY, OAuth,
# Stripe, Adobe, Brevo/Resend, MaxMind, Turnstile) — ce sont des identifiants
# réels à obtenir manuellement sur chaque plateforme, cf. staging/README.md
# et prod/README.md pour la liste.
#
# Usage (depuis le répertoire kovixel/ sur le serveur) :
#   bash 03-generate-secrets.sh [staging.kovixel.com]
#
# Si un .env existe déjà, le script REFUSE de l'écraser (utiliser --force pour
# forcer, ex. lors d'un premier essai jetable) — les secrets générés une fois
# (en particulier ENCRYPTION_MASTER_KEY) ne doivent JAMAIS être régénérés une
# fois des documents chiffrés en base, sous peine de rendre ces documents
# définitivement illisibles (crypto-shredding involontaire).
# =============================================================================
set -euo pipefail

DOMAIN="${1:-}"
FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if [[ ! -f .env.example ]]; then
  echo "Erreur : .env.example introuvable — lance ce script depuis le répertoire kovixel/." >&2
  exit 1
fi

if [[ -f .env && "$FORCE" != true ]]; then
  echo "Erreur : .env existe déjà. Ce script ne l'écrase pas par défaut —" >&2
  echo "         régénérer ENCRYPTION_MASTER_KEY rendrait tous les documents déjà" >&2
  echo "         chiffrés illisibles. Utilise --force uniquement si tu es sûr" >&2
  echo "         qu'aucune donnée réelle n'existe encore derrière ce .env." >&2
  exit 1
fi

cp .env.example .env

gen_hex32() { openssl rand -hex 32; }
gen_b64_24() { openssl rand -base64 24; }
gen_b64_32() { openssl rand -base64 32; }

set_env() {
  local key="$1" value="$2"
  # Échappe les caractères spéciaux sed dans la valeur (base64 peut contenir / + =)
  local escaped
  escaped=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

echo "==> Génération des secrets forts"
set_env DB_PASSWORD                      "$(gen_hex32)"
set_env JWT_SECRET                       "$(gen_hex32)"
set_env ENCRYPTION_MASTER_KEY             "$(gen_hex32)"
set_env REDIS_PASSWORD                   "$(gen_hex32)"
set_env MINIO_ROOT_PASSWORD              "$(gen_hex32)"
set_env GRAFANA_PASSWORD                 "$(gen_b64_24)"
set_env BACKUP_ENCRYPTION_KEY             "$(gen_b64_32)"
set_env PDF_ESIGNATURE_CERT_ENCRYPTION_KEY "$(gen_b64_32)"
# ORIGIN_AUTH_SECRET délibérément PAS généré ici, contrairement aux autres secrets :
# nginx.conf.template exige l'en-tête X-Origin-Auth sur TOUTE requête dès que cette
# variable est non vide, indépendamment d'ORIGIN_LOCKDOWN_ENABLED — un site tout juste
# déployé (staging, sans Cloudflare devant) se retrouve alors à renvoyer 403 sur tout,
# sans lien évident avec ce script. À ne renseigner qu'en suivant
# kovixel-ui/docker/CLOUDFLARE_RUNBOOK.md (la Transform Rule Cloudflare doit poser le
# même secret AVANT que cette variable ne soit remplie côté serveur).

if [[ -n "$DOMAIN" ]]; then
  echo "==> Application du domaine '${DOMAIN}' (CORS, mail, MinIO endpoint interne)"
  set_env CORS_ALLOWED_ORIGINS "https://${DOMAIN}"
  set_env APP_BASE_URL         "https://${DOMAIN}"
fi

chmod 600 .env

cat <<'EOF'

==> .env généré. IL RESTE À REMPLIR MANUELLEMENT :
      - ANTHROPIC_API_KEY        (console.anthropic.com)
      - OPENAI_API_KEY           (platform.openai.com — embeddings RAG, obligatoire)
      - GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
      - MICROSOFT_CLIENT_ID
      - MAIL_USERNAME / MAIL_SMTP_PASSWORD (Brevo ou Resend)
      - ADOBE_CLIENT_ID / ADOBE_CLIENT_SECRET   (fonctionnalités PRO uniquement)
      - STRIPE_*                 (si le paiement est testé sur cet environnement)

    Vérifie ensuite CORS_ALLOWED_ORIGINS / APP_BASE_URL si aucun domaine n'a été
    passé en argument.

    ⚠️  Sauvegarde ENCRYPTION_MASTER_KEY et BACKUP_ENCRYPTION_KEY dans un gestionnaire
        de secrets externe (1Password, Vault) MAINTENANT — leur perte rend
        respectivement les documents chiffrés et les backups irrécupérables.
EOF
