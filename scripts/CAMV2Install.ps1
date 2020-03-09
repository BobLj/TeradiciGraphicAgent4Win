

$RESULT_COMPLETED = "Completed"
$RESULT_RESTART = "Restarting"

$ENABLE_AUTO_SHUTDOWN = $true
$AUTO_SHUTDOWN_IDLE_TIME = 240

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-UnixTimestamp {
    return (Get-Date -Date ((Get-Date).ToUniversalTime()) -UFormat %s)
}

function Get-AuthToken {
    try {
        $response = Invoke-RestMethod -Method "Get" -Headers $METADATA_HEADERS -Uri $METADATA_AUTH_URI
        return $response."access_token"
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Get-AuthToken" -Message "Error fetching auth token: $_"
        return  $false
    }
}

function Decrypt-Credentials {
    $token = Get-AuthToken

    if(!($token)) {
        return $false
    }

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $($token)")

    $resource = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $resource.Add("ciphertext", $ENC_DATA)
    
    try {
        $response = Invoke-RestMethod -Method "Post" -Headers $headers -Uri $DECRYPT_URI -Body $resource
        $credsB64 = $response."plaintext"
        $credsString = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($credsB64))
	    $credsObj = ConvertFrom-Json -InputObject $credsString
        return $credsObj
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Decrypt-Credentials" -Message "Error decrypting credentials: $_"
        return  $false
    }
}

function Get-Metadata {
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$namespace,
        [Parameter(Mandatory=$true)]
        [string]$key,
        [Parameter()]
        [bool]$suppressError
    )

    $uri = "$($METADATA_ATTR_URI)-$($namespace)/$($key)"

    try {
        return Invoke-RestMethod -Method "Get" -Headers $METADATA_HEADERS -Uri $uri
    }
    catch {
        if(!($suppressError)) {
            Log-Message -Level $LOG_ERROR -Scope "Get-Metadata" -Message "Error fetching metadata: $_"
        }
        
        return  $false
    }
}

function Put-Metadata {
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$namespace,
        [Parameter(Mandatory=$true)]
        [string]$key,
        [Parameter(Mandatory=$true)]
        [string]$value
    )

    $uri = "$($METADATA_ATTR_URI)-$($namespace)/$($key)"

    try{
        $result = Invoke-RestMethod -Method "Put" -Headers $METADATA_HEADERS -Uri $uri -Body $value
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Put-Metadata" -Message "Error storing metadata: $_"
    }
}

function Download-File {
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$uri,
        [Parameter(Mandatory=$true)]
        [string]$outFile
    )

    $retryCount = 0
    $maxRetries = 5
    $delaySeconds = 30
    $downloaded = $false

    while(-not $downloaded) {
        try {
            Invoke-WebRequest -Uri $uri -OutFile $outFile
            $downloaded = $true
        }
        catch {
            if($retryCount -ge $maxRetries) {
                Log-Message -Level $LOG_ERROR -Scope "Download-File" -Message "Failed max number of times."
                throw
            } else {
                Log-Message -Level $LOG_INFO -Scope "Download-File" -Message "Failed to download file: $_"
                Start-Sleep $delaySeconds
                $retryCount++
            }
        }
    }
}

function Log-Message {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$level,
        [Parameter(Mandatory=$true)]
        [string]$scope,
        [Parameter(Mandatory=$true)]
        [string]$message
    )

    $lvl = "[$($level)]"
    $timestamp = Get-Date
    $guid = New-Guid
    $log = "$($timestamp) $($lvl.PadRight(8)) $($scope.PadRight(24)): $($message)"

    Write-Output $log >> $LOG_FILE
    Put-Metadata -Namespace $KEY_LOGS -Key $guid -Value $log
}

function Create-Step {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$step
    )

    Put-Metadata -Namespace $step -Key $KEY_STATUS -Value $STATUS_PENDING
    Put-Metadata -Namespace $step -Key $KEY_START_TIME -Value "0"
    Put-Metadata -Namespace $step -Key $KEY_END_TIME -Value "0"
}

