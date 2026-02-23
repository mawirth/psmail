# Test whitespace collapsing
$text = @"
E
D
N
E
"@

Write-Host "Before:"
Write-Host "[$text]"
Write-Host ""

# Apply the regex
$text = $text -replace '\s+', ' '

Write-Host "After \s+ replace:"
Write-Host "[$text]"
Write-Host ""

# Split and check
$lines = $text -split "`n"
Write-Host "Lines after split:"
foreach ($line in $lines) {
    Write-Host "  [$line]"
}
