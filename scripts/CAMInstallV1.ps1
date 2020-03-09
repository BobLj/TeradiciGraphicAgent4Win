# Copyright (c) 2018 Teradici Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

Configuration InstallPCoIPAgent
{
    param(
        [Parameter(Mandatory=$true)]
        [String] $pcoipAgentInstallerUrl,

        [Parameter(Mandatory=$false)]
        [String] $videoDriverUrl,
    
        [Parameter(Mandatory=$true)]
        [PSCredential] $registrationCodeCredential,

        [Parameter(Mandatory=$false)]
        [String] $sumoCollectorID,

        [Parameter(Mandatory=$false)]
        [PSCredential] $sasTokenAsCred,

        [Parameter(Mandatory=$false)]
        [PSCredential] $domainJoinCredential,

        [Parameter(Mandatory=$false)]
        [string] $domainGroupToJoin,

        [Parameter(Mandatory=$false)]
        [bool]$enableAutoShutdown,

        [Parameter(Mandatory=$false)]
        [int]$autoShutdownIdleTime,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]$CAMDeploymentInfo,

        [Parameter(Mandatory=$false)]
        [bool]$verifyCAMSaaSCertificate=$true
        )
    
    $isSA = [string]::IsNullOrWhiteSpace($videoDriverUrl)

    $regPath = If ($isSA) {
                    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PCoIP Standard Agent"
               }
               Else {
                    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PCoIP Graphics Agent"
               }
    $regPath64 = If ($isSA) {
                    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCoIP Standard Agent"
               }
               Else {
                    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCoIP Graphics Agent"
               }
    $retryCount = 5
    $delay = 60 # seconds
    $orderNumArray = @('1st', '2nd', '3rd', '4th', '5th')

    $agentInstallerDLDirectory = "C:\WindowsAzure\PCoIPAgentInstaller"

    Node "localhost"
    {
        VmUsability TheVmUsability

        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        File Agent_Download_Directory 
        {
            Ensure          = "Present"
            Type            = "Directory"
            DestinationPath = $agentInstallerDLDirectory
        }

        File Nvidia_Download_Directory 
        {
            Ensure          = If ($isSA) {"Absent"} Else {"Present"} 
            Type            = "Directory"
            DestinationPath = "C:\WindowsAzure\NvidiaInstaller"
        }

        File Sumo_Download_Directory 
        {
            Ensure          = "Present"
            Type            = "Directory"
            DestinationPath = "C:\sumo"
        }

        # Aim to install the collector first and start the log collection before any 
        # other applications are installed.
        Script Install_SumoCollector
        {
            DependsOn  = "[File]Sumo_Download_Directory"
            GetScript  = { @{ Result = "Install_SumoCollector" } }

            TestScript = { 
                return (!$using:sumoCollectorID) -or ( (Get-Service sumo-collector -ErrorAction SilentlyContinue) -ne $null )
            }

            SetScript  = {
                Write-Verbose "Install_SumoCollector"

                $installerFileName = "SumoCollector.exe"

                $sasToken = ($using:sasTokenAsCred).GetNetworkCredential().password
                $blobLocation = ($using:sasTokenAsCred).GetNetworkCredential().username

                $dest = "C:\sumo"
                $sumo_package = 'https://collectors.sumologic.com/rest/download/win64'
                $sourceArray = @()
                $destArray = @()
                $sourceArray += $sumo_package
                $destArray += "$dest\$installerFileName"
                $sourceArray += "$blobLocation/sumo.conf${sasToken}"
                $destArray += "$dest\sumo.conf"
                $sourceArray += "$blobLocation/sumo-agent-vm.json${sasToken}"
                $destArray += "$dest\sumo-agent-vm.json"

                $orderNumArray = $using:orderNumArray
                $retryMax = $using:retryCount
                $downIdx = 0;

                # sumologic server require TLS 1.2
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                foreach ($source in $sourceArray) {
                    $destFile = $destArray[$downIdx]

                    for ($idx = 0; $idx -lt $retryMax; $idx++) {
                        Write-Verbose ('It is the {0} try downloading file from {1} ...' -f $orderNumArray[$idx], $source)
                        Try{
                            Invoke-WebRequest $source -OutFile $destFile -UseBasicParsing -PassThru  -ErrorAction Stop
                            break
                        }Catch{
                            $errMsg = "Attempt {0} of {1} to download file from {2} failed. Error Infomation: {3} " -f ($idx + 1), $retryMax, $source, $_.Exception.Message 
                            Write-Verbose $errMsg
                            if ($idx -ne ($retryMax - 1)) {
                                Start-Sleep -s $using:delay
                            } else {
                                $errMsg = "Failed to install sumo collector because file {0} could not be downloaded" -f $source
                                Write-Verbose $errMsg
                                return                                 
                            }
                        }
                    }

                    $downIdx += 1
                }

                #
                #Insert unique ID
                $collectorID = "$using:sumoCollectorID"
                (Get-Content -Path "$dest\sumo.conf").Replace("collectorID", $collectorID) | Set-Content -Path "$dest\sumo.conf"
                
                #install the collector
                $command = "$dest\$installerFileName -console -q"
                Invoke-Expression $command

                # Wait for collector to be installed before exiting this configuration.
                $retryCount = 1800
                while ($retryCount -gt 0)
                {
                    try
                    {
                        Get-Service sumo-collector -ErrorAction Stop
                        break
                    }
                    catch
                    {
                        Start-Sleep -s 1;
                        $retryCount = $retryCount - 1;
                        if ( $retryCount -eq 0)
                        {
                            throw "Sumo collector not installed in time."
                        }
                        else
                        {
                            Write-Host "Waiting for Sumo collector to be installed"
                        }
                    }
                }
            }
        }

        Script InstallVideoDriver
        {
            DependsOn  = "[File]Nvidia_Download_Directory"

            GetScript  = { @{ Result = "Install_Video_Driver" } }

            TestScript = {
                $isSA = $using:isSA

                if ($isSA -or (Test-Path -path "HKLM:\SOFTWARE\NVIDIA Corporation\Installer2\Drivers")) {
                    return $true
                }else {
                    return $false
                } 
            }

            SetScript  = {
                Write-Verbose "Downloading Nvidia driver"
                $videoDriverUrl = $using:videoDriverUrl
                $installerFileName = [System.IO.Path]::GetFileName($videoDriverUrl)
                $destFile = "c:\WindowsAzure\NvidiaInstaller\" + $installerFileName

                $orderNumArray = $using:orderNumArray
                $retryCount = $using:retryCount

                for ($idx = 1; $idx -le $retryCount; $idx++) {
                    Write-Verbose ('It is the {0} try downloading video driver from {1} ...' -f $orderNumArray[$idx -1], $videoDriverUrl)
                    Try{
                        Invoke-WebRequest $videoDriverUrl -OutFile $destFile -UseBasicParsing -PassThru  -ErrorAction Stop
                        break
                    }Catch{
                        $errMsg = "Attempt {0} of {1} to download video driver failed. Error Infomation: {2} " -f $idx, $retryCount, $_.Exception.Message 
                        Write-Verbose $errMsg
                        if ($idx -ne $retryCount) {
                            Start-Sleep -s $using:delay
                        } else {
                            throw $errMsg
                        }
                    }
                }

                for ($idx = 1; $idx -le $retryCount; $idx++) {
                    Write-Verbose ('It is the {0} try installing Nvidia driver...' -f $orderNumArray[$idx -1])

                    $ret = Start-Process -FilePath $destFile -ArgumentList "/s /noeula /noreboot" -PassThru -Wait
                    
                    # treat exit code 0 or 1 as success
                    if (($ret.ExitCode -eq 0) -or ($ret.ExitCode -eq 1)) {
                        Write-Verbose "Request reboot machine after Installing Video Driver."
                        # Setting the global:DSCMachineStatus = 1 tells DSC that a reboot is required
                        $global:DSCMachineStatus = 1
                        Write-Verbose "Finished Nvidia driver Installation"
                        break
                    } else {
                        $errMsg = "Attempt {0} of {1} to install nvidia driver failed. Exit Code: {2} ." -f  $idx, $retryCount,  $ret.ExitCode
                        Write-Verbose $errMsg
                        if ($idx -ne $retryCount) {
                            Start-Sleep -s $using:delay
                        } else {
                            throw $errMsg
                        }
                    }
                }
            }
        }

        Script Install_PCoIPAgent
        {
            DependsOn  = @("[File]Agent_Download_Directory","[Script]InstallVideoDriver")
            GetScript  = { @{ Result = "Install_PCoIPAgent" } }

            #TODO: Check for other agent types as well?
            TestScript = {
                $regPath = $using:regPath
                $regPath64 = $using:regPath64

                if ( (Test-Path -path $regPath) -or (Test-Path -path $regPath64) )  {
                    return $true
                }else {
                    return $false
                } 
            }

            SetScript  = {
                Write-Verbose "Starting to Install PCoIPAgent"

                #agent installer exit code 1641 require reboot machine
                Set-Variable EXIT_CODE_REBOOT 1641 -Option Constant

                $pcoipAgentInstallerUrl = $using:pcoipAgentInstallerUrl
                if (! $pcoipAgentInstallerUrl.EndsWith('/') ) {
                     $pcoipAgentInstallerUrl =  $pcoipAgentInstallerUrl + '/';
                }

                # Downloading PCoIP Agent requires TLS 1.2
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                # download meta file first
                $metaFileName = "latest-standard-agent.json"
                if (! $using:isSA) {
                    $metaFileName = "latest-graphics-agent.json"
                }

                $downloadUrl =  $pcoipAgentInstallerUrl + $metaFileName
                
                $destFile = Join-Path -Path $using:agentInstallerDLDirectory -ChildPath $metaFileName

                $orderNumArray = $using:orderNumArray
                $retryCount = $using:retryCount

                for ($idx = 1; $idx -le $retryCount; $idx++) {
                    Write-Verbose ('It is the {0} try downloading {1} from {2} ...' -f $orderNumArray[$idx -1], $metaFileName, $pcoipAgentInstallerUrl)
                    Try{
                        Invoke-WebRequest $downloadUrl -OutFile $destFile -UseBasicParsing -PassThru -ErrorAction Stop
                        break
                    } Catch {
                        $errMsg = "Attempt {0} of {1} to download {2} failed. Error Infomation: {3} " -f $idx, $retryCount, $metaFileName, $_.Exception.Message 
                        Write-Verbose $errMsg
                        if ($idx -ne $retryCount) {
                            Start-Sleep -s $using:delay
                        } else {
                            throw $errMsg
                        }
                    }
                }

                # parsing meta file
                $meta=(Get-Content -Raw -Path  $destFile | ConvertFrom-Json)
                $installerFileName =$meta.filename

                # download installer
                $downloadUrl =  $pcoipAgentInstallerUrl + $installerFileName
                
                $destFile = Join-Path -Path $using:agentInstallerDLDirectory -ChildPath $installerFileName

                for ($idx = 1; $idx -le $retryCount; $idx++) {
                    Write-Verbose ('It is the {0} try downloading {1} from {2} ...' -f $orderNumArray[$idx -1], $installerFileName, $pcoipAgentInstallerUrl)
                    Try{
                        Invoke-WebRequest $downloadUrl -OutFile $destFile -UseBasicParsing -PassThru -ErrorAction Stop
                        break
                    } Catch {
                        $errMsg = "Attempt {0} of {1} to download {2} failed. Error Infomation: {3} " -f $idx, $retryCount, $installerFileName, $_.Exception.Message 
                        Write-Verbose $errMsg
                        if ($idx -ne $retryCount) {
                            Start-Sleep -s $using:delay
                        } else {
                            throw $errMsg
                        }
                    }
                }

                #install the agent
                for ($idx = 1; $idx -le $retryCount; $idx++) {
                    Write-Verbose ('It is the {0} try intalling PCoIP Agent...' -f $orderNumArray[$idx -1])

                    $ret = Start-Process -FilePath $destFile -ArgumentList "/S /nopostreboot" -PassThru -Wait

                    if (($ret.ExitCode -eq 0) -or ($ret.ExitCode -eq $EXIT_CODE_REBOOT)) {
                        if ($ret.ExitCode -eq $EXIT_CODE_REBOOT) {
                            Write-Verbose "Request reboot machine after Installing pcoip agent."
                            # Setting the global:DSCMachineStatus = 1 tells DSC that a reboot is required
                            $global:DSCMachineStatus = 1
                        }
                        Write-Verbose "Finished PCoIP Agent Installation"
                        break
                    } else {
                        $errMsg = "Attempt {0} of {1} to install PCoIP Agent failed. Exit Code: {2}." -f $idx, $retryCount, $ret.ExitCode
                        Write-Verbose $errMsg
                        if ($idx -ne $retryCount) {
                            Start-Sleep -s $using:delay
                        } else {
                            throw $errMsg
                        }
                    }
                }
            }
        }

        Script Register
        {
            DependsOn  = @("[Script]Install_PCoIPAgent")

            GetScript  = { return 'registration'}
            
            TestScript = { 
                $path = "C:\Program Files (x86)\Teradici\PCoIP Agent"
                if (!(Test-Path -path $path))  {
                    $path = "C:\Program Files\Teradici\PCoIP Agent"
                }

                cd $path
                $ret = & .\pcoip-validate-license.ps1

                # the powershell variable $? to indicate the last executing command status
                return $?
            }

            SetScript  = {
                #register code is stored at the password property of PSCredential object
                $registrationCode = ($using:registrationCodeCredential).GetNetworkCredential().password
                if ($registrationCode) {
                    # Insert a delay before registering
                    $path = "C:\Program Files (x86)\Teradici\PCoIP Agent"
                    if (!(Test-Path -path $path))  {
                        $path = "C:\Program Files\Teradici\PCoIP Agent"
                    }
                    cd $path

                    $retryCount = $using:retryCount
                    $orderNumArray = $using:orderNumArray

                    for ($idx = 1; $idx -le $retryCount; $idx++) {
                        Write-Verbose ('It is the {0} try registering the registration code.' -f $orderNumArray[$idx -1])
                        $ret = & .\pcoip-register-host.ps1 -RegistrationCode $registrationCode
                        $isExeSucc = $?
                        
                        if ($isExeSucc) {
                            #only do validation when command pcoip-register-host.ps1 passed
                            Write-Verbose ('It is the {0} try validating the registration code.' -f $orderNumArray[$idx -1])
                             $ret = & .\pcoip-validate-license.ps1
                            $isExeSucc = $?
                        }

                        if ($isExeSucc) {
                            Write-Verbose "Succeeded to register the registration code." 
                            break
                        } else {
                            $retMsg = $ret | Out-String
                            $errMsg = "Attempt {0} of {1} to register the registration code failed. Error Message: {2} " -f $idx, $retryCount, $retMsg
                            Write-Verbose  $errMsg     

                            if ($idx -ne $retryCount) {
                                Start-Sleep -s $using:delay
                            } else {
                                throw $errMsg
                            }
                        }
                    }
                }
            }
        }

        Script StartPcoIPService
        {
            DependsOn  = @("[Script]Register")

            GetScript  = { return 'Start PcoIP Service'}

            TestScript = { 
                $serviceName = "PCoIPAgent"

                $svc = Get-Service -Name $serviceName   
            
                return $svc.Status -eq "Running"
            }

            SetScript  = {
                $serviceName = "PCoIPAgent"
                $svc = Get-Service -Name $serviceName   

                if ($svc.StartType -ne "Automatic") {
                    $msg = "try setting {0} Service start type to automatic." -f $serviceName
                    Write-Verbose $msg

                    Set-Service -name  $serviceName -StartupType Automatic

                    $status = If ($?) {"succeeded"} Else {"failed"}
                    $msg = "{0} to change start type of {1} service to Automatic." -f $status, $serviceName
                    Write-Verbose $msg
                }
                    
                if ($svc.status -eq "Paused") {
                    Write-Verbose "try resuming PCoIPAgent Service ."
                    try{
                        $svc.Continue()
                        Write-Verbose "succeeded to resume PCoIPAgent service."
                    }catch{
                        throw "failed to resume PCoIP Agent Service."
                    }
                }

                if ( $svc.status -eq "Stopped" )    {
                    Write-Verbose "Starting PCoIP Agent Service ..."
                    try{
                        $svc.Start()
                        $svc.WaitForStatus("Running", 120)
                    }catch{
                        throw "failed to start PCoIP Agent Service"
                    }
                }
            }
        }

        Script StartCAMIdleShutdownService
        {
            DependsOn  = @("[Script]StartPcoIPService")

            GetScript  = { return 'Start CAM Idle Shutdown Service'}

            TestScript = { 
                $serviceName = "CAMIdleShutdown"

                try {
                    $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
                    return $svc.State -eq "Running"
                } catch {
                    return $false
                }
            }

            SetScript  = {
            	$is64 = $false
                $path = "C:\Program Files (x86)\Teradici\PCoIP Agent\bin"
                if (!(Test-Path -path $path))  {
                    $path = "C:\Program Files\Teradici\PCoIP Agent\bin"
                    $is64 = $true
                }

                cd $path

                $serviceName = "CAMIdleShutdown"

                $ret = .\IdleShutdownAgent.exe -install
                # Check for success
                if( !$? ) {
                    $msg = "Failed to install {0} because: {1}" -f $serviceName, $ret
                    Write-Verbose $msg
                    throw $msg
                }

                $idleTimerRegKeyPath = "HKLM:SOFTWARE\WOW6432Node\Teradici\CAMShutdownIdleMachineAgent"
                if ($is64) {
	                $idleTimerRegKeyPath = "HKLM:SOFTWARE\Teradici\CAMShutdownIdleMachineAgent"
                }
                
                $idleTimerRegKeyName = "MinutesIdleBeforeShutdown"
                $idleTimerRegKeyValue = $using:autoShutdownIdleTime

                if (!(Test-Path $idleTimerRegKeyPath)) {
                    New-Item -Path $idleTimerRegKeyPath -Force
                }
                New-ItemProperty -Path $idleTimerRegKeyPath -Name $idleTimerRegKeyName -Value $idleTimerRegKeyValue -PropertyType DWORD -Force

                $svc = Get-Service -Name $serviceName

                if (!$using:enableAutoShutdown) {
                    $msg = "attempting to disable {0} service" -f $serviceName
                    Write-Verbose $msg

                    try {
                        if ($svc.Status -ne "Stopped") {
                            Start-Sleep -s 15
                            $svc.Stop()
                            $svc.WaitForStatus("Stopped", 180)
                        }
                        Set-Service -InputObject $svc -StartupType "Disabled"
                        $status = if ($?) { "succeeded" } else { "failed" }
                        $msg = "disable {0} service {1}" -f $svc.ServiceName, $status
                        Write-Verbose $msg
                    }
                    catch {
                        throw "failed to disable CAMIdleShutdown service."
                    }
                    return $true
                }

                if ($svc.StartType -ne "Automatic") {
                    $msg = "try setting {0} Service start type to automatic." -f $serviceName
                    Write-Verbose $msg

                    Set-Service -name  $serviceName -StartupType Automatic

                    $status = If ($?) {"succeeded"} Else {"failed"}
                    $msg = "{0} to change start type of {1} service to Automatic." -f $status, $serviceName
                    Write-Verbose $msg
                }

                if ($svc.status -eq "Paused") {
                    Write-Verbose "try resuming CAMIdleShutdown Service ."
                    try{
                        $svc.Continue()
                        Write-Verbose "succeeded to resume CAMIdleShutdown service."
                    }catch{
                        throw "failed to resume CAMIdleShutdown Service."
                    }
                }

                if ( $svc.status -eq "Stopped" )    {
                    Write-Verbose "Starting CAMIdleShutdown Service ..."
                    try{
                        $svc.Start()
                        $svc.WaitForStatus("Running", 120)
                    }catch{
                        throw "failed to start CAMIdleShutdown Service"
                    }
                }
            }
        }


        Script JoinDomainGroup
        {
            DependsOn  = @("[File]Agent_Download_Directory")

            GetScript  = { return 'Join a Domain Group'}

            TestScript = { 
                if( -not $using:domainGroupToJoin )
                {
                    Write-Host "No Domain group to join."
                    return $true
                }
                Test-Path "$using:agentInstallerDLDirectory\domainGroupJoinFile.txt"
            }

            SetScript  = {
                #TODO: Handle OU's and GroupScope like in this article: https://gallery.technet.microsoft.com/scriptcenter/PowerShell-Bulk-AD-Group-4d873f35

                $domainGroupToJoin = $using:domainGroupToJoin
                $machineToJoin = $env:computername

                if( -not ((Get-WmiObject win32_computersystem).partofdomain))
                {
                    Write-Host "$machineToJoin is not part of a domain so is not joining domain group $domainGroupToJoin."
                }
                else
                {
                    try{
                        $domain = (Get-WmiObject win32_computersystem).domain
                        $domainInfo = (Get-WMIObject Win32_NTDomain) | Where-Object {$_.DnsForestName -eq $domain} | Select-Object -First 1
                        $dcname = ($domainInfo.DomainControllerName -replace "\\", "")

                        Write-Host "Connecting to DC to add $machineToJoin to $domainGroupToJoin."
                    
                        # Create a PSSession with the domain controller that we used to login
                        $psSession = New-PSSession -ComputerName $dcname -Credential $using:domainJoinCredential -ErrorAction Stop

                        $invokeResult = Invoke-Command -Session $psSession -ArgumentList $domainGroupToJoin, $machineToJoin  -ErrorAction Stop  `
                        -ScriptBlock {
                            $domainGroupToJoin = $args[0]
                            $machineToJoin = $args[1]

                            # Make the AD group for machines if needed
                            try
                            {
                                $group = Get-ADGroup -Filter {SamAccountName -eq $domainGroupToJoin} -ErrorAction Stop
                                if ($group -eq $null) {
                                    Write-Host "Domain Group `"$domainGroupToJoin`" not found. Creating."

                                    New-ADGroup -name $domainGroupToJoin -GroupScope Global -ErrorAction Stop
                                }

                                # Add-ADGroupMember uses the SAM account name for the computer which has a trailing '$'
                                Add-ADGroupMember -Identity $domainGroupToJoin -Members ($machineToJoin + "$") -ErrorAction Stop

                                return $null
                            }
                            catch
                            {
                                return $_
                            }
                        }

                        if ($invokeResult -ne $null) {
                            throw $invokeResult
                        }
                    }catch{
                        $exception = $_

                        Write-Host "Failed to add $machineToJoin to $domainGroupToJoin because of $exception."
                    }finally{
                        if ($psSession -ne $null) {
                            Remove-PSSession $psSession
                        }
                    }
                }
                    
                #make placeholder file so this is only run once
                New-Item "$using:agentInstallerDLDirectory\domainGroupJoinFile.txt" -type file

                if ($exception -ne $null) {
                    $exception > "$using:agentInstallerDLDirectory\domainGroupJoinFile.txt"
                }
            }
        }

        Script RegisterUserEntitlement
        {
            DependsOn  = @("[File]Agent_Download_Directory")

            GetScript  = { return 'RegisterUserEntitlement'}

            TestScript = { 
                if( -not $using:CAMDeploymentInfo ) {
                    Write-Host "No CAM info to register user to remote workstation."
                    return $true
                } else {
                    $CAMDeploymentInfoCred = $using:CAMDeploymentInfo;
                    $CAMDeploymentInfo = $CAMDeploymentInfoCred.GetNetworkCredential().Password
                    if( (-not $CAMDeploymentInfo) -or ($CAMDeploymentInfo -eq "null")) {
                        Write-Host "No CAM info to register user to remote workstation."
                        return $true
                    }
                }
                # Otherwise check marker file if complete
                Test-Path "$using:agentInstallerDLDirectory\RegisterUserEntitlementFile.txt"
            }

            SetScript  = {
                $machineToJoin = $env:computername

                if( -not ((Get-WmiObject win32_computersystem).partofdomain))
                {
                    throw "$machineToJoin is not part of a domain."
                }

                $domain = (Get-WmiObject win32_computersystem).domain
                $domainInfo = (Get-WMIObject Win32_NTDomain) | Where-Object {$_.DnsForestName -eq $domain} | Select-Object -First 1
                $dcname = ($domainInfo.DomainControllerName -replace "\\", "")

                #create a PSSession with the domain controller that we used to login
                $psSession = New-PSSession -ComputerName $dcname -Credential $using:domainJoinCredential

                # Get User Guid for Domain User
                # TODO: Can we just do this on Localhost?
                $userGuid = Invoke-Command -Session $psSession -ScriptBlock {
                    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
                    [System.DirectoryServices.AccountManagement.UserPrincipal]::Current.Guid.Guid
                }
                Remove-PSSession $psSession

                # get the CAM cred's and info we need.
                Add-Type -AssemblyName System.Web
                $CAMDeploymentInfoCred = $using:CAMDeploymentInfo;
                $CAMDeploymentInfo = $CAMDeploymentInfoCred.GetNetworkCredential().Password
                $CAMDeploymenInfoJSONDecoded = [System.Web.HttpUtility]::UrlDecode($CAMDeploymentInfo)
                $CAMDeploymenInfoDecoded = ConvertFrom-Json $CAMDeploymenInfoJSONDecoded
                $regInfo = $camDeploymenInfoDecoded.RegistrationInfo
                
                $camSaasBaseUri = $regInfo.CAM_URI
                $camSaasBaseUri = $camSaasBaseUri.Trim().TrimEnd('/')

                $camRegistrationError = ""
                for($idx = 0; $idx -lt $using:retryCount; $idx++) {
                    try {
                        $userRequest = @{
                            username = $regInfo.CAM_USERNAME
                            password = $regInfo.CAM_PASSWORD
                            tenantId = $regInfo.CAM_TENANTID
                        }
                        $certificatePolicy = [System.Net.ServicePointManager]::CertificatePolicy
                        
                        if (!$using:verifyCAMSaaSCertificate) {
                            # Do this so SSL Errors are ignored
                            Write-Host "Warning - Ignoring SSL errors!"
                            add-type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
                        
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                        }
                        # CAM requires TLS 1.2
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        
                        # Get a Sign-in token
                        $signInResult = ""
                        try {
                            $signInResult = Invoke-RestMethod -Method Post -Uri ($camSaasBaseUri + "/api/v1/auth/signin") -Body $userRequest
                        } catch {
                            if ($_.ErrorDetails.Message) {
                                $signInResult = ConvertFrom-Json $_.ErrorDetails.Message
                            } else {
                                throw $_
                            }
                        }
                        Write-Verbose ((ConvertTo-Json $signInResult) -replace "\.*token.*", 'Token": "Sanitized"')
                        # Check if signIn succeded
                        if ($signInResult.code -ne 200) {
                            throw ("Signing in failed. Result was: " + (ConvertTo-Json $signInResult))
                        }
                        $tokenHeader = @{
                            authorization=$signInResult.data.token
                        }
                        Write-Host "Cloud Access Manager sign in succeeded"

                        # Register Remote Workstation
                        $machineRequest = @{
                            deploymentId = $regInfo.CAM_DEPLOYMENTID
                            resourceGroup = $regInfo.CAM_RESOURCEGROUP
                            machineName = $machineToJoin
                            subscriptionId = $regInfo.CAM_SUBSCRIPTIONID
                        }
                        $registerMachineResult = ""
                        try {
                            $registerMachineResult = Invoke-RestMethod -Method Post -Uri ($camSaasBaseUri + "/api/v1/machines") -Body $machineRequest -Headers $tokenHeader
                        } catch {
                            if ($_.ErrorDetails.Message) {
                                $registerMachineResult = ConvertFrom-Json $_.ErrorDetails.Message
                            } else {
                                throw $_
                            }
                        }
                        Write-Verbose (ConvertTo-Json $registerMachineResult)
                        # Check if registration succeeded
                        if( !(($registerMachineResult.code -eq 201) -or ($registerMachineResult.data.reason.ToLower().Contains("exists")))) {
                            throw ("Registering Machine failed. Result was: " + (ConvertTo-Json $registerMachineResult))
                        }
                        $machineId = ""
                        # Get the machineId
                        if( ($registerMachineResult.code -eq 409) -and ($registerMachineResult.data.reason.ToLower().Contains("already exist")) ) {
                            # Deployment is already registered so the deplymentId needs to be retrieved
                            $registeredMachine = ""
                            try {
                                $registeredMachine = Invoke-RestMethod `
                                    -Method Get `
                                    -Uri ($camSaasBaseUri + "/api/v1/machines") `
                                    -Body $machineRequest `
                                    -Headers $tokenHeader
                                $machineId = $registeredMachine.data.machineId
                            } catch {
                                if ($_.ErrorDetails.Message) {
                                    $registeredMachine = ConvertFrom-Json $_.ErrorDetails.Message
                                    throw ("Getting Deployment ID failed. Result was: " + (ConvertTo-Json $registeredMachine))
                                } else {
                                    throw $_
                                }                                
                            }
                        } else {
                            $machineId = $registerMachineResult.data.machineId
                        }
                        Write-Host "Remote Workstation $machineToJoin has been registered successfully with Cloud Access Manager"
                        
                        # Register User Entitlement to Machine

                        $entitlementRequest = @{
                            machineId = $machineId
                            deploymentId = $regInfo.CAM_DEPLOYMENTID
                            userGuid = $userGuid
                        }
                        $registerEntitlementResult = ""
                        try {
                            $registerEntitlementResult = Invoke-RestMethod -Method Post -Uri ($camSaasBaseUri + "/api/v1/machines/entitlements") -Body $entitlementRequest -Headers $tokenHeader
                        } catch {
                            if ($_.ErrorDetails.Message) {
                                $registerEntitlementResult = ConvertFrom-Json $_.ErrorDetails.Message
                            } else {
                                throw $_
                            }
                        }
                        Write-Verbose (ConvertTo-Json $registerEntitlementResult)
                        # Check if entitlement succeeded
                        if( !(($registerEntitlementResult.code -eq 201) -or ($registerEntitlementResult.data.reason.ToLower().Contains("exists")))) {
                            throw ("Registering User Entitlement failed. Result was: " + (ConvertTo-Json $registerEntitlementResult))
                        }
                        Write-Host "User Entitlement has been registered succesfully with Cloud Access Manager"

                        $camRegistrationError = ""
                        break;
                    } catch {
                        $camRegistrationError = $_
                        Write-Verbose ( "Attempt {0} of $using:retryCount failed due to Error: {1}" -f ($idx+1), $camRegistrationError )
                        Start-Sleep -s $using:delay
                    } finally {
                        # restore CertificatePolicy 
                        [System.Net.ServicePointManager]::CertificatePolicy = $certificatePolicy
                    }
                }

                if($camRegistrationError) {
                    throw $camRegistrationError
                }

                #make placeholder file so this is only run once
                New-Item "$using:agentInstallerDLDirectory\RegisterUserEntitlementFile.txt" -type file
            }
        }
    }
}



