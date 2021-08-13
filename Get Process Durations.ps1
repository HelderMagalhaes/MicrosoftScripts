﻿#requires -version 3
<#
    Show process durations via security event logs when process creation/termination auditing is enabled

    @guyrleech 2019

    Modification History:

    10/05/2019  GRL   Added subject logon id to grid view output
                      Added enable/disable of process creatiuon and termination auditing

    12/05/2019  GRL   Remove process termination events from array for speed increase
                      Enable cmd line auditing when -enable specified

    13/05/2019  GRL   Added creation and modification times of executables & executable summary option
                      Added multiple computer capability

    23/05/2019  GRL   Added option for processing saved event log files
                      Added option for having no exe file details

    13/06/2019  GRL   Moved end event cache to hash table for considerable speed improvement

    14/06/2019  GRL   Fixed bug giving negative durations. Filtering on process stop collection building

    24/07/2019  GRL   Added time frames via logon sessions from LSASS
                      Added -listSessions to just show LSASS sessions retrieved
                      Changed -logon to -logonTimes and -boot to -bootTimes

    01/08/2019  GRL   Added microsecond granularity to logon times displayed

    03/08/19    GRL   Added elevation information and -elevated
                      Added -parents and -notparents

    04/08/19    GRL   Added -notProcessNames, -notsigned and -nostop

    18/08/19    GRL   Fixed logic bug with -nostop not giving process durations when not specified

    04/09/19    GRL   Fixed bug with -processNames and -notProcessNames

    09/10/19    GRL   Added -duration parameter

    03/06/20    GRL   Added -sinceBoot and -crashes

    05/06/20    GRL   Shows process which ended but start event not in the time window
                      If username in process exit different to starting username then displays this different user name
                      Only get logon sessions if logn times or sessions requested as very slow when sessions are high

    23/02/21    GRL   Moved win32_systemaccount query to be run only if the hashtable is required

    13/08/21    GRL   Added -allTerminations
#>

<#
.SYNOPSIS

Retrieve process start events from the security event log, try and find corresponding process exit and optionally also show start time relative to that user's logon and/or computer boot

.PARAMETER usernames

Only include processes for users which match this regular expression

.PARAMETER processNames

Only include processes which have a match in this comma separated list of regular expressions

.PARAMETER notProcessNames

Exclude processes which have a match in this comma separated list of regular expressions

.PARAMETER eventLog

The path to an event log file containing saved events

.PARAMETER noStop

Do not include details of the process end, duration or exit code

.PARAMETER notSigned

Only include executables which are not signed or the certificates are invalid

.PARAMETER start

Only retrieve processes started after this date/time

.PARAMETER end

Only retrieve processes started before this date/time

.PARAMETER last

Show processes started in the preceding period where 's' is seconds, 'm' is minutes, 'h' is hours, 'd' is days, 'w' is weeks and 'y' is years so 12h will retrieve all in the last 12 hours.

.PARAMETER listSessions

Just list the interactive logon sessions found on each computer

.PARAMETER parents

A comma separated list of parent process names to include only children of these in the output. Use =notself= to exclude processes where the child is the same as the specified parent

.PARAMETER notParents

A comma separated list of processes which if the process has a parent of one of these it will be excluded. Use =self= to exclude processes where the child is the same as the specified parent

.PARAMETER elevated

Only include processes which are run elevated

.PARAMETER logonTimes

Include the logon time and the time since logon for the process creation for the logon session this process belongs to

.PARAMETER bootTimes

Include the boot time and the time since boot for the process creation 

.PARAMETER enable

Enable process creation and termination auditing

.PARAMETER disable

Disable process creation and termination auditing

.PARAMETER sinceBoot

Show process launches starting from the boot time

.PARAMETER crashes

Cross reference process exits to crash events in the Application log

.PARAMETER outputFile

Write the results to the specified csv file

.PARAMETER noGridview

Output the results to the pipeline rather than a grid view

.PARAMETER excludeSystem

Do not include processes run by the system account

.PARAMETER duration

Show events logged from the start specified via -start for the specified period where 's' is seconds, 'm' is minutes, 'h' is hours, 'd' is days, 'w' is weeks and 'y' is years so 2m will retrieve events for 2 minutes from the given start time

.PARAMETER noFileInfo

Do not include exe file information

.PARAMETER summary

Show a summary by executable including number of executions and file details

.PARAMETER computers

A comma separated list of computers to run query the security event logs of. Firewall must allow Remote Eventlog.

.PARAMETER allTerminations

Search for process termination events up to the current time rather than just in the time window specified by -start and -end

.EXAMPLE

& '.\Get Process Durations.ps1' -last 2d -logon -username billybob -boot

Find all process creations and corresponding terminations for the user billybob in the last 2 days, calculate the start time relative to logon for that user's session and relative to the the boot time and display in a grid view

.EXAMPLE

& '.\Get Process Durations.ps1' -enable

Enable process creation and termination auditing

.EXAMPLE

& '.\Get Process Durations.ps1' -notParents explorer.exe,cmd.exe,powershell.exe,=self= -processNames powershell.exe,cmd.exe,powershell_ise.exe

Show all instances of powershell.exe, cmd.exe and powershell_ise.exe processes where the parent process is not one of those listed and not one of the processes listed via -processNames

.EXAMPLE

& '.\Get Process Durations.ps1' -parents winword.exe,excel.exe,outlook.exe.powerpnt.exe,excel.exe,=notself= -notProcesses conhost.exe

Show all instances of processes, except conhost.exe, where the parent process is one of those listed as long as it is not another instance of the same process.

.EXAMPLE

& '.\Get Process Durations.ps1' -elevated -excludeSystem

Show all processes which were run elevated but not using the system account

.EXAMPLE

& '.\Get Process Durations.ps1' -notsigned -noStop

Show all processes where the executable is not signed but do not include process end, duration or exit codes

.EXAMPLE

& '.\Get Process Durations.ps1' -listSessions

Show all interactive logon sessions from LSASS since last boot

.EXAMPLE

& '.\Get Process Durations.ps1' -summary -start "08:00" -computers xa1,xa2

Find all process creations on computers xa1 and xa2 since 0800 today and produce a grid view summarising per unique executable

.NOTES

Must have process creation and process termination auditing enabled although this script can enable/disable if required

If process command line auditing is enabled then the command line will be included. See https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/manage/component-updates/command-line-process-auditing

Enable/Disable of auditing will not work in non-English locales

When run for multiple computers, the file information is only taken from the first instance of that executable encountered so not compared across computers
#>

[CmdletBinding()]

Param
(
    [string]$username ,
    [string[]]$processNames ,
    [string[]]$notProcessNames ,
    [string[]]$pids ,
    [string]$start ,
    [string]$end ,
    [string]$last ,
	[string]$duration ,
    [string]$eventLog ,
    [string]$logonOf ,
    [int]$beforeSeconds = 30 ,
    [int]$afterSeconds = 120 ,
    [string]$logonAround ,
    [int]$skipLogons = 0 ,
    [switch]$listSessions ,
    [string[]]$parents ,
    [string[]]$notParents ,
    [string[]]$computers = @( $env:COMPUTERNAME ) ,
    [switch]$elevated ,
    [switch]$notSigned ,
    [switch]$logonTimes ,
    [switch]$bootTimes ,
    [switch]$sinceBoot ,
    [switch]$crashes ,
    [switch]$noStop ,
    [switch]$enable ,
    [switch]$disable ,
    [switch]$summary ,
    [string]$outputFile ,
    [switch]$nogridview ,
    [switch]$noFileInfo ,
    [switch]$excludeSystem ,
    [switch]$allTerminations 
)

[string[]]$startPropertiesMap = @(
    'SubjectUserSid' ,    ## 0
    'SubjectUserName' ,   ## 1
    'SubjectDomainName' , ## 2
    'SubjectLogonId' ,    ## 3
    'NewProcessId' ,      ## 4
    'NewProcessName' ,    ## 5
    'TokenElevationType' ,## 6
    'ProcessId' ,         ## 7
    'CommandLine' ,       ## 8
    'TargetUserSid' ,     ## 9
    'TargetUserName' ,    ## 10
    'TargetDomainName' ,  ## 11
    'TargetLogonId' ,     ## 12
    'ParentProcessName'   ## 13
)

Set-Variable -Name 'endSubjectUserSid' -Value 0 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endSubjectUserName' -Value 1 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endSubjectDomainName' -Value 2 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endSubjectLogonId' -Value 3 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endStatus' -Value 4 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endProcessId' -Value 5 -Option ReadOnly -ErrorAction SilentlyContinue
Set-Variable -Name 'endProcessName' -Value 6 -Option ReadOnly -ErrorAction SilentlyContinue

