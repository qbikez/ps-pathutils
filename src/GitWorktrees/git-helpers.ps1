function global:Register-GitWorktreeProvider {
    [CmdletBinding()]
    param()

    $providerName = 'WtProvider'
    $providerLoaded = $null -ne (Get-PSProvider -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $providerName })

    if (-not $providerLoaded) {
        function Test-WtProviderAssemblyCompatibility {
            param(
                [Parameter(Mandatory = $true)]
                [string]$AssemblyPath
            )

            try {
                $null = [System.Reflection.AssemblyName]::GetAssemblyName($AssemblyPath)
                return $true
            }
            catch {
                return $false
            }
        }

        $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
        $providerProjectDir = Join-Path -Path $moduleRoot -ChildPath 'PathUtils.WtProvider'
        $providerProjectPath = Join-Path -Path $providerProjectDir -ChildPath 'PathUtils.WtProvider.csproj'
        $providerSourcePath = Join-Path -Path $providerProjectDir -ChildPath 'WtProvider.cs'
        $providerLibDir = Join-Path -Path $PSScriptRoot -ChildPath 'lib'
        $packagedAssemblyPath = Join-Path -Path $providerLibDir -ChildPath 'PathUtils.WtProvider.dll'
        $sessionStamp = "pwsh-$($PSVersionTable.PSVersion)-pid-$PID"
        $providerOutputDir = Join-Path -Path $providerProjectDir -ChildPath (Join-Path -Path 'bin\sessions' -ChildPath $sessionStamp)
        $providerAssemblyPath = $packagedAssemblyPath

        if ((Test-Path -LiteralPath $packagedAssemblyPath) -and (Test-WtProviderAssemblyCompatibility -AssemblyPath $packagedAssemblyPath)) {
            $providerAssemblyPath = $packagedAssemblyPath
        }
        else {
            $providerAssemblyPath = $null
        }

        if (($null -eq $providerAssemblyPath) -and (Test-Path -LiteralPath $providerProjectPath)) {
            $shouldBuild = $true
            $providerAssemblyPath = Join-Path -Path $providerOutputDir -ChildPath 'PathUtils.WtProvider.dll'
            if ((Test-Path -LiteralPath $providerAssemblyPath) -and (Test-Path -LiteralPath $providerSourcePath)) {
                $sourceInfo = Get-Item -LiteralPath $providerSourcePath -ErrorAction Stop
                $assemblyInfo = Get-Item -LiteralPath $providerAssemblyPath -ErrorAction Stop
                $shouldBuild = $sourceInfo.LastWriteTimeUtc -gt $assemblyInfo.LastWriteTimeUtc

                if (-not $shouldBuild) {
                    if (-not (Test-WtProviderAssemblyCompatibility -AssemblyPath $providerAssemblyPath)) {
                        $shouldBuild = $true
                    }
                }
            }

            if ($shouldBuild) {
                $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
                if ($null -eq $dotnetCmd) {
                    throw "dotnet SDK not found. Install .NET SDK or keep a prebuilt provider assembly."
                }

                & $dotnetCmd.Source build $providerProjectPath -c Release -nologo -o $providerOutputDir "-p:PowerShellHome=$PSHOME"
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to build provider project: $providerProjectPath"
                }
            }
        }
        elseif ($null -eq $providerAssemblyPath) {
            if (-not (Test-Path -LiteralPath $providerSourcePath)) {
                throw "Provider assembly not found at '$packagedAssemblyPath' and provider source file not found: $providerSourcePath"
            }

            $providerAssemblyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PathUtils.WtProvider.dll'
            $assemblyExists = Test-Path -LiteralPath $providerAssemblyPath
            if ($assemblyExists) {
                $sourceInfo = Get-Item -LiteralPath $providerSourcePath -ErrorAction Stop
                $assemblyInfo = Get-Item -LiteralPath $providerAssemblyPath -ErrorAction Stop
                $shouldBuild = $sourceInfo.LastWriteTimeUtc -gt $assemblyInfo.LastWriteTimeUtc
            }
            else {
                $shouldBuild = $true
            }

            if ($shouldBuild) {
                if (Test-Path -LiteralPath $providerAssemblyPath) {
                    Remove-Item -LiteralPath $providerAssemblyPath -Force
                }
                Add-Type -Path $providerSourcePath -OutputAssembly $providerAssemblyPath -ErrorAction Stop
            }
        }

        if ([string]::IsNullOrWhiteSpace($providerAssemblyPath) -or (-not (Test-Path -LiteralPath $providerAssemblyPath))) {
            throw "Provider assembly not found. Expected packaged assembly at '$packagedAssemblyPath' or build output at '$providerOutputDir'."
        }

        Import-Module -Name $providerAssemblyPath -Force -ErrorAction Stop
        $providerLoaded = $null -ne (Get-PSProvider -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $providerName })
        if (-not $providerLoaded) {
            throw "Failed to load provider module: $providerName"
        }
    }

    if (-not (Get-PSDrive -Name wt -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name wt -PSProvider $providerName -Root '\' -Scope Global | Out-Null
    }
}

