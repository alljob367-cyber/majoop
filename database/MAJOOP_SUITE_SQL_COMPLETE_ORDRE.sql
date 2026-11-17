-- ══════════════════════════════════════════════════════════════════════════
-- MAJOOP — SUITE SQL COMPLÈTE (fichier unique, ordre d'exécution exact)
-- ══════════════════════════════════════════════════════════════════════════
--
-- PROJET CIBLE D'ORIGINE : noqseajlpogutoneexnf (Supabase, PostgreSQL 17)
-- APPLIQUÉE LE          : 2026-11-16 — ⚠️ CE PROJET EST DÉJÀ MIGRÉ
--
-- ⚠️⚠️  AVERTISSEMENT IMPORTANT  ⚠️⚠️
--   Cette suite a DÉJÀ été exécutée avec succès sur le projet
--   noqseajlpogutoneexnf (toutes les tables existent, site en ligne).
--   NE LA RÉ-EXÉCUTEZ PAS sur ce même projet : CREATE TABLE sans
--   IF NOT EXISTS → erreurs immédiates.
--   À n'utiliser que pour :
--     • un NOUVEAU projet Supabase (reconstruction complète), ou
--     • une conservation / vérification du schéma.
--   Sur un projet neuf : coller TOUT le fichier dans le SQL Editor
--   et cliquer Run UNE SEULE fois. En cas d'erreur en cours de route :
--   Settings → Database → Reset, puis recommencer depuis le début.
--
-- ORDRE DES SECTIONS (celui validé en production) :
--   1/8  001_schema.sql            schéma (25 tables)
--   2/8  002_rls.sql               sécurité RLS
--   3/8  003_functions.sql         logique serveur SECURITY DEFINER
--   4/8  004_seed.sql              bibliothèque de lancement (idempotent)
--   5/10 006_ai_providers.sql      professeur IA multi-fournisseurs (idempotent)
--   6/10 007_monetisation.sql      monétisation Free/Premium (32 RPC)
--   7/10 005_tests_securite.sql    tests de sécurité (auto-nettoyant)
--   8/10 008_tests_monetisation.sql tests de monétisation (auto-nettoyant)
--   9/10 009_concours_hebdomadaire.sql v2 sans gratuit + concours 25 000 F
--  10/10 010_tests_concours.sql    tests du concours (auto-nettoyant)
--
-- NOTE V2 (2026-11-17) : sections 9-10 ajoutées après la v1 — exécuter
-- TOUT le fichier dans l'ordre sur un projet neuf reproduit l'état exact
-- de production (noqseajlpogutoneexnf au 2026-11-17).
--
-- APRÈS MIGRATION (hors SQL) :
--   • Edge Function : npx supabase functions deploy ai-tutor --project-ref <ref>
--     + npx supabase secrets set ... GEMINI_API_KEY=xxx OPENROUTER_API_KEY=xxx MISTRAL_API_KEY=xxx
--   • Premier admin : update public.profiles set is_admin = true
--                     where email = 'ton-email@exemple.com';
--   • Paiements     : Administration → Monétisation, ou
--                     select public.admin_set_setting('payment_instructions', '{...}'::jsonb);
-- ══════════════════════════════════════════════════════════════════════════

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 1/10 — 001_schema.sql
-- SCHÉMA — 25 tables (langues, cours, leçons, exercices, profils, XP, badges, réponses, + 6 tables monétisation). CREATE TABLE sans IF NOT EXISTS.
-- ██████████████████████████████████████████████████████████████████████████

-- ============================================================
-- MAJOOP — Migration 001 : Schéma de la base
-- À exécuter dans l'ordre : 001 → 002 → 003 → 004 (seed) → 005 (tests)
-- Cible : Supabase (PostgreSQL 15+), SQL Editor ou supabase db push
-- ============================================================

-- ============================================================
-- 1. EXTENSIONS ET UTILITAIRES
-- ============================================================
create extension if not exists "pgcrypto";  -- gen_random_uuid()

-- Type énuméré des niveaux CECRL
create type public.cefr_level as enum ('A1', 'A2', 'B1', 'B2', 'C1', 'C2');

-- Types d'exercices (QCM, traduction, trous, association, ordre, compréhension écrite/audio, oral reporté)
create type public.exercise_type as enum (
  'mcq', 'translation', 'gap_fill', 'matching', 'reorder', 'reading', 'listening', 'speaking'
);

-- Statut de progression d'une leçon
create type public.progress_status as enum ('in_progress', 'completed');

-- Sources d'XP (audit complet)
create type public.xp_source as enum (
  'exercise', 'lesson', 'game', 'mission', 'streak', 'achievement', 'admin'
);

-- Modes du professeur IA
create type public.ai_mode as enum (
  'tutor', 'conversation', 'grammar', 'vocabulary', 'situation'
);

-- ============================================================
-- 2. LANGUES ET CONTENU PÉDAGOGIQUE
-- ============================================================

-- Langues disponibles (langues cibles d'apprentissage ; servent aussi de langue d'interface)
create table public.languages (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,             -- 'en', 'fr', 'es', 'de'
  name        text not null,                    -- nom français : 'Anglais'
  native_name text not null,                    -- nom natif : 'English'
  flag        text not null default '',         -- emoji du drapeau
  is_active   boolean not null default true,
  sort_order  int  not null default 0,
  created_at  timestamptz not null default now()
);

-- Cours : un cours = une langue + un niveau CECRL
create table public.courses (
  id          uuid primary key default gen_random_uuid(),
  language_id uuid not null references public.languages(id) on delete cascade,
  code        text not null unique,             -- ex. 'en-a1-basics'
  title       text not null,
  description text not null default '',
  cefr_level  public.cefr_level not null,
  is_published boolean not null default false,  -- publié = visible des apprenants
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- Modules : regroupement thématique de leçons dans un cours
create table public.modules (
  id          uuid primary key default gen_random_uuid(),
  course_id   uuid not null references public.courses(id) on delete cascade,
  code        text not null unique,
  title       text not null,
  description text not null default '',
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

-- Leçons : objectif, explication, vocabulaire, exemples
create table public.lessons (
  id               uuid primary key default gen_random_uuid(),
  module_id        uuid not null references public.modules(id) on delete cascade,
  code             text not null unique,
  title            text not null,
  objective        text not null,               -- objectif pédagogique affiché à l'apprenant
  explanation      text not null default '',    -- explication de la règle (mini-cours)
  vocab            jsonb not null default '[]', -- [{term, translation, phonetic, example, example_tr}]
  examples         jsonb not null default '[]', -- [{sentence, translation}]
  estimated_minutes int not null default 10 check (estimated_minutes between 1 and 120),
  is_published     boolean not null default false,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now()
);

-- Exercices d'une leçon. Le champ `prompt` est PUBLIC (énoncé uniquement).
-- Les réponses correctes ne sont JAMAIS ici : elles vivent dans exercise_answer_keys.
create table public.exercises (
  id         uuid primary key default gen_random_uuid(),
  lesson_id  uuid not null references public.lessons(id) on delete cascade,
  type       public.exercise_type not null,
  position   int not null default 1,
  prompt     jsonb not null default '{}',       -- énoncé public, structure selon le type
  points     int not null default 10 check (points > 0),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  unique (lesson_id, position)
);

-- ⚠️ TABLE SENSIBLE : clés de correction. Aucune policy SELECT n'est créée (002) :
-- illisible depuis le frontend. La correction se fait serveur (003, submit_exercise).
create table public.exercise_answer_keys (
  exercise_id uuid primary key references public.exercises(id) on delete cascade,
  correct     jsonb not null,                   -- structure selon le type
  accepted    jsonb not null default '[]',      -- réponses alternatives acceptées
  explanation text not null default ''          -- explication pédagogique affichée après correction
);

-- ============================================================
-- 3. UTILISATEURS ET PRÉFÉRENCES
-- ============================================================

-- Profil applicatif lié à auth.users (créé par trigger handle_new_user)
create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              text not null,
  first_name         text not null default '',
  last_name          text not null default '',
  avatar_url         text,
  is_admin           boolean not null default false,  -- ⚠️ modification interdite au client (002)
  interface_lang     text not null default 'fr' check (interface_lang in ('en','fr','es','de')),
  target_lang        text,                            -- code langue étudiée (en/fr/es/de)
  cefr_level         public.cefr_level,
  daily_goal_minutes int not null default 15 check (daily_goal_minutes between 5 and 240),
  xp_total           int not null default 0 check (xp_total >= 0),
  level              int not null default 1 check (level >= 1),
  onboarded_at       timestamptz,                     -- null = onboarding non terminé
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Préférences utilisateur (thème, notifications, partage classement)
create table public.user_settings (
  user_id          uuid primary key references public.profiles(id) on delete cascade,
  theme            text not null default 'system' check (theme in ('light','dark','system')),
  notif_daily      boolean not null default true,   -- rappel quotidien (architecture, envoi futur)
  notif_streak     boolean not null default true,   -- alerte de rupture de série
  share_leaderboard boolean not null default true,  -- apparaitre dans le classement
  updated_at       timestamptz not null default now()
);

-- Inscriptions : la langue + le niveau + l'objectif choisi à l'onboarding
create table public.enrollments (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  language_id   uuid not null references public.languages(id) on delete cascade,
  cefr_level    public.cefr_level not null default 'A1',
  objective     text not null default '',          -- ex. 'voyage', 'travail', 'examens'
  daily_minutes int not null default 15 check (daily_minutes between 5 and 240),
  created_at    timestamptz not null default now(),
  unique (user_id, language_id)
);

-- ============================================================
-- 4. PROGRESSION ET GAMIFICATION
-- ============================================================

-- Progression par leçon (une ligne max par utilisateur et leçon)
create table public.lesson_progress (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  lesson_id    uuid not null references public.lessons(id) on delete cascade,
  status       public.progress_status not null default 'in_progress',
  score_pct    int not null default 0 check (score_pct between 0 and 100),
  completed_at timestamptz,
  updated_at   timestamptz not null default now(),
  unique (user_id, lesson_id)
);

-- Historique de chaque tentative d'exercice (données privées de l'apprenant)
create table public.exercise_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  exercise_id uuid not null references public.exercises(id) on delete cascade,
  answer      jsonb not null default '{}',      -- réponse brute soumise (audit)
  is_correct  boolean not null,
  score_ratio numeric(4,3) not null default 0 check (score_ratio between 0 and 1),
  created_at  timestamptz not null default now()
);

-- Journal d'attribution d'XP (source de vérité du total, inséré SERVEUR uniquement)
create table public.xp_events (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  source     public.xp_source not null,
  ref        text not null default '',          -- identifiant de référence (leçon, jeu, mission…)
  xp         int not null check (xp > 0 and xp <= 1000),
  meta       jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Série de jours consécutifs (calculée serveur)
create table public.daily_streaks (
  user_id          uuid primary key references public.profiles(id) on delete cascade,
  current_streak   int not null default 0 check (current_streak >= 0),
  best_streak      int not null default 0 check (best_streak >= 0),
  last_active_date date
);

-- Catalogue des badges
create table public.achievements (
  code        text primary key,
  name        text not null,
  description text not null,
  icon        text not null default '🏆',        -- emoji affiché
  xp_reward   int not null default 0 check (xp_reward >= 0),
  condition   jsonb not null default '{}',       -- méta descriptif de la condition
  sort_order  int not null default 0
);

-- Badges obtenus
create table public.user_achievements (
  user_id       uuid not null references public.profiles(id) on delete cascade,
  achievement_code text not null references public.achievements(code) on delete cascade,
  granted_at    timestamptz not null default now(),
  primary key (user_id, achievement_code)
);

-- Missions quotidiennes générées serveur (3 par jour et utilisateur)
create table public.daily_missions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  mission_date  date not null,
  template_code text not null,                  -- ex. 'answer_10', 'complete_lesson', 'play_game'
  target        int not null check (target > 0),
  progress      int not null default 0 check (progress >= 0),
  claimed       boolean not null default false, -- récompense réclamée
  xp_reward     int not null default 50 check (xp_reward >= 0),
  created_at    timestamptz not null default now(),
  unique (user_id, mission_date, template_code)
);

-- ============================================================
-- 5. PROFESSEUR IA
-- ============================================================

-- Conversations avec le professeur IA
create table public.ai_conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  language_id uuid references public.languages(id) on delete set null,
  mode        public.ai_mode not null default 'tutor',
  title       text not null default 'Conversation',
  scenario    text,                              -- pour le mode 'situation' (ex. 'restaurant')
  created_at  timestamptz not null default now()
);

-- Messages (persistés pour suivi des erreurs récurrentes et quotas)
create table public.ai_messages (
  id             uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role           text not null check (role in ('user', 'tutor', 'system')),
  content        text not null,
  created_at     timestamptz not null default now()
);

-- ============================================================
-- 6. PARAMÉTRAGE ADMINISTRATION
-- ============================================================

-- Paramètres globaux (barème XP, quotas IA, modèle IA) — modifiables par admin RPC
create table public.admin_settings (
  key         text primary key,
  value       jsonb not null,
  description text not null default '',
  updated_by  uuid references public.profiles(id) on delete set null,
  updated_at  timestamptz not null default now()
);

-- ============================================================
-- 7. INDEX DE PERFORMANCE
-- ============================================================
create index idx_courses_language      on public.courses(language_id) where is_published;
create index idx_modules_course        on public.modules(course_id);
create index idx_lessons_module        on public.lessons(module_id) where is_published;
create index idx_exercises_lesson      on public.exercises(lesson_id) where is_published;
create index idx_progress_user         on public.lesson_progress(user_id, status);
create index idx_progress_user_lesson  on public.lesson_progress(user_id, lesson_id);
create index idx_attempts_user_date    on public.exercise_attempts(user_id, created_at desc);
create index idx_attempts_exercise     on public.exercise_attempts(exercise_id);
create index idx_xp_user_date          on public.xp_events(user_id, created_at desc);
create index idx_missions_user_date    on public.daily_missions(user_id, mission_date);
create index idx_conv_user             on public.ai_conversations(user_id, created_at desc);
create index idx_msg_conv              on public.ai_messages(conversation_id, created_at);
create index idx_enroll_user           on public.enrollments(user_id);

-- ============================================================
-- 8. TRIGGERS DE BASE
-- ============================================================

-- updated_at automatique sur profiles et user_settings
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_profiles_updated    before update on public.profiles      for each row execute function public.set_updated_at();
create trigger trg_settings_updated    before update on public.user_settings for each row execute function public.set_updated_at();
create trigger trg_progress_updated    before update on public.lesson_progress for each row execute function public.set_updated_at();

-- Création automatique du profil + réglages à l'inscription (SECURITY DEFINER)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, first_name)
  values (new.id, coalesce(new.email, ''), coalesce(new.raw_user_meta_data->>'first_name', ''))
  on conflict (id) do nothing;

  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  insert into public.daily_streaks (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Recalcul du niveau + streak + missions + badges à chaque événement d'XP.
-- ⚠️ CETTE LOGIQUE S'EXÉCUTE UNIQUEMENT EN SERVEUR : aucune insertion directe
-- d'xp_events n'est possible pour un client (002 bloque INSERT/UPDATE/DELETE).
create or replace function public.on_xp_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Mise à jour atomique : le niveau est recalculé sur le NOUVEAU total
  -- (dans SET, `xp_total` désigne encore l'ancienne valeur).
  update public.profiles
     set xp_total = xp_total + new.xp,
         level    = public.level_for_xp(xp_total + new.xp)
   where id = new.user_id;

  perform public.update_streak(new.user_id);
  perform public.check_achievements(new.user_id);
  return new;
end;
$$;
-- NB : le trigger trg_xp_event qui exécute cette fonction est créé en fin de
-- 003_functions.sql, après que update_streak() et check_achievements() existent.

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 2/10 — 002_rls.sql
-- SÉCURITÉ — RLS + policies + privilèges anon/authenticated : chaque utilisateur ne voit que ses données ; réponses et XP inaccessibles côté client.
-- ██████████████████████████████████████████████████████████████████████████

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

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 3/10 — 003_functions.sql
-- LOGIQUE SERVEUR — fonctions SECURITY DEFINER : XP, correction, tâches quotidiennes, stats, administration. Le client ne peut jamais s’auto-attribuer d’XP.
-- ██████████████████████████████████████████████████████████████████████████

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

  select * into v_ok, v_ratio, v_expected
    from public.evaluate_answer(v_ex.type, v_key.correct, v_key.accepted, p_answer);

  insert into public.exercise_attempts (user_id, exercise_id, answer, is_correct, score_ratio)
  values (auth.uid(), p_exercise, coalesce(p_answer, '{}'::jsonb), v_ok, v_ratio);

  v_xp := 0;
  if v_ok then
    v_xp := public.award_xp(auth.uid(), 'exercise', p_exercise::text,
                            (public.get_setting('xp_correct_answer', '10'))::text::int,
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

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 4/10 — 004_seed.sql
-- DONNÉES — bibliothèque de lancement : 4 langues, 8 cours, 32 leçons, 192 exercices. Idempotent (upsert par code unique) — ré-exécutable sans dupliquer.
-- ██████████████████████████████████████████████████████████████████████████

-- ============================================================
-- MAJOOP — Migration 004 : Données initiales et bibliothèque de lancement
-- Généré automatiquement par scripts/majoop_parts/gen_seed.py — NE PAS ÉDITER À LA MAIN
-- Idempotent : ré-exécutable sans dupliquer (upsert par code unique).
-- ============================================================

-- ---------- Paramètres d'administration ----------
insert into public.admin_settings (key, value, description) values ('xp_correct_answer', '10'::jsonb, 'XP pour une bonne réponse') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('xp_lesson_complete', '30'::jsonb, 'XP pour une leçon terminée') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('xp_daily_mission', '50'::jsonb, 'XP par mission quotidienne réclamée') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('xp_streak_bonus', '100'::jsonb, 'XP de bonus de série (tous les 7 jours)') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('daily_xp_cap_exercise', '600'::jsonb, 'Plafond d''XP journalier via exercices') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('daily_xp_cap_game', '150'::jsonb, 'Plafond d''XP journalier via jeux') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('leaderboard_enabled', 'true'::jsonb, 'Classement activé') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_daily_quota', '20'::jsonb, 'Messages IA par utilisateur et par jour') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_min_interval_sec', '3'::jsonb, 'Intervalle minimal entre 2 messages IA (anti-spam)') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_provider', '"auto"'::jsonb, 'Fournisseur IA : auto (repli gemini→openrouter→mistral) | gemini | openrouter | mistral') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_model', '"gemini-2.5-flash"'::jsonb, 'Modèle Gemini utilisé par l''Edge Function') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_model_openrouter', '"meta-llama/llama-3.3-70b-instruct:free"'::jsonb, 'Modèle OpenRouter (les ID :free changent souvent — voir openrouter.ai/models?max_price=0)') on conflict (key) do update set value = excluded.value, description = excluded.description;
insert into public.admin_settings (key, value, description) values ('ai_model_mistral', '"mistral-small-latest"'::jsonb, 'Modèle Mistral (alias stable)') on conflict (key) do update set value = excluded.value, description = excluded.description;

-- ---------- Catalogue des badges ----------
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('first_lesson', 'Première leçon', 'Termine ta première leçon', '🎯', 20, 1) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('exercises_50', 'Endurance', 'Réussis 50 exercices', '💪', 50, 2) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('streak_7', 'Semaine parfaite', '7 jours de série consécutifs', '🔥', 50, 3) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('game_master', 'Champion des jeux', 'Joue 10 parties de jeux éducatifs', '🎮', 50, 4) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('xp_500', '500 XP', 'Atteins 500 points d''expérience', '⭐', 50, 5) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;
insert into public.achievements (code, name, description, icon, xp_reward, sort_order) values ('xp_2000', 'Maître MAJOOP', 'Atteins 2000 points d''expérience', '🚀', 100, 6) on conflict (code) do update set name = excluded.name, description = excluded.description, icon = excluded.icon, xp_reward = excluded.xp_reward;

-- ---------- Langues (v1 : en, fr, es, de) ----------
insert into public.languages (code, name, native_name, flag, is_active, sort_order) values ('en', 'Anglais', 'English', '🇬🇧', true, 0) on conflict (code) do update set name = excluded.name, native_name = excluded.native_name, flag = excluded.flag, is_active = true;
insert into public.languages (code, name, native_name, flag, is_active, sort_order) values ('fr', 'Français', 'Français', '🇫🇷', true, 1) on conflict (code) do update set name = excluded.name, native_name = excluded.native_name, flag = excluded.flag, is_active = true;
insert into public.languages (code, name, native_name, flag, is_active, sort_order) values ('es', 'Espagnol', 'Español', '🇪🇸', true, 2) on conflict (code) do update set name = excluded.name, native_name = excluded.native_name, flag = excluded.flag, is_active = true;
insert into public.languages (code, name, native_name, flag, is_active, sort_order) values ('de', 'Allemand', 'Deutsch', '🇩🇪', true, 3) on conflict (code) do update set name = excluded.name, native_name = excluded.native_name, flag = excluded.flag, is_active = true;

-- ---------- Bibliothèque de lancement ----------
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'en-a1', 'Anglais A1 — Premiers pas', 'Les bases indispensables : se saluer, se présenter, compter, parler de son quotidien.', 'A1'::public.cefr_level, true, 1 from public.languages where code = 'en' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'en-a1-m1', 'Premiers contacts', '', 1 from public.courses where code = 'en-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m1-l1', 'Saluer', 'Saluer quelqu''un à différents moments de la journée et dire au revoir.', '**Hello / Hi** s''utilisent à tout moment. **Good morning** (le matin), **good afternoon** (l''après-midi), **good evening** (le soir) sont plus formels.

Pour demander des nouvelles : **How are you?** — réponse : **I''m fine, thank you!** ou **I''m good!**

Pour dire au revoir : **Goodbye** (formel), **Bye** (familier), **Good night** (avant de dormir).', '[{"term":"hello","translation":"bonjour","phonetic":"/həˈloʊ/","example":"Hello, Tom!","example_tr":"Bonjour, Tom !"},{"term":"hi","translation":"salut","phonetic":"/haɪ/","example":"Hi, how are you?","example_tr":"Salut, ça va ?"},{"term":"good morning","translation":"bonjour (le matin)","phonetic":"/ɡʊd ˈmɔːrnɪŋ/","example":"Good morning, Mrs. Smith.","example_tr":"Bonjour, Mme Smith."},{"term":"good evening","translation":"bonsoir","phonetic":"/ɡʊd ˈiːvnɪŋ/","example":"Good evening, everyone.","example_tr":"Bonsoir à tous."},{"term":"goodbye","translation":"au revoir","phonetic":"/ɡʊdˈbaɪ/","example":"Goodbye, see you soon!","example_tr":"Au revoir, à bientôt !"},{"term":"good night","translation":"bonne nuit","phonetic":"/ɡʊd naɪt/","example":"Good night, sleep well.","example_tr":"Bonne nuit, dors bien."},{"term":"how are you?","translation":"comment vas-tu ?","phonetic":"/haʊ ɑːr juː/","example":"Hi Lisa, how are you?","example_tr":"Salut Lisa, comment vas-tu ?"},{"term":"I''m fine","translation":"je vais bien","phonetic":"/aɪm faɪn/","example":"I''m fine, thank you.","example_tr":"Je vais bien, merci."}]'::jsonb, '[{"sentence":"Hello! How are you today?","translation":"Bonjour ! Comment vas-tu aujourd''hui ?"},{"sentence":"Good morning, teacher. I''m fine, thanks.","translation":"Bonjour, professeur. Je vais bien, merci."},{"sentence":"Good night, Mum!","translation":"Bonne nuit, maman !"}]'::jsonb, 10, true, 1 from public.modules where code = 'en-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Tu croises votre professeur à 8 h du matin. Que dis-tu ?","options":["Good night!","Good morning!","Good evening!"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Good morning » s''utilise du lever du jour jusqu''à midi. « Good night » se dit uniquement avant de dormir.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"Salut, comment vas-tu ?","hint":"Deux mots pour « salut »…"}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["hi, how are you","hi, how are you doing"]}'::jsonb, '[]'::jsonb, '« Hi » est la forme familière de « hello » ; on enchaîne avec « how are you? ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ are you? — I''m fine, ___ you.","translation":"Comment vas-tu ? — Je vais bien, merci."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["how","thank"]}'::jsonb, '[]'::jsonb, '« How are you? » demande des nouvelles ; la réponse polie est « I''m fine, thank you ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression anglaise à sa traduction.","pairs":[{"left":"good morning","right":"bonjour (le matin)"},{"left":"good night","right":"bonne nuit"},{"left":"goodbye","right":"au revoir"},{"left":"hi","right":"salut"}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Chaque salutation correspond à un moment précis de la journée ou à un registre.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets les mots en ordre pour former une phrase correcte.","words":["are","you","How","?"],"translation":"Comment vas-tu ?"}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[2,0,1,3]}'::jsonb, '[]'::jsonb, 'En anglais, la question avec « how » s''écrit : How + are + you ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Good evening, everyone.","question":"Écoute puis choisis la traduction.","options":["Bonsoir à tous.","Bonne nuit à tous.","Au revoir à tous."]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Good evening » = bonsoir. « Good night » = bonne nuit (avant de dormir).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m1-l2', 'Se présenter', 'Donner son nom, son pays et poser des questions simples à quelqu''un.', 'Pour dire ton nom : **My name is Anna.** ou **I''m Anna.**

Pour demander celui de l''autre : **What''s your name?**

Origine : **I''m from France.** — **Where are you from?**

Âge : **I''m 20 years old.** (on utilise BE, pas HAVE).

Métier : **I''m a student.** / **I work in a hospital.**', '[{"term":"my name is…","translation":"je m''appelle…","phonetic":"/maɪ neɪm ɪz/","example":"My name is Pedro.","example_tr":"Je m''appelle Pedro."},{"term":"nice to meet you","translation":"enchanté","phonetic":"/naɪs tə miːt juː/","example":"Nice to meet you, Anna.","example_tr":"Enchanté, Anna."},{"term":"I''m from…","translation":"je viens de…","phonetic":"/aɪm frɒm/","example":"I''m from Spain.","example_tr":"Je viens d''Espagne."},{"term":"where are you from?","translation":"d''où viens-tu ?","phonetic":"/weər ɑːr juː frɒm/","example":"Where are you from? — Brazil.","example_tr":"D''où viens-tu ? — Du Brésil."},{"term":"student","translation":"étudiant(e)","phonetic":"/ˈstjuːdnt/","example":"I''m a student.","example_tr":"Je suis étudiant."},{"term":"teacher","translation":"professeur","phonetic":"/ˈtiːtʃər/","example":"She is a teacher.","example_tr":"Elle est professeure."},{"term":"years old","translation":"… ans (âge)","phonetic":"/jɪəz oʊld/","example":"He is ten years old.","example_tr":"Il a dix ans."},{"term":"please / thank you","translation":"s''il te plaît / merci","phonetic":"/pliːz θæŋk juː/","example":"Thank you very much!","example_tr":"Merci beaucoup !"}]'::jsonb, '[{"sentence":"Hello, my name is Karl. I''m from Germany.","translation":"Bonjour, je m''appelle Karl. Je viens d''Allemagne."},{"sentence":"What''s your name? — I''m Sofia.","translation":"Comment tu t''appelles ? — Je suis Sofia."},{"sentence":"I''m 15 years old and I''m a student.","translation":"J''ai 15 ans et je suis étudiant."}]'::jsonb, 10, true, 2 from public.modules where code = 'en-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Quelle phrase est correcte pour donner ton âge ?","options":["I have 20 years.","I am 20 years old.","I make 20 years."]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'En anglais, l''âge s''exprime avec BE : « I am 20 years old ». Erreur classique des francophones : « I have ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"Je viens du Brésil."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["i''m from brazil","i am from brazil"]}'::jsonb, '[]'::jsonb, '« I''m from + pays ». L''apostrophe de I''m peut aussi s''écrire « I am ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ name is Lucia. Nice to ___ you.","translation":"Je m''appelle Lucia. Enchantée."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["my","meet"]}'::jsonb, '[]'::jsonb, '« My name is… » pour se présenter ; « nice to meet you » est la formule de politesse standard.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe les questions aux réponses.","pairs":[{"left":"What''s your name?","right":"I''m Marco."},{"left":"Where are you from?","right":"I''m from Italy."},{"left":"How old are you?","right":"I''m 18 years old."},{"left":"How are you?","right":"I''m fine, thanks."}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Chaque question sur l''identité appelle un type de réponse précis : nom, origine, âge, état.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets en ordre :","words":["from","I''m","Japan","."],"translation":"Je viens du Japon."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, 'Ordre : sujet (I''m) + from + pays.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Un nouveau camarade","passage":"Hi! My name is Tom and I am from Canada. I am a student and I am nineteen years old. My teacher is Mrs. Green. She is very nice.","questions":[{"q":"D''où vient Tom ?","options":["From the USA","From Canada","From Australia"]},{"q":"Quel âge a Tom ?","options":["Nine","Ninety","Nineteen"]},{"q":"Qui est Mrs. Green ?","options":["Sa mère","Son professeure","Sa sœur"]}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,2,1]}'::jsonb, '[]'::jsonb, 'Relis le passage : « I am from Canada », « nineteen years old », « My teacher is Mrs. Green ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'en-a1-m2', 'Le quotidien', '', 2 from public.courses where code = 'en-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m2-l1', 'Les nombres 1 à 20', 'Compter de 1 à 20 et donner un numéro de téléphone.', 'Les nombres : one (1), two (2), three (3), four (4), five (5), six (6), seven (7), eight (8), nine (9), ten (10), eleven (11), twelve (12), thirteen (13), fourteen (14), fifteen (15), sixteen (16), seventeen (17), eighteen (18), nineteen (19), twenty (20).

