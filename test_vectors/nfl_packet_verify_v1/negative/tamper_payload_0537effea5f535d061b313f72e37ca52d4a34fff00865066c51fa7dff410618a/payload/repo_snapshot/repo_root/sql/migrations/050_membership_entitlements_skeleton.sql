-- 050_membership_entitlements_skeleton.sql
-- Minimal org + membership + credits. No UI. No payments.

create table if not exists public.gi_ppi_organizations (
  org_id uuid primary key default gen_random_uuid(),
  org_name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.gi_ppi_org_members (
  org_id uuid not null references public.gi_ppi_organizations(org_id) on delete cascade,
  user_id uuid not null,
  role text not null check (role in ('owner','admin','member','service')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- Credits are append-only events, balance is computed.
create table if not exists public.gi_ppi_credit_events (
  event_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.gi_ppi_organizations(org_id) on delete cascade,
  delta_credits bigint not null,
  reason text not null,
  created_at timestamptz not null default now()
);

create or replace view public.v_gi_ppi_org_credit_balance as
select
  org_id,
  coalesce(sum(delta_credits),0)::bigint as credit_balance
from public.gi_ppi_credit_events
group by org_id;

grant select on public.v_gi_ppi_org_credit_balance to authenticated;

-- Optional: enforce "must have credits to evaluate" later as a policy rule,
-- not inside the evaluator. Keep evaluator pure.
