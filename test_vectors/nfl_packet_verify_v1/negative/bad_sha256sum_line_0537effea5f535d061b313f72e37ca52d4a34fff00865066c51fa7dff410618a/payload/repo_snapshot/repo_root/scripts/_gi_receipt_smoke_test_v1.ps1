param(
  [Parameter(Mandatory=$true)][string]$ReceiptId,
  [Parameter(Mandatory=$true)][string]$BearerToken,
  [Parameter(Mandatory=$false)][string]$ProjectRef = "hmlihkcijjamxdurydbv"
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$base = "https://{0}.functions.supabase.co" -f $ProjectRef
$hAuth = "Authorization: Bearer " + $BearerToken

Write-Host "== GI receipt get ==" -ForegroundColor Cyan
$bodyGet = @{ receipt_id = $ReceiptId } | ConvertTo-Json -Depth 50
curl.exe -s -X POST ($base + "/gi-receipt-get") -H "Content-Type: application/json" -H $hAuth -d $bodyGet | Out-Host

Write-Host "== GI receipt verify (proposal echo) ==" -ForegroundColor Cyan
# Replace proposal payload with your real proposal when ready
$proposal = @{ sample = "proposal"; receipt_id = $ReceiptId }
$bodyVer = @{ receipt_id = $ReceiptId; proposal = $proposal } | ConvertTo-Json -Depth 50
curl.exe -s -X POST ($base + "/gi-receipt-verify") -H "Content-Type: application/json" -H $hAuth -d $bodyVer | Out-Host