Attention aux pièges : **thirteen** (13) ≠ **thirty** (30) — l''accent tonique change ! Pour un numéro de téléphone, on énonce chaque chiffre : « zero » se dit aussi **oh**.', '[{"term":"one / two / three","translation":"un / deux / trois","phonetic":"/wʌn tuː θriː/","example":"I have three cats.","example_tr":"J''ai trois chats."},{"term":"four / five / six","translation":"quatre / cinq / six","phonetic":"/fɔːr faɪv sɪks/","example":"Five apples, please.","example_tr":"Cinq pommes, s''il vous plaît."},{"term":"seven / eight / nine","translation":"sept / huit / neuf","phonetic":"/ˈsevn eɪt naɪn/","example":"Nine students are here.","example_tr":"Neuf élèves sont là."},{"term":"ten / eleven / twelve","translation":"dix / onze / douze","phonetic":"/ten ɪˈlevn twelv/","example":"Twelve months in a year.","example_tr":"Douze mois dans une année."},{"term":"thirteen","translation":"treize","phonetic":"/θɜːrˈtiːn/","example":"She is thirteen.","example_tr":"Elle a treize ans."},{"term":"twenty","translation":"vingt","phonetic":"/ˈtwenti/","example":"Twenty euros, please.","example_tr":"Vingt euros, s''il vous plaît."},{"term":"how many?","translation":"combien ?","phonetic":"/haʊ ˈmeni/","example":"How many books do you have?","example_tr":"Combien de livres as-tu ?"},{"term":"phone number","translation":"numéro de téléphone","phonetic":"/foʊn ˈnʌmbər/","example":"What''s your phone number?","example_tr":"Quel est ton numéro de téléphone ?"}]'::jsonb, '[{"sentence":"I have two brothers and one sister.","translation":"J''ai deux frères et une sœur."},{"sentence":"How many days? — Seven!","translation":"Combien de jours ? — Sept !"},{"sentence":"My phone number is oh-seven-five-five…","translation":"Mon numéro est le 07 55…"}]'::jsonb, 10, true, 1 from public.modules where code = 'en-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Comment dit-on « 15 » ?","options":["Fifty","Fifteen","Fiveteen"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '15 = fifteen. Fifty = 50. Et il n''y a jamais de « fiveteen ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Écris le nombre en anglais (en toutes lettres) :","source":"13"}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["thirteen"]}'::jsonb, '[]'::jsonb, '13 = thirteen (accent sur three). 30 = thirty (accent sur thir-).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"How ___ students? — ___ , teacher.","translation":"Combien d''élèves ? — Douze, professeur."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["many","twelve"]}'::jsonb, '[]'::jsonb, '« How many » demande une quantité dénombrable.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque nombre écrit en lettres à son chiffre.","pairs":[{"left":"three","right":"3"},{"left":"eight","right":"8"},{"left":"eleven","right":"11"},{"left":"twenty","right":"20"}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Retiens les bases 1-12 par cœur : elles servent à construire tous les autres nombres.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["number","What''s","your","phone","?"],"translation":"Quel est ton numéro de téléphone ?"}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,2,0,3,4]}'::jsonb, '[]'::jsonb, 'What''s + your + phone number ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"I have seven apples and two bananas.","question":"Écoute puis réponds : combien de pommes ?","options":["Seven","Eleven","Three"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Seven apples » = sept pommes. Attention à ne pas confondre seven /ə/ et eleven.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m2-l2', 'Jours et heures', 'Dire les jours de la semaine, donner l''heure et parler de son agenda.', 'Jours : Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday (toujours avec MAJUSCULE en anglais).

L''heure : **What time is it?** — **It''s three o''clock.** (3 h 00) — **It''s half past three.** (3 h 30) — **It''s quarter past three.** (3 h 15) — **It''s quarter to four.** (3 h 45).

Moment de la journée : **in the morning / in the afternoon / at night** ; jours : **on Monday** ; heures précises : **at 5 o''clock**.', '[{"term":"Monday","translation":"lundi","phonetic":"/ˈmʌndeɪ/","example":"I work on Monday.","example_tr":"Je travaille le lundi."},{"term":"Wednesday","translation":"mercredi","phonetic":"/ˈwenzdeɪ/","example":"We meet on Wednesday.","example_tr":"Nous nous voyons mercredi."},{"term":"Saturday","translation":"samedi","phonetic":"/ˈsætərdeɪ/","example":"Saturday is my favorite day.","example_tr":"Samedi est mon jour préféré."},{"term":"What time is it?","translation":"quelle heure est-il ?","phonetic":"/wɒt taɪm ɪz ɪt/","example":"What time is it? — It''s five.","example_tr":"Quelle heure est-il ? — Cinq heures."},{"term":"half past","translation":"et demie","phonetic":"/hæf pæst/","example":"It''s half past two.","example_tr":"Il est deux heures et demie."},{"term":"quarter to","translation":"moins le quart","phonetic":"/ˈkwɔːrtər tuː/","example":"It''s quarter to nine.","example_tr":"Il est neuf heures moins le quart."},{"term":"today / tomorrow","translation":"aujourd''hui / demain","phonetic":"/təˈdeɪ təˈmɒroʊ/","example":"Tomorrow is Sunday.","example_tr":"Demain, c''est dimanche."},{"term":"o''clock","translation":"heures (pile)","phonetic":"/əˈklɒk/","example":"The class starts at six o''clock.","example_tr":"Le cours commence à six heures."}]'::jsonb, '[{"sentence":"It''s half past seven. I''m late!","translation":"Il est sept heures et demie. Je suis en retard !"},{"sentence":"On Wednesday, I play football at four o''clock.","translation":"Mercredi, je joue au football à quatre heures."},{"sentence":"What time is it? — It''s quarter past ten.","translation":"Quelle heure est-il ? — Dix heures et quart."}]'::jsonb, 10, true, 2 from public.modules where code = 'en-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"« It''s quarter to six » signifie :","options":["6 h 15","5 h 45","6 h 45"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Quarter to six » = un quart AVANT six heures = 5 h 45. « Quarter past six » = 6 h 15.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"Il est trois heures et demie."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["it''s half past three","it is half past three"]}'::jsonb, '[]'::jsonb, '« Half past + heure » = …h30.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"The class is ___ Monday ___ nine o''clock.","translation":"Le cours est lundi à neuf heures."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["on","at"]}'::jsonb, '[]'::jsonb, 'on + jour, at + heure : deux prépositions à ne pas confondre.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque jour anglais à sa traduction.","pairs":[{"left":"Monday","right":"lundi"},{"left":"Wednesday","right":"mercredi"},{"left":"Friday","right":"vendredi"},{"left":"Sunday","right":"dimanche"}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les jours viennent des planètes/astres, comme en français : Moon → Monday, Saturn → Saturday.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["time","What","it","is","?"],"translation":"Quelle heure est-il ?"}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,3,2,4]}'::jsonb, '[]'::jsonb, 'What time is it ? — ordre question : mot interrogatif + auxiliaire + sujet.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Mon emploi du temps","passage":"On Monday, I have English at nine o''clock. On Wednesday, I play tennis at half past four. On Saturday, I don''t work. I love Saturday!","questions":[{"q":"Quand Tom a-t-il son cours d''anglais ?","options":["Lundi 9 h","Mercredi 9 h","Samedi 9 h"]},{"q":"À quelle heure joue-t-il au tennis ?","options":["4 h 15","4 h 30","4 h 45"]},{"q":"Que fait-il samedi ?","options":["Il travaille","Il a anglais","Il ne travaille pas"]}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « at nine o''clock », « half past four », « I don''t work ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m2-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'en-a1-m3', 'Vivre ensemble', '', 3 from public.courses where code = 'en-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m3-l1', 'La nourriture', 'Commander un repas simplement et dire ce qu''on aime manger.', 'Aimer / ne pas aimer : **I like pizza.** — **I don''t like fish.** — Question : **Do you like coffee?**

Commander : **I''d like a coffee, please.** (= I would like, plus poli que « I want »). — **Can I have the menu, please?**

Articles : **a/an** (singulier indéfini) : **an apple**, **a banana**.', '[{"term":"bread","translation":"pain","phonetic":"/bred/","example":"I buy bread every day.","example_tr":"J''achète du pain chaque jour."},{"term":"cheese","translation":"fromage","phonetic":"/tʃiːz/","example":"French cheese is famous.","example_tr":"Le fromage français est célèbre."},{"term":"apple","translation":"pomme","phonetic":"/ˈæpl/","example":"An apple a day!","example_tr":"Une pomme par jour !"},{"term":"water","translation":"eau","phonetic":"/ˈwɔːtər/","example":"A glass of water, please.","example_tr":"Un verre d''eau, s''il vous plaît."},{"term":"breakfast","translation":"petit-déjeuner","phonetic":"/ˈbrekfəst/","example":"I have breakfast at seven.","example_tr":"Je prends mon petit-déjeuner à sept heures."},{"term":"I''d like…","translation":"je voudrais…","phonetic":"/aɪd laɪk/","example":"I''d like a tea, please.","example_tr":"Je voudrais un thé, s''il vous plaît."},{"term":"the bill","translation":"l''addition","phonetic":"/ðə bɪl/","example":"The bill, please!","example_tr":"L''addition, s''il vous plaît !"},{"term":"delicious","translation":"délicieux","phonetic":"/dɪˈlɪʃəs/","example":"This soup is delicious!","example_tr":"Cette soupe est délicieuse !"}]'::jsonb, '[{"sentence":"I like coffee but I don''t like tea.","translation":"J''aime le café mais je n''aime pas le thé."},{"sentence":"I''d like a cheese sandwich, please.","translation":"Je voudrais un sandwich au fromage, s''il vous plaît."},{"sentence":"Do you like apples? — Yes, I do!","translation":"Tu aimes les pommes ? — Oui !"}]'::jsonb, 10, true, 1 from public.modules where code = 'en-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"La formule la plus polie pour commander :","options":["I want a coffee.","Give me a coffee.","I''d like a coffee, please."]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":2}'::jsonb, '[]'::jsonb, '« I''d like… » (= I would like) + please est la formule standard et polie.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"J''aime le fromage."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["i like cheese","i do like cheese"]}'::jsonb, '[]'::jsonb, '« I like + nourriture » sans article : I like cheese (et non « I like the cheese »).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ you like fish? — No, I ___ .","translation":"Aimes-tu le poisson ? — Non."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["do","don''t"]}'::jsonb, '[]'::jsonb, 'Question : Do you like…? Réponse négative : No, I don''t.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque mot à sa traduction.","pairs":[{"left":"bread","right":"pain"},{"left":"water","right":"eau"},{"left":"breakfast","right":"petit-déjeuner"},{"left":"the bill","right":"l''addition"}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Retiens ces quatre mots : ils sont parmi les plus fréquents au restaurant.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la commande en ordre :","words":["a","I''d","please","like","tea",","],"translation":"Je voudrais un thé, s''il vous plaît."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,4,5,3,2]}'::jsonb, '[]'::jsonb, 'Structure : I''d like + a + nom + , + please.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"I''d like a cheese sandwich and a glass of water, please.","question":"Écoute la commande : que veut la personne ?","options":["Un sandwich au fromage et de l''eau","Un thé et du pain","Une pomme et du fromage"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« A cheese sandwich and a glass of water » — écoute les mots-clés sandwich et water.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a1-m3-l2', 'La famille', 'Présenter les membres de sa famille avec les possessifs my/your/his/her.', 'Membres : **father** (père), **mother** (mère), **brother** (frère), **sister** (sœur), **son** (fils), **daughter** (fille), **wife** (épouse), **husband** (époux).

Possessifs : **my** (mon/ma), **your** (ton/ta), **his** (son/sa — à lui), **her** (son/sa — à elle). ⚠️ En anglais, « son » et « sa » dépendent du PROPRIÉTAIRE, pas de l''objet : **his sister** = sa sœur (à lui), **her brother** = son frère (à elle).', '[{"term":"father / mother","translation":"père / mère","phonetic":"/ˈfɑːðər ˈmʌðər/","example":"My father is tall.","example_tr":"Mon père est grand."},{"term":"brother / sister","translation":"frère / sœur","phonetic":"/ˈbrʌðər ˈsɪstər/","example":"I have two sisters.","example_tr":"J''ai deux sœurs."},{"term":"son / daughter","translation":"fils / fille (enfant)","phonetic":"/sʌn ˈdɔːtər/","example":"Their daughter is six.","example_tr":"Leur fille a six ans."},{"term":"his","translation":"son, sa (à lui)","phonetic":"/hɪz/","example":"This is his car.","example_tr":"C''est sa voiture (à lui)."},{"term":"her","translation":"son, sa (à elle)","phonetic":"/hɜːr/","example":"Her name is Ana.","example_tr":"Elle s''appelle Ana (son nom)."},{"term":"married","translation":"marié(e)","phonetic":"/ˈmærid/","example":"They are married.","example_tr":"Ils sont mariés."},{"term":"children","translation":"enfants","phonetic":"/ˈtʃɪldrən/","example":"We have three children.","example_tr":"Nous avons trois enfants."},{"term":"family","translation":"famille","phonetic":"/ˈfæməli/","example":"I love my family.","example_tr":"J''aime ma famille."}]'::jsonb, '[{"sentence":"This is my mother. Her name is Carla.","translation":"Voici ma mère. Elle s''appelle Carla."},{"sentence":"My brother is a teacher. His students are nice.","translation":"Mon frère est professeur. Ses élèves sont gentils."},{"sentence":"How many children do you have?","translation":"Combien d''enfants as-tu ?"}]'::jsonb, 10, true, 2 from public.modules where code = 'en-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Maria a un frère. Comment dire « son frère » (le frère de Maria) ?","options":["his brother","her brother","its brother"]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'Le possessif dépend du propriétaire : Maria = elle → her brother.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"Ma sœur a dix ans."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["my sister is ten years old","my sister is ten","my sister has ten years"]}'::jsonb, '[]'::jsonb, 'On dit « My sister IS ten years old » — avec BE, pas HAVE.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"This is my father. ___ name is Paul. I have two ___.","translation":"Voici mon père. Il s''appelle Paul. J''ai deux sœurs."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["his","sisters"]}'::jsonb, '[]'::jsonb, 'his + nom (le père = à lui) ; sisters au pluriel pour « deux sœurs ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque membre de la famille.","pairs":[{"left":"father","right":"père"},{"left":"daughter","right":"fille (enfant)"},{"left":"wife","right":"épouse"},{"left":"children","right":"enfants"}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Attention : « daughter » = fille-enfant, différent de « girl » (petite fille en général).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["brother","This","my","is","."],"translation":"Voici mon frère."}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,2,0,3,4]}'::jsonb, '[]'::jsonb, 'Structure présentation : This is + my + famille.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"La famille de Leo","passage":"This is Leo. His father is a doctor and his mother is a nurse. He has one sister, Mia. She is a student. Leo''s grandparents live in Rome.","questions":[{"q":"Que fait le père de Leo ?","options":["Infirmier","Médecin","Professeur"]},{"q":"Comment s''appelle la sœur de Leo ?","options":["Mia","Rome","Nina"]},{"q":"Où vivent les grands-parents ?","options":["À Rome","À Paris","À Madrid"]}]}'::jsonb, 10, true from public.lessons where code = 'en-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,0,0]}'::jsonb, '[]'::jsonb, 'Relis : « His father is a doctor », « one sister, Mia », « live in Rome ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a1-m3-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'en-a2', 'Anglais A2 — Conversations du quotidien', 'Parler du passé, faire des projets et tenir une conversation simple.', 'A2'::public.cefr_level, true, 2 from public.languages where code = 'en' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'en-a2-m1', 'Raconter et prévoir', '', 1 from public.courses where code = 'en-a2' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a2-m1-l1', 'Le passé simple (past simple)', 'Raconter ce que tu as fait hier ou la semaine dernière.', 'Le past simple des verbes réguliers prend **-ed** : **work → worked**, **play → played**, **visit → visited**.

Verbes irréguliers à connaître : **go → went**, **have → had**, **see → saw**, **eat → ate**, **buy → bought**, **be → was/were**.

Négation et question avec **did** : **I didn''t go.** — **Did you go?** (le verbe redevient à la base).

Marqueurs de temps : **yesterday**, **last week**, **two days ago**.', '[{"term":"yesterday","translation":"hier","phonetic":"/ˈjestərdeɪ/","example":"I worked yesterday.","example_tr":"J''ai travaillé hier."},{"term":"last week","translation":"la semaine dernière","phonetic":"/læst wiːk/","example":"We went to the beach last week.","example_tr":"Nous sommes allés à la plage la semaine dernière."},{"term":"went","translation":"allé(e) (go → went)","phonetic":"/went/","example":"She went home early.","example_tr":"Elle est rentrée tôt."},{"term":"had","translation":"eu / a eu (have → had)","phonetic":"/hæd/","example":"We had a great time.","example_tr":"Nous avons passé un bon moment."},{"term":"saw","translation":"vu (see → saw)","phonetic":"/sɔː/","example":"I saw a good film.","example_tr":"J''ai vu un bon film."},{"term":"bought","translation":"acheté (buy → bought)","phonetic":"/bɔːt/","example":"He bought new shoes.","example_tr":"Il a acheté de nouvelles chaussures."},{"term":"didn''t","translation":"n''ai pas / n''a pas","phonetic":"/ˈdɪdnt/","example":"I didn''t see him.","example_tr":"Je ne l''ai pas vu."},{"term":"ago","translation":"il y a (temps)","phonetic":"/əˈɡoʊ/","example":"Two years ago, we moved.","example_tr":"Il y a deux ans, nous avons déménagé."}]'::jsonb, '[{"sentence":"Yesterday, I visited my grandmother.","translation":"Hier, j''ai rendu visite à ma grand-mère."},{"sentence":"Did you like the film? — Yes, I did!","translation":"Tu as aimé le film ? — Oui !"},{"sentence":"We didn''t go out because it rained.","translation":"Nous ne sommes pas sortis parce qu''il a plu."}]'::jsonb, 10, true, 1 from public.modules where code = 'en-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Yesterday, I ___ to the cinema. »","options":["goed","went","gone"]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'go est irrégulier : go → went. « goed » n''existe pas ; « gone » sert au present perfect.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"J''ai acheté du pain hier."}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["i bought bread yesterday","yesterday i bought bread"]}'::jsonb, '[]'::jsonb, 'buy → bought (irrégulier) + yesterday en fin ou début de phrase.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ you ___ the match last night? — No, I ___ .","translation":"As-tu vu le match hier soir ? — Non."}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["did","see","didn''t"]}'::jsonb, '[]'::jsonb, 'Question au passé : Did + sujet + verbe à la base ? Réponse : No, I didn''t.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque verbe à son passé.","pairs":[{"left":"go","right":"went"},{"left":"have","right":"had"},{"left":"see","right":"saw"},{"left":"eat","right":"ate"}]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces quatre verbes irréguliers sont parmi les plus fréquents : à mémoriser absolument.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["film","We","last","a","week","saw","."],"translation":"Nous avons vu un film la semaine dernière."}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,5,0,2,4,6]}'::jsonb, '[]'::jsonb, 'Ordre : sujet + verbe + complément + marqueur de temps.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Le week-end d''Emma","passage":"Last Saturday, Emma went to the market with her father. They bought fruit and cheese. In the afternoon, she played tennis with her friends. They had a lot of fun, but she didn''t cook dinner — her mother did!","questions":[{"q":"Où est allée Emma samedi ?","options":["Au marché","Au cinéma","À l''école"]},{"q":"Qu''ont-ils acheté ?","options":["Des chaussures","Des fruits et du fromage","Des livres"]},{"q":"Qui a préparé le dîner ?","options":["Emma","Ses amis","Sa mère"]}]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « went to the market », « bought fruit and cheese », « her mother did! ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'en-a2-m1-l2', 'Parler de ses projets', 'Exprimer un projet ou une intention avec be going to et want to.', 'Pour parler d''un projet futur : **be going to + verbe** — **I''m going to travel this summer.** — **She''s going to study medicine.**

Question : **Are you going to watch the match?** — Négation : **I''m not going to work on Sunday.**

Envie : **I want to learn English.** — **He wants to buy a car.** (want + to + verbe).

Invitation : **Would you like to come?** — réponse : **I''d love to!**', '[{"term":"I''m going to…","translation":"je vais… / j''ai l''intention de…","phonetic":"/aɪm ˈɡoʊɪŋ tuː/","example":"I''m going to visit Peru.","example_tr":"Je vais visiter le Pérou."},{"term":"next month","translation":"le mois prochain","phonetic":"/nekst mʌnθ/","example":"We start next month.","example_tr":"Nous commençons le mois prochain."},{"term":"I want to…","translation":"je veux…","phonetic":"/aɪ wɒnt tuː/","example":"I want to speak better.","example_tr":"Je veux mieux parler."},{"term":"plan","translation":"projet / prévoir","phonetic":"/plæn/","example":"My plan is simple.","example_tr":"Mon projet est simple."},{"term":"Would you like to…?","translation":"aimerais-tu… ?","phonetic":"/wʊd ju laɪk tuː/","example":"Would you like to join us?","example_tr":"Veux-tu te joindre à nous ?"},{"term":"I''d love to!","translation":"avec plaisir !","phonetic":"/aɪd lʌv tuː/","example":"I''d love to come!","example_tr":"J''adorerais venir !"},{"term":"maybe","translation":"peut-être","phonetic":"/ˈmeɪbi/","example":"Maybe next year.","example_tr":"Peut-être l''année prochaine."},{"term":"because","translation":"parce que","phonetic":"/bɪˈkɔːz/","example":"I stay home because I''m tired.","example_tr":"Je reste à la maison parce que je suis fatigué."}]'::jsonb, '[{"sentence":"I''m going to learn Spanish next month.","translation":"Je vais apprendre l''espagnol le mois prochain."},{"sentence":"Are you going to watch the game tonight?","translation":"Tu vas regarder le match ce soir ?"},{"sentence":"She wants to work in Canada.","translation":"Elle veut travailler au Canada."}]'::jsonb, 10, true, 2 from public.modules where code = 'en-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « She ___ going to study tonight. »","options":["is","are","am"]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'be going to s''accorde : I am, he/she/it IS going to, we/you/they are.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en anglais :","source":"Je vais visiter l''Italie cet été."}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["i''m going to visit italy this summer","i am going to visit italy this summer"]}'::jsonb, '[]'::jsonb, 'be going to + verbe à la base : going to visit.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"I want ___ learn English ___ it''s useful.","translation":"Je veux apprendre l''anglais parce que c''est utile."}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["to","because"]}'::jsonb, '[]'::jsonb, 'want TO + verbe ; because introduit la raison.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression à sa traduction.","pairs":[{"left":"next month","right":"le mois prochain"},{"left":"I''d love to!","right":"avec plaisir !"},{"left":"maybe","right":"peut-être"},{"left":"because","right":"parce que"}]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces petits mots rendent tes conversations naturelles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["going","Are","to","you","travel","?"],"translation":"Vas-tu voyager ?"}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,0,2,4,5]}'::jsonb, '[]'::jsonb, 'Question : Are + you + going to + verbe ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"I''m going to visit my grandmother next month.","question":"Écoute : que va faire la personne ?","options":["Voyager en Italie","Rendre visite à sa grand-mère","Acheter une voiture"]}'::jsonb, 10, true from public.lessons where code = 'en-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Visit my grandmother » = rendre visite à sa grand-mère.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'en-a2-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'fr-a1', 'Français A1 — Premiers pas', 'Les bases : saluer, se présenter, compter, le quotidien. (Explications en français, glosses en anglais.)', 'A1'::public.cefr_level, true, 1 from public.languages where code = 'fr' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'fr-a1-m1', 'Premiers contacts', '', 1 from public.courses where code = 'fr-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m1-l1', 'Saluer', 'Saluer à différents moments de la journée et prendre des nouvelles.', 'Le matin : **bonjour**. Le soir : **bonsoir**. Avant de dormir : **bonne nuit**.

Entre amis : **salut** (familier). Pour prendre des nouvelles : **Comment ça va ?** — réponse : **Ça va bien, merci !**

Formule polie : **Comment allez-vous ?** (vouvoiement). Pour partir : **au revoir** ou **à bientôt**.', '[{"term":"bonjour","translation":"hello","phonetic":"[bɔ̃ʒuʁ]","example":"Bonjour, madame !","example_tr":"Hello, madam!"},{"term":"salut","translation":"hi","phonetic":"[saly]","example":"Salut, Pierre !","example_tr":"Hi, Pierre!"},{"term":"bonsoir","translation":"good evening","phonetic":"[bɔ̃swaʁ]","example":"Bonsoir, entrez !","example_tr":"Good evening, come in!"},{"term":"bonne nuit","translation":"good night","phonetic":"[bɔn nɥi]","example":"Bonne nuit, maman !","example_tr":"Good night, mom!"},{"term":"au revoir","translation":"goodbye","phonetic":"[o ʁəvwaʁ]","example":"Au revoir, à demain !","example_tr":"Goodbye, see you tomorrow!"},{"term":"ça va ?","translation":"how are you? (informal)","phonetic":"[sa va]","example":"Salut, ça va ?","example_tr":"Hi, how are you?"},{"term":"ça va bien, merci","translation":"I''m fine, thanks","phonetic":"[sa va bjɛ̃ mɛʁsi]","example":"Ça va bien, merci !","example_tr":"I''m fine, thanks!"},{"term":"à bientôt","translation":"see you soon","phonetic":"[a bjɛ̃to]","example":"À bientôt, Marie !","example_tr":"See you soon, Marie!"}]'::jsonb, '[{"sentence":"Bonjour, comment ça va ?","translation":"Hello, how are you?"},{"sentence":"Ça va bien, merci. Et toi ?","translation":"I''m fine, thanks. And you?"},{"sentence":"Bonsoir, au revoir !","translation":"Good evening, goodbye!"}]'::jsonb, 10, true, 1 from public.modules where code = 'fr-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Vous quittez des amis à 22 h avant de dormir. Que dites-vous ?","options":["Bonjour !","Bonne nuit !","Bonsoir !"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Bonne nuit » se dit juste avant de dormir. « Bonsoir » s''utilise en arrivant le soir.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"Hi, how are you?"}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["salut, ça va","salut, comment ça va","salut, comment vas-tu"]}'::jsonb, '[]'::jsonb, '« Salut » est la forme familière de « bonjour ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ , ça va ? — Ça va ___ , merci.","translation":"Hi, how are you? — I''m fine, thanks."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["salut","bien"]}'::jsonb, '[]'::jsonb, '« Ça va bien, merci » est la réponse la plus courante.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression à son moment d''usage.","pairs":[{"left":"bonjour","right":"le matin ou la journée"},{"left":"bonsoir","right":"le soir"},{"left":"bonne nuit","right":"avant de dormir"},{"left":"au revoir","right":"en partant"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Chaque salutation française correspond à un moment précis.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets les mots en ordre :","words":["va","Ça","bien",","],"translation":"Ça va bien."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, '« Ça va bien » : ordre figé, très utilisé en conversation.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Bonjour, ça va ? — Ça va bien, merci !","question":"Écoute puis choisis la traduction du dialogue.","options":["Hello, how are you? — I''m fine, thanks!","Good night! — See you soon!","Good evening! — Goodbye!"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Ça va ? » demande des nouvelles ; « ça va bien » répond positivement.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m1-l2', 'Se présenter', 'Donner son nom, son âge, sa nationalité et poser ces questions.', 'Nom : **Je m''appelle Anna.** — question : **Comment tu t''appelles ?** (ou « Comment vous appelez-vous ? »).

Origine : **Je viens du Brésil.** — **Je suis brésilien / brésilienne.** — question : **D''où viens-tu ?**

Âge : **J''ai 20 ans.** (⚠️ avec AVOIR, contrairement à l''anglais « I am 20 »).

