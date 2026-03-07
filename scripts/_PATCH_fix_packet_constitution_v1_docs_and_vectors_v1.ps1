param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  if (-not $norm.EndsWith("`n")) { $norm += "`n" }
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}
function ParseGatePs1([string]$Path){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { throw ("PARSE ERROR: " + $errs[0].Message + " (file: " + $Path + ")") }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $Root "scripts"
$Target = Join-Path $ScriptsDir "_PATCH_packet_constitution_v1_docs_and_vectors.ps1"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if (Test-Path -LiteralPath $Target -PathType Leaf) {
  $bak = $Target + ".bak_" + $stamp
  Copy-Item -LiteralPath $Target -Destination $bak -Force | Out-Null
  Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
}

# ---- Write the corrected patch script (NO here-strings) ----
$S = New-Object System.Collections.Generic.List[string]
[void]$S.Add("param([Parameter(Mandatory=$true)][string]`$RepoRoot)")
[void]$S.Add("")
[void]$S.Add("`$ErrorActionPreference=`"Stop`"")
[void]$S.Add("Set-StrictMode -Version Latest")
[void]$S.Add("")
[void]$S.Add("function Die([string]`$m){ throw `$m }")
[void]$S.Add("function Write-Utf8NoBomLf([string]`$Path,[string]`$Text){")
[void]$S.Add("  `$enc = New-Object System.Text.UTF8Encoding(`$false)")
[void]$S.Add("  `$dir = Split-Path -Parent `$Path")
[void]$S.Add("  if (`$dir -and -not (Test-Path -LiteralPath `$dir -PathType Container)) { New-Item -ItemType Directory -Force -Path `$dir | Out-Null }")
[void]$S.Add("  `$norm = (`$Text -replace ``"`r``"`n``,``"`n``" -replace ``"`r``"``,``"`n``"")
[void]$S.Add("  if (-not `$norm.EndsWith(``"`n``"")) { `$norm += ``"`n``"" }")
[void]$S.Add("  [System.IO.File]::WriteAllText(`$Path,`$norm,`$enc)")
[void]$S.Add("}")
[void]$S.Add("")
[void]$S.Add("`$Root = (Resolve-Path -LiteralPath `$RepoRoot).Path")
[void]$S.Add("`$LawDir = Join-Path `$Root ``"docs\packet_constitution_v1``"")
[void]$S.Add("`$VecDir = Join-Path `$Root ``"test_vectors\packet_constitution_v1``"")
[void]$S.Add("foreach(`$d in @(`$LawDir,`$VecDir)){ if (-not (Test-Path -LiteralPath `$d -PathType Container)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null } }")
[void]$S.Add("")
[void]$S.Add("`$LawPath   = Join-Path `$LawDir ``"PACKET_CONSTITUTION_V1.md``"")
[void]$S.Add("`$FinalPath = Join-Path `$LawDir ``"FINALIZATION_LAW_V1.md``"")
[void]$S.Add("`$ChkPath   = Join-Path `$LawDir ``"COMPLIANCE_CHECKLIST_V1.md``"")
[void]$S.Add("`$ReadmeVec = Join-Path `$VecDir ``"README.md``"")
[void]$S.Add("")
[void]$S.Add("# --- Authoritative law text (locked) ---")
[void]$S.Add("`$law = @(")
[void]$S.Add(") -join ``"`n``"")
[void]$S.Add("")
[void]$S.Add("# --- Finalization Law v1 (structured) ---")
[void]$S.Add("`$final = @(")
[void]$S.Add(") -join ``"`n``"")
[void]$S.Add("")
[void]$S.Add("Write-Utf8NoBomLf -Path `$LawPath   -Text `$law")
[void]$S.Add("Write-Utf8NoBomLf -Path `$FinalPath -Text `$final")
[void]$S.Add("Write-Utf8NoBomLf -Path `$ChkPath   -Text `$chk")
[void]$S.Add("Write-Utf8NoBomLf -Path `$ReadmeVec -Text `$vecReadme")
[void]$S.Add("")
[void]$S.Add("# --- Vectors skeleton (placeholders only; no invented golden values) ---")
[void]$S.Add("`$min = Join-Path `$VecDir ``"minimal_packet``"")
[void]$S.Add("`$minPayload = Join-Path `$min ``"payload``"")
[void]$S.Add("`$minSigs = Join-Path `$min ``"signatures``"")
[void]$S.Add("foreach(`$d in @(`$min,`$minPayload,`$minSigs)){ if (-not (Test-Path -LiteralPath `$d -PathType Container)) { New-Item -ItemType Directory -Force -Path `$d | Out-Null } }")
[void]$S.Add("`$ph = @(")
[void]$S.Add("  (Join-Path `$VecDir ``"golden_manifest_without_id.bytes``"),")
[void]$S.Add("  (Join-Path `$VecDir ``"expected_packet_id.txt``"),")
[void]$S.Add("  (Join-Path `$VecDir ``"expected_sha256sums.txt``"),")
[void]$S.Add("  (Join-Path `$VecDir ``"expected_verify_result.txt``"),")
[void]$S.Add("  (Join-Path `$minPayload ``"payload.bin``"),")
[void]$S.Add("  (Join-Path `$min ``"manifest.json``"),")
[void]$S.Add("  (Join-Path `$min ``"packet_id.txt``"),")
[void]$S.Add("  (Join-Path `$min ``"sha256sums.txt``")")
[void]$S.Add(")")
[void]$S.Add("foreach(`$f in @(@(`$ph))){ if (-not (Test-Path -LiteralPath `$f -PathType Leaf)) { Write-Utf8NoBomLf -Path `$f -Text ``"# TODO: populate via canonical producer/verifier tool; placeholder contains no golden values.``" } }")
[void]$S.Add("")
[void]$S.Add("Write-Host (``"WROTE: ``" + `$LawPath)   -ForegroundColor Green")
[void]$S.Add("Write-Host (``"WROTE: ``" + `$FinalPath) -ForegroundColor Green")
[void]$S.Add("Write-Host (``"WROTE: ``" + `$ChkPath)   -ForegroundColor Green")
[void]$S.Add("Write-Host (``"WROTE: ``" + `$ReadmeVec) -ForegroundColor Green")
[void]$S.Add("Write-Host (``"WROTE: test_vectors skeleton at ``" + `$VecDir) -ForegroundColor Green")
[void]$S.Add("Write-Host ``"PATCH_DONE: Packet Constitution v1 stamped into NFL (witness-law + vectors skeleton)``" -ForegroundColor Green")

function JoinLines([System.Collections.Generic.List[string]]$xs){ return ($xs.ToArray() -join "`n") }
$txt = JoinLines $S
Write-Utf8NoBomLf -Path $Target -Text $txt
ParseGatePs1 $Target
Write-Host ("REPAIRED_PATCH_WRITTEN+PARSED: " + $Target) -ForegroundColor Green

# Execute the repaired patch script deterministically
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Target -RepoRoot $Root
Write-Host "FIX_PATCH_DONE" -ForegroundColor Green
