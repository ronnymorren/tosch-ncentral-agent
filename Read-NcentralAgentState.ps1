# Read-only postcheck. Run as a normal script file under the existing policy.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][string]$ExpectedSerial,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$ExpectedApplianceId
)
$ErrorActionPreference='Stop'
try {
    if($env:COMPUTERNAME -ine $ExpectedComputerName){throw 'Computer mismatch'}
    $serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    if($serial -ne $ExpectedSerial){throw 'Serial mismatch'}
    $folder='C:\Program Files (x86)\N-able Technologies\Windows Agent'
    $settings=[Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create((Join-Path $folder 'config\ApplianceConfig.xml'),$settings)
    try {$xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose()}
    $id=[string]$xml.ApplianceConfig.ApplianceID
    if($id -ne $ExpectedApplianceId){throw 'ApplianceID mismatch'}
    $mutex=$null;$held=$false;$busy=$false
    try {
        try {$mutex=[Threading.Mutex]::OpenExisting('Global\_MSIExecute')}
        catch [Threading.WaitHandleCannotBeOpenedException] {}
        if($mutex){$held=$mutex.WaitOne(0);$busy=!$held}
    }finally{if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
    [pscustomobject][ordered]@{
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
        BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        Computer=$env:COMPUTERNAME
        Serial=$serial
        ApplianceID=$id
        AgentVersion=(Get-Item -LiteralPath (Join-Path $folder 'bin\agent.exe')).VersionInfo.FileVersion.Trim()
        ServiceState=[string](Get-Service 'Windows Agent Service').Status
        MsiBusy=$busy
        SetupRunning=(@(Get-Process WindowsAgentSetup -ErrorAction SilentlyContinue).Count -gt 0)
    }|ConvertTo-Json -Compress
}catch{
    [pscustomobject]@{Postcheck='Failed';Computer=$env:COMPUTERNAME;Reason='Read-only identity/version/service check failed; inspect separately without disclosing configuration.'}|ConvertTo-Json -Compress
    exit 1
}
