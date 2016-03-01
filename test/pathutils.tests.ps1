import-module pester
#import-module "$PSScriptRoot/../third-party/pester"  


Describe "module import test" {
    
    It "Should load properly" {
        { import-module "$psscriptroot\..\src\pathutils\pathutils.psm1" -ErrorAction Stop } | should not throw
        gmo pathutils | should not benullorempty
    }
}

Describe "relative path feature" {
    $cases = @(
        @{ 
            path1 = "c:\src\ps-modules\csproj\test\input\test\sln\Sample.Solution";
            path2 = "C:\src\ps-modules\csproj\test\input\test\sln\Sample.Solution\..\..\src\Console\Console1\..\..\Core\Core.Library1\Core.Library1.csproj"
            expected = "..\..\src\Core\Core.Library1\Core.Library1.csproj" 
        }
    )
    It "Should return relative path <expected> for <path1> and <path2>" -TestCases $cases {
        param($path1, $path2, $expected)
        $relpath = Get-RelativePath $path1 $path2
        $relpath | Should be $expected
    }
}