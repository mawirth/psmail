# editor.ps1
# nvim integration

function Edit-DraftInEditor {
    <#
    .SYNOPSIS
    Open content in nvim for editing
    #>
    param([string]$Content)
    
    # Create temp file
    $tempFile = [System.IO.Path]::GetTempFileName()
    $tempFile = [System.IO.Path]::ChangeExtension($tempFile, ".txt")
    
    # Write content with Unix line endings (LF only)
    # Replace CRLF with LF for neovim
    $Content = $Content -replace "`r`n", "`n"
    $Content = $Content -replace "`r", "`n"
    
    [System.IO.File]::WriteAllText($tempFile, $Content, [System.Text.UTF8Encoding]::new($false))
    
    # Get hash before edit
    $hashBefore = Get-FileHash -Path $tempFile -Algorithm MD5
    
    # Open editor and wait for it to finish
    try {
        # Check if editor exists
        $editorPath = (Get-Command $Config.Editor -ErrorAction SilentlyContinue).Source
        if (-not $editorPath) {
            Write-Error-Message "Editor '$($Config.Editor)' not found in PATH"
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            return @{
                Changed = $false
                Content = $null
            }
        }
        
        # Start editor
        $process = Start-Process -FilePath $editorPath `
            -ArgumentList $tempFile `
            -Wait `
            -NoNewWindow `
            -PassThru `
            -ErrorAction Stop
        
        # Check exit code (nvim exits with 0 on :wq, 1 on :q!)
        # We don't treat non-zero as error, just check if file changed
        
    } catch {
        Write-Error-Message "Failed to launch editor: $($_.Exception.Message)"
        Write-Host "Debug: Editor=$($Config.Editor), TempFile=$tempFile" -ForegroundColor DarkGray
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        return @{
            Changed = $false
            Content = $null
        }
    }
    
    # Check if file was modified
    if (-not (Test-Path $tempFile)) {
        return @{
            Changed = $false
            Content = $null
        }
    }
    
    $hashAfter = Get-FileHash -Path $tempFile -Algorithm MD5
    $changed = $hashBefore.Hash -ne $hashAfter.Hash
    
    # Read modified content
    $newContent = Get-Content -Path $tempFile -Raw -Encoding utf8
    
    # Clean up
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    
    return @{
        Changed = $changed
        Content = $newContent
    }
}
