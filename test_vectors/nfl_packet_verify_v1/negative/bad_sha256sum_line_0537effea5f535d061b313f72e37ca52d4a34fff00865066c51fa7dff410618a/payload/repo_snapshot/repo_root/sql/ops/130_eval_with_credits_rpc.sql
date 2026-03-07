-- ============================================
-- GI/PPI EVAL + CREDIT GATE (CANONICAL V0)
-- File: sql/ops/130_eval_with_credits_rpc.sql
-- ============================================

create or replace function public.gi_ppi_eval_with_org_credits(
  p_policy_version_id uuid,
  p_org_id uuid,
  p_proposal jsonb
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
set search_path = public
as $$
declare
  v_balance bigint;
  v_eval record;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- membership gate
  if not exists (
    select 1
    from public.gi_ppi_org_members m
    where m.org_id = p_org_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  ) then
    raise exception 'ORG_MEMBERSHIP_REQUIRED';
  end if;

  select credits_balance into v_balance
  from public.gi_ppi_org_credit_balance
  where org_id = p_org_id;

  v_balance := coalesce(v_balance, 0);

  if v_balance <= 0 then
    return query
    select
      gen_random_uuid(),
      null::text,
      'DENY',
      array['credits_exhausted']::text[],
      jsonb_build_object('org_id', p_org_id, 'credits_balance', v_balance);
    return;
  end if;

  -- canonical evaluation (existing GI/PPI evaluator)
  select * into v_eval
  from public.evaluate_proposal(p_policy_version_id, p_proposal);

  -- spend only on ALLOW
  if v_eval.decision = 'ALLOW' then
    insert into public.gi_ppi_credit_ledger (org_id, delta_credits, reason, created_by)
    values (p_org_id, -1, 'eval_allow_spend_v0', auth.uid());
  end if;

  return query
  select v_eval.evaluation_id, v_eval.proposal_hash, v_eval.decision, v_eval.reason_codes, v_eval.diagnostics;
end;
$$;

grant execute on function public.gi_ppi_eval_with_org_credits(uuid,uuid,jsonb) to authenticated;
