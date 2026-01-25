# contacts.ps1
# Contact directory search and management

function Invoke-ContactSearch {
    <#
    .SYNOPSIS
    Search contacts and copy selected email address
    #>
    
    Write-Host ""
    Write-Host "Fetching contacts..." -ForegroundColor $Config.Colors.LoadingMore
    
    # Fetch contacts from Graph
    $contacts = Get-GraphContacts
    
    if (-not $contacts -or $contacts.Count -eq 0) {
        Write-Error-Message "No contacts found"
        return
    }
    
    Write-Host "Found $($contacts.Count) contacts" -ForegroundColor $Config.Colors.Success
    Write-Host ""
    Write-Host "Enter search term (or press Enter to list all):" -ForegroundColor $Config.Colors.LoadingMore
    Write-Host "> " -NoNewline -ForegroundColor $Config.Colors.Prompt
    $searchTerm = Read-Host
    
    # Filter contacts
    if (-not [string]::IsNullOrWhiteSpace($searchTerm)) {
        $filtered = @($contacts | Where-Object {
            $displayName = if ($_ -is [hashtable]) {
                $_['displayName']
            } else {
                $_.displayName
            }
            $emailAddress = if ($_ -is [hashtable]) {
                $_['emailAddress']
            } else {
                $_.emailAddress
            }
            $displayName -like "*$searchTerm*" `
                -or $emailAddress -like "*$searchTerm*"
        })
    } else {
        $filtered = $contacts
    }
    
    if ($filtered.Count -eq 0) {
        Write-Host "No contacts match '$searchTerm'" -ForegroundColor $Config.Colors.Warning
        return
    }
    
    Write-Host ""
    Write-Host "Matching contacts:" -ForegroundColor $Config.Colors.LoadingMore
    Write-Host ""
    
    # Display contacts with index
    $index = 1
    foreach ($contact in $filtered) {
        # Access properties from hashtable
        if ($contact -is [hashtable]) {
            $displayName = $contact['displayName']
            $emailAddr = $contact['emailAddress']
        } else {
            $displayName = $contact.displayName
            $emailAddr = $contact.emailAddress
        }
        
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = "(No name)"
        }
        
        $formattedLine = "{0,3}. {1,-30} " `
            -f $index, $displayName
        Write-Host $formattedLine -NoNewline
        Write-Host $emailAddr -ForegroundColor $Config.Colors.Success
        $index++
    }
    
    Write-Host ""
    Write-Host "Enter number to copy (or Q to cancel): " `
        -NoNewline -ForegroundColor $Config.Colors.LoadingMore
    $selection = Read-Host
    
    if ($selection -eq "Q" -or $selection -eq "q") {
        Write-Info "Cancelled"
        return
    }
    
    # Parse selection
    try {
        $selectedIndex = [int]$selection
        if ($selectedIndex -lt 1 -or $selectedIndex -gt $filtered.Count) {
            Write-Error-Message "Invalid selection"
            return
        }
        
        $selectedContact = $filtered[$selectedIndex - 1]
        
        # Access emailAddress - could be hashtable or object
        if ($selectedContact -is [hashtable]) {
            $emailAddress = $selectedContact['emailAddress']
        } else {
            $emailAddress = $selectedContact.emailAddress
        }
        
        if ([string]::IsNullOrWhiteSpace($emailAddress)) {
            Write-Error-Message "No email address found for selected contact"
            return
        }
        
        # Copy to clipboard
        Set-Clipboard -Value $emailAddress
        
        Write-Success "Copied to clipboard: $emailAddress"
        
    } catch {
        Write-Error-Message "Invalid selection: $($_.Exception.Message)"
    }
}

function Get-GraphContacts {
    <#
    .SYNOPSIS
    Build contact list from email history
    #>
    
    Write-Host "Building contact list from recent emails..." -ForegroundColor $Config.Colors.Info
    
    try {
        # Collect unique email addresses from inbox and sent items
        $emailAddresses = @{}
        
        # Fetch from Inbox - only headers, minimal data
        # Using $select to fetch only the fields we need
        $inboxUri = "/v1.0/me/mailFolders/inbox/messages" +
            "?`$select=from,toRecipients" +
            "&`$top=100" +
            "&`$orderby=receivedDateTime desc"
        $inboxResponse = Invoke-GraphRequest -Method GET -Uri $inboxUri
        
        if ($inboxResponse -and $inboxResponse.value) {
            foreach ($msg in $inboxResponse.value) {
                # Add sender
                if ($msg.from -and $msg.from.emailAddress) {
                    $addr = $msg.from.emailAddress.address
                    $name = $msg.from.emailAddress.name
                    if ($addr -and -not $emailAddresses.ContainsKey($addr)) {
                        $emailAddresses[$addr] = $name
                    }
                }
                
                # Add recipients
                if ($msg.toRecipients) {
                    foreach ($recipient in $msg.toRecipients) {
                        $addr = $recipient.emailAddress.address
                        $name = $recipient.emailAddress.name
                        if ($addr `
                            -and -not $emailAddresses.ContainsKey($addr)) {
                            $emailAddresses[$addr] = $name
                        }
                    }
                }
            }
        }
        
        # Fetch from Sent Items - only recipient headers
        $sentUri = "/v1.0/me/mailFolders/sentitems/messages" +
            "?`$select=toRecipients" +
            "&`$top=100" +
            "&`$orderby=sentDateTime desc"
        $sentResponse = Invoke-GraphRequest -Method GET -Uri $sentUri
        
        if ($sentResponse -and $sentResponse.value) {
            foreach ($msg in $sentResponse.value) {
                if ($msg.toRecipients) {
                    foreach ($recipient in $msg.toRecipients) {
                        $addr = $recipient.emailAddress.address
                        $name = $recipient.emailAddress.name
                        if ($addr `
                            -and -not $emailAddresses.ContainsKey($addr)) {
                            $emailAddresses[$addr] = $name
                        }
                    }
                }
            }
        }
        
        # Convert to array and sort by name
        $contacts = @()
        foreach ($addr in $emailAddresses.Keys) {
            $contacts += @{
                displayName = $emailAddresses[$addr]
                emailAddress = $addr
            }
        }
        
        # Sort by display name
        $contacts = $contacts | Sort-Object { $_.displayName }
        
        return $contacts
        
    } catch {
        $errMsg = "Failed to build contact list: " +
            $_.Exception.Message
        Write-Error-Message $errMsg
        return @()
    }
}
