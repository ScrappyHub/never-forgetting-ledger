$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteBytes([string]$path, [byte[]]$bytes){
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllBytes($path, $bytes)
  if (-not (Test-Path -LiteralPath $path)) { Die ("WRITE_FAILED: " + $path) }
}
function WriteUtf8NoBom([string]$path, [string]$content){
  $bytes = (Utf8NoBom).GetBytes($content)
  WriteBytes $path $bytes
}

$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Root)) { Die ("Repo root not found: " + $Root) }

$FnDir = Join-Path $Root "supabase\functions\gi-receipt-get"
$Good  = Join-Path $FnDir "index.ts"
$Bad   = Join-Path $FnDir "index..ts"

Write-Host "== LOCK gi-receipt-get (V3) ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor DarkGray
New-Item -ItemType Directory -Path $FnDir -Force | Out-Null

# 1) Delete accidental file
if (Test-Path -LiteralPath $Bad) {
  Remove-Item -LiteralPath $Bad -Force
  if (Test-Path -LiteralPath $Bad) { Die ("DELETE_FAILED: " + $Bad) }
  Write-Host ("DELETED: {0}" -f $Bad) -ForegroundColor Yellow
} else {
  Write-Host ("OK: no accidental file: {0}" -f $Bad) -ForegroundColor DarkGray
}

