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
