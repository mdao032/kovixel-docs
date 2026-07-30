# Analyse d'impact relative à la protection des données (DPIA/AIPD)

**ROADMAP_CHIFFREMENT.md Sprint E-8.2 — RGPD Art. 25 (Privacy by Design).** Ce document analyse
les risques pour les droits et libertés des personnes concernées, liés au traitement de leurs
données par Kovixel, et documente les mesures techniques et organisationnelles mises en œuvre pour
les réduire. Périmètre : traitements existants au 2026-07-25.

## 1. Données collectées et base légale

| Catégorie de donnée | Exemples | Base légale | Composant |
|---|---|---|---|
| Identité et compte | Email, mot de passe (haché BCrypt-12), prénom/nom, plan tarifaire | Exécution du contrat (CGU) | `User` |
| Fichiers uploadés | PDF, Word, images et leur contenu | Exécution du contrat (le service consiste à traiter ces fichiers) | `Document`, chiffrés AES-256-GCM (Sprint E-2) |
| Titres de document | Nom du fichier tel que fourni par l'utilisateur | Exécution du contrat | Chiffré (Sprint E-4, `DocumentTitleConverter`) |
| Secret TOTP (2FA) | Secret partagé pour authentification à deux facteurs | Consentement (fonctionnalité optionnelle) | Chiffré (Sprint E-4, ancré par utilisateur) |
| Traitement IA des documents | Contenu envoyé à un fournisseur IA cloud (Claude/Anthropic pour la génération, OpenAI pour les embeddings RAG — ROADMAP_BASCULE_CLAUDE.md, plus de traitement local Ollama depuis les Sprints C-1/C-2) pour résumé/Q&A/extraction | Exécution du contrat (le service consiste à traiter ces fichiers via IA cloud) | Services IA (`AiRoutingService`) |
| Paiement | Référence d'abonnement Stripe (pas de numéro de carte — délégué à Stripe, PCI-DSS) | Exécution du contrat | Module paiement |
| Anti-fraude / anti-bot | Empreinte navigateur (fingerprint), score de risque, adresse IP | **Intérêt légitime** (protection contre l'abus du service gratuit, fraude) | `com.kovixel.antibot` |
| Journal d'authentification | Connexions, échecs, changements de mot de passe, sessions actives | **Intérêt légitime** / obligation légale (traçabilité sécurité) | `AuthEventService`, `RefreshTokenService` |
| Audit d'accès fichier | Qui a consulté/téléchargé quel fichier, quand, depuis quelle IP | **Intérêt légitime** (RGPD Art. 30, détection d'incident) | `file_access_events` (Sprint E-6) |

## 2. Durées de rétention par type de donnée et par plan

| Donnée | Rétention | Mécanisme |
|---|---|---|
| Fichiers — invité (sans compte) | 2 heures après upload | `RetentionPolicy.ANONYMOUS` |
| Fichiers — plan FREE | 24h après upload, 24h après dernier accès | `RetentionPolicy.uploadRetention/accessRetention(FREE)` |
| Fichiers — PRO / PRO_PLUS | 30 jours après upload, 90 jours après dernier accès | idem (`PRO`) |
| Fichiers — TEAM / ENTERPRISE | 365 jours après upload, 730 jours après dernier accès | idem (`TEAM`/`ENTERPRISE`) — valeur par défaut la plus généreuse, pas encore configurable par organisation |
| Fichier après expiration | Illisible immédiatement (crypto-shredding), octets supprimés physiquement 48h après | `DocumentCleanupJob`, Sprint E-5 |
| Journal d'audit fichier (`file_access_events`) | 90 jours (configurable) | `FileAccessEventPurgeJob`, Sprint E-6, RGPD Art. 30 |
| Compte utilisateur | Jusqu'à suppression explicite par l'utilisateur ou demande RGPD | Export/suppression RGPD (cf. Team Admin) |

## 3. Mesures techniques (résumé — détail dans le PSSI)

- **Chiffrement au repos** : AES-256-GCM pour fichiers, secrets TOTP, titres de document
  (Sprints E-1 à E-4). Chiffrement en transit : TLS (terminé en amont par le CDN, cf. Sprint E-7).
