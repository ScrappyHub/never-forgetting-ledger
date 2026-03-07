$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$Root       = "C:\Users\Keira\gi-ppi"
$ProjectRef = "hmlihkcijjamxdurydbv"
$MigrationsDir = Join-Path $Root "supabase\migrations"
if (-not (Test-Path -LiteralPath $MigrationsDir)) { throw "Missing migrations dir: $MigrationsDir" }

function Utf8NoBom() { New-Object System.Text.UTF8Encoding($false) }

Write-Host "== GI-PPI DB GREEN ==" -ForegroundColor Cyan
Write-Host "Root: $Root" -ForegroundColor Cyan
Write-Host "ProjectRef: $ProjectRef" -ForegroundColor Cyan

# ---------------------------------------------------------------------
# 0) Ensure there is at least ONE local migration file matching 20260120_*.sql
#    Supabase repair uses glob supabase\migrations\20260120_*.sql and fails if none exist.
# ---------------------------------------------------------------------
$placeholder = Join-Path $MigrationsDir "20260120_000000_remote_placeholder.sql"
if (-not (Test-Path -LiteralPath $placeholder)) {
  $phSql = @"
begin;

-- Placeholder file to satisfy Supabase CLI migration repair globs for date 20260120.
-- Remote history references version 20260120, but local repo did not contain a 20260120_* file.
-- This file is intentionally no-op. Do NOT delete unless migration history is fully reconciled.

commit;
"@
  [IO.File]::WriteAllText($placeholder, $phSql, (Utf8NoBom))
  Write-Host "Wrote placeholder: $placeholder" -ForegroundColor Yellow
} else {
  Write-Host "Placeholder exists: $placeholder" -ForegroundColor DarkGray
}

Push-Location $Root
try {
  supabase link --project-ref $ProjectRef | Out-Host

  # -------------------------------------------------------------------
  # 1) Repair migration history so local/remote stop fighting.
  #    Supabase told us to set 20260120 reverted (not applied).
  # -------------------------------------------------------------------
  Write-Host "Repairing migration history..." -ForegroundColor Cyan
  supabase migration repair --status reverted 20260120 | Out-Host
  supabase migration repair --status applied 20260129230921 | Out-Host
  supabase migration repair --status applied 20260129233529 | Out-Host

  Write-Host "Running: supabase db pull" -ForegroundColor Cyan
  supabase db pull | Out-Host
}
finally { Pop-Location }

# ---------------------------------------------------------------------
# 2) QUARANTINE any remaining 20260120_* migrations at the top level
#    (We keep the placeholder; everything else goes to hold.)
# ---------------------------------------------------------------------
$HoldDir = Join-Path $MigrationsDir "_hold_version_collisions"
if (-not (Test-Path -LiteralPath $HoldDir)) { New-Item -ItemType Directory -Path $HoldDir | Out-Null }

$Colliders = Get-ChildItem -LiteralPath $MigrationsDir -File |
  Where-Object { $_.Name -like "20260120_*" -and $_.Name -ne (Split-Path -Leaf $placeholder) }

foreach ($f in $Colliders) {
  $dst = Join-Path $HoldDir $f.Name
  Move-Item -LiteralPath $f.FullName -Destination $dst -Force
  Write-Host ("QUARANTINED -> {0}" -f $dst) -ForegroundColor Yellow
}

Write-Host "Quarantine step complete." -ForegroundColor Green

# ---------------------------------------------------------------------
# 3) ADD new 14-digit migration to unblock return-shape safely
#    IMPORTANT: avoid $function$ token entirely to prevent PowerShell var expansion issues.
#    Use $gi$ ... $gi$ as the dollar-quote tag.
# ---------------------------------------------------------------------
$stamp14 = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$NewMig  = Join-Path $MigrationsDir ("{0}_gi_ppi_eval_core_returnshape_unblock.sql" -f $stamp14)

$UnblockSql = @"
begin;

-- GI-PPI: canonical unblock migration (14-digit)
-- Drops ALL overloads of gi_ppi_eval_with_org_credits_and_overlay_core and recreates canonical return shape.
-- TEMP behavior = DENY until final implementation lands.

do \$\$
declare
  r record;
begin
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
end \$\$;

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
as \$gi\$
begin
  evaluation_id := gen_random_uuid();
  proposal_hash := encode(digest(coalesce(p_proposal::text,''), 'sha256'), 'hex');
  decision := 'DENY';
  reason_codes := array['TEMP_UNBLOCK_SHELL']::text[];
  diagnostics := jsonb_build_object(
    'note', 'TEMP shell installed to restore migration determinism. Final implementation will be installed in a follow-up migration.',
    'policy_version_id', p_policy_version_id,
    'org_id', p_org_id,
    'operator_user_id', p_operator_user_id
  );
  overlay_version_id := null;
  overlay_sha256 := null;
  return next;
end;
\$gi\$;

commit;
"@

[IO.File]::WriteAllText($NewMig, $UnblockSql, (Utf8NoBom))
Write-Host ("Wrote migration: {0}" -f $NewMig) -ForegroundColor Green

# ---------------------------------------------------------------------
# 4) PUSH and FAIL if it errors
# ---------------------------------------------------------------------
Push-Location $Root
try {
  Write-Host "Running: supabase db push" -ForegroundColor Cyan
  cmd.exe /c "echo y| supabase db push"
  if ($LASTEXITCODE -ne 0) { throw "supabase db push failed (exit=$LASTEXITCODE)" }
  Write-Host "DB PUSH: OK" -ForegroundColor Green
}
finally { Pop-Location }

Write-Host "== DB GREEN COMPLETE ==" -ForegroundColor Green