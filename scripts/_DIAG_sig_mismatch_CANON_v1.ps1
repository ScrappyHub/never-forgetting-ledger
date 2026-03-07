param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter()][string]$Namespace = "nfl/ingest-receipt",
  [Parameter()][int]$TimeoutSeconds = 60
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Sha256Hex([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die ("Missing file for hash: " + $Path) }
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Invoke-SshKeygenResult([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($a in @(@($Argv))) {
    $x = $a
    if ($null -eq $x) { $x = "" }
    if ($x -match '[\s"]') { [void]$quoted.Add('"' + ($x -replace '"','\"') + '"') } else { [void]$quoted.Add($x) }
  }
  $argStr = ($quoted.ToArray() -join " ")

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  $sbOut = New-Object System.Text.StringBuilder
  $sbErr = New-Object System.Text.StringBuilder

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender,$e)
    if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) }
  }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender,$e)
    if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) }
  }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s: " + $argStr)
  }
  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{
    Exe      = $ssh
    Args     = $argStr
    ExitCode = $p.ExitCode
    Stdout   = $stdout
    Stderr   = $stderr
  }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

$File    = Join-Path $Root "proofs\trust\trust_bundle.json"
$Sig     = $File + ".sig"
$Allowed = Join-Path $Root "proofs\trust\allowed_signers"

# private/public keys (we will derive pub from priv)
$Priv = Join-Path $Root "proofs\keys\nfl-local_ed25519"
$Pub1 = $Priv + ".pub"
$Pub2 = Join-Path $Root "proofs\keys\nfl-local_ed25519.pub"

Write-Output ("REPO: " + $Root)
Write-Output ("NAMESPACE: " + $Namespace)

foreach($p in @($File,$Sig,$Allowed,$Priv)){
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("MISSING: " + $p) }
}

Write-Output ("FILE_SHA256: " + (Sha256Hex $File))
Write-Output ("SIG_SHA256:  " + (Sha256Hex $Sig))
Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $Allowed))

# 1) Derive public key from private key
Write-Output "RUN: ssh-keygen -y -f <priv>  (derive pub from priv)"
$pubRes = Invoke-SshKeygenResult -Argv @("-y","-f",$Priv) -TimeoutSeconds $TimeoutSeconds
if ($pubRes.ExitCode -ne 0) {
  Die ("DERIVE_PUB_FAIL: " + $pubRes.Args + "`nSTDERR:`n" + $pubRes.Stderr + "`nSTDOUT:`n" + $pubRes.Stdout)
}
$derivedPub = $pubRes.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derivedPub)) { Die "DERIVE_PUB_EMPTY" }
Write-Output ("DERIVED_PUB: " + $derivedPub)

# Compare derived pub to any existing pub file
$pubPath = $null
if (Test-Path -LiteralPath $Pub1 -PathType Leaf) { $pubPath = $Pub1 }
elseif (Test-Path -LiteralPath $Pub2 -PathType Leaf) { $pubPath = $Pub2 }

if ($pubPath) {
  $pubFileLine = (Get-Content -Raw -LiteralPath $pubPath -Encoding UTF8).Trim()
  Write-Output ("PUBFILE_PATH: " + $pubPath)
  Write-Output ("PUBFILE_LINE: " + $pubFileLine)
  if ($pubFileLine -eq $derivedPub) {
    Write-Output "PUB_MATCH: derived pub == pub file"
  } else {
    Write-Output "PUB_MISMATCH: derived pub != pub file"
  }
} else {
  Write-Output "PUBFILE_NOTE: no .pub file found at expected locations"
}

# Extract the base64 key blob for searching allowed_signers
# expected format: "ssh-ed25519 AAAA... comment"
$parts = @(@($derivedPub -split '\s+'))
if ($parts.Count -lt 2) { Die ("DERIVED_PUB_UNEXPECTED_FORMAT: " + $derivedPub) }
$keyBlob = $parts[1]

# 2) Check whether allowed_signers contains this key blob
$allowedText = (Get-Content -Raw -LiteralPath $Allowed -Encoding UTF8)
if ($allowedText -match [regex]::Escape($keyBlob)) {
  Write-Output "ALLOWED_CONTAINS_KEY: YES (derived pub key blob is present)"
} else {
  Write-Output "ALLOWED_CONTAINS_KEY: NO (allowed_signers does NOT contain derived pub key blob)"
}

# 3) find-principals
Write-Output "RUN: ssh-keygen -Y find-principals ..."
$fp = Invoke-SshKeygenResult -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds
Write-Output ("FIND_PRINCIPALS_EXIT: " + $fp.ExitCode)
if (-not [string]::IsNullOrWhiteSpace($fp.Stdout)) {
  Write-Output "FIND_PRINCIPALS_STDOUT:"
  Write-Output $fp.Stdout
} else {
  Write-Output "FIND_PRINCIPALS_STDOUT: <empty>"
}
if (-not [string]::IsNullOrWhiteSpace($fp.Stderr)) {
  Write-Output "FIND_PRINCIPALS_STDERR:"
  Write-Output $fp.Stderr
}

# 4) Attempt verify for each principal that find-principals returned
$principals = @()
if (-not [string]::IsNullOrWhiteSpace($fp.Stdout)) {
  $lines = @(@(($fp.Stdout -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }))
  foreach($ln in $lines){
    if ($ln -notmatch '\s') { $principals += $ln }
  }
}
$principals = @(@($principals))

if ($principals.Count -eq 0) {
  Write-Output "VERIFY_NOTE: find-principals returned no principals. (Either key not trusted, namespace mismatch, or signature not valid)"
} else {
  Write-Output ("VERIFY_NOTE: trying verify with " + $principals.Count + " principal(s) returned by find-principals")
}

$rev = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("neverlost_rev_" + [Guid]::NewGuid().ToString("N") + ".txt"))
try {
  [System.IO.File]::WriteAllText($rev, "", (New-Object System.Text.UTF8Encoding($false)))

  foreach($pr in $principals){
    Write-Output ("RUN: ssh-keygen -Y verify  (-I " + $pr + ")")
    $vr = Invoke-SshKeygenResult -Argv @("-Y","verify","-f",$Allowed,"-I",$pr,"-n",$Namespace,"-s",$Sig,"-r",$rev,$File) -TimeoutSeconds $TimeoutSeconds
    Write-Output ("VERIFY_EXIT(" + $pr + "): " + $vr.ExitCode)
    if ($vr.ExitCode -eq 0) {
      Write-Output ("VERIFY_OK(" + $pr + "): signature valid under this principal")
    } else {
      if (-not [string]::IsNullOrWhiteSpace($vr.Stderr)) {
        Write-Output ("VERIFY_STDERR(" + $pr + "):")
        Write-Output $vr.Stderr
      }
      if (-not [string]::IsNullOrWhiteSpace($vr.Stdout)) {
        Write-Output ("VERIFY_STDOUT(" + $pr + "):")
        Write-Output $vr.Stdout
      }
    }
  }
} finally {
  Remove-Item -LiteralPath $rev -Force -ErrorAction SilentlyContinue
}

Write-Output "DIAG_DONE"
