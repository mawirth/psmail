# drafts.ps1
# Draft lifecycle management

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
    
    # Get footer and determine content type
    $footer = Get-Footer
    $contentType = "Text"
    $body = $parsed.Body
    
    if ($footer -and $footer.Type -eq "HTML") {
        # Convert text to HTML and append HTML footer
        $contentType = "HTML"
        $body = Convert-TextToHtml $body
        $body += "`n" + $footer.Content
    } elseif ($footer) {
        # Append text footer
        $body += "`n`n" + $footer.Content
    }
    
    # Create recipients array
    $toRecipients = @()
    if (-not [string]::IsNullOrWhiteSpace($parsed.To)) {
        $separators = $Config.AttachmentsConfig.RecipientSeparators -join ''
        $toAddresses = $parsed.To -split "[$separators]" | ForEach-Object { 
            $_.Trim() 
        }
        foreach ($addr in $toAddresses) {
            if (-not [string]::IsNullOrWhiteSpace($addr)) {
                $toRecipients += @{
                    emailAddress = @{
                        address = $addr
                    }
                }
            }
        }
    }
    
    # Create draft via Graph
    $draft = New-DraftMessage `
        -Subject $parsed.Subject `
        -Body $body `
        -ToRecipients $toRecipients `
        -ContentType $contentType
    
    if (-not $draft) {
        Write-Error-Message "Failed to create draft"
        return
    }
    
    Write-Success "Draft created (ID: $($draft.id))"
    
    # Add attachments if any
    if ($resolvedAttachments.Count -gt 0) {
        Write-Host "Uploading $($resolvedAttachments.Count) attachment(s)..." `
            -ForegroundColor Cyan
        
        $uploadedCount = 0
        foreach ($filePath in $resolvedAttachments) {
            if (Add-AttachmentToDraft -MessageId $draft.id `
                -FilePath $filePath) {
                $fileName = [System.IO.Path]::GetFileName($filePath)
                Write-Host "  $fileName" -ForegroundColor Green
                $uploadedCount++
            } else {
                Write-Error-Message "Failed to upload: $filePath"
            }
        }
        
        Write-Success "Uploaded $uploadedCount of $($resolvedAttachments.Count) attachments"
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
    
    # Get existing attachments
    $existingAttachments = Get-MessageAttachments `
        -MessageId $item.Id
    $attachmentList = ""
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
    
    $separator = $Config.EmailTemplates.HeaderSeparator
    $content = @"
To: $toList
Subject: $($draft.subject)
Attachments: $attachmentList

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
    
    # Build recipients
    $toRecipients = @()
    if (-not [string]::IsNullOrWhiteSpace($parsed.To)) {
        $separators = $Config.AttachmentsConfig.RecipientSeparators -join ''
        $toAddresses = $parsed.To -split "[$separators]" | ForEach-Object { 
            $_.Trim() 
        }
        foreach ($addr in $toAddresses) {
            if (-not [string]::IsNullOrWhiteSpace($addr)) {
                $toRecipients += @{
                    emailAddress = @{
                        address = $addr
                    }
                }
            }
        }
    }
    
    # Determine if original draft was HTML
    $wasHtml = ($draft.body.contentType -eq "HTML")
    $contentType = "Text"
    $body = $parsed.Body
    
    # If original was HTML, convert edited text back to HTML
    if ($wasHtml) {
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
    
    # Handle attachments if modified
    if ($resolvedAttachments.Count -gt 0) {
        Write-Host "Uploading $($resolvedAttachments.Count) attachment(s)..." `
            -ForegroundColor Cyan
        
        $uploadedCount = 0
        foreach ($filePath in $resolvedAttachments) {
            if (Add-AttachmentToDraft -MessageId $item.Id `
                -FilePath $filePath) {
                $fileName = [System.IO.Path]::GetFileName($filePath)
                Write-Host "  $fileName" -ForegroundColor Green
                $uploadedCount++
            } else {
                Write-Error-Message "Failed to upload: $filePath"
            }
        }
        
        Write-Success "Uploaded $uploadedCount of $($resolvedAttachments.Count) attachments"
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
    
    # Validate attachments before sending
    $attachments = Get-MessageAttachments -MessageId $item.Id
    if ($attachments -and $attachments.Count -gt 0) {
        Write-Info "Message has $($attachments.Count) attachment(s)"
    }
    
    # Confirm
    if (-not (Confirm-Action "Send this message?")) {
        Write-Info "Send cancelled"
        return
    }
    
    # Send
    $result = Send-GraphMessage -MessageId $item.Id
    
    if ($result -ne $null) {
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
    $bodyPart = $Content.Substring($separatorIndex + 4).Trim()
    
    # Parse headers
    $to = ""
    $subject = ""
    $attachments = @()
    
    foreach ($line in $headerPart -split "`n") {
        if ($line -match '^To:\s*(.*)$') {
            $to = $matches[1].Trim()
        } elseif ($line -match '^Subject:\s*(.*)$') {
            $subject = $matches[1].Trim()
        } elseif ($line -match '^Attachments:\s*(.*)$') {
            $attLine = $matches[1].Trim()
            # Parse attachment paths (comma or semicolon separated)
            # Skip [existing:...] markers
            if (-not [string]::IsNullOrWhiteSpace($attLine)) {
                $paths = $attLine -split '[,;]' | ForEach-Object {
                    $_.Trim()
                $existingPrefix = [regex]::Escape($Config.EmailTemplates.ExistingAttachmentPrefix)
                } | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) `
                        -and $_ -notmatch "^$existingPrefix"
                }
                $attachments = @($paths)
            }
        }
    }
    
    return @{
        To = $to
        Subject = $subject
        Body = $bodyPart
        Attachments = $attachments
    }
}

function Get-Footer {
    <#
    .SYNOPSIS
    Load footer (HTML or Text) from file
    Returns hashtable with Type and Content
    #>
    
    # Check for HTML footer first
    $htmlFooterPath = Join-Path (Split-Path $Config.FooterPath) "footer.html"
    if (Test-Path $htmlFooterPath) {
        try {
            $content = Get-Content -Path $htmlFooterPath -Raw -ErrorAction Stop
            return @{
                Type = "HTML"
                Content = $content
            }
        } catch {
            Write-Host "Warning: Could not read HTML footer" -ForegroundColor Yellow
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
    
    # Escape HTML special characters
    $html = [System.Net.WebUtility]::HtmlEncode($Text)
    
    # Convert double line breaks to paragraph breaks
    $html = $html -replace "(`r`n|`n){2,}", "</p>`n<p>"
    
    # Convert single line breaks to <br>
    $html = $html -replace "`r`n", "<br>`n"
    $html = $html -replace "`n", "<br>`n"
    
    # Wrap in paragraphs
    $html = "<p>$html</p>"
    
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
    $Path = $Path -replace '/', '\'
    
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
                -ForegroundColor Cyan
            
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
                    Write-Host "  $($att.name)" -ForegroundColor Green
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
