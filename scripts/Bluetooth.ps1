# Read radio and paired-endpoint state; never connect, pair, toggle, or inspect keys.
function Wait-WinRtRead {
    param($Operation,[Type]$ResultType,[int]$TimeoutMilliseconds=3000)
    if (-not $script:winRtAsTask) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $script:winRtAsTask=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and
            $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        } | Select-Object -First 1
    }
    $task=$script:winRtAsTask.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    if (-not $task.Wait($TimeoutMilliseconds)) { throw [TimeoutException]::new('Bluetooth state read timed out.') }
    return ,$task.Result
}

function Read-WinRtBluetoothRadios {
    [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
    $radios=Wait-WinRtRead ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    $states=@($radios | Where-Object { $_.Kind.ToString() -eq 'Bluetooth' } | ForEach-Object { $_.State.ToString() })
    $state='Unknown'
    if ($states.Count -gt 0) {
        if ('On' -in $states) { $state='On' }
        elseif (@($states | Where-Object { $_ -notin @('Off','Disabled') }).Count -eq 0) { $state='Off' }
    }
    [pscustomobject]@{ state=$state; radioStates=$states; exposedRadioCount=$states.Count; processBits=([IntPtr]::Size*8); note='空の列挙結果はBluetooth非搭載やオフの証明ではありません。' }
}

function Read-WinRtPairedEndpoints {
    param([ValidateSet('Classic','LE')][string]$Protocol)
    [Windows.Devices.Enumeration.DeviceInformation,Windows.Devices.Enumeration,ContentType=WindowsRuntime] | Out-Null
    if ($Protocol -eq 'Classic') {
        [Windows.Devices.Bluetooth.BluetoothDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
        $selector=[Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
    } else {
        [Windows.Devices.Bluetooth.BluetoothLEDevice,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
        $selector=[Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
    }
    $devices=Wait-WinRtRead ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selector,[string[]]@('System.Devices.Aep.IsConnected'),[Windows.Devices.Enumeration.DeviceInformationKind]::AssociationEndpoint)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    foreach ($device in $devices) {
        $connected=$null
        # WinRT maps are enumerable, but their PS5.1 indexer is unreliable.
        foreach ($property in $device.Properties) { if ($property.Key -eq 'System.Devices.Aep.IsConnected' -and $property.Value -is [bool]) { $connected=$property.Value } }
        [pscustomobject]@{ rawId=$device.Id; connected=$connected }
    }
}

function Get-PairedBluetoothEndpoints {
    param([string]$Protocol,[string]$Salt)
    $endpoints=@(Read-WinRtPairedEndpoints -Protocol $Protocol | ForEach-Object {
        [pscustomobject]@{ ref=Get-AnonymousDeviceRef ([string]$_.rawId) $Salt; protocol=$Protocol; connected=$_.connected }
    })
    [pscustomobject]@{
        endpoints=$endpoints; pairedEndpointCount=$endpoints.Count
        knownConnectedCount=@($endpoints | Where-Object { $_.connected -eq $true }).Count
        unknownConnectionCount=@($endpoints | Where-Object { $null -eq $_.connected }).Count
        note='ペアリング済み接続エンドポイント。Classic/LEで物理機器が重複する場合あり。接続中は通信量・キー入力中を意味しません。'
    }
}

function Get-BluetoothState {
    param([string]$Salt)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $state=[pscustomobject]@{
        capturedUtc=[DateTime]::UtcNow.ToString('o')
        radio=Invoke-CollectionSection { Read-WinRtBluetoothRadios }
        classic=Invoke-CollectionSection { Get-PairedBluetoothEndpoints 'Classic' $Salt }
        lowEnergy=Invoke-CollectionSection { Get-PairedBluetoothEndpoints 'LE' $Salt }
        durationMilliseconds=0
        scope='無線とWindowsのペアリング済み接続状態。電波強度・パケット数・再送回数・キー内容は取得しません。PnP Status=OKを接続中と扱いません。'
    }
    $clock.Stop(); $state.durationMilliseconds=$clock.ElapsedMilliseconds
    return $state
}

function Get-BluetoothStateSummary {
    param($State)
    $radio='Unknown'; $count=$null
    if ($State.radio.status -eq 'collected' -and $State.radio.data.state -in @('On','Off')) { $radio=$State.radio.data.state }
    if ($State.classic.status -eq 'collected' -and $State.lowEnergy.status -eq 'collected' -and
        $State.classic.data.unknownConnectionCount -eq 0 -and $State.lowEnergy.data.unknownConnectionCount -eq 0) {
        $count=[int]$State.classic.data.knownConnectedCount + [int]$State.lowEnergy.data.knownConnectedCount
    }
    [pscustomobject]@{ radioState=$radio; connectedEndpointCount=$count }
}

function Get-BluetoothDeviceInventory {
    param([string]$Salt)
    $devices=@(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $drivers=@(Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 20 -ErrorAction Stop)
    $byId=@{}; $byDriver=@{}; $parents=@{}; $selected=@{}; $parentLookupFailures=0
    foreach ($device in $devices) { $byId[$device.InstanceId]=$device }
    foreach ($driver in $drivers) { if ($driver.DeviceID) { $byDriver[$driver.DeviceID]=$driver } }
    foreach ($device in @($devices | Where-Object { $_.Class -in @('Bluetooth','Keyboard','HIDClass') -or $_.InstanceId -match '^BTH' })) {
        $chain=New-Object 'System.Collections.Generic.List[object]'
        $current=$device; $isBluetooth=($device.Class -eq 'Bluetooth' -or $device.InstanceId -match '^BTH'); $seen=@{}
        for ($depth=0; $depth -lt 8 -and $current -and -not $seen.ContainsKey($current.InstanceId); $depth++) {
            $id=[string]$current.InstanceId; $seen[$id]=$true; $chain.Add($current)
            if ($current.Class -eq 'Bluetooth' -or $id -match '^BTH') { $isBluetooth=$true }
            if (-not $parents.ContainsKey($id)) {
                $parent=$null
                try { $parent=[string](Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data } catch { $parentLookupFailures++ }
                $parents[$id]=$parent
            }
            $parent=$parents[$id]
            if ($parent -and $byId.ContainsKey($parent)) { $current=$byId[$parent] } else { $current=$null }
        }
        if ($isBluetooth) { foreach ($entry in $chain) { $selected[$entry.InstanceId]=$entry } }
    }
    $rows=@(foreach ($id in @($selected.Keys | Sort-Object)) {
        $device=$selected[$id]; $driver=$null
        if ($byDriver.ContainsKey($id)) {
            $d=$byDriver[$id]
            $driver=[pscustomobject]@{ provider=$d.DriverProviderName; version=$d.DriverVersion; date=if ($d.DriverDate) { ([DateTime]$d.DriverDate).ToString('yyyy-MM-dd') } else { $null }; inf=$d.InfName }
        }
        $reference=Get-AnonymousDeviceRef $id $Salt
        $adapter=($device.Class -eq 'Bluetooth' -and $id -match '^(USB|PCI|ACPI)\\')
        $productId=$null
        if ($id -match '^USB\\(VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { $productId='USB\' + $Matches[1] }
        elseif ($id -match '^PCI\\(VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $productId='PCI\' + $Matches[1] }
        [pscustomobject]@{
            ref=$reference; parentRef=if ($parents[$id]) { Get-AnonymousDeviceRef $parents[$id] $Salt } else { $null }
            class=$device.Class; role=if ($adapter) { 'adapter' } elseif ($device.Class -in @('Keyboard','HIDClass')) { 'inputNode' } else { 'bluetoothOrAncestorNode' }
            label=if ($adapter) { 'Bluetooth adapter ' + $reference } else { [string]$device.Class + ' ' + $reference }
            pnpStatus=$device.Status; productId=$productId; driver=$driver
        }
    })
    [pscustomobject]@{ devices=$rows; parentLookupFailures=$parentLookupFailures; note='Bluetoothと関連入力ノード・親。PnP状態は接続状態ではありません。親情報の取得失敗時は関連を特定できない場合があります。機器名・MAC・生インスタンスIDは保存しません。未接続機器の登録はペアリング済み情報を参照。' }
}

function Start-BluetoothMonitor {
    param([string]$Salt,[string]$InventoryPath,[int]$IntervalSeconds=10,[int]$MaxSamples=720)
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $cancel=New-Object Threading.ManualResetEvent($false)
    $worker=[PowerShell]::Create()
    [void]$worker.AddScript({
        param($InventoryPath,$CorePath,$Salt,$Queue,$Cancel,$Interval,$Limit)
        $ErrorActionPreference='Stop'
        . $CorePath
        . $InventoryPath
        for ($i=0; $i -lt $Limit -and -not $Cancel.WaitOne(0); $i++) {
            try { $Queue.Enqueue((Get-BluetoothState $Salt)) }
            catch { $Queue.Enqueue([pscustomobject]@{ capturedUtc=[DateTime]::UtcNow.ToString('o'); errorType=$_.Exception.GetType().Name; scope='取得失敗。無線オフや接続なしとは判定しません。' }) }
            if ($Cancel.WaitOne($Interval*1000)) { break }
        }
    }).AddArgument($InventoryPath).AddArgument((Join-Path $PSScriptRoot 'Core.ps1')).AddArgument($Salt).AddArgument($queue).AddArgument($cancel).AddArgument($IntervalSeconds).AddArgument($MaxSamples)
    [pscustomobject]@{ worker=$worker; handle=$worker.BeginInvoke(); queue=$queue; cancel=$cancel; limit=$MaxSamples }
}
