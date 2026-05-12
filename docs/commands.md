# psmail – Command Reference

## Global Navigation

| Command | Description |
|---------|-------------|
| `I` | Switch to Inbox |
| `F` | Switch to Inbox: Relevant / Focused |
| `O` | Switch to Inbox: Sonstige / Other |
| `A` | Switch to Inbox: all messages / Alle |
| `D` | Switch to Drafts |
| `S` | Switch to Sent |
| `G` | Switch to Deleted |
| `J` | Switch to Junk |
| `CONTACTS` | Search contacts and copy email address |
| `SMIME` | Show available S/MIME signing certificates |
| `ACCOUNT LIST` | Show saved account profiles |
| `ACCOUNT ADD` | Sign in and save the connected account as a local profile |
| `ACCOUNT SWITCH <key|email|name>` | Reconnect and load local state for that account |
| `ACCOUNT REMOVE <key|email|name>` | Remove only the local profile entry |
| `LOGOUT` | Disconnect and clear session |
| `Q` | Quit (keeps session active) |

## Common Commands (all folders)

| Command | Description |
|---------|-------------|
| `L` | List / refresh current folder |
| `R <#>` | Read message by number |
| `M` | Load next page of messages |
| `FILTER <text>` | Filter messages (server-side search in From, Subject, Body) |
| `CLEAR` | Remove active filter |

## Folder-specific Commands

### Inbox
| Command | Description |
|---------|-------------|
| `X <#>` / `X <#-#>` | Delete message(s) → Deleted |
| `K <#>` / `K <#-#>` | Move to Junk |
| `FOCUS <#>` / `RELEVANT <#>` | Mark message(s) as Relevant / Focused |
| `OTHER <#>` / `SONSTIGE <#>` | Mark message(s) as Sonstige / Other |
| `FOCUS! <#>` / `RELEVANT! <#>` | Always classify future mail from this sender as Relevant / Focused |
| `OTHER! <#>` / `SONSTIGE! <#>` | Always classify future mail from this sender as Sonstige / Other |

### Drafts
| Command | Description |
|---------|-------------|
| `NEW` | Create new draft |
| `E <#>` | Edit draft |
| `SEND <#>` | Send draft |
| `X <#>` / `X <#-#>` | Delete draft(s) |

### Sent
| Command | Description |
|---------|-------------|
| `REDRAFT <#>` | Copy to Drafts for resending |
| `X <#>` / `X <#-#>` | Delete sent message(s) → Deleted |

### Deleted
| Command | Description |
|---------|-------------|
| `RESTORE <#>` / `RESTORE <#-#>` | Restore to Inbox |
| `PURGE <#>` / `PURGE <#-#>` | Delete permanently |

### Junk
| Command | Description |
|---------|-------------|
| `INBOX <#>` / `INBOX <#-#>` | Move to Inbox |
| `X <#>` / `X <#-#>` | Delete → Deleted |

### When Viewing a Message
| Command | Description |
|---------|-------------|
| `REPLY` | Reply to sender |
| `REPLYALL` | Reply to all recipients |
| `FORWARD` | Forward message |
| `ATT` | List attachments |
| `SAVE <#>` | Save specific attachment |
| `SAVEALL` | Save all non-inline attachments |

---

## Bulk Operations

Many commands accept single numbers, ranges, and comma-separated lists:

```
> X 3          # single message
> X 2-5        # range (also works reversed: X 5-2)
> X 3,1,5      # comma-separated list (auto-sorted, deduped)
> X 1,3-5,7    # mixed
```

Commands that support bulk input: `X`, `K`, `INBOX`, `RESTORE`, `PURGE`

All bulk operations show a preview and require confirmation.

---

## Filtering

Inbox supports Outlook's Focused Inbox split:

```
> F   # Relevant / Focused
> O   # Sonstige / Other
> A   # all / Alle Inbox messages
```

psmail starts in Relevant / Focused mode. Focused Inbox is stored by Microsoft as the message
`inferenceClassification`, not as separate folders. The mode only applies to
Inbox. `FILTER <text>` can be combined with `F` or `O`; psmail searches through
Graph and keeps only messages from the selected Inbox class.

You can correct Outlook's classification for selected Inbox messages:

