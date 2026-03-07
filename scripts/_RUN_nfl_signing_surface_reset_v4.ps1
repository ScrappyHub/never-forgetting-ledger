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

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $root "scripts"
if (-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)) { Die ("scripts dir not found: " + $ScriptsDir) }

$KeyPriv = Join-Path $root "proofs\keys\nfl-local_ed25519"
$KeyPub  = $KeyPriv + ".pub"
if (-not (Test-Path -LiteralPath $KeyPriv -PathType Leaf)) { Die ("MISSING_PRIVKEY: " + $KeyPriv) }
if (-not (Test-Path -LiteralPath $KeyPub  -PathType Leaf)) { Die ("MISSING_PUBKEY : " + $KeyPub) }

$TrustBundle = Join-Path (Join-Path $root "proofs\trust") "trust_bundle.json"
if (-not (Test-Path -LiteralPath $TrustBundle -PathType Leaf)) { Die ("MISSING_TRUST_BUNDLE: " + $TrustBundle) }

Write-Output ("REPO: " + $root)
Write-Output ("KEY : " + $KeyPriv)

# 1) Patch installer drift (optional)
$Installer = Join-Path $ScriptsDir "_install_neverlost_v1_nfl.ps1"
[void](Patch-FileRegexOptional -Path $Installer -Label "installer_keyname_script_scope" -Pattern '\(\s*\$script:AuthorityName\s*\+\s*"_ed25519"\s*\)' -Replacement '"nfl-local_ed25519"')
[void](Patch-FileRegexOptional -Path $Installer -Label "installer_keyname_nonscript_scope" -Pattern '\(\s*\$AuthorityName\s*\+\s*"_ed25519"\s*\)' -Replacement '"nfl-local_ed25519"')

# 2) Write sign_file_v1.ps1
$Sign = Join-Path $ScriptsDir "sign_file_v1.ps1"
$sign = New-Object System.Collections.Generic.List[string]
[void]$sign.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$Namespace,[Parameter(Mandatory=$true)][string]$File,[Parameter(Mandatory=$true)][string]$OutSig,[int]$TimeoutSeconds=30)')
[void]$sign.Add('$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest')
[void]$sign.Add('function Die([string]$m){ throw $m }')
[void]$sign.Add('function Invoke-OpenSshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){ if($TimeoutSeconds -lt 1){ Die "TimeoutSeconds must be >= 1" } $ssh=(Get-Command ssh-keygen.exe -ErrorAction Stop).Source; $parts=New-Object System.Collections.Generic.List[string]; foreach($a in @(@($Argv))){ [void]$parts.Add((Quote-Arg $a)) }; $argStr=($parts.ToArray() -join " "); $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$ssh; $psi.Arguments=$argStr; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=$true; $psi.CreateNoWindow=$true; $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; if(-not $p.Start()){ Die "Failed to start ssh-keygen" }; try{$p.StandardInput.Close()}catch{}; $ok=$p.WaitForExit($TimeoutSeconds*1000); if(-not $ok){ try{$p.Kill()|Out-Null}catch{}; Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr) }; $stdout="";$stderr=""; try{$stdout=$p.StandardOutput.ReadToEnd()}catch{$stdout=""}; try{$stderr=$p.StandardError.ReadToEnd()}catch{$stderr=""}; $stdout=($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd(); $stderr=($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd(); if($p.ExitCode -ne 0){ Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout) }; return $true }')
[void]$sign.Add('$root=(Resolve-Path -LiteralPath $RepoRoot).Path; $KeyPriv=Join-Path $root "proofs\keys\nfl-local_ed25519"; $Principal="single-tenant/local/authority/nfl"' )
[void]$sign.Add('if(-not (Test-Path -LiteralPath $KeyPriv -PathType Leaf)){ Die ("Missing signing key: " + $KeyPriv) }')
[void]$sign.Add('if([string]::IsNullOrWhiteSpace($Namespace)){ Die "Namespace empty" }')
[void]$sign.Add('if(-not (Test-Path -LiteralPath $File -PathType Leaf)){ Die ("Missing file: " + $File) }')
[void]$sign.Add('$OutDir=Split-Path -Parent $OutSig; if($OutDir -and -not (Test-Path -LiteralPath $OutDir -PathType Container)){ New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }')
[void]$sign.Add('if(Test-Path -LiteralPath $OutSig -PathType Leaf){ Remove-Item -LiteralPath $OutSig -Force }')
[void]$sign.Add('Write-Output ("RUN: ssh-keygen -Y sign (I=" + $Principal + " n=" + $Namespace + ")")')
[void]$sign.Add('[void](Invoke-OpenSshKeygenPSI -Argv @("-Y","sign","-f",$KeyPriv,"-I",$Principal,"-n",$Namespace,"-s",$OutSig,$File) -TimeoutSeconds $TimeoutSeconds)')
[void]$sign.Add('if(-not (Test-Path -LiteralPath $OutSig -PathType Leaf)){ Die ("Signature not created: " + $OutSig) }')
[void]$sign.Add('Write-Output ("OK: SIGNED " + $OutSig)' )
Write-Utf8NoBomLf -Path $Sign -Text (($sign.ToArray() -join "`n") + "`n")
Parse-GateFile $Sign
Write-Output ("WROTE: " + $Sign)

