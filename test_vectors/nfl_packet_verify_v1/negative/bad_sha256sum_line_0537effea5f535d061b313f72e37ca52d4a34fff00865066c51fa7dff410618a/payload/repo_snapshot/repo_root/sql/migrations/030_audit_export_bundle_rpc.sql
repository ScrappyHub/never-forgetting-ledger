-- 030_audit_export_bundle_rpc.sql
-- GI/PPI: Audit export bundle (read-only), returns a single JSON object.

create or replace function public.export_audit_bundle(
  p_policy_version_id uuid,
  p_limit int default 500,
  p_offset int default 0
)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'exported_at', now(),
    'policy_version', (
      select to_jsonb(pv)
      from public.governance_policy_versions pv
      where pv.policy_version_id = p_policy_version_id
      limit 1
    ),
    'rules', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.rule_order asc), '[]'::jsonb)
      from public.governance_policy_rules r
      where r.policy_version_id = p_policy_version_id
    ),
    'rule_graph_nodes', (
      select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at asc), '[]'::jsonb)
      from public.governance_policy_rule_graph_nodes n
      where n.policy_version_id = p_policy_version_id
    ),
    'rule_graph_edges', (
      select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at asc), '[]'::jsonb)
      from public.governance_policy_rule_graph_edges e
      where e.policy_version_id = p_policy_version_id
    ),
    'reason_codes', (
      select coalesce(jsonb_agg(to_jsonb(rc) order by rc.code asc), '[]'::jsonb)
      from public.governance_reason_codes rc
    ),
    'evaluations_page', (
      select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at desc), '[]'::jsonb)
      from (
        select
          evaluation_id,
          policy_version_id,
          policy_hash_sha256,
          proposal_hash,
          proposal_hash_pg_sha256,
          proposal_hash_jcs_sha256,
          proposal_canon_hash_sha256,
          decision,
          reason_codes,
          diagnostics,
          created_at
        from public.governance_evaluations
        where policy_version_id = p_policy_version_id
        order by created_at desc
        limit p_limit offset p_offset
      ) ev
    )
  );
$$;

grant execute on function public.export_audit_bundle(uuid,int,int) to anon;
grant execute on function public.export_audit_bundle(uuid,int,int) to authenticated;
