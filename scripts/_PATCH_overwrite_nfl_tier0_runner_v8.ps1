param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8NoBomLf([string]$Path,[string[]]$Lines){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; $txt=((@($Lines) -join "`n") + "`n"); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes($txt)); if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("WRITE_FAILED: " + $Path) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; throw ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
$Runner = Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1"
$bak=$null
if(Test-Path -LiteralPath $Runner -PathType Leaf){ $bak=$Runner + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"); Copy-Item -LiteralPath $Runner -Destination $bak -Force }

# --- write runner as plain line list (no embedded `r/`n backticks anywhere) ---
$RL = New-Object System.Collections.Generic.List[string]
[void]$RL.Add("param([Parameter(Mandatory=$true)][string]$RepoRoot)")
[void]$RL.Add("Set-StrictMode -Version Latest")
[void]$RL.Add("$ErrorActionPreference=""Stop""")
[void]$RL.Add("")
[void]$RL.Add("function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }")
[void]$RL.Add("function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw (""PARSEGATE_MISSING: "" + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join "" | ""; throw (""PARSEGATE_FAIL: "" + $Path + "" :: "" + $m) } }")
[void]$RL.Add("function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }")
[void]$RL.Add("function NormalizeLf([string]$t){ if($null -eq $t){ return """" }; $cr=[char]13; $lf=[char]10; $u=$t.Replace(""$cr$lf"",""$lf"").Replace(""$cr"",""$lf""); if(-not $u.EndsWith(""$lf"")){ $u = $u + ""$lf"" }; return $u }")
[void]$RL.Add("function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes((NormalizeLf $Text))); if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw (""WRITE_FAILED: "" + $Path) } }")
[void]$RL.Add("function Sha256Hex([string]$Path){ (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }")
[void]$RL.Add("function RelPath([string]$Root,[string]$Full){ $bs=[char]92; $r=(Resolve-Path -LiteralPath $Root).Path.TrimEnd($bs); $f=(Resolve-Path -LiteralPath $Full).Path; if($f.Length -lt $r.Length){ return $f.Replace($bs,[char]47) }; if($f.Substring(0,$r.Length).ToLowerInvariant() -ne $r.ToLowerInvariant()){ return $f.Replace($bs,[char]47) }; $rel=$f.Substring($r.Length).TrimStart($bs); return $rel.Replace($bs,[char]47) }")
[void]$RL.Add("function WriteSha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){ $rows=New-Object System.Collections.Generic.List[string]; foreach($fp in $FilesAbs){ if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){ throw (""SHA256SUMS_MISSING_FILE: "" + $fp) }; $hex=Sha256Hex $fp; $rel=RelPath $Root $fp; [void]$rows.Add(($hex + ""  "" + $rel)) }; WriteUtf8NoBomLf $OutPath ((@($rows.ToArray()) -join ""`n"") + ""`n"") }")
[void]$RL.Add("function RunChild([string]$PSExe,[string]$ScriptPath,[string]$RepoRoot,[string]$StdOut,[string]$StdErr){ if(Test-Path -LiteralPath $StdOut -PathType Leaf){ Remove-Item -LiteralPath $StdOut -Force }; if(Test-Path -LiteralPath $StdErr -PathType Leaf){ Remove-Item -LiteralPath $StdErr -Force }; $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$PSExe; $psi.Arguments=("" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + $ScriptPath + ""`" -RepoRoot `"" + $RepoRoot + ""`"""); $psi.WorkingDirectory=$RepoRoot; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true; $pp=New-Object System.Diagnostics.Process; $pp.StartInfo=$psi; $null=$pp.Start(); $so=$pp.StandardOutput.ReadToEnd(); $se=$pp.StandardError.ReadToEnd(); $pp.WaitForExit(); WriteUtf8NoBomLf $StdOut $so; WriteUtf8NoBomLf $StdErr $se; return @{ exit=[int]$pp.ExitCode; stdout=$so; stderr=$se } }")
[void]$RL.Add("function AssertContains([string]$Hay,[string]$Needle,[string]$FailToken){ if($null -eq $Hay){ $Hay="""" }; if($Hay -notmatch [regex]::Escape($Needle)){ throw ($FailToken + "":MISSING_NEEDLE:"" + $Needle) } }")
[void]$RL.Add("function AssertAnyTokenExact([string]$Text,[string[]]$ExactTokens,[string]$FailToken){ $t=NormalizeLf $Text; foreach($x in $ExactTokens){ if($t -match (""(?m)^\Q"" + $x + ""\E$"")){ return } }; throw ($FailToken + "":NO_EXPECTED_TOKEN"") }")
[void]$RL.Add("function JsonEsc([string]$s){ if($null -eq $s){ return """" }; $bs=[string][char]92; $dq=[string][char]34; $t=$s.Replace($bs,$bs+$bs).Replace($dq,$bs+$dq); $t=$t.Replace([char]13,""""); $t=$t.Replace([char]10,""\n""); return $t }")
[void]$RL.Add("")
[void]$RL.Add("$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path")
[void]$RL.Add("$ScriptsDir=Join-Path $RepoRoot ""scripts""")
[void]$RL.Add("$ProofsDir=Join-Path $RepoRoot ""proofs""")
[void]$RL.Add("$RcptRoot=Join-Path $ProofsDir ""receipts""")
[void]$RL.Add("EnsureDir $ProofsDir")
[void]$RL.Add("EnsureDir $RcptRoot")
[void]$RL.Add("")
[void]$RL.Add("$must=@((Join-Path $ScriptsDir ""verify_packet_v1.ps1""),(Join-Path $ScriptsDir ""selftest_verify_packet_v1.ps1""),(Join-Path $ScriptsDir ""selftest_vectors_v1.ps1""),(Join-Path $ScriptsDir ""_selftest_nfl_tier0_v2.ps1""))")
[void]$RL.Add("$libs=@(Get-ChildItem -LiteralPath $ScriptsDir -File -Filter ""lib_*.ps1"" -ErrorAction SilentlyContinue | Sort-Object FullName)")
[void]$RL.Add("foreach($lf in $libs){ $must += @($lf.FullName) }")
[void]$RL.Add("foreach($mf in $must){ if(-not (Test-Path -LiteralPath $mf -PathType Leaf)){ throw (""PARSEGATE_REQUIRED_MISSING: "" + $mf) }; ParseGateFile $mf }")
[void]$RL.Add("Write-Output ""PARSE_GATE_OK""")
[void]$RL.Add("")
[void]$RL.Add("$stamp=(Get-Date).ToUniversalTime().ToString(""yyyyMMddTHHmmssZ"")")
[void]$RL.Add("$bundle=Join-Path $RcptRoot $stamp")
[void]$RL.Add("EnsureDir $bundle")
[void]$RL.Add("$out1=Join-Path $bundle ""selftest_verify_packet.stdout.txt""")
[void]$RL.Add("$err1=Join-Path $bundle ""selftest_verify_packet.stderr.txt""")
[void]$RL.Add("$out2=Join-Path $bundle ""selftest_vectors.stdout.txt""")
[void]$RL.Add("$err2=Join-Path $bundle ""selftest_vectors.stderr.txt""")
[void]$RL.Add("$PSExe=(Get-Command powershell.exe -ErrorAction Stop).Source")
[void]$RL.Add("$st1=Join-Path $ScriptsDir ""selftest_verify_packet_v1.ps1""")
[void]$RL.Add("$st2=Join-Path $ScriptsDir ""selftest_vectors_v1.ps1""")
[void]$RL.Add("$r1=RunChild $PSExe $st1 $RepoRoot $out1 $err1")
[void]$RL.Add("if($r1.exit -ne 0){ Write-Output (""SELFTEST_VERIFY_PACKET_EXIT="" + $r1.exit); throw ""SELFTEST_VERIFY_PACKET_FAILED"" }")
[void]$RL.Add("AssertContains $r1.stdout ""VERIFY_SELFTEST_OK"" ""SELFTEST_VERIFY_PACKET_BAD_STDOUT""")
[void]$RL.Add("$r2=RunChild $PSExe $st2 $RepoRoot $out2 $err2")
[void]$RL.Add("if($r2.exit -ne 0){ Write-Output (""SELFTEST_VECTORS_EXIT="" + $r2.exit); throw ""SELFTEST_VECTORS_FAILED"" }")
[void]$RL.Add("AssertContains $r2.stdout ""VECTORS_SELFTEST_OK"" ""SELFTEST_VECTORS_BAD_STDOUT""")
[void]$RL.Add("$expected=@(""NFL_VERIFY_FAIL:SHA256_MISMATCH"",""NFL_VERIFY_FAIL:MISSING_SIG"",""NFL_VERIFY_FAIL:SIG_VERIFY_FAIL"",""NFL_VERIFY_FAIL:MISSING_SHA256SUMS"",""NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE"",""NFL_VERIFY_FAIL:TRAVERSAL_PATH"",""NFL_VERIFY_FAIL:MISSING_TARGET"")")
[void]$RL.Add("AssertAnyTokenExact $r2.stdout $expected ""ERROR_TAXONOMY_NOT_EMITTED""")
[void]$RL.Add("$rcpt=Join-Path $bundle ""nfl.tier0.selftest.v1.ndjson""")
[void]$RL.Add("$line=(""{"" + """"""type"""""":""""""nfl.tier0.selftest.v1""""","" + """"""utc"""""":"""""" + (JsonEsc $stamp) + """"""","" + """"""ok"""""":true,"" + """"""repo_root"""""":"""""" + (JsonEsc $RepoRoot) + """"""","" + """"""bundle_dir"""""":"""""" + (JsonEsc $bundle) + """"""","" + """"""selftest_verify_exit""""":" + $r1.exit + "","" + """"""selftest_vectors_exit""""":" + $r2.exit + ""}"")")
[void]$RL.Add("WriteUtf8NoBomLf $rcpt ($line + ""`n"")")
[void]$RL.Add("$files=@(Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName)")
[void]$RL.Add("$abs=New-Object System.Collections.Generic.List[string]")
[void]$RL.Add("foreach($ff in $files){ [void]$abs.Add($ff.FullName) }")
[void]$RL.Add("$sum=Join-Path $bundle ""sha256sums.txt""")
[void]$RL.Add("WriteSha256Sums $bundle $sum ($abs.ToArray())")
[void]$RL.Add("Write-Output ""NFL_TIER0_SELFTEST_OK""")
[void]$RL.Add("Write-Output (""BUNDLE_DIR="" + $bundle)")

WriteUtf8NoBomLf $Runner ($RL.ToArray())
ParseGateFile $Runner
Write-Output ("PATCH_OK wrote=" + $Runner)
if($bak){ Write-Output ("BACKUP=" + $bak) }