# 2) Write index.ts from Base64 (no here-strings, no prompt hijack)
$ts_b64 = @(
  "Ly8gR0lfUkVDRUlQVF9HRVRfTE9DS19WMwovLyBkZW5vLWxpbnQtaWdub3JlLWZpbGUgbm8tZXhwbGljaXQtYW55CmV4cG9ydCBjb25zdCBjb25maWcgPSB7IHZlcmlmeV9qd3Q6IGZhbHNlIH07CgppbXBvcnQgeyBjcmVhdGVDbGllbnQgfSBmcm9tICJodHRwczovL2VzbS5zaC9Ac3VwYWJhc2Uvc3VwYWJhc2UtanNAMiI7CgpmdW5jdGlvbiBqKHN0YXR1czogbnVtYmVyLCBib2R5OiBhbnkpIHsKICByZXR1cm4gbmV3IFJlc3BvbnNlKEpTT04uc3RyaW5naWZ5KGJvZHksIG51bGwsIDIpLCB7CiAgICBzdGF0dXMsCiAgICBoZWFkZXJzOiB7ICJjb250ZW50LXR5cGUiOiAiYXBwbGljYXRpb24vanNvbiIgfSwKICB9KTsKfQoKZnVuY3Rpb24gbXVzdEVudihuYW1lOiBzdHJpbmcpIHsKICBjb25zdCB2ID0gRGVuby5lbnYuZ2V0KG5hbWUpOwogIGlmICghdiB8fCB2LnRyaW0oKS5sZW5ndGggPT09IDApIHRocm93IG5ldyBFcnJvcigiTUlTU0lOR19FTlY6IiArIG5hbWUpOwogIHJldHVybiB2LnRyaW0oKTsKfQoKZnVuY3Rpb24gcmVxdWlyZUludGVybmFsKHJlcTogUmVxdWVzdCkgewogIGNvbnN0IHdhbnQgPSBtdXN0RW52KCJHSTpfSU5URVJOQUxfU0VDUkVUIik7CiAgY29uc3QgZ290ID0gKHJlcS5oZWFkZXJzLmdldCgieC1naS1pbnRlcm5hbC1zZWNyZXQiKSA/PyAiIikudHJpbSgpOwogIGlmICghZ290KSByZXR1cm4geyBvazogZmFsc2UsIHJlc3A6IGooNDAxLCB7IG9rOiBmYWxzZSwgcmVhc29uOiAiTUlTU0lOR19JTlRFUk5BTF9TRUNSRVQiIH0pIH07CiAgaWYgKGdvdCAhPT0gd2FudCkgcmV0dXJuIHsgb2s6IGZhbHNlLCByZXNwOiBqKDQwMywgeyBvazogZmFsc2UsIHJlYXNvbjogIklOVkFMSURfSU5URVJOQUxfU0VDUkVUIiB9KSB9OwogIHJldHVybiB7IG9rOiB0cnVlLCByZXNwOiBudWxsIGFzIGFueSB9Owp9CgpmdW5jdGlvbiBzYigpIHsKICBjb25zdCB1cmwgPSBtdXN0RW52KCJHSTpfU1VQQUJBU0VfVVJMIik7CiAgY29uc3Qga2V5ID0gbXVzdEVudigiR0lfU1VQQUJBU0VfU0VDUkVUX0tFWSIpOwogIHJldHVybiBjcmVhdGVDbGllbnQodXJsLCBrZXksIHsgYXV0aDogeyBwZXJzaXN0U2Vzc2lvbjogZmFsc2UgfSB9KTsKfQoKZXhwb3J0IGRlZmF1bHQgYXN5bmMgKHJlcTogUmVxdWVzdCkgPT4gewogIHRyeSB7CiAgICBpZiAocmVxLm1ldGhvZCAhPT0gIlBPU1QiKSByZXR1cm4gajg0MDUsIHsgb2s6IGZhbHNlLCByZWFzb246ICJNRVRIT0RfTk9UX0FMTE9XRUQiIH0pOwogICAgY29uc3QgZ2F0ZSA9IHJlcXVpcmVJbnRlcm5hbChyZXEpOwogICAgaWYgKCFnYXRlLm9rKSByZXR1cm4gZ2F0ZS5yZXNwOwoKICAgIGNvbnN0IGIgPSBhd2FpdCByZXEuanNvbigpLmNhdGNoKCgpID0+IG51bGwpOwogICAgY29uc3QgcmVjZWlwdF9pZCA9IChiPy5yZWNlaXB0X2lkID8/ICIiKS50b1N0cmluZygpLnRyaW0oKTsKICAgIGlmICghcmVjZWlwdF9pZCkgcmV0dXJuIGooNDAwLCB7IG9rOiBmYWxzZSwgcmVhc29uOiAiTUlTU0lOR19SRUNFSVBUX0lEIiB9KTsKCiAgICBjb25zdCBzdXBhYmFzZSA9IHNiKCk7CiAgICBjb25zdCB7IGRhdGEsIGVycm9yIH0gPSBhd2FpdCBzdXBhYmFzZQogICAgICAuZnJvbSgiZ2lfcmVjZWlwdHMiKQogICAgICAuc2VsZWN0KCIqIikKICAgICAgLmVxKCJyZWNlaXB0X2lkIiwgcmVjZWlwdF9pZCkKICAgICAgLm1heWJlU2luZ2xlKCk7CgogICAgaWYgKGVycm9yKSByZXR1cm4gajg1MDAsIHsgb2s6IGZhbHNlLCByZWFzb246ICJEQl9FUlJPUiIsIGRldGFpbDogZXJyb3IubWVzc2FnZSB9KTsKICAgIGlmICghZGF0YSkgcmV0dXJuIGooNDA0LCB7IG9rOiBmYWxzZSwgcmVhc29uOiAiUkVDRUlQVF9OT1RfRk9VTkQiLCByZWNlaXB0X2lkIH0pOwogICAgcmV0dXJuIGooMjAwLCB7IG9rOiB0cnVlLCByZWNlaXB0OiBkYXRhIH0pOwogIH0gY2F0Y2ggKGU6IGFueSkgewogICAgcmV0dXJuIGooNTAwLCB7IG9rOiBmYWxzZSwgcmVhc29uOiAiU0VSVkVSX0VSUk9SIiwgZGV0YWlsOiBTdHJpbmcoZT8ubWVzc2FnZSA/PyBlKSB9KTsKICB9Cn07Cg=="
) -join ""
$ts_bytes = [Convert]::FromBase64String($ts_b64)
WriteBytes $Good $ts_bytes
Write-Host ("WROTE: {0}" -f $Good) -ForegroundColor Green
Write-Host ("SHA256(index.ts): {0}" -f (Get-FileHash -Algorithm SHA256 -LiteralPath $Good).Hash) -ForegroundColor DarkGray

# 3) Deploy deterministically
Push-Location $Root
try {
  Write-Host "== DEPLOY gi-receipt-get ==" -ForegroundColor Cyan
  supabase functions deploy gi-receipt-get | Out-Host
  Write-Host "OK: deployed gi-receipt-get" -ForegroundColor Green
} finally { Pop-Location }