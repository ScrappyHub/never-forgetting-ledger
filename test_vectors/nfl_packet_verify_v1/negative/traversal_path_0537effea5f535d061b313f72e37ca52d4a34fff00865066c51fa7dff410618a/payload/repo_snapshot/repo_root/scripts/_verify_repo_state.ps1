$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$Root       = "C:\Users\Keira\gi-ppi"
$ProjectRef = "hmlihkcijjamxdurydbv"

Write-Host "== GI-PPI VERIFY ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor Cyan
Write-Host ("ProjectRef: {0}" -f $ProjectRef) -ForegroundColor Cyan

Push-Location $Root
try {
  supabase link --project-ref $ProjectRef | Out-Host

  Write-Host "== supabase migration list ==" -ForegroundColor Cyan
  supabase migration list | Out-Host

  Write-Host "== local migrations (head) ==" -ForegroundColor Cyan
  Get-ChildItem -LiteralPath (Join-Path $Root "supabase\migrations") -File | Sort-Object Name | Select-Object -First 25 Name | Format-Table -AutoSize | Out-Host

  Write-Host "== supabase db push (should be up to date) ==" -ForegroundColor Cyan
  cmd.exe /c "echo y| supabase db push" | Out-Host
}
finally { Pop-Location }

Write-Host "== VERIFY DONE ==" -ForegroundColor Green