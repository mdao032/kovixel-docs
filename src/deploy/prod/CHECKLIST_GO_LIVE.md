# Checklist — Go-live production

> À parcourir intégralement avant de basculer le DNS de production vers le VPS
> réel (ou avant de retirer un éventuel "coming soon"). Chaque case cochée doit
> correspondre à une vérification réellement effectuée, pas à une supposition.

## Infrastructure

- [ ] VPS de prod distinct du staging, dimensionné selon les résultats du test de
      charge (§6 de `../prod/README.md`).
- [ ] `01-harden-server.sh` exécuté — SSH par clé uniquement, UFW actif, fail2ban actif.
- [ ] `.env` généré avec des secrets **différents** de ceux du staging
      (`JWT_SECRET`, `ENCRYPTION_MASTER_KEY`, `REDIS_PASSWORD`, `MINIO_ROOT_PASSWORD`).
- [ ] `ENCRYPTION_MASTER_KEY` et `BACKUP_ENCRYPTION_KEY` sauvegardées dans un
      gestionnaire de secrets externe (1Password/Vault), pas seulement sur le VPS.
- [ ] `SPRING_PROFILES_ACTIVE=prod` confirmé (`docker compose exec kovixel-app-1 env | grep SPRING_PROFILES_ACTIVE`).
- [ ] `docker compose ps` — tous les conteneurs `healthy`, aucun redémarrage en boucle.

## Réseau / TLS

- [ ] DNS de prod pointe vers le bon VPS (`dig app.kovixel.com` ou équivalent).
- [ ] HTTPS fonctionnel (`curl -I https://app.kovixel.com/api/v1/health` → 200).
- [ ] `KOVIXEL_COOKIE_SECURE=true` (sinon aucune session ne persiste en HTTPS).
- [ ] `CORS_ALLOWED_ORIGINS` = domaine de prod exact (pas celui du staging).
- [ ] Si Cloudflare : verrou d'origine actif ET vérifié (`CLOUDFLARE_RUNBOOK.md`
      §10 — la requête directe à l'IP origin renvoie bien 403).

## Fonctionnel

- [ ] Inscription email/mot de passe + email de vérification reçu.
- [ ] Connexion OAuth (Google au minimum) avec l'URL de callback de **prod**
      déclarée côté fournisseur (pas celle du staging).
- [ ] Upload PDF, résumé IA, Q&A — testés avec les vraies clés Anthropic/OpenAI
      de prod (pas des clés partagées avec le staging, pour un suivi de coût propre).
- [ ] Paiement Stripe testé en mode `live` (pas `test`) si la facturation est activée.
- [ ] Au moins un cycle de conversion PRO (Adobe) si des utilisateurs PRO existent déjà.

## Sécurité / conformité

- [ ] Grafana/Prometheus non exposés publiquement (UFW restreint ou tunnel SSH).
- [ ] `PLATFORM_ADMIN_ALLOWED_EMAILS` renseigné si la console Super Admin est utilisée.
- [ ] `PSSI_POLITIQUE_SECURITE_DONNEES.md` / DPIA / registre des traitements à jour
      avec l'environnement de prod réel (sous-traitants IA, hébergeur — cf.
      `kovixel-docs/src/compliance/`).

## Sauvegarde / continuité

- [ ] Un backup automatique s'est bien exécuté au moins une fois (`BACKUP_CRON`) —
      vérifier dans les logs de `BackupService`, pas juste que `BACKUP_ENABLED=true`.
- [ ] Une restauration depuis ce backup a été testée sur un environnement jetable.
- [ ] Décision actée sur l'alerting sortant (§3 de `../prod/README.md`) — pas
      seulement "Prometheus tourne".

## Après bascule

- [ ] Surveillance rapprochée des dashboards Grafana pendant les premières 24-48h.
- [ ] Vérifier qu'aucune alerte `alerts.yml` n'est en état "firing" de façon
      persistante (`http://<ip>:9090/alerts`, via le tunnel SSH).
