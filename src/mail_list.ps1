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
        FromName = $Message.from.emailAddress.name
        FromAddress = $Message.from.emailAddress.address
        ToAddress = ""
        DateTime = [datetime]$Message.receivedDateTime
        IsRead = $Message.isRead
        HasAttachments = $Message.hasAttachments
        InferenceClassification = $Message.inferenceClassification
        SmimeStatus = $Config.SmimeStatus.None
        IsEncrypted = $false
    }
    
    # Extract first To recipient
    if ($Message.toRecipients -and $Message.toRecipients.Count -gt 0) {
        $item.ToAddress = $Message.toRecipients[0].emailAddress.address
    }
    
    # S/MIME status is verified lazily when a message is opened
    # (avoids N+1 API calls during inbox listing).
    # Restore a previously cached result so the E/S list indicator
    # persists across list refreshes within the same session.
    $item.SmimeStatus = $Config.SmimeStatus.None
    if ($global:State.SmimeCache -and
        $global:State.SmimeCache.ContainsKey($Message.id)) {
        $cacheEntry = $global:State.SmimeCache[$Message.id]
        $cachedStatus = $cacheEntry.Status
        if ($cachedStatus -ne $Config.SmimeStatus.Encrypted) {
            $item.SmimeStatus = $cachedStatus
        }
        $item.IsEncrypted = [bool]$cacheEntry.IsEncrypted
        if ($null -ne $cacheEntry.HasUserAttachments) {
            $item.HasAttachments = [bool]$cacheEntry.HasUserAttachments
        }
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
    $inboxClass = Get-InboxClassification
    
    if ($filterText) {
        # Use filtered message retrieval
        return Get-FilteredMessages `
            -FolderId $global:State.View `
            -FilterText $filterText `
            -TargetCount $Count `
            -NextLink $NextLink `
            -InferenceClassification $inboxClass
    } else {
        # Normal message retrieval
        return Get-FolderMessages `
            -FolderId $global:State.View `
            -Top $Count `
            -NextLink $NextLink `
            -InferenceClassification $inboxClass
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
    
    # Get messages (automatically handles filter vs normal)
    $result = Get-Messages -Count $pageSize
    
    if (-not $result) {
        Write-Error-Message "Failed to retrieve messages"
        return
    }
    
    # Store next link for pagination
    $global:State.NextLink = $result.NextLink
    
    # Add messages to state
    if ($result.Messages -and $result.Messages.Count -gt 0) {
        Add-MessagesToState -Messages $result.Messages | Out-Null
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
    
    $pageSize = Get-OptimalPageSize

    if (-not $global:State.NextLink) {
        Set-StatusMessage -Message "No more messages available" -Color "Info"
        $lastPageStart = [Math]::Max(0, $global:State.Items.Count - $pageSize)
        Show-CurrentView
        Show-MessageList -StartIndex $lastPageStart
        return
    }
    
    # Get messages (automatically handles filter vs normal)
    $result = Get-Messages -Count $pageSize -NextLink $global:State.NextLink
    
    if (-not $result -or -not $result.Messages) {
        Write-Error-Message "Failed to retrieve messages"
        return
    }
    
    if ($result.Messages.Count -eq 0) {
        $global:State.NextLink = $null
        Set-StatusMessage -Message "No more messages available" -Color "Info"
        $lastPageStart = [Math]::Max(0, $global:State.Items.Count - $pageSize)
        Show-CurrentView
        Show-MessageList -StartIndex $lastPageStart
        return
    }
    
    $previousCount = $global:State.Items.Count

    # Update next link
    $global:State.NextLink = $result.NextLink
    
    # Add messages to state
    $newItems = @(Add-MessagesToState -Messages $result.Messages)

    Set-StatusMessage -Message "Loaded $($newItems.Count) more message(s)" -Color "Success"
    Show-CurrentView
    Show-MessageList -StartIndex $previousCount
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
    
    if ($loadedCount -gt 0) {
        $statusMessage = "Loaded $loadedCount new message(s)"
        if ($global:State.StatusMessage) {
            $statusMessage = "$($global:State.StatusMessage) | $statusMessage"
        }
        Set-StatusMessage -Message $statusMessage -Color "Success"
    }

    if ($global:State.View -eq $Config.Folders.Drafts -and
        (Get-Command Cleanup-StaleEncryptedDraftData -ErrorAction SilentlyContinue)) {
        $currentDraftIds = @($global:State.Items | ForEach-Object { $_.Id })
        $removedEncryptedDrafts = Cleanup-StaleEncryptedDraftData -CurrentDraftIds $currentDraftIds
        if ($removedEncryptedDrafts -gt 0) {
            $cleanupMessage = "Removed $removedEncryptedDrafts stale local encrypted draft entr$(if ($removedEncryptedDrafts -eq 1) { 'y' } else { 'ies' })"
            if ($global:State.StatusMessage) {
                $cleanupMessage = "$($global:State.StatusMessage) | $cleanupMessage"
            }
            Set-StatusMessage -Message $cleanupMessage -Color "Info"
        }
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
