# smime.ps1
# S/MIME: incoming verification and outgoing sign/encrypt
#
# Signing certs:   certmgr.msc -> Personal -> Certificates
# Recipient certs: certmgr.msc -> Other People -> Certificates

Add-Type -AssemblyName System.Security

# ============================================================
# SECTION 1 - MIME PARSING UTILITIES
# ============================================================

function Get-MimeHeaderValue {
    <#
    .SYNOPSIS
    Extract a header value from raw MIME/RFC2822 content.
    Handles folded headers (continuation lines starting with whitespace).
    #>
    param(
        [string]$MimeContent,
        [string]$HeaderName
    )

    # Find header section (ends at first blank line)
    $idx = $MimeContent.IndexOf("`r`n`r`n")
    $headerBlock = if ($idx -ge 0) { $MimeContent.Substring(0, $idx) } else { $MimeContent }

    # Unfold: continuation lines begin with whitespace
    $unfolded = $headerBlock -replace "`r`n[ `t]+", " "
    $unfolded = $unfolded   -replace "`n[ `t]+",   " "

    foreach ($line in ($unfolded -split "`r?`n")) {
        if ($line -match "^$([regex]::Escape($HeaderName))\s*:\s*(.+)$") {
            return $matches[1].Trim()
        }
    }

    # LF-only fallback
    $idx2 = $MimeContent.IndexOf("`n`n")
    if ($idx2 -ge 0) {
        $block2    = $MimeContent.Substring(0, $idx2)
        $unfolded2 = $block2 -replace "`n[ `t]+", " "
        foreach ($line in ($unfolded2 -split "`n")) {
            if ($line -match "^$([regex]::Escape($HeaderName))\s*:\s*(.+)$") {
                return $matches[1].Trim()
            }
        }
    }

    return $null
}

function Get-MimeBoundary {
    <#
    .SYNOPSIS
    Extract the boundary parameter from a Content-Type header value.
    #>
    param([string]$ContentType)

    if ($ContentType -match 'boundary="([^"]+)"') { return $matches[1] }
    if ($ContentType -match "boundary='([^']+)'")  { return $matches[1] }
    if ($ContentType -match 'boundary=([^\s;]+)')   { return $matches[1].Trim(';"') }
    return $null
}

function Get-MimeBodySection {
    <#
    .SYNOPSIS
    Return the body portion of a MIME message/part (everything after the blank line).
    #>
    param([string]$MimeText)

    $i = $MimeText.IndexOf("`r`n`r`n")
    if ($i -ge 0) { return $MimeText.Substring($i + 4) }
    $i = $MimeText.IndexOf("`n`n")
    if ($i -ge 0) { return $MimeText.Substring($i + 2) }
    return $MimeText
}

function Split-MimeParts {
    <#
    .SYNOPSIS
    Split a multipart MIME body into individual part strings.
    Each element includes the part's headers and body.
    #>
    param(
        [string]$MimeBody,
        [string]$Boundary
    )

    $delim = "--$Boundary"
    $close = "--$Boundary--"
    $parts = [System.Collections.ArrayList]@()
    $cur   = $null

    foreach ($line in ($MimeBody -split "`r?`n")) {
        $t = $line.TrimEnd()
        if ($t -eq $close -or $t.StartsWith($close)) {
            if ($null -ne $cur) { [void]$parts.Add($cur.ToString().TrimEnd()) }
            break
        }
        if ($t -eq $delim -or $t.StartsWith($delim)) {
            if ($null -ne $cur) { [void]$parts.Add($cur.ToString().TrimEnd()) }
            $cur = [System.Text.StringBuilder]::new()
            continue
        }
        if ($null -ne $cur) { [void]$cur.AppendLine($line) }
    }

    return @($parts)
}

function ConvertFrom-Base64Mime {
    <#
    .SYNOPSIS
    Decode a base64-encoded MIME body to bytes (strips whitespace first).
    Returns [byte[]] or $null on failure.
    #>
    param([string]$Body)

    $clean = $Body -replace '[\r\n\t\s]', ''
    try { return [Convert]::FromBase64String($clean) } catch { return $null }
}

