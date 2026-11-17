-- ============================================================
-- MAJOOP — Migration 008 : Tests MONÉTISATION (à exécuter APRÈS 007)
-- Exécution : Supabase SQL Editor (connecté postgres) — le script
-- échoue bruyamment (exception) si un test ne passe pas.
-- Les utilisateurs de test et données temporaires sont supprimés à la fin.
--
-- Couverture (14 scénarios obligatoires) :
--   1. Inscription d'un utilisateur Free
--   2. Accès aux fonctionnalités gratuites (lecture tarifs, données perso)
--   3. Limite de 10 interactions IA (Free) + message d'upsell + trop long
--   4. Souscription Premium mensuelle (paiement manuel, statut pending)
--   5. Souscription Premium annuelle (USD)
--   6. Validation serveur des paiements (montant issu du pricing, pas du client)
--   7. Attribution des droits Premium (après validation admin uniquement)
--   8. Expiration des abonnements
--   9. Annulation du renouvellement (droits conservés jusqu'à échéance)
--  10. Réinitialisation des quotas (nouveau mois, historique conservé)
--  11. Modification des tarifs (versionnement, immuabilité, pas de rétroactivité)
--  12. Sécurité RLS (écritures client impossibles, isolation inter-utilisateurs)
--  13. Protection contre les doubles paiements (référence unique, confirmations)
--  14. Affichage correct des devises (XAF ≠ XOF, USD, montants exacts)
-- ============================================================

-- ============================================================
-- A. GRILLE TARIFAIRE (scénario 14) — accessible sans connexion
-- ============================================================
do $$
declare
  v_n int; v_amt numeric;
begin
  select count(*) into v_n from public.subscription_plans
   where is_active and code in ('free','premium_monthly','premium_yearly');
  if v_n <> 3 then
    raise exception 'MAJOOP TEST FAIL: les 3 plans officiels ne sont pas actifs (%/3)', v_n;
  end if;

  select count(*) into v_n from public.pricing where is_active;
  if v_n <> 7 then
    raise exception 'MAJOOP TEST FAIL: grille tarifaire incomplète (%/7 lignes actives)', v_n;
  end if;

  -- Montants officiels — décision commerciale, NON modifiables sans autorisation
  select amount into v_amt from public.pricing where is_active and currency='XAF'
    and billing_interval='monthly' and region='zone_fcfa'
    and plan_id = (select id from public.subscription_plans where code='premium_monthly');
  if v_amt <> 1500 then raise exception 'MAJOOP TEST FAIL: Premium mensuel XAF ≠ 1500 (%)', v_amt; end if;

  select amount into v_amt from public.pricing where is_active and currency='XAF'
    and billing_interval='yearly' and region='zone_fcfa'
    and plan_id = (select id from public.subscription_plans where code='premium_yearly');
  if v_amt <> 12000 then raise exception 'MAJOOP TEST FAIL: Premium annuel XAF ≠ 12000 (%)', v_amt; end if;

  select amount into v_amt from public.pricing where is_active and currency='USD'
    and billing_interval='monthly' and region='international'
    and plan_id = (select id from public.subscription_plans where code='premium_monthly');
  if v_amt <> 3 then raise exception 'MAJOOP TEST FAIL: Premium mensuel USD ≠ 3 (%)', v_amt; end if;

  select amount into v_amt from public.pricing where is_active and currency='USD'
    and billing_interval='yearly' and region='international'
    and plan_id = (select id from public.subscription_plans where code='premium_yearly');
  if v_amt <> 24 then raise exception 'MAJOOP TEST FAIL: Premium annuel USD ≠ 24 (%)', v_amt; end if;

  -- XAF et XOF = devises DISTINCTES : lignes séparées pour les deux
  select count(*) into v_n from public.pricing
   where is_active and currency in ('XAF','XOF') and plan_id in
     (select id from public.subscription_plans where code like 'premium%');
  if v_n <> 4 then
    raise exception 'MAJOOP TEST FAIL: XAF/XOF non traités comme devises distinctes (%/4)', v_n;
  end if;

  -- Le plan Free est à 0 FCFA
  select amount into v_amt from public.pricing where is_active and currency='XAF'
    and plan_id = (select id from public.subscription_plans where code='free');
  if v_amt <> 0 then raise exception 'MAJOOP TEST FAIL: Free ≠ 0 FCFA'; end if;

  raise notice 'OK 14/14 — grille tarifaire exacte : XAF 1500/12000, XOF distinct, USD 3/24, Free 0';
end $$;

do $$
declare v_n int;
begin
  execute 'set local role anon';
  select count(*) into v_n from public.subscription_plans where is_active;
  if v_n <> 3 then raise exception 'MAJOOP TEST FAIL: anon ne voit pas les plans'; end if;
  select count(*) into v_n from public.pricing where is_active;
  if v_n <> 7 then raise exception 'MAJOOP TEST FAIL: anon ne voit pas les tarifs'; end if;
  execute 'reset role';
  raise notice 'OK 2a/14 — page Tarifs lisible hors connexion (plans + prix publics)';
end $$;

-- ============================================================
-- B. UTILISATEURS DE TEST — inscription Free (scénario 1)
-- ============================================================
do $$
declare
  v_free uuid; v_prem uuid; v_admin uuid; v_n int; v_s text;
begin
  delete from auth.users where email in
    ('test-free@majoop.test','test-prem@majoop.test','test-admin@majoop.test');

  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-free@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Alice"}', now(), now())
  returning id into v_free;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-prem@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Bob"}', now(), now())
  returning id into v_prem;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-admin@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Carol"}', now(), now())
  returning id into v_admin;

  if not exists (select 1 from public.profiles where id = v_free)
     or not exists (select 1 from public.profiles where id = v_prem)
     or not exists (select 1 from public.profiles where id = v_admin) then
    raise exception 'MAJOOP TEST FAIL: profils non créés à l''inscription';
  end if;

  if public.user_effective_plan(v_free) <> 'free'
     or public.user_effective_plan(v_prem) <> 'free' then
    raise exception 'MAJOOP TEST FAIL: un nouvel utilisateur n''est pas Free';
  end if;

  -- L'utilisateur voit SON abonnement (aucun pour l'instant → free)
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_free)::text);
  v_s := (public.my_subscription() ->> 'status');
  if v_s <> 'free' then raise exception 'MAJOOP TEST FAIL: statut initial ≠ free (%)', v_s; end if;
  if (public.my_subscription() -> 'usage' ->> 'limit')::int <> 10 then
    raise exception 'MAJOOP TEST FAIL: quota Free affiché ≠ 10';
  end if;
  execute 'reset role';

  -- Admin de test
  update public.profiles set is_admin = true where id = v_admin;

  raise notice 'OK 1/14 — inscription : utilisateurs Free, profil auto, quota 10 affiché';
