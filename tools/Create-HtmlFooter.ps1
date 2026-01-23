# Create-HtmlFooter.ps1
# Helper tool to create HTML footer with inline logo

param(
    [Parameter(Mandatory)]
    [string]$Name,
    
    [string]$Title,
    [string]$Email,
    [string]$Website,
    [string]$LogoPath
)

Write-Host ""
Write-Host "Creating HTML footer..." -ForegroundColor Cyan

$html = @"
<div style="margin-top: 20px; padding-top: 10px; border-top: 1px solid #ccc;">
  <p style="margin: 0; font-family: Arial, sans-serif; font-size: 14px; color: #333;">
    <strong>$Name</strong><br>
"@

if ($Title) { 
    $html += "    $Title<br>`n" 
}

if ($Email) { 
    $html += "    📧 <a href=`"mailto:$Email`" style=`"color: #0066cc; text-decoration: none;`">$Email</a><br>`n" 
}

if ($Website) { 
    $html += "    🌐 <a href=`"$Website`" style=`"color: #0066cc; text-decoration: none;`">$Website</a><br>`n" 
}

$html += "  </p>`n"

# Add logo if provided
if ($LogoPath -and (Test-Path $LogoPath)) {
    Write-Host "Converting logo to data URI..." -ForegroundColor DarkGray
    
    $bytes = [System.IO.File]::ReadAllBytes($LogoPath)
    $base64 = [Convert]::ToBase64String($bytes)
    $ext = [System.IO.Path]::GetExtension($LogoPath).ToLower()
    $mimeType = switch ($ext) {
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".gif"  { "image/gif" }
        ".svg"  { "image/svg+xml" }
        default { "image/png" }
    }
    
    $sizeKB = [math]::Round($bytes.Length / 1024, 1)
    Write-Host "  Logo size: $sizeKB KB" -ForegroundColor DarkGray
    
    if ($sizeKB -gt 100) {
        Write-Host "  Warning: Logo is large ($sizeKB KB). Consider using a smaller image." -ForegroundColor Yellow
    }
    
    $html += @"
  <img src="data:$mimeType;base64,$base64" 
       alt="Logo" 
       width="120" 
       style="margin-top: 10px; display: block;">
"@
} elseif ($LogoPath) {
    Write-Host "  Warning: Logo file not found: $LogoPath" -ForegroundColor Yellow
}

$html += "`n</div>"

# Save to data folder
$dataFolder = Join-Path $PSScriptRoot "..\data"
if (-not (Test-Path $dataFolder)) {
    New-Item -Path $dataFolder -ItemType Directory -Force | Out-Null
}

$outputPath = Join-Path $dataFolder "footer.html"
$html | Out-File -FilePath $outputPath -Encoding utf8 -NoNewline

Write-Host ""
Write-Host "✓ HTML footer created: $outputPath" -ForegroundColor Green
Write-Host ""
Write-Host "From now on, all new emails will be sent as HTML with this footer." -ForegroundColor Cyan
Write-Host "To switch back to plain text, delete or rename footer.html" -ForegroundColor DarkGray
Write-Host ""
