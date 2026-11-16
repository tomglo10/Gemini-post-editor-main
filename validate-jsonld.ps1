param (
    [Parameter(Mandatory = $false, Position = 0)][string]$Path = (Join-Path $PSScriptRoot "posts")
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "`nABORTED: Path not found '$Path'`n" -ForegroundColor Red; exit 1 }
$files = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Item -LiteralPath $Path) } else { Get-ChildItem -LiteralPath $Path -Filter "*.html" -Recurse | Where-Object { $_.Name -ne "post-preview-template.html" } }
if ($files.Count -eq 0) { Write-Host "`nNo HTML post files found in '$Path'.`n" -ForegroundColor Yellow; exit 0 }

$totalErrors = 0
foreach ($file in $files) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $body = [System.Text.RegularExpressions.Regex]::Replace($raw, '(?s)<!--\s*PREVIEW-UI-START\s*-->.*?<!--\s*PREVIEW-UI-END\s*-->', '')
    $fileErrors = 0
    $blocks = [System.Text.RegularExpressions.Regex]::Matches($body, '(?is)<script\b[^>]*type\s*=\s*["'']application/ld\+json["''][^>]*>(.*?)</script>')
    foreach ($b in $blocks) {
        try { $null = $b.Groups[1].Value.Trim() | ConvertFrom-Json -ErrorAction Stop }
        catch { $fileErrors++; Write-Host "  [FAIL] $($file.Name) invalid JSON-LD: $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($body -match 'aginghealth\.website/\.html') { $fileErrors++; Write-Host "  [FAIL] $($file.Name) contains empty slug aginghealth.website/.html" -ForegroundColor Red }
    if ($fileErrors -eq 0) { Write-Host "[PASS] $($file.Name) ($($blocks.Count) JSON-LD block(s))" -ForegroundColor Green }
    $totalErrors += $fileErrors
}
Write-Host "`nBatch Audit Complete: $($files.Count) file(s) checked, $totalErrors error(s).`n" -ForegroundColor $(if ($totalErrors -gt 0) { "Red" } else { "Green" })
if ($totalErrors -gt 0) { exit 1 }