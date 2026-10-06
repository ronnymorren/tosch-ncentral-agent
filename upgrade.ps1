# Tosch - N-central agent UPGRADE in place (keeps the device at its own customer/site)
# Used from Sophos Live Response, with the device's own activation key
# (N-central: device > Settings > Local Agent > Get Activation Key):
#   powershell -ep bypass -c "$env:NCKEY='<key>'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/ronnymorren/tosch-ncentral-agent/main/upgrade.ps1 | iex"
# Safety: aborts unless the key belongs to THIS device (ApplianceID in the key = local ApplianceID)
# and the key points to ncod691. Never installs a new registration. Never prints the key.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Server  = 'ncod691.n-able.com'
$Url     = "https://$Server/download/current/winnt/N-central/WindowsAgentSetup.exe"
$Dir     = 'C:\temp'
$Setup   = Join-Path $Dir 'WindowsAgentSetup.exe'
$AgentDir = 'C:\Program Files (x86)\N-able Technologies\Windows Agent'
$CfgFile = Join-Path $AgentDir 'config\ApplianceConfig.xml'
$AgentExe = Join-Path $AgentDir 'bin\agent.exe'

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }
function Get-ApplianceId { ([xml](Get-Content $CfgFile -Raw)).ApplianceConfig.ApplianceID }
function Get-AgentVersion { if (Test-Path $AgentExe) { (Get-Item $AgentExe).VersionInfo.FileVersion } else { '' } }

try {
    $key = $env:NCKEY
    Remove-Item Env:\NCKEY -ErrorAction SilentlyContinue
    if (-not $key) { throw 'Geen activation key meegegeven (NCKEY).' }
    if (-not (Test-Path $CfgFile)) { throw 'Geen bestaande agent gevonden (ApplianceConfig.xml ontbreekt). Dit script upgradet alleen.' }

    $idBefore  = Get-ApplianceId
    $verBefore = Get-AgentVersion
    if ($idBefore -notmatch '^\d+$' -or [int64]$idBefore -le 0) { throw "Ongeldige lokale ApplianceID: $idBefore" }
    Say "Huidig: ApplianceID $idBefore, versie $verBefore"

    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($key))
    $parts = $decoded.Split('|')
    if ($parts.Count -lt 4) { throw 'Activation key heeft onverwacht formaat.' }
    if ($parts[0] -notmatch [regex]::Escape($Server)) { throw 'Activation key wijst niet naar ncod691.' }
    if ($parts[1] -ne $idBefore) { throw "Activation key hoort bij ApplianceID $($parts[1]), dit device is $idBefore. Gestopt." }
    Say 'Activation key hoort bij dit device'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Say "Download $Url"
    Remove-Item $Setup -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $Setup -UseBasicParsing
    Say ("Downloaded {0:N0} bytes" -f (Get-Item $Setup).Length)

    $sig = Get-AuthenticodeSignature $Setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=N-ABLE TECHNOLOGIES LTD') {
        throw "Signature check failed: $($sig.Status) / $($sig.SignerCertificate.Subject)"
    }
    Say 'Signature OK'

    Say 'Start installer (upgrade met activation key)'
    $proc = Start-Process -FilePath $Setup -ArgumentList "/s /v`" /qn AGENTACTIVATIONKEY=$key`"" -PassThru
    if (-not $proc.WaitForExit(900000)) { Say 'Installer loopt na 15 minuten nog; service wordt toch gecontroleerd' }

    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 10
        $svc = Get-Service -Name 'Windows Agent Service' -ErrorAction SilentlyContinue
    } until (($svc -and $svc.Status -eq 'Running') -or (Get-Date) -gt $deadline)
    if (-not ($svc -and $svc.Status -eq 'Running')) { throw "Windows Agent Service draait niet na 10 minuten (status: $($svc.Status))" }

    $idAfter  = Get-ApplianceId
    $verAfter = Get-AgentVersion
    if ($idAfter -ne $idBefore) { throw "ApplianceID gewijzigd van $idBefore naar $idAfter. Controleer N-central!" }
    Say "OK: service draait, ApplianceID $idAfter ongewijzigd, versie $verBefore -> $verAfter"
}
catch {
    Say "FOUT: $($_.Exception.Message)"
}
