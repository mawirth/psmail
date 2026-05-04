# message_operations.ps1
# Bulk message operations (move, delete, restore)

function Invoke-BulkMessageOperation {
    <#
    .SYNOPSIS
    Perform bulk operation on messages (move, delete, restore)
    
    .DESCRIPTION
    Generic function to handle bulk message operations with validation,
    confirmation, and error handling. Reduces code duplication across
    X, K, INBOX, RESTORE, and PURGE commands.
    
    .PARAMETER Argument
    The argument string containing indices (e.g., "3", "1-5", "1,3,5")
    
    .PARAMETER Command
    The command name for usage messages
    
    .PARAMETER OperationType
    Type of operation: "Move" or "Delete"
    
    .PARAMETER PromptMessage
    Message to show before confirmation (e.g., "Delete this message?")
    
    .PARAMETER ConfirmMessage
    Confirmation prompt text (e.g., "Confirm delete")
    
    .PARAMETER SuccessMessage
    Success message template (use {0} for count)
    
    .PARAMETER DestinationFolderId
    For move operations: destination folder ID
    
    .PARAMETER ConfirmColor
    Color for confirmation prompt (ConfirmWarning or ConfirmDanger)
    
    .PARAMETER ShowCancelledList
    Whether to show list if user cancels (default: $true for X/PURGE/RESTORE, $false for K/INBOX)
    
    .EXAMPLE
    Invoke-BulkMessageOperation -Argument "1-3" -Command "X" -OperationType "Move" `
        -PromptMessage "Delete" -ConfirmMessage "Confirm delete" `
        -SuccessMessage "{0} message(s) moved to Deleted" `
        -DestinationFolderId $Config.Folders.Deleted
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Argument,
        
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter(Mandatory)]
        [ValidateSet("Move", "Delete")]
        [string]$OperationType,
        
        [Parameter(Mandatory)]
        [string]$PromptMessage,
        
        [Parameter(Mandatory)]
        [string]$ConfirmMessage,
        
        [Parameter(Mandatory)]
        [string]$SuccessMessage,
        
        [string]$DestinationFolderId = $null,
        
        [ValidateSet("ConfirmWarning", "ConfirmDanger")]
        [string]$ConfirmColor = "ConfirmWarning",
        
        [bool]$ShowCancelledList = $true
    )
    
    # Validate argument presence
    if ([string]::IsNullOrWhiteSpace($Argument)) {
        Write-Error-Message "Usage: $Command <#>, $Command <#-#>, or $Command <#,#,#>"
        return
    }
    
    # Parse indices
    $indices = Parse-IndexRange $Argument
    
    if (-not $indices) {
        Write-Error-Message "Invalid index or range: $Argument"
        return
    }
    
    # Validate all indices and collect items
    $items = @()
    foreach ($index in $indices) {
        $item = Get-StateItem $index
        if (-not $item) {
            Write-Error-Message "Invalid message number: $index"
            continue
        }
        $items += @{ Index = $index; Item = $item }
    }
    
    if ($items.Count -eq 0) {
        return
    }
    
    # Show confirmation prompt
    Write-Host ""
    
    $promptText = if ($items.Count -eq 1) {
        "$PromptMessage this message?"
    } else {
        "$PromptMessage these $($items.Count) messages?"
    }
    
    Write-Host $promptText -ForegroundColor $Config.Colors.$ConfirmColor
    
    # Show message details
    $view = $global:State.View
    foreach ($entry in $items) {
        $index = $entry.Index
        $item = $entry.Item
        $date = Format-DateTime $item.DateTime
        
        # Choose address based on view
        $addr = if ($view -eq "sentitems" -or $view -eq "drafts") {
            $item.ToAddress
        } else {
            $item.FromAddress
        }
        
        Write-Host "  #$index  $date  $addr" `
            -ForegroundColor $Config.Colors.MessageDetail
        Write-Host "  Subject: $($item.Subject)" `
            -ForegroundColor $Config.Colors.MessageDetail
    }
    Write-Host ""
    
    # Confirmation message
    $confirmMsg = if ($items.Count -eq 1) {
        $ConfirmMessage
    } else {
        "$ConfirmMessage all"
    }
    
    # Get user confirmation
    if (-not (Confirm-Action $confirmMsg)) {
        # Action cancelled
        if ($ShowCancelledList) {
            Show-CurrentView
            Show-MessageList
        }
        return
    }
    
    # Perform operation
    $successCount = 0
    $processedIds = @()
    
    foreach ($entry in $items) {
        $item = $entry.Item
        $operationSucceeded = $false
        
        switch ($OperationType) {
            "Move" {
                if ([string]::IsNullOrWhiteSpace($DestinationFolderId)) {
                    Write-Error-Message "DestinationFolderId required for Move operation"
                    continue
                }
                $operationSucceeded = Move-Message `
                    -MessageId $item.Id `
                    -DestinationFolderId $DestinationFolderId
            }
            "Delete" {
                $operationSucceeded = Remove-Message -MessageId $item.Id
            }
        }
        
        if ($operationSucceeded) {
            $successCount++
            $processedIds += $item.Id
        }
    }
    
    Set-StatusMessage -Message ($SuccessMessage -f $successCount) -Color "Success"
    
    # Refresh list
    if ($processedIds.Count -gt 0) {
        Invoke-RefreshMessageList -DeletedMessageIds $processedIds
    } else {
        # Show current list even if no messages were processed
        Show-CurrentView
        Show-MessageList
    }
}

function Get-SelectedMessageItems {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Argument,

        [Parameter(Mandatory)]
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Argument)) {
        Write-Error-Message "Usage: $Command <#>, $Command <#-#>, or $Command <#,#,#>"
        return @()
    }

    $indices = Parse-IndexRange $Argument
    if (-not $indices) {
        Write-Error-Message "Invalid index or range: $Argument"
        return @()
    }

    $items = @()
    foreach ($index in $indices) {
        $item = Get-StateItem $index
        if (-not $item) {
            Write-Error-Message "Invalid message number: $index"
            continue
        }
        $items += @{ Index = $index; Item = $item }
    }

    return @($items)
}

function Invoke-InboxClassificationOperation {
    <#
    .SYNOPSIS
    Mark Inbox messages as Focused or Other, optionally creating sender overrides.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Argument,

        [Parameter(Mandatory)]
        [ValidateSet("focused", "other")]
        [string]$Classification,

        [switch]$Always
    )

    if ($global:State.View -ne $Config.Folders.Inbox) {
        Write-Error-Message "Focused Inbox classification commands are only available in Inbox"
        return
    }

    $command = if ($Classification -eq "focused") { "FOCUS" } else { "OTHER" }
    if ($Always) { $command += "!" }

    $entries = @(Get-SelectedMessageItems -Argument $Argument -Command $command)
    if ($entries.Count -eq 0) {
        return
    }

    $label = if ($Classification -eq "focused") { "Relevant" } else { "Sonstige" }

    if ($Always) {
        Write-Host ""
        $promptText = if ($entries.Count -eq 1) {
            "Always classify future mail from this sender as $($label)?"
        } else {
            "Always classify future mail from these $($entries.Count) senders as $($label)?"
        }
        Write-Host $promptText -ForegroundColor $Config.Colors.ConfirmWarning

        foreach ($entry in $entries) {
            $item = $entry.Item
            Write-Host "  #$($entry.Index)  $($item.FromAddress)" `
                -ForegroundColor $Config.Colors.MessageDetail
            Write-Host "  Subject: $($item.Subject)" `
                -ForegroundColor $Config.Colors.MessageDetail
        }
        Write-Host ""

        $confirmMsg = if ($entries.Count -eq 1) {
            "Confirm sender rule"
        } else {
            "Confirm sender rules"
        }
        if (-not (Confirm-Action $confirmMsg)) {
            Show-CurrentView
            Show-MessageList
            return
        }
    }

    $successCount = 0
    $messageSuccessCount = 0
    $overrideSuccessCount = 0
    $removedIds = @()
    $seenOverrideAddresses = @{}
    $currentInboxClass = Get-InboxClassification

    foreach ($entry in $entries) {
        $item = $entry.Item

        if ($Always) {
            $messageResult = Set-MessageInferenceClassification `
                -MessageId $item.Id `
                -Classification $Classification
            if ($messageResult) {
                $messageSuccessCount++
                $item.InferenceClassification = $Classification
            }

            if ([string]::IsNullOrWhiteSpace($item.FromAddress)) {
                Write-Error-Message "Cannot create sender rule: selected message has no From address"
                continue
            }

            $addressKey = $item.FromAddress.ToLowerInvariant()
            if ($seenOverrideAddresses.ContainsKey($addressKey)) {
                continue
            }
            $seenOverrideAddresses[$addressKey] = $true
            $overrideResult = Set-InferenceClassificationOverride `
                -Address $item.FromAddress `
                -Name $item.FromName `
                -Classification $Classification
            if ($overrideResult) {
                $overrideSuccessCount++
            }
        } else {
            $result = Set-MessageInferenceClassification `
                -MessageId $item.Id `
                -Classification $Classification
            if ($result) {
                $item.InferenceClassification = $Classification
            }
        }

        if (-not $Always -and $result) {
            $successCount++
            if (-not $Always -and
                $currentInboxClass -and
                $currentInboxClass -ne $Classification) {
                $removedIds += $item.Id
            }
        }
    }

    $statusMessage = if ($Always) {
        "Marked $messageSuccessCount message(s) as $label | Created/updated $overrideSuccessCount sender rule(s)"
    } else {
        "Marked $successCount message(s) as $label"
    }
    Set-StatusMessage -Message $statusMessage -Color "Success"

    if ($Always) {
        Invoke-ListMessages
    } elseif ($removedIds.Count -gt 0) {
        Invoke-RefreshMessageList -DeletedMessageIds $removedIds
    } else {
        Show-CurrentView
        Show-MessageList
    }
}
