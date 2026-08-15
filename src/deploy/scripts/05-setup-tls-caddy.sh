#!/usr/bin/env bash
# =============================================================================
# Kovixel — Termine le TLS avec Caddy (certificat Let's Encrypt automatique,
# renouvellement automatique), en frontal du port 80 déjà publié par le
# conteneur kovixel-ui.
#
# Pourquoi Caddy plutôt que certbot+nginx manuel : le nginx de kovixel-ui/docker/
# (voir kovixel-ui/docker/nginx.conf.template) ne termine QUE du HTTP par design
# (TLS prévu en frontal, via Cloudflare OU ce script) — dupliquer sa config pour
# lui ajouter un `listen 443` créerait deux sources de vérité à maintenir en
# synchronisation. Caddy en reverse proxy devant, sur l'hôte, avec un Caddyfile
# de 3 lignes et un renouvellement de certificat entièrement automatique, est
# plus simple à opérer qu'un cron certbot + reload nginx.
#
# Alternative : si Cloudflare est déjà en frontal (kovixel-ui/docker/CLOUDFLARE_RUNBOOK.md),
# ce script n'est PAS nécessaire — Cloudflare peut terminer le TLS lui-même
# (mode Flexible ou Full).
#
# Usage : sudo bash 05-setup-tls-caddy.sh staging.kovixel.com
# Prérequis : le DNS du domaine pointe déjà vers l'IP publique de ce serveur,
# et les ports 80/443 sont ouverts (fait par 01-harden-server.sh).
# =============================================================================
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domaine> (ex. staging.kovixel.com)" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ce script doit être exécuté en root (ou via sudo)." >&2
  exit 1
fi

if ! command -v caddy &>/dev/null; then
  echo "==> Installation de Caddy (dépôt officiel)"
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
else
  echo "==> Caddy déjà installé — mise à jour de la config uniquement."
fi

echo "==> Écriture du Caddyfile pour ${DOMAIN}"
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
	# kovixel-ui est lié à 127.0.0.1:8080 (docker-compose.yml) pour laisser Caddy
	# seul sur 80/443 — Caddy termine le TLS et proxy tout le reste tel quel
	# (headers, websockets éventuels, gros uploads inclus grâce au streaming
	# natif de reverse_proxy).
	reverse_proxy localhost:8080

	encode gzip

	log {
		output file /var/log/caddy/${DOMAIN}.log
	}
}
EOF

mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

systemctl reload caddy || systemctl restart caddy

echo "==> Fait. Caddy obtient et renouvelle le certificat Let's Encrypt automatiquement."
echo "    Vérification (après propagation, ~30s) : curl -I https://${DOMAIN}/api/v1/health"
echo ""
echo "    N'oublie pas ensuite, dans kovixel/.env :"
echo "      KOVIXEL_COOKIE_SECURE=true"
echo "      CORS_ALLOWED_ORIGINS=https://${DOMAIN}"
echo "      APP_BASE_URL=https://${DOMAIN}"
echo "    puis : docker compose up -d --build kovixel-app-1 kovixel-app-2"
