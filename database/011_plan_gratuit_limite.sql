-- ============================================================
-- MAJOOP — 011_plan_gratuit_limite.sql
-- RÉINTRODUCTION D'UN PLAN GRATUIT TRÈS LIMITÉ (freemium)
-- Date : 2026-11-24 · Exécuter dans Supabase → SQL Editor
-- ------------------------------------------------------------
-- Modèle visé : « Découverte gratuit → Inscription 3 000 F »
--
-- Contenu gratuit (très limité) :
--   • 1 SEULE leçon par cours (la première) — le reste est verrouillé
--     (limitation appliquée côté application, affichée avec un 🔒)
--   • 2 jeux éducatifs sur 8 (mémoire + quiz éclair)
--   • 3 interactions IA par mois (contre 100 en premium) — quota
--     appliqué côté serveur par ai_consume_quota / my_ai_quota
--   • PAS de concours hebdomadaire : déjà réservé aux abonnés côté
--     serveur (get_weekly_leaderboard filtre user_effective_plan
--     like 'premium%' — aucun changement nécessaire)
--   • XP, badges, séries quotidiennes, suivi de progression : inclus
--
-- AUCUNE souscription n'est requise pour le gratuit :
-- user_effective_plan() renvoie 'free' pour tout utilisateur
-- authentifié sans abonnement premium actif → attribution
-- automatique à l'inscription. my_subscription() renvoie
-- plan='free' avec la grille 0 F réactivée ci-dessous.
--
-- IDEMPOTENT : relançable sans erreur, aucune perte de données.
-- ============================================================

-- ------------------------------------------------------------
-- 1. RÉACTIVER le plan free avec la description « très limité »
--    (009 l'avait désactivé dans le modèle « sans gratuit »)
-- ------------------------------------------------------------
update public.subscription_plans set
  is_active = true,
  description = 'Plan Découverte (très limité) : 1 seule leçon par cours, 2 jeux éducatifs (mémoire + quiz éclair), 3 interactions IA par mois, XP, badges et séries quotidiennes inclus. PAS d''accès au concours hebdomadaire (réservé aux abonnés). Passez à l''Inscription Mensuelle (3 000 F/mois) ou Annuelle (30 000 F/an) pour tout débloquer et participer au concours 25 000 F.'
where code = 'free';

-- ------------------------------------------------------------
-- 2. GRILLE TARIFAIRE gratuite : 0 F / mois (idempotent —
--    protégé par not exists contre l'index unique partiel
--    uq_pricing_active(plan, devise, périodicité, région))
-- ------------------------------------------------------------
insert into public.pricing (plan_id, currency, amount, billing_interval, region, is_active)
select p.id, c.cur, c.amt, c.iv::public.billing_interval, c.reg, true
from public.subscription_plans p
join (values
  ('free', 'XAF',  0, 'monthly', 'zone_fcfa'),
  ('free', 'XOF',  0, 'monthly', 'zone_fcfa'),
  ('free', 'USD',  0, 'monthly', 'international')
) as c(code, cur, amt, iv, reg) on c.code = p.code
where p.code = 'free'
  and not exists (
    select 1 from public.pricing pr
    where pr.plan_id = p.id
      and pr.currency = c.cur
      and pr.billing_interval = c.iv::public.billing_interval
      and pr.region = c.reg
      and pr.is_active);

-- ------------------------------------------------------------
-- 3. QUOTA IA du gratuit : 3 interactions/mois (au lieu de 10)
--    ai_consume_quota lit ce réglage à chaque message → effet
--    immédiat, même pour les sessions en cours.
-- ------------------------------------------------------------
insert into public.admin_settings (key, value, description)
values ('ai_quota_free', '3'::jsonb,
        'Quota IA MENSUEL du plan gratuit très limité (3 messages/mois ; premium = 100)')
on conflict (key) do update set
  value      = '3'::jsonb,
  description = excluded.description,
  updated_at = now();

-- ------------------------------------------------------------
-- 4. (SÉCURITÉ) Aucune autre ligne de prix active ne doit traîner
--    pour le plan free : on désactive tout ce qui n'est pas 0 F
--    ou qui n'est pas la grille mensuelle définie ci-dessus.
--    Historique conservé (is_active = false seulement).
-- ------------------------------------------------------------
update public.pricing pr set is_active = false, updated_at = now()
from public.subscription_plans p
where p.id = pr.plan_id
  and p.code = 'free'
  and pr.is_active
  and (pr.amount <> 0 or pr.billing_interval <> 'monthly'
       or (pr.currency, pr.region) not in (('XAF','zone_fcfa'),
                                           ('XOF','zone_fcfa'),
                                           ('USD','international')));

-- ------------------------------------------------------------
-- 5. VÉRIFICATION — résultats attendus :
--    • plan free : is_active = true
--    • 3 lignes de prix actives à 0 (XAF/XOF/USD)
--    • ai_quota_free = 3
--    • un utilisateur sans abonnement → user_effective_plan = 'free'
-- ------------------------------------------------------------
select p.code, p.is_active, p.name from public.subscription_plans p order by p.code;
select pr.currency, pr.amount, pr.billing_interval, pr.region
  from public.pricing pr
  join public.subscription_plans p on p.id = pr.plan_id
 where p.code = 'free' and pr.is_active
 order by pr.currency;
select key, value from public.admin_settings where key = 'ai_quota_free';

-- Rappel : la limite « 1 leçon par cours » et « 2 jeux » est appliquée
-- côté application (docs/index.html, helpers isFreePlan / FREE_LIMITS).
-- Le concours reste verrouillé côté serveur (aucune action requise ici).
