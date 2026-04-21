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

function ConvertFrom-QuotedPrintableMime {
    <#
    .SYNOPSIS
    Decode quoted-printable MIME text to raw bytes.
    Handles soft line breaks and RFC 2045 hex escapes.
    #>
    param([string]$Body)

    if ($null -eq $Body) { return $null }

    $normalized = $Body -replace "=\r?\n", ""
    $bytes = [System.Collections.Generic.List[byte]]::new()

    for ($i = 0; $i -lt $normalized.Length; $i++) {
        $ch = $normalized[$i]
        if ($ch -eq '=' -and $i + 2 -lt $normalized.Length) {
            $hex = $normalized.Substring($i + 1, 2)
            if ($hex -match '^[0-9A-Fa-f]{2}$') {
                [void]$bytes.Add([Convert]::ToByte($hex, 16))
                $i += 2
                continue
            }
        }

        [byte[]]$charBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$ch)
        foreach ($b in $charBytes) {
            [void]$bytes.Add($b)
        }
    }

    return $bytes.ToArray()
}

function Get-MimeCharset {
    <#
    .SYNOPSIS
    Extract charset= from a Content-Type header if present.
    #>
    param([string]$ContentType)

    if ([string]::IsNullOrWhiteSpace($ContentType)) { return $null }
    if ($ContentType -match '(?i)charset\s*=\s*"([^"]+)"') { return $matches[1].Trim() }
    if ($ContentType -match "(?i)charset\s*=\s*'([^']+)'") { return $matches[1].Trim() }
    if ($ContentType -match '(?i)charset\s*=\s*([^\s;]+)') { return $matches[1].Trim(';"'' ') }
    return $null
}

function Get-TextEncodingOrUtf8 {
    <#
    .SYNOPSIS
    Return a .NET text encoding for the given MIME charset, or UTF-8 fallback.
    #>
    param([string]$Charset)

    if ([string]::IsNullOrWhiteSpace($Charset)) {
        return [System.Text.Encoding]::UTF8
    }

    try {
        return [System.Text.Encoding]::GetEncoding($Charset.Trim())
    } catch {
        return [System.Text.Encoding]::UTF8
    }
}

function Get-MultipartPartsRaw {
    <#
    .SYNOPSIS
    Split a multipart body into exact raw part strings without trimming
    significant trailing whitespace. Only the single line break directly
    preceding the next boundary is removed.
    #>
    param(
        [Parameter(Mandatory)][string]$MimeBody,
        [Parameter(Mandatory)][string]$Boundary
    )

    $escapedBoundary = [regex]::Escape($Boundary)
    $pattern = "(?m)^(--$escapedBoundary(?:--)?)[^\r\n]*(\r?\n)"
    $matches = [regex]::Matches($MimeBody, $pattern)
    if ($matches.Count -lt 2) { return @() }

    $parts = [System.Collections.ArrayList]@()
    for ($i = 0; $i -lt $matches.Count - 1; $i++) {
        $current = $matches[$i]
        $next = $matches[$i + 1]
        $delimiter = $current.Groups[1].Value
        if ($delimiter.EndsWith("--")) { break }

        $start = $current.Index + $current.Length
        $length = $next.Index - $start
        if ($length -lt 0) { continue }

        $part = $MimeBody.Substring($start, $length)
        if ($part.EndsWith("`r`n")) {
            $part = $part.Substring(0, $part.Length - 2)
        } elseif ($part.EndsWith("`n")) {
            $part = $part.Substring(0, $part.Length - 1)
        }
        [void]$parts.Add($part)
    }

    return @($parts)
}

function Test-CertificateMatchesEmail {
    <#
    .SYNOPSIS
    Check whether a certificate belongs to the given RFC822 mailbox address.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$EmailAddress
    )

    $emailLower = $EmailAddress.Trim().ToLower()
    $subjectAltName = $Certificate.Extensions | Where-Object {
        $_.Oid.FriendlyName -eq "Subject Alternative Name"
    }
    if ($subjectAltName) {
        $sanText = $subjectAltName.Format($false)
        if ($sanText -match "(?i)(?:^|[,;\s])(?:RFC822 Name|E-mail|Email)\s*=\s*$([regex]::Escape($emailLower))(?:[,;]|$)") {
            return $true
        }
    }

    if ($Certificate.Subject -match '(?i)(?:^|,\s*)(?:E|EMAIL)=([^,]+)') {
        if ($matches[1].Trim().ToLower() -eq $emailLower) { return $true }
    }

    if ($Certificate.Subject -match '(?i)(?:^|,\s*)CN=([^,]+)') {
        $cnValue = $matches[1].Trim().ToLower()
        if ($cnValue -eq $emailLower) { return $true }
    }

    return $false
}

