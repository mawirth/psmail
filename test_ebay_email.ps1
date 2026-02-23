# Load the conversion function
. .\src\mail_read.ps1

# Test 1: Simple tables (should work)
$simpleHtml = @"
<table>
  <tr><td><div>E</div></td></tr>
  <tr><td><div>D</div></td></tr>
</table>
<div>Text after</div>
"@

# Test 2: Nested tables (problem?)
$nestedHtml = @"
<table>
  <tr>
    <td>
      <table>
        <tr><td><div>E</div></td></tr>
        <tr><td><div>D</div></td></tr>
      </table>
    </td>
  </tr>
</table>
<div>Text after</div>
"@

$ebayHtml = $nestedHtml

Write-Host "=== Testing eBay-like HTML ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Input HTML (shortened):"
Write-Host $ebayHtml.Substring(0, [Math]::Min(200, $ebayHtml.Length))
Write-Host "..."
Write-Host ""

$result = Convert-HtmlToText $ebayHtml

Write-Host "=== Converted Result ===" -ForegroundColor Green
Write-Host $result
Write-Host ""

Write-Host "=== Lines (should be minimal) ===" -ForegroundColor Yellow
$lines = $result -split "`n"
Write-Host "Total lines: $($lines.Count)"
foreach ($i in 0..([Math]::Min(10, $lines.Count-1))) {
    Write-Host "Line $($i+1): [$($lines[$i])]"
}

if ($result -match "E\s+D\s+b" -or $result -notmatch "[ED]") {
    Write-Host ""
    Write-Host "✓ SUCCESS: Single-char layout tables removed!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "✗ FAIL: Still seeing single characters on separate lines" -ForegroundColor Red
}