- **Crypto-shredding** : le droit à l'effacement (RGPD Art. 17) est garanti techniquement, pas
  seulement procéduralement — révoquer la clé d'un fichier le rend immédiatement et
  irréversiblement illisible, avant même la suppression physique des octets.
- **Pseudo-anonymisation partielle** : le titre de document est chiffré (illisible en base sans la
  clé applicative) ; un hash (`titleHash`) permet des opérations d'égalité sans déchiffrement.
- **Isolation des clés** : chaque fichier a sa propre clé de chiffrement (DEK) — la compromission
  d'un fichier ne compromet pas les autres (ADR-001, envelope encryption).
- **Traçabilité des accès** : tout accès à un fichier (upload, téléchargement, aperçu, suppression)
  est journalisé avec horodatage et IP (Sprint E-6) — permet de répondre à une demande d'accès
  Art. 15 avec précision, et de détecter un accès anormal.
- **Minimisation** : le traitement IA est nécessaire à l'exécution du contrat (le service consiste
  à traiter les documents via IA) — depuis le retrait d'Ollama (ROADMAP_BASCULE_CLAUDE.md, Sprints
  C-1/C-2), il n'existe plus de mode de traitement local ; toutes les requêtes IA transitent par
  Claude (génération) ou OpenAI (embeddings RAG).

## 4. Droits des personnes concernées — procédures existantes

| Droit RGPD | Procédure | État |
|---|---|---|
| Droit d'accès (Art. 15) | Export des données du compte | Implémenté (Team Admin Roadmap — export RGPD UI) |
| Droit à l'effacement (Art. 17) | Suppression de compte + crypto-shredding de tous les fichiers associés | Implémenté (`DocumentServiceImpl.deleteDocument()` révoque la clé avant suppression) |
| Droit à la portabilité (Art. 20) | Export structuré des documents et métadonnées | Partiel — dépend du format d'export déjà construit côté Team Admin, à valider avec ce sprint |
| Droit de rectification (Art. 16) | Modification du profil (email, nom) via l'UI | Existant (hors périmètre chiffrement) |
| Droit d'opposition au traitement IA | Non applicable — le traitement IA est nécessaire à l'exécution du contrat (fonctionnalités de résumé/Q&A/extraction), pas de mode local alternatif depuis le retrait d'Ollama | Retiré (ROADMAP_BASCULE_CLAUDE.md Sprint C-4) |

## 5. Risques résiduels identifiés

| Risque | Probabilité | Impact | Mesure existante | Mesure restante |
|---|---|---|---|---|
| Compromission de la Master Key de chiffrement | Faible | Élevé (accès à tous les eDEK, mais pas aux fichiers sans accès simultané au stockage — ADR-001) | Rotation documentée (`KEY_ROTATION.md`), procédure d'incident (PSSI §5) | Rotation encore manuelle, pas automatique sur échéance |
| Titre de document ou secret TOTP indéchiffrable après une rotation de MK mal séquencée | Moyenne (si rotation effectuée) | Moyen (perte d'accès, pas fuite) | `rotation-status` expose `totpOutdatedVersionCount` | Aucun job de re-chiffrement automatique des titres (dette documentée, Sprint E-4) |
| Terminaison TLS et connexions PostgreSQL/Redis non chiffrées en interne | Faible (réseau Docker interne) | Moyen si le réseau interne est compromis | Authentification Redis, réseau Docker isolé | Certificats TLS PostgreSQL/Redis non provisionnés (Sprint E-7, `INFRASTRUCTURE_HARDENING.md`) |
| Traitement IA cloud (fuite vers un sous-traitant tiers) | Faible | Moyen | Chiffrement en transit (TLS), aucune donnée persistée côté fournisseur au-delà du traitement | Contrats de sous-traitance (DPA) avec Anthropic et OpenAI à formaliser hors de ce document technique |

## 6. Conclusion

Le traitement présente un risque résiduel **faible à moyen** compte tenu des mesures techniques
en place (chiffrement de bout en bout des données sensibles, crypto-shredding effectif, opt-in
pour le traitement IA, traçabilité des accès). Les points restants (rotation de MK non automatisée,
TLS interne incomplet, DPA fournisseurs IA) sont documentés comme dette connue et ne remettent pas
en cause la faisabilité d'une future certification, à condition d'être traités avant l'audit externe
(Sprint E-8.4).
