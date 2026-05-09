#requires -Version 7.0

$repoRoot = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot "..")
)
$files = @(
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'smime.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'drafts.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'mail_read.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'config.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'state.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'mail_list.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'ui.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'graph.ps1'),
  (Join-Path $repoRoot 'src' -AdditionalChildPath 'util.ps1'),
  (Join-Path $repoRoot 'psmail.ps1'),
  (Join-Path $repoRoot 'tools' -AdditionalChildPath 'Create-Footer.ps1')
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
