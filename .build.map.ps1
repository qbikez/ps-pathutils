$targets = @{
    "build" = {
        param([bool][switch]$noRestore, $_context)

        $projectPath = "src/PathUtils.WtProvider/PathUtils.WtProvider.csproj"
        if (-not (Test-Path -LiteralPath $projectPath)) {
            throw "WtProvider project not found: $projectPath"
        }

        $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($null -eq $dotnetCmd) {
            throw "dotnet SDK was not found on PATH."
        }

        $outputDir = "src/PathUtils.WtProvider/bin/pack"
        $moduleLibDir = "src/PathUtils/lib"
        $moduleAssemblyPath = Join-Path -Path $moduleLibDir -ChildPath "PathUtils.WtProvider.dll"
        $buildArgs = @(
            "build"
            $projectPath
            "-c"
            "Release"
            "-nologo"
            "-o"
            $outputDir
            "-p:PowerShellHome=$PSHOME"
        )
        if ($noRestore) {
            $buildArgs += "--no-restore"
        }

        & $dotnetCmd.Source @buildArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed for $projectPath"
        }

        if (-not (Test-Path -LiteralPath $moduleLibDir)) {
            New-Item -Path $moduleLibDir -ItemType Directory -Force | Out-Null
        }

        $builtAssemblyPath = Join-Path -Path $outputDir -ChildPath "PathUtils.WtProvider.dll"
        if (-not (Test-Path -LiteralPath $builtAssemblyPath)) {
            throw "Built provider assembly not found: $builtAssemblyPath"
        }

        Copy-Item -LiteralPath $builtAssemblyPath -Destination $moduleAssemblyPath -Force
    }
    
    "npm" = [ordered]@{
        "init" = { npm run 'init' }
        "restore" = { npm run 'restore' }
        "test" = { npm run 'test' }
        "code" = { npm run 'code' }
        "push" = { npm run 'push' }
        "install" = { npm run 'install' }
    }
}

return $targets
