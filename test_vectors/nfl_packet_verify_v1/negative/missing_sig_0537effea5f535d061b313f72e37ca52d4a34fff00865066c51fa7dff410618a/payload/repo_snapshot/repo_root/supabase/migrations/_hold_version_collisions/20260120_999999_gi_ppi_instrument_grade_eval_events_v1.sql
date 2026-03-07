begin;

-- =====================================================================
-- GI-PPI CANONICAL MIGRATION REWRITE (UNBLOCK)
-- Reason: "cannot change return type of existing function"
-- Policy: drop any prior versions by name (all overloads) then recreate
-- =====================================================================

do $$
declare
  r record;
begin
  -- Drop ALL overloads of this function name (public schema) deterministically.
  for r in
    select
      n.nspname as schema_name,
      p.proname as func_name,
      pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'gi_ppi_eval_with_org_credits_and_overlay_core'
  loop
    execute format('drop function if exists %I.%I(%s);', r.schema_name, r.func_name, r.args);
  end loop;
end $$;

-- Recreate the function with the canonical return shape you intended.
-- IMPORTANT: This is a TEMPORARY CANONICAL SHELL to restore migration determinism.
-- Next step: we will install the full final implementation in a new migration once DB is green.
create function public.gi_ppi_eval_with_org_credits_and_overlay_core(
  p_policy_version_id uuid,
  p_org_id uuid,
  p_proposal jsonb,
  p_operator_user_id uuid
)
returns table(
  evaluation_id uuid,
  proposal_hash text,
  decision text,
  reason_codes text[],
  diagnostics jsonb,
  overlay_version_id uuid,
  overlay_sha256 text
)
language plpgsql
security definer
as $function$
begin
  -- Minimal deterministic placeholder:
  -- Return a DENY until the final canonical implementation is installed.
  evaluation_id := gen_random_uuid();
  proposal_hash := encode(digest(coalesce(p_proposal::text,''), 'sha256'), 'hex');
  decision := 'DENY';
  reason_codes := array['TEMP_UNBLOCK_SHELL']::text[];
  diagnostics := jsonb_build_object(
    'note', 'Temporary shell function installed to unblock migrations. Install final canonical implementation in a follow-up migration.',
    'policy_version_id', p_policy_version_id,
    'org_id', p_org_id,
    'operator_user_id', p_operator_user_id
  );
  overlay_version_id := null;
  overlay_sha256 := null;

  return next;
end;
$function$;

commit;