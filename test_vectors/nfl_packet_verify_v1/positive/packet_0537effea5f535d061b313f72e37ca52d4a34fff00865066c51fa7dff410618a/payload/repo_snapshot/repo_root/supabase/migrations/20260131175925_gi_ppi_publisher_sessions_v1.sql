begin;

-- =====================================================================
-- GI-PPI: PUBLISHER SESSIONS V1 (CANONICAL RESET)
-- This file was corrupted during patching. We replace it with a valid,
-- idempotent bootstrap that unblocks downstream migrations.
-- =====================================================================

create extension if not exists pgcrypto;

-- Ensure artifacts table exists (minimal canonical surface)
do $$
begin
  if not exists (
    select 1
    from information_schema.tables
    where table_schema='public' and table_name='gi_ppi_artifacts'
  ) then
    create table public.gi_ppi_artifacts (
      artifact_key text primary key,
      bucket_id    text not null,
      object_path  text not null,
      sha256       text not null,
      size_bytes   bigint not null,
      version      text not null,
      platform     text not null,
      created_at   timestamptz not null default now(),
      updated_at   timestamptz not null default now()
    );

    create index if not exists gi_ppi_artifacts_bucket_path_idx
      on public.gi_ppi_artifacts(bucket_id, object_path);

    create index if not exists gi_ppi_artifacts_sha256_idx
      on public.gi_ppi_artifacts(sha256);
  end if;
end $$;

-- Ensure state columns exist (idempotent)
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='status'
  ) then
    alter table public.gi_ppi_artifacts
      add column status text not null default 'active';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='published_utc'
  ) then
    alter table public.gi_ppi_artifacts
      add column published_utc timestamptz null;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='last_verified_utc'
  ) then
    alter table public.gi_ppi_artifacts
      add column last_verified_utc timestamptz null;
  end if;
end $$;

-- NOTE:
-- Publisher session tables + RLS/policies will be introduced in a follow-up
-- migration once receipts/overlays are green. This keeps ordering deterministic.

commit;