end $$;

-- ============================================================
-- C. QUOTA FREE : 10 interactions/mois, comptage serveur (scénario 3)
-- ============================================================
do $$
declare
  v_user uuid; v_conv uuid; v_res jsonb; v_i int;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  -- Accélérer les tests : pas d'intervalle anti-spam, garde journalière élevée
  update public.admin_settings set value = '0' where key = 'ai_min_interval_sec';
  update public.admin_settings set value = '500' where key = 'ai_daily_quota';

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
  insert into public.ai_conversations (user_id, mode, title)
  values (v_user, 'tutor', 'Test quota') returning id into v_conv;
  execute 'reset role';

  -- 10 interactions autorisées (comptées côté serveur uniquement)
  execute 'set local role service_role';
  for v_i in 1 .. 10 loop
    v_res := public.ai_consume_quota(v_conv, 'Message de test numéro ' || v_i);
    if (v_res->>'ok')::boolean is not true then
      raise exception 'MAJOOP TEST FAIL: interaction % refusée pour Free (%)', v_i, v_res->>'message';
    end if;
    if (v_res->>'used')::int <> v_i then
      raise exception 'MAJOOP TEST FAIL: compteur serveur incorrect (% au lieu de %)', v_res->>'used', v_i;
    end if;
  end loop;
  -- La 11e est bloquée avec invitation à passer Premium
  v_res := public.ai_consume_quota(v_conv, 'Une de plus');
  if (v_res->>'ok')::boolean is not false or (v_res->>'reason') <> 'quota'
     or (v_res->>'upgrade')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: la 11e interaction Free n''est pas bloquée correctement';
  end if;
  if (v_res->>'limit')::int <> 10 or (v_res->>'used')::int <> 10 then
    raise exception 'MAJOOP TEST FAIL: compteurs du blocage Free incorrects';
  end if;
  if (v_res->>'message') not like '%Premium%' then
    raise exception 'MAJOOP TEST FAIL: le blocage doit inviter à passer Premium';
  end if;

  -- Message trop long : refusé AVANT tout comptage (maîtrise des coûts)
  v_res := public.ai_consume_quota(v_conv, repeat('x', 2500));
  if (v_res->>'reason') <> 'too_long' then
    raise exception 'MAJOOP TEST FAIL: message trop long accepté';
  end if;

  -- Remboursement si le modèle échoue (l'utilisateur ne paie pas une erreur)
  perform public.ai_refund_quota(v_conv);
  v_res := public.ai_consume_quota(v_conv, 'Dernière autorisée');
  if (v_res->>'ok')::boolean is not true or (v_res->>'used')::int <> 10 then
    raise exception 'MAJOOP TEST FAIL: remboursement de quota défaillant';
  end if;
  execute 'reset role';
  raise notice 'OK 3/14 — quota Free : 10 interactions/mois comptées serveur, 11e bloquée, upsell affiché';
end $$;

-- ============================================================
-- D. PREMIUM MENSUEL : soumission → PENDING → validation admin (4, 6, 7, 13a)
-- ============================================================
do $$
declare
  v_user uuid; v_admin uuid; v_pricing uuid;
  v_pay uuid; v_sub uuid; v_res jsonb; v_exp timestamptz; v_days int; v_ok boolean; v_amt numeric;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  select id into v_admin from public.profiles where email = 'test-admin@majoop.test';
  select id into v_pricing from public.pricing
   where is_active and currency='XAF' and billing_interval='monthly' and region='zone_fcfa'
     and plan_id = (select id from public.subscription_plans where code='premium_monthly');

  -- Soumission par l'utilisateur (référence de sa preuve de paiement)
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
  v_res := public.submit_manual_payment(v_pricing, 'MM-TEST-001', 'Capture Orange Money');
  if (v_res->>'status') <> 'pending' then
    raise exception 'MAJOOP TEST FAIL: paiement soumis non en attente';
  end if;
  v_pay := (v_res->>'payment_id')::uuid;
  v_sub := (v_res->>'subscription_id')::uuid;

  if (v_res->>'amount')::numeric <> 1500 then
    raise exception 'MAJOOP TEST FAIL: le montant ne vient pas du pricing serveur';
  end if;
  -- ⚠️ droits Premium encore ABSENTS avant validation (sécurité)
  if public.user_effective_plan(v_user) <> 'free' then
    raise exception 'MAJOOP TEST FAIL: Premium accordé avant validation du paiement !';
  end if;
  execute 'reset role';

  -- Un non-admin ne peut pas valider
  v_ok := false;
  begin
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
    perform public.admin_confirm_payment(v_pay);
    v_ok := true;
  exception when others then
    if sqlerrm not like '%acces admin requis%' then
      raise exception 'MAJOOP TEST FAIL: refus admin avec mauvais message (%)', sqlerrm;
    end if;
  end;
  execute 'reset role';
  if v_ok then raise exception 'MAJOOP TEST FAIL: un non-admin a validé un paiement !'; end if;

  -- Validation par l'admin → droits Premium actifs
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
  v_res := public.admin_confirm_payment(v_pay);
  if (v_res->>'status') <> 'active' then
    raise exception 'MAJOOP TEST FAIL: activation refusée';
  end if;
  execute 'reset role';

  if public.user_effective_plan(v_user) <> 'premium_monthly' then
    raise exception 'MAJOOP TEST FAIL: droits Premium non attribués après validation';
  end if;
  select expires_at into v_exp from public.user_subscriptions where id = v_sub;
  v_days := extract(epoch from (v_exp - now())) / 86400;
  if v_days < 26 or v_days > 32 then
    raise exception 'MAJOOP TEST FAIL: expiration mensuelle incorrecte (% jours)', v_days;
  end if;

  -- Double confirmation impossible (scénario 13)
  v_ok := false;
  begin
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
    perform public.admin_confirm_payment(v_pay);
    v_ok := true;
  exception when others then
    if sqlerrm not like '%déjà traité%' then
      raise exception 'MAJOOP TEST FAIL: double confirmation avec mauvais message (%)', sqlerrm;
    end if;
  end;
  execute 'reset role';
  if v_ok then raise exception 'MAJOOP TEST FAIL: paiement confirmé deux fois !'; end if;

  -- Montant du paiement = pricing serveur, jamais fourni par le client
  select amount into v_amt from public.payments where id = v_pay;
  if v_amt <> 1500 then
    raise exception 'MAJOOP TEST FAIL: montant du paiement ≠ 1500 (%)', v_amt;
  end if;

  raise notice 'OK 6-7/14 — validation SERVEUR : montant issu du pricing, Premium accordé après validation, expiration +1 mois';
  raise notice 'OK 13a/14 — double confirmation refusée (idempotence stricte)';
end $$;

-- ============================================================
-- E. PREMIUM ANNUEL en USD (scénario 5)
-- ============================================================
do $$
declare
  v_prem uuid; v_admin uuid; v_pricing uuid;
  v_pay uuid; v_sub uuid; v_res jsonb; v_exp timestamptz; v_days int;
begin
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';
  select id into v_admin from public.profiles where email = 'test-admin@majoop.test';
  select id into v_pricing from public.pricing
   where is_active and currency='USD' and billing_interval='yearly' and region='international'
     and plan_id = (select id from public.subscription_plans where code='premium_yearly');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_prem)::text);
  v_res := public.submit_manual_payment(v_pricing, 'MM-TEST-002', null);
  v_pay := (v_res->>'payment_id')::uuid;
  v_sub := (v_res->>'subscription_id')::uuid;
  if (v_res->>'status') <> 'pending' or v_res->>'currency' <> 'USD' or (v_res->>'amount')::numeric <> 24 then
    raise exception 'MAJOOP TEST FAIL: souscription annuelle USD incorrecte';
  end if;
  execute 'reset role';

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
  perform public.admin_confirm_payment(v_pay);
  execute 'reset role';

  if public.user_effective_plan(v_prem) <> 'premium_yearly' then
    raise exception 'MAJOOP TEST FAIL: plan annuel non attribué';
  end if;
  select expires_at into v_exp from public.user_subscriptions where id = v_sub;
  v_days := extract(epoch from (v_exp - now())) / 86400;
  if v_days < 355 or v_days > 371 then
    raise exception 'MAJOOP TEST FAIL: expiration annuelle incorrecte (% jours)', v_days;
  end if;
  raise notice 'OK 5/14 — souscription Premium ANNUELLE (24 USD) validée : accès 12 mois';