Métier : **Je suis étudiant(e).**', '[{"term":"je m''appelle…","translation":"my name is…","phonetic":"[ʒə mapɛl]","example":"Je m''appelle Leo.","example_tr":"My name is Leo."},{"term":"comment tu t''appelles ?","translation":"what''s your name?","phonetic":"[kɔmɑ̃ ty tapɛl]","example":"Comment tu t''appelles ? — Nina.","example_tr":"What''s your name? — Nina."},{"term":"je viens de…","translation":"I come from…","phonetic":"[ʒə vjɛ̃ də]","example":"Je viens d''Espagne.","example_tr":"I come from Spain."},{"term":"j''ai … ans","translation":"I''m … years old","phonetic":"[ʒe ɑ̃]","example":"J''ai quinze ans.","example_tr":"I''m fifteen."},{"term":"étudiant(e)","translation":"student","phonetic":"[etydjɑ̃]","example":"Je suis étudiante.","example_tr":"I''m a student."},{"term":"enchanté(e)","translation":"nice to meet you","phonetic":"[ɑ̃ʃɑ̃te]","example":"Enchanté, Sofia !","example_tr":"Nice to meet you, Sofia!"},{"term":"s''il vous plaît","translation":"please (formal)","phonetic":"[sil vu plɛ]","example":"Répétez, s''il vous plaît.","example_tr":"Repeat, please."},{"term":"merci beaucoup","translation":"thank you very much","phonetic":"[mɛʁsi boku]","example":"Merci beaucoup !","example_tr":"Thank you very much!"}]'::jsonb, '[{"sentence":"Bonjour, je m''appelle Karl et je viens d''Allemagne.","translation":"Hello, my name is Karl and I come from Germany."},{"sentence":"Comment tu t''appelles ? — Je m''appelle Sofia.","translation":"What''s your name? — My name is Sofia."},{"sentence":"J''ai dix-neuf ans et je suis étudiant.","translation":"I''m nineteen and I''m a student."}]'::jsonb, 10, true, 2 from public.modules where code = 'fr-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Quelle phrase est correcte pour donner son âge ?","options":["Je suis 20 ans.","J''ai 20 ans.","Je fais 20 ans."]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'En français, l''âge s''exprime avec AVOIR : « j''ai 20 ans ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"My name is Marco."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["je m''appelle marco","mon nom est marco"]}'::jsonb, '[]'::jsonb, '« Je m''appelle » est la formule standard pour se présenter.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Je ___ du Portugal. ___ m''appelle Ana.","translation":"I come from Portugal. My name is Ana."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["viens","je"]}'::jsonb, '[]'::jsonb, '« Je viens de + pays » (de + le → du pour le Portugal, le Brésil…).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque question à sa réponse.","pairs":[{"left":"Comment tu t''appelles ?","right":"Je m''appelle Marco."},{"left":"D''où viens-tu ?","right":"Je viens d''Italie."},{"left":"Quel âge as-tu ?","right":"J''ai dix-huit ans."},{"left":"Ça va ?","right":"Ça va bien, merci."}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Nom, origine, âge, état : quatre questions essentielles d''une première rencontre.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["appelle","Je","Léa","m''","."],"translation":"Je m''appelle Léa."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,0,2,4]}'::jsonb, '[]'::jsonb, '« Je m''appelle » : le pronom me devient m'' devant appelle.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Un nouveau camarade","passage":"Salut ! Je m''appelle Tom et je viens du Canada. J''ai dix-neuf ans. Je suis étudiant. Mon professeur s''appelle Mme Vert. Elle est très gentille.","questions":[{"q":"D''où vient Tom ?","options":["Des États-Unis","Du Canada","D''Australie"]},{"q":"Quel âge a Tom ?","options":["Neuf ans","Quatre-vingt-dix ans","Dix-neuf ans"]},{"q":"Qui est Mme Vert ?","options":["Sa mère","Son professeure","Sa sœur"]}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,2,1]}'::jsonb, '[]'::jsonb, 'Relis le texte : « je viens du Canada », « dix-neuf ans », « Mon professeur s''appelle Mme Vert ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'fr-a1-m2', 'Le quotidien', '', 2 from public.courses where code = 'fr-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m2-l1', 'Les nombres 1 à 20', 'Compter de 1 à 20 et donner un numéro de téléphone.', '1 un, 2 deux, 3 trois, 4 quatre, 5 cinq, 6 six, 7 sept, 8 huit, 9 neuf, 10 dix, 11 onze, 12 douze, 13 treize, 14 quatorze, 15 quinze, 16 seize, 17 dix-sept, 18 dix-huit, 19 dix-neuf, 20 vingt.

⚠️ Pièges : 15 = **quinze** et 50 = **cinquante** ; 16 = **seize** mais 60 = **soixante**.

Pour un numéro de téléphone, on énonce les chiffres deux par deux : « zéro six, quinze, vingt-trois… ».', '[{"term":"un / deux / trois","translation":"one / two / three","phonetic":"[œ̃ dø tʁwɑ]","example":"J''ai trois chats.","example_tr":"I have three cats."},{"term":"quatre / cinq / six","translation":"four / five / six","phonetic":"[katʁ sɛ̃k sis]","example":"Cinq pommes, s''il vous plaît.","example_tr":"Five apples, please."},{"term":"onze / douze","translation":"eleven / twelve","phonetic":"[ɔ̃z duz]","example":"Douze mois par an.","example_tr":"Twelve months a year."},{"term":"quinze","translation":"fifteen","phonetic":"[kɛ̃z]","example":"Elle a quinze ans.","example_tr":"She is fifteen."},{"term":"seize","translation":"sixteen","phonetic":"[sɛz]","example":"Seize élèves ici.","example_tr":"Sixteen students here."},{"term":"vingt","translation":"twenty","phonetic":"[vɛ̃t]","example":"Vingt euros, s''il vous plaît.","example_tr":"Twenty euros, please."},{"term":"combien ?","translation":"how many / how much?","phonetic":"[kɔ̃bjɛ̃]","example":"Combien de livres ?","example_tr":"How many books?"},{"term":"le numéro","translation":"the number","phonetic":"[lə numeʁo]","example":"Quel est ton numéro ?","example_tr":"What''s your number?"}]'::jsonb, '[{"sentence":"J''ai deux frères et une sœur.","translation":"I have two brothers and one sister."},{"sentence":"Combien de jours ? — Sept !","translation":"How many days? — Seven!"},{"sentence":"Mon numéro est le zéro six, douze, trente-quatre.","translation":"My number is 06 12 34."}]'::jsonb, 10, true, 1 from public.modules where code = 'fr-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Comment dit-on « 15 » ?","options":["Cinquante","Quinze","Cinq"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '15 = quinze ; 50 = cinquante ; 5 = cinq. Trois mots proches à bien distinguer !' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Écris le nombre en français (en toutes lettres) :","source":"13"}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["treize"]}'::jsonb, '[]'::jsonb, '13 = treize ; à ne pas confondre avec « trois » (3).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ d''élèves ? — ___ , monsieur.","translation":"How many students? — Twelve, sir."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["combien","douze"]}'::jsonb, '[]'::jsonb, '« Combien de + nom » demande une quantité.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque nombre en lettres à son chiffre.","pairs":[{"left":"trois","right":"3"},{"left":"huit","right":"8"},{"left":"onze","right":"11"},{"left":"vingt","right":"20"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les nombres 1 à 16 ont un nom unique ; à partir de 17 : dix-sept, dix-huit…' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["numéro","Quel","ton","est","?"],"translation":"Quel est ton numéro ?"}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,2,0,4]}'::jsonb, '[]'::jsonb, 'Structure : Quel + est + ton + nom ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"J''ai sept pommes et deux bananes.","question":"Écoute puis réponds : combien de pommes ?","options":["Sept","Onze","Trois"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Sept pommes » = seven apples.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m2-l2', 'Jours et heures', 'Dire les jours de la semaine et donner l''heure.', 'Jours : lundi, mardi, mercredi, jeudi, vendredi, samedi, dimanche (minuscules en français).

L''heure : **Quelle heure est-il ?** — **Il est trois heures.** — **Il est trois heures et demie.** (3 h 30) — **Il est trois heures et quart.** (3 h 15) — **Il est quatre heures moins le quart.** (3 h 45).

Prépositions : **le lundi** (habitude), **à trois heures** (heure précise), **le matin / l''après-midi / le soir**.', '[{"term":"lundi","translation":"Monday","phonetic":"[lœ̃di]","example":"Je travaille le lundi.","example_tr":"I work on Mondays."},{"term":"mercredi","translation":"Wednesday","phonetic":"[mɛʁkʁədi]","example":"On se voit mercredi.","example_tr":"We meet on Wednesday."},{"term":"samedi","translation":"Saturday","phonetic":"[samdi]","example":"Samedi, c''est mon jour préféré.","example_tr":"Saturday is my favorite day."},{"term":"quelle heure est-il ?","translation":"what time is it?","phonetic":"[kɛl œʁ ɛtil]","example":"Quelle heure est-il ? — Il est cinq heures.","example_tr":"What time is it? — It''s five."},{"term":"et demie","translation":"half past","phonetic":"[e dəmi]","example":"Il est deux heures et demie.","example_tr":"It''s half past two."},{"term":"moins le quart","translation":"quarter to","phonetic":"[mwɛ̃ lə kaʁ]","example":"Il est neuf heures moins le quart.","example_tr":"It''s quarter to nine."},{"term":"aujourd''hui / demain","translation":"today / tomorrow","phonetic":"[oʒuʁdɥi dəmɛ̃]","example":"Demain, c''est dimanche.","example_tr":"Tomorrow is Sunday."},{"term":"à … heures","translation":"at … o''clock","phonetic":"[a œʁ]","example":"Le cours commence à six heures.","example_tr":"The class starts at six."}]'::jsonb, '[{"sentence":"Il est sept heures et demie. Je suis en retard !","translation":"It''s half past seven. I''m late!"},{"sentence":"Mercredi, je joue au football à quatre heures.","translation":"On Wednesday, I play football at four."},{"sentence":"Quelle heure est-il ? — Il est dix heures et quart.","translation":"What time is it? — It''s quarter past ten."}]'::jsonb, 10, true, 2 from public.modules where code = 'fr-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"« Il est six heures moins le quart » signifie :","options":["6 h 15","5 h 45","6 h 45"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Moins le quart » = un quart AVANT l''heure suivante : 5 h 45.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"It''s half past three."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["il est trois heures et demie","il est trois heures et demi"]}'::jsonb, '[]'::jsonb, '« … heures et demie » (demie s''accorde avec heures).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Le cours est ___ lundi ___ neuf heures.","translation":"The class is on Monday at nine."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["le","à"]}'::jsonb, '[]'::jsonb, '« le lundi » pour l''habitude ; « à » pour l''heure précise.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque jour français à sa traduction.","pairs":[{"left":"lundi","right":"Monday"},{"left":"mercredi","right":"Wednesday"},{"left":"vendredi","right":"Friday"},{"left":"dimanche","right":"Sunday"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les jours français viennent des planètes, comme en anglais.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["heure","Quelle","est-il","?"],"translation":"Quelle heure est-il ?"}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, 'Question figée : « Quelle heure est-il ? ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Mon emploi du temps","passage":"Le lundi, j''ai cours d''anglais à neuf heures. Le mercredi, je joue au tennis à quatre heures et demie. Le samedi, je ne travaille pas. J''adore le samedi !","questions":[{"q":"Quand y a-t-il le cours d''anglais ?","options":["Lundi à 9 h","Mercredi à 9 h","Samedi à 9 h"]},{"q":"À quelle heure joue-t-on au tennis ?","options":["4 h 15","4 h 30","4 h 45"]},{"q":"Que fait-on samedi ?","options":["On travaille","On a un cours","On ne travaille pas"]}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « à neuf heures », « quatre heures et demie », « je ne travaille pas ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m2-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'fr-a1-m3', 'Vivre ensemble', '', 3 from public.courses where code = 'fr-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m3-l1', 'La nourriture', 'Commander un repas et dire ce qu''on aime.', 'Aimer / ne pas aimer : **J''aime le fromage.** — **Je n''aime pas le poisson.** — question : **Tu aimes le café ?**

Commander : **Je voudrais un café, s''il vous plaît.** (plus poli que « je veux »). — **L''addition, s''il vous plaît !**

Articles : **un / une / des** (indéfinis), **le / la / les** (définis) : **J''aime le pain** (généralité avec le).', '[{"term":"le pain","translation":"bread","phonetic":"[lə pɛ̃]","example":"J''achète du pain chaque jour.","example_tr":"I buy bread every day."},{"term":"le fromage","translation":"cheese","phonetic":"[lə fʁɔmaʒ]","example":"Le fromage français est célèbre.","example_tr":"French cheese is famous."},{"term":"la pomme","translation":"apple","phonetic":"[la pɔm]","example":"Une pomme par jour !","example_tr":"An apple a day!"},{"term":"l''eau","translation":"water","phonetic":"[lo]","example":"Un verre d''eau, s''il vous plaît.","example_tr":"A glass of water, please."},{"term":"le petit-déjeuner","translation":"breakfast","phonetic":"[lə pətideʒəne]","example":"Je prends mon petit-déjeuner à sept heures.","example_tr":"I have breakfast at seven."},{"term":"je voudrais…","translation":"I would like…","phonetic":"[ʒə vudʁɛ]","example":"Je voudrais un thé, s''il vous plaît.","example_tr":"I''d like a tea, please."},{"term":"l''addition","translation":"the bill","phonetic":"[ladisjɔ̃]","example":"L''addition, s''il vous plaît !","example_tr":"The bill, please!"},{"term":"délicieux / délicieuse","translation":"delicious","phonetic":"[delisjø]","example":"Cette soupe est délicieuse !","example_tr":"This soup is delicious!"}]'::jsonb, '[{"sentence":"J''aime le café mais je n''aime pas le thé.","translation":"I like coffee but I don''t like tea."},{"sentence":"Je voudrais un sandwich au fromage, s''il vous plaît.","translation":"I''d like a cheese sandwich, please."},{"sentence":"Tu aimes les pommes ? — Oui, j''adore ça !","translation":"Do you like apples? — Yes, I love them!"}]'::jsonb, 10, true, 1 from public.modules where code = 'fr-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"La formule la plus polie pour commander :","options":["Je veux un café.","Donne-moi un café.","Je voudrais un café, s''il vous plaît."]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":2}'::jsonb, '[]'::jsonb, '« Je voudrais » (conditionnel) + « s''il vous plaît » : la formule standard.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"I like cheese."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["j''aime le fromage","j''aime du fromage","j''aime fromage"]}'::jsonb, '[]'::jsonb, 'Pour une généralité : « j''aime LE fromage » (article défini).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Tu ___ le poisson ? — Non, je n''___ pas.","translation":"Do you like fish? — No, I don''t."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["aimes","aime"]}'::jsonb, '[]'::jsonb, 'Négation : ne + verbe + pas → « je n''aime pas ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque mot à sa traduction.","pairs":[{"left":"le pain","right":"bread"},{"left":"l''eau","right":"water"},{"left":"le petit-déjeuner","right":"breakfast"},{"left":"l''addition","right":"the bill"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces quatre mots sont parmi les plus fréquents au restaurant.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la commande en ordre :","words":["un","Je","s''il","voudrais","thé","vous","plaît"],"translation":"Je voudrais un thé, s''il vous plaît."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,4,3,5,6,2]}'::jsonb, '[]'::jsonb, 'Structure : je voudrais + un/une + nom + , + s''il vous plaît.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Je voudrais un sandwich au fromage et un verre d''eau, s''il vous plaît.","question":"Écoute la commande : que veut la personne ?","options":["Un sandwich au fromage et de l''eau","Un thé et du pain","Une pomme et du fromage"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'Repère les mots-clés : sandwich, fromage, eau.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a1-m3-l2', 'La famille', 'Présenter sa famille avec les possessifs mon/ma/mes, son/sa/ses.', 'Membres : le **père**, la **mère**, le **frère**, la **sœur**, le **fils**, la **fille**, le **mari**, la **femme**.

Possessifs : **mon/ma/mes** (my), **ton/ta/tes** (your), **son/sa/ses** (his OR her).

⚠️ Le possessif s''accorde avec l''OBJET, pas avec le propriétaire : **son frère** = his brother OU her brother (frère = masculin → son).', '[{"term":"le père / la mère","translation":"father / mother","phonetic":"[lə pɛʁ la mɛʁ]","example":"Mon père est grand.","example_tr":"My father is tall."},{"term":"le frère / la sœur","translation":"brother / sister","phonetic":"[lə fʁɛʁ la sœʁ]","example":"J''ai deux sœurs.","example_tr":"I have two sisters."},{"term":"le fils / la fille","translation":"son / daughter","phonetic":"[lə fi la fi]","example":"Leur fille a six ans.","example_tr":"Their daughter is six."},{"term":"son / sa / ses","translation":"his / her / its","phonetic":"[sɔ̃ sa se]","example":"Sa voiture est rouge.","example_tr":"His/Her car is red."},{"term":"marié(e)","translation":"married","phonetic":"[maʁje]","example":"Ils sont mariés.","example_tr":"They are married."},{"term":"les enfants","translation":"children","phonetic":"[lez ɑ̃fɑ̃]","example":"Nous avons trois enfants.","example_tr":"We have three children."},{"term":"la famille","translation":"family","phonetic":"[la famij]","example":"J''aime ma famille.","example_tr":"I love my family."},{"term":"les grands-parents","translation":"grandparents","phonetic":"[le ɡʁɑ̃paʁɑ̃]","example":"Mes grands-parents habitent à Rome.","example_tr":"My grandparents live in Rome."}]'::jsonb, '[{"sentence":"Voici ma mère. Elle s''appelle Carla.","translation":"This is my mother. Her name is Carla."},{"sentence":"Mon frère est professeur. Ses élèves sont gentils.","translation":"My brother is a teacher. His students are nice."},{"sentence":"Combien d''enfants as-tu ?","translation":"How many children do you have?"}]'::jsonb, 10, true, 2 from public.modules where code = 'fr-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Maria a un frère. Comment dit-on « her brother » ?","options":["son frère","sa frère","ses frère"]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'frère = masculin → « son », quel que soit le propriétaire (Maria = elle).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"My sister is ten years old."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["ma sœur a dix ans","ma soeur a dix ans"]}'::jsonb, '[]'::jsonb, 'Avec AVOIR pour l''âge : « ma sœur a dix ans ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Voici mon père. ___ nom est Paul. J''ai deux ___ .","translation":"This is my father. His name is Paul. I have two sisters."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["son","sœurs"]}'::jsonb, '[]'::jsonb, '« Son nom » (nom = masculin) ; « sœurs » au pluriel.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque membre de la famille.","pairs":[{"left":"le père","right":"father"},{"left":"la fille","right":"daughter"},{"left":"la femme","right":"wife"},{"left":"les enfants","right":"children"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, '« La fille » = daughter (l''enfant fille) ; « la femme » = wife ou woman selon le contexte.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["frère","Voici","mon","."],"translation":"Voici mon frère."}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,2,0,3]}'::jsonb, '[]'::jsonb, '« Voici + mon/ma + membre de la famille ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"La famille de Leo","passage":"Voici Leo. Son père est médecin et sa mère est infirmière. Il a une sœur, Mia. Elle est étudiante. Les grands-parents de Leo habitent à Rome.","questions":[{"q":"Que fait le père de Leo ?","options":["Infirmière","Médecin","Professeur"]},{"q":"Comment s''appelle la sœur de Leo ?","options":["Mia","Rome","Nina"]},{"q":"Où habitent les grands-parents ?","options":["À Rome","À Paris","À Madrid"]}]}'::jsonb, 10, true from public.lessons where code = 'fr-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,0,0]}'::jsonb, '[]'::jsonb, 'Relis : « Son père est médecin », « une sœur, Mia », « habitent à Rome ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a1-m3-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'fr-a2', 'Français A2 — Conversations du quotidien', 'Raconter au passé et parler de ses projets.', 'A2'::public.cefr_level, true, 2 from public.languages where code = 'fr' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'fr-a2-m1', 'Raconter et prévoir', '', 1 from public.courses where code = 'fr-a2' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a2-m1-l1', 'Le passé composé', 'Raconter ce que tu as fait hier ou la semaine dernière.', 'Le passé composé = **avoir** (ou être) au présent + **participe passé**.

Participes : parler → **parlé**, finir → **fini**, prendre → **pris**, faire → **fait**, voir → **vu**.

Verbes avec **être** (accord !) : aller, venir, partir, arriver… — **Je suis allé(e)**, **elle est venue**.

Négation : **Je n''ai pas vu.** — Question : **Tu as vu ?**

Marqueurs : **hier**, **la semaine dernière**, **il y a deux jours**.', '[{"term":"hier","translation":"yesterday","phonetic":"[jɛʁ]","example":"Hier, j''ai travaillé.","example_tr":"Yesterday, I worked."},{"term":"la semaine dernière","translation":"last week","phonetic":"[la səmɛn dɛʁnjɛʁ]","example":"Nous sommes allés à la plage la semaine dernière.","example_tr":"We went to the beach last week."},{"term":"j''ai vu","translation":"I saw","phonetic":"[ʒe vy]","example":"J''ai vu un bon film.","example_tr":"I saw a good film."},{"term":"j''ai fait","translation":"I did / made","phonetic":"[ʒe fɛ]","example":"J''ai fait mes devoirs.","example_tr":"I did my homework."},{"term":"j''ai pris","translation":"I took","phonetic":"[ʒe pʁi]","example":"J''ai pris le bus.","example_tr":"I took the bus."},{"term":"je suis allé(e)","translation":"I went","phonetic":"[ʒə sɥiz ale]","example":"Je suis allée au cinéma.","example_tr":"I went to the cinema."},{"term":"il y a … (temps)","translation":"… ago","phonetic":"[il ja]","example":"Il y a deux ans, on a déménagé.","example_tr":"Two years ago, we moved."},{"term":"je n''ai pas","translation":"I didn''t","phonetic":"[ʒə ne pa]","example":"Je n''ai pas vu le match.","example_tr":"I didn''t see the match."}]'::jsonb, '[{"sentence":"Hier, j''ai rendu visite à ma grand-mère.","translation":"Yesterday, I visited my grandmother."},{"sentence":"Tu as aimé le film ? — Oui, beaucoup !","translation":"Did you like the film? — Yes, a lot!"},{"sentence":"Nous ne sommes pas sortis parce qu''il a plu.","translation":"We didn''t go out because it rained."}]'::jsonb, 10, true, 1 from public.modules where code = 'fr-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Hier, je ___ au cinéma. »","options":["ai allé","suis allé","vais aller"]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'ALLER prend ÊTRE au passé composé : « je suis allé(e) ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"I bought bread yesterday."}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["j''ai acheté du pain hier","hier j''ai acheté du pain"]}'::jsonb, '[]'::jsonb, 'acheter → acheté (participe régulier en -é) + avoir.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Tu ___ vu le match hier soir ? — Non, je n''___ pas vu.","translation":"Did you see the match last night? — No."}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["as","ai"]}'::jsonb, '[]'::jsonb, 'avoir au présent : j''ai, tu as… ; négation : je n''ai pas vu.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque infinitif à son participe passé.","pairs":[{"left":"faire","right":"fait"},{"left":"voir","right":"vu"},{"left":"prendre","right":"pris"},{"left":"finir","right":"fini"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces participes irréguliers sont très fréquents : fait, vu, pris, fini.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["film","un","vu","Nous","avons","."],"translation":"Nous avons vu un film."}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[3,4,2,1,0,5]}'::jsonb, '[]'::jsonb, 'Ordre : sujet + avoir + participe + complément.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Le week-end d''Emma","passage":"Samedi dernier, Emma est allée au marché avec son père. Ils ont acheté des fruits et du fromage. L''après-midi, elle a joué au tennis avec ses amis. Ils se sont bien amusés, mais elle n''a pas préparé le dîner — sa mère l''a fait !","questions":[{"q":"Où est allée Emma samedi ?","options":["Au marché","Au cinéma","À l''école"]},{"q":"Qu''ont-ils acheté ?","options":["Des chaussures","Des fruits et du fromage","Des livres"]},{"q":"Qui a préparé le dîner ?","options":["Emma","Ses amis","Sa mère"]}]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « est allée au marché », « ont acheté des fruits », « sa mère l''a fait ! ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'fr-a2-m1-l2', 'Parler de ses projets', 'Exprimer un projet avec le futur proche et « vouloir ».', 'Futur proche = **aller** + infinitif : **Je vais voyager cet été.** — **Elle va étudier la médecine.**

Négation : **Je ne vais pas travailler dimanche.** — Question : **Tu vas regarder le match ?**

Vouloir + infinitif : **Je veux apprendre l''anglais.** — **Il veut acheter une voiture.**

Invitation : **Tu veux venir ?** — réponse : **Avec plaisir !**', '[{"term":"je vais…","translation":"I''m going to…","phonetic":"[ʒə vɛ]","example":"Je vais visiter le Pérou.","example_tr":"I''m going to visit Peru."},{"term":"le mois prochain","translation":"next month","phonetic":"[lə mwa pʁɔʃɛ̃]","example":"On commence le mois prochain.","example_tr":"We start next month."},{"term":"je veux…","translation":"I want to…","phonetic":"[ʒə vø]","example":"Je veux mieux parler.","example_tr":"I want to speak better."},{"term":"un projet","translation":"a plan","phonetic":"[œ̃ pʁɔʒɛ]","example":"Mon projet est simple.","example_tr":"My plan is simple."},{"term":"tu veux venir ?","translation":"do you want to come?","phonetic":"[ty vø vəniʁ]","example":"Tu veux venir avec nous ?","example_tr":"Do you want to come with us?"},{"term":"avec plaisir !","translation":"I''d love to!","phonetic":"[avɛk pleziʁ]","example":"Avec plaisir, j''arrive !","example_tr":"I''d love to, I''m coming!"},{"term":"peut-être","translation":"maybe","phonetic":"[pøtɛtʁ]","example":"Peut-être l''année prochaine.","example_tr":"Maybe next year."},{"term":"parce que","translation":"because","phonetic":"[paʁskə]","example":"Je reste ici parce que je suis fatigué.","example_tr":"I stay here because I''m tired."}]'::jsonb, '[{"sentence":"Je vais apprendre l''espagnol le mois prochain.","translation":"I''m going to learn Spanish next month."},{"sentence":"Tu vas regarder le match ce soir ?","translation":"Are you going to watch the match tonight?"},{"sentence":"Elle veut travailler au Canada.","translation":"She wants to work in Canada."}]'::jsonb, 10, true, 2 from public.modules where code = 'fr-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Elle ___ étudier ce soir. » (projet)","options":["va","vas","ont"]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'Futur proche : aller conjugué + infinitif → elle VA étudier.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en français :","source":"I''m going to visit Italy this summer."}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["je vais visiter l''italie cet été","je vais visiter l''italie cette été"]}'::jsonb, '[]'::jsonb, 'Futur proche : je vais + visiter. « cet été » (été masculin).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Je ___ apprendre l''anglais ___ c''est utile.","translation":"I want to learn English because it''s useful."}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["veux","parce que"]}'::jsonb, '[]'::jsonb, 'vouloir + infinitif directement : « je veux apprendre ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression à sa traduction.","pairs":[{"left":"le mois prochain","right":"next month"},{"left":"avec plaisir !","right":"I''d love to!"},{"left":"peut-être","right":"maybe"},{"left":"parce que","right":"because"}]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces petits mots rendent tes conversations naturelles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["tu","Vas","voyager","?"],"translation":"Vas-tu voyager ?"}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, 'Inversion : Vas-tu voyager ? ou « Tu vas voyager ? » à l''oral.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Je vais rendre visite à ma grand-mère le mois prochain.","question":"Écoute : que va faire la personne ?","options":["Voyager en Italie","Rendre visite à sa grand-mère","Acheter une voiture"]}'::jsonb, 10, true from public.lessons where code = 'fr-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Rendre visite à » = to visit (a person).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'fr-a2-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'es-a1', 'Espagnol A1 — Primeros pasos', 'Les bases : saluer, se présenter, compter, parler du quotidien.', 'A1'::public.cefr_level, true, 1 from public.languages where code = 'es' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'es-a1-m1', 'Primeros contactos', '', 1 from public.courses where code = 'es-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m1-l1', 'Saluer', 'Saluer à différents moments de la journée et demander des nouvelles.', 'Le matin et la journée : **buenos días**. L''après-midi/soir : **buenas tardes**. Le soir tard : **buenas noches** (sert aussi de « bonne nuit »).

Familier : **hola**. Nouvelles : **¿Cómo estás?** — réponse : **Bien, gracias, ¿y tú?**

