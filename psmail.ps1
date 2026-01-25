# psmail.ps1
# PowerShell Console Mail Client for Outlook.com

<#
.SYNOPSIS
psmail - Console email client for Outlook.com using Microsoft Graph

.DESCRIPTION
Draft-first email workflow with nvim integration and S/MIME support

.NOTES
Requires PowerShell 7+
#>

$ErrorActionPreference = "Stop"

# Load System.Web for URL decoding
# (required for SafeLink unwrapping)
Add-Type -AssemblyName System.Web

# Get script root
$ScriptRoot = $PSScriptRoot

# Dot-source all modules
. "$ScriptRoot\src\config.ps1"
. "$ScriptRoot\src\util.ps1"
. "$ScriptRoot\src\state.ps1"
. "$ScriptRoot\src\auth.ps1"
. "$ScriptRoot\src\graph.ps1"
. "$ScriptRoot\src\ui.ps1"
. "$ScriptRoot\src\mail_list.ps1"
. "$ScriptRoot\src\mail_read.ps1"
. "$ScriptRoot\src\drafts.ps1"
. "$ScriptRoot\src\editor.ps1"
. "$ScriptRoot\src\attachments.ps1"
. "$ScriptRoot\src\smime.ps1"
. "$ScriptRoot\src\contacts.ps1"

# Initialize state
Initialize-State

