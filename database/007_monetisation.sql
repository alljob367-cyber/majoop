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