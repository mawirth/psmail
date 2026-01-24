# util.ps1
# Formatting helpers and utilities

function Truncate-String {
    param(
        [string]$String,
        [int]$MaxLength
    )
    
    if ([string]::IsNullOrWhiteSpace($String)) {
        return ""
    }
    
    if ($String.Length -le $MaxLength) {
        return $String
    }
    
    return ($String.Substring(0, $MaxLength - 1) + "…")
}

function Format-DateTime {
    param([datetime]$DateTime)
    
    return $DateTime.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
}

function Format-DateOnly {
    param([datetime]$DateTime)
    
    return $DateTime.ToLocalTime().ToString("yyyy-MM-dd")
}

function Get-SmimeIcon {
    param([string]$Status)
    
    switch ($Status) {
        "SignedTrusted"   { return "✔" }
        "SignedUntrusted" { return "~" }
        "SignedInvalid"   { return "✖" }
        default           { return " " }
    }
}

function Get-UnreadIcon {
    param([bool]$IsUnread)
    
    if ($IsUnread) { return "*" } else { return " " }
}

function Write-Header {
    param([string]$Text)
    
    Write-Host ""
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("-" * $Text.Length) -ForegroundColor DarkGray
}

function Write-Error-Message {
    param([string]$Message)
    
    Write-Host "Error: $Message" -ForegroundColor Red
}

function Write-Success {
    param([string]$Message)
    
    Write-Host $Message -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    
    Write-Host $Message -ForegroundColor DarkGray
}

function Resolve-FilePath {
    param(
        [string]$Directory,
        [string]$FileName
    )
    
    $basePath = Join-Path $Directory $FileName
    
    if (-not (Test-Path $basePath)) {
        return $basePath
    }
    
    $ext = [System.IO.Path]::GetExtension($FileName)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    
    $counter = 1
    while ($true) {
        $newName = "${name} (${counter})${ext}"
        $newPath = Join-Path $Directory $newName
        
        if (-not (Test-Path $newPath)) {
            return $newPath
        }
        $counter++
    }
}

function Parse-IndexRange {
    <#
    .SYNOPSIS
    Parse index input - supports single number ("3") or range ("2-5")
    
    .DESCRIPTION
    Parses user input for message indices and returns array of all indices.
    Supports both single numbers and ranges (e.g., "2-5" returns 2,3,4,5).
    
    .PARAMETER InputString
    The input string containing either a single number or a range
    
    .EXAMPLE
    Parse-IndexRange "3" returns @(3)
    Parse-IndexRange "2-5" returns @(2,3,4,5)
    #>
    param([string]$InputString)
    
    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return $null
    }
    
    $InputString = $InputString.Trim()
    
    # Check if it's a range (contains "-")
    if ($InputString -match '^(\d+)-(\d+)$') {
        $start = [int]$matches[1]
        $end = [int]$matches[2]
        
        # Validate range
        if ($start -lt 1 -or $end -lt 1) {
            return $null
        }
        
        if ($start -gt $end) {
            # Swap if user entered reversed range
            $temp = $start
            $start = $end
            $end = $temp
        }
        
        # Generate array of indices
        return @($start..$end)
    }
    # Check if it's a single number
    elseif ($InputString -match '^\d+$') {
        return @([int]$InputString)
    }
    else {
        # Invalid format
        return $null
    }
}

function Format-WordWrap {
    <#
    .SYNOPSIS
    Wrap text at word boundaries, not in the middle of words
    #>
    param(
        [string]$Text,
        [int]$Width
    )
    
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @("")
    }
    
    if ($Text.Length -le $Width) {
        return @($Text)
    }
    
    $result = @()
    $words = $Text -split '\s+'
    $currentLine = ""
    
    foreach ($word in $words) {
        # If word itself is longer than width, break it
        if ($word.Length -gt $Width) {
            # Flush current line if not empty
            if ($currentLine.Length -gt 0) {
                $result += $currentLine.TrimEnd()
                $currentLine = ""
            }
            
            # Break long word into chunks
            $start = 0
            while ($start -lt $word.Length) {
                $chunkLength = [Math]::Min($Width, $word.Length - $start)
                $result += $word.Substring($start, $chunkLength)
                $start += $chunkLength
            }
            continue
        }
        
        # Check if adding this word would exceed width
        $testLine = if ($currentLine.Length -eq 0) {
            $word
        } else {
            "$currentLine $word"
        }
        
        if ($testLine.Length -le $Width) {
            # Word fits, add it
            $currentLine = $testLine
        } else {
            # Word doesn't fit, flush current line and start new one
            if ($currentLine.Length -gt 0) {
                $result += $currentLine
            }
            $currentLine = $word
        }
    }
    
    # Add final line
    if ($currentLine.Length -gt 0) {
        $result += $currentLine
    }
    
    return $result
}
