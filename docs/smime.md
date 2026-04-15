# psmail – S/MIME

psmail supports S/MIME for both incoming signature verification and outgoing
signing/encryption, using the **Windows Certificate Store** (`certmgr.msc`).

## Inbox: Message List

The inbox list includes two S/MIME indicator columns:

```
#  U E S A  Date              From               Subject
1  *   ✔ *  2026-01-22 12:30  alice@example.com  Signed message
2     E      2026-01-22 11:10  bob@example.com    Encrypted message
3       ~    2026-01-22 10:40  eve@example.com    Untrusted signature
```

| Column | Meaning |
|--------|---------|
| `E` | `E` = S/MIME encrypted message |
| `S` | `✔` trusted · `~` untrusted · `✖` invalid signature |

> S/MIME status is verified when a message is **opened** for the first time
> (one extra API call). The icon then stays in the list for the session.

## Incoming: Signature Verification

When you open an inbox message, psmail automatically:

1. Fetches the raw MIME content from Graph API
2. Detects `multipart/signed` or `application/pkcs7-mime`
3. Verifies the cryptographic signature via .NET `SignedCms`
4. Validates the certificate chain against Windows root certificates
5. Performs an online revocation check (OCSP/CRL, 10 s timeout)
6. Shows the result below the message header:

```
Signature:   Trusted [S/MIME]
Signer:      Max Mustermann
Issued by:   D-TRUST GmbH
Valid until: 2027-03-15
```

Results are cached for the session — no repeated API calls for the same message.

## Outgoing: Signing and Encryption

Set `Sign: yes` and/or `Encrypt: yes` in the draft header before sending:

```
To: alice@example.com
Subject: Confidential document
Attachments: 
Sign: yes
Encrypt: yes

---
Message body...
```

When you run `SEND`, psmail:

1. Picks your signing certificate automatically (matched by email address)
2. Builds the inner MIME message (body base64-encoded + attachments)
3. Signs with SHA-256 detached signature → `multipart/signed`
   - Body is base64-encoded for transit stability (not quoted-printable)
   - The signed bytes follow RFC 2046 §5.1.1 canonicalisation (trailing
     CRLF before boundary is excluded from the hash)
   - Intermediate CA certificates (e.g. DigiCert) are embedded via
     `ExcludeRoot` so recipients can verify the full chain
4. Encrypts with AES-256-CBC → `application/pkcs7-mime; smime-type=enveloped-data`
5. Wraps in a complete RFC 2822 envelope (MIME-Version, Date, From, To, Subject)
6. Sends via `POST /me/sendMail` with base64-encoded MIME body
   (personal accounts) or `PUT /$value` + `/send` (Microsoft 365 accounts)

Signing and encryption can be used independently or together.
When both are set, signing happens first, then encryption (RFC 5751 order).

Check what certificates are installed:

```
> SMIME
```

## Certificate Setup

### Signing certificate (for outgoing)

You need a personal S/MIME certificate **with private key**:

1. Obtain from a CA: **D-TRUST**, **GlobalSign**, **Sectigo**, **Certum**, etc.
   (or generate a self-signed one for testing)
2. Open Windows Certificate Manager: `Win+R` → `certmgr.msc`
3. Navigate to: **Personal → Certificates → Import**
4. Import your `.p12` / `.pfx` file (must include private key)
5. Verify with the `SMIME` command in psmail

### Recipient certificates (for encryption)

To encrypt for a recipient, their **public certificate** must be installed in Windows:

1. Obtain the recipient's certificate (`.cer` / `.crt`)
2. Open `certmgr.msc`
3. Navigate to: **Other People → Certificates → Import**
4. Import the public certificate

psmail searches for recipient certificates by email address in the Subject
Alternative Name (SAN), Subject field, and legacy `E=` / `EMAIL=` attributes.

### Generating a certificate request (CSR)

If your CA requires a CSR, you can use `certreq` on Windows.
Example `.inf` for an S/MIME certificate:

```ini
[NewRequest]
Subject = "CN=Your Name, E=you@example.com"
KeyLength = 2048
KeyAlgorithm = RSA
MachineKeySet = false
Exportable = true
RequestType = PKCS10

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.4   ; emailProtection
```

Generate the CSR:
```powershell
certreq -new smime.inf smime.csr
```

Submit the CSR to your CA, then import the signed certificate.

## Limitations

- **Encryption requires recipient cert** installed under "Other People"
- **Inbox only**: auto-verification applies to Inbox; Sent/Drafts don't auto-verify
- **Decryption**: Encrypted received messages show the `E` icon but are not
  decrypted in the terminal — the mail client decrypts using the local private key
- **Personal Microsoft accounts** (MSN/Outlook.com): `PUT /$value` is not
  supported; psmail falls back to `POST /me/sendMail` with base64-encoded MIME
- **Outlook iOS + personal accounts**: S/MIME decryption in Outlook iOS requires
  a Microsoft 365 account managed via MDM/Intune; personal account users should
  use Apple Mail (which supports S/MIME fully with certificates installed as
  iOS profiles)
- **Certificate expiry — signing**: old signatures show as unverifiable after
  expiry, but the message remains readable; renew and re-import the certificate
- **Certificate expiry — encryption**: the private key for expired certificates
  must be archived (`.p12` backup) — losing it makes all previously received
  encrypted messages permanently unreadable
