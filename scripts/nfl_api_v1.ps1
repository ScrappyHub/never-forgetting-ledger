param(
  [Parameter(Mandatory=$false)][string]$RepoRoot = ".",
  [Parameter(Mandatory=$false)][string]$Prefix = "http://127.0.0.1:8086/"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Json($res,$obj){
  $json = $obj | ConvertTo-Json -Compress -Depth 20
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")

  $res.Headers["Access-Control-Allow-Origin"] = "*"
  $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
  $res.ContentType = "application/json; charset=utf-8"
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes,0,$bytes.Length)
  $res.OutputStream.Close()
}

function Read-Ndjson($Path){
  $items = @()
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    $items = Get-Content -LiteralPath $Path |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_ | ConvertFrom-Json }
  }
  return @($items)
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

      if($method -eq "OPTIONS"){
        Json $res @{ status = "OK" }
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
        }
        continue
      }
if($method -eq "GET" -and $path -eq "/health"){
        Json $res @{
          status = "OK"
          service = "nfl.api.v1"
          repo_root = $RepoRoot
          prefix = $Prefix
        }
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

        $p = Join-Path $RepoRoot "data\ledger.ndjson"

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

        $line = $row | ConvertTo-Json -Compress -Depth 20
        Add-Content -LiteralPath $p -Value $line -Encoding UTF8

        Json $res @{
          status = "COMMIT_OK"
          item = $row
        }
        continue
      }
      if($method -eq "GET" -and $path -eq "/recent"){
        $p = Join-Path $RepoRoot "data\ledger.ndjson"
        $items = Read-Ndjson $p

        $sourceRepo = [string]$req.QueryString["source_repo"]
        if(-not [string]::IsNullOrWhiteSpace($sourceRepo)){
          $items = @($items | Where-Object { [string]$_.source_repo -eq $sourceRepo })
        }

        [array]::Reverse($items)
        Json $res @{
          status = "OK"
          count = $items.Count
          items = @($items)
        }
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/last-run"){
        $p = Join-Path $RepoRoot "runtime\ingest\last_run.json"
        if(Test-Path -LiteralPath $p -PathType Leaf){
          Json $res @{
            status = "OK"
            item = (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
          }
        } else {
          Json $res @{ status = "OK"; item = $null }
        }
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/runs"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_runs.ndjson"
        $items = Read-Ndjson $p
        [array]::Reverse($items)
        Json $res @{ status = "OK"; items = @($items) }
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/state"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_state.ndjson"
        $items = Read-Ndjson $p
        [array]::Reverse($items)
        Json $res @{ status = "OK"; items = @($items) }
        continue
      }

      if($method -eq "GET" -and $path -eq "/ingest/failures"){
        $p = Join-Path $RepoRoot "proofs\receipts\nfl_ingest_state.ndjson"
        $items = @(Read-Ndjson $p | Where-Object {
          ($_.ok -eq $false) -or
          ([string]$_.stderr -match "FAIL|ERROR|CPR_VERIFY_NOT_GREEN|NFL_VERIFY_FAIL")
        })
        [array]::Reverse($items)
        Json $res @{ status = "OK"; items = @($items) }
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
        }
        continue
      }

      Json $res @{
        status = "NOT_FOUND"
        message = "endpoint not found"
        path = $path
      }
    } catch {
      Json $res @{
        status = "ERROR"
        message = [string]$_.Exception.Message
      }
    }
  }
}
finally {
  if($listener.IsListening){
    $listener.Stop()
  }
  $listener.Close()
}