function Get-MimePartText {
    <#
    .SYNOPSIS
    Decode the body of a single MIME part to a UTF-8 string.
    Handles base64 and identity/7bit/8bit transfer encodings.
    #>
    param([Parameter(Mandatory)][string]$PartContent)

    $cte  = Get-MimeHeaderValue -MimeContent $PartContent `
        -HeaderName "Content-Transfer-Encoding"
    $body = Get-MimeBodySection -MimeText $PartContent

    if ($cte) {
        switch ($cte.ToLower().Trim()) {
            "base64" {
                $bytes = ConvertFrom-Base64Mime -Body $body.Trim()
                if ($bytes) {
                    return [System.Text.Encoding]::UTF8.GetString($bytes)
                }
            }
        }
    }
    return $body.Trim()
}

function Get-MimeReadableText {
    <#
    .SYNOPSIS
    Recursively extract the first readable text body from a MIME entity.
    Prefers text/plain over text/html and skips S/MIME signature blobs.
    #>
    param([Parameter(Mandatory)][string]$MimeContent)

    if ([string]::IsNullOrWhiteSpace($MimeContent)) { return $null }

    $ct = Get-MimeHeaderValue -MimeContent $MimeContent -HeaderName "Content-Type"
    if (-not $ct) {
        $plain = Get-MimeBodySection -MimeText $MimeContent
        if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
        return $plain.Trim()
    }

    $ctLower = $ct.ToLower()

    if ($ctLower -match '^multipart/') {
        $boundary = Get-MimeBoundary -ContentType $ct
        if (-not $boundary) { return $null }

        $body  = Get-MimeBodySection -MimeText $MimeContent
        $parts = @(Split-MimeParts -MimeBody $body -Boundary $boundary)
        if ($parts.Count -eq 0) { return $null }

        $preferred = @()
        if ($ctLower -match 'multipart/alternative') {
            $preferred += @(
                $parts | Where-Object {
                    ((Get-MimeHeaderValue -MimeContent $_ -HeaderName "Content-Type") ?? "").
                        ToLower() -match '^text/plain'
                }
            )
            $preferred += @(
                $parts | Where-Object {
                    ((Get-MimeHeaderValue -MimeContent $_ -HeaderName "Content-Type") ?? "").
                        ToLower() -match '^text/html'
                }
            )
        }
        $preferred += $parts

        foreach ($part in @($preferred | Select-Object -Unique)) {
            $text = Get-MimeReadableText -MimeContent $part
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
        return $null
    }

    if ($ctLower -match '^message/rfc822') {
        $inner = Get-MimeBodySection -MimeText $MimeContent
        return Get-MimeReadableText -MimeContent $inner
    }

    if ($ctLower -match 'application/(x-)?pkcs7-signature') {
        return $null
    }

    if ($ctLower -match '^text/html') {
        $html = Get-MimePartText -PartContent $MimeContent
        if ([string]::IsNullOrWhiteSpace($html)) { return $null }
        return Convert-HtmlToText $html
    }

    if ($ctLower -match '^text/plain') {
        return Get-MimePartText -PartContent $MimeContent
    }

    return $null
}

function Get-SmimeTypeFromAttachment {
    <#
    .SYNOPSIS
    Detect S/MIME type from a structural attachment when raw MIME is unavailable.
    Distinguishes opaque-signed smime.p7m from encrypted smime.p7m whenever
    attachment metadata or bytes allow it.
    #>
    param(
        [Parameter(Mandatory)]$Attachment,
        [string]$MessageId = $null
    )

    $name = ""
    if ($Attachment.PSObject.Properties.Name -contains 'name') {
        $name = "$($Attachment.name)"
    }
    $nameLower = $name.ToLower()

    if ($nameLower -eq 'smime.p7s') { return "MultipleSigned" }
    if ($nameLower -ne 'smime.p7m') { return "None" }

    $contentType = ""
    if ($Attachment.PSObject.Properties.Name -contains 'contentType' -and
        $Attachment.contentType) {
        $contentType = "$($Attachment.contentType)".ToLower()
    }

    if ($contentType -match 'smime-type\s*=\s*enveloped-data') {
        return "Encrypted"
    }
    if ($contentType -match 'smime-type\s*=\s*signed-data') {
        return "OpaqueSign"
    }

    $contentBytesB64 = $null
    if ($Attachment.PSObject.Properties.Name -contains 'contentBytes' -and
        $Attachment.contentBytes) {
        $contentBytesB64 = $Attachment.contentBytes
    } elseif ($MessageId -and
              $Attachment.PSObject.Properties.Name -contains 'id' -and
              $Attachment.id) {
        try {
            $fullAttachment = Get-Attachment `
                -MessageId $MessageId -AttachmentId $Attachment.id
            if ($fullAttachment -and $fullAttachment.contentBytes) {
                $contentBytesB64 = $fullAttachment.contentBytes
            }
        } catch { }
    }

    if ($contentBytesB64) {
        try {
            [byte[]]$contentBytes = [Convert]::FromBase64String($contentBytesB64)
            try {
                $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
                $env.Decode([byte[]]$contentBytes)
                return "Encrypted"
            } catch { }
            try {
                $signed = New-Object System.Security.Cryptography.Pkcs.SignedCms
                $signed.Decode([byte[]]$contentBytes)
                return "OpaqueSign"
            } catch { }
        } catch { }
    }

    # smime.p7m is ambiguous; prefer signed to avoid falsely labelling
    # readable signed mail as encrypted-only.
    return "OpaqueSign"
}

