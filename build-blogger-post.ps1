<#
.SYNOPSIS
  Audits, compiles, and copies a Blogger-ready HTML payload for Aging Health
  (aginghealth.website) with graph-linked JSON-LD structured data.

.EXAMPLE
  .\build-blogger-post.ps1 -HtmlFilePath .\posts\leg-pain-walking.html -PostSlug leg-pain-walking
#>

param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$HtmlFilePath,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$PostSlug,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$TopicName
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# PRE-FLIGHT FILE & EXTENSION GUARDS
# ==============================================================================
if (-not (Test-Path -LiteralPath $HtmlFilePath -PathType Leaf)) {
    Write-Host "`nError: File not found at '$HtmlFilePath'`n" -ForegroundColor Red
    exit 1
}

$fileExt = [System.IO.Path]::GetExtension($HtmlFilePath)
if ($fileExt -notin @('.html', '.htm')) {
    Write-Host "`nABORTED: Expected an .html or .htm file, got '$fileExt' ($(Split-Path -Leaf $HtmlFilePath)). Focus a post HTML file and re-run.`n" -ForegroundColor Red
    exit 1
}

$html = Get-Content -LiteralPath $HtmlFilePath -Raw -Encoding UTF8

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
function ConvertTo-PlainText {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RawText
    )

    $noTags = [regex]::Replace($RawText, '<[^>]+>', '')
    $decoded = [System.Net.WebUtility]::HtmlDecode($noTags)
    return ([regex]::Replace($decoded, '\s+', ' ')).Trim()
}

function Convert-JsLiteralToJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsText
    )

    # Quote unquoted JS object keys and normalize single-quoted strings without altering double-quoted text
    $keyAndQuotePattern = '"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|([a-zA-Z_$][\w$]*)\s*:'
    $normalized = [regex]::Replace($JsText, $keyAndQuotePattern, {
            param($m)
            if ($m.Groups[1].Success) {
                return "`"$($m.Groups[1].Value)`":"
            }
            if ($m.Value.StartsWith("'")) {
                $inner = $m.Value.Substring(1, $m.Value.Length - 2)
                $inner = $inner -replace "\\'", "'"
                $inner = $inner -replace '(?<!\\)"', '\"'
                return "`"$inner`""
            }
            return $m.Value
        })

    # Strip trailing commas before } or ] outside of string literals
    $trailingCommaPattern = '"(?:\\.|[^"\\])*"|(,\s*(?=[\]\}]))'
    $normalized = [regex]::Replace($normalized, $trailingCommaPattern, {
            param($m)
            if ($m.Groups[1].Success) { return "" }
            return $m.Value
        })

    return $normalized
}

function Get-ScholarlyCitationCalls {
    param (
        [Parameter(Mandatory = $true)]
        [string]$HtmlContent
    )

    $results = @()
    $scriptMatches = [regex]::Matches($HtmlContent, '(?is)<script\b(?![^>]*type\s*=\s*[''"]application/ld\+json[''"])[^>]*>(.*?)</script>')

    foreach ($sm in $scriptMatches) {
        $scriptBody = $sm.Groups[1].Value
        $hasGuard = $scriptBody -match 'typeof\s+createScholarlyArticleSchema\s*===\s*[''"]function[''"]'

        $searchPos = 0
        while ($true) {
            $fnIndex = $scriptBody.IndexOf("createScholarlyArticleSchema", $searchPos, [System.StringComparison]::Ordinal)
            if ($fnIndex -lt 0) { break }

            # Skip function declaration if encountered
            $prefix = $scriptBody.Substring([Math]::Max(0, $fnIndex - 15), [Math]::Min(15, $fnIndex))
            if ($prefix -match 'function\s+$') {
                $searchPos = $fnIndex + 28
                continue
            }

            $openParen = $scriptBody.IndexOf("(", $fnIndex + 28)
            if ($openParen -lt 0) { break }

            # Balanced parenthesis scanner (respects quotes and escape sequences)
            $depth = 1
            $i = $openParen + 1
            $inSingle = $false
            $inDouble = $false
            $escaped = $false

            while ($i -lt $scriptBody.Length -and $depth -gt 0) {
                $ch = $scriptBody[$i]
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($ch -eq '\') {
                    $escaped = $true
                }
                elseif ($inSingle) {
                    if ($ch -eq "'") { $inSingle = $false }
                }
                elseif ($inDouble) {
                    if ($ch -eq '"') { $inDouble = $false }
                }
                else {
                    if ($ch -eq "'") { $inSingle = $true }
                    elseif ($ch -eq '"') { $inDouble = $true }
                    elseif ($ch -eq '(') { $depth++ }
                    elseif ($ch -eq ')') { $depth-- }
                }
                $i++
            }

            if ($depth -eq 0) {
                $innerArg = $scriptBody.Substring($openParen + 1, ($i - 1) - ($openParen + 1)).Trim()
                $results += [PSCustomObject]@{
                    RawArgument    = $innerArg
                    HasTypeofGuard = $hasGuard
                    Unclosed       = $false
                }
                $searchPos = $i
            }
            else {
                $results += [PSCustomObject]@{
                    RawArgument    = $null
                    HasTypeofGuard = $hasGuard
                    Unclosed       = $true
                }
                break
            }
        }
    }

    return $results
}

