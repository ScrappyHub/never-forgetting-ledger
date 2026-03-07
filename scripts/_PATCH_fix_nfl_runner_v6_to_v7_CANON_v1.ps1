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

# Build patterns without literal quotes to avoid parser traps
$sq = [char]39   # single quote
$dq = [char]34   # double quote

# Fix 1: return '""' inside single-quoted Add-lines (broken: return '""')
$badReturn  = "return " + $sq + $dq + $dq + $sq
$goodReturn = "return " + $sq + $sq + $dq + $dq + $sq + $sq
$txt = $txt.Replace($badReturn, $goodReturn)

# Fix 2: -match '[\s"]' inside single-quoted Add-lines (broken: -match '[\s"]')
# Use \x22 instead of literal " to keep it deterministic and parse-safe everywhere
$badMatch  = "-match " + $sq + "[\s" + $dq + "]" + $sq
$goodMatch = "-match " + $sq + $sq + "[\s\x22]" + $sq + $sq
$txt = $txt.Replace($badMatch, $goodMatch)

Write-Utf8NoBomLf -Path $RunnerOut -Text $txt
Parse-GateFile $RunnerOut
Write-Output ("WROTE: " + $RunnerOut)
Write-Output "OK: patched + parse-gated"
