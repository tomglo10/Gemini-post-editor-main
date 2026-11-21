param(
    [Parameter(Mandatory = $true)]
    [string]$Url
)

$apiKey = "6e49503ffeec4a76b3cc21adf5160cda"
$endpoint = "https://api.indexnow.org/indexnow?url=$([uri]::EscapeDataString($Url))&key=$apiKey"

try {
    $response = Invoke-WebRequest -Uri $endpoint -Method Get -UseBasicParsing
    Write-Host "IndexNow Ping Sent! Status: $($response.StatusCode) for $Url" -ForegroundColor Green
}
catch {
    Write-Host "IndexNow Ping Failed: $($_.Exception.Message)" -ForegroundColor Red
}
