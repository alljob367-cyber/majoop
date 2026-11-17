# MAJOOP — Apprends une langue. Joue. Progresse. Parle.

Plateforme d'apprentissage des langues : leçons structurées, jeux éducatifs, professeur IA, gamification et administration — construite pour un budget de **0 FCFA** sur des offres gratuites.

> 📥 **Pour démarrer : lis [GUIDE_INSTALLATION.md](GUIDE_INSTALLATION.md)** (20–30 min, étape par étape).
> 🔍 Le diagnostic technique et l'architecture sont détaillés dans [DIAGNOSTIC.md](DIAGNOSTIC.md).

## Contenu du livrable

```
majoop/                            ← dépôt Git PRÊT À POUSSER (branche main)
├── README.md                       ← ce fichier
├── AUDIT_CONFORMITE.md            ← conformité aux maquettes officielles : 12 écrans, identité, tests
├── DEPLOIEMENT_GITHUB.md          ← mise en ligne GitHub Pages en 4 manipulations (voie web ou git)
├── DIAGNOSTIC.md                   ← diagnostic environnement + architecture + sécurité
├── GUIDE_INSTALLATION.md           ← les étapes manuelles exactes (Supabase, IA Gemini/OpenRouter/Mistral, hébergement)
├── MODULE_MONETISATION.md         ← module Free / Premium : grille tarifaire, abonnements, quotas IA, administration
├── docs/                           ← copie de publication servie par GitHub Pages (branche main + dossier /docs)
├── captures/                       ← 10 captures d'écran à jour de l'application
├── database/
│   ├── 001_schema.sql              ← 19 tables, index, FK, triggers (exécutées sur PostgreSQL 17 réel)
│   ├── 002_rls.sql                 ← RLS stricte, politiques, verrou anti-escalade is_admin
│   ├── 003_functions.sql           ← XP/validations SERVEUR, missions, badges, admin, IA
│   ├── 004_seed.sql                ← barème, badges, 4 langues, 32 leçons, 192 exercices
│   ├── 005_tests_securite.sql      ← tests de sécurité automatisés (échouent si faille)
│   ├── 006_ai_providers.sql        ← réglages multi-fournisseurs IA (OpenRouter, Mistral)
│   ├── 007_monetisation.sql        ← MONÉTISATION : 6 tables, RLS, RPC paiements/quotas, grille tarifaire, MRR/ARR
│   └── 008_tests_monetisation.sql  ← 14 scénarios de monétisation automatisés (échouent si faille)
├── supabase/functions/ai-tutor/
│   └── index.ts                    ← Edge Function IA (JWT, quotas mensuels par plan, anti-spam, multi-fournisseurs, repli auto)
└── app/
    └── index.html                  ← L'APPLICATION COMPLÈTE (1 fichier autonome, aucun build)
```

## Ce qui fonctionne dès l'ouverture de `app/index.html` (MODE DÉMO)

L'application démarre en **mode démo** : données locales simulées, clairement identifiées par un bandeau, aucune inscription externe requise. Tous les parcours sont testables immédiatement : inscription, onboarding, leçons, exercices corrigés, XP/niveaux/badges/missions, les 8 jeux, tuteur IA simulé, progression, profil, réglages. La connexion à Supabase (Réglages → Connexion) bascule en **mode réel** sans changer une ligne de code.

## Fonctionnalités (cahier des charges v1)

