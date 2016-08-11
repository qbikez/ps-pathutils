<#
.Synopsis 
finds the specified command on system PATH
.Description 
uses `where` command to find commands on PATH
#>
function Find-Command {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$wally, [switch][bool]$useShellExecute = $true) 
    $usePsFallback = $false
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $useShellExecute = $true       
        $usePsFallback = $true 
    }
    if ($useShellExecute) {
        $p = cmd /c "where $wally"
        if ($p -ne $null) { 
            return @($p) | % { 
                new-object pscustomobject -property @{
                    CommandType = "Application"
                    Name = (split-path $_ -leaf)
                    Source = $_
                    Version = $null
                }
            }
        }
    }
    if (!$useShellExecute -or $usePsFallback)  
    {
        # todo: use pure-powershell method
        return Get-Command $wally -ErrorAction Ignore
    }

    return $null
}

<#
.Synopsis 
Set Environment variable 
.Parameter name 
variable name
.Parameter val 
variable value
.Parameter user 
set variable in user scope (persistent)
.Parameter machine 
set variable in machine scope (persistent)
.Parameter current 
(default=true) set variable in current's process scope
#>
function Set-EnvVar([Parameter(Mandatory=$true)][string]$name, [Parameter(Mandatory=$true)] $val, [switch][bool]$user, [switch][bool]$machine, [switch][bool]$current = $true){
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

<#
.Synopsis 
Get Environment variable value
.Parameter name 
variable name
.Parameter user
get variable from user scope (persistent)
.Parameter machine
get variable from machine scope (persistent)
.Parameter current 
(default=true) get variable from current process scope
#>
function Get-EnvVar([Parameter(Mandatory=$true)][string]$name, [switch][bool]$user, [switch][bool]$machine, [Alias("process")][switch][bool]$current){
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


<#
.Synopsis 
Add s value to enviroment variable (like PATH)
.Description 
assumes that lists are separated by `;`
.Parameter name 
variable name
.Parameter path 
path to add to the list
.Parameter persistent 
save the variable in machine scope
.Parameter first 
preppend the value instead of appending
#>
function Add-ToEnvVar {
    [CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$name, 
    [Parameter(valuefrompipeline=$true)]$path, 
    [switch][bool] $persistent, 
    [switch][bool] $first
)
  
process {
      
    $p = get-envvar $name
    $p = @($p | % { $_.trimend("\") })

    $paths = @($path) 
    foreach ($_ in $paths) { 
        $path = $_.replace("/","\").trimend("\")
        if ($p -contains $path) {
            write-verbose "Env var '$name' already contains path '$path'"
            continue
        }
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


<#
.Synopsis 
Gets PATH env variable
.Parameter user 
Get the value from user scope
.Parameter machine 
(default) Get the value from machine scope
.Parameter process 
Get the value from process scope
.Parameter all 
Return values for each scope
#>
function Get-PathEnv {
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


<#
.SYNOPSIS 
Adds the specified path to PATH env variable
.DESCRIPTION 
assumes that paths on PATH are separated by `;`
.PARAMETER path 
path to add to the list
.PARAMETER persistent 
save the variable in machine scope
.PARAMETER first 
preppend the value instead of appending
.PARAMETER user 
save to user scope
#>
function Add-ToPath {
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

<#
.Synopsis 
removes path from PATH env variable
.Parameter path 
path to remove-frompath
.Parameter persistent 
save modified path in machine scope
#>
function Remove-FromPath {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)]$path, 
    [Alias("p")][switch][bool] $persistent
)

    $paths = @($path) 
    $p = $env:Path.Split(';')
    $defaultSlash = "\"
    $altSlash = "/" 
    $p = $p | % { $_.replace($altSlash, $defaultSlash).trimEnd($defaultSlash) }
    $removed = @()
    $paths | % { 
        $path = $_.replace($altSlash, $defaultSlash).trimEnd($defaultSlash)
        $found = $p | ? { $_ -ieq $path }
        if ($found -ne $null) {
            write-verbose "found $($found.count) matches"
            $p = @($p | ? { !($_ -ieq $path) })    
            $removed += $found
        }
    }

    if ($removed.length -eq 0) {
        write-warning "path '$paths' not found in PATH"
    }

  
    $env:path = [string]::Join(";",$p)

    [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Process);
    if ($persistent) {
        write-warning "saving global PATH"
        [System.Environment]::SetEnvironmentVariable("PATH", $env:Path, [System.EnvironmentVariableTarget]::Machine);
    }
}

<#
    .Synopsis 
    tests if specified path is in PATH env variable
    .Parameter path 
    path to test-envpath
    .Parameter show 
    should return the found path value

#>
function Test-EnvPath([Parameter(Mandatory=$true)]$path, [switch][bool]$show) {
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


<#
    .synopsis 
    Reloads specified env variable from Registry
    .parameter name 
    variable name
#>
function Update-EnvVar {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$name, [switch][bool] $pathmode, [switch][bool] $force) 
    
    if ($name -eq "PATH" -or $name -eq "PATHEXT") { 
        $pathmode = $true
        $force = $true
    }
    $m = get-envvar $name -machine
    $u = get-envvar $name -user
    $p = get-envvar $name -current

    write-verbose " # machine $name :"
    write-verbose "$m"
    write-verbose " # user    $name :"
    write-verbose "$u"
    write-verbose " # proc    $name :"
    write-verbose "$p"

    if($p -ne $null -and !$force) {
         write-verbose "not overriding process variable $name"
         return 
    }

    if ($pathmode) {
        $path = @()
        $path += $m
        $toadd = $u | ? { $_ -cnotin $m }        
        $path += $toadd        
        $val = $path
    }
    else {
        if ($u -ne $null) { $val = $u }
        else { $val = $m }
    }

    if ($val -is [Array]) {
        $val = [string]::Join(";",$val)
        $val = $val.Trim(";")
    }

    
    set-item env:/$name -value $val
}

<#
    .synopsis 
    reloads PATH and PsModulePath variables fro registry
#>
function Update-Env {
[CmdletBinding()]
param([Alias("all")][switch][bool] $force)
    $vars = [System.Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine)
    foreach($v in $vars.GetEnumerator()) {
        update-envvar $v.name -force:$force
    }

    $vars = [System.Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::User)
    foreach($v in $vars.GetEnumerator()) {
        update-envvar $v.name -force:$force
    }
}

function Get-EscapedRegex($pattern) {
    return [Regex]::Escape($pattern)
}

<#
    .synopsis 
    returns a string that is ecaped for REGEX use
#>
function Get-EscapedRegex([Parameter(ValueFromPipeline=$true,Position=0)]$pattern) {
    process {
        return [Regex]::Escape($pattern)
    }
}

<#
    .synopsis 
    tests if given path is relative 
#>
function Test-IsRelativePath([Parameter(Mandatory=$true)]$path) {
    if ([System.IO.Path]::isPathRooted($path)) { return $false }
    if ($path -match "(?<drive>^[a-zA-Z]*):(?<path>.*)") { return $false }
    return $true
}

<#
    .synopsis 
    joins two paths and returns absolute path
    .parameter from 
    base directory or file
    .parameter to 
    second path to join 

    .example
    Get full path for a file
    Get-AbsolutePath . file.txt
       
       c:\test\file.txt
#>
function Get-AbsolutePath([Parameter(Mandatory=$true)][Alias("dir")][string] $from,
[Parameter(Mandatory=$true)][string][Alias("fullname")] $to
) {
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
    
    $p = join-path $dir $to
    if (test-path $p) {
        return (gi $p).FullName
    }
    else {
        return $p
    }
}

<#
    .synopsis 
    returns drive symbol for path (i.e. `c`)
#>
function Get-DriveSymbol([Parameter(Mandatory=$true)]$path) {
    if ($path -match "(?<drive>^[a-zA-Z]*):(?<path>.*)") { return $matches["drive"] }
    return $null
}

<#  
    .synopsis 
    calculates relative path
    .description 
    when given a base path, calculates relative path to the other file location
    .parameter from 
    base path (will calculate path relative to this location)
    .parameter to 
    target file or directory
#>
function Get-RelativePath {
[CmdletBinding()]
param(
[Parameter(Mandatory=$true)][Alias("dir")][string] $from,
[Parameter(Mandatory=$true)][string][Alias("fullname")] $to
) 
    try {
        write-verbose "get relative paths of:"
        write-verbose "$from"
        write-verbose "$to"
    $dir = $from 
    $bothabsolute = !(test-ispathrelative $from) -and !(test-ispathrelative $to)
    if ($bothabsolute) { Write-Verbose "Both paths are absolute" }
    if (test-path $from) { 
        $it = (gi $from)
        if ((test-ispathrelative $from) -or $bothabsolute) {
             Write-Verbose "using full path for comparison: $($it.fullname)"
             $dir = $it.fullname 
            }  
        if (!$it.psiscontainer) {
            #this is a file, we need a directory
            $dir = split-path -Parent $dir
            write-verbose "changed 'from' from file to directory: $dir"
        }
    } else {
        write-verbose "path '$from' does not exist"
    }
    
    $FullName = $to 
    if ((test-path $to)) {
        if (((test-ispathrelative $to) -or $bothabsolute)) {
            $it = gi $to
            Write-Verbose "using full path for comparison: $($it.fullname)"
            $FullName = $it.fullname 
        }
        if ((get-drivesymbol $from) -ne (get-drivesymbol $to)) {
            $it = gi $to
            #maybe the drive symbol is just an alias?
            Write-Verbose "different drive symbols '$(get-drivesymbol $from)' and '$(get-drivesymbol $to)'. using full path for comparison: $($it.fullname)"
            $FullName = $it.fullname 
        }
    } else {
        write-verbose "path '$to' does not exist"
    }
    
    

    $separator = "\"
    $issubdir = $FullName -match (escape-regex $dir)
    
    if ($issubdir) {
        $p = $FullName.Substring($Dir.length).Trim($separator)
    } 
    else {
        $commonPartLength = 0
        $lastslashidx = -10
        for($i = 0; $i -lt ([MAth]::Min($dir.Length, $FullName.Length)) -and $dir[$i] -ieq $FullName[$i]; $i++) {
            $commonPartLength++
            if($dir[$i] -eq "\" -or $dir[$i] -eq "/") {
                $lastslashidx = $i
            }
        }
        $commonPartLength = $lastslashidx + 1
        if ($commonPartLength -le 0) {
            throw "Items '$dir' and '$fullname' have no common path"
        }

        $commonDir = $FullName.Substring(0, $commonPartLength)
        $curdir = $dir.Substring($commonPartLength)
        $filerel = $fullname.Substring($commonPartLength)
        $level = $curdir.Trim($separator).Split($separator).Length    
        $val = ""
        $dots = $val
        1..$level | % { $dots += "$separator.." }

        $p = join-path $dots $filerel
    }

    return $p.Trim($separator)
    } catch {
        throw "failed to get relative path from '$from' to '$to': $($_.Exception)`r`n$($_.ScriptStackTrace)"
    }
}

<#

#>
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

<# 
    .synopsis 
    creates a Junction (File system directory link) at $path, targeting $target
#>
function New-Junction($path, $target) {
    cmd /C mklink /J $path $target
}

<#
    .synopsis 
    checks if given path is a Junction (File system directory link)
#>
function Test-Junction([Parameter(Mandatory=$true)]$path) {
    $_ = get-item $path
    $mode = "$($_.Mode)$(if($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {'J'})"
    return $mode -match "J"        
}

<#
    .synopsis 
    return junction taget directory
#>
function Get-JunctionTarget([Parameter(Mandatory=$true)]$p_path)
{
    fsutil reparsepoint query $p_path | where-object { $_ -imatch 'Print Name:' } | foreach-object { $_ -replace 'Print Name\:\s*','' }
}

<#
    .synopsis 
    installs a module as a linked directory on `PsModulePath`
    .description 
    this function creates a link to a module 
    in `C:\Program Files\WindowsPowershell\Modules` directory
    .parameter modulepath 
    path to installed module (may be a adirectory or .psm1 file)
    .parameter modulename 
    if `modulepath` contains multiple modules, specify a module name
#>
function Install-ModuleLink {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(mandatory=$true)][string]$modulepath,
        [Parameter(mandatory=$false)]$modulename) 
    
    $target = $modulepath
    if ($target.EndsWith(".psm1")) {
        $target = split-path -parent ((get-item $target).FullName)    
    }
    $target = (get-item $target).FullName
    if ($modulename -eq $null) {
        $modulename = split-path -leaf $target
    }
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

<#
    .synopsis 
    updates specified linked module from source control
    .description 
    if a module is a linked directory, that is under
    GIT or HG source control, then pull the newest changes and
    update the repo
#>
function Update-ModuleLink {
    [CmdletBinding(SupportsShouldProcess=$false)]
    param([Parameter(mandatory=$false)]$module)
    $modulename = $module
    if ($modulename -eq $null) {
        $modules = Get-ChildItem "C:\Program Files\WindowsPowershell\Modules" | ? {
             $_.PsIsContainer -and (Test-Junction $_.FullName) 
        }

        $modules | %{
            Update-ModuleLink $_.name
        }
        return
    }
    $path = "C:\Program Files\WindowsPowershell\Modules\$modulename"
    if (test-path $path) {
        pushd
        try {
            if (!(test-junction $path)) {
                throw "'$path' does not seem like a junction to me"
            }
            $target = get-junctiontarget $path
            cd $target
            if (".hg","..\.hg","..\..\.hg" | ? { test-path $_ } ) {
                write-host "running hg pull in '$target'"
                hg pull
                hg update
            } elseif (".git","..\.git","..\..\.git" | ? { test-path $_ } ) {
                write-host "running git pull in '$target'"
                git pull
            } else {
                throw "path '$target' does not contain any recognizable VCS repo (git, hg)"
            }
        }
        finally {
            popd
        }
    }
    else {
        throw "Module '$module' not found at path '$path'"
    }
    
}
function Get-Listing
(
    [string] $Path = ".", 
    $Excludes = @(), 
    [Alias("Recurse")]
    [switch] $Recursive,
    
    [string] $Filter = $null,
    $include = @(),
    [switch][bool] $Files,
    [switch][bool] $Dirs 
) {

    $r = _GetListing @PSBoundParameters
    @($r) | write-output
}

function _GetListing
(
    [string] $Path = ".", 
    $Excludes = @(), 
    [Alias("Recurse")]
    [switch] $Recursive,
    
    [string] $Filter = $null,
    $include = @(),
    [switch][bool] $Files = $false,
    [switch][bool] $Dirs = $false,
    $level = 0,
    $total = @()
)
{
try {
	$result = @()
	if (($Path -eq $null) -or ($Path.Trim() -eq "")) {
		#return $result
	} 
   if (!$dirs.ispresent -and !$files.ispresent) {
       # get dirs by default
       $dirs = $true
       $files = $true
   }
   #$Excludes = @($Excludes | % { $_ -replace "\\","/" })

    if ($Recurse) { $Recursive = $Recurse }
	
    Write-Progress -Activity "getting subdirs. Items Found = $($total.length)" -Status "path=$Path"
    $fullpath = (get-item $path).FullName
    
    if (($fullpath -eq $null) -or ($fullpath.Trim() -eq "")) {
        write-warning "cannot find or resolve path '$path'"
		#return $result
	} 
    $path = $fullpath
    try {
        $topDirs = Get-ChildItem $Path -ErrorAction Stop
    } catch {
        write-error "failed to get child items for path '$path': $_"
        $topDirs = @()
    }
    $topDirs = $topDirs | where { 
        $a = $_
        $dirname = "$($a.FullName.Replace("\","/").Substring($Path.length).Trim("/"))/"
        $matchingExcludes = ($Excludes | where { 
                $dirname -match "$_"
              })
        return $_.PSIsContainer `
        -and ($_.Name -ne $null) `
        -and ($matchingExcludes -eq $null)
    } 
    
    if ($Dirs) {
        $f = $topDirs | where { 
            $_ -ne $null `
            -and ([string]::IsNullOrEmpty($Filter) -or $_.Name -like $Filter) `
            -and ([string]::IsNullOrEmpty($include) -or $_.Name -match $include) `
            }
        if (@($f).Length -gt 0) {
            $result += $f
            $total += $f
            @($f) | write-output 
        }
    }
    if ($Files) {
        try {
            if (!(test-path $Path)) {
                write-warning "path '$Path' not found"
            }
            $ls = Get-ChildItem $path -Filter:$Filter -Recurse:$false | ? { !$_.PSIsContainer }   
            if ($include -ne $null -and $include.length -gt 0) {
                $ls = $ls | ? {
                    $it = $_
                    $name = $it.name
                    $matchingIncludes = $include | ? {
                        ## handle simple globbing case (i.e. *.exe)
                        if ($_.Startswith("*")) {
                            $_ = [Regex]::Escape($_.Substring(1))
                            $_ = ".*" + $_
                        }
                        $name -match $_
                    }
                    return $matchingIncludes -ne $null
                }
            }
            if (@($ls).Count -gt 0) {      
                $result += $ls
                $total += $ls
                @($ls) | write-output
            }
        } catch {
            write-error "failed to get child items for path '$path': $_"
        }
    }
    
    if ($Recursive) {
        foreach($dir in $topDirs) {
            if ([string]::IsNullOrEmpty($dir)) {
                Write-Warning "empty dir!"
            }
            if ($dirs `
                -and (![string]::IsNullOrEmpty($Filter) -and $dir.Name -like $Filter) `
                -and (![string]::IsNullOrEmpty($include) -and $dir.Name -match $include)) {
                #do not recurse into matching dirs
                continue
            }
            else {
                try {
                    $f = _GetListing -Path $dir.FullName -Excludes $Excludes -Recursive:$Recursive -Filter:$Filter -Files:$Files -Dirs:$Dirs -include:$include -level ($level+1) -total $total 
                  
                    if (@($f).Length -gt 0) {
                        $result += $f
                        $total += $f
                        @($f) | write-output
                    }
                    
                } catch {
                    throw
                }
            }
        }
    }

    #return $result | where { $_ -ne $null }
    }
    catch {
        throw
    }
    finally {
        if ($level -eq 0) { 
            Write-Progress -Activity "getting subdirs. Items Found = $($total.length)" -Status "DONE" -PercentComplete 100 -Completed 
        }
    }
}


function find-upwards($pattern, $path = "." ) {
        $path = (get-item $path).FullName
        $foundfile = $null
        if (!(get-item $path).PsIsContainer) {
            $dir = split-path -Parent $path
        }
        else {
            $dir = $path
        }
        while(![string]::IsNullOrEmpty($dir)) {
            if (($pattern | % { "$dir/$_" } | test-path) -eq $true) {
                $reporoot = $dir
                $foundfile = $pattern | % { "$dir/$_" } | ? { test-path $_ } | select -First 1
                break;
            }
            $dir = split-path -Parent $dir
        }
        
        return $foundfile
}

new-alias get-childitemsfiltered get-listing
new-alias Where-Is find-command
new-alias Refresh-Env update-env
# refreshenv alias might be already declared by chocolatey
if ((get-alias refreshenv -erroraction Ignore) -eq $null) {
	new-alias RefreshEnv refresh-env
}
new-alias Contains-Path test-envpath
new-alias Escape-Regex get-escapedregex
new-alias Test-IsPathRelative Test-IsRelativePath
new-alias Get-PathRelative Get-RelativePath
new-alias Test-IsJunction Test-Junction

Export-moduleMember -Function * -Alias *