# ui.ps1
# Menu rendering and input

function Get-OptimalPageSize {
    <#
    .SYNOPSIS
    Calculate optimal page size based on console window height
    #>
    
    # Get console height
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    if ($consoleHeight -le 0) { $consoleHeight = 30 }
    
    # Reserve lines for:
    # - Header (4 lines: 2 blank lines, title, separator line)
    # - Column header (1 line: "#  U S A  Date...")
    # - Menu section (7 lines: blank, separator, 4 menu lines, prompt)
    # - Pagination info (2 lines if present: blank, "[M]...")
    # - Filter indicator (2 lines if active: "[Filter...]", blank)
    # - Safety margin (1 line)
    $reservedLines = 17
    
    # Calculate available lines for messages
    $availableLines = $consoleHeight - $reservedLines
    
    # Ensure minimum and maximum bounds
    $pageSize = [Math]::Max($Config.MinPageSize, $availableLines)
    $pageSize = [Math]::Min($Config.MaxPageSize, $pageSize)
    
    return $pageSize
}

function Show-Menu {
    <#
    .SYNOPSIS
    Display context-sensitive menu based on current view
    #>
    
    Write-Host ""
    Write-Host ("-" * 70) -ForegroundColor DarkGray
    
    $view = $global:State.View
    
    # View-specific commands
    switch ($view) {
        "inbox" {
            Write-Host "[L] List  [R #] Read  [X #/#-#] Delete  " `
                -NoNewline
            Write-Host "[K #/#-#] Junk" -ForegroundColor Yellow
        }
        "drafts" {
            Write-Host "[L] List  [NEW] New  [E #] Edit  " `
                -NoNewline
            Write-Host "[SEND #] Send  [X #/#-#] Delete" `
                -ForegroundColor Yellow
        }
        "sentitems" {
            Write-Host "[L] List  [R #] Read  [REDRAFT #]  " `
                -NoNewline
            Write-Host "[X #/#-#] Delete" -ForegroundColor Yellow
        }
        "deleteditems" {
            Write-Host "[L] List  [R #] Read  [RESTORE #/#-#]  " `
                -NoNewline
            Write-Host "[PURGE #/#-#]" -ForegroundColor Yellow
        }
        "junkemail" {
            Write-Host "[L] List  [R #] Read  [INBOX #/#-#]  " `
                -NoNewline
            Write-Host "[X #/#-#] Delete" -ForegroundColor Yellow
        }
    }
    
    # Global commands
    Write-Host "[I] Inbox  [D] Drafts  [S] Sent  " `
        -NoNewline -ForegroundColor DarkGray
    Write-Host "[G] Deleted  [J] Junk" `
        -ForegroundColor DarkGray
    Write-Host "[FILTER <text>] Filter messages  " `
        -NoNewline -ForegroundColor DarkGray
    Write-Host "[CLEAR] Clear filter" `
        -ForegroundColor DarkGray
    Write-Host "[CONTACTS] Search contacts  " `
        -NoNewline -ForegroundColor DarkGray
    Write-Host "[LOGOUT] Logout  [Q] Quit" `
        -ForegroundColor DarkGray
    Write-Host ""
}

function Read-Command {
    <#
    .SYNOPSIS
    Read and parse user command
    #>
    
    Write-Host "> " -NoNewline -ForegroundColor Green
    $input = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($input)) {
        return $null
    }
    
    # Parse command and argument
    $parts = $input.Trim() -split '\s+', 2
    $cmd = $parts[0].ToUpper()
    $arg = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    
    return @{
        Command = $cmd
        Argument = $arg
    }
}

function Show-CurrentView {
    <#
    .SYNOPSIS
    Display current folder name
    #>
    
    $viewName = $Config.FolderNames[$global:State.View]
    Write-Header $viewName
}

function Show-MessageList {
    <#
    .SYNOPSIS
    Display message list with formatting
    #>
    
    # Show active filter if present
    $filterText = Get-Filter
    if ($filterText) {
        Write-Host "[Filter active: '$filterText']" -ForegroundColor Yellow
        Write-Host ""
    }
    
    if ($global:State.Items.Count -eq 0) {
        Write-Host "No messages." -ForegroundColor DarkGray
        return
    }
    
    # Get console width
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    if ($consoleWidth -le 0) { $consoleWidth = 80 }
    
    $view = $global:State.View
    
    # Calculate dynamic widths based on console width
    # Fixed columns: Index(3) Unread(2) Date(18)
    # Inbox adds: Smime(3)
    # From/To: 20 chars minimum
    # Subject: Rest of space
    
    $fixedWidth = if ($view -eq "inbox") { 26 + 20 } else { 23 + 20 }
    $subjectWidth = [Math]::Max(30, $consoleWidth - $fixedWidth - 5)
    
    # Header line
    if ($view -eq "inbox") {
        Write-Host "#  U S A  Date              From               " `
            -NoNewline
        Write-Host "Subject" -ForegroundColor DarkGray
    } else {
        Write-Host "#  U A  Date              " `
            -NoNewline
        
        if ($view -eq "sentitems" -or $view -eq "drafts") {
            Write-Host "To                 " -NoNewline
        } else {
            Write-Host "From               " -NoNewline
        }
        
        Write-Host "Subject" -ForegroundColor DarkGray
    }
    
    # Message rows
    foreach ($item in $global:State.Items) {
        $index = $item.Index
        $isUnread = -not $item.IsRead
        $unreadIcon = Get-UnreadIcon $isUnread
        $date = Format-DateTime $item.DateTime
        
        # Index and unread
        Write-Host ("{0,-2} " -f $index) -NoNewline
        Write-Host "$unreadIcon " -NoNewline
        
        # S/MIME icon (inbox only)
        if ($view -eq "inbox") {
            $smimeIcon = Get-SmimeIcon $item.SmimeStatus
            Write-Host "$smimeIcon " -NoNewline
        }
        
        # Attachment indicator
        $attachIcon = if ($item.HasAttachments) { "*" } else { " " }
        Write-Host "$attachIcon  " -NoNewline
        
        # Date
        Write-Host "$date  " -NoNewline
        
        # From/To
        $addr = if ($view -eq "sentitems" -or $view -eq "drafts") { 
            $item.ToAddress 
        } else { 
            $item.FromAddress 
        }
        $addrTrunc = Truncate-String $addr 18
        Write-Host ("{0,-18} " -f $addrTrunc) -NoNewline
        
        # Subject (use remaining width)
        $subject = Truncate-String $item.Subject $subjectWidth
        Write-Host $subject
    }
    
    # Pagination info
    if ($global:State.NextLink) {
        Write-Host ""
        Write-Host "[M] More messages available" `
            -ForegroundColor DarkGray
    }
}

function Confirm-Action {
    param([string]$Message)
    
    Write-Host "$Message (y/n): " `
        -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    
    return ($response -eq "y" -or $response -eq "Y")
}
