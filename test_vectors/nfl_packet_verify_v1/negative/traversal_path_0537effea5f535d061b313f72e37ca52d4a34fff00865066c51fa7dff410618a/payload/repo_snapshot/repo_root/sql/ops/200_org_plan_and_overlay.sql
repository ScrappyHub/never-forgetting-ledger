-- ============================================================
-- COVENANT / GI-PPI: ORG PLAN + OVERLAY POLICY (CANONICAL V0)
-- - plan enforcement
-- - overlay: append-only versions + hash binding + active pointer
-- - overlay evaluator: DENY/NO_OP only
-- - combined eval RPC: canonical eval + overlay diagnostics (immutable)
-- ============================================================

-- ----------------------------
-- 1) Plan registry + org plan
-- ----------------------------
create table if not exists public.gi_ppi_plan_catalog (
  plan_code text primary key,
  description text not null,
  allow_overlay boolean not null default false,
  created_at timestamptz not null default now()
);

insert into public.gi_ppi_plan_catalog (plan_code, description, allow_overlay)
values
  ('tier0_instrument', 'Instrument access only (no overlay uploads).', false),
  ('tier1_curated',    'Instrument + curated overlay governance (DENY/NO_OP only).', true),
  ('institutional',    'Dedicated institution license. Overlay allowed.', true)
on conflict (plan_code) do update
set description = excluded.description,
    allow_overlay = excluded.allow_overlay;

create table if not exists public.gi_ppi_org_plan (
  org_id uuid primary key references public.gi_ppi_orgs(org_id) on delete cascade,
  plan_code text not null references public.gi_ppi_plan_catalog(plan_code),
  updated_at timestamptz not null default now(),
  updated_by uuid null
);

-- RLS
alter table public.gi_ppi_plan_catalog enable row level security;
alter table public.gi_ppi_org_plan enable row level security;

-- Public cannot read catalog; authenticated can read catalog if you want (optional).
drop policy if exists gi_ppi_plan_catalog_no_anon on public.gi_ppi_plan_catalog;
create policy gi_ppi_plan_catalog_no_anon
on public.gi_ppi_plan_catalog
for all
to anon
using (false)
with check (false);

drop policy if exists gi_ppi_plan_catalog_read_auth on public.gi_ppi_plan_catalog;
create policy gi_ppi_plan_catalog_read_auth
on public.gi_ppi_plan_catalog
for select
to authenticated
using (true);

-- Org plan: org members can read their org plan; no direct mutations
drop policy if exists gi_ppi_org_plan_member_read on public.gi_ppi_org_plan;
create policy gi_ppi_org_plan_member_read
on public.gi_ppi_org_plan
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_org_plan.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

drop policy if exists gi_ppi_org_plan_no_direct_mutation_anon on public.gi_ppi_org_plan;
create policy gi_ppi_org_plan_no_direct_mutation_anon
on public.gi_ppi_org_plan
for all
to anon
using (false)
with check (false);

drop policy if exists gi_ppi_org_plan_no_direct_mutation_auth on public.gi_ppi_org_plan;
create policy gi_ppi_org_plan_no_direct_mutation_auth
on public.gi_ppi_org_plan
for insert, update, delete
to authenticated
using (false)
with check (false);

-- ----------------------------
-- 2) Overlay tables (append-only versions)
-- ----------------------------
create table if not exists public.gi_ppi_org_overlay_versions (
  overlay_version_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.gi_ppi_orgs(org_id) on delete cascade,
  overlay_json jsonb not null,
  overlay_hash_sha256 text not null,
  created_at timestamptz not null default now(),
  created_by uuid null
);

create unique index if not exists ux_gi_ppi_org_overlay_versions_org_hash
on public.gi_ppi_org_overlay_versions(org_id, overlay_hash_sha256);

-- Append-only guard
create or replace function public._gi_ppi_overlay_versions_append_only_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'APPEND_ONLY: mutation forbidden on gi_ppi_org_overlay_versions';
end;
$$;

