BeforeAll {
    function Invoke-IsolatedPwsh {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ScriptText
        )

        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptText))
        $output = & pwsh -NoLogo -NoProfile -EncodedCommand $encoded 2>&1
        $exitCode = $LASTEXITCODE

        [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = @($output)
        }
    }

    $GitWorktreesModulePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\src\GitWorktrees\GitWorktrees.psd1")).Path
}

Describe "GitWorktrees Set-Location wrapper lifecycle" {
    It "wraps Set-Location and restores cmdlet on unload" {
        $scriptText = @"
Import-Module -Name '$GitWorktreesModulePath' -Force
`$duringType = (Get-Command Set-Location).CommandType
`$duringWrapped = (Get-Command Set-Location).ScriptBlock.ToString().Contains('Set-LocationEx @PSBoundParameters')
Remove-Module GitWorktrees -Force
`$afterType = (Get-Command Set-Location).CommandType
'{0}|{1}|{2}' -f `$duringType, `$duringWrapped, `$afterType
"@
        $result = Invoke-IsolatedPwsh -ScriptText $scriptText

        $result.ExitCode | Should -Be 0
        $result.Output[-1] | Should -Be "Function|True|Cmdlet"
    }

    It "restores pre-existing Set-Location function wrapper on unload" {
        $scriptText = @"
function global:Set-Location {
    param([string]`$Path, [switch]`$PassThru)
    Microsoft.PowerShell.Management\Set-Location @PSBoundParameters
}
Import-Module -Name '$GitWorktreesModulePath' -Force
Remove-Module GitWorktrees -Force
`$restoredType = (Get-Command Set-Location).CommandType
`$restoredContainsOriginal = (Get-Command Set-Location).ScriptBlock.ToString().Contains('Microsoft.PowerShell.Management\Set-Location @PSBoundParameters')
'{0}|{1}' -f `$restoredType, `$restoredContainsOriginal
"@
        $result = Invoke-IsolatedPwsh -ScriptText $scriptText

        $result.ExitCode | Should -Be 0
        $result.Output[-1] | Should -Be "Function|True"
    }

    It "does not double-wrap Set-Location when imported with -Force twice" {
        $scriptText = @"
Import-Module -Name '$GitWorktreesModulePath' -Force
Import-Module -Name '$GitWorktreesModulePath' -Force
`$scriptBody = (Get-Command Set-Location).ScriptBlock.ToString()
`$wrapCount = ([regex]::Matches(`$scriptBody, 'Set-LocationEx @PSBoundParameters')).Count
Remove-Module GitWorktrees -Force
`$wrapCount
"@
        $result = Invoke-IsolatedPwsh -ScriptText $scriptText

        $result.ExitCode | Should -Be 0
        $result.Output[-1] | Should -Be "1"
    }
}
