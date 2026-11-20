<#
.SYNOPSIS
  Validates a Blogger XML theme file for well-formed XML, CDATA safety,
  duplicate section/widget IDs, Blogger namespaces, and static JSON-LD blocks.

.EXAMPLE
  .\scripts\validate-blogger-xml.ps1
  .\scripts\validate-blogger-xml.ps1 -XmlFilePath .\theme\tdmag-theme.xml
#>

param(
    [Parameter(Mandatory = $false, Position = 0)]
    [AllowEmptyString()]
    [string]$XmlFilePath = ""
)

$ErrorActionPreference = "Stop"
$workspaceRoot = Split-Path -Parent $PSScriptRoot

# ==============================================================================
# STEP 0: RESOLVE TARGET XML FILE ("__PICK__", AUTO-DETECT, OR EXPLICIT PATH)
# ==============================================================================
if ($XmlFilePath -eq "__PICK__") {
    $candidates = @(
        Get-ChildItem -Path $workspaceRoot -Recurse -Filter "*.xml" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(sitemap|robots|feed|rss|atom)' } |
        Sort-Object LastWriteTime -Descending
    )

    if ($candidates.Count -eq 0) {
        Write-Host "`nERROR: No Blogger theme .xml files found in $workspaceRoot`n" -ForegroundColor Red
        exit 1
    }

    $selected = $candidates |
    Select-Object @{Name = "Theme XML File"; Expression = { $_.Name } },
    @{Name = "Folder"; Expression = { $_.Directory.Name } },
    @{Name = "Last Modified"; Expression = { $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm") } },
    FullName |
    Out-GridView -Title "Select a Blogger XML Theme File to Validate" -OutputMode Single

    if (-not $selected) {
        Write-Host "`nValidation cancelled.`n" -ForegroundColor Yellow
        exit 0
    }

    $XmlFilePath = $selected.FullName
}
elseif ([string]::IsNullOrWhiteSpace($XmlFilePath) -or ($XmlFilePath -notmatch '\.xml$')) {
    if (-not [string]::IsNullOrWhiteSpace($XmlFilePath) -and ($XmlFilePath -notmatch '\.xml$')) {
        Write-Host "Active file is not a .xml theme. Searching workspace for newest Blogger theme .xml..." -ForegroundColor DarkYellow
    }

    $latestXml = Get-ChildItem -Path $workspaceRoot -Recurse -Filter "*.xml" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(sitemap|robots|feed|rss|atom)' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    if (-not $latestXml) {
        Write-Host "`nERROR: No Blogger theme .xml file found in $workspaceRoot" -ForegroundColor Red
        Write-Host "Export a backup from Blogger (Theme -> Customize -> Back up) into your workspace and re-run.`n" -ForegroundColor Yellow
        exit 1
    }

    $XmlFilePath = $latestXml.FullName
}
elseif (-not (Test-Path -LiteralPath $XmlFilePath)) {
    $candidatePath = Join-Path $workspaceRoot $XmlFilePath
    if (Test-Path -LiteralPath $candidatePath) {
        $XmlFilePath = $candidatePath
    }
}

if (-not (Test-Path -LiteralPath $XmlFilePath -PathType Leaf)) {
    Write-Host "`nERROR: XML file not found at '$XmlFilePath'`n" -ForegroundColor Red
    exit 1
}

$xmlFile = Get-Item -LiteralPath $XmlFilePath
$rawXml = Get-Content -LiteralPath $xmlFile.FullName -Raw -Encoding UTF8
$lines = Get-Content -LiteralPath $xmlFile.FullName -Encoding UTF8

Write-Host "`nValidating Blogger XML Theme: $($xmlFile.FullName)" -ForegroundColor Cyan
Write-Host ("-" * 70) -ForegroundColor DarkGray

$errors = 0
$warnings = 0

# ==============================================================================
# CHECK 1: STRICT WELL-FORMED XML PARSE (WITH EXACT LINE/COLUMN CONTEXT)
# ==============================================================================
$xmlDoc = New-Object System.Xml.XmlDocument
$xmlDoc.PreserveWhitespace = $true

$readerSettings = New-Object System.Xml.XmlReaderSettings
$readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
$readerSettings.XmlResolver = $null

$stringReader = New-Object System.IO.StringReader($rawXml)
$xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)