end $$;

-- ============================================================
-- F. QUOTA PREMIUM : 100 interactions/mois (scénario 3b)
-- ============================================================
do $$
declare
  v_prem uuid; v_conv uuid; v_res jsonb; v_i int;
begin
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_prem)::text);
  insert into public.ai_conversations (user_id, mode, title)
  values (v_prem, 'conversation', 'Test quota premium') returning id into v_conv;
  execute 'reset role';

  execute 'set local role service_role';
  for v_i in 1 .. 100 loop
    v_res := public.ai_consume_quota(v_conv, 'Message premium ' || v_i);
    if (v_res->>'ok')::boolean is not true then
      raise exception 'MAJOOP TEST FAIL: interaction premium % refusée (%)', v_i, v_res->>'message';
    end if;
  end loop;
  v_res := public.ai_consume_quota(v_conv, 'Une de trop');
  if (v_res->>'ok')::boolean is not false or (v_res->>'limit')::int <> 100
     or (v_res->>'upgrade')::boolean is not false then
    raise exception 'MAJOOP TEST FAIL: la 101e interaction Premium n''est pas bloquée';
  end if;
  if (v_res->>'message') like '%Premium pour%' then
    raise exception 'MAJOOP TEST FAIL: un Premium ne doit pas recevoir d''upsell Premium';
  end if;
  execute 'reset role';
  raise notice 'OK 3b/14 — quota Premium : 100 interactions/mois, 101e bloquée sans upsell';
