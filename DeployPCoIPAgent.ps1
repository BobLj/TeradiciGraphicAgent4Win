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


$CustomScriptExtPath = 'C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension\1.9.3\Downloads\0\'
$PCoIPAgent = 'https://downloads.teradici.com/win/stable/latest-graphics-agent.json'

#Microsoft CAS Application GUID: 
$CAsGUID = "0d95c7be-a922-5be2-841a-5381655bf4f1"


#Disable Scheulded Tasks: ServerManager
Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask -Verbose

$NVIDIA_DIR = "C:\Program Files\NVIDIA Corporation\NVSMI"
$nvidia_driver_url = "https://storage.googleapis.com/nvidia-drivers-us-public/GRID/GRID9.1/431.79_grid_win10_server2016_server2019_64bit_international.exe"
$TeradiciURL = 'https://downloads.teradici.com/win/stable/' + $PCoIPLatestAgent.filename
$TeradiciKey  = ''
$PCoIPLatestAgent = $(Invoke-WebRequest $PCoIPAgent -UseBasicParsing -Verbose ).Content | ConvertFrom-Json
$TeradiciDestinationPath = "C:\AzureData\"
$driverDirectory = "C:\AzureData\"
$TeradiciDestination = $TeradiciDestinationPath + $PCoIPLatestAgent.filename

function Nvidia-is-Installed {
    if (!(test-path $NVIDIA_DIR)) {
        return $false
    }

    cd $NVIDIA_DIR
    & .\nvidia-smi.exe
    return $?
    return $false
}

function Nvidia-Install {
    "################################################################"
    "Install NVIDIA GRID Driver"
    "################################################################"

    if (Nvidia-is-Installed) {
        "NVIDIA driver already installed."
        return
    }

    mkdir 'C:\Nvidia'
    $driverDirectory = "C:\Nvidia"
    $nvidiaDriverFileName = Split-Path ${nvidia_driver_url} -Leaf
    $nvidiaDriverLocation = Split-Path ${nvidia_driver_url} -Parent
    $destFile = $driverDirectory + "\" + $nvidiaDriverFileName
    "Downloading NVIDIA GRID Driver from $nvidiaDriverLocation..."
    (New-Object System.Net.WebClient).DownloadFile("${nvidia_driver_url}", $destFile)
    "File Downloaded"

    "Installing NVIDIA GRID Driver..."
    $ret = Start-Process -FilePath $destFile -ArgumentList "/s /noeula /noreboot" -PassThru -Wait

    if (!(Nvidia-is-Installed)) {
        "ERROR: Failed to install NVIDIA GRID driver."
        exit 1
    }

    "NVIDIA GRID Driver installed successfully."
    $global:restart = $true
}

filter Timestamp {"$(Get-Date -Format o): $_"}


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
   
    If(!(test-path $TeradiciDestinationPath))  {
        New-Item -ItemType Directory -Force -Path $TeradiciDestinationPath
    }
    Set-Location -Path $TeradiciDestinationPath

    Write-Output "Downloading latest PCoIP standard agent "
    DownloadFileOverHttp $TeradiciURL $TeradiciDestination


    Write-Output "Install Teradici with "
    $ArgumentList = ' /S /NoPostReboot _?"' + $TeradiciDestination +'"'
    
    Write-Output "Teradici Destination at: $TeradiciDestination"
    Write-Output "Teradici Argument list at: $ArgumentList"
    $process =  Start-Process -FilePath $TeradiciDestination -ArgumentList $ArgumentList -Wait -PassThru;     
    Write-Output "Installed with Exit Code:"  
    Write-Output   $process.ExitCode

    Set-Location -Path  "C:\Program Files\Teradici\PCoIP Agent\"

    $attempts = 2
    do{
       try{    
                Write-Output "Registering Teradici Host attempt #:$attempts"
                & .\pcoip-register-host.ps1 -RegistrationCode $TeradiciKey
                break;

        } catch [Exception]{
                Write-Output $_.Exception.Message
                Write-Error $_.Exception.Message
        }
        $attempts--
        #if ($attempts -gt 0) { sleep $sleepInSeconds }
    }while ($attempts -gt 0) 
    
    Write-Output "Registered Teradici Host " 
    
    & .\pcoip-validate-license.ps1
    Write-Output "Validate Teradici Licence" 

}	

catch [Exception]{
    Write-Output $_.Exception.Message
    Write-Error $_.Exception.Message
}

Nvidia-Install

PCoIP-Agent-Install

"################################################################"
"Restart Computer"
"################################################################"
if ($global:restart) {
    "Restart required. Restarting..."
    Restart-Computer -Force
} else {
    "No restart required"
}

