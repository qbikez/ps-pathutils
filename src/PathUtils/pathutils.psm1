
function where-is($wally, [switch][bool]$useShellExecute = $true) {
    if ($useShellExecute) {
        cmd /c "where $wally"
    } else {
        # todo: use pure-powershell method
        throw "not implemented"
    }
    #Get-Command $wally
}

function get-pathenv([switch][bool]$user, [switch][bool]$machine, [switch][bool]$current) {
    $path = @()
    if ($user) {
        $path += [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User);
    }
    if ($machine) {
        $path += [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine);
    }
    if (!$user.IsPresent -and !$machine.IsPresent) {
        $current = $true
    }
    if ($current) {
        $path = $env:path
    }
    $p = $Path.Split(';')
    return $p
}

function add-topath([Parameter(valuefrompipeline=$true)]$path, [switch][bool] $persistent, [switch][bool]$first) {
    $p = $env:Path.Split(';')
    $p = $p | % { $_.trimend("\") }

    $paths = @($path) 
    $paths | % { 
        $path = $_.trimend("\")
        write-verbose "adding $path to PATH"
        if ($first) {
            if ($path.length -eq 0 -or $path[0] -ine $path) {
                $p = @($path) + $p
            }
        }
        else {
            if ($path -inotin $p) {
                $p += $path
            }
        }
    }
    
    $env:path = [string]::Join(";",$p)

    [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Process);
    if ($persistent) {
          write-warning "saving global PATH"
          [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Machine);
    }
}

function remove-frompath($path, [switch][bool] $persistent) {
    $paths = @($path) 
    $p = $env:Path.Split(';')
    $p = $p | % { $_.trimend("\") }
    $paths | % { 
        $path = $_
        $found = $p | ? { $_ -ieq $path }
        if ($found -ne $null) {
            write-verbose "found $($found.count) matches"
            $p = $p | ? { !($_ -ieq $path) }    
        }
    }

    $env:path = [string]::Join(";",$p)

    [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Process);
    if ($persistent) {
        write-warning "saving global PATH"
        [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Machine);
    }
}

function contains-path($path, [switch][bool]$show) {
    $paths = @($path) 
    $p = $env:Path.Split(';')
    $p = $p | % { $_.trimend("\") }
    $r = $true
    $path = $null
    $paths | % { 
        $path = $_       
        $found = $p | ? { $_ -imatch (escape-regex "$path") }
        if (@($found).Count -le 0) { 
            write-verbose "$path not found in PATH"
            $r = $false 
        }
        else {
            write-verbose "$path found in PATH"
        }
    }

    if ($show) {
        return $found
    }
    return $r
}

function refresh-env {
[CmdletBinding()]
param()
    $path = @()
    $m = get-pathenv -machine
    $u = get-pathenv -user

    write-verbose " # machine PATH:"
    write-verbose "$m"
    write-verbose " # user    PATH:"
    write-verbose "$u"


    $path += $m
    $path += $u

    
    $env:path = [string]::Join(";",$path)
}


function escape-regex($pattern) {
    return $pattern.replace("\","\\")
}

function Get-RelativePath (
[Parameter(Mandatory=$true)][Alias("dir")][string] $from,
[Parameter(Mandatory=$true)][string][Alias("fullname")] $to
) {
    
    $dir = gi $from
    if (test-path $from) { 
        $it = (gi $from)
        $dir = $it.fullname;  
        if (!$it.psiscontainer) {
            #this is a file, we need a directory
            $dir = split-path -Parent $dir
        }
    } 
    else { 
        $dir = $from 
    }
    if (test-path $to) { $FullName = (gi $to).fullname } else { $FullName = $to }
    
    

    $separator = "\"
    $issubdir = $FullName -match (escape-regex $dir)
    
    if ($issubdir) {
        $p = $FullName.Substring($Dir.length).Trim($separator)
    } 
    else {
        $commonPartLength = 0
    
        for($i = 0; $i -lt ([MAth]::Min($dir.Length, $FullName.Length)) -and $dir[$i] -ieq $FullName[$i]; $i++) {
            $commonPartLength++
        }
        if ($commonPartLength -eq 0) {
            throw "Items '$dir' and '$fullname' have no common path"
        }

        $commonDir = $FullName.Substring(0, $commonPartLength)
        $curdir = $dir.Substring($commonPartLength)
        $filerel = $fullname.Substring($commonPartLength)
        $level = $curdir.Split($separator).Length    
        $val = ""
        $dots = $val
        1..$level | % { $dots += "$separator.." }

        $p = join-path $dots $filerel
    }

    return $p.Trim($separator)
    
}


Function Get-ShortPath ([Parameter(ValueFromPipeline=$true)]$path)
{
 BEGIN { 
    $fso = New-Object -ComObject Scripting.FileSystemObject 
}

PROCESS {
  if ($path -is [string]) {
    $path = gi $path
  }
  If ($path.psiscontainer)
  {
    $fso.getfolder($path.fullname).ShortPath
  }

  ELSE {
    $fso.getfile($path.fullname).ShortPath
    } 
} 
}
