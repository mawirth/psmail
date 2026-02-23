# FINAL TEST - Load fresh and test
# Do NOT dot-source, define function inline to avoid any caching

function Test-Convert {
    param([string]$Html)
    
    $text = $Html
    
    # Remove tables completely
    $text = $text -replace '(?si)<table[^>]*>.*?</table>', ''
    
    # Remove div/p/span as spaces
    $text = $text -replace '(?si)</?(div|p|span)[^>]*>', ' '
    
    # Remove all HTML tags
    $text = $text -replace '<[^>]+>', ''
    
    # Remove invisible Unicode
    $text = $text -replace '[\u200B-\u200D\uFEFF\u00AD]', ''
    
    # Collapse whitespace
    $text = $text -replace '\s+', ' '
    
    return $text.Trim()
}

$html1 = "<table><tr><td><div>E</div></td></tr><tr><td><div>D</div></td></tr></table><div>Normal</div>"
$html2 = "<div>E</div><div>D</div><div>N</div><p>Text</p>"

Write-Host "Test 1 (table with single chars):"
$result1 = Test-Convert $html1
Write-Host "  Result: [$result1]"
Write-Host "  Expected: [Normal]"
Write-Host "  Match: $($result1 -eq 'Normal')"
Write-Host ""

Write-Host "Test 2 (divs with single chars):"
$result2 = Test-Convert $html2
Write-Host "  Result: [$result2]"
Write-Host "  Expected: [E D N Text]"
Write-Host "  Match: $($result2 -eq 'E D N Text')"
