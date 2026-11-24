-- ============================================================
-- MAJOOP — 013_chantiers_pdf.sql
-- Implémentation des chantiers 1, 2 et 3 recommandés par le rapport
-- d'analyse (section 7.2), dans l'ordre conseillé :
--
--   §1  CHANTIER 1 — Durcissement serveur des limites du Plan Découverte :
--       get_lesson_content ne renvoie le contenu complet qu'aux abonnés
--       actifs (et aux administrateurs) ; sinon, uniquement la 1re leçon
--       (1er module) de chaque cours. Le contournement côté navigateur
--       ne sert plus rien.
--
--   §2  CHANTIER 2 — Vérification de paiement assistée : table des
--       contrôles + RPC utilisateur et administrateur. La vérification
--       AUTOMATIQUE est faite par l'Edge Function verify-payment
--       (MTN MoMo) si les secrets sont configurés ; sinon repli manuel
--       (l'administrateur reste le filet, plus le goulot d'étranglement).
--
--   §3  CHANTIER 3 — Mesure : journal d'événements respectueux des
--       données (tout reste dans Supabase, aucun traceur tiers) + RPC
--       administrateur des 3 KPI prioritaires du rapport.
--
--   §4  PROMOTION ADMINISTRATEUR — à exécuter avec TON adresse e-mail.
--
-- IDEMPOTENT : relançable sans risque. Exécuter dans Supabase → SQL Editor.
-- ============================================================

