param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$m){ throw ("NFL_PATCH_MISSING_TARGET_FAIL: " + $m) }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function ReadUtf8([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("MISSING_FILE: " + $p) }; [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function WriteUtf8NoBomLfText([string]$p,[string]$t){ $dir = Split-Path -Parent $p; if($dir){ EnsureDir $dir }; $u = NormalizeLf $t; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 12 | ForEach-Object { $_.ToString() }) -join " | "; Die ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }
function BackupFile([string]$p){ $bak = $p + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"); Copy-Item -LiteralPath $p -Destination $bak -Force; return $bak }
function CopyDirDeterministic([string]$src,[string]$dst){ if(-not (Test-Path -LiteralPath $src -PathType Container)){ Die ("COPY_SRC_MISSING: " + $src) }; if(Test-Path -LiteralPath $dst){ Remove-Item -LiteralPath $dst -Recurse -Force }; EnsureDir $dst; Get-ChildItem -LiteralPath $src -Force | Sort-Object Name | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force } }

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$Vectors    = Join-Path $ScriptsDir "selftest_vectors_v1.ps1"
$Runner     = Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1"
$VecRoot    = Join-Path $RepoRoot "test_vectors\nfl_packet_verify_v1"
$SuitePath  = Join-Path $VecRoot "suite.json"
if(-not (Test-Path -LiteralPath $Vectors -PathType Leaf)){ Die ("MISSING_VECTORS: " + $Vectors) }
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
if(-not (Test-Path -LiteralPath $SuitePath -PathType Leaf)){ Die ("MISSING_SUITE: " + $SuitePath) }
$vectorsBak = BackupFile $Vectors
$runnerBak  = BackupFile $Runner
$suiteBak   = BackupFile $SuitePath

# 1) patch selftest_vectors_v1.ps1 classification
$vtxt = NormalizeLf (ReadUtf8 $Vectors)
if($vtxt -notlike "*MISSING_TARGET*"){
  $old = @'
    if($expect -eq "SHA256_MISMATCH" -and ($em -like "*SHA256_MISMATCH*")){ $ok = $true }
    elseif($expect -eq "MISSING_SIG" -and ($em -like "*MISSING_SIG*")){ $ok = $true }
    elseif($expect -eq "SIG_VERIFY_FAIL" -and ($em -like "*SIG_VERIFY_FAIL*")){ $ok = $true }
    elseif($expect -eq "MISSING_SHA256SUMS" -and ($em -like "*MISSING_SHA256SUMS*")){ $ok = $true }
    elseif($expect -eq "BAD_SHA256SUM_LINE" -and ($em -like "*BAD_SHA256SUM_LINE*")){ $ok = $true }
    elseif($expect -eq "TRAVERSAL_PATH" -and ($em -like "*TRAVERSAL_PATH*")){ $ok = $true }
    else { $ok = $false }
'@
  $new = @'
    if($expect -eq "SHA256_MISMATCH" -and ($em -like "*SHA256_MISMATCH*")){ $ok = $true }
    elseif($expect -eq "MISSING_SIG" -and ($em -like "*MISSING_SIG*")){ $ok = $true }
    elseif($expect -eq "SIG_VERIFY_FAIL" -and ($em -like "*SIG_VERIFY_FAIL*")){ $ok = $true }
    elseif($expect -eq "MISSING_SHA256SUMS" -and ($em -like "*MISSING_SHA256SUMS*")){ $ok = $true }
    elseif($expect -eq "BAD_SHA256SUM_LINE" -and ($em -like "*BAD_SHA256SUM_LINE*")){ $ok = $true }
    elseif($expect -eq "TRAVERSAL_PATH" -and ($em -like "*TRAVERSAL_PATH*")){ $ok = $true }
    elseif($expect -eq "MISSING_TARGET" -and ($em -like "*MISSING_TARGET*")){ $ok = $true }
    else { $ok = $false }
'@
  if($vtxt -notlike ("*" + ($old.Trim()) + "*")){ Die "CLASSIFICATION_BLOCK_NOT_FOUND" }
  $vtxt = $vtxt.Replace($old,$new)
}
WriteUtf8NoBomLfText $Vectors $vtxt
ParseGateFile $Vectors

# 2) add one new negative vector + suite entry
$suiteTxt = ReadUtf8 $SuitePath
$suite = $suiteTxt | ConvertFrom-Json -ErrorAction Stop
if(-not $suite){ Die "SUITE_PARSE_EMPTY" }
$posRoot = [string]$suite.positive.packet_root
$posNs   = [string]$suite.positive.sig_namespace
$packetId = [string]$suite.packet_id
if([string]::IsNullOrWhiteSpace($packetId)){ $packetId = Split-Path -Leaf $posRoot }
if(-not (Test-Path -LiteralPath $posRoot -PathType Container)){ Die ("POS_ROOT_MISSING: " + $posRoot) }
$negRoot = Join-Path $VecRoot "negative"
EnsureDir $negRoot
$newName   = "missing_target"
$newExpect = "MISSING_TARGET"
$newRoot   = Join-Path $negRoot ($newName + "_" + $packetId)
CopyDirDeterministic $posRoot $newRoot
$sums = Join-Path $newRoot "sha256sums.txt"
$orig = ReadUtf8 $sums
$line = "0000000000000000000000000000000000000000000000000000000000000000  payload\missing_target.bin"
WriteUtf8NoBomLfText $sums ($orig + $line + "`n")

$map = @{}
foreach($n in @(@($suite.negatives))){ if($n -ne $null){ $map[[string]$n.name] = $n } }
$map[$newName] = [pscustomobject]@{ name=$newName; packet_root=$newRoot; sig_namespace=$posNs; expect=$newExpect }
$orderedNames = @("tamper_payload","missing_sig","wrong_namespace","missing_sha256sums","bad_sha256sum_line","traversal_path","missing_target")
$negOut = New-Object System.Collections.Generic.List[object]
foreach($nm in $orderedNames){ if($map.ContainsKey($nm)){ [void]$negOut.Add($map[$nm]) } }
$suiteObj = [ordered]@{
  packet_id = [string]$suite.packet_id
  positive  = [ordered]@{ packet_root = $posRoot; sig_namespace = $posNs }
  negatives = @($negOut.ToArray())
}
$json = ($suiteObj | ConvertTo-Json -Depth 6)
WriteUtf8NoBomLfText $SuitePath $json

# 3) patch runner expected set from 6 -> 7 tokens
$rtxt = NormalizeLf (ReadUtf8 $Runner)
$oldExpected6 = '$expected=@("NFL_VERIFY_FAIL:SHA256_MISMATCH","NFL_VERIFY_FAIL:MISSING_SIG","NFL_VERIFY_FAIL:SIG_VERIFY_FAIL","NFL_VERIFY_FAIL:MISSING_SHA256SUMS","NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE","NFL_VERIFY_FAIL:TRAVERSAL_PATH")'
$newExpected7 = '$expected=@("NFL_VERIFY_FAIL:SHA256_MISMATCH","NFL_VERIFY_FAIL:MISSING_SIG","NFL_VERIFY_FAIL:SIG_VERIFY_FAIL","NFL_VERIFY_FAIL:MISSING_SHA256SUMS","NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE","NFL_VERIFY_FAIL:TRAVERSAL_PATH","NFL_VERIFY_FAIL:MISSING_TARGET")'
if($rtxt -like ("*" + $oldExpected6 + "*")){
  $rtxt = $rtxt.Replace($oldExpected6,$newExpected7)
} elseif($rtxt -notlike ("*" + $newExpected7 + "*")){
  Die "RUNNER_EXPECTED_BLOCK_NOT_FOUND"
}
WriteUtf8NoBomLfText $Runner $rtxt
ParseGateFile $Runner

Write-Output ("PATCH_OK: " + $Vectors)
Write-Output ("VECTORS_BACKUP=" + $vectorsBak)
Write-Output ("RUNNER_BACKUP=" + $runnerBak)
Write-Output ("SUITE_BACKUP=" + $suiteBak)
