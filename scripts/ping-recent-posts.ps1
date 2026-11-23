<#
.SYNOPSIS
    Reads a Blogger Atom feed, finds posts published in the last 24 hours,
    and submits new URLs to Bing's URL Submission API or IndexNow.
#>

param(
    [string]$SiteUrl = "https://www.aginghealth.website",
    [ValidateSet("Bing", "IndexNow")]
    [string]$Mode = "Bing",
    [int]$HoursBack = 24,
    [switch]$IncludeUpdated,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# --- 1. Load API Key securely from environment variable (keeps keys out of Git) ---
# Set once in PowerShell with:
#   [Environment]::SetEnvironmentVariable("BING_WEBMASTER_API_KEY", "your-key", "User")
#   [Environment]::SetEnvironmentVariable("INDEXNOW_API_KEY", "your-key", "User")
$apiKey = if ($Mode -eq "Bing") { $env:BING_WEBMASTER_API_KEY } else { $env:INDEXNOW_API_KEY }

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($apiKey)) {
    $varName = if ($Mode -eq "Bing") { "BING_WEBMASTER_API_KEY" } else { "INDEXNOW_API_KEY" }
    Write-Host "Missing API key. Set user environment variable '$varName' and restart VS Code." -ForegroundColor Red
    exit 1
}

# --- 2. Load local history so we don't re-submit the same URL on every folder open ---
$historyFile = Join-Path $PSScriptRoot ".pinged-urls.json"
$pingedHistory = @{}
if (Test-Path $historyFile) {
    try {
        $raw = Get-Content $historyFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $pingedHistory[$prop.Name] = $prop.Value
        }
    }
    catch {
        $pingedHistory = @{}
    }
}

# --- 3. Fetch and parse the Blogger Atom feed ---
$cleanSiteUrl = $SiteUrl.TrimEnd("/")
$feedUrl = "$cleanSiteUrl/feeds/posts/default?alt=atom&max-results=25"
Write-Host "Checking Blogger feed: $feedUrl" -ForegroundColor Cyan

try {
    $response = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 15
    [xml]$xml = $response.Content
}
catch {
    Write-Host "Failed to fetch Blogger feed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace("atom", "http://www.w3.org/2005/Atom")

$cutoff = (Get-Date).ToUniversalTime().AddHours(-$HoursBack)
$urlsToSubmit = New-Object System.Collections.Generic.List[string]

$entries = $xml.SelectNodes("//atom:entry", $ns)
foreach ($entry in $entries) {
    $pubStr = $entry.SelectSingleNode("atom:published", $ns).InnerText
    $updStr = $entry.SelectSingleNode("atom:updated", $ns).InnerText

    $pubDate = ([DateTimeOffset]::Parse($pubStr)).UtcDateTime
    $updDate = ([DateTimeOffset]::Parse($updStr)).UtcDateTime

    $isRecent = ($pubDate -ge $cutoff) -or ($IncludeUpdated -and ($updDate -ge $cutoff))
    if (-not $isRecent) { continue }

    $linkNode = $entry.SelectSingleNode("atom:link[@rel='alternate' and @type='text/html']", $ns)
    if (-not $linkNode) { continue }

    $postUrl = $linkNode.GetAttribute("href")
    if (-not $Force -and $pingedHistory.ContainsKey($postUrl)) {
        Write-Host "  [Skipped - already pinged] $postUrl" -ForegroundColor DarkGray
        continue
    }

    $urlsToSubmit.Add($postUrl)
}

if ($urlsToSubmit.Count -eq 0) {
    Write-Host "No new posts found in the last $HoursBack hours. Nothing to submit." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($urlsToSubmit.Count) new URL(s) to submit via ${Mode}:" -ForegroundColor Green
$urlsToSubmit | ForEach-Object { Write-Host "  + $_" -ForegroundColor White }

if ($DryRun) {
    Write-Host "[DryRun] Skipping API call." -ForegroundColor Magenta
    exit 0
}

# --- 4. Submit batch to Bing URL Submission API or IndexNow ---
try {
    if ($Mode -eq "Bing") {
        $endpoint = "https://ssl.bing.com/webmaster/api.svc/json/SubmitUrlBatch?apikey=$apiKey"
        $payload = @{
            siteUrl = $cleanSiteUrl
            urlList = @($urlsToSubmit)
        } | ConvertTo-Json -Depth 3

            -ContentType "application/json; charset=utf-8" -Body $payload -TimeoutSec 20

        Write-Host "Bing URL Submission succeeded (HTTP 200)." -ForegroundColor Green
    }
    else {
        $uriObj = [System.Uri]$cleanSiteUrl
        $endpoint = "https://api.indexnow.org/indexnow"
        $payload = @{
            host        = $uriObj.Host
            key         = $apiKey
            keyLocation = "$cleanSiteUrl/$apiKey.txt"
            urlList     = @($urlsToSubmit)
        } | ConvertTo-Json -Depth 3

        $webResp = Invoke-WebRequest -Uri $endpoint -Method Post `
            -ContentType "application/json; charset=utf-8" -Body $payload -UseBasicParsing -TimeoutSec 20

        Write-Host "IndexNow submission succeeded (HTTP $($webResp.StatusCode))." -ForegroundColor Green
    }

    # --- 5. Record submitted URLs to prevent duplicates ---
    $nowIso = (Get-Date).ToUniversalTime().ToString("o")
    foreach ($u in $urlsToSubmit) {
        $pingedHistory[$u] = $nowIso
    }
    $pingedHistory | ConvertTo-Json -Depth 2 | Set-Content -Path $historyFile -Encoding UTF8

}
catch {
    Write-Host "$Mode submission failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