end $$;

-- ============================================================
-- G. EXPIRATION (scénario 8)
-- ============================================================
do $$
declare
  v_prem uuid; v_n int;
begin
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';
  update public.user_subscriptions
     set expires_at = now() - interval '2 days'
   where user_id = v_prem and status = 'active';

  v_n := public.expire_due_subscriptions();
  if v_n < 1 then raise exception 'MAJOOP TEST FAIL: aucune abonnement expiré'; end if;

  if exists (select 1 from public.user_subscriptions
              where user_id = v_prem and status = 'active') then
    raise exception 'MAJOOP TEST FAIL: abonnement encore actif après expiration';
  end if;
  if public.user_effective_plan(v_prem) <> 'free' then
    raise exception 'MAJOOP TEST FAIL: droits Premium conservés après expiration';
  end if;
  raise notice 'OK 8/14 — expiration : accès Premium révoqué à l''échéance, retour au plan Free';
end $$;

-- ============================================================
-- H. ANNULATION + RENOUVELLEMENT + NOTIFICATION (scénario 9)
-- ============================================================
do $$
declare
  v_user uuid; v_admin uuid; v_pricing uuid;
  v_res jsonb; v_exp_old timestamptz; v_exp_new timestamptz; v_days int; v_n int;
  v_st text; v_auto boolean;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  select id into v_admin from public.profiles where email = 'test-admin@majoop.test';
  select id into v_pricing from public.pricing
   where is_active and currency='XAF' and billing_interval='monthly' and region='zone_fcfa'
     and plan_id = (select id from public.subscription_plans where code='premium_monthly');

  -- Notification d'expiration proche (à 5 jours de la fin)
  update public.user_subscriptions
     set expires_at = now() + interval '5 days'
   where user_id = v_user and status = 'active';
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
  v_res := public.my_subscription();
  if (v_res->>'expiry_warning')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: pas de notification avant expiration';
  end if;
  -- Annulation du renouvellement : les droits payés sont CONSERVÉS
  v_res := public.user_cancel_renewal();
  if (v_res->>'ok')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: annulation refusée';
  end if;
  if (v_res->>'message') not like '%jusqu''au%' then
    raise exception 'MAJOOP TEST FAIL: l''annulation doit préciser la fin de période payée';
  end if;
  execute 'reset role';
  select status::text, auto_renew, expires_at into v_st, v_auto, v_exp_old
    from public.user_subscriptions
   where user_id = v_user and status = 'active';
  if v_auto is not false or v_st is null then
    raise exception 'MAJOOP TEST FAIL: statut après annulation incorrect';
  end if;
  if public.user_effective_plan(v_user) <> 'premium_monthly' then
    raise exception 'MAJOOP TEST FAIL: droits perdus après simple annulation !';
  end if;
  raise notice 'OK 9a/14 — annulation : accès conservé jusqu''à la fin de la période payée, alerte à 5 jours';

  -- RENOUVELLEMENT : le paiement est rattaché à l'abonnement actif
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
  v_res := public.submit_manual_payment(v_pricing, 'MM-TEST-003', null);
  if (v_res->>'renewal')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: paiement de renouvellement non reconnu';
  end if;
  execute 'reset role';
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
  perform public.admin_confirm_payment((select id from public.payments
                                          where provider_reference = 'MM-TEST-003'));
  execute 'reset role';

  v_exp_new := (select expires_at from public.user_subscriptions
                 where user_id = v_user and status = 'active');
  v_days := extract(epoch from (v_exp_new - v_exp_old)) / 86400;
  if v_days < 26 or v_days > 32 then
    raise exception 'MAJOOP TEST FAIL: renouvellement non prolongé depuis la fin payée (% j)', v_days;
  end if;
  select count(*) into v_n from public.user_subscriptions
   where user_id = v_user and status = 'active';
  if v_n <> 1 then raise exception 'MAJOOP TEST FAIL: plusieurs abonnements actifs'; end if;
  raise notice 'OK 9b/14 — renouvellement : prolongé depuis la fin de la période payée (+1 mois)';
