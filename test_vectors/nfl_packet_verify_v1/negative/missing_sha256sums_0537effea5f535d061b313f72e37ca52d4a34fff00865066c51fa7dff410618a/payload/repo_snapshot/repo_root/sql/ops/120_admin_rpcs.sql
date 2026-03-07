-- ============================================
-- GI/PPI ADMIN RPCs (CANONICAL V0)
-- File: sql/ops/120_admin_rpcs.sql
-- ============================================

create or replace function public._gi_ppi_require_admin()
returns void
language plpgsql
as $$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (select 1 from public.gi_ppi_admins a where a.user_id = auth.uid()) then
    raise exception 'ADMIN_REQUIRED';
  end if;
end;
$$;

-- Admin: create org + set creator as owner(active)
create or replace function public.gi_ppi_admin_create_org(
  p_org_slug text,
  p_org_name text
)
returns table (
  org_id uuid,
  org_slug text,
  org_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  perform public._gi_ppi_require_admin();

  if p_org_slug is null or btrim(p_org_slug) = '' then
    raise exception 'INVALID_ORG_SLUG';
  end if;

  if p_org_name is null or btrim(p_org_name) = '' then
    raise exception 'INVALID_ORG_NAME';
  end if;

  insert into public.gi_ppi_orgs (org_slug, org_name, created_by)
  values (p_org_slug, p_org_name, auth.uid())
  returning gi_ppi_orgs.org_id into v_org_id;

  insert into public.gi_ppi_org_members (org_id, user_id, role, status, created_by)
  values (v_org_id, auth.uid(), 'owner', 'active', auth.uid());

  return query
  select v_org_id, p_org_slug, p_org_name;
end;
$$;

-- Admin: set member role/status
create or replace function public.gi_ppi_admin_set_member(
  p_org_id uuid,
  p_user_id uuid,
  p_role text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._gi_ppi_require_admin();

  if p_org_id is null then raise exception 'INVALID_ORG_ID'; end if;
  if p_user_id is null then raise exception 'INVALID_USER_ID'; end if;

  if p_role not in ('owner','admin','member') then
    raise exception 'INVALID_ROLE';
  end if;

  if p_status not in ('active','invited','disabled') then
    raise exception 'INVALID_STATUS';
  end if;

  insert into public.gi_ppi_org_members (org_id, user_id, role, status, created_by)
  values (p_org_id, p_user_id, p_role, p_status, auth.uid())
  on conflict (org_id, user_id) do update
  set role = excluded.role,
      status = excluded.status;
end;
$$;

-- Admin: grant credits (append-only ledger)
create or replace function public.gi_ppi_admin_grant_credits(
  p_org_id uuid,
  p_delta_credits bigint,
  p_reason text
)
returns table (
  entry_id uuid,
  org_id uuid,
  delta_credits bigint,
  reason text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._gi_ppi_require_admin();

  if p_org_id is null then raise exception 'INVALID_ORG_ID'; end if;
  if p_delta_credits is null or p_delta_credits = 0 then raise exception 'INVALID_DELTA'; end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'INVALID_REASON'; end if;

  return query
  insert into public.gi_ppi_credit_ledger (org_id, delta_credits, reason, created_by)
  values (p_org_id, p_delta_credits, p_reason, auth.uid())
  returning entry_id, org_id, delta_credits, reason, created_at;
end;
$$;

grant execute on function public.gi_ppi_admin_create_org(text,text) to authenticated;
grant execute on function public.gi_ppi_admin_set_member(uuid,uuid,text,text) to authenticated;
grant execute on function public.gi_ppi_admin_grant_credits(uuid,bigint,text) to authenticated;
