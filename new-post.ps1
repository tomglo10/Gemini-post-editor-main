<#
.SYNOPSIS
  Scaffolds a new Aging Health post HTML draft from post-preview-template.html,
  updates the slug, title, description, and timestamps, and opens it in VS Code.

.EXAMPLE
  .\new-post.ps1 -PostSlug "leg-pain-walking" -PostTitle "Leg Pain While Walking: Circulation vs. Nerve Compression"
  .\new-post.ps1 leg-pain-walking
#>

param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$PostSlug,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$PostTitle,

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$Description,

    [Parameter(Mandatory = $false)]
    [string]$TemplatePath = (Join-Path $PSScriptRoot "post-preview-template.html"),

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = (Join-Path $PSScriptRoot "posts"),

    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

# 1. Normalize slug into clean lowercase kebab-case
$cleanSlug = $PostSlug.Trim().ToLower() -replace '\.(html|htm)$', ''
$cleanSlug = $cleanSlug -replace '[\s_]+', '-'
$cleanSlug = $cleanSlug -replace '[^a-z0-9-]', ''
$cleanSlug = ($cleanSlug -replace '-{2,}', '-').Trim('-')

if ([string]::IsNullOrWhiteSpace($cleanSlug)) {
    Write-Host "`nABORTED: Could not derive a valid URL slug from '$PostSlug'.`n" -ForegroundColor Red
    exit 1
}

# 2. Verify template exists and ensure target file does not already exist
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    Write-Host "`nABORTED: Preview template not found at '$TemplatePath'.`n" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$targetFile = Join-Path $OutputDir "$cleanSlug.html"
if (Test-Path -LiteralPath $targetFile) {
    Write-Host "`nABORTED: Draft already exists at '$targetFile'. Choose a different slug or open the existing file.`n" -ForegroundColor Red
    exit 1
}

# 3. Derive Title-Case headline if -PostTitle was omitted
if ([string]::IsNullOrWhiteSpace($PostTitle)) {
    $textInfo = (Get-Culture).TextInfo
    $PostTitle = $textInfo.ToTitleCase(($cleanSlug -replace '-', ' '))
}
$PostTitle = $PostTitle.Trim()

# Prepare HTML-escaped and JSON-escaped variants
$htmlTitle = [System.Net.WebUtility]::HtmlEncode($PostTitle)
$jsonTitle = ($PostTitle -replace '\\', '\\') -replace '"', '\"'
$isoNow = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")

# 4. Populate template placeholders
$content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

# Update canonical URLs and @id anchors
$content = $content -replace 'https://www\.aginghealth\.website/post-slug\.html', "https://www.aginghealth.website/$cleanSlug.html"

# Update JSON-LD name/headline and HTML <title>/<h1>
$content = $content -replace '"Post Title Preview - Aging Health"', "`"$jsonTitle - Aging Health`""
$content = $content -replace '"Post Title Preview"', "`"$jsonTitle`""
$content = $content -replace 'Post Title Preview', $htmlTitle
$content = $content -replace 'Simulated Blogger Post Title \(H1 Rendered by Theme\)', $htmlTitle

# Update mock publish/modified timestamps to current local time
$content = $content -replace '2026-11-16T08:00:00-06:00', $isoNow

# Update meta/schema description if provided
if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $jsonDesc = ($Description.Trim() -replace '\\', '\\') -replace '"', '\"'
    $content = $content -replace 'Plain-language senior health and wellness guide from Aging Health\.', $jsonDesc
}

# Write UTF-8 (no BOM) file
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($targetFile, $content, $utf8NoBom)

Write-Host "`nCreated new Aging Health post draft:" -ForegroundColor Green
Write-Host "  File : $targetFile" -ForegroundColor Cyan
Write-Host "  Slug : $cleanSlug.html" -ForegroundColor Cyan
Write-Host "  Title: $PostTitle`n" -ForegroundColor Cyan

# 5. Open in VS Code unless -NoOpen is passed
if (-not $NoOpen) {
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) {
        & $codeCmd.Source $targetFile
    }
    else {
        Write-Host "[WARN] VS Code CLI ('code') not found in PATH. Open the file manually in VS Code." -ForegroundColor Yellow
    }
}