```
> OTHER 3      # mark this message as Sonstige / Other
> FOCUS 3      # mark this message as Relevant / Focused
> OTHER 2-5    # ranges and comma lists work too
```

German aliases are also available: `SONSTIGE` for `OTHER`, and `RELEVANT`
for `FOCUS`.

To classify the selected message(s) and create or update a sender rule for
future Inbox messages, use the `!` commands. These ask for confirmation because
they affect later mail from the same sender:

```
> OTHER! 3     # future mail from this sender goes to Sonstige / Other
> FOCUS! 3     # future mail from this sender goes to Relevant / Focused
```

The `!` commands support the same ranges and comma-separated lists as `X`.
After applying the message classification and sender rule(s), psmail reloads
the current list view.

```
> FILTER john
```
Filters the current folder by sender (name/address), subject, or body.
Uses Microsoft Graph server-side search first, so filtering does not need to
download full message bodies in the normal case.
The filter indicator `[Filter active: 'john']` appears above the list.

```
> CLEAR
```
Removes the active filter.

**Behavior:**
- Case-insensitive substring matching
- Searches From, Subject, and Body simultaneously
- Persists when switching folders — clear explicitly with `CLEAR`
- Pagination works normally with an active filter (`M` loads more results)

---

## Account Profiles

psmail stores account profiles in `data/account-profiles.json`. Account data
such as footers, S/MIME draft flags, and S/MIME cache files live under:

```text
data/accounts/<account-key>/
```

Useful commands:

```text
> ACCOUNT LIST
> ACCOUNT ADD
> ACCOUNT SWITCH max@example.com__consumers
> ACCOUNT REMOVE old@example.com__consumers
```

`ACCOUNT SWITCH` always reconnects through Microsoft Graph and then uses the
account actually returned by Graph to choose local paths. If Microsoft's token
cache or account picker connects a different account than requested, psmail
warns and loads the actual account's local state instead of reusing the wrong
cache.

---

## Hidden Diagnostics

`DEBUGSMIME <#>` prints S/MIME-relevant structure for a listed message:

```text
> DEBUGSMIME 3
```

It shows selected message headers, Graph attachment metadata, detected S/MIME
attachment type, and whether raw MIME is available. It is intentionally not
listed in the in-app menu.

---

## Email Composition

### Creating a Draft

1. Switch to Drafts: `D`
2. Run `NEW` — Neovim opens with this template:

```
To: 
Subject: 
Attachments: 
Signature: no
Sign: no
Encrypt: no

---
(write message body here)
```

3. Fill in the fields, write the body below `---`
4. Save and quit: `:wq`

Set `Signature: yes` to append the footer from the active account folder
(`data/accounts/<account-key>/footer.txt` or `footer.html`).
Attachments are validated and uploaded after saving.

If `Encrypt: yes` is set, psmail keeps the body and attachment paths locally on
this computer and only stores a placeholder draft online until you send it.

### Editing a Draft

```
> E 2
```

Opens the draft in Neovim. Save with `:wq`, cancel with `:q!`.
For `Encrypt: yes` drafts, psmail opens the locally stored cleartext body and
local attachment paths rather than the online placeholder text.

### Sending

```
> SEND 2
```

Confirm when prompted. The draft is sent and moves to Sent Items.
If `Sign: yes` or `Encrypt: yes` was set, S/MIME is applied before sending.

### Redrafting a Sent Message

```
> REDRAFT 3    (from Sent folder)
```

Creates a new draft with the original body, recipients, and attachments.
Subject gets a `Fwd:` prefix. Switch to Drafts to edit or send.

### Attachments

Attach files in the `Attachments:` header field:

```
Attachments: ~/Desktop/report.pdf, image.png, C:\path\to\file.zip
```

- Supports absolute paths, relative paths, and `~` (home directory)
- Comma or semicolon separated
- Files are validated before draft creation
- Received attachments are saved to the active account folder under
  `data/accounts/<account-key>/attachments/`
- Duplicate filenames get numbered: `file (1).pdf`, `file (2).pdf`

### Contact Search

```
> CONTACTS
```

Searches your email history for contacts. Enter a search term or press Enter
for all. Select a number to copy the address to clipboard.
