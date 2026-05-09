# psmail.ps1
# PowerShell Console Mail Client for Outlook.com
#Requires -Version 7.0

<#
.SYNOPSIS
psmail - Console email client for Outlook.com using Microsoft Graph

.DESCRIPTION
Draft-first email workflow with nvim integration and S/MIME support

.PARAMETER Version
Display version information and exit

.NOTES
Requires PowerShell 7+
#>

param(
    [switch]$Version
)

$ErrorActionPreference = "Stop"

# Load System.Web for URL decoding
# (required for SafeLink unwrapping)
Add-Type -AssemblyName System.Web

# Get script root
$ScriptRoot = $PSScriptRoot

# Dot-source all modules
. "$ScriptRoot\src\config.ps1"

# Handle -Version flag
if ($Version) {
    Write-Host ""
    Write-Host "psmail v$($Config.Version)" -ForegroundColor $Config.Colors.Header
    Write-Host "PowerShell Console Mail Client for Outlook.com" -ForegroundColor $Config.Colors.Info
    Write-Host $Config.GitHubUrl -ForegroundColor $Config.Colors.Info
    Write-Host ""
    exit 0
}
. "$ScriptRoot\src\util.ps1"
. "$ScriptRoot\src\state.ps1"
. "$ScriptRoot\src\auth.ps1"
. "$ScriptRoot\src\graph.ps1"
. "$ScriptRoot\src\message_operations.ps1"
. "$ScriptRoot\src\ui.ps1"
. "$ScriptRoot\src\mail_list.ps1"
. "$ScriptRoot\src\mail_read.ps1"
. "$ScriptRoot\src\drafts.ps1"
. "$ScriptRoot\src\editor.ps1"
. "$ScriptRoot\src\attachments.ps1"
. "$ScriptRoot\src\smime.ps1"
. "$ScriptRoot\src\contacts.ps1"

# Connect to Graph
Write-Host ""
Write-Host "=== psmail - PowerShell Mail Client ===" `
    -ForegroundColor $Config.Colors.Header
Write-Host ""

if (-not (Connect-GraphMail)) {
    Write-Error-Message "Failed to connect. Exiting."
    exit 1
}

# Initialize state after login so local cache/draft files are account-specific
Initialize-State

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
            Clear-InboxClassification
            Switch-ToFolder $Config.Folders.Inbox
            $handled = $true
        }
        "F" {
            Set-InboxClassification -Classification "focused"
            Switch-ToFolder $Config.Folders.Inbox
            $handled = $true
        }
        "O" {
            Set-InboxClassification -Classification "other"
            Switch-ToFolder $Config.Folders.Inbox
            $handled = $true
        }
        "A" {
            Clear-InboxClassification
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
            Disconnect-GraphMail
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
            
            Invoke-BulkMessageOperation `
                -Argument $arg `
                -Command "X" `
                -OperationType "Move" `
                -PromptMessage "Delete" `
                -ConfirmMessage "Confirm delete" `
                -SuccessMessage "{0} message(s) moved to Deleted" `
                -DestinationFolderId $Config.Folders.Deleted `
                -ConfirmColor "ConfirmWarning" `
                -ShowCancelledList $true
        }
        "K" {
            # Move to Junk (from inbox)
            if ($view -ne "inbox") {
                Write-Error-Message "K command only available in Inbox"
                continue
            }
            
            Invoke-BulkMessageOperation `
                -Argument $arg `
                -Command "K" `
                -OperationType "Move" `
                -PromptMessage "Move to Junk" `
                -ConfirmMessage "Confirm move to Junk" `
                -SuccessMessage "{0} message(s) moved to Junk" `
                -DestinationFolderId $Config.Folders.Junk `
                -ConfirmColor "ConfirmWarning" `
                -ShowCancelledList $false
        }
        "INBOX" {
            # Move to Inbox (from junk)
            if ($view -ne "junkemail") {
                Write-Error-Message "INBOX command only available in Junk"
                continue
            }
            
            Invoke-BulkMessageOperation `
                -Argument $arg `
                -Command "INBOX" `
                -OperationType "Move" `
                -PromptMessage "Move to Inbox" `
                -ConfirmMessage "Confirm move to Inbox" `
                -SuccessMessage "{0} message(s) moved to Inbox" `
                -DestinationFolderId $Config.Folders.Inbox `
                -ConfirmColor "ConfirmWarning" `
                -ShowCancelledList $false
        }
        "RESTORE" {
            # Restore from deleted
            if ($view -ne "deleteditems") {
                Write-Error-Message "RESTORE only available in Deleted"
                continue
            }
            
            Invoke-BulkMessageOperation `
                -Argument $arg `
                -Command "RESTORE" `
                -OperationType "Move" `
                -PromptMessage "Restore to Inbox" `
                -ConfirmMessage "Confirm restore" `
                -SuccessMessage "{0} message(s) restored to Inbox" `
                -DestinationFolderId $Config.Folders.Inbox `
                -ConfirmColor "ConfirmWarning" `
                -ShowCancelledList $true
        }
        "PURGE" {
            # Hard delete from deleted items
            if ($view -ne "deleteditems") {
                Write-Error-Message "PURGE only available in Deleted"
                continue
            }
            
            Invoke-BulkMessageOperation `
                -Argument $arg `
                -Command "PURGE" `
                -OperationType "Delete" `
                -PromptMessage "Permanently delete" `
                -ConfirmMessage "Confirm permanent delete" `
                -SuccessMessage "{0} message(s) deleted permanently" `
                -ConfirmColor "ConfirmDanger" `
                -ShowCancelledList $true
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
        "SMIME" {
            # Show available S/MIME certificates
            Show-SmimeCertificates
        }
        "FOCUS" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "focused"
        }
        "RELEVANT" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "focused"
        }
        "OTHER" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "other"
        }
        "SONSTIGE" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "other"
        }
        "FOCUS!" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "focused" `
                -Always
        }
        "RELEVANT!" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "focused" `
                -Always
        }
        "OTHER!" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "other" `
                -Always
        }
        "SONSTIGE!" {
            Invoke-InboxClassificationOperation `
                -Argument $arg `
                -Classification "other" `
                -Always
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
                Set-StatusMessage -Message ("Filter changed: '{0}' -> '{1}'" -f $currentFilter, $arg) -Color "Success"
            } else {
                Set-StatusMessage -Message "Filter set: '$arg'" -Color "Success"
            }
            
            # Set new filter (this resets items automatically)
            Set-Filter -FilterText $arg
            Invoke-ListMessages
        }
        "CLEAR" {
            # Clear active filter
            $currentFilter = Get-Filter
            if (-not $currentFilter) {
                Set-StatusMessage -Message "No filter is active" -Color "Info"
                Show-CurrentView
                Show-MessageList
                continue
            }
            Clear-Filter
            Set-StatusMessage -Message "Filter cleared" -Color "Success"
            Invoke-ListMessages
        }
        default {
            Write-Error-Message "Unknown command: $command"
        }
    }
}
