# Registre des traitements (RGPD Art. 30)

**ROADMAP_CHIFFREMENT.md Sprint E-8.3.** Registre tenu par le responsable de traitement (Kovixel).
Chaque fiche décrit un traitement au sens de l'Art. 30 : finalité, base légale, données, durée de
conservation, destinataires, mesures de sécurité. Dernière mise à jour : 2026-07-25.

## Fiche 1 — Traitement des fichiers uploadés

- **Finalité** : conversion, signature, résumé et interrogation (Q&A) de documents pour le compte
  de l'utilisateur.
- **Base légale** : exécution du contrat (CGU) — le traitement du fichier EST le service demandé.
- **Personnes concernées** : utilisateurs authentifiés et visiteurs anonymes (session invité).
- **Données traitées** : contenu du fichier, titre, type MIME, taille.
- **Durée de conservation** : différenciée par plan (2h invité, 24h FREE, 30-90j PRO/PRO_PLUS,
  365-730j TEAM/ENTERPRISE) — voir DPIA §2. Crypto-shredding à expiration, suppression physique
  48h après.
- **Destinataires** : aucun tiers. Stockage interne (MinIO en prod, disque local en dev).
- **Transfert hors UE** : aucun (hébergement en France, cf. mention landing "Données en France").
- **Mesures de sécurité** : chiffrement AES-256-GCM au repos (envelope encryption, DEK unique par
  fichier), clé de chiffrement dérivée par HKDF-SHA256, jamais stockée en clair (Sprints E-1/E-2).

## Fiche 2 — Analyse IA des documents (résumé, Q&A, extraction, traduction)

- **Finalité** : générer un résumé, répondre à des questions sur le contenu, extraire des données
  structurées, traduire un document.
- **Base légale** : **exécution du contrat** — le traitement IA (via Claude/OpenAI) est intrinsèque
  aux fonctionnalités souscrites (résumé, Q&A, extraction) ; plus de mode local alternatif depuis
  le retrait d'Ollama (ROADMAP_BASCULE_CLAUDE.md Sprints C-1/C-2/C-4).
- **Personnes concernées** : utilisateurs ayant activé le traitement IA cloud ; utilisateurs
  anonymes pour les fonctionnalités IA accessibles sans compte (quota IP limité).
- **Données traitées** : contenu du document (texte extrait), question posée par l'utilisateur.
- **Durée de conservation** : alignée sur celle du document source (fiche 1) ; l'historique de
  session Q&A suit le cycle de vie du document.
- **Destinataires** : sous-traitants IA cloud — Anthropic/Claude (génération) et OpenAI (embeddings
  RAG). Plus de traitement local (Ollama retiré, ROADMAP_BASCULE_CLAUDE.md Sprints C-1/C-2/C-4).
- **Transfert hors UE** : possible si sous-traitant cloud hors UE — un accord de sous-traitance
  (DPA) avec le fournisseur IA doit couvrir ce point (hors périmètre technique de ce registre).
- **Mesures de sécurité** : opt-in explicite et réversible, aucune donnée envoyée à un tiers sans
  consentement enregistré.

## Fiche 3 — Journal d'audit (accès fichiers et authentification)

- **Finalité** : traçabilité de sécurité — détecter un accès anormal, enquêter en cas d'incident,
  démontrer la conformité (RGPD Art. 30 lui-même, ISO 27001 A.12.4).
- **Base légale** : intérêt légitime (sécurité du service) et, pour les événements
  d'authentification, obligation légale implicite de traçabilité des accès à des données
  personnelles.
- **Personnes concernées** : tout utilisateur effectuant une action tracée (upload, téléchargement,
  aperçu, suppression de fichier ; connexion, échec de connexion, changement de mot de passe).
- **Données traitées** : identifiant utilisateur, clé de stockage du fichier concerné, action,
  adresse IP, user-agent, horodatage, code d'erreur le cas échéant.
- **Durée de conservation** : 90 jours (configurable, `kovixel.encryption.audit-retention-days`),
  purge automatique quotidienne (`FileAccessEventPurgeJob`, Sprint E-6).
- **Destinataires** : équipe technique Kovixel (rôles `PLATFORM_ADMIN`/`PLATFORM_SUPPORT` selon le
  type d'événement) — jamais transmis à un tiers.
- **Transfert hors UE** : aucun.
- **Mesures de sécurité** : écriture asynchrone (n'expose jamais le flux applicatif principal à un
  échec d'audit), accès restreint par rôle.

## Fiche 4 — Compte utilisateur et authentification

- **Finalité** : création et gestion du compte, authentification, gestion de l'abonnement.
- **Base légale** : exécution du contrat.
- **Personnes concernées** : tout utilisateur inscrit.
- **Données traitées** : email, mot de passe (haché BCrypt, jamais en clair), prénom/nom, plan
  tarifaire, préférences (thème, mode de traitement), secret TOTP si 2FA activée (chiffré).
- **Durée de conservation** : jusqu'à suppression du compte par l'utilisateur ou sur demande RGPD.
- **Destinataires** : Stripe pour la gestion de l'abonnement (référence d'abonnement uniquement,
  aucune donnée bancaire — délégué à Stripe, PCI-DSS).
- **Transfert hors UE** : dépend de la localisation des infrastructures Stripe (à documenter côté
  contrat Stripe, hors périmètre technique).
- **Mesures de sécurité** : hachage BCrypt-12, chiffrement du secret TOTP (ancré par utilisateur,
  Sprint E-4), sessions par refresh-token rotatif (`RefreshTokenService`).

## Fiche 5 — Anti-fraude et anti-abus (antibot)

- **Finalité** : protéger le service gratuit contre l'abus automatisé (scraping, contournement de
  quota, création de comptes en masse).
- **Base légale** : intérêt légitime.
- **Personnes concernées** : tout visiteur du service (authentifié ou non).
- **Données traitées** : empreinte navigateur (fingerprint), score de risque calculé, adresse IP.
- **Durée de conservation** : à documenter précisément côté `com.kovixel.antibot` (hors périmètre
  de ce sprint chiffrement — se référer à `ANTIBOT_ROADMAP.md` pour le détail).
- **Destinataires** : aucun tiers.
- **Transfert hors UE** : aucun.
- **Mesures de sécurité** : mode "shadow" strict pour le moteur de risque (calcule et trace, n'agit
  jamais seul sur la décision, cf. commentaire `SecurityConfig.RiskEvaluationFilter`).

## Notes de tenue du registre

- Ce registre a été rédigé dans le cadre du Sprint E-8 (ROADMAP_CHIFFREMENT.md) et couvre les
  traitements liés au chiffrement/sécurité des données. D'autres traitements existants côté
  produit (facturation détaillée, marketing/newsletter le cas échéant) doivent être ajoutés par
  l'équipe produit/juridique s'ils existent et ne sont pas encore documentés ici.
- À maintenir à jour à chaque nouveau traitement introduisant une nouvelle finalité ou catégorie
  de données.
