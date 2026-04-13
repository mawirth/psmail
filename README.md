# psmail - PowerShell Console Mail Client

A draft-first console email client for **Outlook.com** and **Microsoft 365** accounts
using **Microsoft Graph API**.

![psmail inbox view](email_pixelated.jpg)

## Features

- **Draft-first workflow** — all new emails are created as drafts first
- **nvim integration** — compose and edit in Neovim
- **Reply, Forward, Redraft** — with quoted text and attachment copy
- **Attachments** — upload when composing, save received files
- **Contact search** — search email history, copy address to clipboard
- **Filtering** — search by sender, subject, or body across all folders
- **S/MIME** — verify incoming signatures, sign and encrypt outgoing mail
- **HTML cleanup** — converts HTML emails to readable plain text
- **Folder management** — Inbox, Drafts, Sent, Deleted, Junk
- **Text-only, no local sync** — server-side operations via Graph API

## Requirements

- **PowerShell 7+** (`pwsh`)
- **Neovim** (`nvim`) in PATH
- **Microsoft account** (Outlook.com, Hotmail.com, Microsoft 365)
- Microsoft.Graph.Authentication module (auto-installed on first run)

## Installation

```powershell
git clone https://github.com/mawirth/psmail
cd psmail
pwsh psmail.ps1
```

On first run a browser opens for Microsoft account login. Credentials are
cached by Windows WAM — subsequent starts connect automatically.

## Quick Start

```powershell
pwsh psmail.ps1          # start
pwsh psmail.ps1 -Version # show version
```

| Key | Action |
|-----|--------|
| `I` / `D` / `S` / `G` / `J` | Switch folder (Inbox / Drafts / Sent / Deleted / Junk) |
| `L` | List / refresh |
| `R <#>` | Read message |
| `M` | Load next page |
| `X <#>` | Delete (supports ranges: `X 2-5`, `X 1,3,7`) |
| `NEW` | New draft (Drafts only) |
| `E <#>` | Edit draft |
| `SEND <#>` | Send draft |
| `REPLY` / `REPLYALL` / `FORWARD` | When viewing a message |
| `FILTER <text>` | Filter by sender/subject/body |
| `CLEAR` | Remove filter |
| `CONTACTS` | Search contacts |
| `SMIME` | Show S/MIME certificates |
| `LOGOUT` | Disconnect |
| `Q` | Quit |

→ Full command reference: **[docs/commands.md](docs/commands.md)**

## Message List (Inbox)

```
#  U E S A  Date              From               Subject
1  *   ✔ *  2026-01-22 12:30  alice@example.com  Signed mail
2     E      2026-01-22 11:10  bob@example.com    Encrypted
3       ~    2026-01-22 10:40  eve@example.com    Untrusted sig
4            2026-01-22 09:00  carl@example.com   Normal mail
```

`U` = unread · `E` = encrypted · `S` = signing status (✔ trusted / ~ untrusted / ✖ invalid) · `A` = attachment

S/MIME status is verified on first open and cached for the session.

## Documentation

| Document | Contents |
|----------|----------|
| [docs/commands.md](docs/commands.md) | Full command reference, bulk ops, filtering, composition, attachments |
| [docs/smime.md](docs/smime.md) | S/MIME verification, signing, encryption, certificate setup |
| [docs/configuration.md](docs/configuration.md) | Editor, colors, footer, authentication, pagination |
| [tools/README.md](tools/README.md) | HTML footer with logo |

## File Structure

```
psmail.ps1        # entry point
src/              # modules (config, graph, ui, drafts, smime, …)
docs/             # detailed documentation
tools/            # Create-HtmlFooter.ps1
data/             # footer.txt / footer.html (gitignored)
attachments/      # downloaded attachments (gitignored)
cert/             # certificate files (gitignored)
```

## Troubleshooting

**Module install fails** — run PowerShell as Administrator:
```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
```

**nvim not found:**
```powershell
$env:PATH += ";C:\Program Files\Neovim\bin"
```

**Authentication fails** — clear cached credentials:
```powershell
Disconnect-MgGraph
```

## Limitations

- Text-only composition (no inline HTML on send)
- No POP/IMAP, no background sync
- S/MIME encryption requires recipient certificate in Windows cert store

## License

Demonstration project for educational purposes.

---

**psmail** — simple, draft-first email for the command line.
