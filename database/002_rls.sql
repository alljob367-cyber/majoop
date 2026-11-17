-- ============================================================
-- MAJOOP — Migration 002 : Sécurité (RLS, policies, privilèges)
-- Principe : chaque utilisateur n'accède qu'à ses données ; les réponses
-- des exercices et l'attribution d'XP sont inaccessibles côté client.
-- ============================================================

-- ============================================================
-- 1. FONCTION D'AIDE : rôle administrateur
-- ============================================================
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

-- NB : EXECUTE est accordé aussi à anon — les policies de contenu public
-- (cours, modules, leçons, exercices) appellent is_admin() même pour anon ;
-- sans ce grant, la lecture publique échouerait (permission denied).
-- La fonction ne révèle rien (false si non connecté).
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- ============================================================
-- 2. ACTIVER RLS PARTOUT
-- ============================================================
alter table public.languages            enable row level security;
alter table public.courses              enable row level security;
alter table public.modules              enable row level security;
alter table public.lessons              enable row level security;
alter table public.exercises            enable row level security;
alter table public.exercise_answer_keys enable row level security;
alter table public.profiles             enable row level security;
alter table public.user_settings        enable row level security;
alter table public.enrollments          enable row level security;
alter table public.lesson_progress      enable row level security;
alter table public.exercise_attempts    enable row level security;
alter table public.xp_events            enable row level security;
alter table public.daily_streaks        enable row level security;
alter table public.achievements         enable row level security;
alter table public.user_achievements    enable row level security;
alter table public.daily_missions       enable row level security;
alter table public.ai_conversations     enable row level security;
alter table public.ai_messages          enable row level security;
alter table public.admin_settings       enable row level security;

-- ============================================================
-- 3. CONTENU PUBLIC (langues, cours, modules, leçons, exercices)
--    Lecture autorisée, écriture réservée au service_role / RPC admin.
-- ============================================================

create policy "langues_lecture_publique" on public.languages
  for select to anon, authenticated using (is_active);

create policy "cours_lecture_publie" on public.courses
  for select to anon, authenticated using (is_published or public.is_admin());

create policy "modules_lecture_cours_publie" on public.modules
  for select to anon, authenticated using (
    exists (select 1 from public.courses c
            where c.id = course_id and (c.is_published or public.is_admin()))
  );

create policy "lecons_lecture_publiee" on public.lessons
  for select to anon, authenticated using (
    is_published and exists (
      select 1 from public.modules m
      join public.courses c on c.id = m.course_id
      where m.id = module_id and c.is_published
    ) or public.is_admin()
  );

create policy "exercices_lecture_publiee" on public.exercises
  for select to anon, authenticated using (
    is_published and exists (
      select 1 from public.lessons l
      join public.modules m on m.id = l.module_id
      join public.courses c on c.id = m.course_id
      where l.id = lesson_id and l.is_published and c.is_published
    ) or public.is_admin()
  );

-- ============================================================
-- 4. ⚠️ exercise_answer_keys : DENY TOTAL côté client
--    RLS activée, AUCUNE policy → anon/authenticated ne peuvent RIEN.
--    Seules les fonctions SECURITY DEFINER (003) y accèdent.
-- ============================================================
revoke all on public.exercise_answer_keys from anon, authenticated;

-- ============================================================
-- 5. PROFILS : lecture/écriture de SA ligne ; l'admin lit tout.
--    La colonne is_admin (et xp_total/level/email) n'est PAS modifiable
--    par le client (voir section 8, privilèges par colonne + trigger).
-- ============================================================
create policy "profil_lecture_proprio_ou_admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());

create policy "profil_maj_proprio" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Aucune policy insert/delete : profil créé par trigger handle_new_user.

-- ============================================================
-- 6. PRÉFÉRENCES, INSCRIPTIONS, PROGRESSION (données privées)
-- ============================================================
create policy "settings_proprio" on public.user_settings
  for select to authenticated using (user_id = auth.uid());
create policy "settings_maj_proprio" on public.user_settings
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "enroll_lecture_proprio" on public.enrollments
  for select to authenticated using (user_id = auth.uid());
create policy "enroll_creation_proprio" on public.enrollments
  for insert to authenticated with check (user_id = auth.uid());
create policy "enroll_maj_proprio" on public.enrollments
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "progress_lecture_proprio" on public.lesson_progress
  for select to authenticated using (user_id = auth.uid());
