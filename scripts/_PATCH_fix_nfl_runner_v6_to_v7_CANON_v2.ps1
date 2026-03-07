param([Parameter(Mandatory=$true)][string]$RunnerIn,[Parameter(Mandatory=$true)][string]$RunnerOut)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
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

if (-not (Test-Path -LiteralPath $RunnerIn -PathType Leaf)) { Die ("Missing input runner: " + $RunnerIn) }
$txt = Get-Content -Raw -LiteralPath $RunnerIn -Encoding UTF8

$sq = [char]39
$dq = [char]34

$needle1 = "[void]$" + "sign.Add(" + $sq + "  if ($null -eq $x) { return " + $sq + $dq + $dq + $sq + " }" + $sq + ")"
$fixed1  = "[void]$" + "sign.Add(" + $sq + "  if ($null -eq $x) { return " + $sq + $sq + $dq + $dq + $sq + $sq + " }" + $sq + ")"
$txt = $txt.Replace($needle1, $fixed1)

$needle2 = "[void]$" + "sign.Add(" + $sq + "  if ($x -eq " + $dq + $dq + ")    { return " + $sq + $dq + $dq + $sq + " }" + $sq + ")"
$fixed2  = "[void]$" + "sign.Add(" + $sq + "  if ($x -eq " + $dq + $dq + ")    { return " + $sq + $sq + $dq + $dq + $sq + $sq + " }" + $sq + ")"
$txt = $txt.Replace($needle2, $fixed2)

$needle3 = "[void]$" + "sign.Add(" + $sq + "  if ($x -match " + $sq + "[\s" + $dq + "]" + $sq + ") { return " + $sq + $dq + $sq + " + ($x -replace " + $sq + $dq + $sq + "," + $sq + "\" + $dq + $sq + ") + " + $sq + $dq + $sq + " }" + $sq + ")"
$fixed3  = "[void]$" + "sign.Add(" + $sq + "  if ($x -match " + $sq + $sq + "[\s\x22]" + $sq + $sq + ") { return " + $sq + $sq + $dq + $sq + $sq + " + ($x -replace " + $sq + $sq + $dq + $sq + $sq + "," + $sq + $sq + "\" + $dq + $sq + $sq + ") + " + $sq + $sq + $dq + $sq + $sq + " }" + $sq + ")"
$txt = $txt.Replace($needle3, $fixed3)

Write-Utf8NoBomLf -Path $RunnerOut -Text $txt
Parse-GateFile $RunnerOut
Write-Output ("WROTE: " + $RunnerOut)
Write-Output "OK: patched + parse-gated"
