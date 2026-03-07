begin;

-- ==========================================================
-- GI: RECEIPTS + OVERLAYS LOCKDOWN V1
-- Append-only receipts; frozen overlays; no mutation drift.
-- ==========================================================

-- 1) Hard freeze: policy_versions / overlay_versions / schema_overlay_versions
create or replace function public.gi_assert_frozen_true()
returns trigger
language plpgsql
as $$
begin
  if new.frozen is distinct from true then
    raise exception 'GI_FROZEN_REQUIRED';
  end if;
  return new;
end;
$$;

drop trigger if exists gi_policy_versions_frozen_tg on public.gi_policy_versions;
create trigger gi_policy_versions_frozen_tg
before insert or update on public.gi_policy_versions
for each row execute function public.gi_assert_frozen_true();

drop trigger if exists gi_overlay_versions_frozen_tg on public.gi_overlay_versions;
create trigger gi_overlay_versions_frozen_tg
before insert or update on public.gi_overlay_versions
for each row execute function public.gi_assert_frozen_true();

drop trigger if exists gi_schema_overlay_versions_frozen_tg on public.gi_schema_overlay_versions;
create trigger gi_schema_overlay_versions_frozen_tg
before insert or update on public.gi_schema_overlay_versions
for each row execute function public.gi_assert_frozen_true();

-- 2) Append-only receipts (no update/delete)
create or replace function public.gi_receipts_no_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'GI_RECEIPTS_APPEND_ONLY';
end;
$$;

drop trigger if exists gi_receipts_no_update_tg on public.gi_receipts;
create trigger gi_receipts_no_update_tg
before update on public.gi_receipts
for each row execute function public.gi_receipts_no_mutation();

drop trigger if exists gi_receipts_no_delete_tg on public.gi_receipts;
create trigger gi_receipts_no_delete_tg
before delete on public.gi_receipts
for each row execute function public.gi_receipts_no_mutation();

-- 3) Tighten: binding tables can be updated only by replace (delete+insert)
-- (Leave as-is for now; if you want, we can make bindings append-only too and
-- pick "latest by created_at" in the resolver.)

commit;
