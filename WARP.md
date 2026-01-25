# WARP.md - AI Assistant Guidelines for psmail

This document contains context, patterns, and guidelines for AI assistants working on the psmail project.

## Project Overview

**psmail** is a draft-first console email client for Outlook.com/Microsoft 365 using Microsoft Graph API, written in PowerShell 7+. It emphasizes:
- Text-based workflow with nvim integration
- Server-side operations (no local sync)
- Clean, maintainable code structure
- PowerShell idioms and best practices

## Critical Rules

### Security & Safety
1. **NEVER delete emails from Inbox or other folders without explicit user confirmation**
2. **PURGE command ONLY works in Deleted folder** - this is a hard requirement
3. **Never include co-author line in commits**: `Co-Authored-By: Warp <agent@warp.dev>`
4. **Never expose secrets in terminal commands** - use environment variables
5. **Never run commands that exit the shell** (e.g., `set -e`, `set -u`)

### Code Quality
1. **No orphaned TODOs** - always complete or remove TODO items
2. **No debug output in production code** - remove all `Write-Host` debug statements before committing
3. **Test changes interactively** - use `.\psmail.ps1` in interact mode to verify functionality
4. **Magic numbers must be documented or calculated** - never use unexplained hardcoded values
5. **Maintain existing code patterns** - adhere to idioms already established in the codebase

## Architecture & Patterns

### Module Structure
```
psmail.ps1              # Main entry point, command loop
src/
  config.ps1            # Configuration constants (folders, scopes, limits)
  state.ps1             # Global state management (view, items, filter)
  util.ps1              # Formatting and utility functions
  auth.ps1              # Microsoft Graph authentication
  graph.ps1             # REST API helpers and wrappers
  ui.ps1                # Menu rendering, input parsing, column calculations
  mail_list.ps1         # Message listing logic
  mail_read.ps1         # Message display and paging
  drafts.ps1            # Draft lifecycle and sending
  editor.ps1            # nvim integration
  attachments.ps1       # Attachment handling
  contacts.ps1          # Contact search from email history
  smime.ps1             # S/MIME detection and verification
```

### Key Functions & Their Purpose

#### State Management (state.ps1)
- `Initialize-State` - Set up global state on startup
- `Set-View` - Switch folders (does NOT reset filter anymore)
- `Set-Filter` / `Clear-Filter` - Filter management (persistent across folders)
- `Reset-StateItems` - Clear message list
- `Remove-StateItems` - Remove specific messages and re-index

#### UI Rendering (ui.ps1)
- `Get-ColumnWidths` - Calculate column widths dynamically based on console size
- `Render-MessageListHeader` - Unified header rendering (eliminates duplication)
- `Render-MessageRow` - Unified message row rendering (eliminates duplication)
- `Show-MessageList` - Display message list using above helpers
- `Get-OptimalPageSize` - Calculate how many messages fit on screen (currently reserves 17 lines)

#### Message Operations (mail_list.ps1)
- `Invoke-ListMessages` - Load and display messages for current folder
- `Invoke-ListMore` - Load next page (pagination)
- `Invoke-RefreshMessageList` - Refresh display after delete/move (auto-loads replacements)
- `Add-MessagesToState` - Add messages and assign indices
- `ConvertTo-MessageItem` - Convert Graph API message to internal format

#### Graph API (graph.ps1)
- `Invoke-GraphRequest` - Wrapper with error handling
- `Get-FolderMessages` - Fetch messages with pagination
- `Get-FilteredMessages` - Client-side filtering (subject, from, body)
- `Remove-Message` - **Important**: Returns `@{ success = $true }` on HTTP 204 (not null)
- `Move-Message` - Move between folders
- `Send-GraphMessage` - Send draft

### Important Behavioral Requirements

#### Filter Behavior
- **Filters persist across folder changes** - this is intentional
- Filters ONLY cleared by explicit `CLEAR` command or `Set-Filter` with new text
- Filter searches: From address, From name, Subject, Body (case-insensitive)
- Filter indicator always shown: `[Filter active: 'searchtext']`

#### Delete/Move Commands by Folder
- **Inbox**: `X` moves to Deleted, `K` moves to Junk
- **Drafts**: `X` moves to Deleted
- **Sent**: `X` moves to Deleted
- **Deleted**: `X` is BLOCKED (error message), use `PURGE` for permanent delete or `RESTORE` to recover
- **Junk**: `X` moves to Deleted, `INBOX` moves to Inbox

#### Post-Action Display
After PURGE, RESTORE, or X commands:
- **Always show the message list** - even if cancelled or no messages affected
- Call `Invoke-RefreshMessageList` if messages were successfully moved/deleted
- Call `Show-CurrentView` + `Show-MessageList` if action was cancelled or failed

#### Bulk Operations
All move/delete commands support:
- Single: `X 3`
- Range: `X 2-5` or `X 5-2` (auto-corrects)
- List: `X 3,1,5` (auto-sorts and deduplicates)
- Mixed: `X 1,3-5,7`

Use `Parse-IndexRange` from util.ps1 for parsing.

## UI Layout & Space Management

