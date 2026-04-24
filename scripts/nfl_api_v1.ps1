param(
  [Parameter(Mandatory=$false)][string]$Prefix = "http://127.0.0.1:8085/",
  [Parameter(Mandatory=$false)][string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("NFL_API_FAIL:" + $m)
}

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
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

function ReadUtf8([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("READ_MISSING:" + $Path)
  }
  return [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
}

function WriteUtf8NoBomLfText([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $u = NormalizeLf $Text
  [System.IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($u))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("WRITE_FAILED:" + $Path)
  }
}

function AppendUtf8NoBomLf([string]$Path,[string]$Line){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $t = NormalizeLf $Line
  [System.IO.File]::AppendAllText($Path,$t,(Utf8NoBom))
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("APPEND_FAILED:" + $Path)
  }
}

function ParseGateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("PARSEGATE_MISSING:" + $Path)
  }
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and @(@($err)).Count -gt 0){
    $m = ($err | Select-Object -First 12 | ForEach-Object { $_.ToString() }) -join " | "
    Fail ("PARSEGATE_FAIL:" + $Path + "::" + $m)
  }
}

function Sha256File([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("FILE_NOT_FOUND:" + $Path)
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function JsonResponseBytes([object]$obj){
  $json = ($obj | ConvertTo-Json -Compress -Depth 8)
  return (Utf8NoBom).GetBytes((NormalizeLf $json))
}

function ReadRequestBodyText([System.Net.HttpListenerRequest]$Request){
  $enc = $Request.ContentEncoding
  if($null -eq $enc){ $enc = Utf8NoBom }
  $sr = New-Object System.IO.StreamReader($Request.InputStream,$enc)
  try {
    return $sr.ReadToEnd()
  }
  finally {
    $sr.Dispose()
  }
}

function AddCorsHeaders([System.Net.HttpListenerResponse]$Response){
  $Response.Headers["Access-Control-Allow-Origin"] = "*"
  $Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  $Response.Headers["Access-Control-Allow-Headers"] = "Content-Type"
}

function WriteEmptyResponse([System.Net.HttpListenerResponse]$Response,[int]$StatusCode){
  AddCorsHeaders $Response
  $Response.StatusCode = $StatusCode
  $Response.ContentLength64 = 0
  $Response.OutputStream.Flush()
  $Response.OutputStream.Close()
}

function WriteJsonResponse([System.Net.HttpListenerResponse]$Response,[int]$StatusCode,[object]$obj){
  $bytes = JsonResponseBytes $obj
  AddCorsHeaders $Response
  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  $Response.ContentEncoding = Utf8NoBom
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes,0,$bytes.Length)
  $Response.OutputStream.Flush()
  $Response.OutputStream.Close()
}

function ReadLedgerObjects([string]$LedgerPath){
  $out = New-Object System.Collections.Generic.List[object]
  if(-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)){
    return @($out.ToArray())
  }
  $lines = Get-Content -LiteralPath $LedgerPath -Encoding UTF8
  foreach($l in @(@($lines))){
    if([string]::IsNullOrWhiteSpace($l)){ continue }
    $o = $l | ConvertFrom-Json -ErrorAction Stop
    [void]$out.Add($o)
  }
  return @($out.ToArray())
}

function CommitHash([string]$LedgerPath,[string]$Hash,[string]$Artifact){
  if([string]::IsNullOrWhiteSpace($Hash)){ Fail "MISSING_HASH" }
  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $obj = [ordered]@{
    hash = $Hash.ToLowerInvariant()
    artifact = $Artifact
    timestamp = $ts
  }
  $line = ($obj | ConvertTo-Json -Compress)
  AppendUtf8NoBomLf $LedgerPath $line
  return $obj
}

function LookupHash([string]$LedgerPath,[string]$Hash){
  if([string]::IsNullOrWhiteSpace($Hash)){ Fail "MISSING_HASH" }
  $h = $Hash.ToLowerInvariant()
  $rows = ReadLedgerObjects $LedgerPath
  foreach($o in @(@($rows))){
    if($null -eq $o){ continue }
    if(([string]$o.hash).ToLowerInvariant() -eq $h){
      return $o
    }
  }
  return $null
}

function GetRecentCommits([string]$LedgerPath,[int]$Limit){
  if($Limit -lt 1){ $Limit = 20 }
  $rows = ReadLedgerObjects $LedgerPath
  $arr = @(@($rows))
  $count = $arr.Count
  if($count -le 0){ return @() }

  $start = $count - $Limit
  if($start -lt 0){ $start = 0 }

  $slice = New-Object System.Collections.Generic.List[object]
  for($i = $count - 1; $i -ge $start; $i--){
    [void]$slice.Add($arr[$i])
  }
  return @($slice.ToArray())
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptPath = $MyInvocation.MyCommand.Path
ParseGateFile $ScriptPath

$ScriptsDir = Join-Path $RepoRoot "scripts"
$CliPath    = Join-Path $ScriptsDir "nfl_cli_v1.ps1"
ParseGateFile $CliPath

$DataDir    = Join-Path $RepoRoot "data"
$LedgerPath = Join-Path $DataDir "ledger.ndjson"
$AuditPath  = Join-Path $RepoRoot "proofs\receipts\nfl_api_v1.ndjson"

EnsureDir $DataDir
EnsureDir (Join-Path $RepoRoot "proofs")
EnsureDir (Join-Path $RepoRoot "proofs\receipts")

if(-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)){
  WriteUtf8NoBomLfText $LedgerPath ""
}