function Get-SmimePlaintextBody {
    <#
    .SYNOPSIS
    Extract readable plain text from an S/MIME MIME structure.
    Used when Graph API returns empty body.content for signed messages
    because the text is embedded in the inner MIME part.
    Supports multipart/signed and application/pkcs7-mime smime-type=signed-data.
    Returns $null for encrypted messages or on error.
    #>
    param(
        [Parameter(Mandatory)][string]$MimeContent,
        [Parameter(Mandatory)][string]$SmimeType
    )

    try {
        if ($SmimeType -eq "MultipleSigned") {
            $ct  = Get-MimeHeaderValue -MimeContent $MimeContent `
                -HeaderName "Content-Type"
            $bnd = Get-MimeBoundary -ContentType $ct
            if (-not $bnd) { return $null }
            $body  = Get-MimeBodySection -MimeText $MimeContent
            $parts = Split-MimeParts -MimeBody $body -Boundary $bnd
            if ($parts.Count -lt 1) { return $null }
            return Get-MimeReadableText -MimeContent $parts[0]
        }

        if ($SmimeType -eq "OpaqueSign") {
            # Non-detached CMS: content is embedded inside the SignedData blob
            $body     = Get-MimeBodySection -MimeText $MimeContent
            $cmsBytes = ConvertFrom-Base64Mime -Body $body.Trim()
            if (-not $cmsBytes) { return $null }
            $signedCms = New-Object System.Security.Cryptography.Pkcs.SignedCms
            $signedCms.Decode([byte[]]$cmsBytes)
            $innerBytes = $signedCms.ContentInfo.Content
            $innerMime  = [System.Text.Encoding]::UTF8.GetString($innerBytes)
            return Get-MimeReadableText -MimeContent $innerMime
        }

        if ($SmimeType -eq "Encrypted") {
            # Decrypt using the private key from the Windows Certificate Store.
            # EnvelopedCms.Decrypt() searches CurrentUser\My automatically.
            $body     = Get-MimeBodySection -MimeText $MimeContent
            $encBytes = ConvertFrom-Base64Mime -Body $body.Trim()
            if (-not $encBytes) { return $null }
            $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
            $env.Decode([byte[]]$encBytes)
            $env.Decrypt()   # throws if no matching private key found
            $innerBytes = $env.ContentInfo.Content
            $innerMime  = [System.Text.Encoding]::UTF8.GetString($innerBytes)
            return Get-MimeReadableText -MimeContent $innerMime
        }
    } catch { }
    return $null
}

# ============================================================
# SECTION 2 - S/MIME TYPE DETECTION
# ============================================================

function Get-SmimeMimeType {
    <#
    .SYNOPSIS
    Detect S/MIME type from raw MIME content.
    Returns: "None" | "MultipleSigned" | "OpaqueSign" | "Encrypted"
    #>
    param([string]$MimeContent)

    $ct = Get-MimeHeaderValue -MimeContent $MimeContent -HeaderName "Content-Type"
    if (-not $ct) { return "None" }

    $low = $ct.ToLower()
    if ($low -match 'multipart/signed')       { return "MultipleSigned" }
    if ($low -match 'application/(x-)?pkcs7-mime') {
        if ($low -match 'smime-type=enveloped-data') { return "Encrypted" }
        return "OpaqueSign"
    }
    return "None"
}

# ============================================================
# SECTION 3 - S/MIME VERIFICATION (INCOMING)
# ============================================================

function Get-MessageSmimeStatus {
    <#
    .SYNOPSIS
    Fetch raw MIME for a message and perform full S/MIME verification.
    Returns a hashtable:
      Status     - SmimeStatus config value
      Subject    - signer cert CN
      Issuer     - issuing CA CN
      ValidUntil - cert expiry (yyyy-MM-dd)
      Error      - reason string if not trusted/valid
      Body       - plain-text body extracted from the S/MIME structure,
                   or $null (used when Graph API returns empty body.content)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )

    $none = @{
        Status = $Config.SmimeStatus.None
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
    }

    try {
        $mime = Get-MessageMime -MessageId $MessageId
        if (-not $mime) { return $none }

        if ($mime -is [byte[]]) {
            $mime = [System.Text.Encoding]::UTF8.GetString($mime)
        }

        $t = Get-SmimeMimeType -MimeContent $mime
        if ($t -eq "None") { return $none }
        if ($t -eq "Encrypted") {
            # Try to decrypt. If the private key is available in CurrentUser\My,
            # EnvelopedCms.Decrypt() will succeed.
            # Exchange/Outlook.com also wraps received multipart/signed messages
            # in enveloped-data for secure storage; after decryption the inner
            # content may itself be a signed message.
            $decryptErr  = ""
            $innerMime   = $null
            $innerType   = "None"

            try {
                $rawBody  = Get-MimeBodySection -MimeText $mime
                $encBytes = ConvertFrom-Base64Mime -Body $rawBody.Trim()
                if ($encBytes) {
                    $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
                    $env.Decode([byte[]]$encBytes)
                    $env.Decrypt()
                    [byte[]]$innerBytes = $env.ContentInfo.Content
                    $innerMime = [System.Text.Encoding]::UTF8.GetString($innerBytes)
                    $innerType = Get-SmimeMimeType -MimeContent $innerMime
                }
            } catch {
                $decryptErr = $_.Exception.Message
            }

            # If the decrypted payload is itself a signed message (Exchange
            # secure-wrapping a received multipart/signed), verify that.
            if ($innerType -ne "None" -and $innerType -ne "Encrypted") {
                $result = Invoke-SmimeVerification `
                    -MimeContent $innerMime -SmimeType $innerType
                $result['Body'] = Get-SmimePlaintextBody `
                    -MimeContent $innerMime -SmimeType $innerType
                return $result
            }

            # Truly encrypted: body from local decryption or null.
            $decrypted = if ($innerMime) {
                Get-MimeReadableText -MimeContent $innerMime
            } else { $null }

            return @{
                Status = $Config.SmimeStatus.Encrypted
                Subject = ""; Issuer = ""; ValidUntil = ""
                Error  = $decryptErr
                Body   = $decrypted
            }
        }

        $result = Invoke-SmimeVerification -MimeContent $mime -SmimeType $t
        # Extract body text so callers can display it even when
        # Graph API returns empty body.content for signed messages.
        $result['Body'] = Get-SmimePlaintextBody -MimeContent $mime -SmimeType $t
        return $result

    } catch {
        $none.Error = $_.Exception.Message
        return $none
    }
}

function Invoke-SmimeVerification {
    <#
    .SYNOPSIS
    Internal: parse MIME for S/MIME parts and verify the CMS signature.
    #>
    param([string]$MimeContent, [string]$SmimeType)

    $invalid = @{
        Status = $Config.SmimeStatus.SignedInvalid
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""
    }

    try {
        [byte[]]$sigBytes     = $null
        [byte[]]$contentBytes = $null
        $detached             = $false

        if ($SmimeType -eq "MultipleSigned") {
            $ct       = Get-MimeHeaderValue -MimeContent $MimeContent -HeaderName "Content-Type"
            $boundary = Get-MimeBoundary -ContentType $ct
            if (-not $boundary) {
                $invalid.Error = "No MIME boundary in multipart/signed"
                return $invalid
            }
            $body  = Get-MimeBodySection -MimeText $MimeContent
            $parts = Split-MimeParts -MimeBody $body -Boundary $boundary
            if ($parts.Count -lt 2) {
                $invalid.Error = "multipart/signed needs >= 2 parts"
                return $invalid
            }
            # Signed content = raw bytes of first part (incl. part headers)
            $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($parts[0])
            # Signature = base64-decoded body of second part
            $sigBody  = Get-MimeBodySection -MimeText $parts[1]
            $sigBytes = ConvertFrom-Base64Mime -Body $sigBody
            $detached = $true

        } elseif ($SmimeType -eq "OpaqueSign") {
            $body     = Get-MimeBodySection -MimeText $MimeContent
            $sigBytes = ConvertFrom-Base64Mime -Body $body.Trim()
            $detached = $false
        }

        if (-not $sigBytes) {
            $invalid.Error = "Could not decode CMS signature"
            return $invalid
        }

        return Invoke-CmsVerify -SignatureBytes $sigBytes `
            -ContentBytes $contentBytes -IsDetached $detached

    } catch {
        $invalid.Error = $_.Exception.Message
        return $invalid
    }
}

function Invoke-CmsVerify {
    <#
    .SYNOPSIS
    Cryptographic CMS/PKCS#7 signature verification via .NET.
    Checks signature integrity, then validates the cert chain
    against the Windows root store with online revocation.
    #>
    param(
        [byte[]]$SignatureBytes,
        [byte[]]$ContentBytes,
        [bool]$IsDetached
    )

    $result = @{
        Status = $Config.SmimeStatus.SignedInvalid
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""
    }

    try {
        $signedCms = if ($IsDetached -and $ContentBytes) {
            $ci = New-Object System.Security.Cryptography.Pkcs.ContentInfo(
                , [byte[]]$ContentBytes)
            New-Object System.Security.Cryptography.Pkcs.SignedCms($ci, $true)
        } else {
            New-Object System.Security.Cryptography.Pkcs.SignedCms
        }

        $signedCms.Decode([byte[]]$SignatureBytes)

        try {
            $signedCms.CheckSignature($true)
        } catch {
            $result.Error = "Signature invalid: $($_.Exception.Message)"
            return $result
        }

        if ($signedCms.SignerInfos.Count -eq 0) {
            $result.Error = "No signer information"
            return $result
        }

        $cert = $signedCms.SignerInfos[0].Certificate
        if ($cert) {
            $result.Subject    = Extract-CertCN $cert.Subject
            $result.Issuer     = Extract-CertCN $cert.Issuer
            $result.ValidUntil = $cert.NotAfter.ToString("yyyy-MM-dd")
        }

        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode =
            [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag =
            [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
        $chain.ChainPolicy.UrlRetrievalTimeout =
            [TimeSpan]::FromSeconds($Config.SmimeConfig.RevocationTimeout)

        $chainValid = $false
        try {
            if ($cert) { $chainValid = $chain.Build($cert) }
        } catch {
            $result.Status = $Config.SmimeStatus.SignedUntrusted
            $result.Error  = "Revocation check unavailable"
            return $result
        }

        if ($chainValid) {
            $result.Status = $Config.SmimeStatus.SignedTrusted
        } else {
            $f       = [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]
            $revoked = $chain.ChainStatus | Where-Object { $_.Status -band $f::Revoked }
            $expired = $chain.ChainStatus | Where-Object { $_.Status -band $f::NotTimeValid }

            if ($revoked) {
                $result.Error = "Certificate has been revoked"
            } elseif ($expired) {
                $result.Status = $Config.SmimeStatus.SignedInvalid
                $result.Error  = "Certificate has expired"
                return $result
            } else {
                $result.Status = $Config.SmimeStatus.SignedUntrusted
                $result.Error  = ($chain.ChainStatus |
                    ForEach-Object { $_.StatusInformation.Trim() }) -join "; "
                return $result
            }
        }

        return $result
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}

function Extract-CertCN {
    <#
    .SYNOPSIS
    Extract the CN= value from a certificate Distinguished Name string.
    #>
    param([string]$Dn)
    if (-not $Dn) { return "" }
    if ($Dn -match 'CN=([^,]+)') { return $matches[1].Trim() }
    return $Dn
}

# ============================================================
# SECTION 4 - DISPLAY
# ============================================================

function Show-SmimeInfo {
    <#
    .SYNOPSIS
    Display S/MIME status and signer certificate details.
    Accepts an optional Details hashtable (Subject, Issuer, ValidUntil, Error).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,

        [Parameter(Mandatory)]
        [string]$Status,

        [hashtable]$Details = $null
    )

    Write-Host ""

    switch ($Status) {
        "SignedTrusted" {
            Write-Host "Signature: " -NoNewline `
                -ForegroundColor $Config.Colors.FieldLabel
            Write-Host "Trusted [S/MIME]" -ForegroundColor $Config.Colors.Success
            if ($Details) {
                if ($Details.Subject) {
                    Write-Host "Signer:      " -NoNewline `
                        -ForegroundColor $Config.Colors.FieldLabel
                    Write-Host $Details.Subject
                }
                if ($Details.Issuer) {
                    Write-Host "Issued by:   " -NoNewline `
                        -ForegroundColor $Config.Colors.FieldLabel
                    Write-Host $Details.Issuer -ForegroundColor $Config.Colors.Info
                }
                if ($Details.ValidUntil) {
                    Write-Host "Valid until: " -NoNewline `
                        -ForegroundColor $Config.Colors.FieldLabel
                    Write-Host $Details.ValidUntil -ForegroundColor $Config.Colors.Info
                }
            }
        }
        "SignedUntrusted" {
            Write-Host "Signature: " -NoNewline `
                -ForegroundColor $Config.Colors.FieldLabel
            Write-Host "Untrusted [S/MIME]" -ForegroundColor $Config.Colors.Warning
            if ($Details) {
                if ($Details.Subject) {
                    Write-Host "Signer:      " -NoNewline `
                        -ForegroundColor $Config.Colors.FieldLabel
                    Write-Host $Details.Subject -ForegroundColor $Config.Colors.Warning
                }
                $reason = if ($Details.Error) { $Details.Error } `
                    else { "Certificate chain not trusted" }
                Write-Host "Reason:      " -NoNewline `
                    -ForegroundColor $Config.Colors.FieldLabel
                Write-Host $reason -ForegroundColor $Config.Colors.Warning
            }
        }
        "SignedInvalid" {
            Write-Host "Signature: " -NoNewline `
                -ForegroundColor $Config.Colors.FieldLabel
            Write-Host "INVALID [S/MIME]" -ForegroundColor $Config.Colors.Error
            if ($Details -and $Details.Error) {
                Write-Host "Reason:      " -NoNewline `
                    -ForegroundColor $Config.Colors.FieldLabel
                Write-Host $Details.Error -ForegroundColor $Config.Colors.Error
            }
        }
        "Encrypted" {
            Write-Host "Encryption:" -NoNewline `
                -ForegroundColor $Config.Colors.FieldLabel
            Write-Host " Encrypted [S/MIME]" -ForegroundColor $Config.Colors.Success
            if ($Details -and $Details.Error) {
                Write-Host "Decrypt:     " -NoNewline `
                    -ForegroundColor $Config.Colors.FieldLabel
                Write-Host $Details.Error -ForegroundColor $Config.Colors.Warning
            }
        }
    }
}

