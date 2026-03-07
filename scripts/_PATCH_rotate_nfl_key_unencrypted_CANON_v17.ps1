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
# Repo paths
# ----------------------------
$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeysDir = Join-Path $Root "proofs\keys"
if (-not (Test-Path -LiteralPath $KeysDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $KeysDir | Out-Null }

$Priv  = Join-Path $KeysDir "nfl-local_ed25519"
$Pub   = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Output ("REPO: " + $Root)

# Backup + remove old
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

# ----------------------------
# 1) Generate key INSIDE WSL, then copy into repo
# ----------------------------
try { [void](Get-Command wsl.exe -ErrorAction Stop) } catch { Die "WSL_MISSING: wsl.exe not found" }

$wslPrivDst = WinPath-ToWslLoose $Priv
$wslPubDst  = WinPath-ToWslLoose $Pub

$workId = ("nfl_wsl_keygen_" + [Guid]::NewGuid().ToString("N"))
$work   = ("/tmp/" + $workId)

Write-Output ("WSL_KEYGEN_WORK: " + $work)

$cmdKeygen = "set -e; umask 077; WORK=`"$work`"; rm -rf `"`$WORK`"; mkdir -p `"`$WORK`"; " +
             "ssh-keygen -q -t ed25519 -N '' -f `"`$WORK/key`" -C 'nfl-local'; " +
             "chmod 600 `"`$WORK/key`"; chmod 644 `"`$WORK/key.pub`"; " +
             "test -f `"`$WORK/key`"; test -f `"`$WORK/key.pub`"; " +
             "cp -f `"`$WORK/key`" `"$wslPrivDst`"; cp -f `"`$WORK/key.pub`" `"$wslPubDst`"; " +
             "echo KEYGEN_OK"
Write-Output "RUN: wsl -e sh -lc <wsl keygen>"
$rk = Invoke-WslSync -Argv @("sh","-lc",$cmdKeygen) -TimeoutSeconds 30
if ($rk.ExitCode -ne 0) { Die ("WSL_KEYGEN_FAIL`nSTDERR:`n" + $rk.Stderr + "`nSTDOUT:`n" + $rk.Stdout) }
if (-not [string]::IsNullOrWhiteSpace($rk.Stdout)) { Write-Output ("WSL_KEYGEN_OUT:`n" + $rk.Stdout) }

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

Write-Output ("PRIV_SHA256: " + (Sha256Hex $Priv))
Write-Output ("PUB_SHA256:  " + (Sha256Hex $Pub))

$pubLine = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($pubLine)) { Die "PUBFILE_EMPTY" }
Write-Output ("PUBFILE_LINE: " + $pubLine)

# ----------------------------
# 2) Self-test: sign+verify in WSL using repo key (copied to /tmp for perms)
# ----------------------------
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

  $work2Id = ("nfl_sigtest_" + [Guid]::NewGuid().ToString("N"))
  $work2   = ("/tmp/" + $work2Id)
  Write-Output ("WSL_SIGTEST_WORK: " + $work2)

  $cmdPrep2 = "set -e; umask 077; WORK=`"$work2`"; rm -rf `"`$WORK`"; mkdir -p `"`$WORK`"; " +
              "cp `"$wslPrivSrc`" `"`$WORK/key`"; cp `"$wslPrivSrc.pub`" `"`$WORK/key.pub`"; " +
              "cp `"$wslPayloadSrc`" `"`$WORK/payload.txt`"; cp `"$wslAllowedSrc`" `"`$WORK/allowed_signers`"; cp `"$wslRevSrc`" `"`$WORK/revoked_keys`"; " +
              "chmod 600 `"`$WORK/key`"; chmod 644 `"`$WORK/key.pub`" `"`$WORK/payload.txt`" `"`$WORK/allowed_signers`" `"`$WORK/revoked_keys`"; " +
              "test -f `"`$WORK/key`"; echo PREP_OK"
  Write-Output "RUN: wsl -e sh -lc <prep>"
  $rp = Invoke-WslSync -Argv @("sh","-lc",$cmdPrep2) -TimeoutSeconds 20
  if ($rp.ExitCode -ne 0) { Die ("WSL_PREP_FAIL`nSTDERR:`n" + $rp.Stderr + "`nSTDOUT:`n" + $rp.Stdout) }
  if (-not [string]::IsNullOrWhiteSpace($rp.Stdout)) { Write-Output ("WSL_PREP_OUT:`n" + $rp.Stdout) }

  $cmdSign2 = "set -e; WORK=`"$work2`"; cd `"`$WORK`"; ssh-keygen -Y sign -f `"`$WORK/key`" -I `"$TestPrincipal`" -n `"$TestNamespace`" `"`$WORK/payload.txt`"; echo SIGN_OK"
  Write-Output "RUN: wsl -e sh -lc <sign>"
  $rs = Invoke-WslSync -Argv @("sh","-lc",$cmdSign2) -TimeoutSeconds 20
  if ($rs.ExitCode -ne 0) { Die ("SIGN_FAIL`nSTDERR:`n" + $rs.Stderr + "`nSTDOUT:`n" + $rs.Stdout) }

  $cmdCopySig2 = "set -e; WORK=`"$work2`"; test -f `"`$WORK/payload.txt.sig`"; cp `"`$WORK/payload.txt.sig`" `"$wslPayloadSrc.sig`"; echo COPY_SIG_OK"
  Write-Output "RUN: wsl -e sh -lc <copy sig back>"
  $rc = Invoke-WslSync -Argv @("sh","-lc",$cmdCopySig2) -TimeoutSeconds 20
  if ($rc.ExitCode -ne 0) { Die ("COPY_SIG_FAIL`nSTDERR:`n" + $rc.Stderr + "`nSTDOUT:`n" + $rc.Stdout) }

  if (-not (Test-Path -LiteralPath $sigWin -PathType Leaf)) { Die ("SIG_MISSING: " + $sigWin) }

  Write-Output ("PAYLOAD_SHA256: " + (Sha256Hex $payloadWin))
  Write-Output ("SIG_SHA256:     " + (Sha256Hex $sigWin))
  Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $allowedWin))

  $cmdVerify2 = "set -e; WORK=`"$work2`"; cd `"`$WORK`"; ssh-keygen -Y verify -f `"`$WORK/allowed_signers`" -I `"$TestPrincipal`" -n `"$TestNamespace`" -s `"`$WORK/payload.txt.sig`" -r `"`$WORK/revoked_keys`" `"`$WORK/payload.txt`"; echo VERIFY_OK"
  Write-Output "RUN: wsl -e sh -lc <verify>"
  $rv = Invoke-WslSync -Argv @("sh","-lc",$cmdVerify2) -TimeoutSeconds 20
  if ($rv.ExitCode -ne 0) { Die ("VERIFY_FAIL`nSTDERR:`n" + $rv.Stderr + "`nSTDOUT:`n" + $rv.Stdout) }

  # cleanup best-effort
  [void](Invoke-WslSync -Argv @("sh","-lc",("rm -rf `"$work`" `"$work2`"")) -TimeoutSeconds 20)

  Write-Output "PASS: WSL-generated key stored in repo + WSL -Y sign/verify succeeded"
}
finally {
  Remove-Item -LiteralPath $tmpWin -Recurse -Force -ErrorAction SilentlyContinue
}