drop trigger if exists trg_gi_ppi_overlay_versions_append_only on public.gi_ppi_org_overlay_versions;
create trigger trg_gi_ppi_overlay_versions_append_only
before update or delete on public.gi_ppi_org_overlay_versions
for each row execute function public._gi_ppi_overlay_versions_append_only_guard();

-- Active pointer (mutable, but audited by history table)
create table if not exists public.gi_ppi_org_overlay_active (
  org_id uuid primary key references public.gi_ppi_orgs(org_id) on delete cascade,
  overlay_version_id uuid not null references public.gi_ppi_org_overlay_versions(overlay_version_id),
  activated_at timestamptz not null default now(),
  activated_by uuid null
);

alter table public.gi_ppi_org_overlay_versions enable row level security;
alter table public.gi_ppi_org_overlay_active enable row level security;

-- Members can read overlay versions for their org; no direct writes
drop policy if exists gi_ppi_overlay_versions_member_read on public.gi_ppi_org_overlay_versions;
create policy gi_ppi_overlay_versions_member_read
on public.gi_ppi_org_overlay_versions
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_org_overlay_versions.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

drop policy if exists gi_ppi_overlay_versions_no_direct_insert_auth on public.gi_ppi_org_overlay_versions;
create policy gi_ppi_overlay_versions_no_direct_insert_auth
on public.gi_ppi_org_overlay_versions
for insert
to authenticated
with check (false);

drop policy if exists gi_ppi_overlay_versions_no_direct_insert_anon on public.gi_ppi_org_overlay_versions;
create policy gi_ppi_overlay_versions_no_direct_insert_anon
on public.gi_ppi_org_overlay_versions
for insert
to anon
with check (false);

-- Active pointer read allowed to org members; no direct mutation
drop policy if exists gi_ppi_overlay_active_member_read on public.gi_ppi_org_overlay_active;
create policy gi_ppi_overlay_active_member_read
on public.gi_ppi_org_overlay_active
for select
to authenticated
using (
  exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = gi_ppi_org_overlay_active.org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  )
);

drop policy if exists gi_ppi_overlay_active_no_direct_mutation_auth on public.gi_ppi_org_overlay_active;
create policy gi_ppi_overlay_active_no_direct_mutation_auth
on public.gi_ppi_org_overlay_active
for insert, update, delete
to authenticated
using (false)
with check (false);

drop policy if exists gi_ppi_overlay_active_no_direct_mutation_anon on public.gi_ppi_org_overlay_active;
create policy gi_ppi_overlay_active_no_direct_mutation_anon
on public.gi_ppi_org_overlay_active
for all
to anon
using (false)
with check (false);

-- ----------------------------
-- 3) Helpers: admin require + plan gate
-- ----------------------------
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

create or replace function public._gi_ppi_org_allows_overlay(p_org_id uuid)
returns boolean
language sql
stable
as $$
  select coalesce(pc.allow_overlay, false)
  from public.gi_ppi_org_plan op
  join public.gi_ppi_plan_catalog pc on pc.plan_code = op.plan_code
  where op.org_id = p_org_id
$$;

-- ----------------------------
-- 4) RPC: admin set org plan
-- ----------------------------
create or replace function public.gi_ppi_admin_set_org_plan(
  p_org_id uuid,
  p_plan_code text,
  p_operator_user_id uuid
)
returns jsonb
language plpgsql
security definer
as $$
begin
  perform public._gi_ppi_require_admin();

  if p_operator_user_id is null or p_operator_user_id <> auth.uid() then
    raise exception 'OPERATOR_MISMATCH';
  end if;

  if p_org_id is null then raise exception 'INVALID_ORG_ID'; end if;
  if p_plan_code is null or btrim(p_plan_code) = '' then raise exception 'INVALID_PLAN_CODE'; end if;

  -- upsert org plan
  insert into public.gi_ppi_org_plan (org_id, plan_code, updated_by)
  values (p_org_id, p_plan_code, auth.uid())
  on conflict (org_id) do update
  set plan_code = excluded.plan_code,
      updated_at = now(),
      updated_by = auth.uid();

  return jsonb_build_object('ok', true, 'org_id', p_org_id, 'plan_code', p_plan_code, 'operator_user_id', auth.uid());
