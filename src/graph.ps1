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
        
        [object]$Body = $null,

        [hashtable]$Headers = $null
    )
    
    try {
        if ($Body) {
            if ($Headers) {
                return Invoke-MgGraphRequest `
                    -Method $Method `
                    -Uri $Uri `
                    -Body $Body `
                    -Headers $Headers `
                    -ErrorAction Stop
            } else {
                return Invoke-MgGraphRequest `
                    -Method $Method `
                    -Uri $Uri `
                    -Body $Body `
                    -ErrorAction Stop
            }
        } else {
            if ($Headers) {
                return Invoke-MgGraphRequest `
                    -Method $Method `
                    -Uri $Uri `
                    -Headers $Headers `
                    -ErrorAction Stop
            } else {
                return Invoke-MgGraphRequest `
                    -Method $Method `
                    -Uri $Uri `
                    -ErrorAction Stop
            }
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
            "receivedDateTime,isRead,hasAttachments," +
            "inferenceClassification",
        
        [string]$OrderBy = "receivedDateTime DESC",
        
        [string]$NextLink = $null,
        
        [string]$Filter = $null,

        [string]$InferenceClassification = $null
    )
    
    if ($NextLink) {
        # Reuse Graph paging URL as-is.
        $response = Invoke-GraphRequest -Method GET -Uri $NextLink
    } else {
        # Build new query
        $effectiveFilter = $Filter
        $effectiveOrderBy = $OrderBy

        if ($InferenceClassification) {
            $classificationFilter = "inferenceClassification eq '$InferenceClassification'"
            if ($effectiveFilter) {
                $effectiveFilter = "($effectiveFilter) and ($classificationFilter)"
            } else {
                $effectiveFilter = $classificationFilter
            }

            # Graph rejects inferenceClassification filters ordered only by
            # receivedDateTime with InefficientFilter. Including the filtered
            # field first keeps the list date-descending within the class.
            $effectiveOrderBy = "inferenceClassification,receivedDateTime DESC"
        }

        $uri = "/v1.0/me/mailFolders/$FolderId/messages" +
               "?`$top=$Top" +
               "&`$select=$Select" +
               "&`$orderby=$([uri]::EscapeDataString($effectiveOrderBy))"
        
        # Add filter if provided
        if ($effectiveFilter) {
            $uri += "&`$filter=$([uri]::EscapeDataString($effectiveFilter))"
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
    Get raw MIME content of a message (RFC 2822 format).
    Used for S/MIME verification.
    Returns the raw MIME as a string, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/`$value"
    
    try {
        # -OutputType String returns the raw response body as a string
        # (instead of trying to parse it as JSON)
        return Invoke-MgGraphRequest `
            -Method GET `
            -Uri $uri `
            -OutputType String `
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
    
    # DELETE requests return no content (HTTP 204) on success
    # Invoke-GraphRequest returns $null on error, so we need to handle this differently
    try {
        Invoke-MgGraphRequest `
            -Method DELETE `
            -Uri $uri `
            -ErrorAction Stop
        # If no exception was thrown, deletion was successful
        return @{ success = $true }
    } catch {
        Write-Error-Message ("Failed to delete message: {0}" `
            -f $_.Exception.Message)
        return $null
    }
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

function Set-MessageInferenceClassification {
    <#
    .SYNOPSIS
    Mark one message as Focused or Other in Outlook Focused Inbox.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,

        [Parameter(Mandatory)]
        [ValidateSet("focused", "other")]
        [string]$Classification
    )

    return Update-Message `
        -MessageId $MessageId `
        -Properties @{ inferenceClassification = $Classification }
}

function Set-InferenceClassificationOverride {
    <#
    .SYNOPSIS
    Always classify future Inbox mail from a sender as Focused or Other.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Address,

        [string]$Name = "",

        [Parameter(Mandatory)]
        [ValidateSet("focused", "other")]
        [string]$Classification
    )

    $uri = "/v1.0/me/inferenceClassification/overrides"
    $body = @{
        classifyAs = $Classification
        senderEmailAddress = @{
            name = $Name
            address = $Address
        }
    }

    return Invoke-GraphRequest -Method POST -Uri $uri -Body $body
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
    Get all attachments for a message.
    Always returns a [array] - empty if none, never $null.
    Normalises the SDK response which may return a single item,
    an array, or a full OData envelope depending on version.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    $uri = "/v1.0/me/messages/$MessageId/attachments"
    
    $response = Invoke-GraphRequest -Method GET -Uri $uri
    if (-not $response) { return @() }
    
    # Unwrap OData envelope when present
    $raw = if ($response -is [hashtable] -and $response.ContainsKey('value')) {
        $response['value']
    } else {
        $response.value
    }
    
    if (-not $raw) { return @() }
    # @() wraps single items into arrays; is a no-op for existing arrays
    return @($raw)
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

function Remove-Attachment {
    <#
    .SYNOPSIS
    Delete an attachment from a draft message
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,

        [Parameter(Mandatory)]
        [string]$AttachmentId
    )

    $uri = "/v1.0/me/messages/$MessageId/attachments/$AttachmentId"

    try {
        Invoke-MgGraphRequest `
            -Method DELETE `
            -Uri $uri `
            -ErrorAction Stop
        return @{ success = $true }
    } catch {
        Write-Error-Message ("Failed to delete attachment: {0}" `
            -f $_.Exception.Message)
        return $null
    }
}

function Get-FilteredMessages {
    <#
    .SYNOPSIS
    Get messages matching filter criteria via Microsoft Graph server-side search
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FolderId,
        
        [Parameter(Mandatory)]
        [string]$FilterText,
        
        [int]$TargetCount = 20,
        
        [string]$NextLink = $null,

        [string]$InferenceClassification = $null
    )

    $selectFields = "id,subject,from,toRecipients," +
        "receivedDateTime,isRead,hasAttachments," +
        "inferenceClassification"

    $next = $NextLink
    $messages = [System.Collections.ArrayList]@()

    do {
        if ($next) {
            $response = Invoke-GraphRequest -Method GET -Uri $next
        } else {
            $quotedSearch = '"' + ($FilterText -replace '"', '""') + '"'
            $encodedSearch = [uri]::EscapeDataString($quotedSearch)
            $uri = "/v1.0/me/mailFolders/$FolderId/messages" +
                "?`$top=$TargetCount" +
                "&`$select=$selectFields" +
                "&`$search=$encodedSearch"
            $response = Invoke-GraphRequest -Method GET -Uri $uri
        }

        if (-not $response) {
            break
        }

        foreach ($message in @($response.value)) {
            if ($InferenceClassification -and
                $message.inferenceClassification -ne $InferenceClassification) {
                continue
            }
            [void]$messages.Add($message)
            if ($messages.Count -ge $TargetCount) {
                break
            }
        }

        $next = $response.'@odata.nextLink'
    } while ($InferenceClassification -and
        $messages.Count -lt $TargetCount -and
        $next)

    if (-not $InferenceClassification -and $response) {
        return @{
            Messages = $response.value
            NextLink = $response.'@odata.nextLink'
        }
    }

    return @{
        Messages = @($messages)
        NextLink = $next
    }
}
