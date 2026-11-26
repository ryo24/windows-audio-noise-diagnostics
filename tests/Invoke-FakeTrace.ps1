param([string]$SessionPath,[string]$TraceId,[switch]$FailSave,[switch]$ExitWithoutFinalState,[switch]$WaitForRelease,[switch]$IncludeUsb,[switch]$FailUsbStart,[switch]$FailUsbSave)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Core.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Inventory.ps1')
if($WaitForRelease){
    $release=Join-Path (Join-Path (Join-Path (Split-Path -Parent $SessionPath) 'traces') $TraceId) 'launch.release'
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while(-not (Test-Path -LiteralPath $release)){if([DateTime]::UtcNow -gt $deadline){exit 2};Start-Sleep -Milliseconds 50}
}
# Runs the real recorder state machine in a separate process, replacing WPR
# only. This never requests elevation or records any actual system activity.
function Get-UsbTraceProviders { @([pscustomobject]@{name='Microsoft-Windows-USB-USBXHCI';id=[guid]::Empty.ToString();keywords='0x8243';level=5}) }
$usbPath=Join-Path (Join-Path (Join-Path (Split-Path -Parent $SessionPath) 'traces') $TraceId) 'usb.etl'
$usbRunner={param($a);if($a[0] -eq 'create' -and $FailUsbStart){return 9};if($a[0] -eq 'stop'){if($FailUsbSave){return 12};[IO.File]::WriteAllText($usbPath,'Synthetic USB trace fixture')};return 0}
$state=Invoke-DetailedTrace -SessionPath $SessionPath -TraceId $TraceId -Seconds 30 -IncludeUsb:$IncludeUsb -UsbRunner $usbRunner -WprRunner {
    param($arguments)
    if($arguments[0] -eq '-start'){Start-Sleep -Milliseconds 800}
    if($arguments[0] -eq '-marker' -and $ExitWithoutFinalState){[Environment]::Exit(9)}
    if($arguments[0] -eq '-stop'){
        Start-Sleep -Milliseconds 1800
        if($FailSave){return 25}
        [IO.File]::WriteAllText($arguments[1],'Synthetic trace fixture; not a real ETL')
    }
    return 0
}
if($state.status -notin @('Completed','Cancelled')){exit 1}
