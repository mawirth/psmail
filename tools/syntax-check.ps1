$files = @(
  'C:\Users\marti\OneDrive\psmail\src\smime.ps1',
  'C:\Users\marti\OneDrive\psmail\src\drafts.ps1',
  'C:\Users\marti\OneDrive\psmail\src\mail_read.ps1',
  'C:\Users\marti\OneDrive\psmail\src\config.ps1',
  'C:\Users\marti\OneDrive\psmail\src\state.ps1',
  'C:\Users\marti\OneDrive\psmail\src\mail_list.ps1',
  'C:\Users\marti\OneDrive\psmail\src\ui.ps1',
  'C:\Users\marti\OneDrive\psmail\src\graph.ps1',
  'C:\Users\marti\OneDrive\psmail\src\util.ps1',
  'C:\Users\marti\OneDrive\psmail\psmail.ps1'
)

$allOk = $true
foreach ($f in $files) {
  $tok = $null
  $err = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
  if ($err.Count -gt 0) {
    Write-Host "ERRORS in $f" -ForegroundColor Red
    foreach ($e in $err) {
      Write-Host "  Line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
    }
    $allOk = $false
  } else {
    Write-Host "OK: $(Split-Path $f -Leaf)" -ForegroundColor Green
  }
}

if ($allOk) { Write-Host "`nAll files OK" -ForegroundColor Green }
else         { Write-Host "`nSyntax errors found!" -ForegroundColor Red }
