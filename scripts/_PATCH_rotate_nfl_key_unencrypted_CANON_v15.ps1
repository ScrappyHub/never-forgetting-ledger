param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter()][string]$TestPrincipal = "single-tenant/local/authority/nfl",
  [Parameter()][string]$TestNamespace = "nfl/ingest-receipt"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Sha256Hex([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die ("Missing for sha256: " + $Path) }
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Write-Utf8NoBomFile([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  [System.IO.File]::WriteAllText($Path, $norm, $enc)
}

function Invoke-CmdSync([string]$CmdLine,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command cmd.exe -ErrorAction Stop).Source
  $psi.Arguments = "/d /s /c " + $CmdLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start cmd.exe" }

  try { $p.StandardInput.Close() } catch { }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    $so = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $se = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Die ("cmd timeout after " + $TimeoutSeconds + "s`nCMD: " + $CmdLine + "`nSTDERR:`n" + $se + "`nSTDOUT:`n" + $so)
  }

  $so2 = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $se2 = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{ ExitCode=$p.ExitCode; Stdout=$so2; Stderr=$se2; Cmd=$CmdLine }
}

function WinPath-ToWslLoose([string]$Path){
  if ([string]::IsNullOrWhiteSpace($Path)) { Die "WinPath-ToWslLoose: empty path" }
  $p = [System.IO.Path]::GetFullPath($Path)
  if ($p.Length -lt 3 -or $p[1] -ne ":" -or $p[2] -ne "\") { Die ("WinPath-ToWslLoose: not a drive path: " + $p) }
  $drive = $p.Substring(0,1).ToLowerInvariant()
  $rest  = $p.Substring(2) -replace "\\","/"
  return ("/mnt/" + $drive + $rest)
}

function Invoke-WslSync([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $wsl
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add("-e")
  foreach($a in @(@($Argv))){
    if ($null -eq $a) { Die "Invoke-WslSync: null argv element" }
    $s = [string]$a
    if ($s -match '[\s"]') { $s = '"' + ($s -replace '"','\"') + '"' }
    [void]$parts.Add($s)
  }
  $psi.Arguments = ($parts.ToArray() -join " ")

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start wsl.exe" }

  try { $p.StandardInput.Close() } catch { }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    $so = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $se = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Die ("wsl timeout after " + $TimeoutSeconds + "s`nARGV: " + ($Argv -join " ") + "`nSTDERR:`n" + $se + "`nSTDOUT:`n" + $so)
  }

  $so2 = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $se2 = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{ ExitCode=$p.ExitCode; Stdout=$so2; Stderr=$se2; Args=($Argv -join " ") }
}

# ----------------------------
# 1) Rotate key (Windows keygen)
# ----------------------------
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeysDir = Join-Path $Root "proofs\keys"
if (-not (Test-Path -LiteralPath $KeysDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $KeysDir | Out-Null }

$Priv  = Join-Path $KeysDir "nfl-local_ed25519"
$Pub   = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Output ("REPO: " + $Root)

foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $bak = $p + ".bak_" + $stamp
    Copy-Item -LiteralPath $p -Destination $bak -Force | Out-Null
    Write-Output ("BACKUP_KEY: " + $bak)
  }
}
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Remove-Item -LiteralPath $p -Force
    Write-Output ("REMOVED: " + $p)
  }
}

$sshWin = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
$cmdKeygen = 'echo.| ""' + $sshWin + '"" -q -t ed25519 -N """" -f ""' + $Priv + '"" -C ""nfl-local""'
Write-Output ("RUN: " + $cmdKeygen)

$r = Invoke-CmdSync -CmdLine $cmdKeygen -TimeoutSeconds 30
Write-Output ("KEYGEN_EXIT: " + $r.ExitCode)
if ($r.ExitCode -ne 0) { Die ("KEYGEN_FAIL (exit " + $r.ExitCode + ")`nCMD: " + $r.Cmd + "`nSTDERR:`n" + $r.Stderr + "`nSTDOUT:`n" + $r.Stdout) }

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

Write-Output ("PRIV_SHA256: " + (Sha256Hex $Priv))
Write-Output ("PUB_SHA256:  " + (Sha256Hex $Pub))

$pubLine = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($pubLine)) { Die "PUBFILE_EMPTY" }
Write-Output ("PUBFILE_LINE: " + $pubLine)

# ----------------------------
# 2) Self-test: sign+verify in WSL (key copied into ext4 with 0600)
# ----------------------------
try { [void](Get-Command wsl.exe -ErrorAction Stop) } catch { Die "WSL_MISSING: wsl.exe not found" }

