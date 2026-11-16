# GUIDE D'INSTALLATION MAJOOP — de zéro à l'application en ligne (gratuit)

> Durée réelle : 20 à 30 minutes. Coût : 0 FCFA. Tout repose sur des offres gratuites.
> Les seules actions qui exigent votre intervention sont la création de comptes (Supabase, Google AI Studio, hébergeur) — personne ne peut le faire à votre place, et je n'invente aucune clé.

## Étape 0 — Comptes gratuits à créer (5 min)

1. **Supabase** → [supabase.com](https://supabase.com) → « Start your project » (offre Free : 2 projets, 500 Mo de base, 50 000 utilisateurs actifs/mois, 5 Go de transfert — vérifié le 2026-11-16).
2. **Google AI Studio** → [aistudio.google.com](https://aistudio.google.com) → « Get API key » (clé Gemini gratuite ; les limites du tier gratuit évoluent selon les modèles — voir [aistudio.google.com/docs/rate-limits](https://aistudio.google.com/docs/rate-limits)).
3. (Optionnel, pour la publication) **Netlify** ([app.netlify.com](https://app.netlify.com)) ou **GitHub** ([github.com](https://github.com)).

## Étape 1 — Créer le projet Supabase (2 min)

1. Dashboard Supabase → **New project** → choisis un nom (ex. `majoop`), un mot de passe de base de données (garde-le précieusement), une région proche de ton audience.
2. Attends la fin du provisionnement (~1 min).
3. Note dans un coin (Dashboard → **Project Settings → API**) :
   - **Project URL** : `https://xxxxxxxx.supabase.co`
   - **anon public key** : longue chaîne `eyJhbGci...` (c'est une clé PUBLIQUE, protégée par la RLS — elle n'est pas secrète).

## Étape 2 — Exécuter les migrations SQL (5 min)

Dans le Dashboard Supabase → **SQL Editor** → « New query » → colle le contenu du fichier → **Run**. Dans CET ORDRE STRICT :

| Ordre | Fichier | Contenu |
|---|---|---|
| 1 | `database/001_schema.sql` | 19 tables, index, contraintes, triggers |
| 2 | `database/002_rls.sql` | Row Level Security, politiques, verrou `is_admin` |
| 3 | `database/003_functions.sql` | XP serveur, corrections, missions, badges, admin, IA |
| 4 | `database/004_seed.sql` | Paramètres, badges, 4 langues, 32 leçons, 192 exercices |
| 5 | `database/005_tests_securite.sql` | Tests de sécurité — doit finir par « ✅ TOUS LES TESTS DE SÉCURITÉ SONT PASSÉS » |

Chaque script est idempotent : tu peux le relancer sans dupliquer. Si le script 005 lève une exception, ne continue pas : corrige la cause (le message indique le test en échec).

## Étape 3 — Nommmer le premier administrateur (1 min)

Inscris-toi d'abord dans l'application (Étape 6), puis dans SQL Editor :

```sql
update public.profiles set is_admin = true where email = 'ton-email@exemple.com';
```

⚠️ C'est le SEUL moyen d'attribuer un rôle admin : côté serveur, par SQL. L'app interdit toute auto-promotion (testée).

## Étape 4 — Configurer le professeur IA : Gemini, OpenRouter ou Mistral (5 min)

L'Edge Function `ai-tutor` prend en charge **trois fournisseurs**, tous gratuits au lancement, avec **repli automatique** : en mode `auto` (réglage par défaut), si le premier échoue (quota atteint, indisponibilité), le suivant disponible répond — l'apprenant n'est jamais bloqué.

| Fournisseur | Clé gratuite à créer | Limites du tier gratuit (vérifiées le 2026-11-16) | Secret Supabase |
|---|---|---|---|
| **Gemini** (par défaut) | [aistudio.google.com](https://aistudio.google.com) → « Get API key » | Quotas journaliers variables selon le modèle (voir [rate-limits](https://aistudio.google.com/docs/rate-limits)) | `GEMINI_API_KEY` |
| **OpenRouter** | [openrouter.ai](https://openrouter.ai) → compte → Keys | Modèles `:free` : 20 req/min et **50 req/jour** (1 000/jour si le compte a déjà crédité 10 $) | `OPENROUTER_API_KEY` |
| **Mistral** | [console.mistral.ai](https://console.mistral.ai) → API Keys (offre gratuite « Experiment ») | Accès limité aux modèles de la Plateforme (limites affichées dans leur console) | `MISTRAL_API_KEY` |

La clé ne doit JAMAIS apparaître dans le code frontend. Deux méthodes :

**Méthode A — Supabase CLI (recommandée)** :
```bash
npm install -g supabase
supabase login
supabase link --project-ref xxxxxxxx        # le ref est dans l'URL du projet
supabase functions deploy ai-tutor
# Ajoute AU MOINS UNE des clés ci-dessous :
supabase secrets set GEMINI_API_KEY=ta_cle_gemini
supabase secrets set OPENROUTER_API_KEY=ta_cle_openrouter
supabase secrets set MISTRAL_API_KEY=ta_cle_mistral
# optionnel (domaine autorisé) : supabase secrets set ALLOWED_ORIGIN=https://ton-site.fr
```

**Méthode B — Dashboard** : Edge Functions → « Create a new function » → éditeur en ligne → colle le code de `supabase/functions/ai-tutor/index.ts` → Deploy → puis Project Settings → Edge Functions → Add secret (un ou plusieurs des secrets ci-dessus).

**Choisir le fournisseur** (facultatif) : Administration → **XP & IA** → clé `ai_provider` :
- `auto` (défaut) : essaie Gemini → OpenRouter → Mistral selon les secrets présents, avec repli en cas de quota/panne ;
- `gemini`, `openrouter` ou `mistral` : force ce fournisseur (échoue clairement en 501 si son secret est absent).

Les modèles par fournisseur sont réglables dans le même panneau : `ai_model` (Gemini, défaut `gemini-2.5-flash`), `ai_model_openrouter` (défaut `meta-llama/llama-3.3-70b-instruct:free` — les ID de modèles `:free` changent souvent, la liste officielle est sur openrouter.ai/models avec le filtre gratuit), `ai_model_mistral` (défaut `mistral-small-latest`, alias stable).

> Sans aucune clé, l'app fonctionne intégralement ; le tuteur IA renvoie un message de configuration clair (501). Pour les installations existantes, exécute `database/006_ai_providers.sql` pour ajouter ces réglages.

## Étape 5 — Brancher l'application (2 min)

1. Ouvre `app/index.html` dans ton navigateur (double-clic suffit).
2. Crée un compte → l'onboarding se lance.
3. Va dans **⚙️ Réglages → Connexion Supabase** → colle l'URL du projet + la clé anon → **Tester et enregistrer**. La page se recharge : tu es en MODE SUPABASE (le bandeau « MODE DÉMO » disparaît).
   - Alternative développeur : éditer directement `window.MAJOOP_CONFIG` en tête du fichier `app/index.html`.

Vérification rapide : complète une leçon → recharge → l'XP est conservé côté serveur ; regarde l'onglet **Réseau** du navigateur : les corrections d'exercices passent par des appels RPC, jamais par le HTML.

## Étape 6 — Publier gratuitement (3 min)

Le fichier `app/index.html` est autonome (aucun build). Trois options gratuites :

- **GitHub Pages (recommandée — le dépôt livré est prêt)** : le dossier `majoop/` est déjà un dépôt Git avec le workflow de publication automatique (`.github/workflows/pages.yml`). Suis les 4 manipulations exactes de **[DEPLOIEMENT_GITHUB.md](DEPLOIEMENT_GITHUB.md)** : création du dépôt → `git push` → Settings → Pages → « GitHub Actions » → en ligne à `https://ton-pseudo.github.io/majoop/`. Une voie « sans installer git » (upload web du seul `index.html`) y est aussi décrite.
- **Netlify Drop** : [app.netlify.com/drop](https://app.netlify.com/drop) → glisse le fichier → URL `https://xxxx.netlify.app` immédiate.
- **Cloudflare Pages** : upload direct du fichier.

Ajoute ensuite le domaine autorisé : `supabase secrets set ALLOWED_ORIGIN=https://ton-domaine` (sinon la valeur `*` par défaut autorise tous les origines — acceptable pour un lancement, à restreindre ensuite).

## Dépannage express

| Symptôme | Cause probable | Solution |
|---|---|---|
| « exécute 001→004 » au lancement des tests | migrations incomplètes | rejouer dans l'ordre |
| Le tuteur IA renvoie 501 avec « secret … absent » | aucun secret de fournisseur, ou `ai_provider` force un fournisseur sans clé | Étape 4 : ajouter un secret (ou repasser `ai_provider` en `auto`) |
| Le tuteur IA renvoie 429 | quotas du tier gratuit atteints sur le fournisseur | en `auto` le repli fait la main ; sinon patienter ou changer de `ai_provider`/modèle dans Admin |
| Réponse « GEMINI_429 » alors qu'OpenRouter est configuré | `ai_provider` forcé sur `gemini` | mettre `ai_provider` = `auto` pour activer le repli |
| Le modèle OpenRouter renvoie une erreur 404/400 | l'ID du modèle `:free` n'existe plus (ils changent souvent) | choisir un modèle dans openrouter.ai/models (filtre gratuit) puis mettre à jour `ai_model_openrouter` |
| « Acces admin requis » | `is_admin` non attribué | Étape 3 |
| Connexion impossible depuis le site publié | CORS / ALLOWED_ORIGIN | définir le secret, redéployer la fonction |
| Aucun e-mail de reset reçu | SMTP non configuré (Supabase Free) | Auth → Emails : le SMTP par défaut de Supabase est limité ; configurer un SMTP gratuit (ex. Resend) plus tard |

## Limites du tier gratuit à connaître (vérifiées le 2026-11-16)

- **Supabase Free** : 500 Mo de base, 50 000 MAU, 5 Go egress, projets en pause après 7 jours d'inactivité (il suffit de les restaurer depuis le dashboard).
- **Gemini free tier** : quotas journaliers variables par modèle (voir la page rate-limits citée plus haut).
- **OpenRouter modèles `:free`** : 20 requêtes/min et 50 requêtes/jour (1 000/jour une fois que le compte a crédité 10 $) — [openrouter.ai/pricing](https://openrouter.ai/pricing).
- **Mistral Plateforme (offre gratuite)** : accès limité aux modèles, limites affichées dans leur console — [docs.mistral.ai](https://docs.mistral.ai/admin/billing-usage/usage-limits).
- **Quota MAJOOP par utilisateur** : `ai_daily_quota` (défaut 20 messages/jour) protège ton quota global, quel que soit le fournisseur — le repli automatique multiplie la réserve disponible.

## FlutterFlow (optionnel, plus tard)

Le backend est 100 % réutilisable par une app mobile Flutter/FlutterFlow : mêmes tables, mêmes RPC (`submit_exercise`, `get_dashboard`, `record_game_result`…), mêmes politiques RLS. Dans FlutterFlow : ajoute le projet Supabase (vérifie d'abord sur [docs.flutterflow.io/accounts-billing/plan-comparison](https://docs.flutterflow.io/accounts-billing/plan-comparison) que ton plan inclut l'intégration Supabase), puis consomme les RPC depuis les actions. Aucune refonte n'est nécessaire.

## Après le lancement — roadmap suggérée

1. Envoi réel des rappels quotidiens (cron Supabase + SMTP gratuit).
2. Révisions espacées (SRS) à partir de `exercise_attempts`.
3. Entraînement à l'expression orale (Web Speech Recognition, Chrome d'abord).
4. Erreurs récurrentes injectées dans le prompt du tuteur (les données existent déjà).
5. Objectifs hebdomadaires + more de contenus B1-B2.
6. Version Premium (architecture prête : table `admin_settings`, flags par utilisateur).