### Reserved Lines (Get-OptimalPageSize)
Current calculation reserves **17 lines**:
```
Header section: 4 lines
  - 1 blank line at top
  - 1 folder title (e.g., "Inbox")
  - 1 separator line (dashes)
  - 1 column header ("# U S A Date...")

Footer/Menu: 8 lines
  - 1 blank line before menu
  - 1 separator line
  - 1 view-specific menu line
  - 3 global menu lines
  - 1 blank line after menu
  - 1 prompt line ("> ")

Optional (always reserved): 4 lines
  - 2 pagination lines
  - 2 filter indicator lines

Safety margin: 1 line

Total: 17 lines
```

**Important**: If you change any UI spacing, update the calculation and documentation in `Get-OptimalPageSize`.

### Column Width Calculations
`Get-ColumnWidths` calculates widths based on actual format strings:
- Index: `"{0,-2} "` = 3 chars
- Unread: `"* "` = 2 chars
- S/MIME (inbox only): `"✔ "` = 2 chars
- Attachment: `"*  "` = 3 chars
- Date: `"yyyy-MM-dd HH:mm  "` = 18 chars
- From/To: `"{0,-18} "` = 19 chars
- Subject: Remaining console width (minimum 30)

**Never use magic numbers** - derive from actual format strings or document clearly.

## Common Issues & Solutions

### Issue: PURGE/DELETE not working
**Cause**: `Remove-Message` returns HTTP 204 No Content, which was treated as null/false.
**Solution**: `Remove-Message` now explicitly returns `@{ success = $true }` on success.

### Issue: List not displayed after action
**Cause**: Forgot to call `Show-CurrentView` + `Show-MessageList` after operation.
**Solution**: Always show list after PURGE/RESTORE/X, even if cancelled or failed.

### Issue: Filter disappears when switching folders
**Cause**: `Set-View` was resetting `$global:State.Filter = $null`.
**Solution**: Removed filter reset from `Set-View` - filters now persist across folders.

### Issue: Code duplication in message rendering
**Cause**: Header and row rendering repeated in multiple functions.
**Solution**: Extract to `Render-MessageListHeader` and `Render-MessageRow` helpers.

## Development Workflow

### Making Changes
1. **Research first** - understand current implementation before changing
2. **Test interactively** - use `.\psmail.ps1` in interact mode
3. **Remove debug output** - clean up all debug `Write-Host` statements
4. **Update documentation** - modify README.md if user-facing changes
5. **Commit without co-author** - do not include `Co-Authored-By: Warp <agent@warp.dev>`

### Testing Strategy
- **Don't delete user's real emails** - when testing X/PURGE, acknowledge in task
- **Test across folders** - verify behavior in Inbox, Drafts, Sent, Deleted, Junk
- **Test with filters** - verify filter persistence across folder changes
- **Test pagination** - check "M" command and NextLink handling
- **Test bulk operations** - try ranges, lists, mixed inputs

### Git Commit Messages
Structure:
```
Short summary (imperative mood)

- Bullet point details
- Group related changes
- Explain WHY, not just WHAT
- Reference fixed issues if applicable

```

## User Preferences

Based on conversations with the user:
1. **Concise responses** - no filler text, be direct
2. **No unnecessary summaries** - don't repeat code changes unless complex
3. **Status updates** - provide brief updates every few tool calls
4. **Test before suggesting** - verify solutions work before presenting
5. **Batch operations** - combine file reads/edits when possible
6. **Space efficiency** - minimize UI overhead, maximize message display

## PowerShell Best Practices

### Idioms Used in This Project
- **Hashtables for objects** - `@{ Key = Value }`
- **Pipeline for collections** - `$array | ForEach-Object { }`
- **Explicit returns** - always `return $value`, not implicit
- **ErrorAction** - use `-ErrorAction Stop` for try/catch
- **Null checks** - use `-not $var` or `$null -eq $var`
- **Array handling** - wrap results in `@()` to ensure arrays

### Avoid
- **Positional parameters** - always use named parameters
- **Implicit returns** - be explicit
- **Write-Output in functions** - use `return` instead
- **Pipeline side effects** - functions should be pure when possible

## Future Enhancements (Planned)

### S/MIME (Phase 2)
- Parse MIME structure to detect `multipart/signed` or `application/pkcs7-mime`
- Use .NET `System.Security.Cryptography.Pkcs.SignedCms` for verification
- Validate certificate chains against Windows root store
- Handle revocation checking (online/offline)

### S/MIME (Phase 3)
- Sign outgoing messages with user certificate
- Encrypt messages using recipient certificates
- Combined sign+encrypt operations

## Useful Commands for Development

### Test the application
```powershell
.\psmail.ps1
```

### Search for patterns
```powershell
# Find all TODO comments
grep -r "TODO" src/

# Find function definitions
grep "^function " src/*.ps1

# Find Write-Host debug statements
grep "Write-Host.*Debug\|Write-Host.*DEBUG" src/
```

### Check Git status
```powershell
git status
git diff
git log --oneline -n 10
```

## Notes for AI Assistants

- **This is a personal project** - optimize for maintainability, not enterprise scale
- **User knows PowerShell** - don't over-explain basic PS concepts
- **Test your changes** - use interact mode before committing
- **Space is precious** - console real estate is limited
- **Be consistent** - follow existing patterns even if you'd do it differently
- **Ask when uncertain** - if user requirements are ambiguous, clarify before implementing

## Last Updated
2026-01-25 - After filter persistence and PURGE/delete command refactoring
