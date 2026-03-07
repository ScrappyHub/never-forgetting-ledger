$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Get-RepoRoot {
  $p = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($p)) { throw "PSScriptRoot empty" }
  return (Split-Path -Parent $p)
}

function Get-OpenSshKeygenPath {
  $exe = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
  if (-not (Test-Path -LiteralPath $exe)) { throw ("Missing OpenSSH ssh-keygen: " + $exe) }
  return $exe
}

function Quote-Arg([string]$s) {
  if ($null -eq $s) { throw "Quote-Arg null" }
  # Minimal quoting for CreateProcess command-line parsing
  if ($s -match '[\s"]') {
    # escape embedded quotes by backslash-quote
    return '"' + ($s -replace '"','\"') + '"'
  }
  return $s
}

function Invoke-OpenSshKeygen {
  param(
    [Parameter(Mandatory=$true)][string[]]$Argv,
    [Parameter()][int]$TimeoutSeconds = 30
  )

  if ($null -eq $Argv -or $Argv.Count -eq 0) { throw "Invoke-OpenSshKeygen Argv null/empty." }
  if (@($Argv) | Where-Object { $null -eq $_ }) { throw "Invoke-OpenSshKeygen Argv contains null element." }
  if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

  $exe = Get-OpenSshKeygenPath

  # Deterministic single argument string
  $argLine = (@($Argv) | ForEach-Object { Quote-Arg $_ }) -join ' '

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  if (-not $p.Start()) { throw ("ssh-keygen failed to start: " + $exe) }

  # close stdin so ssh-keygen can never block on input
  try { $p.StandardInput.Close() } catch { }

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() } catch { }
    throw ("ssh-keygen timed out after " + $TimeoutSeconds + "s: " + $argLine)
  }

  # Read streams after exit (safe)
  $stdout = ""
  $stderr = ""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { }
  try { $stderr = $p.StandardError.ReadToEnd() } catch { }

  if ($p.ExitCode -ne 0) {
    $msg = ("ssh-keygen failed (exit " + $p.ExitCode + "): " + $argLine)
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $msg += "
STDERR:
" + $stderr.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $msg += "
STDOUT:
" + $stdout.TrimEnd() }
    throw $msg
  }

  # Return combined output (trimmed) if caller wants it
  return (($stdout + "
" + $stderr).Trim())
}
