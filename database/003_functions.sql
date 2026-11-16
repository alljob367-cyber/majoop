-- ============================================================
-- MAJOOP — Migration 003 : Logique serveur (SECURITY DEFINER)
-- TOUTE validation sensible et TOUTE attribution d'XP vivent ici.
-- Le client ne peut jamais s'auto-attribuer d'XP ni lire les réponses.
-- ============================================================

-- ============================================================
-- 1. PARAMÈTRES ET HELPERS
-- ============================================================

-- Lecture d'un paramètre admin avec valeur par défaut
create or replace function public.get_setting(p_key text, p_default jsonb)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.admin_settings where key = p_key), p_default);
$$;

-- Niveau atteint pour un total d'XP (palier n : 50*(n-1)*n)
create or replace function public.level_for_xp(p_xp int)
returns int language sql immutable as $$
  select greatest(1, floor((sqrt(2500.0 + 200.0 * greatest(p_xp,0)) - 50) / 100)::int + 1);
$$;

-- Normalisation de texte pour la correction (cas, accents, ponctuation)
-- Portables et sans extension : translate() gère les accents latins courants.
create or replace function public.norm_text(p text)
returns text language sql immutable as $$
  select trim(regexp_replace(
    translate(lower(coalesce(p, '')),
      'àáâãäçèéêëìíîïñòóôõöùúûüýÿßœ', 'aaaaaceeeeiiiinooooouuuuyysssoe'),
    '[^a-z0-9\s]', '', 'g'
  ));
$$;

-- ============================================================
-- 2. ATTRIBUTION D'XP — UNIQUE CHEMIN D'ENTRÉE (interne)
--    Plafonds journaliers anti-abus configurables via admin_settings.
-- ============================================================
create or replace function public.award_xp(
  p_user uuid, p_source public.xp_source, p_ref text, p_xp int, p_meta jsonb default '{}'
)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_cap  int;
  v_today int;
  v_award int;
begin
  if p_xp <= 0 then return 0; end if;

  v_cap := case p_source
             when 'exercise' then (public.get_setting('daily_xp_cap_exercise', '600'))::int
             when 'game'     then (public.get_setting('daily_xp_cap_game', '150'))::int
             else 10000
           end;

  select coalesce(sum(xp), 0) into v_today
    from public.xp_events
   where user_id = p_user and source = p_source
     and created_at >= date_trunc('day', now());

  v_award := least(p_xp, greatest(0, v_cap - v_today));
  if v_award <= 0 then return 0; end if;

  insert into public.xp_events (user_id, source, ref, xp, meta)
  values (p_user, p_source, p_ref, v_award, p_meta);

  return v_award;
end;
$$;

