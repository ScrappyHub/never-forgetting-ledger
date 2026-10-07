param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][string]$Prefix = "http://127.0.0.1:8086/",
  [Parameter(Mandatory=$false)][int]$DefaultLimit = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Only localhost origins (or no Origin header at all, i.e. curl/PowerShell) are allowed.
# A browser always sends Origin on cross-origin requests, so this blocks hostile web
# pages from driving the mutating endpoints (/commit, /ingest/control) while the API runs.
function Test-LocalOrigin([string]$origin){
  if([string]::IsNullOrEmpty($origin)){ return $true }
  return ($origin -match '^https?://(127\.0\.0\.1|localhost)(:\d+)?$')
}

function Json($res,$obj,[string]$allowOrigin,[int]$status = 200){
  $json = $obj | ConvertTo-Json -Compress -Depth 20
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")

  if(-not [string]::IsNullOrEmpty($allowOrigin)){
    $res.Headers["Access-Control-Allow-Origin"] = $allowOrigin
    $res.Headers["Vary"] = "Origin"
    $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
  }
  $res.StatusCode = $status
  $res.ContentType = "application/json; charset=utf-8"
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes,0,$bytes.Length)
  $res.OutputStream.Close()
}

# Read only the last $Limit non-blank NDJSON records (bounded memory; -Tail avoids
# loading the whole file). Returns newest-last; caller reverses if it wants newest-first.
function Read-NdjsonTail($Path,[int]$Limit){
  $items = @()
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    $lines = Get-Content -LiteralPath $Path -Tail $Limit -Encoding UTF8
    $items = @($lines |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json })
  }
  return @($items)
}

