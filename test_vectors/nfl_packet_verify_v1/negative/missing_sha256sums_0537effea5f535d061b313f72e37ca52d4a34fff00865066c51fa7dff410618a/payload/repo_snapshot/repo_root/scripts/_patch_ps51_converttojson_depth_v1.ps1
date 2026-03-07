param(
  [Parameter(Mandatory=$true)][string]$TargetPath
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function ReadUtf8NoBom([string]$p){
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("MISSING_FILE: " + $p) }
  [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}

function WriteUtf8NoBomLf([string]$p, [string]$t){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = $t.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  [System.IO.File]::WriteAllText($p, $t, $enc)
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("WRITE_FAILED: " + $p) }
}

function ParseGate([string]$p){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { Die ("PARSE_ERROR: " + $errs[0].Message + " (file: " + $p + ")") }
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }

$src = ReadUtf8NoBom $TargetPath

# Patch ONLY the ConvertTo-Json depth line inside CanonJson:
#   ConvertTo-Json -Depth 200 -Compress  -> ConvertTo-Json -Depth 99 -Compress
# (PS5.1 maximum is 100; we stay below it deterministically.)
$old = 'ConvertTo-Json -Depth 200 -Compress'
$new = 'ConvertTo-Json -Depth 99 -Compress'

if ($src -notmatch [regex]::Escape($old)) {
  Die ("PATCH_PATTERN_NOT_FOUND: expected '" + $old + "' in " + $TargetPath)
}

$dst = $src.Replace($old, $new)

# Sanity: ensure replacement happened exactly at least once
if ($dst -notmatch [regex]::Escape($new)) { Die "PATCH_FAILED: replacement did not apply" }

WriteUtf8NoBomLf $TargetPath $dst

# Parse-gate in current host
ParseGate $TargetPath

Write-Host ("PATCH_OK: " + $TargetPath) -ForegroundColor Green