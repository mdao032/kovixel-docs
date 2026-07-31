# Développement local

> Backend et frontend tournent **nativement** (hot-reload Maven/Angular), seule
> l'infrastructure (Postgres, Redis, MinIO, Gotenberg, MailHog) est containerisée
> via `docker-compose.infra.yml`. C'est délibérément différent de staging/prod
> (`docker-compose.yml` complet) — le hot-reload est incompatible avec un jar
> packagé dans une image Docker.

## Prérequis

- JDK 21, Maven (ou le wrapper `./mvnw`)
- Node.js (version alignée sur `kovixel-ui/package.json`)
- Docker Desktop (Windows/Mac) ou Docker Engine (Linux)

## 1. Infrastructure

```bash
cd kovixel
docker compose -f docker-compose.infra.yml up -d
```

Démarre Postgres+pgvector, Redis, MinIO, Gotenberg, MailHog — tous exposés sur
`localhost` (voir `docker-compose.infra.yml` pour le détail des ports).

## 2. Configuration

```bash
cp .env.example .env
```

Remplir au minimum : `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `JWT_SECRET`,
`ENCRYPTION_MASTER_KEY` (`openssl rand -hex 32` pour les deux derniers). Le reste
peut rester aux valeurs par défaut du fichier — elles sont pensées pour le dev
local (`KOVIXEL_COOKIE_SECURE=false`, `MAIL_HOST=localhost` + MailHog, etc.).
Voir [../ENV_VARIABLES.md](../ENV_VARIABLES.md) pour le détail de chaque variable.

`SPRING_PROFILES_ACTIVE` n'a pas besoin d'être positionné : le profil `dev`
(`LocalFileStorageService`, pas de restriction CORS stricte) est le défaut de
l'application quand ce script démarre l'app directement (pas via
`docker-compose.yml`).

## 3. Lancer le backend

Depuis la racine du monorepo (`E:\Projets\kovixel-all`), les scripts existants
chargent `.env` et lancent Maven :

```bash
./start-back.cmd     # ou start-back.ps1 sous PowerShell
```

Équivalent manuel : `cd kovixel && mvn spring-boot:run -Dspring-boot.run.profiles=dev`.

## 4. Lancer le frontend

```bash
./start-front.cmd
```

Équivalent manuel : `cd kovixel-ui && npm start`.

## Vérification

```bash
curl http://localhost:8080/api/v1/health
```

Frontend sur `http://localhost:4200` (Angular dev server) ou le port configuré
dans `kovixel-ui/angular.json`.

## Différences avec staging/prod à garder en tête

- Pas de MinIO utilisé pour le stockage réel (profil `dev` → stockage disque local
  `STORAGE_PATH`) — un bug spécifique à `MinioFileStorageService` ne se verra
  qu'en staging.
- Pas de load balancer / 2 répliques — le comportement stateless (JWT, quotas
  Redis) n'est vérifié en conditions réelles qu'en staging (`ROADMAP_CAPACITE_INITIALE.md`
  Correction 3).
- CORS/cookie non stricts — un bug d'origine ou de cookie `SameSite` peut passer
  inaperçu en dev et n'apparaître qu'une fois `KOVIXEL_COOKIE_SECURE=true` en staging.

Ces trois écarts sont exactement la raison d'être du staging — ne pas essayer de
les combler en dev, plutôt valider explicitement dessus avant toute mise en prod.