$tmpWin = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("nfl_keytest_" + [Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Force -Path $tmpWin | Out-Null

$payloadWin = Join-Path $tmpWin "payload.txt"
$sigWin     = Join-Path $tmpWin "payload.txt.sig"
$allowedWin = Join-Path $tmpWin "allowed_signers"
$revWin     = Join-Path $tmpWin "revoked_keys"

try {
  Write-Utf8NoBomFile -Path $payloadWin -Text ("nfl key rotation self-test`n" + (Get-Date).ToUniversalTime().ToString("o"))
  Write-Utf8NoBomFile -Path $revWin -Text ""
  Write-Utf8NoBomFile -Path $allowedWin -Text ($TestPrincipal + " " + $pubLine + "`n")

  $wslPrivSrc    = WinPath-ToWslLoose $Priv
  $wslPayloadSrc = WinPath-ToWslLoose $payloadWin
  $wslAllowedSrc = WinPath-ToWslLoose $allowedWin
  $wslRevSrc     = WinPath-ToWslLoose $revWin

  $workId = ("nfl_keytest_" + [Guid]::NewGuid().ToString("N"))

  # IMPORTANT: define WORK inside WSL using \$HOME so PowerShell never expands it.
  $cmdPrep = "set -e; umask 077; WORK=`"\$HOME/.nfl-keytest/$workId`"; mkdir -p `"`$WORK`"; " +
             "cp `"$wslPrivSrc`" `"`$WORK/key`"; cp `"$wslPrivSrc.pub`" `"`$WORK/key.pub`"; " +
             "cp `"$wslPayloadSrc`" `"`$WORK/payload.txt`"; cp `"$wslAllowedSrc`" `"`$WORK/allowed_signers`"; cp `"$wslRevSrc`" `"`$WORK/revoked_keys`"; " +
             "chmod 600 `"`$WORK/key`"; chmod 644 `"`$WORK/key.pub`" `"`$WORK/payload.txt`" `"`$WORK/allowed_signers`" `"`$WORK/revoked_keys`"; " +
             "echo WORK=`"`$WORK`""
  Write-Output "RUN: wsl -e sh -lc <prep>"
  $rp = Invoke-WslSync -Argv @("sh","-lc",$cmdPrep) -TimeoutSeconds 15
  if ($rp.ExitCode -ne 0) { Die ("WSL_PREP_FAIL`nSTDERR:`n" + $rp.Stderr + "`nSTDOUT:`n" + $rp.Stdout) }
  if (-not [string]::IsNullOrWhiteSpace($rp.Stdout)) { Write-Output ("WSL_PREP_OUT:`n" + $rp.Stdout) }

  $cmdSign = "set -e; WORK=`"\$HOME/.nfl-keytest/$workId`"; cd `"`$WORK`"; " +
             "ssh-keygen -Y sign -f `"`$WORK/key`" -I `"$TestPrincipal`" -n `"$TestNamespace`" `"`$WORK/payload.txt`""
  Write-Output "RUN: wsl -e sh -lc <sign>"
  $rs = Invoke-WslSync -Argv @("sh","-lc",$cmdSign) -TimeoutSeconds 15
  if ($rs.ExitCode -ne 0) { Die ("SIGN_FAIL`nSTDERR:`n" + $rs.Stderr + "`nSTDOUT:`n" + $rs.Stdout) }

  $cmdCopySig = "set -e; WORK=`"\$HOME/.nfl-keytest/$workId`"; test -f `"`$WORK/payload.txt.sig`"; " +
                "cp `"`$WORK/payload.txt.sig`" `"$wslPayloadSrc.sig`""
  Write-Output "RUN: wsl -e sh -lc <copy sig back>"
  $rc = Invoke-WslSync -Argv @("sh","-lc",$cmdCopySig) -TimeoutSeconds 15
  if ($rc.ExitCode -ne 0) { Die ("COPY_SIG_FAIL`nSTDERR:`n" + $rc.Stderr + "`nSTDOUT:`n" + $rc.Stdout) }

  if (-not (Test-Path -LiteralPath $sigWin -PathType Leaf)) { Die ("SIG_MISSING: " + $sigWin) }

  Write-Output ("PAYLOAD_SHA256: " + (Sha256Hex $payloadWin))
  Write-Output ("SIG_SHA256:     " + (Sha256Hex $sigWin))
  Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $allowedWin))

  $cmdVerify = "set -e; WORK=`"\$HOME/.nfl-keytest/$workId`"; cd `"`$WORK`"; " +
               "ssh-keygen -Y verify -f `"`$WORK/allowed_signers`" -I `"$TestPrincipal`" -n `"$TestNamespace`" -s `"`$WORK/payload.txt.sig`" -r `"`$WORK/revoked_keys`" `"`$WORK/payload.txt`""
  Write-Output "RUN: wsl -e sh -lc <verify>"
  $rv = Invoke-WslSync -Argv @("sh","-lc",$cmdVerify) -TimeoutSeconds 15
  if ($rv.ExitCode -ne 0) { Die ("VERIFY_FAIL`nSTDERR:`n" + $rv.Stderr + "`nSTDOUT:`n" + $rv.Stdout) }

  $cmdClean = "rm -rf `"\$HOME/.nfl-keytest/$workId`""
  [void](Invoke-WslSync -Argv @("sh","-lc",$cmdClean) -TimeoutSeconds 15)

  Write-Output "PASS: key rotated + WSL ext4 sign/verify succeeded (no /mnt/c key use)"
}
finally {
  Remove-Item -LiteralPath $tmpWin -Recurse -Force -ErrorAction SilentlyContinue
}
