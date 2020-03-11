<#
    .SYNOPSIS
        Configure Windows 10 Workstation with Teradici Graphics Agent.

    .DESCRIPTION
        Configure Windows 10 Workstation with Teradici Graphics Agent.

        Example command line: .\installTeradici.ps1 -TeradiciURL "URL" 
#>
[CmdletBinding(DefaultParameterSetName="Standard")]
param(
    [string]
    [ValidateNotNullOrEmpty()]
    $TeradiciURL
)

filter Timestamp {"$(Get-Date -Format o): $_"}

function
Write-Log($message)
{
    $msg = $message | Timestamp
    Write-Output $msg
}

function
DownloadFileOverHttp($Url, $DestinationPath)
{
     $secureProtocols = @()
     $insecureProtocols = @([System.Net.SecurityProtocolType]::SystemDefault, [System.Net.SecurityProtocolType]::Ssl3)

     foreach ($protocol in [System.Enum]::GetValues([System.Net.SecurityProtocolType]))
     {
         if ($insecureProtocols -notcontains $protocol)
         {
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
Install-Teradici
{
    Write-Log "Downloading Teradici"
    $TeradiciDestinationPath =  "C:\AzureData\PCoIP_agent_release_installer_graphics.exe"

    Write-Log $DestinationPath
    DownloadFileOverHttp $TeradiciURL $TeradiciDestinationPath   

    Write-Log "Install Teradici"
    #Start-Process -FilePath $TeradiciDestinationPath -ArgumentList "/S", "/NoPostReboot", "_?C:\AzureData\PCoIP_agent_release_installer_graphics.exe" -Wait 
    & $TeradiciDestinationPath /S /NoPostReboot _?C:\AzureData\PCoIP_agent_release_installer_graphics.exe
       
    Start-Sleep -s 480

    Write-Log "Register Teradici"   
    & 'C:\Program Files (x86)\Teradici\PCoIP Agent\pcoip-register-host.ps1' -RegistrationCode E52E-747C-A521-C8B8

    Write-Log "Restart Teradici Service" 
    restart-service -name PCoIPAgent
}


try
{

    Write-Log "Call Install-Teradici"
    Install-Teradici
        
    Write-Log "Complete"

    Write-Log "Remove task"
    schtasks.exe /delete /tn "InstallTeradici"
    
}
catch
{
    Write-Error $_
}
