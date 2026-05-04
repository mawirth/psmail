# Footer Tool

## Overview

`Create-Footer.ps1` creates an account-specific footer file:

```text
data/accounts/<account-key>/footer.html
```

This is meant for psmail accounts that want a richer signature without having
to hand-edit the footer files. The tool prompts for useful contact details when
they are not supplied as parameters. The current focus is a clean contact
footer: name, signoff, email, phone/mobile, website, address lines, and an
optional certification link.

By default the tool writes `footer.html`.
With `-TextOnly`, it writes `footer.txt` instead and removes an existing
`footer.html` in that account folder so the text footer is actually used.

If `footer.html` exists, psmail sends the draft as HTML and appends that footer.

For replies and forwards, psmail keeps the quoted original section as HTML with
preserved line breaks, so `--- Original Message ---` / `--- Forwarded Message ---`
blocks do not collapse into one long line when an HTML footer is active.

## What The Tool Generates

Example result without logos:

```text
Mit freundlichen Grüßen,

Max Mustermann
max@example.com
Mobil: +49 170 1234567

Sent by psmail: https://github.com/mawirth/psmail
```

The matching HTML footer uses the same content with clickable links where
possible, including the final `Sent by psmail` GitHub link.

## Usage

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Max Mustermann" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567"
```

If the email address matches exactly one account folder, the tool resolves it
automatically. `-AccountKey` is only needed when the same email exists in
multiple account folders or when you want to force a specific target.

For interactive setup, run the tool without contact parameters:

```powershell
.\tools\Create-Footer.ps1
```

The tool asks for the required name and then prompts for optional title, email,
phone/mobile, website, and address lines. Press Enter to skip an optional field.
If you pass contact details as parameters, the tool uses those values directly.

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
- `-AccountKey` optional: explicit target account folder name
- `-TextOnly` optional: write `footer.txt` instead of `footer.html`

## Examples

Minimal private footer:

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Max Mustermann" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567"
```

Plain-text footer instead of HTML:

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Max Mustermann" `
    -Email "max@example.com" `
    -Mobile "+49 170 1234567" `
    -TextOnly
```

Richer footer with optional fields:

```powershell
.\tools\Create-Footer.ps1 `
    -Name "Max Mustermann" `
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
.\tools\Create-Footer.ps1 `
    -Name "Max Mustermann" `
    -Email "max@example.com" `
    -AddressLines "Musterstrasse 1","78462 Konstanz"
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

If you want a text footer instead, run the tool with `-TextOnly`.