- **18 pages** : Landing, Login, Register, Onboarding (5 étapes), Dashboard, Langues, Cours, Leçon, Exercices, Résultat, Jeux (8), Tuteur IA, Conversations simulées (6 scénarios), Progression, Profil, Réglages, Administration, **Tarifs** (+ **Mon abonnement** dans l'app).
- **Monétisation Free / Premium** (voir [MODULE_MONETISATION.md](MODULE_MONETISATION.md)) : Free 0 FCFA · Premium **1 500 FCFA/mois** · Premium Annuel **12 000 FCFA/an** (≈ 1 000 FCFA/mois, économie 6 000 FCFA) · International **3 $/mois, 24 $/an** · devises XAF, XOF (distinctes), USD, EUR (configurable) · quotas IA **10/mois en Free, 100/mois en Premium** comptés côté serveur de façon atomique · page Tarifs publique (3 cartes, comparatif, FAQ, conditions), page Mon abonnement (statuts, dates, historique de paiements, compteur IA), paywall avec prix dans la devise de l'utilisateur, paiement manuel avec preuve + validation administrateur, Administration → Monétisation (prix versionnés et immuables, quotas, paiements, abonnements, MRR/ARR par devise, exports CSV).
- **4 langues** au lancement (anglais, français, espagnol, allemand), interface FR/EN/ES/DE, architecture prête pour en ajouter (1 ligne SQL + contenu).
- **32 leçons** rédigées (A1/A2) avec objectif, explication, vocabulaire (phonétique + exemples + audio TTS), et **192 exercices** de 7 types : QCM, traduction, texte à trous, association, remise en ordre, compréhension écrite, compréhension audio (Web Speech API). L'expression orale est annoncée « prochaine version » (comme demandé).
- **Gamification** : XP (barème configurable en base), niveaux (paliers 50·n·(n-1)), 6 badges, séries quotidiennes avec bonus tous les 7 jours, 3 missions quotidiennes réclamables, classement opt-in.
- **Professeur IA multi-fournisseurs** : Gemini, **OpenRouter** et **Mistral** — le réglage `ai_provider` (`auto` par défaut) tente Gemini puis OpenRouter puis Mistral selon les secrets présents et **replie automatiquement** en cas de quota ou de panne ; 5 modes (professeur, conversation libre, grammaire, vocabulaire, situations réelles), contexte complet (langues, niveau CECRL, historique), quotas et anti-spam côté serveur, clés API en secrets serveur.
- **Administration** : statistiques, gestion des utilisateurs et rôles, publication du contenu, réglages XP/IA, supervision IA (graphique 7 jours).

## Sécurité (conception + tests)

1. **RLS sur les 25 tables** ; chaque utilisateur ne voit que ses lignes.
2. **Les réponses des exercices sont physiquement illisibles** depuis le client (table `exercise_answer_keys` sans policy, REVOKE explicite) — la correction passe par la fonction serveur `submit_exercise`.
3. **L'XP ne peut pas être forcé par le client** : `xp_events` est en écriture serveur uniquement (fonctions `SECURITY DEFINER` + plafonds journaliers anti-abus configurables).
4. **`is_admin` verrouillé** : privilèges par colonne + trigger de défense + attribution par SQL uniquement.
5. **Premium inaccessible depuis le frontend** : les tables `user_subscriptions`, `payments`, `ai_usage`, `subscription_events` sont en lecture seule pour le client (REVOKE + RLS) ; l'activation passe exclusivement par `admin_confirm_payment` (SECURITY DEFINER, vérification `is_admin`, idempotence stricte). Le montant payé vient toujours de la ligne `pricing` serveur, **immuable** (trigger) — changer un prix crée une nouvelle ligne sans rétroactivité.
6. **Edge Function** : JWT obligatoire, propriété de la conversation vérifiée, **quota mensuel par plan** (10 Free / 100 Premium, incrément atomique anti-double-comptage), garde journalière anti-abus, limite de taille des messages et de tokens configurables, clés API jamais exposées — quel que soit le fournisseur (Gemini / OpenRouter / Mistral). Si le modèle échoue, l'interaction est **remboursée**.
7. **`005_tests_securite.sql` + `008_tests_monetisation.sql`** rejouent tous ces scénarios d'attaque (lecture des réponses, auto-XP, auto-admin, triche de mission, auto-attribution Premium, double paiement, réinitialisation de compteur IA, isolement inter-utilisateurs) et échouent bruyamment si l'un passe.

## Qualité — ce qui a été réellement testé ici

- **Migrations 001→008 exécutées sur PostgreSQL 17 réel** (serveur local extrait des paquets officiels, environnement Supabase simulé : schéma `auth`, rôles anon/authenticated/service_role) : installation complète OK, **suite de sécurité 005 : 7/7 PASSÉS**, **suite monétisation 008 : 14/14 scénarios PASSÉS**. 4 défauts préexistants trouvés et corrigés à cette occasion (fonction `is_admin` non exécutable par anon → contenu public illisible, variables de bloc PL/pgSQL hors de portée dans 005, `SELECT INTO` sur record non assigné, appel PL/pgSQL invalide d'une fonction à paramètres OUT dans `submit_exercise`).
- **Edge Function multi-fournisseurs** : vérification de types TypeScript OK **+ 13 tests hors-ligne** (`scripts/ai_tutor_test.ts`, fetch simulé) couvrant auth, propriété de la conversation, quotas, façonnage exact des requêtes de chaque fournisseur (URL, en-têtes, corps), repli automatique Gemini→OpenRouter sur 429, erreurs de configuration claires (501) et échec agrégé (502) — + nouveaux codes 402 paywall (quota mensuel) et remboursement d'interaction en cas d'échec du modèle.
- **Application** : parcours complets testés au navigateur headless (inscription → onboarding → dashboard → cours → leçon → exercices → jeux → tuteur IA → progression → profil → réglages → admin → responsive). Balayage final de toutes les routes **sans erreur JS**.
- **Monétisation testée au navigateur** : page Tarifs publique (3 cartes, badge annuel « MEILLEURE VALEUR », sélecteur XAF/XOF/USD, comparatif 15 lignes, FAQ, conditions), marque « Ta formule actuelle », page Mon abonnement (statut, compteur IA 0/10, historique), **test de charge du quota : 10 interactions comptées puis 11ᵉ bloquée avec invitation Premium**, paywall affiché avec compteur et date de réinitialisation.
- **Conformité visuelle** : maquettes officielles (12 écrans) auditées écran par écran → 6 écarts corrigés (logo M+🎓, œil mot de passe, OAuth Google/GitHub, chips IA, onglets Progression, puce XP 🪙) — détail dans **[AUDIT_CONFORMITE.md](AUDIT_CONFORMITE.md)**.
- Contenu pédagogique validé programmatiquement : cohérence énoncé ↔ clé de correction des 192 exercices.

Historique des corrections pendant les tests : étape 0 de l'onboarding bloquée ; variables d'énoncé hors de portée dans le moteur d'exercices (4 types muets) ; badges démo jamais attribués ; missions non persistées ; durcissement XP contre NaN ; emoji introuvable pour les termes composés (jeu mot-image) ; coque app visible par-dessus la landing ; leçon recommandée fautive (break imbriqué) ; compteur XP non rafraîchi.

## Limites v1 (assumées et documentées)

- Explications de leçons en français (immersion) — structure prête pour des explications par langue d'interface.
- « Temps d'apprentissage » estimé (30 s/exercice + durées de jeux enregistrées) et non chronométré finement.
- Notifications : préférences enregistrées, l'envoi réel (e-mail/push) est en roadmap (SMTP gratuit à brancher).
- Photo de profil : choix d'emoji v1 ; l'upload d'image passera par Supabase Storage.
- Administration du contenu : publication en un clic dans l'UI ; création/édition complète via les RPC documentées (`admin_upsert_content`, `admin_upsert_exercise`).
- Les témoignages de la landing sont **fictifs et signalés comme tels** ; le contenu des leçons, lui, est réel.

## Monétisation (implémentée — voir [MODULE_MONETISATION.md](MODULE_MONETISATION.md))

Le système Free / Premium est intégré de bout en bout : grille tarifaire officielle (décisions commerciales **verrouillées** : 0 / 1 500 FCFA-mois / 12 000 FCFA-an / 3 $-mois / 24 $-an), page Tarifs publique, abonnements avec statuts (`free`, `pending`, `active`, `expired`, `cancelled`, `payment_failed`), paiement manuel validé par un administrateur (aucun prestataire payant intégré, comme demandé), quotas IA mensuels par plan comptés côté serveur, administration de la monétisation (prix versionnés, devises, quotas, paiements, abonnements, MRR/ARR par devise, exports CSV) et 14 scénarios de tests automatisés.
