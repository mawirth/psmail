#requires -Version 7.0

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$files = @(
  (Join-Path $repoRoot 'src\smime.ps1'),
  (Join-Path $repoRoot 'src\drafts.ps1'),
  (Join-Path $repoRoot 'src\mail_read.ps1'),
  (Join-Path $repoRoot 'src\config.ps1'),
  (Join-Path $repoRoot 'src\state.ps1'),
  (Join-Path $repoRoot 'src\mail_list.ps1'),
  (Join-Path $repoRoot 'src\ui.ps1'),
  (Join-Path $repoRoot 'src\graph.ps1'),
  (Join-Path $repoRoot 'src\util.ps1'),
  (Join-Path $repoRoot 'psmail.ps1'),
  (Join-Path $repoRoot 'tools\Create-Footer.ps1')
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
