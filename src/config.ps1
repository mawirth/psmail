# config.ps1
# Configuration constants and paths

$script:Config = @{
    # Version
    Version = "1.1"
    GitHubUrl = "https://github.com/mawirth/psmail/tree/develop"
    # Graph API scopes required
    # Note: People.Read and Contacts.Read may not work on all consumer accounts
    # The contacts feature will build a list from email history as fallback
    Scopes = @(
        "Mail.ReadWrite"   # Read and write mail, manage folders
        "Mail.Send"        # Send mail from drafts
        "User.Read"        # Read user profile info
        "People.Read"      # Access people/contacts (optional)
        "Contacts.Read"    # Access contacts (optional)
    )
    
    # Folder identifiers
    Folders = @{
        Inbox   = "inbox"
        Drafts  = "drafts"
        Sent    = "sentitems"
        Deleted = "deleteditems"
        Junk    = "junkemail"
    }
    
    # Folder display names
    FolderNames = @{
        inbox        = "Inbox"
        drafts       = "Drafts"
        sentitems    = "Sent"
        deleteditems = "Deleted"
        junkemail    = "Junk"
    }
    
    # List pagination
    # PageSize will be calculated dynamically based on window height
    # Minimum of 1 lines, leaving space for menu and UI elements
    MinPageSize = 1
    MaxPageSize = 50
    
    DataRootPath = Join-Path $PSScriptRoot ".." -AdditionalChildPath "data"
    AccountsDataPath = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "accounts"
    AccountProfilesPath = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "account-profiles.json"

    # Editor path
    Editor = "nvim"
    
    # Footer file paths
    FooterPath = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "footer.txt"
    HtmlFooterPath = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "footer.html"

    # Persisted S/MIME draft flags - survives session restarts.
    # Stored locally because Outlook.com consumer accounts do not allow
    # writing custom metadata to Graph messages (categories: 403 Forbidden;
    # HTML comments are stripped server-side).
    SmimeDraftsPath = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "smime-drafts.json"

    # Persisted S/MIME verification status cache - survives session restarts
    # so the E/S list column indicators reappear without reopening each message.
    # Stores Status/Subject/Issuer/ValidUntil per message ID (not Body).
    SmimeCachePath  = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "smime-cache.json"
    SmimeDebugPath  = Join-Path $PSScriptRoot ".." `
        -AdditionalChildPath "data", "smime-debug.txt"
    CurrentAccount = $null

    # HTML body formatting (when sending HTML emails)
    HtmlBodyStyle = @{
        FontFamily = "Arial"
        FontSize = "10pt"
    }
    
    # Email templates and formatting
    EmailTemplates = @{
        # Draft template separator
        HeaderSeparator = "---"
        
        # Reply/Forward prefixes
        ReplyPrefix = "Re: "
        ForwardPrefix = "Fwd: "
        
        # Quote markers for replies
        OriginalMessageHeader = "--- Original Message ---"
        ForwardedMessageHeader = "--- Forwarded Message ---"
        QuotePrefix = "> "
        
        # Attachment marker for existing attachments in draft editor
        ExistingAttachmentPrefix = "[existing: "
        ExistingAttachmentSuffix = "]"
    }
    
    # Attachments configuration
    AttachmentsConfig = @{
        # Directory for saving attachments. Set per account after login.
        SaveDirectory = "attachments"
        
        # Recipient address separator (for To, CC, BCC fields)
        RecipientSeparators = @(',', ';')
    }
    
    # S/MIME status values
    SmimeStatus = @{
        None             = "None"
        SignedTrusted    = "SignedTrusted"
        SignedUntrusted  = "SignedUntrusted"
        SignedInvalid    = "SignedInvalid"
        Encrypted        = "Encrypted"      # Message is S/MIME encrypted
    }
    
    # S/MIME configuration
    SmimeConfig = @{
        # OID for emailProtection Extended Key Usage
        EmailProtectionOid = "1.3.6.1.5.5.7.3.4"
        
        # Timeout for online revocation check (seconds)
        RevocationTimeout = 10
        
        # Automatically verify S/MIME when opening inbox messages
        # (requires one extra Graph API call per message open)
        AutoVerify = $true
    }
    
    # Color scheme for UI elements
    Colors = @{
        # Headers and titles
        Header          = "Cyan"
        Separator       = "DarkGray"
        
        # Messages and status
        Success         = "Green"
        Error           = "Red"
        Warning         = "Yellow"
        Info            = "DarkGray"
        
        # List display
        SubjectHeader   = "DarkGray"
        FilterActive    = "Yellow"
        NoMessages      = "DarkGray"
        LoadingMore     = "Cyan"
        
        # Menu and prompts
        MenuAction      = "Yellow"
        MenuGlobal      = "DarkGray"
        Prompt          = "Green"
        
        # Message details
        MessageDetail   = "Cyan"
        FieldLabel      = "DarkGray"
        
        # Confirmations
        ConfirmWarning  = "Yellow"
        ConfirmDanger   = "Red"
    }
}

# Make config globally accessible
$global:Config = $script:Config

function ConvertTo-AccountStorageKey {
    param(
        [string]$Email,
        [string]$TenantId
    )

    $normalizedEmail = [string]::IsNullOrWhiteSpace($Email) `
        ? "unknown" `
        : $Email.Trim().ToLowerInvariant()

    $normalizedTenant = [string]::IsNullOrWhiteSpace($TenantId) `
        ? "consumers" `
        : $TenantId.Trim().ToLowerInvariant()

    $combined = "{0}__{1}" -f $normalizedEmail, $normalizedTenant
    return ([regex]::Replace($combined, '[^a-z0-9@._-]', '_'))
}

function Set-AccountStoragePaths {
    param(
        [string]$Email,
        [string]$TenantId
    )

    $accountKey = ConvertTo-AccountStorageKey -Email $Email -TenantId $TenantId
    $accountPath = Join-Path $Config.AccountsDataPath $accountKey

    if (-not (Test-Path $accountPath)) {
        New-Item -ItemType Directory -Path $accountPath -Force | Out-Null
    }

    $Config.CurrentAccount = @{
        Email     = $Email
        TenantId  = $TenantId
        Key       = $accountKey
        DataPath  = $accountPath
    }
    $Config.FooterPath      = Join-Path $accountPath "footer.txt"
    $Config.HtmlFooterPath  = Join-Path $accountPath "footer.html"
    $Config.SmimeDraftsPath = Join-Path $accountPath "smime-drafts.json"
    $Config.SmimeCachePath  = Join-Path $accountPath "smime-cache.json"
    $Config.SmimeDebugPath  = Join-Path $accountPath "smime-debug.txt"
    $Config.SmimeDraftAssetsPath = Join-Path $accountPath "smime-draft-assets"
    $Config.AttachmentsConfig.SaveDirectory = Join-Path $accountPath "attachments"
}
