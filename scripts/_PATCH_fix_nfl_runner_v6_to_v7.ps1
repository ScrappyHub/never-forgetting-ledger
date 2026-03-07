param([Parameter(Mandatory=$true)][string]$RunnerIn,[Parameter(Mandatory=$true)][string]$RunnerOut)
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

if (-not (Test-Path -LiteralPath $RunnerIn -PathType Leaf)) { Die ("Missing input runner: " + $RunnerIn) }
$txt = Get-Content -Raw -LiteralPath $RunnerIn -Encoding UTF8

# Fix 1: inside [void]$sign.Add(' ... '), return '""' must be doubled as two single quotes
$txt = $txt.Replace("return '""""'","return '""""'")  # no-op if already correct
$txt = $txt.Replace("return ''""""''","return '""""'")

# Fix 2: regex literal in a single-quoted Add string must use doubled single quotes: -match '[\s"]'

# Actual needed replacement (from your v6): -match '[\s"]' appears as -match '[\s"]' only if correct; fix the broken one:

# Fix broken pattern specifically: -match '[\s"]' was written as -match '[\s"]'? If v6 has -match '[\s"]' without doubling, it looks like: -match '[\s"]' in file?
# More reliable: replace the exact broken fragment from your error line:

# Even more reliable: fix the two *known* broken Add-lines as raw text:
$txt = $txt.Replace("[void]$sign.Add('  if ($null -eq $x) { return ''""'' }')","[void]$sign.Add('  if ($null -eq $x) { return ''""""'' }')")
$txt = $txt.Replace("[void]$sign.Add('  if ($x -eq """")    { return ''""'' }')","[void]$sign.Add('  if ($x -eq """")    { return ''""""'' }')")

Write-Utf8NoBomLf -Path $RunnerOut -Text $txt
Parse-GateFile $RunnerOut
Write-Output ("WROTE: " + $RunnerOut)
Write-Output "OK: patched + parse-gated"
