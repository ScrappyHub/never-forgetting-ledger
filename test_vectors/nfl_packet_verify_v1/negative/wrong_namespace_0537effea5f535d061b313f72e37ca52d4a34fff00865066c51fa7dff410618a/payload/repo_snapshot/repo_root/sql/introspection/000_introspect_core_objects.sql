-- GI/PPI introspection: canonical columns + constraints

select 'governance_policy_versions.columns' as section;
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_policy_versions'
order by ordinal_position;

select 'governance_policy_rules.columns' as section;
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_policy_rules'
order by ordinal_position;

select 'governance_evaluations.columns' as section;
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_evaluations'
order by ordinal_position;

select 'governance_reason_codes.columns' as section;
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='governance_reason_codes'
order by ordinal_position;

select 'policy_rules.constraints' as section;
select conname, pg_get_constraintdef(c.oid) as constraint_def
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname='public' and t.relname='governance_policy_rules'
order by conname;

select 'graph_edges.constraints' as section;
select conname, pg_get_constraintdef(c.oid) as constraint_def
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname='public' and t.relname='governance_policy_rule_graph_edges'
order by conname;
