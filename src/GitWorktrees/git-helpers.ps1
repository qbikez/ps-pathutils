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

        Invoke-WtOriginalSetLocation -Path $targetPath -PassThru:$PassThru
        return
    }

    Invoke-WtOriginalSetLocation @PSBoundParameters
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

function script:Test-WtSetLocationWrapperPresent {
    $cmd = Get-Command -Name Set-Location -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $false
    }

    return $cmd.ScriptBlock.ToString().Contains('Set-LocationEx @PSBoundParameters')
}

function script:Invoke-WtOriginalSetLocation {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
        [string]$Path,

        [switch]$PassThru
    )

    if ($null -ne $script:WtPreviousSetLocationScriptBlock) {
        & $script:WtPreviousSetLocationScriptBlock @PSBoundParameters
        return
    }

    Microsoft.PowerShell.Management\Set-Location @PSBoundParameters
}

function script:Enable-WtSetLocationOverride {
    if (Test-WtSetLocationWrapperPresent) {
        $script:WtSetLocationStateInitialized = $true
        return
    }

    if (-not $script:WtSetLocationStateInitialized) {
        $existingSetLocation = Get-Command -Name Set-Location -CommandType Function -ErrorAction SilentlyContinue
        $script:WtPreviousSetLocationScriptBlock = if ($null -ne $existingSetLocation) { $existingSetLocation.ScriptBlock } else { $null }
        $script:WtSetLocationStateInitialized = $true
    }

    $wtSetLocationWrapper = {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0, ValueFromPipelineByPropertyName = $true)]
            [string]$Path,

            [switch]$PassThru
        )

        Set-LocationEx @PSBoundParameters
    }

    Set-Item -Path Function:\global:Set-Location -Value $wtSetLocationWrapper
}

function script:Restore-WtSetLocationOverride {
    [CmdletBinding()]
    param()

    if (-not $script:WtSetLocationStateInitialized) {
        Write-Verbose "Restore-WtSetLocationOverride: not initialized"
        return
    }

    if (-not (Test-WtSetLocationWrapperPresent)) {
        # Another module may have changed Set-Location after us; avoid clobbering it.
        $script:WtSetLocationStateInitialized = $false
        $script:WtPreviousSetLocationScriptBlock = $null

        Write-Verbose "Restore-WtSetLocationOverride: not present"
        return
    }

    if ($null -ne $script:WtPreviousSetLocationScriptBlock) {
        Write-Verbose "Restore-WtSetLocationOverride: restoring script block"
        Set-Item -Path Function:\global:Set-Location -Value $script:WtPreviousSetLocationScriptBlock
    }
    else {
        Write-Verbose "Restore-WtSetLocationOverride: removing script block"
        Remove-Item -Path Function:\global:Set-Location
        Remove-Item -Path Function:\Set-Location
    }

    $script:WtSetLocationStateInitialized = $false
    $script:WtPreviousSetLocationScriptBlock = $null
    Write-Verbose "Restore-WtSetLocationOverride: reset state"
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
    $module.OnRemove = {
        if ($null -ne $previousOnRemove) {
            & $previousOnRemove
        }

        Restore-WtSetLocationOverride
    }.GetNewClosure()

    $script:WtOnRemoveHandlerRegistered = $true
}

