# LT-Bert orphan recovery candidate. Static review only until explicitly launched remotely.
# No activation key, policy override, uninstall, config deletion or automatic reboot.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedComputerName,[Parameter(Mandatory)][string]$ExpectedSerial,[Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$ExpectedOldApplianceId)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$token=[Environment]::GetEnvironmentVariable('NCSTAGINGTOKEN','Process')
[Environment]::SetEnvironmentVariable('NCSTAGINGTOKEN',$null,'Process')
$root='C:\Program Files (x86)\N-able Technologies\Windows Agent'
$config=Join-Path $root 'config\ApplianceConfig.xml'
$exe=Join-Path $root 'bin\agent.exe'
$target='2026.4.0.31'
$r=[ordered]@{Status='Failed';Computer=$env:COMPUTERNAME;Serial=$null;OldApplianceId=$null;NewApplianceId=$null;VersionBefore=$null;VersionAfter=$null;InstallerStarted=$false;InstallerExitCode=$null;RebootRequired=$false;BootUnchanged=$null;ServiceState=$null;RequestedCustomerId=653;CloudVerified=$false;Reason=$null}
function Read-Identity {
 foreach($p in @($root,(Join-Path $root 'config'),(Join-Path $root 'bin'),$config,$exe)) {
  if(!(Test-Path -LiteralPath $p)){throw 'Existing orphan agent missing; this is not a new-install script.'}
  if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Agent path is a reparse point.'}
 }
 $s=[Xml.XmlReaderSettings]::new();$s.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$s.XmlResolver=$null
 $reader=[Xml.XmlReader]::Create($config,$s)
 try{$d=[Xml.XmlDocument]::new();$d.XmlResolver=$null;$d.Load($reader)}finally{$reader.Dispose()}
 $ids=@($d.SelectNodes('//*')|Where-Object LocalName -eq 'ApplianceID')
 $urls=@($d.SelectNodes('//*')|Where-Object LocalName -eq 'URL')
 if($ids.Count -ne 1 -or $urls.Count -ne 1){throw 'Ambiguous agent configuration.'}
 # Vendor configuration is encoded DATA, never executable code.
 $value=[string]$urls[0].InnerText
 if($value -notmatch '^https://'){$value=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))}
 $uri=[Uri]$value
 if($uri.Scheme -ne 'https' -or $uri.Host -ine 'ncod691.n-able.com' -or $uri.Port -ne 443 -or $uri.UserInfo){throw 'Existing server binding mismatch.'}
 [pscustomobject]@{ApplianceId=[string]$ids[0].InnerText;Version=(Get-Item -LiteralPath $exe).VersionInfo.FileVersion.Trim()}
}
function Assert-Idle {
 $m=$null;$held=$false
 try{try{$m=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{}
 if($m){$held=$m.WaitOne(0);if(!$held){throw 'Windows Installer busy; skip.'}}}
 finally{if($held){$m.ReleaseMutex()};if($m){$m.Dispose()}}
 if(Get-Process -Name WindowsAgentSetup,WindowsProbeSetup -ErrorAction SilentlyContinue){throw 'Agent or probe setup already running.'}
}
try {
 if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'SYSTEM required.'}
 if(!$token -or $token -notmatch '^[A-Za-z0-9_-]{12,}$'){throw 'Staging token missing or invalid.'}
 if($env:COMPUTERNAME -ine $ExpectedComputerName){throw 'Hostname mismatch.'}
 $r.Serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim()
 if($r.Serial -cne $ExpectedSerial){throw 'Serial mismatch.'}
 $before=Read-Identity;$r.OldApplianceId=$before.ApplianceId;$r.VersionBefore=$before.Version
 if($before.ApplianceId -ne $ExpectedOldApplianceId){throw 'Old ApplianceID mismatch.'}
 if([version]$before.Version -ge [version]$target){throw 'Agent already current; no recovery started.'}
 $service=Get-Service -Name 'Windows Agent Service'
 if($service.Status -ne 'Stopped'){throw 'Existing agent is not stopped; re-evaluate before recovery.'}
 Assert-Idle
 $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
 $work='C:\ProgramData\Tosch\AgentMaintenance'
 foreach($p in @('C:\ProgramData','C:\ProgramData\Tosch',$work)){
  if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Work path is a reparse point.'}}
  else{New-Item -ItemType Directory -Path $p|Out-Null}
 }
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit, ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $work -AclObject $acl
 $installer=Join-Path $work ('WindowsAgentSetup-recovery-'+[Guid]::NewGuid().ToString('N')+'.exe')
 $partial=$installer+'.partial'
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 Invoke-WebRequest -Uri 'https://ncod691.n-able.com/download/2026.4.0.31/winnt/N-central/WindowsAgentSetup.exe' -OutFile $partial -UseBasicParsing -TimeoutSec 600 -MaximumRedirection 0
 if((Get-Item -LiteralPath $partial).Length -ne 139556088){throw 'Unexpected installer length.'}
 if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine '3f37f8b4535fa75e9a637fd720c15f116adce8b4c236045ae7635b5b66992fce'){throw 'Installer hash mismatch.'}
 $signature=Get-AuthenticodeSignature -LiteralPath $partial
 if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(?:^|,\s*)O="?N-ABLE TECHNOLOGIES LTD"?(?:,|$)'){throw 'Installer signature/publisher invalid.'}
 Move-Item -LiteralPath $partial -Destination $installer
 $latest=Read-Identity
 if($latest.ApplianceId -ne $ExpectedOldApplianceId -or $latest.Version -ne $before.Version -or (Get-Service -Name 'Windows Agent Service').Status -ne 'Stopped'){throw 'Agent changed before launch.'}
 if($env:COMPUTERNAME -ine $ExpectedComputerName -or (Get-CimInstance Win32_BIOS).SerialNumber.Trim() -cne $ExpectedSerial){throw 'Identity changed before launch.'}
 Assert-Idle
 $argsForInstaller='/s /v" /qn CUSTOMERID=653 CUSTOMERSPECIFIC=1 REGISTRATION_TOKEN='+$token+' SERVERPROTOCOL=HTTPS SERVERADDRESS=ncod691.n-able.com SERVERPORT=443 REBOOT=ReallySuppress "'
 $process=Start-Process -FilePath $installer -ArgumentList $argsForInstaller -PassThru
 $r.InstallerStarted=$true
 if(!$process.WaitForExit(900000)){$r.Status='UnknownInstallerOutcome';throw 'Installer timeout; do not kill or retry.'}
 $process.Refresh();$r.InstallerExitCode=$process.ExitCode
 if($process.ExitCode -notin @(0,3010)){throw ('Installer exit '+$process.ExitCode)}
 $r.RebootRequired=$process.ExitCode -eq 3010
 $deadline=(Get-Date).AddMinutes(10)
 do {
  $after=$null
  try{$after=Read-Identity}catch [IO.IOException]{}catch [Xml.XmlException]{}catch{if($_.Exception.Message -ne 'Existing orphan agent missing; this is not a new-install script.'){throw}}
  $service=Get-Service -Name 'Windows Agent Service' -ErrorAction SilentlyContinue
  if($after -and $after.Version -eq $target -and $service.Status -eq 'Running'){break}
  Start-Sleep -Seconds 10
 }while((Get-Date) -lt $deadline)
 $r.NewApplianceId=$after.ApplianceId;$r.VersionAfter=$after.Version;$r.ServiceState=[string]$service.Status
 $r.BootUnchanged=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') -eq $boot
 $r.Status=if($r.RebootRequired){'PendingReboot'}elseif($after.Version -eq $target -and $service.Status -eq 'Running'){'LocalVerifiedWaitStagingCloud'}else{'LocalVerificationIncomplete'}
 $r.Reason='Cloud customer 653, identity, serial uniqueness and fresh check-in must be independently verified before any move; requested customer is not proof.'
}catch{
 if($r.Status -ne 'UnknownInstallerOutcome'){$r.Status='Failed'}
 $message=[string]$_.Exception.Message;if($token){$message=$message.Replace($token,'[redacted]')}
 $r.Reason=[regex]::Replace($message,'[A-Za-z0-9+/]{64,}={0,2}','[redacted]')
}finally{$token=$null;$argsForInstaller=$null;[Environment]::SetEnvironmentVariable('NCSTAGINGTOKEN',$null,'Process')}
$r|ConvertTo-Json -Compress
if($r.Status -eq 'PendingReboot'){exit 3010}
if($r.Status -eq 'LocalVerifiedWaitStagingCloud'){exit 0}
exit 1