$cleanSlug = $PostSlug -replace '\.html$', ''
$baseUrl = "https://www.aginghealth.website/$cleanSlug.html"

if ([string]::IsNullOrWhiteSpace($TopicName)) {
    $textInfo = (Get-Culture).TextInfo
    $TopicName = $textInfo.ToTitleCase(($cleanSlug -replace '-', ' '))
}

# ==============================================================================
# STEP 1: EXTRACT INNER BODY CONTENT & STRIP LOCAL PREVIEW UI
# ==============================================================================
$bodyMatch = [regex]::Match(
    $html,
    '<body[^>]*>([\s\S]*?)</body>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$postContent = if ($bodyMatch.Success) { $bodyMatch.Groups[1].Value.Trim() } else { $html.Trim() }

# Strip local Live Server preview toolbar and toggle scripts
$postContent = [regex]::Replace(
    $postContent,
    '<!-- PREVIEW-UI-START -->[\s\S]*?<!-- PREVIEW-UI-END -->\s*',
    ''
)

# Remove any previously auto-generated schema blocks so re-running stays clean
$postContent = [regex]::Replace(
    $postContent,
    '<!-- AUTO-GENERATED-SCHEMA-START -->[\s\S]*?<!-- AUTO-GENERATED-SCHEMA-END -->\s*',
    ''
)

# ==============================================================================
# STEP 2: SEO, ACCESSIBILITY (CLS/ALT), HEADING, CITATION & E-E-A-T AUDIT
# ==============================================================================
Write-Host "`nRunning AgingHealth Pre-Publish Content & SEO Audit..." -ForegroundColor Cyan
Write-Host ("-" * 65) -ForegroundColor DarkGray

$auditErrors = 0
$auditWarnings = 0

# 2A. Image Alt Text & CLS Dimension Check
$imgMatches = [regex]::Matches($postContent, '<img\b[^>]*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if ($imgMatches.Count -eq 0) {
    Write-Host "  [WARN] No <img> tags found in post body." -ForegroundColor Yellow
    $auditWarnings++
}
else {
    $imgIndex = 0
    foreach ($img in $imgMatches) {
        $imgIndex++
        $tag = $img.Value
        $altMatch = [regex]::Match($tag, '\balt\s*=\s*["'']([^"'']*)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if (-not $altMatch.Success -or [string]::IsNullOrWhiteSpace($altMatch.Groups[1].Value)) {
            Write-Host "  [FAIL] Image #$imgIndex is missing a descriptive 'alt' attribute." -ForegroundColor Red
            $auditErrors++
        }

        if ($tag -notmatch '\bwidth\s*=' -or $tag -notmatch '\bheight\s*=') {
            Write-Host "  [WARN] Image #$imgIndex is missing explicit 'width' and 'height' attributes (helps prevent CLS)." -ForegroundColor Yellow
            $auditWarnings++
        }
    }
    if ($auditErrors -eq 0) {
        $imgCount = $imgMatches.Count
        Write-Host "  [OK] Audited $imgCount image(s) for alt text." -ForegroundColor Green
    }
}

# 2B. Heading Hierarchy Audit (Blogger renders Post Title as H1, so body should use H2/H3)
$h1Matches = [regex]::Matches($postContent, '<h1\b[^>]*>([\s\S]*?)</h1>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$h2Matches = [regex]::Matches($postContent, '<h2\b[^>]*>([\s\S]*?)</h2>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

if ($h1Matches.Count -gt 1) {
    $h1Count = $h1Matches.Count
    Write-Host "  [FAIL] Found $h1Count <h1> tags in post body (Blogger already outputs post title as H1; use <h2> for sections)." -ForegroundColor Red
    $auditErrors++
}
elseif ($h1Matches.Count -eq 1) {
    Write-Host "  [WARN] Found an <h1> tag inside post body (verify you don't paste a duplicate title into Blogger)." -ForegroundColor Yellow
    $auditWarnings++
}

if ($h2Matches.Count -eq 0) {
    Write-Host "  [WARN] No <h2> section headings found (recommended for AEO/LLM chunking and Table of Contents)." -ForegroundColor Yellow
    $auditWarnings++
}
else {
    $h2Count = $h2Matches.Count
    Write-Host "  [OK] Found $h2Count <h2> section headings." -ForegroundColor Green
}

# Check for skipped heading levels (e.g., H2 jumping directly to H4)
$headingTags = [regex]::Matches($postContent, '<h([1-6])\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$prevLevel = 1
foreach ($ht in $headingTags) {
    $currLevel = [int]$ht.Groups[1].Value
    if (($currLevel - $prevLevel) -gt 1) {
        Write-Host "  [WARN] Heading hierarchy skip detected: <h$prevLevel> followed by <h$currLevel>." -ForegroundColor Yellow
        $auditWarnings++
    }
    $prevLevel = $currLevel
}

# 2C. External Medical Citations Audit (PubMed, NIH, CDC, Mayo, .gov, .edu, DOI)
$linkMatches = [regex]::Matches($postContent, '<a\b[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
$medicalDomains = '(nih\.gov|pubmed\.ncbi\.nlm\.nih\.gov|cdc\.gov|who\.int|fda\.gov|mayoclinic\.org|clevelandclinic\.org|hopkinsmedicine\.org|health\.harvard\.edu|doi\.org|\.gov|\.edu)'
$citationCount = 0
$hasGlossaryHubLink = $false

foreach ($lnk in $linkMatches) {
    $href = $lnk.Groups[1].Value.Trim()
    if ($href -match $medicalDomains) {
        $citationCount++
    }
    if ($href -match 'aginghealth\.website/p/glossary\.html' -or $href -match '^#term-') {
        $hasGlossaryHubLink = $true
    }
}

if ($citationCount -eq 0) {
    Write-Host "  [WARN] No authoritative medical/clinical citations (.gov, .edu, PubMed, DOI) detected in links." -ForegroundColor Yellow
    $auditWarnings++
}
else {
    Write-Host "  [OK] Verified $citationCount authoritative medical/clinical citation link(s)." -ForegroundColor Green
}

# 2D. Internal Glossary Link & Anchor Parity Check
if (-not $hasGlossaryHubLink) {
    Write-Host "  [WARN] No internal link to '/p/glossary.html' or '#term-' anchors found." -ForegroundColor Yellow
    $auditWarnings++
}
else {
    Write-Host "  [OK] Verified internal glossary link(s)." -ForegroundColor Green
}

$localTermLinks = [regex]::Matches($postContent, 'href\s*=\s*["'']#(term-[^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
foreach ($tl in $localTermLinks) {
    $targetId = $tl.Groups[1].Value
    if ($postContent -notmatch ("id\s*=\s*['""]" + [regex]::Escape($targetId) + "['""]")) {
        Write-Host "  [FAIL] Broken internal anchor: href='#$targetId' has no matching id='$targetId' in the post." -ForegroundColor Red
        $auditErrors++
    }
}

# 2E. Dynamic ScholarlyArticle Citations Audit (createScholarlyArticleSchema)
$citationCalls = Get-ScholarlyCitationCalls -HtmlContent $postContent
if ($citationCalls.Count -eq 0) {
    Write-Host "  [WARN] No createScholarlyArticleSchema() citation block found in post body." -ForegroundColor Yellow
    $auditWarnings++
}
else {
    $callNum = 0
    $verifiedStudies = 0
    $citationErrorsBefore = $auditErrors

    foreach ($call in $citationCalls) {
        $callNum++

        if ($call.Unclosed) {
            Write-Host "  [FAIL] Citation call #${callNum}: Unclosed parenthesis in createScholarlyArticleSchema(...)." -ForegroundColor Red
            $auditErrors++
            continue
        }

        if (-not $call.HasTypeofGuard) {
            Write-Host "  [WARN] Citation call #${callNum}: Missing 'if (typeof createScholarlyArticleSchema === ''function'')' guard." -ForegroundColor Yellow
            $auditWarnings++
        }

        if ($call.RawArgument -match '\$\{\d+:[^}]+\}') {
            Write-Host "  [FAIL] Citation call #${callNum}: Unreplaced VS Code snippet tabstop found." -ForegroundColor Red
            $auditErrors++
        }

        try {
            $jsonReady = Convert-JsLiteralToJson -JsText $call.RawArgument
            $parsedArg = $jsonReady | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "  [FAIL] Citation call #${callNum}: Could not parse JS object/array argument - $errMsg" -ForegroundColor Red
            $auditErrors++
            continue
        }

        $studies = @($parsedArg)
        if ($studies.Count -eq 0) {
            Write-Host "  [FAIL] Citation call #${callNum}: Citation array is empty." -ForegroundColor Red
            $auditErrors++
            continue
        }

        for ($idx = 0; $idx -lt $studies.Count; $idx++) {
            $study = $studies[$idx]
            $label = "Citation call #${callNum}, study #$($idx + 1)"

            $title = "$($study.title)".Trim()
            if ([string]::IsNullOrWhiteSpace($title) -or $title -eq "Full Study Title") {
                Write-Host "  [FAIL] ${label}: Missing or unreplaced placeholder 'title'." -ForegroundColor Red
                $auditErrors++
            }

            $authors = @($study.authors) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }
            if ($authors.Count -eq 0) {
                Write-Host "  [WARN] ${label}: 'authors' array is empty." -ForegroundColor Yellow
                $auditWarnings++
            }
            elseif ($authors -contains "First Author" -or $authors -contains "Second Author") {
                Write-Host "  [FAIL] ${label}: Unreplaced placeholder author name." -ForegroundColor Red
                $auditErrors++
            }

            $yearStr = "$($study.year)".Trim()
            if ($yearStr -notmatch '^(19|20)\d{2}$') {
                Write-Host "  [FAIL] ${label}: Invalid or missing 4-digit 'year' ('$yearStr')." -ForegroundColor Red
                $auditErrors++
            }

            $journal = "$($study.journal)".Trim()
            if ([string]::IsNullOrWhiteSpace($journal)) {
                Write-Host "  [WARN] ${label}: Missing 'journal' name." -ForegroundColor Yellow
                $auditWarnings++
            }
            elseif ($journal -eq "Journal Name") {
                Write-Host "  [FAIL] ${label}: Unreplaced placeholder journal ('Journal Name')." -ForegroundColor Red
                $auditErrors++
            }

            $pmid = "$($study.pmid)".Trim()
            $pmcid = "$($study.pmcid)".Trim()
            $doi = "$($study.doi)".Trim()

            if ([string]::IsNullOrWhiteSpace($pmid) -and [string]::IsNullOrWhiteSpace($pmcid) -and [string]::IsNullOrWhiteSpace($doi)) {
                Write-Host "  [WARN] ${label}: No pmid, pmcid, or doi provided (schema will lack url and sameAs links)." -ForegroundColor Yellow
                $auditWarnings++
            }
            if (-not [string]::IsNullOrWhiteSpace($pmid) -and $pmid -notmatch '^\d+$') {
                Write-Host "  [FAIL] ${label}: Invalid PMID '$pmid' (expected digits only)." -ForegroundColor Red
                $auditErrors++
            }
            if (-not [string]::IsNullOrWhiteSpace($pmcid) -and $pmcid -notmatch '^(?i)(PMC)?\d+$') {
                Write-Host "  [FAIL] ${label}: Invalid PMCID '$pmcid' (expected digits or PMC + digits)." -ForegroundColor Red
                $auditErrors++
            }
            if (-not [string]::IsNullOrWhiteSpace($doi) -and $doi -notmatch '^(?i)(https?://(dx\.)?doi\.org/)?10\.\d{4,9}/\S+$') {
                Write-Host "  [FAIL] ${label}: Invalid DOI '$doi'." -ForegroundColor Red
                $auditErrors++
            }

            $verifiedStudies++
        }
    }

    if ($auditErrors -eq $citationErrorsBefore) {
        Write-Host "  [OK] Audited $verifiedStudies ScholarlyArticle citation(s) in createScholarlyArticleSchema()." -ForegroundColor Green
    }
}

if ($auditErrors -gt 0) {
    Write-Host "`nABORTED: Fix the $auditErrors critical [FAIL] issue(s) above before compiling for Blogger.`n" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# STEP 3: GENERATE GRAPH-LINKED FAQPage & DefinedTermSet JSON-LD + DUPLICATE CHECK
# ==============================================================================
$generatedBlocks = @()
$schemaConflicts = 0

$faqHtmlPlaceholders = @(
    "First question for older adults and caregivers?",
    "Second question?",
    "Question?",
    "Clear, plain-language answer.",
    "Sample question for older adults and caregivers?"
)

$glossaryIdPlaceholders = @(
    "term-term-slug",
    "term-second-term-slug",
    "term-example"
)

$glossaryTextPlaceholders = @(
    "Medical Term",
    "Second Medical Term",
    "Example Medical Term",
    "Plain-language definition."
)

# Collect @type values from any existing manual JSON-LD blocks in $postContent
$manualSchemaTypes = @()
$existingLdMatches = [regex]::Matches(
    $postContent,
    '(?is)<script\b[^>]*type\s*=\s*[''"]application/ld\+json[''"][^>]*>([\s\S]*?)</script>'
)

foreach ($em in $existingLdMatches) {
    $rawBlock = $em.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($rawBlock)) { continue }
    try {
        $parsedBlock = $rawBlock | ConvertFrom-Json -ErrorAction Stop
        $nodes = if ($parsedBlock.'@graph') { @($parsedBlock.'@graph') } else { @($parsedBlock) }
        foreach ($node in $nodes) {
            if ($node.'@type') {
                $manualSchemaTypes += @($node.'@type')
            }
        }
    }
    catch {
        # Syntax errors in manual JSON-LD blocks are caught and reported in Step 4
    }
}

$manualFaqCount = ($manualSchemaTypes | Where-Object { $_ -eq 'FAQPage' }).Count
$manualGlossaryCount = ($manualSchemaTypes | Where-Object { $_ -eq 'DefinedTermSet' }).Count

if ($manualFaqCount -gt 1) {
    Write-Host "  [FAIL] Found $manualFaqCount manual FAQPage JSON-LD blocks in post body (only 1 is allowed per page)." -ForegroundColor Red
    $schemaConflicts++
}
if ($manualGlossaryCount -gt 1) {
    Write-Host "  [FAIL] Found $manualGlossaryCount manual DefinedTermSet JSON-LD blocks in post body." -ForegroundColor Red
    $schemaConflicts++
}

# 3A. Parse & Placeholder-Audit .ah-faq-section
$faqSectionMatch = [regex]::Match(
    $postContent,
    '<section[^>]*class=["''][^"'']*ah-faq-section[^"'']*["''][^>]*>([\s\S]*?)</section>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

if ($faqSectionMatch.Success) {
    $faqHtml = $faqSectionMatch.Groups[1].Value
    $faqConflictsBefore = $schemaConflicts

    if ($faqHtml -match '\$\{\d+:[^}]+\}') {
        Write-Host "  [FAIL] .ah-faq-section contains an unreplaced VS Code snippet tabstop." -ForegroundColor Red
        $schemaConflicts++
    }

    $detailsRegex = [regex]::new(
        '<details[^>]*>[\s\S]*?<summary[^>]*>([\s\S]*?)</summary>([\s\S]*?)</details>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $questionsList = @()
    $faqItemIdx = 0

    foreach ($m in $detailsRegex.Matches($faqHtml)) {
        $faqItemIdx++
        $qText = ConvertTo-PlainText -RawText $m.Groups[1].Value
        $aText = ConvertTo-PlainText -RawText $m.Groups[2].Value

        if ($faqHtmlPlaceholders -contains $qText) {
            Write-Host "  [FAIL] FAQ item #${faqItemIdx} still has placeholder question: '$qText'" -ForegroundColor Red
            $schemaConflicts++
        }
        if ($faqHtmlPlaceholders -contains $aText) {
            Write-Host "  [FAIL] FAQ item #${faqItemIdx} still has placeholder answer: '$aText'" -ForegroundColor Red
            $schemaConflicts++
        }

        if ($qText -and $aText) {
            $questionsList += [ordered]@{
                "@type"          = "Question"
                "name"           = $qText
                "acceptedAnswer" = [ordered]@{
                    "@type" = "Answer"
                    "text"  = $aText
                }
            }
        }
    }

    if ($questionsList.Count -gt 0 -and $schemaConflicts -eq $faqConflictsBefore) {
        if ($manualFaqCount -gt 0) {
            Write-Host "  [FAIL] Duplicate FAQPage schema: a manual FAQPage JSON-LD block already exists alongside .ah-faq-section. Remove the manual block so Step 3 can auto-generate it." -ForegroundColor Red
            $schemaConflicts++
        }
        else {
            $faqSchema = [ordered]@{
                "@context"   = "https://schema.org"
                "@type"      = "FAQPage"
                "@id"        = "$baseUrl#faq"
                "url"        = $baseUrl
                "inLanguage" = "en-US"
                "isPartOf"   = [ordered]@{
                    "@id" = $baseUrl
                }
                "about"      = [ordered]@{
                    "@id" = "$baseUrl#article"
                }
                "author"     = [ordered]@{
                    "@id" = "https://www.aginghealth.website/#author"
                }
                "publisher"  = [ordered]@{
                    "@id" = "https://www.aginghealth.website/#organization"
                }
                "mainEntity" = $questionsList
            }
            $compactFaq = $faqSchema | ConvertTo-Json -Depth 6 -Compress
            $generatedBlocks += "<script type=`"application/ld+json`">$compactFaq</script>"
            $qCount = $questionsList.Count
            Write-Host "  [OK] Built graph-linked FAQPage schema ($qCount questions)." -ForegroundColor Green
        }
    }
}

# 3B. Parse & Placeholder-Audit .ah-article-glossary
$glossarySectionMatch = [regex]::Match(
    $postContent,
    '<section[^>]*class=["''][^"'']*ah-article-glossary[^"'']*["''][^>]*>([\s\S]*?)</section>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

if ($glossarySectionMatch.Success) {
    $glossaryHtml = $glossarySectionMatch.Groups[1].Value
    $glossaryConflictsBefore = $schemaConflicts

    if ($glossaryHtml -match '\$\{\d+:[^}]+\}') {
        Write-Host "  [FAIL] .ah-article-glossary contains an unreplaced VS Code snippet tabstop." -ForegroundColor Red
        $schemaConflicts++
    }

    $termRegex = [regex]::new(
        '<div[^>]*id=["''](term-[^"'']+)["''][^>]*>[\s\S]*?<dt[^>]*>([\s\S]*?)</dt>[\s\S]*?<dd[^>]*>([\s\S]*?)</dd>[\s\S]*?</div>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $termsList = @()
    $glossaryId = "$baseUrl#glossary"
    $termItemIdx = 0

    foreach ($m in $termRegex.Matches($glossaryHtml)) {
        $termItemIdx++
        $anchorId = $m.Groups[1].Value.Trim()
        $termName = ConvertTo-PlainText -RawText $m.Groups[2].Value
        $termDesc = ConvertTo-PlainText -RawText $m.Groups[3].Value

        if ($glossaryIdPlaceholders -contains $anchorId) {
            Write-Host "  [FAIL] Glossary term #${termItemIdx} still has placeholder anchor ID: '$anchorId'" -ForegroundColor Red
            $schemaConflicts++
        }
        if ($glossaryTextPlaceholders -contains $termName) {
            Write-Host "  [FAIL] Glossary term #${termItemIdx} still has placeholder term name: '$termName'" -ForegroundColor Red
            $schemaConflicts++
        }
        if ($glossaryTextPlaceholders -contains $termDesc) {
            Write-Host "  [FAIL] Glossary term #${termItemIdx} still has placeholder definition: '$termDesc'" -ForegroundColor Red
            $schemaConflicts++
        }

        if ($termName -and $termDesc) {
            $termsList += [ordered]@{
                "@type"            = "DefinedTerm"
                "@id"              = "$baseUrl#$anchorId"
                "name"             = $termName
                "description"      = $termDesc
                "inDefinedTermSet" = [ordered]@{
                    "@id" = $glossaryId
                }
            }
        }
    }

    if ($termsList.Count -gt 0 -and $schemaConflicts -eq $glossaryConflictsBefore) {
        if ($manualGlossaryCount -gt 0) {
            Write-Host "  [FAIL] Duplicate DefinedTermSet schema: a manual DefinedTermSet JSON-LD block already exists alongside .ah-article-glossary. Remove the manual block so Step 3 can auto-generate it." -ForegroundColor Red
            $schemaConflicts++
        }
        else {
            $glossarySchema = [ordered]@{
                "@context"         = "https://schema.org"
                "@type"            = "DefinedTermSet"
                "@id"              = $glossaryId
                "url"              = $glossaryId
                "name"             = "$TopicName Medical Glossary"
                "description"      = "Plain-language definitions of key medical and clinical terms referenced in $TopicName."
                "inLanguage"       = "en-US"
                "mainEntityOfPage" = [ordered]@{
                    "@id" = $baseUrl
                }
                "subjectOf"        = [ordered]@{
                    "@id" = "$baseUrl#article"
                }
                "isPartOf"         = [ordered]@{
                    "@type" = "DefinedTermSet"
                    "@id"   = "https://www.aginghealth.website/p/glossary.html#glossary-hub"
                    "name"  = "Aging Health Medical & Senior Wellness Glossary"
                    "url"   = "https://www.aginghealth.website/p/glossary.html"
                }
                "hasDefinedTerm"   = $termsList
            }
            $compactGlossary = $glossarySchema | ConvertTo-Json -Depth 6 -Compress
            $generatedBlocks += "<script type=`"application/ld+json`">$compactGlossary</script>"
            $tCount = $termsList.Count
            Write-Host "  [OK] Built graph-linked DefinedTermSet schema ($tCount terms)." -ForegroundColor Green
        }
    }
}

if ($schemaConflicts -gt 0) {
    Write-Host "`nABORTED: Resolve the $schemaConflicts JSON-LD conflict or placeholder error(s) above before compiling for Blogger.`n" -ForegroundColor Red
    exit 1
}
# ==============================================================================
# STEP 4: HARDEN & PLACEHOLDER-AUDIT EXISTING MANUAL JSON-LD BLOCKS
# ==============================================================================
$script:manualBlockNum = 0
$script:manualLdErrors = 0

$snippetPlaceholders = @(
    "First question?",
    "Second question?",
    "Clear, plain-language answer.",
    "Topic Name Medical Glossary",
    "referenced in Topic Name.",
    "#term-term-slug",
    "Medical Term",
    "Plain-language definition.",
    "Key Takeaways: Article Topic",
    "Essential plain-language takeaways for older adults and caregivers.",
    "First key takeaway.",
    "Second key takeaway.",
    "Third key takeaway.",
    "Illustrative Case Scenario Title",
    "Brief summary of the patient scenario and clinical takeaway.",
    "Plain-language walkthrough of the scenario and practical lesson.",
    "Clinical Guideline or Resource Title"
)

$scriptRegex = [regex]::new(
    '<script[^>]*type=["'']application/ld\+json["''][^>]*>([\s\S]*?)</script>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

$postContent = $scriptRegex.Replace($postContent, {
        param($match)
        $script:manualBlockNum++
        $blockIdx = $script:manualBlockNum
        $rawJson = $match.Groups[1].Value.Trim()

        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} is empty." -ForegroundColor Red
            $script:manualLdErrors++
            return $match.Value
        }

        # Check for raw VS Code snippet tabstop syntax (e.g., ${1:placeholder})
        if ($rawJson -match '\$\{\d+:[^}]+\}') {
            Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} contains an unreplaced VS Code snippet tabstop." -ForegroundColor Red
            $script:manualLdErrors++
        }

        # Check for empty slug URLs (e.g., https://www.aginghealth.website/.html)
        if ($rawJson -match 'aginghealth\.website/\.html') {
            Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} has an empty post slug in its URL/@id ('aginghealth.website/.html')." -ForegroundColor Red
            $script:manualLdErrors++
        }

        # Check for unedited default strings from ah-* VS Code snippets
        foreach ($ph in $snippetPlaceholders) {
            if ($rawJson.IndexOf($ph, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} contains unreplaced snippet placeholder: '$ph'" -ForegroundColor Red
                $script:manualLdErrors++
            }
        }

        try {
            $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop

            if (-not $parsed.'@context') {
                Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} is missing required '@context'." -ForegroundColor Red
                $script:manualLdErrors++
            }
            if (-not $parsed.'@type' -and -not $parsed.'@graph') {
                Write-Host "  [FAIL] Manual JSON-LD block #${blockIdx} is missing '@type' or '@graph'." -ForegroundColor Red
                $script:manualLdErrors++
            }

            $minified = $parsed | ConvertTo-Json -Depth 10 -Compress
            return "<script type=`"application/ld+json`">$minified</script>"
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Host "  [FAIL] Invalid JSON-LD syntax in manual script block #${blockIdx}: $errMsg" -ForegroundColor Red
            $script:manualLdErrors++
            return $match.Value
        }
    })

if ($script:manualLdErrors -gt 0) {
    Write-Host "`nABORTED: Fix the $($script:manualLdErrors) manual JSON-LD error(s) above before compiling for Blogger.`n" -ForegroundColor Red
    exit 1
}

if ($script:manualBlockNum -gt 0) {
    Write-Host "  [OK] Audited and minified $($script:manualBlockNum) manual JSON-LD block(s)." -ForegroundColor Green
}
# ==============================================================================
# STEP 5: ASSEMBLE FINAL BLOGGER PAYLOAD & COPY TO CLIPBOARD
# ==============================================================================
if ($generatedBlocks.Count -gt 0) {
    $schemaWrapper = "<!-- AUTO-GENERATED-SCHEMA-START -->`n" + ($generatedBlocks -join "`n") + "`n<!-- AUTO-GENERATED-SCHEMA-END -->"
    $finalBloggerHtml = "$postContent`n`n$schemaWrapper"
}
else {
    $finalBloggerHtml = $postContent
}

$finalBloggerHtml | Set-Clipboard

Write-Host ("-" * 65) -ForegroundColor DarkGray
Write-Host "READY FOR BLOGGER ($auditWarnings warning(s)): Post HTML + minified JSON-LD copied to clipboard!" -ForegroundColor Green
Write-Host "Open Blogger -> Post -> HTML View -> Select All (Ctrl+A) -> Paste (Ctrl+V)." -ForegroundColor Cyan