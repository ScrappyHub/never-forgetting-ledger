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

# Fix A: Quote-Arg return "" inside single-quoted Add-lines

# Fix B: -match '[\s"]' inside single-quoted Add-lines. Avoid literal " by using \x22.

Write-Utf8NoBomLf -Path $RunnerOut -Text $txt
Parse-GateFile $RunnerOut
Write-Output ("WROTE: " + $RunnerOut)
Write-Output "OK: patched + parse-gated"
