# smime.ps1
# S/MIME detection and verification

function Get-MessageSmimeStatus {
    <#
    .SYNOPSIS
    Detect and verify S/MIME status for a message
    Phase 1: Detection only, returns None for all messages
    Phase 2: Full verification implementation
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    # Phase 1: Stub - always return None
    # Future: Implement MIME type detection and verification
    return $Config.SmimeStatus.None
}

function Show-SmimeInfo {
    <#
    .SYNOPSIS
    Display S/MIME signature information
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [Parameter(Mandatory)]
        [string]$Status
    )
    
    Write-Host ""
    
    switch ($Status) {
        "SignedTrusted" {
            Write-Host "Signature: " -NoNewline -ForegroundColor DarkGray
            Write-Host "Trusted" -ForegroundColor Green
            
            # Phase 2: Show actual certificate details
            Write-Host "Signer:    " -NoNewline -ForegroundColor DarkGray
            Write-Host "(Not yet implemented)"
        }
        "SignedUntrusted" {
            Write-Host "Signature: " -NoNewline -ForegroundColor DarkGray
            Write-Host "Untrusted" -ForegroundColor Yellow
            Write-Host "Reason:    " -NoNewline -ForegroundColor DarkGray
            Write-Host "Certificate chain not trusted or revocation unavailable"
        }
        "SignedInvalid" {
            Write-Host "Signature: " -NoNewline -ForegroundColor DarkGray
            Write-Host "Invalid" -ForegroundColor Red
            Write-Host "Reason:    " -NoNewline -ForegroundColor DarkGray
            Write-Host "Signature verification failed or certificate expired"
        }
    }
}

function Protect-MessageSmime {
    <#
    .SYNOPSIS
    Sign and/or encrypt message for sending
    Phase 3: Implementation for outgoing S/MIME
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,
        
        [bool]$Sign = $false,
        [bool]$Encrypt = $false
    )
    
    # Phase 3: Not yet implemented
    Write-Error-Message "S/MIME signing/encryption not yet implemented"
    return $false
}

function Verify-MessageSmime {
    <#
    .SYNOPSIS
    Verify S/MIME signature on received message
    Phase 2: Full implementation
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MessageId
    )
    
    # Phase 2: Not yet implemented
    # Steps:
    # 1. Fetch MIME content via Get-MessageMime
    # 2. Detect if multipart/signed or application/pkcs7-mime
    # 3. Use .NET SignedCms to verify signature
    # 4. Validate certificate chain using X509Chain
    # 5. Check against Windows root store
    # 6. Handle revocation (online check with fallback)
    # 7. Return appropriate status
    
    return $Config.SmimeStatus.None
}

<#
.NOTES
Phase 2 Implementation Plan (S/MIME Verification):

1. MIME Detection:
   - Parse Content-Type header
   - Check for multipart/signed or application/pkcs7-mime
   
2. Signature Verification:
   - Use [System.Security.Cryptography.Pkcs.SignedCms]
   - Load MIME content
   - Call CheckSignature()
   
3. Certificate Validation:
   - Extract signer certificate
   - Create [System.Security.Cryptography.X509Certificates.X509Chain]
   - Set ChainPolicy for Windows root store
   - Enable revocation checking with online fallback
   
4. Status Determination:
   - SignedTrusted: Signature valid + chain trusted
   - SignedUntrusted: Signature valid + chain issues/revocation unavailable
   - SignedInvalid: Signature broken or cert expired
   
5. Certificate Info Display:
   - Extract: Subject, Issuer, Valid Until
   - Format as per spec in email.txt
#>

<#
.NOTES
Phase 3 Implementation Plan (S/MIME Sending):

1. Certificate Selection:
   - Query CurrentUser\My certificate store
   - Find cert with private key for signing
   - Find recipient certs for encryption
   
2. Signing:
   - Create ContentInfo from message body
   - Create SignedCms
   - Compute signature
   - Convert to MIME format
   
3. Encryption:
   - Verify all recipients have certificates
   - Create EnvelopedCms
   - Add recipients
   - Encrypt content
   
4. Combined Sign+Encrypt:
   - Sign first, then encrypt
   - Proper MIME structure
   
5. MIME Upload:
   - Use Graph API to upload MIME content
   - Only use MIME when S/MIME is enabled
#>