function Start-Step {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$step
    )

    $timestamp = Get-UnixTimestamp

    Put-Metadata -Namespace $step -Key $KEY_STATUS -Value $STATUS_EXECUTING
    Put-Metadata -Namespace $step -Key $KEY_START_TIME -Value $timestamp
    Put-Metadata -Namespace $KEY_STATE -Key $KEY_STEP -Value $step

    Log-Message -Level $LOG_INFO -Scope "Start-Step" -Message "Starting $($step)"
}

function Complete-Step {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$step
    )

    $timestamp = Get-UnixTimestamp

    Put-Metadata -Namespace $step -Key $KEY_STATUS -Value $STATUS_COMPLETE
    Put-Metadata -Namespace $step -Key $KEY_END_TIME -Value $timestamp

    Log-Message -Level $LOG_INFO -Scope "Complete-Step" -Message "Completed $($step)"
}

function Fail-Step {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$step,
        [Parameter(Mandatory=$true)]
        [Alias("ErrorMessage")]
        [string]$errMsg
    )

    $timestamp = Get-UnixTimestamp

    Put-Metadata -Namespace $step -Key $KEY_STATUS -Value $STATUS_FAILED
    Put-Metadata -Namespace $step -Key $KEY_MESSAGE -Value $errMsg
    Put-Metadata -Namespace $step -Key $KEY_END_TIME -Value $timestamp

    Log-Message -Level $LOG_INFO -Scope "Fail-Step" -Message "Failed $($step)"
}

function Cancel-Step {
    param 
    (
        [Parameter(Mandatory=$true)]
        [string]$step
    )

    $timestamp = Get-UnixTimestamp

    Put-Metadata -Namespace $step -Key $KEY_STATUS -Value $STATUS_CANCELLED
    Put-Metadata -Namespace $step -Key $KEY_START_TIME -Value $timestamp
    Put-Metadata -Namespace $step -Key $KEY_END_TIME -Value $timestamp

    Log-Message -Level $LOG_INFO -Scope "Cancel-Step" -Message "Cancelled $($step)"
}

function Require-Reboot {
    Put-Metadata -Namespace $KEY_RESTART -Key $KEY_REQUIRED -Value "true"
}

function Trigger-Reboot {
    Put-Metadata -Namespace $KEY_RESTART -Key $KEY_REQUIRED -Value "false"
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}

function Init-Steps {
    param
    (
        [Parameter(Mandatory=$true)]
        [string[]]$steps
    )

    $currentStep = Get-Metadata -Namespace $KEY_STATE -Key $KEY_STEP -SuppressError $true

    if (!($currentStep)) {
        Log-Message -Level $LOG_INFO -Scope "Init-Steps" -Message "Initializing Provisioning Metadata..."

        Put-Metadata -Namespace $KEY_STATE -Key $KEY_STEPS -Value (ConvertTo-Json -InputObject $steps -Compress)

        for($i = 0; $i -lt $steps.length; $i++) {
            Create-Step -Step $steps[$i]
        }

        $currentStep = $steps[0]

        Log-Message -Level $LOG_INFO -Scope "Init-Steps" -Message "Starting with Step $($currentStep)"

        Start-Step -Step $currentStep
    }
    else {
        Log-Message -Level $LOG_INFO -Scope "Init-Steps" -Message "Resuming Step $($currentStep)"
    }

    return $currentStep
}

