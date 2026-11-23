function Invoke-DetailedTrace {
    param([string]$SessionPath,[ValidateRange(1,120)][int]$Seconds=60,[scriptblock]$WprRunner,[string]$TraceId='')
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
        $state.startExitCode=Invoke-TraceCommand @('-start','GeneralProfile','-start','Audio')
        if($state.startExitCode -ne 0){throw 'WPR start failed. No other trace was cancelled.'}
        $started=$true;$state.status='Recording';$state.started=Get-ClockPoint;Save-TraceState
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
    }catch{$state.errorType=$_.Exception.GetType().Name;$state.status='Failed'}
    finally{
        if($started){
            $failedBeforeStop=[bool]$state.errorType
            $state.status='Stopping';$state.stopping=Get-ClockPoint;try{Save-TraceState}catch{}
            $etl=Join-Path $traceDirectory 'trace.etl'
            try {
                $state.stopExitCode=Invoke-TraceCommand @('-stop',$etl,'Audio noise reproduction','-skipPdbGen')
                if($state.stopExitCode -eq 0 -and (Test-Path -LiteralPath $etl) -and (Get-Item -LiteralPath $etl).Length -gt 0){
                    $state.status=if($failedBeforeStop){'Failed'}else{'Completed'};$state.bytes=(Get-Item -LiteralPath $etl).Length;$state.sha256=(Get-FileHash -LiteralPath $etl).Hash
                }else{$state.status='StopFailed';$state.errorType='TraceSaveFailed'}
            }catch{$state.status='StopFailed';$state.errorType=$_.Exception.GetType().Name}
        }
        $state.ended=Get-ClockPoint;Save-TraceState
    }
    return $state

}
