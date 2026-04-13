# psmail – Configuration

All configuration lives in `src/config.ps1`.

## Editor

Change the editor used for composing emails:

```powershell
Editor = "nvim"   # default – change to "notepad", "code", "vim", etc.
```

## Email Footer

### Plain text footer

Create `data/footer.txt` with your signature. It is appended automatically to
all new drafts, replies, and forwards.

### HTML footer with logo

When `data/footer.html` exists, all emails are sent as HTML and the footer is
embedded. Create one with the included tool:

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name     "Your Name" `
    -Title    "Your Title" `
    -Email    "you@example.com" `
    -Website  "https://yourwebsite.com" `
    -LogoPath "path\to\logo.png"
```

Logo guidelines: PNG preferred, under 50 KB, 120–200 px wide.

Switch back to plain text:
```powershell
Remove-Item data\footer.html
```

See `tools/README.md` for full options.

## Color Scheme

All UI colors are configurable in the `Colors` block in `src/config.ps1`:

```powershell
Colors = @{
    Header         = "Cyan"      # folder titles, separators
    Success        = "Green"     # success messages
    Error          = "Red"       # error messages
    Warning        = "Yellow"    # warnings
    Info           = "DarkGray"  # info messages
    MenuAction     = "Yellow"    # action menu items
    MenuGlobal     = "DarkGray"  # global navigation
    Prompt         = "Green"     # > prompt
    FieldLabel     = "DarkGray"  # From:, Subject:, etc.
    FilterActive   = "Yellow"    # active filter indicator
    ConfirmWarning = "Yellow"    # confirmation prompts
    ConfirmDanger  = "Red"       # PURGE and similar
    # ... see config.ps1 for all keys
}
```

Supported values: `Black`, `DarkBlue`, `DarkGreen`, `DarkCyan`, `DarkRed`,
`DarkMagenta`, `DarkYellow`, `Gray`, `DarkGray`, `Blue`, `Green`, `Cyan`,
`Red`, `Magenta`, `Yellow`, `White`

## S/MIME Settings

```powershell
SmimeConfig = @{
    EmailProtectionOid = "1.3.6.1.5.5.7.3.4"  # EKU for signing certs
    RevocationTimeout  = 10                     # seconds for OCSP/CRL
    AutoVerify         = $true                  # verify on message open
}
```

Set `AutoVerify = $false` to skip S/MIME verification when opening messages
(saves one API call per message, no S/MIME icons in the list).

## Pagination

The page size is calculated dynamically based on the terminal height.
Hard limits in `src/config.ps1`:

```powershell
MinPageSize = 1
MaxPageSize = 50
```

---

## Authentication & Permissions

psmail uses **OAuth 2.0 device code flow** via Microsoft Graph.

On first run:
1. A browser opens for login
2. Sign in with your Microsoft account (consumer or work/school)
3. Grant the requested permissions:

| Permission | Purpose |
|------------|---------|
| `Mail.ReadWrite` | Read and write mail, manage folders |
| `Mail.Send` | Send mail from drafts |
| `User.Read` | Read user profile (account address) |
| `People.Read` | Access contacts (may not work on all consumer accounts) |
| `Contacts.Read` | Access contacts (fallback) |

Credentials are cached by Windows Web Account Manager (WAM) — subsequent
starts connect without a browser prompt.

**Logout** (to switch accounts or clear credentials):
```
> LOGOUT
```

Or clear cached credentials manually:
```powershell
Disconnect-MgGraph
```
