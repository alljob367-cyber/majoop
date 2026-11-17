-- ============================================================
-- MAJOOP — Migration 005 : Tests de sécurité (à exécuter APRÈS 004)
-- Exécution : Supabase SQL Editor (connecté postgres) — le script
-- échoue bruyamment (exception) si un test ne passe pas.
-- Les utilisateurs de test sont supprimés à la fin.
-- ============================================================

do $$
declare
  v_n int;
  v_ok boolean;
begin
  -- ============================================================
  -- 0. PRÉREQUIS
  -- ============================================================
  select count(*) into v_n from public.languages;
  if v_n < 4 then
    raise exception 'MAJOOP TEST: exécute 001→004 avant les tests (langues manquantes)';
  end if;
  select count(*) into v_n from public.exercises;
  if v_n < 100 then
    raise exception 'MAJOOP TEST: contenu insuffisant — exécute 004';
  end if;
  raise notice 'OK 0/7 — prérequis satisfaits';

  -- ============================================================
  -- 1. RLS activée sur les 19 tables
  -- ============================================================
  select count(*) into v_n from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity = true;
  if v_n < 19 then
    raise exception 'MAJOOP TEST FAIL: RLS non activée partout (%/19 tables)', v_n;
  end if;
  raise notice 'OK 1/7 — RLS activée sur % tables', v_n;

  -- ============================================================
  -- 2. Visibilité anonyme : contenu public oui, données privées non
  -- ============================================================
  begin
    execute 'set local role anon';
    select count(*) into v_n from public.languages;
    if v_n < 4 then raise exception 'MAJOOP TEST FAIL: langues invisibles pour anon'; end if;
    select count(*) into v_n from public.lessons where is_published;
    if v_n < 32 then raise exception 'MAJOOP TEST FAIL: leçons invisibles pour anon'; end if;
    select count(*) into v_n from public.exercises where is_published;
    if v_n < 192 then raise exception 'MAJOOP TEST FAIL: exercices invisibles pour anon'; end if;
    raise notice 'OK 2a — contenu public lisible par anon';
  exception when others then
    raise exception 'MAJOOP TEST FAIL: le contenu public doit être lisible par anon (%)', sqlerrm;
  end;

  -- Les clés de correction doivent être IMPOSSIBLES à lire pour anon
  -- (v_ok est déclaré dans le bloc externe pour rester visible après l'exception)
  v_ok := false;
  begin
    execute 'set local role anon';
    perform 1 from public.exercise_answer_keys limit 1;
    v_ok := true;
  exception when others then
    raise notice 'OK 2b — exercise_answer_keys refusé à anon (%)', sqlerrm;
  end;
  if v_ok then
    raise exception 'MAJOOP TEST FAIL: anon peut lire les réponses !';
  end if;

  execute 'set local role anon';
  if exists (select 1 from public.xp_events) then
    raise exception 'MAJOOP TEST FAIL: anon voit xp_events';
  end if;
  if exists (select 1 from public.profiles) then
    raise exception 'MAJOOP TEST FAIL: anon voit des profils';
  end if;
  if exists (select 1 from public.lesson_progress) then
    raise exception 'MAJOOP TEST FAIL: anon voit lesson_progress';
  end if;
  execute 'reset role';
  raise notice 'OK 2c — données privées invisibles pour anon';
end $$;

-- ============================================================
-- 3-7. Parcours complet avec deux utilisateurs de test
-- ============================================================
do $$
declare
  v_a uuid; v_b uuid;
  v_n int; v_xp int; v_lvl int; v_res jsonb; v_m uuid; v_ans jsonb;
  v_lesson uuid;
  v_keys jsonb;
  v_ex record;
  v_ok boolean;
begin
  -- ---------- Préparation : deux comptes de test ----------
  delete from auth.users where email in ('test-a@majoop.test', 'test-b@majoop.test');

  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-a@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Alice"}', now(), now())
  returning id into v_a;

  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
          'authenticated', 'test-b@majoop.test', now(),
          '{"provider":"email","providers":["email"]}', '{"first_name":"Bob"}', now(), now())
  returning id into v_b;

  if not exists (select 1 from public.profiles where id = v_a)
     or not exists (select 1 from public.profiles where id = v_b) then
    raise exception 'MAJOOP TEST FAIL: le trigger handle_new_user n''a pas créé les profils';
  end if;
  raise notice 'OK 3/7 — comptes de test créés + profils auto';

  -- ============================================================
  -- Session utilisateur A (simulée par JWT)
  -- ============================================================
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_a)::text);

  -- Dashboard + onboarding
  v_res := public.get_dashboard();
  if (v_res->'profile'->>'first_name') <> 'Alice' then
    raise exception 'MAJOOP TEST FAIL: dashboard incorrect';
  end if;
  v_res := public.complete_onboarding('fr', 'en', 'A1', 'voyage', 15);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: onboarding échoué';
  end if;
  raise notice 'OK 4a — dashboard + onboarding';

  -- Missions du jour créées AVANT les activités (progression mesurable)
  perform public.ensure_daily_missions(v_a);
  select count(*) into v_n from public.daily_missions
   where user_id = v_a and mission_date = current_date;
  if v_n <> 3 then raise exception 'MAJOOP TEST FAIL: missions du jour != 3'; end if;

  -- Contenu de leçon : 6 exercices publics, aucune clé de correction exposée
  select id into v_lesson from public.lessons where code = 'en-a1-m1-l1';
  v_res := public.get_lesson_content(v_lesson);
  if jsonb_array_length(v_res->'exercises') <> 6 then
    raise exception 'MAJOOP TEST FAIL: leçon sans ses 6 exercices';
  end if;
  if v_res::text like '%"correct"%' or v_res::text like '%exercise_answer_keys%' then
    raise exception 'MAJOOP TEST FAIL: des réponses fuient dans get_lesson_content';
  end if;
  raise notice 'OK 4b — contenu de leçon servi sans réponses';

  -- Mauvaise réponse : 0 XP
  select id into v_ex from public.exercises
   where lesson_id = v_lesson and position = 1;
  v_res := public.submit_exercise(v_ex.id, to_jsonb(-1));
  if (v_res->>'correct')::boolean then
    raise exception 'MAJOOP TEST FAIL: mauvaise réponse comptée correcte';
  end if;
  select coalesce(sum(xp),0) into v_n from public.xp_events where user_id = v_a;
  if v_n <> 0 then raise exception 'MAJOOP TEST FAIL: XP attribué sans bonne réponse'; end if;

  -- Construction des réponses attendues (comme le ferait un client légitime)
  -- ⚠️ faite en contexte postgres : l'utilisateur ne peut PAS lire les clés lui-même
  execute 'reset role';
  select coalesce(jsonb_object_agg(e.id, case e.type
      when 'mcq' then (k.correct->'answer')
      when 'listening' then coalesce(k.correct->'answer', to_jsonb(k.correct->'variants'->>0))
      when 'translation' then to_jsonb(k.correct->'variants'->>0)
      when 'gap_fill' then k.correct->'blanks'
      when 'matching' then k.correct->'pairs'
      when 'reorder' then k.correct->'order'
      when 'reading' then k.correct->'answers'
      else 'null'::jsonb end), '{}'::jsonb)
    into v_keys
    from public.exercises e
    join public.exercise_answer_keys k on k.exercise_id = e.id
   where e.lesson_id = v_lesson and e.type <> 'speaking';

  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);

  -- Bonne réponse : +10 XP (barème par défaut)
  v_ans := v_keys -> v_ex.id::text;
  v_res := public.submit_exercise(v_ex.id, v_ans);
  if (v_res->>'correct')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: bonne réponse comptée fausse : %', v_res::text;
  end if;
  select xp_total into v_xp from public.profiles where id = v_a;
  if v_xp <> 10 then
    raise exception 'MAJOOP TEST FAIL: XP attendu 10, obtenu %', v_xp;
  end if;
  raise notice 'OK 4c — correction serveur : mauvaise = 0 XP, bonne = +10 XP';

  -- Jeu : XP borné, jeu inconnu refusé
  v_res := public.record_game_result('memory', 100, 60, '{}');
  if coalesce((v_res->>'xp')::int, 0) <> 10 then
    raise exception 'MAJOOP TEST FAIL: XP de jeu attendu 10, obtenu %', v_res::text;
  end if;
  v_ok := false;
  begin
    perform public.record_game_result('jeu_bidon', 100, 60, '{}');
    v_ok := true;
  exception when others then
    raise notice 'OK 4d — jeu inconnu refusé (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: jeu inconnu accepté'; end if;

  -- ============================================================
  -- Défenses anti-triche
  -- ============================================================
  v_ok := false;
  begin
    insert into public.xp_events (user_id, source, ref, xp) values (v_a, 'admin', 'triche', 999);
    v_ok := true;
  exception when others then
    raise notice 'OK 5a — insertion directe d''XP refusée (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un client peut s''attribuer de l''XP !'; end if;

  v_ok := false;
  begin
    update public.profiles set is_admin = true where id = v_a;
    v_ok := true;
  exception when others then
    raise notice 'OK 5b — auto-promotion admin refusée (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un client peut se rendre admin !'; end if;

  v_ok := false;
  begin
    update public.daily_missions set progress = 999 where user_id = v_a;
    v_ok := true;
  exception when others then
    raise notice 'OK 5c — triche de mission refusée (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: un client peut tricher les missions !'; end if;

  -- Isolation inter-utilisateurs : A ne voit rien de B
  if exists (select 1 from public.xp_events where user_id = v_b) then
    raise exception 'MAJOOP TEST FAIL: A lit les XP de B';
  end if;
  if exists (select 1 from public.profiles where id = v_b) then
    raise exception 'MAJOOP TEST FAIL: A lit le profil de B';
  end if;
  raise notice 'OK 5/7 — anti-triche et isolation inter-utilisateurs';

  -- ============================================================
  -- Leçon complète : XP, badge, mission, niveau
  -- ============================================================
  -- Les 5 exercices restants, soumis correctement
  for v_ex in
    select id, position from public.exercises
     where lesson_id = v_lesson and position > 1 order by position
  loop
    v_ans := v_keys -> v_ex.id::text;
    v_res := public.submit_exercise(v_ex.id, v_ans);
    if (v_res->>'correct')::boolean is not true then
      raise exception 'MAJOOP TEST FAIL: soumission position % échouée : %',
        v_ex.position, v_res::text;
    end if;
  end loop;

  -- 6 bonnes réponses = +60 XP ; la leçon complète = +30 ; le badge = +20
  v_res := public.complete_lesson(v_lesson);
  if (v_res->>'status') <> 'completed' or (v_res->>'xp')::int <> 30 then
    raise exception 'MAJOOP TEST FAIL: complétion leçon anormale : %', v_res::text;
  end if;
  if not exists (select 1 from public.user_achievements
                  where user_id = v_a and achievement_code = 'first_lesson') then
    raise exception 'MAJOOP TEST FAIL: badge first_lesson non attribué';
  end if;

  select xp_total, level into v_xp, v_lvl from public.profiles where id = v_a;
  -- 60 + 10 (jeu) + 30 (leçon) + 20 (badge) = 120 XP → niveau 2
  if v_xp <> 120 or v_lvl <> 2 then
    raise exception 'MAJOOP TEST FAIL: attendu XP=120 niveau=2, obtenu XP=% niveau=%', v_xp, v_lvl;
  end if;

  -- Idempotence : refaire la leçon ne rapporte rien
  v_res := public.complete_lesson(v_lesson);
  if (v_res->>'xp')::int <> 0 then
    raise exception 'MAJOOP TEST FAIL: leçon re-récompensée (exploit)';
  end if;
  select xp_total into v_xp from public.profiles where id = v_a;
  if v_xp <> 120 then raise exception 'MAJOOP TEST FAIL: XP dupliqués par re-complétion'; end if;

  -- Réclamer la mission : 6 bonnes réponses = objectif atteint
  select id into v_m from public.daily_missions
   where user_id = v_a and mission_date = current_date and template_code = 'answer_exercises';
  v_res := public.claim_mission(v_m);
  if (v_res->>'xp')::int <> 50 then
    raise exception 'MAJOOP TEST FAIL: récompense mission != 50';
  end if;
  select xp_total, level into v_xp, v_lvl from public.profiles where id = v_a;
  if v_xp <> 170 or v_lvl <> 2 then
    raise exception 'MAJOOP TEST FAIL: attendu XP=170 niveau=2, obtenu XP=% niveau=%', v_xp, v_lvl;
  end if;

  -- Série : première activité du jour
  select current_streak into v_n from public.daily_streaks where user_id = v_a;
  if v_n <> 1 then raise exception 'MAJOOP TEST FAIL: série attendue = 1, obtenue %', v_n; end if;

  -- Classement (opt-in par défaut)
  v_res := public.get_leaderboard(20);
  if not (v_res::text like '%Alice%') then
    raise exception 'MAJOOP TEST FAIL: Alice absente du classement';
  end if;
  raise notice 'OK 6/7 — leçon, XP=170, niveau 2, badge, mission réclamée, série, classement';

  -- ============================================================
  -- Garde-fous admin et IA
  -- ============================================================
  v_ok := false;
  begin
    perform public.admin_stats();
    v_ok := true;
  exception when others then
    raise notice 'OK 7a — admin_stats refusé à un non-admin (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: non-admin peut appeler admin_stats'; end if;

  v_ok := false;
  begin
    perform public.ai_consume_quota(gen_random_uuid(), 'test');
    v_ok := true;
  exception when others then
    raise notice 'OK 7b — fonction IA refusée au client (%)', sqlerrm;
  end;
  if v_ok then raise exception 'MAJOOP TEST FAIL: le client peut appeler les fonctions IA'; end if;
  execute 'reset role';

  -- Admin attribué CÔTÉ SERVEUR uniquement : alors ça marche
  update public.profiles set is_admin = true where id = v_a;
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', v_a)::text);
  v_res := public.admin_stats();
  if (v_res->>'users_total')::int < 2 then
    raise exception 'MAJOOP TEST FAIL: stats admin incohérentes';
  end if;
  v_res := public.admin_set_setting('xp_correct_answer', '15', 'test');
  if (v_res->>'ok')::boolean is not true then
    raise exception 'MAJOOP TEST FAIL: admin_set_setting échoué';
  end if;
  execute 'reset role';
  update public.profiles set is_admin = false where id = v_a;
  update public.admin_settings set value = '10'::jsonb where key = 'xp_correct_answer';
  raise notice 'OK 7/7 — accès admin strictement côté serveur';

  -- ============================================================
  -- Plafond d'XP journalier (anti-abus)
  -- ============================================================
  perform public.award_xp(v_a, 'exercise', 'cap-test-1', 595);
  v_res := public.award_xp(v_a, 'exercise', 'cap-test-2', 100);
  if (v_res)::int <> 0 then
    raise exception 'MAJOOP TEST FAIL: plafond journalier non appliqué (award=%)', v_res::text;
  end if;
  raise notice 'OK bonus — plafond d''XP journalier actif';

  -- ============================================================
  -- Nettoyage
  -- ============================================================
  delete from auth.users where id in (v_a, v_b);
  raise notice '✅ TOUS LES TESTS DE SÉCURITÉ SONT PASSÉS (utilisateurs de test supprimés)';
end $$;
