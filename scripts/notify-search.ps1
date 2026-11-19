param(
  [Parameter(Mandatory = $true)][string]$PostUrl
)

$BingApiKey = "f3c39fb371a14ec697c7a74c71058b07"

if ($PostUrl -notmatch '^https://www\.aginghealth\.website/.+\.html$') {
  Write-Host "Error: Provide a valid full post URL (e.g., https://www.aginghealth.website/2026/11/your-slug.html)." -ForegroundColor Red
  exit 1
}

# 1. Submit to Bing Webmaster Tools API
if ($BingApiKey -ne "YOUR_BING_API_KEY" -and -not [string]::IsNullOrWhiteSpace($BingApiKey)) {
  $bingEndpoint = "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrl?apikey=$BingApiKey"
  $bingBody = @{
    siteUrl = "https://www.aginghealth.website"
    url     = $PostUrl
  } | ConvertTo-Json -Compress

  try {
    Invoke-RestMethod -Uri $bingEndpoint -Method Post -ContentType "application/json; charset=utf-8" -Body $bingBody | Out-Null
    Write-Host "Bing Webmaster API accepted: $PostUrl" -ForegroundColor Green
  }
  catch {
    Write-Host "Bing API notice: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# 2. Copy URL to clipboard & open Google Search Console property directly
Set-Clipboard -Value $PostUrl
$gscHome = "https://search.google.com/search-console?resource_id=sc-domain%3Aaginghealth.website"
Start-Process "msedge.exe" $gscHome
Write-Host "URL copied to clipboard! Press Ctrl+V in the top Search Console inspection bar: $PostUrl" -ForegroundColor Cyan
