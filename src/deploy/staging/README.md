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

> ⚠️ **Clone `kovixel-docs` sur le VPS plutôt que de copier les scripts un par un.**
> Un `scp` ponctuel se fige au moment de la copie — un correctif poussé plus tard
> sur `kovixel-docs` n'a alors aucun effet lors d'une réexécution du script sur le
> VPS (bug réel rencontré, voir [../TROUBLESHOOTING.md #5](../TROUBLESHOOTING.md#5-scripts-de-déploiement-non-synchronisés-avec-git)).
> ```bash
> git clone <url-git-kovixel-docs> ~/kovixel-app/kovixel-docs
> ```
> Puis, avant **chaque** exécution d'un script ci-dessous :
> ```bash
> cd ~/kovixel-app/kovixel-docs && git pull --ff-only
> ```
> et remplacer les commandes `scp ../scripts/...` ci-dessous par un appel direct
> depuis `~/kovixel-app/kovixel-docs/src/deploy/scripts/`.
>
> 📖 Si un problème pendant le déploiement ressemble à quelque chose de déjà vu
> (nginx qui refuse de démarrer, boucle de redirection HTTPS, assets 404, port déjà
> utilisé, DNS...), consulte d'abord [../TROUBLESHOOTING.md](../TROUBLESHOOTING.md)
> — probablement plus rapide qu'un nouveau diagnostic complet.

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

> ⚠️ **Vérifie d'abord que le DNS pointe vraiment vers ce serveur — avant toute
> autre hypothèse.** Une IP mal notée/mal communiquée lors de la récupération
> auprès de l'hébergeur ressemble à s'y méprendre à un blocage réseau complexe
> (voir [../TROUBLESHOOTING.md #8](../TROUBLESHOOTING.md#8-fausse-piste--blocage-réseau-hébergeur),
> ~1h de diagnostic perdue sur cette confusion lors du premier déploiement) :
> ```bash
> # Sur le VPS, source de vérité absolue pour sa propre IP publique :
> curl -s https://ifconfig.me
> # Depuis ta machine, ce que le monde voit réellement (bypass le cache résolveur local) :
> nslookup staging.kovixel.com 8.8.8.8
> ```
> Les deux doivent être identiques avant de continuer. Si ce n'est pas le cas,
> corrige l'enregistrement `A` chez ton registrar et attends la propagation
> (quelques minutes à ~30 min) avant de relancer le script ci-dessous.

```bash
scp ../scripts/05-setup-tls-caddy.sh deploy@<ip-vps>:~/kovixel-app/
ssh deploy@<ip-vps> 'sudo bash ~/kovixel-app/05-setup-tls-caddy.sh staging.kovixel.com'
```

Vérification post-exécution recommandée (les deux bugs ci-dessous ont été réels au
premier déploiement, tous deux corrigés dans le code mais à re-vérifier si le
Caddyfile ou `nginx.conf.template` sont modifiés à l'avenir) :
```bash
curl -IL https://staging.kovixel.com/api/v1/health   # doit renvoyer 200, PAS une boucle de 308
bash ~/kovixel-app/kovixel-docs/src/deploy/scripts/health-check.sh https://staging.kovixel.com
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
Q&A — et un œil sur Grafana pour confirmer que les métriques remontent (accès
via tunnel SSH, voir ci-dessous).

> ℹ️ Postgres, Redis, MinIO, Gotenberg, Prometheus, node-exporter et Grafana sont
> tous liés à `127.0.0.1` dans `docker-compose.yml` — **pas** exposés à Internet,
> uniquement `kovixel-ui` (port 80/443) l'est. C'est volontaire : `ufw allow`
> seul ne suffit pas à protéger un port publié par Docker (Docker manipule
> iptables directement et court-circuite les règles UFW — piège classique), donc
> ces services n'ont jamais eu de port ouvert publiquement en premier lieu.
> Pour y accéder depuis ta machine (Grafana, console MinIO, psql direct…), ouvre
> un tunnel SSH :
> ```bash
> ssh -L 3001:localhost:3001 -L 9090:localhost:9090 -L 9001:localhost:9001 deploy@<ip-vps>
> ```
> puis ouvre `http://localhost:3001` (Grafana), `http://localhost:9090` (Prometheus)
> ou `http://localhost:9001` (console MinIO) normalement dans ton navigateur.

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