function Test-CertificateHasEmailProtection {
    <#
    .SYNOPSIS
    Check for emailProtection EKU, allowing unrestricted certificates.
    #>
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $oid = $Config.SmimeConfig.EmailProtectionOid
    return ($Certificate.EnhancedKeyUsageList.Count -eq 0 -or
        ($Certificate.EnhancedKeyUsageList | Where-Object {
            $_.ObjectId -eq $oid
        }).Count -gt 0)
}

function Test-CertificateIsCertificateAuthority {
    <#
    .SYNOPSIS
    Return $true for CA certificates, $false for end-entity certificates.
    #>
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    foreach ($ext in $Certificate.Extensions) {
        if ($ext -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]) {
            return $ext.CertificateAuthority
        }
    }
    return $false
}

function Test-CertificateCanEncryptMail {
    <#
    .SYNOPSIS
    Check whether a certificate is suitable as an S/MIME recipient cert.
    #>
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if ($Certificate.NotAfter -lt [DateTime]::UtcNow) { return $false }
    if (Test-CertificateIsCertificateAuthority -Certificate $Certificate) { return $false }
    if (-not (Test-CertificateHasEmailProtection -Certificate $Certificate)) { return $false }

    $keyUsageExt = $Certificate.Extensions | Where-Object {
        $_ -is [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]
    } | Select-Object -First 1

    if (-not $keyUsageExt) { return $true }

    $flags = [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]
    $usage = $keyUsageExt.KeyUsages
    return (($usage -band $flags::KeyEncipherment) -ne 0 -or
            ($usage -band $flags::DataEncipherment) -ne 0 -or
            ($usage -band $flags::KeyAgreement) -ne 0)
}

