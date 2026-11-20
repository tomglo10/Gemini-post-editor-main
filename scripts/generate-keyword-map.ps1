param(
    [string]$SiteUrl = "https://www.aginghealth.website",
    [string]$OutputPath = "C:\Users\tomgl\OneDrive\Documents\Gemini-post-editor-main\Gemini-post-editor-main-main\scripts\keyword-map.json",
    [int]$PageSize = 150
)

$ErrorActionPreference = "Stop"
$startIndex = 1
$allEntries = @()
$totalReported = $null

Write-Host "Fetching all live Blogger post metadata from $SiteUrl..." -ForegroundColor Cyan

while ($true) {
    $feedUrl = "$SiteUrl/feeds/posts/summary?alt=json&start-index=$startIndex&max-results=$PageSize"
    $response = Invoke-RestMethod -Uri $feedUrl -Method Get

    if ($null -eq $totalReported -and $response.feed.'openSearch$totalResults') {
        $totalReported = [int]$response.feed.'openSearch$totalResults'.'$t'
        Write-Host "Blogger feed reports $totalReported total published posts." -ForegroundColor Yellow
    }

    $batch = @($response.feed.entry | Where-Object { $null -ne $_ })
    if ($batch.Count -eq 0) {
        break
    }

    $allEntries += $batch
    Write-Host "  Fetched $($allEntries.Count) of $totalReported posts..." -ForegroundColor DarkGray

    if ($null -ne $totalReported -and $allEntries.Count -ge $totalReported) {
        break
    }

    $startIndex += $batch.Count
    Start-Sleep -Milliseconds 150
}

$seenUrls = @{}
$mappedPosts = foreach ($entry in $allEntries) {
    $altLink = ($entry.link | Where-Object { $_.rel -eq "alternate" } | Select-Object -First 1).href
    if ([string]::IsNullOrWhiteSpace($altLink)) { continue }

    $canonicalUrl = ($altLink -replace '^http://', 'https://').Trim()
    if ($seenUrls.ContainsKey($canonicalUrl)) { continue }
    $seenUrls[$canonicalUrl] = $true

    $title = ($entry.title.'$t').Trim()
    $published = $entry.published.'$t'
    $updated = $entry.updated.'$t'

    $labels = @()
    if ($entry.category) {
        $labels = @(
            $entry.category |
            ForEach-Object { $_.term.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        )
    }

    $slug = ""
    if ($canonicalUrl -match '/([^/]+)\.html$') {
        $slug = $Matches[1]
    }

    $keywordCandidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $mainTitle = ($title -split '[:|\u2014\u2013]')[0].Trim().ToLowerInvariant()
        if ($mainTitle.Length -ge 4) {
            $keywordCandidates.Add($mainTitle)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($slug)) {
        $slugPhrase = ($slug -replace '-', ' ').Trim().ToLowerInvariant()
        if ($slugPhrase.Length -ge 4) {
            $keywordCandidates.Add($slugPhrase)
        }
    }

    foreach ($lbl in $labels) {
        $cleanLabel = $lbl.ToLowerInvariant()
        if ($cleanLabel.Length -ge 3) {
            $keywordCandidates.Add($cleanLabel)
        }
    }

    $uniqueKeywords = @($keywordCandidates | Select-Object -Unique)

    [PSCustomObject]@{
        title     = $title
        url       = $canonicalUrl
        slug      = $slug
        labels    = $labels
        keywords  = $uniqueKeywords
        published = $published
        updated   = $updated
    }
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$payload = [PSCustomObject]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    siteUrl     = $SiteUrl
    totalPosts  = $mappedPosts.Count
    posts       = $mappedPosts
}

$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "`nSUCCESS: Exported all $($mappedPosts.Count) live posts to $OutputPath" -ForegroundColor Green