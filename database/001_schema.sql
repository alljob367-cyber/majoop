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
