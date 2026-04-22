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

        $sessionStamp = "pwsh-$($PSVersionTable.PSVersion)-pid-$PID"
        $outputDir = "src/PathUtils.WtProvider/bin/sessions/$sessionStamp"
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
