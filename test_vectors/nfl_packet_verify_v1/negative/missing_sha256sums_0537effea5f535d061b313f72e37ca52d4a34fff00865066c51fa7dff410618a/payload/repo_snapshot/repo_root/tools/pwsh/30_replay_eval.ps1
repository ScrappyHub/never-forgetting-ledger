Set-StrictMode -Version Latest
. "$PSScriptRoot\00_env.ps1"

param(
  [Parameter(Mandatory=$true)]
  [string]$EvaluationId
)

$headers = @{
  "apikey"        = $SUPABASE_KEY
  "Authorization" = "Bearer $SUPABASE_KEY"
  "Content-Type"  = "application/json"
}

# 1) Fetch original evaluation row (REST select)
$evalUri = "$SUPABASE_URL/rest/v1/governance_evaluations?evaluation_id=eq.$EvaluationId&select=evaluation_id,proposal,policy_hash_sha256,decision,reason_codes,created_at"
$orig = Invoke-RestMethod -Method Get -Uri $evalUri -Headers $headers
if (-not $orig -or $orig.Count -lt 1) { throw "Evaluation not found: $EvaluationId" }
$orig = $orig[0]

# 2) Replay under the same policy hash
$replayUri = "$SUPABASE_URL/rest/v1/rpc/replay_proposal_at_policy_hash"
$replayBody = @{
  p_policy_hash_sha256 = $orig.policy_hash_sha256
  p_proposal           = $orig.proposal
}
$replay = Invoke-RestMethod -Method Post -Uri $replayUri -Headers $headers -Body ($replayBody | ConvertTo-Json -Depth 50)

# 3) Persist replay bundle
$repoRoot = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repoRoot "replays"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
$bundleDir = Join-Path $outDir "replay_${EvaluationId}_$ts"
New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null

($orig   | ConvertTo-Json -Depth 50) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $bundleDir "original_evaluation_row.json")
($replay | ConvertTo-Json -Depth 50) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $bundleDir "replay_result.json")

# 4) Print verdict
[pscustomobject]@{
  evaluation_id = $EvaluationId
  policy_hash_sha256 = $orig.policy_hash_sha256
  original_decision = $orig.decision
  replay_decision   = $replay.decision
  original_reasons  = ($orig.reason_codes -join ",")
  replay_reasons    = ($replay.reason_codes -join ",")
  match = ($orig.decision -eq $replay.decision)
}