function Get-MimePartText {
    <#
    .SYNOPSIS
    Decode the body of a single MIME part to a UTF-8 string.
    Handles base64 and identity/7bit/8bit transfer encodings.
    #>
    param([Parameter(Mandatory)][string]$PartContent)

    $ct   = Get-MimeHeaderValue -MimeContent $PartContent -HeaderName "Content-Type"
    $enc  = Get-TextEncodingOrUtf8 -Charset (Get-MimeCharset -ContentType $ct)
    $cte  = Get-MimeHeaderValue -MimeContent $PartContent `
        -HeaderName "Content-Transfer-Encoding"
    $body = Get-MimeBodySection -MimeText $PartContent

    if (-not $cte) {
        return $body.TrimEnd([char[]]"`r`n")
    }

    switch ($cte.ToLower().Trim()) {
        "base64" {
            $bytes = ConvertFrom-Base64Mime -Body $body.Trim()
            if ($bytes) {
                return $enc.GetString($bytes).TrimEnd([char[]]"`r`n")
            }
        }
        "quoted-printable" {
            $bytes = ConvertFrom-QuotedPrintableMime -Body $body
            if ($bytes) {
                return $enc.GetString($bytes).TrimEnd([char[]]"`r`n")
            }
        }
    }

    return $body.TrimEnd([char[]]"`r`n")
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
    $extLower = [System.IO.Path]::GetExtension($nameLower)

    $contentType = ""
    if ($Attachment.PSObject.Properties.Name -contains 'contentType' -and
        $Attachment.contentType) {
        $contentType = "$($Attachment.contentType)".ToLower()
    }

    if ($nameLower -eq 'smime.p7s' -or
        $extLower -eq '.p7s' -or
        $contentType -match '^multipart/signed\b' -or
        $contentType -match '^application/(x-)?pkcs7-signature\b') {
        return "MultipleSigned"
    }

    if ($nameLower -eq 'smime.p7m' -or $extLower -eq '.p7m') {
        # continue below
    } elseif (
        $contentType -notmatch '^application/(x-)?pkcs7-mime\b') {
        # still continue to byte inspection below for generic application/octet-stream
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
                $rawText = [System.Text.Encoding]::ASCII.GetString($contentBytes)
                $looksLikeMime = (
                    $rawText -match '^(?im)(content-type|mime-version|content-transfer-encoding):'
                )
                if ($looksLikeMime) {
                    $embeddedType = Get-SmimeMimeType -MimeContent $rawText
                    if ($embeddedType -ne "None") { return $embeddedType }
                }
            } catch { }
            try {
                $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
                [byte[]]$normalizedEncBytes = ConvertTo-NormalizedCmsBytes `
                    -Bytes $contentBytes -Kind Encrypted
                $env.Decode([byte[]]$normalizedEncBytes)
                return "Encrypted"
            } catch { }
            try {
                $signed = New-Object System.Security.Cryptography.Pkcs.SignedCms
                [byte[]]$normalizedSigBytes = ConvertTo-NormalizedCmsBytes `
                    -Bytes $contentBytes -Kind Signed
                $signed.Decode([byte[]]$normalizedSigBytes)
                return "OpaqueSign"
            } catch { }
        } catch { }
    }

    if ($contentType -match '^application/(x-)?pkcs7-mime\b') {
        # Generic p7m containers are ambiguous, but signed-data can usually be
        # identified by headers or successful SignedCms parsing above. Bias the
        # undecidable fallback toward encrypted to avoid false signature labels
        # for decryptable encrypted-only mail.
        return "Encrypted"
    }

    return "OpaqueSign"
}

function Test-IsSmimeStructuralAttachment {
    <#
    .SYNOPSIS
    Return $true when an attachment is part of the S/MIME wrapper rather than
    a user-visible attachment.
    #>
    param(
        [Parameter(Mandatory)]$Attachment,
        [string]$MessageId = $null
    )

    $type = Get-SmimeTypeFromAttachment -Attachment $Attachment -MessageId $MessageId
    return ($type -ne "None")
}

function Test-IsExplicitSignatureAttachment {
    <#
    .SYNOPSIS
    Return $true only for attachments that explicitly advertise signature
    semantics, not just a generic PKCS#7 MIME container.
    #>
    param([Parameter(Mandatory)]$Attachment)

    $name = ""
    if ($Attachment.PSObject.Properties.Name -contains 'name') {
        $name = "$($Attachment.name)"
    }
    $nameLower = $name.ToLower()
    $extLower = [System.IO.Path]::GetExtension($nameLower)

    $contentType = ""
    if ($Attachment.PSObject.Properties.Name -contains 'contentType' -and
        $Attachment.contentType) {
        $contentType = "$($Attachment.contentType)".ToLower()
    }

    return (
        $nameLower -eq 'smime.p7s' -or
        $extLower -eq '.p7s' -or
        $contentType -match '^multipart/signed\b' -or
        $contentType -match '^application/(x-)?pkcs7-signature\b' -or
        $contentType -match 'smime-type\s*=\s*"?(signed-data)"?'
    )
}

function ConvertTo-NormalizedCmsBytes {
    <#
    .SYNOPSIS
    Normalize PKCS#7/CMS bytes from Graph attachments.
    Some payloads arrive as ASCII base64 text instead of raw DER.
    #>
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateSet("Signed", "Encrypted")]
        [string]$Kind = "Signed"
    )

    $testDecode = if ($Kind -eq "Encrypted") {
        {
            param([byte[]]$Data)
            $cms = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
            $cms.Decode([byte[]]$Data)
        }
    } else {
        {
            param([byte[]]$Data)
            $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
            $cms.Decode([byte[]]$Data)
        }
    }

    try {
        & $testDecode $Bytes
        return $Bytes
    } catch { }

    try {
        $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
        if ($text -match '(?im)^content-type:' -or
            $text -match '(?im)^content-transfer-encoding:') {
            $cte = Get-MimeHeaderValue -MimeContent $text `
                -HeaderName "Content-Transfer-Encoding"
            $body = Get-MimeBodySection -MimeText $text

            $decodedFromMime = $null
            switch (($cte ?? "").ToLower().Trim()) {
                "base64" {
                    $decodedFromMime = ConvertFrom-Base64Mime -Body $body
                }
                "quoted-printable" {
                    $decodedFromMime = ConvertFrom-QuotedPrintableMime -Body $body
                }
                default {
                    $decodedFromMime = ConvertFrom-Base64Mime -Body $body
                }
            }

            if ($decodedFromMime) {
                & $testDecode $decodedFromMime
                return $decodedFromMime
            }
        }
    } catch { }

    try {
        $ascii = [System.Text.Encoding]::ASCII.GetString($Bytes)
        $decoded = ConvertFrom-Base64Mime -Body $ascii
        if ($decoded) {
            & $testDecode $decoded
            return $decoded
        }
    } catch { }

    return $Bytes
}

