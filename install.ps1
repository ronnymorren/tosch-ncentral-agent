# Tosch - N-central agent (re)install
# Used from Sophos Live Response:
#   powershell -ep bypass -c "irm https://raw.githubusercontent.com/ronnymorren/tosch-ncentral-agent/main/install.ps1 | iex"
# The device registers in N-central under "Herinstallatie Site" (CUSTOMERID 653);
# move it to the right customer afterwards.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on

$Server  = 'ncod691.n-able.com'
$Url     = "https://$Server/download/current/winnt/N-central/WindowsAgentSetup.exe"
$Dir     = 'C:\temp'
$Setup   = Join-Path $Dir 'WindowsAgentSetup.exe'
$InstallArgs = '/s /v" /qn CUSTOMERID=653 CUSTOMERSPECIFIC=1 REGISTRATION_TOKEN=8b15ee1b-62d5-b8ed-b0cd-0220448af521 SERVERPROTOCOL=HTTPS SERVERADDRESS=ncod691.n-able.com SERVERPORT=443"'

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null

    Say "Download $Url"
    Remove-Item $Setup -Force -ErrorAction SilentlyContinue
    # No BITS: ncod691 does not support Range requests, so BITS cannot resume either.
    Invoke-WebRequest -Uri $Url -OutFile $Setup -UseBasicParsing
    Say ("Downloaded {0:N0} bytes" -f (Get-Item $Setup).Length)

    $sig = Get-AuthenticodeSignature $Setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=N-ABLE TECHNOLOGIES LTD') {
        throw "Signature check failed: $($sig.Status) / $($sig.SignerCertificate.Subject)"
    }
    Say "Signature OK: $($sig.SignerCertificate.Subject)"

    Say "Start installer"
    Start-Process -FilePath $Setup -ArgumentList $InstallArgs -Wait

    # The setup hands off to msiexec; wait for the agent service to come up.
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 10
        $svc = Get-Service -Name 'Windows Agent Service' -ErrorAction SilentlyContinue
    } until (($svc -and $svc.Status -eq 'Running') -or (Get-Date) -gt $deadline)

    if ($svc -and $svc.Status -eq 'Running') {
        Say "OK: Windows Agent Service running on $env:COMPUTERNAME"
    } else {
        throw "Windows Agent Service not running after 10 minutes (status: $($svc.Status))"
    }
}
catch {
    Say "FOUT: $($_.Exception.Message)"
}