-- ============================================================
-- §1 — CHANTIER 1 : contenu de leçon filtré par plan
-- ============================================================
create or replace function public.get_lesson_content(p_lesson uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_l public.lessons;
  v_premium boolean;
  v_free_lesson uuid;
begin
  if v_uid is null then raise exception 'MAJOOP: authentification requise'; end if;

  select * into v_l from public.lessons where id = p_lesson and is_published;
  if not found then raise exception 'MAJOOP: lecon introuvable'; end if;

  -- Abonnement actif non expiré, ou administrateur
  select exists (
    select 1 from public.user_subscriptions s
     where s.user_id = v_uid and s.status = 'active' and s.expires_at > now()
  ) or public.is_admin() into v_premium;

  if not v_premium then
    -- Plan Découverte : uniquement la 1re leçon (1er module) de chaque cours
    select l2.id into v_free_lesson
      from public.modules m
      join public.lessons l2 on l2.module_id = m.id
     where m.id = (select module_id from public.lessons where id = p_lesson)
       and m.sort_order = (select min(m2.sort_order) from public.modules m2
                            where m2.course_id = m.course_id)
     order by l2.sort_order asc, l2.created_at asc
     limit 1;
    if v_free_lesson is null or v_free_lesson <> p_lesson then
      raise exception 'MAJOOP: lecon verrouillee (Plan Decouverte) - abonnement requis';
    end if;
  end if;

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
revoke all on function public.get_lesson_content(uuid) from public, anon;
grant execute on function public.get_lesson_content(uuid) to authenticated;

-- ============================================================
-- §2 — CHANTIER 2 : vérification de paiement assistée
-- ============================================================
create table if not exists public.payment_checks (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  reference   text not null,
  provider    text not null default 'mtn_momo',
  status      text not null default 'pending'
              check (status in ('pending','auto_verified','auto_rejected','manual_verified','manual_rejected')),
  details     jsonb not null default '{}',
  checked_at  timestamptz,
  created_at  timestamptz not null default now()
);
alter table public.payment_checks enable row level security;
drop policy if exists pc_select on public.payment_checks;
create policy pc_select on public.payment_checks for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists pc_insert on public.payment_checks;
create policy pc_insert on public.payment_checks for insert to authenticated
  with check (user_id = auth.uid());

-- L'utilisateur demande un contrôle automatique de sa référence
create or replace function public.request_payment_check(p_reference text, p_provider text default 'mtn_momo')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'MAJOOP: authentification requise'; end if;
  if p_reference is null or length(btrim(p_reference)) < 4 then
    raise exception 'MAJOOP: reference de paiement invalide';
  end if;
  insert into public.payment_checks(user_id, reference, provider)
  values (auth.uid(), btrim(p_reference), p_provider)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$$;
revoke all on function public.request_payment_check(text, text) from public, anon;
grant execute on function public.request_payment_check(text, text) to authenticated;

-- File des contrôles (côté administrateur)
create or replace function public.admin_list_payment_checks(p_limit int default 50)
returns setof public.payment_checks language sql security definer set search_path = public as $$
  select * from public.payment_checks where public.is_admin()
  order by created_at desc limit greatest(1, least(p_limit, 200));
$$;
revoke all on function public.admin_list_payment_checks(int) from public, anon;
grant execute on function public.admin_list_payment_checks(int) to authenticated;

-- Décision de l'administrateur (ou résultat automatique propagé par l'Edge Function)
create or replace function public.admin_resolve_payment_check(p_id uuid, p_new_status text, p_note jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces administrateur requis'; end if;
  if p_new_status not in ('auto_verified','auto_rejected','manual_verified','manual_rejected') then
    raise exception 'MAJOOP: statut invalide';
  end if;
  update public.payment_checks
     set status = p_new_status, details = details || p_note, checked_at = now()
   where id = p_id;
  if not found then raise exception 'MAJOOP: controle introuvable'; end if;
  -- Rappel : l'activation effective de l'abonnement suit le flux existant
  -- (onglet Monétisation de la page Administration, table payments).
end;
$$;
revoke all on function public.admin_resolve_payment_check(uuid, text, jsonb) from public, anon;
grant execute on function public.admin_resolve_payment_check(uuid, text, jsonb) to authenticated;

-- ============================================================
-- §3 — CHANTIER 3 : mesure (événements + 3 KPI)
-- ============================================================
create table if not exists public.app_events (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete set null,
  name       text not null,
  meta       jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists idx_app_events_name on public.app_events(name, created_at);
alter table public.app_events enable row level security;
drop policy if exists ae_select_admin on public.app_events;
create policy ae_select_admin on public.app_events for select to authenticated
  using (public.is_admin());

-- Tout utilisateur journalise ses propres événements (aucune donnée sensible)
create or replace function public.track_event(p_name text, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if length(btrim(p_name)) = 0 or length(p_name) > 64 then
    raise exception 'MAJOOP: nom d''evenement invalide';
  end if;
  insert into public.app_events(user_id, name, meta) values (auth.uid(), btrim(p_name), p_meta);
end;
$$;
revoke all on function public.track_event(text, jsonb) from public, anon;
grant execute on function public.track_event(text, jsonb) to authenticated;

-- Les 3 KPI prioritaires du rapport (réservés aux administrateurs)
create or replace function public.admin_kpis()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_started int;
  v_completed int;
  v_signups int;
  v_converted int;
  v_free_users int;
  v_interactions numeric;
  v_cost_unit numeric;
begin
  if not public.is_admin() then raise exception 'MAJOOP: acces administrateur requis'; end if;

  -- KPI 1 : taux de complétion de la première leçon gratuite
  select count(distinct user_id) into v_started
    from public.app_events where name = 'first_lesson_started';
  select count(distinct user_id) into v_completed
    from public.app_events where name = 'first_lesson_completed';
  v_started := coalesce(v_started, 0);
  v_completed := coalesce(v_completed, 0);

  -- KPI 2 : conversion gratuit → payant à 7 jours (abonnement actif démarré
  --         dans les 7 jours suivant la création du compte)
  select count(*) into v_signups
    from public.profiles
   where created_at >= now() - interval '90 days';
  select count(*) into v_converted
    from public.profiles p
   where p.created_at >= now() - interval '90 days'
     and exists (select 1 from public.user_subscriptions s
                  where s.user_id = p.id and s.status = 'active'
                    and coalesce(s.started_at, s.created_at) <= p.created_at + interval '7 days');
  v_signups := coalesce(v_signups, 0);
  v_converted := coalesce(v_converted, 0);

  -- KPI 3 : interactions IA par utilisateur gratuit ce mois-ci
  --         (coût = interactions × coût unitaire, réglable dans
  --          Administration → Réglages : admin_settings 'ai_cost_per_interaction',
  --          exprimé en FCFA ; 0 par défaut tant que le tarif réel n'est pas connu)
  select coalesce((select value::text::numeric from public.admin_settings
                    where key = 'ai_cost_per_interaction' limit 1), 0) into v_cost_unit;
  select count(distinct u.id) into v_free_users
    from public.profiles u
   where not exists (select 1 from public.user_subscriptions s
                      where s.user_id = u.id and s.status = 'active' and s.expires_at > now())
     and not public.is_admin();
  select coalesce(sum(a.interaction_count), 0) into v_interactions
    from public.ai_usage a
    join public.profiles u on u.id = a.user_id
   where a.period_start >= date_trunc('month', now())::date
     and not exists (select 1 from public.user_subscriptions s
                      where s.user_id = u.id and s.status = 'active' and s.expires_at > now())
     and not u.is_admin;
  v_free_users := coalesce(v_free_users, 0);
  v_interactions := coalesce(v_interactions, 0);

  return jsonb_build_object(
    'first_lesson', jsonb_build_object(
      'started', v_started, 'completed', v_completed,
      'rate_pct', case when v_started > 0 then round(100.0 * v_completed / v_started, 1) else null end),
    'conversion_7d', jsonb_build_object(
      'signups_90d', v_signups, 'converted', v_converted,
      'rate_pct', case when v_signups > 0 then round(100.0 * v_converted / v_signups, 1) else null end),
    'ai_cost_per_free_user', jsonb_build_object(
      'free_users', v_free_users, 'interactions_month', v_interactions,
      'cost_unit_xaf', v_cost_unit,
      'cost_per_user_xaf', case when v_free_users > 0
        then round(v_interactions * v_cost_unit / v_free_users, 0) else null end)
  );
end;
$$;
revoke all on function public.admin_kpis() from public, anon;
grant execute on function public.admin_kpis() to authenticated;

-- Coût unitaire IA (FCFA) — réglable depuis Administration → Réglages
insert into public.admin_settings(key, value, description)
values ('ai_cost_per_interaction', 0,
        'Coût moyen d''une interaction IA en FCFA (utilisé par le KPI coût IA/utilisateur gratuit)')
on conflict (key) do nothing;

-- ============================================================
-- §4 — PROMOTION ADMINISTRATEUR (à exécuter avec TON adresse e-mail)
-- L'adresse doit correspondre au compte avec lequel tu te connectes.
-- Exemple (décommenter et remplacer) :
--   update public.profiles set is_admin = true where email = 'TON-EMAIL@EXEMPLE.COM';
-- Vérification :
--   select email, is_admin from public.profiles where is_admin;
-- ============================================================

-- Contrôles finaux attendus :
--   select public.get_lesson_content(<id d'une leçon non gratuite>) en tant
--   qu'utilisateur gratuit doit lever « lecon verrouillee » ;
--   select public.admin_kpis() en tant qu'admin renvoie les 3 KPI ;
--   select * from public.payment_checks limit 5;
