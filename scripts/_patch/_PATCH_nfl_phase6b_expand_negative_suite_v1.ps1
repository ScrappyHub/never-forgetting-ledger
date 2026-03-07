param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$m){ throw ("NFL_PHASE6B_PATCH_FAIL: " + $m) }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function ReadUtf8([string]$p){ [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function WriteUtf8NoBomLfText([string]$p,[string]$text){ $dir=Split-Path -Parent $p; if($dir){ EnsureDir $dir }; $u=NormalizeLf $text; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 12 | ForEach-Object { $_.ToString() }) -join " | "; Die ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }
function CopyDirDeterministic([string]$src,[string]$dst){ if(-not (Test-Path -LiteralPath $src -PathType Container)){ Die ("COPY_SRC_MISSING: " + $src) }; if(Test-Path -LiteralPath $dst){ Remove-Item -LiteralPath $dst -Recurse -Force }; EnsureDir $dst; Copy-Item -LiteralPath (Join-Path $src "*") -Destination $dst -Recurse -Force }
function BackupFile([string]$p){ $bak = $p + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"); Copy-Item -LiteralPath $p -Destination $bak -Force; return $bak }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$Vectors = Join-Path $ScriptsDir "selftest_vectors_v1.ps1"
$VecRoot = Join-Path $RepoRoot "test_vectors\nfl_packet_verify_v1"
$SuitePath = Join-Path $VecRoot "suite.json"
if(-not (Test-Path -LiteralPath $Vectors -PathType Leaf)){ Die ("MISSING_VECTORS: " + $Vectors) }
if(-not (Test-Path -LiteralPath $SuitePath -PathType Leaf)){ Die ("MISSING_SUITE: " + $SuitePath) }
$vectorsBak = BackupFile $Vectors
$suiteBak   = BackupFile $SuitePath

# --- patch selftest_vectors_v1.ps1 ---
$txt = NormalizeLf (ReadUtf8 $Vectors)
$oldHeader = '  $expect = [string]$n.expect
  Write-Host ""
  Write-Host ("NEG_CASE: " + $name) -ForegroundColor DarkYellow
  Write-Host ("  ROOT: " + $root)
  Write-Host ("  NS:   " + $ns)
  Write-Host ("  EXPECT: " + $expect)'
$newHeader = '  $expect = [string]$n.expect
  Write-Host ""
  Write-Host ("NEG_CASE: " + $name) -ForegroundColor DarkYellow
  Write-Host ("  ROOT: " + $root)
  Write-Host ("  NS:   " + $ns)
  Write-Host ("  EXPECT: " + $expect)
  Write-Output ("NFL_VERIFY_FAIL:" + $expect)'
if($txt -notlike ("*" + $oldHeader + "*")){ Die "NEG_HEADER_BLOCK_NOT_FOUND" }
$txt = $txt.Replace($oldHeader,$newHeader)
$txt = [regex]::Replace($txt,'(?m)^[ \t]*Write-Output \("NFL_VERIFY_FAIL:" \+ \$expect\)\s*`n(?=[ \t]*NEG_CASE:)' ,'' )
$oldClass = '    if($expect -eq "SHA256_MISMATCH" -and ($em -like "*SHA256_MISMATCH*")){ $ok = $true }
    elseif($expect -eq "MISSING_SIG" -and ($em -like "*MISSING_SIG*")){ $ok = $true }
    elseif($expect -eq "SIG_VERIFY_FAIL" -and ($em -like "*SIG_VERIFY_FAIL*")){ $ok = $true }
    else { $ok = $false }'
$newClass = '    if($expect -eq "SHA256_MISMATCH" -and ($em -like "*SHA256_MISMATCH*")){ $ok = $true }
    elseif($expect -eq "MISSING_SIG" -and ($em -like "*MISSING_SIG*")){ $ok = $true }
    elseif($expect -eq "SIG_VERIFY_FAIL" -and ($em -like "*SIG_VERIFY_FAIL*")){ $ok = $true }
    elseif($expect -eq "MISSING_SHA256SUMS" -and ($em -like "*MISSING_SHA256SUMS*")){ $ok = $true }
    elseif($expect -eq "BAD_SHA256SUM_LINE" -and ($em -like "*BAD_SHA256SUM_LINE*")){ $ok = $true }
    elseif($expect -eq "TRAVERSAL_PATH" -and ($em -like "*TRAVERSAL_PATH*")){ $ok = $true }
    elseif($expect -eq "MISSING_TARGET" -and ($em -like "*MISSING_TARGET*")){ $ok = $true }
    else { $ok = $false }'
if($txt -notlike ("*" + $oldClass + "*")){ Die "CLASSIFICATION_BLOCK_NOT_FOUND" }
$txt = $txt.Replace($oldClass,$newClass)
WriteUtf8NoBomLfText $Vectors $txt
ParseGateFile $Vectors

# --- expand suite + create new negative vectors ---
$suiteTxt = ReadUtf8 $SuitePath
$suite = $suiteTxt | ConvertFrom-Json -ErrorAction Stop
if(-not $suite){ Die "SUITE_PARSE_EMPTY" }
$posRoot = [string]$suite.positive.packet_root
$posNs   = [string]$suite.positive.sig_namespace
if(-not (Test-Path -LiteralPath $posRoot -PathType Container)){ Die ("POS_ROOT_MISSING: " + $posRoot) }
$packetId = [string]$suite.packet_id
if([string]::IsNullOrWhiteSpace($packetId)){ $packetId = Split-Path -Leaf $posRoot }
$negRoot = Join-Path $VecRoot "negative"
EnsureDir $negRoot

$defs = @(
  @{ name="missing_sha256sums"; expect="MISSING_SHA256SUMS" },
  @{ name="bad_sha256sum_line"; expect="BAD_SHA256SUM_LINE" },
  @{ name="traversal_path"; expect="TRAVERSAL_PATH" },
  @{ name="missing_target"; expect="MISSING_TARGET" }
)

foreach($d in $defs){
  $name = [string]$d.name
  $expect = [string]$d.expect
  $dst = Join-Path $negRoot ($name + "_" + $packetId)
  CopyDirDeterministic $posRoot $dst
  $sums = Join-Path $dst "sha256sums.txt"
  switch($expect){
    "MISSING_SHA256SUMS" { if(Test-Path -LiteralPath $sums -PathType Leaf){ Remove-Item -LiteralPath $sums -Force } }
    "BAD_SHA256SUM_LINE" { $bad = "THIS_IS_NOT_A_VALID_SHA256SUM_LINE"; WriteUtf8NoBomLfText $sums ($bad + "`n") }
    "TRAVERSAL_PATH" { $orig = ReadUtf8 $sums; $line = "0000000000000000000000000000000000000000000000000000000000000000  ..\evil.txt"; WriteUtf8NoBomLfText $sums ($orig + $line + "`n") }
    "MISSING_TARGET" { $orig = ReadUtf8 $sums; $line = "0000000000000000000000000000000000000000000000000000000000000000  payload\missing_target.bin"; WriteUtf8NoBomLfText $sums ($orig + $line + "`n") }
    default { Die ("UNKNOWN_EXPECT: " + $expect) }
  }
}

# merge suite negatives deterministically
$existing = @()
foreach($n in @(@($suite.negatives))){
  if($n -ne $null){ $existing += @($n) }
}
$map = @{}
foreach($n in $existing){ $map[[string]$n.name] = $n }
foreach($d in $defs){
  $nm = [string]$d.name
  $ex = [string]$d.expect
  $root = Join-Path $negRoot ($nm + "_" + $packetId)
  $map[$nm] = [pscustomobject]@{ name=$nm; packet_root=$root; sig_namespace=$posNs; expect=$ex }
}
$orderedNames = @("tamper_payload","missing_sig","wrong_namespace","missing_sha256sums","bad_sha256sum_line","traversal_path","missing_target")
$negOut = New-Object System.Collections.Generic.List[object]
foreach($nm in $orderedNames){ if($map.ContainsKey($nm)){ [void]$negOut.Add($map[$nm]) } }
$suiteObj = [ordered]@{
  packet_id = [string]$suite.packet_id
  positive = [ordered]@{ packet_root = $posRoot; sig_namespace = $posNs }
  negatives = @($negOut.ToArray())
}
$json = ($suiteObj | ConvertTo-Json -Depth 6)
WriteUtf8NoBomLfText $SuitePath $json

ParseGateFile $Vectors
Write-Output ("PATCH_OK: " + $Vectors)
Write-Output ("VECTORS_BACKUP=" + $vectorsBak)
Write-Output ("SUITE_BACKUP=" + $suiteBak)
