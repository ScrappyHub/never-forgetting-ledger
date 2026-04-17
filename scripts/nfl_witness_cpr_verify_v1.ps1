param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$CprVerifierPath,
  [Parameter(Mandatory=$true)][string]$PacketDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_WITNESS_CPR_VERIFY_FAIL:" + $m) }

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Utf8NoBom(){
  New-Object System.Text.UTF8Encoding($false)
}

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$CprVerifierPath = (Resolve-Path -LiteralPath $CprVerifierPath).Path
$PacketDir = (Resolve-Path -LiteralPath $PacketDir).Path

$CprRepoRoot = Split-Path -Parent (Split-Path -Parent $CprVerifierPath)

$RcptDir = Join-Path $RepoRoot "proofs\receipts"
$RcptPath = Join-Path $RcptDir "nfl.cpr_verify_witness.ndjson"
EnsureDir $RcptDir

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
$psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -PacketPath "{2}"' -f $CprVerifierPath, $CprRepoRoot, $PacketDir)
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
$stdout = $p.StandardOutput.ReadToEnd()
$stderr = $p.StandardError.ReadToEnd()
$p.WaitForExit()

$ok = $false
if(($p.ExitCode -eq 0) -and ($stdout -match 'CPR_VERIFY_OK')){
  $ok = $true
}

$receipt = [ordered]@{
  schema = "nfl.cpr_verify_witness.receipt.v1"
  utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  ok = $ok
  packet_dir = $PacketDir
  cpr_repo_root = $CprRepoRoot
  cpr_verifier = $CprVerifierPath
  exit_code = [int]$p.ExitCode
  stdout = $stdout
  stderr = $stderr
}

$line = ($receipt | ConvertTo-Json -Compress -Depth 10)
Add-Content -LiteralPath $RcptPath -Value $line -Encoding UTF8

if(-not $ok){
  Fail "CPR_VERIFY_NOT_GREEN"
}

Write-Output "NFL_WITNESS_CPR_VERIFY_OK"
Write-Output ("RECEIPT=" + $RcptPath)