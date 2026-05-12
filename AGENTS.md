# AGENTS

## Project Context

`psmail` is a draft-first console mail client for Outlook.com / Microsoft 365,
written in PowerShell 7+ on top of Microsoft Graph.

Core characteristics:
- text-first workflow with an external editor
- server-side mailbox operations, no local mailbox sync
- account-specific local helper state under `data/accounts/<account-key>/...`
- S/MIME verification for incoming mail and sign/encrypt support for outgoing mail

## Working Rules

Maintain existing code patterns unless there is a clear reason to refactor.

Before broad repository searches, verify the actual shell location. Do not rely
on `workdir` alone: constrain `rg`/file enumeration to the repository root or
specific repo files/includes so searches never spill into parent or unrelated
directories.

Prefer current repo behavior over stale notes:
- filters persist across folder changes until explicitly cleared
- `PURGE` only belongs in Deleted
- destructive mail actions require explicit confirmation
- after delete/move-style actions, the list view should remain stable and visible

When changing UI spacing, paging, or list rendering:
- keep the viewport-filling behavior stable
- avoid introducing stray output lines that shift the list
- document non-obvious reserved-line calculations in code

When changing HTML-to-text or reply/forward formatting:
- preserve readable structure over aggressive whitespace collapsing
- test with realistic Outlook-style HTML, links, and quoted sections

When changing S/MIME behavior:
- preserve the lazy verification model on message open
- keep encrypted draft cleartext out of online drafts
- keep local encrypted-draft data keyed by message ID, not list position

## Code Quality

- no orphaned TODOs
- no debug-only output in production code
- explain or derive magic numbers
- prefer understanding the current path before changing it
- update user-facing docs when behavior changes

## Commit Safety

Before creating any git commit in this repository, always check for content
that may be private, sensitive, or not intended for version control.

This includes at least:
- personal email addresses
- phone numbers
- private postal addresses
- credentials, tokens, secrets, or account identifiers
- screenshots, photos, or other images that may contain personal or unrelated data
- generated/debug/export files that do not belong in the repo

If any such content is present or even plausibly present:
- warn explicitly before the commit
- point to the affected file(s)
- ask for explicit confirmation before committing

Do not silently include potentially private data or unrelated images in a
commit, even if they appear in documentation or examples.

## Validation

Before closing substantial changes, prefer checking the relevant path directly:
- interactive psmail behavior when feasible
- parser/syntax checks for touched PowerShell files
- targeted workflow tests for drafts, reply/forward, list refresh, and S/MIME paths
