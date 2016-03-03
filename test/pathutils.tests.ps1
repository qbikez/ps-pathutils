import-module pester
#import-module "$PSScriptRoot/../third-party/pester"  

function TouchFile($paths) {
    $paths = @($paths)
    foreach($path2 in $paths) {
        if (!(test-path $path2)) {
            if ([System.IO.Path]::GetFilenameWithoutExtension($path2) -eq $null `
                -or $path2.EndsWith("/") -or $path2.EndsWith("\")
            ) {
                $null = new-item -type directory ($path2)
            } else {
                if (!(test-path (split-path -parent $path2))) {
                    $null = new-item -type directory (split-path -parent $path2)
                }
                "" | Out-File $path2 
            }
        }        
    }
}

Describe "module import test" {
    
    It "Should load properly" {
        { import-module "$psscriptroot\..\src\pathutils\pathutils.psm1" -ErrorAction Stop } | should not throw
        gmo pathutils | should not benullorempty
    }
}

Describe "relative path feature" {
    $cases = @(
        @{ 
            path1 = "test\sln\Sample.Solution\";
            path2 = "test\sln\Sample.Solution\..\..\src\Console\Console1\..\..\Core\Core.Library1\Core.Library1.csproj"
            expected = "..\..\src\Core\Core.Library1\Core.Library1.csproj" 
        }
        @{ 
            path1 = "test\sln\Sample.Solution\Sample.Solution.sln";
            path2 = "test\sln\Sample.Solution\..\..\src\Console\Console1\..\..\Core\Core.Library1\Core.Library1.csproj"
            expected = "..\..\src\Core\Core.Library1\Core.Library1.csproj" 
        }
        @{
            path1 = "testdrive:\test\sln\Sample.Solution\";
            path2 = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create = $true
        }
        @{
            path1 = "testdrive:\test\sln\Sample.Solution\";
            path2 = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create = $false
        }
    )
    In "testdrive:/" {
    It "Should return relative path <expected> for (existing=<create>) <path1> and <path2>" -TestCases $cases {
        param($path1, $path2, $expected, $create)
        # make sure these paths exists, because only then will they will be resolved to full paths
        if ($create -ne $false) {
            TouchFile $path1,$path2
        }
           
        $relpath = Get-RelativePath $path1 $path2
        $relpath | Should be $expected
    }
    It "Should return relative path <expected> for (existing=<create>) absolute paths of <path1> and <path2>" -TestCases $cases {
        param($path1, $path2, $expected)
        # make sure these paths exists, because only then will they will be resolved to full paths
        TouchFile $path1,$path2

        $relpath = Get-RelativePath (gi $path1).fullname (gi $path2).FullName
        $relpath | Should be $expected
    }
    }
}