# graph.ps1
# REST helpers and pagination

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
    Wrapper around Invoke-MgGraphRequest with error handling
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Method,
        
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [object]$Body = $null
    )
    
    try {
        if ($Body) {
            return Invoke-MgGraphRequest `
                -Method $Method `
                -Uri $Uri `
                -Body $Body `
                -ErrorAction Stop
        } else {
            return Invoke-MgGraphRequest `
                -Method $Method `
                -Uri $Uri `
                -ErrorAction Stop
        }
    } catch {
        Write-Error-Message ("Graph API error: {0}" `
            -f $_.Exception.Message)
        return $null
    }
}

function Get-FolderMessages {
    <#
    .SYNOPSIS
    Get messages from a folder with pagination support
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FolderId,
        
        [int]$Top = 20,
        
        [string]$Select = "id,subject,from,toRecipients," +
            "receivedDateTime,isRead,hasAttachments",
        
        [string]$OrderBy = "receivedDateTime DESC",
        
        [string]$NextLink = $null,
        
        [string]$Filter = $null
    )
    
    if ($NextLink) {
        # Use next link for pagination
        $response = Invoke-GraphRequest -Method GET -Uri $NextLink
    } else {
        # Build new query
        $uri = "/v1.0/me/mailFolders/$FolderId/messages" +
               "?`$top=$Top" +
               "&`$select=$Select" +
               "&`$orderby=$OrderBy"
        
        # Add filter if provided
        if ($Filter) {
            $uri += "&`$filter=$Filter"
        }
        
        $response = Invoke-GraphRequest -Method GET -Uri $uri
    }
    
    if (-not $response) {
        return $null
    }
    
    return @{
        Messages = $response.value
        NextLink = $response.'@odata.nextLink'
    }
}

function Get-Message {
    <#
    .SYNOPSIS
    Get a single message by ID
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [string]$Select = $null
    )
    
    $uri = "/v1.0/me/messages/$MessageId"
    if ($Select) {
        $uri += "?`$select=$Select"
    }
    
    return Invoke-GraphRequest -Method GET -Uri $uri
}

function Get-MessageMime {
    <#
    .SYNOPSIS
    Get message MIME content for S/MIME verification
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/`$value"
    
    try {
        return Invoke-MgGraphRequest `
            -Method GET `
            -Uri $uri `
            -ErrorAction Stop
    } catch {
        return $null
    }
}

function Move-Message {
    <#
    .SYNOPSIS
    Move message to another folder
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [Parameter(Mandatory)]
        [string]$DestinationFolderId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/move"
    $body = @{ destinationId = $DestinationFolderId }
    
    return Invoke-GraphRequest -Method POST -Uri $uri -Body $body
}

function Remove-Message {
    <#
    .SYNOPSIS
    Delete a message (hard delete)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId"
    
    return Invoke-GraphRequest -Method DELETE -Uri $uri
}

function Send-GraphMessage {
    <#
    .SYNOPSIS
    Send a draft message
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/send"
    
    # Send returns no content (202), but we need to handle 
    # the result properly
    try {
        $result = Invoke-MgGraphRequest `
            -Method POST `
            -Uri $uri `
            -ErrorAction Stop
        # Success if no exception thrown
        return @{ success = $true }
    } catch {
        Write-Error-Message ("Failed to send message: {0}" `
            -f $_.Exception.Message)
        return $null
    }
}

function Update-Message {
    <#
    .SYNOPSIS
    Update message properties (PATCH)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [Parameter(Mandatory)]
        [hashtable]$Properties
    )
    
    $uri = "/v1.0/me/messages/$MessageId"
    
    return Invoke-GraphRequest -Method PATCH -Uri $uri -Body $Properties
}

function New-DraftMessage {
    <#
    .SYNOPSIS
    Create a new draft message
    #>
    param(
        [string]$Subject = "",
        [string]$Body = "",
        [array]$ToRecipients = @(),
        [string]$ContentType = "Text"  # "Text" or "HTML"
    )
    
    $uri = "/v1.0/me/messages"
    
    $message = @{
        subject = $Subject
        body = @{
            contentType = $ContentType
            content = $Body
        }
        toRecipients = $ToRecipients
    }
    
    return Invoke-GraphRequest -Method POST -Uri $uri -Body $message
}

function Get-MessageAttachments {
    <#
    .SYNOPSIS
    Get all attachments for a message
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/attachments"
    
    $response = Invoke-GraphRequest -Method GET -Uri $uri
    
    if (-not $response) {
        return @()
    }
    
    return $response.value
}

function Get-Attachment {
    <#
    .SYNOPSIS
    Get a specific attachment
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [Parameter(Mandatory)]
        [string]$AttachmentId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/attachments/$AttachmentId"
    
    return Invoke-GraphRequest -Method GET -Uri $uri
}

function Get-FilteredMessages {
    <#
    .SYNOPSIS
    Get messages matching filter criteria (from, subject, body)
    Fetches messages in batches until target count is reached
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FolderId,
        
        [Parameter(Mandatory)]
        [string]$FilterText,
        
        [int]$TargetCount = 20,
        
        [string]$NextLink = $null
    )
    
    $filteredMessages = @()
    $currentNextLink = $NextLink
    $batchSize = $Config.FilterBatchSize
    $maxSearch = $Config.FilterMaxSearch
    $messagesSearched = 0
    
    # Convert filter text to lowercase
    # for case-insensitive matching
    $filterLower = $FilterText.ToLower()
    
    while ($filteredMessages.Count -lt $TargetCount `
        -and $messagesSearched -lt $maxSearch) {
        # Fetch next batch with body content included
        $selectFields = "id,subject,from,toRecipients," +
            "receivedDateTime,isRead,hasAttachments,body"
        $result = Get-FolderMessages `
            -FolderId $FolderId `
            -Top $batchSize `
            -Select $selectFields `
            -NextLink $currentNextLink
        
        if (-not $result -or -not $result.Messages `
            -or $result.Messages.Count -eq 0) {
            # No more messages available
            break
        }
        
        # Track how many messages we've searched through
        $messagesSearched += $result.Messages.Count
        
        # Filter messages
        foreach ($msg in $result.Messages) {
            $matches = $false
            
            # Check subject
            if ($msg.subject `
                -and $msg.subject.ToLower().Contains($filterLower)) {
                $matches = $true
            }
            
            # Check from address
            if (-not $matches -and $msg.from `
                -and $msg.from.emailAddress) {
                $fromAddr = $msg.from.emailAddress.address
                $fromName = $msg.from.emailAddress.name
                $addrMatch = $fromAddr `
                    -and $fromAddr.ToLower().Contains($filterLower)
                $nameMatch = $fromName `
                    -and $fromName.ToLower().Contains($filterLower)
                if ($addrMatch -or $nameMatch) {
                    $matches = $true
                }
            }
            
            # Check body content
            if (-not $matches -and $msg.body -and $msg.body.content) {
                if ($msg.body.content.ToLower().Contains($filterLower)) {
                    $matches = $true
                }
            }
            
            if ($matches) {
                $filteredMessages += $msg
                # Stop if we've reached target count
                if ($filteredMessages.Count -ge $TargetCount) {
                    break
                }
            }
        }
        
        # Update next link for pagination
        $currentNextLink = $result.NextLink
        
        # Break if no more messages
        if (-not $currentNextLink) {
            break
        }
    }
    
    return @{
        Messages = $filteredMessages
        NextLink = $currentNextLink
    }
}
