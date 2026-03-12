function global:Get-GitWorktree {
    <#
    .SYNOPSIS
    Lists all git worktrees in the current repository and returns them as PowerShell objects.

    .DESCRIPTION
    Executes `git worktree list` and parses the output into PowerShell objects.
    Returns information about each worktree including path, commit hash, branch/detached status,
    and whether it's prunable.

    .PARAMETER Path
    The root path of the git repository. Defaults to current directory.

    .EXAMPLE
    Get-GitWorktree
    Lists all worktrees in the current git repository

    .EXAMPLE
    Get-GitWorktree -Path "C:\path\to\repo"
    Lists all worktrees in the specified repository

    .EXAMPLE
    Get-GitWorktree | Where-Object { $_.IsPrunable }
    List only prunable worktrees

    .OUTPUTS
    PSCustomObject with properties: Path, CommitHash, Branch, IsDetached, IsPrunable
    #>
    
    [CmdletBinding()]
    param(
        [string]$Path = "."
    )

    # Resolve to absolute path and verify git repo
    $absolutePath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

    $repoRoot = $null
    try {
        $repoRoot = & git -C $absolutePath rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
            Write-Error "Not a git repository: $absolutePath"
            return
        }
        $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
    }
    catch {
        Write-Error "Not a git repository: $absolutePath"
        return
    }

    try {
        $output = & git -C $repoRoot worktree list

        if (!$output) {
            Write-Warning "No worktrees found"
            return
        }

        <#
        Standard format:
        /path/to/repo                    abc123def [main]
        /path/to/worktree                def456ghi [feature-branch]
        /path/to/detached                ghi789jkl (detached)
        /path/to/prunable                jkl012mno (prunable)
        #>
        foreach ($line in $output) {
            if ($line -match '^\s*(.+?)\s{2,}([a-f0-9]+)\s+(\[(.+?)\]|\((.+?)\))') {
                $path = $Matches[1]
                $commitHash = $Matches[2]
                $status = $Matches[4] + $Matches[5]  # Either the branch name or status
                
                $isDetached = $status -eq "detached"
                $isPrunable = $status -eq "prunable"
                $branch = if (!$isDetached -and !$isPrunable) { $status } else { $null }
                
                $isMain = $false
                if ($repoRoot) {
                    try {
                        $resolvedPath = (Resolve-Path -LiteralPath $path).Path
                        $isMain = [string]::Equals($resolvedPath, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
                    }
                    catch {
                        $isMain = $false
                    }
                }

                $o = [PSCustomObject]@{
                    Name       = Split-Path -Leaf $path
                    Path       = $path
                    CommitHash = $commitHash
                    Branch     = $branch
                    IsDetached = $isDetached
                    IsPrunable = $isPrunable
                    IsMain     = $isMain
                }
                Write-Output $o
            }
        }
    }
    catch {
        Write-Error "Failed to list git worktrees: $_"
    }
}

function global:Register-GitWorktreeProvider {
    [CmdletBinding()]
    param()

    $providerTypeName = 'PathUtils.WtProvider'
    $providerName = 'WtProvider'
    $providerLoaded = $null -ne (Get-PSProvider -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $providerName })

    if (-not $providerLoaded) {
        $providerSourcePath = Join-Path -Path $PSScriptRoot -ChildPath 'WtProvider.cs'
        if (-not (Test-Path -LiteralPath $providerSourcePath)) {
            throw "Provider source file not found: $providerSourcePath"
        }

        $providerAssemblyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PathUtils.WtProvider.dll'
        $shouldBuild = -not (Test-Path -LiteralPath $providerAssemblyPath)
        if (-not $shouldBuild) {
            $sourceInfo = Get-Item -LiteralPath $providerSourcePath -ErrorAction Stop
            $assemblyInfo = Get-Item -LiteralPath $providerAssemblyPath -ErrorAction Stop
            $shouldBuild = $sourceInfo.LastWriteTimeUtc -gt $assemblyInfo.LastWriteTimeUtc
        }

        if ($shouldBuild) {
            if (Test-Path -LiteralPath $providerAssemblyPath) {
                Remove-Item -LiteralPath $providerAssemblyPath -Force
            }
            Add-Type -Path $providerSourcePath -OutputAssembly $providerAssemblyPath -ErrorAction Stop
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

        $normalized = $Matches[1].Trim('\\', '/')
        $segments = if ($normalized) { $normalized -split '[\\/]' } else { @() }
        $worktreeSelector = if ($segments.Count -gt 0) { $segments[0] } else { $null }
        $explicitRelative = if ($segments.Count -gt 1) { ($segments | Select-Object -Skip 1) -join '\' } else { $null }

        $worktrees = @(Get-GitWorktree)
        if (-not $worktrees) {
            return
        }

        $target = if ([string]::IsNullOrWhiteSpace($worktreeSelector)) {
            $worktrees | Where-Object { $_.IsMain } | Select-Object -First 1
        }
        else {
            $worktrees | Where-Object { $_.Name -ieq $worktreeSelector } | Select-Object -First 1
            if (-not $?) { $null }
        }

        if ($null -eq $target -and -not [string]::IsNullOrWhiteSpace($worktreeSelector)) {
            $target = $worktrees | Where-Object { $_.Name -like "*$worktreeSelector*" } | Select-Object -First 1
        }

        if ($null -eq $target) {
            Write-Error "Worktree not found: $worktreeSelector"
            return
        }

        $targetPath = "wt:\$($target.Name)"
        if ($explicitRelative) {
            $targetPath = "$targetPath\$explicitRelative"
        }
        else {
            $relativeFromCurrent = Get-GitWorktreeRelativePath -BaseWorktreePath $target.Path
            if ($relativeFromCurrent) {
                $candidate = "$targetPath\$relativeFromCurrent"
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

    $prefix = if ($wordToComplete -match '^wt:[\\/]?(.*)') { $Matches[1] } else { '' }

    if (-not $prefix) {
        [System.Management.Automation.CompletionResult]::new(
            'wt:\',
            'wt:\',
            'ProviderContainer',
            'Main worktree'
        )
    }

    Get-GitWorktree | ForEach-Object {
        $name = Split-Path -Leaf $_.Path
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

Register-GitWorktreeProvider

Set-Alias -Name cd -Value Set-LocationEx -Option AllScope -Scope Global

New-Alias "git-wt" Get-GitWorktree -Scope Global -Force
