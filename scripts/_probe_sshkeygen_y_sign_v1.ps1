param(
  [Parameter()][int]$TimeoutSeconds = 8
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Run-ExeTimeout([string]$Exe,[string]$Args,[int]$TimeoutSec){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $Args
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { return [pscustomobject]@{ Ok=$false; ExitCode=999; Stdout=""; Stderr="START_FAIL"; Exe=$Exe; Args=$Args } }

  # close stdin immediately so it cannot prompt-block
  try { $p.StandardInput.Close() } catch { }

  $stdout = ""
  $stderr = ""
  try {
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
  } catch {
    # ignore read exceptions if process is killed
  }

  $ok = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    return [pscustomobject]@{ Ok=$false; ExitCode=998; Stdout=$stdout; Stderr=("TIMEOUT after " + $TimeoutSec + "s"); Exe=$Exe; Args=$Args }
  }

  return [pscustomobject]@{
    Ok       = ($p.ExitCode -eq 0)
    ExitCode = $p.ExitCode
    Stdout   = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Stderr   = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Exe      = $Exe
    Args     = $Args
  }
}

function Add-If([System.Collections.Generic.List[string]]$L,[string]$P){
  if ($P -and (Test-Path -LiteralPath $P -PathType Leaf)) { [void]$L.Add($P) }
}

# Candidate ssh-keygen.exe locations (common)
$c = New-Object System.Collections.Generic.List[string]
try {
  $w = & where.exe ssh-keygen 2>$null
  foreach($p in @(@($w))) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { [void]$c.Add($p) } }
} catch { }

Add-If $c "C:\Program Files\Git\usr\bin\ssh-keygen.exe"
Add-If $c "C:\Program Files\Git\bin\ssh-keygen.exe"
Add-If $c "C:\Program Files (x86)\Git\usr\bin\ssh-keygen.exe"
Add-If $c "C:\Program Files (x86)\Git\bin\ssh-keygen.exe"
Add-If $c "C:\Windows\System32\OpenSSH\ssh-keygen.exe"

# de-dup (preserve order)
$seen = @{}
$uniq = New-Object System.Collections.Generic.List[string]
foreach($p in @(@($c))){
  $k = $p.ToLowerInvariant()
  if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; [void]$uniq.Add($p) }
}

if ($uniq.Count -eq 0) { Die "No ssh-keygen.exe found" }

# Prepare temp key + payload
$tmp = Join-Path $env:TEMP ("nfl_ysign_probe_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$k = Join-Path $tmp "k"
$payload = Join-Path $tmp "payload.txt"
[System.IO.File]::WriteAllText($payload, "probe " + (Get-Date).ToUniversalTime().ToString("o"), (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("TMP: " + $tmp)

$winner = $null

try {
  foreach($ssh in @(@($uniq))){
    Write-Output ""
    Write-Output ("CANDIDATE: " + $ssh)

    # keygen: ed25519, empty passphrase.
    # NOTE: use cmd-style quoting inside a single Arguments string (safe here).
    $argsKey = '-q -t ed25519 -N "" -f "' + $k + '" -C "probe"'
    $r1 = Run-ExeTimeout -Exe $ssh -Args $argsKey -TimeoutSec $TimeoutSeconds
    Write-Output ("  KEYGEN: ok=" + $r1.Ok + " exit=" + $r1.ExitCode)
    if (-not $r1.Ok) { Write-Output ("  KEYGEN_STDERR: " + $r1.Stderr); continue }

    if (-not (Test-Path -LiteralPath $k -PathType Leaf)) { Write-Output "  KEYGEN_MISSING_PRIV"; continue }

    # -Y sign (this is what hangs on the built-in OpenSSH for you)
    $argsSign = '-Y sign -f "' + $k + '" -I "probe/principal" -n "probe/ns" "' + $payload + '"'
    $r2 = Run-ExeTimeout -Exe $ssh -Args $argsSign -TimeoutSec $TimeoutSeconds
    Write-Output ("  YSIGN: ok=" + $r2.Ok + " exit=" + $r2.ExitCode)
    if (-not $r2.Ok) { Write-Output ("  YSIGN_STDERR: " + $r2.Stderr); continue }

    $winner = $ssh
    break
  }

  if ([string]::IsNullOrWhiteSpace($winner)) {
    Die "NO_WORKING_SSH_KEYGEN: every candidate timed out or failed on -Y sign"
  }

  Write-Output ""
  Write-Output ("WINNER_SSH_KEYGEN: " + $winner)
  Write-Output "NEXT: use this path in NFL scripts instead of the System32 OpenSSH ssh-keygen.exe"
}
finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}