Au revoir : **adiós**, **hasta luego** (à plus tard), **hasta mañana** (à demain).', '[{"term":"hola","translation":"bonjour / salut","phonetic":"[''ola]","example":"¡Hola, Tom!","example_tr":"Salut, Tom !"},{"term":"buenos días","translation":"bonjour (le matin)","phonetic":"[''bwenos ''dias]","example":"Buenos días, señora.","example_tr":"Bonjour, madame."},{"term":"buenas tardes","translation":"bonjour / bonsoir (après-midi)","phonetic":"[''bwenas ''taɾdes]","example":"Buenas tardes, a todos.","example_tr":"Bonjour à tous."},{"term":"buenas noches","translation":"bonsoir / bonne nuit","phonetic":"[''bwenas ''notʃes]","example":"Buenas noches, mamá.","example_tr":"Bonne nuit, maman."},{"term":"adiós","translation":"au revoir","phonetic":"[a''ðjos]","example":"Adiós, hasta pronto.","example_tr":"Au revoir, à bientôt."},{"term":"hasta luego","translation":"à plus tard","phonetic":"[''asta ''lweɣo]","example":"Hasta luego, Ana.","example_tr":"À plus tard, Ana."},{"term":"¿cómo estás?","translation":"comment vas-tu ?","phonetic":"[''komo es''tas]","example":"Hola, ¿cómo estás?","example_tr":"Salut, comment vas-tu ?"},{"term":"bien, gracias","translation":"bien, merci","phonetic":"[bjen ''gɾasjas]","example":"Bien, gracias. ¿Y tú?","example_tr":"Bien, merci. Et toi ?"}]'::jsonb, '[{"sentence":"¡Hola! ¿Cómo estás hoy?","translation":"Salut ! Comment vas-tu aujourd''hui ?"},{"sentence":"Buenos días, profesor. Bien, gracias.","translation":"Bonjour, professeur. Bien, merci."},{"sentence":"Buenas noches, hasta mañana.","translation":"Bonne nuit, à demain."}]'::jsonb, 10, true, 1 from public.modules where code = 'es-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Tu croises ton professeur à 9 h du matin. Que dis-tu ?","options":["Buenas noches.","Buenos días.","Adiós."]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Buenos días » s''utilise du matin jusqu''à midi environ.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"Salut, comment vas-tu ?"}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["hola como estas","hola, ¿cómo estás?","hola, como estas"]}'::jsonb, '[]'::jsonb, '« Hola » à tout moment + « ¿cómo estás? » pour demander des nouvelles (familier).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"¿Cómo ___ ? — Bien, ___ .","translation":"Comment vas-tu ? — Bien, merci."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["estás","gracias"]}'::jsonb, '[]'::jsonb, 'estás = tu es (verbe estar). Réponse standard : « bien, gracias ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque salutation à son moment.","pairs":[{"left":"buenos días","right":"le matin"},{"left":"buenas tardes","right":"l''après-midi"},{"left":"buenas noches","right":"le soir / avant de dormir"},{"left":"hasta luego","right":"en partant (à plus tard)"}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les salutations espagnoles suivent la journée : días, tardes, noches.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets les mots en ordre :","words":["estás","Cómo","¿","?"],"translation":"¿Cómo estás ?"}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[2,1,0,3]}'::jsonb, '[]'::jsonb, 'Les questions espagnoles commencent par ¿ inversé et se terminent par ?.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Buenas noches a todos. ¡Adiós!","question":"Écoute puis choisis la traduction.","options":["Bonsoir à tous — au revoir.","Bonjour à tous — à demain.","Salut à tous — merci."]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Buenas noches » = bonsoir/bonne nuit ; « adiós » = au revoir.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m1-l2', 'Se présenter', 'Donner son nom, son origine, son âge et poser ces questions.', 'Nom : **Me llamo Pedro.** ou **Soy Pedro.** — question : **¿Cómo te llamas?**

Origine : **Soy de España.** — **¿De dónde eres?**

Âge : **Tengo 20 años.** (⚠️ avec TENER = avoir, comme en français).

Métier : **Soy estudiante.** (pas d''article !) — politesse : **por favor**, **gracias**.', '[{"term":"me llamo…","translation":"je m''appelle…","phonetic":"[me ''ʝamo]","example":"Me llamo Pedro.","example_tr":"Je m''appelle Pedro."},{"term":"¿cómo te llamas?","translation":"comment tu t''appelles ?","phonetic":"[''komo te ''jamas]","example":"¿Cómo te llamas? — Ana.","example_tr":"Comment tu t''appelles ? — Ana."},{"term":"soy de…","translation":"je viens de…","phonetic":"[soj ðe]","example":"Soy de Brasil.","example_tr":"Je viens du Brésil."},{"term":"tengo … años","translation":"j''ai … ans","phonetic":"[''teŋgo ''años]","example":"Tengo quince años.","example_tr":"J''ai quinze ans."},{"term":"estudiante","translation":"étudiant(e)","phonetic":"[estu''ðjante]","example":"Soy estudiante.","example_tr":"Je suis étudiant."},{"term":"mucho gusto","translation":"enchanté","phonetic":"[''mutʃo ''gusto]","example":"Mucho gusto, Ana.","example_tr":"Enchanté, Ana."},{"term":"por favor","translation":"s''il vous plaît","phonetic":"[poɾ fa''βoɾ]","example":"Repita, por favor.","example_tr":"Répétez, s''il vous plaît."},{"term":"gracias","translation":"merci","phonetic":"[''gɾasjas]","example":"Muchas gracias.","example_tr":"Merci beaucoup."}]'::jsonb, '[{"sentence":"Hola, me llamo Karl y soy de Alemania.","translation":"Salut, je m''appelle Karl et je viens d''Allemagne."},{"sentence":"¿Cómo te llamas? — Me llamo Sofia.","translation":"Comment tu t''appelles ? — Je m''appelle Sofia."},{"sentence":"Tengo diecinueve años y soy estudiante.","translation":"J''ai dix-neuf ans et je suis étudiant."}]'::jsonb, 10, true, 2 from public.modules where code = 'es-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Quelle phrase est correcte pour donner son âge ?","options":["Soy 20 años.","Tengo 20 años.","Hago 20 años."]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'L''âge s''exprime avec TENER : « tengo 20 años » — comme le français « j''ai ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"Je viens du Brésil."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["soy de brasil","vengo de brasil"]}'::jsonb, '[]'::jsonb, '« Soy de + pays » est la formule la plus simple pour l''origine.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Me ___ Ana. ___ de Portugal.","translation":"Je m''appelle Ana. Je viens du Portugal."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["llamo","Soy"]}'::jsonb, '[]'::jsonb, '« Me llamo » pour le nom ; « soy de » pour l''origine.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque question à sa réponse.","pairs":[{"left":"¿Cómo te llamas?","right":"Me llamo Marco."},{"left":"¿De dónde eres?","right":"Soy de Italia."},{"left":"¿Cuántos años tienes?","right":"Tengo dieciocho años."},{"left":"¿Cómo estás?","right":"Bien, gracias."}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Nom, origine, âge, état : les quatre questions d''une première rencontre.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["llamo","Me","Lía","."],"translation":"Me llamo Lía."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, '« Me llamo + prénom » : structure figée.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Un nuevo compañero","passage":"¡Hola! Me llamo Tom y soy de Canadá. Tengo diecinueve años. Soy estudiante. Mi profesora se llama señora Verde. Es muy simpática.","questions":[{"q":"D''où vient Tom ?","options":["De Estados Unidos","De Canadá","De Australia"]},{"q":"Quel âge a Tom ?","options":["Nueve","Noventa","Diecinueve"]},{"q":"Quién es la señora Verde ?","options":["Su madre","Su profesora","Su hermana"]}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,2,1]}'::jsonb, '[]'::jsonb, 'Relis : « soy de Canadá », « diecinueve años », « mi profesora se llama señora Verde ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'es-a1-m2', 'La vida diaria', '', 2 from public.courses where code = 'es-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m2-l1', 'Les nombres 1 à 20', 'Compter de 1 à 20 et donner un numéro de téléphone.', '1 uno, 2 dos, 3 tres, 4 cuatro, 5 cinco, 6 seis, 7 siete, 8 ocho, 9 nueve, 10 diez, 11 once, 12 doce, 13 trece, 14 catorce, 15 quince, 16 dieciséis, 17 diecisiete, 18 dieciocho, 19 diecinueve, 20 veinte.

⚠️ Pièges : 15 = **quince** mais 50 = **cincuenta**. À partir de 16 : **dieci** + nombre (dieciséis, diecisiete…).

Pour un téléphone : « cero, seis, cinco, cinco… ».', '[{"term":"uno / dos / tres","translation":"un / deux / trois","phonetic":"[''uno ''dos ''tɾes]","example":"Tengo tres gatos.","example_tr":"J''ai trois chats."},{"term":"cuatro / cinco / seis","translation":"quatre / cinq / six","phonetic":"[''kwatɾo ''siŋko ''sejs]","example":"Cinco manzanas, por favor.","example_tr":"Cinq pommes, s''il vous plaît."},{"term":"siete / ocho / nueve","translation":"sept / huit / neuf","phonetic":"[''sjete ''otʃo ''nweβe]","example":"Nueve estudiantes aquí.","example_tr":"Neuf élèves ici."},{"term":"once / doce","translation":"onze / douze","phonetic":"[''onse ''doθe]","example":"Doce meses al año.","example_tr":"Douze mois par an."},{"term":"quince","translation":"quinze","phonetic":"[''kiŋθe]","example":"Ella tiene quince años.","example_tr":"Elle a quinze ans."},{"term":"veinte","translation":"vingt","phonetic":"[''bejnte]","example":"Veinte euros, por favor.","example_tr":"Vingt euros, s''il vous plaît."},{"term":"¿cuántos?","translation":"combien ?","phonetic":"[''kwantos]","example":"¿Cuántos libros tienes?","example_tr":"Combien de livres as-tu ?"},{"term":"el número de teléfono","translation":"le numéro de téléphone","phonetic":"[el ''numeɾo ðe tele''fono]","example":"¿Cuál es tu número?","example_tr":"Quel est ton numéro ?"}]'::jsonb, '[{"sentence":"Tengo dos hermanos y una hermana.","translation":"J''ai deux frères et une sœur."},{"sentence":"¿Cuántos días? — ¡Siete!","translation":"Combien de jours ? — Sept !"},{"sentence":"Mi número es cero-seis-cinco-cinco.","translation":"Mon numéro est le 06 55."}]'::jsonb, 10, true, 1 from public.modules where code = 'es-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Comment dit-on « 15 » ?","options":["Cincuenta","Quince","Cinco"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '15 = quince ; 50 = cincuenta ; 5 = cinco.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Écris le nombre en espagnol (en toutes lettres) :","source":"13"}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["trece"]}'::jsonb, '[]'::jsonb, '13 = trece ; 3 = tres.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"¿___ estudiantes? — ___ , señor.","translation":"Combien d''élèves ? — Douze, monsieur."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["cuántos","doce"]}'::jsonb, '[]'::jsonb, '« ¿Cuántos…? » demande une quantité.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque nombre en lettres à son chiffre.","pairs":[{"left":"tres","right":"3"},{"left":"ocho","right":"8"},{"left":"once","right":"11"},{"left":"veinte","right":"20"}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, '1 à 15 ont un nom unique ; de 16 à 29 : dieci-…, veinti-…' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["tu","¿Cuál","número","es","?"],"translation":"¿Cuál es tu número ?"}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,2,0,4]}'::jsonb, '[]'::jsonb, '« ¿Cuál es…? » = « quel est… ? »' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Tengo siete manzanas y dos plátanos.","question":"Écoute puis réponds : combien de pommes ?","options":["Siete","Once","Tres"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Siete manzanas » = sept pommes.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m2-l2', 'Jours et heures', 'Dire les jours de la semaine et donner l''heure.', 'Jours : lunes, martes, miércoles, jueves, viernes, sábado, domingo (minuscules).

L''heure : **¿Qué hora es?** — **Son las tres.** (3 h) — **Son las tres y media.** (3 h 30) — **Son las tres y cuarto.** (3 h 15) — **Son las cuatro menos cuarto.** (3 h 45). Attention : une seule heure → **Es la una.**

Prépositions : **el lunes** (habitude), **a las tres** (heure), **por la mañana / por la tarde / por la noche**.', '[{"term":"lunes","translation":"lundi","phonetic":"[''lunes]","example":"Trabajo los lunes.","example_tr":"Je travaille les lundis."},{"term":"miércoles","translation":"mercredi","phonetic":"[''mjeɾkoles]","example":"Nos vemos el miércoles.","example_tr":"On se voit mercredi."},{"term":"sábado","translation":"samedi","phonetic":"[sa''βaðo]","example":"El sábado es mi día favorito.","example_tr":"Samedi est mon jour préféré."},{"term":"¿qué hora es?","translation":"quelle heure est-il ?","phonetic":"[ke ''oɾa es]","example":"¿Qué hora es? — Son las cinco.","example_tr":"Quelle heure est-il ? — Cinq heures."},{"term":"y media","translation":"et demie","phonetic":"[j ''meðja]","example":"Son las dos y media.","example_tr":"Il est deux heures et demie."},{"term":"menos cuarto","translation":"moins le quart","phonetic":"[''menos ''kwaɾto]","example":"Son las nueve menos cuarto.","example_tr":"Il est neuf heures moins le quart."},{"term":"hoy / mañana","translation":"aujourd''hui / demain","phonetic":"[oj ma''ñana]","example":"Mañana es domingo.","example_tr":"Demain, c''est dimanche."},{"term":"a las …","translation":"à … heures","phonetic":"[a las]","example":"La clase empieza a las seis.","example_tr":"Le cours commence à six heures."}]'::jsonb, '[{"sentence":"Son las siete y media. ¡Estoy tarde!","translation":"Il est sept heures et demie. Je suis en retard !"},{"sentence":"El miércoles juego al fútbol a las cuatro.","translation":"Mercredi, je joue au football à quatre heures."},{"sentence":"¿Qué hora es? — Son las diez y cuarto.","translation":"Quelle heure est-il ? — Dix heures et quart."}]'::jsonb, 10, true, 2 from public.modules where code = 'es-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"« Son las seis menos cuarto » signifie :","options":["6 h 15","5 h 45","6 h 45"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Menos cuarto » = un quart AVANT l''heure suivante : 5 h 45.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"Il est trois heures et demie."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["son las tres y media","son las 3 y media"]}'::jsonb, '[]'::jsonb, '« Son las + heure + y media » pour …h30.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"La clase es ___ lunes ___ las nueve.","translation":"Le cours est lundi à neuf heures."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["el","a"]}'::jsonb, '[]'::jsonb, '« el lunes » pour l''habitude ; « a las + heure » pour l''heure.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque jour espagnol à sa traduction.","pairs":[{"left":"lunes","right":"lundi"},{"left":"miércoles","right":"mercredi"},{"left":"viernes","right":"vendredi"},{"left":"domingo","right":"dimanche"}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les jours espagnols viennent aussi des planètes et divinités romaines.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["hora","¿Qué","es","?"],"translation":"¿Qué hora es ?"}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, '« ¿Qué hora es? » : question figée.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Mi horario","passage":"El lunes tengo clase de inglés a las nueve. El miércoles juego al tenis a las cuatro y media. El sábado no trabajo. ¡Me encanta el sábado!","questions":[{"q":"Quand a-t-il cours d''anglais ?","options":["Lundi à 9 h","Mercredi à 9 h","Samedi à 9 h"]},{"q":"À quelle heure joue-t-il au tennis ?","options":["4 h 15","4 h 30","4 h 45"]},{"q":"Que fait-il samedi ?","options":["Il travaille","Il a un cours","Il ne travaille pas"]}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « a las nueve », « a las cuatro y media », « no trabajo ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m2-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'es-a1-m3', 'Vivir juntos', '', 3 from public.courses where code = 'es-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m3-l1', 'La nourriture', 'Commander un repas et dire ce qu''on aime.', 'Aimer : **Me gusta el queso.** (gustar + article défini). Négation : **No me gusta el pescado.** — question : **¿Te gusta el café?**

Commander : **Quiero un café, por favor.** — **Para mí, un té.** — L''addition : **La cuenta, por favor.**

Articles : **un/una** (un/une), **el/la** (le/la) : **Me gusta EL queso** (généralité).', '[{"term":"el pan","translation":"le pain","phonetic":"[el pan]","example":"Compro pan cada día.","example_tr":"J''achète du pain chaque jour."},{"term":"el queso","translation":"le fromage","phonetic":"[el ''keso]","example":"El queso francés es famoso.","example_tr":"Le fromage français est célèbre."},{"term":"la manzana","translation":"la pomme","phonetic":"[la man''θana]","example":"¡Una manzana al día!","example_tr":"Une pomme par jour !"},{"term":"el agua","translation":"l''eau","phonetic":"[el ''aɣwa]","example":"Un vaso de agua, por favor.","example_tr":"Un verre d''eau, s''il vous plaît."},{"term":"el desayuno","translation":"le petit-déjeuner","phonetic":"[el desa''ʝuno]","example":"Desayuno a las siete.","example_tr":"Je prends mon petit-déjeuner à sept heures."},{"term":"quiero…","translation":"je veux / je voudrais…","phonetic":"[''kjeɾo]","example":"Quiero un té, por favor.","example_tr":"Je voudrais un thé, s''il vous plaît."},{"term":"la cuenta","translation":"l''addition","phonetic":"[la ''kwenta]","example":"¡La cuenta, por favor!","example_tr":"L''addition, s''il vous plaît !"},{"term":"delicioso","translation":"délicieux","phonetic":"[de''lisjoso]","example":"¡Esta sopa está deliciosa!","example_tr":"Cette soupe est délicieuse !"}]'::jsonb, '[{"sentence":"Me gusta el café pero no me gusta el té.","translation":"J''aime le café mais je n''aime pas le thé."},{"sentence":"Quiero un sándwich de queso, por favor.","translation":"Je voudrais un sandwich au fromage, s''il vous plaît."},{"sentence":"¿Te gustan las manzanas? — ¡Sí, me encantan!","translation":"Tu aimes les pommes ? — Oui, j''adore !"}]'::jsonb, 10, true, 1 from public.modules where code = 'es-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « ___ gusta el queso. »","options":["Me","Yo","Quiero"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'GUSTAR se construit avec un pronom : ME gusta, TE gusta, LE gusta…' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"J''aime le fromage."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["me gusta el queso","me gusta queso"]}'::jsonb, '[]'::jsonb, '« Me gusta EL queso » : gustar + article défini pour la généralité.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"¿Te ___ el pescado? — No, no me ___ .","translation":"Aimes-tu le poisson ? — Non."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["gusta","gusta"]}'::jsonb, '[]'::jsonb, 'Question : ¿Te gusta…? Négation : « no me gusta ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque mot à sa traduction.","pairs":[{"left":"el pan","right":"le pain"},{"left":"el agua","right":"l''eau"},{"left":"el desayuno","right":"le petit-déjeuner"},{"left":"la cuenta","right":"l''addition"}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Quatre mots essentiels au restaurant espagnol.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la commande en ordre :","words":["un","Quiero","favor","té","por",","],"translation":"Quiero un té, por favor."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,3,5,4,2]}'::jsonb, '[]'::jsonb, 'Structure : quiero + un/una + nom + , + por favor.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Quiero un sándwich de queso y un vaso de agua, por favor.","question":"Écoute la commande : que veut la personne ?","options":["Un sandwich au fromage et de l''eau","Un thé et du pain","Une pomme et du fromage"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'Repère : sándwich de queso + vaso de agua.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a1-m3-l2', 'La famille', 'Présenter sa famille avec les possessifs mi/mis, su/sus.', 'Membres : el **padre**, la **madre**, el **hermano**, la **hermana**, el **hijo**, la **hija**, el **marido/esposo**, la **mujer/esposa**.

Possessifs : **mi/mis** (mon/mes), **tu/tus** (ton/tes), **su/sus** (son/sa/ses — à lui ET à elle !).

⚠️ « su hermano » peut signifier son frère (à lui) ou son frère (à elle) : le contexte décide.', '[{"term":"el padre / la madre","translation":"le père / la mère","phonetic":"[el ''paðɾe la ''maðɾe]","example":"Mi padre es alto.","example_tr":"Mon père est grand."},{"term":"el hermano / la hermana","translation":"le frère / la sœur","phonetic":"[el eɾ''mano la eɾ''mana]","example":"Tengo dos hermanas.","example_tr":"J''ai deux sœurs."},{"term":"el hijo / la hija","translation":"le fils / la fille","phonetic":"[el ''ixo la ''ixa]","example":"Su hija tiene seis años.","example_tr":"Leur fille a six ans."},{"term":"su / sus","translation":"son, sa, ses (à lui/elle)","phonetic":"[su sus]","example":"Su coche es rojo.","example_tr":"Sa voiture est rouge."},{"term":"casado/a","translation":"marié(e)","phonetic":"[ka''saðo]","example":"Ellos están casados.","example_tr":"Ils sont mariés."},{"term":"los hijos","translation":"les enfants","phonetic":"[los ''ixos]","example":"Tenemos tres hijos.","example_tr":"Nous avons trois enfants."},{"term":"la familia","translation":"la famille","phonetic":"[la fa''milja]","example":"Quiero a mi familia.","example_tr":"J''aime ma famille."},{"term":"los abuelos","translation":"les grands-parents","phonetic":"[los a''βwelos]","example":"Mis abuelos viven en Roma.","example_tr":"Mes grands-parents vivent à Rome."}]'::jsonb, '[{"sentence":"Esta es mi madre. Se llama Carla.","translation":"Voici ma mère. Elle s''appelle Carla."},{"sentence":"Mi hermano es profesor. Sus alumnos son simpáticos.","translation":"Mon frère est professeur. Ses élèves sont sympathiques."},{"sentence":"¿Cuántos hijos tienes?","translation":"Combien d''enfants as-tu ?"}]'::jsonb, 10, true, 2 from public.modules where code = 'es-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Maria a un frère. Comment dit-on « son frère » (à Maria) ?","options":["su hermano","sus hermano","tu hermano"]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'SU/SUS s''utilise pour « à lui » et « à elle » : su hermano (de Maria).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"Ma sœur a dix ans."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["mi hermana tiene diez años","mi hermana tiene 10 años"]}'::jsonb, '[]'::jsonb, 'TENER pour l''âge : « mi hermana tiene diez años ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Este es mi padre. ___ nombre es Paul. Tengo dos ___ .","translation":"Voici mon père. Il s''appelle Paul. J''ai deux sœurs."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["su","hermanas"]}'::jsonb, '[]'::jsonb, '« su nombre » (nom à lui) ; hermanas au pluriel.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque membre de la famille.","pairs":[{"left":"el padre","right":"le père"},{"left":"la hija","right":"la fille"},{"left":"la esposa","right":"l''épouse"},{"left":"los hijos","right":"les enfants"}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, '« La hija » = la fille-enfant ; « la esposa » = l''épouse.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["hermano","Este","mi","es","."],"translation":"Este es mi hermano."}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,2,0,4]}'::jsonb, '[]'::jsonb, '« Este es + mi + famille » pour présenter quelqu''un.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"La familia de Leo","passage":"Este es Leo. Su padre es médico y su madre es enfermera. Tiene una hermana, Mia. Ella es estudiante. Los abuelos de Leo viven en Roma.","questions":[{"q":"Que fait le père de Leo ?","options":["Enfermera","Médico","Profesor"]},{"q":"Comment s''appelle la sœur de Leo ?","options":["Mia","Roma","Nina"]},{"q":"Où vivent les grands-parents ?","options":["En Roma","En París","En Madrid"]}]}'::jsonb, 10, true from public.lessons where code = 'es-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,0,0]}'::jsonb, '[]'::jsonb, 'Relis : « su padre es médico », « una hermana, Mia », « viven en Roma ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a1-m3-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'es-a2', 'Espagnol A2 — Conversaciones diarias', 'Raconter au passé et parler de ses projets.', 'A2'::public.cefr_level, true, 2 from public.languages where code = 'es' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'es-a2-m1', 'Contar y planificar', '', 1 from public.courses where code = 'es-a2' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a2-m1-l1', 'Le passé composé (pretérito perfecto)', 'Raconter ce que tu as fait hier ou récemment.', 'Pretérito perfecto = **he / has / ha / hemos / habéis / han** + participe passé.

Participes réguliers : hablar → **hablado**, comer → **comido**, vivir → **vivido**.

Irréguliers : hacer → **hecho**, ver → **visto**, decir → **dicho**, escribir → **escrito**.

Marqueurs : **hoy**, **esta semana**, **ya** (déjà), **todavía no** (pas encore).', '[{"term":"hoy","translation":"aujourd''hui","phonetic":"[oj]","example":"Hoy he trabajado mucho.","example_tr":"Aujourd''hui, j''ai beaucoup travaillé."},{"term":"he visto","translation":"j''ai vu","phonetic":"[e ''βisto]","example":"He visto una buena película.","example_tr":"J''ai vu un bon film."},{"term":"he hecho","translation":"j''ai fait","phonetic":"[e ''etʃo]","example":"He hecho mis deberes.","example_tr":"J''ai fait mes devoirs."},{"term":"hemos ido","translation":"nous sommes allé(e)s","phonetic":"[''emos ''iðo]","example":"Hemos ido a la playa.","example_tr":"Nous sommes allés à la plage."},{"term":"ya","translation":"déjà","phonetic":"[ja]","example":"Ya he comido.","example_tr":"J''ai déjà mangé."},{"term":"todavía no","translation":"pas encore","phonetic":"[toða''βja no]","example":"Todavía no he visto el final.","example_tr":"Je n''ai pas encore vu la fin."},{"term":"esta semana","translation":"cette semaine","phonetic":"[''esta se''mana]","example":"Esta semana he leído dos libros.","example_tr":"Cette semaine, j''ai lu deux livres."},{"term":"ayer","translation":"hier","phonetic":"[a''jeɾ]","example":"Ayer compré pan.","example_tr":"Hier, j''ai acheté du pain."}]'::jsonb, '[{"sentence":"Hoy he visitado a mi abuela.","translation":"Aujourd''hui, j''ai rendu visite à ma grand-mère."},{"sentence":"¿Has visto la película? — ¡Sí, ya la he visto!","translation":"Tu as vu le film ? — Oui, je l''ai déjà vu !"},{"sentence":"No hemos salido porque ha llovido.","translation":"Nous ne sommes pas sortis parce qu''il a plu."}]'::jsonb, 10, true, 1 from public.modules where code = 'es-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Hoy ___ al cine. »","options":["voy ido","he ido","he yendo"]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'IR a un participe irrégulier : ido. Pretérito perfecto : he ido.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"J''ai acheté du pain hier."}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["he comprado pan ayer","ayer he comprado pan","ayer compré pan"]}'::jsonb, '[]'::jsonb, 'comprar → he comprado. Avec « ayer », l''espagnol accepte aussi le passé simple (compré).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"¿___ visto el partido? — No, no ___ visto.","translation":"As-tu vu le match ? — Non."}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["has","he"]}'::jsonb, '[]'::jsonb, '¿Has visto…? (tu as vu ?) — No, no he visto (je n''ai pas vu).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque infinitif à son participe.","pairs":[{"left":"hacer","right":"hecho"},{"left":"ver","right":"visto"},{"left":"comer","right":"comido"},{"left":"hablar","right":"hablado"}]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Deux irréguliers (hecho, visto) et deux réguliers (comido, hablado).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["película","He","una","visto","."],"translation":"He visto una película."}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,2,0,4]}'::jsonb, '[]'::jsonb, 'Ordre : he + visto + une + película.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"El fin de semana de Emma","passage":"El sábado, Emma ha ido al mercado con su padre. Han comprado fruta y queso. Por la tarde, ha jugado al tenis con sus amigos. Se han divertido mucho, pero no ha cocinado la cena — ¡su madre lo ha hecho!","questions":[{"q":"Où est allée Emma ?","options":["Al mercado","Al cine","A la escuela"]},{"q":"Qu''ont-ils acheté ?","options":["Zapatos","Fruta y queso","Libros"]},{"q":"Qui a préparé le dîner ?","options":["Emma","Sus amigos","Su madre"]}]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « ha ido al mercado », « han comprado fruta y queso », « su madre lo ha hecho ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'es-a2-m1-l2', 'Parler de ses projets', 'Exprimer un projet avec ir a + infinitif et querer.', 'Projet futur : **ir a + infinitif** — **Voy a viajar este verano.** — **Ella va a estudiar medicina.**

Négation : **No voy a trabajar el domingo.** — Question : **¿Vas a ver el partido?**

Vouloir : **Quiero aprender inglés.** — **Quiere comprar un coche.**

