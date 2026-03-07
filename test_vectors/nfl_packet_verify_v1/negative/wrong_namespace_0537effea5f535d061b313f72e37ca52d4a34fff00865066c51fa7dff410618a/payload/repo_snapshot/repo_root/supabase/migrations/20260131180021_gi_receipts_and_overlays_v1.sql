begin;

-- =====================================================================
-- GI: RECEIPTS + OVERLAYS (V1)
-- Two planes:
--   Control plane: overlay versions + bindings
--   Data plane: receipts (every eval)
-- Two overlay tiers:
--   Runtime overlay + Schema overlay
-- =====================================================================

create extension if not exists pgcrypto;


-- GI_DIGEST_RESOLVER_V1
-- Supabase may install pgcrypto into a non-public schema (often "extensions").
-- We resolve digest(bytea,text) deterministically via catalog lookup, then call it.
create or replace function public.gi_digest(p_data bytea, p_alg text)
returns bytea
language plpgsql
stable
as $gi$
declare
  v_schema text;
  v_out bytea;
begin
  select n.nspname into v_schema
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.proname = 'digest'
    and pg_get_function_identity_arguments(p.oid) = 'bytea, text'
  order by (case when n.nspname = 'extensions' then 0 when n.nspname = 'public' then 1 else 2 end)
  limit 1;

  if v_schema is null then
    raise exception 'GI_DIGEST_NOT_FOUND: digest(bytea,text) not found in any schema';
  end if;

  execute format('select %I.digest($1,$2)', v_schema)
    into v_out
    using p_data, p_alg;

  return v_out;
end;
$gi$;
-- -------------------------------
-- CONTROL PLANE: POLICY VERSIONS
-- -------------------------------
create table if not exists public.gi_policy_versions (
  policy_version_id uuid primary key default gen_random_uuid(),
  policy_sha256 text not null,
  policy_json jsonb not null,
  created_at timestamptz not null default now(),
  frozen boolean not null default true
);

-- ---------------------------------
-- CONTROL PLANE: RUNTIME OVERLAYS
-- ---------------------------------
create table if not exists public.gi_overlay_versions (
  overlay_version_id uuid primary key default gen_random_uuid(),
  overlay_sha256 text not null,
  overlay_json jsonb not null,
  created_at timestamptz not null default now(),
  frozen boolean not null default true
);

create table if not exists public.gi_overlay_bindings (
  binding_id uuid primary key default gen_random_uuid(),
  org_id uuid,
  user_id uuid,
  app_id text,
  device_id text,
  overlay_version_id uuid not null references public.gi_overlay_versions(overlay_version_id),
  created_at timestamptz not null default now(),
  unique (org_id, user_id, app_id, device_id)
);

-- ---------------------------------
-- CONTROL PLANE: SCHEMA OVERLAYS
-- ---------------------------------
create table if not exists public.gi_schema_overlay_versions (
  schema_overlay_version_id uuid primary key default gen_random_uuid(),
  schema_overlay_sha256 text not null,
  schema_overlay_json jsonb not null,
  created_at timestamptz not null default now(),
  frozen boolean not null default true
);

create table if not exists public.gi_schema_overlay_bindings (
  binding_id uuid primary key default gen_random_uuid(),
  org_id uuid,
  schema_overlay_version_id uuid not null references public.gi_schema_overlay_versions(schema_overlay_version_id),
  created_at timestamptz not null default now(),
  unique (org_id)
);

-- -------------------------------
-- DATA PLANE: RECEIPTS
-- -------------------------------
create table if not exists public.gi_receipts (
  receipt_id uuid primary key default gen_random_uuid(),
  evaluation_id uuid not null,
  policy_version_id uuid not null references public.gi_policy_versions(policy_version_id),
  overlay_version_id uuid references public.gi_overlay_versions(overlay_version_id),
  overlay_sha256 text,
  schema_overlay_version_id uuid references public.gi_schema_overlay_versions(schema_overlay_version_id),
  schema_overlay_sha256 text,

  proposal jsonb,
  proposal_hash text not null,

  decision text not null check (decision in ('ALLOW','DENY')),
  reason_codes text[] not null default '{}'::text[],

  results jsonb,
  result_hash text,

  caller_org_id uuid,
  caller_user_id uuid,

  created_at timestamptz not null default now()
);

