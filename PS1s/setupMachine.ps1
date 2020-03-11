<#
    .SYNOPSIS
        Configure Windows 10 Workstation with Avid Media Composer.

    .DESCRIPTION
        Configure Windows 10 Workstation with Avid Media Composer.

        Example command line: .\setupMachine.ps1 Avid Media Composer
#>
[CmdletBinding(DefaultParameterSetName = "Standard")]
param(
    [string]
    [ValidateNotNullOrEmpty()]
    $MediaComposerURL,
    [string]
    [ValidateNotNullOrEmpty()]
    $TeradiciURL,
    [string]
    [ValidateNotNullOrEmpty()]
    $NvidiaURL,
    [string]
    [ValidateNotNullOrEmpty()]
    $TeradiciKey
)

# the windows packages we want to remove
$global:AppxPkgs = @(
    "*windowscommunicationsapps*"
    "*windowsstore*"
)

filter Timestamp {"$(Get-Date -Format o): $_"}

function
Write-Log($message) {
    $msg = $message | Timestamp
    Write-Output $msg
}

function
DownloadFileOverHttp($Url, $DestinationPath) {
    $secureProtocols = @()
    $insecureProtocols = @([System.Net.SecurityProtocolType]::SystemDefault, [System.Net.SecurityProtocolType]::Ssl3)

    foreach ($protocol in [System.Enum]::GetValues([System.Net.SecurityProtocolType])) {
        if ($insecureProtocols -notcontains $protocol) {
            $secureProtocols += $protocol
        }
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $secureProtocols

    # make Invoke-WebRequest go fast: https://stackoverflow.com/questions/14202054/why-is-this-powershell-code-invoke-webrequest-getelementsbytagname-so-incred
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest $Url -UseBasicParsing -OutFile $DestinationPath -Verbose
    Write-Log "$DestinationPath updated"
}

function
Remove-WindowsApps($UserPath) {
    ForEach ($app in $global:AppxPkgs) {
        Get-AppxPackage -Name $app | Remove-AppxPackage -ErrorAction SilentlyContinue
    }
    try {
        ForEach ($app in $global:AppxPkgs) {
            Get-AppxPackage -Name $app | Remove-AppxPackage -User $UserPath -ErrorAction SilentlyContinue
        }
    }
    catch {
        # the user may not be created yet, but in case it is we want to remove the app
    }
    
    #Remove-Item "c:\Users\Public\Desktop\Short_survey_to_provide_input_on_this_VM..url"
}

function
Install-ChocolatyAndPackages {
    
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        
    Write-Log "choco install -y 7zip.install"
    choco install -y 7zip.install

    Write-Log "Quicktime"
    choco install -y quicktime

    Write-Log "Microsoft C++ Redistribution"
    choco install -y vcredist-all
}

function
Install-MediaComposer {
    Write-Log "downloading Media Composer"
    # TODO: dynamically generate names based on download usrl
    $DestinationPath = "D:\AzureData\Media_Composer_2018.12_Win.zip"
    Write-Log $DestinationPath
    DownloadFileOverHttp $MediaComposerURL $DestinationPath
   
   
    # unzip media composer first
    Write-Log "unzip media composer first"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($DestinationPath, "D:\AzureData\")
        
    #PreReqBasePath
    $PreReqBasePath = "D:\AzureData\MediaComposer\Installers\MediaComposer\ISSetupPrerequisites"
                      
    #Install PACE License Support
    Write-Log "Installing PACE License Support"
    New-Item -ItemType Directory -Force -Path "$PreReqBasePath\pace"
    $PaceLicenseSupportExe = "$PreReqBasePath\PACE License Support 3.1.3\License Support Win64.exe"
    Start-Process -FilePath $PaceLicenseSupportExe -ArgumentList "/s", "/x", "/b$PreReqBasePath\pace", "/v/qn" -Wait
    Start-Process -FilePath "$PreReqBasePath\pace\PACE License Support Win64.msi" -ArgumentList "/quiet", "/passive", "/norestart" -Wait

    #Install Sentinel USB Driver
    Write-Log "Installing Sentinel USB Driver"
    New-Item -ItemType Directory -Force -Path "$PreReqBasePath\sentinel"
    Start-Process -FilePath "$PreReqBasePath\Sentinel USB 7.6.6 Driver\Sentinel Protection Installer 7.6.6.exe" -ArgumentList "/s", "/x", "/b$PreReqBasePath\sentinel", "/v/qn" -Wait
    Start-Process -FilePath "$PreReqBasePath\sentinel\Sentinel Protection Installer 7.6.6.msi" -ArgumentList "/quiet", "/passive", "/norestart" -Wait

    #Install Avid Application Manager
    Write-Log "Installing Avid Application Manager"   
    New-Item -ItemType Directory -Force -Path "$PreReqBasePath\avidapplicationmanager"
    Start-Process -FilePath "$PreReqBasePath\Avid Application Manager\AvidApplicationManagerSetup.exe" -ArgumentList "/s", "/x", "/b$PreReqBasePath\avidapplicationmanager", "/v/qn" -Wait
    Start-Process -FilePath "$PreReqBasePath\avidapplicationmanager\Avid Application Manager.msi" -ArgumentList "/quiet", "/passive", "/norestart" -Wait

    #Install media composer first
    Write-Log "Install Media Composer"
    Start-Process -FilePath "D:\AzureData\MediaComposer\Installers\MediaComposer\Avid Media Composer.msi" -ArgumentList "/quiet", "/passive", "/norestart" -Wait
    Write-Log "Finished Installing Media Composer"
}


function
Install-Teradici {
    
    Set-Location -Path "C:\AzureData"
        
    Write-Log "Downloading Teradici"
    $TeradiciDestinationPath = "D:\AzureData\PCoIP_agent_release_installer_graphic.exe"

    Write-Log $DestinationPath
    DownloadFileOverHttp $TeradiciURL $TeradiciDestinationPath   
    
    Write-Log "Install Teradici"
    Start-Process -FilePath $TeradiciDestinationPath -ArgumentList "/S", "/nopostreboot" -Verb RunAs -Wait 

    cd "C:\Program Files (x86)\Teradici\PCoIP Agent"

    Write-Log "Register Teradici"   
    #$TeradiciRegistrationPath = "C:\Program Files (x86)\Teradici\PCoIP Agent\pcoip-register-host.ps1" 
    #$TeradiciRegistrationAuguments = "-RegistrationCode " + $TeradiciKey
    #Write-Log $TeradiciRegistrationAuguments
    #Start-Process -FilePath $TeradiciRegistrationPath -ArgumentList $TeradiciRegistrationAuguments
    
    & .\pcoip-register-host.ps1 -RegistrationCode $TeradiciKey

    & .\pcoip-validate-license.ps1

    Write-Log "Restart Teradici Service" 
    restart-service -name PCoIPAgent
}

function 
Install-NvidiaGPU {
    Write-Log "Download Nvidia Tesla Driver"
    $NvidiaDestinationPath = "D:\AzureData\Nividia.exe"

    Write-Log $DestinationPath
    DownloadFileOverHttp $NvidiaURL $NvidiaDestinationPath  
    
    Write-Log "Install Nvidia"
    Start-Process -FilePath $NvidiaDestinationPath -ArgumentList "-s", "-noreboot" -Verb RunAs -Wait 

}

function
Mount-DataDisk {
    
    $disks = Get-Disk | Where partitionstyle -eq 'raw' | sort number

    $letters = 70..89 | ForEach-Object { [char]$_ }
    $count = 0
    $labels = "SampleVideo1", "data1", "data2", "data3", "data4", "data5", "data6", "data7", "data8", "data9", "data10"

    foreach ($disk in $disks) {
        $driveLetter = $letters[$count].ToString()
        $disk | 
            Initialize-Disk -PartitionStyle MBR -PassThru |
            New-Partition -UseMaximumSize -DriveLetter $driveLetter |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $labels[$count] -Confirm:$true -Force
        $count++
    }
}

try {
    # Set to false for debugging.  This will output the start script to
    # c:\AzureData\CustomDataSetupScript.log, and then you can RDP
    # to the windows machine, and run the script manually to watch
    # the output.
    if ($true) 
    {

        Write-Log("----Parameters-----")

        Write-Log("***Media Composer URL***")
        Write-Log($MediaComposerURL)

        Write-Log("***Teradici URL***")
        Write-Log($TeradiciURL)

        Write-Log("***Nvidia URL***")
        Write-Log($NvidiaURL)

        Write-Log("***Teradici Key***")
        Write-Log($TeradiciKey)
        
        Write-Log("----Parameters-----")


        Write-Log("clean-up windows apps")
        Remove-WindowsApps $UserName

        try {
            Write-Log "Installing chocolaty and packages"
            Install-ChocolatyAndPackages
        }
        catch {
            # chocolaty is best effort
        }

        Write-Log "Mount Data Disks"
        Mount-DataDisk

        Write-Log "Create Download folder"
        mkdir D:\AzureData

        Write-Log "Call Install-NvidiaGPU"
        Install-NvidiaGPU

        Write-Log "Call Install-Teradici"
        Install-Teradici

        Write-Log "Call Install-MediaComposer"
        Install-MediaComposer
        
        Write-Log "Complete"

        Write-Log "Restart Computer"
        Restart-Computer 
    }
    else {
        # keep for debugging purposes
        Write-Log "Set-ExecutionPolicy -ExecutionPolicy Unrestricted"
        Write-Log ".\CustomDataSetupScript.ps1 -MediaComposerURL $MediaComposerURL -TeradiciURL $TeradiciURL"
    }
}
catch {
    Write-Error $_
}