function Get-ByteHexPreview {
    <#
    .SYNOPSIS
    Return a short uppercase hex preview for debug logging.
    #>
    param(
        [byte[]]$Bytes,
        [int]$Count = 48
    )

    if (-not $Bytes -or $Bytes.Length -eq 0) { return "" }
    return (($Bytes | Select-Object -First $Count) |
        ForEach-Object { $_.ToString('X2') }) -join ' '
}

function Get-ByteAsciiPreview {
    <#
    .SYNOPSIS
    Return a short ASCII preview for debug logging.
    #>
    param(
        [byte[]]$Bytes,
        [int]$Count = 320
    )

    if (-not $Bytes -or $Bytes.Length -eq 0) { return "" }
    $slice = $Bytes | Select-Object -First $Count
    $text = [System.Text.Encoding]::ASCII.GetString([byte[]]$slice)
    return ($text -replace "`r", "<CR>" -replace "`n", "<LF>")
}

function Write-SmimeDebugDump {
    <#
    .SYNOPSIS
    Append a local debug dump for problematic S/MIME messages.
    #>
    param(
        [string]$MessageId,
        [string]$AttachmentName,
        [string]$AttachmentContentType,
        [string]$AttachmentType,
        [string]$BodyContentType,
        [string]$BodyPreview,
        [byte[]]$RawBytes,
        [byte[]]$NormalizedBytes,
        [string]$Error
    )

    try {
        $debugPath = $Config.SmimeDebugPath
        $timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")
        $rawLen = if ($RawBytes) { $RawBytes.Length } else { 0 }
        $normLen = if ($NormalizedBytes) { $NormalizedBytes.Length } else { 0 }

        $lines = @(
            "===== S/MIME Debug $timestamp =====",
            "MessageId: $MessageId",
            "AttachmentName: $AttachmentName",
            "AttachmentContentType: $AttachmentContentType",
            "DetectedAttachmentType: $AttachmentType",
            "BodyContentType: $BodyContentType",
            "Error: $Error",
            "RawLength: $rawLen",
            "RawHex: $(Get-ByteHexPreview -Bytes $RawBytes)",
            "RawAscii: $(Get-ByteAsciiPreview -Bytes $RawBytes)",
            "NormalizedLength: $normLen",
            "NormalizedHex: $(Get-ByteHexPreview -Bytes $NormalizedBytes)",
            "NormalizedAscii: $(Get-ByteAsciiPreview -Bytes $NormalizedBytes)",
            "BodyPreview: $BodyPreview",
            ""
        )
        Add-Content -Path $debugPath -Value $lines -Encoding UTF8
    } catch { }
}