end $$;

-- ============================================================
-- I. RÉINITIALISATION DES QUOTAS (scénario 10)
-- ============================================================
do $$
declare
  v_user uuid; v_conv uuid; v_res jsonb; v_n int;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  -- Simuler l'usage du mois précédent
  update public.ai_usage
     set period_start = (date_trunc('month', now()) - interval '1 month')::date,
         period_end   = date_trunc('month', now())::date - 1
   where user_id = v_user;

  select id into v_conv from public.ai_conversations
   where user_id = v_user order by created_at limit 1;
  execute 'set local role service_role';
  v_res := public.ai_consume_quota(v_conv, 'Nouveau mois');
  execute 'reset role';
  if (v_res->>'ok')::boolean is not true or (v_res->>'used')::int <> 1 then
    raise exception 'MAJOOP TEST FAIL: quota non réinitialisé au nouveau mois';
  end if;
  select count(*) into v_n from public.ai_usage where user_id = v_user;
  if v_n <> 2 then
    raise exception 'MAJOOP TEST FAIL: historique d''usage non conservé (% lignes)', v_n;
  end if;
  raise notice 'OK 10/14 — quotas réinitialisés au 1er du mois, historique conservé';
end $$;

-- ============================================================
-- J. MODIFICATION DES TARIFS (scénario 11) — versionnement, immuabilité
-- ============================================================
do $$
declare
  v_user uuid; v_admin uuid; v_plan uuid;
  v_new uuid; v_old uuid; v_old_amt numeric; v_sub_pricing uuid; v_ok boolean; v_n int;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  select id into v_admin from public.profiles where email = 'test-admin@majoop.test';
  select id into v_plan from public.subscription_plans where code = 'premium_monthly';
  select id, amount into v_old, v_old_amt from public.pricing
   where is_active and currency='XAF' and billing_interval='monthly' and region='zone_fcfa'
     and plan_id = v_plan;
  v_sub_pricing := (select pricing_id from public.user_subscriptions
                     where user_id = v_user and status = 'active');

  -- Nouveau prix futur : crée une VERSION, désactive l'ancienne ligne
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
  v_new := (public.admin_add_pricing(v_plan, 'XAF', 2000, 'monthly', 'zone_fcfa')->>'pricing_id')::uuid;
  execute 'reset role';

  if exists (select 1 from public.pricing where id = v_old and is_active) then
    raise exception 'MAJOOP TEST FAIL: ancienne ligne de tarif toujours active';
  end if;
  if (select amount from public.pricing where id = v_new) <> 2000 then
    raise exception 'MAJOOP TEST FAIL: nouvelle ligne de tarif incorrecte';
  end if;
  -- PAS de rétroactivité : l'abonnement en cours garde son prix
  if v_sub_pricing <> v_old or (select amount from public.pricing where id = v_sub_pricing) <> 1500 then
    raise exception 'MAJOOP TEST FAIL: rétroactivité sur l''abonnement existant !';
  end if;

  -- Immuabilité : modifier directement le montant d'une ligne est INTERDIT
  v_ok := false;
  begin
    update public.pricing set amount = 9999 where id = v_new;
    v_ok := true;
  exception when others then
    if sqlerrm not like '%immuable%' then
      raise exception 'MAJOOP TEST FAIL: garde tarifaire avec mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: montant d''une ligne de tarif modifié !'; end if;

  -- Journalisation de la modification tarifaire
  select count(*) into v_n from public.subscription_events
   where event_type = 'pricing_created'
     and metadata->>'amount' = '2000';
  if v_n < 1 then raise exception 'MAJOOP TEST FAIL: modification tarifaire non journalisée'; end if;

  -- Non-admin ne peut pas changer les tarifs
  v_ok := false;
  begin
    execute 'set local role authenticated';
    execute format('set local request.jwt.claims = %L', json_build_object('sub', v_user)::text);
    perform public.admin_add_pricing(v_plan, 'XAF', 1, 'monthly', 'zone_fcfa');
    v_ok := true;
  exception when others then
    if sqlerrm not like '%acces admin requis%' then
      raise exception 'MAJOOP TEST FAIL: refus tarifs non-admin (%)', sqlerrm;
    end if;
  end;
  execute 'reset role';
  if v_ok then raise exception 'MAJOOP TEST FAIL: non-admin a modifié les tarifs !'; end if;

  raise notice 'OK 11/14 — tarifs : versionnement (nouvelle ligne), immuabilité, pas de rétroactivité, journalisé';
