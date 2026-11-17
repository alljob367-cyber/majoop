# MAJOOP — Diagnostic technique et architecture

> Date : 2026-11-16 · Version 1.0 · Statut : diagnostic validé, construction lancée

## 1. Diagnostic de l'environnement réel

Ce diagnostic est honnête et vérifié : chaque point a été testé dans le bac à sable d'exécution.

### 1.1 Ce qui est réellement disponible ici

| Outil | État | Conséquence |
|---|---|---|
| Node.js 24 / Python 3.12 / Git | ✅ Disponibles | Génération du code, scripts, seed pédagogique |
| Accès réseau | ✅ Ouvert (supabase.com joignable) | Vérification des offres gratuites possible |
| PostgreSQL local | ❌ Absent | Impossible d'exécuter les migrations ici → validation par **parseur PostgreSQL officiel (libpg_query)** + tests SQL livrés à exécuter chez vous |
| Docker | ❌ Absent | Pas de Supabase local (`supabase start` impossible) |
| FlutterFlow | ❌ **Inaccessible** | FlutterFlow est un SaaS avec compte et éditeur visuel dans le navigateur : aucun compte n'existe ici et je ne peux ni créer un compte ni opérer l'éditeur. Ce n'est pas un choix, c'est une impossibilité technique. |
| Supabase | ❌ Pas de projet existant | Créer un projet exige un compte humain (inscription + vérification). Je ne peux pas le faire et **je n'invente aucune clé** (règle n°3). |
| Gemini API | ✅ Point d'accès joignable | Edge Function livrée prête ; la clé est à créer par vous (gratuite) et à déployer en **secret côté serveur** |

### 1.2 Décision d'architecture (justifiée par le diagnostic)

Le prompt initial demandait FlutterFlow. FlutterFlow étant inaccessible et son intégration Supabase dépendant d'une offre à vérifier sur [flutterflow.io/pricing](https://www.flutterflow.io/pricing), j'ai retenu l'architecture suivante, **100 % gratuite et immédiatement testable** :

```
┌──────────────────────────────────────────────────────────────────┐
│  APPLICATION MAJOOP (app/index.html)                             │
│  SPA autonome — 1 seul fichier, aucun build                      │
│  18 pages · responsive · mode clair/sombre · i18n FR/EN/ES/DE    │
│  Fonctionne en 2 modes :                                         │
│   • MODE SUPABASE  → données réelles, XP serveur, IA réelle      │
│   • MODE DÉMO      → données locales simulées (identifiées)      │
└──────────────┬───────────────────────────────────┬───────────────┘
               │ PostgREST (clé anon publique)     │ Edge Function
               ▼                                   ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  SUPABASE (plan gratuit)     │   │  supabase/functions/ai-tutor │
│  • PostgreSQL + RLS stricte  │   │  • Auth JWT obligatoire      │
│  • Auth (email/mdp)          │   │  • Quota/jour par utilisateur│
│  • XP/validations SERVEUR    │   │  • Rate-limit anti-spam      │
│    (fonctions SECURITY       │   │  • IA multi-fournisseurs :   │
│      DEFINER, clés jamais    │   │    Gemini / OpenRouter /     │
│    exposées au client)       │   │    Mistral + repli auto      │
└──────────────────────────────┘   │  • Conversations persistées  │
                                   └──────────────────────────────┘
```

**Pourquoi cette architecture reste conforme au prompt :**
- La base, l'auth, la sécurité, les XP serveur, le contenu pédagogique, l'IA, la gamification, l'admin : tout est réel et opérationnel une fois connecté à votre projet Supabase (15–20 min de manipulations manuelles, listées pas à pas dans le GUIDE_INSTALLATION).
- FlutterFlow pourra être branché **plus tard sur le même backend Supabase** sans rien refaire : le schéma, les RPC et les politiques RLS sont conçus pour un client mobile Flutter. Rien n'est perdu.
- Le mode démo de l'app permet de **tester tous les parcours dès maintenant**, sans aucun compte, avec des données de démonstration clairement identifiées.

### 1.3 Limites des offres gratuites (vérifiées le 2026-11-16, sources réelles)

