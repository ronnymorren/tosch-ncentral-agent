@echo off
rem REVIEW CANDIDATE: deliberately not runnable until reviewed values are filled in.
rem NCKEY must already be present in the calling session. Never put a key in this file.
setlocal
set "RC=1"
set "SCRIPT_COMMIT=5f03fd7218db385308d42e464d90c1f0f8d5e9e4"
set "SCRIPT_SHA256=39388db163ff0e9c410c62cbf491df673b5fe3bee567344117f6f80d1984d6ac"
set "INSTALLER_SHA256=3f37f8b4535fa75e9a637fd720c15f116adce8b4c236045ae7635b5b66992fce"
rem Controller supplies validated hostname, serial and ApplianceID as three arguments.
set "DEVICE_NAME=%~1"
set "DEVICE_SERIAL=%~2"
set "APPLIANCE_ID=%~3"
set "WORK=C:\ProgramData\Tosch\AgentMaintenance"
if "%SCRIPT_COMMIT%"=="REVIEWED_COMMIT" goto notready
if "%INSTALLER_SHA256%"=="REVIEWED_INSTALLER_SHA256" goto notready
if "%DEVICE_NAME%"=="" goto notready
if "%DEVICE_SERIAL%"=="" goto notready
if "%APPLIANCE_ID%"=="" goto notready
if not defined NCKEY goto notready
whoami /user | findstr /c:"S-1-5-18" >nul
if errorlevel 1 goto finish
if not exist "C:\ProgramData\Tosch" mkdir "C:\ProgramData\Tosch"
fsutil reparsepoint query "C:\ProgramData\Tosch" >nul 2>&1
if not errorlevel 1 goto finish
if not exist "%WORK%" mkdir "%WORK%"
fsutil reparsepoint query "%WORK%" >nul 2>&1
if not errorlevel 1 goto finish
icacls "%WORK%" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" >nul
if errorlevel 1 goto finish
set "RUN=%WORK%\run-%RANDOM%-%RANDOM%"
if exist "%RUN%" goto finish
mkdir "%RUN%"
if errorlevel 1 goto finish
curl.exe --fail --silent --show-error --location --max-redirs 0 --connect-timeout 30 --max-time 120 --output "%RUN%\Upgrade-NcentralAgent.ps1" "https://raw.githubusercontent.com/ronnymorren/tosch-ncentral-agent/%SCRIPT_COMMIT%/Upgrade-NcentralAgent.ps1"
if errorlevel 1 goto finish
certutil -hashfile "%RUN%\Upgrade-NcentralAgent.ps1" SHA256 > "%RUN%\script-sha256.txt"
if errorlevel 1 goto finish
findstr /i /x /c:"%SCRIPT_SHA256%" "%RUN%\script-sha256.txt" >nul
if errorlevel 1 goto finish
rem Use normal execution policy. If policy blocks the script, stop and review it.
powershell.exe -NoProfile -File "%RUN%\Upgrade-NcentralAgent.ps1" -ExpectedComputerName "%DEVICE_NAME%" -ExpectedSerial "%DEVICE_SERIAL%" -ExpectedApplianceId "%APPLIANCE_ID%" -ExpectedInstallerSha256 "%INSTALLER_SHA256%"
set "RC=%ERRORLEVEL%"
goto finish
:notready
echo Reviewed commit, installer hash, device identity and runtime key are required. Nothing executed.
:finish
endlocal & set "NCKEY=" & exit /b %RC%



