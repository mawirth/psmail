# drafts.ps1
# Draft lifecycle management

function Get-EncryptedDraftPlaceholderBody {
    return "[Encrypted draft stored locally on this computer]"
}

function Ensure-SmimeDraftAssetsRoot {
    if (-not (Test-Path $Config.SmimeDraftAssetsPath)) {
        New-Item -ItemType Directory -Path $Config.SmimeDraftAssetsPath -Force | Out-Null
    }
}

function Get-SmimeDraftAssetDirectory {
    param([Parameter(Mandatory)][string]$MessageId)

    Ensure-SmimeDraftAssetsRoot
    return (Join-Path $Config.SmimeDraftAssetsPath $MessageId)
}

function Remove-LocalEncryptedDraftAssets {
    param([Parameter(Mandatory)][string]$MessageId)

    if (-not $Config.SmimeDraftAssetsPath) { return }
    $assetDir = Join-Path $Config.SmimeDraftAssetsPath $MessageId
    if (Test-Path $assetDir) {
        Remove-Item -LiteralPath $assetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalEncryptedDraftData {
    param([Parameter(Mandatory)][string]$MessageId)

    if (-not $global:State.SmimeDrafts) { return $null }
    if (-not $global:State.SmimeDrafts.ContainsKey($MessageId)) { return $null }

    $entry = $global:State.SmimeDrafts[$MessageId]
    if (-not $entry.LocalOnly) { return $null }

    return @{
        Sign        = [bool]$entry.Sign
        Encrypt     = [bool]$entry.Encrypt
        LocalOnly   = [bool]$entry.LocalOnly
        To          = if ($entry.To) { "$($entry.To)" } else { "" }
        Subject     = if ($entry.Subject) { "$($entry.Subject)" } else { "" }
        Body        = if ($entry.Body) { "$($entry.Body)" } else { "" }
        Attachments = @($entry.Attachments)
    }
}

function Set-LocalEncryptedDraftData {
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [string]$To = "",
        [string]$Subject = "",
        [string]$Body = "",
        [array]$Attachments = @(),
        [bool]$Sign = $false,
        [bool]$Encrypt = $true
    )

    if (-not $global:State.SmimeDrafts) { $global:State.SmimeDrafts = @{} }

    $global:State.SmimeDrafts[$MessageId] = @{
        Sign        = $Sign
        Encrypt     = $Encrypt
        LocalOnly   = $true
        To          = $To
        Subject     = $Subject
        Body        = $Body
        Attachments = @($Attachments)
    }
    Save-SmimeDrafts
}

function Clear-LocalEncryptedDraftData {
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [bool]$Sign = $false,
        [bool]$Encrypt = $false
    )

    if (-not $global:State.SmimeDrafts) { $global:State.SmimeDrafts = @{} }
    $global:State.SmimeDrafts[$MessageId] = @{
        Sign = $Sign
        Encrypt = $Encrypt
    }
    Save-SmimeDrafts
}

function Update-EncryptedDraftPlaceholder {
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [string]$Subject = "",
        [array]$ToRecipients = @()
    )

    $updates = @{
        subject = $Subject
        body = @{
            contentType = "Text"
            content = (Get-EncryptedDraftPlaceholderBody)
        }
        toRecipients = $ToRecipients
    }

    $result = Update-Message -MessageId $MessageId -Properties $updates
    if (-not $result) { return $false }

    $attachments = Get-MessageAttachments -MessageId $MessageId
    foreach ($attachment in $attachments) {
        if (-not (Remove-Attachment -MessageId $MessageId -AttachmentId $attachment.id)) {
            return $false
        }
    }

    return $true
}

