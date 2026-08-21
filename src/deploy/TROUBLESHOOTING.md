# Journal des incidents — premier déploiement staging réel

> Ce document existe parce que le premier déploiement staging réel (VPS Contabo,
> `staging.kovixel.com`, août 2026) a révélé une dizaine de bugs qui ne pouvaient
> **pas** être détectés en local (dev natif ou `ng serve` ne passent jamais par ce
> nginx, ce Caddy, ni ce vrai réseau public). Tous sont corrigés dans le code à la
> date de rédaction — ce fichier documente le symptôme et la cause racine pour que
> la prod n'ait pas à les redécouvrir une seconde fois, et pour que quiconque
> retombe sur un symptôme similaire ait un raccourci direct vers la cause.
>
> Si un nouveau problème de déploiement survient et n'est pas encore ici : une fois
> résolu, ajoute-le. C'est le but de ce fichier.

## Index rapide par symptôme

| Symptôme observé | Cause | Section |
|---|---|---|
| `nginx: [emerg] could not build map_hash, you should increase map_hash_bucket_size: 64` | Clé du bloc `map` trop longue pour la taille de bucket par défaut | [#1](#1-map_hash_bucket_size-trop-petit) |
| `nginx: [emerg] ... unexpected "{"` sur un bloc `map` | Regex/remplacement contenant `{ }` non entre guillemets | [#2](#2-bloc-map-non-quoté) |
| Caddy : `could not build... bind: address already in use` sur `:80` | `kovixel-ui` publie déjà `80:80` sur l'hôte, en conflit avec Caddy | [#3](#3-conflit-de-port-80-entre-kovixel-ui-et-caddy) |
| `curl https://<domaine>/...` boucle en `308` vers la même URL, indéfiniment | `X-Forwarded-Proto` écrasé par nginx avec sa propre vue (`$scheme`=http) | [#4](#4-boucle-de-redirection-https-x-forwarded-proto-écrasé) |
| Après un fix poussé sur GitHub, le comportement sur le VPS ne change pas | Script `.sh` copié une fois via `scp`, jamais un `git pull` | [#5](#5-scripts-de-déploiement-non-synchronisés-avec-git) |
| En-têtes de sécurité HTTP dupliqués (`X-Frame-Options: DENY, SAMEORIGIN`, etc.) | nginx et Spring Security posent chacun les leurs, sans coordination | [#6](#6-en-têtes-de-sécurité-dupliqués-nginxspring) |
| Page d'accueil `200 OK` mais toutes les ressources JS/CSS en `404` dans le navigateur | `root` nginx pointe vers le dossier par défaut de l'image, pas vers le build Angular | [#7](#7-assets-statiques-en-404-mauvaise-racine-nginx) |
| Port 80/443/22 injoignable depuis Internet, alors qu'UFW les autorise et qu'une session SSH déjà ouverte continue de fonctionner | Vérifier le **DNS avant tout** — l'IP peut être fausse (typo) avant de suspecter un blocage réseau hébergeur | [#8](#8-fausse-piste--blocage-réseau-hébergeur) |
| `sudo` refuse un utilisateur créé avec `adduser --disabled-password` | Pas de `NOPASSWD` configuré pour un utilisateur sans mot de passe | [#9](#9-sudo-impossible-pour-lutilisateur-deploy) |
| `git push` sur un deploy key échoue avec `Key is already in use` | Une clé de déploiement GitHub ne peut servir qu'à **un seul** dépôt | [#10](#10-clé-de-déploiement-github-réutilisée) |
| Boucle Spring/Hibernate au démarrage avec `SPRING_PROFILES_ACTIVE=prod` | Dépendance circulaire de bean révélée seulement par le profil `prod` | [#11](#11-dépendance-circulaire-de-bean-spring) |

---

## 1. `map_hash_bucket_size` trop petit

**Contexte.** `kovixel-ui/docker/nginx.conf.template`, bloc `map $request_uri $loggable_uri`.

**Symptôme.** nginx refuse de démarrer :
```
could not build map_hash, you should increase map_hash_bucket_size: 64
```

**Cause.** La valeur par défaut (64 octets, taille d'une ligne de cache CPU) est trop
petite pour la clé du bloc `map` une fois celle-ci entre guillemets (nécessaire, voir
[#2](#2-bloc-map-non-quoté)).

**Fix (déjà en place).** `map_hash_bucket_size 128;` ajouté en tête du bloc `http {}`.

**Pourquoi jamais vu avant.** `kovixel-ui` n'avait jamais tourné avec ce bloc
effectivement chargé avant ce premier déploiement réel (dev local utilise `ng serve`,
qui ne passe jamais par ce nginx).

---

## 2. Bloc `map` non quoté

**Contexte.** Même fichier, juste avant #1.

**Symptôme.** `nginx: [emerg] ... unexpected "{" in nginx.conf:20` — piste explorée à
tort : absence de support PCRE dans nginx Alpine (**infirmé** via `ldd`/`strings`,
PCRE2 était bien lié).

**Cause réelle.** Le tokenizer de nginx confond les accolades d'un quantificateur
regex (`{10,}`) avec des délimiteurs de bloc, **sauf si le motif et le remplacement
sont entre guillemets**. Ce n'est pas documenté de façon évidente dans les messages
d'erreur nginx.

**Fix (déjà en place).**
```nginx
map $request_uri $loggable_uri {
    "~^(/api/v1/organizations/invitations/)[^/?&]{10,}(.*)$"  "$1[REDACTED]$2";
    default $request_uri;
}
```

**Règle à retenir.** Tout bloc `map` (ou toute directive regex nginx) dont le motif
contient `{` ou `}` DOIT être entre guillemets, y compris le remplacement.

---

## 3. Conflit de port 80 entre `kovixel-ui` et Caddy

**Contexte.** `docker-compose.yml` publiait `kovixel-ui` sur `"80:80"` (toutes
interfaces), et `05-setup-tls-caddy.sh` installe Caddy pour écouter aussi sur
`:80`/`:443` en frontal.

**Symptôme.**
```
systemctl status caddy
...
bind: address already in use
```

**Cause.** Deux process voulaient écouter sur le port 80 de l'hôte simultanément.

**Fix (déjà en place).**
- `docker-compose.yml` : `kovixel-ui` publie désormais `"127.0.0.1:8080:80"`
  (interne uniquement).
- `kovixel-ui/docker/CLOUDFLARE_RUNBOOK.md`'s companion, `05-setup-tls-caddy.sh` :
  `reverse_proxy localhost:8080` (au lieu de `localhost:80`).

**Piège pour la prod.** Si un jour Cloudflare Tunnel ou un autre reverse proxy TLS
est utilisé à la place de Caddy, il doit lui aussi cibler `localhost:8080`, jamais
`:80` directement.

---

## 4. Boucle de redirection HTTPS (`X-Forwarded-Proto` écrasé)

**Contexte.** `kovixel-ui/docker/nginx.conf.template`, locations `/api/` et `@ssr`.

**Symptôme.** `curl -IL https://staging.kovixel.com/...` boucle indéfiniment sur un
`308` dont le `Location` est **la même URL**, jusqu'à épuiser `--max-redirs`.

**Cause.** Caddy (TLS en frontal) ajoute correctement `X-Forwarded-Proto: https` en
proxyfiant vers `kovixel-ui`. Mais `kovixel-ui`/nginx **écrasait** cet en-tête avec
`proxy_set_header X-Forwarded-Proto $scheme;` — et `$scheme`, du point de vue de
nginx, vaut `http` (Caddy lui parle en clair en interne). Le backend Spring recevait
donc toujours `X-Forwarded-Proto: http`, se croyait non sécurisé, et forçait une
redirection vers `https://` de la même URL — qui repassait par le même nginx, qui
réécrasait à nouveau l'en-tête. Boucle infinie entièrement côté serveur.

**Comment le diagnostiquer rapidement.** Les en-têtes de la réponse en boucle ne
contenaient QUE des en-têtes Caddy (`server: Caddy`, `alt-svc`), sans aucun en-tête
nginx/Spring (CSP, `X-Content-Type-Options`, etc.) — signe que la boucle se refermait
avant même d'atteindre le reste de la chaîne, ou dans les cas où elle boucle après
nginx, qu'aucune couche en aval ne "gagne" jamais.

**Fix (déjà en place).**
```nginx
map $http_x_forwarded_proto $proxy_x_forwarded_proto {
    default $http_x_forwarded_proto;
    ""      $scheme;
}
# ... puis dans chaque location proxy_pass :
proxy_set_header X-Forwarded-Proto $proxy_x_forwarded_proto;
```
Préserve l'en-tête entrant s'il existe déjà (Caddy, Cloudflare), ne retombe sur
`$scheme` que si aucun proxy TLS n'est devant (accès direct dev/CI local).

**Piège pour la prod.** Si Cloudflare termine le TLS en Full/Flexible au lieu de
Caddy, vérifier qu'il envoie bien `X-Forwarded-Proto: https` — Cloudflare le fait par
défaut, mais toute variante de proxy custom doit être vérifiée avec le même test
(`curl -IL`, s'assurer qu'il n'y a jamais plus d'une redirection).

---

## 5. Scripts de déploiement non synchronisés avec Git

**Contexte.** Les scripts de `deploy/scripts/` sont documentés comme copiés une fois
sur le VPS via `scp` (voir `staging/README.md` historique).

**Symptôme.** Un bug corrigé dans `05-setup-tls-caddy.sh` (voir #3), commité et
poussé sur `kovixel-docs`, **n'avait aucun effet** lors d'une deuxième exécution du
script sur le VPS — celui-ci utilisait encore l'ancienne copie `scp`-ée en tout début
de déploiement, plusieurs heures/jours plus tôt.

**Cause.** `~/kovixel-app/` sur le VPS n'est PAS un checkout git de `kovixel-docs` —
seuls `kovixel/` et `kovixel-ui/` (via `04-deploy.sh`) le sont. Les scripts eux-mêmes
n'ont pas de mécanisme de mise à jour automatique.

**Fix appliqué dans l'incident.** Re-`scp` manuel du script corrigé.

**Fix structurel (recommandé, voir `staging/README.md` mis à jour) :** cloner
`kovixel-docs` sur le VPS au lieu de copier les scripts un par un :
```bash
git clone <url-git-kovixel-docs> ~/kovixel-app/kovixel-docs
# puis, avant CHAQUE exécution d'un script :
cd ~/kovixel-app/kovixel-docs && git pull --ff-only
bash src/deploy/scripts/<script>.sh ...
```
Élimine structurellement la classe de bug entière (script obsolète silencieusement
réexécuté).

---

## 6. En-têtes de sécurité dupliqués (nginx/Spring)

**Contexte.** `kovixel-ui/docker/nginx.conf.template` pose des `add_header` de
sécurité au niveau `server {}` (hérités par toutes les `location`, y compris
`/api/`) ; `SecurityConfig.java` pose également les siens côté Spring.

**Symptôme.** Réponses `/api/*` avec des en-têtes en double, parfois contradictoires :
```
x-frame-options: DENY
x-frame-options: SAMEORIGIN
content-security-policy: default-src 'self'; frame-ancestors 'none'
content-security-policy: default-src 'self'; script-src ... (CSP orientée SPA)
```

**Cause.** Aucune coordination entre les deux couches — chacune ignore l'existence de
l'autre.

**Fix (déjà en place).** Dans la `location /api/`, un unique
`add_header X-Frame-Options "" always;` — en nginx, dès qu'**un seul** `add_header`
est déclaré au niveau d'une location, **tout** l'héritage des `add_header` du niveau
parent est coupé (pas fusionné). Cette seule ligne empêche donc nginx d'ajouter quoi
que ce soit sur `/api/`, laissant Spring Security seul maître des en-têtes de
sécurité pour l'API JSON. Le frontend (SSR/statique) garde les en-têtes nginx,
adaptés au rendu HTML.

**Piège pour la prod.** Si un jour un `add_header` supplémentaire est ajouté au
niveau `server {}` en pensant qu'il s'appliquera partout, il **ne s'appliquera pas**
à `/api/` à cause de cette règle d'héritage — vérifier explicitement avec
`curl -I` sur une route API après tout changement d'en-tête.

---

## 7. Assets statiques en 404 (mauvaise racine nginx)

**Contexte.** `kovixel-ui/docker/nginx.conf.template`, directive `root`.

**Symptôme.** `curl -I https://staging.kovixel.com/` renvoie `200` avec du HTML
valide — mais dans le navigateur, **toutes** les ressources référencées
(`main-*.js`, `chunk-*.js`, `polyfills-*.js`, `styles-*.css`, `favicon.svg`, etc.)
renvoient `404`. C'est le bug le plus trompeur de la série : la page "marche" en
apparence (curl sur `/` est vert) alors que l'app est en réalité totalement cassée.

**Cause.** `root /usr/share/nginx/html;` pointait vers le dossier par défaut de
l'image `nginx:1.27-alpine` (qui ne contient que la page d'accueil nginx par
défaut). Le build Angular SSR est copié par le `Dockerfile` dans
`/app/dist/kovixel-ui/browser` (structure standard d'un `ng build --ssr`, séparée
du dossier `server/` pour le rendu Node). `/` fonctionnait quand même car
`try_files $uri @ssr` retombe sur le serveur Node/Express (`x-powered-by: Express`
visible dans les en-têtes), qui lui lit le bon chemin — mais la location dédiée aux
assets statiques hashés (`location ~* \.(js|css|...)`) cherchait dans le mauvais
dossier.

**Fix (déjà en place).**
```nginx
root /app/dist/kovixel-ui/browser;
```

**Comment le détecter plus tôt la prochaine fois.** `curl -I` sur `/` seul ne suffit
PAS à valider un déploiement frontend — il faut vérifier qu'au moins une ressource
statique référencée par la page répond aussi en `200`. `health-check.sh` a été mis à
jour pour le faire automatiquement (extraction d'un `<script src=...>` depuis le HTML
retourné, puis vérification de son statut).

---

## 8. Fausse piste : "blocage réseau hébergeur"

**Contexte.** Diagnostic de connectivité pendant la mise en place de #3/#4.

**Symptôme.** `check-host.net` (test TCP multi-pays) rapportait "Connection timed
out" sur les ports 80/443 depuis absolument tous les points du globe, alors qu'UFW
autorisait ces ports et qu'une session SSH déjà établie continuait de fonctionner.

**Fausse piste suivie (~1h de diagnostic).** Suspicion de null-route/DDoS mitigation
côté Contabo — ticket support ouvert, migration live du VPS effectuée par Contabo
(host physique effectivement surchargé, mais **non lié** au symptôme réseau), avant
que la vraie cause soit trouvée.

**Cause réelle.** L'enregistrement DNS `A` de `staging.kovixel.com` pointait vers une
IP (`168.58.101.224`) qui n'était **jamais** celle du VPS (la vraie IP était
`169.58.101.224` — simple erreur de frappe/communication lors de la récupération de
l'IP auprès de l'hébergeur). Le SSH continuait de fonctionner car la connexion se
faisait directement vers la bonne IP, sans jamais passer par le DNS.

**Comment l'éviter/le détecter en 30 secondes la prochaine fois, AVANT toute
hypothèse réseau complexe :**
```bash
# Depuis le VPS, source de vérité absolue pour sa propre IP publique :
curl -s https://ifconfig.me
# Comparer avec :
nslookup <domaine> 8.8.8.8
```
Si les deux ne correspondent pas → corriger le DNS, point final. Ne creuser une
hypothèse de firewall/DDoS hébergeur qu'**après** avoir confirmé que le DNS pointe
bien vers la bonne IP. `staging/README.md` inclut désormais cette vérification comme
étape explicite avant la configuration TLS.

---

## 9. `sudo` impossible pour l'utilisateur `deploy`

**Cause.** Un utilisateur créé avec `adduser --disabled-password` (auth par clé SSH
uniquement) ne peut par définition jamais satisfaire une invite de mot de passe
`sudo` interactive.

**Fix (déjà en place dans `01-harden-server.sh`).** Ajout de
`/etc/sudoers.d/${DEPLOY_USER}` avec `NOPASSWD:ALL` à la création de l'utilisateur.

---

## 10. Clé de déploiement GitHub réutilisée

**Symptôme.** `git push`/`git pull` échoue avec `Key is already in use` lors de
l'ajout d'une deuxième clé de déploiement (deploy key) déjà utilisée sur un autre
dépôt.

**Cause.** GitHub interdit qu'une même clé publique serve de deploy key à plus d'un
dépôt.

**Fix appliqué.** Une clé SSH distincte par dépôt (`id_ed25519_kovixel`,
`id_ed25519_kovixel_ui`), avec des alias `Host` dans `~/.ssh/config` :
```
Host github.com-kovixel
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_kovixel

Host github.com-kovixel-ui
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_kovixel_ui
```
et les remotes clonés avec l'alias correspondant plutôt que `github.com` directement.

---

## 11. Dépendance circulaire de bean Spring

**Symptôme.** Le backend refuse de démarrer **uniquement** avec
`SPRING_PROFILES_ACTIVE=prod` (jamais vu en profil `dev`), avec une erreur de
dépendance circulaire impliquant `entityManagerFactory`.

**Cause.** Deux beans profil-spécifiques (`FlywayConfig`, actif seulement en
`@Profile("prod")`) ou avec des dépendances runtime tardives
(`DocumentLifecycleListener` → `UserRepository`) créaient un cycle avec
`entityManagerFactory` uniquement visible quand ces beans sont réellement
instanciés — ce qui n'arrive qu'en profil `prod`.

**Fix (déjà en place).** `@Lazy` au niveau du **paramètre du constructeur explicite**
— pas sur le champ avec `@RequiredArgsConstructor` de Lombok, qui ne recopie pas
l'annotation sur le paramètre généré :
```java
public FlywayConfig(@Lazy BackupService backupService) {
    this.backupService = backupService;
}
```

**Piège pour la prod.** Tout nouveau bean `@Profile("prod")` ou avec des dépendances
qui remontent vers des repositories JPA doit être testé avec
`SPRING_PROFILES_ACTIVE=prod` **avant** le déploiement staging/prod, pas découvert
en même temps que le premier vrai déploiement. Envisagé : ajouter un test
d'intégration qui démarre le contexte Spring complet avec le profil `prod` en CI
(actuellement non fait, cf. `../README.md` — CI/CD explicitement différé).
