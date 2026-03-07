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
# 1) WSL keygen + self-test ENTIRELY in /tmp (no /mnt/c involved)
# ----------------------------
try { [void](Get-Command wsl.exe -ErrorAction Stop) } catch { Die "WSL_MISSING: wsl.exe not found" }

$workId = ("nfl_wsl_fulltest_" + [Guid]::NewGuid().ToString("N"))
$work   = ("/tmp/" + $workId)
Write-Output ("WSL_WORK: " + $work)

$tmpWin = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("nfl_keytest_" + [Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Force -Path $tmpWin | Out-Null

$payloadWin = Join-Path $tmpWin "payload.txt"
$sigWin     = Join-Path $tmpWin "payload.txt.sig"
$allowedWin = Join-Path $tmpWin "allowed_signers"
$revWin     = Join-Path $tmpWin "revoked_keys"

try {
  Write-Utf8NoBomFile -Path $payloadWin -Text ("nfl key rotation self-test`n" + (Get-Date).ToUniversalTime().ToString("o"))
  Write-Utf8NoBomFile -Path $revWin -Text ""
  # allowed_signers content will be created in WSL from WSL key.pub (to guarantee match)

  $wslPayloadSrc = WinPath-ToWslLoose $payloadWin
  $wslSigDst     = WinPath-ToWslLoose $sigWin
  $wslAllowedDst = WinPath-ToWslLoose $allowedWin
  $wslRevDst     = WinPath-ToWslLoose $revWin

  $cmd = "set -e; umask 077; WORK=`"$work`"; rm -rf `"`$WORK`"; mkdir -p `"`$WORK`"; " +
         "ssh-keygen -q -t ed25519 -N '' -f `"`$WORK/key`" -C 'nfl-local'; " +
         "chmod 600 `"`$WORK/key`"; chmod 644 `"`$WORK/key.pub`"; " +
         "cp `"$wslPayloadSrc`" `"`$WORK/payload.txt`"; " +
         "printf '%s %s\n' '" + $TestPrincipal.Replace("'","'\\''") + "' `"`$(cat `"`$WORK/key.pub`")`" > `"`$WORK/allowed_signers`"; " +
         "cp `"$wslRevDst`" `"`$WORK/revoked_keys`"; chmod 644 `"`$WORK/allowed_signers`" `"`$WORK/revoked_keys`" `"`$WORK/payload.txt`"; " +
         "ssh-keygen -Y sign -f `"`$WORK/key`" -I '" + $TestPrincipal.Replace("'","'\\''") + "' -n '" + $TestNamespace.Replace("'","'\\''") + "' `"`$WORK/payload.txt`"; " +
         "test -f `"`$WORK/payload.txt.sig`"; " +
         "ssh-keygen -Y verify -f `"`$WORK/allowed_signers`" -I '" + $TestPrincipal.Replace("'","'\\''") + "' -n '" + $TestNamespace.Replace("'","'\\''") + "' -s `"`$WORK/payload.txt.sig`" -r `"`$WORK/revoked_keys`" `"`$WORK/payload.txt`"; " +
         "cp -f `"`$WORK/payload.txt.sig`" `"$wslSigDst`"; " +
         "cp -f `"`$WORK/allowed_signers`" `"$wslAllowedDst`"; " +
         "echo WSL_SELFTEST_OK"
  Write-Output "RUN: wsl -e sh -lc <keygen+sign+verify>"
  $rt = Invoke-WslSync -Argv @("sh","-lc",$cmd) -TimeoutSeconds 40
  if ($rt.ExitCode -ne 0) { Die ("WSL_SELFTEST_FAIL`nSTDERR:`n" + $rt.Stderr + "`nSTDOUT:`n" + $rt.Stdout) }
  if (-not [string]::IsNullOrWhiteSpace($rt.Stdout)) { Write-Output ("WSL_SELFTEST_OUT:`n" + $rt.Stdout) }

  if (-not (Test-Path -LiteralPath $sigWin -PathType Leaf)) { Die ("SIG_MISSING_AFTER_SELFTEST: " + $sigWin) }

  Write-Output ("PAYLOAD_SHA256: " + (Sha256Hex $payloadWin))
  Write-Output ("SIG_SHA256:     " + (Sha256Hex $sigWin))
  Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $allowedWin))

  # ----------------------------
  # 2) Copy the VERIFIED WSL keypair into the repo, then byte-compare
  # ----------------------------
  $wslPrivDst = WinPath-ToWslLoose $Priv
  $wslPubDst  = WinPath-ToWslLoose $Pub

  $cmdCopy = "set -e; WORK=`"$work`"; " +
             "cp -f `"`$WORK/key`" `"$wslPrivDst`"; cp -f `"`$WORK/key.pub`" `"$wslPubDst`"; " +
             "echo COPIED_TO_REPO"
  Write-Output "RUN: wsl -e sh -lc <copy keypair to repo>"
  $rc = Invoke-WslSync -Argv @("sh","-lc",$cmdCopy) -TimeoutSeconds 20
  if ($rc.ExitCode -ne 0) { Die ("WSL_COPY_TO_REPO_FAIL`nSTDERR:`n" + $rc.Stderr + "`nSTDOUT:`n" + $rc.Stdout) }

  if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("REPO_PRIV_MISSING: " + $Priv) }
  if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("REPO_PUB_MISSING: " + $Pub) }

  Write-Output ("REPO_PRIV_SHA256: " + (Sha256Hex $Priv))
  Write-Output ("REPO_PUB_SHA256:  " + (Sha256Hex $Pub))

  # Compare bytes as seen by WSL on both paths (detect DrvFS mutation)
  $wslPrivRepo = WinPath-ToWslLoose $Priv
  $wslPubRepo  = WinPath-ToWslLoose $Pub

  $cmdCmp = "set -e; WORK=`"$work`"; " +
            "h1=`$(sha256sum `"`$WORK/key`" | awk '{print $1}') ; " +
            "h2=`$(sha256sum `"$wslPrivRepo`" | awk '{print $1}') ; " +
            "p1=`$(sha256sum `"`$WORK/key.pub`" | awk '{print $1}') ; " +
            "p2=`$(sha256sum `"$wslPubRepo`" | awk '{print $1}') ; " +
            "echo WSL_PRIV_TMP_SHA256=`$h1 ; echo WSL_PRIV_REPO_SHA256=`$h2 ; " +
            "echo WSL_PUB_TMP_SHA256=`$p1 ; echo WSL_PUB_REPO_SHA256=`$p2 ; " +
            "test `"$h1`" = `"$h2`" ; test `"$p1`" = `"$p2`" ; echo WSL_REPO_BYTES_MATCH"
  Write-Output "RUN: wsl -e sh -lc <compare tmp vs repo bytes>"
  $rm = Invoke-WslSync -Argv @("sh","-lc",$cmdCmp) -TimeoutSeconds 20
  if ($rm.ExitCode -ne 0) { Die ("WSL_REPO_MISMATCH: DrvFS mutated key bytes?`nSTDERR:`n" + $rm.Stderr + "`nSTDOUT:`n" + $rm.Stdout) }
  if (-not [string]::IsNullOrWhiteSpace($rm.Stdout)) { Write-Output ("WSL_MATCH_OUT:`n" + $rm.Stdout) }

  $pubLine = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()
  Write-Output ("PUBFILE_LINE: " + $pubLine)

  # cleanup best-effort
  [void](Invoke-WslSync -Argv @("sh","-lc",("rm -rf `"$work`"")) -TimeoutSeconds 10)

  Write-Output "PASS: WSL self-test verified + repo keypair copied + bytes match"
}
finally {
  Remove-Item -LiteralPath $tmpWin -Recurse -Force -ErrorAction SilentlyContinue
}
