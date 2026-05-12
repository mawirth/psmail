# psmail – Configuration

All configuration lives in `src/config.ps1`.

## Editor

Change the editor used for composing emails:

```powershell
Editor = "nvim"   # default – change to "notepad", "code", "vim", etc.
```

## Email Footer

Footers are **account-specific**. After the first successful login, psmail uses
the active account's local folder:

```text
data/accounts/<account-key>/footer.txt
data/accounts/<account-key>/footer.html
```

The `<account-key>` is derived from the signed-in email address and tenant, for
example:

```text
data/accounts/max@example.com__consumers/footer.txt
```

## Account Profiles and Switching

psmail keeps a small global profile list in:

```text
data/account-profiles.json
```

Each profile points at one account-specific data folder:

```text
data/accounts/<account-key>/
```

The account folder contains local-only helper files such as:

- `footer.txt`
- `footer.html`
- `smime-cache.json`
- `smime-drafts.json`
- `smime-draft-assets/`
- `smime-debug.txt`
- `attachments/`

Use these commands inside psmail:

```text
ACCOUNT LIST
ACCOUNT ADD
ACCOUNT SWITCH <key|email|name>
ACCOUNT REMOVE <key|email|name>
```

`ACCOUNT SWITCH` reconnects to Microsoft Graph and then derives local paths
from the account Graph actually returns. This prevents local state from one
mailbox being loaded for another mailbox. If Graph connects a different account
than the requested profile, psmail warns and uses the actual connected account's
folder.

### Plain text footer

Create `footer.txt` inside the target account folder. It is appended to new
drafts, replies, and forwards when the draft header has `Signature: yes`.

### HTML footer with logo

When `footer.html` exists in the active account folder and `Signature: yes` is
set, psmail sends the draft as HTML and appends that footer. Replies and
forwards also keep the quoted or forwarded original block as HTML line breaks,
so header lines and paragraph breaks stay readable.

`Create-Footer.ps1` writes `footer.html` by default. With `-TextOnly`, it
writes `footer.txt` instead and removes an existing `footer.html` for that
account so the text footer is actually used.

Create one with the included tool:

```powershell
.\tools\Create-Footer.ps1 `
    -Name       "Your Name" `
    -Email      "you@example.com" `
    -Mobile     "+49 170 1234567" `
    -Website    "https://yourwebsite.com"
```

If the email address matches exactly one account folder, the tool resolves it
automatically. If the same email exists with multiple account keys, specify the
target account explicitly:

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Your Name" `
    -Email "you@example.com" `
    -AccountKey "you@example.com__consumers"
```

Logo guidelines: PNG preferred, under 50 KB, 120–200 px wide.

Optional footer fields supported by the tool:
- title / role
- email
- phone
- mobile
- website
- address lines
- certification text
- certification URL
- optional logo

Switch back to plain text:
```powershell
Remove-Item data\accounts\<account-key>\footer.html
```

For a plain-text footer instead of HTML:

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Your Name" `
    -Email "you@example.com" `
    -AccountKey "you@example.com__consumers" `
    -TextOnly
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
