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
    
    # Fetch full message
    $msg = Get-Message -MessageId $item.Id
    
    if (-not $msg) {
        Write-Error-Message "Failed to load message"
        return
    }
    
    # Display header (let email content naturally push old menu off screen)
    Write-Host ""
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
    
    # S/MIME info
    if ($item.SmimeStatus -ne $Config.SmimeStatus.None) {
        Show-SmimeInfo -MessageId $item.Id -Status $item.SmimeStatus
    }
    
    # Attachments
    if ($msg.hasAttachments) {
        Write-Host ""
        Write-Host "Attachments: " -NoNewline -ForegroundColor $Config.Colors.FieldLabel
        $rawAttachments = Get-MessageAttachments -MessageId $item.Id
        
        # Check if it's a single attachment
        # (hashtable with @odata.type) or an array,
        # or a hashtable with 'value' key
        if ($rawAttachments -is [hashtable]) {
            if ($rawAttachments.ContainsKey('value')) {
                # Response with value array
                $attachments = $rawAttachments['value']
            } elseif ($rawAttachments.ContainsKey('@odata.type')) {
                # Single attachment returned directly
                $attachments = @($rawAttachments)
            } else {
                $attachments = $rawAttachments
            }
        } else {
            $attachments = $rawAttachments
        }
        
        # Ensure we have an array
        if ($attachments -isnot [System.Array]) {
            $attachments = @($attachments)
        }
        
        # Filter to file attachments only
        $fileAttachments = @($attachments | Where-Object {
            $type = if ($_ -is [hashtable]) {
                $_['@odata.type']
            } else {
                $_.'@odata.type'
            }
            $type -eq '#microsoft.graph.fileAttachment'
        })
        
        if ($fileAttachments) {
            Write-Host "$($fileAttachments.Count) file(s)"
            Write-Host "[SAVE #] Save attachment" `
                -ForegroundColor $Config.Colors.MenuAction
            Write-Host "[SAVEALL] Save all attachments" `
                -ForegroundColor $Config.Colors.MenuAction
        }
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
    
    # Calculate header lines used
    # (for accurate paging on first page)
    # Count: blank + top sep + Subject + From + To + Date + bottom sep + blank = 8 base lines
    $headerLines = 8
    if ($msg.toRecipients -and $msg.toRecipients.Count -gt 0) {
        $headerLines += 0  # To is already counted
    }
    if ($item.SmimeStatus -ne $Config.SmimeStatus.None) {
        $headerLines += 3  # S/MIME info adds ~3 lines
    }
    if ($msg.hasAttachments) {
        $headerLines += 4  # Attachments info adds ~4 lines
    }
    
    # Footer menu takes 4 lines:
    # blank + REPLY/REPLYALL + FORWARD + blank
    $footerLines = 4
    
    # Display body with paging
    Show-PagedContent `
        -Content $body `
        -HeaderLinesUsed $headerLines `
        -FooterLinesUsed $footerLines
    Write-Host ""
    
    # Show reply/forward options
    Write-Host "[REPLY] Reply to sender  [REPLYALL] Reply to all  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuAction
    Write-Host "[FORWARD] Forward" -ForegroundColor $Config.Colors.MenuAction
    Write-Host ""
    
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
        $ctx = Get-MgContext
        $myAddress = $ctx.Account.ToLower()
        
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
    
    # Build template
    $separator = $Config.EmailTemplates.HeaderSeparator
    $template = @"
To: $toList
Subject: $subject
Attachments: 

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
    
    # Create draft
    $draft = New-DraftMessage `
        -Subject $parsed.Subject `
        -Body $body `
        -ToRecipients $toRecipients `
        -ContentType $contentType
    
    if (-not $draft) {
        Write-Error-Message "Failed to create reply"
        return
    }
    
    Write-Success "Reply draft created (ID: $($draft.id))"
    
    # Upload attachments
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
            }
        }
        
        Write-Success "Uploaded $uploadedCount of $($resolvedAttachments.Count) attachments"
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
    
    # Create draft
    $draft = New-DraftMessage `
        -Subject $parsed.Subject `
        -Body $body `
        -ToRecipients $toRecipients `
        -ContentType $contentType
    
    if (-not $draft) {
        Write-Error-Message "Failed to create forward"
        return
    }
    
    Write-Success "Forward draft created (ID: $($draft.id))"
    
    # Upload attachments
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
            }
        }
        
        Write-Success "Uploaded $uploadedCount of $($resolvedAttachments.Count) attachments"
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
    
    $text = $Html
    
    # Step 1: Remove problematic elements entirely
    $text = $text -replace '(?si)<script[^>]*>.*?</script>', ''
    $text = $text -replace '(?si)<style[^>]*>.*?</style>', ''
    $text = $text -replace '(?si)<head[^>]*>.*?</head>', ''
    
    # Step 2: Remove table structure but keep content
    # Just strip the table/tr/td tags, keep everything inside
    $text = $text -replace '(?si)</?table[^>]*>', ''
    $text = $text -replace '(?si)</?tbody[^>]*>', ''
    $text = $text -replace '(?si)</?thead[^>]*>', ''
    $text = $text -replace '(?si)</?tfoot[^>]*>', ''
    $text = $text -replace '(?si)</?tr[^>]*>', ' '
    $text = $text -replace '(?si)</?t[dh][^>]*>', ' '
    
    # Step 3: Decode HTML entities for URL processing
    $text = $text -replace '&amp;', '&'
    $text = $text -replace '&quot;', '"'
    $text = $text -replace '&lt;', '<'
    $text = $text -replace '&gt;', '>'
    
    # Step 4: Extract links before removing tags
    # Convert <a href="URL">Label</a> to "Label <URL>"
    $linkPattern = '(?i)<a[^>]*href=["'']([^"'']+)["''][^>]*>([^<]+)</a>'
    $linkMatches = [regex]::Matches($text, $linkPattern)
    foreach ($match in $linkMatches) {
        $url = $match.Groups[1].Value
        $label = $match.Groups[2].Value
        $unwrappedUrl = Unwrap-SafeLink $url
        # Use placeholder to protect angle brackets
        $replacement = "$label __LINK__$unwrappedUrl`__ENDLINK__"
        $text = $text.Replace($match.Value, $replacement)
    }
    
    # Step 5: Convert block elements to newlines
    # IMPORTANT: </div> becomes SPACE not newline!
    # Many HTML emails use <div> for layout (single chars in cells), not paragraphs.
    # Outlook uses <p> for real paragraphs, so </p> correctly creates newlines.
    $text = $text -replace '(?si)</(p|h[1-6]|li)>', "`n"
    $text = $text -replace '(?si)<br\s*/?>', "`n"
    $text = $text -replace '(?si)</div>', ' '
    
    # Step 6: Remove ALL remaining HTML tags
    $text = $text -replace '<[^>]+>', ''
    
    # Step 7: Decode HTML entities
    $text = $text -replace '&nbsp;', ' '
    $text = $text -replace '&lt;', '<'
    $text = $text -replace '&gt;', '>'
    $text = $text -replace '&amp;', '&'
    $text = $text -replace '&quot;', '"'
    $text = $text -replace '&#39;', "'"
    $text = $text -replace '&#(\d+);', { param($m) [char][int]$m.Groups[1].Value }
    $text = $text -replace '&#x([0-9a-fA-F]+);', { param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16) }
    
    # Step 8: Clean up whitespace
    $text = $text -replace '[ \t]+', ' '  # Multiple spaces/tabs to single space
    $text = $text -replace ' *\n *', "`n"  # Remove spaces around newlines
    $text = $text -replace '\n{3,}', "`n`n"  # Max 2 consecutive newlines
    
    # Step 9: Trim empty lines
    $lines = $text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $text = $lines -join "`n"
    
    # Step 10: Restore links with angle brackets
    $text = $text -replace '__LINK__', ' <'
    $text = $text -replace '__ENDLINK__', '>'
    
    # Step 11: Unwrap remaining SafeLinks in plain text
    $safelinkPattern = 'https?://[^\s<>]*safelinks\.protection\.outlook\.com[^\s<>]*'
    $text = [regex]::Replace($text, $safelinkPattern, { param($m) Unwrap-SafeLink $m.Value })
    
    return $text.Trim()
}

