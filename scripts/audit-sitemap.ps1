param(
  [string]$SiteUrl = "https://www.aginghealth.website",
  [string]$BingApiKey = "f3c39fb371a14ec697c7a74c71058b07",
  [string]$KeywordMapPath = ".\scripts\keyword-map.json",
  [switch]$PingBing
)

$sitemaps = @(
  "$SiteUrl/sitemap.xml",
  "$SiteUrl/sitemap-pages.xml"
)

$allUrls = @()
$errors = @()
$redirects = @()

Write-Host "Fetching live Blogger sitemaps for $SiteUrl..." -ForegroundColor Cyan

foreach ($sm in $sitemaps) {
  try {
    [xml]$xml = (Invoke-WebRequest -Uri $sm -UseBasicParsing).Content
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("sm", "http://www.sitemaps.org/schemas/sitemap/0.9")

    $subMaps = $xml.SelectNodes("//sm:sitemap/sm:loc", $ns)
    if ($subMaps.Count -gt 0) {
      foreach ($sub in $subMaps) {
        [xml]$subXml = (Invoke-WebRequest -Uri $sub.InnerText.Trim() -UseBasicParsing).Content
        foreach ($u in $subXml.SelectNodes("//sm:url", $ns)) {
          $allUrls += [PSCustomObject]@{
            Loc     = $u.loc.Trim()
            LastMod = $u.lastmod
            Source  = $sm
          }
        }
      }
    }
    else {
      foreach ($u in $xml.SelectNodes("//sm:url", $ns)) {
        $allUrls += [PSCustomObject]@{
          Loc     = $u.loc.Trim()
          LastMod = $u.lastmod
          Source  = $sm
        }
      }
    }
  }
  catch {
    Write-Host "Failed to read $sm : $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host "Found $($allUrls.Count) total URLs across sitemaps. Auditing HTTP status, redirects & canonical rules..." -ForegroundColor Yellow

function Inspect-SitemapUrl([string]$TargetUrl) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $resp = Invoke-WebRequest -Uri $TargetUrl -Method Head -MaximumRedirection 0 -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
      return [PSCustomObject]@{
        Status   = [int]$resp.StatusCode
        FinalUrl = $TargetUrl
      }
    }
    catch {
      if ($_.Exception.Response) {
        $code = [int]$_.Exception.Response.StatusCode
        $locationHeader = $_.Exception.Response.Headers["Location"]
        if ($code -in @(301, 302, 307, 308)) {
          try {
            $finalResp = Invoke-WebRequest -Uri $TargetUrl -Method Head -MaximumRedirection 5 -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
            $dest = $finalResp.BaseResponse.ResponseUri.AbsoluteUri
            return [PSCustomObject]@{
              Status   = $code
              FinalUrl = $dest
              DestCode = [int]$finalResp.StatusCode
            }
          }
          catch {
            $destStatus = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "Unreachable ($locationHeader)" }
            return [PSCustomObject]@{
              Status   = $code
              FinalUrl = if ($locationHeader) { $locationHeader } else { "Unreachable" }
              DestCode = $destStatus
            }
          }
        }
        return [PSCustomObject]@{
          Status   = $code
          FinalUrl = $TargetUrl
        }
      }
      if ($attempt -eq 1) { Start-Sleep -Milliseconds 500 }
    }
  }
  return [PSCustomObject]@{
    Status   = "Request Failed (Timeout/DNS/Bad Redirect)"
    FinalUrl = $TargetUrl
  }
}

foreach ($entry in $allUrls) {
  $url = $entry.Loc

  if ($url -notmatch '^https://www\.aginghealth\.website/' -or $url -match '\?m=1') {
    $errors += [PSCustomObject]@{ Url = $url; Issue = "Non-canonical URL format" }
  }

  $check = Inspect-SitemapUrl -TargetUrl $url

  if ($check.Status -eq 200) {
    # Healthy direct 200 URL
  }
  elseif ($check.Status -in @(301, 302, 307, 308)) {
    if ($check.DestCode -eq 200 -and $check.FinalUrl -match '^https://www\.aginghealth\.website/') {
      $redirects += [PSCustomObject]@{
        From   = $url
        To     = $check.FinalUrl
        Status = "HTTP $($check.Status) -> 200 OK"
      }
    }
    else {
      $errors += [PSCustomObject]@{
        Url   = $url
        Issue = "Broken Redirect ($($check.Status) -> $($check.DestCode) at $($check.FinalUrl))"
      }
    }
  }
  else {
    $errors += [PSCustomObject]@{
      Url   = $url
      Issue = "HTTP $($check.Status)"
    }
  }

  Start-Sleep -Milliseconds 40
}

# Export clean local inventory
$allUrls | ConvertTo-Json -Depth 3 | Set-Content -Path ".\scripts\live-sitemap-inventory.json" -Encoding UTF8
Write-Host "Saved clean URL inventory to .\scripts\live-sitemap-inventory.json" -ForegroundColor Green

