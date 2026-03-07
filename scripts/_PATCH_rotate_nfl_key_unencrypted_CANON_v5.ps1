param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function ReadTextUtf8([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
  return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8)
}

function Invoke-SshKeygenFiles([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_out_" + [Guid]::NewGuid().ToString("N") + ".txt"))
  $errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_err_" + [Guid]::NewGuid().ToString("N") + ".txt"))

  try {
    # PS5.1: Start-Process -ArgumentList rejects empty-string elements.
    # Therefore Argv MUST contain no "" elements. (Use attached forms like -N"" when needed.)
    foreach($a in @(@($Argv))){
      if ($null -eq $a) { Die "ARGV_INVALID: null element" }
      if ($a -eq "")    { Die "ARGV_INVALID: empty-string element (PS5.1 Start-Process cannot accept this)" }
    }

    $p = Start-Process -FilePath $ssh -ArgumentList $Argv -NoNewWindow -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    if ($null -eq $p) { Die "Failed to start ssh-keygen" }

    $ok = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $ok) {
      try { $p.Kill() | Out-Null } catch { }
      $so = (ReadTextUtf8 $outFile -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
      $se = (ReadTextUtf8 $errFile -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
      Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGV: " + ($Argv -join " ") + "`nSTDERR:`n" + $se + "`nSTDOUT:`n" + $so)
    }

    $stdout = (ReadTextUtf8 $outFile -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $stderr = (ReadTextUtf8 $errFile -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

    if ($p.ExitCode -ne 0) {
      Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGV: " + ($Argv -join " ") + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout)
    }

    return [pscustomobject]@{
      Exe      = $ssh
      ExitCode = $p.ExitCode
      Stdout   = $stdout
      Stderr   = $stderr
    }
  } finally {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeysDir = Join-Path $Root "proofs\keys"
if (-not (Test-Path -LiteralPath $KeysDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $KeysDir | Out-Null }

$Priv = Join-Path $KeysDir "nfl-local_ed25519"
$Pub  = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Output ("REPO: " + $Root)

# Backup existing key material (if present)
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $bak = $p + ".bak_" + $stamp
    Copy-Item -LiteralPath $p -Destination $bak -Force | Out-Null
    Write-Output ("BACKUP_KEY: " + $bak)
  }
}

# Hard delete to avoid overwrite prompt
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Remove-Item -LiteralPath $p -Force
    Write-Output ("REMOVED: " + $p)
  }
}

# Generate new UNENCRYPTED key
# IMPORTANT: use attached form -N"" to avoid empty argv element in PS5.1
Write-Output 'RUN: ssh-keygen -t ed25519 -N"" -f proofs\keys\nfl-local_ed25519'
[void](Invoke-SshKeygenFiles -Argv @("-t","ed25519","-N""","-f",$Priv,"-C","nfl-local") -TimeoutSeconds 60)

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

# Prove non-interactive access (must NOT hang)
Write-Output "RUN: ssh-keygen -y -f <priv> (prove non-interactive)"
$resY = Invoke-SshKeygenFiles -Argv @("-y","-f",$Priv) -TimeoutSeconds 10
$derived = $resY.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + ((Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()))
Write-Output "OK: rotated NFL signing key to UNENCRYPTED repo-managed key"
