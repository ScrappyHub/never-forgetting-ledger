-- ============================================
-- GI/PPI CREDITS LEDGER (CANONICAL V0)
-- File: sql/ops/110_credits_ledger.sql
-- ============================================

create extension if not exists pgcrypto;

create table if not exists public.gi_ppi_credit_ledger (
  entry_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.gi_ppi_orgs(org_id) on delete cascade,
  delta_credits bigint not null,
  reason text not null,
  created_at timestamptz not null default now(),
  created_by uuid null
);

-- Append-only guard
create or replace function public._gi_ppi_credit_ledger_append_only_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'APPEND_ONLY_LEDGER: mutation forbidden on gi_ppi_credit_ledger';
end;
$$;

drop trigger if exists trg_gi_ppi_credit_ledger_append_only on public.gi_ppi_credit_ledger;
create trigger trg_gi_ppi_credit_ledger_append_only
before update or delete on public.gi_ppi_credit_ledger
for each row execute function public._gi_ppi_credit_ledger_append_only_guard();

-- Deterministic balance view
create or replace view public.gi_ppi_org_credit_balance as
select
  org_id,
  coalesce(sum(delta_credits), 0)::bigint as credits_balance
from public.gi_ppi_credit_ledger
group by org_id;

-- RLS
alter table public.gi_ppi_credit_ledger enable row level security;

-- Members can read their org’s ledger
drop policy if exists gi_ppi_credit_ledger_member_read on public.gi_ppi_credit_ledger;
create policy gi_ppi_credit_ledger_member_read
on public.gi_ppi_credit_ledger
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_credit_ledger.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

-- No direct insert for anon/authenticated (RPC only)
drop policy if exists gi_ppi_credit_ledger_no_direct_insert_anon on public.gi_ppi_credit_ledger;
create policy gi_ppi_credit_ledger_no_direct_insert_anon
on public.gi_ppi_credit_ledger
for insert
to anon
with check (false);

drop policy if exists gi_ppi_credit_ledger_no_direct_insert_auth on public.gi_ppi_credit_ledger;
create policy gi_ppi_credit_ledger_no_direct_insert_auth
on public.gi_ppi_credit_ledger
for insert
to authenticated
with check (false);
