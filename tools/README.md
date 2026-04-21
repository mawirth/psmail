# Footer Tool

## Overview

`Create-HtmlFooter.ps1` creates an account-specific HTML footer:

```text
data/accounts/<account-key>/footer.html
```

This is meant for psmail accounts that want a richer signature without having
to hand-edit the footer files. The current focus is a clean contact footer:
name, signoff, email, phone/mobile, website, address lines, and an optional
certification link.

If `footer.html` exists, psmail sends the draft as HTML and appends that footer.
`footer.txt` is optional and only written when you explicitly request it with
`-WriteTextFooter`.

For replies and forwards, psmail keeps the quoted original section as HTML with
preserved line breaks, so `--- Original Message ---` / `--- Forwarded Message ---`
blocks do not collapse into one long line when an HTML footer is active.

## What The Tool Generates

Example result without logos:

```text
Mit freundlichen Grüßen,

Martin Wirth
max@example.com
Mobil: +49 170 1234567
```

The matching HTML footer uses the same content with clickable links where
possible.

## Usage

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Martin Wirth" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567" `
    -AccountKey "max@example.com__consumers"
```

If exactly one account folder exists under `data/accounts`, `-AccountKey` is
optional. If multiple account folders exist, pass `-AccountKey`.

## Parameters

- `-Name` required: display name
- `-Signoff` optional: greeting/signoff line above the signature block
- `-Title` optional: title or role
- `-Email` optional: rendered as `mailto:` link in HTML
- `-Phone` optional: general phone number
- `-Mobile` optional: mobile number
- `-Website` optional: clickable link in HTML
- `-AddressLines` optional: one or more address lines
- `-CertificationText` optional: extra credential line
- `-CertificationUrl` optional: clickable certification link
- `-LogoPath` optional: inline image as data URI
- `-AccountKey` optional: target account folder name
- `-WriteTextFooter` optional: also write `footer.txt`

## Examples

Minimal private footer:

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Martin Wirth" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567" `
    -AccountKey "max@example.com__consumers"
```

Same footer plus a plain-text fallback file:

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Martin Wirth" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567" `
    -AccountKey "max@example.com__consumers" `
    -WriteTextFooter
```

Richer footer with optional fields:

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Martin Wirth" `
    -Title "Projektleitung" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567" `
    -Website "https://www.example.com" `
    -CertificationText "ISO 9001" `
    -CertificationUrl "https://www.example.com/certification" `
    -AccountKey "max@example.com__consumers"
```

Address lines:

```powershell
.\tools\Create-HtmlFooter.ps1 `
    -Name "Martin Wirth" `
    -AddressLines "Musterstrasse 1","78462 Konstanz" `
    -AccountKey "max@example.com__consumers"
```

## Notes

- The tool currently generates a simple footer block, not a full Outlook-style
  MIME signature package with CID-linked inline images.
- For logos, the current implementation uses a data URI directly in the HTML.
- A future extension could add layout styles, preview output, or true MIME/CID
  asset packaging if needed.

## Switching Back To Plain Text

```powershell
Remove-Item data\accounts\<account-key>\footer.html
```

If you created `footer.txt` with `-WriteTextFooter`, psmail can then fall back
to that plain-text footer.
