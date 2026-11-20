param(
    [string]$DraftPath = "",
    [string]$KeywordMapPath = "",
    [int]$Top = 10
)

$ErrorActionPreference = "Stop"

$workspaceRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($KeywordMapPath)) {
    $KeywordMapPath = Join-Path $PSScriptRoot "keyword-map.json"
}

if (-not (Test-Path -LiteralPath $KeywordMapPath)) {
    Write-Host "ERROR: Cannot find keyword-map.json at $KeywordMapPath" -ForegroundColor Red
    Write-Host "Run 'Refresh Local Keyword Map' first." -ForegroundColor Yellow
    exit 1
}

# If VS Code passed a non-HTML file (like tasks.json or a .ps1 script), ignore it and auto-locate the newest HTML draft
if (-not [string]::IsNullOrWhiteSpace($DraftPath) -and ($DraftPath -notmatch '\.html?$')) {
    Write-Host "Active tab ($((Split-Path -Leaf $DraftPath))) is not an HTML draft. Searching workspace for newest HTML draft..." -ForegroundColor DarkYellow
    $DraftPath = ""
}

if ([string]::IsNullOrWhiteSpace($DraftPath) -or -not (Test-Path -LiteralPath $DraftPath)) {
    $postsDir = Join-Path $workspaceRoot "posts"
    $searchRoot = if (Test-Path -LiteralPath $postsDir) { $postsDir } else { $workspaceRoot }

    $latestDraft = Get-ChildItem -Path $searchRoot -Recurse -Filter "*.html" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'preview|template|index|glossary-data' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    # If posts\ had no HTML files, fall back to workspace root
    if (-not $latestDraft -and $searchRoot -ne $workspaceRoot) {
        $latestDraft = Get-ChildItem -Path $workspaceRoot -Recurse -Filter "*.html" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'preview|template|index|glossary-data' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    }

    if ($latestDraft) {
        $DraftPath = $latestDraft.FullName
    }
}

if ([string]::IsNullOrWhiteSpace($DraftPath) -or -not (Test-Path -LiteralPath $DraftPath)) {
    Write-Host "ERROR: No .html draft file found in posts\ or workspace root." -ForegroundColor Red
    exit 1
}

$draftFile = Get-Item -LiteralPath $DraftPath
$draftSlug = [System.IO.Path]::GetFileNameWithoutExtension($draftFile.Name).ToLowerInvariant()
$rawHtml = Get-Content -LiteralPath $draftFile.FullName -Raw -Encoding UTF8

# Collect URLs already linked in the draft
$existingLinks = @{}
$hrefMatches = [regex]::Matches($rawHtml, 'href\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')
foreach ($m in $hrefMatches) {
    $cleanHref = ($m.Groups[1].Value -replace '^http://', 'https://' -replace '[?#].*$', '').Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($cleanHref)) {
        $existingLinks[$cleanHref] = $true
    }
}

# Extract H2/H3 headings for relevance boosting
$headingMatches = [regex]::Matches($rawHtml, '<h[23][^>]*>(.*?)</h[23]>', 'IgnoreCase,Singleline')
$headingText = ($headingMatches | ForEach-Object {
        ([regex]::Replace($_.Groups[1].Value, '<[^>]+>', ' '))
    }) -join " "
$headingText = [System.Net.WebUtility]::HtmlDecode($headingText).ToLowerInvariant()

# Strip scripts, styles, and HTML tags to isolate article prose
$cleanHtml = [regex]::Replace($rawHtml, '<script[^>]*>.*?</script>', ' ', 'IgnoreCase,Singleline')
$cleanHtml = [regex]::Replace($cleanHtml, '<style[^>]*>.*?</style>', ' ', 'IgnoreCase,Singleline')
$plainText = [regex]::Replace($cleanHtml, '<[^>]+>', ' ')
$plainText = [System.Net.WebUtility]::HtmlDecode($plainText)
$plainTextNormalized = ([regex]::Replace($plainText, '\s+', ' ')).Trim()
$plainTextLower = $plainTextNormalized.ToLowerInvariant()

$stopWords = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    "the", "and", "for", "with", "that", "this", "from", "your", "what", "when", "where", "which", "while",
    "how", "why", "can", "are", "was", "were", "been", "have", "has", "had", "not", "but", "into", "over",
    "after", "before", "about", "more", "most", "some", "such", "than", "then", "them", "they", "their",
    "there", "these", "those", "will", "would", "could", "should", "may", "might", "also", "only", "just",
    "very", "well", "even", "much", "many", "each", "both", "other", "another", "between", "through",
    "aging", "health", "senior", "seniors", "older", "adult", "adults", "guide", "tips", "facts", "truth",
    "fiction", "complete", "understanding", "explained", "simply", "ways", "best", "worst", "signs",
    "symptoms", "causes", "treatments", "treatment", "prevention", "risk", "risks", "benefits", "effects",
    "impacts", "impact", "role", "link", "connection", "matters", "beyond", "every", "daily"
) | ForEach-Object { [void]$stopWords.Add($_) }

$draftTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($tok in ([regex]::Matches($plainTextLower, '\b[a-z][a-z0-9]{3,}\b'))) {
    if (-not $stopWords.Contains($tok.Value)) {
        [void]$draftTokens.Add($tok.Value)
    }
}

$mapData = Get-Content -LiteralPath $KeywordMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$posts = @($mapData.posts)

Write-Host "`nScanning draft : $($draftFile.FullName)" -ForegroundColor Cyan
Write-Host "Word tokens    : $($draftTokens.Count) unique topic words | Existing links skipped: $($existingLinks.Count)" -ForegroundColor DarkGray
Write-Host "Catalog size   : $($posts.Count) live posts from keyword-map.json`n" -ForegroundColor DarkGray

if ($posts.Count -eq 0) {
    Write-Host "ERROR: keyword-map.json contains 0 posts. Run 'Refresh Local Keyword Map' first." -ForegroundColor Red
    exit 1
}

$scoredResults = foreach ($post in $posts) {
    $postUrlLower = $post.url.Trim().ToLowerInvariant()
    $postSlugLower = if ($post.slug) { $post.slug.Trim().ToLowerInvariant() } else { "" }

    if ($postSlugLower -eq $draftSlug) { continue }
    if ($existingLinks.ContainsKey($postUrlLower)) { continue }

    $score = 0
    $matchedPhrases = New-Object System.Collections.Generic.List[string]
    $matchedWords = New-Object System.Collections.Generic.List[string]
    $bestAnchorText = ""

    foreach ($kw in @($post.keywords)) {
        if ([string]::IsNullOrWhiteSpace($kw)) { continue }
        $kwClean = $kw.Trim().ToLowerInvariant()
        if ($kwClean.Length -lt 5) { continue }
        if ($stopWords.Contains($kwClean)) { continue }

        $pattern = '\b' + [regex]::Escape($kwClean) + '\b'
        $m = [regex]::Match($plainTextNormalized, $pattern, 'IgnoreCase')
        if ($m.Success) {
            $wordCount = ($kwClean -split '\s+').Count
            $phrasePoints = if ($wordCount -ge 2) { 18 } else { 10 }
            if ([regex]::IsMatch($headingText, $pattern, 'IgnoreCase')) {
                $phrasePoints += 8
            }
            $score += $phrasePoints
            $matchedPhrases.Add($m.Value)

            if ([string]::IsNullOrWhiteSpace($bestAnchorText) -or ($wordCount -ge 2 -and $wordCount -le 5)) {
                $bestAnchorText = $m.Value
            }
        }
    }

    $candidateSource = "$($post.title) $($postSlugLower -replace '-', ' ')".ToLowerInvariant()
    $candidateTokens = [regex]::Matches($candidateSource, '\b[a-z][a-z0-9]{3,}\b') |
    ForEach-Object { $_.Value } |
    Where-Object { -not $stopWords.Contains($_) } |
    Select-Object -Unique

    foreach ($ct in $candidateTokens) {
        if ($draftTokens.Contains($ct)) {
            $wordPts = if ($ct.Length -ge 8) { 5 } else { 3 }
            if ($headingText -match ('\b' + [regex]::Escape($ct) + '\b')) {
                $wordPts += 2
            }
            $score += $wordPts
            $matchedWords.Add($ct)
        }
    }

    if ($score -lt 6) { continue }

    if ([string]::IsNullOrWhiteSpace($bestAnchorText)) {
        $cleanTitle = ($post.title -split '[:|\u2014\u2013]')[0].Trim()
        $bestAnchorText = $cleanTitle.ToLowerInvariant()
    }

    $reasonParts = @()
    if ($matchedPhrases.Count -gt 0) {
        $reasonParts += "Exact phrase: `"$(($matchedPhrases | Select-Object -Unique | Select-Object -First 2) -join '", "')`""
    }
    if ($matchedWords.Count -gt 0) {
        $reasonParts += "Shared topics: $(($matchedWords | Select-Object -Unique | Select-Object -First 4) -join ', ')"
    }

    [PSCustomObject]@{
        Score      = $score
        Title      = $post.title
        Url        = $post.url
        Labels     = (@($post.labels) -join ", ")
        Reason     = ($reasonParts -join " | ")
        AnchorHtml = "<a href=""$($post.url)"">$bestAnchorText</a>"
    }
}

$topMatches = @($scoredResults | Sort-Object Score -Descending | Select-Object -First $Top)

if ($topMatches.Count -eq 0) {
    Write-Host "No matching internal links found for $($draftFile.Name)." -ForegroundColor Yellow
    exit 0
}

Write-Host "=== TOP $($topMatches.Count) INTERNAL LINK SUGGESTIONS ===" -ForegroundColor Green
$rank = 1
foreach ($item in $topMatches) {
    Write-Host "`n[$rank] (Score: $($item.Score)) $($item.Title)" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($item.Labels)) {
        Write-Host "    Labels : $($item.Labels)" -ForegroundColor DarkGray
    }
    Write-Host "    Match  : $($item.Reason)" -ForegroundColor Yellow
    Write-Host "    HTML   : $($item.AnchorHtml)" -ForegroundColor Cyan
    $rank++
}
Write-Host ""