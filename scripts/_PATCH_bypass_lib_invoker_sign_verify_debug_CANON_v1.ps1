param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source

function Write-Utf8NoBom([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}
function ParseGateFile([string]$Path){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { throw ("PARSE ERROR: " + $errs[0].Message + " (file: " + $Path + ")") }
}
function Sha256Hex([string]$Path){
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Invoke-SshKeygen([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $tmpOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_out_" + [Guid]::NewGuid().ToString("N") + ".txt"))
  $tmpErr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_err_" + [Guid]::NewGuid().ToString("N") + ".txt"))
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ssh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    # PS5.1-safe argv join w/ quoting
    $quoted = New-Object System.Collections.Generic.List[string]
    foreach ($a in @(@($Argv))) {
      if ($null -eq $a) { $a = "" }
      if ($a -match '[\s"]') {
        $quoted.Add('"' + ($a -replace '"','\"') + '"') | Out-Null
      } else {
        $quoted.Add($a) | Out-Null
      }
    }
    $psi.Arguments = ($quoted.ToArray() -join " ")

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    if (-not $p.Start()) { throw "Failed to start ssh-keygen" }

    $waitOk = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $waitOk) {
      try { $p.Kill() | Out-Null } catch { }
      throw ("ssh-keygen timeout after " + $TimeoutSeconds + "s")
    }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    # Normalize to display deterministically
    $stdout = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $stderr = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

    if ($p.ExitCode -ne 0) {
      $msg = "ssh-keygen failed (exit " + $p.ExitCode + "): " + ($psi.Arguments) + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout
      throw $msg
    }

    return $stdout
  } finally {
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
  }
}

$Root    = (Resolve-Path -LiteralPath $RepoRoot).Path
$Scripts = Join-Path $Root "scripts"

$Lib  = Join-Path $Scripts "_lib_neverlost_v1.ps1"
$Sign = Join-Path $Scripts "sign_file_v1.ps1"
$Ver  = Join-Path $Scripts "verify_sig_v1.ps1"
$Dbg  = Join-Path $Scripts "debug_verify_find_principals_v1.ps1"

if (-not (Test-Path -LiteralPath $Lib -PathType Leaf)) { throw ("Missing required script: " + $Lib) }

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# ----------------------------
# sign_file_v1.ps1 (direct ssh-keygen)
# ----------------------------
if (Test-Path -LiteralPath $Sign -PathType Leaf) {
  $bak = $Sign + ".bak_" + $stamp
  Copy-Item -LiteralPath $Sign -Destination $bak -Force | Out-Null
  ("BACKUP_SIGN: " + $bak) | Out-Host
}

$signBody = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Namespace,
  [Parameter()][int]`$TimeoutSeconds = 30
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

function Invoke-SshKeygen([string[]]`$Argv,[int]`$TimeoutSeconds){
  if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  `$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  `$psi = New-Object System.Diagnostics.ProcessStartInfo
  `$psi.FileName = `$ssh
  `$psi.UseShellExecute = `$false
  `$psi.RedirectStandardOutput = `$true
  `$psi.RedirectStandardError  = `$true
  `$psi.CreateNoWindow = `$true

  `$quoted = New-Object System.Collections.Generic.List[string]
  foreach (`$a in @(@(`$Argv))) {
    if (`$null -eq `$a) { `$a = "" }
    if (`$a -match '[\s"]') { [void]`$quoted.Add('"' + (`$a -replace '"','\"') + '"') } else { [void]`$quoted.Add(`$a) }
  }
  `$psi.Arguments = (`$quoted.ToArray() -join " ")

  `$p = New-Object System.Diagnostics.Process
  `$p.StartInfo = `$psi
  if (-not `$p.Start()) { throw "Failed to start ssh-keygen" }

  `$waitOk = `$p.WaitForExit(`$TimeoutSeconds * 1000)
  if (-not `$waitOk) { try { `$p.Kill() | Out-Null } catch { } ; throw ("ssh-keygen timeout after " + `$TimeoutSeconds + "s") }

  `$stdout = (`$p.StandardOutput.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  `$stderr = (`$p.StandardError.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  if (`$p.ExitCode -ne 0) { throw ("ssh-keygen failed (exit " + `$p.ExitCode + "): " + `$psi.Arguments + "`nSTDERR:`n" + `$stderr + "`nSTDOUT:`n" + `$stdout) }
  return `$stdout
}

`$Root = Get-RepoRoot
`$KeyPriv = Join-Path `$Root "proofs\keys\nfl-local_ed25519"
`$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath `$KeyPriv -PathType Leaf)) { throw ("Missing signing key: " + `$KeyPriv) }
if (-not (Test-Path -LiteralPath `$File -PathType Leaf))    { throw ("Missing file: " + `$File) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }
if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