function Execute-Steps {
    param
    (
        [Parameter(Mandatory=$true)]
        [string[]]$steps,
        [Parameter(Mandatory=$true)]
        [string[]]$stepHandlers
    )

    $currentStep = Init-Steps -Steps $steps
    $index = [array]::indexof($steps, $currentStep)

    $result = $RESULT_COMPLETED
    while (!($currentStep -eq $steps[-1])){
        $retryCount = 0
        $maxRetries = 3
        $delaySeconds = 30
        $stepCompleted = $false

        while(-not $stepCompleted) {
            $result = Invoke-Expression $stepHandlers[$index]
            if ($result -eq $RESULT_COMPLETED) {
                $nextStep = $steps[++$index]
                Complete-Step -Step $currentStep
                Start-Step -Step $nextStep
                $currentStep = $nextStep

                $stepCompleted = $true
            }
            elseif($result -eq $RESULT_RESTART) {
                break
            }
            else {
                if($retryCount -ge $maxRetries) {
                    Log-Message -Level $LOG_ERROR -Scope "Execute-Steps" -Message "Step $currentStep failed max number of times."

                    Fail-Step -Step $currentStep -ErrorMessage $result
                    for($i=$index+1; $i -lt $steps.length; $i++) {
                        Cancel-Step -Step $steps[$i]
                    }

                    break
                } else {
                    Log-Message -Level $LOG_ERROR -Scope "Execute-Steps" -Message "Step $currentStep failed: ( $result ) retrying..."
                    Start-Sleep $delaySeconds
                    $retryCount++
                }
                
            }
        }
        
        if(-not $stepCompleted) {
            break
        }
    }

    if(($currentStep -eq $steps[-1])) {
        Complete-Step -Step $currentStep
    }

    return $result
}

function Execute-InstallAgent {
    if(!(Test-Path $AGENT_INSTALLER_DIR)) {
        New-Item -ItemType Directory -Force -Path $AGENT_INSTALLER_DIR
    }

    # Download meta file first
    $srcUrl = "$AGENT_DOWNLOAD_URI/$AGENT_META_FILE_NAME"
    $destFile = "$AGENT_INSTALLER_DIR\$AGENT_META_FILE_NAME"
    try {
        Download-File -Uri $srcUrl -OutFile $destFile
        Log-Message -Level $LOG_INFO -Scope "Execute-InstallAgent" -Message "Downloaded meta file to $destFile"
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Execute-InstallAgent" -Message "Error downloading meta file from ${srcUrl}: $_"
        return "Failed to download meta file"
    }

    # parsing meta file and get agent installer file name
    try {
        $meta=(Get-Content -Raw -Path  $destFile | ConvertFrom-Json)
    } catch {
        Log-Message -Level $LOG_ERROR -Scope "Execute-InstallAgent" -Message "Failed to parse meta file: $_"
        return "Failed to parse meta file"
    }
    $installerFileName =$meta.filename

    # Download agent installer
    $srcUrl = "${AGENT_DOWNLOAD_URI}/${installerFileName}"
    $destFile = "${AGENT_INSTALLER_DIR}\${installerFileName}"
    try {
        Download-File -Uri $srcUrl -OutFile $destFile
        Log-Message -Level $LOG_INFO -Scope "Execute-InstallAgent" -Message "Downloaded agent installer to $destFile"
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Execute-InstallAgent" -Message "Error downloading agent installer from ${srcUrl}: $_"
        return "Failed to download agent installer"
    }
    
    $AGENT_INSTALLER_FILE = $destFile

    try {
        $ret = Start-Process -FilePath $AGENT_INSTALLER_FILE -ArgumentList "/S /nopostreboot" -PassThru -Wait
        Log-Message -Level $LOG_INFO -Scope "Execute-InstallAgent" -Message "Installed agent"
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Execute-InstallAgent" -Message "Error installing agent: $_"
        return "Failed to install agent"
    }

    return $RESULT_COMPLETED
}

