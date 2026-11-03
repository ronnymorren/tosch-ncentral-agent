# REVIEW CANDIDATE. Not deployed or execution-tested.
# Run as SYSTEM using normal PowerShell policy; never use ExecutionPolicy Bypass.
# Provide the existing device's activation key through NCKEY, never a script file.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][string]$ExpectedSerial,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$ExpectedApplianceId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedInstallerSha256,
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$TargetVersion='2026.4.0.31',
    [long]$ExpectedInstallerBytes=139556088
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$serverHost='ncod691.n-able.com'
$agentDirectory='C:\Program Files (x86)\N-able Technologies\Windows Agent'
$configFile=Join-Path $agentDirectory 'config\ApplianceConfig.xml'
$agentExe=Join-Path $agentDirectory 'bin\agent.exe'
$workingDirectory='C:\ProgramData\Tosch\AgentMaintenance'
$key=$null
$token=$null
$installerExit=$null
$installerStarted=$false
$beforeVersion=$null
$beforeBoot=$null
$result=[ordered]@{Status='Failed';Computer=$env:COMPUTERNAME;Serial=$null;ApplianceId=$null;VersionBefore=$null;VersionAfter=$null;InstallerExitCode=$null;InstallerStarted=$false;RebootRequired=$false;BootUnchanged=$null;ServiceState=$null;Reason=$null}

function Read-AgentIdentity {
    if(!(Test-Path -LiteralPath $configFile) -or !(Test-Path -LiteralPath $agentExe)){throw 'Existing agent/configuration missing; upgrade-only operation refused.'}
    $xmlSettings=[Xml.XmlReaderSettings]::new()
    $xmlSettings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $xmlSettings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create($configFile,$xmlSettings)
    try {$doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.Load($reader)}finally{$reader.Dispose()}
    [pscustomobject]@{ApplianceId=[string]$doc.ApplianceConfig.ApplianceID;Version=(Get-Item -LiteralPath $agentExe).VersionInfo.FileVersion.Trim()}
}

function Assert-InstallerIdle {
    $mutex=$null;$held=$false
    try {
        try {$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}
        catch [Threading.WaitHandleCannotBeOpenedException] {}
        if($mutex){$held=$mutex.WaitOne(0);if(!$held){throw 'Windows Installer busy; defer until next round.'}}
    } finally {if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
    if(Get-Process -Name WindowsAgentSetup -ErrorAction SilentlyContinue){throw 'Agent setup already running; do not start another.'}
}

function New-ProtectedWorkDirectory {
    foreach($path in @('C:\ProgramData\Tosch',$workingDirectory)){
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Work directory is a reparse point; refused.'}
        }else{New-Item -ItemType Directory -Path $path|Out-Null}
    }
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $identity=[Security.Principal.SecurityIdentifier]::new($sid)
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $workingDirectory -AclObject $acl
}

