@echo off
rem Independent read-only check. No PS1 files, policy changes, downloads or installation.
setlocal DisableDelayedExpansion
set "EXPECTED_COMPUTER=%~1"
set "EXPECTED_SERIAL=%~2"
set "EXPECTED_APPLIANCE=%~3"
if not defined EXPECTED_COMPUTER goto notready
if not defined EXPECTED_SERIAL goto notready
if not defined EXPECTED_APPLIANCE goto notready
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop';try{if($env:COMPUTERNAME -ine $env:EXPECTED_COMPUTER){throw 'Computer'};$serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim();if($serial -ne $env:EXPECTED_SERIAL){throw 'Serial'};$folder='C:\Program Files (x86)\N-able Technologies\Windows Agent';$settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$reader=[Xml.XmlReader]::Create((Join-Path $folder 'config\ApplianceConfig.xml'),$settings);try{$xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose()};$id=[string]$xml.ApplianceConfig.ApplianceID;if($id -ne $env:EXPECTED_APPLIANCE){throw 'Appliance'};$mutex=$null;$held=$false;$busy=$false;try{try{$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}catch [Threading.WaitHandleCannotBeOpenedException]{};if($mutex){$held=$mutex.WaitOne(0);$busy=!$held}}finally{if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}};[pscustomobject][ordered]@{ObservedUtc=(Get-Date).ToUniversalTime().ToString('o');BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');Computer=$env:COMPUTERNAME;Serial=$serial;ApplianceID=$id;AgentVersion=(Get-Item -LiteralPath (Join-Path $folder 'bin\agent.exe')).VersionInfo.FileVersion.Trim();ServiceState=[string](Get-Service 'Windows Agent Service').Status;MsiBusy=$busy;SetupRunning=(@(Get-Process WindowsAgentSetup,WindowsProbeSetup -ErrorAction SilentlyContinue).Count -gt 0)}|ConvertTo-Json -Compress;exit 0}catch{[pscustomobject][ordered]@{ObservedUtc=(Get-Date).ToUniversalTime().ToString('o');Postcheck='Failed';Reason='Independent read-only identity/version/service check failed; no configuration disclosed.'}|ConvertTo-Json -Compress;exit 1}"
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
:notready
echo {"Postcheck":"Failed","Reason":"Expected identity arguments missing."}
endlocal & exit /b 1
