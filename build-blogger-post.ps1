param (
    [Parameter(Mandatory = $true)][string]$HtmlFilePath,
    [Parameter(Mandatory = $false)][string]$PostSlug,
    [Parameter(Mandatory = $false)][string]$TopicName
)
$ErrorActionPreference = "Stop"
function Strip-HtmlTags([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $clean = [System.Text.RegularExpressions.Regex]::Replace($Text, '<[^>]+>', ' ')
    $clean = [System.Net.WebUtility]::HtmlDecode($clean)
    return ([System.Text.RegularExpressions.Regex]::Replace($clean, '\s+', ' ')).Trim()
}
if (-not (Test-Path -LiteralPath $HtmlFilePath)) { Write-Host "`nABORTED: File not found at '$HtmlFilePath'`n" -ForegroundColor Red; exit 1 }
$rawHtml = Get-Content -LiteralPath $HtmlFilePath -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($PostSlug)) { $PostSlug = [System.IO.Path]::GetFileNameWithoutExtension($HtmlFilePath) }
$PostSlug = ($PostSlug.Trim().ToLower() -replace '\.(html|htm)$', '' -replace '[^a-z0-9-]', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($TopicName)) { $TopicName = (Get-Culture).TextInfo.ToTitleCase(($PostSlug -replace '-', ' ')) }

$pageUrl    = "https://www.aginghealth.website/$PostSlug.html"
$articleId  = "$pageUrl#article"
$authorId   = "https://www.aginghealth.website/#author"
$orgId      = "https://www.aginghealth.website/#organization"
$glossaryId = "$pageUrl#glossary"
$faqId      = "$pageUrl#faq"

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " AGING HEALTH PRE-PUBLISH AUDIT & BLOGGER COMPILER" -ForegroundColor Cyan
Write-Host " File : $(Split-Path -Leaf $HtmlFilePath)" -ForegroundColor Cyan
Write-Host " URL  : $pageUrl" -ForegroundColor Cyan
Write-Host "============================================================`n" -ForegroundColor Cyan

# STEP 1: Strip preview wrapper and extract body
$bodyHtml = [System.Text.RegularExpressions.Regex]::Replace($rawHtml, '(?s)<!--\s*PREVIEW-UI-START\s*-->.*?<!--\s*PREVIEW-UI-END\s*-->', '')
if ($bodyHtml -match '(?is)<body[^>]*>(.*)</body>') { $bodyHtml = $Matches[1].Trim() }
$bodyHtml = [System.Text.RegularExpressions.Regex]::Replace($bodyHtml, '(?s)<!--\s*AUTO-GENERATED-SCHEMA-START\s*-->.*?<!--\s*AUTO-GENERATED-SCHEMA-END\s*-->', '').Trim()

# STEP 2: Audit HTML, Headings, Links & Citations
$errors = 0; $warnings = 0
$h1Count = ([System.Text.RegularExpressions.Regex]::Matches($bodyHtml, '(?i)<h1\b')).Count
if ($h1Count -gt 0) { Write-Host "  [FAIL] Found $h1Count <h1> tag(s). Start body headings at <h2>." -ForegroundColor Red; $errors++ }
$h2Count = ([System.Text.RegularExpressions.Regex]::Matches($bodyHtml, '(?i)<h2\b')).Count
if ($h2Count -eq 0) { Write-Host "  [WARN] No <h2> section headings found." -ForegroundColor Yellow; $warnings++ }
$imgMatches = [System.Text.RegularExpressions.Regex]::Matches($bodyHtml, '(?is)<img\b[^>]*>')
foreach ($img in $imgMatches) {
    $tag = $img.Value
    if ($tag -notmatch '(?i)\balt\s*=') { Write-Host "  [FAIL] <img> missing alt attribute." -ForegroundColor Red; $errors++ }
    if ($tag -notmatch '(?i)\bwidth\s*=' -or $tag -notmatch '(?i)\bheight\s*=') { Write-Host "  [WARN] <img> missing explicit width/height." -ForegroundColor Yellow; $warnings++ }
}
if ($bodyHtml -match 'aginghealth\.website/\.html') { Write-Host "  [FAIL] Empty slug 'aginghealth.website/.html' found." -ForegroundColor Red; $errors++ }
if ($bodyHtml -match 'First question for older adults|First Medical Term|Full Study Title') { Write-Host "  [FAIL] Unreplaced snippet placeholder text found." -ForegroundColor Red; $errors++ }