Invitation : **¿Quieres venir?** — réponse : **¡Con gusto!** ou **¡Me encantaría!**', '[{"term":"voy a…","translation":"je vais…","phonetic":"[boj a]","example":"Voy a visitar Perú.","example_tr":"Je vais visiter le Pérou."},{"term":"el mes que viene","translation":"le mois prochain","phonetic":"[el mes ke ''βjene]","example":"Empezamos el mes que viene.","example_tr":"On commence le mois prochain."},{"term":"quiero…","translation":"je veux…","phonetic":"[''kjeɾo]","example":"Quiero hablar mejor.","example_tr":"Je veux mieux parler."},{"term":"el plan","translation":"le projet","phonetic":"[el plan]","example":"Mi plan es simple.","example_tr":"Mon projet est simple."},{"term":"¿quieres venir?","translation":"veux-tu venir ?","phonetic":"[''kjeɾes βe''niɾ]","example":"¿Quieres venir con nosotros?","example_tr":"Veux-tu venir avec nous ?"},{"term":"¡con gusto!","translation":"avec plaisir !","phonetic":"[kon ''gusto]","example":"¡Con gusto, voy!","example_tr":"Avec plaisir, j''y vais !"},{"term":"quizás","translation":"peut-être","phonetic":"[ki''sas]","example":"Quizás el año que viene.","example_tr":"Peut-être l''année prochaine."},{"term":"porque","translation":"parce que","phonetic":"[''poɾke]","example":"Me quedo porque estoy cansado.","example_tr":"Je reste parce que je suis fatigué."}]'::jsonb, '[{"sentence":"Voy a aprender español el mes que viene.","translation":"Je vais apprendre l''espagnol le mois prochain."},{"sentence":"¿Vas a ver el partido esta noche?","translation":"Tu vas regarder le match ce soir ?"},{"sentence":"Quiere trabajar en Canadá.","translation":"Elle veut travailler au Canada."}]'::jsonb, 10, true, 2 from public.modules where code = 'es-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Ella ___ a estudiar esta noche. »","options":["va","vas","van"]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'ir a : voy, vas, VA, vamos, vais, van → ella va a estudiar.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en espagnol :","source":"Je vais visiter l''Italie cet été."}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["voy a visitar italia este verano","voy a visitar a italia este verano"]}'::jsonb, '[]'::jsonb, 'Voy a + infinitif : voy a visitar. « este verano » = cet été.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ aprender inglés ___ es útil.","translation":"Je veux apprendre l''anglais parce que c''est utile."}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["quiero","porque"]}'::jsonb, '[]'::jsonb, 'Quiero + infinitif directement : « quiero aprender ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression à sa traduction.","pairs":[{"left":"el mes que viene","right":"le mois prochain"},{"left":"¡con gusto!","right":"avec plaisir !"},{"left":"quizás","right":"peut-être"},{"left":"porque","right":"parce que"}]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces petits mots rendent tes conversations naturelles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["a","¿Vas","viajar","?"],"translation":"¿Vas a viajar ?"}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, '¿Vas a + infinitif ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Voy a visitar a mi abuela el mes que viene.","question":"Écoute : que va faire la personne ?","options":["Voyager en Italie","Rendre visite à sa grand-mère","Acheter une voiture"]}'::jsonb, 10, true from public.lessons where code = 'es-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Visitar a mi abuela » = rendre visite à ma grand-mère.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'es-a2-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'de-a1', 'Allemand A1 — Premiers pas', 'Les bases : saluer, se présenter, compter, le quotidien.', 'A1'::public.cefr_level, true, 1 from public.languages where code = 'de' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'de-a1-m1', 'Erste Kontakte', '', 1 from public.courses where code = 'de-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m1-l1', 'Saluer', 'Saluer à différents moments de la journée et demander des nouvelles.', 'Toute la journée : **Hallo** (familier) ou **Guten Tag** (standard). Le matin : **Guten Morgen**. Le soir : **Guten Abend**. Avant de dormir : **Gute Nacht**.

Nouvelles : **Wie geht''s?** (familier) ou **Wie geht es dir?** — réponse : **Gut, danke!**

Au revoir : **Auf Wiedersehen** (formel), **Tschüss** (familier), **Bis bald** (à bientôt).', '[{"term":"hallo","translation":"bonjour / salut","phonetic":"[ˈhalo]","example":"Hallo, Tom!","example_tr":"Salut, Tom !"},{"term":"guten Morgen","translation":"bonjour (le matin)","phonetic":"[''guːtn ''mɔʁgn̩]","example":"Guten Morgen, Frau Schmidt.","example_tr":"Bonjour, Mme Schmidt."},{"term":"guten Tag","translation":"bonjour (la journée)","phonetic":"[''guːtn̩ taːk]","example":"Guten Tag, alle zusammen.","example_tr":"Bonjour à tous."},{"term":"gute Nacht","translation":"bonne nuit","phonetic":"[''guːtə naxt]","example":"Gute Nacht, Mama!","example_tr":"Bonne nuit, maman !"},{"term":"tschüss","translation":"salut (au revoir, familier)","phonetic":"[tʃʏs]","example":"Tschüss, bis bald!","example_tr":"Salut, à bientôt !"},{"term":"auf Wiedersehen","translation":"au revoir (formel)","phonetic":"[aʊf ''viːdɐzeːən]","example":"Auf Wiedersehen, Herr Braun.","example_tr":"Au revoir, M. Braun."},{"term":"wie geht''s?","translation":"comment vas-tu ?","phonetic":"[viː ˈɡeːts]","example":"Hallo, wie geht''s?","example_tr":"Salut, comment vas-tu ?"},{"term":"gut, danke","translation":"bien, merci","phonetic":"[guːt ''daŋkə]","example":"Gut, danke. Und dir?","example_tr":"Bien, merci. Et toi ?"}]'::jsonb, '[{"sentence":"Hallo! Wie geht es dir?","translation":"Salut ! Comment vas-tu ?"},{"sentence":"Guten Morgen, Lehrer. Gut, danke.","translation":"Bonjour, professeur. Bien, merci."},{"sentence":"Gute Nacht, schlaf gut!","translation":"Bonne nuit, dors bien !"}]'::jsonb, 10, true, 1 from public.modules where code = 'de-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Tu croises ton professeur à 8 h du matin. Que dis-tu ?","options":["Gute Nacht!","Guten Morgen!","Guten Abend!"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Guten Morgen » s''utilise le matin ; « Gute Nacht » uniquement avant de dormir.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"Salut, comment vas-tu ?"}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["hallo wie geht''s","hallo, wie geht''s","hallo wie geht es dir"]}'::jsonb, '[]'::jsonb, '« Hallo » + « wie geht''s? » est la formule familière courante.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Wie ___ es dir? — Gut, ___ .","translation":"Comment vas-tu ? — Bien, merci."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["geht","danke"]}'::jsonb, '[]'::jsonb, '« Wie geht es dir? » ; réponse : « gut, danke ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque salutation à son moment.","pairs":[{"left":"guten Morgen","right":"le matin"},{"left":"guten Tag","right":"la journée"},{"left":"guten Abend","right":"le soir"},{"left":"gute Nacht","right":"avant de dormir"}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'L''allemand distingue précisément les moments de la journée.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets les mots en ordre :","words":["es","Wie","dir","geht","?"],"translation":"Wie geht es dir ?"}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,0,2,4]}'::jsonb, '[]'::jsonb, 'Ordre : Wie + geht + es + dir ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Guten Abend zusammen. Auf Wiedersehen!","question":"Écoute puis choisis la traduction.","options":["Bonsoir à tous. Au revoir !","Bonne nuit à tous. À demain !","Bonjour à tous. Merci !"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Guten Abend » = bonsoir ; « auf Wiedersehen » = au revoir (formel).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m1-l2', 'Se présenter', 'Donner son nom, son origine, son âge et poser ces questions.', 'Nom : **Ich heiße Pedro.** ou **Ich bin Pedro.** — question : **Wie heißt du?**

Origine : **Ich komme aus Spanien.** — question : **Woher kommst du?**

Âge : **Ich bin 20 Jahre alt.** (⚠️ avec SEIN, contrairement au français).

Métier : **Ich bin Student.** (pas d''article) — politesse : **bitte**, **danke**.', '[{"term":"ich heiße…","translation":"je m''appelle…","phonetic":"[ɪç ''haɪsə]","example":"Ich heiße Pedro.","example_tr":"Je m''appelle Pedro."},{"term":"wie heißt du?","translation":"comment tu t''appelles ?","phonetic":"[viː haɪst duː]","example":"Wie heißt du? — Anna.","example_tr":"Comment tu t''appelles ? — Anna."},{"term":"ich komme aus…","translation":"je viens de…","phonetic":"[ɪç ''kɔmə aʊs]","example":"Ich komme aus Brasilien.","example_tr":"Je viens du Brésil."},{"term":"ich bin … Jahre alt","translation":"j''ai … ans","phonetic":"[ɪç bɪn jaːʁə alt]","example":"Ich bin fünfzehn Jahre alt.","example_tr":"J''ai quinze ans."},{"term":"der Student / die Studentin","translation":"étudiant / étudiante","phonetic":"[ʃtuˈdɛnt]","example":"Ich bin Student.","example_tr":"Je suis étudiant."},{"term":"freut mich","translation":"enchanté","phonetic":"[fʁɔʏt mɪç]","example":"Freut mich, Anna!","example_tr":"Enchanté, Anna !"},{"term":"bitte","translation":"s''il vous plaît","phonetic":"[''bɪtə]","example":"Wiederholen Sie bitte.","example_tr":"Répétez, s''il vous plaît."},{"term":"danke schön","translation":"merci beaucoup","phonetic":"[''daŋkə ʃøːn]","example":"Danke schön!","example_tr":"Merci beaucoup !"}]'::jsonb, '[{"sentence":"Hallo, ich heiße Karl und komme aus Deutschland.","translation":"Salut, je m''appelle Karl et je viens d''Allemagne."},{"sentence":"Wie heißt du? — Ich heiße Sofia.","translation":"Comment tu t''appelles ? — Je m''appelle Sofia."},{"sentence":"Ich bin neunzehn und bin Student.","translation":"J''ai dix-neuf ans et je suis étudiant."}]'::jsonb, 10, true, 2 from public.modules where code = 'de-a1-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Quelle phrase est correcte pour donner son âge ?","options":["Ich habe 20 Jahre.","Ich bin 20 Jahre alt.","Ich mache 20 Jahre."]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'En allemand : « Ich bin … Jahre alt » avec SEIN.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"Je viens du Brésil."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["ich komme aus brasilien"]}'::jsonb, '[]'::jsonb, '« Ich komme aus + pays » — les pays sont avec majuscule : Brasilien.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Ich ___ Ana. Ich ___ aus Portugal.","translation":"Je m''appelle Ana. Je viens du Portugal."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["heiße","komme"]}'::jsonb, '[]'::jsonb, '« ich heiße » pour le nom ; « ich komme aus » pour l''origine.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque question à sa réponse.","pairs":[{"left":"Wie heißt du?","right":"Ich heiße Marco."},{"left":"Woher kommst du?","right":"Ich komme aus Italien."},{"left":"Wie alt bist du?","right":"Ich bin achtzehn."},{"left":"Wie geht''s?","right":"Gut, danke."}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Nom, origine, âge, état : les quatre questions essentielles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["heiße","Ich","Lia","."],"translation":"Ich heiße Lia."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, '« Ich heiße + prénom » — le verbe est en 2e position.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Ein neuer Mitschüler","passage":"Hallo! Ich heiße Tom und komme aus Kanada. Ich bin neunzehn Jahre alt. Ich bin Student. Meine Lehrerin heißt Frau Grün. Sie ist sehr nett.","questions":[{"q":"D''où vient Tom ?","options":["Aus den USA","Aus Kanada","Aus Australien"]},{"q":"Quel âge a Tom ?","options":["Neun","Neunzig","Neunzehn"]},{"q":"Qui est Frau Grün ?","options":["Sa mère","Son professeure","Sa sœur"]}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,2,1]}'::jsonb, '[]'::jsonb, 'Relis : « komme aus Kanada », « neunzehn Jahre alt », « Meine Lehrerin heißt Frau Grün ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'de-a1-m2', 'Der Alltag', '', 2 from public.courses where code = 'de-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m2-l1', 'Les nombres 1 à 20', 'Compter de 1 à 20 et donner un numéro de téléphone.', '1 eins, 2 zwei, 3 drei, 4 vier, 5 fünf, 6 sechs, 7 sieben, 8 acht, 9 neun, 10 zehn, 11 elf, 12 zwölf, 13 dreizehn, 14 vierzehn, 15 fünfzehn, 16 sechzehn (⚠️ sans -s !), 17 siebzehn (⚠️ sans -en !), 18 achtzehn, 19 neunzehn, 20 zwanzig.

Pour un téléphone : « null, sechs, fünf, fünf… ».', '[{"term":"eins / zwei / drei","translation":"un / deux / trois","phonetic":"[aɪn tsvaɪ dʁaɪ]","example":"Ich habe drei Katzen.","example_tr":"J''ai trois chats."},{"term":"vier / fünf / sechs","translation":"quatre / cinq / six","phonetic":"[fiːɐ fʏnf zɛks]","example":"Fünf Äpfel, bitte.","example_tr":"Cinq pommes, s''il vous plaît."},{"term":"sieben / acht / neun","translation":"sept / huit / neuf","phonetic":"[''ziːbn̩ axt nɔʏn]","example":"Neun Studenten hier.","example_tr":"Neuf élèves ici."},{"term":"elf / zwölf","translation":"onze / douze","phonetic":"[ɛlf tsvœlf]","example":"Zwölf Monate im Jahr.","example_tr":"Douze mois par an."},{"term":"fünfzehn","translation":"quinze","phonetic":"[''fʏnftseːn]","example":"Sie ist fünfzehn.","example_tr":"Elle a quinze ans."},{"term":"zwanzig","translation":"vingt","phonetic":"[''tsvantsɪç]","example":"Zwanzig Euro, bitte.","example_tr":"Vingt euros, s''il vous plaît."},{"term":"wie viele?","translation":"combien ?","phonetic":"[viː ''fiːlə]","example":"Wie viele Bücher hast du?","example_tr":"Combien de livres as-tu ?"},{"term":"die Telefonnummer","translation":"le numéro de téléphone","phonetic":"[teːle''foːnnumɐ]","example":"Wie ist deine Nummer?","example_tr":"Quel est ton numéro ?"}]'::jsonb, '[{"sentence":"Ich habe zwei Brüder und eine Schwester.","translation":"J''ai deux frères et une sœur."},{"sentence":"Wie viele Tage? — Sieben!","translation":"Combien de jours ? — Sept !"},{"sentence":"Meine Nummer ist null-sechs-fünf-fünf.","translation":"Mon numéro est le 06 55."}]'::jsonb, 10, true, 1 from public.modules where code = 'de-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Comment dit-on « 15 » ?","options":["Fünfzig","Fünfzehn","Fünf"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '15 = fünfzehn ; 50 = fünfzig ; 5 = fünf.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Écris le nombre en allemand (en toutes lettres) :","source":"13"}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["dreizehn"]}'::jsonb, '[]'::jsonb, '13 = dreizehn (drei + zehn collés).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Wie ___ Studenten? — ___ , Herr Lehrer.","translation":"Combien d''élèves ? — Douze, monsieur."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["viele","zwölf"]}'::jsonb, '[]'::jsonb, '« Wie viele…? » demande une quantité.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque nombre en lettres à son chiffre.","pairs":[{"left":"drei","right":"3"},{"left":"acht","right":"8"},{"left":"elf","right":"11"},{"left":"zwanzig","right":"20"}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, '1 à 12 ont un nom unique ; de 13 à 19 : -zehn ; attention à sechzehn et siebzehn.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["deine","Wie","Nummer","ist","?"],"translation":"Wie ist deine Nummer ?"}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,0,2,4]}'::jsonb, '[]'::jsonb, 'Ordre : Wie + ist + deine + Nummer ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Ich habe sieben Äpfel und zwei Bananen.","question":"Écoute puis réponds : combien de pommes ?","options":["Sieben","Elf","Drei"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Sieben Äpfel » = sept pommes.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m2-l2', 'Jours et heures', 'Dire les jours de la semaine et donner l''heure.', 'Jours : Montag, Dienstag, Mittwoch, Donnerstag, Freitag, Samstag, Sonntag (MAJUSCULE en allemand).

L''heure : **Wie spät ist es?** — **Es ist drei Uhr.** (3 h) — **Es ist halb vier.** (⚠️ 3 h 30, PAS 4 h 30 ! « halb » vise l''heure qui vient) — **Es ist Viertel nach drei.** (3 h 15) — **Es ist Viertel vor vier.** (3 h 45).

Prépositions : **am Montag** (jour), **um drei Uhr** (heure), **morgens / abends**.', '[{"term":"der Montag","translation":"lundi","phonetic":"[ˈmoːntaːk]","example":"Am Montag arbeite ich.","example_tr":"Lundi, je travaille."},{"term":"der Mittwoch","translation":"mercredi","phonetic":"[ˈmɪtvɔx]","example":"Wir treffen uns am Mittwoch.","example_tr":"On se voit mercredi."},{"term":"der Samstag","translation":"samedi","phonetic":"[''zamstag]","example":"Samstag ist mein Lieblingstag.","example_tr":"Samedi est mon jour préféré."},{"term":"wie spät ist es?","translation":"quelle heure est-il ?","phonetic":"[viː ʃpɛːt ɪst ɛs]","example":"Wie spät ist es? — Es ist fünf Uhr.","example_tr":"Quelle heure est-il ? — Cinq heures."},{"term":"halb vier","translation":"3 h 30 (⚠️ demi vers 4 h)","phonetic":"[halb fiːɐ]","example":"Es ist halb vier.","example_tr":"Il est trois heures et demie."},{"term":"Viertel vor","translation":"moins le quart","phonetic":"[''fɪʁtl̩ fɔːɐ]","example":"Es ist Viertel vor neun.","example_tr":"Il est neuf heures moins le quart."},{"term":"heute / morgen","translation":"aujourd''hui / demain","phonetic":"[''hɔʏtə ''mɔʁgn̩]","example":"Morgen ist Sonntag.","example_tr":"Demain, c''est dimanche."},{"term":"um … Uhr","translation":"à … heures","phonetic":"[ʊm ʔuːɐ]","example":"Der Kurs beginnt um sechs Uhr.","example_tr":"Le cours commence à six heures."}]'::jsonb, '[{"sentence":"Es ist halb acht. Ich bin spät!","translation":"Il est sept heures et demie. Je suis en retard !"},{"sentence":"Am Mittwoch spiele ich um vier Uhr Fußball.","translation":"Mercredi, je joue au football à quatre heures."},{"sentence":"Wie spät ist es? — Es ist Viertel nach zehn.","translation":"Quelle heure est-il ? — Dix heures et quart."}]'::jsonb, 10, true, 2 from public.modules where code = 'de-a1-m2' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"« Es ist halb sechs » signifie :","options":["6 h 30","5 h 30","6 h 15"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '⚠️ Piège classique : « halb sechs » = la moitié EN ROUTE vers six = 5 h 30 !' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"Il est trois heures et demie."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["es ist halb vier"]}'::jsonb, '[]'::jsonb, '3 h 30 = « halb VIER » en allemand (on regarde l''heure qui vient).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Der Kurs ist ___ Montag ___ neun Uhr.","translation":"Le cours est lundi à neuf heures."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["am","um"]}'::jsonb, '[]'::jsonb, 'am + jour, um + heure : deux prépositions essentielles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque jour allemand à sa traduction.","pairs":[{"left":"Montag","right":"lundi"},{"left":"Mittwoch","right":"mercredi"},{"left":"Freitag","right":"vendredi"},{"left":"Sonntag","right":"dimanche"}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Les noms de jours allemands prennent toujours une majuscule.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["spät","Wie","es","ist","?"],"translation":"Wie spät ist es ?"}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,3,2,4]}'::jsonb, '[]'::jsonb, '« Wie spät ist es? » : question figée.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Mein Stundenplan","passage":"Am Montag habe ich um neun Uhr Englisch. Am Mittwoch spiele ich um halb fünf Tennis. Am Samstag arbeite ich nicht. Ich liebe den Samstag!","questions":[{"q":"Quand a-t-il cours d''anglais ?","options":["Lundi à 9 h","Mercredi à 9 h","Samedi à 9 h"]},{"q":"À quelle heure joue-t-il au tennis ?","options":["4 h 15","4 h 30","4 h 45"]},{"q":"Que fait-il samedi ?","options":["Il travaille","Il a un cours","Il ne travaille pas"]}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m2-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « um neun Uhr », « um halb fünf » (= 4 h 30), « arbeite ich nicht ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m2-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'de-a1-m3', 'Zusammen leben', '', 3 from public.courses where code = 'de-a1' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m3-l1', 'La nourriture', 'Commander un repas et dire ce qu''on aime.', 'Aimer : **Ich mag Käse.** ou **Ich esse gern Käse.** Négation : **Ich mag keinen Fisch.** — question : **Magst du Kaffee?**

Commander : **Ich möchte einen Kaffee, bitte.** (möchte = je voudrais, plus poli que « will ») — **Die Rechnung, bitte!**

Accusatif : le masculin prend **einen/ein/einen** : **Ich möchte einen Tee.**', '[{"term":"das Brot","translation":"le pain","phonetic":"[das bʁoːt]","example":"Ich kaufe jeden Tag Brot.","example_tr":"J''achète du pain chaque jour."},{"term":"der Käse","translation":"le fromage","phonetic":"[deːɐ̯ ''kɛːzə]","example":"Französischer Käse ist berühmt.","example_tr":"Le fromage français est célèbre."},{"term":"der Apfel","translation":"la pomme","phonetic":"[deːɐ̯ ''apfl̩]","example":"Ein Apfel am Tag!","example_tr":"Une pomme par jour !"},{"term":"das Wasser","translation":"l''eau","phonetic":"[das ''vasɐ]","example":"Ein Glas Wasser, bitte.","example_tr":"Un verre d''eau, s''il vous plaît."},{"term":"das Frühstück","translation":"le petit-déjeuner","phonetic":"[ˈfʁʏʃtʏk]","example":"Ich frühstücke um sieben.","example_tr":"Je prends mon petit-déjeuner à sept heures."},{"term":"ich möchte…","translation":"je voudrais…","phonetic":"[ɪç ''mœçtə]","example":"Ich möchte einen Tee, bitte.","example_tr":"Je voudrais un thé, s''il vous plaît."},{"term":"die Rechnung","translation":"l''addition","phonetic":"[diː ''ʁɛxnʊŋ]","example":"Die Rechnung, bitte!","example_tr":"L''addition, s''il vous plaît !"},{"term":"lecker","translation":"délicieux","phonetic":"[''lɛkɐ]","example":"Diese Suppe ist lecker!","example_tr":"Cette soupe est délicieuse !"}]'::jsonb, '[{"sentence":"Ich mag Kaffee, aber ich mag keinen Tee.","translation":"J''aime le café mais je n''aime pas le thé."},{"sentence":"Ich möchte ein Käsebrot, bitte.","translation":"Je voudrais un sandwich au fromage, s''il vous plaît."},{"sentence":"Magst du Äpfel? — Ja, sehr!","translation":"Tu aimes les pommes ? — Oui, beaucoup !"}]'::jsonb, 10, true, 1 from public.modules where code = 'de-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"La formule la plus polie pour commander :","options":["Ich will einen Kaffee.","Gib mir einen Kaffee.","Ich möchte einen Kaffee, bitte."]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":2}'::jsonb, '[]'::jsonb, '« Ich möchte…, bitte » est la formule standard et polie.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"J''aime le fromage."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["ich mag käse","ich esse gern käse"]}'::jsonb, '[]'::jsonb, '« Ich mag + nom » (sans article) ou « Ich esse gern… ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ du Fisch? — Nein, ich mag ___ Fisch.","translation":"Aimes-tu le poisson ? — Non."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["Magst","keinen"]}'::jsonb, '[]'::jsonb, 'Question : Magst du…? Négation avec kein au masculin accusatif : keinen.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque mot à sa traduction.","pairs":[{"left":"das Brot","right":"le pain"},{"left":"das Wasser","right":"l''eau"},{"left":"das Frühstück","right":"le petit-déjeuner"},{"left":"die Rechnung","right":"l''addition"}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Quatre mots essentiels au restaurant allemand.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la commande en ordre :","words":["einen","möchte","bitte","Ich","Tee",","],"translation":"Ich möchte einen Tee, bitte."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[3,1,0,4,5,2]}'::jsonb, '[]'::jsonb, 'Ordre : Ich + möchte + einen + Tee + , + bitte.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Ich möchte ein Käsebrot und ein Glas Wasser, bitte.","question":"Écoute la commande : que veut la personne ?","options":["Un sandwich au fromage et de l''eau","Un thé et du pain","Une pomme et du fromage"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, '« Käsebrot + Glas Wasser » — repère les mots-clés.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a1-m3-l2', 'La famille', 'Présenter sa famille avec les possessifs mein/dein/sein/ihr.', 'Membres : der **Vater**, die **Mutter**, der **Bruder**, die **Schwester**, der **Sohn**, die **Tochter**, der **Mann**, die **Frau**.

Possessifs : **mein** (mon), **dein** (ton), **sein** (son à LUI), **ihr** (son à ELLE). ⚠️ Comme en anglais : sein/ihr dépendent du PROPRIÉTAIRE.