[hashtable]$auditingGuids = @{
    'Process Creation'    = '{0CCE922C-69AE-11D9-BED3-505054503030}'
    'Process Termination' = '{0CCE922C-69AE-11D9-BED3-505054503030}' }

## https://www.codeproject.com/Articles/18179/Using-the-Local-Security-Authority-to-Enumerate-Us
$LSADefinitions = @'
    [DllImport("secur32.dll", SetLastError = false)]
    public static extern uint LsaFreeReturnBuffer(IntPtr buffer);

    [DllImport("Secur32.dll", SetLastError = false)]
    public static extern uint LsaEnumerateLogonSessions
            (out UInt64 LogonSessionCount, out IntPtr LogonSessionList);

    [DllImport("Secur32.dll", SetLastError = false)]
    public static extern uint LsaGetLogonSessionData(IntPtr luid, 
        out IntPtr ppLogonSessionData);

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING
    {
        public UInt16 Length;
        public UInt16 MaximumLength;
        public IntPtr buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID
    {
        public UInt32 LowPart;
        public UInt32 HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_LOGON_SESSION_DATA
    {
        public UInt32 Size;
        public LUID LoginID;
        public LSA_UNICODE_STRING Username;
        public LSA_UNICODE_STRING LoginDomain;
        public LSA_UNICODE_STRING AuthenticationPackage;
        public UInt32 LogonType;
        public UInt32 Session;
        public IntPtr PSiD;
        public UInt64 LoginTime;
        public LSA_UNICODE_STRING LogonServer;
        public LSA_UNICODE_STRING DnsDomainName;
        public LSA_UNICODE_STRING Upn;
    }

    public enum SECURITY_LOGON_TYPE : uint
    {
        Interactive = 2,        //The security principal is logging on 
                                //interactively.
        Network,                //The security principal is logging using a 
                                //network.
        Batch,                  //The logon is for a batch process.
        Service,                //The logon is for a service account.
        Proxy,                  //Not supported.
        Unlock,                 //The logon is an attempt to unlock a workstation.
        NetworkCleartext,       //The logon is a network logon with cleartext 
                                //credentials.
        NewCredentials,         //Allows the caller to clone its current token and
                                //specify new credentials for outbound connections.
        RemoteInteractive,      //A terminal server session that is both remote 
                                //and interactive.
        CachedInteractive,      //Attempt to use the cached credentials without 
                                //going out across the network.
        CachedRemoteInteractive,// Same as RemoteInteractive, except used 
                                // internally for auditing purposes.
        CachedUnlock            // The logon is an attempt to unlock a workstation.
    }
'@

<#
Function Load-GUI( $inputXml )
{
    $form = $NULL
    [xml]$XAML =  $inputXML -replace 'mc:Ignorable="d"' , '' -replace 'x:N' ,'N'  -replace '^<Win.*' , '<Window'
    $reader = New-Object Xml.XmlNodeReader $xaml

    try
    {
        $form = [Windows.Markup.XamlReader]::Load( $reader )
    }
    catch
    {
        Write-Error -Message "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .NET is installed.`n$_"
        return $null
    }
 
    if( $form )
    {
        $xaml.SelectNodes('//*[@Name]') | ForEach-Object `
        {
            Set-Variable -Name "WPF$($_.Name)" -Value $Form.FindName($_.Name) -Scope Global
        }
    }

    return $form
}
#>

Function Get-FileInfo
{
    Param
    (
        [ref]$started
    )

    [bool]$excluded = $false 

    if( ! ( $exeProperties = $fileProperties[ $started.Value.NewProcessName ] ) )
    {
        if( $remoteParam.Count )
        {
            if( $result = Invoke-Command @remoteParam -ScriptBlock { Get-ItemProperty -Path $($using:started).NewProcessName -ErrorAction SilentlyContinue } )
            {
                ## This is a deserialised object which doesn't seem to persist new properties added so we will make a local copy
                $exeProperties = New-Object -TypeName 'PSCustomObject'
                $result.PSObject.Properties | Where-Object MemberType -Match 'property$' | Foreach-ObjectFast `
                {
                    if( $_.Name -eq 'VersionInfo' ) ## has been flattened into a string so need to unflatten
                    {
                        [int]$added = 0
                        $versionInfo = New-Object -TypeName 'PSCustomObject'
                        $_.Value -split "`n" | Foreach-ObjectFast `
                        {
                            [string[]]$split = $_ -split ':',2 ## will be : in file names so only split on first
                            if( $split -and $split.Count -eq 2 )
                            {
                                Add-Member -InputObject $versionInfo -MemberType NoteProperty -Name $split[0] -Value ($split[1]).Trim()
                                $added++
                            }
                        }
                        if( $added )
                        {
                            Add-Member -InputObject $exeProperties -MemberType NoteProperty -Name VersionInfo -Value $versionInfo 
                        }
                    }
                    else
                    {
                        Add-Member -InputObject $exeProperties -MemberType NoteProperty -Name $_.Name -Value $_.Value
                    }
                }
            }
        }
        elseif( $started.Value.NewProcessName )
        {
            $exeProperties = Get-ItemProperty -Path $started.Value.NewProcessName -ErrorAction SilentlyContinue
        }
        if( $exeProperties ) 
        {  
            try
            {
                if( $remoteParam.Count )
                {
                    $signature = Invoke-Command @remoteParam -ScriptBlock { Get-AuthenticodeSignature -FilePath $($using:exeProperties).FullName -ErrorAction SilentlyContinue }
                }
                else
                {
                    $signature = Get-AuthenticodeSignature -FilePath $exeProperties.FullName -ErrorAction SilentlyContinue
                }
            }
            catch
            {
                $signature = $null
            }
            if( $remoteParam.Count )
            {
                $owner = Invoke-Command @remoteParam -ScriptBlock {  Get-Acl -Path $($using:started).NewProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Owner }
            }
            else
            {
                $owner = Get-Acl -Path $started.Value.NewProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Owner
            }
            $extraProperties = Add-Member -PassThru -InputObject $exeProperties -Force -NotePropertyMembers @{
                'Vendor' = $(if( $signature -and $signature.SignerCertificate -and ( $signature.SignerCertificate.Subject -cmatch 'CN=(.*),\s*OU=' -or $signature.SignerCertificate.Subject -cmatch 'CN=(.*),\s*O=' ) ) { $Matches[1].Trim( '"' ) })
                'Signed' = $(if( $signature -and $signature.Status.ToString() -eq 'Valid' ) { 'Yes' } else { 'No' })
                'Occurrences' = ([int]1)
                'Owner' = $owner
            }
            $fileProperties.Add( $started.Value.NewProcessName , $extraProperties )
        }
    }
    else
    {
        $exeProperties.Occurrences += 1
    }

    if( $exeProperties )
    {
        $started.Value += @{
            'Exe Signed' = $exeProperties.Signed
            'Exe Created' = $exeProperties.CreationTime
            'Exe Modified' = $exeProperties.LastWriteTime 
            'Exe Company' = $exeProperties.VersionInfo|Select-Object -ExpandProperty CompanyName -ErrorAction SilentlyContinue
            'Exe Vendor' = $exeProperties.Vendor
            'Exe File Owner' = $exeProperties.Owner }

        if( $notSigned -and $exeProperties.PSObject.Properties[ 'Signed' ] -and $exeProperties.Signed -eq 'Yes' )
        {
            $excluded = $true
        }
    }
    $excluded
}

Function Get-AuditSetting
{
    [CmdletBinding()]
    Param
    (
        [string]$GUID
    )
    [string[]]$fields = ( auditpol.exe /get /subcategory:"$GUID" /r | Select-Object -Skip 1 ) -split ',' ## Don't use ConvertFrom-CSV as makes it harder to get the column we want
    if( $fields -and $fields.Count -ge 6 )
    {
        ## Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting
        ## DESKTOP2,System,Process Termination,{0CCE922C-69AE-11D9-BED3-505054503030},No Auditing,
        $fields[5] ## get a blank field at the start
    }
    else
    {
        Write-Warning "Unable to determine audit setting"
    }
}

## http://powershell.one/tricks/performance/pipeline from @TobiasPSP
function Foreach-ObjectFast
{
  param
  (
    [ScriptBlock]
    $Process,
    
    [ScriptBlock]
    $Begin,
    
    [ScriptBlock]
    $End
  )
  
  begin
  {
    # construct a hard-coded anonymous simple function from
    # the submitted scriptblocks:
    $code = @"
& {
  begin
  {
    $Begin
  }
  process
  {
    $Process
  }
  end
  {
    $End
  }
}
"@
    # turn code into a scriptblock and invoke it
    # via a steppable pipeline so we can feed in data
    # as it comes in via the pipeline:
    $pip = [ScriptBlock]::Create($code).GetSteppablePipeline()
    $pip.Begin($true)
  }
  process 
  {
    # forward incoming pipeline data to the custom scriptblock:
    $pip.Process($_)
  }
  end
  {
    $pip.End()
  }
}

[datetime]$startTime = Get-Date

if( $enable -and $disable )
{
    Throw 'Cannot enable and disable in same call'
}

if( $summary -and $noFileInfo )
{
    Throw 'Cannot specify -noFileInfo with -summary'
}

if( $notSigned -and $noFileInfo )
{
    Throw 'Cannot specify -notSigned with -noFileInfo'
}

if( $enable -or $disable )
{
    [hashtable]$requiredAuditEvents = @{
        'Process Creation'    = '0cce922b-69ae-11d9-bed3-505054503030'
        'Process Termination' = '0cce922c-69ae-11d9-bed3-505054503030'
    }

    [string]$state = $(if( $enable ) { 'Enable' } else { 'Disable' })

    [int]$errors = 0

    ForEach( $requiredAuditEvent in $requiredAuditEvents.GetEnumerator() )
    {
        $process = Start-Process -FilePath auditpol.exe -ArgumentList "/set /subcategory:{$($requiredAuditEvent.Value)} /success:$state" -Wait -WindowStyle Hidden -PassThru
        if( ! $process -or $process.ExitCode )
        {
            Write-Error "Error running auditpol.exe to set $($requiredAuditEvent.Name) auditing to $state - error $($process|Select-Object -ExpandProperty ExitCode)"
            $errors++
        }
    }

    if( $enable )
    {
        [void](New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1 -PropertyType 'DWord' -Force)
    }

    Exit $errors
}

if( $PSBoundParameters[ 'last' ] -and ( $PSBoundParameters[ 'start' ] -or $PSBoundParameters[ 'end' ] -or $PSBoundParameters[ 'sinceBoot' ] ) )
{
    Throw "Cannot use -last when -start, -sinceboot or -end are also specified"
}

if( $PSBoundParameters[ 'nostop' ] -and $PSBoundParameters[ 'crashes' ] )
{
    Throw "Cannot use -nostop and -crashes"
}

[hashtable]$startEventFilter = @{
    'Id' = 4688
}

[int]$secondsAgo = 0

if( ! [string]::IsNullOrEmpty( $last ) )
{
    ## see what last character is as will tell us what units to work with
    [int]$multiplier = 0
    switch( $last[-1] )
    {
        "s" { $multiplier = 1 }
        "m" { $multiplier = 60 }
        "h" { $multiplier = 3600 }
        "d" { $multiplier = 86400 }
        "w" { $multiplier = 86400 * 7 }
        "y" { $multiplier = 86400 * 365 }
        default { Throw "Unknown multiplier `"$($last[-1])`"" }
    }
    $endDate = Get-Date
    if( $last.Length -le 1 )
    {
        $secondsAgo = $multiplier
    }
    else
    {
        $secondsAgo = ( ( $last.Substring( 0 , $last.Length - 1 ) -as [decimal] ) * $multiplier )
    }

    $startDate = $endDate.AddSeconds( -$secondsAgo )
    $startEventFilter.Add( 'StartTime' , $startDate )
    ## if using event log file so -last is relative to the latest event in the file so -1h means 0700 if latest event is 0800 but we'll calculate this when we process that computer (which is probably local anyway) and change STartTime
}

$closest = $null
if( $PSBoundParameters[ 'logonOf' ] )
{
    if( $computers -and ( $computers.Count -gt 1 -or ( $computers[0] -ne '.' -and $computers[0] -ne $env:COMPUTERNAME ) ) )
    {
        Throw "Cannot use -logonOf with -computers"
    }

    if( ! ( ([System.Management.Automation.PSTypeName]'Win32.Secure32').Type ) )
    {
        Add-Type -MemberDefinition $LSADefinitions -Name 'Secure32' -Namespace 'Win32' -UsingNamespace System.Text -Debug:$false
    }

    $count = [UInt64]0
    $luidPtr = [IntPtr]::Zero

    [uint64]$ntStatus = [Win32.Secure32]::LsaEnumerateLogonSessions( [ref]$count , [ref]$luidPtr )

    if( $ntStatus )
    {
        Write-Error "LsaEnumerateLogonSessions failed with error $ntStatus"
    }
    elseif( ! $count )
    {
        Write-Error "No sessions returned by LsaEnumerateLogonSessions"
    }
    elseif( $luidPtr -eq [IntPtr]::Zero )
    {
        Write-Error "No buffer returned by LsaEnumerateLogonSessions"
    }
    else
    {   
        Write-Debug "$count sessions retrieved from LSASS"
        [IntPtr]$iter = $luidPtr
        $earliestSession = $null
        [array]$lsaSessions = @( For ([uint64]$i = 0; $i -lt $count; $i++)
        {
            $sessionData = [IntPtr]::Zero
            $ntStatus = [Win32.Secure32]::LsaGetLogonSessionData( $iter , [ref]$sessionData )

            if( ! $ntStatus -and $sessionData -ne [IntPtr]::Zero )
            {
                $data = [System.Runtime.InteropServices.Marshal]::PtrToStructure( $sessionData , [type][Win32.Secure32+SECURITY_LOGON_SESSION_DATA] )

                if ($data.PSiD -ne [IntPtr]::Zero)
                {
                    $sid = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $Data.PSiD

                    #extract some useful information from the session data struct
                    [datetime]$loginTime = [datetime]::FromFileTime( $data.LoginTime )
                    $thisUser = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.Username.buffer) #get the account name
                    $thisDomain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.LoginDomain.buffer) #get the domain name
                    try
                    { 
                        $secType = [Win32.Secure32+SECURITY_LOGON_TYPE]$data.LogonType
                    }
                    catch
                    {
                        $secType = 'Unknown'
                    }

                    if( ! $earliestSession -or $loginTime -lt $earliestSession )
                    {
                        $earliestSession = $loginTime
                    }
                    if( $secType -match 'Interactive' )
                    {
                        $authPackage = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.AuthenticationPackage.buffer) #get the authentication package
                        $session = $data.Session # get the session number
                        $logonServer = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.LogonServer.buffer) #get the logon server
                        $DnsDomainName = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.DnsDomainName.buffer) #get the DNS Domain Name
                        $upn = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($data.upn.buffer) #get the User Principal Name

                        [pscustomobject]@{
                            'Sid' = $sid
                            'Username' = $thisUser
                            'Domain' = $thisDomain
                            'Session' = $session
                            'LoginId' = [uint64]( $loginID = [Int64]("0x{0:x8}{1:x8}" -f $data.LoginID.HighPart , $data.LoginID.LowPart) )
                            'LogonServer' = $logonServer
                            'DnsDomainName' = $DnsDomainName
                            'UPN' = $upn
                            'AuthPackage' = $authPackage
                            'SecurityType' = $secType
                            'Type' = $data.LogonType
                            'LoginTime' = [datetime]$loginTime
                        }
                    }
                }
                [void][Win32.Secure32]::LsaFreeReturnBuffer( $sessionData )
                $sessionData = [IntPtr]::Zero
            }
            $iter = $iter.ToInt64() + [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32.Secure32+LUID])  # move to next pointer
        }) | Sort-Object -Descending -Property 'LoginTime'

        [void]([Win32.Secure32]::LsaFreeReturnBuffer( $luidPtr ))
        $luidPtr = [IntPtr]::Zero

        Write-Verbose "Found $(if( $lsaSessions ) { $lsaSessions.Count } else { 0 }) LSA sessions, earliest session $(if( $earliestSession ) { Get-Date $earliestSession -Format G } else { 'never' })"

        ## Now find the requested session
        if( $PSBoundParameters[ 'logonAround' ] )
        {
            [datetime]$targetLogonTime = Get-Date -Date $logonAround -ErrorAction Stop
        }
        [int]$logonCount = 0

        ForEach( $lsaSession in $lsaSessions )
        {
            if( $lsaSession.Username -eq $logonOf )
            {
                $logonCount++
                if( $PSBoundParameters[ 'logonAround' ] )
                {        
                    if( $closest )
                    {
                        $thisCloseness = [math]::Abs( ( New-TimeSpan -Start $lsaSession.LoginTime -End $targetLogonTime ).TotalSeconds )
                        $otherCloseness = [math]::Abs( ( New-TimeSpan -Start $closest.LoginTime -End $targetLogonTime ).TotalSeconds )
                        if( $thisCloseness -lt $otherCloseness )
                        {
                            $closest = $lsaSession
                        }
                    }
                    elseif( $logonCount -gt $skipLogons )
                    {
                        $closest = $lsaSession
                    }
                }
                elseif( $logonCount -gt $skipLogons ) ## get the last logon for the user
                {
                    $closest = $lsaSession
                    break
                }
            }
        }

        if( $closest )
        {
            Write-Verbose "Using logon for $($closest.Domain)\$($closest.Username) at $(Get-Date -Date $closest.LoginTime -Format G)"
            $startEventFilter.Add( 'StartTime' , $closest.LoginTime.AddSeconds( -$beforeSeconds ) )
            $startEventFilter.Add( 'EndTime' , $closest.LoginTime.AddSeconds( $afterSeconds ) )
        }
        else
        {
            [datetime]$bootTime = Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty LastBootupTime
            Throw "Unable to find a logon for $logonOf in $(if( $lsaSessions ) { $lsaSessions.Count } else { 0 }) LSA sessions, earliest session $(if( $earliestSession ) { Get-Date $earliestSession -Format G } else { 'never' }), boot at $(Get-Date -Date $bootTime -Format G)"
        }
    }
}