# Report verified 301/302 Custom Redirects separately
if ($redirects.Count -gt 0) {
  Write-Host "`nINFO: Verified $($redirects.Count) active Custom Redirect(s) resolving to HTTP 200:" -ForegroundColor Cyan
  $redirects | Format-Table -AutoSize
  $redirects | ConvertTo-Json -Depth 2 | Set-Content -Path ".\scripts\sitemap-redirects.json" -Encoding UTF8
}

# --- Cross-check local keyword-map.json ---
$foundMap = Get-ChildItem -Path "." -Filter "keyword-map.json" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($foundMap) { $KeywordMapPath = $foundMap.FullName }

if (Test-Path -LiteralPath $KeywordMapPath) {
  Write-Host "`nCross-checking local keyword-map.json ($KeywordMapPath)..." -ForegroundColor Cyan
  $rawMap = Get-Content -LiteralPath $KeywordMapPath -Raw -Encoding UTF8
  $mapUrlMatches = [regex]::Matches($rawMap, 'https?://(?:www\.)?aginghealth\.website/[^\s"''\},]+')
  $mapUrls = $mapUrlMatches | ForEach-Object { $_.Value.TrimEnd('/') } | Select-Object -Unique

  $liveUrlSet = @{}
  foreach ($item in $allUrls) { $liveUrlSet[$item.Loc.TrimEnd('/')] = $true }

  $redirectedSet = @{}
  foreach ($r in $redirects) { $redirectedSet[$r.From.TrimEnd('/')] = $r.To }

  $outdatedMapUrls = @()
  $redirectedMapUrls = @()
  foreach ($mUrl in $mapUrls) {
    $normalized = $mUrl -replace '^http://', 'https://'
    if (-not $liveUrlSet.ContainsKey($normalized)) {
      $outdatedMapUrls += $mUrl
    }
    elseif ($redirectedSet.ContainsKey($normalized)) {
      $redirectedMapUrls += "$mUrl  -->  $($redirectedSet[$normalized])"
    }
  }

  $mapUrlLookup = @{}
  foreach ($mUrl in $mapUrls) { $mapUrlLookup[($mUrl -replace '^http://', 'https://')] = $true }

  $unmappedLivePosts = $allUrls | Where-Object {
    $_.Loc -match '/\d{4}/\d{2}/[^/]+\.html$' -and -not $mapUrlLookup.ContainsKey($_.Loc.TrimEnd('/')) -and -not $redirectedSet.ContainsKey($_.Loc.TrimEnd('/'))
  }

  if ($outdatedMapUrls.Count -eq 0) {
    Write-Host "PASS: All $($mapUrls.Count) URLs in keyword-map.json exist in live sitemaps." -ForegroundColor Green
  }
  else {
    Write-Host "WARNING: Found $($outdatedMapUrls.Count) missing URL(s) in keyword-map.json:" -ForegroundColor Red
    $outdatedMapUrls | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  }

  if ($redirectedMapUrls.Count -gt 0) {
    Write-Host "TIP: Update these $($redirectedMapUrls.Count) redirected URL(s) in keyword-map.json to point directly to their final target:" -ForegroundColor Yellow
    $redirectedMapUrls | ForEach-Object { Write-Host "  ~ $_" -ForegroundColor Yellow }
  }

  if ($unmappedLivePosts.Count -gt 0) {
    Write-Host "INFO: $($unmappedLivePosts.Count) live blog post(s) are not yet in keyword-map.json (saved to .\scripts\unmapped-posts.txt)." -ForegroundColor Yellow
    $unmappedLivePosts.Loc | Set-Content -Path ".\scripts\unmapped-posts.txt" -Encoding UTF8
  }
  else {
    Write-Host "PASS: Every live blog post is indexed in keyword-map.json." -ForegroundColor Green
  }
}
else {
  Write-Host "`nNote: No local keyword-map.json found yet in workspace." -ForegroundColor DarkGray
}

Write-Host ""
if ($errors.Count -eq 0) {
  Write-Host "PASS: All $($allUrls.Count) sitemap URLs are healthy ($($redirects.Count) verified 301/302 redirect(s))." -ForegroundColor Green

  if ($PingBing -and -not [string]::IsNullOrWhiteSpace($BingApiKey)) {
    $feedApi = "https://ssl.bing.com/webmaster/api.svc/json/SubmitFeed?apikey=$BingApiKey"
    $body = @{ siteUrl = $SiteUrl; feedUrl = "$SiteUrl/sitemap.xml" } | ConvertTo-Json -Compress
    try {
      Invoke-RestMethod -Uri $feedApi -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
      Write-Host "Resubmitted clean sitemap.xml to Bing Webmaster Tools API." -ForegroundColor Green
    }
    catch {
      Write-Host "Bing SubmitFeed notice: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
}
else {
  Write-Host "FOUND $($errors.Count) SITEMAP ISSUES:" -ForegroundColor Red
  $errors | Format-Table -AutoSize
}