function Copy-ExistingDraftAttachmentsToLocal {
    param([Parameter(Mandatory)][string]$MessageId)

    $attachments = Get-MessageAttachments -MessageId $MessageId
    if (-not $attachments -or $attachments.Count -eq 0) {
        return @()
    }

    $assetDir = Get-SmimeDraftAssetDirectory -MessageId $MessageId
    if (-not (Test-Path $assetDir)) {
        New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
    }

    $localPaths = @()
    foreach ($attachment in $attachments) {
        if ($attachment.isInline) { continue }

        $fullAttachment = Get-Attachment -MessageId $MessageId -AttachmentId $attachment.id
        if (-not $fullAttachment -or -not $fullAttachment.contentBytes) {
            Write-Error-Message "Failed to copy attachment locally: $($attachment.name)"
            return $null
        }

        $targetPath = Join-Path $assetDir $attachment.name
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($attachment.name)
        $extension = [System.IO.Path]::GetExtension($attachment.name)
        $suffix = 1
        while (Test-Path $targetPath) {
            $targetPath = Join-Path $assetDir ("{0}_{1}{2}" -f $baseName, $suffix, $extension)
            $suffix++
        }

        [System.IO.File]::WriteAllBytes(
            $targetPath,
            [Convert]::FromBase64String($fullAttachment.contentBytes)
        )
        $localPaths += $targetPath
    }

    return @($localPaths)
}