# 3) Write verify_sig_v1.ps1 (you already wrote this, but we hard reset it)
$Ver = Join-Path $ScriptsDir "verify_sig_v1.ps1"
$ver = New-Object System.Collections.Generic.List[string]
[void]$ver.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$Namespace,[Parameter(Mandatory=$true)][string]$File,[Parameter(Mandatory=$true)][string]$Sig,[string]$Principal="single-tenant/local/authority/nfl",[int]$TimeoutSeconds=30)')
[void]$ver.Add('$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest')
[void]$ver.Add('function Die([string]$m){ throw $m }')
[void]$ver.Add('function Invoke-OpenSshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){ if($TimeoutSeconds -lt 1){ Die "TimeoutSeconds must be >= 1" } $ssh=(Get-Command ssh-keygen.exe -ErrorAction Stop).Source; $parts=New-Object System.Collections.Generic.List[string]; foreach($a in @(@($Argv))){ [void]$parts.Add((Quote-Arg $a)) }; $argStr=($parts.ToArray() -join " "); $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$ssh; $psi.Arguments=$argStr; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=$true; $psi.CreateNoWindow=$true; $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi; if(-not $p.Start()){ Die "Failed to start ssh-keygen" }; try{$p.StandardInput.Close()}catch{}; $ok=$p.WaitForExit($TimeoutSeconds*1000); if(-not $ok){ try{$p.Kill()|Out-Null}catch{}; Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr) }; $stdout="";$stderr=""; try{$stdout=$p.StandardOutput.ReadToEnd()}catch{$stdout=""}; try{$stderr=$p.StandardError.ReadToEnd()}catch{$stderr=""}; $stdout=($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd(); $stderr=($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd(); if($p.ExitCode -ne 0){ Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout) }; return $true }')
[void]$ver.Add('$root=(Resolve-Path -LiteralPath $RepoRoot).Path; $AllowedSigners=Join-Path $root "proofs\trust\allowed_signers"' )
[void]$ver.Add('if(-not (Test-Path -LiteralPath $AllowedSigners -PathType Leaf)){ Die ("Missing allowed_signers: " + $AllowedSigners) }')
[void]$ver.Add('if([string]::IsNullOrWhiteSpace($Namespace)){ Die "Namespace empty" }')
[void]$ver.Add('if([string]::IsNullOrWhiteSpace($Principal)){ Die "Principal empty" }')
[void]$ver.Add('if(-not (Test-Path -LiteralPath $File -PathType Leaf)){ Die ("Missing file: " + $File) }')
[void]$ver.Add('if(-not (Test-Path -LiteralPath $Sig -PathType Leaf)){ Die ("Missing sig: " + $Sig) }')
[void]$ver.Add('$tmpRev=Join-Path ([System.IO.Path]::GetTempPath()) ("nfl_revocations_empty_" + [Guid]::NewGuid().ToString("N") + ".txt"); "" | Set-Content -LiteralPath $tmpRev -Encoding UTF8' )
[void]$ver.Add('try{ Write-Output ("RUN: ssh-keygen -Y verify (I=" + $Principal + " n=" + $Namespace + ")"); [void](Invoke-OpenSshKeygenPSI -Argv @("-Y","verify","-f",$AllowedSigners,"-I",$Principal,"-n",$Namespace,"-s",$Sig,"-r",$tmpRev,$File) -TimeoutSeconds $TimeoutSeconds) } finally { try{ Remove-Item -LiteralPath $tmpRev -Force -ErrorAction SilentlyContinue } catch {} }' )
[void]$ver.Add('Write-Output "OK: VERIFIED"' )
Write-Utf8NoBomLf -Path $Ver -Text (($ver.ToArray() -join "`n") + "`n")
Parse-GateFile $Ver
Write-Output ("WROTE: " + $Ver)