Terminaison selon le genre : **mein Vater** (masc.), **meine Mutter** (fém.), **meine Geschwister** (pluriel).', '[{"term":"der Vater / die Mutter","translation":"le père / la mère","phonetic":"[deːɐ̯ ''faːtɐ diː ''mʊtɐ]","example":"Mein Vater ist groß.","example_tr":"Mon père est grand."},{"term":"der Bruder / die Schwester","translation":"le frère / la sœur","phonetic":"[ˈbʁuːdɐ ˈʃvɛstɐ]","example":"Ich habe zwei Schwestern.","example_tr":"J''ai deux sœurs."},{"term":"der Sohn / die Tochter","translation":"le fils / la fille","phonetic":"[zoːn ''tɔxtɐ]","example":"Ihre Tochter ist sechs.","example_tr":"Leur fille a six ans."},{"term":"sein / ihr","translation":"son, sa (à lui) / (à elle)","phonetic":"[zaɪn iːɐ̯]","example":"Sein Auto ist rot.","example_tr":"Sa voiture (à lui) est rouge."},{"term":"verheiratet","translation":"marié(e)","phonetic":"[fɛɐ̯''haɪʁaːtət]","example":"Sie sind verheiratet.","example_tr":"Ils sont mariés."},{"term":"die Kinder","translation":"les enfants","phonetic":"[diː ''kɪndɐ]","example":"Wir haben drei Kinder.","example_tr":"Nous avons trois enfants."},{"term":"die Familie","translation":"la famille","phonetic":"[fa''miːliə]","example":"Ich liebe meine Familie.","example_tr":"J''aime ma famille."},{"term":"die Großeltern","translation":"les grands-parents","phonetic":"[ˈɡʁoːsʔɛltɐn]","example":"Meine Großeltern wohnen in Rom.","example_tr":"Mes grands-parents habitent à Rome."}]'::jsonb, '[{"sentence":"Das ist meine Mutter. Sie heißt Carla.","translation":"Voici ma mère. Elle s''appelle Carla."},{"sentence":"Mein Bruder ist Lehrer. Seine Schüler sind nett.","translation":"Mon frère est professeur. Ses élèves sont gentils."},{"sentence":"Wie viele Kinder hast du?","translation":"Combien d''enfants as-tu ?"}]'::jsonb, 10, true, 2 from public.modules where code = 'de-a1-m3' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Maria a un frère. Comment dit-on « son frère » (à Maria) ?","options":["sein Bruder","ihr Bruder","dein Bruder"]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'Maria = elle → ihr Bruder. « Sein » = à lui.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"Ma sœur a dix ans."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["meine schwester ist zehn jahre alt","meine schwester ist zehn"]}'::jsonb, '[]'::jsonb, 'Avec SEIN : « meine Schwester ist zehn Jahre alt ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Das ist mein Vater. ___ Name ist Paul. Ich habe zwei ___ .","translation":"Voici mon père. Il s''appelle Paul. J''ai deux sœurs."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["sein","Schwestern"]}'::jsonb, '[]'::jsonb, '« sein Name » (le père = à lui) ; Schwestern au pluriel.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque membre de la famille.","pairs":[{"left":"der Vater","right":"le père"},{"left":"die Tochter","right":"la fille"},{"left":"die Frau","right":"l''épouse"},{"left":"die Kinder","right":"les enfants"}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, '« die Tochter » = la fille-enfant ; « die Frau » = la femme/l''épouse.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["ist","Das","mein","Bruder","."],"translation":"Das ist mein Bruder."}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3,4]}'::jsonb, '[]'::jsonb, '« Das ist + mein/meine + famille ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Leos Familie","passage":"Das ist Leo. Sein Vater ist Arzt und seine Mutter ist Krankenschwester. Er hat eine Schwester, Mia. Sie ist Studentin. Leos Großeltern wohnen in Rom.","questions":[{"q":"Que fait le père de Leo ?","options":["Krankenschwester","Arzt","Lehrer"]},{"q":"Comment s''appelle la sœur de Leo ?","options":["Mia","Rom","Nina"]},{"q":"Où habitent les grands-parents ?","options":["In Rom","In Paris","In Madrid"]}]}'::jsonb, 10, true from public.lessons where code = 'de-a1-m3-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[1,0,0]}'::jsonb, '[]'::jsonb, 'Relis : « Sein Vater ist Arzt », « eine Schwester, Mia », « wohnen in Rom ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a1-m3-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.courses (language_id, code, title, description, cefr_level, is_published, sort_order) select id, 'de-a2', 'Allemand A2 — Alltagsgespräche', 'Raconter au passé (Perfekt) et parler de ses projets.', 'A2'::public.cefr_level, true, 2 from public.languages where code = 'de' on conflict (code) do update set title = excluded.title, description = excluded.description, cefr_level = excluded.cefr_level, is_published = true, sort_order = excluded.sort_order;
insert into public.modules (course_id, code, title, description, sort_order) select id, 'de-a2-m1', 'Erzählen und planen', '', 1 from public.courses where code = 'de-a2' on conflict (code) do update set title = excluded.title, description = excluded.description, sort_order = excluded.sort_order;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a2-m1-l1', 'Le passé composé (Perfekt)', 'Raconter ce que tu as fait hier ou la semaine dernière.', 'Le Perfekt = **haben/sein** (présent) + **participe passé** en fin de phrase.

Participes réguliers : gemacht, gekauft, gespielt, gearbeitet (ge- … -t).

Irréguliers : gehen → **gegangen** (sein!), sehen → **gesehen**, essen → **gegessen**, haben → **gehabt**.

⚠️ Verbes de déplacement avec **sein** : ich bin gegangen, gefahren, geflogen.

Marqueurs : **gestern**, **letzte Woche**, **vor zwei Jahren**.', '[{"term":"gestern","translation":"hier","phonetic":"[''gɛstɐn]","example":"Gestern habe ich gearbeitet.","example_tr":"Hier, j''ai travaillé."},{"term":"letzte Woche","translation":"la semaine dernière","phonetic":"[''lɛtsə ''vɔxə]","example":"Letzte Woche sind wir ans Meer gefahren.","example_tr":"La semaine dernière, nous sommes allés à la mer."},{"term":"ich habe gesehen","translation":"j''ai vu","phonetic":"[ɪç ''haːbə gə''zeːən]","example":"Ich habe einen guten Film gesehen.","example_tr":"J''ai vu un bon film."},{"term":"ich habe gemacht","translation":"j''ai fait","phonetic":"[ɪç ''haːbə gə''maxt]","example":"Ich habe meine Hausaufgaben gemacht.","example_tr":"J''ai fait mes devoirs."},{"term":"ich bin gegangen","translation":"je suis allé(e)","phonetic":"[ɪç bɪn gə''gaŋən]","example":"Ich bin ins Kino gegangen.","example_tr":"Je suis allé au cinéma."},{"term":"wir haben gehabt","translation":"nous avons eu","phonetic":"[viːɐ ''haːbn̩ gə''haːpt]","example":"Wir haben viel Spaß gehabt.","example_tr":"Nous avons eu beaucoup de plaisir."},{"term":"vor zwei Jahren","translation":"il y a deux ans","phonetic":"[foːɐ ''tsvaɪ ''jaːʁən]","example":"Vor zwei Jahren sind wir umgezogen.","example_tr":"Il y a deux ans, nous avons déménagé."},{"term":"nicht","translation":"pas (négation)","phonetic":"[nɪçt]","example":"Ich habe ihn nicht gesehen.","example_tr":"Je ne l''ai pas vu."}]'::jsonb, '[{"sentence":"Gestern habe ich meine Oma besucht.","translation":"Hier, j''ai rendu visite à ma grand-mère."},{"sentence":"Hast du den Film gesehen? — Ja, sicher!","translation":"Tu as vu le film ? — Oui, bien sûr !"},{"sentence":"Wir sind nicht ausgegangen, weil es geregnet hat.","translation":"Nous ne sommes pas sortis parce qu''il a plu."}]'::jsonb, 10, true, 1 from public.modules where code = 'de-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Gestern ___ ich ins Kino gegangen. »","options":["habe","bin","war"]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, 'gehen (déplacement) prend SEIN : « ich bin gegangen ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"J''ai acheté du pain hier."}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["ich habe gestern brot gekauft","gestern habe ich brot gekauft","ich habe brot gestern gekauft"]}'::jsonb, '[]'::jsonb, 'kaufen → gekauft avec haben + gestern peut se placer au début.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"___ du das Spiel ___ ? — Nein, ich habe es nicht ___ .","translation":"As-tu vu le match ? — Non."}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["Hast","gesehen","gesehen"]}'::jsonb, '[]'::jsonb, '« Hast du… gesehen? » ; réponse : « nein, ich habe es nicht gesehen ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque infinitif à son participe.","pairs":[{"left":"machen","right":"gemacht"},{"left":"sehen","right":"gesehen"},{"left":"essen","right":"gegessen"},{"left":"gehen","right":"gegangen"}]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'ge-…-t pour les réguliers ; ge-…-en pour les irréguliers.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la phrase en ordre :","words":["Film","Wir","gesehen","haben","einen","."],"translation":"Wir haben einen Film gesehen."}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,3,4,0,2,5]}'::jsonb, '[]'::jsonb, 'Ordre : sujet + haben + complément + PARTICIPE EN FIN.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reading'::public.exercise_type, 6, '{"title":"Emmas Wochenende","passage":"Am Samstag ist Emma mit ihrem Vater zum Markt gegangen. Sie haben Obst und Käse gekauft. Am Nachmittag hat sie mit ihren Freunden Tennis gespielt. Sie haben viel Spaß gehabt, aber das Abendessen hat ihre Mutter gemacht!","questions":[{"q":"Où est allée Emma ?","options":["Zum Markt","Zum Kino","Zur Schule"]},{"q":"Qu''ont-ils acheté ?","options":["Schuhe","Obst und Käse","Bücher"]},{"q":"Qui a préparé le dîner ?","options":["Emma","Ihre Freunde","Ihre Mutter"]}]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l1' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answers":[0,1,2]}'::jsonb, '[]'::jsonb, 'Relis : « zum Markt gegangen », « Obst und Käse gekauft », « ihre Mutter hat das Abendessen gemacht ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l1' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.lessons (module_id, code, title, objective, explanation, vocab, examples, estimated_minutes, is_published, sort_order) select id, 'de-a2-m1-l2', 'Parler de ses projets', 'Exprimer un projet avec werden, vorhaben et wollen.', 'Projet futur : **werden + infinitif en fin de phrase** — **Ich werde diesen Sommer reisen.** — **Sie wird Medizin studieren.**

Futur proche familier : **vorhaben** — **Was hast du vor?** (que prévois-tu ?) — **Ich habe vor, Deutsch zu lernen.**

Vouloir : **Ich will Englisch lernen.** — **Er will ein Auto kaufen.**

Invitation : **Möchtest du mitkommen?** — réponse : **Gerne!**', '[{"term":"ich werde…","translation":"je vais… (futur)","phonetic":"[ɪç ''veːɐdə]","example":"Ich werde Peru besuchen.","example_tr":"Je vais visiter le Pérou."},{"term":"nächsten Monat","translation":"le mois prochain","phonetic":"[''nɛçstn̩ ''moːnat]","example":"Wir fangen nächsten Monat an.","example_tr":"On commence le mois prochain."},{"term":"ich will…","translation":"je veux…","phonetic":"[ɪç vɪl]","example":"Ich will besser sprechen.","example_tr":"Je veux mieux parler."},{"term":"der Plan","translation":"le projet","phonetic":"[plaːn]","example":"Mein Plan ist einfach.","example_tr":"Mon projet est simple."},{"term":"möchtest du…?","translation":"aimerais-tu… ?","phonetic":"[''mœçtəst duː]","example":"Möchtest du mitkommen?","example_tr":"Veux-tu venir avec nous ?"},{"term":"gerne!","translation":"avec plaisir !","phonetic":"[''gɛʁnə]","example":"Gerne, ich komme!","example_tr":"Avec plaisir, je viens !"},{"term":"vielleicht","translation":"peut-être","phonetic":"[fi''laɪçt]","example":"Vielleicht nächstes Jahr.","example_tr":"Peut-être l''année prochaine."},{"term":"weil","translation":"parce que","phonetic":"[vaɪl]","example":"Ich bleibe, weil ich müde bin.","example_tr":"Je reste parce que je suis fatigué."}]'::jsonb, '[{"sentence":"Ich werde nächsten Monat Spanisch lernen.","translation":"Je vais apprendre l''espagnol le mois prochain."},{"sentence":"Wirst du heute Abend das Spiel sehen?","translation":"Vas-tu regarder le match ce soir ?"},{"sentence":"Sie will in Kanada arbeiten.","translation":"Elle veut travailler au Canada."}]'::jsonb, 10, true, 2 from public.modules where code = 'de-a2-m1' on conflict (code) do update set title = excluded.title, objective = excluded.objective, explanation = excluded.explanation, vocab = excluded.vocab, examples = excluded.examples, is_published = true, sort_order = excluded.sort_order;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'mcq'::public.exercise_type, 1, '{"question":"Complète : « Sie ___ Medizin studieren. » (futur)","options":["wird","werdet","wirst"]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":0}'::jsonb, '[]'::jsonb, 'werden : ich werde, du wirst, er/sie WIRD, wir werden.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 1 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'translation'::public.exercise_type, 2, '{"instruction":"Traduis en allemand :","source":"Je vais visiter l''Italie cet été."}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"variants":["ich werde diesen sommer italien besuchen","ich werde im sommer italien besuchen"]}'::jsonb, '[]'::jsonb, 'werden + infinitif EN FIN de phrase : « … besuchen ».' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 2 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'gap_fill'::public.exercise_type, 3, '{"sentence":"Ich will Englisch lernen, ___ es nützlich ist.","translation":"Je veux apprendre l''anglais parce que c''est utile."}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"blanks":["weil"]}'::jsonb, '[]'::jsonb, '« weil » introduit la raison (le verbe va en fin de subordonnée : es nützlich ist).' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 3 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'matching'::public.exercise_type, 4, '{"instruction":"Associe chaque expression à sa traduction.","pairs":[{"left":"nächsten Monat","right":"le mois prochain"},{"left":"gerne!","right":"avec plaisir !"},{"left":"vielleicht","right":"peut-être"},{"left":"weil","right":"parce que"}]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"pairs":[0,1,2,3]}'::jsonb, '[]'::jsonb, 'Ces petits mots rendent tes conversations naturelles.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 4 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'reorder'::public.exercise_type, 5, '{"instruction":"Remets la question en ordre :","words":["du","Wirst","reisen","?"],"translation":"Wirst du reisen ?"}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"order":[1,0,2,3]}'::jsonb, '[]'::jsonb, 'Question : Wirst + du + infinitif ?' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 5 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;
insert into public.exercises (lesson_id, type, position, prompt, points, is_published) select id, 'listening'::public.exercise_type, 6, '{"audio_text":"Ich werde nächsten Monat meine Großmutter besuchen.","question":"Écoute : que va faire la personne ?","options":["Voyager en Italie","Rendre visite à sa grand-mère","Acheter une voiture"]}'::jsonb, 10, true from public.lessons where code = 'de-a2-m1-l2' on conflict (lesson_id, position) do update set type = excluded.type, prompt = excluded.prompt, is_published = true;
insert into public.exercise_answer_keys (exercise_id, correct, accepted, explanation) select e.id, '{"answer":1}'::jsonb, '[]'::jsonb, '« Meine Großmutter besuchen » = rendre visite à ma grand-mère.' from public.exercises e join public.lessons l on l.id = e.lesson_id where l.code = 'de-a2-m1-l2' and e.position = 6 on conflict (exercise_id) do update set correct = excluded.correct, accepted = excluded.accepted, explanation = excluded.explanation;

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 5/10 — 006_ai_providers.sql
-- PROFESSEUR IA — réglages multi-fournisseurs (Gemini, OpenRouter, Mistral). Idempotent.
-- ██████████████████████████████████████████████████████████████████████████

-- ============================================================
-- MAJOOP — Migration 006 : Professeur IA multi-fournisseurs
-- Ajoute les réglages OpenRouter et Mistral (idempotent).
-- Pour les installations existantes : exécuter APRÈS 001→005
-- (les nouvelles installations l'obtiennent déjà via 004 regénéré).
--
-- Secrets à définir côté Supabase (au moins un) :
--   supabase secrets set GEMINI_API_KEY=...        (aistudio.google.com)
--   supabase secrets set OPENROUTER_API_KEY=...    (openrouter.ai)
--   supabase secrets set MISTRAL_API_KEY=...       (console.mistral.ai)
-- ============================================================

-- Choix du fournisseur :
--   'auto'      → essaie Gemini, puis OpenRouter, puis Mistral (repli automatique)
--   'gemini'    → uniquement Gemini
--   'openrouter'→ uniquement OpenRouter
--   'mistral'   → uniquement Mistral
insert into public.admin_settings (key, value, description)
values ('ai_provider', '"auto"'::jsonb,
        'Fournisseur IA : auto (repli gemini→openrouter→mistral) | gemini | openrouter | mistral')
on conflict (key) do update set value = excluded.value, description = excluded.description;

-- Modèle par fournisseur (modifiable dans Administration → XP & IA)
insert into public.admin_settings (key, value, description)
values ('ai_model', '"gemini-2.5-flash"'::jsonb, 'Modèle Gemini utilisé par l''Edge Function')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description)
values ('ai_model_openrouter', '"meta-llama/llama-3.3-70b-instruct:free"'::jsonb,
        'Modèle OpenRouter (les ID :free changent souvent — voir openrouter.ai/models?max_price=0)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

insert into public.admin_settings (key, value, description)
values ('ai_model_mistral', '"mistral-small-latest"'::jsonb, 'Modèle Mistral (alias stable)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 6/10 — 007_monetisation.sql
-- MONÉTISATION — plans, tarifs, abonnements, paiements manuels, quotas IA, 32 RPC (my_subscription, submit_manual_payment, admin_confirm_payment…).
-- ██████████████████████████████████████████████████████████████████████████

-- ============================================================
-- MAJOOP — Migration 007 : MONÉTISATION (Free / Premium)
-- Exécution : APRÈS 001→006 (Supabase SQL Editor ou supabase db push)
--
-- Contenu :
--   1. Types + 6 tables (subscription_plans, pricing, user_subscriptions,
--      payments, ai_usage, subscription_events)
--   2. Index anti-doublons (abonnement, paiement, compteur IA)
--   3. Triggers (updated_at, garde tarifaire immuable)
--   4. RLS + privilèges tables (écriture = RPC serveur uniquement)
--   5. Fonctions serveur :
--        user_effective_plan / user_is_premium / expire_due_subscriptions
--        ai_consume_quota (quotas MENSUELS par plan, atomique) / ai_refund_quota
--        my_ai_quota / my_subscription / submit_manual_payment / user_cancel_renewal
--        admin_list_plans / admin_set_plan_active / admin_add_pricing /
--        admin_deactivate_pricing / admin_list_subscriptions / admin_list_payments /
--        admin_confirm_payment / admin_reject_payment / admin_set_ai_quota /
--        admin_monetization_stats (MRR/ARR) / admin_export_monetization
--   6. Seed : plans officiels + grille tarifaire (XAF, XOF, USD ; EUR configurable)
--   7. Privilèges RPC
--
-- Règles de sécurité appliquées :
--   • Le frontend ne peut JAMAIS accorder Premium (aucune écriture client).
--   • Le montant payé vient TOUJOURS de la ligne `pricing` serveur (jamais du client).
--   • Une ligne pricing est immuable : changer un prix = nouvelle ligne
--     (les abonnements existants gardent leur prix — pas de rétroactivité).
--   • Paiements anti-doublons : unique(provider, provider_reference) + statut.
--   • Quota IA compté serveur, incrément atomique protégé contre la concurrence.
--   • Aucune clé API IA ici : secrets Supabase uniquement (Edge Function).
-- ============================================================

-- ============================================================
-- 1. TYPES ET TABLES
-- ============================================================

create type public.billing_interval as enum ('monthly', 'yearly');

create type public.subscription_status as enum (
  'free', 'pending', 'active', 'expired', 'cancelled', 'payment_failed'
);

create type public.payment_status as enum ('pending', 'confirmed', 'rejected', 'failed');

create type public.subscription_event_type as enum (
  'subscription_created', 'subscription_activated', 'subscription_renewed',
  'subscription_expired', 'subscription_cancelled', 'renewal_cancelled',
  'payment_submitted', 'payment_confirmed', 'payment_rejected',
  'pricing_created', 'pricing_deactivated', 'quota_config_changed',
  'plan_status_changed', 'expiry_warning'
);

-- Plans commerciaux (free / premium_monthly / premium_yearly à la création)
create table public.subscription_plans (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 80),
  code        text not null unique check (length(btrim(code)) between 2 and 40),
  description text not null default '',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- Grille tarifaire multi-devises / multi-régions.
-- ⚠️ XAF et XOF sont deux devises DISTINCTES : ils occupent des lignes séparées.
-- ⚠️ Une ligne active est IMMUABLE (trigger garde_pricing_amount) : une
--    modification de prix crée une NOUVELLE ligne active (versionnement).
create table public.pricing (
  id               uuid primary key default gen_random_uuid(),
  plan_id          uuid not null references public.subscription_plans(id) on delete cascade,
  currency         text not null check (currency in ('EUR', 'USD', 'XAF', 'XOF')),
  amount           numeric(12,2) not null check (amount >= 0),
  billing_interval public.billing_interval not null,
  region           text not null default 'international' check (length(btrim(region)) between 2 and 40),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Abonnements. Un seul statut pending OU active par utilisateur
-- (index partiels uniques ci-dessous) ; l'historique est conservé
-- avec les autres statuts (expired, cancelled, payment_failed).
create table public.user_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  plan_id    uuid not null references public.subscription_plans(id) on delete restrict,
  pricing_id uuid references public.pricing(id) on delete set null,
  status     public.subscription_status not null default 'free',
  started_at timestamptz not null default now(),
  expires_at timestamptz,                    -- null = plan gratuit sans expiration
  auto_renew boolean not null default false, -- renouvellement = nouveau paiement validé
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Paiements. provider_reference : référence unique par fournisseur
-- (preuve mobile money, transaction, etc.) → anti-doublons.
-- Le montant est copié depuis la ligne `pricing` SERVEUR à la soumission.
create table public.payments (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles(id) on delete cascade,
  subscription_id    uuid references public.user_subscriptions(id) on delete set null,
  amount             numeric(12,2) not null check (amount >= 0),
  currency           text not null check (currency in ('EUR', 'USD', 'XAF', 'XOF')),
  provider           text not null default 'manual' check (length(btrim(provider)) between 2 and 40),
  provider_reference text not null check (length(btrim(provider_reference)) between 4 and 120),
  status             public.payment_status not null default 'pending',
  paid_at            timestamptz,
  created_at         timestamptz not null default now()
);

-- Compteur mensuel d'interactions IA (une ligne par utilisateur et par mois).
-- L'incrément est ATOMIQUE et exclusivement serveur (ai_consume_quota).
create table public.ai_usage (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles(id) on delete cascade,
  subscription_id   uuid references public.user_subscriptions(id) on delete set null,
  interaction_count int not null default 0 check (interaction_count >= 0),
  period_start      date not null,
  period_end        date not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (period_end >= period_start)
);

-- Journal des événements de monétisation (audit complet, modifs tarifaires incluses)
create table public.subscription_events (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references public.profiles(id) on delete cascade,
  subscription_id uuid references public.user_subscriptions(id) on delete set null,
  event_type      public.subscription_event_type not null,
  metadata        jsonb not null default '{}',
  created_at      timestamptz not null default now()
);

-- ============================================================
-- 2. INDEX ET ANTI-DOUBLONS
-- ============================================================

-- Un seul abonnement pending OU actif par utilisateur (pas de doublon)
create unique index uq_user_sub_pending on public.user_subscriptions(user_id) where status = 'pending';
create unique index uq_user_sub_active  on public.user_subscriptions(user_id) where status = 'active';

-- Une seule ligne de tarif ACTIVE par (plan, devise, périodicité, région)
create unique index uq_pricing_active
  on public.pricing(plan_id, currency, billing_interval, region) where is_active;

-- Référence de paiement unique par fournisseur → ni double soumission,
-- ni double confirmation (webhook rejoué, preuve déjà utilisée…)
create unique index uq_payment_provider_ref on public.payments(provider, provider_reference);

-- Compteur IA : une ligne par utilisateur et par mois
create unique index uq_ai_usage_period on public.ai_usage(user_id, period_start);

create index idx_sub_user     on public.user_subscriptions(user_id, status);
create index idx_sub_expires  on public.user_subscriptions(status, expires_at) where status = 'active';
create index idx_pay_user     on public.payments(user_id, created_at desc);
create index idx_pay_status   on public.payments(status, created_at desc);
create index idx_usage_period on public.ai_usage(period_start);
create index idx_events_user  on public.subscription_events(user_id, created_at desc);
create index idx_events_sub   on public.subscription_events(subscription_id);

-- ============================================================
-- 3. TRIGGERS
-- ============================================================

create trigger trg_pricing_updated    before update on public.pricing            for each row execute function public.set_updated_at();
create trigger trg_subscription_upd   before update on public.user_subscriptions for each row execute function public.set_updated_at();
create trigger trg_ai_usage_updated   before update on public.ai_usage           for each row execute function public.set_updated_at();

-- Garde tarifaire : le MONTANT d'une ligne pricing est immuable.
-- Pour changer un prix → désactiver la ligne + créer une nouvelle ligne
-- (admin_add_pricing). Les abonnements déjà vendus gardent leur prix.
create or replace function public.guard_pricing_amount()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.amount is distinct from old.amount then
    raise exception 'MAJOOP: le montant d''une ligne de tarif est immuable. Désactive cette ligne et crée une nouvelle ligne de tarif (admin_add_pricing) — les abonnements existants conservent leur prix.';
  end if;
  return new;
end;
$$;

create trigger trg_guard_pricing_amount before update on public.pricing
  for each row execute function public.guard_pricing_amount();

-- ============================================================
-- 4. RLS ET PRIVILÈGES TABLES
-- ============================================================

alter table public.subscription_plans  enable row level security;
alter table public.pricing             enable row level security;
alter table public.user_subscriptions  enable row level security;
alter table public.payments            enable row level security;
alter table public.ai_usage            enable row level security;
alter table public.subscription_events enable row level security;

-- Plans et tarifs : lecture publique des lignes actives (page Tarifs hors connexion),
-- l'admin voit tout. Écritures : uniquement via RPC DEFINER (aucune policy d'écriture).
create policy "plans_lecture_active" on public.subscription_plans
  for select to anon, authenticated using (is_active or public.is_admin());
create policy "pricing_lecture_active" on public.pricing
  for select to anon, authenticated using (is_active or public.is_admin());

-- Données monétisation personnelles : lecture par le propriétaire (ou l'admin).
-- AUCUNE policy d'écriture : tout passe par les fonctions SECURITY DEFINER.
create policy "sub_lecture_proprio_ou_admin" on public.user_subscriptions
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "pay_lecture_proprio_ou_admin" on public.payments
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "usage_lecture_proprio_ou_admin" on public.ai_usage
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "events_lecture_proprio_ou_admin" on public.subscription_events
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

revoke all on public.user_subscriptions, public.payments, public.ai_usage,
              public.subscription_events from anon, authenticated;
grant select on public.user_subscriptions, public.payments, public.ai_usage,
                public.subscription_events to authenticated;
grant select on public.subscription_plans, public.pricing to anon, authenticated;

-- ============================================================
-- 5. FONCTIONS SERVEUR
-- ============================================================

-- ------------------------------------------------------------
-- 5a. Plan effectif d'un utilisateur ('free' par défaut)
-- ------------------------------------------------------------
create or replace function public.user_effective_plan(p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_code text;
begin
  select pl.code into v_code
    from public.user_subscriptions s
    join public.subscription_plans pl on pl.id = s.plan_id
   where s.user_id = p_user and s.status = 'active' and s.expires_at > now()
   order by s.expires_at desc limit 1;
  return coalesce(v_code, 'free');
end;
$$;

create or replace function public.user_is_premium(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.user_effective_plan(p_user) like 'premium%';
$$;

-- ------------------------------------------------------------
-- 5b. Expiration : bascule les abonnements actifs échus en 'expired'
--     (idempotent — n'altère jamais les droits non échus)
-- ------------------------------------------------------------
create or replace function public.expire_due_subscriptions()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_count int;
begin
  with exp as (
    update public.user_subscriptions s
       set status = 'expired', updated_at = now()
     where s.status = 'active' and s.expires_at <= now()
    returning s.user_id, s.id, s.expires_at
  )
  insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
  select user_id, id, 'subscription_expired',
         jsonb_build_object('expires_at', expires_at)
  from exp;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ------------------------------------------------------------
-- 5c. Quota IA MENSUEL (par plan) — remplace la logique quotidienne
--     par plan, tout en conservant anti-spam + garde anti-abus journalière.
--     Signature inchangée : l'Edge Function continue d'appeler telle quelle.
--     • Incrément ATOMIQUE : l'UPDATE conditionnel (interaction_count < limite)
--       est sérialisé par le verrou de ligne → pas de double comptage simultané.
-- ------------------------------------------------------------
create or replace function public.ai_consume_quota(p_conversation uuid, p_user_msg text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_conv record;
  v_code text;
  v_limit_month int;
  v_limit_day int;
  v_min_gap int;
  v_max_chars int;
  v_today int;
  v_last timestamptz;
  v_period date;
  v_period_end date;
  v_used int;
begin
  select * into v_conv from public.ai_conversations where id = p_conversation;
  if not found then raise exception 'MAJOOP: conversation introuvable'; end if;

  v_code := public.user_effective_plan(v_conv.user_id);

  if v_code like 'premium%' then
    v_limit_month := (public.get_setting('ai_quota_premium', '100'))::text::int;
  else
    v_limit_month := (public.get_setting('ai_quota_free', '10'))::text::int;
  end if;
  v_limit_day := (public.get_setting('ai_daily_quota', '60'))::text::int;
  v_min_gap   := (public.get_setting('ai_min_interval_sec', '3'))::text::int;
  v_max_chars := (public.get_setting('ai_max_message_chars', '2000'))::text::int;

  if v_limit_month <= 0 or v_limit_day <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'disabled',
      'message', 'Le professeur IA est momentanément désactivé par l''administrateur.');
  end if;

  -- Limite de taille des messages (maîtrise des coûts)
  if length(p_user_msg) > v_max_chars then
    return jsonb_build_object('ok', false, 'reason', 'too_long',
      'message', 'Message trop long (' || length(p_user_msg) || ' caractères, maximum ' || v_max_chars || '). Réduis-le un peu.');
  end if;

  -- Garde anti-abus journalière (configurable — ne remplace pas le quota mensuel)
  select count(*) into v_today
    from public.ai_messages m
    join public.ai_conversations c on c.id = m.conversation_id
   where c.user_id = v_conv.user_id and m.role = 'user'
     and m.created_at >= date_trunc('day', now());
  if v_today >= v_limit_day then
    return jsonb_build_object('ok', false, 'reason', 'daily',
      'message', 'Limite journalière de protection atteinte (' || v_limit_day || ' messages). Reviens demain !');
  end if;

  -- Anti-spam : intervalle minimal entre deux messages
  select max(m.created_at) into v_last
    from public.ai_messages m
    join public.ai_conversations c on c.id = m.conversation_id
   where c.user_id = v_conv.user_id and m.role = 'user';
  if v_last is not null and now() - v_last < make_interval(secs => v_min_gap) then
    return jsonb_build_object('ok', false, 'reason', 'rate',
      'message', 'Un peu de calme ! Attends quelques secondes entre chaque message.');
  end if;

  -- ===== QUOTA MENSUEL (atome de vérité) =====
  v_period     := date_trunc('month', now())::date;
  v_period_end := (date_trunc('month', now()) + interval '1 month - 1 day')::date;

  insert into public.ai_usage (user_id, period_start, period_end)
  values (v_conv.user_id, v_period, v_period_end)
  on conflict (user_id, period_start) do nothing;

  update public.ai_usage u
     set interaction_count = u.interaction_count + 1,
         subscription_id = (select s.id from public.user_subscriptions s
                             where s.user_id = v_conv.user_id and s.status = 'active'
                               and s.expires_at > now()
                             order by s.expires_at desc limit 1),
         updated_at = now()
   where u.user_id = v_conv.user_id and u.period_start = v_period
     and u.interaction_count < v_limit_month
  returning u.interaction_count into v_used;

  if v_used is null then
    -- quota épuisé : message d'upsell clair, jamais "illimité"
    select interaction_count into v_used from public.ai_usage
     where user_id = v_conv.user_id and period_start = v_period;
    return jsonb_build_object(
      'ok', false, 'reason', 'quota', 'plan', v_code,
      'used', coalesce(v_used, v_limit_month), 'limit', v_limit_month,
      'reset_at', v_period_end, 'upgrade', (v_code = 'free'),
      'message',
        case when v_code = 'free'
          then 'Tu as utilisé tes ' || coalesce(v_used, v_limit_month) ||
               ' interactions IA de ce mois (formule Free). Passe à Premium pour 100 interactions par mois !'
          else 'Tu as utilisé tes ' || coalesce(v_used, v_limit_month) || '/' || v_limit_month ||
               ' interactions Premium de ce mois. Elles se réinitialisent le ' ||
               to_char(v_period_end, 'DD/MM/YYYY') || '.'
        end);
  end if;

  insert into public.ai_messages (conversation_id, role, content)
  values (p_conversation, 'user', left(p_user_msg, 4000));

  perform public.progress_mission(v_conv.user_id, 'ai_chat', 1);

  return jsonb_build_object('ok', true, 'plan', v_code, 'used', v_used,
    'limit', v_limit_month, 'reset_at', v_period_end);
end;
$$;

-- ------------------------------------------------------------
-- 5d. Rembourse 1 interaction (appelé par l'Edge Function si l'appel
--     au modèle IA échoue complètement : l'utilisateur ne paie pas une erreur)
-- ------------------------------------------------------------
create or replace function public.ai_refund_quota(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
begin
  select user_id into v_user from public.ai_conversations where id = p_conversation;
  if v_user is null then return; end if;
  update public.ai_usage
     set interaction_count = greatest(interaction_count - 1, 0), updated_at = now()
   where user_id = v_user and period_start = date_trunc('month', now())::date
     and interaction_count > 0;
end;
$$;

-- ------------------------------------------------------------
-- 5e. Compteur IA de l'utilisateur courant (affichage UI)
-- ------------------------------------------------------------
create or replace function public.my_ai_quota()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_code text;
  v_limit int;
  v_used int;
  v_period date := date_trunc('month', now())::date;
  v_period_end date := (date_trunc('month', now()) + interval '1 month - 1 day')::date;
begin
  if v_user is null then raise exception 'MAJOOP: authentification requise'; end if;
  v_code := public.user_effective_plan(v_user);
  if v_code like 'premium%' then
    v_limit := (public.get_setting('ai_quota_premium', '100'))::text::int;
  else
    v_limit := (public.get_setting('ai_quota_free', '10'))::text::int;
  end if;
  select interaction_count into v_used from public.ai_usage
   where user_id = v_user and period_start = v_period;
  return jsonb_build_object('plan', v_code, 'used', coalesce(v_used, 0),
    'limit', v_limit, 'remaining', greatest(v_limit - coalesce(v_used, 0), 0),
    'period_start', v_period, 'reset_at', v_period_end);
end;
$$;

-- ------------------------------------------------------------
-- 5f. Abonnement de l'utilisateur courant (MySubscriptionPage)
--     Appelle d'abord expire_due_subscriptions() pour un statut à jour.
-- ------------------------------------------------------------
create or replace function public.my_subscription()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_sub record;
  v_pay record;
  v_pr record;
  v_code text;
  v_quota jsonb;
  v_warn boolean := false;
  v_status text := 'free';
  v_started timestamptz;
  v_expires timestamptz;
  v_auto boolean := false;
  v_days int;
  v_pricing jsonb;
  v_payment jsonb;
begin
  if v_user is null then raise exception 'MAJOOP: authentification requise'; end if;
  perform public.expire_due_subscriptions();

  v_code := public.user_effective_plan(v_user);

  select s.* into v_sub from public.user_subscriptions s
   where s.user_id = v_user and s.status in ('active', 'pending')
   order by case s.status when 'active' then 0 else 1 end, s.created_at desc limit 1;

  if found then
    v_status := v_sub.status::text;
    v_started := v_sub.started_at;
    v_expires := v_sub.expires_at;
    v_auto := v_sub.auto_renew;

    select * into v_pr from public.pricing where id = v_sub.pricing_id;
    if found then
      v_pricing := jsonb_build_object('amount', v_pr.amount, 'currency', v_pr.currency,
        'billing_interval', v_pr.billing_interval, 'region', v_pr.region);
    end if;
    select * into v_pay from public.payments
     where subscription_id = v_sub.id order by created_at desc limit 1;
    if found then
      v_payment := jsonb_build_object('id', v_pay.id, 'status', v_pay.status::text,
        'amount', v_pay.amount, 'currency', v_pay.currency, 'provider', v_pay.provider,
        'provider_reference', v_pay.provider_reference,
        'created_at', v_pay.created_at, 'paid_at', v_pay.paid_at);
    end if;
    -- Notification d'expiration proche (une seule fois par période de 3 jours)
    if v_sub.status = 'active' and v_expires is not null
       and v_expires < now() + interval '7 days' then
      v_warn := true;
      if not exists (select 1 from public.subscription_events
                      where subscription_id = v_sub.id and event_type = 'expiry_warning'
                        and created_at > now() - interval '3 days') then
        insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
        values (v_user, v_sub.id, 'expiry_warning',
                jsonb_build_object('expires_at', v_expires,
                                   'days_left', ceil(extract(epoch from (v_expires - now())) / 86400)));
      end if;
    end if;
    if v_expires is not null then
      v_days := greatest(ceil(extract(epoch from (v_expires - now())) / 86400)::int, 0);
    end if;
  end if;

  v_quota := public.my_ai_quota();

  return jsonb_build_object(
    'plan', v_code,
    'plan_name', case when v_code = 'free' then 'Free'
                      when v_code = 'premium_monthly' then 'Premium Mensuel'
                      when v_code = 'premium_yearly' then 'Premium Annuel'
                      else v_code end,
    'status', v_status,
    'started_at', v_started,
    'expires_at', v_expires,
    'auto_renew', v_auto,
    'days_left', v_days,
    'pricing', v_pricing,
    'payment', v_payment,
    'expiry_warning', v_warn,
    'usage', v_quota
  );
end;
$$;

-- ------------------------------------------------------------
-- 5f-bis. Instructions de paiement manuel (lecture authentifiée).
--   admin_settings n'est lisible que par l'admin : cette fonction expose
--   UNIQUEMENT les instructions de paiement aux utilisateurs connectés
--   (aucun secret ici — l'admin les configure via admin_set_setting).
-- ------------------------------------------------------------
create or replace function public.get_payment_instructions()
returns jsonb language sql stable security definer set search_path = public as $$
  select public.get_setting('payment_instructions', '{}'::jsonb);
$$;

-- ------------------------------------------------------------
-- 5g. Soumission d'un paiement MANUEL (mode sans fournisseur configuré).
--     • Le montant vient de la ligne pricing SERVEUR (jamais du client).
--     • Référence unique → anti-doublons (contrainte + vérification explicite).
--     • Crée/réutilise UN abonnement 'pending' ; Premium n'est accordé
--       qu'à la VALIDATION ADMIN (admin_confirm_payment).
-- ------------------------------------------------------------
create or replace function public.submit_manual_payment(
  p_pricing_id uuid, p_reference text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_pr record;
  v_sub record;
  v_pay record;
  v_active record;
begin
  if v_user is null then raise exception 'MAJOOP: authentification requise'; end if;

  select pr.*, pl.code as plan_code, pl.name as plan_name, pl.is_active as plan_active
    into v_pr
    from public.pricing pr
    join public.subscription_plans pl on pl.id = pr.plan_id
   where pr.id = p_pricing_id and pr.is_active;
  if not found or not v_pr.plan_active then
    raise exception 'MAJOOP: cette formule n''est plus disponible';
  end if;
  if v_pr.amount <= 0 then
    raise exception 'MAJOOP: cette formule est gratuite — aucun paiement requis';
  end if;
  if p_reference is null or length(btrim(p_reference)) < 4 then
    raise exception 'MAJOOP: référence de paiement invalide (4 caractères minimum)';
  end if;

  -- Anti-doublon explicite (la contrainte unique protège aussi en concurrence)
  if exists (select 1 from public.payments
              where provider = 'manual' and provider_reference = btrim(p_reference)) then
    raise exception 'MAJOOP: cette référence de paiement a déjà été soumise';
  end if;

  -- RENOUVELLEMENT : un abonnement ACTIF du même plan existe → le paiement est
  -- rattaché à CET abonnement ; la validation prolongera sa période à partir
  -- de la fin de la période déjà payée (aucun jour perdu, jamais rétroactif).
  select s.* into v_active
    from public.user_subscriptions s
    join public.subscription_plans pl2 on pl2.id = s.plan_id
   where s.user_id = v_user and s.status = 'active' and s.expires_at > now()
     and pl2.code = v_pr.plan_code
   order by s.expires_at desc limit 1;
  if found then
    insert into public.payments (user_id, subscription_id, amount, currency,
                                 provider, provider_reference, status)
    values (v_user, v_active.id, v_pr.amount, v_pr.currency, 'manual', btrim(p_reference), 'pending')
    returning * into v_pay;

    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_user, v_active.id, 'payment_submitted', jsonb_build_object(
      'payment_id', v_pay.id, 'provider', 'manual',
      'reference', btrim(p_reference), 'amount', v_pr.amount, 'currency', v_pr.currency,
      'plan', v_pr.plan_code, 'phase', 'renewal', 'note', left(coalesce(p_note, ''), 500)));

    return jsonb_build_object('ok', true,
      'payment_id', v_pay.id, 'subscription_id', v_active.id, 'status', 'pending',
      'amount', v_pr.amount, 'currency', v_pr.currency, 'renewal', true,
      'message', 'Renouvellement enregistré. Après vérification par un administrateur, ton accès actuel sera prolongé à partir de la fin de la période déjà payée.');
  end if;

  -- Nouvelle souscription (ou changement de plan) : réutiliser l'abonnement
  -- pending existant (un seul autorisé) ou en créer un
  select * into v_sub from public.user_subscriptions
   where user_id = v_user and status = 'pending';
  if found then
    update public.user_subscriptions
       set plan_id = v_pr.plan_id, pricing_id = v_pr.id, updated_at = now()
     where id = v_sub.id
    returning * into v_sub;
  else
    insert into public.user_subscriptions (user_id, plan_id, pricing_id, status, started_at)
    values (v_user, v_pr.plan_id, v_pr.id, 'pending', now())
    returning * into v_sub;
  end if;

  insert into public.payments (user_id, subscription_id, amount, currency,
                               provider, provider_reference, status)
  values (v_user, v_sub.id, v_pr.amount, v_pr.currency, 'manual', btrim(p_reference), 'pending')
  returning * into v_pay;

  insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
  values (v_user, v_sub.id, 'payment_submitted', jsonb_build_object(
    'payment_id', v_pay.id, 'provider', 'manual',
    'reference', btrim(p_reference), 'amount', v_pr.amount, 'currency', v_pr.currency,
    'plan', v_pr.plan_code, 'note', left(coalesce(p_note, ''), 500)));

  return jsonb_build_object('ok', true,
    'payment_id', v_pay.id, 'subscription_id', v_sub.id, 'status', 'pending',
    'amount', v_pr.amount, 'currency', v_pr.currency,
    'message', 'Paiement soumis. Un administrateur va le vérifier — ton accès Premium sera actif dès validation.');
end;
$$;

-- ------------------------------------------------------------
-- 5h. Annulation du renouvellement par l'utilisateur.
--     Les droits déjà payés sont CONSERVÉS jusqu'à expires_at.
--     Annule aussi une demande pending (aucun droit payé perdu : rien n'était actif).
-- ------------------------------------------------------------
create or replace function public.user_cancel_renewal()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_sub record;
begin
  if v_user is null then raise exception 'MAJOOP: authentification requise'; end if;

  select * into v_sub from public.user_subscriptions
   where user_id = v_user and status = 'active';
  if found then
    update public.user_subscriptions set auto_renew = false where id = v_sub.id;
    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_user, v_sub.id, 'renewal_cancelled',
            jsonb_build_object('expires_at', v_sub.expires_at));
    return jsonb_build_object('ok', true, 'status', 'active',
      'expires_at', v_sub.expires_at,
      'message', 'Renouvellement annulé. Ton accès Premium reste actif jusqu''au ' ||
                 to_char(v_sub.expires_at, 'DD/MM/YYYY') || ' (fin de la période payée).');
  end if;

  select * into v_sub from public.user_subscriptions
   where user_id = v_user and status = 'pending';
  if found then
    update public.user_subscriptions set status = 'cancelled' where id = v_sub.id;
    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_user, v_sub.id, 'subscription_cancelled', jsonb_build_object('phase', 'pending'));
    return jsonb_build_object('ok', true, 'status', 'cancelled',
      'message', 'Demande d''abonnement annulée. Aucun montant n''a été débité.');
  end if;

  return jsonb_build_object('ok', false, 'message', 'Aucun abonnement actif à annuler.');
end;
$$;

-- ------------------------------------------------------------
-- 5i. FONCTIONS ADMIN (chaque appel vérifie is_admin())
-- ------------------------------------------------------------

create or replace function public.admin_list_plans()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
    select p.id, p.code, p.name, p.description, p.is_active, p.created_at,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', e.id, 'currency', e.currency, 'amount', e.amount,
                 'billing_interval', e.billing_interval, 'region', e.region,
                 'is_active', e.is_active, 'created_at', e.created_at) order by e.currency, e.billing_interval)
        from public.pricing e where e.plan_id = p.id
      ), '[]'::jsonb) as pricing
    from public.subscription_plans p order by p.code
  ) d;
end;
$$;

create or replace function public.admin_set_plan_active(p_plan_id uuid, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  update public.subscription_plans set is_active = p_active where id = p_plan_id;
  if not found then raise exception 'MAJOOP: plan introuvable'; end if;
  insert into public.subscription_events (user_id, event_type, metadata)
  values (auth.uid(), 'plan_status_changed',
          jsonb_build_object('plan_id', p_plan_id, 'is_active', p_active));
  return jsonb_build_object('ok', true, 'is_active', p_active);
end;
$$;

-- Nouvelle ligne de tarif : crée une VERSION (l'ancienne ligne active du même
-- couple devise/périodicité/région est désactivée). Jamais de rétroactivité :
-- les abonnements en cours pointent leur propre pricing_id.
create or replace function public.admin_add_pricing(
  p_plan_id uuid, p_currency text, p_amount numeric,
  p_interval public.billing_interval, p_region text default 'international')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_new record;
  v_old public.pricing;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  if p_currency not in ('EUR','USD','XAF','XOF') then
    raise exception 'MAJOOP: devise non supportée (%). Devises configurables : EUR, USD, XAF, XOF', p_currency;
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'MAJOOP: montant invalide';
  end if;
  if p_amount > 0 and p_region is null then
    raise exception 'MAJOOP: région requise';
  end if;

  update public.pricing e
     set is_active = false, updated_at = now()
   where e.plan_id = p_plan_id and e.currency = p_currency
     and e.billing_interval = p_interval and e.region = p_region and e.is_active
  returning * into v_old;

  insert into public.pricing (plan_id, currency, amount, billing_interval, region, is_active)
  values (p_plan_id, p_currency, p_amount, p_interval, coalesce(p_region, 'international'), true)
  returning * into v_new;

  insert into public.subscription_events (user_id, event_type, metadata)
  values (auth.uid(), 'pricing_created', jsonb_build_object(
    'plan_id', p_plan_id, 'currency', p_currency, 'amount', p_amount,
    'billing_interval', p_interval, 'region', coalesce(p_region, 'international'),
    'replaced_pricing_id', case when v_old is not null then v_old.id end,
    'replaced_amount', case when v_old is not null then v_old.amount end,
    'note', 'Les abonnements existants conservent leur ancien prix.'));

  if v_old is not null then
    insert into public.subscription_events (user_id, event_type, metadata)
    values (auth.uid(), 'pricing_deactivated', jsonb_build_object(
      'pricing_id', v_old.id, 'amount', v_old.amount, 'currency', v_old.currency,
      'billing_interval', v_old.billing_interval, 'region', v_old.region));
  end if;

  return jsonb_build_object('ok', true, 'pricing_id', v_new.id);
end;
$$;

create or replace function public.admin_deactivate_pricing(p_pricing_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_old public.pricing;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  update public.pricing e set is_active = false where e.id = p_pricing_id and e.is_active
  returning * into v_old;
  if v_old is null then raise exception 'MAJOOP: tarif introuvable ou déjà inactif'; end if;
  insert into public.subscription_events (user_id, event_type, metadata)
  values (auth.uid(), 'pricing_deactivated', jsonb_build_object(
    'pricing_id', v_old.id, 'amount', v_old.amount, 'currency', v_old.currency,
    'billing_interval', v_old.billing_interval, 'region', v_old.region));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_list_subscriptions(
  p_limit int default 100, p_offset int default 0, p_status text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  perform public.expire_due_subscriptions();
  return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
    select s.id, prof.email, s.status::text as status,
           pl.code as plan_code, pl.name as plan_name,
           pr.amount, pr.currency, pr.billing_interval::text as billing_interval,
           s.started_at, s.expires_at, s.auto_renew, s.created_at,
           (select count(*) from public.payments pay
             where pay.subscription_id = s.id and pay.status = 'confirmed') as payments_confirmed
    from public.user_subscriptions s
    join public.profiles prof on prof.id = s.user_id
    join public.subscription_plans pl on pl.id = s.plan_id
    left join public.pricing pr on pr.id = s.pricing_id
    where p_status is null or s.status::text = p_status
    order by s.created_at desc
    limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0)
  ) d;
end;
$$;

create or replace function public.admin_list_payments(
  p_status text default null, p_limit int default 100)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
    select pay.id, prof.email, pay.amount, pay.currency, pay.provider,
           pay.provider_reference, pay.status::text as status, pay.paid_at, pay.created_at,
           pay.subscription_id, pl.code as plan_code, s.status::text as sub_status
    from public.payments pay
    join public.profiles prof on prof.id = pay.user_id
    left join public.user_subscriptions s on s.id = pay.subscription_id
    left join public.subscription_plans pl on pl.id = s.plan_id
    where p_status is null or pay.status::text = p_status
    order by pay.created_at desc
    limit least(greatest(p_limit, 1), 500)
  ) d;
end;
$$;

-- ------------------------------------------------------------
-- Validation d'un paiement (SERVEUR uniquement).
-- • Idempotent strict : seul un paiement 'pending' peut être confirmé
--   (verrou de ligne + vérification du statut → pas de double attribution).
-- • La durée provient de la ligne pricing du paiement (prix verrouillé à la soumission).
-- • RENOUVELLEMENT : prolonge depuis max(maintenant, expiration) — jamais rétroactif.
-- ------------------------------------------------------------
create or replace function public.admin_confirm_payment(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay record;
  v_sub record;
  v_pr record;
  v_interval public.billing_interval;
  v_new_exp timestamptz;
  v_renewal boolean := false;
  v_other record;
  v_base timestamptz;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;

  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'MAJOOP: paiement introuvable'; end if;
  if v_pay.status <> 'pending' then
    raise exception 'MAJOOP: paiement déjà traité (statut : %) — confirmation refusée', v_pay.status;
  end if;
  if v_pay.subscription_id is null then
    raise exception 'MAJOOP: aucun abonnement lié à ce paiement';
  end if;

  select * into v_sub from public.user_subscriptions where id = v_pay.subscription_id for update;
  if not found then raise exception 'MAJOOP: abonnement introuvable'; end if;

  select * into v_pr from public.pricing where id = v_sub.pricing_id;
  if found then
    v_interval := v_pr.billing_interval;
  else
    -- Abonnement sans ligne pricing (cas anormal) : déduire du plan
    select case when pl.code = 'premium_yearly' then 'yearly' else 'monthly' end::public.billing_interval
      into v_interval
      from public.subscription_plans pl where pl.id = v_sub.plan_id;
  end if;

  update public.payments set status = 'confirmed', paid_at = now() where id = v_pay.id;

  if v_sub.status = 'active' then
    -- RENOUVELLEMENT : extension à partir de la fin de la période payée
    v_renewal := true;
    v_new_exp := greatest(coalesce(v_sub.expires_at, now()), now())
                 + (case when v_interval = 'yearly' then interval '12 months' else interval '1 month' end);
    update public.user_subscriptions
       set expires_at = v_new_exp, auto_renew = false, updated_at = now()
     where id = v_sub.id;
    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_pay.user_id, v_sub.id, 'subscription_renewed', jsonb_build_object(
      'payment_id', v_pay.id, 'new_expires_at', v_new_exp,
      'amount', v_pay.amount, 'currency', v_pay.currency));
  else
    -- ACTIVATION : les droits Premium commencent à la validation serveur.
    -- S'il reste un abonnement actif d'un AUTRE plan, il est clôturé SANS
    -- perte : la nouvelle période démarre à la fin de la période payée
    -- (empilement, jamais de chevauchement de deux abonnements actifs).
    v_base := now();
    select * into v_other from public.user_subscriptions
     where user_id = v_pay.user_id and status = 'active' and id <> v_sub.id
     order by expires_at desc limit 1;
    if found then
      v_base := greatest(coalesce(v_other.expires_at, now()), now());
      update public.user_subscriptions set status = 'cancelled', updated_at = now()
       where id = v_other.id;
      insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
      values (v_pay.user_id, v_other.id, 'subscription_cancelled', jsonb_build_object(
        'phase', 'superseded', 'superseded_by', v_sub.id, 'payment_id', v_pay.id,
        'previous_expires_at', v_other.expires_at));
    end if;
    v_new_exp := v_base + (case when v_interval = 'yearly' then interval '12 months' else interval '1 month' end);
    update public.user_subscriptions
       set status = 'active', started_at = now(), expires_at = v_new_exp,
           auto_renew = false, updated_at = now()
     where id = v_sub.id;
    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_pay.user_id, v_sub.id, 'subscription_activated', jsonb_build_object(
      'payment_id', v_pay.id, 'expires_at', v_new_exp,
      'amount', v_pay.amount, 'currency', v_pay.currency,
      'plan_id', v_sub.plan_id));
  end if;

  insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
  values (v_pay.user_id, v_sub.id, 'payment_confirmed', jsonb_build_object(
    'payment_id', v_pay.id, 'amount', v_pay.amount, 'currency', v_pay.currency,
    'provider', v_pay.provider, 'reference', v_pay.provider_reference,
    'validated_by', auth.uid()));

  return jsonb_build_object('ok', true, 'status', 'active',
    'expires_at', v_new_exp, 'renewal', v_renewal);
end;
$$;

create or replace function public.admin_reject_payment(p_payment_id uuid, p_reason text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_pay record;
  v_sub record;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then raise exception 'MAJOOP: paiement introuvable'; end if;
  if v_pay.status <> 'pending' then
    raise exception 'MAJOOP: paiement déjà traité (statut : %)', v_pay.status;
  end if;

  update public.payments set status = 'rejected' where id = v_pay.id;

  select * into v_sub from public.user_subscriptions where id = v_pay.subscription_id;
  if found and v_sub.status = 'pending' then
    update public.user_subscriptions set status = 'cancelled' where id = v_sub.id;
    insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
    values (v_pay.user_id, v_sub.id, 'subscription_cancelled',
            jsonb_build_object('payment_id', v_pay.id, 'reason', left(coalesce(p_reason, ''), 300)));
  end if;

  insert into public.subscription_events (user_id, subscription_id, event_type, metadata)
  values (v_pay.user_id, v_sub.id, 'payment_rejected', jsonb_build_object(
    'payment_id', v_pay.id, 'reason', left(coalesce(p_reason, ''), 300),
    'reference', v_pay.provider_reference, 'rejected_by', auth.uid()));

  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;

-- ------------------------------------------------------------
-- Quotas IA configurables (paramètres + journalisation de la modification)
-- ------------------------------------------------------------
create or replace function public.admin_set_ai_quota(p_free int, p_premium int)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  if p_free is null or p_premium is null or p_free < 0 or p_premium < 0
     or p_free > 10000 or p_premium > 10000 then
    raise exception 'MAJOOP: quotas invalides (entiers entre 0 et 10000)';
  end if;
  if p_premium <= p_free then
    raise exception 'MAJOOP: le quota Premium doit être supérieur au quota Free';
  end if;

  insert into public.admin_settings (key, value, description, updated_by)
  values ('ai_quota_free', to_jsonb(p_free), 'Interactions IA mensuelles — plan Free', auth.uid())
  on conflict (key) do update set value = excluded.value, updated_by = auth.uid(), updated_at = now();
  insert into public.admin_settings (key, value, description, updated_by)
  values ('ai_quota_premium', to_jsonb(p_premium), 'Interactions IA mensuelles — plans Premium', auth.uid())
  on conflict (key) do update set value = excluded.value, updated_by = auth.uid(), updated_at = now();

  insert into public.subscription_events (user_id, event_type, metadata)
  values (auth.uid(), 'quota_config_changed',
          jsonb_build_object('free', p_free, 'premium', p_premium));

  return jsonb_build_object('ok', true, 'free', p_free, 'premium', p_premium);
end;
$$;

-- ------------------------------------------------------------
-- Statistiques commerciales. Distinction explicite :
--   • collected : paiements ENCAISSÉS (somme des paiements confirmés)
--   • mrr / arr : revenus récurrents NORMALISÉS (mensuel tel quel,
--     annuel ÷ 12) — ne JAMAIS additionner avec "collected".
--   • ai_cost_estimate : ESTIMATION configurable, pas une facture.
-- ------------------------------------------------------------
create or replace function public.admin_monetization_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_free bigint; v_prem bigint; v_monthly bigint; v_yearly bigint;
  v_conv numeric;
  v_pending bigint;
  v_churn numeric;
  v_ai_used int;
  v_result jsonb;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  perform public.expire_due_subscriptions();

  select count(*) into v_free from public.profiles p
   where not exists (select 1 from public.user_subscriptions s
                      where s.user_id = p.id and s.status = 'active' and s.expires_at > now());

  select count(*) into v_prem
    from public.user_subscriptions s
    join public.subscription_plans pl on pl.id = s.plan_id
   where s.status = 'active' and s.expires_at > now() and pl.code like 'premium%';

  select count(*) into v_monthly from public.user_subscriptions s
   join public.subscription_plans pl on pl.id = s.plan_id
   where s.status = 'active' and s.expires_at > now() and pl.code = 'premium_monthly';

  select count(*) into v_yearly from public.user_subscriptions s
   join public.subscription_plans pl on pl.id = s.plan_id
   where s.status = 'active' and s.expires_at > now() and pl.code = 'premium_yearly';

  v_conv := round(100.0 * v_prem / greatest(v_free + v_prem, 1), 1);

  select count(*) into v_pending from public.payments where status = 'pending';

  -- Taux de résiliation sur 30 jours : annulations / (actifs + annulations 30 j)
  v_churn := round(100.0 *
    (select count(*) from public.subscription_events
      where event_type in ('subscription_cancelled', 'renewal_cancelled')
        and created_at >= now() - interval '30 days')
    / greatest(v_prem +
    (select count(*) from public.subscription_events
      where event_type in ('subscription_cancelled', 'renewal_cancelled')
        and created_at >= now() - interval '30 days'), 1), 1);

  select coalesce(sum(interaction_count), 0) into v_ai_used
    from public.ai_usage where period_start = date_trunc('month', now())::date;

  v_result := jsonb_build_object(
    'free_users', v_free,
    'premium_active', v_prem,
    'premium_monthly', v_monthly,
    'premium_yearly', v_yearly,
    'conversion_rate_pct', v_conv,
    'pending_payments', v_pending,
    'churn_rate_pct_30j', v_churn,
    'ai_interactions_month', v_ai_used,
    'ai_cost_estimate_fcfa_month',
      v_ai_used * (public.get_setting('ai_cost_estimate_fcfa_per_interaction', '25'))::text::int
  );

  -- Revenus par devise (jamais mélangés entre devises)
  v_result := v_result || jsonb_build_object(
    'collected_by_currency', coalesce((
      select jsonb_agg(jsonb_build_object('currency', p.currency, 'collected', p.total) order by p.currency)
      from (select currency, sum(amount) as total from public.payments
             where status = 'confirmed' group by currency) p
    ), '[]'::jsonb),
    'mrr_by_currency', coalesce((
      select jsonb_agg(jsonb_build_object('currency', r.currency, 'mrr', round(r.mrr, 2)) order by r.currency)
      from (select pr.currency,
                   sum(case when pr.billing_interval = 'monthly'
                            then pr.amount else pr.amount / 12.0 end) as mrr
              from public.user_subscriptions s
              join public.pricing pr on pr.id = s.pricing_id
             where s.status = 'active' and s.expires_at > now()
             group by pr.currency) r
    ), '[]'::jsonb),
    'arr_by_currency', coalesce((
      select jsonb_agg(jsonb_build_object('currency', r.currency, 'arr', round(r.mrr * 12, 2)) order by r.currency)
      from (select pr.currency,
                   sum(case when pr.billing_interval = 'monthly'
                            then pr.amount else pr.amount / 12.0 end) as mrr
              from public.user_subscriptions s
              join public.pricing pr on pr.id = s.pricing_id
             where s.status = 'active' and s.expires_at > now()
             group by pr.currency) r
    ), '[]'::jsonb)
  );

  return v_result;
end;
$$;

-- ------------------------------------------------------------
-- Export de données (CSV côté UI) : abonnements, paiements, événements, usage IA
-- ------------------------------------------------------------
create or replace function public.admin_export_monetization(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces admin requis'; end if;
  case p_kind
    when 'subscriptions' then
      return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
        select s.id, prof.email, s.status::text as status, pl.code as plan_code,
               pr.currency, pr.amount, s.started_at, s.expires_at, s.auto_renew
        from public.user_subscriptions s
        join public.profiles prof on prof.id = s.user_id
        join public.subscription_plans pl on pl.id = s.plan_id
        left join public.pricing pr on pr.id = s.pricing_id
        order by s.created_at desc limit 5000) d;
    when 'payments' then
      return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
        select pay.id, prof.email, pay.amount, pay.currency, pay.provider,
               pay.provider_reference, pay.status::text as status, pay.paid_at, pay.created_at
        from public.payments pay
        join public.profiles prof on prof.id = pay.user_id
        order by pay.created_at desc limit 5000) d;
    when 'events' then
      return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
        select e.id, prof.email, e.event_type::text as event_type, e.metadata, e.created_at
        from public.subscription_events e
        left join public.profiles prof on prof.id = e.user_id
        order by e.created_at desc limit 5000) d;
    when 'ai_usage' then
      return coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) from (
        select prof.email, u.period_start, u.period_end, u.interaction_count
        from public.ai_usage u
        join public.profiles prof on prof.id = u.user_id
        order by u.period_start desc, prof.email limit 5000) d;
    else
      raise exception 'MAJOOP: type d''export inconnu (%). Attendu : subscriptions | payments | events | ai_usage', p_kind;
  end case;
end;
$$;

-- ============================================================
-- 6. SEED : plans officiels, grille tarifaire, réglages quotas
--    PRIX VALIDÉS COMMERCIALLY — ne pas modifier sans autorisation :
--      Free 0 · Premium 1 500 FCFA/mois · Premium 12 000 FCFA/an (≈1 000/mois,
--      économie 6 000 FCFA) · International 3 USD/mois · 24 USD/an.
--      XAF et XOF = devises distinctes (mêmes montants nominaux).
--      EUR : configurable via Administration → Monétisation (aucun prix inventé ici).
-- ============================================================

insert into public.subscription_plans (code, name, description, is_active) values
  ('free', 'Free',
   'Gratuit : 4 langues (anglais, français, espagnol, allemand), leçons gratuites, exercices de base, jeux éducatifs de base, XP, badges, séries quotidiennes, suivi de progression standard, 10 interactions IA par mois.', true),
  ('premium_monthly', 'Premium Mensuel',
   '1 500 FCFA par mois : tous les cours, tous les niveaux, tous les exercices, tous les jeux, professeur IA avec 100 interactions par mois, conversations personnalisées, corrections détaillées, explications grammaticales, historique complet des conversations, statistiques avancées, sans publicité.', true),
  ('premium_yearly', 'Premium Annuel',
   '12 000 FCFA par an (12 mois d''accès — prix mensuel équivalent 1 000 FCFA, économie de 6 000 FCFA) : mêmes avantages que le Premium mensuel.', true)
on conflict (code) do update set
  name = excluded.name, description = excluded.description, is_active = excluded.is_active;

-- Grille tarifaire (idempotent ; une seule ligne active par combinaison)
insert into public.pricing (plan_id, currency, amount, billing_interval, region, is_active)
select p.id, c.cur, c.amt, c.iv::public.billing_interval, c.reg, true
from public.subscription_plans p
join (values
  ('free',           'XAF',    0, 'monthly', 'zone_fcfa'),
  ('premium_monthly','XAF', 1500, 'monthly', 'zone_fcfa'),
  ('premium_monthly','XOF', 1500, 'monthly', 'zone_fcfa'),
  ('premium_monthly','USD',    3, 'monthly', 'international'),
  ('premium_yearly', 'XAF',12000, 'yearly',  'zone_fcfa'),
  ('premium_yearly', 'XOF',12000, 'yearly',  'zone_fcfa'),
  ('premium_yearly', 'USD',   24, 'yearly',  'international')
) as c(code, cur, amt, iv, reg) on c.code = p.code
where not exists (
  select 1 from public.pricing e
   where e.plan_id = p.id and e.currency = c.cur
     and e.billing_interval = c.iv::public.billing_interval
     and e.region = c.reg and e.is_active
);

-- Réglages quotas IA (configurables dans Administration → Monétisation)
insert into public.admin_settings (key, value, description) values
  ('ai_quota_free', '10', 'Interactions IA mensuelles — plan Free (décision commerciale : 10)')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('ai_quota_premium', '100', 'Interactions IA mensuelles — plans Premium (décision commerciale : 100)')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('ai_max_message_chars', '2000', 'Taille maximale d''un message envoyé à l''IA (caractères)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('ai_max_output_tokens', '600', 'Tokens max de la réponse IA (maîtrise des coûts)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('ai_cost_estimate_fcfa_per_interaction', '25', 'Estimation configurable du coût moyen d''une interaction IA (FCFA) — sert aux statistiques, ne remplace pas une facture')
on conflict (key) do update set description = excluded.description;

-- Garde anti-abus journalière : relevée de 20 à 60 (le quota mensuel par plan
-- devient la limite principale ; ce plafond reste un garde-fou configurable)
insert into public.admin_settings (key, value, description) values
  ('ai_daily_quota', '60', 'Garde anti-abus : messages IA max par utilisateur et par jour (la limite principale est le quota mensuel par plan)')
on conflict (key) do update set value = excluded.value, description = excluded.description;

-- Instructions de paiement manuel (À CONFIGURER par l''administrateur)
insert into public.admin_settings (key, value, description) values
  ('payment_instructions', '{"XAF":{"method":"Mobile Money ou dépôt bancaire","details":"À configurer : Administration → Monétisation → Paiement manuel (numéro à créditer, nom du bénéficiaire)."},"XOF":{"method":"Mobile Money ou dépôt bancaire","details":"À configurer par l''administrateur."},"USD":{"method":"Wire transfer","details":"To be configured by the administrator."},"EUR":{"method":"Virement bancaire","details":"À configurer par l''administrateur."}}'::jsonb,
   'Instructions de paiement manuel par devise (modifiées via admin_set_setting)')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('default_display_currency', '"XAF"', 'Devise d''affichage par défaut de la page Tarifs (XAF | XOF | USD | EUR)')
on conflict (key) do update set description = excluded.description;

-- ============================================================
-- 7. PRIVILÈGES RPC
-- ============================================================

revoke all on function public.user_effective_plan(uuid) from public, anon, authenticated;
grant execute on function public.user_effective_plan(uuid) to authenticated, service_role;
revoke all on function public.user_is_premium(uuid) from public, anon, authenticated;
grant execute on function public.user_is_premium(uuid) to authenticated, service_role;

revoke all on function public.expire_due_subscriptions() from public, anon, authenticated;
grant execute on function public.expire_due_subscriptions() to authenticated, service_role;

revoke all on function public.ai_refund_quota(uuid) from public, anon, authenticated;
grant execute on function public.ai_refund_quota(uuid) to service_role;

revoke all on function public.my_ai_quota() from public, anon;
grant execute on function public.my_ai_quota() to authenticated;
revoke all on function public.my_subscription() from public, anon;
grant execute on function public.my_subscription() to authenticated;
revoke all on function public.get_payment_instructions() from public, anon;
grant execute on function public.get_payment_instructions() to authenticated;
revoke all on function public.submit_manual_payment(uuid, text, text) from public, anon;
grant execute on function public.submit_manual_payment(uuid, text, text) to authenticated;
revoke all on function public.user_cancel_renewal() from public, anon;
grant execute on function public.user_cancel_renewal() to authenticated;

-- Administration : utilisateurs authentifiés (vérification is_admin() interne)
revoke all on function public.admin_list_plans() from public, anon;
grant execute on function public.admin_list_plans() to authenticated;
revoke all on function public.admin_set_plan_active(uuid, boolean) from public, anon;
grant execute on function public.admin_set_plan_active(uuid, boolean) to authenticated;
revoke all on function public.admin_add_pricing(uuid, text, numeric, public.billing_interval, text) from public, anon;
grant execute on function public.admin_add_pricing(uuid, text, numeric, public.billing_interval, text) to authenticated;
revoke all on function public.admin_deactivate_pricing(uuid) from public, anon;
grant execute on function public.admin_deactivate_pricing(uuid) to authenticated;
revoke all on function public.admin_list_subscriptions(int, int, text) from public, anon;
grant execute on function public.admin_list_subscriptions(int, int, text) to authenticated;
revoke all on function public.admin_list_payments(text, int) from public, anon;
grant execute on function public.admin_list_payments(text, int) to authenticated;
revoke all on function public.admin_confirm_payment(uuid) from public, anon;
grant execute on function public.admin_confirm_payment(uuid) to authenticated;
revoke all on function public.admin_reject_payment(uuid, text) from public, anon;
grant execute on function public.admin_reject_payment(uuid, text) to authenticated;
revoke all on function public.admin_set_ai_quota(int, int) from public, anon;
grant execute on function public.admin_set_ai_quota(int, int) to authenticated;
revoke all on function public.admin_monetization_stats() from public, anon;
grant execute on function public.admin_monetization_stats() to authenticated;
revoke all on function public.admin_export_monetization(text) from public, anon;
grant execute on function public.admin_export_monetization(text) to authenticated;

-- NB : ai_consume_quota(uuid, text) conserve son grant service_role existant
-- (CREATE OR REPLACE préserve les privilèges). Rappel : 003 l'accorde à service_role.

do $$ begin
  raise notice 'MAJOOP 007 : monétisation installée (plans, tarifs, quotas IA, RPC admin)';
end $$;

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 7/10 — 005_tests_securite.sql
-- TESTS SÉCURITÉ — échoue bruyamment (exception) si un test ne passe pas ; supprime ses utilisateurs de test à la fin. Attendu : ✅ TOUS LES TESTS DE SÉCURITÉ SONT PASSÉS.
-- ██████████████████████████████████████████████████████████████████████████

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

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 8/10 — 008_tests_monetisation.sql
-- TESTS MONÉTISATION — 14 tests (prix immuables, quotas, flux de paiement…) ; auto-nettoyant. Attendu : ✅ TOUS LES TESTS DE MONÉTISATION SONT PASSÉS.
-- ██████████████████████████████████████████████████████████████████████████

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

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 9/10 — 009_concours_hebdomadaire.sql
-- V2 SANS GRATUIT + CONCOURS — free désactivé, Inscription Mensuelle 3 000 F / Annuelle 30 000 F, tables concours, RPC (leaderboard, my rank, overview, clôture admin, gains payés), réglages cagnotte 25 000 F.
-- ██████████████████████████████████████████████████████████████████████████

-- ============================================================
-- MAJOOP — Migration 009 : NOUVEAU MODÈLE (sans gratuit)
--                                      + CONCOURS HEBDOMADAIRE
-- Exécution : APRÈS 001→008 (Supabase SQL Editor ou pooler)
-- Idempotent : ré-exécutable sans dupliquer ni casser les prix.
--
-- Modèle décidé (2026-11-17) :
--   • PLUS de plan gratuit : l'inscription démarre à 3 000 F.
--   • Inscription Mensuelle : 3 000 F/mois (XAF/XOF) — 6 USD international.
--   • Inscription Annuelle  : 30 000 F/an (≈ 2 500 F/mois, −6 000 F) — 60 USD.
--   • CONCOURS HEBDOMADAIRE : cagnotte de 25 000 F chaque semaine répartie
--     🥇 1er 15 000 F · 🥈 2e 6 000 F · 🥉 3e 4 000 F.
--     Classement = XP gagnés du lundi 00:00 UTC au dimanche minuit UTC,
--     réservés aux utilisateurs dont l'inscription est ACTIVE (premium).
--     Paiement des gains par Mobile Money sous 72 h après clôture.
-- ============================================================

-- ------------------------------------------------------------
-- 1. PLANS : plus de gratuit, nouvelles appellations et prix
--    (pricing : les lignes actives sont immuables → on désactive
--    les anciennes et on crée les nouvelles, historique conservé)
-- ------------------------------------------------------------
update public.subscription_plans set
  is_active = false,
  description = 'Plan gratuit retiré (modèle « sans gratuit » depuis 2026-11-17) : l''accès requiert une inscription à partir de 3 000 F.'
where code = 'free';

update public.subscription_plans set
  name = 'Inscription Mensuelle',
  description = '3 000 F par mois : accès complet (tous les cours, niveaux, exercices, jeux, 100 interactions IA/mois) + participation au CONCOURS HEBDOMADAIRE : 25 000 F aux meilleurs chaque semaine (🥇 15 000 · 🥈 6 000 · 🥉 4 000).'
where code = 'premium_monthly';

update public.subscription_plans set
  name = 'Inscription Annuelle',
  description = '30 000 F par an (12 mois — équivalent 2 500 F/mois, économie de 6 000 F) : mêmes avantages que l''Inscription Mensuelle, concours hebdomadaire inclus.'
where code = 'premium_yearly';

-- Anciennes lignes actives (0 / 1500 / 12000 / 3 / 24) → désactivées.
-- Idempotent : les nouvelles lignes (3000/30000/6/60) ne sont pas touchées.
update public.pricing set is_active = false, updated_at = now()
where is_active
  and plan_id in (select id from public.subscription_plans
                  where code in ('free','premium_monthly','premium_yearly'))
  and amount in (0, 1500, 12000, 3, 24);

-- Nouvelle grille (idempotent — une seule ligne active par combinaison)
insert into public.pricing (plan_id, currency, amount, billing_interval, region, is_active)
select p.id, c.cur, c.amt, c.iv::public.billing_interval, c.reg, true
from public.subscription_plans p
join (values
  ('premium_monthly','XAF', 3000, 'monthly', 'zone_fcfa'),
  ('premium_monthly','XOF', 3000, 'monthly', 'zone_fcfa'),
  ('premium_monthly','USD',    6, 'monthly', 'international'),
  ('premium_yearly', 'XAF',30000, 'yearly',  'zone_fcfa'),
  ('premium_yearly', 'XOF',30000, 'yearly',  'zone_fcfa'),
  ('premium_yearly', 'USD',   60, 'yearly',  'international')
) as c(code, cur, amt, iv, reg) on c.code = p.code
where not exists (
  select 1 from public.pricing e
   where e.plan_id = p.id and e.currency = c.cur
     and e.billing_interval = c.iv::public.billing_interval
     and e.region = c.reg and e.is_active
);

-- ------------------------------------------------------------
-- 2. TABLES DU CONCOURS + RLS (lecture uniquement via RPC DEFINER)
-- ------------------------------------------------------------
create table if not exists public.competition_weeks (
  week_start date primary key
    check (extract(isodow from week_start) = 1),   -- toujours un lundi (UTC)
  prize_pool int  not null default 25000 check (prize_pool >= 0),
  status     text not null default 'open'
    check (status in ('open','distributed','cancelled')),
  closed_at  timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.competition_winners (
  id                uuid primary key default gen_random_uuid(),
  week_start        date not null references public.competition_weeks(week_start) on delete cascade,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  rank              int  not null check (rank between 1 and 3),
  prize_amount      int  not null check (prize_amount >= 0),
  status            text not null default 'pending'
    check (status in ('pending','paid','cancelled')),
  payment_channel   text not null default '',   -- ex. Orange Money / MTN MoMo
  payment_reference text not null default '',   -- réf. de transfert des gains
  paid_at           timestamptz,
  created_at        timestamptz not null default now(),
  unique (week_start, rank)
);

alter table public.competition_weeks   enable row level security;
alter table public.competition_winners enable row level security;
-- Aucune policy : accès exclusivement via les RPC SECURITY DEFINER
-- (la liste des gagnants est publiée par get_competition_overview).
revoke all on public.competition_weeks   from anon, authenticated;
revoke all on public.competition_winners from anon, authenticated;

create index if not exists idx_xp_events_week
  on public.xp_events (user_id, created_at);
create index if not exists idx_winners_user
  on public.competition_winners (user_id);

-- ------------------------------------------------------------
-- 3. FONCTIONS DU CONCOURS
-- ------------------------------------------------------------

-- Lundi (UTC) de la semaine contenant p_date (défaut : semaine courante).
create or replace function public.current_week_start(p_date date default null)
returns date language sql immutable as $$
  select coalesce(p_date, current_date)
         - ((extract(isodow from coalesce(p_date, current_date))::int - 1));
$$;

-- Classement hebdomadaire (top 50) : XP gagnés pendant la semaine parmi
-- les utilisateurs dont l'INSCRIPTION EST ACTIVE (premium). Public :
-- affiché sur la page Concours (noms + XP uniquement, jamais d'e-mails).
create or replace function public.get_weekly_leaderboard(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ws date := public.current_week_start(p_week_start);
begin
  if p_week_start is not null and p_week_start > public.current_week_start() then
    raise exception 'MAJOOP: semaine future invalide';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'rank', r.rank, 'user_id', r.user_id, 'name', r.name,
             'weekly_xp', r.weekly_xp, 'days_active', r.days_active,
             'is_me', coalesce(r.user_id = auth.uid(), false)
           ) order by r.rank)
    from (
      select row_number() over (
               order by a.weekly_xp desc, a.days_active desc, a.first_xp asc
             ) as rank,
             a.user_id, a.weekly_xp, a.days_active,
             coalesce(nullif(btrim(p.first_name), ''),
                      split_part(p.email, '@', 1)) as name
      from (
        select x.user_id,
               sum(x.xp)::int as weekly_xp,
               count(distinct x.created_at::date)::int as days_active,
               min(x.created_at) as first_xp
        from public.xp_events x
        where x.created_at >= v_ws::timestamptz
          and x.created_at <  (v_ws + 7)::timestamptz
          and public.user_effective_plan(x.user_id) like 'premium%'
        group by x.user_id
      ) a
      join public.profiles p on p.id = a.user_id
      order by a.weekly_xp desc, a.days_active desc, a.first_xp asc
      limit 50
    ) r
  ), '[]'::jsonb);
end;
$$;

-- Ma position de la semaine : éligible ?, rang, écart au podium.
create or replace function public.get_my_weekly_rank(p_week_start date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_ws   date := public.current_week_start(p_week_start);
  v_me   record;
  v_podium int;
begin
  if v_user is null then raise exception 'MAJOOP: authentification requise'; end if;
  if public.user_effective_plan(v_user) not like 'premium%' then
    return jsonb_build_object('eligible', false, 'week_start', v_ws,
                              'weekly_xp', 0, 'rank', null, 'gap_to_podium', null);
  end if;

  select a.weekly_xp, a.rank into v_me
  from (
    select g.user_id, g.weekly_xp, g.first_xp,
           row_number() over (
             order by g.weekly_xp desc, g.days_active desc, g.first_xp asc
           ) as rank
    from (
      select x.user_id, sum(x.xp)::int as weekly_xp,
             count(distinct x.created_at::date)::int as days_active,
             min(x.created_at) as first_xp
      from public.xp_events x
      where x.created_at >= v_ws::timestamptz
        and x.created_at <  (v_ws + 7)::timestamptz
        and public.user_effective_plan(x.user_id) like 'premium%'
      group by x.user_id
    ) g
  ) a
  where a.user_id = v_user;

  select weekly_xp into v_podium
  from (
    select sum(x.xp)::int as weekly_xp
    from public.xp_events x
    where x.created_at >= v_ws::timestamptz
      and x.created_at <  (v_ws + 7)::timestamptz
      and public.user_effective_plan(x.user_id) like 'premium%'
    group by x.user_id
    order by weekly_xp desc, min(x.created_at) asc
    offset 2 limit 1
  ) podium;

  return jsonb_build_object(
    'eligible', true, 'week_start', v_ws,
    'weekly_xp', coalesce(v_me.weekly_xp, 0),
    'rank', coalesce(v_me.rank, null::int),
    'gap_to_podium',
      case when v_me.rank is not null and v_me.rank > 3 and v_podium is not null
           then v_podium - coalesce(v_me.weekly_xp, 0) else null end
  );
end;
$$;

-- Vue d'ensemble publique (page Concours + règles affichées).
create or replace function public.get_competition_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_ws  date := public.current_week_start();
  v_top jsonb;
begin
  v_top := coalesce((
    select jsonb_agg(w) from (
      select * from jsonb_to_recordset(public.get_weekly_leaderboard(v_ws)) as t(
        rank int, user_id uuid, name text, weekly_xp int, days_active int, is_me boolean)
      where rank <= 3
    ) w
  ), '[]'::jsonb);

  return jsonb_build_object(
    'week_start', v_ws,
    'closes_at',  (v_ws + 7)::timestamptz - interval '1 second',
    'enabled',    coalesce(public.get_setting('competition_enabled', 'true'::jsonb)::text, 'true') <> 'false',
    'prize_pool', coalesce(public.get_setting('competition_prize_pool', '25000'::jsonb)::text, '25000')::int,
    'split',      public.get_setting('competition_prize_split',
                                     '{"1":15000,"2":6000,"3":4000}'::jsonb),
    'status',     coalesce((select status from public.competition_weeks
                            where week_start = v_ws), 'open'),
    'top3',       v_top
  );
end;
$$;

-- Clôture d'une semaine terminée : fige le podium et crée les gains
-- (idempotent — ré-exécuter ne duplique rien et ne touche pas aux 'paid').
create or replace function public.admin_close_competition_week(p_week_start date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ws  date := public.current_week_start(p_week_start);
  v_split jsonb := public.get_setting('competition_prize_split',
                                      '{"1":15000,"2":6000,"3":4000}'::jsonb);
  v_pool  int := coalesce(public.get_setting('competition_prize_pool', '25000'::jsonb)::text, '25000')::int;
  v_top   record;
  v_out   jsonb := '[]'::jsonb;
  v_newid uuid;
begin
  if not public.is_admin() then
    raise exception 'MAJOOP: accès administrateur requis';
  end if;
  if (v_ws + 7)::timestamptz > now() then
    raise exception 'MAJOOP: la semaine % n''est pas encore terminée (elle se termine le % UTC)',
                    v_ws, (v_ws + 7)::timestamptz;
  end if;
  if coalesce(public.get_setting('competition_enabled', 'true'::jsonb)::text, 'true') = 'false' then
    raise exception 'MAJOOP: concours désactivé (competition_enabled=false)';
  end if;

  insert into public.competition_weeks (week_start, prize_pool, status, closed_at)
  values (v_ws, v_pool, 'distributed', now())
  on conflict (week_start) do update
    set status = 'distributed', closed_at = now(),
        prize_pool = excluded.prize_pool;

  for v_top in
    select a.user_id,
           row_number() over (
             order by a.weekly_xp desc, a.days_active desc, a.first_xp asc
           ) as rank
    from (
      select x.user_id, sum(x.xp)::int as weekly_xp,
             count(distinct x.created_at::date)::int as days_active,
             min(x.created_at) as first_xp
      from public.xp_events x
      where x.created_at >= v_ws::timestamptz
        and x.created_at <  (v_ws + 7)::timestamptz
        and public.user_effective_plan(x.user_id) like 'premium%'
      group by x.user_id
    ) a
    join public.profiles p on p.id = a.user_id
    limit 3
  loop
    v_newid := null;
    insert into public.competition_winners
      (week_start, user_id, rank, prize_amount, status)
    values (v_ws, v_top.user_id, v_top.rank,
            coalesce((v_split ->> v_top.rank::text)::int, 0), 'pending')
    on conflict (week_start, rank) do nothing
    returning id into v_newid;
    if v_newid is not null then
      v_out := v_out || jsonb_build_object(
        'rank', v_top.rank, 'user_id', v_top.user_id,
        'prize_amount', coalesce((v_split ->> v_top.rank::text)::int, 0),
        'status', 'pending');
    end if;
  end loop;

  return jsonb_build_object('week_start', v_ws, 'winners', v_out);
end;
$$;

-- Marquer un gain comme payé (Mobile Money / espèces) avec référence.
create or replace function public.admin_mark_winner_paid(
  p_winner_id uuid, p_channel text default '', p_reference text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_w record;
begin
  if not public.is_admin() then
    raise exception 'MAJOOP: accès administrateur requis';
  end if;
  update public.competition_winners
     set status = 'paid', payment_channel = left(btrim(p_channel), 60),
         payment_reference = left(btrim(p_reference), 120), paid_at = now()
   where id = p_winner_id and status = 'pending'
   returning * into v_w;
  if not found then
    raise exception 'MAJOOP: gagnant introuvable ou déjà payé';
  end if;
  return jsonb_build_object('id', v_w.id, 'week_start', v_w.week_start,
    'rank', v_w.rank, 'prize_amount', v_w.prize_amount, 'status', v_w.status,
    'payment_channel', v_w.payment_channel, 'payment_reference', v_w.payment_reference);
end;
$$;

-- Historique des semaines (Administration → Concours).
create or replace function public.admin_list_competition_weeks(p_limit int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'MAJOOP: accès administrateur requis';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'week_start', w.week_start, 'prize_pool', w.prize_pool,
      'status', w.status, 'closed_at', w.closed_at,
      'winners', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'rank', v.rank, 'user_id', v.user_id,
                 'name', coalesce(nullif(btrim(p.first_name), ''),
                                  split_part(p.email, '@', 1)),
                 'prize_amount', v.prize_amount, 'status', v.status,
                 'payment_channel', v.payment_channel,
                 'payment_reference', v.payment_reference, 'paid_at', v.paid_at
               ) order by v.rank)
        from public.competition_winners v
        join public.profiles p on p.id = v.user_id
        where v.week_start = w.week_start
      ), '[]'::jsonb)
    ) order by w.week_start desc)
    from (select * from public.competition_weeks
          order by week_start desc
          limit greatest(least(coalesce(p_limit, 12), 52), 1)) w
  ), '[]'::jsonb);