try {
    $xmlDoc.Load($xmlReader)
    Write-Host "  [OK] Well-formed XML syntax verified ($($lines.Count) lines)." -ForegroundColor Green
}
catch [System.Xml.XmlException] {
    $ex = $_.Exception
    $errLine = $ex.LineNumber
    $errPos = $ex.LinePosition

    Write-Host "  [FAIL] XML Syntax Error at Line $errLine, Column $errPos" -ForegroundColor Red
    Write-Host "         $($ex.Message)" -ForegroundColor Red

    if ($errLine -gt 0 -and $errLine -le $lines.Count) {
        $start = [Math]::Max(1, $errLine - 2)
        $end = [Math]::Min($lines.Count, $errLine + 2)
        Write-Host "`n  --- Context around Line $errLine ---" -ForegroundColor Yellow
        for ($ln = $start; $ln -le $end; $ln++) {
            $marker = if ($ln -eq $errLine) { ">>" } else { "  " }
            $color = if ($ln -eq $errLine) { "Red" } else { "DarkGray" }
            Write-Host ("  $marker {0,5}: {1}" -f $ln, $lines[$ln - 1]) -ForegroundColor $color
        }
        Write-Host ""
    }

    Write-Host "  Tip: Common causes are an unclosed <b:if>/<b:widget> tag, an unquoted attribute," -ForegroundColor DarkYellow
    Write-Host "       or an unescaped '&' or '<' inside a <script> block missing //<![CDATA[ ... //]]>." -ForegroundColor DarkYellow
    Write-Host "`nABORTED: Fix the XML syntax error above before uploading to Blogger.`n" -ForegroundColor Red
    exit 1
}
finally {
    $xmlReader.Dispose()
    $stringReader.Dispose()
}

# ==============================================================================
# CHECK 2: BLOGGER XML NAMESPACES ON ROOT <html ...> ELEMENT
# ==============================================================================
$rootNode = $xmlDoc.DocumentElement
if ($null -eq $rootNode -or $rootNode.LocalName -ne "html") {
    Write-Host "  [FAIL] Root element must be <html> (found '$($rootNode.LocalName)')." -ForegroundColor Red
    $errors++
}
else {
    $requiredNamespaces = @{
        "xmlns:b"    = "http://www.google.com/2005/gml/b"
        "xmlns:data" = "http://www.google.com/2005/gml/data"
        "xmlns:expr" = "http://www.google.com/2005/gml/expr"
    }

    $nsMissing = $false
    foreach ($nsAttr in $requiredNamespaces.Keys) {
        $val = $rootNode.GetAttribute($nsAttr)
        if ($val -ne $requiredNamespaces[$nsAttr]) {
            Write-Host "  [FAIL] Missing or invalid $nsAttr on <html> (expected '$($requiredNamespaces[$nsAttr])')." -ForegroundColor Red
            $errors++
            $nsMissing = $true
        }
    }

    if (-not $nsMissing) {
        Write-Host "  [OK] Blogger XML namespaces (b, data, expr) verified on <html>." -ForegroundColor Green
    }
}

# ==============================================================================
# CHECK 3: <b:skin> PRESENCE & CDATA WRAPPER
# ==============================================================================
$nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
$nsMgr.AddNamespace("b", "http://www.google.com/2005/gml/b")
$nsMgr.AddNamespace("data", "http://www.google.com/2005/gml/data")
$nsMgr.AddNamespace("expr", "http://www.google.com/2005/gml/expr")

$skinNodes = $xmlDoc.SelectNodes("//b:skin", $nsMgr)
if ($skinNodes.Count -eq 0) {
    Write-Host "  [FAIL] Missing required <b:skin> tag (Blogger rejects themes without <b:skin>)." -ForegroundColor Red
    $errors++
}
elseif ($skinNodes.Count -gt 1) {
    Write-Host "  [FAIL] Found $($skinNodes.Count) <b:skin> tags (only 1 is allowed per Blogger theme)." -ForegroundColor Red
    $errors++
}
else {
    $hasCdata = $false
    foreach ($child in $skinNodes[0].ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::CDATA) {
            $hasCdata = $true
            break
        }
    }
    if (-not $hasCdata) {
        Write-Host "  [WARN] <b:skin> does not wrap its CSS inside <![CDATA[ ... ]]>." -ForegroundColor Yellow
        $warnings++
    }
    else {
        Write-Host "  [OK] Verified single <b:skin> with <![CDATA[ ... ]]> wrapper." -ForegroundColor Green
    }
}

# ==============================================================================
# CHECK 4: DUPLICATE <b:section> AND <b:widget> IDs (STRICT BLOGGER UPLOAD CHECK)
# ==============================================================================
$seenSectionIds = @{}
$sectionNodes = $xmlDoc.SelectNodes("//b:section", $nsMgr)
foreach ($sec in $sectionNodes) {
    $secId = $sec.GetAttribute("id")
    if ([string]::IsNullOrWhiteSpace($secId)) {
        Write-Host "  [FAIL] Found a <b:section> missing a required 'id' attribute." -ForegroundColor Red
        $errors++
    }
    elseif ($seenSectionIds.ContainsKey($secId)) {
        Write-Host "  [FAIL] Duplicate <b:section id='$secId'> found (Blogger requires unique section IDs)." -ForegroundColor Red
        $errors++
    }
    else {
        $seenSectionIds[$secId] = $true
    }
}