function Show-PagedContent {
    <#
    .SYNOPSIS
    Display content with paging support, accounting for line wrapping
    #>
    param(
        [string]$Content,
        [int]$HeaderLinesUsed = 0,
        [int]$FooterLinesUsed = 0
    )
    
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return
    }
    
    # Get console dimensions
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    
    if ($consoleHeight -le 0) { $consoleHeight = 25 }
    if ($consoleWidth -le 0) { $consoleWidth = 80 }
    
    # Available screen lines per page (for subsequent pages)
    # On subsequent pages, we fill entire screen with content + More prompt.
    # No header, no footer menu, no main menu visible.
    $availableLines = $consoleHeight - 3  # Just reserve space for More prompt
    
    # Split content into logical lines
    $logicalLines = $Content -split "`n"
    
    # Apply word-wrapping to each logical line and build screen line info
    $screenLineInfo = @()
    foreach ($line in $logicalLines) {
        if ([string]::IsNullOrEmpty($line)) {
            # Empty lines take 1 screen line
            $screenLineInfo += @{
                WrappedLines = @("")
                ScreenLines = 1
            }
        } else {
            # Apply word-wrapping at console width
            # IMPORTANT: @() ensures result is always an array, even for single lines.
            # Without it, a single string makes WrappedLines[0] return first CHARACTER.
            $wrapped = @(Format-WordWrap -Text $line -Width $consoleWidth)
            $screenLineInfo += @{
                WrappedLines = $wrapped
                ScreenLines = $wrapped.Count
            }
        }
    }
    
    # Calculate total screen lines
    $totalScreenLines = ($screenLineInfo | Measure-Object -Property ScreenLines -Sum).Sum
    
    # For first page: Calculate exact lines to display
    #
    # Output sequence in Invoke-OpenMessage:
    #   1. Email header ($HeaderLinesUsed lines)
    #   2. Email body (X screen lines - what we're calculating)
    #   3. Footer REPLY/FORWARD menu ($FooterLinesUsed lines)
    #
    # Note: Main menu is output AFTER this function returns, not during.
    # We want to fill the screen to push old content away while keeping header visible.
    #
    # Maximum before header scrolls off: Header + Body <= ConsoleHeight
    # But we also output Footer after body, so: Header + Body + Footer
    #
    # To fill screen: Body = ConsoleHeight - Header - Footer
    #
    $firstPageAvailableLines = $consoleHeight - $HeaderLinesUsed - $FooterLinesUsed
    
    # Ensure minimum
    if ($firstPageAvailableLines -lt 5) { $firstPageAvailableLines = 5 }
    
    # Paging mode
    $currentLogicalLine = 0
    $totalLogicalLines = $screenLineInfo.Count
    $isFirstPage = $true
    
    while ($currentLogicalLine -lt $totalLogicalLines) {
        # Re-query console height for each page in case window size changed
        if (-not $isFirstPage) {
            $consoleHeight = $Host.UI.RawUI.WindowSize.Height
            if ($consoleHeight -le 0) { $consoleHeight = 25 }
            $availableLines = $consoleHeight - 3 - $FooterLinesUsed
        }
        
        # Determine available lines for this page
        $pageLinesAvailable = if ($isFirstPage) { $firstPageAvailableLines } else { $availableLines }
        
        # Determine how many logical lines fit in the current page
        # We track both complete and partial logical lines
        $screenLinesUsed = 0
        $endLogicalLine = $currentLogicalLine
        $partialWrappedLineCount = 0  # If > 0, only show this many wrapped lines from last logical line
        
        while ($endLogicalLine -lt $totalLogicalLines) {
            $linesNeeded = $screenLineInfo[$endLogicalLine].ScreenLines
            
            if ($screenLinesUsed + $linesNeeded -le $pageLinesAvailable) {
                # Entire logical line fits
                $screenLinesUsed += $linesNeeded
                $endLogicalLine++
                $partialWrappedLineCount = 0
            } else {
                # Logical line doesn't fit completely
                $remainingSpace = $pageLinesAvailable - $screenLinesUsed
                
                if ($remainingSpace -gt 0) {
                    # Show partial wrapped lines from this logical line
                    $partialWrappedLineCount = $remainingSpace
                    $endLogicalLine++
                }
                break
            }
        }
        
        # If no lines fit at all, show at least first logical line (partial if needed)
        if ($endLogicalLine -eq $currentLogicalLine) {
            $endLogicalLine = $currentLogicalLine + 1
            $partialWrappedLineCount = [Math]::Min($pageLinesAvailable, $screenLineInfo[$currentLogicalLine].ScreenLines)
        }
        
        # Display lines for this page
        for ($i = $currentLogicalLine; $i -lt $endLogicalLine; $i++) {
            $isLastLogicalLine = ($i -eq $endLogicalLine - 1)
            $linesToShow = if ($isLastLogicalLine -and $partialWrappedLineCount -gt 0) {
                $partialWrappedLineCount
            } else {
                $screenLineInfo[$i].WrappedLines.Count
            }
            
            for ($j = 0; $j -lt $linesToShow; $j++) {
                Write-Host $screenLineInfo[$i].WrappedLines[$j]
            }
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
            Write-Host (" " * 100) -NoNewline
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
