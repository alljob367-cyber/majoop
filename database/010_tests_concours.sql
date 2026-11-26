-- ============================================================
-- MAJOOP — Migration 010 : Tests CONCOURS HEBDOMADAIRE + sans gratuit
-- Exécution : Supabase SQL Editor (connecté postgres) — APRÈS 009.
-- Le script échoue BRUYAMMENT (exception) si un test ne passe pas ;
-- toutes les données de test sont supprimées à la fin.
-- Hermetique : semaine de test = il y a 5 semaines (aucun XP réel à cette
-- date), utilisateurs dédiés test-concours-*@majoop.test.
-- ============================================================
do $$
declare
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid;   -- 5 utilisateurs de test
  v_ws date := public.current_week_start() - 35;      -- semaine de test (passée)
  v_plan uuid;
  v_pricing uuid;
  v_n int; v_ok boolean; v_j jsonb; v_total int := 0; v_dummy int; v_w1 uuid;
begin
  -- 0. Nettoyage préalable (ré-exécution) : semaine de test + users dédiés
  delete from public.competition_weeks where week_start = v_ws;
  delete from auth.users where email like 'test-concours-%@majoop.test';

  -- 1. Utilisateurs de test (le trigger 001 crée les profiles)
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-concours-a@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Alice"}', now(), now())
  returning id into v_a;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-concours-b@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Boris"}', now(), now())
  returning id into v_b;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-concours-c@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Chantal"}', now(), now())
  returning id into v_c;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-concours-d@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"David"}', now(), now())
  returning id into v_d;
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-concours-e@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Emma"}', now(), now())
  returning id into v_e;

  select id into v_plan from public.subscription_plans where code = 'premium_monthly';
  select id into v_pricing from public.pricing
   where plan_id = v_plan and is_active and currency = 'XAF'
     and billing_interval = 'monthly' and region = 'zone_fcfa' and amount = 3000;
  if v_plan is null or v_pricing is null then
    raise exception 'MAJOOP TEST FAIL: plan/pricing Inscription Mensuelle 3 000 F introuvable — 009 appliqué ?';
  end if;

  -- 2. Abonnements : A, B, C actifs ; E expiré ; D jamais inscrit
  insert into public.user_subscriptions (user_id, plan_id, pricing_id, status, started_at, expires_at)
  values (v_a, v_plan, v_pricing, 'active', now() - interval '3 days', now() + interval '27 days'),
         (v_b, v_plan, v_pricing, 'active', now() - interval '2 days', now() + interval '28 days'),
         (v_c, v_plan, v_pricing, 'active', now() - interval '1 day',  now() + interval '29 days');
  insert into public.user_subscriptions (user_id, plan_id, pricing_id, status, started_at, expires_at)
  values (v_e, (select id from public.subscription_plans where code='premium_yearly'),
          null, 'active', now() - interval '40 days', now() - interval '1 day');

  -- 3. XP de la semaine de TEST (passée) :
  --    B 500 (3 j) > A 300 (3 j) > C 200 (1 j) ; D 999 (NON inscrit) ; E 400 (expiré)
  insert into public.xp_events (user_id, source, ref, xp, created_at) values
    (v_a, 'lesson',  'test', 100, v_ws::timestamptz + interval '1 day 2 hours'),
    (v_a, 'exercise','test', 100, v_ws::timestamptz + interval '2 day 3 hours'),
    (v_a, 'game',    'test', 100, v_ws::timestamptz + interval '3 day 4 hours'),
    (v_b, 'lesson',  'test', 200, v_ws::timestamptz + interval '1 day 1 hours'),
    (v_b, 'game',    'test', 200, v_ws::timestamptz + interval '2 day 2 hours'),
    (v_b, 'exercise','test', 100, v_ws::timestamptz + interval '3 day 3 hours'),
    (v_c, 'lesson',  'test', 200, v_ws::timestamptz + interval '4 day 1 hours'),
    (v_d, 'lesson',  'test', 999, v_ws::timestamptz + interval '1 day 1 hours'),
    (v_e, 'lesson',  'test', 400, v_ws::timestamptz + interval '1 day 1 hours');

  -- 4. Classement : seulement les inscrits actifs, bon ordre
  v_j := public.get_weekly_leaderboard(v_ws);
  if jsonb_array_length(v_j) <> 3 then
    raise exception 'MAJOOP TEST FAIL: leaderboard attendu 3 inscrits, obtenu %', jsonb_array_length(v_j);
  end if;
  if v_j -> 0 ->> 'user_id' <> v_b::text or (v_j -> 0 ->> 'weekly_xp')::int <> 500 then
    raise exception 'MAJOOP TEST FAIL: rang 1 attendu Boris (500 xp), obtenu %', v_j -> 0;
  end if;
  if (v_j -> 1 ->> 'user_id')::uuid <> v_a or (v_j -> 2 ->> 'user_id')::uuid <> v_c then
    raise exception 'MAJOOP TEST FAIL: ordre rangs 2/3 incorrect : %', v_j;
  end if;
  if exists (select 1 from jsonb_array_elements(v_j) e
              where e ->> 'user_id' in (v_d::text, v_e::text)) then
    raise exception 'MAJOOP TEST FAIL: un non-inscrit ou expiré figure au classement !';
  end if;
  if (v_j -> 0 ->> 'is_me')::boolean is not false then
    raise exception 'MAJOOP TEST FAIL: is_me doit être false hors session';
  end if;

  -- 5. Guards : clôture refusée sans être admin ; semaine en cours non closable
  --    (Alice est admin : le guard non-admin est testé avec Boris)
  update public.profiles set is_admin = true where id = v_a;
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_b)::text);   -- Boris : NON admin
  v_ok := false;
  begin
    perform public.admin_close_competition_week(v_ws);
    v_ok := true;
  exception when others then
    if sqlerrm not like '%accès administrateur requis%' then
      raise exception 'MAJOOP TEST FAIL: clôture non-admin, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un non-admin a clôturé une semaine !'; end if;

  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_a)::text);   -- Alice : admin
  v_ok := false;
  begin
    perform public.admin_close_competition_week(public.current_week_start());
    v_ok := true;
  exception when others then
    if sqlerrm not like '%pas encore terminée%' then
      raise exception 'MAJOOP TEST FAIL: semaine en cours closable, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: la semaine en cours a été clôturée !'; end if;
  execute 'reset role';

  -- 6. Alice (admin) clôture la semaine de test
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);
  v_j := public.admin_close_competition_week(v_ws);
  execute 'reset role';

  select count(*) into v_n from public.competition_winners where week_start = v_ws;
  if v_n <> 3 then
    raise exception 'MAJOOP TEST FAIL: 3 gagnants attendus, obtenu %', v_n;
  end if;
  select coalesce(sum(prize_amount), 0) into v_total
    from public.competition_winners where week_start = v_ws;
  if v_total <> 25000 then
    raise exception 'MAJOOP TEST FAIL: la cagnotte répartie = % au lieu de 25 000 F', v_total;
  end if;
  if (select prize_amount from public.competition_winners
       where week_start = v_ws and rank = 1) <> 15000
     or (select user_id from public.competition_winners
       where week_start = v_ws and rank = 1) <> v_b then
    raise exception 'MAJOOP TEST FAIL: rang 1 doit être Boris avec 15 000 F';
  end if;
  if (select status from public.competition_weeks where week_start = v_ws) <> 'distributed' then
    raise exception 'MAJOOP TEST FAIL: statut de semaine attendu distributed';
  end if;

  -- Idempotence : re-clôturer ne duplique rien
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);
  perform public.admin_close_competition_week(v_ws);
  execute 'reset role';
  select count(*) into v_n from public.competition_winners where week_start = v_ws;
  if v_n <> 3 then
    raise exception 'MAJOOP TEST FAIL: re-clôture a dupliqué des gagnants (%)', v_n;
  end if;
  select id into v_w1 from public.competition_winners
   where week_start = v_ws and rank = 1;   -- lu AVANT changement de rôle

  -- 7. Paiement des gains : refusé non-admin, réussi par admin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_b)::text);
  v_ok := false;
  begin
    perform public.admin_mark_winner_paid(v_w1, 'Orange Money', 'OM-TEST-001');
    v_ok := true;
  exception when others then
    if sqlerrm not like '%accès administrateur requis%' then
      raise exception 'MAJOOP TEST FAIL: paiement non-admin, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un non-admin a marqué un gain payé !'; end if;
  execute 'reset role';

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);
  v_j := public.admin_mark_winner_paid(v_w1, 'Orange Money', 'OM-TEST-001');
  if v_j ->> 'status' <> 'paid' or v_j ->> 'payment_reference' <> 'OM-TEST-001' then
    raise exception 'MAJOOP TEST FAIL: gain non marqué payé : %', v_j;
  end if;
  v_ok := false;
  begin
    perform public.admin_mark_winner_paid(v_w1, 'Orange Money', 'OM-TEST-001');
    v_ok := true;
  exception when others then
    if sqlerrm not like '%déjà payé%' then
      raise exception 'MAJOOP TEST FAIL: double paiement permis, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un gain déjà payé a été re-payé !'; end if;

  -- 8. Ma position : Alice (rang 2 de la semaine de test), David non éligible
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);
  v_j := public.get_my_weekly_rank(v_ws);
  if (v_j ->> 'eligible')::boolean is not true or (v_j ->> 'rank')::int <> 2 then
    raise exception 'MAJOOP TEST FAIL: rang d''Alice attendu 2, obtenu %', v_j;
  end if;
  execute 'reset role';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_d)::text);
  v_j := public.get_my_weekly_rank(v_ws);
  if (v_j ->> 'eligible')::boolean is not false then
    raise exception 'MAJOOP TEST FAIL: David (non inscrit) ne doit pas être éligible';
  end if;
  execute 'reset role';

  -- 9. Anonyme : peut lire le classement et l'aperçu, pas les tables, pas my rank
  --    (purger aussi les JWT claims locaux : auth.uid() ne dépend pas du rôle)
  execute 'set local request.jwt.claims = ''{}''';
  execute 'set local role anon';
  v_j := public.get_weekly_leaderboard(v_ws);
  if jsonb_array_length(v_j) <> 3 then
    raise exception 'MAJOOP TEST FAIL: leaderboard anon incorrect';
  end if;
  v_j := public.get_competition_overview();
  if (v_j ->> 'prize_pool')::int <> 25000
     or (v_j -> 'split' ->> '1')::int <> 15000 then
    raise exception 'MAJOOP TEST FAIL: aperçu concours incorrect : %', v_j;
  end if;
  v_ok := false;
  begin
    perform public.get_my_weekly_rank();
    v_ok := true;
  exception when others then
    if sqlerrm not like '%authentification requise%' then
      raise exception 'MAJOOP TEST FAIL: my rank anon, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: get_my_weekly_rank anonyme accepté !'; end if;
  v_ok := false;
  begin
    select 1 into v_dummy from public.competition_winners limit 1;
    v_ok := true;
  exception when others then
    if sqlerrm not like '%permission denied%' then
      raise exception 'MAJOOP TEST FAIL: lecture directe winners, mauvais message (%)', sqlerrm;
    end if;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: lecture directe de competition_winners permise !'; end if;
  execute 'reset role';

  -- 10. Sans gratuit : le plan free est bien inactif, 3 000 F actif
  if exists (select 1 from public.subscription_plans where code = 'free' and is_active) then
    raise exception 'MAJOOP TEST FAIL: le plan gratuit est encore actif !';
  end if;
  if not exists (select 1 from public.pricing
                  where is_active and amount = 3000 and currency = 'XAF'
                    and billing_interval = 'monthly') then
    raise exception 'MAJOOP TEST FAIL: la ligne pricing 3 000 F XAF mensuel est absente !';
  end if;
  select count(*) into v_n from public.pricing
   where is_active and billing_interval = 'monthly' and amount = 0;
  if v_n <> 0 then
    raise exception 'MAJOOP TEST FAIL: % ligne(s) de prix gratuit(0) encore active(s)', v_n;
  end if;

  -- Z. NETTOYAGE (semaine + utilisateurs de test, cascades XP/abonnements/gains)
  delete from public.competition_weeks where week_start = v_ws;
  delete from auth.users where id in (v_a, v_b, v_c, v_d, v_e);

  raise notice '✅ TOUS LES TESTS DU CONCOURS SONT PASSÉS (données de test supprimées)';
end $$;