$seenWidgetIds = @{}
$widgetNodes = $xmlDoc.SelectNodes("//b:widget", $nsMgr)
foreach ($wid in $widgetNodes) {
    $widId = $wid.GetAttribute("id")
    $widType = $wid.GetAttribute("type")

    if ([string]::IsNullOrWhiteSpace($widId)) {
        Write-Host "  [FAIL] Found a <b:widget> missing a required 'id' attribute." -ForegroundColor Red
        $errors++
    }
    elseif ($seenWidgetIds.ContainsKey($widId)) {
        Write-Host "  [FAIL] Duplicate <b:widget id='$widId'> found (Blogger rejects duplicate widget IDs)." -ForegroundColor Red
        $errors++
    }
    else {
        $seenWidgetIds[$widId] = $true
    }

    if ([string]::IsNullOrWhiteSpace($widType)) {
        Write-Host "  [FAIL] <b:widget id='$widId'> is missing a required 'type' attribute." -ForegroundColor Red
        $errors++
    }
}

Write-Host "  [OK] Audited $($sectionNodes.Count) <b:section> and $($widgetNodes.Count) <b:widget> elements." -ForegroundColor Green

# ==============================================================================
# CHECK 5: INLINE <script> CDATA SAFETY & STATIC JSON-LD SYNTAX
# ==============================================================================
$allScripts = $xmlDoc.GetElementsByTagName("script")
$unwrappedScripts = 0
$ldBlocksChecked = 0

foreach ($scr in $allScripts) {
    $srcAttr = $scr.GetAttribute("src")
    $typeAttr = $scr.GetAttribute("type").Trim().ToLowerInvariant()
    $innerRaw = $scr.InnerText.Trim()

    # Skip external scripts with src="..." and empty bodies
    if (-not [string]::IsNullOrWhiteSpace($srcAttr) -or [string]::IsNullOrWhiteSpace($innerRaw)) {
        continue
    }

    # Validate static JSON-LD blocks (skip dynamic ones containing <b:...> or <data:...> tags)
    if ($typeAttr -eq "application/ld+json") {
        $ldBlocksChecked++
        if ($scr.InnerXml -notmatch '<(b|data|expr):') {
            try {
                $null = $innerRaw | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                Write-Host "  [FAIL] Invalid JSON-LD syntax inside theme <script type='application/ld+json'>: $($_.Exception.Message)" -ForegroundColor Red
                $errors++
            }
        }
        continue
    }

    # Check whether inline JavaScript uses a CDATA node
    $scriptHasCdata = $false
    foreach ($c in $scr.ChildNodes) {
        if ($c.NodeType -eq [System.Xml.XmlNodeType]::CDATA) {
            $scriptHasCdata = $true
            break
        }
    }

    if (-not $scriptHasCdata -and $innerRaw.Length -gt 20) {
        $unwrappedScripts++
    }
}

if ($unwrappedScripts -gt 0) {
    Write-Host "  [WARN] Found $unwrappedScripts inline <script> block(s) without //<![CDATA[ ... //]]> wrappers." -ForegroundColor Yellow
    Write-Host "         Future edits containing '&&' or '<' inside those blocks will break Blogger XML parsing." -ForegroundColor DarkYellow
    $warnings++
}
else {
    Write-Host "  [OK] Inline <script> CDATA safety and $ldBlocksChecked JSON-LD block(s) verified." -ForegroundColor Green
}

# ==============================================================================
# CHECK 6: CORE BLOGGER HEAD INCLUDE
# ==============================================================================
if ($rawXml -notmatch "all-head-content") {
    Write-Host "  [WARN] Could not find <b:include data='blog' name='all-head-content'/> in theme." -ForegroundColor Yellow
    $warnings++
}
else {
    Write-Host "  [OK] Verified Blogger 'all-head-content' head include." -ForegroundColor Green
}

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Host ("-" * 70) -ForegroundColor DarkGray
if ($errors -gt 0) {
    Write-Host "FAILED: Found $errors error(s) and $warnings warning(s). Fix [FAIL] items before uploading.`n" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "PASS: Blogger XML theme is valid ($warnings warning(s)) and safe to upload to Blogger.`n" -ForegroundColor Green
    exit 0
}
