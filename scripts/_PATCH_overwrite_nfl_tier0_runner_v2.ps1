param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function Normalize-Lf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  [System.IO.File]::WriteAllBytes($Path, (Utf8NoBom).GetBytes((Normalize-Lf $Text)))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("WRITE_FAILED: " + $Path) }
}
function Parse-GateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + $Path) }
  $tok=$null; $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and $err.Count -gt 0){
    $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "
    throw ("PARSEGATE_FAIL: " + $Path + " :: " + $m)
  }
}
function Sha256FileHex([string]$Path){
  $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  return ($h.Hash.ToLowerInvariant())
}
function RelPath([string]$Root,[string]$Full){
  $r = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
  $f = (Resolve-Path -LiteralPath $Full).Path
  if($f.Length -lt $r.Length){ return ($f -replace '\\','/') }
  if($f.Substring(0,$r.Length).ToLowerInvariant() -ne $r.ToLowerInvariant()){ return ($f -replace '\\','/') }
  $rel = $f.Substring($r.Length).TrimStart('\')
  return ($rel -replace '\\','/')
}
function Write-Sha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){
  $rows = New-Object System.Collections.Generic.List[string]
  foreach($p in $FilesAbs){
    if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + $p) }
    $hex = Sha256FileHex $p
    $rel = RelPath $Root $p
    [void]$rows.Add(($hex + "  " + $rel))
  }
  $txt = ($rows.ToArray() -join "`n") + "`n"
  Write-Utf8NoBomLf $OutPath $txt
}
function Run-Child([string]$PSExe,[string]$ScriptPath,[string]$RepoRoot,[string]$StdOut,[string]$StdErr){
  if(Test-Path -LiteralPath $StdOut -PathType Leaf){ Remove-Item -LiteralPath $StdOut -Force }
  if(Test-Path -LiteralPath $StdErr -PathType Leaf){ Remove-Item -LiteralPath $StdErr -Force }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $ScriptPath,$RepoRoot)
  $psi.WorkingDirectory = $RepoRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  $null = $p.Start()
  $so = $p.StandardOutput.ReadToEnd()
  $se = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  Write-Utf8NoBomLf $StdOut $so
  Write-Utf8NoBomLf $StdErr $se

  return @{ exit=[int]$p.ExitCode; stdout=$so; stderr=$se }
}
function Assert-Contains([string]$Hay,[string]$Needle,[string]$FailToken){
  if($null -eq $Hay){ $Hay = "" }
  if($Hay -notmatch [regex]::Escape($Needle)){
    throw ($FailToken + ":MISSING_NEEDLE:" + $Needle)
  }
}
function Assert-AnyTokenExact([string]$Text,[string[]]$ExactTokens,[string]$FailToken){
  $t = Normalize-Lf $Text
  foreach($x in $ExactTokens){
    if($t -match ("(?m)^\Q" + $x + "\E$")){ return }
  }
  throw ($FailToken + ":NO_EXPECTED_TOKEN")
}
function JsonEsc([string]$s){
  if($null -eq $s){ return "" }
  $t = $s.Replace('\','\\').Replace('"','\"')
  $t = ($t -replace "`r","").Replace("`n","\n")
  return $t
}

$RepoRoot  = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$ProofsDir  = Join-Path $RepoRoot "proofs"
$RcptRoot   = Join-Path $ProofsDir "receipts"

EnsureDir $ProofsDir
EnsureDir $RcptRoot

$OutRunner = Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1"

# --- overwrite runner v2 (known-good; narrow parse-gate) ---
$runner = @"
param([Parameter(Mandatory=\$true)][string]\$RepoRoot)

Set-StrictMode -Version Latest
\$ErrorActionPreference = "Stop"

function EnsureDir([string]\$p){
  if([string]::IsNullOrWhiteSpace(\$p)){ return }
  if(-not (Test-Path -LiteralPath \$p -PathType Container)){
    New-Item -ItemType Directory -Force -Path \$p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding(\$false) }
function Normalize-Lf([string]\$t){
  if(\$null -eq \$t){ return "" }
  \$u = (\$t -replace "`r`n","`n") -replace "`r","`n"
  if(-not \$u.EndsWith("`n")){ \$u += "`n" }
  return \$u
}
function Write-Utf8NoBomLf([string]\$Path,[string]\$Text){
  \$dir = Split-Path -Parent \$Path
  if(\$dir){ EnsureDir \$dir }
  [System.IO.File]::WriteAllBytes(\$Path, (Utf8NoBom).GetBytes((Normalize-Lf \$Text)))
  if(-not (Test-Path -LiteralPath \$Path -PathType Leaf)){ throw ("WRITE_FAILED: " + \$Path) }
}
function Parse-GateFile([string]\$Path){
  if(-not (Test-Path -LiteralPath \$Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + \$Path) }
  \$tok=\$null; \$err=\$null
  [void][System.Management.Automation.Language.Parser]::ParseFile(\$Path,[ref]\$tok,[ref]\$err)
  if(\$err -and \$err.Count -gt 0){
    \$m = (\$err | Select-Object -First 10 | ForEach-Object { \$_.ToString() }) -join " | "
    throw ("PARSEGATE_FAIL: " + \$Path + " :: " + \$m)
  }
}
function Sha256FileHex([string]\$Path){
  \$h = Get-FileHash -LiteralPath \$Path -Algorithm SHA256
  return (\$h.Hash.ToLowerInvariant())
}
function RelPath([string]\$Root,[string]\$Full){
  \$r = (Resolve-Path -LiteralPath \$Root).Path.TrimEnd('\')
  \$f = (Resolve-Path -LiteralPath \$Full).Path
  if(\$f.Length -lt \$r.Length){ return (\$f -replace '\\\\','/') }
  if(\$f.Substring(0,\$r.Length).ToLowerInvariant() -ne \$r.ToLowerInvariant()){ return (\$f -replace '\\\\','/') }
  \$rel = \$f.Substring(\$r.Length).TrimStart('\')
  return (\$rel -replace '\\\\','/')
}
function Write-Sha256Sums([string]\$Root,[string]\$OutPath,[string[]]\$FilesAbs){
  \$rows = New-Object System.Collections.Generic.List[string]
  foreach(\$p in \$FilesAbs){
    if(-not (Test-Path -LiteralPath \$p -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + \$p) }
    \$hex = Sha256FileHex \$p
    \$rel = RelPath \$Root \$p
    [void]\$rows.Add((\$hex + "  " + \$rel))
  }
  Write-Utf8NoBomLf \$OutPath ((\$rows.ToArray() -join "`n") + "`n")
}
function Run-Child([string]\$PSExe,[string]\$ScriptPath,[string]\$RepoRoot,[string]\$StdOut,[string]\$StdErr){
  if(Test-Path -LiteralPath \$StdOut -PathType Leaf){ Remove-Item -LiteralPath \$StdOut -Force }
  if(Test-Path -LiteralPath \$StdErr -PathType Leaf){ Remove-Item -LiteralPath \$StdErr -Force }

  \$psi = New-Object System.Diagnostics.ProcessStartInfo
  \$psi.FileName = \$PSExe
  \$psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f \$ScriptPath,\$RepoRoot)
  \$psi.WorkingDirectory = \$RepoRoot
  \$psi.UseShellExecute = \$false
  \$psi.RedirectStandardOutput = \$true
  \$psi.RedirectStandardError  = \$true
  \$psi.CreateNoWindow = \$true

  \$p = New-Object System.Diagnostics.Process
  \$p.StartInfo = \$psi

  \$null = \$p.Start()
  \$so = \$p.StandardOutput.ReadToEnd()
  \$se = \$p.StandardError.ReadToEnd()
  \$p.WaitForExit()

  Write-Utf8NoBomLf \$StdOut \$so
  Write-Utf8NoBomLf \$StdErr \$se

  return @{ exit=[int]\$p.ExitCode; stdout=\$so; stderr=\$se }
}
function Assert-Contains([string]\$Hay,[string]\$Needle,[string]\$FailToken){
  if(\$null -eq \$Hay){ \$Hay = "" }
  if(\$Hay -notmatch [regex]::Escape(\$Needle)){ throw (\$FailToken + ":MISSING_NEEDLE:" + \$Needle) }
}
function Assert-AnyTokenExact([string]\$Text,[string[]]\$ExactTokens,[string]\$FailToken){
  \$t = Normalize-Lf \$Text
  foreach(\$x in \$ExactTokens){
    if(\$t -match ("(?m)^\\Q" + \$x + "\\E\$")){ return }
  }
  throw (\$FailToken + ":NO_EXPECTED_TOKEN")
}
function JsonEsc([string]\$s){
  if(\$null -eq \$s){ return "" }
  \$t = \$s.Replace('\','\\').Replace('"','\"')
  \$t = (\$t -replace "`r","").Replace("`n","\n")
  return \$t
}

\$RepoRoot  = (Resolve-Path -LiteralPath \$RepoRoot).Path
\$ScriptsDir = Join-Path \$RepoRoot "scripts"
\$ProofsDir  = Join-Path \$RepoRoot "proofs"
\$RcptRoot   = Join-Path \$ProofsDir "receipts"

EnsureDir \$ProofsDir
EnsureDir \$RcptRoot

# --- Tier-0 parse-gate ONLY product surface (NO _PATCH_*, NO _bootstrap_*, NO _install_*) ---
\$must = @(
  (Join-Path \$ScriptsDir "verify_packet_v1.ps1"),
  (Join-Path \$ScriptsDir "selftest_verify_packet_v1.ps1"),
  (Join-Path \$ScriptsDir "selftest_vectors_v1.ps1"),
  (Join-Path \$ScriptsDir "_selftest_nfl_tier0_v2.ps1")
)
\$libs = @(Get-ChildItem -LiteralPath \$ScriptsDir -File -Filter "lib_*.ps1" -ErrorAction SilentlyContinue | Sort-Object FullName)
foreach(\$l in \$libs){ \$must += @(\$l.FullName) }

foreach(\$p in \$must){
  if(-not (Test-Path -LiteralPath \$p -PathType Leaf)){ throw ("PARSEGATE_REQUIRED_MISSING: " + \$p) }
  Parse-GateFile \$p
}
Write-Output "PARSE_GATE_OK"

# --- bundle ---
\$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
\$bundle = Join-Path \$RcptRoot \$stamp
EnsureDir \$bundle

\$out1 = Join-Path \$bundle "selftest_verify_packet.stdout.txt"
\$err1 = Join-Path \$bundle "selftest_verify_packet.stderr.txt"
\$out2 = Join-Path \$bundle "selftest_vectors.stdout.txt"
\$err2 = Join-Path \$bundle "selftest_vectors.stderr.txt"

\$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
if(-not (Test-Path -LiteralPath \$PSExe -PathType Leaf)){ throw ("MISSING_POWERSHELL_EXE: " + \$PSExe) }

\$st1 = Join-Path \$ScriptsDir "selftest_verify_packet_v1.ps1"
\$st2 = Join-Path \$ScriptsDir "selftest_vectors_v1.ps1"

\$r1 = Run-Child \$PSExe \$st1 \$RepoRoot \$out1 \$err1
if(\$r1.exit -ne 0){ Write-Output ("SELFTEST_VERIFY_PACKET_EXIT=" + \$r1.exit); throw "SELFTEST_VERIFY_PACKET_FAILED" }
Assert-Contains \$r1.stdout "VERIFY_SELFTEST_OK" "SELFTEST_VERIFY_PACKET_BAD_STDOUT"

\$r2 = Run-Child \$PSExe \$st2 \$RepoRoot \$out2 \$err2
if(\$r2.exit -ne 0){ Write-Output ("SELFTEST_VECTORS_EXIT=" + \$r2.exit); throw "SELFTEST_VECTORS_FAILED" }
Assert-Contains \$r2.stdout "VECTORS_SELFTEST_OK" "SELFTEST_VECTORS_BAD_STDOUT"

# --- Phase 6 gate: require suite to emit at least ONE stable token line (exact) ---
\$expected = @(
  "NFL_VERIFY_FAIL:SHA256_MISMATCH",
  "NFL_VERIFY_FAIL:MISSING_SIG",
  "NFL_VERIFY_FAIL:SIG_VERIFY_FAIL",
  "NFL_VERIFY_FAIL:MISSING_SHA256SUMS",
  "NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE",
  "NFL_VERIFY_FAIL:TRAVERSAL_PATH",
  "NFL_VERIFY_FAIL:MISSING_TARGET"
)
Assert-AnyTokenExact \$r2.stdout \$expected "ERROR_TAXONOMY_NOT_EMITTED"

# --- receipt + sha256 evidence ---
\$rcptPath = Join-Path \$bundle "nfl.tier0.selftest.v1.ndjson"
\$line = '{' +
  '"type":"nfl.tier0.selftest.v1",' +
  '"utc":"' + (JsonEsc \$stamp) + '",' +
  '"ok":true,' +
  '"repo_root":"' + (JsonEsc \$RepoRoot) + '",' +
  '"bundle_dir":"' + (JsonEsc \$bundle) + '",' +
  '"selftest_verify_exit":' + \$r1.exit + ',' +
  '"selftest_vectors_exit":' + \$r2.exit +
'}'
Write-Utf8NoBomLf \$rcptPath (\$line + "`n")

\$bundleFiles = Get-ChildItem -LiteralPath \$bundle -Recurse -File | Sort-Object FullName
\$abs = New-Object System.Collections.Generic.List[string]
foreach(\$f in \$bundleFiles){ [void]\$abs.Add(\$f.FullName) }
\$sumPath = Join-Path \$bundle "sha256sums.txt"
Write-Sha256Sums \$bundle \$sumPath (\$abs.ToArray())

Write-Output "NFL_TIER0_SELFTEST_OK"
Write-Output ("BUNDLE_DIR=" + \$bundle)
"@

Write-Utf8NoBomLf $OutRunner $runner
Parse-GateFile $OutRunner

Write-Output ("PATCH_OK wrote=" + $OutRunner)
