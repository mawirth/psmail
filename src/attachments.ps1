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
    
    $attachments = Get-MessageAttachments -MessageId $global:State.OpenMessageId
    
    if ($attachments.Count -eq 0) {
        Write-Error-Message "No attachments found"
        return
    }
    
    # Filter to real user-visible file attachments only. S/MIME signatures can
    # arrive from Graph as fileAttachment objects, but they are message
    # structure rather than files the user intentionally attached.
    $attachments = @($attachments | Where-Object {
        $_.'@odata.type' -eq '#microsoft.graph.fileAttachment' -and
        -not (Test-IsSmimeStructuralAttachment `
            -Attachment $_ -MessageId $global:State.OpenMessageId)
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
    $attachDir = $Config.AttachmentsConfig.SaveDirectory
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
    
    $attachments = Get-MessageAttachments -MessageId $global:State.OpenMessageId
    
    if ($attachments.Count -eq 0) {
        Write-Error-Message "No attachments found"
        return
    }
    
    # File attachments that are not inline and not S/MIME structure blobs.
    $toSave = @($attachments | Where-Object {
        $_.'@odata.type' -eq '#microsoft.graph.fileAttachment' -and
        -not $_.isInline -and
        -not (Test-IsSmimeStructuralAttachment `
            -Attachment $_ -MessageId $global:State.OpenMessageId)
    })
    
    if ($toSave.Count -eq 0) {
        Write-Info "No non-inline attachments to save"
        return
    }
    
    # Create attachments directory if needed
    $attachDir = $Config.AttachmentsConfig.SaveDirectory
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
    
    $attachments = Get-MessageAttachments -MessageId $global:State.OpenMessageId
    
    if ($attachments.Count -eq 0) {
        Write-Host "No attachments." -ForegroundColor $Config.Colors.NoMessages
        return
    }
    
    # Filter to real user-visible file attachments only.
    $attachments = @($attachments | Where-Object {
        $_.'@odata.type' -eq '#microsoft.graph.fileAttachment' -and
        -not (Test-IsSmimeStructuralAttachment `
            -Attachment $_ -MessageId $global:State.OpenMessageId)
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