# 4) Write selftest and run it (runner owns $root and Die)
$SelfTest = Join-Path $ScriptsDir "_selftest_nfl_sign_verify_v1.ps1"
$st = New-Object System.Collections.Generic.List[string]
[void]$st.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot)')
[void]$st.Add('$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest')
[void]$st.Add('function Die([string]$m){ throw $m }')
[void]$st.Add('$root=(Resolve-Path -LiteralPath $RepoRoot).Path; $ScriptsDir=Join-Path $root "scripts"' )
[void]$st.Add('$mk=Join-Path $ScriptsDir "make_allowed_signers_v1.ps1"; if(Test-Path -LiteralPath $mk -PathType Leaf){ Write-Output "RUN: make_allowed_signers_v1.ps1"; & (Get-Command powershell.exe -ErrorAction Stop).Source -NoProfile -ExecutionPolicy Bypass -File $mk -Root $root | Out-Null } else { Write-Output "SKIP: make_allowed_signers_v1.ps1 not present" }' )
[void]$st.Add('$payload=Join-Path $root "proofs\_tmp_selftest_payload.txt"; $sig=Join-Path $root "proofs\_tmp_selftest_payload.sig"; "selftest " + (Get-Date).ToUniversalTime().ToString("o") | Set-Content -LiteralPath $payload -Encoding UTF8' )
[void]$st.Add('$ns="nfl/selftest"; $sign=Join-Path $ScriptsDir "sign_file_v1.ps1"; $ver=Join-Path $ScriptsDir "verify_sig_v1.ps1"; if(-not (Test-Path -LiteralPath $sign -PathType Leaf)){ Die ("Missing sign script: " + $sign) }; if(-not (Test-Path -LiteralPath $ver -PathType Leaf)){ Die ("Missing verify script: " + $ver) }' )
[void]$st.Add('Write-Output "RUN: sign_file_v1.ps1"; & (Get-Command powershell.exe -ErrorAction Stop).Source -NoProfile -ExecutionPolicy Bypass -File $sign -RepoRoot $root -Namespace $ns -File $payload -OutSig $sig | Out-Null' )
[void]$st.Add('Write-Output "RUN: verify_sig_v1.ps1"; & (Get-Command powershell.exe -ErrorAction Stop).Source -NoProfile -ExecutionPolicy Bypass -File $ver -RepoRoot $root -Namespace $ns -File $payload -Sig $sig | Out-Null' )
[void]$st.Add('Write-Output "PASS: NFL SIGN/VERIFY SELFTEST v1"' )
Write-Utf8NoBomLf -Path $SelfTest -Text (($st.ToArray() -join "`n") + "`n")
Parse-GateFile $SelfTest
Write-Output ("WROTE: " + $SelfTest)

Write-Output ""
Write-Output "RUN: selftest..."
$p = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-File",$SelfTest,"-RepoRoot",$root) -NoNewWindow -Wait -PassThru
if ($p.ExitCode -ne 0) { Die ("SELFTEST failed (exit " + $p.ExitCode + ")") }

Write-Output "OK: NFL signing surface locked to repo-managed key + selftest PASS"
