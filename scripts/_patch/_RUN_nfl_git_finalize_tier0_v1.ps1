param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$m){ throw ("NFL_GIT_FINALIZE_FAIL: " + $m) }
function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function WriteUtf8NoBomLfText([string]$p,[string]$text){ $dir = Split-Path -Parent $p; if($dir){ EnsureDir $dir }; $u = NormalizeLf $text; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Set-Location $RepoRoot

# --- sanity ---
$Need = @(
  (Join-Path $RepoRoot "docs\NFL_TIER0_LOCK.md"),
  (Join-Path $RepoRoot "docs\NFL_CANONICAL_STATUS.md"),
  (Join-Path $RepoRoot "scripts\verify_packet_v1.ps1"),
  (Join-Path $RepoRoot "scripts\selftest_verify_packet_v1.ps1"),
  (Join-Path $RepoRoot "scripts\selftest_vectors_v1.ps1"),
  (Join-Path $RepoRoot "scripts\_selftest_nfl_tier0_v2.ps1"),
  (Join-Path $RepoRoot "test_vectors\tier0_frozen\nfl_tier0_green_20260307")
)
foreach($p in $Need){ if(-not (Test-Path -LiteralPath $p)){ Die ("MISSING_REQUIRED: " + $p) } }

# --- init git if missing ---
if(-not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git") -PathType Container)){
  git init | Out-Host
  if($LASTEXITCODE -ne 0){ Die "GIT_INIT_FAILED" }
}

# --- local deterministic git config ---
git config --local core.longpaths true
if($LASTEXITCODE -ne 0){ Die "SET_CORE_LONGPATHS_FAILED" }
git config --local core.autocrlf false
if($LASTEXITCODE -ne 0){ Die "SET_AUTOCRLF_FAILED" }
git config --local core.filemode false
if($LASTEXITCODE -ne 0){ Die "SET_FILEMODE_FAILED" }
git branch -M main | Out-Host
if($LASTEXITCODE -ne 0){ Die "BRANCH_MAIN_FAILED" }

# --- local identity if absent ---
$name = git config --local user.name
if($LASTEXITCODE -ne 0){ $name = $null }
$mail = git config --local user.email
if($LASTEXITCODE -ne 0){ $mail = $null }
if([string]::IsNullOrWhiteSpace([string]$name)){
  git config --local user.name "ScrappyHub"
  if($LASTEXITCODE -ne 0){ Die "SET_USER_NAME_FAILED" }
}
if([string]::IsNullOrWhiteSpace([string]$mail)){
  git config --local user.email "58554648+ScrappyHub@users.noreply.github.com"
  if($LASTEXITCODE -ne 0){ Die "SET_USER_EMAIL_FAILED" }
}

# --- set origin to actual repo ---
$originUrl = "https://github.com/ScrappyHub/Never-Forgetting-Ledger.git"
$remotes = @(git remote)
if($LASTEXITCODE -ne 0){ Die "REMOTE_LIST_FAILED" }
$hasOrigin = $false
foreach($r in @(@($remotes))){ if([string]$r -eq "origin"){ $hasOrigin = $true } }
if($hasOrigin){
  git remote set-url origin $originUrl | Out-Host
  if($LASTEXITCODE -ne 0){ Die "REMOTE_SETURL_FAILED" }
} else {
  git remote add origin $originUrl | Out-Host
  if($LASTEXITCODE -ne 0){ Die "REMOTE_ADD_FAILED" }
}

# --- .gitignore for bounded repo hygiene ---
$GitIgnore = Join-Path $RepoRoot ".gitignore"
$IgnoreText = @'
# NFL repo hygiene
*.bak_*
scripts/_scratch/
proofs/_tmp/
'@
WriteUtf8NoBomLfText $GitIgnore $IgnoreText

# --- clear failed stage state from previous attempts ---
git reset | Out-Host
if($LASTEXITCODE -ne 0){ Die "GIT_RESET_FAILED" }

# --- stage ONLY canonical repo surface ---
$Stage = @(
  ".gitignore",
  "docs",
  "proofs",
  "scripts",
  "test_vectors"
)
foreach($item in $Stage){
  git add -- $item | Out-Host
  if($LASTEXITCODE -ne 0){ Die ("GIT_ADD_FAILED: " + $item) }
}

$staged = @(git status --short)
if($LASTEXITCODE -ne 0){ Die "STATUS_AFTER_ADD_FAILED" }
if(@(@($staged)).Count -lt 1){ Die "NOTHING_STAGED" }

# --- commit ---
$commitMsg = "NFL: freeze Tier-0 green state, lock canonical bundle, docs, and frozen evidence"
git commit -m $commitMsg | Out-Host
if($LASTEXITCODE -ne 0){ Die "GIT_COMMIT_FAILED" }

# --- tag ---
$tagName = "nfl-tier0-green-20260307"
$tagExisting = @(git tag --list $tagName)
if($LASTEXITCODE -ne 0){ Die "GIT_TAG_LIST_FAILED" }
$tagExists = $false
foreach($t in @(@($tagExisting))){ if([string]$t -eq $tagName){ $tagExists = $true } }
if(-not $tagExists){
  git tag -a $tagName -m "NFL Tier-0 frozen green state" | Out-Host
  if($LASTEXITCODE -ne 0){ Die "GIT_TAG_CREATE_FAILED" }
}

# --- push main + tag ---
git push -u origin main | Out-Host
if($LASTEXITCODE -ne 0){ Die "GIT_PUSH_MAIN_FAILED" }
git push origin nfl-tier0-green-20260307 | Out-Host
if($LASTEXITCODE -ne 0){ Die "GIT_PUSH_TAG_FAILED" }

git status --short | Out-Host
if($LASTEXITCODE -ne 0){ Die "FINAL_STATUS_FAILED" }
git log --oneline -n 3 | Out-Host
if($LASTEXITCODE -ne 0){ Die "FINAL_LOG_FAILED" }
git tag --list "nfl-tier0-green-20260307" | Out-Host
if($LASTEXITCODE -ne 0){ Die "FINAL_TAG_SHOW_FAILED" }

Write-Host "NFL_GIT_FINALIZE_OK" -ForegroundColor Green
Write-Host ("REMOTE=https://github.com/ScrappyHub/Never-Forgetting-Ledger.git") -ForegroundColor Green
Write-Host ("TAG=nfl-tier0-green-20260307") -ForegroundColor Green