create policy "progress_creation_proprio" on public.lesson_progress
  for insert to authenticated with check (user_id = auth.uid());
create policy "progress_maj_proprio" on public.lesson_progress
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "attempts_lecture_proprio" on public.exercise_attempts
  for select to authenticated using (user_id = auth.uid());
create policy "attempts_creation_proprio" on public.exercise_attempts
  for insert to authenticated with check (user_id = auth.uid());
-- NB : insérer une tentative ne donne AUCUN XP — l'XP ne naît que d'xp_events,
-- alimenté exclusivement par les fonctions serveur de 003.

-- ============================================================
-- 7. TABLES SERVEUR UNIQUEMENT : XP, séries, badges, missions
--    → lecture seule pour le propriétaire ; écriture via fonctions DEFINER.
-- ============================================================
create policy "xp_lecture_proprio" on public.xp_events
  for select to authenticated using (user_id = auth.uid());

create policy "streak_lecture_proprio" on public.daily_streaks
  for select to authenticated using (user_id = auth.uid());

create policy "badges_catalogue_public" on public.achievements
  for select to anon, authenticated using (true);

create policy "badges_user_lecture_proprio" on public.user_achievements
  for select to authenticated using (user_id = auth.uid());

create policy "missions_lecture_proprio" on public.daily_missions
  for select to authenticated using (user_id = auth.uid());

-- Le client ne peut cocher que `claimed` ; l'XP n'est délivré que par claim_mission().
revoke update on public.daily_missions from authenticated;
grant update (claimed) on public.daily_missions to authenticated;

-- ============================================================
-- 8. PROFILS : défense en profondeur contre l'escalade de privilèges
-- ============================================================
-- 8a. Le client ne peut modifier QUE ces colonnes de son profil :
revoke update on public.profiles from authenticated;
grant update (first_name, last_name, avatar_url, interface_lang, target_lang, cefr_level, daily_goal_minutes)
  on public.profiles to authenticated;

-- 8b. Trigger : bloque toute tentative de modification de is_admin
--     hors contexte serveur (service_role / postgres).
create or replace function public.guard_profile_admin_flag()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_admin is distinct from old.is_admin
     and session_user not in ('service_role', 'postgres', 'supabase_admin') then
    raise exception 'MAJOOP: modification de is_admin interdite hors contexte serveur';
  end if;
  return new;
end;
$$;

create trigger trg_guard_is_admin before update on public.profiles
  for each row execute function public.guard_profile_admin_flag();

-- ============================================================
-- 9. PROFESSEUR IA : conversations et messages privés
-- ============================================================
create policy "conv_lecture_proprio" on public.ai_conversations
  for select to authenticated using (user_id = auth.uid());
create policy "conv_creation_proprio" on public.ai_conversations
  for insert to authenticated with check (user_id = auth.uid());
create policy "conv_maj_proprio" on public.ai_conversations
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "conv_suppression_proprio" on public.ai_conversations
  for delete to authenticated using (user_id = auth.uid());

-- L'apprenant insère ses propres messages ; les messages du tuteur sont écrits
-- par l'Edge Function (service_role) → impossible de forger un message 'tutor'.
create policy "msg_lecture_via_conv_proprio" on public.ai_messages
  for select to authenticated using (
    exists (select 1 from public.ai_conversations c
            where c.id = conversation_id and c.user_id = auth.uid())
  );
create policy "msg_creation_message_apprenant" on public.ai_messages
  for insert to authenticated with check (
    role = 'user' and exists (
      select 1 from public.ai_conversations c
      where c.id = conversation_id and c.user_id = auth.uid()
    )
  );

-- ============================================================
-- 10. PARAMÈTRES ADMIN : lecture réservée à l'admin (RPC en 003)
-- ============================================================
create policy "settings_admin_lecture" on public.admin_settings
  for select to authenticated using (public.is_admin());

-- ============================================================
-- 11. ACCÈS ADMIN EN LECTURE sur les données utilisateurs
--     (gestion des utilisateurs, statistiques, supervision IA)
-- ============================================================
create policy "admin_lecture_progress" on public.lesson_progress
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_attempts" on public.exercise_attempts
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_xp" on public.xp_events
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_missions" on public.daily_missions
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_convs" on public.ai_conversations
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_msgs" on public.ai_messages
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_enroll" on public.enrollments
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_streaks" on public.daily_streaks
  for select to authenticated using (public.is_admin());
create policy "admin_lecture_badges" on public.user_achievements
  for select to authenticated using (public.is_admin());
