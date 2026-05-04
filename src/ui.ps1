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
    # Index: dynamic width based on highest loaded list index + trailing space
    # Unread: "* " = 2 chars
    # S/MIME (inbox only): "✔ " = 2 chars
    # Attachment: "*  " = 3 chars
    # Date: "yyyy-MM-dd HH:mm  " = 18 chars
    # From/To: "{0,-18} " = 19 chars
    # Spacing and margins: ~5 chars

    $maxIndex = 99
    if ($global:State -and $global:State.Items -and $global:State.Items.Count -gt 0) {
        $maxItemIndex = ($global:State.Items | Measure-Object -Property Index -Maximum).Maximum
        if ($null -ne $maxItemIndex) {
            $maxIndex = [Math]::Max($maxIndex, [int]$maxItemIndex)
        }
    }

    $indexDigits    = [Math]::Max(2, ([string]$maxIndex).Length)
    $indexWidth     = $indexDigits + 1
    $unreadWidth    = 2
    $encryptedWidth = 2   # E column (inbox only)
    $smimeWidth     = 2   # S column (inbox only)
    $attachWidth    = 3
    $dateWidth      = 18
    $addressWidth   = 19
    $spacing        = 5
    
    # Calculate fixed width (everything except subject)
    $fixedWidth = $indexWidth + $unreadWidth + $attachWidth + $dateWidth + $addressWidth + $spacing
    
    # Add E (encrypted) and S (signing) columns for inbox
    if ($View -eq "inbox") {
        $fixedWidth += $encryptedWidth + $smimeWidth
    }
    
    # Subject gets remaining space (minimum 30 chars)
    $subjectWidth = [Math]::Max(30, $consoleWidth - $fixedWidth)
    
    # Address display width (for truncation) is addressWidth minus formatting
    $addressDisplayWidth = 18
    
    return @{
        Index   = $indexDigits
        Subject = $subjectWidth
        Address = $addressDisplayWidth
    }
}

