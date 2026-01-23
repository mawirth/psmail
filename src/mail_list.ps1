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
    
    # Append messages
    $index = $global:State.Items.Count + 1
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
        $index++
    }
    
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
