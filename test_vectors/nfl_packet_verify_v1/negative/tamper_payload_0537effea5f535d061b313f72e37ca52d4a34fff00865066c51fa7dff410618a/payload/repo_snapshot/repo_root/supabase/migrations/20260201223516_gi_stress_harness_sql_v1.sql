begin;

-- ==========================================================
-- GI STRESS HARNESS SQL V1 (AUDITED, DETERMINISTIC VECTORS)
-- ==========================================================

create table if not exists public.gi_test_vectors (
  vector_id       text primary key,           -- deterministic id (sha256 hex)
  label           text not null,
  input_json      jsonb not null,
  expected_json   jsonb null,                 -- optional expectations
  created_at      timestamptz not null default now()
);

create table if not exists public.gi_test_runs (
  run_id          bigserial primary key,
  vector_id       text not null references public.gi_test_vectors(vector_id),
  input_json      jsonb not null,
  output_json     jsonb not null,
  output_sha256   text not null,
  ok              boolean not null,
  fail_reason     text null,
  created_at      timestamptz not null default now()
);

-- Deterministic SHA256 over jsonb::text (canonical key order)
create or replace function public.gi_sha256_jsonb(p jsonb)
returns text
language sql
immutable
as $$
  select encode(public.gi_digest(convert_to(coalesce(p::text,''),'utf8'), 'sha256'::text), 'hex');
$$;

-- Runner: stores results in gi_test_runs, never mutates vectors
-- NOTE: For now it just echoes + hashes; we wire GI calls next migration once we confirm function names.
create or replace function public.gi_run_test_vector(p_vector_id text)
returns public.gi_test_runs
language plpgsql
as $$
declare
  v public.gi_test_vectors;
  out_json jsonb;
  out_hash text;
  ok boolean := true;
  fail text := null;
  r public.gi_test_runs;
begin
  select * into v from public.gi_test_vectors where vector_id = p_vector_id;
  if not found then
    raise exception 'GI_VECTOR_NOT_FOUND:%', p_vector_id;
  end if;

  -- Phase 0: deterministic echo (baseline). Next step: call GI gate + receipt writers here.
  out_json := jsonb_build_object(
    'vector_id', v.vector_id,
    'label', v.label,
    'input', v.input_json,
    'note', 'baseline echo; wire GI calls next'
  );

  out_hash := public.gi_sha256_jsonb(out_json);

  insert into public.gi_test_runs(vector_id, input_json, output_json, output_sha256, ok, fail_reason)
  values (v.vector_id, v.input_json, out_json, out_hash, ok, fail)
  returning * into r;

  return r;
end;
$$;

commit;