`$OutSig = `$File + ".sig"
if (Test-Path -LiteralPath `$OutSig -PathType Leaf) { Remove-Item -LiteralPath `$OutSig -Force }

Write-Host ("Signing file " + `$File)
[void](Invoke-SshKeygen -Argv @("-Y","sign","-f",`$KeyPriv,"-I",`$Principal,"-n",`$Namespace,"-s",`$OutSig,`$File) -TimeoutSeconds `$TimeoutSeconds)

if (-not (Test-Path -LiteralPath `$OutSig -PathType Leaf)) { throw ("Signature not created: " + `$OutSig) }
Write-Host ("OK: " + `$OutSig)
"@

[System.IO.File]::WriteAllText($Sign, (($signBody.TrimEnd()) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
ParseGateFile $Sign
("WROTE: " + $Sign) | Out-Host

# ----------------------------
# verify_sig_v1.ps1 (direct ssh-keygen)
# ----------------------------
if (Test-Path -LiteralPath $Ver -PathType Leaf) {
  $bak = $Ver + ".bak_" + $stamp
  Copy-Item -LiteralPath $Ver -Destination $bak -Force | Out-Null
  ("BACKUP_VERIFY: " + $bak) | Out-Host
}

$verifyBody = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Sig,
  [Parameter(Mandatory=`$true)][string]`$Namespace,
  [Parameter()][int]`$TimeoutSeconds = 30,
  [Parameter()][switch]`$DebugFindPrincipals
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

function Invoke-SshKeygen([string[]]`$Argv,[int]`$TimeoutSeconds){
  if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  `$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  `$psi = New-Object System.Diagnostics.ProcessStartInfo
  `$psi.FileName = `$ssh
  `$psi.UseShellExecute = `$false
  `$psi.RedirectStandardOutput = `$true
  `$psi.RedirectStandardError  = `$true
  `$psi.CreateNoWindow = `$true

  `$quoted = New-Object System.Collections.Generic.List[string]
  foreach (`$a in @(@(`$Argv))) {
    if (`$null -eq `$a) { `$a = "" }
    if (`$a -match '[\s"]') { [void]`$quoted.Add('"' + (`$a -replace '"','\"') + '"') } else { [void]`$quoted.Add(`$a) }
  }
  `$psi.Arguments = (`$quoted.ToArray() -join " ")

  `$p = New-Object System.Diagnostics.Process
  `$p.StartInfo = `$psi
  if (-not `$p.Start()) { throw "Failed to start ssh-keygen" }

  `$waitOk = `$p.WaitForExit(`$TimeoutSeconds * 1000)
  if (-not `$waitOk) { try { `$p.Kill() | Out-Null } catch { } ; throw ("ssh-keygen timeout after " + `$TimeoutSeconds + "s") }

  `$stdout = (`$p.StandardOutput.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  `$stderr = (`$p.StandardError.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  if (`$p.ExitCode -ne 0) { throw ("ssh-keygen failed (exit " + `$p.ExitCode + "): " + `$psi.Arguments + "`nSTDERR:`n" + `$stderr + "`nSTDOUT:`n" + `$stdout) }
  return `$stdout
}

`$Root = Get-RepoRoot
`$Allowed   = Join-Path `$Root "proofs\trust\allowed_signers"
`$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }
if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

if (`$DebugFindPrincipals) {
  Write-Host ("DEBUG: ssh-keygen=" + (Get-Command ssh-keygen.exe -ErrorAction Stop).Source)
  Write-Host ("DEBUG: file sha256=" + (Get-FileHash -LiteralPath `$File -Algorithm SHA256).Hash.ToLowerInvariant())
  Write-Host ("DEBUG: sig  sha256=" + (Get-FileHash -LiteralPath `$Sig  -Algorithm SHA256).Hash.ToLowerInvariant())
  Write-Host "DEBUG: ssh-keygen -Y find-principals"
  `$out = Invoke-SshKeygen -Argv @("-Y","find-principals","-f",`$Allowed,"-n",`$Namespace,"-s",`$Sig,`$File) -TimeoutSeconds `$TimeoutSeconds
  if (-not [string]::IsNullOrWhiteSpace(`$out)) { `$out | Out-Host }
}

`$rev = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("neverlost_rev_" + [Guid]::NewGuid().ToString("N") + ".txt"))
try {
  [System.IO.File]::WriteAllText(`$rev, "", (New-Object System.Text.UTF8Encoding(`$false)))
  [void](Invoke-SshKeygen -Argv @("-Y","verify","-f",`$Allowed,"-I",`$Principal,"-n",`$Namespace,"-s",`$Sig,"-r",`$rev,`$File) -TimeoutSeconds `$TimeoutSeconds)
  "OK: verified" | Out-Host
} finally {
  Remove-Item -LiteralPath `$rev -Force -ErrorAction SilentlyContinue
}
"@

[System.IO.File]::WriteAllText($Ver, (($verifyBody.TrimEnd()) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
ParseGateFile $Ver
("WROTE: " + $Ver) | Out-Host

# ----------------------------
# debug_verify_find_principals_v1.ps1 (direct ssh-keygen)
# ----------------------------
if (Test-Path -LiteralPath $Dbg -PathType Leaf) {
  $bak2 = $Dbg + ".bak_" + $stamp
  Copy-Item -LiteralPath $Dbg -Destination $bak2 -Force | Out-Null
  ("BACKUP_DEBUG: " + $bak2) | Out-Host
}

$dbgBody = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Sig,
  [Parameter(Mandatory=`$true)][string]`$Namespace,
  [Parameter()][int]`$TimeoutSeconds = 30
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

function Invoke-SshKeygen([string[]]`$Argv,[int]`$TimeoutSeconds){
  if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  `$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  `$psi = New-Object System.Diagnostics.ProcessStartInfo
  `$psi.FileName = `$ssh
  `$psi.UseShellExecute = `$false
  `$psi.RedirectStandardOutput = `$true
  `$psi.RedirectStandardError  = `$true
  `$psi.CreateNoWindow = `$true

  `$quoted = New-Object System.Collections.Generic.List[string]
  foreach (`$a in @(@(`$Argv))) {
    if (`$null -eq `$a) { `$a = "" }
    if (`$a -match '[\s"]') { [void]`$quoted.Add('"' + (`$a -replace '"','\"') + '"') } else { [void]`$quoted.Add(`$a) }
  }
  `$psi.Arguments = (`$quoted.ToArray() -join " ")

  `$p = New-Object System.Diagnostics.Process
  `$p.StartInfo = `$psi
  if (-not `$p.Start()) { throw "Failed to start ssh-keygen" }

  `$waitOk = `$p.WaitForExit(`$TimeoutSeconds * 1000)
  if (-not `$waitOk) { try { `$p.Kill() | Out-Null } catch { } ; throw ("ssh-keygen timeout after " + `$TimeoutSeconds + "s") }

  `$stdout = (`$p.StandardOutput.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  `$stderr = (`$p.StandardError.ReadToEnd() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  if (`$p.ExitCode -ne 0) { throw ("ssh-keygen failed (exit " + `$p.ExitCode + "): " + `$psi.Arguments + "`nSTDERR:`n" + `$stderr + "`nSTDOUT:`n" + `$stdout) }
  return `$stdout
}

`$Root = Get-RepoRoot
`$Allowed = Join-Path `$Root "proofs\trust\allowed_signers"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }
if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

Write-Host ("DEBUG: ssh-keygen=" + (Get-Command ssh-keygen.exe -ErrorAction Stop).Source)
Write-Host ("DEBUG: file sha256=" + (Get-FileHash -LiteralPath `$File -Algorithm SHA256).Hash.ToLowerInvariant())
Write-Host ("DEBUG: sig  sha256=" + (Get-FileHash -LiteralPath `$Sig  -Algorithm SHA256).Hash.ToLowerInvariant())

Write-Host "RUN: ssh-keygen -Y find-principals"
`$out = Invoke-SshKeygen -Argv @("-Y","find-principals","-f",`$Allowed,"-n",`$Namespace,"-s",`$Sig,`$File) -TimeoutSeconds `$TimeoutSeconds
if ([string]::IsNullOrWhiteSpace(`$out)) { throw "No principal matched." }
`$out | Out-Host
"OK: find-principals produced principal(s)" | Out-Host
"@

[System.IO.File]::WriteAllText($Dbg, (($dbgBody.TrimEnd()) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
ParseGateFile $Dbg
("WROTE: " + $Dbg) | Out-Host

# ----------------------------
# Re-sign + verify (deterministic)
# ----------------------------
$Tb  = Join-Path $Root "proofs\trust\trust_bundle.json"
$Sig = $Tb + ".sig"

if (-not (Test-Path -LiteralPath $Tb -PathType Leaf)) { throw ("Missing: " + $Tb) }
if (Test-Path -LiteralPath $Sig -PathType Leaf) { Remove-Item -LiteralPath $Sig -Force }

& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Sign -File $Tb -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Dbg  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Ver  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 -DebugFindPrincipals | Out-Host

"OK: patch + resign + verify complete" | Out-Host