function global:Get-SetLocationWrapperGraph {
    [CmdletBinding()]
    param(
        [string]$CommandName = 'Set-Location',
        [int]$MaxDepth = 16
    )

    function Resolve-SetLocationInnerCandidates {
        param(
            [Parameter(Mandatory = $true)]
            [Management.Automation.CommandInfo]$Command
        )

        if ($Command.CommandType -ne 'Function') {
            return @()
        }

        $scriptText = $Command.ScriptBlock.ToString()
        $commandAsts = $Command.ScriptBlock.Ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            },
            $true
        )

        $candidateNames = @(
            $commandAsts |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        # Prioritize direct Set-Location calls first, then wrappers/helpers.
        $prioritized = @(
            $candidateNames | Where-Object { $_ -ieq 'Microsoft.PowerShell.Management\Set-Location' }
            $candidateNames | Where-Object { $_ -ieq 'Set-Location' }
            $candidateNames | Where-Object { $_ -ieq 'Set-LocationEx' }
            $candidateNames | Where-Object { $_ -ieq 'Invoke-WtOriginalSetLocation' }
            $candidateNames | Where-Object { $_ -match 'Set-Location' -and $_ -inotmatch 'Microsoft\.PowerShell\.Management\\Set-Location|Set-Location|Set-LocationEx|Invoke-WtOriginalSetLocation' }
        )

        $unique = @()
        foreach ($name in $prioritized) {
            if ($name -inotin $unique) {
                $unique += $name
            }
        }

        return @(
            $unique | ForEach-Object {
                [PSCustomObject]@{
                    Name     = $_
                    IsDirect = $scriptText -match "(\b|\\)$([Regex]::Escape($_))\b"
                }
            }
        )
    }

    function Resolve-SetLocationGraphNode {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [int]$Depth = 0,
            [Parameter(Mandatory = $true)]
            [hashtable]$Visited
        )

        if ($Depth -ge $MaxDepth) {
            return [PSCustomObject]@{
                Name             = $Name
                Exists           = $false
                CommandType      = 'Unknown'
                IsOriginal       = $false
                IsWrapped        = $false
                Source           = $null
                ScriptPreview    = $null
                InnerCalls       = @()
                AnalysisWarnings = @("MaxDepth reached ($MaxDepth).")
            }
        }

        $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            return [PSCustomObject]@{
                Name             = $Name
                Exists           = $false
                CommandType      = 'NotFound'
                IsOriginal       = $false
                IsWrapped        = $false
                Source           = $null
                ScriptPreview    = $null
                InnerCalls       = @()
                AnalysisWarnings = @("Command not found.")
            }
        }

        $scriptText = if ($command.CommandType -eq 'Function') { $command.ScriptBlock.ToString() } else { $null }
        $identity = "$($command.CommandType)|$($command.Name)|$($command.Source)|$scriptText"
        if ($Visited.ContainsKey($identity)) {
            return [PSCustomObject]@{
                Name             = $command.Name
                Exists           = $true
                CommandType      = "$($command.CommandType)"
                IsOriginal       = $false
                IsWrapped        = $false
                Source           = $command.Source
                ScriptPreview    = if ($scriptText) { $scriptText.Trim() } else { $null }
                InnerCalls       = @()
                AnalysisWarnings = @('Cycle detected. Stopping recursion.')
            }
        }
        $Visited[$identity] = $true

        $isOriginal = $command.CommandType -eq 'Cmdlet' -and $command.Name -eq 'Set-Location' -and $command.Source -eq 'Microsoft.PowerShell.Management'
        $innerCalls = @()
        $warnings = @()

        if ($command.CommandType -eq 'Function') {
            $candidates = Resolve-SetLocationInnerCandidates -Command $command
            foreach ($candidate in $candidates) {
                $targetName = $candidate.Name
                if ($targetName -ieq $command.Name -and $command.CommandType -eq 'Function') {
                    continue
                }

                $innerCalls += [PSCustomObject]@{
                    CallName   = $targetName
                    IsDirect   = $candidate.IsDirect
                    InnerGraph = Resolve-SetLocationGraphNode -Name $targetName -Depth ($Depth + 1) -Visited $Visited
                }
            }

            if ($innerCalls.Count -eq 0 -and $scriptText -match '(?m)^\s*&\s*\$') {
                $warnings += 'Function appears to invoke a scriptblock variable; static inner-command resolution may be incomplete.'
            }
        }

        return [PSCustomObject]@{
            Name             = $command.Name
            Exists           = $true
            CommandType      = "$($command.CommandType)"
            IsOriginal       = $isOriginal
            IsWrapped        = ($command.CommandType -eq 'Function')
            Source           = $command.Source
            ScriptPreview    = if ($scriptText) { ($scriptText.Trim() -replace '\s+', ' ') } else { $null }
            InnerCalls       = $innerCalls
            AnalysisWarnings = $warnings
        }
    }

    $visited = @{}
    Resolve-SetLocationGraphNode -Name $CommandName -Depth 0 -Visited $visited
}

function global:Show-SetLocationWrapperGraph {
    [CmdletBinding()]
    param(
        [string]$CommandName = 'Set-Location',
        [int]$MaxDepth = 16
    )

    function Format-SetLocationGraphNode {
        param(
            [Parameter(Mandatory = $true)]
            [psobject]$Node,
            [string]$Indent = '',
            [switch]$IsRoot
        )

        $type = if ($Node.Exists) { $Node.CommandType } else { 'Missing' }
        $flags = @()
        if ($Node.IsOriginal) { $flags += 'original' }
        if ($Node.IsWrapped) { $flags += 'wrapped' }
        if ($flags.Count -eq 0) { $flags += 'plain' }
        $flagText = $flags -join ','

        $prefix = if ($IsRoot) { '' } else { "$Indent- " }
        $line = "{0}{1} [{2}] ({3})" -f $prefix, $Node.Name, $type, $flagText
        Write-Output $line

        foreach ($warning in @($Node.AnalysisWarnings)) {
            Write-Output ("{0}  ! {1}" -f $Indent, $warning)
        }

        foreach ($inner in @($Node.InnerCalls)) {
            $callMeta = if ($inner.IsDirect) { 'direct' } else { 'indirect' }
            Write-Output ("{0}  -> {1} [{2}]" -f $Indent, $inner.CallName, $callMeta)
            Format-SetLocationGraphNode -Node $inner.InnerGraph -Indent ($Indent + '    ')
        }
    }

    $graph = Get-SetLocationWrapperGraph -CommandName $CommandName -MaxDepth $MaxDepth
    Format-SetLocationGraphNode -Node $graph -IsRoot
}

Register-GitWorktreeProvider
Enable-WtSetLocationOverride
Register-WtOnRemoveHandler