function global:Get-GitWorktreeRelativePath {
    [CmdletBinding()]
    param(
        [string]$BaseWorktreePath
    )

    $currentLocation = Get-Location

    if ($currentLocation.Provider.Name -eq 'WtProvider') {
        $providerPath = $currentLocation.ProviderPath.Trim('\', '/')
        $parts = if ($providerPath) { $providerPath -split '[\\/]' } else { @() }
        if ($parts.Count -gt 1) {
            return (($parts | Select-Object -Skip 1) -join [System.IO.Path]::DirectorySeparatorChar)
        }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($BaseWorktreePath)) {
        return $null
    }

    try {
        $baseResolved = (Resolve-Path -LiteralPath $BaseWorktreePath).Path
        $currentResolved = (Resolve-Path -LiteralPath $currentLocation.Path).Path
        if ($currentResolved -like "$baseResolved*") {
            $suffix = $currentResolved.Substring($baseResolved.Length).TrimStart('\', '/')
            if ($suffix) {
                return $suffix
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function global:Set-LocationEx {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,

        [switch]$PassThru
    )

    if ($Path -match '^wt:[\\/]?(.*)$') {
        Register-GitWorktreeProvider

        $normalized = $Matches[1].Trim([char[]]@('\', '/'))
        $segments = if ($normalized) { $normalized -split '[\\/]' } else { @() }
        $explicitRelative = if ($segments.Count -gt 1) { ($segments | Select-Object -Skip 1) -join '\' } else { $null }

        $providerPath = if ([string]::IsNullOrWhiteSpace($normalized)) { 'wt:\' } else { "wt:\$normalized" }
        $providerItem = if ([string]::IsNullOrWhiteSpace($normalized)) {
            Get-ChildItem -LiteralPath 'wt:\' -ErrorAction SilentlyContinue | Where-Object { $_.IsMain } | Select-Object -First 1
        }
        else {
            Get-Item -LiteralPath $providerPath -ErrorAction SilentlyContinue
        }

        if ($null -eq $providerItem) {
            Write-Error "Worktree path not found: $providerPath"
            return
        }

        $targetRootPath = if ($providerItem.PSObject.Properties.Name -contains 'FullName') { $providerItem.FullName } else { $providerItem.Path }
        if ([string]::IsNullOrWhiteSpace($targetRootPath)) {
            Write-Error "Failed to resolve file system path for provider item: $providerPath"
            return
        }

        $targetPath = $targetRootPath
        if (-not $explicitRelative) {
            $relativeFromCurrent = Get-GitWorktreeRelativePath -BaseWorktreePath $targetRootPath
            if ($relativeFromCurrent) {
                $candidate = Join-Path -Path $targetRootPath -ChildPath $relativeFromCurrent
                if (Test-Path -LiteralPath $candidate) {
                    $targetPath = $candidate
                }
                else {
                    Write-Warning "Subdirectory not found in target worktree: $relativeFromCurrent"
                }
            }
        }

        Microsoft.PowerShell.Management\Set-Location -Path $targetPath -PassThru:$PassThru
        return
    }

    Microsoft.PowerShell.Management\Set-Location @PSBoundParameters
}

Register-ArgumentCompleter -CommandName Set-LocationEx, Set-Location, cd, Get-ChildItem, ls, dir -ParameterName Path -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    if ($wordToComplete -notlike 'wt:*') {
        return
    }

    Register-GitWorktreeProvider

    $prefix = if ($wordToComplete -match '^wt:[\\/]?(.*)') { $Matches[1] } else { '' }

    if (-not $prefix) {
        [System.Management.Automation.CompletionResult]::new(
            'wt:\',
            'wt:\',
            'ProviderContainer',
            'Main worktree'
        )
    }

    Get-ChildItem -LiteralPath 'wt:\' -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($name -like "$prefix*") {
            $completionText = "wt:\$name"
            $listText = $name
            $tooltip = if ($_.Branch) { "$($_.Branch) - $($_.CommitHash)" } else { $_.CommitHash }

            [System.Management.Automation.CompletionResult]::new(
                $completionText,
                $listText,
                'ProviderItem',
                $tooltip
            )
        }
    }
}

function script:Enable-WtCdAliasOverride {
    if (-not $script:WtCdAliasStateInitialized) {
        $existingCdAlias = Get-Alias -Name cd -Scope Global -ErrorAction SilentlyContinue
        $previousDefinition = if ($null -ne $existingCdAlias) { $existingCdAlias.Definition } else { $null }
        # Never persist our own override as the "original" alias target.
        $script:WtCdPreviousDefinition = if ($previousDefinition -eq 'Set-LocationEx') { 'Set-Location' } else { $previousDefinition }
        $script:WtCdAliasStateInitialized = $true
    }

    Set-Alias -Name cd -Value Set-LocationEx -Option AllScope -Scope Global
}

function script:Restore-WtCdAliasOverride {
    if (-not $script:WtCdAliasStateInitialized) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:WtCdPreviousDefinition) -or $script:WtCdPreviousDefinition -eq 'Set-LocationEx') {
        Set-Alias -Name cd -Value Set-Location -Option AllScope -Scope Global
    }
    else {
        Set-Alias -Name cd -Value $script:WtCdPreviousDefinition -Option AllScope -Scope Global
    }

    $script:WtCdAliasStateInitialized = $false
    $script:WtCdPreviousDefinition = $null
}

function script:Register-WtOnRemoveHandler {
    if ($script:WtOnRemoveHandlerRegistered) {
        return
    }

    $module = $ExecutionContext.SessionState.Module
    if ($null -eq $module) {
        return
    }

    $previousOnRemove = $module.OnRemove
    $wtCdPreviousDefinition = $script:WtCdPreviousDefinition
    $module.OnRemove = {
        if ($null -ne $previousOnRemove) {
            & $previousOnRemove
        }

        $targetCdCommand = if ([string]::IsNullOrWhiteSpace($wtCdPreviousDefinition) -or $wtCdPreviousDefinition -eq 'Set-LocationEx') {
            'Set-Location'
        }
        else {
            $wtCdPreviousDefinition
        }

        Set-Alias -Name cd -Value $targetCdCommand -Option AllScope -Scope Global -ErrorAction SilentlyContinue
    }.GetNewClosure()

    $script:WtOnRemoveHandlerRegistered = $true
}

Register-GitWorktreeProvider
Enable-WtCdAliasOverride
Register-WtOnRemoveHandler
