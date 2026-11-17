# 💎 MODULE DE MONÉTISATION — MAJOOP (v2 : sans gratuit + concours)

> ⚡ **V2 — 2026-11-17 (modèle actuel)** : plus de plan gratuit. Inscription **3 000 F/mois** ou **30 000 F/an** (60 $/an, 6 $/mois international), et **CONCOURS HEBDOMADAIRE : 25 000 F chaque semaine** aux 3 meilleurs apprenants (🥇 15 000 · 🥈 6 000 · 🥉 4 000), payés en Mobile Money sous 72 h. Migration `009_concours_hebdomadaire.sql` (appliquée et testée par `010`). Les sections ci-dessous décrivent la base v1 restée valable (paiements, quotas, admin).

## 10. V2 — Concours hebdomadaire (`009_concours_hebdomadaire.sql`)

**Tarifs (lignes actives au 2026-11-17)** : les anciennes lignes (0 / 1 500 / 12 000 / 3 $ / 24 $) sont désactivées (jamais supprimées — historique conservé) ; nouvelles lignes : XAF/XOF 3 000 mensuel · XAF/XOF 30 000 annuel · USD 6 / 60. Le plan `free` est désactivé (`is_active=false`) ; `user_effective_plan` ne renvoie plus que `premium_*` pour les inscrits actifs.

**Tables** : `competition_weeks` (lundi UTC, cagnotte, statut open/distributed) et `competition_winners` (rang 1-3, montant, statut pending/paid, canal + référence de versement) — RLS activées, accès uniquement via RPC.

**RPC publiques** (anon ou authentifié) :
- `get_weekly_leaderboard(p_week_start default null)` — top 50 : XP de la semaine (lundi 00:00 → dimanche minuit UTC) parmi les inscrits ACTIFS uniquement ; départages : XP, puis jours actifs, puis premier XP.
- `get_competition_overview()` — semaine courante, clôture, cagnotte, répartition, top 3.
- `get_my_weekly_rank()` (authentifié) — éligibilité, rang, écart au podium.

**RPC admin** (garde `is_admin()` revérifiée dans chaque fonction) :
- `admin_close_competition_week(p_week_start)` — fige le podium d'une semaine TERMINÉE (refus sinon), crée les gains `pending` ; idempotent.
- `admin_mark_winner_paid(p_winner_id, p_channel, p_reference)` — marque payé, une seule fois.
- `admin_list_competition_weeks(p_limit)` — historique pour l'administration.

**Réglages** (`admin_settings`) : `competition_prize_pool` (25 000), `competition_prize_split` ({"1":15000,"2":6000,"3":4000}), `competition_enabled` (true).

**Front** : page publique `#/concours` (podium, top 10, ta position, compte à rebours, règles), bandeau concours sur la landing et le dashboard, page Tarifs sans carte gratuite, **paywall** : les pages de contenu redirigent vers les tarifs tant que l'inscription n'est pas active (`gate.required`). Process de payout : chaque dimanche ≥ minuit UTC → Administration → Concours → clôturer → payer les 3 gains en Mobile Money et saisir les références.


Système de monétisation SaaS complet : deux formules principales (Free, Premium) et deux périodicités (mensuelle, annuelle), multi-devises, avec quotas du professeur IA comptés côté serveur, paiement manuel validé par un administrateur, administration des tarifs et statistiques commerciales.

> **Prix officiels — décisions commerciales validées.** Ne pas modifier sans autorisation.
> Grille seedée en base (migration 007) et protégée : changer un prix crée une **nouvelle ligne versionnée** sans toucher aux abonnements existants.

---

## 1. Grille tarifaire officielle

| Formule | Prix | Inclus |
|---|---|---|
| **Free** | **0 FCFA** | 4 langues (anglais, français, espagnol, allemand) · leçons gratuites · exercices de base · jeux éducatifs de base · XP · badges et séries quotidiennes · suivi de progression standard · **10 interactions IA/mois** · publicité éventuellement activable ultérieurement |
| **Premium Mensuel** | **1 500 FCFA / mois** | Tous les cours · tous les niveaux · tous les exercices · tous les jeux · professeur IA **100 interactions/mois** · conversations personnalisées · corrections détaillées · explications grammaticales · historique complet des conversations · statistiques avancées · sans publicité |
| **Premium Annuel** | **12 000 FCFA / an** | Mêmes avantages · **12 mois d'accès** · prix mensuel équivalent **1 000 FCFA** · **économie de 6 000 FCFA** par rapport à 12 paiements mensuels. Mis en avant comme **« MEILLEURE VALEUR »** sur la page Tarifs |

