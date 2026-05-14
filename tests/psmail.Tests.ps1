#requires -Version 7.0

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:RepoRoot 'src' -AdditionalChildPath 'config.ps1')
. (Join-Path $script:RepoRoot 'src' -AdditionalChildPath 'util.ps1')
. (Join-Path $script:RepoRoot 'src' -AdditionalChildPath 'state.ps1')
. (Join-Path $script:RepoRoot 'src' -AdditionalChildPath 'accounts.ps1')
. (Join-Path $script:RepoRoot 'src' -AdditionalChildPath 'mail_read.ps1')

Describe "Parse-IndexRange" {
    It "parses comma-separated numbers and ranges in sorted order" {
        (Parse-IndexRange "3,1,2-4") -join "," | Should Be "1,2,3,4"
    }

    It "normalizes reversed ranges" {
        (Parse-IndexRange "5-3") -join "," | Should Be "3,4,5"
    }

    It "returns null for invalid input" {
        Parse-IndexRange "1,a" | Should BeNullOrEmpty
    }
}

Describe "Read view wrapping" {
    It "estimates wrapped rows without changing the original line" {
        $url = "https://example.com/" + ("a" * 81)

        Get-ConsoleWrappedLineCount -Line $url -Width 40 | Should Be 3
        $url | Should Be ("https://example.com/" + ("a" * 81))
    }

    It "counts the terminating newline after an exact-width line" {
        Get-ConsoleWrappedLineCount -Line ("x" * 40) -Width 40 | Should Be 1
        Get-ConsoleWrappedLineCount -Line ("x" * 41) -Width 40 | Should Be 2
        Get-ConsoleWrappedLineCount -Line ("x" * 80) -Width 40 | Should Be 2
        Get-ConsoleWrappedLineCount -Line ("x" * 81) -Width 40 | Should Be 3
    }

    It "counts empty and control-sequence-only lines as one row" {
        Get-ConsoleWrappedLineCount -Line "" -Width 40 | Should Be 1
        Get-ConsoleWrappedLineCount -Line "$([char]27)[31m$([char]27)[0m" -Width 40 |
            Should Be 1
    }

    It "expands tabs when estimating display cells" {
        Get-ConsoleDisplayCellCount -Text "a`tbc" | Should Be 10
    }

    It "reserves lines for the main menu printed after reading" {
        Get-PostOpenMessageLineCount -View "inbox" -Width 120 | Should BeGreaterThan 8
    }

    It "uses height minus one as the read-view cursor target" {
        $oldTermProgram = $env:TERM_PROGRAM
        $oldWarpSession = $env:WARP_IS_LOCAL_SHELL_SESSION
        try {
            $env:TERM_PROGRAM = ""
            $env:WARP_IS_LOCAL_SHELL_SESSION = ""

            Get-ReadViewTargetRowsFromHeaderStart -ConsoleHeight 30 | Should Be 29
            Get-ReadViewTargetRowsFromHeaderStart -ConsoleHeight 0 | Should Be 24
        } finally {
            $env:TERM_PROGRAM = $oldTermProgram
            $env:WARP_IS_LOCAL_SHELL_SESSION = $oldWarpSession
        }
    }

    It "accounts for Warp's pinned command header" {
        $oldTermProgram = $env:TERM_PROGRAM
        $oldWarpSession = $env:WARP_IS_LOCAL_SHELL_SESSION
        try {
            $env:TERM_PROGRAM = "WarpTerminal"
            $env:WARP_IS_LOCAL_SHELL_SESSION = "1"

            Get-TerminalViewportTopInset | Should Be 2
            Get-ReadViewTargetRowsFromHeaderStart -ConsoleHeight 31 | Should Be 28
        } finally {
            $env:TERM_PROGRAM = $oldTermProgram
            $env:WARP_IS_LOCAL_SHELL_SESSION = $oldWarpSession
        }
    }
}

Describe "Account storage keys" {
    It "normalizes personal account keys" {
        ConvertTo-AccountStorageKey `
            -Email "USER@Example.COM " `
            -TenantId "" |
            Should Be "user@example.com__consumers"
    }

    It "normalizes tenant identifiers" {
        ConvertTo-AccountStorageKey `
            -Email "user@example.com" `
            -TenantId " Tenant Id " |
            Should Be "user@example.com__tenant_id"
    }
}

Describe "Account-specific local state" {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ("psmail-tests-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $Config.DataRootPath = $script:TempRoot
        $Config.AccountsDataPath = Join-Path $script:TempRoot "accounts"
        $Config.AccountProfilesPath = Join-Path $script:TempRoot `
            "account-profiles.json"
    }

    AfterEach {
        if (Test-Path $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It "sets different cache paths for different accounts" {
        Set-AccountStoragePaths -Email "private@example.com" -TenantId "consumers"
        $privateCache = $Config.SmimeCachePath
        $privateAttachments = $Config.AttachmentsConfig.SaveDirectory

        Set-AccountStoragePaths -Email "office@example.com" -TenantId "tenant"
        $officeCache = $Config.SmimeCachePath
        $officeAttachments = $Config.AttachmentsConfig.SaveDirectory

        $privateCache | Should Not Be $officeCache
        $privateAttachments | Should Not Be $officeAttachments
        $privateCache | Should Match "private@example.com__consumers"
        $officeCache | Should Match "office@example.com__tenant"
        $privateAttachments | Should Match "private@example.com__consumers"
        $officeAttachments | Should Match "office@example.com__tenant"
    }

    It "loads S/MIME cache from the active account path only" {
        Set-AccountStoragePaths -Email "private@example.com" -TenantId "consumers"
        New-Item -ItemType Directory -Path $Config.CurrentAccount.DataPath -Force |
            Out-Null
        @{
            privateMessage = @{
                Status = $Config.SmimeStatus.SignedTrusted
                IsEncrypted = $false
                Subject = "private"
            }
        } | ConvertTo-Json -Depth 3 |
            Set-Content $Config.SmimeCachePath -Encoding utf8NoBOM

        Set-AccountStoragePaths -Email "office@example.com" -TenantId "tenant"
        New-Item -ItemType Directory -Path $Config.CurrentAccount.DataPath -Force |
            Out-Null
        @{
            officeMessage = @{
                Status = $Config.SmimeStatus.Encrypted
                IsEncrypted = $true
                Subject = "office"
            }
        } | ConvertTo-Json -Depth 3 |
            Set-Content $Config.SmimeCachePath -Encoding utf8NoBOM

        Initialize-State
        $global:State.SmimeCache.ContainsKey("officeMessage") | Should Be $true
        $global:State.SmimeCache.ContainsKey("privateMessage") | Should Be $false
    }
}

Describe "Account profiles" {
    BeforeEach {
        $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ("psmail-tests-{0}" -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        $Config.DataRootPath = $script:TempRoot
        $Config.AccountsDataPath = Join-Path $script:TempRoot "accounts"
        $Config.AccountProfilesPath = Join-Path $script:TempRoot `
            "account-profiles.json"
    }

    AfterEach {
        if (Test-Path $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }
    }

    It "registers the actually connected account profile" {
        Set-AccountStoragePaths -Email "office@example.com" -TenantId "tenant"

        Register-CurrentAccountProfile | Out-Null
        $profiles = Read-AccountProfiles

        $profiles.ContainsKey("office@example.com__tenant") | Should Be $true
        $profiles["office@example.com__tenant"].Email |
            Should Be "office@example.com"
    }
}