end;
$$;

-- ------------------------------------------------------------
-- 4. PRIVILÈGES : public (anon + authentifié) pour la lecture du
--    concours ; admin_* réservés aux appelants authentifiés
--    (la garde is_admin() est TOUJOURS revérifiée dans la fonction).
-- ------------------------------------------------------------
revoke all on function public.current_week_start(date)              from public;
revoke all on function public.get_weekly_leaderboard(date)          from public;
revoke all on function public.get_my_weekly_rank(date)              from public;
revoke all on function public.get_competition_overview()            from public;
revoke all on function public.admin_close_competition_week(date)    from public;
revoke all on function public.admin_mark_winner_paid(uuid,text,text) from public;
revoke all on function public.admin_list_competition_weeks(int)     from public;

grant execute on function public.current_week_start(date)            to anon, authenticated;
grant execute on function public.get_weekly_leaderboard(date)        to anon, authenticated;
grant execute on function public.get_my_weekly_rank(date)            to authenticated;
grant execute on function public.get_competition_overview()          to anon, authenticated;
grant execute on function public.admin_close_competition_week(date)  to authenticated;
grant execute on function public.admin_mark_winner_paid(uuid,text,text) to authenticated;
grant execute on function public.admin_list_competition_weeks(int)   to authenticated;

