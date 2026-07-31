#!/usr/bin/env bash
# =============================================================================
# Kovixel — Déploie ou met à jour la stack complète (docker-compose.yml).
# À exécuter en tant qu'utilisateur 'deploy' (pas root), depuis le répertoire
# parent qui contiendra kovixel/ et kovixel-ui/ côte à côte (docker-compose.yml
# référence ../kovixel-ui comme contexte de build).
#
# Premier déploiement :
#   bash 04-deploy.sh <url-git-kovixel> <url-git-kovixel-ui>
#
# Redéploiements suivants (repos déjà clonés) :
#   bash 04-deploy.sh
# =============================================================================
set -euo pipefail

KOVIXEL_REPO="${1:-}"
KOVIXEL_UI_REPO="${2:-}"

if [[ ! -d kovixel ]]; then
  if [[ -z "$KOVIXEL_REPO" ]]; then
    echo "Erreur : kovixel/ n'existe pas encore — fournis l'URL du repo en argument." >&2
    echo "Usage : $0 <url-git-kovixel> <url-git-kovixel-ui>" >&2
    exit 1
  fi
  echo "==> Clonage de kovixel"
  git clone "$KOVIXEL_REPO" kovixel
fi

if [[ ! -d kovixel-ui ]]; then
  if [[ -z "$KOVIXEL_UI_REPO" ]]; then
    echo "Erreur : kovixel-ui/ n'existe pas encore — fournis l'URL du repo en argument." >&2
    exit 1
  fi
  echo "==> Clonage de kovixel-ui"
  git clone "$KOVIXEL_UI_REPO" kovixel-ui
fi

cd kovixel

if [[ ! -f .env ]]; then
  echo "Erreur : kovixel/.env introuvable — exécute d'abord 03-generate-secrets.sh" >&2
  echo "         et remplis les clés tierces avant de déployer." >&2
  exit 1
fi

echo "==> git pull (kovixel + kovixel-ui)"
git pull --ff-only
(cd ../kovixel-ui && git pull --ff-only)

echo "==> Build des images (peut prendre plusieurs minutes la première fois)"
docker compose build

echo "==> Application des migrations + démarrage de la stack"
docker compose up -d

echo "==> Attente des healthchecks (jusqu'à 3 min)"
for i in $(seq 1 36); do
  UNHEALTHY=$(docker compose ps --format json 2>/dev/null | grep -c '"Health":"unhealthy"' || true)
  STARTING=$(docker compose ps --format json 2>/dev/null | grep -c '"Health":"starting"' || true)
  if [[ "$UNHEALTHY" -gt 0 ]]; then
    echo "!! Au moins un conteneur est 'unhealthy' — voir : docker compose ps && docker compose logs" >&2
    exit 1
  fi
  if [[ "$STARTING" -eq 0 ]]; then
    echo "==> Tous les conteneurs avec healthcheck sont 'healthy'."
    break
  fi
  sleep 5
done

echo ""
docker compose ps
echo ""
echo "==> Déploiement terminé. Vérifications suggérées :"
echo "    curl -I http://localhost/api/v1/health"
echo "    docker compose logs -f kovixel-app-1 kovixel-app-2"
