param (
    [Parameter(Mandatory = $true, Position = 0)][string]$PostSlug,
    [Parameter(Mandatory = $false, Position = 1)][string]$PostTitle,
    [Parameter(Mandatory = $false, Position = 2)][string]$Description,
    [Parameter(Mandatory = $false)][string]$TemplatePath = (Join-Path $PSScriptRoot "post-preview-template.html"),
    [Parameter(Mandatory = $false)][string]$OutputDir = (Join-Path $PSScriptRoot "posts"),
    [switch]$NoOpen
)
$ErrorActionPreference = "Stop"
$cleanSlug = ($PostSlug.Trim().ToLower() -replace '\.(html|htm)$', '' -replace '[\s_]+', '-' -replace '[^a-z0-9-]', '' -replace '-{2,}', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($cleanSlug)) { Write-Host "`nABORTED: Invalid slug '$PostSlug'.`n" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { Write-Host "`nABORTED: Template not found at '$TemplatePath'.`n" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$targetFile = Join-Path $OutputDir "$cleanSlug.html"
if (Test-Path -LiteralPath $targetFile) { Write-Host "`nABORTED: Draft already exists at '$targetFile'.`n" -ForegroundColor Red; exit 1 }
if ([string]::IsNullOrWhiteSpace($PostTitle)) { $PostTitle = (Get-Culture).TextInfo.ToTitleCase(($cleanSlug -replace '-', ' ')) }
$PostTitle = $PostTitle.Trim()
$htmlTitle = [System.Net.WebUtility]::HtmlEncode($PostTitle)
$jsonTitle = ($PostTitle -replace '\\', '\\') -replace '"', '\"'
$isoNow    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
$content   = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
$content   = $content -replace 'https://www\.aginghealth\.website/post-slug\.html', "https://www.aginghealth.website/$cleanSlug.html"
$content   = $content -replace '"Post Title Preview - Aging Health"', "`"$jsonTitle - Aging Health`""
$content   = $content -replace '"Post Title Preview"', "`"$jsonTitle`""
$content   = $content -replace 'Post Title Preview', $htmlTitle
$content   = $content -replace 'Simulated Blogger Post Title \(H1 Rendered by Theme\)', $htmlTitle
$content   = $content -replace '2026-11-16T08:00:00-06:00', $isoNow
if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $jsonDesc = ($Description.Trim() -replace '\\', '\\') -replace '"', '\"'
    $content = $content -replace 'Plain-language senior health and wellness guide from Aging Health\.', $jsonDesc
}
[System.IO.File]::WriteAllText($targetFile, $content, [System.Text.UTF8Encoding]::new($false))
Write-Host "`nCreated new Aging Health post draft:" -ForegroundColor Green
Write-Host "  File : $targetFile" -ForegroundColor Cyan
Write-Host "  Slug : $cleanSlug.html" -ForegroundColor Cyan
Write-Host "  Title: $PostTitle`n" -ForegroundColor Cyan
if (-not $NoOpen) {
    $codeCmd = Get-Command code -ErrorAction SilentlyContinue
    if ($codeCmd) { & $codeCmd.Source $targetFile }
}