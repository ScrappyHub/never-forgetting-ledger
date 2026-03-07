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

$Root    = (Resolve-Path -LiteralPath $RepoRoot).Path
$Scripts = Join-Path $Root "scripts"

$Lib  = Join-Path $Scripts "_lib_neverlost_v1.ps1"
$Sign = Join-Path $Scripts "sign_file_v1.ps1"
$Ver  = Join-Path $Scripts "verify_sig_v1.ps1"
$Dbg  = Join-Path $Scripts "debug_verify_find_principals_v1.ps1"

if (-not (Test-Path -LiteralPath $Lib -PathType Leaf)) { throw ("Missing required script: " + $Lib) }

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# -------------------------------------------------------------------
# Canonical ssh-keygen runner (NO stdio pipes; redirect to temp files)
# -------------------------------------------------------------------
$InvokeSshKeygenFunc = @"
function Invoke-SshKeygen([string[]]`$Argv,[int]`$TimeoutSeconds){
  if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  `$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  `$outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_out_" + [Guid]::NewGuid().ToString("N") + ".txt"))
  `$errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("sshkeygen_err_" + [Guid]::NewGuid().ToString("N") + ".txt"))
  try {
    # Build PS5.1-safe argument string with quoting
    `$quoted = New-Object System.Collections.Generic.List[string]
    foreach (`$a in @(@(`$Argv))) {
      if (`$null -eq `$a) { `$a = "" }
      if (`$a -match '[\s"]') { [void]`$quoted.Add('"' + (`$a -replace '"','\"') + '"') } else { [void]`$quoted.Add(`$a) }
    }
    `$argStr = (`$quoted.ToArray() -join " ")

    # Start-Process with file redirects prevents deadlocks on stdout/stderr
    `$p = Start-Process -FilePath `$ssh -ArgumentList `$argStr -NoNewWindow -PassThru -Wait `
      -RedirectStandardOutput `$outFile -RedirectStandardError `$errFile

    if (`$null -eq `$p) { throw "Failed to start ssh-keygen" }
    if (`$p.ExitCode -ne 0) {
      `$stdout = ""
      `$stderr = ""
      if (Test-Path -LiteralPath `$outFile -PathType Leaf) { `$stdout = (Get-Content -Raw -LiteralPath `$outFile -Encoding UTF8) }
      if (Test-Path -LiteralPath `$errFile -PathType Leaf) { `$stderr = (Get-Content -Raw -LiteralPath `$errFile -Encoding UTF8) }
      `$stdout = (`$stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
      `$stderr = (`$stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
      throw ("ssh-keygen failed (exit " + `$p.ExitCode + "): " + `$argStr + "`nSTDERR:`n" + `$stderr + "`nSTDOUT:`n" + `$stdout)
    }

    `$out = ""
    if (Test-Path -LiteralPath `$outFile -PathType Leaf) { `$out = (Get-Content -Raw -LiteralPath `$outFile -Encoding UTF8) }
    `$out = (`$out -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    return `$out
  } finally {
    Remove-Item -LiteralPath `$outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath `$errFile -Force -ErrorAction SilentlyContinue
  }
}
"@

# ----------------------------
# sign_file_v1.ps1 rewrite
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
  [Parameter()][int]`$TimeoutSeconds = 60
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

$InvokeSshKeygenFunc

`$Root = Get-RepoRoot
`$KeyPriv = Join-Path `$Root "proofs\keys\nfl-local_ed25519"
`$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath `$KeyPriv -PathType Leaf)) { throw ("Missing signing key: " + `$KeyPriv) }
if (-not (Test-Path -LiteralPath `$File -PathType Leaf))    { throw ("Missing file: " + `$File) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }

`$OutSig = `$File + ".sig"
if (Test-Path -LiteralPath `$OutSig -PathType Leaf) { Remove-Item -LiteralPath `$OutSig -Force }

Write-Host ("Signing file " + `$File)
[void](Invoke-SshKeygen -Argv @("-Y","sign","-f",`$KeyPriv,"-I",`$Principal,"-n",`$Namespace,"-s",`$OutSig,`$File) -TimeoutSeconds `$TimeoutSeconds)

if (-not (Test-Path -LiteralPath `$OutSig -PathType Leaf)) { throw ("Signature not created: " + `$OutSig) }
Write-Host ("OK: " + `$OutSig)
"@

Write-Utf8NoBom -Path $Sign -Text (($signBody.TrimEnd()) + "`r`n")
ParseGateFile $Sign
("WROTE: " + $Sign) | Out-Host

# ----------------------------
# verify_sig_v1.ps1 rewrite
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
  [Parameter()][int]`$TimeoutSeconds = 60,
  [Parameter()][switch]`$DebugFindPrincipals
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

$InvokeSshKeygenFunc

`$Root = Get-RepoRoot
`$Allowed   = Join-Path `$Root "proofs\trust\allowed_signers"
`$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }

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

Write-Utf8NoBom -Path $Ver -Text (($verifyBody.TrimEnd()) + "`r`n")
ParseGateFile $Ver
("WROTE: " + $Ver) | Out-Host

# ----------------------------
# debug_verify_find_principals_v1.ps1 rewrite
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
  [Parameter()][int]`$TimeoutSeconds = 60
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

$InvokeSshKeygenFunc

`$Root = Get-RepoRoot
`$Allowed = Join-Path `$Root "proofs\trust\allowed_signers"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }

Write-Host ("DEBUG: ssh-keygen=" + (Get-Command ssh-keygen.exe -ErrorAction Stop).Source)
Write-Host ("DEBUG: file sha256=" + (Get-FileHash -LiteralPath `$File -Algorithm SHA256).Hash.ToLowerInvariant())
Write-Host ("DEBUG: sig  sha256=" + (Get-FileHash -LiteralPath `$Sig  -Algorithm SHA256).Hash.ToLowerInvariant())

Write-Host "RUN: ssh-keygen -Y find-principals"
`$out = Invoke-SshKeygen -Argv @("-Y","find-principals","-f",`$Allowed,"-n",`$Namespace,"-s",`$Sig,`$File) -TimeoutSeconds `$TimeoutSeconds
if ([string]::IsNullOrWhiteSpace(`$out)) { throw "No principal matched." }
`$out | Out-Host
"OK: find-principals produced principal(s)" | Out-Host
"@

Write-Utf8NoBom -Path $Dbg -Text (($dbgBody.TrimEnd()) + "`r`n")
ParseGateFile $Dbg
("WROTE: " + $Dbg) | Out-Host

# ----------------------------
# Re-sign + verify
# ----------------------------
$Tb  = Join-Path $Root "proofs\trust\trust_bundle.json"
$Sig = $Tb + ".sig"

if (-not (Test-Path -LiteralPath $Tb -PathType Leaf)) { throw ("Missing: " + $Tb) }
if (Test-Path -LiteralPath $Sig -PathType Leaf) { Remove-Item -LiteralPath $Sig -Force }

& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Sign -File $Tb -Namespace "nfl/ingest-receipt" -TimeoutSeconds 60 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Dbg  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 60 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Ver  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 60 -DebugFindPrincipals | Out-Host

"OK: patch + resign + verify complete" | Out-Host
