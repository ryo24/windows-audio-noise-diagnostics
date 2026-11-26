function Invoke-DetailedTrace {
    param([string]$SessionPath,[ValidateRange(1,120)][int]$Seconds=60,[scriptblock]$WprRunner,[string]$TraceId='',[switch]$IncludeUsb,[scriptblock]$UsbRunner)
    # Invoked explicitly by the user, in an elevated helper. Never cancels another WPR instance.
    $session=Read-Session $SessionPath
    if($session.id -notmatch '^[a-fA-F0-9]{32}$'){throw 'Invalid session ID'}
    $sessionDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($SessionPath))
    if(-not $TraceId){$TraceId=[guid]::NewGuid().ToString('N')}
    if($TraceId -notmatch '^[a-fA-F0-9]{32}$'){throw 'Invalid trace ID'}
    $instance='AudioNoise-'+$TraceId
    $traceDirectory=Join-Path (Join-Path $sessionDirectory 'traces') $traceId
    [IO.Directory]::CreateDirectory($traceDirectory)|Out-Null
    $existingState=Join-Path $traceDirectory 'trace.json'
    if(Test-Path -LiteralPath $existingState){
        $existing=Get-Content -LiteralPath $existingState -Raw -Encoding UTF8|ConvertFrom-Json
        if($existing.status -ne 'Launching' -or $existing.id -ne $traceId -or $existing.sessionId -ne $session.id){throw 'Existing trace data will not be overwritten'}
    }
    $state=[pscustomobject]@{id=$traceId;instanceName=$instance;sessionId=$session.id;status='Starting';helperPid=$PID;command=$null;commandStarted=$null;profiles=@('GeneralProfile','Audio');mode='Memory';requestedSeconds=$Seconds;started=Get-ClockPoint;updated=$null;stopping=$null;ended=$null;stopReason=$null;sha256=$null;bytes=0;startExitCode=$null;stopExitCode=$null;markers=@();errorType=$null;scope='ETL can contain process names, file paths and system-wide activity. Memory tracing is bounded and older events can be lost. Audio and DPC/ISR coverage depends on Windows; USB transfer-level tracing is not guaranteed.'}
    $state|Add-Member -NotePropertyName link -NotePropertyValue $(if($existing){$existing.link}else{$null})
    $state|Add-Member -NotePropertyName audioStatus -NotePropertyValue 'NotStarted'
    $state|Add-Member -NotePropertyName target -NotePropertyValue $null
    $state|Add-Member -NotePropertyName usb -NotePropertyValue ([pscustomobject]@{requested=[bool]$IncludeUsb;instanceName=('AudioNoise-USB-'+$TraceId);status='NotRequested';providers=@();started=$null;ended=$null;startExitCode=$null;stopExitCode=$null;bytes=0;sha256=$null;errorType=$null;clock='QPC';maxMegabytes=256;mode='Circular';scope='xHCI/UCX/USBHUB3 stack, including USB 2 devices on xHCI. All devices on these stacks; not filtered to one endpoint. Transfer headers, errors, state machines and rundown; no PartialDataBusTrace or FullDataBusTrace requested. Descriptors and identifiers can be present. Circular events may be overwritten; missing events never prove normality.'})
    $stateFile=Join-Path $traceDirectory 'trace.json'
    function Save-TraceState {$state.updated=Get-ClockPoint;Write-AtomicText $stateFile ($state|ConvertTo-Json -Depth 10)}
    function Invoke-TraceCommand {
        param([string[]]$Arguments)
        # Discard localized raw output: it can contain paths and must not become normal logs.
        if($WprRunner){return (& $WprRunner ($Arguments+@('-instancename',$instance)))}
        $state.command=$Arguments[0];$state.commandStarted=Get-ClockPoint;Save-TraceState
        Invoke-WprProcess -Arguments $Arguments -Instance $instance -Heartbeat {Save-TraceState}
    }
    $started=$false
    try{
        Save-TraceState
        if(Test-Path -LiteralPath (Join-Path $traceDirectory 'stop.request')){$state.status='Cancelled';$state.stopReason='RequestedBeforeStart';return $state}
        if(-not $WprRunner){
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
            if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator privileges are required for WPR.'}
        }
        if($IncludeUsb){$state.target=Get-UsbTargetSnapshot $state.link.endpointRef $session.id;Save-TraceState;if(Test-Path -LiteralPath (Join-Path $traceDirectory 'stop.request')){$state.status='Cancelled';$state.stopReason='RequestedBeforeStart';return $state};$state.usb.status='Starting';Save-TraceState;Start-UsbTrace $state.usb $traceDirectory $UsbRunner {Save-TraceState};Save-TraceState}
        $state.audioStatus='Starting'
        $state.startExitCode=Invoke-TraceCommand @('-start','GeneralProfile','-start','Audio')
        if($state.startExitCode -ne 0){throw 'WPR start failed. No other trace was cancelled.'}
        $started=$true;$state.audioStatus='Recording';$state.status='Recording';$state.started=Get-ClockPoint;Save-TraceState
        [void](Invoke-TraceCommand @('-marker',('AudioNoiseTraceStart-'+$traceId)))
        $clock=[Diagnostics.Stopwatch]::StartNew();$seen=@{};$lastHeartbeat=0
        while($clock.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path -LiteralPath (Join-Path $traceDirectory 'stop.request'))){
            # Session writes are atomic. UTC/QPC of the original click are included in the delayed ETW marker text.
            try{
                $current=Read-Session $SessionPath
                foreach($event in @($current.timeline|Where-Object {$_.kind -eq 'NoiseHeard' -and [double]$_.qpc -ge [double]$state.started.qpc})){
                    if(-not $seen.ContainsKey($event.id)){
                        $point=Get-ClockPoint
                        $code=Invoke-TraceCommand @('-marker',('Noise-'+$event.id+'-QPC-'+$event.qpc+'-UTC-'+$event.utc))
                        $state.markers+=@([pscustomobject]@{eventId=$event.id;originalPoint=$event;submittedPoint=$point;exitCode=$code});$seen[$event.id]=$true
                    }
                }
            }catch{}
            Start-Sleep -Milliseconds 300
            if($clock.Elapsed.TotalSeconds - [double]$lastHeartbeat -ge 1){Save-TraceState;$lastHeartbeat=$clock.Elapsed.TotalSeconds}
        }
        $state.stopReason=if(Test-Path -LiteralPath (Join-Path $traceDirectory 'stop.request')){'Requested'}else{'TimeLimit'}
    }catch{$state.errorType=$_.Exception.GetType().Name;$state.status='Failed';if($state.audioStatus -eq 'Starting'){$state.audioStatus='StartFailed'}}
    finally{
        if($started){
            $state.audioStatus='Stopping'
            $failedBeforeStop=[bool]$state.errorType
            $state.status='Stopping';$state.stopping=Get-ClockPoint;try{Save-TraceState}catch{}
            $etl=Join-Path $traceDirectory 'trace.etl'
            try {
                $state.stopExitCode=Invoke-TraceCommand @('-stop',$etl,'Audio noise reproduction','-skipPdbGen')
                if($state.stopExitCode -eq 0 -and (Test-Path -LiteralPath $etl) -and (Get-Item -LiteralPath $etl).Length -gt 0){
                    $state.audioStatus='Completed';$state.status=if($failedBeforeStop){'Failed'}else{'Completed'};$state.bytes=(Get-Item -LiteralPath $etl).Length;$state.sha256=(Get-FileHash -LiteralPath $etl).Hash
                }else{$state.audioStatus='StopFailed';$state.status='StopFailed';$state.errorType='TraceSaveFailed'}
            }catch{$state.audioStatus='StopFailed';$state.status='StopFailed';$state.errorType=$_.Exception.GetType().Name}
        }
        if($IncludeUsb -and $state.usb.status -eq 'Recording'){
            $state.status='Stopping';if(-not $state.stopping){$state.stopping=Get-ClockPoint};Save-TraceState
            Stop-UsbTrace $state.usb $traceDirectory $UsbRunner {Save-TraceState}
            if($state.usb.status -ne 'Completed'){$state.status='StopFailed';$state.errorType='UsbTraceSaveFailed'}elseif(-not $started){$state.status='Failed'}else{$state.status=if($state.errorType){'Failed'}else{'Completed'}}
        }
        if($IncludeUsb -and $state.usb.status -in @('Starting','Failed')){$state.usb.status='Failed';$state.usb.errorType=$state.errorType}
        $state.ended=Get-ClockPoint;Save-TraceState
    }
    return $state

}