function Execute-Install-Idle-ShutDown {

    $serviceName = "CAMIdleShutdown"

    Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message "Starting installation of IdleShutdownAgent.exe"

    $is64 = $false
    $path = "C:\Program Files (x86)\Teradici\PCoIP Agent\bin"
    if (!(Test-Path -path $path))  {
        $path = "C:\Program Files\Teradici\PCoIP Agent\bin"
        $is64 = $true
    }
    
    cd $path

    $ret = .\IdleShutdownAgent.exe -install
    # Check for success
    if( !$? ) {
        $msg = "Failed to install {0} because: {1}" -f $serviceName, $ret
        Log-Message -Level $LOG_ERROR -Scope "Execute-Install-Idle-ShutDown" -Message $msg
        return $msg
    }

    $idleTimerRegKeyPath = "HKLM:SOFTWARE\WOW6432Node\Teradici\CAMShutdownIdleMachineAgent"
    if ($is64) {
        $idleTimerRegKeyPath = "HKLM:SOFTWARE\Teradici\CAMShutdownIdleMachineAgent"
    }
    
    $idleTimerRegKeyName = "MinutesIdleBeforeShutdown"

    if (!(Test-Path $idleTimerRegKeyPath)) {
        New-Item -Path $idleTimerRegKeyPath -Force
    }
    New-ItemProperty -Path $idleTimerRegKeyPath -Name $idleTimerRegKeyName -Value $AUTO_SHUTDOWN_IDLE_TIME -PropertyType DWORD -Force

    $svc = Get-Service -Name $serviceName

    if (!$ENABLE_AUTO_SHUTDOWN) {
        $msg = "attempting to disable {0} service" -f $serviceName
        Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message $msg

        try {
            if ($svc.Status -ne "Stopped") {
                Start-Sleep -s 15
                $svc.Stop()
                $svc.WaitForStatus("Stopped", 30)
            }
            Set-Service -InputObject $svc -StartupType "Disabled"
            $status = if ($?) { "succeeded" } else { "failed" }
            $msg = "disable {0} service {1}" -f $svc.ServiceName, $status
            Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message $msg
        }
        catch {
            return "failed to disable CAMIdleShutdown service."
        }
    }

    if ($svc.StartType -ne "Automatic") {
        $msg = "try setting {0} Service start type to automatic." -f $serviceName
        Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message $msg

        Set-Service -name  $serviceName -StartupType Automatic

        $status = If ($?) {"succeeded"} Else {"failed"}
        $msg = "{0} to change start type of {1} service to Automatic." -f $status, $serviceName
        Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message $msg
    }

    if ($svc.status -eq "Paused") {
        Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message "try resuming CAMIdleShutdown Service ."
        try{
            $svc.Continue()
            Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message "succeeded to resume CAMIdleShutdown service."
        }catch{
            return "failed to resume CAMIdleShutdown Service."
        }
    }

    if ( $svc.status -eq "Stopped" )    {
        Log-Message -Level $LOG_INFO -Scope "Execute-Install-Idle-ShutDown" -Message "Starting CAMIdleShutdown Service ..."
        try{
            $svc.Start()
            $svc.WaitForStatus("Running", 120)
        }catch{
            return "failed to start CAMIdleShutdown Service"
        }
    }
    return $RESULT_COMPLETED
}

function Execute-DecryptCredentials {
    if(!($ENCRYPTED -eq "true")) {
        Log-Message -Level $LOG_INFO -Scope "Execute-DecryptCredentials" -Message "Credentials not encrypted, skipping ..."
        return $RESULT_COMPLETED
    }

    try {
        $creds = Decrypt-Credentials

        if(!($creds)) {
            return "Failed to decrypt credentials"
        }
    
        $DATA."registrationCode" = $creds."registrationCode"
        $DATA."serviceAccountPassword" = $creds."serviceAccountPassword"
        $DATA."serviceAccount" = $creds."serviceAccount"
        $DATA."domainLocalIp" = $creds."domainLocalIp" -join ","
        $DATA."domainName" = $creds."domainName"

        Log-Message -Level $LOG_INFO -Scope "Execute-DecryptCredentials" -Message "Decrypted credentials."
    }
    catch {
        Log-Message -Level $LOG_ERROR -Scope "Execute-DecryptCredentials" -Message "Error decrypting credentials: $_"

        return "Missing credentials from decrypted data"
    }

    return $RESULT_COMPLETED
}

function Get-AgentHomePath {
    $path = "C:\Program Files\Teradici\PCoIP Agent"

    if (Test-Path -path $path)  {
        return $path
    }

    return "C:\Program Files (x86)\Teradici\PCoIP Agent"
}

