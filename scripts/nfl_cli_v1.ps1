param(
  [Parameter(Mandatory=$true,Position=0)]
  [ValidateSet("commit","lookup","verify")]
  [string]$Command,

  [string]$Hash,
  [string]$Artifact,
  [string]$File
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("NFL_CLI_FAIL:" + $m)
}

function Utf8NoBom(){
  New-Object System.Text.UTF8Encoding($false)
}

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
}

function Sha256File([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("FILE_NOT_FOUND:" + $Path)
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$RepoRoot = (Resolve-Path -LiteralPath ".").Path
$DataDir  = Join-Path $RepoRoot "data"
$Ledger   = Join-Path $DataDir "ledger.ndjson"

EnsureDir $DataDir

# initialize ledger if missing
if(-not (Test-Path -LiteralPath $Ledger -PathType Leaf)){
  WriteUtf8NoBomLfText $Ledger ""
}

# -------------------------------------------------
# COMMIT
# -------------------------------------------------
if($Command -eq "commit"){

  if([string]::IsNullOrWhiteSpace($Hash)){
    Fail "MISSING_HASH"
  }

  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

  $obj = [ordered]@{
    hash = $Hash.ToLowerInvariant()
    artifact = $Artifact
    timestamp = $ts
  }

  $line = ($obj | ConvertTo-Json -Compress)
  Add-Content -LiteralPath $Ledger -Value ($line + "`n") -Encoding UTF8

  Write-Output "COMMIT_OK"
  Write-Output ("HASH=" + $obj.hash)
  Write-Output ("TIMESTAMP=" + $ts)
  exit 0
}

# -------------------------------------------------
# LOOKUP
# -------------------------------------------------
if($Command -eq "lookup"){

  if([string]::IsNullOrWhiteSpace($Hash)){
    Fail "MISSING_HASH"
  }

  $h = $Hash.ToLowerInvariant()
  $lines = Get-Content -LiteralPath $Ledger -Encoding UTF8

  foreach($l in @(@($lines))){
    if([string]::IsNullOrWhiteSpace($l)){ continue }
    $o = $l | ConvertFrom-Json
    if($o.hash -eq $h){
      Write-Output "FOUND"
      Write-Output ("HASH=" + $o.hash)
      Write-Output ("TIMESTAMP=" + $o.timestamp)
      Write-Output ("ARTIFACT=" + $o.artifact)
      exit 0
    }
  }

  Write-Output "NOT_FOUND"
  exit 0
}

# -------------------------------------------------
# VERIFY
# -------------------------------------------------
if($Command -eq "verify"){

  if([string]::IsNullOrWhiteSpace($File)){
    Fail "MISSING_FILE"
  }

  $h = Sha256File $File

  Write-Output ("HASH=" + $h)

  $lines = Get-Content -LiteralPath $Ledger -Encoding UTF8

  foreach($l in @(@($lines))){
    if([string]::IsNullOrWhiteSpace($l)){ continue }
    $o = $l | ConvertFrom-Json
    if($o.hash -eq $h){
      Write-Output "VERIFIED"
      Write-Output ("TIMESTAMP=" + $o.timestamp)
      exit 0
    }
  }

  Write-Output "NOT_FOUND"
  exit 0
}

Fail "UNKNOWN_COMMAND"