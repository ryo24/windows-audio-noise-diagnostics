function ConvertTo-UsbNumber {
    param([string]$Value)
    try{
        if($Value -match '^0x[0-9a-f]+$'){return [Convert]::ToUInt64($Value.Substring(2),16)}
        if($Value -match '^\d+$'){return [Convert]::ToUInt64($Value,10)}
    }catch{}
    return $null
}
function ConvertTo-UsbEvent {
    param([string]$Xml,[string]$Salt)
    $settings=New-Object Xml.XmlReaderSettings;$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create((New-Object IO.StringReader($Xml)),$settings)
    try{$doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null;$doc.Load($reader)}finally{$reader.Dispose()}
    $provider=$doc.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="Provider"]').GetAttribute('Name')
    if($provider -notin @('Microsoft-Windows-USB-USBHUB3','Microsoft-Windows-USB-UCX','Microsoft-Windows-USB-USBXHCI')){return}
    $fields=@{};$instanceRef=$null
    foreach($data in $doc.SelectNodes('//*[local-name()="Data"][@Name or @name]')){
        $name=$data.GetAttribute('Name');if(-not $name){$name=$data.GetAttribute('name')};$name=$name -replace '^fid_','';$value=$data.InnerText
        if($name -eq 'DeviceInterfacePath'){
            $id=($value -replace '^\\\\\?\\','' -replace '#\{[0-9a-f-]+\}$','' -replace '#','\').TrimEnd('\')
            if($id -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}[^\\]*\\[^\\]+$'){$instanceRef=Get-AnonymousDeviceRef $id $Salt}
        }
        if($name -in @('UsbDevice','Endpoint','PipeHandle','UcxController','Controller','SlotId','PortPath','PortNumber','idVendor','idProduct','bEndpointAddress','Status','UsbdStatus','UrbStatus','NtStatus','TransferLength','TransferBufferLength','BytesTransferred','StartFrame','FrameNumber','NumberOfPackets','ErrorCount','CurrentWdfPowerDeviceState')){
            if($name -eq 'PortPath'){$fields[$name]=$value}else{$number=ConvertTo-UsbNumber $value;if($null -ne $number){$fields[$name]=[string]$number}}
        }
        if($name -in @('DeviceDescriptor','USB_Device_Descriptor') -and $value -match '^[0-9A-Fa-f]{36}$'){$fields.idVendor=[string][Convert]::ToInt32(($value.Substring(18,2)+$value.Substring(16,2)),16);$fields.idProduct=[string][Convert]::ToInt32(($value.Substring(22,2)+$value.Substring(20,2)),16)}
    }
    $port=@();if($fields.PortPath){
        $fields.PortPath=$fields.PortPath -replace '^0x(?=[0-9A-Fa-f]{48}$)',''
        if($fields.PortPath -match '^[0-9A-Fa-f]{48}$'){$port=@(for($i=0;$i -lt 48;$i+=8){$chunk=$fields.PortPath.Substring($i,8);[Convert]::ToInt32(($chunk.Substring(6,2)+$chunk.Substring(4,2)+$chunk.Substring(2,2)+$chunk.Substring(0,2)),16)})}
        else{$port=@([regex]::Matches($fields.PortPath,'0x[0-9A-Fa-f]+|\d+')|ForEach-Object {ConvertTo-UsbNumber $_.Value})}
        $port=@($port|Where-Object {$_ -gt 0})
    }
    [pscustomobject]@{provider=$provider;eventId=$doc.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="EventID"]').InnerText;utc=$doc.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="TimeCreated"]').GetAttribute('SystemTime');instanceRef=$instanceRef;portPath=$port;fields=$fields}
}
function Find-UsbTargetKeys {
    param([scriptblock]$Read,$Target)
    $candidates=@{};$exact=@{};$conflicts=@{};$refs=@($Target.chain|ForEach-Object {$_.ref})
    & $Read | ForEach-Object {
        $event=$_;$device=$event.fields.UsbDevice
        if($device -and $device -ne '0'){
            $matchesInstance=$event.instanceRef -and $refs -contains $event.instanceRef
            $matchesPort=$Target.portPath.Count -gt 0 -and ($event.portPath -join ',') -eq ($Target.portPath -join ',')
            $matchesDescriptor=$null -ne $event.fields.idVendor -and $null -ne $event.fields.idProduct -and $event.fields.idVendor -eq [string][Convert]::ToInt32($Target.vid,16) -and $event.fields.idProduct -eq [string][Convert]::ToInt32($Target.pid,16)
            if(($event.instanceRef -and -not $matchesInstance) -or ($null -ne $event.fields.idVendor -and $null -ne $event.fields.idProduct -and -not $matchesDescriptor)){$conflicts[$event.provider+'/'+$device]=$true}
            if($matchesInstance -or ($Target.sameVidPidDevices -eq 1 -and $matchesPort -and $matchesDescriptor)){
                if(-not $candidates.ContainsKey($event.provider)){$candidates[$event.provider]=@{}}
                $candidates[$event.provider][$device]=$true
                if($matchesInstance){if(-not $exact.ContainsKey($event.provider)){$exact[$event.provider]=@{}};$exact[$event.provider][$device]=$true}
            }
        }
    }
    $keys=@{};$ambiguities=@()
    foreach($provider in $candidates.Keys){
        $selected=if($exact.ContainsKey($provider)){$exact[$provider]}else{$candidates[$provider]}
        if($selected.Count -eq 1 -and -not $conflicts.ContainsKey($provider+'/'+@($selected.Keys)[0])){$keys[$provider]=@{device=@($selected.Keys)[0];method=if($exact.ContainsKey($provider)){'ExactInstanceRef'}else{'UniqueVidPidAndPortPath'}}}else{$ambiguities+=@($provider)}
    }
    [pscustomobject]@{providers=$keys;ambiguousProviders=$ambiguities;status=if($keys.Count){'matched'}else{'unresolved'};scope='Rundown selection only. Never joins shared controller/hub pointers. Missing rundown, duplicate devices, reconnects or unsupported fields can prevent or limit attribution.'}
}
function Select-UsbTargetEvents {
    param([scriptblock]$Read,$Selection,$Probe)
    $endpoints=@{};$endpointConflicts=@{}
    # Endpoint handles are provider-scoped and learned only from the selected device.
    & $Read | ForEach-Object {
        $event=$_;$key=$Selection.providers[$event.provider]
        if($key -and $event.fields.UsbDevice -and $event.fields.Endpoint -and $event.fields.Endpoint -ne '0'){
            $handle=$event.provider+'/'+$event.fields.Endpoint
            if($event.fields.UsbDevice -eq $key.device){$endpoints[$handle]=$true}else{$endpointConflicts[$handle]=$true}
        }
    }
    & $Read | ForEach-Object {
        $event=$_;$key=$Selection.providers[$event.provider]
        $direct=$key -and $event.fields.UsbDevice -eq $key.device
        $endpoint=$key -and -not $event.fields.UsbDevice -and $event.fields.Endpoint -and $endpoints.ContainsKey($event.provider+'/'+$event.fields.Endpoint) -and -not $endpointConflicts.ContainsKey($event.provider+'/'+$event.fields.Endpoint)
        if($direct -or $endpoint){
            $offset=$null;if($Probe.capture.startedUtc -and $event.utc){$offset=[Math]::Round(([DateTime]::Parse($event.utc).ToUniversalTime()-[DateTime]::Parse($Probe.capture.startedUtc).ToUniversalTime()).TotalSeconds,6)}
            [pscustomobject]@{utc=$event.utc;recordingOffsetSecondsUtc=$offset;referenceOffsetSecondsUtc=if($null -ne $offset){$offset-$Probe.capture.referenceStartOffsetSeconds}else{$null};provider=$event.provider;eventId=$event.eventId;matchMethod=$key.method;usbDevice=$event.fields.UsbDevice;endpoint=$event.fields.Endpoint;status=$event.fields.Status;usbdStatus=$event.fields.UsbdStatus;urbStatus=$event.fields.UrbStatus;ntStatus=$event.fields.NtStatus;transferLength=$event.fields.TransferLength;bytesTransferred=$event.fields.BytesTransferred;startFrame=$event.fields.StartFrame;frameNumber=$event.fields.FrameNumber;packetCount=$event.fields.NumberOfPackets;errorCount=$event.fields.ErrorCount}
        }
    }
}