# ============================================================
# SECTION 5 - CERTIFICATE MANAGEMENT
# ============================================================

function Get-SmimeSigningCertificates {
    <#
    .SYNOPSIS
    Return valid S/MIME signing certificates from CurrentUser\My.
    Criteria: has private key, not expired, emailProtection EKU (or unrestricted).
    #>
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        "My", "CurrentUser")
    try {
        $store.Open(
            [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
        $oid = $Config.SmimeConfig.EmailProtectionOid
        $now = [DateTime]::UtcNow
        $certs = @($store.Certificates | Where-Object {
            $_.HasPrivateKey -and $_.NotAfter -gt $now -and
            ($_.EnhancedKeyUsageList.Count -eq 0 -or
             ($_.EnhancedKeyUsageList | Where-Object {
                 $_.ObjectId -eq $oid }).Count -gt 0)
        })
        return $certs
    } finally {
        $store.Close()
    }
}

function Get-SmimeEncryptionCertificate {
    <#
    .SYNOPSIS
    Find an S/MIME encryption certificate for a given email address.
    Searches CurrentUser stores: AddressBook, My, Root, CA.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EmailAddress
    )

    $emailLower = $EmailAddress.ToLower().Trim()
    foreach ($storeName in @("AddressBook", "My", "Root", "CA")) {
        try {
            $store = New-Object `
                System.Security.Cryptography.X509Certificates.X509Store(
                    $storeName, "CurrentUser")
            $store.Open(
                [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            foreach ($cert in $store.Certificates) {
                if ($cert.NotAfter -lt [DateTime]::UtcNow) { continue }
                # Subject Alternative Name (rfc822Name)
                $san = $cert.Extensions | Where-Object {
                    $_.Oid.FriendlyName -eq "Subject Alternative Name" }
                if ($san -and $san.Format($false).ToLower().Contains($emailLower)) {
                    $store.Close(); return $cert }
                # Subject field
                if ($cert.Subject.ToLower().Contains($emailLower)) {
                    $store.Close(); return $cert }
                # Legacy E= / EMAIL= in Subject DN
                if ($cert.Subject -match '(?i)(?:E|EMAIL)=([^,]+)') {
                    if ($matches[1].Trim().ToLower() -eq $emailLower) {
                        $store.Close(); return $cert } }
            }
            $store.Close()
        } catch { }
    }
    return $null
}

function Get-DefaultSigningCertificate {
    <#
    .SYNOPSIS
    Return the S/MIME signing certificate for the given sender address.
    Matches Subject Alternative Name (rfc822Name), Subject CN, or E=/EMAIL= field.
    Falls back to $null if no matching cert is found (no silent fallback to a
    wrong certificate).
    #>
    param(
        [string]$EmailAddress = $null
    )

    $certs = Get-SmimeSigningCertificates
    if (-not $certs -or $certs.Count -eq 0) { return $null }

    if ($EmailAddress) {
        $emailLower = $EmailAddress.ToLower().Trim()
        $matched = $certs | Where-Object {
            $c = $_
            # Subject Alternative Name (rfc822Name)
            $san = $c.Extensions | Where-Object {
                $_.Oid.FriendlyName -eq "Subject Alternative Name" }
            if ($san -and $san.Format($false).ToLower().Contains($emailLower)) {
                return $true }
            # Subject field contains email
            if ($c.Subject.ToLower().Contains($emailLower)) { return $true }
            # Legacy E= / EMAIL= field in Subject DN
            if ($c.Subject -match '(?i)(?:E|EMAIL)=([^,]+)') {
                if ($matches[1].Trim().ToLower() -eq $emailLower) { return $true } }
            return $false
        }
        if ($matched) { return @($matched)[0] }
        return $null   # no cert for this address - caller must handle
    }

    return $certs[0]
}

function Show-SmimeCertificates {
    <#
    .SYNOPSIS
    Display available S/MIME signing certificates and usage instructions.
    #>
    Write-Header "S/MIME Signing Certificates"

    $certs = Get-SmimeSigningCertificates
    if (-not $certs -or $certs.Count -eq 0) {
        Write-Host ""
        Write-Host "No S/MIME signing certificates found." `
            -ForegroundColor $Config.Colors.Warning
        Write-Host ""
        Write-Host "How to install:" -ForegroundColor $Config.Colors.Info
        Write-Host "  1. Obtain certificate (D-TRUST, GlobalSign, Sectigo ...)"
        Write-Host "  2. Run: certmgr.msc"
        Write-Host "  3. Personal -> Certificates -> Import (.p12/.pfx, with private key)"
        Write-Host ""
        Write-Host "For recipient encryption certificates:" -ForegroundColor $Config.Colors.Info
        Write-Host "  certmgr.msc -> Other People -> Certificates -> Import"
        Write-Host ""
        return
    }

    Write-Host ""
    $idx = 1
    foreach ($cert in $certs) {
        $cn    = Extract-CertCN $cert.Subject
        $issue = Extract-CertCN $cert.Issuer
        $until = $cert.NotAfter.ToString("yyyy-MM-dd")
        $thumb = $cert.Thumbprint.Substring(
            0, [Math]::Min(16, $cert.Thumbprint.Length)) + "..."
        Write-Host ("{0,2}. " -f $idx) -NoNewline
        Write-Host $cn -ForegroundColor $Config.Colors.Success
        Write-Host ("    Issuer:      $issue") -ForegroundColor $Config.Colors.FieldLabel
        Write-Host ("    Valid until: $until  |  Thumb: $thumb") `
            -ForegroundColor $Config.Colors.FieldLabel
        Write-Host ""
        $idx++
    }
    Write-Info "Set 'Sign: yes' or 'Encrypt: yes' when editing a draft to use S/MIME."
    Write-Host ""
}

# ============================================================
# SECTION 6 - DRAFT S/MIME STATE
# ============================================================
# Flags are persisted to data/smime-drafts.json so they survive restarts.
# Outlook.com consumer accounts do not allow writing custom metadata to
# Graph messages (categories: 403; HTML comments stripped server-side),
# so a local file is the only reliable storage option for this tool.

function Save-SmimeDrafts {
    <#
    .SYNOPSIS
    Write the in-memory SmimeDrafts table to disk. Silent on error.
    #>
    try {
        $global:State.SmimeDrafts | ConvertTo-Json -Depth 3 | `
            Set-Content $Config.SmimeDraftsPath -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Set-DraftSmimeFlag {
    <#
    .SYNOPSIS
    Store Sign/Encrypt flags for a draft and persist them to disk.
    #>
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [bool]$Sign    = $false,
        [bool]$Encrypt = $false
    )
    if (-not $global:State.SmimeDrafts) { $global:State.SmimeDrafts = @{} }
    $global:State.SmimeDrafts[$MessageId] = @{ Sign = $Sign; Encrypt = $Encrypt }
    Save-SmimeDrafts
}

function Get-DraftSmimeFlag {
    <#
    .SYNOPSIS
    Retrieve Sign/Encrypt flags for a draft.
    Returns @{ Sign=$false; Encrypt=$false } if not set.
    #>
    param([Parameter(Mandatory)][string]$MessageId)
    if ($global:State.SmimeDrafts -and
        $global:State.SmimeDrafts.ContainsKey($MessageId)) {
        return $global:State.SmimeDrafts[$MessageId]
    }
    return @{ Sign = $false; Encrypt = $false }
}

function Remove-DraftSmimeFlag {
    <#
    .SYNOPSIS
    Remove S/MIME flags for a draft after sending and persist the change.
    #>
    param([Parameter(Mandatory)][string]$MessageId)
    if ($global:State.SmimeDrafts -and
        $global:State.SmimeDrafts.ContainsKey($MessageId)) {
        $global:State.SmimeDrafts.Remove($MessageId)
        Save-SmimeDrafts
    }
}

# ============================================================
# SECTION 7 - OUTGOING MIME BUILDING
# ============================================================

function Build-SmimeMimeContent {
    <#
    .SYNOPSIS
    Build inner MIME content (body + attachments) for signing/encrypting.
    Returns a CRLF-terminated string.
    Attachments: array of @{ Name=; ContentType=; Bytes=[byte[]] }

    The body is base64-encoded rather than quoted-printable. Base64 is
    treated as opaque binary by mail servers and is therefore not
    re-encoded in transit, which is critical for S/MIME signature stability.
    #>
    param(
        [string]$BodyText,
        [string]$BodyContentType = "text/plain",
        [array]$Attachments      = @()
    )

    $crlf = "`r`n"
    $sb   = [System.Text.StringBuilder]::new()

    # Encode body as base64 (76-char lines, CRLF terminated).
    [byte[]]$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($BodyText)
    $b64raw   = [Convert]::ToBase64String($bodyBytes)
    $bodyEncSb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $b64raw.Length; $i += 76) {
        [void]$bodyEncSb.Append(
            $b64raw.Substring($i, [Math]::Min(76, $b64raw.Length - $i)) + $crlf)
    }
    # $bodyEncSb already ends with \r\n; no extra CRLF is appended so that
    # Build-SmimeMimeContent returns exactly one trailing \r\n for the
    # RFC 2046 boundary-separator stripping in New-SmimeSignedMime.

    if ($Attachments.Count -eq 0) {
        [void]$sb.Append("Content-Type: $BodyContentType; charset=utf-8$crlf")
        [void]$sb.Append("Content-Transfer-Encoding: base64$crlf")
        [void]$sb.Append($crlf)
        [void]$sb.Append($bodyEncSb.ToString())
    } else {
        $bnd = "MixedBnd_" + [Guid]::NewGuid().ToString("N")
        [void]$sb.Append("Content-Type: multipart/mixed; boundary=`"$bnd`"$crlf")
        [void]$sb.Append($crlf)
        [void]$sb.Append("--$bnd$crlf")
        [void]$sb.Append("Content-Type: $BodyContentType; charset=utf-8$crlf")
        [void]$sb.Append("Content-Transfer-Encoding: base64$crlf")
        [void]$sb.Append($crlf)
        # Body base64 ends with \r\n which serves as boundary separator.
        [void]$sb.Append($bodyEncSb.ToString())

        foreach ($att in $Attachments) {
            $ct = if ($att.ContentType) { $att.ContentType } `
                  else { "application/octet-stream" }
            [void]$sb.Append("--$bnd$crlf")
            [void]$sb.Append("Content-Type: $ct; name=`"$($att.Name)`"$crlf")
            [void]$sb.Append("Content-Transfer-Encoding: base64$crlf")
            [void]$sb.Append(
                "Content-Disposition: attachment; filename=`"$($att.Name)`"$crlf")
            [void]$sb.Append($crlf)
            $b64 = [Convert]::ToBase64String($att.Bytes)
            for ($i = 0; $i -lt $b64.Length; $i += 76) {
                [void]$sb.Append(
                    $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)) + $crlf)
            }
        }
        [void]$sb.Append("--$bnd--$crlf")
    }
    return $sb.ToString()
}

