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

<#
    .SYNOPSIS
        Configure Windows 10 Workstation with Teradici PCoIP.

    .DESCRIPTION
        Configure Windows 10 Workstation with Avid Media Composer.
        Example command line: .\setupMachine.ps1 Avid Media Composer

#>

[CmdletBinding(DefaultParameterSetName = "Standard")]
param(

    [string]
    [ValidateNotNullOrEmpty()]
    $TeraRegKey,

    [string]
    [ValidateNotNullOrEmpty()]
    $PCoIPAgentURI,

    [string]
    [ValidateNotNullOrEmpty()]
    $PCoIPAgentEXE
)

Test Configuration
$TeraRegKey='CN1XHFS757XM82F1-2CAE-54A2-83BF'
$PCoIPAgentUri= 'https://downloads.teradici.com/win/stable/'
$PCoIPAgentEXE = 'pcoip-agent-graphics_20.01.1.exe'



#Install/Test Configuration
$AgentDestinationPath = 'C:\AzureData\'
$AgentLocation ='C:\Program Files\Teradici\PCoIP Agent\'


$AgentDestination = $AgentDestinationPath + $PCoIPAgentEXE
$PCoIPAgentURL = $PCoIPAgentUri

Write-Output "TeraRegKey:      $TeraRegKey"
Write-Output "PCoIPAgentURI:   $PCoIPAgentURI"
Write-Output "PCoIPAgentEXE:   $PCoIPAgentEXE"
Write-Output "AgentDestination:$AgentDestination"
Write-Output "PCoIPAgentURL:   $PCoIPAgentURL"


#Disable Scheulded Tasks: ServerManager
Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask -Verbose
# Install new desktop background
# Install Firefox


function DownloadFileOverHttp($Url, $DestinationPath) {
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
    Write-Output "$DestinationPath updated"
}

try {
   
    #Set the Agent's destination 
    If(!(test-path $AgentDestinationPath))  {
        New-Item -ItemType Directory -Force -Path $AgentDestinationPath
    }
    Set-Location -Path $AgentDestinationPath

    #Download Agent
    Write-Output "Downloading latest PCoIP standard agent from $PCoIPAgentURL"
    DownloadFileOverHttp $PCoIPAgentURL $AgentDestination

    
    #Install Agent from Agent Destination 
    Write-Output "Install Teradici with Destination Path: $AgentDestination"
    $ArgumentList = ' /S /NoPostReboot _?"' + $AgentDestination +'"'

    Write-Output "Teradici Argument list at: $ArgumentList"
    $process =  Start-Process -FilePath $AgentDestination -ArgumentList $ArgumentList -Wait -PassThru;     
    Write-Output "Installed PCoIP Agent with Exit Code:" $process.ExitCode
    
    #Registering Agent with Licence Server
    Set-Location -Path  $AgentLocation

    $Registered = & .\pcoip-register-host.ps1 -RegistrationCode $TeraRegKey
    Write-Output "Registering Teradici Host returned this result: $Registered"

    #Validate Licence 
    $Validate =& .\pcoip-validate-license.ps1
    Write-Output "Validate Teradici Licence returned: $Validate"       
    
    Write-Output "Restart VM..."   
    Restart-Computer -Force

}
catch [Exception]{
    Write-Output $_.Exception.Message
    Write-Error $_.Exception.Message
}