function Invoke-DetailedTrace {
    param([string]$SessionPath,[ValidateRange(1,120)][int]$Seconds=60,[scriptblock]$WprRunner)
    # Invoked explicitly by the user, in an elevated helper. Never cancels another WPR instance.
    $session=Read-Session $SessionPath
    if($session.id -notmatch '^[a-fA-F0-9]{32}$'){throw 'Invalid session ID'}
    $sessionDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($SessionPath))
    $traceId=[guid]::NewGuid().ToString('N');$instance='AudioNoise-'+$traceId
    $traceDirectory=Join-Path (Join-Path $sessionDirectory 'traces') $traceId
    [IO.Directory]::CreateDirectory($traceDirectory)|Out-Null
    $state=[pscustomobject]@{id=$traceId;instanceName=$instance;sessionId=$session.id;status='Starting';profiles=@('GeneralProfile','Audio');mode='Memory';requestedSeconds=$Seconds;started=Get-ClockPoint;ended=$null;sha256=$null;bytes=0;startExitCode=$null;stopExitCode=$null;markers=@();errorType=$null;scope='ETL can contain process names, file paths and system-wide activity. Memory tracing is bounded and older events can be lost. Audio and DPC/ISR coverage depends on Windows; USB transfer-level tracing is not guaranteed.'}
    $stateFile=Join-Path $traceDirectory 'trace.json'
    function Save-TraceState {Write-AtomicText $stateFile ($state|ConvertTo-Json -Depth 10)}
    function Invoke-TraceCommand {
        param([string[]]$Arguments)
        # Discard localized raw output: it can contain paths and must not become normal logs.
        if($WprRunner){return (& $WprRunner ($Arguments+@('-instancename',$instance)))}
        $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
        try{& "$env:SystemRoot\System32\wpr.exe" @Arguments -instancename $instance 2>&1|Out-Null;return $LASTEXITCODE}finally{$ErrorActionPreference=$previous}
    }
    $started=$false
    try{
        Save-TraceState
        if(-not $WprRunner){
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
            if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator privileges are required for WPR.'}
        }
        $state.startExitCode=Invoke-TraceCommand @('-start','GeneralProfile','-start','Audio')
        if($state.startExitCode -ne 0){throw 'WPR start failed. No other trace was cancelled.'}
        $started=$true;$state.status='Recording';$state.started=Get-ClockPoint;Save-TraceState
        [void](Invoke-TraceCommand @('-marker',('AudioNoiseTraceStart-'+$traceId)))
        $clock=[Diagnostics.Stopwatch]::StartNew();$seen=@{}
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
        }
    }catch{$state.errorType=$_.Exception.GetType().Name;$state.status='Failed'}
    finally{
        if($started){
            $state.status='Stopping';try{Save-TraceState}catch{}
            $etl=Join-Path $traceDirectory 'trace.etl'
            $state.stopExitCode=Invoke-TraceCommand @('-stop',$etl,'Audio noise reproduction','-skipPdbGen')
            if($state.stopExitCode -eq 0 -and (Test-Path -LiteralPath $etl)){
                $state.status='Completed';$state.bytes=(Get-Item -LiteralPath $etl).Length;$state.sha256=(Get-FileHash -LiteralPath $etl).Hash
            }else{$state.status='StopFailed';$state.errorType='TraceSaveFailed'}
        }
        $state.ended=Get-ClockPoint;Save-TraceState
    }
    return $state

}
