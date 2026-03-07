param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [Parameter(Mandatory=$true)][string]$SigNamespace,
  [Parameter(Mandatory=$false)][string]$AllowedSigners
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("COVENANT_VERIFY_FAIL: " + $m) }
function ReadUtf8([string]$p){ return [System.IO.File]::ReadAllText($p,(New-Object System.Text.UTF8Encoding($false))) }
function HexSha256File([string]$p){
  $fs = [System.IO.File]::OpenRead($p)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $h = $sha.ComputeHash($fs)
    } finally { $sha.Dispose() }
  } finally { $fs.Dispose() }
  $sb = New-Object System.Text.StringBuilder
  foreach($b in @($h)){ [void]$sb.Append($b.ToString("x2")) }
  return $sb.ToString()
}

$PacketRoot = (Resolve-Path -LiteralPath $PacketRoot).Path
if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ Die ("MISSING_PACKETROOT: " + $PacketRoot) }
Write-Host ("PACKET: " + $PacketRoot) -ForegroundColor Cyan
Write-Host ("NAMESPACE: " + $SigNamespace) -ForegroundColor Cyan

# -----------------------------
# 1) sha256sums.txt verification
# -----------------------------
$shaPath = Join-Path $PacketRoot "sha256sums.txt"
if(-not (Test-Path -LiteralPath $shaPath -PathType Leaf)){ Die ("MISSING_SHA256SUMS: " + $shaPath) }
$lines = Get-Content -LiteralPath $shaPath -ErrorAction Stop
$arr = @(@($lines))
if(@(@($arr)).Count -lt 1){ Die "EMPTY_SHA256SUMS" }
$ok = 0
foreach($ln in @($arr)){
  $t = [string]$ln
  if([string]::IsNullOrWhiteSpace($t)){ continue }
  if($t.TrimStart().StartsWith("#")){ continue }
  $m = [regex]::Match($t, "^(?<hex>[0-9a-fA-F]{64})\s+(?<path>.+)$")
  if(-not $m.Success){ Die ("BAD_SHA256_LINE: " + $t) }
  $hex = $m.Groups["hex"].Value.ToLowerInvariant()
  $rel = $m.Groups["path"].Value
  $rel = $rel.Replace("/","\").Trim()
  $fp  = Join-Path $PacketRoot $rel
  if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){ Die ("MISSING_FILE: " + $fp) }
  $h = HexSha256File $fp
  if($h -ne $hex){ Die ("SHA_MISMATCH: " + $rel + " expected=" + $hex + " got=" + $h) }
  $ok++
}
Write-Host ("OK: sha256sums verified entries=" + $ok) -ForegroundColor Green

# -----------------------------
# 2) Covenant detached signature verification
# -----------------------------
$sigEnv  = Join-Path $PacketRoot "payload\sig_envelope.json"
$ingest  = Join-Path $PacketRoot "payload\nfl.ingest.json"
$sigPath = Join-Path $PacketRoot "signatures\ingest.sig"
$pubPath = Join-Path $PacketRoot "signer_ed25519.pub"
if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ Die ("MISSING_SIG: " + $sigPath) }
if(-not (Test-Path -LiteralPath $pubPath -PathType Leaf)){ Die ("MISSING_PUB: " + $pubPath) }
$targetPath = $null
if(Test-Path -LiteralPath $sigEnv -PathType Leaf){ $targetPath = $sigEnv }
elseif(Test-Path -LiteralPath $ingest -PathType Leaf){ $targetPath = $ingest }
else{ Die "NO_SIGNED_TARGET_FOUND (payload\sig_envelope.json or payload\nfl.ingest.json)" }

# principal from sig_envelope.json (required for Covenant)
$principal = $null
try {
  if(Test-Path -LiteralPath $sigEnv -PathType Leaf){
    $j = ReadUtf8 $sigEnv | ConvertFrom-Json -ErrorAction Stop
    if($j -ne $null -and ($j.principal -as [string])){ $principal = [string]$j.principal }
  }
} catch { $principal = $null }
if([string]::IsNullOrWhiteSpace($principal)){ Die "MISSING_PRINCIPAL_IN_SIG_ENVELOPE" }

Write-Host ("SIG: " + $sigPath) -ForegroundColor Cyan
Write-Host ("TARGET: " + $targetPath) -ForegroundColor Cyan
Write-Host ("PUB: " + $pubPath) -ForegroundColor Cyan
Write-Host ("PRINCIPAL: " + $principal) -ForegroundColor Cyan

# allowed_signers: use provided path or derive temp from signer_ed25519.pub
$asPath = $null
if($AllowedSigners -and (Test-Path -LiteralPath $AllowedSigners -PathType Leaf)){
  $asPath = (Resolve-Path -LiteralPath $AllowedSigners).Path
  Write-Host ("ALLOWED_SIGNERS: " + $asPath) -ForegroundColor DarkGray
} else {
  $tmp = Join-Path $env:TEMP ("covenant_allowed_signers_" + (Get-Date).ToString("yyyyMMdd_HHmmss"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $asPath = Join-Path $tmp "allowed_signers"
  $pubLine = (Get-Content -LiteralPath $pubPath -TotalCount 1 -ErrorAction Stop)
  if([string]::IsNullOrWhiteSpace($pubLine)){ Die "PUBKEY_EMPTY" }
  $line = ($principal + " " + $pubLine)
  $line = $line.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $line.EndsWith("`n")){ $line += "`n" }
  [System.IO.File]::WriteAllText($asPath,$line,(New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("ALLOWED_SIGNERS_TMP: " + $asPath) -ForegroundColor DarkGray
}

$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
$bytes = [System.IO.File]::ReadAllBytes($targetPath)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ssh
$psi.Arguments = ("-Y verify -f `"{0}`" -I `"{1}`" -n `"{2}`" -s `"{3}`"" -f $asPath,$principal,$SigNamespace,$sigPath)
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
$p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit()
if(-not [string]::IsNullOrWhiteSpace($out)){ Write-Host $out }
if(-not [string]::IsNullOrWhiteSpace($err)){ Write-Host $err -ForegroundColor DarkYellow }
if($p.ExitCode -ne 0){ Die ("SIG_VERIFY_FAIL exit=" + $p.ExitCode) }
Write-Host "SIG_VERIFY_OK" -ForegroundColor Green

Write-Host "VERIFY_OK" -ForegroundColor Green