function Execute-RegisterLicense {
    Log-Message -Level $LOG_INFO -Scope "Execute-RegisterLicense" -Message "Registering pcoip license ..."

    $agent_home = Get-AgentHomePath
    cd $agent_home
    & .\pcoip-register-host.ps1 -RegistrationCode $DATA."registrationCode"
    & .\pcoip-validate-license.ps1
    if ($?) {
      Log-Message -Level $LOG_INFO -Scope "Execute-RegisterLicense" -Message "Register completed"
      return $RESULT_COMPLETED
    } else {
      Log-Message -Level $LOG_ERROR -Scope "Execute-RegisterLicense" -Message "Register failed"
      return "Registration Failed"
    }
}

function Execute-JoinDomain {
    Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "Starting join domain ..."
    try{
      $interface = (Get-DNSClientServerAddress -AddressFamily "IPv4" | Where-Object {$_.ServerAddresses.Count -gt 0} | Where-Object InterfaceAlias -notlike "*$($PROJECT)*").InterfaceAlias
      Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "interface: $interface"

      Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "set DNSClientServerAddress"
      Set-DNSClientServerAddress -InterfaceAlias $interface -ServerAddresses $DATA."domainLocalIp".split(",")

      $username = $DATA."serviceAccount" + "@" + $DATA."domainName"
      $password = ConvertTo-SecureString $DATA."serviceAccountPassword" -AsPlainText -Force
      $cred = New-Object System.Management.Automation.PSCredential ($username, $password)

      Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "Adding computer..."
      Add-Computer -DomainName $DATA."domainName" -Credential $cred
      if ($?) {
        Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "Add computer Completed"
        Log-Message -Level $LOG_INFO -Scope "Execute-JoinDomain" -Message "Join domain completed"
        Require-Reboot
        return $RESULT_COMPLETED
      } else {
        Log-Message -Level $LOG_ERROR -Scope "Execute-JoinDomain" -Message "Add computer failed"
        return "Could not add computer"
      }
    }
    catch
    {
      Log-Message -Level $LOG_ERROR -Scope "Execute-JoinDomain" -Message "Failed to join domain: $_"
      return "Could not join domain"
    }
}

function Execute-Reboot {
    $rebootRequired = Get-Metadata -Namespace $KEY_RESTART -Key $KEY_REQUIRED

    if (($rebootRequired -eq "true")) {
        Log-Message -Level $LOG_INFO -Scope "Execute-Reboot" -Message "Preparing to restart"

        return $RESULT_RESTART
    }
    elseif(($rebootRequired -eq "") -Or ($rebootRequired -eq "false")) {
        Log-Message -Level $LOG_INFO -Scope "Execute-Reboot" -Message "Reboot complete"

        return $RESULT_COMPLETED
    }
}

function Execute-Complete {
    Log-Message -Level $LOG_INFO -Scope "Execute-Complete" -Message "Provisioning Complete"

    return $RESULT_COMPLETED
}

function Run-Script {
    $steps = "install-agent", "decrypt-credentials", "register-license", "install-idle-shutdown", "join-domain", "reboot", "complete"
    $stepHandlers = "Execute-InstallAgent", "Execute-DecryptCredentials", "Execute-RegisterLicense", "Execute-Install-Idle-ShutDown", "Execute-JoinDomain", "Execute-Reboot", "Execute-Complete"

    if(!(Test-Path $LOG_DIR)) {
      New-Item -ItemType Directory -Force -Path $LOG_DIR
    }

    Put-Metadata -Namespace $KEY_STATE -Key $KEY_STATUS -Value $STATUS_EXECUTING

    $result = Execute-Steps -Steps $steps -StepHandlers $stepHandlers

    if(($result -eq $RESULT_COMPLETED)) {
        Put-Metadata -Namespace $KEY_STATE -Key $KEY_STATUS -Value $STATUS_COMPLETE
    }
    elseif(($result -eq $RESULT_RESTART)) {
        Trigger-Reboot
    }
    else {
        Put-Metadata -Namespace $KEY_STATE -Key $KEY_STATUS -Value $STATUS_FAILED
        Put-Metadata -Namespace $KEY_STATE -Key $KEY_MESSAGE -Value $result
    }
}

Run-Script
