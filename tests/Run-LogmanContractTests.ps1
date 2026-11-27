$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1');. (Join-Path $root 'scripts/Inventory.ps1')
$directory=Join-Path (Join-Path $root 'test-output') ('logman-contract-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory)|Out-Null
# An unregistered random test provider records no actual USB traffic.
# Exercise the real Logman command and output naming, not a fixture runner.
$script:contractProvider=[guid]::NewGuid().ToString()
function Get-UsbTraceProviders {@([pscustomobject]@{name='InactiveContractProvider';id=$script:contractProvider;keywords='0x8243';level=5})}
$usb=[pscustomobject]@{instanceName=('AudioNoise-Contract-'+[guid]::NewGuid().ToString('N'));status='Starting';providers=@();startExitCode=$null;stopExitCode=$null;started=$null;ended=$null;bytes=0;sha256=$null;errorType=$null}
try {
    try{Start-UsbTrace $usb $directory}catch{
        if($usb.startExitCode -eq -2147024891 -or $usb.startExitCode -eq -2147023582){
            Write-Output 'PASS: Native Logman accepts direct-session arguments and reaches its privilege check; elevated file creation is not tested in this process.'
            return
        }
        throw ('Native Logman start failed with code '+$usb.startExitCode+'; argument/output contract is unverified.')
    }
    Stop-UsbTrace $usb $directory
    if($usb.status -ne 'Completed' -or $usb.bytes -le 0 -or $usb.sha256 -notmatch '^[0-9A-Fa-f]{64}$'){throw ('Native Logman did not save the exact usb.etl file: '+$usb.status+' / '+$usb.stopExitCode)}
    if(@(Get-ChildItem $directory -Filter '*.etl').Count -ne 1){throw 'Unexpected versioned or extra ETL files'}
    Write-Output 'PASS: Native Logman starts/stops its owned direct session and saves exact usb.etl with a hash using an inactive test provider; no real USB traffic is recorded.'
}finally{
    if($usb.status -in @('Recording','Stopping')){Stop-UsbTrace $usb $directory}
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($directory).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe contract cleanup'}
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
}