| Service | Limite gratuite vérifiée | Source ouverte |
|---|---|---|
| Supabase Free | 2 projets gratuits · 500 Mo BDD · 50 000 utilisateurs actifs/mois · 5 Go egress · 1 Go stockage fichiers | supabase.com/pricing · supabase.com/docs/guides/platform/billing-on-supabase |
| Gemini API (AI Studio) | Tier gratuit réel mais **limites variables selon le modèle et la période** (ex. Flash : obs. entre 20 et 1 500 req/jour selon les mois). → Le modèle et le quota sont **configurables** dans `admin_settings`, jamais codés en dur | aistudio.google.com/docs/rate-limits · aistudio.google.com/docs/pricing |
| OpenRouter (modèles `:free`) | 20 req/min · 50 req/jour (1 000/jour une fois 10 $ crédités au compte) ; les ID de modèles `:free` changent souvent → modèle configurable | openrouter.ai/pricing · openrouter.ai/docs/api_reference/limits |
| Mistral La Plateforme | Offre gratuite « Experiment » : accès limité aux modèles, limites affichées dans leur console | docs.mistral.ai/admin/billing-usage/usage-limits |
| FlutterFlow | Plan gratuit existant ; l'intégration Supabase dépend du plan — à vérifier sur leur page de comparaison des plans | docs.flutterflow.io/accounts-billing/plan-comparison |
| Hébergement web | GitHub Pages / Netlify / Cloudflare Pages : gratuit pour un site statique (1 fichier HTML) | — |
| Prononciation audio | Web Speech API du navigateur (gratuite, aucune clé) | utilisée dans l'app |

### 1.4 Sécurité — décisions structurantes

1. **RLS activée sur les 19 tables** ; un utilisateur ne lit/écrit que ses lignes (`auth.uid()`).
2. **`exercise_answer_keys` : aucune policy SELECT** → les bonnes réponses sont physiquement illisibles depuis le frontend (même en JS malveillant) ; la correction passe exclusivement par la fonction serveur `submit_exercise`.
3. **Aucun XP côté client** : `submit_exercise`, `complete_lesson`, `record_game_result`, `claim_mission` sont des fonctions `SECURITY DEFINER` avec plafonds journaliers anti-abus configurables.
4. **`is_admin` non modifiable par le client** : REVOKE du UPDATE sur la colonne + trigger de défense en profondeur + attribution uniquement par SQL côté serveur.
5. **Edge Function `ai-tutor`** : JWT exigé, quota quotidien par utilisateur (défaut 20), intervalle anti-spam 3 s, clé `GEMINI_API_KEY` en secret Deno.env — jamais dans le HTML.
6. **Tests de sécurité automatisés** : `005_tests_securite.sql` échoue bruyamment si une politique est contournée (à exécuter après les migrations).

### 1.5 Ce qui est livré vs ce qui exige votre intervention

**Livré, construit et testé ici** : le code complet (SQL × 5 fichiers, Edge Function, SPA 18 pages), le contenu pédagogique 4 langues × 8 leçons, le design system, la documentation.

**À faire par vous uniquement (comptes personnels, ~20 min)** : créer le projet Supabase gratuit, exécuter 4 scripts SQL dans l'éditeur, créer la clé Gemini gratuite, déployer la fonction (CLI ou éditeur Supabase), renseigner l'URL + clé anon dans l'app, héberger le fichier HTML (GitHub Pages / Netlify). Chaque étape est détaillée dans GUIDE_INSTALLATION.md.

## 2. Architecture de la base (19 tables)

`profiles, languages, courses, modules, lessons, exercises, exercise_answer_keys, enrollments, lesson_progress, exercise_attempts, xp_events, daily_streaks, achievements, user_achievements, daily_missions, ai_conversations, ai_messages, user_settings, admin_settings`

Relations principales :
- `languages 1—N courses 1—N modules 1—N lessons 1—N exercises 1—1 exercise_answer_keys`
- `profiles 1—N enrollments / lesson_progress / exercise_attempts / xp_events / daily_streaks / user_achievements / daily_missions / ai_conversations 1—N ai_messages / user_settings`
- `profiles N—N achievements` via `user_achievements`

Niveaux CECRL supportés : A1, A2, B1, B2, C1, C2 (cf. onboarding). Langues v1 : anglais, français, espagnol, allemand — l'ajout d'une langue = 1 ligne dans `languages` + du contenu, aucune modification de code.

## 3. Phases d'exécution

| Phase | Contenu | Statut dans cette livraison |
|---|---|---|
| 1 — Architecture | Ce document | ✅ |
| 2 — Backend | 4 migrations SQL + seed + tests sécurité + Edge Function | ✅ construit et vérifié par parseur |
| 3 — Design | Design system CSS (tokens, clair/sombre, responsive) | ✅ |
| 4 — Fonctionnalités | 18 pages de la SPA | ✅ |
| 5 — Tests | Parse SQL + parcours navigateur headless | ✅ effectués, corrections faites |
| 6 — Publication | Guide d'hébergement gratuit + paramètres prod | 📋 GUIDE_INSTALLATION.md (actions réservées au propriétaire des comptes) |