if(-not $Prefix.EndsWith("/")){
  $Prefix = $Prefix + "/"
}

$listener = New-Object System.Net.HttpListener
[void]$listener.Prefixes.Add($Prefix)

try {
  $listener.Start()
}
catch {
  Fail ("LISTENER_START_FAILED:" + $_.Exception.Message)
}

Write-Output "NFL_API_LISTENING"
Write-Output ("PREFIX=" + $Prefix)

try {
  while($listener.IsListening){
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    try {
      $path = $req.Url.AbsolutePath.TrimEnd("/")
      if([string]::IsNullOrWhiteSpace($path)){ $path = "/" }
      $method = $req.HttpMethod.ToUpperInvariant()

      if($method -eq "OPTIONS"){
        WriteEmptyResponse $res 204
        continue
      }

      if($method -eq "POST" -and $path -eq "/commit"){
        $body = ReadRequestBodyText $req
        if([string]::IsNullOrWhiteSpace($body)){ Fail "EMPTY_BODY" }
        $obj = $body | ConvertFrom-Json -ErrorAction Stop
        $hash = [string]$obj.hash
        $artifact = [string]$obj.artifact

        $committed = CommitHash $LedgerPath $hash $artifact

        $audit = [ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
          event = "nfl.api.commit.v1"
          hash = [string]$committed.hash
          artifact = [string]$committed.artifact
          remote = [string]$req.RemoteEndPoint
        }
        AppendUtf8NoBomLf $AuditPath (($audit | ConvertTo-Json -Compress))

        WriteJsonResponse $res 200 ([ordered]@{
          status = "COMMIT_OK"
          hash = [string]$committed.hash
          timestamp = [string]$committed.timestamp
          artifact = [string]$committed.artifact
        })
        continue
      }

      if($method -eq "GET" -and $path -eq "/lookup"){
        $hash = [string]$req.QueryString["hash"]
        if([string]::IsNullOrWhiteSpace($hash)){ Fail "MISSING_HASH" }

        $found = LookupHash $LedgerPath $hash

        $audit = [ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
          event = "nfl.api.lookup.v1"
          hash = $hash
          found = ($null -ne $found)
          remote = [string]$req.RemoteEndPoint
        }
        AppendUtf8NoBomLf $AuditPath (($audit | ConvertTo-Json -Compress))

        if($null -eq $found){
          WriteJsonResponse $res 200 ([ordered]@{
            status = "NOT_FOUND"
            hash = $hash.ToLowerInvariant()
          })
        } else {
          WriteJsonResponse $res 200 ([ordered]@{
            status = "FOUND"
            hash = [string]$found.hash
            timestamp = [string]$found.timestamp
            artifact = [string]$found.artifact
          })
        }
        continue
      }

      if($method -eq "GET" -and $path -eq "/recent"){
        $limitRaw = [string]$req.QueryString["limit"]
        $limit = 20
        if(-not [string]::IsNullOrWhiteSpace($limitRaw)){
          $parsed = 0
          if([int]::TryParse($limitRaw,[ref]$parsed)){
            $limit = $parsed
          }
        }

        $items = GetRecentCommits $LedgerPath $limit

        $audit = [ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
          event = "nfl.api.recent.v1"
          limit = $limit
          count = @(@($items)).Count
          remote = [string]$req.RemoteEndPoint
        }
        AppendUtf8NoBomLf $AuditPath (($audit | ConvertTo-Json -Compress))

        WriteJsonResponse $res 200 ([ordered]@{
          status = "OK"
          count = @(@($items)).Count
          items = @($items)
        })
        continue
      }

      if($method -eq "POST" -and $path -eq "/verify"){
        $body = ReadRequestBodyText $req
        if([string]::IsNullOrWhiteSpace($body)){ Fail "EMPTY_BODY" }
        $obj = $body | ConvertFrom-Json -ErrorAction Stop
        $file = [string]$obj.file
        if([string]::IsNullOrWhiteSpace($file)){ Fail "MISSING_FILE" }

        $hash = Sha256File $file
        $found = LookupHash $LedgerPath $hash

        $audit = [ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
          event = "nfl.api.verify.v1"
          hash = $hash
          file = $file
          found = ($null -ne $found)
          remote = [string]$req.RemoteEndPoint
        }
        AppendUtf8NoBomLf $AuditPath (($audit | ConvertTo-Json -Compress))

        if($null -eq $found){
          WriteJsonResponse $res 200 ([ordered]@{
            status = "NOT_FOUND"
            hash = $hash
            file = $file
          })
        } else {
          WriteJsonResponse $res 200 ([ordered]@{
            status = "VERIFIED"
            hash = $hash
            file = $file
            timestamp = [string]$found.timestamp
            artifact = [string]$found.artifact
          })
        }
        continue
      }

      WriteJsonResponse $res 404 ([ordered]@{
        status = "NOT_FOUND"
        message = "endpoint not found"
      })
    }
    catch {
      $msg = [string]$_.Exception.Message
      try {
        WriteJsonResponse $res 400 ([ordered]@{
          status = "ERROR"
          message = $msg
        })
      }
      catch {
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
