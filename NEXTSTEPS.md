# NEXTSTEPS

This file collects plausible next steps for `psmail` after the current `1.1` scope.

## Version 1.2 Idea: Local Reply Suggestions

Goal: help triage incoming mail by preparing reply suggestions that can be reviewed in a second step before anything is sent.

### Core idea

- Scan inbox messages and identify mails that likely need a reply
- Generate a reply suggestion for selected mails
- Store suggestions locally, not in the online Drafts folder
- Review suggestions in a separate list view
- Let the user explicitly approve, edit, send, regenerate, or discard each suggestion

### Important design choice

Reply suggestions should live in a local file, not as cloud drafts.

Reasoning:
- avoids polluting the Outlook Drafts folder
- keeps experimental or half-finished AI output local
- makes it possible to discard or regenerate suggestions without changing mailbox state
- keeps a clear separation between "mail data from Graph" and "assistant-generated local state"

### Suggested v1.2 workflow

1. Inbox scan
- inspect currently listed inbox messages
- optionally mark messages as `reply candidate`

2. Suggestion generation
- build a local proposed reply for each candidate
- save the result into a local queue file

3. Review queue
- show all pending suggestions in a dedicated list
- support commands such as:
  - `SUGGEST`
  - `SUGGEST #`
  - `PENDING`
  - `OPEN #`
  - `EDIT #`
  - `SEND #`
  - `DISMISS #`
  - `REGEN #`

4. Final send step
- only when approved, create/send through the existing draft/send pipeline

### Local storage

Proposed local file:

- `data/reply-suggestions.json`

Each entry could contain:
- source message id
- thread/conversation id
- detected language
- candidate reason
- suggested subject
- suggested body
- generation timestamp
- status: `new`, `reviewed`, `approved`, `sent`, `dismissed`
- safety flags such as `contains_sensitive_content`, `smime_encrypted`, `manual_only`

### Safety and privacy rules

- Never auto-send
- Never send encrypted incoming mail to an online model
- Prefer skipping AI suggestion generation for:
  - legal topics
  - banking/financial instructions
  - contracts
  - health/medical topics
  - identity or account recovery mails
- For S/MIME encrypted mail:
  - local review is fine
  - online AI generation should be disabled by default

### Minimal viable version

The simplest useful `1.2` would be:

- manual trigger only
- no background processing
- local JSON queue
- one suggestion per source mail
- review list with send/dismiss/edit
- online AI optional and easy to disable

### Nice follow-up after v1.2

- local-only heuristics to detect reply candidates
- thread-aware reply generation
- different reply tones such as short/formal/friendly
- "suggest summary only" mode
- batch review page for multiple pending replies
- local model integration as an alternative to an online API

## Other plausible next steps

- add account profiles with explicit `ACCOUNT ADD`, `ACCOUNT LIST`, and `ACCOUNT SWITCH <name>` commands
- support switching between Microsoft accounts in one psmail install, while keeping only one active Graph session at a time
- move local state to per-account storage, for example `data/accounts/<account-key>/...`, so S/MIME cache/draft flags and future local metadata do not mix between accounts
- reset and reload in-memory state on account switch: current folder, message list, next link, open message, filter, and account-specific caches
- show active account identity in the UI header so mailbox switches are always obvious
- define a stable account key format based on resolved mailbox address plus tenant identifier when available
- prefer this account-switch flow: first `ACCOUNT ADD` does a full login, later `ACCOUNT SWITCH` first tries to reuse a cached Graph context/token and only falls back to interactive re-authentication when needed
- verify how reliably `Connect-MgGraph -ContextScope CurrentUser` can restore per-account contexts across personal Microsoft accounts and work/school tenants
- add a non-destructive `ACCOUNT REMOVE` flow that deletes only the local profile metadata, not the Microsoft Graph login itself
- document account-switching constraints clearly, especially differences between personal Microsoft accounts and work/school tenants
- more interop testing with S/MIME messages from different clients
- improve MIME handling for rarer nested multipart structures
- add a debug command for inspecting S/MIME/message structure without patching code
- add tests around list height calculation and S/MIME parsing
- document local state files and cache cleanup more explicitly
