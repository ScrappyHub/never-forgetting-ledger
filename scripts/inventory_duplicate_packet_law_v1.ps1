param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
  $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

$ReportPath = Join-Path $RepoRoot "proofs\packet_law_inventory.txt"
$Needles = @(
  "sha256sums",
  "packet_id",
  "manifest.json",
  "Get-FileHash",
  "SHA256",
  "ConvertFrom-Json",
  "ConvertTo-Json"
)

$Lines = New-Object System.Collections.Generic.List[string]
[void]$Lines.Add("NFL PACKET LAW INVENTORY")
[void]$Lines.Add("RepoRoot: " + $RepoRoot)
[void]$Lines.Add("")

$Files = Get-ChildItem -LiteralPath (Join-Path $RepoRoot "scripts") -File -Filter *.ps1 -Recurse | Sort-Object FullName
foreach ($File in $Files) {
  $Text = [System.IO.File]::ReadAllText($File.FullName)
  $Matched = New-Object System.Collections.Generic.List[string]
  foreach ($Needle in $Needles) {
    if ($Text -match [regex]::Escape($Needle)) {
      [void]$Matched.Add($Needle)
    }
  }
  if ($Matched.Count -gt 0) {
    [void]$Lines.Add($File.FullName)
    [void]$Lines.Add("  matches: " + (($Matched.ToArray()) -join ", "))
    [void]$Lines.Add("")
  }
}

$Enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ReportPath,(($Lines.ToArray()) -join "`n") + "`n",$Enc)

Write-Host ("INVENTORY_REPORT: " + $ReportPath) -ForegroundColor Gray
Write-Host "NFL_PACKET_LAW_INVENTORY_OK" -ForegroundColor Green
