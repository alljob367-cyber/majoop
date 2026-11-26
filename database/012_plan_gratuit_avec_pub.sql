-- ============================================================
-- MAJOOP — 012_plan_gratuit_avec_pub.sql
-- Le Plan Découverte (gratuit) est financé par la PUBLICITÉ ;
-- Premium = sans publicité. Exécuter dans Supabase → SQL Editor.
-- IDEMPOTENT : simple mise à jour de la description du plan free.
-- (L'affichage des pubs est géré côté application : adSlotHTML(),
--  visible uniquement quand isFreePlan() = true.)
-- ============================================================

update public.subscription_plans set
  description = 'Plan Découverte (très limité) : 1 seule leçon par cours, 2 jeux éducatifs (mémoire + quiz éclair), 3 interactions IA par mois, XP, badges et séries quotidiennes inclus. Ce plan gratuit est financé par la PUBLICITÉ (emplacements affichés dans l''app). PAS d''accès au concours hebdomadaire (réservé aux abonnés). Passez à l''Inscription Mensuelle (3 000 F/mois) ou Annuelle (30 000 F/an) pour tout débloquer sans publicité et participer au concours 25 000 F.'
where code = 'free';

-- Vérification attendue : description mise à jour, plan actif
select code, is_active, left(description, 90) as extrait from public.subscription_plans where code = 'free';
