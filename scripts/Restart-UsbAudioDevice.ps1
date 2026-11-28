#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EndpointName,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$devices = @(Get-PnpDevice -PresentOnly)
$endpoints = @($devices | Where-Object {
    $_.Class -eq 'AudioEndpoint' -and
    $_.InstanceId -match '^SWD\\MMDEVAPI\\\{0\.0\.0\.' -and
    $_.FriendlyName -eq $EndpointName
})
if ($endpoints.Count -ne 1) {
    throw ('Expected one present playback endpoint named "{0}"; found {1}. Use the exact name from Device Manager.' -f $EndpointName, $endpoints.Count)
}

$deviceById = @{}
foreach ($device in $devices) {
    $deviceById[$device.InstanceId] = $device
}

$candidate = $endpoints[0]
$audioFunction = $null
$audioProperties = $null
$usbId = $null
$seen = @{}
while ($candidate -and -not $seen.ContainsKey($candidate.InstanceId)) {
    $seen[$candidate.InstanceId] = $true
    $properties = @{}
    foreach ($property in (Get-PnpDeviceProperty -InstanceId $candidate.InstanceId)) {
        $properties[$property.KeyName] = $property.Data
    }
    if ($candidate.Class -eq 'MEDIA' -and $candidate.InstanceId -match '^(USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4})&MI_[0-9A-F]{2}\\') {
        $audioFunction = $candidate
        $audioProperties = $properties
        $usbId = $Matches[1]
        break
    }
    $parentId = [string]$properties['DEVPKEY_Device_Parent']
    $candidate = $deviceById[$parentId]
}
if (-not $audioFunction) {
    throw 'The playback endpoint could not be traced to a present USB Media interface.'
}

$parentId = [string]$audioProperties['DEVPKEY_Device_Parent']
$composite = $deviceById[$parentId]
if (-not $composite -or $composite.Class -ne 'USB' -or
    -not $composite.InstanceId.StartsWith(($usbId + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The USB audio interface does not have a matching present USB composite parent.'
}
$service = (Get-PnpDeviceProperty -InstanceId $composite.InstanceId -KeyName 'DEVPKEY_Device_Service').Data
if ($service -ne 'usbccgp') {
    throw 'The USB parent does not use the Windows USB composite parent driver (usbccgp).'
}

[pscustomobject]@{
    PlaybackEndpoint       = $endpoints[0].FriendlyName
    AudioInterface         = $audioFunction.FriendlyName
    AudioHardwareIds       = $audioProperties['DEVPKEY_Device_HardwareIds'] -join ', '
    AudioDriverInf         = $audioProperties['DEVPKEY_Device_DriverInfPath']
    AudioDriverVersion     = $audioProperties['DEVPKEY_Device_DriverVersion']
    UsbCompositeParent     = $composite.FriendlyName
    ParentInstanceId       = $composite.InstanceId
    ParentService          = $service
} | Format-List | Out-Host

if (-not $Apply) {
    Write-Host 'Preview only. To restart this USB composite device, run with -Apply in an administrator PowerShell.'
    return
}

if ($PSCmdlet.ShouldProcess($composite.InstanceId, 'Restart this USB composite device and its functions')) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run with -Apply from an administrator PowerShell.'
    }

    & (Join-Path ([Environment]::SystemDirectory) 'pnputil.exe') /restart-device $composite.InstanceId
    $restartExitCode = $LASTEXITCODE
    if ($restartExitCode -ne 0) {
        throw "PnPUtil returned $restartExitCode. Check its output before taking further action."
    }
    Write-Host 'PnPUtil finished. Reselect the same output and check the original symptom.'
}
