# MAJOOP — Apprends une langue. Joue. Progresse. Parle.

Plateforme d'apprentissage des langues : leçons structurées, jeux éducatifs, professeur IA, gamification et administration — construite pour un budget de **0 FCFA** sur des offres gratuites.

> 📥 **Pour démarrer : lis [GUIDE_INSTALLATION.md](GUIDE_INSTALLATION.md)** (20–30 min, étape par étape).
> 🔍 Le diagnostic technique et l'architecture sont détaillés dans [DIAGNOSTIC.md](DIAGNOSTIC.md).

## Contenu du livrable

```
majoop/
├── README.md                       ← ce fichier
├── DIAGNOSTIC.md                   ← diagnostic environnement + architecture + sécurité
├── GUIDE_INSTALLATION.md           ← les étapes manuelles exactes (Supabase, IA Gemini/OpenRouter/Mistral, hébergement)
├── database/
│   ├── 001_schema.sql              ← 19 tables, index, FK, triggers (syntaxe vérifiée)
│   ├── 002_rls.sql                 ← RLS stricte, politiques, verrou anti-escalade is_admin
│   ├── 003_functions.sql           ← XP/validations SERVEUR, missions, badges, admin, IA
│   ├── 004_seed.sql                ← barème, badges, 4 langues, 32 leçons, 192 exercices
│   ├── 005_tests_securite.sql      ← tests de sécurité automatisés (échouent si faille)
│   └── 006_ai_providers.sql        ← réglages multi-fournisseurs IA (OpenRouter, Mistral)
├── supabase/functions/ai-tutor/
│   └── index.ts                    ← Edge Function IA (JWT, quotas, anti-spam, Gemini/OpenRouter/Mistral, repli auto)
└── app/
    └── index.html                  ← L'APPLICATION COMPLÈTE (1 fichier autonome, aucun build)
```

## Ce qui fonctionne dès l'ouverture de `app/index.html` (MODE DÉMO)

L'application démarre en **mode démo** : données locales simulées, clairement identifiées par un bandeau, aucune inscription externe requise. Tous les parcours sont testables immédiatement : inscription, onboarding, leçons, exercices corrigés, XP/niveaux/badges/missions, les 8 jeux, tuteur IA simulé, progression, profil, réglages. La connexion à Supabase (Réglages → Connexion) bascule en **mode réel** sans changer une ligne de code.

## Fonctionnalités (cahier des charges v1)

- **18 pages** : Landing, Login, Register, Onboarding (5 étapes), Dashboard, Langues, Cours, Leçon, Exercices, Résultat, Jeux (8), Tuteur IA, Conversations simulées (6 scénarios), Progression, Profil, Réglages, Administration.
- **4 langues** au lancement (anglais, français, espagnol, allemand), interface FR/EN/ES/DE, architecture prête pour en ajouter (1 ligne SQL + contenu).
- **32 leçons** rédigées (A1/A2) avec objectif, explication, vocabulaire (phonétique + exemples + audio TTS), et **192 exercices** de 7 types : QCM, traduction, texte à trous, association, remise en ordre, compréhension écrite, compréhension audio (Web Speech API). L'expression orale est annoncée « prochaine version » (comme demandé).
- **Gamification** : XP (barème configurable en base), niveaux (paliers 50·n·(n-1)), 6 badges, séries quotidiennes avec bonus tous les 7 jours, 3 missions quotidiennes réclamables, classement opt-in.
- **Professeur IA multi-fournisseurs** : Gemini, **OpenRouter** et **Mistral** — le réglage `ai_provider` (`auto` par défaut) tente Gemini puis OpenRouter puis Mistral selon les secrets présents et **replie automatiquement** en cas de quota ou de panne ; 5 modes (professeur, conversation libre, grammaire, vocabulaire, situations réelles), contexte complet (langues, niveau CECRL, historique), quotas et anti-spam côté serveur, clés API en secrets serveur.
- **Administration** : statistiques, gestion des utilisateurs et rôles, publication du contenu, réglages XP/IA, supervision IA (graphique 7 jours).

