# mail_read.ps1
# Message reading and display

function Invoke-OpenMessage {
    <#
    .SYNOPSIS
    Open and display a message
    #>
    param([int]$Index)
    
    $item = Get-StateItem $Index
    
    if (-not $item) {
        Write-Error-Message "Invalid message number"
        return
    }
    
    # Fetch only the fields used by the read view and reply/forward context.
    $selectFields = "subject,from,toRecipients,ccRecipients," +
        "receivedDateTime,body,bodyPreview,hasAttachments,isRead," +
        "internetMessageHeaders"
    $msg = Get-Message -MessageId $item.Id -Select $selectFields
    
    if (-not $msg) {
        Write-Error-Message "Failed to load message"
        return
    }

    $readViewStartY = $Host.UI.RawUI.CursorPosition.Y
    $global:State.ReadViewTopY = $readViewStartY
    Start-ReadLayoutDebug -Index $Index -MessageId $item.Id -StartY $readViewStartY

    # Display header. The separator is the first row of the read page; do not
    # add a leading blank line or the viewport target would align that blank
    # row instead of the message header.
    Write-Host ("=" * 70) -ForegroundColor $Config.Colors.Header
    Write-Host "Subject: " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
    Write-Host $msg.subject
    Write-Host "From:    " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
    Write-Host ("{0} <{1}>" -f `
        $msg.from.emailAddress.name, `
        $msg.from.emailAddress.address)
    
    # To recipients
    if ($msg.toRecipients -and $msg.toRecipients.Count -gt 0) {
        Write-Host "To:      " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
        $toList = $msg.toRecipients | ForEach-Object {
            if ($_.emailAddress.name) {
                "{0} <{1}>" -f $_.emailAddress.name, `
                    $_.emailAddress.address
            } else {
                $_.emailAddress.address
            }
        }
        Write-Host ($toList -join ", ")
    }
    
    # Date
    $receivedDate = [datetime]$msg.receivedDateTime
    Write-Host "Date:    " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
    Write-Host (Format-DateTime $receivedDate)
    
    # Pre-fetch attachments (needed for S/MIME fallback detection below)
    $fileAttachments = @()
    if ($msg.hasAttachments) {
        $fileAttachments = @(
            (Get-MessageAttachments -MessageId $item.Id) | Where-Object {
                $_.'@odata.type' -eq '#microsoft.graph.fileAttachment'
            }
        )
    }

    # Classify attachments before verification. A message with neither S/MIME
    # headers nor structural S/MIME attachments should not trigger the raw-MIME
    # verification path or show a misleading transient status line.
    $structuralAttachment = $null
    if ($fileAttachments.Count -gt 0) {
        $structuralAttachment = @(
            $fileAttachments | Where-Object {
                Test-IsSmimeStructuralAttachment `
                    -Attachment $_ -MessageId $item.Id
            }
        ) | Select-Object -First 1
    }
    $userAttachments = @($fileAttachments | Where-Object {
        -not (Test-IsSmimeStructuralAttachment -Attachment $_ -MessageId $item.Id)
    })

    $contentTypeHeader = Get-InternetMessageHeaderValue `
        -Headers $msg.internetMessageHeaders `
        -HeaderName "Content-Type"
    $contentTypeLower = if ($contentTypeHeader) {
        $contentTypeHeader.ToLowerInvariant()
    } else { "" }
    $hasSmimeHeaderHint = (
        $contentTypeLower -match '^multipart/signed\b' -or
        $contentTypeLower -match '^application/(x-)?pkcs7-(mime|signature)\b' -or
        $contentTypeLower -match 'smime-type\s*='
    )
    $hasSmimeHint = ($hasSmimeHeaderHint -or $null -ne $structuralAttachment)

    # S/MIME verification (all read-only folders; result is cached per session)
    $smimeResult = $null
    if ($global:State.View -ne $Config.Folders.Drafts -and $Config.SmimeConfig.AutoVerify) {
        $smimeFromCache = $false
        if (-not $global:State.SmimeCache) { $global:State.SmimeCache = @{} }
        if ($global:State.SmimeCache.ContainsKey($item.Id)) {
            $cachedSmimeResult = $global:State.SmimeCache[$item.Id]
            if ($hasSmimeHint -and
                (Test-PersistableSmimeStatus `
                    $cachedSmimeResult.Status `
                    ([bool]$cachedSmimeResult.IsEncrypted))) {
                $smimeResult = $cachedSmimeResult
                $smimeFromCache = $true
            } else {
                $global:State.SmimeCache.Remove($item.Id)
            }
        }

        $verificationLineShown = $false
        if (-not $smimeResult -and $hasSmimeHint) {
            Write-Host "Verifying S/MIME..." `
                -ForegroundColor $Config.Colors.Info
            $verificationLineShown = $true
            $smimeResult = Get-MessageSmimeStatus -MessageId $item.Id
            if (Test-PersistableSmimeStatus `
                    $smimeResult.Status `
                    ([bool]$smimeResult.IsEncrypted)) {
                $global:State.SmimeCache[$item.Id] = $smimeResult
                Save-SmimeCache
            }
        }
        if (-not $smimeResult) {
            $smimeResult = @{
                Status      = $Config.SmimeStatus.None
                IsEncrypted = $false
                Subject     = ""; Issuer = ""; ValidUntil = ""
                Error       = ""; Body = $null
            }
        }
        $item.SmimeStatus = $smimeResult.Status
        $item.IsEncrypted = [bool]$smimeResult.IsEncrypted

        # Fallback/reconciliation when raw MIME is inaccessible or an old cache
        # entry classified an opaque-signed smime.p7m as encrypted.
        if ($fileAttachments.Count -gt 0) {
            # Old versions could misclassify regular attachments such as PDFs as
            # opaque S/MIME signatures and persist SignedInvalid in the cache.
            # If the current attachment scan finds no structural S/MIME part,
            # drop that weak cached status and treat the message as non-S/MIME.
            if (-not $structuralAttachment -and
                $smimeFromCache -and
                $smimeResult -and
                ($item.SmimeStatus -eq $Config.SmimeStatus.SignedInvalid -or
                 $item.SmimeStatus -eq $Config.SmimeStatus.SignedUntrusted) -and
                -not [bool]$smimeResult.IsEncrypted -and
                [string]::IsNullOrWhiteSpace("$($smimeResult.Subject)") -and
                [string]::IsNullOrWhiteSpace("$($smimeResult.Issuer)")) {
                $item.SmimeStatus = $Config.SmimeStatus.None
                $item.IsEncrypted = $false
                $smimeResult = @{
                    Status      = $Config.SmimeStatus.None
                    IsEncrypted = $false
                    Subject     = ""; Issuer = ""; ValidUntil = ""
                    Error       = ""; Body = $null
                }
                $global:State.SmimeCache[$item.Id] = $smimeResult
                Save-SmimeCache
            }

            if ($structuralAttachment) {
                $attachmentType = Get-SmimeTypeFromAttachment `
                    -Attachment $structuralAttachment -MessageId $item.Id

                $attachmentFallback = Get-SmimeStatusFromAttachmentFallback `
                    -Message $msg `
                    -Attachment $structuralAttachment `
                    -MessageId $item.Id `
                    -UserAttachments $userAttachments
                if ($attachmentFallback.Status -ne $Config.SmimeStatus.None) {
                    $smimeResult = $attachmentFallback
                    $item.SmimeStatus = $attachmentFallback.Status
                    $item.IsEncrypted = [bool]$attachmentFallback.IsEncrypted
                    $global:State.SmimeCache[$item.Id] = $smimeResult
                    Save-SmimeCache
                }

                $isExplicitSignature = Test-IsExplicitSignatureAttachment `
                    -Attachment $structuralAttachment

                if ($attachmentType -eq "MultipleSigned" -or
                    $attachmentType -eq "OpaqueSign") {
                    if ($item.SmimeStatus -eq $Config.SmimeStatus.SignedTrusted -or
                        $item.SmimeStatus -eq $Config.SmimeStatus.SignedUntrusted -or
                        $item.SmimeStatus -eq $Config.SmimeStatus.SignedInvalid) {
                        # Verified via attachment reconstruction above.
                    } elseif ($isExplicitSignature -and
                        ($item.SmimeStatus -eq $Config.SmimeStatus.None -or
                        $item.SmimeStatus -eq $Config.SmimeStatus.Encrypted)) {
                        $item.SmimeStatus = $Config.SmimeStatus.SignedUntrusted
                        $smimeResult = @{
                            Status     = $Config.SmimeStatus.SignedUntrusted
                            IsEncrypted = $false
                            Subject    = ""; Issuer = ""; ValidUntil = ""
                            Error      = "Signature detected but could not be verified"
                            Body       = $null
                        }
                        $item.IsEncrypted = $false
                        $global:State.SmimeCache[$item.Id] = $smimeResult
                        Save-SmimeCache
                    } elseif (-not $isExplicitSignature -and
                        $item.SmimeStatus -eq $Config.SmimeStatus.None) {
                        $item.SmimeStatus = $Config.SmimeStatus.Encrypted
                        $item.IsEncrypted = $true
                        $smimeResult = @{
                            Status = $Config.SmimeStatus.Encrypted
                            IsEncrypted = $true
                            Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
                        }
                        $global:State.SmimeCache[$item.Id] = $smimeResult
                        Save-SmimeCache
                    }
                } elseif ($attachmentType -eq "Encrypted" -and
                          $item.SmimeStatus -eq $Config.SmimeStatus.None) {
                    $item.SmimeStatus = $Config.SmimeStatus.Encrypted
                    $item.IsEncrypted = $true
                    $smimeResult = @{
                        Status = $Config.SmimeStatus.Encrypted
                        IsEncrypted = $true
                        Subject = ""; Issuer = ""; ValidUntil = ""; Error = ""; Body = $null
                    }
                    $global:State.SmimeCache[$item.Id] = $smimeResult
                    Save-SmimeCache
                }
            }
        }
    }

    if ($item.SmimeStatus -ne $Config.SmimeStatus.None) {
        Show-SmimeInfo `
            -MessageId $item.Id `
            -Status    $item.SmimeStatus `
            -Details   $smimeResult
    }

    # Attachments — use the already-fetched list; filter out S/MIME structural files
    if ($smimeResult) {
        $smimeResult['HasUserAttachments'] = ($userAttachments.Count -gt 0)
        $smimeResult['IsEncrypted'] = [bool]$item.IsEncrypted
        if ($global:State.SmimeCache) {
            $global:State.SmimeCache[$item.Id] = $smimeResult
            Save-SmimeCache
        }
    }
    $item.HasAttachments = ($userAttachments.Count -gt 0)
    if ($userAttachments.Count -gt 0) {
        Write-Host ""
        Write-Host "Attachments: " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
        Write-Host "$($userAttachments.Count) file(s)"
        Write-Host "[SAVE #] Save attachment" `
            -ForegroundColor $Config.Colors.MenuAction
        Write-Host "[SAVEALL] Save all attachments" `
            -ForegroundColor $Config.Colors.MenuAction
    }
    
    Write-Host ("=" * 70) -ForegroundColor $Config.Colors.Header
    Write-Host ""
    
    # Body
    $body = $msg.body.content
    
    # Strip HTML if needed
    if ($msg.body.contentType -eq "HTML") {
        $body = Convert-HtmlToText $body
    } else {
        # For plain text emails, still unwrap SafeLinks
        $safelinkPattern = 'https?://[^\s<>]*([a-z0-9-]+\.)?safelinks\.protection\.outlook\.com[^\s<>]*'
        $safelinkMatches = [regex]::Matches($body, $safelinkPattern)
        foreach ($slMatch in $safelinkMatches) {
            $safeUrl = $slMatch.Value
            $unwrapped = Unwrap-SafeLink $safeUrl
            $body = $body.Replace($safeUrl, $unwrapped)
        }
    }

    # For S/MIME messages, body.content is often empty. Depending on how Graph
    # normalized the message, the text can be in an S/MIME container or in a
    # normal raw-MIME text part next to a structural S/MIME attachment.
    # Fallback chain:
    #   1. $smimeResult.Body  - from live verification (not persisted in cache)
    #   2. Lazy extraction    - fetch raw MIME and extract if Body is null
    #      (handles the case where result came from persistent cache with Body=null)
    #   3. bodyPreview        - Graph text snippet (~255 chars)
    $bodyPreviewLineShown = $false
    if ([string]::IsNullOrWhiteSpace($body)) {
        if ($smimeResult -and $smimeResult.Body) {
            $body = $smimeResult.Body
        } else {
            # Body not cached or not classified as S/MIME: try raw MIME.
            $rawMime = Get-MessageMime -MessageId $item.Id
            if ($rawMime) {
                $mimeType = Get-SmimeMimeType -MimeContent $rawMime
                if ($mimeType -ne "None") {
                    $body = Get-SmimePlaintextBody `
                        -MimeContent $rawMime -SmimeType $mimeType
                } else {
                    $body = Get-MimeReadableText -MimeContent $rawMime
                }
                if ($body -and $smimeResult) {
                    $smimeResult['Body'] = $body  # session cache
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($body) -and
            -not [string]::IsNullOrWhiteSpace($msg.bodyPreview)) {
            $body = $msg.bodyPreview
            Write-Host "(S/MIME: showing text preview — full body not extractable)" `
                -ForegroundColor $Config.Colors.Info
            $bodyPreviewLineShown = $true
        }
    }
    
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    if ($consoleWidth -le 0) { $consoleWidth = 80 }

    $headerLines = Get-OpenMessageHeaderLineCount `
        -Message $msg `
        -SmimeStatus $item.SmimeStatus `
        -SmimeDetails $smimeResult `
        -UserAttachmentCount $userAttachments.Count `
        -VerificationLineShown $verificationLineShown `
        -BodyPreviewLineShown $bodyPreviewLineShown `
        -Width $consoleWidth
    $footerLines = Get-OpenMessageFooterLineCount -Width $consoleWidth
    $postReadLines = Get-PostOpenMessageLineCount `
        -View $global:State.View `
        -Width $consoleWidth
    Add-ReadLayoutDebugPoint `
        -Name "after-header" `
        -Extra @{
            HeaderLines = $headerLines
            FooterLines = $footerLines
            PostReadLines = $postReadLines
            Width = $consoleWidth
            Height = $Host.UI.RawUI.WindowSize.Height
        }
    
    # Display body with paging
    Show-PagedContent `
        -Content $body `
        -HeaderLinesUsed $headerLines `
        -FooterLinesUsed $footerLines `
        -PostContentLinesUsed $postReadLines
    Add-ReadLayoutDebugPoint -Name "after-paged-body"
    Write-Host ""
    
    # Show reply/forward options
    Write-Host "[REPLY] Reply to sender  [REPLYALL] Reply to all  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuAction
    Write-Host "[FORWARD] Forward" -ForegroundColor $Config.Colors.MenuAction
    Write-Host ""
    Add-ReadLayoutDebugPoint -Name "after-read-footer"
    
    # Mark as read if it was unread
    if (-not $msg.isRead) {
        $null = Update-Message -MessageId $item.Id `
            -Properties @{ isRead = $true }
        $item.IsRead = $true
    }
    
    # Store current open message
    $global:State.OpenMessageId = $item.Id
}

function Invoke-ReplyMessage {
    <#
    .SYNOPSIS
    Reply to the currently open message
    #>
    param([bool]$ReplyAll = $false)
    
    if (-not $global:State.OpenMessageId) {
        Write-Error-Message "No message is currently open"
        return
    }
    
    # Fetch original message
    $msg = Get-Message -MessageId $global:State.OpenMessageId
    
    if (-not $msg) {
        Write-Error-Message "Failed to load message"
        return
    }
    
    # Build recipient list
    $toAddresses = @()
    
    # Always include original sender
    $toAddresses += $msg.from.emailAddress.address
    
    # Reply All: add all original recipients except ourselves
    if ($ReplyAll) {
        $myAddress = (Get-CurrentUserEmail).ToLower()
        
        if ($msg.toRecipients) {
            foreach ($recipient in $msg.toRecipients) {
                $addr = $recipient.emailAddress.address.ToLower()
                if ($addr -ne $myAddress -and $toAddresses -notcontains $addr) {
                    $toAddresses += $recipient.emailAddress.address
                }
            }
        }
        
        if ($msg.ccRecipients) {
            foreach ($recipient in $msg.ccRecipients) {
                $addr = $recipient.emailAddress.address.ToLower()
                if ($addr -ne $myAddress -and $toAddresses -notcontains $addr) {
                    $toAddresses += $recipient.emailAddress.address
                }
            }
        }
    }
    
    $toList = $toAddresses -join ", "
    
    # Build subject with Re:
    $rePrefix = $Config.EmailTemplates.ReplyPrefix
    $subject = $msg.subject
    if ($subject -notmatch "^$rePrefix") {
        $subject = $rePrefix + $subject
    }
    
    # Get original body
    $originalBody = $msg.body.content
    if ($msg.body.contentType -eq "HTML") {
        $originalBody = Convert-HtmlToText $originalBody
    }
    
    # Build quoted reply
    $receivedDate = [datetime]$msg.receivedDateTime
    $msgHeader = $Config.EmailTemplates.OriginalMessageHeader
    $quotePrefix = $Config.EmailTemplates.QuotePrefix
    $quotedBody = "`n`n$msgHeader`n"
    $quotedBody += "From: $($msg.from.emailAddress.address)`n"
    $quotedBody += "Date: $(Format-DateTime $receivedDate)`n"
    $quotedBody += "Subject: $($msg.subject)`n`n"
    
    # Quote each line of original
    $originalBody -split "`n" | ForEach-Object {
        $quotedBody += "$quotePrefix$_`n"
    }
    $quotedBody = Format-QuotedMessageBlock `
        -Text $quotedBody `
        -HeaderMarker $msgHeader
    
    # Build template
    $separator = $Config.EmailTemplates.HeaderSeparator
    $template = @"
To: $toList
Subject: $subject
Attachments: 
Signature: no
Sign: no
Encrypt: no

$separator
$quotedBody
"@
    
    # Open editor
    try {
        $result = Edit-DraftInEditor -Content $template
    } catch {
        Write-Error-Message "Editor failed: $($_.Exception.Message)"
        return
    }
    
    if (-not $result.Changed) {
        Write-Info "Reply cancelled"
        return
    }
    
    # Parse and create draft
    try {
        $parsed = Parse-DraftContent $result.Content
    } catch {
        Write-Error-Message "Parse failed: $($_.Exception.Message)"
        return
    }
    
    if (-not $parsed) {
        Write-Error-Message "Invalid draft format"
        return
    }
    
    # Validate attachments
    $resolvedAttachments = @()
    if ($parsed.Attachments -and $parsed.Attachments.Count -gt 0) {
        $validationResult = Test-AttachmentPaths $parsed.Attachments
        if (-not $validationResult.Valid) {
            Write-Error-Message ("Invalid attachment(s): {0}" `
                -f ($validationResult.Missing -join ", "))
            return
        }
        $resolvedAttachments = $validationResult.Resolved
    }
    
    $toRecipients  = ConvertTo-RecipientArray $parsed.To

    if ($parsed.Encrypt) {
        $draft = New-DraftMessage `
            -Subject      $parsed.Subject `
            -Body         (Get-EncryptedDraftPlaceholderBody) `
            -ToRecipients $toRecipients `
            -ContentType  "Text"
    } else {
        $footerResult  = Apply-DraftFooterBeforeQuotedSection `
            -BodyText $parsed.Body `
            -QuotedSectionHeader $Config.EmailTemplates.OriginalMessageHeader `
            -Enabled $parsed.Signature

        # Create draft
        $draft = New-DraftMessage `
            -Subject      $parsed.Subject `
            -Body         $footerResult.Body `
            -ToRecipients $toRecipients `
            -ContentType  $footerResult.ContentType
    }
    
    if (-not $draft) {
        Write-Error-Message "Failed to create reply"
        return
    }

    if ($parsed.Encrypt) {
        if (-not (Save-EncryptedDraftLocally `
            -MessageId $draft.id `
            -ParsedDraft $parsed `
            -ResolvedAttachments $resolvedAttachments)) {
            Remove-Message -MessageId $draft.id | Out-Null
            Write-Error-Message "Failed to prepare encrypted reply draft"
            return
        }
        Write-Success "Reply draft created (ID: $($draft.id))"
        Write-Info "Encrypted reply body is kept local; online draft is a placeholder"
    } else {
        Set-DraftSmimeFlag -MessageId $draft.id -Sign $parsed.Sign -Encrypt $parsed.Encrypt
        Write-Success "Reply draft created (ID: $($draft.id))"
        Invoke-UploadAttachments -MessageId $draft.id -FilePaths $resolvedAttachments
    }
    Write-Info "Reply saved in Drafts folder"
}

function Invoke-ForwardMessage {
    <#
    .SYNOPSIS
    Forward the currently open message
    #>
    
    if (-not $global:State.OpenMessageId) {
        Write-Error-Message "No message is currently open"
        return
    }
    
    # Fetch original message
    $msg = Get-Message -MessageId $global:State.OpenMessageId
    
    if (-not $msg) {
        Write-Error-Message "Failed to load message"
        return
    }
    
    # Build subject with Fwd:
    $fwdPrefix = $Config.EmailTemplates.ForwardPrefix
    $subject = $msg.subject
    if ($subject -notmatch "^$fwdPrefix" -and $subject -notmatch '^FW:') {
        $subject = $fwdPrefix + $subject
    }
    
    # Get original body
    $originalBody = $msg.body.content
    if ($msg.body.contentType -eq "HTML") {
        $originalBody = Convert-HtmlToText $originalBody
    }
    
    # Build forwarded message
    $receivedDate = [datetime]$msg.receivedDateTime
    $msgHeader = $Config.EmailTemplates.ForwardedMessageHeader
    $forwardedBody = "`n`n$msgHeader`n"
    $forwardedBody += "From: $($msg.from.emailAddress.address)`n"
    $forwardedBody += "Date: $(Format-DateTime $receivedDate)`n"
    $forwardedBody += "Subject: $($msg.subject)`n"
    
    if ($msg.toRecipients -and $msg.toRecipients.Count -gt 0) {
        $toList = ($msg.toRecipients | ForEach-Object { 
            $_.emailAddress.address 
        }) -join ", "
        $forwardedBody += "To: $toList`n"
    }
    
    $forwardedBody += "`n$originalBody"
    
    # Build template
    $separator = $Config.EmailTemplates.HeaderSeparator
    $template = @"
To: 
Subject: $subject
Attachments: 
Signature: no
Sign: no
Encrypt: no

$separator
$forwardedBody
"@
    
    # Open editor
    try {
        $result = Edit-DraftInEditor -Content $template
    } catch {
        Write-Error-Message "Editor failed: $($_.Exception.Message)"
        return
    }
    
    if (-not $result.Changed) {
        Write-Info "Forward cancelled"
        return
    }
    
    # Parse and create draft
    try {
        $parsed = Parse-DraftContent $result.Content
    } catch {
        Write-Error-Message "Parse failed: $($_.Exception.Message)"
        return
    }
    
    if (-not $parsed) {
        Write-Error-Message "Invalid draft format"
        return
    }
    
    # Validate attachments
    $resolvedAttachments = @()
    if ($parsed.Attachments -and $parsed.Attachments.Count -gt 0) {
        $validationResult = Test-AttachmentPaths $parsed.Attachments
        if (-not $validationResult.Valid) {
            Write-Error-Message ("Invalid attachment(s): {0}" `
                -f ($validationResult.Missing -join ", "))
            return
        }
        $resolvedAttachments = $validationResult.Resolved
    }
    
    $toRecipients = ConvertTo-RecipientArray $parsed.To

    if ($parsed.Encrypt) {
        $draft = New-DraftMessage `
            -Subject      $parsed.Subject `
            -Body         (Get-EncryptedDraftPlaceholderBody) `
            -ToRecipients $toRecipients `
            -ContentType  "Text"
    } else {
        $footerResult = Apply-DraftFooterBeforeQuotedSection `
            -BodyText $parsed.Body `
            -QuotedSectionHeader $Config.EmailTemplates.ForwardedMessageHeader `
            -Enabled $parsed.Signature

        # Create draft
        $draft = New-DraftMessage `
            -Subject      $parsed.Subject `
            -Body         $footerResult.Body `
            -ToRecipients $toRecipients `
            -ContentType  $footerResult.ContentType
    }
    
    if (-not $draft) {
        Write-Error-Message "Failed to create forward"
        return
    }

    if ($parsed.Encrypt) {
        if (-not (Save-EncryptedDraftLocally `
            -MessageId $draft.id `
            -ParsedDraft $parsed `
            -ResolvedAttachments $resolvedAttachments)) {
            Remove-Message -MessageId $draft.id | Out-Null
            Write-Error-Message "Failed to prepare encrypted forward draft"
            return
        }
        Write-Success "Forward draft created (ID: $($draft.id))"
        Write-Info "Encrypted forward body is kept local; online draft is a placeholder"
    } else {
        Set-DraftSmimeFlag -MessageId $draft.id -Sign $parsed.Sign -Encrypt $parsed.Encrypt
        Write-Success "Forward draft created (ID: $($draft.id))"
        Invoke-UploadAttachments -MessageId $draft.id -FilePaths $resolvedAttachments
    }
    Write-Info "Forward saved in Drafts folder"
}

function Unwrap-SafeLink {
    <#
    .SYNOPSIS
    Extract original URL from Microsoft SafeLinks wrapper
    #>
    param([string]$Url)
    
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }
    
    # Check if this is a SafeLink (Outlook, ATP, etc.)
    # Match various regional SafeLink domains like nor01.safelinks.protection.outlook.com
    if ($Url -match '([a-z0-9-]+\.)?safelinks\.protection\.outlook\.com') {
        # Try to extract the 'url' parameter (most common)
        if ($Url -match '[?&]url=([^&\s]+)') {
            $encodedUrl = $matches[1]
            # URL decode (may need multiple passes)
            try {
                $decodedUrl = [System.Web.HttpUtility]::UrlDecode($encodedUrl)
                # Sometimes it's double-encoded, try again
                if ($decodedUrl -match '%[0-9A-Fa-f]{2}') {
                    $decodedUrl = [System.Web.HttpUtility]::UrlDecode($decodedUrl)
                }
                return $decodedUrl
            } catch {
                # If decoding fails, return the encoded version
                return $encodedUrl
            }
        }
    }
    
    # Return original URL if not a SafeLink
    return $Url
}

function Convert-HtmlToText {
    <#
    .SYNOPSIS
    Convert HTML to clean text, removing all CSS and styling
    #>
    param([string]$Html)
    
    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ""
    }
    
    $text = $Html -replace "`r`n", "`n"
    
    # Step 1: Remove problematic elements entirely
    $text = $text -replace '(?si)<!--.*?-->', ''
    $text = $text -replace '(?si)<script[^>]*>.*?</script>', ''
    $text = $text -replace '(?si)<style[^>]*>.*?</style>', ''
    $text = $text -replace '(?si)<head[^>]*>.*?</head>', ''
    $text = $text -replace '(?si)<title[^>]*>.*?</title>', ''
    
    # Step 2: Preserve common structural markers before stripping tags
    $text = $text -replace '(?si)<hr[^>]*>', "`n----------------------------------------`n"
    $text = $text -replace '(?si)<img[^>]*alt=["'']([^"'']+)["''][^>]*>', ' [$1] '
    $text = $text -replace '(?si)<img[^>]*>', ''
    
    # Step 3: Keep readable table/list structure
    $text = $text -replace '(?si)</?table[^>]*>', ''
    $text = $text -replace '(?si)</?tbody[^>]*>', ''
    $text = $text -replace '(?si)</?thead[^>]*>', ''
    $text = $text -replace '(?si)</?tfoot[^>]*>', ''
    $text = $text -replace '(?si)<tr[^>]*>', ''
    $text = $text -replace '(?si)</tr[^>]*>', "`n"
    $text = $text -replace '(?si)<t[dh][^>]*>', ''
    $text = $text -replace '(?si)</t[dh][^>]*>', ' | '
    $text = $text -replace '(?si)<li[^>]*>', "`n- "
    
    # Step 4: Extract links before removing remaining tags.
    # Allow nested inline markup inside the anchor.
    $text = [regex]::Replace(
        $text,
        '(?is)<a\b[^>]*href=["'']([^"'']+)["''][^>]*>(.*?)</a>',
        {
            param($m)
            $url = Unwrap-SafeLink $m.Groups[1].Value
            $inner = $m.Groups[2].Value
            $label = $inner -replace '(?is)<br\s*/?>', ' '
            $label = $label -replace '(?is)<[^>]+>', ''
            $label = [System.Web.HttpUtility]::HtmlDecode($label).Trim()

            if ([string]::IsNullOrWhiteSpace($label)) {
                return "__LINK__$url`__ENDLINK__"
            }
            if ($label -eq $url) {
                return $label
            }
            return "$label __LINK__$url`__ENDLINK__"
        }
    )
    
    # Step 5: Convert block elements to newlines
    # Outlook HTML commonly uses <div> for each visual line. Treating </div> as a
    # space collapses whole messages into one paragraph, which breaks reply/forward
    # quoting badly. Prefer preserving line structure over compact layout here.
    $text = $text -replace '(?si)</(div|p|h[1-6]|li|ul|ol|blockquote|section|article|header|footer|address|pre)>', "`n"
    $text = $text -replace '(?si)<br\s*/?>', "`n"

    # Step 6: Remove ALL remaining HTML tags
    $text = $text -replace '<[^>]+>', ''
    
    # Step 7: Decode HTML entities
    $text = [System.Web.HttpUtility]::HtmlDecode($text)
    $text = $text -replace [char]0x00A0, ' '
    
    # Step 8: Clean up whitespace
    $text = $text -replace '[ \t]+', ' '  # Multiple spaces/tabs to single space
    $text = $text -replace '(?m)( \| )+$', ''  # Trim trailing table separators
    $text = $text -replace '(?m)^(?:\| )+', ''  # Trim leading table separators
    $text = $text -replace ' *\n *', "`n"  # Remove spaces around newlines
    $text = $text -replace '\n{3,}', "`n`n"  # Max 2 consecutive newlines
    
    # Step 9: Trim whitespace from each line (keep blank lines for paragraph spacing)
    # Step 8 already ensures max 1 blank line between paragraphs
    $lines = $text -split "`n" | ForEach-Object { $_.Trim() }
    $text = $lines -join "`n"
    
    # Step 10: Restore links with angle brackets
    $text = $text -replace '__LINK__', ' <'
    $text = $text -replace '__ENDLINK__', '>'
    
    # Step 11: Unwrap remaining SafeLinks in plain text
    $safelinkPattern = 'https?://[^\s<>]*safelinks\.protection\.outlook\.com[^\s<>]*'
    $text = [regex]::Replace($text, $safelinkPattern, { param($m) Unwrap-SafeLink $m.Value })
    
    return $text.Trim()
}

function Get-ConsoleWrappedLineCount {
    <#
    .SYNOPSIS
    Estimate how many physical console rows one logical line will occupy.
    #>
    param(
        [AllowNull()]
        [string]$Line,
        [int]$Width
    )

    if ($Width -le 0) { $Width = 80 }
    if ([string]::IsNullOrEmpty($Line)) { return 1 }

    $visibleLine = Remove-TerminalControlSequences $Line
    $cellCount = Get-ConsoleDisplayCellCount -Text $visibleLine
    if ($cellCount -le 0) { return 1 }

    return [Math]::Max(1, [int][Math]::Ceiling($cellCount / $Width))
}

function Test-ReadLayoutDebugEnabled {
    return ($env:PSMAIL_LAYOUT_DEBUG -eq "1" -or
            $env:PSMAIL_LAYOUT_DEBUG -eq "true")
}

function Get-ReadLayoutDebugPath {
    $root = if ($Config.CurrentAccount -and $Config.CurrentAccount.DataPath) {
        $Config.CurrentAccount.DataPath
    } else {
        $Config.DataRootPath
    }
    return Join-Path $root "read-layout-debug.log"
}

function Start-ReadLayoutDebug {
    param(
        [int]$Index,
        [string]$MessageId,
        [int]$StartY
    )

    if (-not (Test-ReadLayoutDebugEnabled)) { return }

    $global:State.ReadLayoutDebug = @{
        Path = Get-ReadLayoutDebugPath
        StartY = $StartY
        Points = @()
    }

    Add-ReadLayoutDebugPoint `
        -Name "start" `
        -Extra @{
            Index = $Index
            MessageId = $MessageId
            Window = "{0}x{1}" -f `
                $Host.UI.RawUI.WindowSize.Width, `
                $Host.UI.RawUI.WindowSize.Height
            Buffer = "{0}x{1}" -f `
                $Host.UI.RawUI.BufferSize.Width, `
                $Host.UI.RawUI.BufferSize.Height
        }
}

function Add-ReadLayoutDebugPoint {
    param(
        [string]$Name,
        [hashtable]$Extra = @{}
    )

    if (-not $global:State -or -not $global:State.ReadLayoutDebug) {
        return
    }

    $raw = $Host.UI.RawUI
    $point = [ordered]@{
        Name = $Name
        CursorY = $raw.CursorPosition.Y
        WindowY = $raw.WindowPosition.Y
        DeltaFromStart = $raw.CursorPosition.Y - [int]$global:State.ReadLayoutDebug.StartY
    }
    foreach ($key in $Extra.Keys) {
        $point[$key] = $Extra[$key]
    }
    $global:State.ReadLayoutDebug.Points += [pscustomobject]$point
}

function Flush-ReadLayoutDebug {
    if (-not $global:State -or -not $global:State.ReadLayoutDebug) {
        return
    }

    try {
        $path = $global:State.ReadLayoutDebug.Path
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $lines = @("===== Read layout debug $timestamp =====")
        foreach ($point in $global:State.ReadLayoutDebug.Points) {
            $values = @()
            foreach ($prop in $point.PSObject.Properties) {
                $values += ("{0}={1}" -f $prop.Name, $prop.Value)
            }
            $lines += ($values -join " | ")
        }
        $lines += ""
        Add-Content -Path $path -Value $lines -Encoding utf8
    } catch {
    } finally {
        $global:State.Remove("ReadLayoutDebug")
    }
}

function Get-ConsoleDisplayCellCount {
    <#
    .SYNOPSIS
    Estimate console display cells, including tab expansion.
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return 0 }

    $cells = 0
    foreach ($char in $Text.ToCharArray()) {
        if ($char -eq "`t") {
            $cells += 8 - ($cells % 8)
        } elseif ([char]::IsControl($char)) {
            continue
        } else {
            $cells++
        }
    }

    return $cells
}

function Get-OpenMessageFooterLineCount {
    param([int]$Width)

    $menuLine = "[REPLY] Reply to sender  [REPLYALL] Reply to all  [FORWARD] Forward"
    return 2 + (Get-ConsoleWrappedLineCount -Line $menuLine -Width $Width)
}

function Get-PostOpenMessageLineCount {
    <#
    .SYNOPSIS
    Count the menu and prompt printed by the main loop after opening a message.
    #>
    param(
        [string]$View,
        [int]$Width
    )

    $lines = @(
        "",
        ("-" * 70)
    )

    switch ($View) {
        "inbox" {
            $lines += "[L] List  [R #] Read  [X #/#-#] Delete  [K #/#-#] Junk"
            $lines += "[FOCUS #] Relevant  [OTHER #] Sonstige  [FOCUS! #] Always Relevant  [OTHER! #] Always Sonstige"
        }
        "drafts" {
            $lines += "[L] List  [NEW] New  [E #] Edit  [SEND #] Send  [X #/#-#] Delete"
        }
        "sentitems" {
            $lines += "[L] List  [R #] Read  [REDRAFT #]  [X #/#-#] Delete"
        }
        "deleteditems" {
            $lines += "[L] List  [R #] Read  [RESTORE #/#-#]  [PURGE #/#-#]"
        }
        "junkemail" {
            $lines += "[L] List  [R #] Read  [INBOX #/#-#]  [X #/#-#] Delete"
        }
    }

    $lines += "[I] Inbox  [F] Relevant  [O] Sonstige  [A] Alle  "
    $lines += "[D] Drafts  [S] Sent  [G] Deleted  [J] Junk"
    $lines += "[FILTER <text>] Filter messages  [CLEAR] Clear filter"
    $lines += "[CONTACTS] Search contacts  [SMIME] S/MIME certs  [LOGOUT] Logout  [Q] Quit"
    $lines += ""
    $lines += "> "

    $count = 0
    foreach ($line in $lines) {
        $count += Get-ConsoleWrappedLineCount -Line $line -Width $Width
    }
    return $count
}

function Get-MorePromptLineCount {
    param(
        [int]$RemainingScreenLines,
        [int]$Width
    )

    $promptLine = "-- More (~$RemainingScreenLines screen lines remaining) --" +
        "  [SPACE] Next  [Q] Quit"
    return 1 + (Get-ConsoleWrappedLineCount -Line $promptLine -Width $Width)
}

function Get-ConsoleRowsWrittenSince {
    <#
    .SYNOPSIS
    Return how many console rows were written since a buffer Y position.
    #>
    param([int]$StartY)

    $currentY = $Host.UI.RawUI.CursorPosition.Y
    return [Math]::Max(0, $currentY - $StartY)
}

function Get-SmimeInfoLineCount {
    param(
        [Parameter(Mandatory)]
        [string]$Status,
        [hashtable]$Details,
        [int]$Width
    )

    $lines = @("")
    $isEncrypted = ($Details -and $Details.IsEncrypted) -or
        $Status -eq $Config.SmimeStatus.Encrypted

    if ($isEncrypted) {
        $lines += "Encryption: Encrypted [S/MIME]"
        if ($Status -eq $Config.SmimeStatus.Encrypted -and $Details -and $Details.Error) {
            $lines += "Decrypt:     $($Details.Error)"
        }
        if ($Status -ne $Config.SmimeStatus.Encrypted) {
            $lines += ""
        }
    }

    switch ($Status) {
        "SignedTrusted" {
            $lines += "Signature: Trusted [S/MIME]"
            if ($Details) {
                if ($Details.Subject) { $lines += "Signer:      $($Details.Subject)" }
                if ($Details.Issuer) { $lines += "Issued by:   $($Details.Issuer)" }
                if ($Details.ValidUntil) { $lines += "Valid until: $($Details.ValidUntil)" }
            }
        }
        "SignedUntrusted" {
            $lines += "Signature: Untrusted [S/MIME]"
            if ($Details) {
                if ($Details.Subject) { $lines += "Signer:      $($Details.Subject)" }
                $reason = if ($Details.Error) { $Details.Error } `
                    else { "Certificate chain not trusted" }
                $lines += "Reason:      $reason"
            }
        }
        "SignedInvalid" {
            $lines += "Signature: INVALID [S/MIME]"
            if ($Details -and $Details.Error) {
                $lines += "Reason:      $($Details.Error)"
            }
        }
        "Encrypted" {
            if (-not $isEncrypted) {
                $lines += "Encryption: Encrypted [S/MIME]"
            }
            if ($Details -and $Details.Error) {
                $lines += "Decrypt:     $($Details.Error)"
            }
        }
    }

    $count = 0
    foreach ($line in $lines) {
        $count += Get-ConsoleWrappedLineCount -Line $line -Width $Width
    }
    return $count
}

function Get-OpenMessageHeaderLineCount {
    <#
    .SYNOPSIS
    Calculate the rows written before the read body starts.
    #>
    param(
        [Parameter(Mandatory)]
        $Message,
        [string]$SmimeStatus,
        [hashtable]$SmimeDetails,
        [int]$UserAttachmentCount = 0,
        [bool]$VerificationLineShown = $false,
        [bool]$BodyPreviewLineShown = $false,
        [int]$Width
    )

    $lines = @(
        ("=" * 70),
        "Subject: $($Message.subject)",
        ("From:    {0} <{1}>" -f `
            $Message.from.emailAddress.name, `
            $Message.from.emailAddress.address)
    )

    if ($Message.toRecipients -and $Message.toRecipients.Count -gt 0) {
        $toList = $Message.toRecipients | ForEach-Object {
            if ($_.emailAddress.name) {
                "{0} <{1}>" -f $_.emailAddress.name, $_.emailAddress.address
            } else {
                $_.emailAddress.address
            }
        }
        $lines += "To:      $($toList -join ', ')"
    }

    $receivedDate = [datetime]$Message.receivedDateTime
    $lines += "Date:    $(Format-DateTime $receivedDate)"

    if ($VerificationLineShown) {
        $lines += "Verifying S/MIME..."
    }

    $count = 0
    foreach ($line in $lines) {
        $count += Get-ConsoleWrappedLineCount -Line $line -Width $Width
    }

    if ($SmimeStatus -and $SmimeStatus -ne $Config.SmimeStatus.None) {
        $count += Get-SmimeInfoLineCount `
            -Status $SmimeStatus -Details $SmimeDetails -Width $Width
    }

    if ($UserAttachmentCount -gt 0) {
        foreach ($line in @(
                "",
                "Attachments: $UserAttachmentCount file(s)",
                "[SAVE #] Save attachment",
                "[SAVEALL] Save all attachments")) {
            $count += Get-ConsoleWrappedLineCount -Line $line -Width $Width
        }
    }

    $count += Get-ConsoleWrappedLineCount -Line ("=" * 70) -Width $Width
    $count += 1

    if ($BodyPreviewLineShown) {
        $count += Get-ConsoleWrappedLineCount `
            -Line "(S/MIME: showing text preview - full body not extractable)" `
            -Width $Width
    }

    return $count
}

function Get-ReadViewTargetRowsFromHeaderStart {
    param([int]$ConsoleHeight)

    if ($ConsoleHeight -le 0) { $ConsoleHeight = 25 }
    $topInset = Get-TerminalViewportTopInset
    return [Math]::Max(1, $ConsoleHeight - $topInset - 1)
}

function Show-PagedContent {
    <#
    .SYNOPSIS
    Display content with paging support, accounting for line wrapping
    #>
    param(
        [string]$Content,
        [int]$HeaderLinesUsed = 0,
        [int]$FooterLinesUsed = 0,
        [int]$PostContentLinesUsed = 0
    )
    
    # Get console dimensions
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    
    if ($consoleHeight -le 0) { $consoleHeight = 25 }
    if ($consoleWidth -le 0) { $consoleWidth = 80 }
    
    # Split content into logical lines. Keep each line intact when writing it:
    # Warp and other terminals only keep long URLs clickable when they perform
    # the visual wrap themselves, without hard newlines inserted into the URL.
    $contentText = if ($null -eq $Content) { "" } else { $Content }
    $contentText = $contentText -replace "`r`n", "`n" -replace "`r", "`n"
    $logicalLines = $contentText -split "`n"
    
    # Keep the full visible text intact. Let the terminal perform visual wraps
    # so URL text remains inspectable and terminal URL detection still has the
    # original contiguous link text.
    $screenLineInfo = @()
    foreach ($line in $logicalLines) {
        $screenLineInfo += @{
            Line        = $line
            ScreenLines = Get-ConsoleWrappedLineCount `
                -Line $line -Width $consoleWidth
        }
    }
    
    # Calculate total screen lines
    $totalScreenLines = ($screenLineInfo | Measure-Object -Property ScreenLines -Sum).Sum
    
    # For each page, calculate exact body lines to display.
    #
    # HeaderLinesUsed is measured after the header was actually written, so
    # wrapped Subject/From/S/MIME/attachment lines are accounted for without
    # relying on stale fixed estimates.
    
    # Paging mode
    $currentLogicalLine = 0
    $totalLogicalLines = $screenLineInfo.Count
    $isFirstPage = $true
    
    while ($currentLogicalLine -lt $totalLogicalLines) {
        # Re-query console height for each page in case window size changed
        if (-not $isFirstPage) {
            $consoleHeight = $Host.UI.RawUI.WindowSize.Height
            if ($consoleHeight -le 0) { $consoleHeight = 25 }
            $consoleWidth = $Host.UI.RawUI.WindowSize.Width
            if ($consoleWidth -le 0) { $consoleWidth = 80 }
        }
        
        $remainingBeforePage = 0
        for ($i = $currentLogicalLine; $i -lt $totalLogicalLines; $i++) {
            $remainingBeforePage += $screenLineInfo[$i].ScreenLines
        }

        # To keep the first header row at the top of the viewport after the
        # prompt is printed, the cursor must end on start row + Height - 1.
        # Filling all Height rows would scroll the header row out of view.
        $targetRowsFromHeaderStart = Get-ReadViewTargetRowsFromHeaderStart `
            -ConsoleHeight $consoleHeight
        $preBodyLines = $isFirstPage ? $HeaderLinesUsed : 0
        $finalReservedLines = $FooterLinesUsed + $PostContentLinesUsed
        $finalPageLinesAvailable = $targetRowsFromHeaderStart - $preBodyLines - $finalReservedLines
        if ($finalPageLinesAvailable -lt 0) { $finalPageLinesAvailable = 0 }
        $morePromptLines = Get-MorePromptLineCount `
            -RemainingScreenLines $remainingBeforePage `
            -Width $consoleWidth

        $reservedAfterBody = $finalReservedLines
        $pageLinesAvailable = $finalPageLinesAvailable
        if ($remainingBeforePage -gt $finalPageLinesAvailable) {
            $reservedAfterBody = $morePromptLines
            $pageLinesAvailable = $targetRowsFromHeaderStart - $preBodyLines - $reservedAfterBody
            if ($pageLinesAvailable -lt 0) { $pageLinesAvailable = 0 }
        }
        Add-ReadLayoutDebugPoint `
            -Name ("page-plan-{0}" -f ($isFirstPage ? "first" : "next")) `
            -Extra @{
                CurrentLine = $currentLogicalLine
                RemainingRows = $remainingBeforePage
                PreBodyRows = $preBodyLines
                FinalReservedRows = $finalReservedLines
                PostContentRows = $PostContentLinesUsed
                FinalPageRowsAvailable = $finalPageLinesAvailable
                MorePromptRows = $morePromptLines
                ReservedAfterBody = $reservedAfterBody
                PageRowsAvailable = $pageLinesAvailable
                TargetRows = $targetRowsFromHeaderStart
            }
        
        # Determine how many physical rows fit in the current page.
        $screenLinesUsed = 0
        $endLogicalLine = $currentLogicalLine
        
        while ($endLogicalLine -lt $totalLogicalLines) {
            $linesNeeded = $screenLineInfo[$endLogicalLine].ScreenLines
            
            if ($screenLinesUsed + $linesNeeded -le $pageLinesAvailable) {
                $screenLinesUsed += $linesNeeded
                $endLogicalLine++
            } else {
                break
            }
        }
        
        # Always make progress when there is at least one body row available.
        if ($endLogicalLine -eq $currentLogicalLine -and $pageLinesAvailable -gt 0) {
            $endLogicalLine = $currentLogicalLine + 1
            $screenLinesUsed = $screenLineInfo[$currentLogicalLine].ScreenLines
        }

        # If the optimistic More-prompt reservation would consume the rest of
        # the body, the page is actually the final page and must reserve the
        # larger reply/menu/prompt block instead. Re-select body lines with the
        # final-page budget so the header remains at the top of the viewport.
        if ($endLogicalLine -ge $totalLogicalLines -and
            $reservedAfterBody -ne $finalReservedLines) {
            $reservedAfterBody = $finalReservedLines
            $pageLinesAvailable = $finalPageLinesAvailable
            $screenLinesUsed = 0
            $endLogicalLine = $currentLogicalLine

            while ($endLogicalLine -lt $totalLogicalLines) {
                $linesNeeded = $screenLineInfo[$endLogicalLine].ScreenLines
                if ($screenLinesUsed + $linesNeeded -le $pageLinesAvailable) {
                    $screenLinesUsed += $linesNeeded
                    $endLogicalLine++
                } else {
                    break
                }
            }

            if ($endLogicalLine -eq $currentLogicalLine -and $pageLinesAvailable -gt 0) {
                $endLogicalLine = $currentLogicalLine + 1
                $screenLinesUsed = $screenLineInfo[$currentLogicalLine].ScreenLines
            }
        }
        Add-ReadLayoutDebugPoint `
            -Name ("page-selected-{0}" -f ($isFirstPage ? "first" : "next")) `
            -Extra @{
                EndLine = $endLogicalLine
                BodyRowsSelected = $screenLinesUsed
                LinesSelected = $endLogicalLine - $currentLogicalLine
                ReservedAfterSelection = $reservedAfterBody
            }
        
        # Display lines for this page
        for ($i = $currentLogicalLine; $i -lt $endLogicalLine; $i++) {
            Write-Host $screenLineInfo[$i].Line
        }

        $blankLinesToFill = $pageLinesAvailable - $screenLinesUsed
        for ($i = 0; $i -lt $blankLinesToFill; $i++) {
            Write-Host ""
        }
        
        # Check if more content available
        if ($endLogicalLine -lt $totalLogicalLines) {
            # Calculate remaining screen lines
            $remainingScreenLines = 0
            for ($i = $endLogicalLine; $i -lt $totalLogicalLines; $i++) {
                $remainingScreenLines += $screenLineInfo[$i].ScreenLines
            }
            
            Write-Host ""
            Write-Host "-- More (~$remainingScreenLines screen lines remaining) --" `
                -ForegroundColor Cyan -NoNewline
            Write-Host "  [SPACE] Next  [Q] Quit" `
                -ForegroundColor DarkGray -NoNewline
            
            # Wait for key press
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            
            # Clear the prompt line
            Write-Host "`r" -NoNewline
            Write-Host (" " * ([Math]::Max(1, $consoleWidth - 1))) -NoNewline
            Write-Host "`r" -NoNewline
            
            # Handle key
            if ($key.Character -eq 'q' -or $key.Character -eq 'Q') {
                Write-Host ""
                Write-Host "(Skipped remaining content)" `
                    -ForegroundColor DarkGray
                break
            } else {
                # Space or any other key - next page
                $currentLogicalLine = $endLogicalLine
                $isFirstPage = $false
            }
        } else {
            # Last page reached
            $currentLogicalLine = $endLogicalLine
        }
    }
}
