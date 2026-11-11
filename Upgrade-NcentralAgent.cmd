@echo off
rem Reviewed CMD route. No PowerShell script files, IEX, encoded code or policy changes.
rem NCKEY is runtime-only vendor activation-key data. Never put its value in this file.
setlocal DisableDelayedExpansion
set "RC=1"
set "EXPECTED_COMPUTER=%~1"
set "EXPECTED_SERIAL=%~2"
set "EXPECTED_APPLIANCE=%~3"
set "TARGET_VERSION=2026.4.1.26"
set "INSTALLER_SHA256=7ff03c5fd6ab8cafb981a4aa4c6cda37b8a0ae3996f88d09936d387de7719b85"
set "INSTALLER_BYTES=139808560"
if not defined EXPECTED_COMPUTER goto notready
if not defined EXPECTED_SERIAL goto notready
if not defined EXPECTED_APPLIANCE goto notready
if not defined NCKEY goto notready
powershell.exe -NoProfile -Command "try { if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') { exit 0 }; exit 1 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 goto notready
set "ROOT=C:\ProgramData\Tosch"
if not exist "%ROOT%" mkdir "%ROOT%"
fsutil reparsepoint query "%ROOT%" >nul 2>&1
if not errorlevel 1 goto notready
set "WORK=%ROOT%\AgentMaintenanceCmd"
if not exist "%WORK%" mkdir "%WORK%"
fsutil reparsepoint query "%WORK%" >nul 2>&1
if not errorlevel 1 goto notready
icacls "%WORK%" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" >nul
if errorlevel 1 goto notready
set "RUN=%WORK%\run-%RANDOM%-%RANDOM%"
if exist "%RUN%" goto notready
mkdir "%RUN%"
if errorlevel 1 goto notready
set "INSTALLER=%RUN%\WindowsAgentSetup.exe"
set "AGENT_CONFIG=C:\Program Files (x86)\N-able Technologies\Windows Agent\config\ApplianceConfig.xml"
set "AGENT_EXE=C:\Program Files (x86)\N-able Technologies\Windows Agent\bin\agent.exe"
rem Preflight is a transparent, normal PowerShell command, not a loaded script or policy bypass.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop';try{if($env:COMPUTERNAME -ine $env:EXPECTED_COMPUTER){throw 'Computer'};$serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim();if($serial -ne $env:EXPECTED_SERIAL){throw 'Serial'};if($env:EXPECTED_APPLIANCE -notmatch '^\d+$' -or $env:NCKEY -notmatch '^[A-Za-z0-9+/]+=*$'){throw 'Input'};if(!(Test-Path -LiteralPath $env:AGENT_CONFIG) -or !(Test-Path -LiteralPath $env:AGENT_EXE)){throw 'Existing agent missing'};$xs=[Xml.XmlReaderSettings]::new();$xs.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$xs.XmlResolver=$null;$xr=[Xml.XmlReader]::Create($env:AGENT_CONFIG,$xs);try{$x=[Xml.XmlDocument]::new();$x.XmlResolver=$null;$x.Load($xr)}finally{$xr.Dispose()};$id=[string]$x.ApplianceConfig.ApplianceID;if($id -ne $env:EXPECTED_APPLIANCE){throw 'Appliance'};$v=(Get-Item -LiteralPath $env:AGENT_EXE).VersionInfo.FileVersion.Trim();$k=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:NCKEY)).Split('|');if($k.Count -lt 4){throw 'Key format'};$address=if($k[0] -match '://'){$k[0]}else{'https://'+$k[0]};$u=[uri]$address;if(!$u.IsAbsoluteUri -or $u.Host -ine 'ncod691.n-able.com' -or $u.UserInfo -or $k[1] -ne $id){throw 'Key identity'};$b=[ordered]@{Computer=$env:COMPUTERNAME;Serial=$serial;ApplianceId=$id;VersionBefore=$v;BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')};[IO.File]::WriteAllText((Join-Path $env:RUN 'before.json'),($b|ConvertTo-Json -Compress));if([version]$v -ge [version]$env:TARGET_VERSION){[pscustomobject]@{Status='AlreadyCurrent';InstallerStarted=$false;VersionBefore=$v;VersionAfter=$v}|ConvertTo-Json -Compress;exit 10};$m=$null;$held=$false;try{try{$m=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{};if($m){$held=$m.WaitOne(0);if(!$held){throw 'MSI busy'}};if(@(Get-Process WindowsAgentSetup,WindowsProbeSetup -ErrorAction SilentlyContinue).Count){throw 'Setup busy'}}finally{if($held){$m.ReleaseMutex()};if($m){$m.Dispose()}};[pscustomobject]@{Phase='PreflightVerified';VersionBefore=$v}|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{Status='PreflightRefused';InstallerStarted=$false;Reason='Identity, existing agent, key or installer-idle check failed. No installer started.'}|ConvertTo-Json -Compress;exit 1}finally{$k=$null;$env:NCKEY=$null}"
set "RC=%ERRORLEVEL%"
if "%RC%"=="10" goto finish
if not "%RC%"=="0" goto finish
curl.exe --fail --silent --show-error --location --max-redirs 0 --connect-timeout 30 --max-time 600 --output "%INSTALLER%.partial" "https://ncod691.n-able.com/download/2026.4.1.26/winnt/N-central/WindowsAgentSetup.exe"
if errorlevel 1 goto downloadfailed
rem Verify exact bytes, SHA-256, valid publisher signature, unchanged identity/version and idle installer immediately before launch.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop';try{$f=Get-Item -LiteralPath ($env:INSTALLER+'.partial');if($f.Attributes -band [IO.FileAttributes]::ReparsePoint -or $f.Length -ne [long]$env:INSTALLER_BYTES){throw 'Length/path'};if((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -ine $env:INSTALLER_SHA256){throw 'Hash'};$sig=Get-AuthenticodeSignature -LiteralPath $f.FullName;if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch ('(?i)(?:^|,\s*)O='+[char]34+'?N-ABLE TECHNOLOGIES LTD'+[char]34+'?(?:,|$)')){throw 'Signature'};$b=Get-Content -LiteralPath (Join-Path $env:RUN 'before.json') -Raw|ConvertFrom-Json;if($env:COMPUTERNAME -ine $b.Computer -or (Get-CimInstance Win32_BIOS).SerialNumber.Trim() -ne $b.Serial){throw 'Identity'};$xs=[Xml.XmlReaderSettings]::new();$xs.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$xs.XmlResolver=$null;$xr=[Xml.XmlReader]::Create($env:AGENT_CONFIG,$xs);try{$x=[Xml.XmlDocument]::new();$x.XmlResolver=$null;$x.Load($xr)}finally{$xr.Dispose()};if([string]$x.ApplianceConfig.ApplianceID -ne $b.ApplianceId -or (Get-Item -LiteralPath $env:AGENT_EXE).VersionInfo.FileVersion.Trim() -ne $b.VersionBefore){throw 'Concurrent change'};$m=$null;$held=$false;try{try{$m=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{};if($m){$held=$m.WaitOne(0);if(!$held){throw 'MSI busy'}};if(@(Get-Process WindowsAgentSetup,WindowsProbeSetup -ErrorAction SilentlyContinue).Count){throw 'Setup busy'}}finally{if($held){$m.ReleaseMutex()};if($m){$m.Dispose()}};Move-Item -LiteralPath $f.FullName -Destination $env:INSTALLER;[pscustomobject]@{Phase='InstallerVerified'}|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{Status='ValidationRefused';InstallerStarted=$false;Reason='Download integrity, signature, identity or installer-idle check failed. No installer started.'}|ConvertTo-Json -Compress;exit 1}"
if errorlevel 1 goto failed
rem Launch only the verified vendor installer; wait at most 15 minutes. Never kill it or launch another.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop';$started=$false;try{$installerArguments='/s /v'+[char]34+' /qn AGENTACTIVATIONKEY='+$env:NCKEY+' REBOOT=ReallySuppress'+[char]34;$p=Start-Process -FilePath $env:INSTALLER -ArgumentList $installerArguments -PassThru;$started=$true;$env:NCKEY=$null;[IO.File]::WriteAllText((Join-Path $env:RUN 'installer-pid.txt'),[string]$p.Id);if(!$p.WaitForExit(900000)){[pscustomobject]@{Status='UnknownInstallerOutcome';InstallerStarted=$true;Reason='15 minute deadline. Do not kill, reboot or start another installer.'}|ConvertTo-Json -Compress;exit 3};$p.Refresh();$code=$p.ExitCode;[IO.File]::WriteAllText((Join-Path $env:RUN 'installer-exit.txt'),[string]$code);if($code -notin @(0,3010)){[pscustomobject]@{Status='InstallerFailed';InstallerStarted=$true;InstallerExitCode=$code}|ConvertTo-Json -Compress;exit 1};[pscustomobject]@{Phase='InstallerExited';InstallerExitCode=$code}|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject]@{Status='UnknownInstallerOutcome';InstallerStarted=$started;Reason='Launcher failed. Independently inspect current state before retry; no second installer.'}|ConvertTo-Json -Compress;exit 3}finally{$installerArguments=$null;$env:NCKEY=$null}"
set "RC=%ERRORLEVEL%"
set "NCKEY="
if not "%RC%"=="0" goto finish
rem Separate read-only postcheck, tolerating temporarily absent/writing agent files for at most 10 minutes.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop';try{$b=Get-Content -LiteralPath (Join-Path $env:RUN 'before.json') -Raw|ConvertFrom-Json;$code=[int](Get-Content -LiteralPath (Join-Path $env:RUN 'installer-exit.txt') -Raw);$deadline=(Get-Date).AddMinutes(10);$ok=$false;$v=$null;$svc=$null;do{if((Test-Path -LiteralPath $env:AGENT_CONFIG) -and (Test-Path -LiteralPath $env:AGENT_EXE)){try{$xs=[Xml.XmlReaderSettings]::new();$xs.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$xs.XmlResolver=$null;$xr=[Xml.XmlReader]::Create($env:AGENT_CONFIG,$xs);try{$x=[Xml.XmlDocument]::new();$x.XmlResolver=$null;$x.Load($xr)}finally{$xr.Dispose()};if([string]$x.ApplianceConfig.ApplianceID -ne $b.ApplianceId){throw [InvalidOperationException]::new('Identity changed')};$v=(Get-Item -LiteralPath $env:AGENT_EXE).VersionInfo.FileVersion.Trim();$svc=Get-Service 'Windows Agent Service';if($v -eq $env:TARGET_VERSION -and $svc.Status -eq 'Running'){$ok=$true;break}}catch [IO.IOException]{}catch [Xml.XmlException]{}};Start-Sleep -Seconds 10}while((Get-Date) -lt $deadline);if($env:COMPUTERNAME -ine $b.Computer -or (Get-CimInstance Win32_BIOS).SerialNumber.Trim() -ne $b.Serial){throw 'Post identity'};$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');$status=if($code -eq 3010){'PendingReboot'}elseif($ok){'LocalVerifiedWaitCloud'}else{'LocalVerificationIncomplete'};[pscustomobject][ordered]@{Status=$status;Computer=$env:COMPUTERNAME;Serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim();ApplianceId=[string]$x.ApplianceConfig.ApplianceID;VersionBefore=$b.VersionBefore;VersionAfter=$v;InstallerExitCode=$code;InstallerStarted=$true;RebootRequired=($code -eq 3010);BootUnchanged=($boot -eq $b.BootUtc);ServiceState=[string]$svc.Status;Reason='Independent local/cloud/customer/site/heartbeat/duplicate checks still required. No reboot performed.'}|ConvertTo-Json -Compress;if($code -eq 3010){exit 3010};if(!$ok){exit 1};exit 0}catch{[pscustomobject]@{Status='LocalVerificationIncomplete';InstallerStarted=$true;Reason='Read-only postcheck failed. Inspect independently; do not repeat installation.'}|ConvertTo-Json -Compress;exit 1}"
set "RC=%ERRORLEVEL%"
goto finish
:downloadfailed
echo {"Status":"DownloadFailed","InstallerStarted":false,"Reason":"Single bounded curl download failed. No retry or installation."}
set "RC=1"
goto finish
:failed
set "RC=1"
goto finish
:notready
echo {"Status":"PreflightRefused","InstallerStarted":false,"Reason":"Required runtime identity, key, SYSTEM account or protected workspace missing."}
set "RC=1"
:finish
endlocal & set "NCKEY=" & exit /b %RC%
