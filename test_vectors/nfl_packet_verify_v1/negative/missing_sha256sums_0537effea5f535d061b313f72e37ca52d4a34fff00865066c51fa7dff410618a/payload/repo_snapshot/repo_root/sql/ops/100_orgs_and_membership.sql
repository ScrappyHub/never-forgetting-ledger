-- ============================================
-- GI/PPI ORGS + MEMBERSHIP (CANONICAL V0)
-- File: sql/ops/100_orgs_and_membership.sql
-- ============================================

create extension if not exists pgcrypto;

create table if not exists public.gi_ppi_admins (
  user_id uuid primary key,
  created_at timestamptz not null default now(),
  note text not null default ''
);

create table if not exists public.gi_ppi_orgs (
  org_id uuid primary key default gen_random_uuid(),
  org_slug text not null unique,
  org_name text not null,
  created_at timestamptz not null default now(),
  created_by uuid null
);

create table if not exists public.gi_ppi_org_members (
  org_id uuid not null references public.gi_ppi_orgs(org_id) on delete cascade,
  user_id uuid not null,
  role text not null,
  status text not null,
  created_at timestamptz not null default now(),
  created_by uuid null,
  primary key (org_id, user_id),
  constraint gi_ppi_org_members_role_check
    check (role in ('owner','admin','member')),
  constraint gi_ppi_org_members_status_check
    check (status in ('active','invited','disabled'))
);

-- --------------------------------------------
-- RLS ENABLE
-- --------------------------------------------
alter table public.gi_ppi_admins enable row level security;
alter table public.gi_ppi_orgs enable row level security;
alter table public.gi_ppi_org_members enable row level security;

-- --------------------------------------------
-- POLICIES: ADMINS (no anon access)
-- --------------------------------------------
drop policy if exists gi_ppi_admins_no_anon on public.gi_ppi_admins;
create policy gi_ppi_admins_no_anon
on public.gi_ppi_admins
for all
to anon
using (false)
with check (false);

-- Optional: block authenticated direct access too (admin RPC will be SECURITY DEFINER)
drop policy if exists gi_ppi_admins_no_direct_auth on public.gi_ppi_admins;
create policy gi_ppi_admins_no_direct_auth
on public.gi_ppi_admins
for all
to authenticated
using (false)
with check (false);

-- --------------------------------------------
-- POLICIES: ORGS
-- - authenticated members can SELECT their org rows
-- - no direct INSERT/UPDATE/DELETE (RPC only)
-- --------------------------------------------
drop policy if exists gi_ppi_orgs_member_read on public.gi_ppi_orgs;
create policy gi_ppi_orgs_member_read
on public.gi_ppi_orgs
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_orgs.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

drop policy if exists gi_ppi_orgs_no_direct_mutation_anon on public.gi_ppi_orgs;
create policy gi_ppi_orgs_no_direct_mutation_anon
on public.gi_ppi_orgs
for all
to anon
using (false)
with check (false);

drop policy if exists gi_ppi_orgs_no_direct_insert_auth on public.gi_ppi_orgs;
create policy gi_ppi_orgs_no_direct_insert_auth
on public.gi_ppi_orgs
for insert
to authenticated
with check (false);

drop policy if exists gi_ppi_orgs_no_direct_update_auth on public.gi_ppi_orgs;
create policy gi_ppi_orgs_no_direct_update_auth
on public.gi_ppi_orgs
for update
to authenticated
using (false)
with check (false);

drop policy if exists gi_ppi_orgs_no_direct_delete_auth on public.gi_ppi_orgs;
create policy gi_ppi_orgs_no_direct_delete_auth
on public.gi_ppi_orgs
for delete
to authenticated
using (false);

-- --------------------------------------------
-- POLICIES: MEMBERS
-- - authenticated users can SELECT membership rows for orgs they belong to
-- - no direct INSERT/UPDATE/DELETE (RPC only)
-- --------------------------------------------
drop policy if exists gi_ppi_members_member_read on public.gi_ppi_org_members;
create policy gi_ppi_members_member_read
on public.gi_ppi_org_members
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_org_members.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

drop policy if exists gi_ppi_members_no_direct_mutation_anon on public.gi_ppi_org_members;
create policy gi_ppi_members_no_direct_mutation_anon
on public.gi_ppi_org_members
for all
to anon
using (false)
with check (false);

drop policy if exists gi_ppi_members_no_direct_insert_auth on public.gi_ppi_org_members;
create policy gi_ppi_members_no_direct_insert_auth
on public.gi_ppi_org_members
for insert
to authenticated
with check (false);

drop policy if exists gi_ppi_members_no_direct_update_auth on public.gi_ppi_org_members;
create policy gi_ppi_members_no_direct_update_auth
on public.gi_ppi_org_members
for update
to authenticated
using (false)
with check (false);

drop policy if exists gi_ppi_members_no_direct_delete_auth on public.gi_ppi_org_members;
create policy gi_ppi_members_no_direct_delete_auth
on public.gi_ppi_org_members
for delete
to authenticated
using (false);

-- --------------------------------------------
-- BOOTSTRAP: add your auth user as GI/PPI admin
-- --------------------------------------------
insert into public.gi_ppi_admins (user_id, note)
values ('a25d49d9-a77e-4ed0-9668-239af09c20f7'::uuid, 'bootstrap admin')
on conflict (user_id) do nothing;
