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
            path1 = ".\test\sln\Sample.Solution\Sample.Solution.sln";
            path2 = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create = $false
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

Describe "env variable manipulation" {
    $env:test = ""
    $p1 = "c:\test\test1"
    $p2 = "c:\test\test2"
    $p3 = "c:\test\test3"
    
    It "Should add path" {
        $env:test = ""
        add-toenvvar "test" $p1
        $val = @(get-envvar "test")
        $val[0] | Should Be $p1
        $val.length | Should Be 1
    }
    It "Should add at the end path" {
        $env:test = ""
        add-toenvvar "test" $p1
        add-toenvvar "test" $p2
        $val = @(get-envvar "test")
        $val[$val.length - 1] | Should Be $p2
        $val.length | Should Be 2
    }

    It "Should add at the beginning with -first" {
        $env:test = ""
        add-toenvvar "test" $p1
        add-toenvvar "test" $p2
        add-toenvvar "test" $p3 -first
        $val = @(get-envvar "test")
        $val[0] | Should Be $p3
        $val.length | Should Be 3
    }
    
    It "Should not add existing path" {
        $val0 = @(get-envvar "test")
       
        add-toenvvar "test" $p3 -first
        $val = @(get-envvar "test")
        $val.length | Should Be $val0.length
       
        add-toenvvar "test" $p3
        $val = @(get-envvar "test")
        $val.length | Should Be $val0.length
    }
    
    $p4 = "c:/test/test4/"
    $p4conv = "c:\test\test4"
    
    
    It "Should convert slashes to backslashes" {        
        $val0 = @(get-envvar "test")
        add-toenvvar "test" $p4
        $val = @(get-envvar "test")
        $val.length | Should Be ($val0.length + 1)
        $val[$val.Length - 1] | Should Be $p4conv
    }

      It "Should update env var" {
        $val = "123654"
        [System.Environment]::SetEnvironmentVariable("test1", $val, [System.EnvironmentVariableTarget]::Machine)
        update-envvar "test1"

        $env:test1 | Should Be $val
    }

      It "Should remove paths" {
        $p1 = "c:\test\test1"
        $p2 = "c:\test\test2"
        $p3 = "c:\test\test3"
        try {
            $oldpath = $env:path
            $env:path = ""
            add-topath  $p1
            add-topath $p2
            $val = @(get-pathenv -current)
            $val.length | Should Be 2

            remove-frompath $p1

            $val = @(get-pathenv -current)
            $val.length | Should Be 1

        } finally {
            $env:path = $oldpath
        }
    }

     It "Should remove paths with different slashes" {
        $p1 = "c:\test\test1"
        $p2 = "c:/test/test1"
        try {
            $oldpath = $env:path
            $env:path = ""
            add-topath $p1
            $val = @(get-pathenv -current)
            $val.length | Should Be 1

            remove-frompath $p2

            $val = @(get-pathenv -current)
            $val.length | Should Be 0

        } finally {
            $env:path = $oldpath
        }
    }

     It "Should remove paths with trailing slashes" {
        $p1 = "c:\test\test1\"
        $p2 = "c:\test\test1"
        try {
            $oldpath = $env:path
            $env:path = ""
            add-topath $p1
            $val = @(get-pathenv -current)
            $val.length | Should Be 1

            remove-frompath $p2

            $val = @(get-pathenv -current)
            $val.length | Should Be 0

        } finally {
            $env:path = $oldpath
        }
    }

    It "Should remove paths with missing trailing slashes" {
        $p1 = "c:\test\test1"
        $p2 = "c:\test\test1\"
        try {
            $oldpath = $env:path
            $env:path = ""
            add-topath $p1
            $val = @(get-pathenv -current)
            $val.length | Should Be 1

            remove-frompath $p2

            $val = @(get-pathenv -current)
            $val.length | Should Be 0

        } finally {
            $env:path = $oldpath
        }
    }
    
}