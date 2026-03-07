-- GI-PPI: canonical fix
-- Ensure EDGE-only SECURITY DEFINER functions execute as a privileged owner,
-- while caller identity remains enforced by `session_user = 'gi_ppi_edge'`.

begin;

-- Introspection (non-fatal; helps audit)
-- select n.nspname as schema, p.proname, pg_get_userbyid(p.proowner) as owner, p.prosecdef
-- from pg_proc p join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname='public' and p.proname in ('gi_ppi_edge_issue_license_file','gi_ppi_edge_get_download_url');

alter function public.gi_ppi_edge_issue_license_file(uuid, text, uuid) owner to postgres;
alter function public.gi_ppi_edge_get_download_url(uuid, text, uuid, integer) owner to postgres;

-- Make sure the edge role can execute them (harmless if already granted)
grant execute on function public.gi_ppi_edge_issue_license_file(uuid, text, uuid) to gi_ppi_edge;
grant execute on function public.gi_ppi_edge_get_download_url(uuid, text, uuid, integer) to gi_ppi_edge;

commit;