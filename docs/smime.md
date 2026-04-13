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

1. Picks your signing certificate automatically (first valid cert in store)
2. Builds a complete MIME message (body + all attachments)
3. Signs with SHA-256 → `multipart/signed`
4. Encrypts with AES-256-CBC → `application/pkcs7-mime`
5. Uploads the protected MIME back to the draft
6. Sends

Signing and encryption can be used independently or together.
When both are set, signing happens first, then encryption (RFC-correct order).

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
- **Exchange stripping**: Outlook.com may occasionally strip S/MIME content
  server-side; if a known-signed message shows no status, this is likely the cause
- **Decryption**: Encrypted received messages show the `E` icon but are not
  decrypted in the terminal — Exchange decrypts server-side for messages
  addressed to your own account
