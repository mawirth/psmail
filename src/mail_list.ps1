# mail_list.ps1
# Folder listing logic

function ConvertTo-MessageItem {
    <#
    .SYNOPSIS
    Convert a Graph API message to an internal item object
    #>
    param(
        [Parameter(Mandatory)]
        $Message,
        
        [Parameter(Mandatory)]
        [int]$Index
    )
    
    $item = @{
        Index = $Index
        Id = $Message.id
        Subject = $Message.subject
        FromAddress = $Message.from.emailAddress.address
        ToAddress = ""
        DateTime = [datetime]$Message.receivedDateTime
        IsRead = $Message.isRead
        HasAttachments = $Message.hasAttachments
        SmimeStatus = $Config.SmimeStatus.None
    }
    
    # Extract first To recipient
    if ($Message.toRecipients -and $Message.toRecipients.Count -gt 0) {
        $item.ToAddress = $Message.toRecipients[0].emailAddress.address
    }
    
    # Detect S/MIME for inbox messages
    if ($global:State.View -eq "inbox") {
        $item.SmimeStatus = Get-MessageSmimeStatus $Message.id
    }
    
    return $item
}

function Get-Messages {
    <#
    .SYNOPSIS
    Get messages with automatic filter handling
    Returns hashtable with Messages and NextLink
    #>
    param(
        [int]$Count,
        [string]$NextLink = $null
    )
    
    $filterText = Get-Filter
    
    if ($filterText) {
        # Use filtered message retrieval
        return Get-FilteredMessages `
            -FolderId $global:State.View `
            -FilterText $filterText `
            -TargetCount $Count `
            -NextLink $NextLink
    } else {
        # Normal message retrieval
        return Get-FolderMessages `
            -FolderId $global:State.View `
            -Top $Count `
            -NextLink $NextLink
    }
}

function Add-MessagesToState {
    <#
    .SYNOPSIS
    Add messages to state and convert them to items
    Returns array of added items
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Messages
    )
    
    $startIndex = $global:State.Items.Count + 1
    $addedItems = [System.Collections.ArrayList]@()
    
    $index = $startIndex
    foreach ($msg in $Messages) {
        $item = ConvertTo-MessageItem -Message $msg -Index $index
        Add-StateItem $item
        [void]$addedItems.Add($item)
        $index++
    }
    
    # Return as array (ArrayList will not unwrap)
    return @($addedItems)
}

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
        Write-Host "Applying filter: '$filterText'..." -ForegroundColor Cyan
    }
    
    # Get messages (automatically handles filter vs normal)
    $result = Get-Messages -Count $pageSize
    
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
    
    # Add messages to state
    Add-MessagesToState -Messages $result.Messages | Out-Null
    
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
        Write-Host "Loading more filtered messages..." -ForegroundColor Cyan
    }
    
    # Get messages (automatically handles filter vs normal)
    $result = Get-Messages -Count $pageSize -NextLink $global:State.NextLink
    
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
    
    # Add messages to state
    $newItems = @(Add-MessagesToState -Messages $result.Messages)
    
    # Display only new messages
    Write-Host ""
    Write-Host "Loaded $($newItems.Count) more message(s):" -ForegroundColor Cyan
    Write-Host ""
    
    # Show header for new messages
    $view = $global:State.View
    $columnWidths = Get-ColumnWidths -View $view
    
    Render-MessageListHeader -View $view
    
    # Display only new items
    foreach ($item in $newItems) {
        Render-MessageRow -Item $item -View $view -ColumnWidths $columnWidths
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
    Refresh the message list display after deleting/moving messages
    Automatically loads more messages to maintain optimal page size
    #>
    param(
        [Parameter(Mandatory)]
        [array]$DeletedMessageIds
    )
    
    # Remove deleted items from state and re-index
    $deletedCount = $DeletedMessageIds.Count
    Remove-StateItems -MessageIds $DeletedMessageIds
    
    # Auto-load messages to maintain optimal page size
    $loadedCount = 0
    if ($global:State.NextLink) {
        $pageSize = Get-OptimalPageSize
        $currentCount = $global:State.Items.Count
        
        # Calculate how many messages we need to load to reach optimal size
        $messagesToLoad = [Math]::Min($deletedCount, $pageSize - $currentCount)
        
        if ($messagesToLoad -gt 0) {
            # Get messages (may return more than requested, especially with filters)
            $result = Get-Messages -Count $messagesToLoad -NextLink $global:State.NextLink
            
            if ($result -and $result.Messages -and $result.Messages.Count -gt 0) {
                # Update next link
                $global:State.NextLink = $result.NextLink
                
                # Only add exactly as many messages as we need
                $messagesToAdd = [Math]::Min($result.Messages.Count, $messagesToLoad)
                
                if ($messagesToAdd -ge $result.Messages.Count) {
                    # Take all messages
                    $messageBatch = $result.Messages
                } else {
                    # Take only what we need
                    $messageBatch = @($result.Messages | Select-Object -First $messagesToAdd)
                }
                
                # Add messages to state
                $addedItems = @(Add-MessagesToState -Messages $messageBatch)
                $loadedCount = $addedItems.Count
            }
        }
    }
    
    # Show load message if we loaded new messages
    if ($loadedCount -gt 0) {
        Write-Host "Loaded $loadedCount new message(s)" -ForegroundColor Green
        Write-Host ""
    }
    
    # Display the refreshed message list
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