Configuration VmUsability
{
    Node "localhost"
    {
        DisableServerManager TheDisableServerManager
        InstallFirefox TheInstallFirefox
        AudioService TheAudioService
    }
}

Configuration DisableServerManager
{
    Node "localhost"
    {
        Registry DisableServerManager
        {
            Ensure = "Present"
            Key = "HKLM:\Software\Microsoft\ServerManager"
            ValueName = "DoNotOpenServerManagerAtLogon"
            ValueData = "1"
            ValueType = "Dword"
        }
    }
}

Configuration InstallFirefox
{
    param
    (
        [string]$VersionNumber = "latest",
        [string]$Language = "en-US",
        [string]$OS = "win",
        [string]$MachineBits = "x86",
        [string]$LocalPath = "$env:SystemDrive\Windows\DtlDownloads\Firefox Setup " + $versionNumber +".exe"
    )
    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    xRemoteFile Downloader
    {
        Uri = "http://download.mozilla.org/?product=firefox-" + $VersionNumber +"&os="+$OS+"&lang=" + $Language 
        DestinationPath = $LocalPath
    }
     
    Script Install_Firefox
    {
        DependsOn = "[xRemoteFile]Downloader"
        GetScript  = { @{ Result = "Install_Firefox" } }

        TestScript = {
            $regPath = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Mozilla Firefox*"

            if ( Test-Path -path $regPath)  {
                return $true
            } else {
                return $false
            } 
        }

        SetScript  = {
            Write-Verbose "Will install firefox"
            $destFile = $using:LocalPath

            $retryCount = 3
            $delay = 10
            $orderNumArray = @('1st', '2nd', '3rd')

            for ($idx = 1; $idx -le $retryCount; $idx++) {
                Write-Verbose ('It is the {0} try installing firefox ...' -f $orderNumArray[$idx -1])

                $ret = Start-Process -FilePath $destFile -ArgumentList "/SilentMode" -PassThru -Wait

                if ($ret.ExitCode -eq 0) {
                    Write-Verbose "Finished firefox Installation."
                    break
                } else {
                    $errMsg = "Attempt {0} of {1} to install firefox failed. Exit Code: {2}" -f $idx, $retryCount, $ret.ExitCode
                    Write-Verbose $errMsg
                    if ($idx -ne $retryCount) {
                        Start-Sleep -s $delay
                    }
                }
            }
        }
    }
}

