#!/usr/bin/env bash
# =============================================================================
# Kovixel — Durcissement initial d'un serveur Ubuntu 24.04 fraîchement provisionné
# (staging ET prod partagent ce script — aucune raison de traiter la sécurité
# de base différemment selon l'environnement).
#
# Usage (en root, juste après la première connexion SSH) :
#   curl -fsSL <url-brute-du-script> -o harden.sh && bash harden.sh <clé_ssh_publique>
# ou, si le repo est déjà cloné :
#   sudo bash 01-harden-server.sh "ssh-ed25519 AAAA... toi@ta-machine"
#
# Idempotent : peut être relancé sans casser une exécution précédente.
# =============================================================================
set -euo pipefail

SSH_PUBLIC_KEY="${1:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ce script doit être exécuté en root (ou via sudo)." >&2
  exit 1
fi

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
  echo "Usage: $0 \"<clé SSH publique à autoriser pour ${DEPLOY_USER}>\"" >&2
  echo "Exemple : $0 \"\$(cat ~/.ssh/id_ed25519.pub)\"" >&2
  exit 1
fi

echo "==> Mise à jour du système"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "==> Création de l'utilisateur non-root '${DEPLOY_USER}' (idempotent)"
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  usermod -aG sudo "$DEPLOY_USER"
fi

# --disabled-password ci-dessus signifie qu'aucun mot de passe n'existe pour cet
# utilisateur (authentification SSH par clé uniquement, cohérent avec le reste de ce
# script) — sudo ne peut donc PAS lui demander "son" mot de passe, il n'y en a pas.
# Sans NOPASSWD, `sudo` reste bloqué indéfiniment sur un prompt qu'aucun mot de passe
# ne peut jamais satisfaire. Accès sudo total sans mot de passe, cohérent avec le
# modèle "authentification par clé SSH uniquement" déjà appliqué ci-dessus.
echo "==> Sudo sans mot de passe pour '${DEPLOY_USER}' (cohérent avec l'auth par clé SSH)"
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"
visudo -c -f "/etc/sudoers.d/${DEPLOY_USER}"

echo "==> Installation de la clé SSH publique pour ${DEPLOY_USER}"
DEPLOY_HOME="/home/${DEPLOY_USER}"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "${DEPLOY_HOME}/.ssh"
AUTH_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"
touch "$AUTH_KEYS"
grep -qxF "$SSH_PUBLIC_KEY" "$AUTH_KEYS" || echo "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"

echo "==> Durcissement SSH (désactive mot de passe + login root direct)"
SSHD_CONFIG=/etc/ssh/sshd_config
sed -i \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
  "$SSHD_CONFIG"
systemctl reload ssh || systemctl reload sshd

echo "==> Pare-feu UFW — seuls SSH/HTTP/HTTPS sont exposés"
apt-get install -y -qq ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> fail2ban (protection brute-force SSH)"
apt-get install -y -qq fail2ban
systemctl enable --now fail2ban

echo "==> Mises à jour de sécurité automatiques"
apt-get install -y -qq unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Fait. Reconnecte-toi avec : ssh ${DEPLOY_USER}@<ip-du-serveur>"
echo "    Vérifie que cette connexion fonctionne AVANT de fermer la session root actuelle."