-- ------------------------------------------------------------
-- 5. RÉGLAGES du concours (Administration → Monétisation)
-- ------------------------------------------------------------
insert into public.admin_settings (key, value, description) values
  ('competition_prize_pool', '25000',
   'Cagnotte hebdomadaire en FCFA (décision commerciale : 25 000 F chaque semaine)')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('competition_prize_split', '{"1":15000,"2":6000,"3":4000}',
   'Répartition de la cagnotte par rang : 1er 15 000 F, 2e 6 000 F, 3e 4 000 F')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('competition_enabled', 'true',
   'Concours hebdomadaire activé (false = suspendre les clôtures et les gains)')
on conflict (key) do update set description = excluded.description;

insert into public.admin_settings (key, value, description) values
  ('ai_quota_free', '10',
   'Plan gratuit RETIRÉ (sans gratuit) — conservé pour compatibilité, sans effet')
on conflict (key) do update set description = excluded.description;

do $$ begin raise notice '✅ 009 appliqué : sans gratuit (inscription dès 3 000 F) + concours hebdomadaire 25 000 F (15 000/6 000/4 000)'; end $$;

-- ██████████████████████████████████████████████████████████████████████████
-- SECTION 10/10 — 010_tests_concours.sql
-- TESTS CONCOURS — éligibilité (non-inscrits exclus), guards admin, clôture idempotente, gains 15 000/6 000/4 000, anon lecture seule ; auto-nettoyant. Attendu : ✅ TOUS LES TESTS DU CONCOURS SONT PASSÉS.
-- ██████████████████████████████████████████████████████████████████████████

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
