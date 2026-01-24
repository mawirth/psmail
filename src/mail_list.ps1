# mail_list.ps1
# Folder listing logic

function Invoke-ListMessages {
    <#
    .SYNOPSIS
    List messages in current folder
    #>
    
    Reset-StateItems
    
    # Calculate optimal page size based on window height
    $pageSize = Get-OptimalPageSize
    
    # Check if filter is active
    $filterText = Get-Filter
    
    if ($filterText) {
        # Use filtered message retrieval
        Write-Host "Applying filter: '$filterText'..." -ForegroundColor Cyan
        $result = Get-FilteredMessages `
            -FolderId $global:State.View `
            -FilterText $filterText `
            -TargetCount $pageSize
    } else {
        # Normal message retrieval
        $result = Get-FolderMessages `
            -FolderId $global:State.View `
            -Top $pageSize
    }
    
    if (-not $result) {
        Write-Error-Message "Failed to retrieve messages"
        return
    }
    
    if (-not $result.Messages -or $result.Messages.Count -eq 0) {
        Show-CurrentView
        if ($filterText) {
            Write-Host "No messages match filter '$filterText'." -ForegroundColor Yellow
        } else {
            Write-Host "No messages." -ForegroundColor DarkGray
        }
        return
    }
    
    # Store next link for pagination
    $global:State.NextLink = $result.NextLink
    
    # Process messages
    $index = 1
    foreach ($msg in $result.Messages) {
        $item = @{
            Index = $index
            Id = $msg.id
            Subject = $msg.subject
            FromAddress = $msg.from.emailAddress.address
            ToAddress = ""
            DateTime = [datetime]$msg.receivedDateTime
            IsRead = $msg.isRead
            HasAttachments = $msg.hasAttachments
            SmimeStatus = $Config.SmimeStatus.None
        }
        
        # Extract first To recipient
        if ($msg.toRecipients -and $msg.toRecipients.Count -gt 0) {
            $item.ToAddress = $msg.toRecipients[0].emailAddress.address
        }
        
        # Detect S/MIME for inbox messages
        if ($global:State.View -eq "inbox") {
            $item.SmimeStatus = Get-MessageSmimeStatus $msg.id
        }
        
        Add-StateItem $item
        $index++
    }
    
    # Display list
    Show-CurrentView
    Show-MessageList
}

function Invoke-ListMore {
    <#
    .SYNOPSIS
    Load next page of messages
    #>
    
    if (-not $global:State.NextLink) {
        Write-Info "No more messages available"
        return
    }
    
    # Calculate how many more messages to load
    $pageSize = Get-OptimalPageSize
    
    # Check if filter is active
    $filterText = Get-Filter
    
    if ($filterText) {
        # Use filtered message retrieval
        Write-Host "Loading more filtered messages..." -ForegroundColor Cyan
        $result = Get-FilteredMessages `
            -FolderId $global:State.View `
            -FilterText $filterText `
            -TargetCount $pageSize `
            -NextLink $global:State.NextLink
    } else {
        # Normal message retrieval
        $result = Get-FolderMessages `
            -FolderId $global:State.View `
            -NextLink $global:State.NextLink
    }
    
    if (-not $result -or -not $result.Messages) {
        Write-Error-Message "Failed to retrieve messages"
        return
    }
    
    if ($result.Messages.Count -eq 0) {
        Write-Info "No more messages available"
        return
    }
    
    # Update next link
    $global:State.NextLink = $result.NextLink
    
    # Store starting index for new messages
    $startIndex = $global:State.Items.Count + 1
    
    # Append messages
    $index = $startIndex
    $newItems = @()
    foreach ($msg in $result.Messages) {
        $item = @{
            Index = $index
            Id = $msg.id
            Subject = $msg.subject
            FromAddress = $msg.from.emailAddress.address
            ToAddress = ""
            DateTime = [datetime]$msg.receivedDateTime
            IsRead = $msg.isRead
            HasAttachments = $msg.hasAttachments
            SmimeStatus = $Config.SmimeStatus.None
        }
        
        if ($msg.toRecipients -and $msg.toRecipients.Count -gt 0) {
            $item.ToAddress = $msg.toRecipients[0].emailAddress.address
        }
        
        if ($global:State.View -eq "inbox") {
            $item.SmimeStatus = Get-MessageSmimeStatus $msg.id
        }
        
        Add-StateItem $item
        $newItems += $item
        $index++
    }
    
    # Display only new messages
    Write-Host ""
    Write-Host "Loaded $($newItems.Count) more message(s):" -ForegroundColor Cyan
    Write-Host ""
    
    # Show header for new messages
    $view = $global:State.View
    if ($view -eq "inbox") {
        Write-Host "#  U S A  Date              From               " `
            -NoNewline
        Write-Host "Subject" -ForegroundColor DarkGray
    } else {
        Write-Host "#  U A  Date              " `
            -NoNewline
        
        if ($view -eq "sentitems" -or $view -eq "drafts") {
            Write-Host "To                 " -NoNewline
        } else {
            Write-Host "From               " -NoNewline
        }
        
        Write-Host "Subject" -ForegroundColor DarkGray
    }
    
    # Display only new items
    foreach ($item in $newItems) {
        $isUnread = -not $item.IsRead
        $unreadIcon = Get-UnreadIcon $isUnread
        $date = Format-DateTime $item.DateTime
        
        # Index and unread
        Write-Host ("{0,-2} " -f $item.Index) -NoNewline
        Write-Host "$unreadIcon " -NoNewline
        
        # S/MIME icon (inbox only)
        if ($view -eq "inbox") {
            $smimeIcon = Get-SmimeIcon $item.SmimeStatus
            Write-Host "$smimeIcon " -NoNewline
        }
        
        # Attachment indicator
        $attachIcon = if ($item.HasAttachments) { "*" } else { " " }
        Write-Host "$attachIcon  " -NoNewline
        
        # Date
        Write-Host "$date  " -NoNewline
        
        # From/To
        $addr = if ($view -eq "sentitems" -or $view -eq "drafts") { 
            $item.ToAddress 
        } else { 
            $item.FromAddress 
        }
        $addrTrunc = Truncate-String $addr 18
        Write-Host ("{0,-18} " -f $addrTrunc) -NoNewline
        
        # Get console width for subject
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        if ($consoleWidth -le 0) { $consoleWidth = 80 }
        $fixedWidth = if ($view -eq "inbox") { 26 + 20 } else { 23 + 20 }
        $subjectWidth = [Math]::Max(30, $consoleWidth - $fixedWidth - 5)
        
        # Subject
        $subject = Truncate-String $item.Subject $subjectWidth
        Write-Host $subject
    }
    
    # Show pagination info if more available
    if ($global:State.NextLink) {
        Write-Host ""
        Write-Host "[M] More messages available" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    Write-Host "Total: $($global:State.Items.Count) message(s) loaded" -ForegroundColor DarkGray
}

function Invoke-RefreshMessageList {
    <#
    .SYNOPSIS
    Refresh the message list display without reloading from server
    Used after deleting messages to preserve NextLink for filters
    #>
    param(
        [Parameter(Mandatory)]
        [array]$DeletedMessageIds
    )
    
    # Remove deleted items from state and re-index
    Remove-StateItems -MessageIds $DeletedMessageIds
    
    # Display updated list
    Show-CurrentView
    Show-MessageList
}

function Switch-ToFolder {
    <#
    .SYNOPSIS
    Switch to a different folder and list messages
    #>
    param([string]$FolderId)
    
    Set-View $FolderId
    Invoke-ListMessages
}