# STEP 3: Auto-Compile Visible FAQ & Glossary Sections into JSON-LD
$generatedSchemas = @()
$faqSectionMatch = [System.Text.RegularExpressions.Regex]::Match($bodyHtml, '(?is)<section[^>]*class="[^"]*\bah-faq-section\b[^"]*"[^>]*>.*?</section>')
if ($faqSectionMatch.Success) {
    $detailMatches = [System.Text.RegularExpressions.Regex]::Matches($faqSectionMatch.Value, '(?is)<details[^>]*>.*?<summary[^>]*>(.*?)</summary>(.*?)</details>')
    $faqEntities = @()
    foreach ($d in $detailMatches) {
        $q = Strip-HtmlTags $d.Groups[1].Value; $a = Strip-HtmlTags $d.Groups[2].Value
        if ($q -and $a) { $faqEntities += [ordered]@{ "@type" = "Question"; "name" = $q; "acceptedAnswer" = [ordered]@{ "@type" = "Answer"; "text" = $a } } }
    }
    if ($faqEntities.Count -gt 0) {
        $faqObj = [ordered]@{ "@context" = "https://schema.org"; "@type" = "FAQPage"; "@id" = $faqId; "url" = $pageUrl; "inLanguage" = "en-US"; "isPartOf" = [ordered]@{ "@id" = $pageUrl }; "about" = [ordered]@{ "@id" = $articleId }; "author" = [ordered]@{ "@id" = $authorId }; "publisher" = [ordered]@{ "@id" = $orgId }; "mainEntity" = $faqEntities }
        $generatedSchemas += "<script type=`"application/ld+json`">" + ($faqObj | ConvertTo-Json -Depth 10 -Compress) + "</script>"
        Write-Host "  [OK]   Compiled $($faqEntities.Count) visible FAQ item(s) into FAQPage JSON-LD." -ForegroundColor Green
    }
}
$glossaryMatch = [System.Text.RegularExpressions.Regex]::Match($bodyHtml, '(?is)<section[^>]*class="[^"]*\bah-article-glossary\b[^"]*"[^>]*>.*?</section>')
if ($glossaryMatch.Success) {
    $termMatches = [System.Text.RegularExpressions.Regex]::Matches($glossaryMatch.Value, '(?is)<div[^>]*id="(term-[a-z0-9-]+)"[^>]*>.*?<dt[^>]*>(.*?)</dt>.*?<dd[^>]*>(.*?)</dd>.*?</div>')
    $definedTerms = @()
    foreach ($t in $termMatches) {
        $tid = $t.Groups[1].Value; $tname = Strip-HtmlTags $t.Groups[2].Value; $tdesc = Strip-HtmlTags $t.Groups[3].Value
        if ($tname -and $tdesc) { $definedTerms += [ordered]@{ "@type" = "DefinedTerm"; "@id" = "$pageUrl#$tid"; "name" = $tname; "description" = $tdesc; "inDefinedTermSet" = [ordered]@{ "@id" = $glossaryId } } }
    }
    if ($definedTerms.Count -gt 0) {
        $glossObj = [ordered]@{ "@context" = "https://schema.org"; "@type" = "DefinedTermSet"; "@id" = $glossaryId; "url" = $glossaryId; "name" = "$TopicName Medical Glossary"; "description" = "Plain-language definitions of key medical and clinical terms referenced in $TopicName."; "inLanguage" = "en-US"; "mainEntityOfPage" = [ordered]@{ "@id" = $pageUrl }; "subjectOf" = [ordered]@{ "@id" = $articleId }; "isPartOf" = [ordered]@{ "@type" = "DefinedTermSet"; "@id" = "https://www.aginghealth.website/p/glossary.html#glossary-hub"; "name" = "Aging Health Medical & Senior Wellness Glossary"; "url" = "https://www.aginghealth.website/p/glossary.html" }; "hasDefinedTerm" = $definedTerms }
        $generatedSchemas += "<script type=`"application/ld+json`">" + ($glossObj | ConvertTo-Json -Depth 10 -Compress) + "</script>"
        Write-Host "  [OK]   Compiled $($definedTerms.Count) visible glossary term(s) into DefinedTermSet JSON-LD." -ForegroundColor Green
    }
}

# STEP 4: Validate & Minify Manual JSON-LD Blocks
$jsonBlockRegex = [System.Text.RegularExpressions.Regex]::new('(?is)(<script\b[^>]*type\s*=\s*["'']application/ld\+json["''][^>]*>)(.*?)(</script>)')
$compiledBody = $jsonBlockRegex.Replace($bodyHtml, {
    param($m)
    try {
        $parsed = $m.Groups[2].Value.Trim() | ConvertFrom-Json -ErrorAction Stop
        return $m.Groups[1].Value + ($parsed | ConvertTo-Json -Depth 20 -Compress) + $m.Groups[3].Value
    } catch {
        $script:errors++
        Write-Host "  [FAIL] Invalid JSON-LD syntax: $($_.Exception.Message)" -ForegroundColor Red
        return $m.Value
    }
})

# STEP 5: Final Output & Clipboard Export
Write-Host "`n------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " SUMMARY: $errors Error(s) | $warnings Warning(s)" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "Green" })
Write-Host "------------------------------------------------------------`n" -ForegroundColor Cyan
if ($errors -gt 0) { Write-Host "ABORTED: Fix [FAIL] items above before copying to Blogger.`n" -ForegroundColor Red; exit 1 }

$finalPayload = $compiledBody
if ($generatedSchemas.Count -gt 0) {
    $finalPayload += "`n`n<!-- AUTO-GENERATED-SCHEMA-START -->`n" + ($generatedSchemas -join "`n") + "`n<!-- AUTO-GENERATED-SCHEMA-END -->"
}
$finalPayload | Set-Clipboard
Write-Host "READY FOR BLOGGER: Post HTML + minified JSON-LD copied to clipboard!" -ForegroundColor Green
Write-Host "Next: Open Blogger -> New/Edit Post -> Switch to HTML View -> Ctrl+A -> Ctrl+V`n" -ForegroundColor White