function Get-SmimeStatusFromAttachmentFallback {
    <#
    .SYNOPSIS
    Best-effort S/MIME verification when Graph has already unpacked the message
    into body + PKCS#7 attachment and raw MIME is unavailable.
    Currently supports detached signatures for simple messages without
    user-visible attachments.
    #>
    param(
        [Parameter(Mandatory)]$Message,
        [Parameter(Mandatory)]$Attachment,
        [Parameter(Mandatory)][string]$MessageId,
        [array]$UserAttachments = @()
    )

    $none = @{
        Status = $Config.SmimeStatus.None
        IsEncrypted = $false
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
    }

    $attachmentType = Get-SmimeTypeFromAttachment -Attachment $Attachment -MessageId $MessageId
    if ($attachmentType -ne "MultipleSigned" -and
        $attachmentType -ne "OpaqueSign" -and
        $attachmentType -ne "Encrypted") {
        return $none
    }

    $fullAttachment = $Attachment
    if ((-not $Attachment.PSObject.Properties.Name.Contains('contentBytes')) -or
        -not $Attachment.contentBytes) {
        $fullAttachment = Get-Attachment -MessageId $MessageId -AttachmentId $Attachment.id
    }
    if (-not $fullAttachment -or -not $fullAttachment.contentBytes) {
        return $none
    }

    try {
        [byte[]]$sigBytes = [Convert]::FromBase64String($fullAttachment.contentBytes)
        [byte[]]$normalizedSigBytes = $sigBytes
        $rawText = [System.Text.Encoding]::ASCII.GetString($sigBytes)
        $embeddedMimeType = Get-SmimeMimeType -MimeContent $rawText

        if ($embeddedMimeType -ne "None") {
            $result = Get-SmimeStatusFromMimeContent -MimeContent $rawText
            if (-not $result.Body -and $Message.body.content) {
                $result['Body'] = if ($Message.body.contentType -eq "HTML") {
                    Convert-HtmlToText $Message.body.content
                } else {
                    $Message.body.content
                }
            }
            return $result
        }

        if ($attachmentType -eq "Encrypted") {
            $normalizedSigBytes = ConvertTo-NormalizedCmsBytes -Bytes $sigBytes -Kind Encrypted
            $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
            $env.Decode([byte[]]$normalizedSigBytes)
            $env.Decrypt()
            $innerMime = [System.Text.Encoding]::UTF8.GetString($env.ContentInfo.Content)
            $result = Get-SmimeStatusFromMimeContent -MimeContent $innerMime
            if ($result.Status -eq $Config.SmimeStatus.None) {
                $result = @{
                    Status = $Config.SmimeStatus.Encrypted
                    IsEncrypted = $true
                    Subject = ""; Issuer = ""; ValidUntil = ""
                    Error = ""; Body = Get-MimeReadableText -MimeContent $innerMime
                }
            }
            $result['IsEncrypted'] = $true
            return $result
        }

        if ($attachmentType -eq "OpaqueSign") {
            $normalizedSigBytes = ConvertTo-NormalizedCmsBytes -Bytes $sigBytes -Kind Signed
            $result = Invoke-CmsVerify -SignatureBytes $normalizedSigBytes -IsDetached $false
            $result['Body'] = if ($Message.body.content) { $Message.body.content } else { $null }
            if ($result.Status -eq $Config.SmimeStatus.SignedInvalid -and
                $result.Error -match 'Invalid cryptographic message type') {
                try {
                    $normalizedEncBytes = ConvertTo-NormalizedCmsBytes -Bytes $sigBytes -Kind Encrypted
                    $env = New-Object System.Security.Cryptography.Pkcs.EnvelopedCms
                    $env.Decode([byte[]]$normalizedEncBytes)
                    $env.Decrypt()
                    $innerMime = [System.Text.Encoding]::UTF8.GetString($env.ContentInfo.Content)
                    $encResult = Get-SmimeStatusFromMimeContent -MimeContent $innerMime
                    if ($encResult.Status -eq $Config.SmimeStatus.None) {
                        $encResult = @{
                            Status = $Config.SmimeStatus.Encrypted
                            IsEncrypted = $true
                            Subject = ""; Issuer = ""; ValidUntil = ""
                            Error = ""; Body = Get-MimeReadableText -MimeContent $innerMime
                        }
                    }
                    $encResult['IsEncrypted'] = $true
                    return $encResult
                } catch { }
            }
            if ($result.Status -eq $Config.SmimeStatus.SignedInvalid) {
                $bodyPreview = if ($Message.body.content) {
                    $Message.body.content.Substring(0, [Math]::Min(300, $Message.body.content.Length)).
                        Replace("`r", "<CR>").Replace("`n", "<LF>")
                } else { "" }
                Write-SmimeDebugDump `
                    -MessageId $MessageId `
                    -AttachmentName $fullAttachment.name `
                    -AttachmentContentType $fullAttachment.contentType `
                    -AttachmentType $attachmentType `
                    -BodyContentType $Message.body.contentType `
                    -BodyPreview $bodyPreview `
                    -RawBytes $sigBytes `
                    -NormalizedBytes $normalizedSigBytes `
                    -Error $result.Error
            }
            return $result
        }

        if ($UserAttachments.Count -gt 0) {
            return $none
        }

        $bodyText = if ($Message.body.contentType -eq "HTML") {
            Convert-HtmlToText $Message.body.content
        } else {
            $Message.body.content
        }
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
            return $none
        }

        $reconstructed = Build-SmimeMimeContent -BodyText $bodyText -Attachments @()
        $crlf = "`r`n"
        if ($reconstructed.EndsWith($crlf)) {
            $reconstructed = $reconstructed.Substring(0, $reconstructed.Length - 2)
        }
        [byte[]]$contentBytes = [System.Text.Encoding]::UTF8.GetBytes($reconstructed)
        $normalizedSigBytes = ConvertTo-NormalizedCmsBytes -Bytes $sigBytes -Kind Signed

        $result = Invoke-CmsVerify `
            -SignatureBytes $normalizedSigBytes -ContentBytes $contentBytes -IsDetached $true
        $result['Body'] = $bodyText
        if ($result.Status -eq $Config.SmimeStatus.SignedInvalid) {
            $bodyPreview = $bodyText.Substring(0, [Math]::Min(300, $bodyText.Length)).
                Replace("`r", "<CR>").Replace("`n", "<LF>")
            Write-SmimeDebugDump `
                -MessageId $MessageId `
                -AttachmentName $fullAttachment.name `
                -AttachmentContentType $fullAttachment.contentType `
                -AttachmentType $attachmentType `
                -BodyContentType $Message.body.contentType `
                -BodyPreview $bodyPreview `
                -RawBytes $sigBytes `
                -NormalizedBytes $normalizedSigBytes `
                -Error $result.Error
        }
        return $result
    } catch {
        $bodyPreview = if ($Message.body.content) {
            $body = if ($Message.body.contentType -eq "HTML") {
                Convert-HtmlToText $Message.body.content
            } else {
                $Message.body.content
            }
            $body.Substring(0, [Math]::Min(300, $body.Length)).
                Replace("`r", "<CR>").Replace("`n", "<LF>")
        } else { "" }
        Write-SmimeDebugDump `
            -MessageId $MessageId `
            -AttachmentName $fullAttachment.name `
            -AttachmentContentType $fullAttachment.contentType `
            -AttachmentType $attachmentType `
            -BodyContentType $Message.body.contentType `
            -BodyPreview $bodyPreview `
            -RawBytes $sigBytes `
            -NormalizedBytes $normalizedSigBytes `
            -Error $_.Exception.Message
        $none.Error = $_.Exception.Message
        return $none
    }
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
            $parts = Get-MultipartPartsRaw -MimeBody $body -Boundary $bnd
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

function Get-SmimeStatusFromMimeContent {
    <#
    .SYNOPSIS
    Evaluate S/MIME status from already available raw MIME content.
    #>
    param([Parameter(Mandatory)][string]$MimeContent)

    $none = @{
        Status = $Config.SmimeStatus.None
        IsEncrypted = $false
        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
    }

    try {
        if ($MimeContent -is [byte[]]) {
            $MimeContent = [System.Text.Encoding]::UTF8.GetString($MimeContent)
        }

        $t = Get-SmimeMimeType -MimeContent $MimeContent
        if ($t -eq "None") { return $none }
        if ($t -eq "Encrypted") {
            $decryptErr  = ""
            $innerMime   = $null
            $innerType   = "None"

            try {
                $rawBody  = Get-MimeBodySection -MimeText $MimeContent
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

            if ($innerType -ne "None" -and $innerType -ne "Encrypted") {
                $result = Invoke-SmimeVerification `
                    -MimeContent $innerMime -SmimeType $innerType
                $result['IsEncrypted'] = $true
                $result['Body'] = Get-SmimePlaintextBody `
                    -MimeContent $innerMime -SmimeType $innerType
                return $result
            }

            $decrypted = if ($innerMime) {
                Get-MimeReadableText -MimeContent $innerMime
            } else { $null }

            return @{
                Status = $Config.SmimeStatus.Encrypted
                IsEncrypted = $true
                Subject = ""; Issuer = ""; ValidUntil = ""
                Error  = $decryptErr
                Body   = $decrypted
            }
        }

        $result = Invoke-SmimeVerification -MimeContent $MimeContent -SmimeType $t
        $result['Body'] = Get-SmimePlaintextBody -MimeContent $MimeContent -SmimeType $t
        return $result
    } catch {
        $none.Error = $_.Exception.Message
        return $none
    }
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
        if ($low -match 'smime-type\s*=\s*"?(enveloped-data)"?') { return "Encrypted" }
        if ($low -match 'smime-type\s*=\s*"?(signed-data)"?') { return "OpaqueSign" }
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

    try {
        $mime = Get-MessageMime -MessageId $MessageId
        if (-not $mime) {
            return @{
                Status = $Config.SmimeStatus.None
                Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
            }
        }
        return Get-SmimeStatusFromMimeContent -MimeContent $mime
    } catch {
        return @{
            Status = $Config.SmimeStatus.None
            Subject = ""; Issuer = ""; ValidUntil = ""
            Error = $_.Exception.Message; Body = $null
        }
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
            $parts = Get-MultipartPartsRaw -MimeBody $body -Boundary $boundary
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

    $isEncrypted = ($Details -and $Details.IsEncrypted) -or
        $Status -eq $Config.SmimeStatus.Encrypted

    if ($isEncrypted) {
        Write-Host "Encryption:" -NoNewline `
            -ForegroundColor $Config.Colors.FieldLabel
        Write-Host " Encrypted [S/MIME]" -ForegroundColor $Config.Colors.Success
        if ($Status -eq $Config.SmimeStatus.Encrypted -and $Details -and $Details.Error) {
            Write-Host "Decrypt:     " -NoNewline `
                -ForegroundColor $Config.Colors.FieldLabel
            Write-Host $Details.Error -ForegroundColor $Config.Colors.Warning
        }
        if ($Status -ne $Config.SmimeStatus.Encrypted) {
            Write-Host ""
        }
    }

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
            if (-not $isEncrypted) {
                Write-Host "Encryption:" -NoNewline `
                    -ForegroundColor $Config.Colors.FieldLabel
                Write-Host " Encrypted [S/MIME]" -ForegroundColor $Config.Colors.Success
            }
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
    foreach ($storeName in @("AddressBook", "My")) {
        try {
            $store = New-Object `
                System.Security.Cryptography.X509Certificates.X509Store(
                    $storeName, "CurrentUser")
            $store.Open(
                [System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            foreach ($cert in $store.Certificates) {
                if (-not (Test-CertificateCanEncryptMail -Certificate $cert)) { continue }
                if (Test-CertificateMatchesEmail -Certificate $cert -EmailAddress $emailLower) {
                    $store.Close()
                    return $cert
                }
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
            Test-CertificateMatchesEmail -Certificate $c -EmailAddress $emailLower
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
            $availableSubjects = @(
                Get-SmimeSigningCertificates | ForEach-Object {
                    if ($_.Subject -match '(?i)(?:^|,\s*)CN=([^,]+)') {
                        $matches[1].Trim()
                    } else {
                        $_.Subject
                    }
                }
            )
            $details = if ($availableSubjects.Count -gt 0) {
                " Available cert subjects: " + ($availableSubjects -join "; ")
            } else {
                ""
            }
            Write-Error-Message "No S/MIME signing certificate for '$fromEmail'.$details Run SMIME for instructions."
            return $false
        }
        Write-Info "Signing with: $(Extract-CertCN $signingCert.Subject)"
    }

    # 4b. Recipient certificates (for encryption)
    [System.Security.Cryptography.X509Certificates.X509Certificate2[]]$recipCerts = @()
    if ($Encrypt) {
        $senderEncryptionCert = Get-SmimeEncryptionCertificate -EmailAddress $fromEmail
        if (-not $senderEncryptionCert) {
            Write-Error-Message "No encryption-capable S/MIME certificate for sender '$fromEmail'."
            return $false
        }

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

        $recipCerts += $senderEncryptionCert
        $recipCerts = @(
            $recipCerts | Group-Object Thumbprint | ForEach-Object {
                $_.Group[0]
            }
        )
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