# ============================================================
# SECTION 8 - OUTGOING S/MIME PROTECTION
# ============================================================

function New-SmimeSignedMime {
    <#
    .SYNOPSIS
    Wrap MIME content in multipart/signed (detached SHA-256 signature).

    RFC 2046 §5.1.1 CRLF canonicalisation
    The CRLF immediately before a boundary delimiter is "conceptually
    attached to the boundary" and is NOT part of the preceding body part.
    RFC-compliant verifiers (Outlook, iOS Mail, OpenSSL) therefore hash
    the body content WITHOUT that trailing CRLF. This function strips the
    trailing CRLF before computing the signature and emits it separately
    as the boundary separator, ensuring the signed bytes match exactly
    what every verifier will compute.

    ExcludeRoot: intermediate CA certificates (e.g. DigiCert) are
    included in the CMS so recipients can build the full chain.
    Returns complete multipart/signed MIME string (CRLF line endings).
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]]$ContentBytes,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $crlf = "`r`n"

    # Decode to string; strip trailing CRLF before signing (RFC 2046 rule).
    $contentStr = [System.Text.Encoding]::UTF8.GetString($ContentBytes)
    $signStr    = if ($contentStr.EndsWith($crlf)) {
        $contentStr.Substring(0, $contentStr.Length - 2)
    } else { $contentStr }
    [byte[]]$signBytes = [System.Text.Encoding]::UTF8.GetBytes($signStr)

    $ci     = New-Object System.Security.Cryptography.Pkcs.ContentInfo(, $signBytes)
    $signed = New-Object System.Security.Cryptography.Pkcs.SignedCms($ci, $true)
    $signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner($Certificate)
    # ExcludeRoot: include intermediate CA certs; root is pre-installed.
    $signer.IncludeOption =
        [System.Security.Cryptography.X509Certificates.X509IncludeOption]::ExcludeRoot
    # SHA-256 digest OID
    $signer.DigestAlgorithm =
        New-Object System.Security.Cryptography.Oid("2.16.840.1.101.3.4.2.1")

    $signed.ComputeSignature($signer, $false)
    [byte[]]$sigBytes = $signed.Encode()

    $b64   = [Convert]::ToBase64String($sigBytes)
    $sigSb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        [void]$sigSb.Append(
            $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)) + $crlf)
    }

    $bnd = "SmimeSigBnd_" + [Guid]::NewGuid().ToString("N")

    $mime = [System.Text.StringBuilder]::new()
    [void]$mime.Append(
        "Content-Type: multipart/signed; " +
        "protocol=`"application/pkcs7-signature`"; " +
        "micalg=`"sha-256`"; " +
        "boundary=`"$bnd`"$crlf")
    [void]$mime.Append($crlf)
    [void]$mime.Append("--$bnd$crlf")
    [void]$mime.Append($signStr)          # signed content WITHOUT trailing CRLF
    [void]$mime.Append($crlf)             # boundary separator (not part of signed content)
    [void]$mime.Append("--$bnd$crlf")
    [void]$mime.Append(
        "Content-Type: application/pkcs7-signature; name=`"smime.p7s`"$crlf")
    [void]$mime.Append("Content-Transfer-Encoding: base64$crlf")
    [void]$mime.Append(
        "Content-Disposition: attachment; filename=`"smime.p7s`"$crlf")
    [void]$mime.Append($crlf)
    [void]$mime.Append($sigSb.ToString())
    [void]$mime.Append("--$bnd--$crlf")
    return $mime.ToString()
}

function New-SmimeEncryptedMime {
    <#
    .SYNOPSIS
    Encrypt content bytes for recipients using EnvelopedCms (AES-256-CBC).
    Returns application/pkcs7-mime MIME string.
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]]$ContentBytes,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$RecipientCerts
    )

    $crlf = "`r`n"
    $ci   = New-Object System.Security.Cryptography.Pkcs.ContentInfo(, $ContentBytes)
    # AES-256-CBC OID
    $aesOid = [System.Security.Cryptography.Oid]::new("2.16.840.1.101.3.4.1.42")
    $alg    = New-Object System.Security.Cryptography.Pkcs.AlgorithmIdentifier($aesOid)
    $env    = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms($ci, $alg)

    $recipColl = New-Object System.Security.Cryptography.Pkcs.CmsRecipientCollection
    foreach ($rcert in $RecipientCerts) {
        $rcipient = New-Object `
            System.Security.Cryptography.Pkcs.CmsRecipient($rcert)
        [void]$recipColl.Add($rcipient)
    }
    $env.Encrypt($recipColl)
    [byte[]]$encBytes = $env.Encode()

    $b64   = [Convert]::ToBase64String($encBytes)
    $encSb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        [void]$encSb.Append(
            $b64.Substring($i, [Math]::Min(76, $b64.Length - $i)) + $crlf)
    }

    $mime = [System.Text.StringBuilder]::new()
    [void]$mime.Append(
        "Content-Type: application/pkcs7-mime; " +
        "smime-type=enveloped-data; name=`"smime.p7m`"$crlf")
    [void]$mime.Append("Content-Transfer-Encoding: base64$crlf")
    [void]$mime.Append(
        "Content-Disposition: attachment; filename=`"smime.p7m`"$crlf")
    [void]$mime.Append($crlf)
    [void]$mime.Append($encSb.ToString())
    return $mime.ToString()
}

