# Déploiement Staging

> Objectif du staging : valider en conditions réelles ce que le dev local ne peut
> pas tester — MinIO, 2 répliques + load balancer (`ROADMAP_CAPACITE_INITIALE.md`
> Correction 3), CORS/cookies stricts, TLS, monitoring Prometheus/Grafana — **avant**
> d'engager un VPS de production et un test de charge outillé.

## 0. Prérequis

- Un VPS Ubuntu 24.04 (validé : 8 vCPU / 24 Go RAM / 300 Go SSD, Contabo — largement
  suffisant pour cette stack, voir le calcul dans la conversation d'origine).
- Un sous-domaine DNS pointant vers l'IP du VPS (ex. `staging.kovixel.com`, en
  **DNS only**, pas de proxy Cloudflare nécessaire à ce stade).
- Accès SSH root initial fourni par l'hébergeur.
- Les clés/credentials tiers listés dans [../ENV_VARIABLES.md](../ENV_VARIABLES.md)
  (au minimum Anthropic + OpenAI pour que l'app démarre).

Tous les scripts référencés ci-dessous sont dans [../scripts/](../scripts/).

## 1. Durcissement initial du serveur

Depuis ta machine, copie le script puis exécute-le sur le serveur (en root) :

```bash
scp ../scripts/01-harden-server.sh root@<ip-vps>:/root/
ssh root@<ip-vps> 'bash /root/01-harden-server.sh "'"$(cat ~/.ssh/id_ed25519.pub)"'"'
```

Ce script crée l'utilisateur `deploy`, installe ta clé SSH, désactive le login
root/mot de passe, configure UFW (SSH/80/443 uniquement) et fail2ban.

**Vérifie que la connexion suivante fonctionne avant de fermer la session root :**

```bash
ssh deploy@<ip-vps>
```

## 2. Installer Docker

```bash
scp ../scripts/02-install-docker.sh deploy@<ip-vps>:~/
ssh deploy@<ip-vps> 'sudo bash 02-install-docker.sh'
```

Déconnecte-toi et reconnecte-toi (`ssh deploy@<ip-vps>`) pour que l'appartenance
au groupe `docker` prenne effet sans `sudo`.

## 3. DNS

Crée l'enregistrement `A` de ton sous-domaine (ex. `staging.kovixel.com`) vers
l'IP publique du VPS, en **DNS only** (nuage gris si tu utilises Cloudflare comme
registrar DNS — pas de proxy à ce stade, ni de verrou d'origine).

## 4. Cloner et configurer

```bash
ssh deploy@<ip-vps>
mkdir -p ~/kovixel-app && cd ~/kovixel-app
scp ../scripts/03-generate-secrets.sh deploy@<ip-vps>:~/kovixel-app/
scp ../scripts/04-deploy.sh deploy@<ip-vps>:~/kovixel-app/

git clone <url-git-kovixel> kovixel
cd kovixel
bash ../03-generate-secrets.sh staging.kovixel.com
```

Édite ensuite `kovixel/.env` pour renseigner les clés tierces (Anthropic, OpenAI,
OAuth, mail…) — voir [../ENV_VARIABLES.md](../ENV_VARIABLES.md) pour la liste
complète et ce qui casse si une variable manque.

## 5. Déployer la stack

```bash
cd ~/kovixel-app
bash 04-deploy.sh <url-git-kovixel> <url-git-kovixel-ui>
```

Ce script clone `kovixel-ui` (nécessaire — `docker-compose.yml` référence
`../kovixel-ui` comme contexte de build), build les images, applique les
migrations Flyway au démarrage, lance la stack complète (Postgres, Redis, MinIO,
Gotenberg, 2 répliques `kovixel-app` + load balancer nginx, `kovixel-ui`,
Prometheus, Grafana), et attend que les healthchecks passent.

## 6. TLS

```bash
scp ../scripts/05-setup-tls-caddy.sh deploy@<ip-vps>:~/kovixel-app/
ssh deploy@<ip-vps> 'sudo bash ~/kovixel-app/05-setup-tls-caddy.sh staging.kovixel.com'
```

Caddy obtient et renouvelle automatiquement un certificat Let's Encrypt, et
termine le TLS devant le port 80 déjà publié par `kovixel-ui`. Une fois vérifié :

```bash
cd ~/kovixel-app/kovixel
sed -i 's/^KOVIXEL_COOKIE_SECURE=.*/KOVIXEL_COOKIE_SECURE=true/' .env
docker compose up -d --build kovixel-app-1 kovixel-app-2
```

`CORS_ALLOWED_ORIGINS` et `APP_BASE_URL` ont déjà été positionnés par
`03-generate-secrets.sh` si le domaine lui a été passé en argument.

## 7. OAuth

Si Google/Microsoft OAuth doivent être testés sur cet environnement, ajoute
`https://staging.kovixel.com/...` (URL de callback exacte, cf. code d'auth) dans
les identifiants OAuth respectifs (Google Cloud Console, Azure Portal) — les
providers OAuth refusent les redirections vers une URL non déclarée.

## 8. Vérification

```bash
bash ~/kovixel-app/scripts/health-check.sh https://staging.kovixel.com
```

Puis manuellement : inscription, login (email + OAuth), upload PDF, résumé IA,
Q&A — et un œil sur Grafana (`http://<ip-vps>:3001`, **à restreindre** — voir
note ci-dessous) pour confirmer que les métriques remontent.

> ⚠️ Grafana (port 3001) et Prometheus (port 9090) sont publiés sur l'hôte par
> `docker-compose.yml` mais ne sont protégés que par leur propre auth (Grafana) ou
> rien du tout (Prometheus). En staging, restreins l'accès via UFW à ton IP
> (`sudo ufw allow from <ton-ip> to any port 3001,9090 proto tcp`) plutôt que de
> les laisser ouverts à tout Internet — surtout pour Prometheus qui n'a aucune
> authentification.

## Redéploiement (mise à jour du code)

```bash
cd ~/kovixel-app
bash 04-deploy.sh
```

Sans argument, le script se contente de `git pull` + rebuild + redémarrage.

## Ce qui reste volontairement différent de la prod

Voir [../prod/README.md](../prod/README.md) — le staging n'a par exemple pas
vocation à avoir de vraies alertes sortantes (Slack/PagerDuty) ni un plan de
sauvegarde hors-site testé en restauration, contrairement à la prod.
