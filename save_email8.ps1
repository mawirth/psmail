# Load psmail modules
. .\src\config.ps1
. .\src\util.ps1
. .\src\auth.ps1
. .\src\graph.ps1

# Connect
if (-not (Connect-GraphMail)) {
    Write-Error "Failed to connect"
    exit 1
}

# Get inbox messages
$messages = Get-FolderMessages -FolderId $Config.Folders.Inbox -Top 20

# Debug - show all subjects
Write-Host "Found $($messages.value.Count) messages"
$messages.value | Select-Object -First 10 | ForEach-Object { Write-Host "  - $($_.subject)" }

# Find email 8 (Re: Alter Envmod1 VCO tests)
$msg8 = $messages.value | Where-Object { $_.subject -like '*VCO*' } | Select-Object -First 1

if ($msg8) {
    $fullMsg = Get-Message -MessageId $msg8.id
    $fullMsg.body.content | Out-File "email8_original.html" -Encoding UTF8
    Write-Host "Saved to email8_original.html"
    Write-Host "Content type: $($fullMsg.body.contentType)"
    Write-Host "Length: $($fullMsg.body.content.Length) chars"
} else {
    Write-Host "Email not found"
}