function Save-EncryptedDraftLocally {
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [Parameter(Mandatory)][hashtable]$ParsedDraft,
        [array]$ResolvedAttachments = @(),
        [array]$ExistingLocalAttachments = @()
    )

    $toRecipients = ConvertTo-RecipientArray $ParsedDraft.To
    if (-not (Update-EncryptedDraftPlaceholder `
        -MessageId $MessageId `
        -Subject $ParsedDraft.Subject `
        -ToRecipients $toRecipients)) {
        return $false
    }

    $attachmentPaths = @($ExistingLocalAttachments + $ResolvedAttachments)
    Set-LocalEncryptedDraftData `
        -MessageId $MessageId `
        -To $ParsedDraft.To `
        -Subject $ParsedDraft.Subject `
        -Body $ParsedDraft.Body `
        -Attachments $attachmentPaths `
        -Sign $ParsedDraft.Sign `
        -Encrypt $ParsedDraft.Encrypt

    return $true
}

function Cleanup-StaleEncryptedDraftData {
    <#
    .SYNOPSIS
    Remove local encrypted-draft payloads whose backing online draft no longer exists.
    #>
    param([array]$CurrentDraftIds = @())

    if (-not $global:State.SmimeDrafts) {
        return 0
    }

    $removedCount = 0
    $localOnlyIds = @(
        $global:State.SmimeDrafts.Keys | Where-Object {
            $entry = $global:State.SmimeDrafts[$_]
            $entry -and $entry.LocalOnly
        }
    )

    foreach ($messageId in $localOnlyIds) {
        if ($CurrentDraftIds -contains $messageId) {
            continue
        }

        $draft = Get-Message -MessageId $messageId
        if ($draft) {
            continue
        }

        Remove-DraftSmimeFlag -MessageId $messageId
        $removedCount++
    }

    return $removedCount
}

function Invoke-NewDraft {
    <#
    .SYNOPSIS
    Create a new draft message
    #>
    
    # Create template
    $separator = $Config.EmailTemplates.HeaderSeparator
    $template = @"
To: 
Subject: 
Attachments: 
Sign: no
Encrypt: no

$separator
"@
    
    # Open editor
    $result = Edit-DraftInEditor -Content $template
    
    if (-not $result.Changed) {
        Write-Info "Draft creation cancelled"
        return
    }
    
    # Parse draft
    $parsed = Parse-DraftContent $result.Content
    
    if (-not $parsed) {
        Write-Error-Message "Invalid draft format"
        return
    }
    
    # Validate and resolve attachments
    $resolvedAttachments = @()
    if ($parsed.Attachments -and $parsed.Attachments.Count -gt 0) {
        $validationResult = Test-AttachmentPaths $parsed.Attachments
        if (-not $validationResult.Valid) {
            $missingFiles = $validationResult.Missing -join ", "
            $errMsg = "Invalid attachment(s): {0}" -f $missingFiles
            Write-Error-Message $errMsg
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
        $footerResult  = Apply-DraftFooter $parsed.Body
        $contentType   = $footerResult.ContentType
        $body          = $footerResult.Body

        # Create draft via Graph
        $draft = New-DraftMessage `
            -Subject      $parsed.Subject `
            -Body         $body `
            -ToRecipients $toRecipients `
            -ContentType  $contentType
    }
    
    if (-not $draft) {
        Write-Error-Message "Failed to create draft"
        return
    }
    
    Write-Success "Draft created (ID: $($draft.id))"
    
    if ($parsed.Encrypt) {
        if (-not (Save-EncryptedDraftLocally `
            -MessageId $draft.id `
            -ParsedDraft $parsed `
            -ResolvedAttachments $resolvedAttachments)) {
            Remove-Message -MessageId $draft.id | Out-Null
            Write-Error-Message "Failed to prepare encrypted draft"
            return
        }
        Write-Info "Encrypted draft body is kept local; online draft is a placeholder"
    } else {
        # Store S/MIME flags in session state (persisted to disk by Set-DraftSmimeFlag)
        Set-DraftSmimeFlag `
            -MessageId $draft.id `
            -Sign      $parsed.Sign `
            -Encrypt   $parsed.Encrypt

        Invoke-UploadAttachments -MessageId $draft.id -FilePaths $resolvedAttachments
    }
}

function Invoke-EditDraft {
    <#
    .SYNOPSIS
    Edit an existing draft
    #>
    param([int]$Index)
    
    $item = Get-StateItem $Index
    
    if (-not $item) {
        Write-Error-Message "Invalid message number"
        return
    }
    
    # Fetch draft
    $draft = Get-Message -MessageId $item.Id
    
    if (-not $draft) {
        Write-Error-Message "Failed to load draft"
        return
    }
    
    # Build editable content
    $toList = ""
    if ($draft.toRecipients -and $draft.toRecipients.Count -gt 0) {
        $toList = ($draft.toRecipients | ForEach-Object { 
            $_.emailAddress.address 
        }) -join ", "
    }
    
    # Get current S/MIME flags for this draft
    $existingFlags = Get-DraftSmimeFlag -MessageId $item.Id
    $signVal       = if ($existingFlags.Sign)    { "yes" } else { "no" }
    $encryptVal    = if ($existingFlags.Encrypt) { "yes" } else { "no" }

    $localEncryptedDraft = Get-LocalEncryptedDraftData -MessageId $item.Id
    $attachmentList = ""
    $bodyContent = ""
    $subjectLine = $draft.subject
    $toListForEdit = $toList
    $existingAttachments = @()

    if ($localEncryptedDraft) {
        $bodyContent = $localEncryptedDraft.Body
        $subjectLine = $localEncryptedDraft.Subject
        $toListForEdit = $localEncryptedDraft.To
        if ($localEncryptedDraft.Attachments.Count -gt 0) {
            $attachmentList = $localEncryptedDraft.Attachments -join ", "
        }
    } else {
        # Get existing attachments
        $existingAttachments = Get-MessageAttachments `
            -MessageId $item.Id
        if ($existingAttachments `
            -and $existingAttachments.Count -gt 0) {
            $prefix = $Config.EmailTemplates.ExistingAttachmentPrefix
            $suffix = $Config.EmailTemplates.ExistingAttachmentSuffix
            $attachmentList = ($existingAttachments | ForEach-Object { 
                "$prefix$($_.name)$suffix" 
            }) -join ", "
        }

        # Get body content and convert HTML to text if needed
        $bodyContent = $draft.body.content
        if ($draft.body.contentType -eq "HTML") {
            $bodyContent = Convert-HtmlToText $bodyContent
        }
    }
    
    $separator = $Config.EmailTemplates.HeaderSeparator
    $content = @"
To: $toListForEdit
Subject: $subjectLine
Attachments: $attachmentList
Sign: $signVal
Encrypt: $encryptVal

$separator
$bodyContent
"@
    
    # Open editor
    $result = Edit-DraftInEditor -Content $content
    
    if (-not $result.Changed) {
        Write-Info "Draft not modified"
        return
    }
    
    # Parse updated content
    $parsed = Parse-DraftContent $result.Content
    
    if (-not $parsed) {
        Write-Error-Message "Invalid draft format"
        return
    }
    
    # Validate and resolve new attachments
    $resolvedAttachments = @()
    if ($parsed.Attachments -and $parsed.Attachments.Count -gt 0) {
        $validationResult = Test-AttachmentPaths $parsed.Attachments
        if (-not $validationResult.Valid) {
            $missingFiles = $validationResult.Missing -join ", "
            $errMsg = "Invalid attachment(s): {0}" -f $missingFiles
            Write-Error-Message $errMsg
            return
        }
        $resolvedAttachments = $validationResult.Resolved
    }
    
    $toRecipients = ConvertTo-RecipientArray $parsed.To

    if ($parsed.Encrypt) {
        $migratedAttachments = @()
        if (-not $localEncryptedDraft -and $existingAttachments.Count -gt 0) {
            $migratedAttachments = Copy-ExistingDraftAttachmentsToLocal -MessageId $item.Id
            if ($null -eq $migratedAttachments) {
                Write-Error-Message "Failed to move existing attachments into local encrypted draft storage"
                return
            }
        }
        if (-not (Save-EncryptedDraftLocally `
            -MessageId $item.Id `
            -ParsedDraft $parsed `
            -ResolvedAttachments $resolvedAttachments `
            -ExistingLocalAttachments $migratedAttachments)) {
            Write-Error-Message "Failed to update encrypted draft"
            return
        }
        Write-Success "Draft updated"
        Write-Info "Encrypted draft body is kept local; online draft is a placeholder"
        return
    } else {
        # Determine if original draft was HTML
        $wasHtml = ($draft.body.contentType -eq "HTML")
        $contentType = "Text"
        $body = $parsed.Body

        if ($localEncryptedDraft) {
            $footerResult = Apply-DraftFooter $parsed.Body
            $contentType = $footerResult.ContentType
            $body = $footerResult.Body
        } elseif ($wasHtml) {
            # If original was HTML, convert edited text back to HTML
            $contentType = "HTML"
            $body = Convert-TextToHtml $body

            # Re-append footer if it exists
            $footer = Get-Footer
            if ($footer -and $footer.Type -eq "HTML") {
                $body += "`n" + $footer.Content
            }
        }

        # Update draft
        $updates = @{
            subject = $parsed.Subject
            body = @{
                contentType = $contentType
                content = $body
            }
            toRecipients = $toRecipients
        }

        $result = Update-Message `
            -MessageId $item.Id `
            -Properties $updates

        if (-not $result) {
            Write-Error-Message "Failed to update draft"
            return
        }

        Write-Success "Draft updated"

        # Update S/MIME flags (persisted to disk by Set-DraftSmimeFlag)
        Clear-LocalEncryptedDraftData `
            -MessageId $item.Id `
            -Sign      $parsed.Sign `
            -Encrypt   $parsed.Encrypt

        Invoke-UploadAttachments -MessageId $item.Id -FilePaths $resolvedAttachments
        if ($localEncryptedDraft) {
            Remove-LocalEncryptedDraftAssets -MessageId $item.Id
        }
    }
}

function Invoke-SendDraft {
    <#
    .SYNOPSIS
    Send a draft message
    #>
    param([int]$Index)
    
    $item = Get-StateItem $Index
    
    if (-not $item) {
        Write-Error-Message "Invalid message number"
        return
    }

    $draft = Get-Message `
        -MessageId $item.Id `
        -Select "subject,toRecipients,ccRecipients,bccRecipients"
    if (-not $draft) {
        Write-Error-Message "Failed to load draft details"
        return
    }
    
    # Validate attachments before sending
    $attachments = Get-MessageAttachments -MessageId $item.Id
    if ($attachments -and $attachments.Count -gt 0) {
        Write-Info "Message has $($attachments.Count) attachment(s)"
    }
    
    # Check S/MIME flags
    $smimeFlags = Get-DraftSmimeFlag -MessageId $item.Id
    $smimeLabel = ""
    if ($smimeFlags.Sign -or $smimeFlags.Encrypt) {
        $modes = @()
        if ($smimeFlags.Sign)    { $modes += "Sign" }
        if ($smimeFlags.Encrypt) { $modes += "Encrypt" }
        $smimeLabel = " [S/MIME: $($modes -join '+')]"
    }
    
    # Confirm
    $fromAddress = $Config.CurrentAccount?.Email ?? (Get-CurrentUserEmail)
    $toAddresses = @(
        @($draft.toRecipients) |
            ForEach-Object { $_.emailAddress.address } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $ccAddresses = @(
        @($draft.ccRecipients) |
            ForEach-Object { $_.emailAddress.address } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $bccAddresses = @(
        @($draft.bccRecipients) |
            ForEach-Object { $_.emailAddress.address } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $recipientParts = @()
    if ($toAddresses.Count -gt 0) {
        $recipientParts += "To: $($toAddresses -join ', ')"
    }
    if ($ccAddresses.Count -gt 0) {
        $recipientParts += "Cc: $($ccAddresses -join ', ')"
    }
    if ($bccAddresses.Count -gt 0) {
        $recipientParts += "Bcc: $($bccAddresses -join ', ')"
    }
    $recipientSummary = $recipientParts.Count -gt 0 `
        ? ($recipientParts -join " | ") `
        : "(no recipients)"
    $confirmMessage = "Send this message from $fromAddress to $recipientSummary?$smimeLabel"

    if (-not (Confirm-Action $confirmMessage)) {
        Write-Info "Send cancelled"
        return
    }
    
    # Apply S/MIME if requested
    if ($smimeFlags.Sign -or $smimeFlags.Encrypt) {
        $smimeOk = Protect-MessageSmime `
            -MessageId $item.Id `
            -Sign      $smimeFlags.Sign `
            -Encrypt   $smimeFlags.Encrypt
        
        if (-not $smimeOk) {
            Write-Error-Message "S/MIME failed - message not sent."
            return
        }
        # Protect-MessageSmime sends directly and deletes the draft;
        # skip the normal Send-GraphMessage step.
        Remove-DraftSmimeFlag -MessageId $item.Id
        Write-Success "Message sent"
        Invoke-ListMessages
        return
    }
    
    # Non-S/MIME: send via Graph draft endpoint
    $result = Send-GraphMessage -MessageId $item.Id
    
    if ($null -ne $result) {
        Remove-DraftSmimeFlag -MessageId $item.Id
        Write-Success "Message sent"
        # Refresh list
        Invoke-ListMessages
    } else {
        Write-Error-Message "Failed to send message"
    }
}

function Parse-DraftContent {
    <#
    .SYNOPSIS
    Parse draft text into components
    #>
    param([string]$Content)
    
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }
    
    # Split into header and body at separator
    $separator = $Config.EmailTemplates.HeaderSeparator
    $separatorIndex = $Content.IndexOf("`n$separator")
    
    if ($separatorIndex -eq -1) {
        return $null
    }
    
    $headerPart = $Content.Substring(0, $separatorIndex)
    # Skip past '\n' (1) + separator length to reach the body
    $bodyPart = $Content.Substring(
        $separatorIndex + 1 + $separator.Length).Trim()
    
    # Parse headers
    $to          = ""
    $subject     = ""
    $attachments = @()
    $signStr     = "no"
    $encryptStr  = "no"
    
    foreach ($line in $headerPart -split "`n") {
        if ($line -match '^To:\s*(.*)$') {
            $to = $matches[1].Trim()
        } elseif ($line -match '^Subject:\s*(.*)$') {
            $subject = $matches[1].Trim()
        } elseif ($line -match '^Sign:\s*(.*)$') {
            $signStr = $matches[1].Trim()
        } elseif ($line -match '^Encrypt:\s*(.*)$') {
            $encryptStr = $matches[1].Trim()
        } elseif ($line -match '^Attachments:\s*(.*)$') {
            $attLine = $matches[1].Trim()
            # Parse attachment paths (comma or semicolon separated)
            # Skip [existing:...] markers
            if (-not [string]::IsNullOrWhiteSpace($attLine)) {
                $existingPrefix = [regex]::Escape(
                    $Config.EmailTemplates.ExistingAttachmentPrefix)
                
                $paths = $attLine -split '[,;]' | ForEach-Object {
                    $_.Trim()
                } | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) `
                        -and $_ -notmatch "^$existingPrefix"
                }
                $attachments = @($paths)
            }
        }
    }
    
    $sign    = ($signStr.ToLower()    -eq "yes" -or $signStr.ToLower()    -eq "true")
    $encrypt = ($encryptStr.ToLower() -eq "yes" -or $encryptStr.ToLower() -eq "true")
    
    return @{
        To          = $to
        Subject     = $subject
        Body        = $bodyPart
        Attachments = $attachments
        Sign        = $sign
        Encrypt     = $encrypt
    }
}

function Apply-DraftFooter {
    <#
    .SYNOPSIS
    Apply the email footer to a plain-text body for new drafts, replies
    and forwards. Returns @{ ContentType = ...; Body = ... }.
    When an HTML footer exists, the body is converted to HTML first.
    #>
    param([string]$BodyText)
    
    $footer = Get-Footer
    
    if ($footer -and $footer.Type -eq "HTML") {
        return @{
            ContentType = "HTML"
            Body        = (Convert-TextToHtml $BodyText) + "`n" + $footer.Content
        }
    }
    if ($footer) {
        return @{
            ContentType = "Text"
            Body        = $BodyText + "`n`n" + $footer.Content
        }
    }
    return @{ ContentType = "Text"; Body = $BodyText }
}

function Convert-TextToHtmlFragment {
    <#
    .SYNOPSIS
    Convert plain text to an HTML fragment while preserving line breaks.
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $normalized = $Text -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"

    $html = [System.Net.WebUtility]::HtmlEncode($normalized)
    $html = $html -replace "`n", "<br>`n"

    return $html
}

function Apply-DraftFooterBeforeQuotedSection {
    <#
    .SYNOPSIS
    Apply the footer only to the new top section of a reply/forward body and
    keep the quoted/forwarded original content below it.
    #>
    param(
        [string]$BodyText,
        [Parameter(Mandatory)][string]$QuotedSectionHeader
    )

    if ([string]::IsNullOrWhiteSpace($BodyText)) {
        return Apply-DraftFooter $BodyText
    }

    $markerIndex = $BodyText.IndexOf($QuotedSectionHeader)
    if ($markerIndex -lt 0) {
        return Apply-DraftFooter $BodyText
    }

    $introBody = $BodyText.Substring(0, $markerIndex).TrimEnd()
    $quotedBody = $BodyText.Substring($markerIndex).TrimStart()

    $footerResult = Apply-DraftFooter $introBody
    $combinedBody = if ([string]::IsNullOrWhiteSpace($footerResult.Body)) {
        if ($footerResult.ContentType -eq "HTML") {
            "<div style=`"margin-top: 18px;`">$(Convert-TextToHtmlFragment $quotedBody)</div>"
        } else {
            $quotedBody
        }
    } else {
        if ($footerResult.ContentType -eq "HTML") {
            $footerResult.Body + "`n" +
                "<div style=`"margin-top: 18px;`">$(Convert-TextToHtmlFragment $quotedBody)</div>"
        } else {
            $footerResult.Body + "`n`n" + $quotedBody
        }
    }

    return @{
        ContentType = $footerResult.ContentType
        Body        = $combinedBody
    }
}

function Invoke-UploadAttachments {
    <#
    .SYNOPSIS
    Upload a list of local file paths as attachments to a draft message.
    Does nothing when the list is empty.
    #>
    param(
        [Parameter(Mandatory)][string]$MessageId,
        [array]$FilePaths = @()
    )
    
    if (-not $FilePaths -or $FilePaths.Count -eq 0) { return }
    
    Write-Host "Uploading $($FilePaths.Count) attachment(s)..." `
        -ForegroundColor $Config.Colors.LoadingMore
    
    $uploaded = 0
    foreach ($path in $FilePaths) {
        if (Add-AttachmentToDraft -MessageId $MessageId -FilePath $path) {
            Write-Host "  $([System.IO.Path]::GetFileName($path))" `
                -ForegroundColor $Config.Colors.Success
            $uploaded++
        } else {
            Write-Error-Message "Failed to upload: $path"
        }
    }
    Write-Success "Uploaded $uploaded of $($FilePaths.Count) attachments"
}

function Get-Footer {
    <#
    .SYNOPSIS
    Load footer (HTML or Text) from file
    Returns hashtable with Type and Content
    #>
    
    # Check for HTML footer first
    if (Test-Path $Config.HtmlFooterPath) {
        try {
            $content = Get-Content -Path $Config.HtmlFooterPath -Raw -ErrorAction Stop
            return @{
                Type = "HTML"
                Content = $content
            }
        } catch {
            Write-Host "Warning: Could not read HTML footer" -ForegroundColor $Config.Colors.Warning
        }
    }
    
    # Fallback to text footer
    if (Test-Path $Config.FooterPath) {
        try {
            $content = Get-Content -Path $Config.FooterPath -Raw -ErrorAction Stop
            return @{
                Type = "Text"
                Content = $content
            }
        } catch {
            return $null
        }
    }
    
    return $null
}

function Convert-TextToHtml {
    <#
    .SYNOPSIS
    Convert plain text to HTML with configured font styling
    #>
    param([string]$Text)
    
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "<p></p>"
    }

    $normalized = $Text -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    $normalized = $normalized.Trim()

    # Collapse oversized blank areas to a single paragraph break.
    $normalized = $normalized -replace "`n{3,}", "`n`n"

    $paragraphs = @()
    foreach ($paragraph in ($normalized -split "`n`n")) {
        $encodedParagraph = [System.Net.WebUtility]::HtmlEncode($paragraph)
        $encodedParagraph = $encodedParagraph -replace "`n", "<br>`n"
        $paragraphs += "<p style=`"margin: 0 0 0.85em 0;`">$encodedParagraph</p>"
    }

    if ($paragraphs.Count -gt 0) {
        $paragraphs[$paragraphs.Count - 1] = $paragraphs[$paragraphs.Count - 1] `
            -replace ' margin: 0 0 0\.85em 0;', ' margin: 0;'
    }

    $html = $paragraphs -join "`n"
    
    # Apply font styling from config
    $fontFamily = $Config.HtmlBodyStyle.FontFamily
    $fontSize = $Config.HtmlBodyStyle.FontSize
    $styleAttr = "font-family: $fontFamily; font-size: $fontSize;"
    
    # Wrap in div with font styling
    $html = "<div style=`"$styleAttr`">$html</div>"
    
    return $html
}

function Test-AttachmentPaths {
    <#
    .SYNOPSIS
    Validate that attachment file paths exist
    Returns resolved paths and validation result
    #>
    param([array]$Paths)
    
    $missing = @()
    $resolved = @()
    
    foreach ($path in $Paths) {
        $resolvedPath = Resolve-AttachmentPath $path
        
        if (-not (Test-Path -Path $resolvedPath -PathType Leaf)) {
            $missing += $path
        } else {
            $resolved += $resolvedPath
        }
    }
    
    return @{
        Valid = ($missing.Count -eq 0)
        Missing = $missing
        Resolved = $resolved
    }
}

function Resolve-AttachmentPath {
    <#
    .SYNOPSIS
    Resolve relative paths, ~ expansion, and convert to absolute
    #>
    param([string]$Path)
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    
    # Expand ~ to home directory
    if ($Path.StartsWith("~")) {
        $Path = $Path -replace '^~', $HOME
    }
    
    # Convert forward slashes to backslashes on Windows
    $Path = $Path -replace '/', '\\'
    
    # If relative path, resolve against current location
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    
    # Normalize the path
    try {
        $Path = [System.IO.Path]::GetFullPath($Path)
    } catch {
        # If path is invalid, return as-is
    }
    
    return $Path
}

function Invoke-RedraftMessage {
    <#
    .SYNOPSIS
    Copy a sent message to drafts for resending
    #>
    param([int]$Index)
    
    $item = Get-StateItem $Index
    
    if (-not $item) {
        Write-Error-Message "Invalid message number"
        return
    }
    
    # Fetch original message with all fields
    $selectFields = "subject,body,toRecipients,ccRecipients," +
        "bccRecipients,hasAttachments"
    $original = Get-Message -MessageId $item.Id -Select $selectFields
    
    if (-not $original) {
        Write-Error-Message "Failed to load sent message"
        return
    }
    
    # Prepare subject with Fwd: prefix
    $fwdPrefix = $Config.EmailTemplates.ForwardPrefix
    $subject = $original.subject
    if (-not $subject.StartsWith($fwdPrefix)) {
        $subject = $fwdPrefix + $subject
    }
    
    # Get body content
    $body = ""
    if ($original.body -and $original.body.content) {
        $body = $original.body.content
    }
    
    # Determine content type from original
    $contentType = "Text"
    if ($original.body -and $original.body.contentType -eq "HTML") {
        $contentType = "HTML"
    }
    
    # Build recipients arrays
    $toRecipients = @()
    if ($original.toRecipients) {
        $toRecipients = $original.toRecipients
    }
    
    $ccRecipients = @()
    if ($original.ccRecipients) {
        $ccRecipients = $original.ccRecipients
    }
    
    $bccRecipients = @()
    if ($original.bccRecipients) {
        $bccRecipients = $original.bccRecipients
    }
    
    # Create new draft
    $draftBody = @{
        subject = $subject
        body = @{
            contentType = $contentType
            content = $body
        }
        toRecipients = $toRecipients
    }
    
    # Add CC and BCC if present
    if ($ccRecipients.Count -gt 0) {
        $draftBody.ccRecipients = $ccRecipients
    }
    if ($bccRecipients.Count -gt 0) {
        $draftBody.bccRecipients = $bccRecipients
    }
    
    $uri = "/v1.0/me/messages"
    $draft = Invoke-GraphRequest -Method POST -Uri $uri -Body $draftBody
    
    if (-not $draft) {
        Write-Error-Message "Failed to create draft"
        return
    }
    
    Write-Success "Draft created from sent message #$Index"
    
    # Copy attachments if present
    if ($original.hasAttachments) {
        $attachments = Get-MessageAttachments -MessageId $item.Id
        
        if ($attachments -and $attachments.Count -gt 0) {
            Write-Host "Copying $($attachments.Count) attachment(s)..." `
                -ForegroundColor $Config.Colors.LoadingMore
            
            $copiedCount = 0
            foreach ($att in $attachments) {
                # Skip inline attachments (e.g. embedded images)
                if ($att.isInline) {
                    continue
                }
                
                # Copy attachment to new draft
                if (Copy-AttachmentToDraft `
                    -SourceMessageId $item.Id `
                    -TargetMessageId $draft.id `
                    -Attachment $att) {
                    Write-Host "  $($att.name)" -ForegroundColor $Config.Colors.Success
                    $copiedCount++
                } else {
                    Write-Error-Message "Failed to copy: $($att.name)"
                }
            }
            
            Write-Success "Copied $copiedCount of $($attachments.Count) attachments"
        }
    }
}

function Copy-AttachmentToDraft {
    <#
    .SYNOPSIS
    Copy an attachment from one message to a draft
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourceMessageId,
        
        [Parameter(Mandatory)]
        [string]$TargetMessageId,
        
        [Parameter(Mandatory)]
        [object]$Attachment
    )
    
    try {
        # Fetch full attachment with content
        $fullAtt = Get-Attachment `
            -MessageId $SourceMessageId `
            -AttachmentId $Attachment.id
        
        if (-not $fullAtt -or -not $fullAtt.contentBytes) {
            return $false
        }
        
        # Create new attachment on target draft
        $uri = "/v1.0/me/messages/$TargetMessageId/attachments"
        $newAttachment = @{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            name = $fullAtt.name
            contentType = $fullAtt.contentType
            contentBytes = $fullAtt.contentBytes
        }
        
        $result = Invoke-GraphRequest `
            -Method POST `
            -Uri $uri `
            -Body $newAttachment
        
        return ($null -ne $result)
        
    } catch {
        Write-Error-Message "Copy failed: $($_.Exception.Message)"
        return $false
    }
}

function Add-AttachmentToDraft {
    <#
    .SYNOPSIS
    Upload an attachment to a draft message
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        return $false
    }
    
    try {
        # Read file as base64
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $base64 = [Convert]::ToBase64String($bytes)
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        
        # Determine content type
        $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()
        $contentType = switch ($extension) {
            ".jpg"  { "image/jpeg" }
            ".jpeg" { "image/jpeg" }
            ".png"  { "image/png" }
            ".gif"  { "image/gif" }
            ".pdf"  { "application/pdf" }
            ".txt"  { "text/plain" }
            ".zip"  { "application/zip" }
            ".docx" {
                $type = "application/"
                $type += "vnd.openxmlformats-officedocument."
                $type += "wordprocessingml.document"
                $type
            }
            ".xlsx" {
                $type = "application/"
                $type += "vnd.openxmlformats-officedocument."
                $type += "spreadsheetml.sheet"
                $type
            }
            default { "application/octet-stream" }
        }
        
        # Create attachment
        $uri = "/v1.0/me/messages/$MessageId/attachments"
        $attachment = @{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            name = $fileName
            contentType = $contentType
            contentBytes = $base64
        }
        
        $result = Invoke-GraphRequest -Method POST -Uri $uri -Body $attachment
        return ($null -ne $result)
        
    } catch {
        Write-Error-Message "Upload failed: $($_.Exception.Message)"
        return $false
    }
}
