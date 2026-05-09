#requires -Version 7.0

$repoRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot "..")
)

$pester = Get-Module -ListAvailable -Name Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host "Pester is not installed." -ForegroundColor Yellow
    Write-Host "Install with: Install-Module Pester -Scope CurrentUser"
    exit 2
}

Import-Module Pester -ErrorAction Stop
$testPath = Join-Path $repoRoot "tests"

if ($pester.Version.Major -ge 5) {
    Invoke-Pester -Path $testPath -Output Detailed
} else {
    Invoke-Pester -Script $testPath
}