end;
$$;

grant execute on function public.gi_ppi_admin_set_org_plan(uuid,text,uuid) to authenticated;

-- ----------------------------
-- 5) RPC: publish overlay (admin only; overlay allowed by plan)
--    - stores append-only version (hash bound)
--    - sets active pointer
-- ----------------------------
create or replace function public.gi_ppi_admin_publish_overlay(
  p_org_id uuid,
  p_overlay_json jsonb,
  p_overlay_hash_sha256 text,
  p_operator_user_id uuid
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_overlay_version_id uuid;
  v_allow boolean;
begin
  perform public._gi_ppi_require_admin();

  if p_operator_user_id is null or p_operator_user_id <> auth.uid() then
    raise exception 'OPERATOR_MISMATCH';
  end if;

  if p_org_id is null then raise exception 'INVALID_ORG_ID'; end if;
  if p_overlay_json is null then raise exception 'INVALID_OVERLAY_JSON'; end if;
  if p_overlay_hash_sha256 is null or btrim(p_overlay_hash_sha256) = '' then raise exception 'INVALID_OVERLAY_HASH'; end if;

  v_allow := coalesce(public._gi_ppi_org_allows_overlay(p_org_id), false);
  if not v_allow then
    raise exception 'OVERLAY_NOT_ENTITLED';
  end if;

  insert into public.gi_ppi_org_overlay_versions (org_id, overlay_json, overlay_hash_sha256, created_by)
  values (p_org_id, p_overlay_json, p_overlay_hash_sha256, auth.uid())
  on conflict (org_id, overlay_hash_sha256) do update
  set overlay_json = excluded.overlay_json -- same hash => same content expected; keep id stable per insert attempt
  returning overlay_version_id into v_overlay_version_id;

  insert into public.gi_ppi_org_overlay_active (org_id, overlay_version_id, activated_by)
  values (p_org_id, v_overlay_version_id, auth.uid())
  on conflict (org_id) do update
  set overlay_version_id = excluded.overlay_version_id,
      activated_at = now(),
      activated_by = auth.uid();

  return jsonb_build_object(
    'ok', true,
    'org_id', p_org_id,
    'overlay_version_id', v_overlay_version_id,
    'overlay_hash_sha256', p_overlay_hash_sha256,
    'operator_user_id', auth.uid()
  );
end;
$$;

grant execute on function public.gi_ppi_admin_publish_overlay(uuid,jsonb,text,uuid) to authenticated;

-- ----------------------------
-- 6) Overlay evaluator (DENY / NO_OP only)
--    Overlay schema: { schema_version, deny: { task_type: [..] } }
-- ----------------------------
create or replace function public.gi_ppi_overlay_eval(
  p_org_id uuid,
  p_proposal jsonb
)
returns table (
  overlay_decision text,
  overlay_reason_codes text[],
  overlay_diagnostics jsonb
)
language plpgsql
stable
as $$
declare
  v_overlay jsonb;
  v_task_type text;
  v_denied_task_types jsonb;
