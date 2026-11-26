function Get-UsbTargetSnapshot {
    param([string]$EndpointRef,[string]$Salt)
    $result=[pscustomobject]@{status='unavailable';point=Get-ClockPoint;endpointRef=$EndpointRef;chain=@();physicalRef=$null;vid=$null;pid=$null;portPath=@();sameVidPidDevices=$null;boot=$null;missing=@();scope='Selected output and ancestors at trace start. References are session salted. Capture covers all xHCI devices; analysis must establish a unique target.'}
    if($EndpointRef -notmatch '^[a-fA-F0-9]{16}$'){$result.missing=@('SelectedEndpointRef');return $result}
    try {
        $devices=@(Get-PnpDevice -PresentOnly -ErrorAction Stop);$byId=@{};foreach($device in $devices){$byId[$device.InstanceId]=$device}
        $roots=@($devices|Where-Object {(Get-AnonymousDeviceRef $_.InstanceId $Salt) -eq $EndpointRef})
        if($roots.Count -ne 1){throw 'Selected endpoint is absent or ambiguous'}
        $current=$roots[0];$seen=@{}
        for($depth=0;$depth -lt 12 -and $current;$depth++){
            $id=[string]$current.InstanceId;if($seen.ContainsKey($id)){break};$seen[$id]=$true
            $props=@(Get-PnpDeviceProperty -InstanceId $id -ErrorAction Stop)
            $parent=[string]($props|Where-Object KeyName -eq 'DEVPKEY_Device_Parent').Data
            $hardware=@(($props|Where-Object KeyName -eq 'DEVPKEY_Device_HardwareIds').Data|Where-Object {$_ -match '^(USB\\(VID_|Class_)|HDAUDIO\\|INTELAUDIO\\|PCI\\VEN_)'})
            $locations=@(($props|Where-Object KeyName -eq 'DEVPKEY_Device_LocationPaths').Data|Where-Object {$_ -match '^PCIROOT\([0-9A-F]+\)(#(PCI|USBROOT|USB)\([0-9A-F]+\))+$'})
            $ref=Get-AnonymousDeviceRef $id $Salt
            $result.chain+=@([pscustomobject]@{ref=$ref;parentRef=if($parent){Get-AnonymousDeviceRef $parent $Salt}else{$null};class=$current.Class;hardwareIds=$hardware;locationPaths=$locations})
            if(-not $result.physicalRef -and $id -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})\\'){
                $result.physicalRef=$ref;$result.vid=$Matches[1];$result.pid=$Matches[2]
                if($locations.Count){$result.portPath=@([regex]::Matches($locations[0],'#USB\(([0-9A-F]+)\)')|ForEach-Object {[Convert]::ToInt32($_.Groups[1].Value,16)})}
                $pattern='^USB\\VID_'+$result.vid+'&PID_'+$result.pid+'\\'
                $result.sameVidPidDevices=@($devices|Where-Object InstanceId -match $pattern).Count
            }
            if($parent -and $byId.ContainsKey($parent)){$current=$byId[$parent]}else{$current=$null}
        }
        if(-not $result.physicalRef){$result.missing+=@('UsbPhysicalAncestor')}
        if(-not $result.portPath.Count){$result.missing+=@('UsbPortPath')}
        if($current){$result.missing+=@('AncestorChainIncomplete')}
        $result.boot=Invoke-CollectionSection {$os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop;[pscustomobject]@{lastBootUtc=$os.LastBootUpTime.ToUniversalTime().ToString('o')}}
        if($result.boot.status -ne 'collected'){$result.missing+=@('BootIdentity')}
        $result.status=if($result.physicalRef -and $result.portPath.Count -and -not $result.missing.Count){'collected'}else{'partial'}
    }catch{$result.missing+=@($_.Exception.GetType().Name);$result.status='partial'}
    return $result
}
