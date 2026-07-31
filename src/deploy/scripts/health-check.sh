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
