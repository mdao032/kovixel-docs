# Déploiement Kovixel — dev / staging / prod

> Documentation opérationnelle de déploiement, distincte des roadmaps fonctionnelles
> (`kovixel-docs/src/roadmaps/`). Ce dossier répond à une seule question : **comment
> faire tourner Kovixel dans chaque environnement, de la machine du développeur au
> serveur de production.**

## Vue d'ensemble

| Environnement | Où | Comment | Guide |
|---|---|---|---|
| **Dev** | Poste du développeur (Windows/Mac/Linux) | Backend/Frontend natifs + infra Docker minimale | [dev/README.md](dev/README.md) |
| **Staging** | VPS dédié, isolé de la prod | Stack Docker Compose complète, profil `prod` | [staging/README.md](staging/README.md) |
| **Prod** | VPS dédié (dimensionné après validation staging) | Identique à staging + durcissement additionnel | [prod/README.md](prod/README.md) |

Staging et prod utilisent **la même image Docker et le même `docker-compose.yml`** —
c'est le point : un environnement de staging qui diverge de la prod ne teste rien
d'utile. Seuls diffèrent le domaine, les credentials, et quelques garde-fous
(voir [prod/README.md](prod/README.md) pour la liste des écarts volontaires).

## Arbre de décision rapide

- **Je développe une fonctionnalité au quotidien** → [dev/README.md](dev/README.md)
- **Je prépare un premier VPS pour valider un déploiement réel avant la prod**
  → [staging/README.md](staging/README.md)
- **Le staging est validé, je passe en production réelle avec des utilisateurs**
  → [prod/README.md](prod/README.md) puis [prod/CHECKLIST_GO_LIVE.md](prod/CHECKLIST_GO_LIVE.md)

## Contenu de ce dossier

```
deploy/
├── README.md                 — ce fichier
├── TROUBLESHOOTING.md         — bugs réels rencontrés en déploiement, cause + fix
├── ENV_VARIABLES.md           — référence complète des variables d'environnement
├── dev/README.md              — guide développeur (natif + docker-compose.infra.yml)
├── staging/README.md          — guide staging pas à pas (VPS Contabo ou équivalent)
├── prod/README.md             — écarts staging→prod + guide de bascule
├── prod/CHECKLIST_GO_LIVE.md  — checklist de mise en production
└── scripts/                   — scripts partagés staging/prod (idempotents, testés)
    ├── 01-harden-server.sh        — durcissement OS (SSH, UFW, fail2ban)
    ├── 02-install-docker.sh       — installation Docker + Compose
    ├── 03-generate-secrets.sh     — génère un .env avec des secrets forts
    ├── 04-deploy.sh                — clone/pull + build + up + healthcheck
    ├── 05-setup-tls-caddy.sh       — TLS automatique (Let's Encrypt via Caddy)
    └── health-check.sh             — vérification post-déploiement (HTTP + assets + redirections)
```

> 📖 **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** recense, avec cause racine et
> correctif, tous les bugs réels rencontrés lors du premier déploiement staging
> (nginx, Caddy, DNS, en-têtes de sécurité, dépendances circulaires Spring...).
> Tous sont déjà corrigés dans le code à ce jour — ce document sert de référence
> rapide si un symptôme similaire réapparaît, et de check-list de non-régression
> avant la bascule prod.

## Principes qui traversent tous les environnements

1. **`.env` n'est jamais commité.** Chaque environnement a le sien, généré depuis
   `kovixel/.env.example` (voir [ENV_VARIABLES.md](ENV_VARIABLES.md) pour le détail
   variable par variable — obligatoire/optionnel, où l'obtenir, ce qui casse si absent).
2. **`ENCRYPTION_MASTER_KEY` et `BACKUP_ENCRYPTION_KEY` ne se régénèrent jamais**
   une fois des données réelles chiffrées derrière — leur perte est irréversible
   (crypto-shredding involontaire des documents / backups). Sauvegardées dans un
   gestionnaire de secrets externe (1Password, Vault) dès leur génération.
3. **Staging et prod tournent en profil Spring `prod`** (`SPRING_PROFILES_ACTIVE=prod`)
   — c'est le profil qui active MinIO, le cookie sécurisé, le CORS restreint, et
   sépare le port de management (9090) du port applicatif (8080). Le profil `dev`
   (par défaut si `docker-compose.yml` est lancé sans configuration) est réservé au
   développement local sans Docker complet.
4. **Aucun secret ne doit apparaître dans les logs de déploiement, l'historique
   shell, ou un ticket/PR.** Les scripts de ce dossier génèrent les secrets
   directement dans `.env` (jamais affichés en clair sur la sortie standard).