### Tarification internationale

| Zone | Mensuel | Annuel |
|---|---|---|
| Zone FCFA (XAF) | 1 500 FCFA | 12 000 FCFA |
| Zone FCFA (XOF) | 1 500 FCFA | 12 000 FCFA |
| International (USD) | 3 $ | 24 $ |

- **XAF et XOF sont traités comme des devises DISTINCTES** : lignes `pricing` séparées (mêmes montants nominaux, codes ISO différents).
- **EUR est prévu et configurable** (Administration → Monétisation → créer une ligne de tarif EUR) : **aucun prix EUR n'a été inventé** dans le seed, faute de décision commerciale validée.
- Le prix affiché provient **toujours** de la configuration serveur (`pricing`) associée à une devise explicite ; **aucune conversion approximative côté frontend** — le sélecteur de devise de la page Tarifs ne montre que les devises réellement configurées.
- Les prix et régions se modifient depuis l'administration (versionnement, voir §6).
- **Le montant d'un abonnement déjà payé n'est jamais modifié** : l'abonnement référence la ligne `pricing` de sa souscription, dont le montant est immuable.

## 2. Page Tarifs (`#/pricing`)

Public (accessible hors connexion), responsive, identité visuelle MAJOOP (violet/indigo/orange/blanc) :

- **3 cartes** : Free (bordure verte), Premium Mensuel, Premium Annuel (badge « MEILLEURE VALEUR », bordure violette, note « ≈ 1 000 FCFA/mois · Économise 6 000 FCFA »).
- **Sélecteur de devise** (XAF / XOF / USD…) : puces ne montrant que les devises configurées.
- **Comparatif** de 15 fonctionnalités ✓/—.
- **FAQ abonnements** (5 questions : souscription, début/fin d'accès, annulation, quotas IA, protection des paiements).
- **Conditions de renouvellement et de résiliation** affichées.
- Boutons : **Commencer gratuitement**, **Choisir Premium**, **Choisir Premium Annuel** ; la formule active de l'utilisateur est marquée « ✓ Ta formule actuelle ».
- Navigation : lien « Tarifs » dans l'en-tête public et le pied de page.

## 3. Abonnements (`#/subscription` — Mon abonnement)

- Consultation du plan, du **statut**, des **dates de début et d'expiration**, du **statut du paiement**, du **compteur IA** (barre de progression + date de réinitialisation).
- **Historique des paiements** (références, montants, statuts).
- Actions : **souscrire** / **renouveler** (→ page Tarifs + modal de paiement), **annuler le renouvellement**.
- **Notification avant expiration** : bandeau d'alerte à 7 jours (événement `expiry_warning` journalisé, non répété pendant 3 jours).

### Statuts (`user_subscriptions.status`)

| Statut | Signification |
|---|---|
| `free` | Utilisateur gratuit (aucun abonnement actif) |
| `pending` | Paiement soumis, en attente de validation admin |
| `active` | Accès Premium actif jusqu'à `expires_at` |
| `expired` | Période payée terminée |
| `cancelled` | Annulé (demande retirée, ou remplacé par un autre plan) |
| `payment_failed` | Échec de paiement (réservé aux fournisseurs automatiques) |

**Règles appliquées :**
- Premium accordé **uniquement** après vérification serveur du paiement (`admin_confirm_payment`).
- Une annulation **ne supprime jamais les droits déjà payés** : accès conservé jusqu'à `expires_at`.
- Le renouvellement prolonge depuis `max(maintenant, expiration)` — jamais rétroactif, aucun jour perdu.
- Achat d'un plan différent pendant un abonnement actif : la nouvelle période **démarre à la fin** de la période payée (empilement sans chevauchement, ancien abonnement clôturé avec événement).

## 4. Quotas du professeur IA

| Plan | Quota mensuel | Configurable |
|---|---|---|
| Free | **10 interactions / mois** | `ai_quota_free` (admin, défaut officiel 10) |
| Premium | **100 interactions / mois** | `ai_quota_premium` (admin, défaut officiel 100) |

- **Comptage exclusivement serveur** : table `ai_usage` (une ligne par utilisateur et par mois, `period_start`/`period_end`), incrément **atomique** (`UPDATE ... WHERE interaction_count < limite` sous verrou de ligne) → **protection contre les appels simultanés et les doubles comptages**.
- **Réinitialisation automatique** le 1ᵉʳ de chaque mois (période calendaire), **historique d'utilisation conservé** mois par mois.
- **Blocage automatique** à épuisement : réponse `402` structurée (`used`, `limit`, `reset_at`, `upgrade`) de l'Edge Function → **paywall** avec compteur, date de réinitialisation, avantages Premium et prix dans la devise de l'utilisateur ; bouton « Continuer gratuitement » pour revenir à son activité.
- **Jamais présenté comme illimité** ; message d'upsell explicite (« Passe à Premium pour 100 interactions par mois »).
- **Maîtrise des coûts** : taille max des messages (`ai_max_message_chars`, défaut 2000), tokens max de réponse (`ai_max_output_tokens`, défaut 600), garde anti-abus journalière (`ai_daily_quota`, défaut 60) et anti-spam (`ai_min_interval_sec`) — tout configurable en administration.
- **Si le modèle IA échoue** (tous fournisseurs), l'interaction est **remboursée** (`ai_refund_quota`) : l'utilisateur ne paie jamais une erreur serveur.
- **Clé API du modèle jamais exposée** : secrets Supabase uniquement ; aucune clé n'apparaît dans le frontend ni dans les réponses.

## 5. Structure de la base (migration `007_monetisation.sql`)

| Table | Rôle |
|---|---|
| `subscription_plans` | Plans (`free`, `premium_monthly`, `premium_yearly`), activation/désactivation |
| `pricing` | Grille tarifaire multi-devises/régions, **versionnée et immuable** (trigger `guard_pricing_amount`) |
| `user_subscriptions` | Abonnements, un seul `pending`/`active` par utilisateur (index partiels uniques) |
| `payments` | Paiements, référence unique par fournisseur (`unique(provider, provider_reference)`) |
| `ai_usage` | Compteur mensuel IA, une ligne par utilisateur/période |
| `subscription_events` | Journal complet : paiements, activations, renouvellements, expirations, **modifs tarifaires**, changements de quotas |

Clés étrangères, contraintes (montants ≥ 0, devises en liste fermée `EUR/USD/XAF/XOF`, périodicités `monthly/yearly`, références 4–120 caractères), index de performance et politiques **RLS** : lecture publique des plans/tarifs actifs, lecture de ses propres données (ou admin), **écriture impossible côté client** (privilèges révoqués — tout passe par les RPC `SECURITY DEFINER`).

## 6. Sécurité des paiements

1. **Premium jamais accordé depuis le frontend** : aucune policy d'écriture client sur les 4 tables de monétisation ; activation exclusivement par `admin_confirm_payment` (vérification `is_admin()` interne).
2. **Montant jamais lu depuis le client** : `submit_manual_payment` copie le montant depuis la ligne `pricing` serveur.
3. **Validation serveur obligatoire** : seul un paiement `pending` peut être confirmé (verrou `FOR UPDATE` + vérification de statut) → **idempotence stricte**, confirmations répétées impossibles.
4. **Anti-doublons** : `unique(provider, provider_reference)` + vérification explicite avant insertion (une preuve de paiement ne peut être soumise ni confirmée deux fois).
5. **Références de transaction enregistrées** dans `payments.provider_reference` (avec note libre de l'utilisateur).
6. **Journalisation** : `subscription_events` trace chaque soumission, confirmation, rejet, expiration, modification tarifaire (ancien/nouveau prix) et changement de quota.
7. **Modifications administratives restreintes** : fonctions `admin_*` vérifiant `is_admin()` ; tarif direct modifiable seulement par versionnement.
8. **Mode paiement manuel** (aucun prestataire configuré — conformément à la consigne, **aucun prestataire payant n'a été intégré**) : l'utilisateur paie via Mobile Money/virement selon les instructions configurées (`payment_instructions`, modifiables par l'admin), saisit sa **référence de transaction**, l'administrateur **valide ou rejette** avec motif après vérification. **Aucun paiement n'est jamais simulé comme réussi** : le statut reste « En attente de validation » jusqu'à l'action admin.
9. Les webhooks signés seront branchés lors de l'intégration d'un futur fournisseur (l'architecture `payments` + events est prête) — uniquement avec ton autorisation.

## 7. Administration → Monétisation (onglet `admin#/money`)

- **Statistiques** : utilisateurs Free, abonnés Premium, **taux de conversion Free → Premium**, abonnements mensuels / annuels, paiements en attente, taux de résiliation (30 j), interactions IA du mois, **coût IA estimé** (`ai_cost_estimate_fcfa_per_interaction`, paramètre configurable — une estimation, pas une facture).
- **Revenus par devise** (XAF/XOF/USD/EUR affichés séparément, jamais mélangés) : **MRR** (mensuel tel quel, annuel ÷ 12), **ARR** (= MRR × 12), **encaissé** (paiements confirmés). Les encaissés et les revenus récurrents annualisés sont **explicitement distingués** et ne sont jamais additionnés.
- **Plans** : activer/désactiver (`admin_set_plan_active`).
- **Tarifs** : créer une ligne de tarif (plan, devise, montant, périodicité, région) → **versionnement** (l'ancienne ligne est désactivée, les abonnements en cours gardent leur prix) ; désactiver une ligne.
- **Quotas IA** : modifier Free/Premium (`admin_set_ai_quota`, journalisé, Premium > Free imposé).
- **Paiements** : liste, **valider** (✓) ou **rejeter** (✕ avec motif journalisé).
- **Abonnements** : liste complète (email, plan, statut, tarif, dates, paiements confirmés).
- **Exports CSV** : abonnements, paiements, événements, usage IA (`admin_export_monetization`).

## 8. Tests (`008_tests_monetisation.sql`) — **14/14 PASSÉS**

Exécutés sur **PostgreSQL 17 réel** (environnement Supabase simulé) avec la suite de sécurité 005 (7/7) :

1. ✅ Inscription utilisateur Free (profil auto, plan effectif `free`, quota 10 affiché)
2. ✅ Accès gratuit : page Tarifs lisible hors connexion, données perso isolées
3. ✅ Limite de 10 interactions IA : comptage serveur 1→10, 11ᵉ bloquée avec upsell Premium, message trop long refusé, remboursement en cas d'erreur
4. ✅ Souscription Premium mensuelle : statut `pending`, **aucun droit avant validation**
5. ✅ Souscription Premium annuelle USD : expiration à +12 mois
6. ✅ Validation serveur : montant issu du `pricing`, non-admin refusé, expiration exacte (+1 mois)
7. ✅ Attribution des droits : plan effectif `premium_monthly` après validation
8. ✅ Expiration : droits révoqués à l'échéance, retour Free
9. ✅ Annulation : accès conservé jusqu'à la fin payée + alerte à 5 jours ; renouvellement prolongé depuis la fin payée
10. ✅ Réinitialisation des quotas au 1ᵉʳ du mois, historique conservé
11. ✅ Modification des tarifs : versionnement, **immuabilité du montant** (trigger), zéro rétroactivité, journalisation
12. ✅ RLS : écritures client impossibles (auto-attribution Premium, réinitialisation de compteur), isolation inter-utilisateurs
13. ✅ Doubles paiements : même référence refusée, double confirmation refusée
14. ✅ Devises : XAF ≠ XOF (lignes distinctes), montants exacts 1500/12000/3/24/0

Test navigateur complémentaire : page Tarifs (3 cartes, badge annuel, devise XAF/XOF/USD, comparatif, FAQ), marque « Ta formule actuelle », compteur 0/10, **10 interactions comptées puis 11ᵉ bloquée → paywall** affiché.

## 9. Mise en production (résumé)

1. Exécuter `database/007_monetisation.sql` **puis** `database/008_tests_monetisation.sql` dans le SQL Editor Supabase (après 001→006).
2. Redéployer l'Edge Function : `supabase functions deploy ai-tutor`.
3. (Optionnel) Configurer les instructions de paiement réelles : SQL Editor → `select public.admin_set_setting('payment_instructions', '{"XAF":{"method":"Orange Money / MTN MoMo","details":"Envoyer au +237 6XX XX XX XX (MAJOOP SARL)"} , ...}'::jsonb);`
4. Se donner le rôle admin : `update public.profiles set is_admin = true where id = '<ton uuid>';`
5. (Optionnel) Ajouter un tarif EUR via Administration → Monétisation dès que le prix est validé commercialement.
6. Mettre à jour `ai_cost_estimate_fcfa_per_interaction` avec ton coût réel par interaction pour des statistiques fidèles.

Détail des écrans, RPC et messages d'erreur : voir le code (`database/007_monetisation.sql` commenté section par section, `supabase/functions/ai-tutor/index.ts`, page Tarifs dans `app/index.html`).
