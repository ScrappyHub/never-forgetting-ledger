param([Parameter(Mandatory=$true)][string]$RepoRoot)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { Die ("RepoRoot not found: " + $RepoRoot) }

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Host ("REPO: " + $root)
Write-Host ""

# Targets: scripts + docs + root ps1/md/json/yml
$includeExt = @(".ps1",".psm1",".psd1",".md",".txt",".json",".yml",".yaml")
$files = @(@(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop | Where-Object {
  $e = [string]$_.Extension
  $includeExt -contains $e
}))

if ($files.Count -eq 0) { Die "No files found to scan." }

# Patterns that indicate "this is the signing surface"
$patterns = @(
  "ssh-keygen",
  "ssh-keygen.exe",
  " -Y sign",
  " -Y verify",
  "allowed_signers",
  "trust_bundle.json",
  "sign_file_v1",
  "verify_sig_v1",
  "make_allowed_signers",
  "id_ed25519",
  ".ssh\",
  "nfl-local_ed25519",
  "ed25519",
  "principal",
  "allowed namespaces",
  "namespace",
  "Sign",
  "Verify"
)

# Scan
$hits = New-Object System.Collections.Generic.List[object]
foreach($f in $files){
  $path = $f.FullName
  $txt = $null
  try { $txt = Get-Content -Raw -LiteralPath $path -Encoding UTF8 -ErrorAction Stop } catch { continue }
  if ([string]::IsNullOrEmpty($txt)) { continue }

  foreach($pat in @(@($patterns))){
    if ($txt -match [regex]::Escape($pat)) {
      # Collect matching lines (cheap, deterministic)
      $lines = @(@($txt -split "`n"))
      for($i=0; $i -lt $lines.Count; $i++){
        $line = $lines[$i]
        if ($line -match [regex]::Escape($pat)) {
          $hits.Add([pscustomobject]@{
            File = $path
            Line = ($i+1)
            Pattern = $pat
            Text = $line.TrimEnd()
          }) | Out-Null
        }
      }
    }
  }
}

if ($hits.Count -eq 0) {
  Write-Host "NO_HITS: No obvious signing/verifying/key references found."
  Write-Host "If you expected hits, your signing may be in a non-UTF8 file type, or generated at runtime."
  return
}

# Rank files by hit count
$byFile = @(@($hits | Group-Object File | Sort-Object Count -Descending))

Write-Host ("HIT_FILES: " + $byFile.Count)
Write-Host ""

$topN = 15
$shown = 0
foreach($g in $byFile){
  $shown++
  if ($shown -gt $topN) { break }
  Write-Host ("--- FILE (" + $g.Count + " hits): " + $g.Name)
  $rows = @(@($hits | Where-Object { $_.File -eq $g.Name } | Sort-Object Line,Pattern | Select-Object -First 40))
  foreach($r in $rows){
    Write-Host ("{0:D5} [{1}] {2}" -f $r.Line, $r.Pattern, $r.Text)
  }
  Write-Host ""
}

Write-Host "NEXT:"
Write-Host "1) Pick the top file above that contains the actual 'ssh-keygen -Y sign' or calls sign_file_v1.ps1."
Write-Host "2) We'll patch that script to hard-bind to proofs\keys\nfl-local_ed25519 and add a selftest."
Write-Host ""
Write-Host "PASS: NFL SIGNING SURFACE AUDIT v1"