Configuration AudioService
{
    Node "localhost"
    {
        $serviceName = "Audiosrv"

        Script SetAudioServiceAutomaticAndRunning
        {
            GetScript  = { @{ Result = "Audio_Service" } }

            TestScript = {
                $serviceName = $using:serviceName 
                $svc = Get-Service -Name $serviceName   

                return $svc.Status -eq "Running"
            }

            SetScript  = {
                $serviceName = $using:serviceName 
                $svc = Get-Service -Name $serviceName   

                if ($svc.StartType -ne "Automatic") {
                    $msg = "start type of " + $servicename + " is: " + $svc.StartType
                    Write-Verbose $msg
                    Set-Service -name  $serviceName -StartupType Automatic
                    if ($?) {
                        $msg = "changed start type of " + $servicename + " to: Automatic"
                    } else {
                        $msg = "falied to change start type of " + $servicename + " to: Automatic"
                    }
                    Write-Verbose $msg
                }
                    
                if ($svc.status -ne "Running") {
                    $msg = "status of " + $servicename + " is: " + $svc.status
                    Write-Verbose $msg
                    Set-Service -Name $serviceName -Status Running
                    if ($?) {
                        $msg = "changed status of " + $servicename + " to: Running"
                    } else {
                        $msg = "falied to change status of " + $servicename + " to: Running"
                    }

                    Write-Verbose $msg
                }
            }
        }
    }
}