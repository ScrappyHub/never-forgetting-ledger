begin;

-- Canonical artifacts table (source of truth for bucket/path/hash)
create table if not exists public.gi_ppi_artifacts (
  artifact_key  text primary key,
  bucket_id     text not null,
  object_path   text not null,
  sha256        text not null,
  size_bytes    bigint not null,
  version       text not null,
  platform      text not null,
  created_utc   timestamptz not null default now()
);

-- Minimal sanity checks
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'gi_ppi_artifacts_sha256_len_chk'
  ) then
    alter table public.gi_ppi_artifacts
      add constraint gi_ppi_artifacts_sha256_len_chk
      check (length(sha256)=64);
  end if;
end $$;

-- Issuance ledger (auditable allow/deny)
create table if not exists public.gi_ppi_download_issuance (
  issuance_id     uuid primary key default gen_random_uuid(),
  issued_at       timestamptz not null default now(),
  org_id          uuid not null,
  user_id         uuid not null,
  artifact_key    text not null references public.gi_ppi_artifacts(artifact_key),
  expires_at      timestamptz not null,
  policy_snapshot jsonb not null default '{}'::jsonb,
  request_ip      text null,
  user_agent      text null,
  result          text not null,
  error           text null
);

create index if not exists gi_ppi_download_issuance_org_idx on public.gi_ppi_download_issuance(org_id);
create index if not exists gi_ppi_download_issuance_user_idx on public.gi_ppi_download_issuance(user_id);
create index if not exists gi_ppi_download_issuance_artifact_idx on public.gi_ppi_download_issuance(artifact_key);

commit;