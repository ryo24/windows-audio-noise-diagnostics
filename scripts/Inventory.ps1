. (Join-Path $PSScriptRoot 'Bluetooth.ps1')

function Invoke-CollectionSection {
    param([scriptblock]$Read)
    try { [pscustomobject]@{ status='collected'; data=(& $Read); errorType=$null } }
    catch { [pscustomobject]@{ status='unavailable'; data=$null; errorType=$_.Exception.GetType().Name } }
}

function Get-AnonymousDeviceRef {
    param([string]$Id, [string]$Salt)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Salt + $Id.ToUpperInvariant())))).Replace('-','').Substring(0,16) }
    finally { $sha.Dispose() }
}

function Get-DefaultEndpoint {
    if (-not ('AudioNoiseDiagnostics.Endpoint' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'AudioEndpoint.cs') -ErrorAction Stop }
    $info = [AudioNoiseDiagnostics.Endpoint]::Read()
    $name = '未取得'
    if ($info.Id -match '(\{[0-9a-fA-F-]+\})$') {
        $properties = Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\' + $Matches[1] + '\Properties') -ErrorAction Stop
        $nameProperty = $properties.PSObject.Properties['{a45c254e-df1c-4efd-8020-67d146a850e0},14']
        if ($nameProperty) { $name = [string]$nameProperty.Value }
    }
    [pscustomobject]@{ name=$name; sampleRate=$info.SampleRate; channels=$info.Channels; containerBits=$info.ContainerBits; note=$info.FormatNote; scope='既定のマルチメディア出力。アプリ個別の出力先は手動で確認してください。' }
}

function Get-AudioDeviceInventory {
    param([string]$Salt)
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 20 -ErrorAction Stop)
    $byId = @{}
    foreach ($device in $devices) { $byId[$device.InstanceId] = $device }
    $driverById = @{}
    foreach ($driver in $drivers) { if ($driver.DeviceID) { $driverById[$driver.DeviceID] = $driver } }
    $selected = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $roots = @($devices | Where-Object { $_.Class -in @('MEDIA','AudioEndpoint') })
    foreach ($root in $roots) {
        $current = $root
        for ($depth=0; $depth -lt 8 -and $null -ne $current; $depth++) {
            $id = [string]$current.InstanceId
            if ($seen.ContainsKey($id)) { break }
            $seen[$id] = $true
            $parentId = $null
            $hardwareIds = @()
            $propertyStatus = 'collected'
            try {
                $props = @(Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent','DEVPKEY_Device_HardwareIds' -ErrorAction Stop)
                $parentProp = $props | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_Parent' }
                if ($parentProp) { $parentId = [string]$parentProp.Data }
                $hardwareProp = $props | Where-Object { $_.KeyName -eq 'DEVPKEY_Device_HardwareIds' }
                if ($hardwareProp) { $hardwareIds = @($hardwareProp.Data | Where-Object { $_ -match '^(USB\\(VID_|Class_)|HDAUDIO\\|INTELAUDIO\\|PCI\\VEN_)' }) }
            } catch { $propertyStatus='partial' }
            $driverInfo = $null
            if ($driverById.ContainsKey($id)) {
                $driver = $driverById[$id]
                $driverInfo = [pscustomobject]@{ provider=$driver.DriverProviderName; version=$driver.DriverVersion; date=if ($driver.DriverDate) { ([DateTime]$driver.DriverDate).ToString('yyyy-MM-dd') } else { $null }; inf=$driver.InfName; signed=$driver.IsSigned }
            }
            $selected.Add([pscustomobject]@{
                ref=Get-AnonymousDeviceRef $id $Salt
                parentRef=if ($parentId) { Get-AnonymousDeviceRef $parentId $Salt } else { $null }
                class=$current.Class; name=$current.FriendlyName; status=$current.Status; relation=if ($depth -eq 0) { 'audio' } else { 'ancestor' }
                hardwareIds=$hardwareIds; driver=$driverInfo; propertiesStatus=$propertyStatus
            })
            if ($parentId -and $byId.ContainsKey($parentId)) { $current=$byId[$parentId] } else { $current=$null }
        }
    }
    [pscustomobject]@{ devices=$selected.ToArray(); note='音声デバイスと最大8階層の親。インスタンスIDはセッション内の照合用に匿名化し、シリアル番号を保存しません。端点と物理デバイスの関連が公開APIで取得できない場合は空欄になります。' }
}