-- ============================================================
-- 3. SÉRIE QUOTIDIENNE
-- ============================================================
create or replace function public.update_streak(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_row   public.daily_streaks;
  v_bonus int;
begin
  select * into v_row from public.daily_streaks where user_id = p_user for update;
  if not found then
    insert into public.daily_streaks (user_id, current_streak, best_streak, last_active_date)
    values (p_user, 1, 1, current_date)
    on conflict (user_id) do nothing;
    return;
  end if;

  if v_row.last_active_date = current_date then
    return;  -- déjà actif aujourd'hui
  end if;

  if v_row.last_active_date = current_date - 1 then
    update public.daily_streaks
       set current_streak = current_streak + 1,
           best_streak    = greatest(best_streak, current_streak + 1),
           last_active_date = current_date
     where user_id = p_user
     returning current_streak into v_row.current_streak;
  else
    update public.daily_streaks
       set current_streak = 1,
           best_streak    = greatest(best_streak, 1),
           last_active_date = current_date
     where user_id = p_user
     returning current_streak into v_row.current_streak;
  end if;

  -- Bonus tous les 7 jours consécutifs (barème configurable)
  if v_row.current_streak > 0 and v_row.current_streak % 7 = 0 then
    v_bonus := (public.get_setting('xp_streak_bonus', '100'))::int;
    perform public.award_xp(p_user, 'streak', 'streak_' || v_row.current_streak, v_bonus,
                            jsonb_build_object('days', v_row.current_streak));
  end if;
end;
$$;

-- ============================================================
-- 4. BADGES
-- ============================================================
create or replace function public.check_achievements(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_lessons int; v_correct int; v_games int; v_xp int; v_streak int;
  v_rec record;
begin
  select count(*) into v_lessons from public.lesson_progress
   where user_id = p_user and status = 'completed';
  select count(*) into v_correct from public.exercise_attempts
   where user_id = p_user and is_correct;
  select count(*) into v_games from public.xp_events
   where user_id = p_user and source = 'game';
  select xp_total into v_xp from public.profiles where id = p_user;
  select coalesce(current_streak, 0) into v_streak from public.daily_streaks where user_id = p_user;

  -- Un seul passage : chaque candidat éligible est tenté une fois ;
  -- l'XP du badge n'est accordé que si l'insertion a réellement eu lieu (FOUND).
  for v_rec in
    select * from (values
      (v_lessons  >= 1,   'first_lesson', 20),
      (v_correct  >= 50,  'exercises_50', 50),
      (v_streak   >= 7,   'streak_7',     50),
      (v_games    >= 10,  'game_master',  50),
      (v_xp       >= 500, 'xp_500',       50),
      (v_xp       >= 2000,'xp_2000',      100)
    ) as t(ok, code, reward)
    where ok
  loop
    insert into public.user_achievements (user_id, achievement_code)
    values (p_user, v_rec.code)
    on conflict (user_id, achievement_code) do nothing;

    if found then
      perform public.award_xp(p_user, 'achievement', 'badge_' || v_rec.code,
                              v_rec.reward, jsonb_build_object('badge', v_rec.code));
    end if;
  end loop;
end;
$$;

-- ============================================================
-- 5. MISSIONS QUOTIDIENNES
-- ============================================================

-- Génère (idempotent) les 3 missions du jour pour un utilisateur
create or replace function public.ensure_daily_missions(p_user uuid)
returns setof public.daily_missions
language plpgsql security definer set search_path = public as $$
begin
  insert into public.daily_missions (user_id, mission_date, template_code, target, xp_reward)
  values
    (p_user, current_date, 'answer_exercises',
      5 + least(10, (select level from public.profiles where id = p_user)),
      (public.get_setting('xp_daily_mission', '50'))::int),
    (p_user, current_date, 'complete_lesson', 1,
      (public.get_setting('xp_daily_mission', '50'))::int),
    (p_user, current_date, 'play_game', 1,
      (public.get_setting('xp_daily_mission', '50'))::int)
  on conflict (user_id, mission_date, template_code) do nothing;

  return query select * from public.daily_missions
   where user_id = p_user and mission_date = current_date
   order by template_code;
end;
$$;

-- Incrémente la progression d'une mission du jour (appelé par les fonctions serveur)
create or replace function public.progress_mission(p_user uuid, p_template text, p_amount int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.daily_missions
     set progress = least(target, progress + p_amount)
   where user_id = p_user and mission_date = current_date and template_code = p_template;
end;
$$;

-- Réclamer la récompense d'une mission terminée
create or replace function public.claim_mission(p_mission uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_row public.daily_missions;
  v_xp  int;
begin
  if auth.uid() is null then
    raise exception 'MAJOOP: authentification requise';
  end if;

  select * into v_row from public.daily_missions
   where id = p_mission and user_id = auth.uid() for update;
  if not found then raise exception 'MAJOOP: mission introuvable'; end if;
  if v_row.mission_date <> current_date then
    raise exception 'MAJOOP: mission expiree';
  end if;
  if v_row.claimed then raise exception 'MAJOOP: mission deja reclamée'; end if;
  if v_row.progress < v_row.target then
    raise exception 'MAJOOP: mission non terminee';
  end if;

  update public.daily_missions set claimed = true where id = p_mission;

  v_xp := public.award_xp(auth.uid(), 'mission', v_row.template_code, v_row.xp_reward,
                          jsonb_build_object('mission', p_mission));
  return jsonb_build_object('xp', v_xp);
end;
$$;

-- ============================================================
-- 6. ÉVALUATION DES RÉPONSES (interne — les clés ne sortent jamais)
-- ============================================================
create or replace function public.evaluate_answer(
  p_type public.exercise_type, p_correct jsonb, p_accepted jsonb, p_answer jsonb,
  out is_correct boolean, out ratio numeric, out expected jsonb
)
language plpgsql stable as $$
declare
  v_ans  text;
  v_i    int;
  v_n    int;
  v_ok   int := 0;
  v_carr jsonb;
  v_aarr jsonb;
  v_tmp  boolean := true;
begin
  is_correct := false; ratio := 0; expected := 'null'::jsonb;

  case p_type
    when 'mcq' then
      expected := p_correct->'answer';
      begin
        v_i := (p_answer #>> '{}')::int;
      exception when others then v_i := -1;
      end;
      is_correct := (p_correct->>'answer')::int = v_i;
      ratio := case when is_correct then 1 else 0 end;

    when 'translation' then
      expected := coalesce(p_correct->'variants', jsonb_build_array(p_correct->>'text'));
      v_ans := public.norm_text(p_answer #>> '{}');
      v_carr := coalesce(p_correct->'variants', jsonb_build_array(p_correct->>'text'));
      v_aarr := coalesce(p_accepted, '[]'::jsonb);
      is_correct := exists (
        select 1 from jsonb_array_elements_text(v_carr || v_aarr) a(v)
        where public.norm_text(a.v) = v_ans and coalesce(v_ans, '') <> ''
      );
      ratio := case when is_correct then 1 else 0 end;

    when 'gap_fill' then
      expected := p_correct->'blanks';
      v_n := jsonb_array_length(p_correct->'blanks');
      if jsonb_typeof(p_answer) = 'array' and jsonb_array_length(p_answer) = v_n then
        for v_i in 0 .. v_n - 1 loop
          if public.norm_text(p_answer->>v_i) = public.norm_text(p_correct->'blanks'->>v_i) then
            v_ok := v_ok + 1;
          end if;
        end loop;
        ratio := round(v_ok::numeric / greatest(v_n,1), 3);
        is_correct := v_ok = v_n;
      end if;

    when 'matching' then
      expected := p_correct->'pairs';
      v_n := jsonb_array_length(p_correct->'pairs');
      if jsonb_typeof(p_answer) = 'array' and jsonb_array_length(p_answer) = v_n then
        for v_i in 0 .. v_n - 1 loop
          if (p_answer->>v_i)::int = (p_correct->'pairs'->>v_i)::int then
            v_ok := v_ok + 1;
          end if;
        end loop;
        ratio := round(v_ok::numeric / greatest(v_n,1), 3);
        is_correct := v_ok = v_n;
      end if;

    when 'reorder' then
      expected := p_correct->'order';
      v_n := jsonb_array_length(p_correct->'order');
      if jsonb_typeof(p_answer) = 'array' and jsonb_array_length(p_answer) = v_n then
        v_tmp := true;
        for v_i in 0 .. v_n - 1 loop
          if (p_answer->>v_i)::int <> (p_correct->'order'->>v_i)::int then v_tmp := false; end if;
        end loop;
        is_correct := v_tmp;
        ratio := case when is_correct then 1 else 0 end;
      end if;

    when 'reading' then
      expected := p_correct->'answers';
      v_n := jsonb_array_length(p_correct->'answers');
      if jsonb_typeof(p_answer) = 'array' and jsonb_array_length(p_answer) = v_n then
        for v_i in 0 .. v_n - 1 loop
          if (p_answer->>v_i)::int = (p_correct->'answers'->>v_i)::int then
            v_ok := v_ok + 1;
          end if;
        end loop;
        ratio := round(v_ok::numeric / greatest(v_n,1), 3);
        is_correct := v_ok = v_n;
      end if;

    when 'listening' then
      if p_correct ? 'variants' or p_correct ? 'text' then
        expected := coalesce(p_correct->'variants', jsonb_build_array(p_correct->>'text'));
        v_ans := public.norm_text(p_answer #>> '{}');
        is_correct := exists (
          select 1 from jsonb_array_elements_text(
            coalesce(p_correct->'variants', jsonb_build_array(p_correct->>'text')) || coalesce(p_accepted, '[]'::jsonb)
          ) a(v)
          where public.norm_text(a.v) = v_ans and coalesce(v_ans, '') <> ''
        );
      else
        expected := p_correct->'answer';
        begin
          v_i := (p_answer #>> '{}')::int;
        exception when others then v_i := -1;
        end;
        is_correct := (p_correct->>'answer')::int = v_i;
      end if;
      ratio := case when is_correct then 1 else 0 end;

    else  -- 'speaking' : reporté à une version ultérieure
      is_correct := false; ratio := 0;
  end case;
end;
$$;

-- ============================================================
-- 7. SOUMISSION D'EXERCICE (RPC principal du client)
-- ============================================================
create or replace function public.submit_exercise(p_exercise uuid, p_answer jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ex    public.exercises;
  v_key   public.exercise_answer_keys;
  v_ok    boolean; v_ratio numeric; v_expected jsonb;
  v_xp    int;
begin
  if auth.uid() is null then
    raise exception 'MAJOOP: authentification requise';
  end if;

  select * into v_ex from public.exercises
   where id = p_exercise and is_published;
  if not found then raise exception 'MAJOOP: exercice introuvable'; end if;
  if v_ex.type = 'speaking' then
    raise exception 'MAJOOP: expression orale bientot disponible';
  end if;

  select * into v_key from public.exercise_answer_keys where exercise_id = p_exercise;
  if not found then raise exception 'MAJOOP: exercice non corrige'; end if;

  perform public.evaluate_answer(v_ex.type, v_key.correct, v_key.accepted, p_answer,
                                 v_ok, v_ratio, v_expected);

  insert into public.exercise_attempts (user_id, exercise_id, answer, is_correct, score_ratio)
  values (auth.uid(), p_exercise, coalesce(p_answer, '{}'::jsonb), v_ok, v_ratio);

  v_xp := 0;
  if v_ok then
    v_xp := public.award_xp(auth.uid(), 'exercise', p_exercise::text,
                            (public.get_setting('xp_correct_answer', '10'))::int,
                            jsonb_build_object('type', v_ex.type, 'lesson', v_ex.lesson_id));
    perform public.progress_mission(auth.uid(), 'answer_exercises', 1);
  end if;

  return jsonb_build_object(
    'correct', v_ok,
    'ratio', v_ratio,
    'expected', v_expected,
    'explanation', v_key.explanation,
    'xp', v_xp
  );
end;
$$;

-- ============================================================
-- 8. COMPLÉTION DE LEÇON
-- ============================================================
create or replace function public.complete_lesson(p_lesson uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_total   int; v_correct int; v_score int;
  v_status  public.progress_status;
  v_prev    public.progress_status;
  v_xp      int := 0;
begin
  if auth.uid() is null then
    raise exception 'MAJOOP: authentification requise';
  end if;
  if not exists (select 1 from public.lessons where id = p_lesson and is_published) then
    raise exception 'MAJOOP: lecon introuvable';
  end if;

  select count(*) into v_total from public.exercises
   where lesson_id = p_lesson and is_published and type <> 'speaking';
  select count(distinct exercise_id) into v_correct
    from public.exercise_attempts
   where user_id = auth.uid() and is_correct
     and exercise_id in (select id from public.exercises where lesson_id = p_lesson);

  if v_total = 0 then v_score := 100; else v_score := round(100.0 * v_correct / v_total); end if;
  v_status := case when v_score >= 70 then 'completed' else 'in_progress' end;

  select status into v_prev from public.lesson_progress
   where user_id = auth.uid() and lesson_id = p_lesson;

  insert into public.lesson_progress (user_id, lesson_id, status, score_pct, completed_at)
  values (auth.uid(), p_lesson, v_status, v_score, case when v_status = 'completed' then now() end)
  on conflict (user_id, lesson_id) do update
    set status = case
          when lesson_progress.status = 'completed' then 'completed'::public.progress_status
          else v_status
        end,
        score_pct = greatest(lesson_progress.score_pct, v_score),
        completed_at = coalesce(lesson_progress.completed_at,
                          case when v_status = 'completed' then now() end);

  -- XP de leçon : une seule fois, uniquement à la première complétion
  if v_status = 'completed' and coalesce(v_prev, 'in_progress') <> 'completed' then
    v_xp := public.award_xp(auth.uid(), 'lesson', p_lesson::text,
                            (public.get_setting('xp_lesson_complete', '30'))::int,
                            jsonb_build_object('lesson', p_lesson, 'score', v_score));
    perform public.progress_mission(auth.uid(), 'complete_lesson', 1);
  end if;

  return jsonb_build_object('score', v_score, 'status', v_status::text, 'xp', v_xp);
end;
$$;

-- ============================================================
-- 9. RÉSULTAT DE JEU
-- ============================================================
create or replace function public.record_game_result(
  p_game text, p_score int, p_duration_sec int default 0, p_meta jsonb default '{}'
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_games text[] := array['memory','quiz_race','quick_translate','sentence_builder',
                          'match_image','vocab_challenge','conjugation','daily_challenge'];
  v_xp int := 0;
  v_ref text;
begin
  if auth.uid() is null then
    raise exception 'MAJOOP: authentification requise';
  end if;
  if not (p_game = any(v_games)) then raise exception 'MAJOOP: jeu inconnu'; end if;
  p_score    := least(greatest(coalesce(p_score, 0), 0), 500);
  p_duration_sec := least(greatest(coalesce(p_duration_sec, 0), 0), 1800);

  v_ref := p_game || '_' || to_char(current_date, 'YYYY-MM-DD');

  -- Défi quotidien : récompensé une seule fois par jour
  if p_game = 'daily_challenge' and exists (
       select 1 from public.xp_events
        where user_id = auth.uid() and source = 'game' and ref = v_ref) then
    return jsonb_build_object('xp', 0, 'message', 'defi_deja_recompense');
  end if;

  -- Minimum 30 points pour obtenir de l'XP (anti-farm)
  if p_score >= 30 then
    v_xp := public.award_xp(auth.uid(), 'game', v_ref,
                            least(20, greatest(1, p_score / 10)),
                            jsonb_build_object('game', p_game, 'score', p_score,
                                               'duration', p_duration_sec));
  end if;

  perform public.progress_mission(auth.uid(), 'play_game', 1);
  return jsonb_build_object('xp', v_xp);
end;
$$;

-- ============================================================
-- 10. ONBOARDING
-- ============================================================
create or replace function public.complete_onboarding(
  p_interface_lang text, p_target_lang text, p_cefr text,
  p_objective text, p_daily_minutes int
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_lang_id uuid;
begin
  if auth.uid() is null then
    raise exception 'MAJOOP: authentification requise';
  end if;
  if p_interface_lang not in ('en','fr','es','de') or p_target_lang not in ('en','fr','es','de') then
    raise exception 'MAJOOP: langue inconnue';
  end if;
  if p_cefr not in ('A1','A2','B1','B2','C1','C2') then
    raise exception 'MAJOOP: niveau inconnu';
  end if;

  select id into v_lang_id from public.languages where code = p_target_lang and is_active;
  if v_lang_id is null then raise exception 'MAJOOP: langue inactive'; end if;

  update public.profiles
     set interface_lang = p_interface_lang,
         target_lang    = p_target_lang,
         cefr_level     = p_cefr::public.cefr_level,
         daily_goal_minutes = least(greatest(coalesce(p_daily_minutes, 15), 5), 240),
         onboarded_at   = now()
   where id = auth.uid();

  insert into public.enrollments (user_id, language_id, cefr_level, objective, daily_minutes)
  values (auth.uid(), v_lang_id, p_cefr::public.cefr_level,
          left(coalesce(p_objective, ''), 200),
          least(greatest(coalesce(p_daily_minutes, 15), 5), 240))
  on conflict (user_id, language_id) do update
    set cefr_level = excluded.cefr_level,
        objective  = excluded.objective,
        daily_minutes = excluded.daily_minutes;

  return jsonb_build_object('ok', true, 'target_lang', p_target_lang);
end;
$$;

-- ============================================================
-- 11. CLASSEMENT (opt-in via user_settings.share_leaderboard)
-- ============================================================
create or replace function public.get_leaderboard(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_enabled boolean;
begin
  v_enabled := (public.get_setting('leaderboard_enabled', 'true'))::text::boolean;
  if not v_enabled then return jsonb_build_array(); end if;

  return coalesce(jsonb_agg(r), '[]'::jsonb) from (
    select jsonb_build_object(
             'rank', row_number() over (order by p.xp_total desc),
             'first_name', p.first_name,
             'level', p.level, 'xp_total', p.xp_total,
             'streak', s.current_streak
           ) as r
      from public.profiles p
      join public.user_settings st on st.user_id = p.id
      left join public.daily_streaks s on s.user_id = p.id
     where st.share_leaderboard and p.xp_total > 0
     order by p.xp_total desc
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) t;
end;
$$;

-- ============================================================
-- 12. DASHBOARD — agrégat unique pour l'accueil
-- ============================================================
create or replace function public.get_dashboard()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_p   public.profiles;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'MAJOOP: authentification requise'; end if;
  select * into v_p from public.profiles where id = v_uid;

  perform public.ensure_daily_missions(v_uid);

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'first_name', v_p.first_name,
      'interface_lang', v_p.interface_lang,
      'target_lang', v_p.target_lang,
      'cefr_level', v_p.cefr_level,
      'xp_total', v_p.xp_total,
      'level', v_p.level,
      'level_floor_xp', 50 * (v_p.level - 1) * v_p.level,
      'next_level_xp',  50 * v_p.level * (v_p.level + 1),
      'daily_goal_minutes', v_p.daily_goal_minutes,
      'onboarded', (v_p.onboarded_at is not null)
    ),
    'streak', (select jsonb_build_object('current', current_streak, 'best', best_streak,
                                         'last_active', last_active_date)
               from public.daily_streaks where user_id = v_uid),
    'missions', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'template', template_code,
                    'target', target, 'progress', progress, 'claimed', claimed,
                    'xp_reward', xp_reward) order by template_code)
      from public.daily_missions
       where user_id = v_uid and mission_date = current_date), '[]'::jsonb),
    'stats', jsonb_build_object(
      'lessons_completed', (select count(*) from public.lesson_progress
                             where user_id = v_uid and status = 'completed'),
      'exercises_correct', (select count(*) from public.exercise_attempts
                             where user_id = v_uid and is_correct),
      'xp_today', (select coalesce(sum(xp),0) from public.xp_events
                    where user_id = v_uid and created_at >= date_trunc('day', now())),
      'minutes_today_est', ((select count(*) from public.exercise_attempts
                              where user_id = v_uid and created_at >= date_trunc('day', now())) * 30
                          + (select coalesce(sum((meta->>'duration')::int), 0)
                             from public.xp_events
                             where user_id = v_uid and source = 'game'
                               and created_at >= date_trunc('day', now()))) / 60
    ),
    'next_lesson', coalesce((
      select jsonb_build_object('id', l.id, 'title', l.title,
             'course', c.title, 'module', m.title, 'level', c.cefr_level)
        from public.enrollments e
        join public.courses c  on c.language_id = e.language_id and c.is_published
        join public.modules m  on m.course_id = c.id
        join public.lessons l  on l.module_id = m.id and l.is_published
       where e.user_id = v_uid
         and not exists (select 1 from public.lesson_progress lp
                          where lp.user_id = v_uid and lp.lesson_id = l.id
                            and lp.status = 'completed')
       order by c.cefr_level, c.sort_order, m.sort_order, l.sort_order
       limit 1
    ), 'null'::jsonb),
    'badges_recent', coalesce((
      select jsonb_agg(jsonb_build_object('code', ua.achievement_code, 'at', ua.granted_at)
                       order by ua.granted_at desc)
      from public.user_achievements ua where ua.user_id = v_uid limit 5), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- ============================================================
-- 13. VUES DE CONTENU (arbre cours→modules→leçons + statut utilisateur)
-- ============================================================
create or replace function public.get_language_overview(p_lang text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'MAJOOP: authentification requise'; end if;

  return coalesce(jsonb_agg(course order by course->>'level', course->>'sort'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', c.id, 'code', c.code, 'title', c.title, 'description', c.description,
      'level', c.cefr_level, 'sort', c.sort_order,
      'modules', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', m.id, 'title', m.title, 'description', m.description, 'sort', m.sort_order,
                 'lessons', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'id', l.id, 'title', l.title, 'objective', l.objective,
                            'minutes', l.estimated_minutes, 'sort', l.sort_order,
                            'status', (select lp.status::text from public.lesson_progress lp
                                        where lp.user_id = v_uid and lp.lesson_id = l.id),
                            'score', (select lp.score_pct from public.lesson_progress lp
                                       where lp.user_id = v_uid and lp.lesson_id = l.id)
                          ) order by l.sort_order)
                   from public.lessons l
                  where l.module_id = m.id and l.is_published
                 ), '[]'::jsonb)
               ) order by m.sort_order)
        from public.modules m where m.course_id = c.id
      ), '[]'::jsonb)
    ) as course
    from public.courses c
    join public.languages lg on lg.id = c.language_id
    where lg.code = p_lang and c.is_published
  ) t;
end;
$$;

-- Contenu d'une leçon : mini-cours + exercices publics (JAMAIS les réponses)
create or replace function public.get_lesson_content(p_lesson uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_l public.lessons;
begin
  if v_uid is null then raise exception 'MAJOOP: authentification requise'; end if;

  select * into v_l from public.lessons where id = p_lesson and is_published;
  if not found then raise exception 'MAJOOP: lecon introuvable'; end if;

  return jsonb_build_object(
    'id', v_l.id, 'title', v_l.title, 'objective', v_l.objective,
    'explanation', v_l.explanation, 'vocab', v_l.vocab, 'examples', v_l.examples,
    'minutes', v_l.estimated_minutes,
    'exercises', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'type', e.type, 'position', e.position,
               'prompt', e.prompt, 'points', e.points
             ) order by e.position)
      from public.exercises e
      where e.lesson_id = v_l.id and e.is_published
    ), '[]'::jsonb),
    'my_status', (select lp.status::text from public.lesson_progress lp
                   where lp.user_id = v_uid and lp.lesson_id = v_l.id),
    'my_score', (select lp.score_pct from public.lesson_progress lp
                  where lp.user_id = v_uid and lp.lesson_id = v_l.id)
  );
