#!/usr/bin/env bash
# =============================================================================
# Kovixel — Installation de Docker Engine + plugin Compose sur Ubuntu 24.04.
# Idempotent — peut être relancé sans effet si Docker est déjà installé.
#
# Usage : sudo bash 02-install-docker.sh
# =============================================================================
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ce script doit être exécuté en root (ou via sudo)." >&2
  exit 1
fi

if command -v docker &>/dev/null; then
  echo "==> Docker déjà installé ($(docker --version)) — rien à faire."
else
  echo "==> Installation de Docker Engine (script officiel get.docker.com)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

echo "==> Ajout de l'utilisateur 'deploy' au groupe docker (accès sans sudo)"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
if id "$DEPLOY_USER" &>/dev/null; then
  usermod -aG docker "$DEPLOY_USER"
  echo "    ${DEPLOY_USER} doit se reconnecter (ou 'newgrp docker') pour que ça prenne effet."
else
  echo "    Utilisateur ${DEPLOY_USER} introuvable — lance d'abord 01-harden-server.sh." >&2
fi

echo "==> Vérification"
docker --version
docker compose version

echo "==> Fait."
