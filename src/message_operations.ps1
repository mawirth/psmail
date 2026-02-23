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
    
    # Show success message
    Write-Success ($SuccessMessage -f $successCount)
    
    # Refresh list
    if ($processedIds.Count -gt 0) {
        Invoke-RefreshMessageList -DeletedMessageIds $processedIds
    } else {
        # Show current list even if no messages were processed
        Show-CurrentView
        Show-MessageList
    }
}
