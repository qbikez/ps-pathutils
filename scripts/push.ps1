[CmdletBinding(SupportsShouldProcess=$true)]
param([switch][bool]$newversion, $source, $apikey)


function push-module {
[CmdletBinding(SupportsShouldProcess=$true)]
param($modulepath, [switch][bool]$newversion, $source, $apikey)

    $envscript = "$psscriptroot\..\.env.ps1" 
    if (test-path "$envscript") {
        . $envscript
    }

    $repo = "$env:PS_PUBLISH_REPO"
    $key = "$env:PS_PUBLISH_REPO_KEY"

    . $psscriptroot\imports\set-moduleversion.ps1
    . $psscriptroot\imports\nuspec-tools.ps1

    $ver = get-moduleversion $modulepath
    if ($newversion) {
        $newver = Incremet-Version $ver
    } else {
        $newver = $ver
    }
    set-moduleversion $modulepath -version $newver


    $r = get-psrepository $repo
    if ($r -eq $null) { 
        Register-PSRepository -Name $repo -SourceLocation "$repo/nuget" -PublishLocation $repo -InstallationPolicy Trusted -Verbose
    }

    Publish-Module -Path $modulepath -Repository $repo -Verbose -NuGetApiKey $key

}

$root = $psscriptroot
$modules = get-childitem "$root\..\src" -filter "*.psm1" -recurse | % { $_.Directory.FullName }
$modules | % { push-module $_ -newversion:$newversion }
