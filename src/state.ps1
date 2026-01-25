# state.ps1
# Global state management

function Initialize-State {
    $global:State = @{
        View           = $Config.Folders.Inbox
        Items          = @()
        NextLink       = $null
        PrevLinks      = @()
        LastQuery      = $null
        OpenMessageId  = $null
        Filter         = $null
    }
}

function Reset-StateItems {
    $global:State.Items = @()
    $global:State.NextLink = $null
    $global:State.PrevLinks = @()
}

function Add-StateItem {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Item
    )
    $global:State.Items += $Item
}

function Get-StateItem {
    param([int]$Index)
    
    if ($Index -lt 1 -or $Index -gt $global:State.Items.Count) {
        return $null
    }
    return $global:State.Items[$Index - 1]
}

function Remove-StateItems {
    <#
    .SYNOPSIS
    Remove items from state by their IDs and re-index remaining items
    #>
    param(
        [Parameter(Mandatory)]
        [array]$MessageIds
    )
    
    if ($MessageIds.Count -eq 0) {
        return
    }
    
    # Filter out items with matching IDs
    $remainingItems = @($global:State.Items | Where-Object { 
        $MessageIds -notcontains $_.Id 
    })
    
    # Re-index remaining items
    $index = 1
    foreach ($item in $remainingItems) {
        $item.Index = $index
        $index++
    }
    
    # Update state
    $global:State.Items = $remainingItems
}

function Set-View {
    param([string]$FolderId)
    
    $global:State.View = $FolderId
    # Filter bleibt beim Ordnerwechsel erhalten
    # Nur Reset-StateItems aufrufen, um die Nachrichtenliste zu leeren
    Reset-StateItems
}

function Set-Filter {
    param([string]$FilterText)
    
    $global:State.Filter = $FilterText
    # Reset items and NextLink when filter changes
    # to prevent mixing old and new filter results
    Reset-StateItems
}

function Clear-Filter {
    $global:State.Filter = $null
    # Reset items and NextLink when clearing filter
    # to prevent mixing filtered and unfiltered results
    Reset-StateItems
}

function Get-Filter {
    return $global:State.Filter
}
