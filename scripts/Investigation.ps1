function Protect-InvestigationText {
    param([string]$Text,[string]$SessionDirectory,[int]$Limit=16384)
    if($SessionDirectory){$Text=$Text.Replace($SessionDirectory,'<session>')}
    if($script:ToolRoot){$Text=$Text.Replace($script:ToolRoot,'<tool>')}
    $Text=[regex]::Replace($Text,'(?i)[A-Z]:\\Users\\[^\\\s"'']+','<user>')
    $Text=[regex]::Replace($Text,'(?i)(USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}[^\\\s<"'']*\\)[^\s<"'']+','$1<instance>')
    $Text=[regex]::Replace($Text,'(?i)(USB#VID_[0-9A-F]{4}&PID_[0-9A-F]{4}[^#\\\s<]*#)[^#\s<]+','$1<instance>')
    if($Text.Length -gt $Limit){return $Text.Substring(0,$Limit)+"`n<truncated>"}
    return $Text
}
function Invoke-InvestigationSection {
    param([scriptblock]$Read,[string]$SessionDirectory)
    $begin=Get-ClockPoint
    try{$data=& $Read;$status='collected';$errorDetail=$null}
    catch{$data=$null;$status='unavailable';$errorDetail=[pscustomobject]@{type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult;message=Protect-InvestigationText $_.Exception.Message $SessionDirectory}}
    $end=Get-ClockPoint
    [pscustomobject]@{status=$status;started=$begin;ended=$end;durationMilliseconds=[Math]::Round(($end.qpc-$begin.qpc)*1000/$begin.frequency,2);data=$data;error=$errorDetail}
}
function Get-InvestigationNative {
    param([string]$Executable,[string[]]$Arguments,[string]$SessionDirectory,[scriptblock]$Heartbeat)
    $nativeResultBox=New-Object 'System.Collections.Generic.List[object]'
    $code=Invoke-DiagnosticProcess -Executable (Join-Path $env:SystemRoot ('System32/'+$Executable)) -Arguments $Arguments -Heartbeat $Heartbeat -OnResult {param($result);$nativeResultBox.Add($result)}
    $record=if($nativeResultBox.Count){$nativeResultBox[0]}else{[pscustomobject]@{exitCode=$code;stdout='';stderr='';started=$null;ended=$null}}
    [pscustomobject]@{exitCode=$code;started=$record.started;ended=$record.ended;stdout=Protect-InvestigationText $record.stdout $SessionDirectory 65536;stderr=Protect-InvestigationText $record.stderr $SessionDirectory 65536;outputTruncated=($record.stdout.Length -gt 65536 -or $record.stderr.Length -gt 65536)}
}
function Get-InvestigationAudio {
    param([string]$EndpointRef,[string]$Salt)
    Initialize-AudioInterop
    $endpoint=@([AudioNoiseDiagnostics.AudioFiles]::Endpoints()|Where-Object {(Get-AnonymousDeviceRef ('SWD\MMDEVAPI\'+$_.Id) $Salt) -eq $EndpointRef})
    if($endpoint.Count -ne 1){throw 'Selected audio endpoint is absent or ambiguous'}
    $info=[AudioNoiseDiagnostics.Endpoint]::Read($endpoint[0].Id)
    $effects=@();$effectsStatus='notPresent';$registryId=$null
    if($endpoint[0].Id -match '(\{[a-fA-F0-9-]+\})$'){$registryId=$Matches[1]}
    if($registryId){
        $path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\'+$registryId+'\FxProperties'
        if(Test-Path -LiteralPath $path){$effectsStatus='configuredProperties';$properties=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            $effects=@(foreach($property in $properties.PSObject.Properties){if($property.Name -match '^\{[a-fA-F0-9-]+\},\d+$'){
                $value=$property.Value
                if($value -is [byte[]]){$value=[Convert]::ToBase64String($value);if($value.Length -gt 8192){$value=$value.Substring(0,8192)+'<truncated>'}}
                elseif($value -is [string]){$value=Protect-InvestigationText $value '' 8192}
                [pscustomobject]@{key=$property.Name;type=$property.TypeNameOfValue;value=$value}
            }})
        }
    }
    [pscustomobject]@{endpointRef=$EndpointRef;name=$endpoint[0].Name;format=$info|Select-Object SampleRate,Channels,ContainerBits,DefaultPeriod100ns,MinimumPeriod100ns,PeriodError,VolumeScalar,Muted,VolumeError;effectsStatus=$effectsStatus;effects=$effects;playback=Get-PlaybackSnapshot $Salt $endpoint[0].Id;scope='Configured FxProperties are raw settings, not proof of the current live APO chain or audible processing. Endpoint periods describe scheduling, not physical DAC clock.'}
}
function Get-InvestigationDevices {
    param($Target,[string]$Salt)
    $refs=@($Target.chain.ref);$present=@(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    @(foreach($device in $present){$ref=Get-AnonymousDeviceRef $device.InstanceId $Salt;if($refs -contains $ref){
        $properties=Invoke-InvestigationSection {
            $props=@(Get-PnpDeviceProperty -InstanceId $device.InstanceId -ErrorAction Stop)
            $keys=@('DEVPKEY_Device_Service','DEVPKEY_Device_DriverProvider','DEVPKEY_Device_DriverVersion','DEVPKEY_Device_DriverDate','DEVPKEY_Device_DriverInfPath','DEVPKEY_Device_ClassGuid','DEVPKEY_Device_UpperFilters','DEVPKEY_Device_LowerFilters','DEVPKEY_Device_PowerData','DEVPKEY_Device_Capabilities','DEVPKEY_Device_BusNumber','DEVPKEY_Device_Address','DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus')
            $values=@(foreach($p in $props|Where-Object {$_.KeyName -in $keys}){[pscustomobject]@{key=$p.KeyName;type=[string]$p.Type;value=if($p.Data -is [byte[]]){[Convert]::ToBase64String($p.Data)}else{$p.Data}}})
            $classGuid=[string]($props|Where-Object KeyName -eq 'DEVPKEY_Device_ClassGuid').Data
            $classFilters=if($classGuid -match '^\{[a-fA-F0-9-]{36}\}$'){
                Invoke-InvestigationSection {$class=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$classGuid) -ErrorAction Stop;[pscustomobject]@{upperFilters=@($class.UpperFilters);lowerFilters=@($class.LowerFilters)}} ''
            }else{[pscustomobject]@{status='unavailable';data=$null;error='MissingClassGuid'}}
            [pscustomobject]@{deviceProperties=$values;classFilters=$classFilters}
        } ''
        [pscustomobject]@{ref=$ref;class=$device.Class;status=$device.Status;properties=$properties}
    }})
}
function Get-InvestigationDriverFiles {
    param($Devices)
    $names=@($Devices|ForEach-Object {if($_.properties.status -eq 'collected'){
        $_.properties.data.deviceProperties|Where-Object {$_.key -in @('DEVPKEY_Device_Service','DEVPKEY_Device_UpperFilters','DEVPKEY_Device_LowerFilters')}|ForEach-Object {$_.value}
        $_.properties.data.classFilters.data.upperFilters; $_.properties.data.classFilters.data.lowerFilters
    }}|Where-Object {$_ -match '^[a-zA-Z0-9_.-]{1,128}$'}|Sort-Object -Unique)
    $driverMap=@{};foreach($entry in @(Get-CimInstance Win32_SystemDriver -OperationTimeoutSec 8 -ErrorAction Stop)){$driverMap[$entry.Name]=$entry}
    @(foreach($name in $names){Invoke-InvestigationSection {
        $driver=$driverMap[$name]
        if(-not $driver){throw 'No kernel/system driver for this service name'}
        $path=([string]$driver.PathName).Trim('"')
        if($path.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)){$path=Join-Path $env:SystemRoot $path.Substring(12)}
        elseif($path.StartsWith('System32\',[StringComparison]::OrdinalIgnoreCase)){$path=Join-Path $env:SystemRoot $path}
        $path=$path -replace '^\\\?\?\\',''
        $file=$null
        if([IO.Path]::GetExtension($path) -eq '.sys' -and (Test-Path -LiteralPath $path -PathType Leaf)){
            $item=Get-Item -LiteralPath $path
            $file=[pscustomobject]@{path=Protect-InvestigationText $path '';bytes=$item.Length;version=$item.VersionInfo.FileVersion;productVersion=$item.VersionInfo.ProductVersion;sha256=if($item.Length -le 64MB){(Get-FileHash -LiteralPath $path).Hash}else{$null}}
        }
        [pscustomobject]@{name=$name;state=$driver.State;startMode=$driver.StartMode;started=$driver.Started;serviceType=$driver.ServiceType;file=$file;scope='Target device/class service and filter drivers only. Hash/version does not verify signature trust.'}
    } ''})
}
function Get-InvestigationSnapshot {
    param($Target,[string]$Salt,[string]$SessionDirectory,[scriptblock]$Heartbeat)
    $deviceSection=Invoke-InvestigationSection {Get-InvestigationDevices $Target $Salt} $SessionDirectory
    [pscustomobject]@{
        point=Get-ClockPoint
        audio=Invoke-InvestigationSection {Get-InvestigationAudio $Target.endpointRef $Salt} $SessionDirectory
        devices=$deviceSection
        driverFiles=Invoke-InvestigationSection {Get-InvestigationDriverFiles $deviceSection.data} $SessionDirectory
        services=Invoke-InvestigationSection {@(Get-CimInstance Win32_Service -Filter "Name='Audiosrv' OR Name='AudioEndpointBuilder' OR Name='RpcSs'" -OperationTimeoutSec 8 -ErrorAction Stop|Select-Object Name,State,StartMode,ProcessId,ExitCode)} $SessionDirectory
        powerPlan=Invoke-InvestigationSection {Get-InvestigationNative powercfg.exe @('/query','SCHEME_CURRENT') $SessionDirectory $Heartbeat} $SessionDirectory
        wprGeneralDefinition=Invoke-InvestigationSection {Get-InvestigationNative wpr.exe @('-profiledetails','GeneralProfile') $SessionDirectory $Heartbeat} $SessionDirectory
        wprAudioDefinition=Invoke-InvestigationSection {Get-InvestigationNative wpr.exe @('-profiledetails','Audio') $SessionDirectory $Heartbeat} $SessionDirectory
        powerRequests=Invoke-InvestigationSection {Get-InvestigationNative powercfg.exe @('/requests') $SessionDirectory $Heartbeat} $SessionDirectory
        environment=Invoke-InvestigationSection {$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent());[pscustomobject]@{elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);processBits=[IntPtr]::Size*8;powerShell=[string]$PSVersionTable.PSVersion;os=[Environment]::OSVersion.VersionString;logmanVersion=(Get-Item (Join-Path $env:SystemRoot 'System32/logman.exe')).VersionInfo.FileVersion;wprVersion=(Get-Item (Join-Path $env:SystemRoot 'System32/wpr.exe')).VersionInfo.FileVersion}} $SessionDirectory
        scope='Read-only before/after snapshot. No service, device, driver, power or registry settings are changed. Each section records actual time and errors; snapshots are not instantaneous.'
    }
}
function Get-InvestigationSample {
    param([string]$SessionDirectory,$Target,[string]$Salt)
    [pscustomobject]@{point=Get-ClockPoint;cpu=Invoke-InvestigationSection {@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -OperationTimeoutSec 2 -ErrorAction Stop|Select-Object -First 129 Name,PercentProcessorTime,PercentDPCTime,PercentInterruptTime,InterruptsPersec,DPCsQueuedPersec)} $SessionDirectory;audio=Invoke-InvestigationSection {Get-InvestigationAudio $Target.endpointRef $Salt} $SessionDirectory}
}
function Get-InvestigationEvents {
    param([DateTime]$Start,[DateTime]$End,[string]$SessionDirectory)
    Invoke-InvestigationSection {
        try{$events=@(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$Start;EndTime=$End} -MaxEvents 2000 -ErrorAction Stop)}catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){$events=@()}else{throw}}
        $matching=@($events|Where-Object {$_.ProviderName -match 'USB|Audio|Kernel-PnP|DriverFrameworks|Kernel-Power|WHEA'}|Select-Object -First 300)
        $rows=@(foreach($event in $matching){$message=try{$event.FormatDescription()}catch{''};[pscustomobject]@{provider=$event.ProviderName;id=$event.Id;level=$event.Level;utc=$event.TimeCreated.ToUniversalTime().ToString('o');recordId=$event.RecordId;message=Protect-InvestigationText $message $SessionDirectory 8192}})
        foreach($event in $events){$event.Dispose()}
        [pscustomobject]@{events=$rows;scanned=$events.Count;scanCapped=($events.Count -eq 2000);matchCapped=($matching.Count -eq 300);scope='Targeted System providers, including informational events. No events is not proof of no glitches. Raw instance suffixes/user paths are redacted.'}
    } $SessionDirectory
}
function Test-InvestigationUsbEvents {
    param([string]$Path,$Target,[string]$Salt,[scriptblock]$Heartbeat)
    $counts=@{};$types=@{};$normalized=New-Object 'System.Collections.Generic.List[object]';$scanned=0;$first=$null;$last=$null;$errorDetail=$null
    try{
        Get-WinEvent -Path $Path -Oldest -MaxEvents 10001 -ErrorAction Stop|ForEach-Object {
            $scanned++;if($scanned -le 10000){
                $name=$_.ProviderName;if(-not $counts.ContainsKey($name)){$counts[$name]=0};$counts[$name]++
                $key=$name+'/'+$_.Id;if(-not $types.ContainsKey($key)){$types[$key]=0};$types[$key]++
                $utc=$_.TimeCreated.ToUniversalTime().ToString('o');if(-not $first){$first=$utc};$last=$utc
                $item=ConvertTo-UsbEvent $_.ToXml() $Salt;if($item){$normalized.Add($item)}
            };$_.Dispose();if($Heartbeat -and $scanned%1000 -eq 0){& $Heartbeat}
        }
    }catch{$errorDetail=[pscustomobject]@{type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult;message=Protect-InvestigationText $_.Exception.Message ''}}
    $selection=if($normalized.Count -and $Target.physicalRef){Find-UsbTargetKeys {$normalized.ToArray()} $Target}else{$null}
    [pscustomobject]@{status=if($errorDetail){'ReadFailed'}elseif($normalized.Count){'ReadableUsbEvents'}else{'NoUsbEventsInSample'};scanned=$scanned;scanCapped=($scanned -gt 10000);usbEventsInSample=$normalized.Count;providerCounts=$counts;eventTypes=$types;firstUtc=$first;lastUtc=$last;targetSelection=$selection;error=$errorDetail;scope='Bounded read of first 10,000 events, not an analysis of the whole trace or proof of correct USB transfers. Event loss is not measured here. Target mapping may remain unresolved.'}
}
function Get-InvestigationHypotheses {
    param($Trace,$Before,$After,$Validation)
    @(
        [pscustomobject]@{id='usb-transfer-timing';evidence=@('usb.etl','usb-validation.json','target');available=($Trace.usb.status -eq 'Completed' -and $Validation.status -eq 'ReadableUsbEvents' -and $Validation.targetSelection.status -eq 'matched');question='Compare target isochronous transfers, status/frame/length and physical pitch/drop timing. A readable file is not a diagnosis.'},
        [pscustomobject]@{id='driver-device-state';evidence=@('investigation-before.json','investigation-after.json','trace.etl');available=($Before.devices.status -eq 'collected' -and $After.devices.status -eq 'collected');question='Compare device services/filters/versions/power data and resets. Do not restart devices during the baseline capture.'},
        [pscustomobject]@{id='windows-audio-settings';evidence=@('investigation-before.json','investigation-after.json','trace.etl','reference.wav','loopback.wav');available=($Before.audio.status -eq 'collected');question='Compare actual selected mix format, scheduling periods, raw effects and service state with loopback/reference. Raw effects are not live APO proof.'},
        [pscustomobject]@{id='power-transition';evidence=@('investigation-before.json','investigation-after.json','investigation-events.json');available=($Before.powerPlan.data.exitCode -eq 0);question='Compare active power settings, device power metadata and events against the same physical interval.'},
        [pscustomobject]@{id='cpu-dpc-isr-starvation';evidence=@('investigation-samples.json','trace.etl');available=($Trace.audioStatus -eq 'Completed');question='Use ETW DPC/ISR and scheduling plus coarse CPU samples. Low sampled values or zero warning events cannot exclude short stalls.'},
        [pscustomobject]@{id='physical-output-or-recorder';evidence=@('physical/','reference.wav','loopback.wav');available=$false;question='Requires linked physical recording and reference alignment. Clean loopback cannot alone distinguish transfer, DAC, analog circuitry or phone processing.'}
    )
}
function Get-InvestigationCoverage {
    param($Before,$After,$Samples,$Validation,$Target=$null)
    $missing=New-Object 'System.Collections.Generic.List[string]'
    foreach($entry in @(@('before',$Before),@('after',$After))){
        foreach($name in @('audio','devices','driverFiles','services','powerPlan','powerRequests','wprGeneralDefinition','wprAudioDefinition','environment')){
            $section=$entry[1].$name
            if($section.status -ne 'collected'){$missing.Add($entry[0]+'.'+$name)}
            elseif($section.data -and $section.data.PSObject.Properties['exitCode'] -and $section.data.exitCode -ne 0){$missing.Add($entry[0]+'.'+$name+'.NativeExit='+$section.data.exitCode)}
        }
        foreach($node in @($entry[1].devices.data|Where-Object {$_})){
            if($node.properties -and $node.properties.status -ne 'collected'){$missing.Add($entry[0]+'.deviceProperties:'+ $node.ref)}
            elseif($node.properties.data.classFilters.status -ne 'collected'){$missing.Add($entry[0]+'.classFilters:'+ $node.ref)}
        }
        foreach($ref in @($Target.chain.ref|Where-Object {$_})){if($ref -notin @($entry[1].devices.data.ref)){$missing.Add($entry[0]+'.absentTargetNode:'+ $ref)}}
        foreach($driver in @($entry[1].driverFiles.data|Where-Object {$_})){if($driver.status -ne 'collected'){$missing.Add($entry[0]+'.driverEntryUnavailable')}elseif(-not $driver.data.file.sha256){$missing.Add($entry[0]+'.driverFileHash:'+ $driver.data.name)}}
        foreach($name in @('PeriodError','VolumeError')){if($entry[1].audio.data.format.$name){$missing.Add($entry[0]+'.audio.'+$name)}}
    }
    [pscustomobject]@{unavailableSections=$missing.ToArray();sampleCount=@($Samples|Where-Object {$_}).Count;cpuSampleFailures=@($Samples|Where-Object {$_.cpu.status -ne 'collected'}).Count;audioSampleFailures=@($Samples|Where-Object {$_.audio.status -ne 'collected'}).Count;usbEventCheck=if($Validation){$Validation.status}else{'NotAttempted'};targetMapping=if($Validation.targetSelection){$Validation.targetSelection.status}else{'unresolved'};scope='Attempt completion is separate from evidence coverage. Missing/unavailable information is not proof of normal operation.'}
}
function Get-InvestigationProviderSchema {
    @(foreach($name in @('Microsoft-Windows-USB-USBXHCI','Microsoft-Windows-USB-UCX','Microsoft-Windows-USB-USBHUB3')){
        $provider=Get-WinEvent -ListProvider $name -ErrorAction Stop
        if(-not $provider.Name -or -not $provider.Id){throw 'USB provider metadata is unavailable'}
        $events=@($provider.Events)
        [pscustomobject]@{name=$provider.Name;id=$provider.Id.ToString();keywords=@($provider.Keywords|Select-Object Name,Value);eventCount=$events.Count;eventsCapped=($events.Count -gt 1000);events=@($events|Select-Object -First 1000|ForEach-Object {[pscustomobject]@{id=$_.Id;version=$_.Version;level=$_.Level.Value;task=$_.Task.Value;opcode=$_.Opcode.Value;template=$_.Template}});scope='OS provider schema at capture time, not device-specific payload.'}
    })
}
