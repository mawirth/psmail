# Create-Footer.ps1
# Helper tool to create an account-specific footer in HTML or plain text

param(
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
    [switch]$TextOnly
)

. (Join-Path $PSScriptRoot "..\src\config.ps1")

$PsmailProjectUrl = "https://github.com/mawirth/psmail"
$providedFooterDetailParameters = @(
    "Title",
    "Email",
    "Website",
    "Phone",
    "Mobile",
    "AddressLines",
    "CertificationText",
    "CertificationUrl",
    "LogoPath"
) | Where-Object { $PSBoundParameters.ContainsKey($_) }
$PromptForOptionalFooterDetails = (-not $PSBoundParameters.ContainsKey("Name")) -or ($providedFooterDetailParameters.Count -eq 0)

function Read-FooterRequiredValue {
    param(
        [string]$Prompt,
        [string]$CurrentValue
    )

    if (Test-ValuePresent $CurrentValue) {
        return $CurrentValue
    }

    do {
        $value = Read-Host $Prompt
        if (Test-ValuePresent $value) {
            return $value.Trim()
        }

        Write-Host "This value is required." -ForegroundColor Yellow
    } while ($true)
}

function Read-FooterOptionalValue {
    param(
        [string]$Prompt,
        [string]$CurrentValue
    )

    if (Test-ValuePresent $CurrentValue) {
        return $CurrentValue
    }

    $value = Read-Host "$Prompt (optional)"
    if (Test-ValuePresent $value) {
        return $value.Trim()
    }

    return $CurrentValue
}

function Read-FooterOptionalLines {
    param(
        [string]$Prompt,
        [string[]]$CurrentValue
    )

    if ($CurrentValue -and $CurrentValue.Count -gt 0) {
        return $CurrentValue
    }

    $value = Read-Host "$Prompt (optional, separate lines with |)"
    if (-not (Test-ValuePresent $value)) {
        return $CurrentValue
    }

    return @(
        $value -split "\|" |
            ForEach-Object { $_.Trim() } |
            Where-Object { Test-ValuePresent $_ }
    )
}