end $$;

-- ============================================================
-- K. SÉCURITÉ RLS (scénario 12)
-- ============================================================
do $$
declare
  v_user uuid; v_prem uuid; v_n int; v_ok boolean;
begin
  select id into v_user from public.profiles where email = 'test-free@majoop.test';
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';

  -- Isolation : Bob ne voit pas les paiements d'Alice
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_prem)::text);
  select count(*) into v_n from public.payments
   where user_id = v_user; -- paiement d'Alice
  if v_n <> 0 then raise exception 'MAJOOP TEST FAIL: paiements d''autrui visibles'; end if;
  select count(*) into v_n from public.user_subscriptions where user_id = v_user;
  if v_n <> 0 then raise exception 'MAJOOP TEST FAIL: abonnements d''autrui visibles'; end if;

  -- Aucune écriture directe côté client (privilèges retirés)
  v_ok := false;
  begin
    insert into public.user_subscriptions (user_id, plan_id, status, started_at, expires_at)
    values (v_prem,
            (select id from public.subscription_plans where code='premium_yearly'),
            'active', now(), now() + interval '10 years');
    v_ok := true;
  exception when others then
    if sqlerrm not like '%permission denied%' then
      raise exception 'MAJOOP TEST FAIL: insertion directe avec mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un client s''est auto-attribué Premium !'; end if;

  v_ok := false;
  begin
    update public.ai_usage set interaction_count = 0 where user_id = v_prem;
    v_ok := true;
  exception when others then
    if sqlerrm not like '%permission denied%' then
      raise exception 'MAJOOP TEST FAIL: update usage direct (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un client a réinitialisé son compteur IA !'; end if;
  execute 'reset role';

  -- anon : rien
  execute 'set local role anon';
  begin
    perform 1 from public.user_subscriptions limit 1;
    raise exception 'MAJOOP TEST FAIL: anon lit les abonnements';
  exception when others then
    if sqlerrm not like '%permission denied%' then
      raise exception 'MAJOOP TEST FAIL: anon avec mauvais message (%)', sqlerrm;
    end if;
  end;
  execute 'reset role';

  raise notice 'OK 12/14 — RLS : isolation inter-utilisateurs, aucune écriture client, Premium innaccessible depuis le frontend';
