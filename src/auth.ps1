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
            -ForegroundColor Cyan
        Install-Module Microsoft.Graph.Authentication `
            -Scope CurrentUser `
            -Force `
            -AllowClobber
    }
    
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    
    Write-Host "Connecting to Microsoft Graph..." `
        -ForegroundColor Cyan
    
    try {
        # Try with consumers tenant first
        Connect-MgGraph `
            -Scopes $Config.Scopes `
            -ContextScope CurrentUser `
            -NoWelcome `
            -ErrorAction Stop
            
        Write-Success "Successfully connected!"
        
        # Show connection info
        $ctx = Get-MgContext
        $tenantInfo = if ($ctx.TenantId) { 
            $ctx.TenantId 
        } else { 
            "consumers" 
        }
        Write-Info ("Account: {0}  Tenant: {1}" `
            -f $ctx.Account, $tenantInfo)
        
        return $true
        
    } catch {
        Write-Error-Message "Connection failed: $($_.Exception.Message)"
        return $false
    }
}

function Disconnect-GraphMail {
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
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