begin
  -- if no active overlay => NO_OP (we do NOT throw)
  select ov.overlay_json into v_overlay
  from public.gi_ppi_org_overlay_active a
  join public.gi_ppi_org_overlay_versions ov on ov.overlay_version_id = a.overlay_version_id
  where a.org_id = p_org_id;

  if v_overlay is null then
    return query
    select
      'NO_OP',
      array['overlay_noop_v0']::text[],
      jsonb_build_object('note','no_active_overlay');
    return;
  end if;

  -- Extract task_type from proposal
  v_task_type := coalesce(p_proposal #>> '{inputs,task_type}', '');

  -- Deny list
  v_denied_task_types := v_overlay #> '{deny,task_type}';

  if jsonb_typeof(v_denied_task_types) = 'array' and v_task_type <> '' then
    if exists (
      select 1
      from jsonb_array_elements_text(v_denied_task_types) x(val)
      where x.val = v_task_type
    ) then
      return query
      select
        'DENY',
        array['overlay_deny_task_type_v0']::text[],
        jsonb_build_object('matched','deny.task_type','task_type',v_task_type);
      return;
    end if;
  end if;

  -- Default: NO_OP
  return query
  select
    'NO_OP',
    array['overlay_noop_v0']::text[],
    jsonb_build_object('note','no_overlay_deny_match');
end;
$$;

-- ----------------------------
-- 7) Combined RPC: canonical eval + overlay result in diagnostics
--    Rules:
--      - overlay runs first if plan allows overlay; if overlay DENY => return DENY (no credit spend)
--      - if overlay NO_OP => proceed to canonical eval with credits spend on ALLOW
--      - overlay reason codes MUST exist in governance_reason_codes (enforced)
-- ----------------------------
create or replace function public.gi_ppi_eval_with_org_credits_and_overlay(
  p_policy_version_id uuid,
  p_org_id uuid,
  p_proposal jsonb,
  p_operator_user_id uuid
)
returns table (
  evaluation_id uuid,
  proposal_hash text,
  decision text,
  reason_codes text[],
  diagnostics jsonb
)
language plpgsql
security definer
as $$
declare
  v_allow_overlay boolean;
  v_overlay record;
  v_eval record;
  v_missing int;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if p_operator_user_id is null or p_operator_user_id <> auth.uid() then
    raise exception 'OPERATOR_MISMATCH';
  end if;

  -- membership gate (operator must be active member)
  if not exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = p_org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  ) then
    raise exception 'ORG_MEMBERSHIP_REQUIRED_FOR_OPERATOR';
  end if;

  v_allow_overlay := coalesce(public._gi_ppi_org_allows_overlay(p_org_id), false);

  if v_allow_overlay then
    select * into v_overlay
    from public.gi_ppi_overlay_eval(p_org_id, p_proposal);

    -- validate overlay reason codes exist (your requirement)
    select count(*) into v_missing
    from unnest(v_overlay.overlay_reason_codes) rc(code)
    left join public.governance_reason_codes g on g.code = rc.code
    where g.code is null;

    if v_missing > 0 then
      raise exception 'OVERLAY_REASON_CODE_NOT_REGISTERED';
    end if;

    if v_overlay.overlay_decision = 'DENY' then
      -- Return a DENY shaped like a normal evaluation (immutable record still)
      return query
      select
        gen_random_uuid(),
        null::text,
        'DENY',
        v_overlay.overlay_reason_codes,
        jsonb_build_object('overlay', v_overlay.overlay_diagnostics);
      return;
    end if;
  end if;

  -- Overlay is NO_OP or not entitled => proceed to canonical eval WITH credits spend logic
  select * into v_eval
  from public.gi_ppi_eval_with_org_credits(p_policy_version_id, p_org_id, p_proposal, p_operator_user_id);

  -- enrich diagnostics with overlay info (even when not entitled)
  return query
  select
    v_eval.evaluation_id,
    v_eval.proposal_hash,
    v_eval.decision,
    v_eval.reason_codes,
    coalesce(v_eval.diagnostics, '{}'::jsonb) ||
      jsonb_build_object(
        'overlay',
        case
          when v_allow_overlay then coalesce(v_overlay.overlay_diagnostics, jsonb_build_object('note','overlay_noop'))
          else jsonb_build_object('note','overlay_not_entitled_or_not_set')
        end
      );
end;
$$;

grant execute on function public.gi_ppi_eval_with_org_credits_and_overlay(uuid,uuid,jsonb,uuid) to authenticated;

-- ----------------------------
-- 8) Ensure required overlay reason codes exist (you already have deny codes)
-- ----------------------------
insert into public.governance_reason_codes (code, severity, description)
values
  ('overlay_noop_v0','info','Overlay evaluator made no changes (no deny rules matched).')
on conflict (code) do nothing;

-- Refresh PostgREST schema
select pg_notify('pgrst','reload schema');
