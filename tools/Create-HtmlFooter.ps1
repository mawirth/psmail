# Create-HtmlFooter.ps1
# Helper tool to create account-specific text and HTML footers

param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$Title,
    [string]$Email,
    [string]$Website,
    [string]$Phone,
    [string]$Mobile,
    [string[]]$AddressLines,
    [string]$CertificationText,
    [string]$CertificationUrl,
    [string]$Signoff = "Mit freundlichen Grüßen,",
    [string]$LogoPath,
    [string]$AccountKey,
    [switch]$WriteTextFooter
)

function Resolve-TargetFolder {
    param([string]$ExplicitAccountKey)

    $dataFolder = Join-Path $PSScriptRoot "..\data"
    $accountsFolder = Join-Path $dataFolder "accounts"

    if ($ExplicitAccountKey) {
        return (Join-Path $accountsFolder $ExplicitAccountKey)
    }

    $accountDirs = @()
    if (Test-Path $accountsFolder) {
        $accountDirs = @(Get-ChildItem -Path $accountsFolder -Directory)
    }

    if ($accountDirs.Count -eq 1) {
        Write-Host "Using account: $($accountDirs[0].Name)" -ForegroundColor DarkGray
        return $accountDirs[0].FullName
    }

    if ($accountDirs.Count -gt 1) {
        Write-Host "Multiple account folders found. Please specify -AccountKey." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Available account keys:" -ForegroundColor DarkGray
        foreach ($dir in $accountDirs) {
            Write-Host "  $($dir.Name)" -ForegroundColor DarkGray
        }
        Write-Host ""
        throw "AccountKey required when multiple account folders exist."
    }

    throw "No account folder found. Start psmail and log in once before creating a footer."
}

function Test-ValuePresent {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value)
}