try {
    # Consume and clear the key before any download or process launch.
    $key=[Environment]::GetEnvironmentVariable('NCKEY','Process')
    [Environment]::SetEnvironmentVariable('NCKEY',$null,'Process')
    if(!$key){throw 'NCKEY not supplied.'}
    if($key -notmatch '^[A-Za-z0-9+/]+=*$'){throw 'Activation key encoding invalid.'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'SYSTEM execution required.'}
    if($env:COMPUTERNAME -ine $ExpectedComputerName){throw 'Computer name mismatch.'}
    $serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    $result.Serial=$serial
    if($serial -ne $ExpectedSerial){throw 'BIOS serial mismatch.'}
    $beforeBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $before=Read-AgentIdentity
    $result.ApplianceId=$before.ApplianceId;$result.VersionBefore=$before.Version
    if($before.ApplianceId -ne $ExpectedApplianceId){throw 'Existing ApplianceID mismatch.'}

    # Base64 decoding here is only the vendor's activation-key format, never code.
    $parts=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($key)).Split('|')
    if($parts.Count -lt 4){throw 'Activation key format invalid.'}
    $address=if($parts[0] -match '://'){$parts[0]}else{'https://'+$parts[0]}
    $server=[Uri]$address
    if(!$server.IsAbsoluteUri -or $server.Host -ine $serverHost -or $server.UserInfo){throw 'Activation key server mismatch.'}
    if($parts[1] -ne $ExpectedApplianceId){throw 'Activation key ApplianceID mismatch.'}
    $token=$parts[2]
    if([version]$before.Version -ge [version]$TargetVersion){
        $result.Status='AlreadyCurrent';$result.VersionAfter=$before.Version;$result.Reason='No installer started.'
    }else{
        Assert-InstallerIdle
        New-ProtectedWorkDirectory
        $installer=Join-Path $workingDirectory ('WindowsAgentSetup-'+$TargetVersion+'-'+[Guid]::NewGuid().ToString('N')+'.exe')
        $partial=$installer+'.partial'
        foreach($path in @($partial,$installer)){
            if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Installer path is a reparse point; refused.'}
        }
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $url='https://'+$serverHost+'/download/'+$TargetVersion+'/winnt/N-central/WindowsAgentSetup.exe'
        # One bounded download. A failed download does not automatically retry an installation.
        Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 0
        if((Get-Item -LiteralPath $partial).Length -ne $ExpectedInstallerBytes){throw 'Incomplete or unexpected installer length.'}
        if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $ExpectedInstallerSha256){throw 'Installer SHA256 mismatch.'}
        $signature=Get-AuthenticodeSignature -LiteralPath $partial
        if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?N-ABLE TECHNOLOGIES LTD"?(?:,|$)'){throw 'Installer signature/publisher invalid.'}
        Move-Item -LiteralPath $partial -Destination $installer -Force

        # Recheck immediately before launch, including possible concurrent native updates.
        $latest=Read-AgentIdentity
        if($latest.ApplianceId -ne $ExpectedApplianceId -or $latest.Version -ne $before.Version){throw 'Agent changed during download; do not install.'}
        Assert-InstallerIdle
        $arguments='/s /v" /qn AGENTACTIVATIONKEY='+$key+' REBOOT=ReallySuppress"'
        $process=Start-Process -FilePath $installer -ArgumentList $arguments -PassThru
        $installerStarted=$true;$result.InstallerStarted=$true
        if(!$process.WaitForExit(900000)){
            $result.Status='UnknownInstallerOutcome'
            throw 'Installer did not finish within 15 minutes. Do not kill or start another installer.'
        }
        $process.Refresh();$installerExit=$process.ExitCode;$result.InstallerExitCode=$installerExit
        if($installerExit -notin @(0,3010)){throw ('Installer exit code '+$installerExit)}
        $result.RebootRequired=($installerExit -eq 3010)
        $deadline=(Get-Date).AddMinutes(10)
        $after=$null;$service=$null
        do {
            # Agent files can temporarily disappear while the installer finishes.
            # Wait within the existing deadline; never run the installer again.
            if(!(Test-Path -LiteralPath $configFile) -or !(Test-Path -LiteralPath $agentExe)){
                Start-Sleep -Seconds 10
                continue
            }
            try {$after=Read-AgentIdentity}
            catch [IO.IOException] {Start-Sleep -Seconds 10;continue}
            catch [Xml.XmlException] {Start-Sleep -Seconds 10;continue}
            catch {
                if($_.Exception.Message -eq 'Existing agent/configuration missing; upgrade-only operation refused.'){
                    Start-Sleep -Seconds 10
                    continue
                }
                throw
            }
            $service=Get-Service -Name 'Windows Agent Service' -ErrorAction SilentlyContinue
            if($after.ApplianceId -ne $ExpectedApplianceId){throw 'ApplianceID changed; manual investigation required.'}
            if($after.Version -eq $TargetVersion -and $service.Status -eq 'Running'){break}
            Start-Sleep -Seconds 10
        }while((Get-Date) -lt $deadline)
        $result.VersionAfter=$after.Version;$result.ServiceState=[string]$service.Status
        $result.BootUnchanged=((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') -eq $beforeBoot)
        if(!$after -or $after.Version -ne $TargetVersion -or $service.Status -ne 'Running'){
            $result.Status=if($result.RebootRequired){'PendingRebootNeedsVerification'}else{'LocalVerificationIncomplete'}
            $result.Reason='Postcheck deadline reached; target version/service not confirmed. No second installer or reboot started.'
        }else{
            $result.Status=if($result.RebootRequired){'PendingReboot'}else{'LocalVerifiedWaitCloud'}
            $result.Reason='Independent cloud/customer/site/heartbeat/duplicate checks still required.'
        }
    }
}catch{
    if($result.Status -ne 'UnknownInstallerOutcome'){$result.Status='Failed'}
    $message=[string]$_.Exception.Message
    foreach($secret in @($key,$token)){if($secret){$message=$message.Replace($secret,'[redacted]')}}
    $result.Reason=[regex]::Replace($message,'[A-Za-z0-9+/]{64,}={0,2}','[redacted]')
}finally{
    $key=$null;$token=$null;$parts=$null;$arguments=$null
    [Environment]::SetEnvironmentVariable('NCKEY',$null,'Process')
}
$result|ConvertTo-Json -Compress
if($result.Status -in @('PendingReboot','PendingRebootNeedsVerification')){exit 3010}
if($result.Status -in @('LocalVerifiedWaitCloud','AlreadyCurrent')){exit 0}
exit 1
