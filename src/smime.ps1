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
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )

    $none = @{
        Status = $Config.SmimeStatus.None
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""
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
            return @{
                Status = $Config.SmimeStatus.Encrypted
                Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""
            }
        }

        return Invoke-SmimeVerification -MimeContent $mime -SmimeType $t

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
    Return the first available S/MIME signing certificate (no UI).
    #>
    $certs = Get-SmimeSigningCertificates
    if ($certs -and $certs.Count -gt 0) { return $certs[0] }
    return $null
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

function Set-DraftSmimeFlag {
    <#
    .SYNOPSIS
    Store Sign/Encrypt flags for a draft in the session state.
    #>
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [bool]$Sign    = $false,
        [bool]$Encrypt = $false
    )
    if (-not $global:State.SmimeDrafts) { $global:State.SmimeDrafts = @{} }
    $global:State.SmimeDrafts[$MessageId] = @{ Sign = $Sign; Encrypt = $Encrypt }
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
    Remove S/MIME flags for a draft after sending.
    #>
    param([Parameter(Mandatory)][string]$MessageId)
    if ($global:State.SmimeDrafts -and
        $global:State.SmimeDrafts.ContainsKey($MessageId)) {
        $global:State.SmimeDrafts.Remove($MessageId)
    }
}

# ============================================================
# SECTION 7 - OUTGOING MIME BUILDING
# ============================================================

function ConvertTo-QuotedPrintable {
    <#
    .SYNOPSIS
    Encode a UTF-8 string as quoted-printable (RFC 2045, max 76 chars/line).
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $sb      = [System.Text.StringBuilder]::new()
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $lineLen = 0

    foreach ($b in $bytes) {
        if ($b -eq 13) { continue }   # skip bare CR
        if ($b -eq 10) {
            [void]$sb.Append("`r`n")
            $lineLen = 0
            continue
        }
        $needsEncode = -not (
            ($b -ge 33 -and $b -le 126 -and $b -ne 61) -or
            $b -eq 9 -or $b -eq 32)
        $encoded = if ($needsEncode) { "={0:X2}" -f $b } else { [char]$b }
        $addLen  = $encoded.Length
        if ($lineLen + $addLen -gt 75) {
            [void]$sb.Append("=`r`n")
            $lineLen = 0
        }
        [void]$sb.Append($encoded)
        $lineLen += $addLen
    }
    return $sb.ToString()
}

function Build-SmimeMimeContent {
    <#
    .SYNOPSIS
    Build inner MIME content (body + attachments) for signing/encrypting.
    Returns a CRLF-terminated string.
    Attachments: array of @{ Name=; ContentType=; Bytes=[byte[]] }
    #>
    param(
        [string]$BodyText,
        [string]$BodyContentType = "text/plain",
        [array]$Attachments      = @()
    )

    $crlf = "`r`n"
    $sb   = [System.Text.StringBuilder]::new()

    $qpBody = ConvertTo-QuotedPrintable -Text $BodyText

    if ($Attachments.Count -eq 0) {
        [void]$sb.Append("Content-Type: $BodyContentType; charset=utf-8$crlf")
        [void]$sb.Append("Content-Transfer-Encoding: quoted-printable$crlf")
        [void]$sb.Append($crlf)
        [void]$sb.Append($qpBody)
        [void]$sb.Append($crlf)
    } else {
        $bnd = "MixedBnd_" + [Guid]::NewGuid().ToString("N")
        [void]$sb.Append("Content-Type: multipart/mixed; boundary=`"$bnd`"$crlf")
        [void]$sb.Append($crlf)
        [void]$sb.Append("--$bnd$crlf")
        [void]$sb.Append("Content-Type: $BodyContentType; charset=utf-8$crlf")
        [void]$sb.Append("Content-Transfer-Encoding: quoted-printable$crlf")
        [void]$sb.Append($crlf)
        [void]$sb.Append($qpBody)
        [void]$sb.Append($crlf)

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
    Returns complete multipart/signed MIME string (CRLF line endings).
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]]$ContentBytes,
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $crlf = "`r`n"

    $ci     = New-Object System.Security.Cryptography.Pkcs.ContentInfo(
        , $ContentBytes)
    $signed = New-Object System.Security.Cryptography.Pkcs.SignedCms($ci, $true)
    $signer = New-Object System.Security.Cryptography.Pkcs.CmsSigner($Certificate)
    $signer.IncludeOption =
        [System.Security.Cryptography.X509Certificates.X509IncludeOption]::EndCertOnly
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

    $bnd     = "SmimeSigBnd_" + [Guid]::NewGuid().ToString("N")
    $content = [System.Text.Encoding]::UTF8.GetString($ContentBytes)

    $mime = [System.Text.StringBuilder]::new()
    [void]$mime.Append(
        "Content-Type: multipart/signed; " +
        "protocol=`"application/pkcs7-signature`"; " +
        "micalg=`"sha-256`"; " +
        "boundary=`"$bnd`"$crlf")
    [void]$mime.Append($crlf)
    [void]$mime.Append("--$bnd$crlf")
    [void]$mime.Append($content)
    if (-not $content.EndsWith($crlf)) { [void]$mime.Append($crlf) }
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

    # 1. Sender address
    $ctx       = Get-MgContext
    $fromEmail = $ctx.Account

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
        $signingCert = Get-DefaultSigningCertificate
        if (-not $signingCert) {
            Write-Error-Message "No S/MIME signing certificate. Run SMIME for instructions."
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

    # 7. Wrap in RFC 2822 envelope
    $crlf     = "`r`n"
    $fullMime  = "MIME-Version: 1.0$crlf" +
                 "From: $fromEmail$crlf"  +
                 "To: $toList$crlf"       +
                 "Subject: $subject$crlf" +
                 $protectedMime

    # 8. Upload
    Write-Info "Uploading..."
    if (-not (Upload-MimeDraft -MessageId $MessageId -MimeContent $fullMime)) {
        return $false
    }
    Write-Success "S/MIME applied"
    return $true
}

function Upload-MimeDraft {
    <#
    .SYNOPSIS
    Upload raw MIME to an existing draft via Graph PUT /messages/{id}/$value.
    Replaces the entire message content including attachments.
    #>
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [Parameter(Mandatory)][string]$MimeContent
    )

    $uri = "/v1.0/me/messages/$MessageId/`$value"
    try {
        [byte[]]$bytes = [System.Text.Encoding]::UTF8.GetBytes($MimeContent)
        Invoke-MgGraphRequest `
            -Method      PUT `
            -Uri         $uri `
            -Body        $bytes `
            -ContentType "text/plain" `
            -ErrorAction Stop
        return $true
    } catch {
        Write-Error-Message "MIME upload: $($_.Exception.Message)"
        return $false
    }
}