end;
$$;

-- ============================================================
-- 14. IA — fonctions réservées au service_role (Edge Function)
-- ============================================================

-- Contexte complet pour le prompt système du tuteur
create or replace function public.ai_get_context(p_conversation uuid, p_history int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_conv public.ai_conversations;
  v_p public.profiles;
begin
  select * into v_conv from public.ai_conversations where id = p_conversation;
  if not found then raise exception 'MAJOOP: conversation introuvable'; end if;
  select * into v_p from public.profiles where id = v_conv.user_id;

  return jsonb_build_object(
    'user', jsonb_build_object(
      'interface_lang', v_p.interface_lang,
      'target_lang', coalesce(v_p.target_lang, 'en'),
      'cefr_level', coalesce(v_p.cefr_level::text, 'A1'),
      'first_name', v_p.first_name
    ),
    'mode', v_conv.mode, 'scenario', v_conv.scenario,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('role', h.role, 'content', h.content)
                       order by h.created_at)
      from (
        select role, content, created_at
          from public.ai_messages
         where conversation_id = p_conversation
         order by created_at desc
         limit greatest(p_history, 2)
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

-- Consomme 1 crédit IA : quotas journalier + intervalle anti-spam
create or replace function public.ai_consume_quota(p_conversation uuid, p_user_msg text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_conv public.ai_conversations;
  v_quota int; v_min_gap int;
  v_today int; v_last timestamptz;
begin
  select * into v_conv from public.ai_conversations where id = p_conversation;
  if not found then raise exception 'MAJOOP: conversation introuvable'; end if;

  v_quota  := (public.get_setting('ai_daily_quota', '20'))::int;
  v_min_gap := (public.get_setting('ai_min_interval_sec', '3'))::int;

  select count(*) into v_today
    from public.ai_messages m
    join public.ai_conversations c on c.id = m.conversation_id
   where c.user_id = v_conv.user_id and m.role = 'user'
     and m.created_at >= date_trunc('day', now());

  if v_today >= v_quota then
    return jsonb_build_object('ok', false, 'reason', 'quota',
      'message', 'Limite quotidienne atteinte (' || v_quota || ' messages). Reviens demain !');
  end if;

  select max(m.created_at) into v_last
    from public.ai_messages m
    join public.ai_conversations c on c.id = m.conversation_id
   where c.user_id = v_conv.user_id and m.role = 'user';

  if v_last is not null and now() - v_last < make_interval(secs => v_min_gap) then
    return jsonb_build_object('ok', false, 'reason', 'rate',
      'message', 'Un peu de calme ! Attends quelques secondes entre chaque message.');
  end if;

  insert into public.ai_messages (conversation_id, role, content)
  values (p_conversation, 'user', left(p_user_msg, 4000));

  perform public.progress_mission(v_conv.user_id, 'ai_chat', 1);
  return jsonb_build_object('ok', true);
end;
$$;

-- Sauvegarde la réponse du tuteur
create or replace function public.ai_save_tutor_message(p_conversation uuid, p_content text)
returns void language sql security definer set search_path = public as $$
  insert into public.ai_messages (conversation_id, role, content)
  values (p_conversation, 'tutor', left(p_content, 12000));
$$;

-- ============================================================
-- 15. ADMINISTRATION
-- ============================================================

-- Chaque fonction admin vérifie is_admin() : attribuer admin = SQL serveur uniquement.

create or replace function public.admin_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return jsonb_build_object(
    'users_total',    (select count(*) from public.profiles),
    'users_week',     (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
    'lessons_done',   (select count(*) from public.lesson_progress where status = 'completed'),
    'attempts_total', (select count(*) from public.exercise_attempts),
    'attempts_correct', (select count(*) from public.exercise_attempts where is_correct),
    'xp_total',       (select coalesce(sum(xp),0) from public.xp_events),
    'ai_msgs_today',  (select count(*) from public.ai_messages where created_at >= date_trunc('day', now())),
    'ai_users_today', (select count(distinct c.user_id) from public.ai_messages m
                        join public.ai_conversations c on c.id = m.conversation_id
                        where m.created_at >= date_trunc('day', now()))
  );
end;
$$;

create or replace function public.admin_list_users(p_limit int default 50, p_offset int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return coalesce(jsonb_agg(row), '[]'::jsonb) from (
    select jsonb_build_object('id', p.id, 'email', p.email, 'first_name', p.first_name,
           'is_admin', p.is_admin, 'xp_total', p.xp_total, 'level', p.level,
           'target_lang', p.target_lang, 'created_at', p.created_at,
           'last_xp_at', (select max(created_at) from public.xp_events x where x.user_id = p.id)
           ) as r
      from public.profiles p
      order by p.created_at desc
      limit least(greatest(p_limit,1), 200) offset greatest(p_offset,0)
  ) t;
end;
$$;

create or replace function public.admin_set_user_admin(p_user uuid, p_admin boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  if p_user = auth.uid() and p_admin = false then
    raise exception 'MAJOOP: impossible de retirer son propre acces admin';
  end if;
  update public.profiles set is_admin = p_admin where id = p_user;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_description text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  insert into public.admin_settings (key, value, description, updated_by)
  values (p_key, p_value, coalesce(p_description, ''), auth.uid())
  on conflict (key) do update
    set value = excluded.value,
        description = coalesce(excluded.description, admin_settings.description),
        updated_by = auth.uid(),
        updated_at = now();
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_list_settings()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return coalesce(jsonb_agg(row), '[]'::jsonb) from (
    select jsonb_build_object('key', key, 'value', value, 'description', description,
           'updated_at', updated_at) as r
      from public.admin_settings order by key
  ) t;
end;
$$;

-- Contenu : upsert générique avec types en liste blanche (langue, cours, module, leçon)
create or replace function public.admin_upsert_content(p_kind text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;

  case p_kind
    when 'language' then
      insert into public.languages (id, code, name, native_name, flag, is_active, sort_order)
      values (coalesce((p_payload->>'id')::uuid, gen_random_uuid()),
              p_payload->>'code', p_payload->>'name', p_payload->>'native_name',
              coalesce(p_payload->>'flag', ''), coalesce((p_payload->>'is_active')::boolean, true),
              coalesce((p_payload->>'sort_order')::int, 0))
      on conflict (code) do update
        set name = excluded.name, native_name = excluded.native_name, flag = excluded.flag,
            is_active = excluded.is_active, sort_order = excluded.sort_order
      returning id into v_id;

    when 'course' then
      insert into public.courses (id, language_id, code, title, description, cefr_level,
                                  is_published, sort_order)
      values (coalesce((p_payload->>'id')::uuid, gen_random_uuid()),
              (p_payload->>'language_id')::uuid, p_payload->>'code', p_payload->>'title',
              coalesce(p_payload->>'description', ''),
              (coalesce(p_payload->>'cefr_level','A1'))::public.cefr_level,
              coalesce((p_payload->>'is_published')::boolean, false),
              coalesce((p_payload->>'sort_order')::int, 0))
      on conflict (code) do update
        set title = excluded.title, description = excluded.description,
            cefr_level = excluded.cefr_level, is_published = excluded.is_published,
            sort_order = excluded.sort_order
      returning id into v_id;

    when 'module' then
      insert into public.modules (id, course_id, code, title, description, sort_order)
      values (coalesce((p_payload->>'id')::uuid, gen_random_uuid()),
              (p_payload->>'course_id')::uuid, p_payload->>'code', p_payload->>'title',
              coalesce(p_payload->>'description',''), coalesce((p_payload->>'sort_order')::int, 0))
      on conflict (code) do update
        set title = excluded.title, description = excluded.description,
            sort_order = excluded.sort_order
      returning id into v_id;

    when 'lesson' then
      insert into public.lessons (id, module_id, code, title, objective, explanation, vocab,
                                  examples, estimated_minutes, is_published, sort_order)
      values (coalesce((p_payload->>'id')::uuid, gen_random_uuid()),
              (p_payload->>'module_id')::uuid, p_payload->>'code', p_payload->>'title',
              coalesce(p_payload->>'objective',''), coalesce(p_payload->>'explanation',''),
              coalesce(p_payload->'vocab','[]'::jsonb), coalesce(p_payload->'examples','[]'::jsonb),
              coalesce((p_payload->>'estimated_minutes')::int, 10),
              coalesce((p_payload->>'is_published')::boolean, false),
              coalesce((p_payload->>'sort_order')::int, 0))
      on conflict (code) do update
        set title = excluded.title, objective = excluded.objective,
            explanation = excluded.explanation, vocab = excluded.vocab,
            examples = excluded.examples, estimated_minutes = excluded.estimated_minutes,
            is_published = excluded.is_published, sort_order = excluded.sort_order
      returning id into v_id;

    else raise exception 'MAJOOP: type de contenu inconnu';
  end case;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Exercice + clé de correction (le seul endroit où la clé est écrite)
create or replace function public.admin_upsert_exercise(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;

  insert into public.exercises (id, lesson_id, type, position, prompt, points, is_published)
  values (coalesce((p_payload->>'id')::uuid, gen_random_uuid()),
          (p_payload->>'lesson_id')::uuid,
          (coalesce(p_payload->>'type','mcq'))::public.exercise_type,
          coalesce((p_payload->>'position')::int, 1),
          coalesce(p_payload->'prompt','{}'::jsonb),
          coalesce((p_payload->>'points')::int, 10),
          coalesce((p_payload->>'is_published')::boolean, false))
  on conflict (lesson_id, position) do update
    set type = excluded.type, prompt = excluded.prompt, points = excluded.points,
        is_published = excluded.is_published
  returning id into v_id;

  if p_payload ? 'correct' then
    insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation)
    values (v_id, p_payload->'correct', coalesce(p_payload->'accepted','[]'::jsonb),
            coalesce(p_payload->>'explanation',''))
    on conflict (exercise_id) do update
      set correct = excluded.correct, accepted = excluded.accepted,
          explanation = excluded.explanation;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.admin_delete_content(p_kind text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  case p_kind
    when 'course'   then delete from public.courses where id = p_id;
    when 'module'   then delete from public.modules where id = p_id;
    when 'lesson'   then delete from public.lessons where id = p_id;
    when 'exercise' then delete from public.exercises where id = p_id;
    else raise exception 'MAJOOP: type de contenu inconnu';
  end case;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_publish(p_kind text, p_id uuid, p_published boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  case p_kind
    when 'course'   then update public.courses   set is_published = p_published where id = p_id;
    when 'lesson'   then update public.lessons   set is_published = p_published where id = p_id;
    when 'exercise' then update public.exercises set is_published = p_published where id = p_id;
    else raise exception 'MAJOOP: type de contenu inconnu';
  end case;
  return jsonb_build_object('ok', true);
end;
$$;

-- Supervision IA : usage par jour (N derniers jours)
create or replace function public.admin_ai_usage(p_days int default 7)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return coalesce(jsonb_agg(row), '[]'::jsonb) from (
    select jsonb_build_object('day', d.day, 'user_msgs', coalesce(u.cnt, 0)) as r
      from generate_series(current_date - (greatest(p_days,1) - 1), current_date, '1 day') d(day)
      left join (
        select date_trunc('day', m.created_at)::date as day, count(*) as cnt
          from public.ai_messages m where m.role = 'user'
         group by 1
      ) u on u.day = d.day
      order by d.day
  ) t;
end;
$$;

-- ============================================================
-- 16. TRIGGER XP (créé ici : toutes les fonctions appelées existent)
-- ============================================================
create trigger trg_xp_event after insert on public.xp_events
  for each row execute function public.on_xp_event();

-- ============================================================
-- 17. PRIVILÈGES D'EXÉCUTION (moindre privilège)
--     Par défaut EXECUTE est accordé à PUBLIC : on révoque puis on accorde.
-- ============================================================
revoke all on function public.get_setting(text, jsonb) from public, anon;
revoke all on function public.level_for_xp(int) from public, anon;
revoke all on function public.norm_text(text) from public, anon;
revoke all on function public.award_xp(uuid, public.xp_source, text, int, jsonb) from public, anon, authenticated;
revoke all on function public.update_streak(uuid) from public, anon, authenticated;
revoke all on function public.check_achievements(uuid) from public, anon, authenticated;
revoke all on function public.ensure_daily_missions(uuid) from public, anon;
revoke all on function public.progress_mission(uuid, text, int) from public, anon;
revoke all on function public.evaluate_answer(public.exercise_type, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.submit_exercise(uuid, jsonb) from public, anon;
revoke all on function public.complete_lesson(uuid) from public, anon;
revoke all on function public.record_game_result(text, int, int, jsonb) from public, anon;
revoke all on function public.complete_onboarding(text, text, text, text, int) from public, anon;
revoke all on function public.get_leaderboard(int) from public, anon;
revoke all on function public.get_dashboard() from public, anon;
revoke all on function public.get_language_overview(text) from public, anon;
revoke all on function public.get_lesson_content(uuid) from public, anon;
revoke all on function public.ai_get_context(uuid, int) from public, anon, authenticated;
revoke all on function public.ai_consume_quota(uuid, text) from public, anon, authenticated;
revoke all on function public.ai_save_tutor_message(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_stats() from public, anon;
revoke all on function public.admin_list_users(int, int) from public, anon;
revoke all on function public.admin_set_user_admin(uuid, boolean) from public, anon;
revoke all on function public.admin_set_setting(text, jsonb, text) from public, anon;
revoke all on function public.admin_list_settings() from public, anon;
revoke all on function public.admin_upsert_content(text, jsonb) from public, anon;
revoke all on function public.admin_upsert_exercise(jsonb) from public, anon;
revoke all on function public.admin_delete_content(text, uuid) from public, anon;
revoke all on function public.admin_set_publish(text, uuid, boolean) from public, anon;
revoke all on function public.admin_ai_usage(int) from public, anon;

grant execute on function public.submit_exercise(uuid, jsonb) to authenticated;
grant execute on function public.complete_lesson(uuid) to authenticated;
grant execute on function public.record_game_result(text, int, int, jsonb) to authenticated;
grant execute on function public.complete_onboarding(text, text, text, text, int) to authenticated;
grant execute on function public.get_leaderboard(int) to authenticated;
grant execute on function public.get_dashboard() to authenticated;
grant execute on function public.get_language_overview(text) to authenticated;
grant execute on function public.get_lesson_content(uuid) to authenticated;
grant execute on function public.ensure_daily_missions(uuid) to authenticated;
grant execute on function public.claim_mission(uuid) to authenticated;
grant execute on function public.level_for_xp(int) to authenticated;
grant execute on function public.get_setting(text, jsonb) to authenticated;

-- IA : réservées à l'Edge Function (service_role)
grant execute on function public.ai_get_context(uuid, int) to service_role;
grant execute on function public.ai_consume_quota(uuid, text) to service_role;
grant execute on function public.ai_save_tutor_message(uuid, text) to service_role;
grant execute on function public.get_setting(text, jsonb) to service_role;

-- Administration : utilisateurs authentifiés (la vérification is_admin est interne)
grant execute on function public.admin_stats() to authenticated;
grant execute on function public.admin_list_users(int, int) to authenticated;
grant execute on function public.admin_set_user_admin(uuid, boolean) to authenticated;
grant execute on function public.admin_set_setting(text, jsonb, text) to authenticated;
grant execute on function public.admin_list_settings() to authenticated;
grant execute on function public.admin_upsert_content(text, jsonb) to authenticated;
grant execute on function public.admin_upsert_exercise(jsonb) to authenticated;
grant execute on function public.admin_delete_content(text, uuid) to authenticated;
grant execute on function public.admin_set_publish(text, uuid, boolean) to authenticated;
grant execute on function public.admin_ai_usage(int) to authenticated;
