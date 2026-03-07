-- 040_introspection_views.sql
-- Read-only introspection views for operators and auditors.

create or replace view public.v_gi_ppi_policies as
select
  policy_version_id,
  version_name,
  status,
  created_at,
  activated_at,
  policy_hash_sha256,
  rule_graph_hash_sha256
from public.governance_policy_versions
order by created_at desc;

create or replace view public.v_gi_ppi_active_policy as
select *
from public.governance_policy_versions
where status = 'active'
order by created_at desc
limit 1;

create or replace view public.v_gi_ppi_rules as
select
  r.policy_version_id,
  r.rule_id,
  r.rule_order,
  r.priority,
  r.decision,
  r.reason_code,
  r.match_note,
  r.match
from public.governance_policy_rules r;

create or replace view public.v_gi_ppi_reason_codes as
select code, severity, description
from public.governance_reason_codes
order by code asc;

create or replace view public.v_gi_ppi_latest_evaluations as
select
  evaluation_id,
  policy_version_id,
  policy_hash_sha256,
  proposal_hash,
  proposal_hash_jcs_sha256,
  proposal_hash_pg_sha256,
  proposal_canon_hash_sha256,
  decision,
  reason_codes,
  created_at
from public.governance_evaluations
order by created_at desc;

grant select on public.v_gi_ppi_policies to anon, authenticated;
grant select on public.v_gi_ppi_active_policy to anon, authenticated;
grant select on public.v_gi_ppi_rules to anon, authenticated;
grant select on public.v_gi_ppi_reason_codes to anon, authenticated;
grant select on public.v_gi_ppi_latest_evaluations to anon, authenticated;