function Resolve-TargetFolder {
    param(
        [string]$ExplicitAccountKey,
        [string]$EmailAddress
    )

    $dataFolder = Join-Path $PSScriptRoot "..\data"
    $accountsFolder = Join-Path $dataFolder "accounts"

    if ($ExplicitAccountKey) {
        return (Join-Path $accountsFolder $ExplicitAccountKey)
    }

    $accountDirs = @()
    if (Test-Path $accountsFolder) {
        $accountDirs = @(Get-ChildItem -Path $accountsFolder -Directory)
    }

    if (Test-ValuePresent $EmailAddress) {
        $normalizedEmail = $EmailAddress.Trim().ToLowerInvariant()
        $matchingDirs = @(
            $accountDirs | Where-Object {
                $_.Name.ToLowerInvariant().StartsWith("$normalizedEmail" + "__")
            }
        )

        if ($matchingDirs.Count -eq 1) {
            Write-Host "Using account from email: $($matchingDirs[0].Name)" -ForegroundColor DarkGray
            return $matchingDirs[0].FullName
        }

        if ($matchingDirs.Count -gt 1) {
            Write-Host "Multiple account folders match $EmailAddress. Please specify -AccountKey." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Matching account keys:" -ForegroundColor DarkGray
            foreach ($dir in $matchingDirs) {
                Write-Host "  $($dir.Name)" -ForegroundColor DarkGray
            }
            Write-Host ""
            throw "AccountKey required when the same email exists with multiple account keys."
        }
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

function Read-FooterInput {
    Write-Host ""
    if ($PromptForOptionalFooterDetails) {
        Write-Host "Footer details. Press Enter to skip optional fields." -ForegroundColor Cyan
    }

    $script:Name = Read-FooterRequiredValue -Prompt "Name" -CurrentValue $script:Name

    if (-not $PromptForOptionalFooterDetails) {
        return
    }

    $script:Signoff = Read-FooterOptionalValue -Prompt "Signoff" -CurrentValue $script:Signoff
    $script:Title = Read-FooterOptionalValue -Prompt "Title or role" -CurrentValue $script:Title
    $script:Email = Read-FooterOptionalValue -Prompt "Email" -CurrentValue $script:Email
    $script:Mobile = Read-FooterOptionalValue -Prompt "Mobile" -CurrentValue $script:Mobile
    $script:Phone = Read-FooterOptionalValue -Prompt "Phone" -CurrentValue $script:Phone
    $script:Website = Read-FooterOptionalValue -Prompt "Website" -CurrentValue $script:Website
    $script:AddressLines = Read-FooterOptionalLines -Prompt "Address lines" -CurrentValue $script:AddressLines
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

    $lines.Add("")
    $lines.Add("Sent by psmail: $PsmailProjectUrl")

    return (($lines | Where-Object { $_ -ne $null }) -join "`r`n").TrimEnd()
}

function Build-HtmlFooter {
    $fontFamily = $Config.HtmlBodyStyle.FontFamily
    $fontSize = $Config.HtmlBodyStyle.FontSize

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

    if (Test-ValuePresent $Email) {
        $emailLine = ConvertTo-LinkHtml -Href "mailto:$Email" -Label $Email
        if (Test-ValuePresent $emailLine) {
            $detailLines.Add($emailLine)
        }
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

    $psmailLine = ConvertTo-LinkHtml -Href $PsmailProjectUrl -Label "Sent by psmail"
    $psmailHtml = "<p style=`"margin: 12px 0 0 0; color: #666; font-size: 0.9em;`">$psmailLine</p>"

    $signoffHtml = if (Test-ValuePresent $Signoff) {
        "<p style=`"margin: 0 0 12px 0;`">$(ConvertTo-HtmlText $Signoff)</p>"
    } else {
        ""
    }

    $detailsHtml = "<p style=`"margin: 0;`">" + ($detailLines -join "<br>`r`n") + "</p>"

    $html = @(
        "<div style=`"margin-top: 18px; color: #222; font-family: $fontFamily; font-size: $fontSize; line-height: 1.45;`">"
        "  $signoffHtml"
        "  $detailsHtml"
        $(if ($logoHtml) { "  $logoHtml" })
        "  $psmailHtml"
        "</div>"
    ) | Where-Object { Test-ValuePresent $_ }

    return ($html -join "`r`n")
}

Write-Host ""
Write-Host "Creating account-specific footer..." -ForegroundColor Cyan

Read-FooterInput

$targetFolder = Resolve-TargetFolder -ExplicitAccountKey $AccountKey -EmailAddress $Email
if (-not (Test-Path $targetFolder)) {
    New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
}

$textPath = Join-Path $targetFolder "footer.txt"
$htmlPath = Join-Path $targetFolder "footer.html"

if ($TextOnly) {
    $textFooter = Build-TextFooter
    $textFooter | Out-File -FilePath $textPath -Encoding utf8 -NoNewline
    if (Test-Path $htmlPath) {
        Remove-Item -Path $htmlPath -Force -ErrorAction SilentlyContinue
    }
} else {
    $htmlFooter = Build-HtmlFooter
    $htmlFooter | Out-File -FilePath $htmlPath -Encoding utf8 -NoNewline
}

Write-Host ""
Write-Host "Created:" -ForegroundColor Green
if ($TextOnly) {
    Write-Host "  $textPath" -ForegroundColor Green
} else {
    Write-Host "  $htmlPath" -ForegroundColor Green
}
Write-Host ""
if ($TextOnly) {
    Write-Host "psmail will use footer.txt for this account as long as no footer.html exists." -ForegroundColor Cyan
    Write-Host "An existing footer.html was removed so the text footer is actually used." -ForegroundColor DarkGray
} else {
    Write-Host "psmail will use footer.html whenever it exists for this account." -ForegroundColor Cyan
    Write-Host "Use -TextOnly if you want to generate footer.txt instead." -ForegroundColor DarkGray
}
Write-Host ""