end $$;

-- ============================================================
-- L. DOUBLE PAIEMENT (scénario 13b) — référence unique
-- ============================================================
do $$
declare
  v_prem uuid; v_pricing uuid; v_ok boolean;
begin
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';
  select id into v_pricing from public.pricing
   where is_active and currency='USD' and billing_interval='yearly' and region='international'
     and plan_id = (select id from public.subscription_plans where code='premium_yearly');

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_prem)::text);
  v_ok := false;
  begin
    perform public.submit_manual_payment(v_pricing, 'MM-TEST-002', null);
    v_ok := true;
  exception when others then
    if sqlerrm not like '%déjà été soumise%' then
      raise exception 'MAJOOP TEST FAIL: référence dupliquée avec mauvais message (%)', sqlerrm;
    end if;
  end;
  execute 'reset role';
  if v_ok then raise exception 'MAJOOP TEST FAIL: même référence acceptée deux fois !'; end if;
  raise notice 'OK 13b/14 — double paiement : même référence de preuve refusée';
end $$;

-- ============================================================
-- M. STATISTIQUES COMMERCIALES + EXPORT + QUOTAS ADMIN (point 10)
-- ============================================================
do $$
declare
  v_admin uuid; v_prem uuid; v_st jsonb; v_res jsonb; v_n int; v_ok boolean;