# Connect to Graph
Write-Host ""
Write-Host "=== psmail - PowerShell Mail Client ===" `
    -ForegroundColor Cyan
Write-Host ""

if (-not (Connect-GraphMail)) {
    Write-Error-Message "Failed to connect. Exiting."
    exit 1
}

# Initial list
Invoke-ListMessages

# Command loop
while ($true) {
    Show-Menu
    $cmd = Read-Command
    
    if (-not $cmd) {
        continue
    }
    
    $command = $cmd.Command
    $arg = $cmd.Argument
    
    # Global folder navigation - handle these first
    # and skip the view-specific switch
    $handled = $false
    switch ($command) {
        "I" {
            Switch-ToFolder $Config.Folders.Inbox
            $handled = $true
        }
        "D" {
            Switch-ToFolder $Config.Folders.Drafts
            $handled = $true
        }
        "S" {
            Switch-ToFolder $Config.Folders.Sent
            $handled = $true
        }
        "G" {
            Switch-ToFolder $Config.Folders.Deleted
            $handled = $true
        }
        "J" {
            Switch-ToFolder $Config.Folders.Junk
            $handled = $true
        }
        "LOGOUT" {
            Write-Host ""
            Write-Info "Disconnecting and clearing session..."
            Disconnect-MgGraph -ErrorAction SilentlyContinue
            Write-Success "Logged out successfully"
            exit 0
        }
        "Q" {
            Write-Host ""
            Write-Info "Goodbye! (Session remains active)"
            exit 0
        }
    }
    
    # If global navigation was handled, skip view commands
    if ($handled) {
        continue
    }
    
    # View-specific commands
    $view = $global:State.View
    
    switch ($command) {
        "L" {
            Invoke-ListMessages
        }
        "M" {
            Invoke-ListMore
        }
        "R" {
            if (-not $arg) {
                Write-Error-Message "Usage: R <number>"
                continue
            }
            $index = [int]$arg
            Invoke-OpenMessage -Index $index
        }
        "X" {
            # X is not available in Deleted folder - use PURGE or RESTORE instead
            if ($view -eq "deleteditems") {
                Write-Error-Message "X not available in Deleted. Use PURGE to permanently delete or RESTORE to recover."
                continue
            }
            
            if (-not $arg) {
                Write-Error-Message "Usage: X <#>, X <#-#>, or X <#,#,#>"
                continue
            }
            
            # Parse argument - could be single number or range
            $indices = Parse-IndexRange $arg
            
            if (-not $indices) {
                Write-Error-Message "Invalid index or range: $arg"
                continue
            }
            
            # Validate all indices
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
                continue
            }
            
            # Show message details before delete
            Write-Host ""
            if ($items.Count -eq 1) {
                Write-Host "Delete this message?" `
                    -ForegroundColor Yellow
            } else {
                Write-Host "Delete these $($items.Count) messages?" `
                    -ForegroundColor Yellow
            }
            
            foreach ($entry in $items) {
                $index = $entry.Index
                $item = $entry.Item
                $date = Format-DateTime $item.DateTime
                $from = if ($view -eq "sentitems") {
                    $item.ToAddress
                } else {
                    $item.FromAddress
                }
                Write-Host "  #$index  $date  $from" `
                    -ForegroundColor Cyan
                Write-Host "  Subject: $($item.Subject)" `
                    -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmMsg = if ($items.Count -eq 1) { 
                "Confirm delete" 
            } else { 
                "Confirm delete all" 
            }
            
            if (Confirm-Action $confirmMsg) {
                $successCount = 0
                $deletedIds = @()
                foreach ($entry in $items) {
                    $item = $entry.Item
                    # Move to deleted
                    if (Move-Message `
                        -MessageId $item.Id `
                        -DestinationFolderId $Config.Folders.Deleted) {
                        $successCount++
                        $deletedIds += $item.Id
                    }
                }
                
                Write-Success "$successCount message(s) moved to Deleted"
                
                if ($deletedIds.Count -gt 0) {
                    # Refresh list without reloading (preserves NextLink for filters)
                    Invoke-RefreshMessageList -DeletedMessageIds $deletedIds
                } else {
                    # Show current list even if no messages were deleted
                    Show-CurrentView
                    Show-MessageList
                }
            } else {
                # Action cancelled - still show the list
                Show-CurrentView
                Show-MessageList
            }
        }
        "K" {
            # Move to Junk (from inbox)
            if ($view -ne "inbox") {
                Write-Error-Message "K command only available in Inbox"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: K <#>, K <#-#>, or K <#,#,#>"
                continue
            }
            
            # Parse argument - could be single number or range
            $indices = Parse-IndexRange $arg
            
            if (-not $indices) {
                Write-Error-Message "Invalid index or range: $arg"
                continue
            }
            
            # Validate all indices
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
                continue
            }
            
            # Show message details before moving to junk
            Write-Host ""
            if ($items.Count -eq 1) {
                Write-Host "Move this message to Junk?" `
                    -ForegroundColor Yellow
            } else {
                Write-Host "Move these $($items.Count) messages to Junk?" `
                    -ForegroundColor Yellow
            }
            
            foreach ($entry in $items) {
                $index = $entry.Index
                $item = $entry.Item
                $date = Format-DateTime $item.DateTime
                Write-Host "  #$index  $date  $($item.FromAddress)" `
                    -ForegroundColor Cyan
                Write-Host "  Subject: $($item.Subject)" `
                    -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmMsg = if ($items.Count -eq 1) { 
                "Confirm move to Junk" 
            } else { 
                "Confirm move all to Junk" 
            }
            
            if (Confirm-Action $confirmMsg) {
                $successCount = 0
                $movedIds = @()
                foreach ($entry in $items) {
                    $item = $entry.Item
                    if (Move-Message `
                        -MessageId $item.Id `
                        -DestinationFolderId $Config.Folders.Junk) {
                        $successCount++
                        $movedIds += $item.Id
                    }
                }
                
                Write-Success "$successCount message(s) moved to Junk"
                
                if ($movedIds.Count -gt 0) {
                    # Refresh list without reloading (preserves NextLink for filters)
                    Invoke-RefreshMessageList -DeletedMessageIds $movedIds
                }
            }
        }
        "INBOX" {
            # Move to Inbox (from junk)
            if ($view -ne "junkemail") {
                Write-Error-Message "INBOX command only available in Junk"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: INBOX <#>, INBOX <#-#>, or INBOX <#,#,#>"
                continue
            }
            
            # Parse argument - could be single number or range
            $indices = Parse-IndexRange $arg
            
            if (-not $indices) {
                Write-Error-Message "Invalid index or range: $arg"
                continue
            }
            
            # Validate all indices
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
                continue
            }
            
            # Show message details before moving to inbox
            Write-Host ""
            if ($items.Count -eq 1) {
                Write-Host "Move this message to Inbox?" `
                    -ForegroundColor Yellow
            } else {
                Write-Host "Move these $($items.Count) messages to Inbox?" `
                    -ForegroundColor Yellow
            }
            
            foreach ($entry in $items) {
                $index = $entry.Index
                $item = $entry.Item
                $date = Format-DateTime $item.DateTime
                Write-Host "  #$index  $date  $($item.FromAddress)" `
                    -ForegroundColor Cyan
                Write-Host "  Subject: $($item.Subject)" `
                    -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmMsg = if ($items.Count -eq 1) { 
                "Confirm move to Inbox" 
            } else { 
                "Confirm move all to Inbox" 
            }
            
            if (Confirm-Action $confirmMsg) {
                $successCount = 0
                $movedIds = @()
                foreach ($entry in $items) {
                    $item = $entry.Item
                    if (Move-Message `
                        -MessageId $item.Id `
                        -DestinationFolderId $Config.Folders.Inbox) {
                        $successCount++
                        $movedIds += $item.Id
                    }
                }
                
                Write-Success "$successCount message(s) moved to Inbox"
                
                if ($movedIds.Count -gt 0) {
                    # Refresh list without reloading (preserves NextLink for filters)
                    Invoke-RefreshMessageList -DeletedMessageIds $movedIds
                }
            }
        }
        "RESTORE" {
            # Restore from deleted
            if ($view -ne "deleteditems") {
                Write-Error-Message "RESTORE only available in Deleted"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: RESTORE <#>, RESTORE <#-#>, or RESTORE <#,#,#>"
                continue
            }
            
            # Parse argument - could be single number or range
            $indices = Parse-IndexRange $arg
            
            if (-not $indices) {
                Write-Error-Message "Invalid index or range: $arg"
                continue
            }
            
            # Validate all indices
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
                continue
            }
            
            # Show message details before restoring
            Write-Host ""
            if ($items.Count -eq 1) {
                Write-Host "Restore this message to Inbox?" `
                    -ForegroundColor Yellow
            } else {
                Write-Host "Restore these $($items.Count) messages to Inbox?" `
                    -ForegroundColor Yellow
            }
            
            foreach ($entry in $items) {
                $index = $entry.Index
                $item = $entry.Item
                $date = Format-DateTime $item.DateTime
                Write-Host "  #$index  $date  $($item.FromAddress)" `
                    -ForegroundColor Cyan
                Write-Host "  Subject: $($item.Subject)" `
                    -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmMsg = if ($items.Count -eq 1) { 
                "Confirm restore" 
            } else { 
                "Confirm restore all" 
            }
            
            if (Confirm-Action $confirmMsg) {
                $successCount = 0
                $restoredIds = @()
                foreach ($entry in $items) {
                    $item = $entry.Item
                    if (Move-Message `
                        -MessageId $item.Id `
                        -DestinationFolderId $Config.Folders.Inbox) {
                        $successCount++
                        $restoredIds += $item.Id
                    }
                }
                
                Write-Success "$successCount message(s) restored to Inbox"
                
                if ($restoredIds.Count -gt 0) {
                    # Refresh list without reloading (preserves NextLink for filters)
                    Invoke-RefreshMessageList -DeletedMessageIds $restoredIds
                } else {
                    # Show current list even if no messages were restored
                    Show-CurrentView
                    Show-MessageList
                }
            } else {
                # Action cancelled - still show the list
                Show-CurrentView
                Show-MessageList
            }
        }
        "PURGE" {
            # Hard delete from deleted items
            if ($view -ne "deleteditems") {
                Write-Error-Message "PURGE only available in Deleted"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: PURGE <#>, PURGE <#-#>, or PURGE <#,#,#>"
                continue
            }
            
            # Parse argument - could be single number or range
            $indices = Parse-IndexRange $arg
            
            if (-not $indices) {
                Write-Error-Message "Invalid index or range: $arg"
                continue
            }
            
            # Validate all indices
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
                continue
            }
            
            # Show message details before purge
            Write-Host ""
            if ($items.Count -eq 1) {
                Write-Host "Permanently delete this message?" `
                    -ForegroundColor Red
            } else {
                Write-Host "Permanently delete these $($items.Count) messages?" `
                    -ForegroundColor Red
            }
            
            foreach ($entry in $items) {
                $index = $entry.Index
                $item = $entry.Item
                $date = Format-DateTime $item.DateTime
                Write-Host "  #$index  $date  $($item.FromAddress)" `
                    -ForegroundColor Cyan
                Write-Host "  Subject: $($item.Subject)" `
                    -ForegroundColor Cyan
            }
            Write-Host ""
            
            $confirmMsg = if ($items.Count -eq 1) { 
                "Confirm permanent delete" 
            } else { 
                "Confirm permanent delete all" 
            }
            
            if (Confirm-Action $confirmMsg) {
                $successCount = 0
                $purgedIds = @()
                foreach ($entry in $items) {
                    $item = $entry.Item
                    if (Remove-Message -MessageId $item.Id) {
                        $successCount++
                        $purgedIds += $item.Id
                    }
                }
                
                Write-Success "$successCount message(s) deleted permanently"
                
                if ($purgedIds.Count -gt 0) {
                    # Refresh list without reloading (preserves NextLink for filters)
                    Invoke-RefreshMessageList -DeletedMessageIds $purgedIds
                } else {
                    # Show current list even if no messages were purged
                    Show-CurrentView
                    Show-MessageList
                }
            } else {
                # Action cancelled - still show the list
                Show-CurrentView
                Show-MessageList
            }
        }
        "NEW" {
            # New draft
            if ($view -ne "drafts") {
                Write-Error-Message "NEW only available in Drafts"
                continue
            }
            Invoke-NewDraft
            Invoke-ListMessages
        }
        "E" {
            # Edit draft
            if ($view -ne "drafts") {
                Write-Error-Message "E only available in Drafts"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: E <number>"
                continue
            }
            $index = [int]$arg
            Invoke-EditDraft -Index $index
        }
        "SEND" {
            # Send draft
            if ($view -ne "drafts") {
                Write-Error-Message "SEND only available in Drafts"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: SEND <number>"
                continue
            }
            $index = [int]$arg
            Invoke-SendDraft -Index $index
        }
        "REDRAFT" {
            # Redraft from sent items
            if ($view -ne "sentitems") {
                Write-Error-Message "REDRAFT only available in Sent"
                continue
            }
            if (-not $arg) {
                Write-Error-Message "Usage: REDRAFT <number>"
                continue
            }
            $index = [int]$arg
            Invoke-RedraftMessage -Index $index
        }
        "SAVE" {
            # Save attachment
            if (-not $arg) {
                Write-Error-Message "Usage: SAVE <number>"
                continue
            }
            $index = [int]$arg
            Invoke-SaveAttachment -AttachmentIndex $index
        }
        "SAVEALL" {
            # Save all attachments
            Invoke-SaveAllAttachments
        }
        "ATT" {
            # List attachments
            Show-Attachments
        }
        "REPLY" {
            # Reply to current message
            Invoke-ReplyMessage -ReplyAll $false
        }
        "REPLYALL" {
            # Reply to all recipients
            Invoke-ReplyMessage -ReplyAll $true
        }
        "FORWARD" {
            # Forward current message
            Invoke-ForwardMessage
        }
        "CONTACTS" {
            # Search contacts
            Invoke-ContactSearch
        }
        "FILTER" {
            # Set filter for current folder
            if (-not $arg) {
                Write-Error-Message "Usage: FILTER <search text>"
                continue
            }
            
            # Check if replacing existing filter
            $currentFilter = Get-Filter
            if ($currentFilter) {
                Write-Info "Replacing filter '$currentFilter' " +
                    "with '$arg'"
            }
            
            # Set new filter (this resets items automatically)
            Set-Filter -FilterText $arg
            Write-Success "Filter set: '$arg'"
            Invoke-ListMessages
        }
        "CLEAR" {
            # Clear active filter
            $currentFilter = Get-Filter
            if (-not $currentFilter) {
                Write-Info "No filter is active"
                continue
            }
            Clear-Filter
            Write-Success "Filter cleared"
            Invoke-ListMessages
        }
        default {
            Write-Error-Message "Unknown command: $command"
        }
    }
}