function ConvertTo-HtmlText {
    param([string]$Value)
    if (-not (Test-ValuePresent $Value)) {
        return ""
    }
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-LinkHtml {
    param(
        [string]$Href,
        [string]$Label
    )

    if (-not (Test-ValuePresent $Href)) {
        return ""
    }

    $safeHref = [System.Net.WebUtility]::HtmlEncode($Href)
    $safeLabel = ConvertTo-HtmlText $(if (Test-ValuePresent $Label) { $Label } else { $Href })
    return "<a href=`"$safeHref`" style=`"color: #1a5fb4; text-decoration: none;`">$safeLabel</a>"
}

function Build-TextFooter {
    $lines = [System.Collections.Generic.List[string]]::new()

    if (Test-ValuePresent $Signoff) {
        $lines.Add($Signoff)
        $lines.Add("")
    }

    $lines.Add($Name)

    if (Test-ValuePresent $Title) {
        $lines.Add($Title)
    }
    if (Test-ValuePresent $CertificationText) {
        $lines.Add($CertificationText)
    }
    if ($AddressLines) {
        foreach ($line in $AddressLines) {
            if (Test-ValuePresent $line) {
                $lines.Add($line)
            }
        }
    }
    if (Test-ValuePresent $Email) {
        $lines.Add($Email)
    }
    if (Test-ValuePresent $Phone) {
        $lines.Add("Telefon: $Phone")
    }
    if (Test-ValuePresent $Mobile) {
        $lines.Add("Mobil: $Mobile")
    }
    if (Test-ValuePresent $Website) {
        $lines.Add($Website)
    }
    if (Test-ValuePresent $CertificationUrl) {
        $lines.Add($CertificationUrl)
    }

    return (($lines | Where-Object { $_ -ne $null }) -join "`r`n").TrimEnd()
}

function Build-HtmlFooter {
    $detailLines = [System.Collections.Generic.List[string]]::new()

    $detailLines.Add("<strong>$(ConvertTo-HtmlText $Name)</strong>")

    if (Test-ValuePresent $Title) {
        $detailLines.Add((ConvertTo-HtmlText $Title))
    }
    if (Test-ValuePresent $CertificationText) {
        $detailLines.Add((ConvertTo-HtmlText $CertificationText))
    }
    if ($AddressLines) {
        foreach ($line in $AddressLines) {
            if (Test-ValuePresent $line) {
                $detailLines.Add((ConvertTo-HtmlText $line))
            }
        }
    }

    $emailLine = ConvertTo-LinkHtml -Href "mailto:$Email" -Label $Email
    if (Test-ValuePresent $emailLine) {
        $detailLines.Add($emailLine)
    }

    if (Test-ValuePresent $Phone) {
        $detailLines.Add((ConvertTo-HtmlText "Telefon: $Phone"))
    }
    if (Test-ValuePresent $Mobile) {
        $detailLines.Add((ConvertTo-HtmlText "Mobil: $Mobile"))
    }

    $websiteLine = ConvertTo-LinkHtml -Href $Website -Label $Website
    if (Test-ValuePresent $websiteLine) {
        $detailLines.Add($websiteLine)
    }

    $certUrlLine = ConvertTo-LinkHtml -Href $CertificationUrl -Label $CertificationUrl
    if (Test-ValuePresent $certUrlLine) {
        $detailLines.Add($certUrlLine)
    }

    if (Test-ValuePresent $LogoPath) {
        if (Test-Path $LogoPath) {
            $bytes = [System.IO.File]::ReadAllBytes($LogoPath)
            $base64 = [Convert]::ToBase64String($bytes)
            $ext = [System.IO.Path]::GetExtension($LogoPath).ToLowerInvariant()
            $mimeType = switch ($ext) {
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".gif"  { "image/gif" }
                ".svg"  { "image/svg+xml" }
                default { "image/png" }
            }
            $logoHtml = "<div style=`"margin-top: 12px;`"><img src=`"data:$mimeType;base64,$base64`" alt=`"Logo`" style=`"max-width: 220px; height: auto; display: block;`"></div>"
        } else {
            Write-Host "Warning: Logo file not found: $LogoPath" -ForegroundColor Yellow
        }
    }

    $signoffHtml = if (Test-ValuePresent $Signoff) {
        "<p style=`"margin: 0 0 12px 0;`">$(ConvertTo-HtmlText $Signoff)</p>"
    } else {
        ""
    }

    $detailsHtml = "<p style=`"margin: 0;`">" + ($detailLines -join "<br>`r`n") + "</p>"

    $html = @(
        "<div style=`"margin-top: 18px; color: #222; font-family: Aptos, Calibri, Helvetica, sans-serif; font-size: 12pt; line-height: 1.45;`">"
        "  $signoffHtml"
        "  $detailsHtml"
        $(if ($logoHtml) { "  $logoHtml" })
        "</div>"
    ) | Where-Object { Test-ValuePresent $_ }

    return ($html -join "`r`n")
}

Write-Host ""
Write-Host "Creating account-specific HTML footer..." -ForegroundColor Cyan

$targetFolder = Resolve-TargetFolder -ExplicitAccountKey $AccountKey
if (-not (Test-Path $targetFolder)) {
    New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
}

$htmlFooter = Build-HtmlFooter

$textPath = Join-Path $targetFolder "footer.txt"
$htmlPath = Join-Path $targetFolder "footer.html"

$htmlFooter | Out-File -FilePath $htmlPath -Encoding utf8 -NoNewline

if ($WriteTextFooter) {
    $textFooter = Build-TextFooter
    $textFooter | Out-File -FilePath $textPath -Encoding utf8 -NoNewline
}

Write-Host ""
Write-Host "Created:" -ForegroundColor Green
Write-Host "  $htmlPath" -ForegroundColor Green
if ($WriteTextFooter) {
    Write-Host "  $textPath" -ForegroundColor Green
}
Write-Host ""
Write-Host "psmail will use footer.html whenever it exists for this account." -ForegroundColor Cyan
if ($WriteTextFooter) {
    Write-Host "footer.txt was also written as an optional plain-text fallback file." -ForegroundColor DarkGray
} else {
    Write-Host "Use -WriteTextFooter if you also want a separate plain-text footer file." -ForegroundColor DarkGray
}
Write-Host "Delete or rename footer.html in this account folder to stop HTML footer usage." -ForegroundColor DarkGray
Write-Host ""
