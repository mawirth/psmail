# state.ps1
# Global state management

function Test-PersistableSmimeStatus {
    param(
        [string]$Status,
        [bool]$IsEncrypted = $false
    )

    return ($IsEncrypted -or
            $Status -eq $Config.SmimeStatus.SignedTrusted -or
            $Status -eq $Config.SmimeStatus.SignedUntrusted -or
            $Status -eq $Config.SmimeStatus.SignedInvalid)
}

function Initialize-State {
    # Load persisted S/MIME draft flags (survives session restarts)
    $smimeDrafts = @{}
    if (Test-Path $Config.SmimeDraftsPath) {
        try {
            $json   = Get-Content $Config.SmimeDraftsPath -Raw -ErrorAction Stop
            $loaded = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($loaded) { $smimeDrafts = $loaded }
        } catch { }
    }

    # Load persisted S/MIME status cache so E/S list indicators survive restarts
    $smimeCache = @{}
    $smimeCacheNeedsCleanup = $false
    if (Test-Path $Config.SmimeCachePath) {
        try {
            $json   = Get-Content $Config.SmimeCachePath -Raw -ErrorAction Stop
            $loaded = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($loaded) {
                foreach ($id in $loaded.Keys) {
                    $e = $loaded[$id]
                    if (-not (Test-PersistableSmimeStatus $e.Status ([bool]$e.IsEncrypted))) {
                        $smimeCacheNeedsCleanup = $true
                        continue
                    }
                    $smimeCache[$id] = @{
                        Status     = $e.Status
                        IsEncrypted = [bool]$e.IsEncrypted
                        Subject    = $e.Subject    ?? ""
                        Issuer     = $e.Issuer     ?? ""
                        ValidUntil = $e.ValidUntil ?? ""
                        Error      = $e.Error      ?? ""
                        HasUserAttachments = $e.HasUserAttachments
                        Body       = $null
                    }
                }
            }
        } catch { }
    }

    $global:State = @{
        View           = $Config.Folders.Inbox
        Items          = @()
        NextLink       = $null
        PrevLinks      = @()
        LastQuery      = $null
        OpenMessageId  = $null
        Filter         = $null
        StatusMessage  = $null
        StatusColor    = $null
        # S/MIME: per-draft flags, keyed by message ID.
        # Persisted to SmimeDraftsPath so flags survive session restarts.
        SmimeDrafts    = $smimeDrafts
        # S/MIME: verification result cache - persisted to SmimeCachePath.
        SmimeCache     = $smimeCache
    }

    if ($smimeCacheNeedsCleanup) {
        Save-SmimeCache
    }
}

function Save-SmimeCache {
    <#
    .SYNOPSIS
    Persist the in-memory SmimeCache (Status/cert info per message ID).
    Body is excluded to keep the file small.
    #>
    try {
        $toSave = @{}
        foreach ($id in $global:State.SmimeCache.Keys) {
            $e = $global:State.SmimeCache[$id]
            if (-not (Test-PersistableSmimeStatus $e.Status ([bool]$e.IsEncrypted))) {
                continue
            }
            $toSave[$id] = @{
                Status     = $e.Status
                IsEncrypted = [bool]$e.IsEncrypted
                Subject    = if ($e.Subject)    { $e.Subject    } else { "" }
                Issuer     = if ($e.Issuer)     { $e.Issuer     } else { "" }
                ValidUntil = if ($e.ValidUntil) { $e.ValidUntil } else { "" }
                Error      = if ($e.Error)      { $e.Error      } else { "" }
                HasUserAttachments = if ($null -ne $e.HasUserAttachments) {
                    [bool]$e.HasUserAttachments
                } else {
                    $null
                }
            }
        }
        $toSave | ConvertTo-Json -Depth 3 |
            Set-Content $Config.SmimeCachePath -Encoding UTF8 -ErrorAction Stop
    } catch { }
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

function Set-StatusMessage {
    param(
        [string]$Message,
        [string]$Color = "Info"
    )

    $global:State.StatusMessage = $Message
    $global:State.StatusColor = $Color
}

function Clear-StatusMessage {
    $global:State.StatusMessage = $null
    $global:State.StatusColor = $null
}
