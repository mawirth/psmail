# ui.ps1
# Menu rendering and input

function Get-ColumnWidths {
    <#
    .SYNOPSIS
    Calculate column widths for message list display
    Returns hashtable with column widths based on current view
    #>
    param([string]$View)
    
    # Get console width
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    if ($consoleWidth -le 0) { $consoleWidth = 80 }
    
    # Column widths (derived from actual column headers and formatting)
    # Index: "{0,-2} " = 3 chars
    # Unread: "* " = 2 chars
    # S/MIME (inbox only): "✔ " = 2 chars
    # Attachment: "*  " = 3 chars
    # Date: "yyyy-MM-dd HH:mm  " = 18 chars
    # From/To: "{0,-18} " = 19 chars
    # Spacing and margins: ~5 chars
    
    $indexWidth = 3
    $unreadWidth = 2
    $smimeWidth = 2
    $attachWidth = 3
    $dateWidth = 18
    $addressWidth = 19
    $spacing = 5
    
    # Calculate fixed width (everything except subject)
    $fixedWidth = $indexWidth + $unreadWidth + $attachWidth + $dateWidth + $addressWidth + $spacing
    
    # Add S/MIME column for inbox
    if ($View -eq "inbox") {
        $fixedWidth += $smimeWidth
    }
    
    # Subject gets remaining space (minimum 30 chars)
    $subjectWidth = [Math]::Max(30, $consoleWidth - $fixedWidth)
    
    # Address display width (for truncation) is addressWidth minus formatting
    $addressDisplayWidth = 18
    
    return @{
        Subject = $subjectWidth
        Address = $addressDisplayWidth
    }
}

function Render-MessageListHeader {
    <#
    .SYNOPSIS
    Render the column header for message list
    #>
    param([string]$View)
    
    if ($View -eq "inbox") {
        Write-Host "#  U S A  Date              From               " `
            -NoNewline
        Write-Host "Subject" -ForegroundColor DarkGray
    } else {
        Write-Host "#  U A  Date              " `
            -NoNewline
        
        if ($View -eq "sentitems" -or $View -eq "drafts") {
            Write-Host "To                 " -NoNewline
        } else {
            Write-Host "From               " -NoNewline
        }
        
        Write-Host "Subject" -ForegroundColor DarkGray
    }
}

function Render-MessageRow {
    <#
    .SYNOPSIS
    Render a single message row in the list
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Item,
        
        [Parameter(Mandatory)]
        [string]$View,
        
        [Parameter(Mandatory)]
        [hashtable]$ColumnWidths
    )
    
    $isUnread = -not $Item.IsRead
    $unreadIcon = Get-UnreadIcon $isUnread
    $date = Format-DateTime $Item.DateTime
    
    # Index and unread
    Write-Host ("{0,-2} " -f $Item.Index) -NoNewline
    Write-Host "$unreadIcon " -NoNewline
    
    # S/MIME icon (inbox only)
    if ($View -eq "inbox") {
        $smimeIcon = Get-SmimeIcon $Item.SmimeStatus
        Write-Host "$smimeIcon " -NoNewline
    }
    
    # Attachment indicator
    $attachIcon = if ($Item.HasAttachments) { "*" } else { " " }
    Write-Host "$attachIcon  " -NoNewline
    
    # Date
    Write-Host "$date  " -NoNewline
    
    # From/To
    $addr = if ($View -eq "sentitems" -or $View -eq "drafts") { 
        $Item.ToAddress 
    } else { 
        $Item.FromAddress 
    }
    $addrTrunc = Truncate-String $addr $ColumnWidths.Address
    Write-Host ("{0,-18} " -f $addrTrunc) -NoNewline
    
    # Subject
    $subject = Truncate-String $Item.Subject $ColumnWidths.Subject
    Write-Host $subject
}

function Get-OptimalPageSize {
    <#
    .SYNOPSIS
    Calculate optimal page size based on console window height
    
    .DESCRIPTION
    Calculates how many message lines can fit on screen by subtracting
    all UI overhead (header, menu, pagination) from total console height.
    #>
    
    # Get console height
    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    if ($consoleHeight -le 0) { $consoleHeight = 30 }
    
    # Count reserved lines (all non-message UI elements):
    # 
    # Header section:
    #   - 1 blank line at top
    #   - 1 folder title line (e.g., "Inbox")
    #   - 1 separator line (dashes)
    #   - 1 column header line ("#  U S A  Date...")
    # = 4 lines
    # 
    # Footer/Menu section:
    #   - 1 blank line before menu
    #   - 1 separator line (dashes)
    #   - 1 view-specific menu line (e.g., "[L] List [R #] Read...")
    #   - 3 global menu lines (folders, filter/contacts, logout)
    #   - 1 blank line after menu
    #   - 1 prompt line ("> ")
    # = 8 lines
    # 
    # Optional elements (always reserve space):
    #   - 2 pagination lines (blank + "[M] More messages available")
    #   - 2 filter indicator lines ("[Filter active: '...']" + blank)
    # = 4 lines
    # 
    # Safety margin: 1 line
    # 
    # Total: 4 + 8 + 4 + 1 = 17 lines
    
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
    
    $view = $global:State.View
    $columnWidths = Get-ColumnWidths -View $view
    
    # Header line
    Render-MessageListHeader -View $view
    
    # Message rows
    foreach ($item in $global:State.Items) {
        Render-MessageRow -Item $item -View $view -ColumnWidths $columnWidths
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
