
function find-command($wally, [switch][bool]$useShellExecute = $true) {
    if ($useShellExecute) {
        cmd /c "where $wally"
    } else {
        # todo: use pure-powershell method
        throw "not implemented"
    }
    #Get-Command $wally
}

function set-envvar([Parameter(Mandatory=$true)][string]$name, [Parameter(Mandatory=$true)] $val, [switch][bool]$user, [switch][bool]$machine, [switch][bool]$current = $true){
    if ($current) {
        write-host "scope=Process: setting env var '$name' to '$val'" 
        [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::Process);
    }
    if ($user) {
        write-host "scope=User: setting env var '$name' to '$val'"
        [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::User);
    }
    if ($machine) {
        write-host "scope=Machine setting env var '$name' to '$val'"
        [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::Machine);
    }
}

function get-envvar([Parameter(Mandatory=$true)][string]$name, [switch][bool]$user, [switch][bool]$machine, [switch][bool]$current){
    $val = @()
    if ($user) {
        $val += [System.Environment]::GetEnvironmentVariable($name, [System.EnvironmentVariableTarget]::User);
    }
    if ($machine) {
        $val += [System.Environment]::GetEnvironmentVariable($name, [System.EnvironmentVariableTarget]::Machine);
    }
    if (!$user.IsPresent -and !$machine.IsPresent) {
        $current = $true
    }
    if ($current) {
        $val = invoke-expression "`$env:$name"
    }
    if ($val -ne $null) {
        $p = $val.Split(';')
    } else {
        $p = @()
    }
    
    return $p
}


function add-toenvvar {
    [CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$name, 
    [Parameter(valuefrompipeline=$true)]$path, 
    [switch][bool] $persistent, 
    [switch][bool]$first
)
  
process {
      
    $p = get-envvar $name
    $p = $p | % { $_.trimend("\") }

    $paths = @($path) 
    $paths | % { 
        $path = $_.trimend("\")
        write-verbose "adding $path to $name"
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
    
    $val = [string]::Join(";",$p)
    
    Invoke-Expression "`$env:$name = `$val"

    [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::Process);
    if ($persistent) {
          write-warning "saving global $name"
          [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::Machine);
    }
}
}


function get-pathenv {
[CmdLetBinding(DefaultParameterSetName="scoped")]
param(
    [Parameter(ParameterSetName="scoped")]
    [switch][bool]$user,
    [Parameter(ParameterSetName="scoped")] 
    [switch][bool]$machine, 
    [Alias("process")]
    [Parameter(ParameterSetName="scoped")]
    [switch][bool]$current, 
    [Parameter(ParameterSetName="all")][switch][bool]$all
)
 
    $scopespecified = $user.IsPresent -or $machine.IsPresent -or $current.IsPresent
    $path = @()
    $userpath = get-envvar "PATH" -user 
    if ($user) {
        $path += $userpath
    }
    $machinepath = get-envvar "PATH" -machine
    if ($machine -or !$scopespecified) {
        $path += $machinepath
    }
    if (!$user.IsPresent -and !$machine.IsPresent) {
        $current = $true
    }
    $currentPath = get-envvar "PATH" -current
    if ($current) {
        $path = $currentPath
    }
    
    if ($all) {
        $h = @{
            user = $userpath
            machine = $machinepath
            process = $currentPath
        }
        return @(
            "`r`n USER",
            " -----------",
            $h.user, 
            "`r`n MACHINE",
            " -----------",
            $h.machine, 
            "`r`n PROCESS",
            " -----------",
            $h.process
            )
    }
    
    return $path
}

function add-topath {
[CmdletBinding()]
param([Parameter(valuefrompipeline=$true)]$path, [Alias("p")][switch][bool] $persistent, [switch][bool]$first, [switch][bool] $user) 

process { 
    if ($user) {
        $p = Get-Pathenv -user
    } elseif ($persistent) {
        $p = Get-Pathenv -machine
    } else {
        $p = Get-Pathenv -process
    }
    $p = $p | % { $_.trimend("\") }
    $p = @($p)
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

    if ($user) {
        write-warning "saving user PATH"
          [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::User);
          #add also to process PATH
          add-topath $path -persistent:$false -first:$first
    } elseif ($persistent) {            
          write-warning "saving global PATH"
          [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Machine);
          #add also to process PATH
          add-topath $path -persistent:$false -first:$first
    } else {
        [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Process);
    }
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

function test-envpath($path, [switch][bool]$show) {
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


function update-EnvVar($name) {
    
    $path = @()
    $m = get-envvar $name -machine
    $u = get-envvar $name -user

    write-verbose " # machine $name :"
    write-verbose "$m"
    write-verbose " # user    $name :"
    write-verbose "$u"
       
    $path += $m
    $path += $u

    $val = [string]::Join(";",$path)
    invoke-expression "`$env:$name = `$val"
}


function update-Env {
[CmdletBinding()]
param()
    update-EnvVar "Path"
    update-EnvVar "PsModulePath"  
}


function get-escapedregex($pattern) {
    return [Regex]::Escape($pattern)
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

function test-junction($path) {
    $_ = $path
    $mode = "$($_.Mode)$(if($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {'J'})"
    return $mode -match "J"        
}

function install-modulelink {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(mandatory=$true)][string]$modulename) 
    
    
    $target = $modulename
    if ($target.EndsWith(".psm1")) {
        $target = split-path -parent ((get-item $target).FullName)    
    }
    $target = (get-item $target).FullName
    
    $modulename = split-path -leaf $target
    $path = "C:\Program Files\WindowsPowershell\Modules\$modulename"
    if (test-path $path) {
        if ($PSCmdlet.ShouldProcess("removing path $path")) {
            # packagemanagement module may be locking some files in existing module dir
            if (gmo powershellget) { rmo powershellget }
            if (gmo packagemanagement) { rmo packagemanagement }
            remove-item -Recurse $path -force
            if (test-path $path) { remove-item -Recurse $path -force }
        }
    }
    write-host "executing mklink /J $path $target"
    cmd /C "mklink /J ""$path"" ""$target"""
}


new-alias where-is get-command
new-alias refresh-env update-env
new-alias refreshenv refresh-env
new-alias contains-path test-envpath
new-alias escape-regex get-escapedregex