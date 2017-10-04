import-module pester

import-module $PSScriptRoot\..\src\PathUtils
#import-module "$PSScriptRoot/../third-party/pester"  
import-module require -ErrorAction Stop

req process

function TouchFile($paths) {
    $paths = @($paths)
    foreach ($path2 in $paths) {
        if (!(test-path $path2)) {
            if ([System.IO.Path]::GetFilenameWithoutExtension($path2) -eq $null `
                    -or $path2.EndsWith("/") -or $path2.EndsWith("\")
            ) {
                $null = new-item -type directory ($path2)
            }
            else {
                if (!(test-path (split-path -parent $path2))) {
                    $null = new-item -type directory (split-path -parent $path2)
                }
                "" | Out-File $path2 
            }
        }        
    }
}


Describe "Refresh-env" {
    It "Should update new environment from user scope" {
        $env:TEST123 = $null
        $oldpath = $env:PATH
        try {
            [System.Environment]::SetEnvironmentVariable("TEST123", "456", [System.EnvironmentVariableTarget]::User)
            $env:TEST123 | Should Be $null
            Refresh-Env
            $env:TEST123 | Should Be "456"
        } finally {
            [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::User)
            $env:path = $oldpath 
        }
    }

    
    It "Should not override existing variable by default" {
        $env:TEST123 = $null
        $oldpath = $env:PATH
        try {
            $env:TEST123 = "0"
            [System.Environment]::SetEnvironmentVariable("TEST123", "456", [System.EnvironmentVariableTarget]::User)
            $env:TEST123 | Should Be 0
            Refresh-Env 
            $env:TEST123 | Should Be 0
        } finally {
            [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::User)
            $env:Path = $oldpath
        }
    }
    It "Should override existing variable when forced" {
        $env:TEST123 = $null
        $oldpath = $env:PATH
        try {
            $env:TEST123 = "0"
            [System.Environment]::SetEnvironmentVariable("TEST123", "456", [System.EnvironmentVariableTarget]::User)
            $env:TEST123 | Should Be "0"
            Refresh-Env -force
            $env:TEST123 | Should Be "456"
        } finally {
            [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::User)
            $env:Path = $oldpath
        }
    }
    It "Should concatenate machine and user paths" {
        $oldpath = $env:PATH
        try {
            $machinepath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine) 
            $userpath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)

            if ([string]::IsNullOrEmpty($userpath)) { Set-TestInconclusive "user-level PATH variable is empty" }

            update-envvar "PATH" -force:$true

            $env:PATH.StartsWith($machinePath) | Should Be $true
            
            #$p2 = $env:PATH.Substring($machinepath.length + 1)
            #$oldp2 = $oldpath.Substring($machinepath.length + 1)

            $machinepaths = $machinepath.split(";")
            $userpaths = $userpath.split(";")

            foreach($p in $machinepaths) {
                $env:PATH | Should Match ($p | Escape-Regex)
            }
            foreach($p in $userpaths) {
                $env:PATH | Should Match  ($p | Escape-Regex)
            }
            
            # this is easy to break:
            #$oldpath.StartsWith($machinePath) | Should Be $true
            #$oldPath.StartsWith($env:PATH) | Should Be $True
            
            #$env:PATH | Should Be $oldpath
            #$env:PATH | Should Be "$($machinepath);$($userpath)".Trim(";")
        } finally {
            $env:PATH = $oldpath
        }
    }

    Context "when user is admin" {
        BeforeEach {
            if (!(test-isadmin)) { Set-TestInconclusive "admin priviledge is required" }             
        }
        It "Should update new environment from machine scope" {                        
            $env:TEST123 = $null
            $oldpath = $env:PATH
            try {
                [System.Environment]::SetEnvironmentVariable("TEST123", "456", [System.EnvironmentVariableTarget]::Machine)
                $env:TEST123 | Should Be $null
                Refresh-Env
                $env:TEST123 | Should Be "456"
            } finally {
                [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::Machine)
                $env:Path = $oldpath
            }
        }
        It "User should override machine" {
            $env:TEST123 = $null
            $oldpath = $env:PATH
            try {
                [System.Environment]::SetEnvironmentVariable("TEST123", "456", [System.EnvironmentVariableTarget]::User)
                [System.Environment]::SetEnvironmentVariable("TEST123", "999", [System.EnvironmentVariableTarget]::Machine)
                $env:TEST123 | Should Be $null
                Refresh-Env
                $env:TEST123 | Should Be "456"
            } finally {
                [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::Machine)
                [System.Environment]::SetEnvironmentVariable("TEST123", $null, [System.EnvironmentVariableTarget]::User)
                $env:Path = $oldpath
            }
        }
    }
}



Describe "listing test" {
    Copy-Item "$psscriptroot/test" "testdrive:/" -Recurse -Verbose 
    In "testdrive:/test" {
        It "should find multiple include files recursive" {
            $l = get-listing -files -include "*.test.txt", "*.sln.txt", "*.test-data.txt" -recurse
            $l.length | Should Be 3
        }
        It "should find multiple top level include files" {
            $l = @(get-listing -files -excludes "^\..*/" -include "*.bin", "*.global.txt")
            $l.length | Should Be 2
        }
        It "should find top level include files" {
            $l = @(get-listing -files -excludes "^\..*/" -include "*.bin")
            $l.length | Should Be 1
        }
        It "should ommit top dirs by regex" {
            $l = get-listing -dirs -excludes "^\..*/"
            $l.length | Should Be 2
        }
        It "should list recursive dirs" {
            $l = get-listing -Recursive -dirs
            $l.fullname | format-table | out-string | write-host
            $l.length | Should Be 8
        }
        It "should list recursive files" {
            $l = get-listing -Recursive -files
            $l.length | Should Be 8
        }
        It "should list recursive all" {
            $l = get-listing -Recursive
            $l.fullname | format-table | out-string | write-host
            $l.length | Should Be 16
        }

        It "should list top level dirs and files" {
            $l = get-listing 
            $l.length | Should Be 6
        }
        It "should list top level files" {
            $l = get-listing -files
            $l.length | Should Be 2
        }
        It "should list top level dirs" {
            $l = get-listing -dirs
            $l.length | Should Be 4
        }
        It "should ommit top dirs by wildcard" {
            $l = get-listing -dirs -excludes ".test"
            $l.length | Should Be 2
        }
        It "should ommit excluded top dirs exact" {
            $l = get-listing -dirs -excludes ".test/"
            $l.length | Should Be 3
            #don't use backslashes as path separator in regex - this won't work
            #$l = get-listing -dirs -excludes ".test\\"
        }
        It "should include dirs by relative path" {
            $l = get-listing -dirs -recurse -include "src/Core/"
            $l.length | Should Be 3
        }
        It "should include and exclude dirs by relative path" {
            $l = get-listing -dirs -recurse -include "src/Core/" -exclude "src/Core/Core\.Library2/"
            $l.length | Should Be 2
        }
    }
    Copy-Item "$psscriptroot/test2" "testdrive:/" -Recurse -Verbose 
    In "testdrive:/test2" {
        It "should not recurse into dirs that are returned by filter" {
            $l = get-listing -dirs -recurse -Filter "log"
            $l.length | Should Be 2
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
            path1    = "test\sln\Sample.Solution\";
            path2    = "test\sln\Sample.Solution\..\..\src\Console\Console1\..\..\Core\Core.Library1\Core.Library1.csproj"
            expected = "..\..\src\Core\Core.Library1\Core.Library1.csproj" 
        }
        @{ 
            path1    = "test\sln\Sample.Solution\Sample.Solution.sln";
            path2    = "test\sln\Sample.Solution\..\..\src\Console\Console1\..\..\Core\Core.Library1\Core.Library1.csproj"
            expected = "..\..\src\Core\Core.Library1\Core.Library1.csproj" 
        }
        @{
            path1    = "testdrive:\test\sln\Sample.Solution\";
            path2    = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create   = $true
        }
        @{
            path1    = ".\test\sln\Sample.Solution\Sample.Solution.sln";
            path2    = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create   = $false
        }
        @{
            path1    = "testdrive:\test\sln\Sample.Solution\";
            path2    = "testdrive:\test\packages\"
            expected = "..\..\packages" 
            create   = $false
        }
    )
    In "testdrive:/" {
        It "Should return relative path <expected> for (existing=<create>) <path1> and <path2>" -TestCases $cases {
            param($path1, $path2, $expected, $create)
            # make sure these paths exists, because only then will they will be resolved to full paths
            if ($create -ne $false) {
                TouchFile $path1, $path2
            }
           
            $relpath = Get-RelativePath $path1 $path2
            $relpath | Should be $expected
        }
        It "Should return relative path <expected> for (existing=<create>) <path1> and <path2> with alt separator" -TestCases $cases {
            param($path1, $path2, $expected, $create)
            # make sure these paths exists, because only then will they will be resolved to full paths
            if ($create -ne $false) {
                TouchFile $path1, $path2
            }
        
            $path1 = $path1.replace("\", "/")
            $path2 = $path2.replace("\", "/")   
            $relpath = Get-RelativePath $path1 $path2 -separator "/"
            $relpath | Should be $expected.replace("\", "/")

        }
        It "Should return relative path <expected> for (existing=<create>) absolute paths of <path1> and <path2>" -TestCases $cases {
            param($path1, $path2, $expected)
            # make sure these paths exists, because only then will they will be resolved to full paths
            TouchFile $path1, $path2

            $relpath = Get-RelativePath (gi $path1).fullname (gi $path2).FullName
            $relpath | Should be $expected
        }

        It "Should return relative path <expected> for (existing=<create>) absolute paths of <path1> and <path2> with alt sep" -TestCases $cases {
            param($path1, $path2, $expected)
            # make sure these paths exists, because only then will they will be resolved to full paths
            TouchFile $path1, $path2
            $path1 = $path1.replace("\", "/")
            $path2 = $path2.replace("\", "/")   
       
            $relpath = Get-RelativePath (gi $path1).fullname (gi $path2).FullName -separator "/"
            $relpath | Should be $expected.replace("\", "/")   
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

    It "Should not duplicate with -first" {
        $env:test = ""
        add-toenvvar "test" $p1
        add-toenvvar "test" $p2
        add-toenvvar "test" $p3 -first
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

    Context "when user is admin" {
        BeforeEach {
            if (!(test-isadmin)) { Set-TestInconclusive "admin priviledge is required" }             
        }
        It "Should update env var" {
            $val = "123654"
            [System.Environment]::SetEnvironmentVariable("test1", $val, [System.EnvironmentVariableTarget]::Machine)
            update-envvar "test1"

            $env:test1 | Should Be $val
        }
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



Describe "where is" {
    It "Should return object with Source property" {
        $w = where-is "notepad.exe"
        $w | Should Not benullorempty
        $w.Source | Should Not benullorempty
    }
    It "Should return null for missing command" {
        $w = where-is "non-existing.exe" 
        $w | Should BeNullOrEmpty
    }
    It "Should return null for missing command in shell mode" {
        $w = where-is "non-existing.exe" -useShellExecute
        $w | Should BeNullOrEmpty
    }
    It "Should return array for multiple matches" {
        mkdir "testdrive:\bin1"
        mkdir "testdrive:\bin2"
        "" | set-content "testdrive:\bin1\test321.exe"
        "" | set-content "testdrive:\bin2\test321.exe"
        (Get-TestDriveItem "bin1").fullname | add-topath
        (Get-TestDriveItem "bin2").fullname | add-topath
        $w = @(where-is "test321")
        $w | Format-Table | Out-String | write-host
        $w.length | Should Be 2
    }
}

Describe "filename manipulation" {
    Context "replace file extension" {
        It "should work with starting ." {
            $file = "test.csv"
            $outfile = Replace-FileExtension $file ".bak.csv"
            $outfile | Should Be "test.bak.csv"
        }
        It "should work without starting ." {
            $file = "test.csv"
            $outfile = Replace-FileExtension $file "-bak.csv"
            $outfile | Should Be "test-bak.csv"
        }
        It "should preserve directory" {
            $file = "data/test.csv"
            $outfile = Replace-FileExtension $file ".bak.csv"
            $outfile | Should Be "data\test.bak.csv"
        }
    }
}
