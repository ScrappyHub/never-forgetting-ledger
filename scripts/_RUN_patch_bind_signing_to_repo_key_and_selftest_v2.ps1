param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}
function Parse-GateFile([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die ("Parse-Gate missing file: " + $Path) }
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { Die ("Parse-Gate error: " + $errs[0].Message + " (file: " + $Path + ")") }
}

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $root "scripts"
if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) { Die ("scripts dir not found: " + $ScriptsDir) }

$Patch = Join-Path $ScriptsDir "_PATCH_bind_signing_to_repo_key_and_selftest_v2.ps1"

$patchText = @'
param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}
function Parse-GateFile([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die ("Parse-Gate missing file: " + $Path) }
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { Die ("Parse-Gate error: " + $errs[0].Message + " (file: " + $Path + ")") }
}

function Patch-FileRegexOptional([string]$Path,[string]$Label,[string]$Pattern,[string]$Replacement){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Output ("SKIP: missing " + $Label + " file: " + $Path); return $false }
  $orig = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
  $new  = [regex]::Replace($orig,$Pattern,$Replacement,[System.Text.RegularExpressions.RegexOptions]::Multiline)
  if ($new -eq $orig) { Write-Output ("SKIP: nochange (" + $Label + "): " + $Path); return $false }
  Write-Utf8NoBomLf -Path $Path -Text $new
  Parse-GateFile $Path
  Write-Output ("PATCHED: " + $Path + " [" + $Label + "]")
  return $true
}

function Quote-Arg([string]$x){
  if ($null -eq $x) { return '""' }
  if ($x -eq "")    { return '""' }
  if ($x -match '[\s"]') { return '"' + ($x -replace '"','\"') + '"' }
  return $x
}

function Invoke-OpenSshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $parts = New-Object System.Collections.Generic.List[string]
  foreach($a in @(@($Argv))){ [void]$parts.Add((Quote-Arg $a)) }
  $argStr = ($parts.ToArray() -join " ")

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  try { $p.StandardInput.Close() } catch { }

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) { try { $p.Kill() | Out-Null } catch { } ; Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr) }

  $stdout=""; $stderr=""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { $stdout = "" }
  try { $stderr = $p.StandardError.ReadToEnd()  } catch { $stderr = "" }

  $stdout = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  if ($p.ExitCode -ne 0) {
    Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout)
  }

  return [pscustomobject]@{ Exe=$ssh; Args=$argStr; ExitCode=$p.ExitCode; Stdout=$stdout; Stderr=$stderr }
}

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $root "scripts"
if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) { Die ("scripts dir not found: " + $ScriptsDir) }

$KeyPriv = Join-Path $root "proofs\keys\nfl-local_ed25519"
$KeyPub  = $KeyPriv + ".pub"
if (-not (Test-Path -LiteralPath $KeyPriv -PathType Leaf)) { Die ("MISSING_PRIVKEY: " + $KeyPriv) }
if (-not (Test-Path -LiteralPath $KeyPub  -PathType Leaf)) { Die ("MISSING_PUBKEY : " + $KeyPub) }

$TrustDir = Join-Path $root "proofs\trust"
$TrustBundle = Join-Path $TrustDir "trust_bundle.json"
$AllowedSigners = Join-Path $TrustDir "allowed_signers"
if (-not (Test-Path -LiteralPath $TrustBundle -PathType Leaf)) { Die ("MISSING_TRUST_BUNDLE: " + $TrustBundle) }

Write-Output ("REPO: " + $root)
Write-Output ("KEY : " + $KeyPriv)

# 1) Patch installer drift (non-fatal if already patched)
$Installer = Join-Path $ScriptsDir "_install_neverlost_v1_nfl.ps1"
[void](Patch-FileRegexOptional -Path $Installer -Label "installer_keyname_script_scope" `
  -Pattern '\(\s*\$script:AuthorityName\s*\+\s*"_ed25519"\s*\)' -Replacement '"nfl-local_ed25519"')
[void](Patch-FileRegexOptional -Path $Installer -Label "installer_keyname_nonscript_scope" `
  -Pattern '\(\s*\$AuthorityName\s*\+\s*"_ed25519"\s*\)' -Replacement '"nfl-local_ed25519"')

# 2) Rewrite sign_file_v1.ps1 (hard bind to repo key)
$Sign = Join-Path $ScriptsDir "sign_file_v1.ps1"
$signBody = @'
param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$OutSig,
  [Parameter(Mandatory=$false)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Quote-Arg([string]$x){
  if ($null -eq $x) { return '""' }
  if ($x -eq "")    { return '""' }
  if ($x -match '[\s"]') { return '"' + ($x -replace '"','\"') + '"' }
  return $x
}
function Invoke-OpenSshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
  $parts = New-Object System.Collections.Generic.List[string]
  foreach($a in @(@($Argv))){ [void]$parts.Add((Quote-Arg $a)) }
  $argStr = ($parts.ToArray() -join " ")
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  try { $p.StandardInput.Close() } catch { }
  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) { try { $p.Kill() | Out-Null } catch { } ; Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr) }
  $stdout=""; $stderr=""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { $stdout = "" }
  try { $stderr = $p.StandardError.ReadToEnd()  } catch { $stderr = "" }
  $stdout = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  if ($p.ExitCode -ne 0) { Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout) }
  return $true
}

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeyPriv = Join-Path $root "proofs\keys\nfl-local_ed25519"
$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath $KeyPriv -PathType Leaf)) { Die ("Missing signing key: " + $KeyPriv) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { Die "Namespace empty" }
if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Die ("Missing file: " + $File) }

$OutDir = Split-Path -Parent $OutSig
if ($OutDir -and -not (Test-Path -LiteralPath $OutDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if (Test-Path -LiteralPath $OutSig -PathType Leaf) { Remove-Item -LiteralPath $OutSig -Force }

Write-Output ("RUN: ssh-keygen -Y sign (I=" + $Principal + " n=" + $Namespace + ")")
[void](Invoke-OpenSshKeygenPSI -Argv @("-Y","sign","-f",$KeyPriv,"-I",$Principal,"-n",$Namespace,"-s",$OutSig,$File) -TimeoutSeconds $TimeoutSeconds)

if (-not (Test-Path -LiteralPath $OutSig -PathType Leaf)) { Die ("Signature not created: " + $OutSig) }
Write-Output ("OK: SIGNED " + $OutSig)