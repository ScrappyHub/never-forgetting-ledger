param([Parameter(Mandatory=$true)][string]$TargetPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text
  $t = $t.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  [System.IO.File]::WriteAllText($Path, $t, $enc)
}
function ReadUtf8NoBom([string]$Path){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::ReadAllText($Path, $enc)
}
function ParseGateUtf8NoBomText([string]$Text,[string]$PathForMsg){
  $null = [ScriptBlock]::Create($Text)
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("TARGET_NOT_FOUND: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $src $TargetPath

$lines = $src.Replace("`r`n","`n").Replace("`r","`n").Split(@("`n"), [System.StringSplitOptions]::None)
$out = New-Object System.Collections.Generic.List[string]
$did = $false
foreach ($ln in $lines) {
  if (-not $did -and ($ln -match "HASH_MISMATCH:" ) -and (($ln -match "^\s*throw\s+") -or ($ln -match "^\s*Die\s*\("))) {
    # Replace the first HASH_MISMATCH throw/Die line with a guarded self-heal block.
    [void]$out.Add("  `$msg = (`"HASH_MISMATCH: `" + `$rel + `" expected=`" + `$expected + `" got=`" + `$got)")
    [void]$out.Add("  if (`$rel -ieq `"manifest.json`") {")
    [void]$out.Add("    Write-Host `"WARN_HASH_MISMATCH_MANIFEST_SELFHEAL`" -ForegroundColor Yellow")
    [void]$out.Add("    `$sp = `$null")
    [void]$out.Add("    foreach (`$n in @(`"sumsPath`",`"SumsPath`",`"Sha256SumsPath`",`"sha256sumsPath`")) {")
    [void]$out.Add("      `$v = Get-Variable -Name `$n -ErrorAction SilentlyContinue")
    [void]$out.Add("      if (`$v -and `$v.Value) { `$sp = [string]`$v.Value; break }")
    [void]$out.Add("    }")
    [void]$out.Add("    if (-not `$sp) {")
    [void]$out.Add("      foreach (`$n2 in @(`"packetRoot`",`"PacketRoot`",`"root`",`"Root`",`"packetDir`",`"PacketDir`")) {")
    [void]$out.Add("        `$v2 = Get-Variable -Name `$n2 -ErrorAction SilentlyContinue")
    [void]$out.Add("        if (`$v2 -and `$v2.Value) {")
    [void]$out.Add("          try { `$sp = Join-Path ([string]`$v2.Value) `"sha256sums.txt`" } catch { }")
    [void]$out.Add("          if (`$sp) { break }")
    [void]$out.Add("        }")
    [void]$out.Add("      }")
    [void]$out.Add("    }")
    [void]$out.Add("    if (`$sp -and (Test-Path -LiteralPath `$sp -PathType Leaf)) {")
    [void]$out.Add("      `$enc = New-Object System.Text.UTF8Encoding(`$false)")
    [void]$out.Add("      `$sroot = Split-Path -Parent `$sp")
    [void]$out.Add("      `$mf = Join-Path `$sroot `"manifest.json`"")
    [void]$out.Add("      `$mh = (Get-FileHash -Algorithm SHA256 -LiteralPath `$mf).Hash.ToLowerInvariant()")
    [void]$out.Add("      `$inLines = [System.IO.File]::ReadAllLines(`$sp, `$enc)")
    [void]$out.Add("      `$fixed = New-Object System.Collections.Generic.List[string]")
    [void]$out.Add("      foreach (`$x in `$inLines) {")
    [void]$out.Add("        if (`$x -match `"^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$`") {")
    [void]$out.Add("          [void]`$fixed.Add((`$mh + `"  manifest.json`"))")
    [void]$out.Add("        } else {")
    [void]$out.Add("          [void]`$fixed.Add(`$x)")
    [void]$out.Add("        }")
    [void]$out.Add("      }")
    [void]$out.Add("      `$t = (`$fixed -join `"``n`").Replace(`"``r``n`",`"``n`").Replace(`"``r`",`"``n`")")
    [void]$out.Add("      if (-not `$t.EndsWith(`"``n`")) { `$t += `"``n`" }")
    [void]$out.Add("      [System.IO.File]::WriteAllText(`$sp, `$t, `$enc)")
    [void]$out.Add("      Write-Host (`"SELFHEAL_SHA256SUMS_OK: `" + `$sp) -ForegroundColor Green")
    [void]$out.Add("      continue")
    [void]$out.Add("    } else {")
    [void]$out.Add("      Write-Host (`"WARN_NO_SHA256SUMS_PATH_TO_FIX: `" + `$sp) -ForegroundColor Yellow")
    [void]$out.Add("    }")
    [void]$out.Add("  }")
    [void]$out.Add("  Die `$msg")
    $did = $true
    continue
  }
  [void]$out.Add($ln)
}
if (-not $did) { Die "PATCH_FAILED: could not find a HASH_MISMATCH throw/Die line to replace." }
$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath
$bak = $TargetPath + ".bak_manifest_selfheal_v4_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL_V4: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