create index if not exists gi_receipts_proposal_hash_idx on public.gi_receipts(proposal_hash);
create index if not exists gi_receipts_eval_id_idx on public.gi_receipts(evaluation_id);

-- ==========================================================
-- CANONICAL HASHING
-- Postgres jsonb::text is stable key order => deterministic.
-- ==========================================================
create or replace function public.gi_canonical_hash_jsonb(p jsonb)
returns text
language sql
immutable
as $$
  select encode(public.gi_digest(convert_to(coalesce(p::text,''), 'utf8'), 'sha256'::text), 'hex');
$$;

-- ==========================================================
-- RECEIPT WRITER
-- ==========================================================
create or replace function public.gi_write_receipt(
  p_evaluation_id uuid,
  p_policy_version_id uuid,
  p_overlay_version_id uuid,
  p_overlay_sha256 text,
  p_schema_overlay_version_id uuid,
  p_schema_overlay_sha256 text,
  p_proposal jsonb,
  p_decision text,
  p_reason_codes text[],
  p_results jsonb,
  p_caller_org_id uuid,
  p_caller_user_id uuid
)
returns uuid
language plpgsql
security definer
as $gi$
declare
  v_proposal_hash text;
  v_result_hash text;
  v_receipt_id uuid;
begin
  v_proposal_hash := public.gi_canonical_hash_jsonb(p_proposal);

  if p_results is null then
    v_result_hash := null;
  else
    v_result_hash := public.gi_canonical_hash_jsonb(p_results);
  end if;

  insert into public.gi_receipts(
    evaluation_id,
    policy_version_id,
    overlay_version_id,
    overlay_sha256,
    schema_overlay_version_id,
    schema_overlay_sha256,
    proposal,
    proposal_hash,
    decision,
    reason_codes,
    results,
    result_hash,
    caller_org_id,
    caller_user_id
  )
  values (
    p_evaluation_id,
    p_policy_version_id,
    p_overlay_version_id,
    p_overlay_sha256,
    p_schema_overlay_version_id,
    p_schema_overlay_sha256,
    p_proposal,
    v_proposal_hash,
    p_decision,
    coalesce(p_reason_codes, '{}'::text[]),
    p_results,
    v_result_hash,
    p_caller_org_id,
    p_caller_user_id
  )
  returning receipt_id into v_receipt_id;

  return v_receipt_id;
end;
$gi$;

-- ==========================================================
-- RECEIPT VERIFIER
-- Recomputes hashes and returns deterministic comparison.
-- ==========================================================
create or replace function public.gi_verify_receipt(
  p_receipt_id uuid,
  p_proposal jsonb
)
returns jsonb
language plpgsql
security definer
as $gi$
declare
  r public.gi_receipts%rowtype;
  v_in_hash text;
  v_ok boolean;
begin
  select * into r from public.gi_receipts where receipt_id = p_receipt_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'RECEIPT_NOT_FOUND');
  end if;

  v_in_hash := public.gi_canonical_hash_jsonb(p_proposal);

  v_ok := (v_in_hash = r.proposal_hash);

  return jsonb_build_object(
    'ok', v_ok,
    'receipt_id', r.receipt_id,
    'evaluation_id', r.evaluation_id,
    'stored_proposal_hash', r.proposal_hash,
    'recomputed_proposal_hash', v_in_hash,
    'hash_match', v_ok,
    'decision', r.decision,
    'reason_codes', r.reason_codes,
    'policy_version_id', r.policy_version_id,
    'overlay_version_id', r.overlay_version_id,
    'overlay_sha256', r.overlay_sha256,
    'schema_overlay_version_id', r.schema_overlay_version_id,
    'schema_overlay_sha256', r.schema_overlay_sha256,
    'result_hash', r.result_hash,
    'created_at', r.created_at
  );
end;
$gi$;

commit;