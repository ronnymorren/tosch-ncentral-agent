# Read-only probe inspection. No installation, downloads, secrets or service changes.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedComputerName,
    [Parameter(Mandatory)][string]$ExpectedSerial,
    [Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$ExpectedProbeApplianceId
)
$ErrorActionPreference='Stop'
try {
    if($env:COMPUTERNAME -ine $ExpectedComputerName){throw 'Computer mismatch'}
    $serial=(Get-CimInstance Win32_BIOS).SerialNumber.Trim()
    if($serial -ne $ExpectedSerial){throw 'Serial mismatch'}
    $names=@('Windows Software Probe Service','Windows Software Probe Maintenance Service','Windows Software Probe Syslog Service')
    $services=@(foreach($name in $names){
        $svc=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'")
        if(!$svc){throw 'Probe service missing'}
        [pscustomobject]@{Name=$name;State=[string]$svc.State;StartMode=[string]$svc.StartMode}
    })
    $main=Get-CimInstance Win32_Service -Filter "Name='Windows Software Probe Service'"
    $match=[regex]::Match([string]$main.PathName,'^\s*(?:"([^"]+\.exe)"|(.+?\.exe))(?:\s|$)')
    if(!$match.Success){throw 'Cannot identify service executable'}
    $exe=if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}
    $allowed=Join-Path ${env:ProgramFiles(x86)} 'N-able Technologies\Windows Software Probe'
    $allowed=[IO.Path]::GetFullPath($allowed).TrimEnd('\')+'\'
    $exe=[IO.Path]::GetFullPath($exe)
    if(!$exe.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected executable location'}
    $file=Get-Item -LiteralPath $exe
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Executable is a reparse point'}
    $version=$file.VersionInfo.FileVersion.Trim()
    if($version -notmatch '^\d+(\.\d+){3}$'){throw 'Unexpected version format'}
    $identity=$null;$identitySource=$null
    $candidates=@('config\ApplianceConfig.xml','config\ProbeConfig.xml')
    $existing=@()
    foreach($relative in $candidates){
        $path=Join-Path $allowed $relative
        if(!(Test-Path -LiteralPath $path)){continue}
        $existing+=$relative
        if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Configuration is a reparse point'}
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($path,$settings)
        try {$xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose()}
        $nodes=@($xml.SelectNodes("//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='applianceid']"))
        if($nodes.Count -eq 1 -and $nodes[0].InnerText.Trim() -match '^\d+$'){
            $found=$nodes[0].InnerText.Trim()
            if($identity -and $identity -ne $found){throw 'Conflicting probe identities'}
            $identity=$found;$identitySource=$relative
        }
    }
    $verified=$identity -eq $ExpectedProbeApplianceId
    [pscustomobject][ordered]@{
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Status=$(if($verified){'ReadOnlyVerified'}else{'IdentityUnverified'})
        Computer=$env:COMPUTERNAME;Serial=$serial
        BootUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        ProbeVersion=$version;ProbeApplianceID=$identity;ProbeIdentityVerified=$verified
        IdentitySource=$identitySource;ConfigurationCandidatesFound=$existing
        Executable=$exe;Services=$services
    }|ConvertTo-Json -Depth 5 -Compress
    if(!$verified){exit 2}
}catch{
    [pscustomobject][ordered]@{ObservedUtc=(Get-Date).ToUniversalTime().ToString('o');Status='Failed';Reason='Read-only probe inspection failed; no changes made. Configuration values and credentials are not disclosed.'}|ConvertTo-Json -Compress
    exit 1
}