## Sécurité (conception + tests)

1. **RLS sur les 19 tables** ; chaque utilisateur ne voit que ses lignes.
2. **Les réponses des exercices sont physiquement illisibles** depuis le client (table `exercise_answer_keys` sans policy, REVOKE explicite) — la correction passe par la fonction serveur `submit_exercise`.
3. **L'XP ne peut pas être forcé par le client** : `xp_events` est en écriture serveur uniquement (fonctions `SECURITY DEFINER` + plafonds journaliers anti-abus configurables).
4. **`is_admin` verrouillé** : privilèges par colonne + trigger de défense + attribution par SQL uniquement.
5. **Edge Function** : JWT obligatoire, propriété de la conversation vérifiée, quota quotidien (`ai_daily_quota`), intervalle minimal entre messages, clés API jamais exposées — quel que soit le fournisseur (Gemini / OpenRouter / Mistral).
6. **`005_tests_securite.sql`** rejoue tous ces scénarios d'attaque (lecture des réponses, auto-XP, auto-admin, triche de mission, isolement inter-utilisateurs) et échoue bruyamment si l'un passe.

## Qualité — ce qui a été réellement testé ici

- **Syntaxe SQL des 6 migrations** validée par le parseur officiel PostgreSQL (libpg_query / pglast).
- **Edge Function multi-fournisseurs** : vérification de types Deno (`deno check`) OK **+ 13 tests hors-ligne** (`scripts/ai_tutor_test.ts`, fetch simulé) couvrant auth, propriété de la conversation, quotas, façonnage exact des requêtes de chaque fournisseur (URL, en-têtes, corps), repli automatique Gemini→OpenRouter sur 429, erreurs de configuration claires (501) et échec agrégé (502).
- **Application** : parcours complets testés au navigateur headless (inscription → onboarding 5 étapes → dashboard → cours → leçon → 7 types d'exercices → résultat → 8 jeux → tuteur IA → scénarios → progression → profil → réglages → admin → thème clair/sombre → responsive 390 px). **9 défauts trouvés et corrigés** (voir historique ci-dessous) ; balayage final de toutes les routes **sans erreur JS**.
- Contenu pédagogique validé programmatiquement : cohérence énoncé ↔ clé de correction des 192 exercices.

Historique des corrections pendant les tests : étape 0 de l'onboarding bloquée ; variables d'énoncé hors de portée dans le moteur d'exercices (4 types muets) ; badges démo jamais attribués ; missions non persistées ; durcissement XP contre NaN ; emoji introuvable pour les termes composés (jeu mot-image) ; coque app visible par-dessus la landing ; leçon recommandée fautive (break imbriqué) ; compteur XP non rafraîchi.

## Limites v1 (assumées et documentées)

- Explications de leçons en français (immersion) — structure prête pour des explications par langue d'interface.
- « Temps d'apprentissage » estimé (30 s/exercice + durées de jeux enregistrées) et non chronométré finement.
- Notifications : préférences enregistrées, l'envoi réel (e-mail/push) est en roadmap (SMTP gratuit à brancher).
- Photo de profil : choix d'emoji v1 ; l'upload d'image passera par Supabase Storage.
- Administration du contenu : publication en un clic dans l'UI ; création/édition complète via les RPC documentées (`admin_upsert_content`, `admin_upsert_exercise`).
- Les témoignages de la landing sont **fictifs et signalés comme tels** ; le contenu des leçons, lui, est réel.

## Monétisation future (préparée, non bloquante)

Aucun paiement n'est intégré. L'architecture est prête : `admin_settings` centralise les réglages, les fonctions serveur acceptent un flag de niveau d'accès par utilisateur, et les quotas IA sont déjà par utilisateur — une version Premium (sessions IA supplémentaires, parcours spécialisés) s'ajoute sans refonte.