begin
  select id into v_admin from public.profiles where email = 'test-admin@majoop.test';
  select id into v_prem from public.profiles where email = 'test-prem@majoop.test';

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);

  v_st := public.admin_monetization_stats();
  if v_st->>'free_users' is null or v_st->>'premium_active' is null
     or v_st->>'conversion_rate_pct' is null or v_st->>'pending_payments' is null
     or v_st->>'churn_rate_pct_30j' is null or v_st->>'ai_cost_estimate_fcfa_month' is null
     or v_st->'mrr_by_currency' is null or v_st->'arr_by_currency' is null
     or v_st->'collected_by_currency' is null then
    raise exception 'MAJOOP TEST FAIL: statistiques incomplètes';
  end if;

  -- Cohérence : encaissé XAF = 1500 (souscription) + 1500 (renouvellement) = 3000
  -- MRR XAF = 1500 (1 abonnement mensuel actif) ; USD = 0 (Bob expiré)
  if ((select v from jsonb_array_elements(v_st->'collected_by_currency') t(v)
       where v->>'currency' = 'XAF') ->> 'collected')::numeric <> 3000 then
    raise exception 'MAJOOP TEST FAIL: encaissé XAF ≠ 3000';
  end if;
  if ((select v from jsonb_array_elements(v_st->'mrr_by_currency') t(v)
       where v->>'currency' = 'XAF') ->> 'mrr')::numeric <> 1500 then
    raise exception 'MAJOOP TEST FAIL: MRR XAF ≠ 1500 (ne pas confondre avec l''encaissé)';
  end if;
  if exists (select 1 from jsonb_array_elements(v_st->'mrr_by_currency') t(v)
              where v->>'currency' = 'USD' and (v->>'mrr')::numeric > 0) then
    raise exception 'MAJOOP TEST FAIL: MRR USD > 0 alors qu''aucun abonnement USD actif';
  end if;

  -- Exports
  v_res := public.admin_export_monetization('payments');
  if jsonb_typeof(v_res) <> 'array' or jsonb_array_length(v_res) < 3 then
    raise exception 'MAJOOP TEST FAIL: export paiements vide';
  end if;
  v_res := public.admin_export_monetization('subscriptions');
  if jsonb_array_length(v_res) < 2 then
    raise exception 'MAJOOP TEST FAIL: export abonnements vide';
  end if;

  -- Quotas configurables par l'admin
  perform public.admin_set_ai_quota(15, 200);
  execute 'reset role';
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_prem)::text);
  v_n := (public.my_ai_quota() ->> 'limit')::int;
  execute 'reset role';
  if v_n <> 15 then raise exception 'MAJOOP TEST FAIL: quota Free non modifié par l''admin'; end if;
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_admin)::text);
  perform public.admin_set_ai_quota(10, 100); -- restauration (valeurs officielles)
  execute 'reset role';

  raise notice 'OK 10-2/14 — stats : encaissé ≠ MRR/ARR (par devise), quotas modifiables par admin, exports OK';
end $$;

-- ============================================================
-- Z. NETTOYAGE (utilisateurs de test + données temporaires)
-- ============================================================
do $$
begin
  delete from auth.users where email in
    ('test-free@majoop.test','test-prem@majoop.test','test-admin@majoop.test');
  delete from public.pricing where amount = 2000 and currency = 'XAF' and region = 'zone_fcfa';
  -- Réactiver la ligne officielle désactivée par le test de versionnement (J)
  update public.pricing set is_active = true
   where amount = 1500 and currency = 'XAF' and billing_interval = 'monthly'
     and region = 'zone_fcfa';
  update public.admin_settings set value = '3' where key = 'ai_min_interval_sec';
  update public.admin_settings set value = '60' where key = 'ai_daily_quota';
  -- La grille tarifaire officielle est intacte :
  if (select count(*) from public.pricing where is_active) <> 7 then
    raise exception 'MAJOOP TEST FAIL: la grille officielle a été altérée par les tests';
  end if;
  raise notice '✅ TOUS LES TESTS DE MONÉTISATION SONT PASSÉS (données de test supprimées)';
end $$;
