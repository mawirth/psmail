# auth.ps1
# Graph authentication helpers

function Connect-GraphMail {
    <#
    .SYNOPSIS
    Connect to Microsoft Graph for Outlook.com (consumers)
    #>
    
    # Ensure module is available
    $moduleName = "Microsoft.Graph.Authentication"
    $module = Get-Module -ListAvailable -Name $moduleName `
        | Sort-Object Version -Descending `
        | Select-Object -First 1
    
    if (-not $module -or $module.Version.Major -lt 2) {
        Write-Host "Installing/Updating $moduleName (v2+)..." `
            -ForegroundColor $Config.Colors.LoadingMore
        Install-Module Microsoft.Graph.Authentication `
            -Scope CurrentUser `
            -Force `
            -AllowClobber
    }
    
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    
    Write-Host "Connecting to Microsoft Graph..." `
        -ForegroundColor $Config.Colors.LoadingMore
    
    try {
        # Try with consumers tenant first
        Connect-MgGraph `
            -Scopes $Config.Scopes `
            -ContextScope CurrentUser `
            -NoWelcome `
            -ErrorAction Stop
            
        Write-Success "Successfully connected!"
        
        # Show connection info
        $ctx     = Get-MgContext
        $email   = Get-CurrentUserEmail
        $tenantInfo = if ($ctx.TenantId) { $ctx.TenantId } else { "consumers" }
        Set-AccountStoragePaths -Email $email -TenantId $tenantInfo
        Write-Info ("Account: {0}  Tenant: {1}" -f $email, $tenantInfo)
        
        return $true
        
    } catch {
        Write-Error-Message "Connection failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-CurrentUserEmail {
    <#
    .SYNOPSIS
    Return the signed-in user's email address.
    $ctx.Account is empty for personal MSA (Outlook.com) accounts;
    falls back to GET /me in that case.
    #>
    $ctx = Get-MgContext
    if (-not [string]::IsNullOrWhiteSpace($ctx.Account)) {
        return $ctx.Account
    }
    try {
        $me = Invoke-MgGraphRequest `
            -Method GET `
            -Uri    "/v1.0/me?`$select=mail,userPrincipalName" `
            -ErrorAction Stop
        if ($me.mail)              { return $me.mail }
        if ($me.userPrincipalName) { return $me.userPrincipalName }
    } catch { }
    return ""
}

function Disconnect-GraphMail {
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        $Config.CurrentAccount = $null
        Write-Info "Disconnected from Microsoft Graph"
    } catch {
        # Ignore disconnect errors
    }
}

function Test-GraphConnection {
    <#
    .SYNOPSIS
    Check if Graph connection is active
    #>
    
    $ctx = Get-MgContext
    return ($null -ne $ctx)
}