if( $PSBoundParameters[ 'start' ] )
{
    $startEventFilter.Add( 'StartTime' , (Get-Date -Date $start ))
}
elseif( $PSBoundParameters[ 'sinceBoot' ] )
{
    if( $lastboot = Get-CimInstance -ClassName Win32_operatingsystem | Select-Object -ExpandProperty LastBootupTime )
    {
        $startEventFilter.Add( 'StartTime' , $lastboot )
    }
    else
    {
        Throw "Unable to get last boot time"
    }
}

if( $PSBoundParameters[ 'duration' ] )
{
    if( $PSBoundParameters[ 'end' ] )
    {
        Throw 'Cannot use both -duration and -end'
    }
    if( ! $startEventFilter[ 'StartTime' ] )
    {
        Throw 'Must specify -start when using -duration'
    }

    [int]$multiplier = 0
    switch( $duration[-1] )
    {
        's' { $multiplier = 1 }
        'm' { $multiplier = 60 }
        'h' { $multiplier = 3600 }
        'd' { $multiplier = 86400 }
        'w' { $multiplier = 86400 * 7 }
        'y' { $multiplier = 86400 * 365 }
        default { Throw "Unknown multiplier `"$($duration[-1])`"" }
    }
    if( $duration.Length -le 1 )
    {
        $secondsDuration = $multiplier
    }
    else
    {
        $secondsDuration = ( ( $duration.Substring( 0 , $duration.Length - 1 ) -as [decimal] ) * $multiplier )
    }
    $startEventFilter.Add( 'EndTime' , ( $startEventFilter[ 'StartTime' ]).AddSeconds( $secondsDuration ))
}
elseif( $PSBoundParameters[ 'end' ] )
{
    $startEventFilter.Add( 'EndTime' , (Get-Date -Date $end ))
}

[bool]$differentUserName = $false

[int]$counter = 0
[int]$index = 0
[hashtable]$fileProperties = @{}
[hashtable]$allSessions = @{}

if( $PSBoundParameters[ 'eventLog' ] )
{
    $startEventFilter.Add( 'Path' , $eventLog )
}
else
{
    $startEventFilter.Add( 'LogName', 'Security' )
}

## If called via scheduled task, arrays aren't passed as arrarys so split back out
if( $processNames -and $processNames.Count -and $processNames[0].IndexOf( ',' ) -ge 0 )
{
    $processNames = $processNames -split ','
}
if( $pids -and $pids.Count -and $pids[0].IndexOf( ',' ) -ge 0 )
{
    [int[]]$pids = [int[]]$pids -split ','
}
else
{
    [int[]]$pids = $pids
}
if( $notProcessNames -and $notProcessNames.Count -and $notProcessNames[0].IndexOf( ',' ) -ge 0 )
{
    $notProcessNames = $notProcessNames -split ','
}
if( $computers -and $computers.Count -and $computers[0].IndexOf( ',' ) -ge 0 )
{
    $computers = $computers -split ','
}
if( $parents -and $parents.Count -and $parents[0].IndexOf( ',' ) -ge 0 )
{
    $parents = $parents -split ','
}
if( $notParents -and $notParents.Count -and $notParents[0].IndexOf( ',' ) -ge 0 )
{
    $notParents = $notParents -split ','
}

[array]$processes = @( ForEach( $computer in $computers )
{
    if( $computer -eq '.' )
    {
        $computer = $env:COMPUTERNAME
    }

    $counter++
    Write-Verbose "Checking $counter / $($computers.Count ) : $computer"
    
    [string]$machineAccount = $computer + '$'

    [hashtable]$remoteParam = @{}
    if( $computer -ne '.' -and $computer -ne $env:COMPUTERNAME )
    {
        $remoteParam.Add( 'ComputerName' , $computer )
    }
    
    [hashtable]$systemAccounts = @{}

    ## if cross referencing to crashes, get that data
    [array]$processCrashes = $null
    if( $PSBoundParameters[ 'crashes' ] )
    {
        [hashtable]$crashParameters = @{ 'Providername' = 'Windows Error Reporting' ; Id = 1001 }
        if( $startEventFilter[ 'StartTime' ] )
        {
            $crashParameters.Add( 'StartTime' , $startEventFilter.StartTime )
        }
        if( $startEventFilter[ 'EndTime' ] )
        {
            $crashParameters.Add( 'EndTime' , $startEventFilter.EndTime )
        }
        $processCrashes = @( Get-WinEvent -FilterHashtable $crashParameters -ErrorAction SilentlyContinue | Where-Object { ! $_.processNames -or ! $_.processNames.Count -or [system.io.path]::GetFileNameWithoutExtension( $_.Properties[5].Value ) -in $processNames } )

        Write-Verbose "Got $($processCrashes.Count) process crashes on $computer"
    }

    ## If using event log file and -last then we need to get the date of the newest event as -last will be relative to that
    if( $PSBoundParameters[ 'last' ] -and $PSBoundParameters[ 'eventLog' ] )
    {
        ## Remove start time from hash table
        $startEventFilter.Remove( 'StartTime' )
        $latestEventHere = Get-WinEvent @remoteParam -FilterHashtable $startEventFilter -ErrorAction SilentlyContinue -MaxEvents 1
        if( $latestEventHere )
        {
            $startEventFilter.Add( 'StartTime' , $latestEventHere.TimeCreated.AddSeconds( - $secondsAgo ) )
        }
    }

    ## Get Oldest event before we filter on date so can report oldest
    Write-Verbose -Message "$(Get-Date -Format G): getting oldest start event"
    $earliestEvent = $null
    $earliestEventHere = Get-WinEvent @remoteParam -FilterHashtable $startEventFilter -Oldest -ErrorAction SilentlyContinue -MaxEvents 1
    if( ! $earliestEvent -or $earliestEventHere -lt $earliestEvent )
    {
        $earliestEvent = $earliestEventHere
    }
    
    if( $earliestEvent )
    {
        Write-Verbose -Message "$(Get-Date -Format G): earliest event is $(Get-Date -Date $earliestEvent.TimeCreated -Format G)"
    }
    else
    {
        Write-Warning -Message "Got no events"
    }

    [hashtable]$logons = @{}
    if( $logonTimes -or $listSessions )
    {
        [array]$loggedOnUsers = @( Get-CimInstance @remoteParam -Classname win32_loggedonuser )
        ## get logons so we can cross reference to the id of the logon
        Get-CimInstance @remoteParam -Classname win32_logonsession -Filter "LogonType='10' or LogonType='12' or LogonType='2' or LogonType='11'" | ForEach-Object `
        {
            $session = $_
            [array]$users = @( $loggedOnUsers.Where( { $_.Dependent -match "`"$($session.LogonId)`"" } ) | . { Process `
            {
                if( $_.Antecedent -match 'Name = "(.*)", Domain = "(.*)"' )
                {
                    [pscustomobject]@{ 'LogonTime' = $session.StartTime ; 'Domain' = $Matches[2] ; 'UserName' = $Matches[1] ; 'Computer' = $computer }
                }
                else
                {
                    Write-Warning "Unexpected antecedent format `"$($_.Antecedent)`""
                }
            }})
            if( $users -and $users.Count )
            {
                $logons.Add( $session.LogonId , $users )
            }
        }
    }

    if( $listSessions )
    {
        $allSessions += $logons
    }
    else
    {
        $eventError = $null
        $error.Clear()
        [int]$multiplePids = 0

        [hashtable]$endEvents = @{}
        if( ! $noStop -and ! $summary )
        {
            [hashtable]$stopEventFilter = $startEventFilter.Clone()
            $stopEventFilter[ 'Id' ] = 4689

            ## if -allTerminations specified, we'll trawl the event log until now to ensure we get the process end event if its there
            if( $allTerminations -and $stopEventFilter.ContainsKey( 'EndTime' ) )
            {
                $stopEventFilter.Remove( 'EndTime' )
            }

            Write-Verbose -Message "$(Get-Date -Format G): getting termination events"

            Get-WinEvent @remoteParam -FilterHashtable $stopEventFilter -Oldest -ErrorAction SilentlyContinue | . { Process `
            {
                $event = $_
                if( ( !$PSBoundParameters[ 'username' ] -or $event.Properties[ $endSubjectUserName ].Value -match $username ) )
                {
                    [bool]$include = $true
                    if( $PSBoundParameters[ 'processNames' ] -and $processNames.Count )
                    {
                        $include = $false
                        ForEach( $processName in $processNames )
                        {
                            if( $event.Properties[ 6 ].Value -match $processName )
                            {
                                $include = $true
                                break
                            }
                        }
                    }
                    if( $pids -and $pids.Count )
                    {
                        $include = $pids -contains $event.Properties[ 5 ].Value 
                    }
                    if( $PSBoundParameters[ 'notProcessNames' ] -and $notProcessNames.Count )
                    {
                        if( ! $processNames -or ! $processNames.Count )
                        {
                            $include = $true
                        }
                        ForEach( $notProcessName in $notProcessNames )
                        {
                            if( $event.Properties[ 6 ].Value -match $notProcessName )
                            {
                                $include = $false
                                break
                            }
                        }
                    }
                    if( $include )
                    {
                        try
                        {
                            $endEvents.Add( $event.Properties[ $endProcessId ].Value -as [int] , $event )
                        }
                        catch
                        {
                            ## already got it so will need to have an array so we can look for the right start time and or user
                            $existing = $endEvents[ [int]$event.Properties[ $endProcessId ].Value ]
                            if( $existing -is [System.Collections.ArrayList] )
                            {
                                [void]($endEvents[ $event.Properties[ $endProcessId ].Value -as [int] ]).Add( $event ) ## appends
                                $multiplePids++
                            }
                            elseif( $existing )
                            {
                                $endEvents[ [int]$event.Properties[ $endProcessId ].Value ] = [System.Collections.ArrayList]@( $existing , $event ) ## oldest first
                            }
                            else
                            {
                                Throw $_
                            }
                        }
                    }
                    else
                    {
                        Write-Verbose "Excluding Pid $($event.Properties[ $endProcessId ].Value) stop event"
                    }
                }
            }}
        }

        Write-Verbose "Got $($endEvents.Count) + $multiplePids end events from $computer"

        [hashtable]$runningProcesses = @{}
        if( $remoteParam.Count )
        {
            $processes = @( Invoke-Command @remoteParam -ScriptBlock { Get-Process -IncludeUserName } )
        }
        else
        {
            $processes = @( Get-Process -IncludeUserName )
        }
    
        $bootTime = $null

        ## Don't cache if saved event log not for this machine 
        if( ( $earliestEventHere -and ( $earliestEventHere.MachineName -eq $computer -or ( $earliestEventHere.MachineName -split '\.' )[0] -eq $computer ) ) )
        {
            ## get the boot time so we can add a column relative to it and also check a process start is after latest boot otherwise LSASS won't have login details for it
            $bootTime = Get-CimInstance @remoteParam -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LastBootupTime
    
            ForEach( $process in $processes )
            {
                if( ! $bootTime -or $process.StartTime -ge $bootTime )
                {
                    $runningProcesses.Add( [int]$process.Id , $process )
                }
            }
        }
        
        Write-Verbose -Message "$(Get-Date -Format G): processing start events"

        ## Find all process starts then we'll look for the corresponding stops
        Get-WinEvent @remoteParam -FilterHashtable $startEventFilter -Oldest -ErrorAction SilentlyContinue -ErrorVariable 'eventError' | . { Process `
        {
            $event = $_
            if( ( ! $username -or $event.Properties[ 1 ].Value -match $username ) -and ( ! $excludeSystem -or ( $event.Properties[ 1 ].Value -ne $machineAccount `
                -and $event.Properties[ 1 ].Value -ne '-' )) -and ( ! $elevated -or $event.Properties[ 6 ].Value -eq '%%1937' ) -and ( ! $pids -or $pids -contains $event.Properties[ 4 ].Value ) )
            {
                [bool]$include = $true
                if( $processNames -and $processNames.Count )
                {
                    $include = $false
                    ForEach( $processName in $processNames )
                    {
                        if( $event.Properties[ 5 ].Value -match $processName )
                        {
                            $include = $true
                            break
                        }
                    }
                }
                <#
                if( $PSBoundParameters[ 'pids' ] -and $pids.Count )
                {
                    $include = $event.Properties[ 6 ].Value -in $pids
                }
                #>
                if( $notProcessNames -and $notProcessNames.Count )
                {
                    if( ! $processNames -or ! $processNames.Count )
                    {
                        $include = $true
                    }
                    ForEach( $notProcessName in $notProcessNames )
                    {
                        if( $event.Properties[ 5 ].Value -match $notProcessName )
                        {
                            $include = $false
                            break
                        }
                    }
                }
                if( $include -and $parents -and $parents.Count )
                {
                    $include = $false
                    ForEach( $parent in $parents )
                    {
                        if( $event.Properties[ 13 ].Value -match $parent )
                        {
                            $include = $true
                        }
                        if( $parent -eq '=notself=' -and $event.Properties[ 13 ].Value -eq $event.Properties[ 5 ].Value )
                        {
                            $include = $false
                            break
                        }
                    }
                }
                if( $include -and $notParents -and $notParents.Count )
                {
                    ForEach( $notParent in $notParents )
                    {
                        if( $event.Properties[ 13 ].Value -match $notparent )
                        {
                            $include = $false
                            break
                        }
                        elseif( $notParent -eq '=self=' -and $event.Properties[ 13 ].Value -eq $event.Properties[ 5 ].Value )
                        {
                            $include = $false
                            break
                        }
                    }
                }
                if( $include )
                {
                    [hashtable]$started = @{ 'Start' = $event.TimeCreated ; 'Computer' = $computer }
                    For( $index = 0 ; $index -lt [math]::Min( $startPropertiesMap.Count , $event.Properties.Count ) ; $index++ )
                    {
                        $started.Add( $startPropertiesMap[ $index ] , $event.Properties[ $index ].value )
                    }
                    if( $started[ 'SubjectUserName' ] -eq '-' )
                    {
                        ## This query has been found to be very slow (45s) on some systems so only call it if we need to use it
                        if( ! $systemAccounts -or ! $systemAccounts.Count )
                        {
                            Get-CimInstance @remoteParam -ClassName win32_SystemAccount | ForEach-Object `
                            {
                                $systemAccounts.Add( $_.SID , $_.Name )
                            }
                        }

                        $started.Set_Item( 'SubjectUserName' , $systemAccounts[ ($event.Properties[ 0 ].Value | Select-Object -ExpandProperty Value) ] )
                        $started.Set_Item( 'SubjectDomainName' , $env:COMPUTERNAME )
                    }

                    ## now find corresponding termination event
                    if( ! $noStop -and ! $summary )
                    {
                        $terminate = $endEvents[ [int]$started.NewProcessId ]
                    }
                    else
                    {
                        $terminate = $null
                    }
                    if( $terminate -is [System.Collections.ArrayList] -and $terminate.Count )
                    {
                        ## need to find the right event as have multiple pids but oldest first so pick the first one after the time we need
                        $thisTerminate = $null
                        $index = 0
                        do
                        {
                            try
                            {
                                if( $terminate[$index].TimeCreated -ge $event.TimeCreated -and $terminate[$index].Properties[6].value -eq $event.Properties[5].value )
                                {
                                    $thisTerminate = $terminate[$index]
                                }
                            }
                            catch
                            {
                                Write-Error $_
                            }
                        } while( ! $thisTerminate -and (++$index) -lt $terminate.Count )

                        if( $thisTerminate )
                        {
                            $terminate.RemoveAt( $index )
                            $terminate = $thisTerminate
                        }
                        else
                        {
                            $terminate = $null
                        }
                    }
                    elseif( $terminate -and ( $terminate.TimeCreated -lt $event.TimeCreated -or $terminate.Properties[6].value -ne $event.Properties[5].value) )## This is not the event you are looking for (because it is prior to the launch)
                    {
                        $terminate = $null
                    }
            
                    [string]$crashed = $null

                    if( $terminate )
                    {
                        if( $processCrashes -and $processCrashes.Count )
                        {
                            # look for crash event within 30 seconds of process exit  m
                            [string]$crashExe = Split-Path -Path $terminate.Properties[6].value -Leaf
                            if( ( $crashEvent = $processCrashes.Where( { $_.TimeCreated -ge $terminate.TimeCreated -and $crashExe -eq $_.Properties[5].Value -and $_.TimeCreated -le $terminate.TimeCreated.AddSeconds( 30 ) } , 1 ) ) -or $terminate.Properties[ $endStatus ].value -match '^0xC' )
                            {
                                $crashed = 'Yes'
                            }
                        }
                        $started += @{
                            'Exit Code' = $terminate.Properties[ $endStatus ].value
                            'End' = $terminate.TimeCreated
                            'Duration' = (New-TimeSpan -Start $event.TimeCreated -End $terminate.TimeCreated | Select-Object -ExpandProperty TotalMilliSeconds) / 1000 
                            'Crashed' = $crashed }
                        ## Tag the terminate event as being used so we can pull out those which aren't later
                        $blah = Add-Member -InputObject $terminate -MemberType NoteProperty -Name StartSeen -Value $started -PassThru
                        if( ! $blah )
                        {
                            $_
                        }
                        if( $started.SubjectUserSid -ne $terminate.Properties[0].Value -and $null -eq $started.PSObject.Properties[ 'User Name Now' ] )
                        {
                            $differentUsername = $true
                            $started.Add( 'User Name Now' , ( "{0}\{1}" -f $terminate.Properties[2].Value , $terminate.Properties[1].Value ))
                        }
                    }

                    if( ! $crashed -and $started.NewProcessName -match '\\werfault\.exe\W\-p\s*(\d+)' )
                    {
                        ## if werfault then find the pid to the -p argument
                    }

                    [bool]$excluded = $false

                    if( ! $noFileInfo )
                    {
                        $excluded = Get-FileInfo -started ([ref]$started)
                    }

                    if( ! $excluded )
                    {
                        if( ! $terminate -and ! $PSBoundParameters[ 'eventLog' ] ) ## probably still running
                        {
                            $existing = $runningProcesses[ [int]$started.NewProcessId ]
                            if( $existing )
                            {
                                ## check user running now is same as launched
                                if( $existing.UserName -and $existing.UserName -ne "$($started.SubjectDomainName)\$($started.SubjectUserName)" )
                                {
                                    $differentUserName = $true
                                    $started.Add( 'User Name Now' , $existing.UserName )
                                }
                            }
                            elseif( ! $noStop -and ! $summary )
                            {
                                Write-Warning "Cannot find process terminated event for pid $($started.NewProcessId) ($($started.NewProcessName)) started at $(Get-Date -Date $started.start -Format G) and not currently running"
                                ## TODO might it be because it crashed and werfault took over?
                            }
                        }

                        ## check on same computer and logon after last boot othwerwise LSASS won't have it
                        $theLogon = $null
                        if( $logonTimes -and  ( $earliestEventHere -and ( $earliestEventHere.MachineName -eq $computer -or ( $earliestEventHere.MachineName -split '\.' )[0] -eq $computer ) ) -and ( ! $bootTime -or $started.Start -ge $bootTime ) )
                        {
                            ## get the logon time so we can add a column relative to it
                            $logonTime = $null
                            $thisLogon = $logons[ $started.SubjectLogonId.ToString() ]

                            if( $thisLogon )
                            {
                                if( $thisLogon -is [array] )
                                {
                                    ## Need to find this user
                                    ForEach( $alogon in $thisLogon )
                                    {
                                        if( $started.SubjectDomainName -eq $alogon.Domain -and $started.SubjectUserName -eq $alogon.Username )
                                        {
                                            if( $theLogon )
                                            {
                                                Write-Warning "Multiple logons for same user $($started.SubjectDomainName)\$($started.SubjectUserName)"
                                            }
                                            $theLogon = $alogon
                                        }
                                    }
                                }
                                elseif( $started.SubjectDomainName -eq $thisLogon.Domain -and $started.SubjectUserName -eq $thisLogon.Username )
                                {
                                    $theLogon -eq $thisLogon
                                }
                                if( ! $theLogon )
                                {
                                    Write-Warning "Couldn't find logon for user $($started.SubjectDomainName)\$($started.SubjectUserName) for process $($started.NewProcessId) started @ $(Get-Date -Date $started.Start -Format G)"
                                }
                                $started.Add( 'Logon Time' , $(if( $theLogon ) { $theLogon.LogonTime } ) )
                                $started.Add( 'After Logon (s)' , $(if( $theLogon ) { New-TimeSpan -Start $theLogon.LogonTime -End $started.Start | Select-Object -ExpandProperty TotalSeconds } ) )
                            }
                        }
                        if( $bootTimes -and $bootTime )
                        {
                            $started.Add( 'After Boot (s)' , $(if( $theLogon ) { New-TimeSpan -Start $bootTime -End $started.Start | Select-Object -ExpandProperty TotalSeconds } ) )
                        }
                        [pscustomobject]$started
                    }
                }
            }
        }}

        ## look at what termination events there were for which we don't have the start event
        ForEach( $endEvent in $endEvents.GetEnumerator() )
        {
            [array]$notSeenStartEvents= @( if( $endEvent.Value.GetType().Name -eq 'ArrayList' )
            {
                $endEvent.Value | Where-Object { ! $_.PSObject.Properties[ 'StartSeen' ] }
            }
            else
            {
                if( $null -eq $endEvent.Value.PSObject.Properties[ 'StartSeen' ] )
                {
                    $endEvent
                }
            })

            if( $notSeenStartEvents -and $notSeenStartEvents.Count )
            {
                ForEach( $notSeenStartEvent in $notSeenStartEvents )
                {
                    if( $notSeenStartEvent.PSObject.Properties[ 'value' ] -and $null -ne $notSeenStartEvent.Value -and $notSeenStartEvent.Value.PSObject.Properties[ 'count' ] -and $notSeenStartEvent.Value.Count )
                    {
                        [bool]$include = $true
                        if( $PSBoundParameters[ 'processNames' ] -and $processNames.Count )
                        {
                            $include = $false
                            ForEach( $processName in $processNames )
                            {
                                if( $notSeenStartEvent.value.Properties[ 6 ].Value -match $processName )
                                {
                                    $include = $true
                                    break
                                }
                            }
                        }
                        if( $pids -and $pids.Count )
                        {
                            $include = $pids -contains $notSeenStartEvent.value.Properties[ 5 ].Value 
                        }
                        if( $PSBoundParameters[ 'notProcessNames' ] -and $notProcessNames.Count )
                        {
                            if( ! $processNames -or ! $processNames.Count )
                            {
                                $include = $true
                            }
                            ForEach( $notProcessName in $notProcessNames )
                            {
                                if( $notSeenStartEvent.value.Properties[ 6 ].Value -match $notProcessName )
                                {
                                    $include = $false
                                    break
                                }
                            }
                        }
                        if( $include )
                        {
                            if( $processCrashes -and $processCrashes.Count )
                            {
                                # look for crash event within 30 seconds of process exit
                                [string]$crashExe = Split-Path -Path $notSeenStartEvent.Value.Properties[6].value -Leaf
                                if( ( $crashEvent = $processCrashes.Where( { $_.TimeCreated -ge $notSeenStartEvent.Value.TimeCreated -and $crashExe -eq $_.Properties[5].Value -and $_.TimeCreated -le $notSeenStartEvent.Value.TimeCreated.AddSeconds( 30 ) } , 1 ) ) -or $terminate.Properties[ $endStatus ].value -match '^0xC' )
                                {
                                    $crashed = 'Yes'
                                }
                            }

                            $differentUserName = $true ## since we don't actually know what it was started as
                            $started = @{ 
                                'Computer' = $computer
                                'NewProcessName' = $notSeenStartEvent.Value.Properties[6].Value
                                'NewProcessId' = $notSeenStartEvent.Name
                                'SubjectLogonId' = $notSeenStartEvent.Value.Properties[3].Value
                                'Exit Code' = $notSeenStartEvent.Value.Properties[4].Value
                                'User Name Now' = ("{0}\{1}" -f $notSeenStartEvent.Value.Properties[2].Value , $notSeenStartEvent.Value.Properties[1].Value )
                                'SubjectUserName' = $notSeenStartEvent.Value.Properties[1].Value
                                'SubjectDomainName' = $notSeenStartEvent.Value.Properties[2].Value
                                'SubjectUserSid' = $notSeenStartEvent.Value.Properties[0].Value
                                'End' = $notSeenStartEvent.Value.TimeCreated
                                'Duration' = $null
                                'Crashed' = $crashed }

                            [bool]$excluded = $false
                            if( ! $noFileInfo )
                            {
                                $excluded = Get-FileInfo -started ([ref]$started )
                            }
                    
                            if( ! $excluded )
                            {
                                [pscustomobject]$started
                            }
                        }
                    }
                }
            }
        }
        if( $eventError )
        {
            $oldestEvent = Get-WinEvent @remoteParam -LogName $startEventFilter[ 'Logname' ] -Oldest -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-Warning "Failed to get any events with ids $($startEventFilter[ 'Id' ] -join ',') from $($startEventFilter[ 'Logname' ]) event log on $computer between $(Get-Date -Date $startEventFilter[ 'StartTime' ] -Format G) and $(Get-Date -Date $startEventFilter[ 'EndTime' ] -Format G), oldest event is $(Get-Date -Date $oldestEvent.TimeCreated -Format G)"

            ## Look to see if there's an error otherwise check if required auditing is enabled
            if( $eventError -and $eventError.Count )
            {
                if( $eventError[0].Exception.Message -match 'No events were found that match the specified selection criteria' )
                {
                    ForEach( $auditGuid in $auditingGuids.GetEnumerator() )
                    {
                        [string]$result = Get-AuditSetting -GUID $auditGuid.Value
                        if( $result -notmatch 'Success' )
                        {
                            Write-Warning "Auditing for $($auditGuid.Name) is `"$result`" so will not generate required events"
                        }
                    }
                }
                Throw $eventError[0]
            }
        }
    }
})

[string]$status = $null
if( $PSBoundParameters[ 'username' ] )
{
    $status += " matching user `"$username`""
}
if( $startEventFilter[ 'StartTime' ] )
{
    $status += " from $(Get-Date -Date $startEventFilter[ 'StartTime' ] -Format G)"
}
if( $startEventFilter[ 'EndTime' ] )
{
    $status += " to $(Get-Date -Date $startEventFilter[ 'EndTime' ] -Format G)"
}
if( $earliestEvent )
{
    $status += " earliest event $(Get-Date $earliestEvent.TimeCreated -Format G)"
}

Write-Verbose "Got $($processes.Count) processes $status in $((New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds) seconds"

if( $listSessions )
{
    if( $allSessions.Count )
    {
        $allSessions.GetEnumerator() | Select-Object -ExpandProperty Value | Sort-Object -Property LogonTime -Descending |Select-Object -Property LogonTime,@{n='Precise Logon Time';e={"$(Get-Date -Date $_.LogonTime -Format d) $((Get-Date -Date $_.LogonTime).ToString('HH:mm:ss.ffffff'))"}},@{n='Username';e={"$($_.Domain)\$($_.Username)"}},Computer
    }
    else
    {
        Write-Warning "No logon sessions found"
    }
}

if( ! $processes.Count )
{
    if( ! $listSessions )
    {
        Write-Warning "No matching process start events found$status"
    }
}
elseif( $summary )
{
    $output = @( $fileProperties.GetEnumerator() | Foreach-ObjectFast `
    {
        $exeFile = $_.Value
        [pscustomobject][ordered]@{
            'Executable' = $exeFile.FullName
            'Executions' = $exeFile.Occurrences
            'Created' = $exeFile.CreationTime
            'Last Modified' = $exeFile.LastWriteTime
            'File Owner' = $exeFile.Owner
            'Size (KB)' = [int]( $exeFile.Length / 1KB )
            'Product Name' = $exeFile.VersionInfo | Select-Object -ExpandProperty ProductName -ErrorAction SilentlyContinue
            'Company Name' = $exeFile.VersionInfo | Select-Object -ExpandProperty CompanyName -ErrorAction SilentlyContinue
            'File Description'  = $exeFile.VersionInfo | Select-Object -ExpandProperty FileDescription -ErrorAction SilentlyContinue
            'File Version' = $exeFile.VersionInfo | Select-Object -ExpandProperty FileVersion -ErrorAction SilentlyContinue
            'Product Version' = $exeFile.VersionInfo | Select-Object -ExpandProperty ProductVersion -ErrorAction SilentlyContinue
            'Vendor' = $exeFile.Vendor
            'Signed' = $exeFile.Signed
        }
    })

    if( $nogridview )
    {
        $output
    }
    else
    {
        [string]$title = "$($output.Count) unique executable process starts $status"
        [array]$selected = @( $output | Out-GridView -PassThru -Title $title )
        if( $selected -and $selected.Count )
        {
            $selected | Set-Clipboard
        }
    }
}
else
{
    $headings = [System.Collections.Generic.List[psobject]]@()
    if( $computers.Count -gt 1 )
    {
        [void]$headings.Add( 'Computer' )
    }
    [void]$headings.Add( @{n='User Name';e={'{0}\{1}' -f $_.SubjectDomainName , $_.SubjectUserName}} )
    if( $differentUserName )
    {
        $headings.Add( 'User Name Now' )
    }
    $headings += @( @{n='Process';e={$_.NewProcessName}} , @{n='PID';e={$_.NewProcessId}} , `
        'CommandLine' , @{n='Parent Process';e={$_.ParentProcessName}} , 'SubjectLogonId' , @{n='Parent PID';e={$_.ProcessId}} , @{n='Elevated';e={$(if( $_.TokenElevationType -eq '%%1937' ) { 'Yes' } else { 'No' } )}} ,`
        @{n='Start';e={('{0}.{1}' -f (Get-Date -Date $_.start -Format G) , $_.start.Millisecond)}} )
    if( ! $nostop )
    {
        $headings += @( @{n='End';e={('{0}.{1}' -f (Get-Date -Date $_.end -Format G) , $_.end.Millisecond)}} , 'Duration' ,  @{n='Exit Code';e={if( $_.'Exit Code' -ne $null ) { '0x{0:x}' -f $_.'Exit Code'}}} )
        if( $crashes )
        {
            $headings += @( 'Crashed' )
        }
    }
    if( ! $noFileInfo )
    {
        $headings += @( 'Exe Created' , 'Exe Modified' , 'Exe File Owner' , 'Exe Signed' , 'Exe Vendor' , 'Exe Company' )
    }
    if( $logonTimes )
    {
        $headings += @( @{n='Logon Time';e={('{0}.{1}' -f (Get-Date -Date $_.'Logon Time' -Format G) , $_.'Logon Time'.Millisecond)}} , 'After Logon (s)' )
    }
    if( $bootTimes -and $bootTime )
    {
        $headings += @( @{n='Boot Time';e={Get-Date -Date $bootTime -Format G}} , 'After Boot (s)' )
    }
    if( $PSBoundParameters[ 'outputfile' ] )
    {
        $processes | Export-Csv -Path $outputFile -NoTypeInformation -NoClobber
    }
    if( $nogridview )
    {
        $processes
    }
    else
    {
        <#
        [void][Reflection.Assembly]::LoadWithPartialName('Presentationframework')

        $mainForm = Load-GUI $mainwindowXAML

        if( ! $mainForm )
        {
            return
        }

        [array]$processes = @( Get-CimInstance -ClassName win32_process -ComputerName $machine | Select-Object Name,ProcessId,@{n='Owner';e={Invoke-WmiMethod -InputObject $_ -Name GetOwner | Select -ExpandProperty user}},ParentProcessId,SessionId,
                                @{n='WorkingSetKB';e={[math]::Round( $_.WorkingSetSize / 1KB)}},@{n='PeakWorkingSetKB';e={$_.PeakWorkingSetSize}},
                                @{n='PageFileUsageKB';e={$_.PageFileUsage}},@{n='PeakPageFileUsageKB';e={$_.PeakPageFileUsage}},
                                @{n='IOReadsMB';e={[math]::Round($_.ReadTransferCount/1MB)}},@{n='IOWritesMB';e={[math]::Round($_.WriteTransferCount/1MB)}},
                                @{n='BasePriority';e={$processPriorities[ [int]$_.Priority ] }},@{n='ProcessorTime';e={[math]::round( ($_.KernelModeTime + $_.UserModeTime) / 10e6 )}},HandleCount,ThreadCount,
                                @{n='StartTime';e={Get-Date $_.CreationDate -Format G}},CommandLine )

        $mainForm.Title =  "$($processes.Count) processes on $machine"
        $WPFProcessList.ItemsSource = $processes
        $WPFProcessList.IsReadOnly = $true
        $WPFProcessList.CanUserSortColumns = $true
        #>

        [string]$title = "$($processes.Count) process starts $status"
        if( $closest )
        {
            $title += " logon of $($closest.Domain)\$($closest.Username) at $(Get-Date -Date $closest.LoginTime -Format d) $((Get-Date -Date $closest.LoginTime).ToString('HH:mm:ss.ffffff'))"
        }
        [array]$selected = @( $processes | Select-Object -Property $headings| Out-GridView -PassThru -Title $title )
        if( $selected -and $selected.Count )
        {
            $selected | Set-Clipboard
        }
    }
}