function Get-RelatedEvents {
    param([DateTime]$Start = ([DateTime]::UtcNow.AddHours(-24)), [DateTime]$End = ([DateTime]::UtcNow))
    $records = New-Object 'System.Collections.Generic.List[object]'
    $status = New-Object 'System.Collections.Generic.List[object]'
    foreach ($log in @('System','Application')) {
        $readStatus = 'collected'
        $errorType = $null
        $scanCount = 0
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$Start; EndTime=$End; Level=1,2,3 } -MaxEvents 500 -ErrorAction Stop)
            $scanCount = $events.Count
            foreach ($event in $events) {
                if ($event.ProviderName -match 'Audio|USB|Kernel-PnP|DriverFrameworks|Kernel-Power|WHEA|Bluetooth|BTH|HidBth') {
                    $records.Add([pscustomobject]@{ log=$log; provider=$event.ProviderName; eventId=$event.Id; level=$event.Level; timeUtc=$event.TimeCreated.ToUniversalTime().ToString('o') })
                }
            }
        } catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $readStatus='noMatchingEvents' }
            else { $readStatus='unavailable'; $errorType=$_.Exception.GetType().Name }
        }
        $status.Add([pscustomobject]@{ log=$log; status=$readStatus; scanned=$scanCount; capped=($scanCount -ge 500); errorType=$errorType })
    }
    [pscustomobject]@{ startUtc=$Start.ToUniversalTime().ToString('o'); endUtc=$End.ToUniversalTime().ToString('o'); logs=$status.ToArray(); events=$records.ToArray(); note='各ログの最新500件までの重大・警告・エラーから関連プロバイダー名を抽出。メッセージ本文・ユーザー・マシン名・生イベントは保存しません。関連イベントなしは異常なしの証明ではありません。' }
}

function Get-TestEvidence {
    param([DateTime]$Start, [DateTime]$End, [string]$Salt, [switch]$IncludeDrivers)
    [pscustomobject]@{
        relatedEvents=Get-RelatedEvents -Start $Start -End $End
        bluetoothEndState=Get-BluetoothState $Salt
        driverSnapshot=if ($IncludeDrivers) {
            [pscustomobject]@{ capturedUtc=[DateTime]::UtcNow.ToString('o'); audioDevices=Invoke-CollectionSection { Get-AudioDeviceInventory $Salt } }
        } else { $null }
    }
}

function Get-DiagnosticInventory {
    param([string]$Salt)
    [pscustomobject]@{
        capturedUtc=[DateTime]::UtcNow.ToString('o')
        computer=Invoke-CollectionSection {
            $pc=Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
            $cpu=Get-CimInstance Win32_Processor -OperationTimeoutSec 15 -ErrorAction Stop | Select-Object -First 1
            [pscustomobject]@{ manufacturer=$pc.Manufacturer; model=$pc.Model; cpu=$cpu.Name }
        }
        windows=Invoke-CollectionSection {
            $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop
            $version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            [pscustomobject]@{ caption=$os.Caption; version=$os.Version; displayVersion=$version.DisplayVersion; build=$os.BuildNumber; revision=$version.UBR; lastBootUtc=$os.LastBootUpTime.ToUniversalTime().ToString('o') }
        }
        bios=Invoke-CollectionSection {
            $bios=Get-CimInstance Win32_BIOS -OperationTimeoutSec 15 -ErrorAction Stop
            [pscustomobject]@{ manufacturer=$bios.Manufacturer; version=$bios.SMBIOSBIOSVersion; releaseDate=if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { $null }; cStates='自動取得対象外。利用者の確認を参照。' }
        }
        defaultEndpoint=Invoke-CollectionSection { Get-DefaultEndpoint }
        audioDevices=Invoke-CollectionSection { Get-AudioDeviceInventory $Salt }
        bluetoothState=Get-BluetoothState $Salt
        bluetoothDevices=Invoke-CollectionSection { Get-BluetoothDeviceInventory $Salt }
        power=Invoke-CollectionSection {
            $raw=& powercfg.exe /getactivescheme
            if ($LASTEXITCODE -ne 0) { throw 'PowerPlanUnavailable' }
            $text=$raw -join ' '
            $guidMatch=[regex]::Match($text,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
            [pscustomobject]@{ schemeGuid=$guidMatch.Value; note='プラン名は任意の個人情報を含み得るため保存しません。設定変更は行いません。' }
        }
        relatedEvents=Invoke-CollectionSection { Get-RelatedEvents }
    }
}