function Render-MessageListHeader {
    <#
    .SYNOPSIS
    Render the column header for message list
    #>
    param(
        [string]$View,
        [hashtable]$ColumnWidths
    )

    $indexHeader = "#".PadRight($ColumnWidths.Index + 1)

    if ($View -eq "inbox") {
        Write-Host "$indexHeader" -NoNewline
        Write-Host "U E S A  Date              From               " `
            -NoNewline
        Write-Host "Subject" -ForegroundColor $Config.Colors.SubjectHeader
    } else {
        Write-Host "$indexHeader" -NoNewline
        Write-Host "U A  Date              " `
            -NoNewline
        
        if ($View -eq "sentitems" -or $View -eq "drafts") {
            Write-Host "To                 " -NoNewline
        } else {
            Write-Host "From               " -NoNewline
        }
        
        Write-Host "Subject" -ForegroundColor $Config.Colors.SubjectHeader
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
    $indexText = ([string]$Item.Index).PadRight($ColumnWidths.Index + 1)
    Write-Host $indexText -NoNewline
    Write-Host "$unreadIcon " -NoNewline
    
    # E (encrypted) and S (signing) icons - inbox only
    if ($View -eq "inbox") {
        $encIcon   = if ($Item.IsEncrypted -or
            $Item.SmimeStatus -eq $Config.SmimeStatus.Encrypted) {
            "E"
        } else {
            " "
        }
        $smimeIcon = Get-SmimeIcon $Item.SmimeStatus
        Write-Host "$encIcon " -NoNewline
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
    $addr = Remove-TerminalControlSequences $addr
    $addrTrunc = Truncate-String $addr $ColumnWidths.Address
    Write-Host ("{0,-18} " -f $addrTrunc) -NoNewline
    
    # Subject
    $subject = Remove-TerminalControlSequences $Item.Subject
    $subject = Truncate-String $subject $ColumnWidths.Subject
    Write-Host $subject
}

function Get-ListLayoutInfo {
    <#
    .SYNOPSIS
    Return the exact line budget for the list viewport.
    #>

    $consoleHeight = $Host.UI.RawUI.WindowSize.Height
    if ($consoleHeight -le 0) { $consoleHeight = 30 }

    $filterLines = if ((Get-Filter) -or (Get-InboxClassification)) { 2 } else { 0 }

    $headerLines = 3      # Write-Header: blank + title + separator
    $listHeaderLines = 1  # "# U ..." header
    $paginationLines = 1  # fixed slot, with or without [M] message
    $menuLines = 8        # Show-Menu output
    $promptLines = 1      # Read-Command prompt

    $reservedLines = $headerLines + $filterLines + $listHeaderLines +
        $paginationLines + $menuLines + $promptLines
    $messageRows = $consoleHeight - $reservedLines
    if ($messageRows -lt $Config.MinPageSize) {
        $messageRows = $Config.MinPageSize
    }
    $messageRows = [Math]::Min($Config.MaxPageSize, $messageRows)

    return @{
        ConsoleHeight = $consoleHeight
        FilterLines   = $filterLines
        MessageRows   = $messageRows
    }
}

function Write-BlankListRows {
    param([int]$Count)

    for ($i = 0; $i -lt $Count; $i++) {
        Write-Host ""
    }
}

function Get-OptimalPageSize {
    <#
    .SYNOPSIS
    Calculate optimal page size based on console window height
    
    .DESCRIPTION
    Calculates how many message lines can fit on screen by subtracting
    all UI overhead (header, menu, pagination) from total console height.
    #>
    
    return (Get-ListLayoutInfo).MessageRows
}

function Show-Menu {
    <#
    .SYNOPSIS
    Display context-sensitive menu based on current view
    #>
    
    Write-Host ""
    Write-Host ("-" * 70) -ForegroundColor $Config.Colors.Separator
    
    $view = $global:State.View
    
    # View-specific commands
    switch ($view) {
        "inbox" {
            Write-Host "[L] List  [R #] Read  [X #/#-#] Delete  " `
                -NoNewline
            Write-Host "[K #/#-#] Junk" -ForegroundColor $Config.Colors.MenuAction
        }
        "drafts" {
            Write-Host "[L] List  [NEW] New  [E #] Edit  " `
                -NoNewline
            Write-Host "[SEND #] Send  [X #/#-#] Delete" `
                -ForegroundColor $Config.Colors.MenuAction
        }
        "sentitems" {
            Write-Host "[L] List  [R #] Read  [REDRAFT #]  " `
                -NoNewline
            Write-Host "[X #/#-#] Delete" -ForegroundColor $Config.Colors.MenuAction
        }
        "deleteditems" {
            Write-Host "[L] List  [R #] Read  [RESTORE #/#-#]  " `
                -NoNewline
            Write-Host "[PURGE #/#-#]" -ForegroundColor $Config.Colors.MenuAction
        }
        "junkemail" {
            Write-Host "[L] List  [R #] Read  [INBOX #/#-#]  " `
                -NoNewline
            Write-Host "[X #/#-#] Delete" -ForegroundColor $Config.Colors.MenuAction
        }
    }
    
    # Global commands
    Write-Host "[I] Inbox  [F] Relevant  [O] Sonstige  [A] Alle  " `
        -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[D] Drafts  [S] Sent  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[G] Deleted  [J] Junk" `
        -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[FILTER <text>] Filter messages  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[CLEAR] Clear filter" `
        -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[CONTACTS] Search contacts  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[SMIME] S/MIME certs  " `
        -NoNewline -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host "[LOGOUT] Logout  [Q] Quit" `
        -ForegroundColor $Config.Colors.MenuGlobal
    Write-Host ""
}

function Read-Command {
    <#
    .SYNOPSIS
    Read and parse user command
    #>
    
    Write-Host "> " -NoNewline -ForegroundColor $Config.Colors.Prompt
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
    param(
        [int]$StartIndex = 0
    )
    
    $layout = Get-ListLayoutInfo

    # Show active filter if present
    $filterText = Get-Filter
    $inboxClass = Get-InboxClassification
    if ($filterText -or $inboxClass) {
        $indicators = @()
        if ($inboxClass) {
            $label = if ($inboxClass -eq "focused") { "Relevant" } else { "Sonstige" }
            $indicators += "Inbox: $label"
        }
        if ($filterText) {
            $indicators += "Filter active: '$filterText'"
        }
        Write-Host ("[{0}]" -f ($indicators -join " | ")) -ForegroundColor $Config.Colors.FilterActive
        Write-Host ""
    }

    $view = $global:State.View
    $columnWidths = Get-ColumnWidths -View $view
    
    # Header line
    Render-MessageListHeader -View $view -ColumnWidths $columnWidths

    if ($StartIndex -lt 0) {
        $StartIndex = 0
    }

    $displayItems = @($global:State.Items |
        Select-Object -Skip $StartIndex -First $layout.MessageRows)
    foreach ($item in $displayItems) {
        Render-MessageRow -Item $item -View $view -ColumnWidths $columnWidths
    }

    if ($displayItems.Count -eq 0) {
        $emptyMessage = if ($filterText -and $inboxClass) {
            "No $inboxClass inbox messages match filter '$filterText'."
        } elseif ($filterText) {
            "No messages match filter '$filterText'."
        } elseif ($inboxClass) {
            "No $inboxClass inbox messages."
        } else {
            "No messages."
        }
        Write-Host $emptyMessage -ForegroundColor $Config.Colors.NoMessages
        Write-BlankListRows -Count ($layout.MessageRows - 1)
    } elseif ($displayItems.Count -lt $layout.MessageRows) {
        Write-BlankListRows -Count ($layout.MessageRows - $displayItems.Count)
    }

    # Fixed pagination/status slot to keep the layout height stable
    if ($global:State.StatusMessage) {
        $statusColor = if ($global:State.StatusColor) {
            $global:State.StatusColor
        } else {
            "Info"
        }
        Write-Host $global:State.StatusMessage `
            -ForegroundColor $Config.Colors.$statusColor
        Clear-StatusMessage
    } elseif ($global:State.NextLink) {
        Write-Host "[M] More messages available" `
            -ForegroundColor $Config.Colors.Info
    } else {
        Write-Host ""
    }
}

function Confirm-Action {
    param([string]$Message)
    
    Write-Host "$Message (y/n): " `
        -NoNewline -ForegroundColor $Config.Colors.ConfirmWarning
    $response = Read-Host
    
    return ($response -eq "y" -or $response -eq "Y")
}