function Get-Limit($req,[int]$fallback){
  $q = [string]$req.QueryString["limit"]
  $n = 0
  if([int]::TryParse($q,[ref]$n) -and $n -gt 0 -and $n -le 100000){ return $n }
  return $fallback
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if(-not $Prefix.EndsWith("/")){
  $Prefix += "/"
}

$listener = New-Object System.Net.HttpListener
[void]$listener.Prefixes.Add($Prefix)
$listener.Start()

Write-Output "NFL_API_LISTENING"
Write-Output ("PREFIX=" + $Prefix)

try {
  while($listener.IsListening){
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    try {
      $path = $req.Url.AbsolutePath
      $method = $req.HttpMethod.ToUpperInvariant()
      $origin = [string]$req.Headers["Origin"]

      # Origin guard: reject any request that carries a non-local Origin header.
      if(-not (Test-LocalOrigin $origin)){
        Json $res @{ status = "FORBIDDEN"; message = "cross-origin request rejected" } "" 403
        continue
      }
      $allow = if([string]::IsNullOrEmpty($origin)){ "" } else { $origin }

      if($method -eq "OPTIONS"){
        Json $res @{ status = "OK" } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/"){
        Json $res @{
          status = "OK"
          service = "nfl.api.v1"
          message = "Never Forgetting Ledger API"
          health = "/health"
          recent = "/recent"
          ingest_last_run = "/ingest/last-run"
          ingest_runs = "/ingest/runs"
          ingest_state = "/ingest/state"
          ingest_failures = "/ingest/failures"
        } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/health"){
        Json $res @{
          status = "OK"
          service = "nfl.api.v1"
          repo_root = $RepoRoot
          prefix = $Prefix
        } $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/commit"){
        $reader = New-Object IO.StreamReader($req.InputStream)
        try {
          $raw = $reader.ReadToEnd()
        } finally {
          $reader.Dispose()
        }

        if([string]::IsNullOrWhiteSpace($raw)){
          throw "EMPTY_BODY"
        }

        $body = $raw | ConvertFrom-Json

        $hash = [string]$body.hash
        if([string]::IsNullOrWhiteSpace($hash)){
          throw "MISSING_HASH"
        }

        $row = [ordered]@{
          schema = "nfl.ledger.commit.v2"
          hash = $hash.ToLowerInvariant()
          artifact = [string]$body.artifact
          timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
          source_repo = [string]$body.source_repo
          source_repo_path = [string]$body.source_repo_path
          branch = [string]$body.branch
          commit_hash = [string]$body.commit_hash
          remote = [string]$body.remote
          event_type = [string]$body.event_type
        }

        # Clean single-line NDJSON append (no BOM, LF terminator, no blank lines).
        $p = Join-Path $RepoRoot "data\ledger.ndjson"
        $line = ($row | ConvertTo-Json -Compress -Depth 20) + "`n"
        [System.IO.File]::AppendAllText($p, $line, [Text.UTF8Encoding]::new($false))

        Json $res @{
          status = "COMMIT_OK"
          item = $row
        } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/recent"){
        $p = Join-Path $RepoRoot "data\ledger.ndjson"
        $limit = Get-Limit $req $DefaultLimit
        $items = Read-NdjsonTail $p $limit

        $sourceRepo = [string]$req.QueryString["source_repo"]
        if(-not [string]::IsNullOrWhiteSpace($sourceRepo)){
          $items = @($items | Where-Object { [string]$_.source_repo -eq $sourceRepo })
        }

        [array]::Reverse($items)
        Json $res @{
          status = "OK"
          count = $items.Count
          limit = $limit
          items = @($items)
        } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/last-run"){
        $p = Join-Path $RepoRoot "runtime\ingest\last_run.json"
        if(Test-Path -LiteralPath $p -PathType Leaf){
          Json $res @{
            status = "OK"
            item = (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
          } $allow
        } else {
          Json $res @{ status = "OK"; item = $null } $allow
        }
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/runs"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_runs.ndjson"
        $limit = Get-Limit $req $DefaultLimit
        $items = Read-NdjsonTail $p $limit
        [array]::Reverse($items)
        Json $res @{ status = "OK"; count = $items.Count; limit = $limit; items = @($items) } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/state"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_state.ndjson"
        $limit = Get-Limit $req $DefaultLimit
        $items = Read-NdjsonTail $p $limit
        [array]::Reverse($items)
        Json $res @{ status = "OK"; count = $items.Count; limit = $limit; items = @($items) } $allow
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/failures"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_state.ndjson"
        $limit = Get-Limit $req $DefaultLimit
        $items = @(Read-NdjsonTail $p $limit | Where-Object {
          ($_.ok -eq $false) -or
          ([string]$_.stderr -match "FAIL|ERROR|CPR_VERIFY_NOT_GREEN|NFL_VERIFY_FAIL")
        })
        [array]::Reverse($items)
        Json $res @{ status = "OK"; count = $items.Count; limit = $limit; items = @($items) } $allow
        continue
      }

      if($method -eq "POST" -and $path -eq "/ingest/control"){
        $reader = New-Object IO.StreamReader($req.InputStream)
        try {
          $raw = $reader.ReadToEnd()
        } finally {
          $reader.Dispose()
        }

        if([string]::IsNullOrWhiteSpace($raw)){
          throw "EMPTY_BODY"
        }

        $body = $raw | ConvertFrom-Json
        $action = [string]$body.action

        if($action -notin @("status","run-once","start","stop")){
          throw ("BAD_ACTION:" + $action)
        }

        $script = Join-Path $RepoRoot "scripts\nfl_ingest_control_v1.ps1"
        if(-not (Test-Path -LiteralPath $script -PathType Leaf)){
          throw ("CONTROL_SCRIPT_MISSING:" + $script)
        }

        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action $action 2>&1

        Json $res @{
          status = "OK"
          action = $action
          output = ($out -join "`n")
        } $allow
        continue
      }

      Json $res @{
        status = "NOT_FOUND"
        message = "endpoint not found"
        path = $path
      } $allow 404
    } catch {
      Json $res @{
        status = "ERROR"
        message = [string]$_.Exception.Message
      } "" 400
    }
  }
}
finally {
  if($listener.IsListening){
    $listener.Stop()
  }
  $listener.Close()
}
