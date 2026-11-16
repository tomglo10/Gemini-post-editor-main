<#
.SYNOPSIS
  Batch-validates static JSON-LD blocks, visible FAQ/Glossary HTML sections,
  and dynamic createScholarlyArticleSchema() calls across Aging Health post files.

.EXAMPLE
  .\validate-jsonld.ps1 -Path .\posts\leg-pain-walking.html
  .\validate-jsonld.ps1 -Path .\posts
#>

param(
    [Parameter(Position = 0)]
    [string]$Path = "."
)

$ErrorActionPreference = "Stop"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawText
    )

    $noTags = [regex]::Replace($RawText, '<[^>]+>', '')
    $decoded = [System.Net.WebUtility]::HtmlDecode($noTags)
    return ([regex]::Replace($decoded, '\s+', ' ')).Trim()
}

function Convert-JsLiteralToJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsText
    )

    # Quote unquoted JS object keys and normalize single-quoted strings without touching double-quoted text
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
    param(
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

            # Skip function declaration in theme/preview template files
            $prefix = $scriptBody.Substring([Math]::Max(0, $fnIndex - 15), [Math]::Min(15, $fnIndex))
            if ($prefix -match 'function\s+$') {
                $searchPos = $fnIndex + 28
                continue
            }

            $openParen = $scriptBody.IndexOf("(", $fnIndex + 28)
            if ($openParen -lt 0) { break }

            # Balanced parenthesis scanner (respects quotes and escapes)
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

# ==============================================================================
# PLACEHOLDER DICTIONARIES (Synced with build-blogger-post.ps1 & html.json)
# ==============================================================================
$jsonLdSnippetPlaceholders = @(
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

# ==============================================================================
# RESOLVE TARGET HTML FILES
# ==============================================================================
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "[ERROR] Path not found: $Path" -ForegroundColor Red
    exit 1
}

$targetItem = Get-Item -LiteralPath $Path
$isDirectoryScan = $targetItem.PSIsContainer

$htmlFiles = if ($isDirectoryScan) {
    Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object { $_.Extension -in @('.html', '.htm') }
}
else {
    if ($targetItem.Extension -notin @('.html', '.htm')) {
        Write-Host "[ERROR] Expected an .html or .htm file, got '$($targetItem.Extension)' ($($targetItem.Name))." -ForegroundColor Red
        exit 1
    }
    @($targetItem)
}

if ($htmlFiles.Count -eq 0) {
    Write-Host "[WARN] No .html or .htm files found at $Path" -ForegroundColor Yellow
    exit 0
}

$totalFilesAudited = 0
$totalErrors = 0
$totalWarnings = 0

foreach ($file in $htmlFiles) {
    # Skip starter preview template automatically during folder-wide batch scans
    if ($isDirectoryScan -and $file.Name -eq "post-preview-template.html") {
        Write-Host "[SKIP] $($file.Name) (starter preview template)" -ForegroundColor DarkGray
        continue
    }

    $totalFilesAudited++
    $rawHtml = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    # Extract <body> if present, then strip Live Server preview UI and auto-generated schema wrappers
    $bodyMatch = [regex]::Match($rawHtml, '<body[^>]*>([\s\S]*?)</body>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $content = if ($bodyMatch.Success) { $bodyMatch.Groups[1].Value.Trim() } else { $rawHtml.Trim() }
    $content = [regex]::Replace($content, '<!-- PREVIEW-UI-START -->[\s\S]*?<!-- PREVIEW-UI-END -->\s*', '')
    $content = [regex]::Replace($content, '<!-- AUTO-GENERATED-SCHEMA-START -->[\s\S]*?<!-- AUTO-GENERATED-SCHEMA-END -->\s*', '')

    $fileErrors = @()
    $fileWarnings = @()
    $manualSchemaTypes = @()

    # --------------------------------------------------------------------------
    # 1. Validate Manual <script type="application/ld+json"> Blocks
    # --------------------------------------------------------------------------
    $jsonLdMatches = [regex]::Matches($content, '(?is)<script\b[^>]*type\s*=\s*[''"]application/ld\+json[''"][^>]*>(.*?)</script>')
    $blockNum = 0

    foreach ($jm in $jsonLdMatches) {
        $blockNum++
        $rawJson = $jm.Groups[1].Value.Trim()

        if ([string]::IsNullOrWhiteSpace($rawJson)) {
            $fileErrors += "JSON-LD block #${blockNum}: Empty script block."
            continue
        }

        if ($rawJson -match '\$\{\d+:[^}]+\}') {
            $fileErrors += "JSON-LD block #${blockNum}: Unreplaced VS Code snippet tabstop found."
        }

        if ($rawJson -match 'aginghealth\.website/\.html') {
            $fileErrors += "JSON-LD block #${blockNum}: Empty post slug in URL/@id ('aginghealth.website/.html')."
        }

        if ($rawJson -match '"@isPartOf"') {
            $fileErrors += "JSON-LD block #${blockNum}: Invalid '@isPartOf' property (remove '@')."
        }

        foreach ($ph in $jsonLdSnippetPlaceholders) {
            if ($rawJson.IndexOf($ph, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $fileErrors += "JSON-LD block #${blockNum}: Unreplaced snippet placeholder '$ph'."
            }
        }

        try {
            $parsedJson = $rawJson | ConvertFrom-Json -ErrorAction Stop
            if (-not $parsedJson.'@context') {
                $fileErrors += "JSON-LD block #${blockNum}: Missing '@context'."
            }
            if (-not $parsedJson.'@type' -and -not $parsedJson.'@graph') {
                $fileErrors += "JSON-LD block #${blockNum}: Missing '@type' or '@graph'."
            }

            $nodes = if ($parsedJson.'@graph') { @($parsedJson.'@graph') } else { @($parsedJson) }
            foreach ($node in $nodes) {
                if ($node.'@type') {
                    $manualSchemaTypes += @($node.'@type')
                }
            }
        }
        catch {
            $fileErrors += "JSON-LD block #${blockNum}: Invalid JSON syntax - $($_.Exception.Message)"
        }
    }

    $manualFaqCount = ($manualSchemaTypes | Where-Object { $_ -eq 'FAQPage' }).Count
    $manualGlossaryCount = ($manualSchemaTypes | Where-Object { $_ -eq 'DefinedTermSet' }).Count

    if ($manualFaqCount -gt 1) {
        $fileErrors += "Found $manualFaqCount manual FAQPage JSON-LD blocks (only 1 allowed per page)."
    }
    if ($manualGlossaryCount -gt 1) {
        $fileErrors += "Found $manualGlossaryCount manual DefinedTermSet JSON-LD blocks."
    }

    # --------------------------------------------------------------------------
    # 2. Validate Visible .ah-faq-section & .ah-article-glossary HTML Sources
    # --------------------------------------------------------------------------
    $faqSectionMatch = [regex]::Match(
        $content,
        '<section[^>]*class=["''][^"'']*ah-faq-section[^"'']*["''][^>]*>([\s\S]*?)</section>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($faqSectionMatch.Success) {
        $faqHtml = $faqSectionMatch.Groups[1].Value
        if ($faqHtml -match '\$\{\d+:[^}]+\}') {
            $fileErrors += ".ah-faq-section: Unreplaced VS Code snippet tabstop found."
        }

        $detailsRegex = [regex]::new('<details[^>]*>[\s\S]*?<summary[^>]*>([\s\S]*?)</summary>([\s\S]*?)</details>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $faqMatches = $detailsRegex.Matches($faqHtml)
        $faqIdx = 0

        foreach ($fm in $faqMatches) {
            $faqIdx++
            $qText = ConvertTo-PlainText -RawText $fm.Groups[1].Value
            $aText = ConvertTo-PlainText -RawText $fm.Groups[2].Value

            if ($faqHtmlPlaceholders -contains $qText) {
                $fileErrors += "FAQ item #${faqIdx}: Unreplaced placeholder question '$qText'."
            }
            if ($faqHtmlPlaceholders -contains $aText) {
                $fileErrors += "FAQ item #${faqIdx}: Unreplaced placeholder answer '$aText'."
            }
        }

        if ($faqMatches.Count -gt 0 -and $manualFaqCount -gt 0) {
            $fileErrors += "Duplicate FAQPage schema: manual FAQPage JSON-LD exists alongside .ah-faq-section."
        }
    }

    $glossarySectionMatch = [regex]::Match(
        $content,
        '<section[^>]*class=["''][^"'']*ah-article-glossary[^"'']*["''][^>]*>([\s\S]*?)</section>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($glossarySectionMatch.Success) {
        $glossaryHtml = $glossarySectionMatch.Groups[1].Value
        if ($glossaryHtml -match '\$\{\d+:[^}]+\}') {
            $fileErrors += ".ah-article-glossary: Unreplaced VS Code snippet tabstop found."
        }

        $termRegex = [regex]::new('<div[^>]*id=["''](term-[^"'']+)["''][^>]*>[\s\S]*?<dt[^>]*>([\s\S]*?)</dt>[\s\S]*?<dd[^>]*>([\s\S]*?)</dd>[\s\S]*?</div>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $termMatches = $termRegex.Matches($glossaryHtml)
        $termIdx = 0

        foreach ($tm in $termMatches) {
            $termIdx++
            $anchorId = $tm.Groups[1].Value.Trim()
            $termName = ConvertTo-PlainText -RawText $tm.Groups[2].Value
            $termDesc = ConvertTo-PlainText -RawText $tm.Groups[3].Value

            if ($glossaryIdPlaceholders -contains $anchorId) {
                $fileErrors += "Glossary term #${termIdx}: Unreplaced placeholder anchor ID '$anchorId'."
            }
            if ($glossaryTextPlaceholders -contains $termName) {
                $fileErrors += "Glossary term #${termIdx}: Unreplaced placeholder term name '$termName'."
            }
            if ($glossaryTextPlaceholders -contains $termDesc) {
                $fileErrors += "Glossary term #${termIdx}: Unreplaced placeholder definition '$termDesc'."
            }
        }

        if ($termMatches.Count -gt 0 -and $manualGlossaryCount -gt 0) {
            $fileErrors += "Duplicate DefinedTermSet schema: manual DefinedTermSet JSON-LD exists alongside .ah-article-glossary."
        }
    }

    # Verify local #term-... anchor links match id="term-..." attributes
    $localTermLinks = [regex]::Matches($content, 'href\s*=\s*["'']#(term-[^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($tl in $localTermLinks) {
        $targetId = $tl.Groups[1].Value
        if ($content -notmatch ("id\s*=\s*['""]" + [regex]::Escape($targetId) + "['""]")) {
            $fileErrors += "Broken internal anchor: href='#$targetId' has no matching id='$targetId'."
        }
    }

    # --------------------------------------------------------------------------
    # 3. Validate Dynamic createScholarlyArticleSchema(...) Calls
    # --------------------------------------------------------------------------
    $citationCalls = Get-ScholarlyCitationCalls -HtmlContent $content
    $callNum = 0

    foreach ($call in $citationCalls) {
        $callNum++

        if ($call.Unclosed) {
            $fileErrors += "Citation call #${callNum}: Unclosed parenthesis in createScholarlyArticleSchema(...)."
            continue
        }

        if (-not $call.HasTypeofGuard) {
            $fileWarnings += "Citation call #${callNum}: Missing 'if (typeof createScholarlyArticleSchema === ''function'')' guard."
        }

        if ($call.RawArgument -match '\$\{\d+:[^}]+\}') {
            $fileErrors += "Citation call #${callNum}: Unreplaced VS Code snippet tabstop found."
        }

        try {
            $jsonReady = Convert-JsLiteralToJson -JsText $call.RawArgument
            $parsedArg = $jsonReady | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $fileErrors += "Citation call #${callNum}: Could not parse JS object/array argument - $($_.Exception.Message)"
            continue
        }

        $studies = @($parsedArg)
        if ($studies.Count -eq 0) {
            $fileErrors += "Citation call #${callNum}: Citation array is empty."
            continue
        }

        for ($idx = 0; $idx -lt $studies.Count; $idx++) {
            $study = $studies[$idx]
            $label = "Citation call #${callNum}, study #$($idx + 1)"

            $title = "$($study.title)".Trim()
            if ([string]::IsNullOrWhiteSpace($title)) {
                $fileErrors += "${label}: Missing required 'title'."
            }
            elseif ($title -eq "Full Study Title") {
                $fileErrors += "${label}: Unreplaced placeholder title ('Full Study Title')."
            }

            $authors = @($study.authors) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }
            if ($authors.Count -eq 0) {
                $fileWarnings += "${label}: 'authors' array is empty."
            }
            elseif ($authors -contains "First Author" -or $authors -contains "Second Author") {
                $fileErrors += "${label}: Unreplaced placeholder author name."
            }

            $yearStr = "$($study.year)".Trim()
            if ($yearStr -notmatch '^(19|20)\d{2}$') {
                $fileErrors += "${label}: Invalid or missing 4-digit 'year' ('$yearStr')."
            }

            $journal = "$($study.journal)".Trim()
            if ([string]::IsNullOrWhiteSpace($journal)) {
                $fileWarnings += "${label}: Missing 'journal' name."
            }
            elseif ($journal -eq "Journal Name") {
                $fileErrors += "${label}: Unreplaced placeholder journal ('Journal Name')."
            }

            $pmid = "$($study.pmid)".Trim()
            $pmcid = "$($study.pmcid)".Trim()
            $doi = "$($study.doi)".Trim()

            if ([string]::IsNullOrWhiteSpace($pmid) -and [string]::IsNullOrWhiteSpace($pmcid) -and [string]::IsNullOrWhiteSpace($doi)) {
                $fileWarnings += "${label}: No pmid, pmcid, or doi provided (schema will lack url and sameAs links)."
            }
            if (-not [string]::IsNullOrWhiteSpace($pmid) -and $pmid -notmatch '^\d+$') {
                $fileErrors += "${label}: Invalid PMID '$pmid' (expected digits only)."
            }
            if (-not [string]::IsNullOrWhiteSpace($pmcid) -and $pmcid -notmatch '^(?i)(PMC)?\d+$') {
                $fileErrors += "${label}: Invalid PMCID '$pmcid' (expected digits or PMC + digits)."
            }
            if (-not [string]::IsNullOrWhiteSpace($doi) -and $doi -notmatch '^(?i)(https?://(dx\.)?doi\.org/)?10\.\d{4,9}/\S+$') {
                $fileErrors += "${label}: Invalid DOI '$doi'."
            }
        }
    }

    # --------------------------------------------------------------------------
    # 4. Report File Results
    # --------------------------------------------------------------------------
    if ($fileErrors.Count -eq 0 -and $fileWarnings.Count -eq 0) {
        Write-Host "[PASS] $($file.Name) ($($jsonLdMatches.Count) JSON-LD block(s), $($citationCalls.Count) citation call(s))" -ForegroundColor Green
    }
    else {
        Write-Host "[FILE] $($file.Name)" -ForegroundColor Cyan
        foreach ($err in $fileErrors) {
            Write-Host "  [ERROR] $err" -ForegroundColor Red
        }
        foreach ($warn in $fileWarnings) {
            Write-Host "  [WARN]  $warn" -ForegroundColor Yellow
        }
    }

    $totalErrors += $fileErrors.Count
    $totalWarnings += $fileWarnings.Count
}

Write-Host "`nSummary: $totalFilesAudited file(s) audited | $totalErrors error(s) | $totalWarnings warning(s)" -ForegroundColor White

if ($totalErrors -gt 0) {
    exit 1
}
exit 0