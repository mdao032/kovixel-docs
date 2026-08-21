#!/usr/bin/env bash
# =============================================================================
# Kovixel — Vérification post-déploiement (staging ET prod).
# Usage : bash health-check.sh [https://staging.kovixel.com]
# Sans argument, teste en local (http://localhost).
# =============================================================================
set -uo pipefail

BASE_URL="${1:-http://localhost}"
FAIL=0

check() {
  local desc="$1" url="$2" expect="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url")
  if [[ "$code" == "$expect" ]]; then
    echo "OK   [$code] $desc"
  else
    echo "FAIL [$code, attendu $expect] $desc"
    FAIL=1
  fi
}

echo "== Vérifications HTTP (${BASE_URL}) =="
check "Frontend (SSR)"        "${BASE_URL}/"                        "200"
check "API health"            "${BASE_URL}/api/v1/health"           "200"

# ── Assets statiques référencés par la page ─────────────────────────────────
# curl -I sur "/" seul ne suffit PAS : le SSR (Node/Express) répond 200 même si
# nginx sert les fichiers statiques (JS/CSS hashés) depuis le mauvais dossier —
# bug réel du premier déploiement staging (TROUBLESHOOTING.md #7), invisible tant
# qu'on ne vérifie pas qu'au moins une ressource référencée par la page charge
# vraiment. On extrait le premier <script src="..."> du HTML retourné et on le
# vérifie séparément.
ASSET_PATH=$(curl -s --max-time 10 "${BASE_URL}/" | grep -oE 'src="/[^"]+\.js"' | head -1 | sed -E 's/^src="//; s/"$//')
if [[ -n "$ASSET_PATH" ]]; then
  check "Asset statique référencé ($ASSET_PATH)" "${BASE_URL}${ASSET_PATH}" "200"
else
  echo "!! Impossible d'extraire un asset JS depuis le HTML de \"${BASE_URL}/\" — vérification ignorée."
fi

# ── Pas de boucle de redirection HTTPS ──────────────────────────────────────
# Bug réel (TROUBLESHOOTING.md #4) : X-Forwarded-Proto écrasé par nginx causait
# une boucle infinie de 308 vers la même URL. On vérifie qu'au plus 1 redirection
# a lieu avant d'atteindre un 200 final.
if [[ "$BASE_URL" == https://* ]]; then
  REDIRECT_COUNT=$(curl -s -o /dev/null -w "%{num_redirects}" --max-time 10 --max-redirs 3 "${BASE_URL}/api/v1/health")
  if [[ "$REDIRECT_COUNT" -le 1 ]]; then
    echo "OK   [$REDIRECT_COUNT redirection(s)] Pas de boucle de redirection HTTPS"
  else
    echo "FAIL [$REDIRECT_COUNT redirections] Boucle de redirection suspectée sur /api/v1/health — voir TROUBLESHOOTING.md #4"
    FAIL=1
  fi
fi

echo ""
echo "== État des conteneurs =="
if command -v docker &>/dev/null && [[ -f kovixel/docker-compose.yml || -f docker-compose.yml ]]; then
  COMPOSE_DIR=$( [[ -f docker-compose.yml ]] && echo "." || echo "kovixel" )
  (cd "$COMPOSE_DIR" && docker compose ps)
  UNHEALTHY=$(cd "$COMPOSE_DIR" && docker compose ps --format json 2>/dev/null | grep -c '"Health":"unhealthy"' || true)
  if [[ "$UNHEALTHY" -gt 0 ]]; then
    echo "!! Conteneur(s) unhealthy détecté(s)."
    FAIL=1
  fi
else
  echo "(docker compose non disponible ou docker-compose.yml introuvable ici — vérification ignorée)"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "==> Toutes les vérifications sont passées."
else
  echo "==> Au moins une vérification a échoué — voir ci-dessus. 'docker compose logs -f' pour investiguer."
fi
exit "$FAIL"
