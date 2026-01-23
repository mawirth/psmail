# config.ps1
# Configuration constants and paths

$script:Config = @{
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
    # Minimum of 10 lines, leaving space for menu and UI elements
    MinPageSize = 10
    MaxPageSize = 50
    
    # Filter search limits
    # Maximum number of messages to search per filter operation
    # to prevent excessive downloads in large mailboxes
    FilterMaxSearch = 200  # Search at most 200 messages per filter/more
    FilterBatchSize = 50   # Fetch 50 messages per API call
    
    # Editor path
    Editor = "nvim"
    
    # Footer file path (relative to script root)
    FooterPath = Join-Path $PSScriptRoot "..\data\footer.txt"
    
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
        # Directory for saving attachments (relative to current directory)
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
    }
}

# Make config globally accessible
$global:Config = $script:Config
