# CANDIDATE ONLY. Not published, executed or released. One explicitly approved pilot required.
# New install only on LT07 / 5CD12799C1. Requested staging 653 is not cloud proof.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$token=[Environment]::GetEnvironmentVariable('NCSTAGINGTOKEN','Process')
[Environment]::SetEnvironmentVariable('NCSTAGINGTOKEN',$null,'Process')
$target='2026.4.1.26'
$installerSha='7ff03c5fd6ab8cafb981a4aa4c6cda37b8a0ae3996f88d09936d387de7719b85'
$installerBytes=139808560
$resultFile=$null;$reservation=$null;$argsForInstaller=$null
$r=[ordered]@{Status='Preflight';Computer=$env:COMPUTERNAME;Serial=$null;RequestedCustomerId=653;TargetVersion=$target;InstallerStarted=$false;InstallerPid=$null;InstallerExitCode=$null;RebootRequired=$false;BootBeforeUtc=$null;BootAfterUtc=$null;BootUnchanged=$null;ApplianceId=$null;VersionAfter=$null;ServiceState=$null;ServiceExitCode=$null;CloudVerified=$false;Reason=$null;ObservedUtc=$null}
function Write-State([string]$Status){
 $r.Status=$Status;$r.ObservedUtc=[DateTime]::UtcNow.ToString('o')
 $json=$r|ConvertTo-Json -Depth 5 -Compress
 if($resultFile){[IO.File]::WriteAllText($resultFile,$json,[Text.UTF8Encoding]::new($false))}
 Write-Output $json
}
function Assert-NewOnly {
 if($env:COMPUTERNAME -ine 'LT07' -or (Get-CimInstance Win32_BIOS).SerialNumber.Trim() -cne '5CD12799C1'){throw 'Pilot identity mismatch.'}
 foreach($base in @('C:\Program Files (x86)\N-able Technologies\Windows Agent','C:\Program Files\N-able Technologies\Windows Agent')){
  if(Test-Path -LiteralPath $base){throw 'Existing agent directory detected; this route never repairs or upgrades.'}
 }
 if(Get-CimInstance Win32_Service -Filter "Name='Windows Agent Service'"){throw 'Existing agent service detected.'}
 foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')){
  if(Test-Path $key){
   $found=@(Get-ChildItem $key|Get-ItemProperty|Where-Object {$_.DisplayName -match '(?i)Windows Agent|N-central.*Agent|N-able.*Agent'})
   if($found.Count){throw 'Existing agent uninstall registration detected; manual evaluation required.'}
  }
 }
}
function Assert-Idle {
 $m=$null;$held=$false
 try{
  try{$m=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{}
  if($m){$held=$m.WaitOne(0);if(!$held){throw 'Windows Installer busy; skip.'}}
 }finally{if($held){$m.ReleaseMutex()};if($m){$m.Dispose()}}
 if(Get-Process WindowsAgentSetup,WindowsProbeSetup -ErrorAction SilentlyContinue){throw 'Agent or probe installer already running.'}
}
function Read-Agent {
 $base='C:\Program Files (x86)\N-able Technologies\Windows Agent'
 $config=Join-Path $base 'config\ApplianceConfig.xml';$exe=Join-Path $base 'bin\agent.exe'
 foreach($path in @($base,(Join-Path $base 'config'),(Join-Path $base 'bin'),$config,$exe)){
  if(!(Test-Path -LiteralPath $path)){return $null}
  if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Agent path is a reparse point.'}
 }
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
 $reader=[Xml.XmlReader]::Create($config,$settings)
 try{$doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null;$doc.Load($reader)}finally{$reader.Dispose()}
 $ids=@($doc.SelectNodes('//*')|Where-Object LocalName -eq 'ApplianceID')
 if($ids.Count -ne 1 -or $ids[0].InnerText -notmatch '^[1-9][0-9]*$'){return $null}
 $svc=Get-CimInstance Win32_Service -Filter "Name='Windows Agent Service'"
 [pscustomobject]@{ApplianceId=[string]$ids[0].InnerText;Version=(Get-Item -LiteralPath $exe).VersionInfo.FileVersion.Trim();ServiceState=$svc.State;ServiceExitCode=$svc.ExitCode}
}
try {
 if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'SYSTEM required.'}
 if((Get-ExecutionPolicy) -notin @('Unrestricted','RemoteSigned','Bypass')){throw 'Inherited policy does not support this readable route; no override permitted.'}
 if(!$token -or $token -notmatch '^[A-Za-z0-9_-]{12,}$'){throw 'Staging token missing or invalid.'}
 Assert-NewOnly;Assert-Idle
 $r.Serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim()
 $r.BootBeforeUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
 $work='C:\ProgramData\Tosch\AgentMaintenanceNewInstall'
 foreach($path in @('C:\ProgramData','C:\ProgramData\Tosch',$work)){
  if(Test-Path -LiteralPath $path){if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Work path is a reparse point.'}}
  else{New-Item -ItemType Directory -Path $path|Out-Null}
 }
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit, ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $work -AclObject $acl
 $reservation=Join-Path $work 'LT07-5CD12799C1.install-reservation.json'
 if(Test-Path -LiteralPath $reservation){throw 'Prior pilot reservation exists; do not retry automatically.'}
 $run=Join-Path $work ('run-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $run|Out-Null
 $resultFile=Join-Path $run 'result.json'
 Write-State 'PreflightVerified'
 $installer=Join-Path $run 'WindowsAgentSetup.exe';$partial=$installer+'.partial'
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Invoke-WebRequest -UseBasicParsing -Uri 'https://ncod691.n-able.com/download/2026.4.1.26/winnt/N-central/WindowsAgentSetup.exe' -OutFile $partial -TimeoutSec 120
 if((Get-Item -LiteralPath $partial).Length -ne $installerBytes -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $installerSha){throw 'Installer size/hash mismatch.'}
 $signature=Get-AuthenticodeSignature -LiteralPath $partial
 if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?N-ABLE TECHNOLOGIES LTD"?(?:,|$)'){throw 'Installer signature/publisher mismatch.'}
 Move-Item -LiteralPath $partial -Destination $installer
 Write-State 'InstallerVerified'
 Assert-NewOnly;Assert-Idle
 # Atomic local reservation prevents a second attempt when the original outcome is unknown.
 $lock=[IO.File]::Open($reservation,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.Encoding]::UTF8.GetBytes((@{runDirectory=$run;requestedCustomerId=653;retryAllowed=$false;createdUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress));$lock.Write($bytes,0,$bytes.Length);$lock.Flush()}finally{$lock.Dispose()}
 $argsForInstaller='/s /v" /qn CUSTOMERID=653 CUSTOMERSPECIFIC=1 REGISTRATION_TOKEN='+$token+' SERVERPROTOCOL=HTTPS SERVERADDRESS=ncod691.n-able.com SERVERPORT=443 REBOOT=ReallySuppress "'
 Write-State 'LaunchRequested'
 $process=Start-Process -FilePath $installer -ArgumentList $argsForInstaller -PassThru -WindowStyle Hidden
 $r.InstallerStarted=$true;$r.InstallerPid=$process.Id;Write-State 'InstallerRunning'
 if(!$process.WaitForExit(900000)){$r.Reason='Installer timeout; no kill or second installation permitted.';Write-State 'UnknownInstallerOutcome';exit 1}
 $process.Refresh();$r.InstallerExitCode=$process.ExitCode;$r.RebootRequired=$process.ExitCode -eq 3010
 Write-State 'InstallerExited'
 if($process.ExitCode -notin @(0,3010)){throw ('Installer exit '+$process.ExitCode)}
 $deadline=(Get-Date).AddMinutes(10);$agent=$null
 do{
  try{$agent=Read-Agent}catch [IO.IOException]{$agent=$null}catch [Xml.XmlException]{$agent=$null}
  if($agent -and $agent.Version -eq $target -and $agent.ServiceState -eq 'Running' -and $agent.ServiceExitCode -eq 0){break}
  Start-Sleep -Seconds 10
 }while((Get-Date) -lt $deadline)
 $r.BootAfterUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');$r.BootUnchanged=$r.BootAfterUtc -eq $r.BootBeforeUtc
 $r.ApplianceId=$agent.ApplianceId;$r.VersionAfter=$agent.Version;$r.ServiceState=$agent.ServiceState;$r.ServiceExitCode=$agent.ServiceExitCode
 if(!$r.BootUnchanged){throw 'Unexpected Windows restart observed; independent review required.'}
 if(!$agent -or $agent.Version -ne $target -or $agent.ServiceState -ne 'Running' -or $agent.ServiceExitCode -ne 0){throw 'Local postcheck incomplete; no retry.'}
 $r.Reason='Independently verify actual cloud customer 653, identity, unique registration and a later heartbeat before any move. No reboot command issued.'
 if($r.RebootRequired){Write-State 'PendingReboot';exit 3010}
 Write-State 'LocalVerifiedWaitStagingCloud'
}catch{
 $message=[string]$_.Exception.Message;if($token){$message=$message.Replace($token,'[redacted]')}
 $r.Reason=[regex]::Replace($message,'[A-Za-z0-9+/]{64,}={0,2}','[redacted]')
 Write-State 'Failed';exit 1
}finally{$token=$null;$argsForInstaller=$null;[Environment]::SetEnvironmentVariable('NCSTAGINGTOKEN',$null,'Process')}
