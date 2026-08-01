# Déploiement Production

> Suppose que [../staging/README.md](../staging/README.md) a déjà été suivi une
> fois avec succès sur un environnement séparé — ce document ne répète pas les
> étapes communes, il liste uniquement ce qui **change** pour la prod.

## Prérequis spécifiques

- Un second VPS, distinct du staging (jamais le même serveur physique/instance).
  Dimensionnement à décider une fois le staging validé par un test de charge —
  32 ou 48 Go RAM envisagés selon le trafic réel observé, contre 24 Go en staging.
- Le domaine réel (ex. `app.kovixel.com`), pas le sous-domaine staging.
- Toutes les clés tierces en mode **production** des fournisseurs (pas de clés de
  test/sandbox Stripe, Adobe, etc.).

## Étapes identiques au staging

Reprendre [../staging/README.md](../staging/README.md) étapes 1 à 6
(durcissement, Docker, DNS, clone, déploiement, TLS) à l'identique, avec le
domaine et le VPS de prod. `SPRING_PROFILES_ACTIVE=prod` est le même profil
qu'en staging — c'est un principe fondateur de ce dossier de déploiement (voir
[../README.md](../README.md)).

## Ce qui diffère réellement

### 1. Cloudflare en frontal (recommandé, pas obligatoire en staging)

Suivre `kovixel-ui/docker/CLOUDFLARE_RUNBOOK.md` intégralement : bascule DNS,
Bot Fight Mode, WAF managé, verrou d'origine (`ORIGIN_LOCKDOWN_ENABLED=true` +
`ORIGIN_AUTH_SECRET`). Ce runbook est explicitement hors du périmètre du staging
(`ORIGIN_LOCKDOWN_ENABLED=false` y reste la valeur correcte) — l'activer en prod
uniquement, après vérification complète (§10 du runbook : la requête directe à
l'IP origin doit renvoyer 403).

Si Cloudflare termine le TLS (mode Flexible ou Full), `05-setup-tls-caddy.sh`
n'est pas nécessaire en prod — les deux mécanismes de TLS sont mutuellement
exclusifs (ne pas faire tourner Caddy ET Cloudflare Full sur le même port 443
sans adapter la chaîne de confiance).

### 2. Sauvegardes — vérifier, pas seulement activer

`BACKUP_ENABLED=true` est déjà le défaut. En prod, ne pas s'arrêter à "le job
tourne" :
- Vérifier au moins une fois qu'une **restauration réelle** depuis un backup
  fonctionne (sur un environnement jetable, jamais sur la prod elle-même).
- Confirmer que `BACKUP_ENCRYPTION_KEY` est sauvegardée dans un gestionnaire de
  secrets externe (1Password, Vault) — pas seulement dans `.env` sur le serveur.
  Un VPS perdu + pas de copie externe de cette clé = backups définitivement
  inutilisables malgré leur présence physique.

### 3. Alerting réel

`RESILIENCE_ROADMAP.md` Phase 2 a mis en place Prometheus/Grafana avec des
règles d'alerte évaluées (`docker/prometheus/alerts.yml`), **mais sans
Alertmanager** — les alertes sont visibles dans l'UI Prometheus/Grafana, aucune
notification sortante (Slack/email/PagerDuty) n'est câblée. Décision produit
explicitement différée. Avant la mise en prod réelle avec des utilisateurs,
statuer sur ce point : soit brancher un canal de notification, soit assumer
consciemment une supervision "pull" (quelqu'un doit consulter Grafana
activement, ça ne va pas chercher personne).

### 4. Ports internes déjà non exposés — rien à faire de plus

Postgres, Redis, MinIO, Gotenberg, Prometheus, node-exporter et Grafana sont liés
à `127.0.0.1` dans `docker-compose.yml` (identique staging/prod) — accès admin
uniquement via tunnel SSH (`ssh -L 3001:localhost:3001 deploy@<ip-vps>`), jamais
une exposition publique, y compris temporaire. Rien de spécifique à la prod ici,
juste à ne pas régresser en modifiant `docker-compose.yml` sans y repenser.

### 5. Rotation du Master Key de chiffrement

`kovixel/docker/encryption/KEY_ROTATION.md` (Sprint E-3) documente la procédure —
non nécessaire au premier déploiement, mais à planifier (fréquence à définir avec
le RSSI/PSSI, cf. `kovixel-docs/src/compliance/PSSI_POLITIQUE_SECURITE_DONNEES.md`)
une fois la prod en fonctionnement depuis un moment.

### 6. Test de charge avant bascule DNS finale

`ROADMAP_CAPACITE_INITIALE.md` — aucun test de charge outillé n'a été exécuté à
la rédaction de cette documentation. Avant de considérer la prod prête pour un
trafic réel à l'échelle visée (100k utilisateurs/jour), exécuter un test de
charge sur le VPS de prod dimensionné, avec la topologie complète (2 répliques +
LB), et comparer aux plafonds théoriques du roadmap (pool Hikari, quotas
Redis/anonymes).

## Checklist

Voir [CHECKLIST_GO_LIVE.md](CHECKLIST_GO_LIVE.md) avant toute bascule DNS finale
vers la prod.
