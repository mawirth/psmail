# accounts.ps1
# Account profile management for local state separation.

function Read-AccountProfiles {
    if (-not (Test-Path $Config.AccountProfilesPath)) {
        return @{}
    }

    try {
        $json = Get-Content $Config.AccountProfilesPath -Raw -ErrorAction Stop
        $profiles = $json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        return $profiles ?? @{}
    } catch {
        Write-Error-Message "Could not read account profiles: $($_.Exception.Message)"
        return @{}
    }
}

function Save-AccountProfiles {
    param([hashtable]$Profiles)

    try {
        if (-not (Test-Path $Config.DataRootPath)) {
            New-Item -ItemType Directory -Path $Config.DataRootPath -Force |
                Out-Null
        }
        $Profiles | ConvertTo-Json -Depth 4 |
            Set-Content $Config.AccountProfilesPath `
                -Encoding utf8NoBOM `
                -ErrorAction Stop
    } catch {
        Write-Error-Message "Could not save account profiles: $($_.Exception.Message)"
    }
}

function Register-CurrentAccountProfile {
    $account = $Config.CurrentAccount
    if (-not $account) {
        return $null
    }

    $profiles = Read-AccountProfiles
    $now = [DateTime]::Now.ToString("s")
    $existing = $profiles[$account.Key] ?? @{}

    $profiles[$account.Key] = @{
        Key          = $account.Key
        Email        = $account.Email
        TenantId     = $account.TenantId
        DisplayName  = $existing.DisplayName ?? $account.Email
        DataPath     = $account.DataPath
        LastUsed     = $now
        Created      = $existing.Created ?? $now
    }

    Save-AccountProfiles -Profiles $profiles
    return $profiles[$account.Key]
}

function Find-AccountProfile {
    param([string]$Selector)

    $profiles = Read-AccountProfiles
    if ([string]::IsNullOrWhiteSpace($Selector)) {
        return $null
    }

    $selectorLower = $Selector.Trim().ToLowerInvariant()
    foreach ($profile in $profiles.Values) {
        if ($profile.Key.ToLowerInvariant() -eq $selectorLower -or
            "$($profile.Email)".ToLowerInvariant() -eq $selectorLower -or
            "$($profile.DisplayName)".ToLowerInvariant() -eq $selectorLower) {
            return $profile
        }
    }

    return $null
}

function Show-AccountProfiles {
    $profiles = Read-AccountProfiles
    $currentKey = $Config.CurrentAccount?.Key

    Write-Header "Accounts"
    if ($profiles.Count -eq 0) {
        Write-Info "No saved account profiles yet. Use ACCOUNT ADD."
        return
    }

    foreach ($profile in ($profiles.Values | Sort-Object Email, TenantId)) {
        $marker = $profile.Key -eq $currentKey ? "*" : " "
        Write-Host ("{0} {1}" -f $marker, $profile.DisplayName) `
            -ForegroundColor $Config.Colors.Info
        Write-Host ("  Key:    {0}" -f $profile.Key)
        Write-Host ("  Email:  {0}" -f $profile.Email)
        Write-Host ("  Tenant: {0}" -f $profile.TenantId)
        Write-Host ("  Data:   {0}" -f $profile.DataPath)
    }
}

function Clear-DisconnectedSessionState {
    if (-not $global:State) {
        return
    }

    Reset-StateItems
    $global:State.OpenMessageId = $null
    $global:State.Filter = $null
    $global:State.InboxClass = "focused"
}

function Invoke-AccountAdd {
    Write-Info "Sign in with the account to add."
    Disconnect-GraphMail
    if (-not (Connect-GraphMail)) {
        Clear-DisconnectedSessionState
        Write-Error-Message "Account add failed."
        return
    }

    $profile = Register-CurrentAccountProfile
    Initialize-State
    Set-StatusMessage `
        -Message ("Account added: {0}" -f $profile.Email) `
        -Color "Success"
    Invoke-ListMessages
}

function Invoke-AccountSwitch {
    param([string]$Selector)

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        Write-Error-Message "Usage: ACCOUNT SWITCH <key|email|name>"
        return
    }

    $profile = Find-AccountProfile -Selector $Selector
    if (-not $profile) {
        Write-Error-Message "No account profile matches '$Selector'."
        return
    }

    Write-Info ("Switching to {0}. Sign in if prompted." -f $profile.Email)
    Disconnect-GraphMail

    $tenant = $profile.TenantId -eq "consumers" ? $null : $profile.TenantId
    if (-not (Connect-GraphMail -TenantId $tenant)) {
        Clear-DisconnectedSessionState
        Write-Error-Message "Account switch failed."
        return
    }

    $actual = Register-CurrentAccountProfile
    Initialize-State

    if ($actual.Key -ne $profile.Key) {
        Set-StatusMessage `
            -Message ("Connected as {0}, not requested {1}" -f `
                $actual.Email, $profile.Email) `
            -Color "Warning"
    } else {
        Set-StatusMessage `
            -Message ("Switched to {0}" -f $actual.Email) `
            -Color "Success"
    }
    Invoke-ListMessages
}

function Invoke-AccountRemove {
    param([string]$Selector)

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        Write-Error-Message "Usage: ACCOUNT REMOVE <key|email|name>"
        return
    }

    $profile = Find-AccountProfile -Selector $Selector
    if (-not $profile) {
        Write-Error-Message "No account profile matches '$Selector'."
        return
    }

    $profiles = Read-AccountProfiles
    $profiles.Remove($profile.Key)
    Save-AccountProfiles -Profiles $profiles
    Write-Success ("Removed local profile for {0}. Local account data was not deleted." `
        -f $profile.Email)
}

function Invoke-AccountCommand {
    param([string]$Argument)

    $parts = ($Argument ?? "").Trim() -split '\s+', 2
    $subCommand = ($parts[0] ?? "").ToUpperInvariant()
    $selector = $parts.Count -gt 1 ? $parts[1] : $null

    switch ($subCommand) {
        ""       { Show-AccountProfiles }
        "LIST"   { Show-AccountProfiles }
        "ADD"    { Invoke-AccountAdd }
        "SWITCH" { Invoke-AccountSwitch -Selector $selector }
        "REMOVE" { Invoke-AccountRemove -Selector $selector }
        default {
            Write-Error-Message `
                "Usage: ACCOUNT LIST|ADD|SWITCH <key|email|name>|REMOVE <key|email|name>"
        }
    }
}
