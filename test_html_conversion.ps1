# Test HTML to Text conversion
. .\src\mail_read.ps1

# Test 1: Table with divs (should be removed)
$testHtml1 = @"
<table>
  <tr>
    <td><div>N</div></td>
    <td><div>e</div></td>
  </tr>
</table>
<p>This should remain</p>
"@

# Test 2: Divs outside table (like eBay email)
$testHtml2 = @"
<div>E</div>
<div>D</div>
<div>N</div>
<div>E</div>
<p>Normal text</p>
"@

$testHtml = $testHtml2

Write-Host "=== Original HTML ===" -ForegroundColor Cyan
Write-Host $testHtml

# Manual step-by-step processing
Write-Host "`n=== Step-by-step processing ===" -ForegroundColor Yellow
$text = $testHtml

Write-Host "After removing table tags:"
$text = $text -replace '(?si)</?table[^>]*>', ''
$text = $text -replace '(?si)</?tbody[^>]*>', ''
$text = $text -replace '(?si)</?tr[^>]*>', ' '
$text = $text -replace '(?si)</?t[dh][^>]*>', ''
Write-Host "[$text]"

Write-Host "`nAfter removing div/p/span as spaces:"
$text = $text -replace '(?si)</?(div|p|span)[^>]*>', ' '
Write-Host "[$text]"

Write-Host "`n=== Converted Text ===" -ForegroundColor Cyan
$result = Convert-HtmlToText $testHtml
Write-Host $result

Write-Host "`n=== Each line separately ===" -ForegroundColor Cyan
$result -split "`n" | ForEach-Object { Write-Host "Line: [$_]" }