# SIG # Begin signature block
# MIINRQYJKoZIhvcNAQcCoIINNjCCDTICAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUThH0LsuESX6fs+EMylN85tiF
# /H+gggqHMIIFMDCCBBigAwIBAgIQBAkYG1/Vu2Z1U0O1b5VQCDANBgkqhkiG9w0B
# AQsFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMTMxMDIyMTIwMDAwWhcNMjgxMDIyMTIwMDAwWjByMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQg
# Q29kZSBTaWduaW5nIENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
# +NOzHH8OEa9ndwfTCzFJGc/Q+0WZsTrbRPV/5aid2zLXcep2nQUut4/6kkPApfmJ
# 1DcZ17aq8JyGpdglrA55KDp+6dFn08b7KSfH03sjlOSRI5aQd4L5oYQjZhJUM1B0
# sSgmuyRpwsJS8hRniolF1C2ho+mILCCVrhxKhwjfDPXiTWAYvqrEsq5wMWYzcT6s
# cKKrzn/pfMuSoeU7MRzP6vIK5Fe7SrXpdOYr/mzLfnQ5Ng2Q7+S1TqSp6moKq4Tz
# rGdOtcT3jNEgJSPrCGQ+UpbB8g8S9MWOD8Gi6CxR93O8vYWxYoNzQYIH5DiLanMg
# 0A9kczyen6Yzqf0Z3yWT0QIDAQABo4IBzTCCAckwEgYDVR0TAQH/BAgwBgEB/wIB
# ADAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwMweQYIKwYBBQUH
# AQEEbTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYI
# KwYBBQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFz
# c3VyZWRJRFJvb3RDQS5jcnQwgYEGA1UdHwR6MHgwOqA4oDaGNGh0dHA6Ly9jcmw0
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwOqA4oDaG
# NGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcmwwTwYDVR0gBEgwRjA4BgpghkgBhv1sAAIEMCowKAYIKwYBBQUHAgEWHGh0
# dHBzOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwCgYIYIZIAYb9bAMwHQYDVR0OBBYE
# FFrEuXsqCqOl6nEDwGD5LfZldQ5YMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1Ri6en
# IZ3zbcgPMA0GCSqGSIb3DQEBCwUAA4IBAQA+7A1aJLPzItEVyCx8JSl2qB1dHC06
# GsTvMGHXfgtg/cM9D8Svi/3vKt8gVTew4fbRknUPUbRupY5a4l4kgU4QpO4/cY5j
# DhNLrddfRHnzNhQGivecRk5c/5CxGwcOkRX7uq+1UcKNJK4kxscnKqEpKBo6cSgC
# PC6Ro8AlEeKcFEehemhor5unXCBc2XGxDI+7qPjFEmifz0DLQESlE/DmZAwlCEIy
# sjaKJAL+L3J+HNdJRZboWR3p+nRka7LrZkPas7CM1ekN3fYBIM6ZMWM9CBoYs4Gb
# T8aTEAb8B4H6i9r5gkn3Ym6hU/oSlBiFLpKR6mhsRDKyZqHnGKSaZFHvMIIFTzCC
# BDegAwIBAgIQBP3jqtvdtaueQfTZ1SF1TjANBgkqhkiG9w0BAQsFADByMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQgQ29k
# ZSBTaWduaW5nIENBMB4XDTIwMDcyMDAwMDAwMFoXDTIzMDcyNTEyMDAwMFowgYsx
# CzAJBgNVBAYTAkdCMRIwEAYDVQQHEwlXYWtlZmllbGQxJjAkBgNVBAoTHVNlY3Vy
# ZSBQbGF0Zm9ybSBTb2x1dGlvbnMgTHRkMRgwFgYDVQQLEw9TY3JpcHRpbmdIZWF2
# ZW4xJjAkBgNVBAMTHVNlY3VyZSBQbGF0Zm9ybSBTb2x1dGlvbnMgTHRkMIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr20nXdaAALva07XZykpRlijxfIPk
# TUQFAxQgXTW2G5Jc1YQfIYjIePC6oaD+3Zc2WN2Jrsc7bj5Qe5Nj4QHHHf3jopLy
# g8jXl7Emt1mlyzUrtygoQ1XpBBXnv70dvZibro6dXmK8/M37w5pEAj/69+AYM7IO
# Fz2CrTIrQjvwjELSOkZ2o+z+iqfax9Z1Tv82+yg9iDHnUxZWhaiEXk9BFRv9WYsz
# qTXQTEhv8fmUI2aZX48so4mJhNGu7Vp1TGeCik1G959Qk7sFh3yvRugjY0IIXBXu
# A+LRT00yjkgMe8XoDdaBoIn5y3ZrQ7bCVDjoTrcn/SqfHvhEEMj1a1f0zQIDAQAB
# o4IBxTCCAcEwHwYDVR0jBBgwFoAUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHQYDVR0O
# BBYEFE16ovlqIk5uX2JQy6og0OCPrsnJMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUE
# DDAKBggrBgEFBQcDAzB3BgNVHR8EcDBuMDWgM6Axhi9odHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDA1oDOgMYYvaHR0cDovL2Ny
# bDQuZGlnaWNlcnQuY29tL3NoYTItYXNzdXJlZC1jcy1nMS5jcmwwTAYDVR0gBEUw
# QzA3BglghkgBhv1sAwEwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNl
# cnQuY29tL0NQUzAIBgZngQwBBAEwgYQGCCsGAQUFBwEBBHgwdjAkBggrBgEFBQcw
# AYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tME4GCCsGAQUFBzAChkJodHRwOi8v
# Y2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRTSEEyQXNzdXJlZElEQ29kZVNp
# Z25pbmdDQS5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAQEAU9zO
# 9UpTkPL8DNrcbIaf1w736CgWB5KRQsmp1mhXbGECUCCpOCzlYFCSeiwH9MT0je3W
# aYxWqIpUMvAI8ndFPVDp5RF+IJNifs+YuLBcSv1tilNY+kfa2OS20nFrbFfl9QbR
# 4oacz8sBhhOXrYeUOU4sTHSPQjd3lpyhhZGNd3COvc2csk55JG/h2hR2fK+m4p7z
# sszK+vfqEX9Ab/7gYMgSo65hhFMSWcvtNO325mAxHJYJ1k9XEUTmq828ZmfEeyMq
# K9FlN5ykYJMWp/vK8w4c6WXbYCBXWL43jnPyKT4tpiOjWOI6g18JMdUxCG41Hawp
# hH44QHzE1NPeC+1UjTGCAigwggIkAgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAv
# BgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EC
# EAT946rb3bWrnkH02dUhdU4wCQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAI
# oAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIB
# CzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFDUTmSJ6JN1LUCPUFfg1
# XjJybeH1MA0GCSqGSIb3DQEBAQUABIIBAIKeA3QvI3gpoxsnX7ITcaoux1CVnvO9
# xpbkMiwG2fEZiCYTqLHIaM1r/zQWUo8GgKllJU2h1LICWWSvD5hObNYHBSNuqGcs
# 5UfyDNT9I240EQ16HydU74fzwQxsetpM1zmu8QZQ4Vz+33ceyqXT+AWIBOEXwtBq
# 2hdmGX1awWdZJA69SVLbo6kZdheMjpug1PYjq+tELRGUMpyowp3V8alhDOK6t/1E
# XA6cdQeBaKYX+XQ2uij2cMMd0PKyhL4GOxLR2G3RlbYTSZsOr4lWsQU5lpuxAroe
# /YzycPvdeByVCyR/h5sy8NlaQmEYrXEa4nPux3RG+jdFaPZ/0GzXPvk=
# SIG # End signature block
