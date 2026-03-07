-- GI/PPI INTROSPECTION — CANONICAL
-- Purpose: pull exact schemas/constraints for audit + debugging

select 'governance_policy_versions' as obj, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_policy_versions'
order by ordinal_position;

select 'governance_policy_rules' as obj, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_policy_rules'
order by ordinal_position;

select 'governance_evaluations' as obj, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_evaluations'
order by ordinal_position;

select conname, pg_get_constraintdef(c.oid) as constraint_def
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname='public'
  and t.relname in ('governance_policy_versions','governance_policy_rules','governance_evaluations','governance_policy_rule_graph_nodes','governance_policy_rule_graph_edges')
order by t.relname, conname;
