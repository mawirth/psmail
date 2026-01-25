# attachments.ps1
# Attachment save logic

function Invoke-SaveAttachment {
    <#
    .SYNOPSIS
    Save a specific attachment
    #>
    param(
        [Parameter(Mandatory)]
        [int]$AttachmentIndex
    )
    
    if (-not $global:State.OpenMessageId) {
        Write-Error-Message "No message is currently open"
        return
    }
    
    # Get attachments
    $rawAttachments = Get-MessageAttachments `
        -MessageId $global:State.OpenMessageId
    
    # Check if it's a single attachment
    # or array or value wrapper
    if ($rawAttachments -is [hashtable]) {
        if ($rawAttachments.ContainsKey('value')) {
            $attachments = $rawAttachments['value']
        } elseif ($rawAttachments.ContainsKey('@odata.type')) {
            $attachments = @($rawAttachments)
        } else {
            $attachments = $rawAttachments
        }
    } else {
        $attachments = $rawAttachments
    }
    
    # Ensure we have an array
    if ($attachments -isnot [System.Array]) {
        $attachments = @($attachments)
    }
    
    if (-not $attachments -or $attachments.Count -eq 0) {
        Write-Error-Message "No attachments found"
        return
    }
    
    # Filter to only file attachments
    $attachments = @($attachments | Where-Object {
        $type = if ($_ -is [hashtable]) {
            $_['@odata.type']
        } else {
            $_.'@odata.type'
        }
        $type -eq '#microsoft.graph.fileAttachment'
    })
    
    if ($AttachmentIndex -lt 1 -or `
        $AttachmentIndex -gt $attachments.Count) {
        Write-Error-Message "Invalid attachment number"
        return
    }
    
    $attachment = $attachments[$AttachmentIndex - 1]
    
    # Fetch full attachment data
    $attData = Get-Attachment `
        -MessageId $global:State.OpenMessageId `
        -AttachmentId $attachment.id
    
    if (-not $attData) {
        Write-Error-Message "Failed to retrieve attachment"
        return
    }
    
    # Create attachments directory if needed
    $attachDir = Join-Path (Get-Location).Path $Config.AttachmentsConfig.SaveDirectory
    if (-not (Test-Path $attachDir)) {
        New-Item -Path $attachDir -ItemType Directory -Force | Out-Null
    }
    
    # Save to attachments directory
    $fileName = $attData.name
    $targetPath = Resolve-FilePath `
        -Directory $attachDir `
        -FileName $fileName
    
    # Decode and save
    try {
        $bytes = [Convert]::FromBase64String($attData.contentBytes)
        [System.IO.File]::WriteAllBytes($targetPath, $bytes)
        Write-Success "Saved: $targetPath"
    } catch {
        Write-Error-Message "Failed to save: $($_.Exception.Message)"
    }
}

function Invoke-SaveAllAttachments {
    <#
    .SYNOPSIS
    Save all non-inline attachments
    #>
    
    if (-not $global:State.OpenMessageId) {
        Write-Error-Message "No message is currently open"
        return
    }
    
    # Get attachments
    $rawAttachments = Get-MessageAttachments `
        -MessageId $global:State.OpenMessageId
    
    # Check if it's a single attachment
    # or array or value wrapper
    if ($rawAttachments -is [hashtable]) {
        if ($rawAttachments.ContainsKey('value')) {
            $attachments = $rawAttachments['value']
        } elseif ($rawAttachments.ContainsKey('@odata.type')) {
            $attachments = @($rawAttachments)
        } else {
            $attachments = $rawAttachments
        }
    } else {
        $attachments = $rawAttachments
    }
    
    # Ensure we have an array
    if ($attachments -isnot [System.Array]) {
        $attachments = @($attachments)
    }
    
    if (-not $attachments -or $attachments.Count -eq 0) {
        Write-Error-Message "No attachments found"
        return
    }
    
    # Filter to file attachments that are not inline
    $toSave = @($attachments | Where-Object {
        $type = if ($_ -is [hashtable]) {
            $_['@odata.type']
        } else {
            $_.'@odata.type'
        }
        $isInline = if ($_ -is [hashtable]) {
            $_['isInline']
        } else {
            $_.isInline
        }
        $type -eq '#microsoft.graph.fileAttachment' `
            -and -not $isInline
    })
    
    if ($toSave.Count -eq 0) {
        Write-Info "No non-inline attachments to save"
        return
    }
    
    # Create attachments directory if needed
    $attachDir = Join-Path (Get-Location).Path $Config.AttachmentsConfig.SaveDirectory
    if (-not (Test-Path $attachDir)) {
        New-Item -Path $attachDir -ItemType Directory -Force | Out-Null
    }
    
    Write-Host "Saving $($toSave.Count) attachment(s)..." `
        -ForegroundColor $Config.Colors.LoadingMore
    
    $saved = 0
    foreach ($attachment in $toSave) {
        # Fetch full data
        $attData = Get-Attachment `
            -MessageId $global:State.OpenMessageId `
            -AttachmentId $attachment.id
        
        if (-not $attData) {
            Write-Error-Message "Failed to retrieve: $($attachment.name)"
            continue
        }
        
        # Save
        $fileName = $attData.name
        $targetPath = Resolve-FilePath `
            -Directory $attachDir `
            -FileName $fileName
        
        try {
            $bytes = [Convert]::FromBase64String($attData.contentBytes)
            [System.IO.File]::WriteAllBytes($targetPath, $bytes)
            Write-Host "  $fileName" -ForegroundColor $Config.Colors.Success
            $saved++
        } catch {
            Write-Error-Message "Failed to save $fileName"
        }
    }
    
    Write-Success "Saved $saved of $($toSave.Count) attachments"
}

function Show-Attachments {
    <#
    .SYNOPSIS
    List attachments for current message
    #>
    
    if (-not $global:State.OpenMessageId) {
        Write-Error-Message "No message is currently open"
        return
    }
    
    $rawAttachments = Get-MessageAttachments `
        -MessageId $global:State.OpenMessageId
    
    # Check if it's a single attachment
    # or array or value wrapper
    if ($rawAttachments -is [hashtable]) {
        if ($rawAttachments.ContainsKey('value')) {
            $attachments = $rawAttachments['value']
        } elseif ($rawAttachments.ContainsKey('@odata.type')) {
            $attachments = @($rawAttachments)
        } else {
            $attachments = $rawAttachments
        }
    } else {
        $attachments = $rawAttachments
    }
    
    # Ensure we have an array
    if ($attachments -isnot [System.Array]) {
        $attachments = @($attachments)
    }
    
    if (-not $attachments -or $attachments.Count -eq 0) {
        Write-Host "No attachments." -ForegroundColor $Config.Colors.NoMessages
        return
    }
    
    # Filter to file attachments only
    $attachments = @($attachments | Where-Object {
        $type = if ($_ -is [hashtable]) {
            $_['@odata.type']
        } else {
            $_.'@odata.type'
        }
        $type -eq '#microsoft.graph.fileAttachment'
    })
    
    if ($attachments.Count -eq 0) {
        Write-Host "No file attachments." -ForegroundColor $Config.Colors.NoMessages
        return
    }
    
    Write-Header "Attachments"
    
    $index = 1
    foreach ($att in $attachments) {
        $inline = if ($att.isInline) { " (inline)" } else { "" }
        $sizeKB = [math]::Round($att.size / 1024, 1)
        
        Write-Host ("{0,2}. {1,-40} {2,8} KB{3}" `
            -f $index, $att.name, $sizeKB, $inline)
        $index++
    }
    
    Write-Host ""
}
