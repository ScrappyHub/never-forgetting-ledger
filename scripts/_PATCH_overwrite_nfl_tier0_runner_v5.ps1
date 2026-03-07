param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes((NormalizeLf $Text))); if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("WRITE_FAILED: " + $Path) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; throw ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir=Join-Path $RepoRoot "scripts"
if(-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)){ throw ("MISSING_SCRIPTS_DIR: " + $ScriptsDir) }

$OutRunner = Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1"
$bak = $null
if(Test-Path -LiteralPath $OutRunner -PathType Leaf){ $bak = $OutRunner + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"); Copy-Item -LiteralPath $OutRunner -Destination $bak -Force }

$R = New-Object System.Collections.Generic.List[string]
[void]$R.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot)')
[void]$R.Add('')
[void]$R.Add('Set-StrictMode -Version Latest')
[void]$R.Add('$ErrorActionPreference="Stop"')
[void]$R.Add('')
[void]$R.Add('function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }')
[void]$R.Add('function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }')
[void]$R.Add('function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }')
[void]$R.Add('function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllBytes($Path,$enc.GetBytes((NormalizeLf $Text))); if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("WRITE_FAILED: " + $Path) } }')
[void]$R.Add('function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; throw ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }')
[void]$R.Add('function Sha256Hex([string]$Path){ (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }')
[void]$R.Add('function RelPath([string]$Root,[string]$Full){ $r=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\'); $f=(Resolve-Path -LiteralPath $Full).Path; if($f.Length -lt $r.Length){ return $f.Replace('\','/') }; if($f.Substring(0,$r.Length).ToLowerInvariant() -ne $r.ToLowerInvariant()){ return $f.Replace('\','/') }; $rel=$f.Substring($r.Length).TrimStart('\'); return $rel.Replace('\','/') }')
[void]$R.Add('function WriteSha256Sums([string]$Root,[string]$OutPath,[string[]]$FilesAbs){ $rows=New-Object System.Collections.Generic.List[string]; foreach($fp in $FilesAbs){ if(-not (Test-Path -LiteralPath $fp -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + $fp) }; $hex=Sha256Hex $fp; $rel=RelPath $Root $fp; [void]$rows.Add(($hex + "  " + $rel)) }; WriteUtf8NoBomLf $OutPath ((@($rows.ToArray()) -join "`n") + "`n") }')
[void]$R.Add('function RunChild([string]$PSExe,[string]$ScriptPath,[string]$RepoRoot,[string]$StdOut,[string]$StdErr){ if(Test-Path -LiteralPath $StdOut -PathType Leaf){ Remove-Item -LiteralPath $StdOut -Force }; if(Test-Path -LiteralPath $StdErr -PathType Leaf){ Remove-Item -LiteralPath $StdErr -Force }; $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName=$PSExe; $psi.Arguments=("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -RepoRoot `"{1}`"" -f $ScriptPath,$RepoRoot); $psi.WorkingDirectory=$RepoRoot; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true; $pp=New-Object System.Diagnostics.Process; $pp.StartInfo=$psi; $null=$pp.Start(); $so=$pp.StandardOutput.ReadToEnd(); $se=$pp.StandardError.ReadToEnd(); $pp.WaitForExit(); WriteUtf8NoBomLf $StdOut $so; WriteUtf8NoBomLf $StdErr $se; return @{ exit=[int]$pp.ExitCode; stdout=$so; stderr=$se } }')
[void]$R.Add('function AssertContains([string]$Hay,[string]$Needle,[string]$FailToken){ if($null -eq $Hay){ $Hay="" }; if($Hay -notmatch [regex]::Escape($Needle)){ throw ($FailToken + ":MISSING_NEEDLE:" + $Needle) } }')
[void]$R.Add('function AssertAnyTokenExact([string]$Text,[string[]]$ExactTokens,[string]$FailToken){ $t=NormalizeLf $Text; foreach($x in $ExactTokens){ if($t -match ("(?m)^\Q" + $x + "\E$")){ return } }; throw ($FailToken + ":NO_EXPECTED_TOKEN") }')
[void]$R.Add('function JsonEsc([string]$s){ if($null -eq $s){ return "" }; $t=$s.Replace('\','\\').Replace('"','\"'); $t=($t -replace "`r",""); $t=$t.Replace("`n","\n"); return $t }')
[void]$R.Add('')
[void]$R.Add('$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path')
[void]$R.Add('$ScriptsDir=Join-Path $RepoRoot "scripts"')
[void]$R.Add('$ProofsDir=Join-Path $RepoRoot "proofs"')
[void]$R.Add('$RcptRoot=Join-Path $ProofsDir "receipts"')
[void]$R.Add('EnsureDir $ProofsDir')
[void]$R.Add('EnsureDir $RcptRoot')
[void]$R.Add('')
[void]$R.Add('$must=@()')
[void]$R.Add('$must += @(Join-Path $ScriptsDir "verify_packet_v1.ps1")')
[void]$R.Add('$must += @(Join-Path $ScriptsDir "selftest_verify_packet_v1.ps1")')
[void]$R.Add('$must += @(Join-Path $ScriptsDir "selftest_vectors_v1.ps1")')
[void]$R.Add('$must += @(Join-Path $ScriptsDir "_selftest_nfl_tier0_v2.ps1")')
[void]$R.Add('$libs=@(Get-ChildItem -LiteralPath $ScriptsDir -File -Filter "lib_*.ps1" -ErrorAction SilentlyContinue | Sort-Object FullName)')
[void]$R.Add('foreach($lf in $libs){ $must += @($lf.FullName) }')
[void]$R.Add('foreach($mf in $must){ if(-not (Test-Path -LiteralPath $mf -PathType Leaf)){ throw ("PARSEGATE_REQUIRED_MISSING: " + $mf) }; ParseGateFile $mf }')
[void]$R.Add('Write-Output "PARSE_GATE_OK"'))
[void]$R.Add('')
[void]$R.Add('$stamp=(Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")')
[void]$R.Add('$bundle=Join-Path $RcptRoot $stamp')
[void]$R.Add('EnsureDir $bundle')
[void]$R.Add('$out1=Join-Path $bundle "selftest_verify_packet.stdout.txt"')
[void]$R.Add('$err1=Join-Path $bundle "selftest_verify_packet.stderr.txt"')
[void]$R.Add('$out2=Join-Path $bundle "selftest_vectors.stdout.txt"')
[void]$R.Add('$err2=Join-Path $bundle "selftest_vectors.stderr.txt"')
[void]$R.Add('$PSExe=(Get-Command powershell.exe -ErrorAction Stop).Source')
[void]$R.Add('$st1=Join-Path $ScriptsDir "selftest_verify_packet_v1.ps1"')
[void]$R.Add('$st2=Join-Path $ScriptsDir "selftest_vectors_v1.ps1"')
[void]$R.Add('$r1=RunChild $PSExe $st1 $RepoRoot $out1 $err1')
[void]$R.Add('if($r1.exit -ne 0){ Write-Output ("SELFTEST_VERIFY_PACKET_EXIT=" + $r1.exit); throw "SELFTEST_VERIFY_PACKET_FAILED" }')
[void]$R.Add('AssertContains $r1.stdout "VERIFY_SELFTEST_OK" "SELFTEST_VERIFY_PACKET_BAD_STDOUT"'))
[void]$R.Add('$r2=RunChild $PSExe $st2 $RepoRoot $out2 $err2')
[void]$R.Add('if($r2.exit -ne 0){ Write-Output ("SELFTEST_VECTORS_EXIT=" + $r2.exit); throw "SELFTEST_VECTORS_FAILED" }')
[void]$R.Add('AssertContains $r2.stdout "VECTORS_SELFTEST_OK" "SELFTEST_VECTORS_BAD_STDOUT"'))
[void]$R.Add('$expected=@("NFL_VERIFY_FAIL:SHA256_MISMATCH","NFL_VERIFY_FAIL:MISSING_SIG","NFL_VERIFY_FAIL:SIG_VERIFY_FAIL","NFL_VERIFY_FAIL:MISSING_SHA256SUMS","NFL_VERIFY_FAIL:BAD_SHA256SUM_LINE","NFL_VERIFY_FAIL:TRAVERSAL_PATH","NFL_VERIFY_FAIL:MISSING_TARGET")'))
[void]$R.Add('AssertAnyTokenExact $r2.stdout $expected "ERROR_TAXONOMY_NOT_EMITTED"'))
[void]$R.Add('$rcpt=Join-Path $bundle "nfl.tier0.selftest.v1.ndjson"'))
[void]$R.Add('$line=("{" + '"type":"nfl.tier0.selftest.v1",' + '"utc":"' + (JsonEsc $stamp) + '",' + '"ok":true,' + '"repo_root":"' + (JsonEsc $RepoRoot) + '",' + '"bundle_dir":"' + (JsonEsc $bundle) + '",' + '"selftest_verify_exit":' + $r1.exit + ',' + '"selftest_vectors_exit":' + $r2.exit + "}")'))
[void]$R.Add('WriteUtf8NoBomLf $rcpt ($line + "`n")'))
[void]$R.Add('$files=@(Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName)'))
[void]$R.Add('$abs=New-Object System.Collections.Generic.List[string]'))
[void]$R.Add('foreach($ff in $files){ [void]$abs.Add($ff.FullName) }'))
[void]$R.Add('$sum=Join-Path $bundle "sha256sums.txt"'))
[void]$R.Add('WriteSha256Sums $bundle $sum ($abs.ToArray())'))
[void]$R.Add('Write-Output "NFL_TIER0_SELFTEST_OK"'))
[void]$R.Add('Write-Output ("BUNDLE_DIR=" + $bundle)'))

$runnerText = (@($R.ToArray()) -join "`n") + "`n"
WriteUtf8NoBomLf $OutRunner $runnerText
ParseGateFile $OutRunner
Write-Output ("PATCH_OK wrote=" + $OutRunner)
if($bak){ Write-Output ("BACKUP=" + $bak) }
