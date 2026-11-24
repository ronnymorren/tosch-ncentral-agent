@echo off
rem REVIEW CANDIDATE. No execution until the published immutable commit is reviewed and pinned.
rem The payload itself permits only PLU-W-BROED / PC2598CH and staging customer 653.
rem NCSTAGINGTOKEN is supplied at runtime. Never put a token in this file.
setlocal
set "RC=1"
set "SCRIPT_COMMIT=b57d59e7917d520c4751e441f00117d53bfffb34"
set "SCRIPT_SHA256=a0f7d9ebe077de5fb397b712a9c7cbbcffb749c892cf16e1f0e70e96492754a4"
set "SCRIPT_FILE=Install-PLU-W-BROED653-build40-20261123.ps1"
set "WORK=C:\ProgramData\Tosch\AgentMaintenanceNewInstallBootstrap"
if "%SCRIPT_COMMIT%"=="REVIEWED_COMMIT" goto notready
if not defined NCSTAGINGTOKEN goto notready
powershell.exe -NoProfile -Command "try { if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { exit 1 }; if ($env:SCRIPT_COMMIT -cnotmatch '^[a-f0-9]{40}$' -or $env:SCRIPT_SHA256 -cnotmatch '^[a-f0-9]{64}$' -or $env:NCSTAGINGTOKEN -cnotmatch '^[A-Za-z0-9_-]{12,}$') { exit 1 }; exit 0 } catch { exit 1 }" >nul 2>&1
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
curl.exe --fail --silent --show-error --location --max-redirs 0 --connect-timeout 30 --max-time 120 --output "%RUN%\%SCRIPT_FILE%" "https://raw.githubusercontent.com/ronnymorren/tosch-ncentral-agent/%SCRIPT_COMMIT%/%SCRIPT_FILE%"
if errorlevel 1 goto finish
certutil -hashfile "%RUN%\%SCRIPT_FILE%" SHA256 > "%RUN%\script-sha256.txt"
if errorlevel 1 goto finish
findstr /i /x /c:"%SCRIPT_SHA256%" "%RUN%\script-sha256.txt" >nul
if errorlevel 1 goto finish
powershell.exe -NoProfile -File "%RUN%\%SCRIPT_FILE%"
set "RC=%ERRORLEVEL%"
goto finish
:notready
echo Reviewed immutable source and runtime staging token are required. Nothing executed.
:finish
endlocal & set "NCSTAGINGTOKEN=" & exit /b %RC%