function Protect-MessageSmime {
    <#
    .SYNOPSIS
    Apply S/MIME sign/encrypt to an existing Graph draft and upload the result.
    Workflow: fetch draft + attachments -> select certs -> build MIME ->
    sign/encrypt -> PUT /$value back to Graph.
    Returns $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        [bool]$Sign    = $false,
        [bool]$Encrypt = $false
    )

    if (-not $Sign -and -not $Encrypt) { return $true }

    # 1. Sender address ($ctx.Account is empty for personal MSA accounts)
    $fromEmail = Get-CurrentUserEmail
    if ([string]::IsNullOrWhiteSpace($fromEmail)) {
        Write-Error-Message "Could not determine sender address. Please reconnect."
        return $false
    }

    # 2. Fetch draft
    $draft = Get-Message -MessageId $MessageId
    if (-not $draft) {
        Write-Error-Message "Could not fetch draft for S/MIME"
        return $false
    }
    $subject  = $draft.subject
    $toList   = ($draft.toRecipients |
        ForEach-Object { $_.emailAddress.address }) -join ", "
    $bodyText = $draft.body.content
    if ($draft.body.contentType -eq "HTML") {
        $bodyText = Convert-HtmlToText $bodyText
    }

    # 3. Fetch attachments (embed in MIME before signing)
    $attachments = @()
    if ($draft.hasAttachments) {
        Write-Info "Fetching attachments..."
        $rawAtts = Get-MessageAttachments -MessageId $MessageId
        if ($rawAtts) {
            foreach ($att in $rawAtts) {
                $full = Get-Attachment `
                    -MessageId $MessageId -AttachmentId $att.id
                if ($full -and $full.contentBytes) {
                    $attachments += @{
                        Name        = $full.name
                        ContentType = $full.contentType
                        Bytes       = [Convert]::FromBase64String($full.contentBytes)
                    }
                }
            }
        }
    }

    # 4. Signing certificate
    $signingCert = $null
    if ($Sign) {
        $signingCert = Get-DefaultSigningCertificate -EmailAddress $fromEmail
        if (-not $signingCert) {
            Write-Error-Message "No S/MIME signing certificate for '$fromEmail'. Run SMIME for instructions."
            return $false
        }
        Write-Info "Signing with: $(Extract-CertCN $signingCert.Subject)"
    }

    # 4b. Recipient certificates (for encryption)
    [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$recipCerts = @()
    if ($Encrypt) {
        $toAddresses = @($toList -split '[,;]' |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($addr in $toAddresses) {
            $rc = Get-SmimeEncryptionCertificate -EmailAddress $addr
            if (-not $rc) {
                Write-Error-Message "No encryption cert for: $addr"
                Write-Error-Message "Import via certmgr.msc -> Other People -> Certificates"
                return $false
            }
            $recipCerts += $rc
            Write-Info "Encryption cert found: $addr"
        }
        # Include sender cert so they can decrypt sent copies
        if ($signingCert) { $recipCerts += $signingCert }
    }

    # 5. Build inner MIME
    Write-Info "Building MIME..."
    $innerMime  = Build-SmimeMimeContent `
        -BodyText $bodyText -Attachments $attachments
    [byte[]]$innerBytes = [System.Text.Encoding]::UTF8.GetBytes($innerMime)

    # 6. Sign / encrypt
    [string]$protectedMime = $null
    try {
        if ($Sign -and $Encrypt) {
            Write-Info "Signing..."
            $signedMime = New-SmimeSignedMime `
                -ContentBytes $innerBytes -Certificate $signingCert
            Write-Info "Encrypting..."
            [byte[]]$signedBytes = [System.Text.Encoding]::UTF8.GetBytes($signedMime)
            $protectedMime = New-SmimeEncryptedMime `
                -ContentBytes $signedBytes -RecipientCerts $recipCerts
        } elseif ($Sign) {
            Write-Info "Signing..."
            $protectedMime = New-SmimeSignedMime `
                -ContentBytes $innerBytes -Certificate $signingCert
        } else {
            Write-Info "Encrypting..."
            $protectedMime = New-SmimeEncryptedMime `
                -ContentBytes $innerBytes -RecipientCerts $recipCerts
        }
    } catch {
        Write-Error-Message "S/MIME crypto error: $($_.Exception.Message)"
        return $false
    }

    # 7. Wrap in RFC 2822 envelope (Date: is required by RFC 2822)
    $crlf    = "`r`n"
    $dateStr = [System.DateTime]::UtcNow.ToString(
        "ddd, dd MMM yyyy HH:mm:ss +0000",
        [System.Globalization.CultureInfo]::InvariantCulture)
    $fullMime = "MIME-Version: 1.0$crlf"  +
                "Date: $dateStr$crlf"     +
                "From: $fromEmail$crlf"   +
                "To: $toList$crlf"        +
                "Subject: $subject$crlf"  +
                $protectedMime

    # 8. Send: try PUT /$value on the existing draft then /send (preferred;
    #    works for Microsoft 365 accounts and some personal accounts).
    #    Fall back to POST /me/sendMail if PUT is not available.
    Write-Info "Sending..."
    [byte[]]$mimeBytes = [System.Text.Encoding]::UTF8.GetBytes($fullMime)

    $valueUri = "/v1.0/me/messages/$MessageId/`$value"
    $usedPut  = $false
    try {
        Invoke-MgGraphRequest `
            -Method      PUT `
            -Uri         $valueUri `
            -Body        $mimeBytes `
            -ContentType "text/plain" `
            -ErrorAction Stop
        $usedPut = $true
    } catch {
        # PUT /$value is not supported for personal Microsoft accounts (405).
        # Silently fall back to POST /me/sendMail.
        if (-not (Send-MimeDirectly -MimeContent $fullMime)) {
            return $false
        }
        # sendMail creates a new sent message; remove the unsent original draft.
        Remove-Message -MessageId $MessageId | Out-Null
        Write-Success "S/MIME message sent"
        return $true
    }

    # PUT succeeded – now send the updated draft.
    $sendUri = "/v1.0/me/messages/$MessageId/send"
    try {
        Invoke-MgGraphRequest `
            -Method      POST `
            -Uri         $sendUri `
            -ErrorAction Stop
    } catch {
        $detail = if ($_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { "" }
        Write-Error-Message "Send failed: $($_.Exception.Message)$detail"
        return $false
    }

    Write-Success "S/MIME message sent"
    return $true
}

function Send-MimeDirectly {
    <#
    .SYNOPSIS
    Send raw RFC 2822 MIME via POST /me/sendMail.
    Graph API requires the MIME content to be base64-encoded in the
    request body (Content-Type: text/plain). Sending raw MIME results
    in ErrorMimeContentInvalidBase64String (HTTP 400).
    #>
    param(
        [Parameter(Mandatory)][string]$MimeContent
    )

    $uri = "/v1.0/me/sendMail"
    try {
        # Graph /me/sendMail requires the MIME as a base64-encoded string.
        [byte[]]$mimeBytes = [System.Text.Encoding]::UTF8.GetBytes($MimeContent)
        $b64Body           = [Convert]::ToBase64String($mimeBytes)

        Invoke-MgGraphRequest `
            -Method      POST `
            -Uri         $uri `
            -Body        $b64Body `
            -ContentType "text/plain" `
            -ErrorAction Stop
        return $true
    } catch {
        $detail = if ($_.ErrorDetails.Message) { " | $($_.ErrorDetails.Message)" } else { "" }
        Write-Error-Message "MIME send: $($_.Exception.Message)$detail"
        return $false
    }
}
