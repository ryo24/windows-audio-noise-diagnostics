function Invoke-DetailedTrace {
    param([string]$SessionPath,[ValidateRange(1,120)][int]$Seconds=60,[scriptblock]$WprRunner,[string]$TraceId='',[switch]$IncludeUsb,[scriptblock]$UsbRunner,[switch]$ExerciseInvestigation)
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
    $requireCaptureAck=[bool]($IncludeUsb -and $existing.requireCaptureAck)
    if($requireCaptureAck){
        $Seconds=[int]$existing.requestedSeconds
        if($Seconds -notin @(30,60)){throw 'Invalid linked capture duration'}
    }
    $stopPath=Join-Path $traceDirectory 'stop.request'
    $state=[pscustomobject]@{id=$traceId;instanceName=$instance;sessionId=$session.id;status='Starting';helperPid=$PID;command=$null;commandStarted=$null;profiles=@('GeneralProfile','Audio');mode='Memory';requestedSeconds=$Seconds;started=Get-ClockPoint;updated=$null;stopping=$null;ended=$null;stopReason=$null;sha256=$null;bytes=0;startExitCode=$null;stopExitCode=$null;markers=@();errorType=$null;scope='ETL can contain process names, file paths and system-wide activity. Memory tracing is bounded and older events can be lost. Audio and DPC/ISR coverage depends on Windows; USB transfer-level tracing is not guaranteed.'}
    $state|Add-Member -NotePropertyName link -NotePropertyValue $(if($existing){$existing.link}else{$null})
    $state|Add-Member -NotePropertyName requireCaptureAck -NotePropertyValue $requireCaptureAck
    $state|Add-Member -NotePropertyName captureHandshake -NotePropertyValue ([pscustomobject]@{
        status=if($requireCaptureAck){'NotReady'}else{'NotRequired'}
        ready=$null;acknowledged=$null;timeoutSeconds=30;readErrors=0
    })
    $state|Add-Member -NotePropertyName startupStage -NotePropertyValue 'Preparing'
    $state|Add-Member -NotePropertyName inspectionStarted -NotePropertyValue $null
    $state|Add-Member -NotePropertyName audioStatus -NotePropertyValue 'NotStarted'
    $state|Add-Member -NotePropertyName target -NotePropertyValue $null
    $state|Add-Member -NotePropertyName commands -NotePropertyValue @()
    $state|Add-Member -NotePropertyName commandsTruncated -NotePropertyValue $false
    $state|Add-Member -NotePropertyName investigation -NotePropertyValue ([pscustomobject]@{enabled=[bool]$IncludeUsb;synthetic=[bool]$WprRunner;files=@();usbValidation=$null;coverage=$null;failure=$null;phase='NotStarted'})
    $before=$null;$after=$null;$validation=$null;$samples=New-Object 'System.Collections.Generic.List[object]'
    function Save-InvestigationFile {
        param([string]$Name,$Value)
        $artifactPath=Join-Path $traceDirectory $Name
        Write-AtomicText $artifactPath ($Value|ConvertTo-Json -Depth 16)
        $state.investigation.files=@($state.investigation.files|Where-Object {$_.name -ne $Name})+@([pscustomobject]@{name=$Name;bytes=(Get-Item $artifactPath).Length;sha256=(Get-FileHash $artifactPath).Hash})
    }
    $nativeEvidence={param($nativeResult)
        if($state.commands.Count -ge 256){$state.commandsTruncated=$true;return}
        $state.commands+=@([pscustomobject]@{executable=$nativeResult.executable;arguments=@($nativeResult.arguments|ForEach-Object {Protect-InvestigationText $_ $sessionDirectory});started=$nativeResult.started;ended=$nativeResult.ended;exitCode=$nativeResult.exitCode;outputEncoding=$nativeResult.outputEncoding;outputCodePage=$nativeResult.outputCodePage;exitHex=('0x'+([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$nativeResult.exitCode),0)).ToString('X8'));stdout=Protect-InvestigationText $nativeResult.stdout $sessionDirectory;stderr=Protect-InvestigationText $nativeResult.stderr $sessionDirectory;outputTruncated=($nativeResult.stdout.Length -gt 16384 -or $nativeResult.stderr.Length -gt 16384)})
        Save-TraceState
    }
    $state|Add-Member -NotePropertyName usb -NotePropertyValue ([pscustomobject]@{requested=[bool]$IncludeUsb;instanceName=('AudioNoise-USB-'+$TraceId);status='NotRequested';providers=@();started=$null;ended=$null;startExitCode=$null;stopExitCode=$null;bytes=0;sha256=$null;errorType=$null;clock='QPC';maxMegabytes=256;mode='Circular';scope='xHCI/UCX/USBHUB3 stack, including USB 2 devices on xHCI. All devices on these stacks; not filtered to one endpoint. Transfer headers, errors, state machines and rundown; no PartialDataBusTrace or FullDataBusTrace requested. Descriptors and identifiers can be present. Circular events may be overwritten; missing events never prove normality.'})
    $stateFile=Join-Path $traceDirectory 'trace.json'
    function Save-TraceState {$state.updated=Get-ClockPoint;Write-AtomicText $stateFile ($state|ConvertTo-Json -Depth 10)}
    function Invoke-TraceCommand {
        param([string[]]$Arguments)
        # Preserve bounded, redacted native output in diagnostic command evidence.
        if($WprRunner){return (& $WprRunner ($Arguments+@('-instancename',$instance)))}
        $state.command=$Arguments[0];$state.commandStarted=Get-ClockPoint;Save-TraceState
        Invoke-WprProcess -Arguments $Arguments -Instance $instance -Heartbeat {Save-TraceState} -OnResult $nativeEvidence
    }
    function Stop-LinkedUsbTrace {
        try{Save-TraceState}catch{}
        Stop-UsbTrace $state.usb $traceDirectory $UsbRunner {Save-TraceState} $nativeEvidence
    }
    $started=$false
    try{
        Save-TraceState
        if(Test-Path -LiteralPath $stopPath){$state.status='Cancelled';$state.stopReason='RequestedBeforeStart';return $state}
        if(-not $WprRunner){
            if(-not (Test-TraceAdministrator)){throw 'Administrator privileges are required for WPR.'}
        }
        if($IncludeUsb){
            if($requireCaptureAck){
                $probe=$session.audioProbes|Where-Object id -eq $state.link.probeId|Select-Object -First 1
                $before=[pscustomobject]@{
                    point=Get-ClockPoint
                    audio=$probe.selectedOutputFormat
                    playback=$probe.playbackSnapshot
                    scope='Pre-start audio evidence from the UI. Full device, driver and power reads occur after trace save to avoid delaying playback.'
                }
                Save-InvestigationFile 'investigation-before.json' $before
            }else{
                $state.target=Get-UsbTargetSnapshot $state.link.endpointRef $session.id
                if(-not $WprRunner -or $ExerciseInvestigation){
                    $state.investigation.phase='Before'
                    $before=Get-InvestigationSnapshot $state.target $session.id $sessionDirectory {Save-TraceState}
                    Save-InvestigationFile 'investigation-before.json' $before
                    $schema=Invoke-InvestigationSection {Get-InvestigationProviderSchema} $sessionDirectory
                    Save-InvestigationFile 'usb-provider-schema.json' $schema
                }
            }
            if(Test-Path -LiteralPath $stopPath){
                $state.status='Cancelled';$state.stopReason='RequestedBeforeStart';return $state
            }
            $state.startupStage='Usb';$state.usb.status='Starting';Save-TraceState
            Start-UsbTrace $state.usb $traceDirectory $UsbRunner {Save-TraceState} $nativeEvidence
        }
        $state.startupStage='Audio'
        if($requireCaptureAck -and (Test-Path -LiteralPath $stopPath)){
            $state.stopReason='RequestedDuringStartup'
        }else{
            $state.audioStatus='Starting'
            $state.startExitCode=Invoke-TraceCommand @('-start','GeneralProfile','-start','Audio')
            if($state.startExitCode -ne 0){throw 'WPR start failed. No other trace was cancelled.'}
            $started=$true
            $state.audioStatus='Recording'
            $state.started=Get-ClockPoint
            if($requireCaptureAck){
                if(-not (Test-Path -LiteralPath $stopPath)){
                    $state.status='AwaitingCapture'
                    $state.captureHandshake.ready=Get-ClockPoint
                    $state.captureHandshake.status='Waiting'
                    Save-TraceState
                    $ackPath=Join-Path $traceDirectory 'capture-started.json'
                    $ackWait=[Diagnostics.Stopwatch]::StartNew()
                    $pulse=0
                    while($ackWait.Elapsed.TotalSeconds -lt $state.captureHandshake.timeoutSeconds -and
                        -not (Test-Path -LiteralPath $stopPath)){
                        try{$state.captureHandshake.acknowledged=Read-TraceCaptureAck $ackPath $state}
                        catch{$state.captureHandshake.readErrors++}
                        if($state.captureHandshake.acknowledged){break}
                        if($ackWait.Elapsed.TotalSeconds-$pulse -ge 1){
                            Save-TraceState;$pulse=$ackWait.Elapsed.TotalSeconds
                        }
                        Start-Sleep -Milliseconds 100
                    }
                }
                if(Test-Path -LiteralPath $stopPath){
                    $state.captureHandshake.status='Stopped'
                    $state.stopReason='RequestedDuringStartup'
                }elseif(-not $state.captureHandshake.acknowledged){
                    $state.captureHandshake.status='TimedOut'
                    $state.stopReason='CaptureAckTimeout'
                    throw 'Audio capture did not acknowledge trace readiness within 30 seconds'
                }else{$state.captureHandshake.status='Acknowledged'}
            }
        }
        if($started -and -not $state.stopReason){
            $state.status='Recording'
            $state.investigation.phase='Recording'
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $seen=@{};$lastHeartbeat=0;$lastSample=-5
            Save-TraceState
            [void](Invoke-TraceCommand @('-marker',('AudioNoiseTraceStart-'+$traceId)))
            while($clock.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path -LiteralPath $stopPath)){
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
                if($IncludeUsb -and (-not $WprRunner -or $ExerciseInvestigation) -and $samples.Count -lt 30 -and $clock.Elapsed.TotalSeconds-$lastSample -ge 5){$samples.Add((Get-InvestigationSample $sessionDirectory $state.link $session.id));$lastSample=$clock.Elapsed.TotalSeconds}
                Start-Sleep -Milliseconds 300
                if($clock.Elapsed.TotalSeconds - [double]$lastHeartbeat -ge 1){Save-TraceState;$lastHeartbeat=$clock.Elapsed.TotalSeconds}
            }
            $state.stopReason=if(Test-Path -LiteralPath $stopPath){'Requested'}else{'TimeLimit'}
        }
    }catch{$state.errorType=$_.Exception.GetType().Name;$state.investigation.failure=[pscustomobject]@{type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult;message=Protect-InvestigationText $_.Exception.Message $sessionDirectory};$state.status='Failed';if($state.audioStatus -eq 'Starting'){$state.audioStatus='StartFailed'}}
    finally{
        if($started -or $state.usb.status -eq 'Recording'){
            $state.status='Stopping'
            $state.stopping=Get-ClockPoint
            if($started){$state.audioStatus='Stopping'}
            try{Save-TraceState}catch{}
        }
        if($requireCaptureAck -and $state.usb.status -eq 'Recording'){Stop-LinkedUsbTrace}
        if($started){
            $failedBeforeStop=[bool]$state.errorType
            $etl=Join-Path $traceDirectory 'trace.etl'
            try {
                $state.stopExitCode=Invoke-TraceCommand @('-stop',$etl,'Audio noise reproduction','-skipPdbGen')
                if($state.stopExitCode -eq 0 -and (Test-Path -LiteralPath $etl) -and (Get-Item -LiteralPath $etl).Length -gt 0){
                    $state.audioStatus='Completed';$state.status=if($failedBeforeStop){'Failed'}else{'Completed'};$state.bytes=(Get-Item -LiteralPath $etl).Length;$state.sha256=(Get-FileHash -LiteralPath $etl).Hash
                }else{$state.audioStatus='StopFailed';$state.status='StopFailed';$state.errorType='TraceSaveFailed'}
            }catch{$state.audioStatus='StopFailed';$state.status='StopFailed';$state.errorType=$_.Exception.GetType().Name}
        }
        if($IncludeUsb -and $state.usb.status -eq 'Recording'){
            Stop-LinkedUsbTrace
        }
        if($state.usb.status -eq 'StopFailed'){
            $state.status='StopFailed'
            if(-not $state.errorType){$state.errorType='UsbTraceSaveFailed'}
        }elseif($state.usb.status -eq 'Completed' -and -not $started){
            $state.status=if($state.stopReason -eq 'RequestedDuringStartup'){'Cancelled'}else{'Failed'}
        }
        if($IncludeUsb -and $state.usb.status -in @('Starting','Failed')){$state.usb.status='Failed';$state.usb.errorType=$state.errorType}
        $providerArtifact=Join-Path $traceDirectory 'usb-providers.txt'
        if($IncludeUsb -and (Test-Path -LiteralPath $providerArtifact)){$state.investigation.files+=@([pscustomobject]@{name='usb-providers.txt';bytes=(Get-Item $providerArtifact).Length;sha256=(Get-FileHash $providerArtifact).Hash})}
        $state.ended=Get-ClockPoint
        if($IncludeUsb -and $state.stopReason -ne 'RequestedBeforeStart' -and (-not $WprRunner -or $ExerciseInvestigation)){
            $terminalStatus=$state.status
            try {
                $state.status='Inspecting';$state.investigation.phase='After'
                $state.inspectionStarted=Get-ClockPoint
                Save-TraceState
                if($requireCaptureAck){
                    $state.target=Get-UsbTargetSnapshot $state.link.endpointRef $session.id
                    $state.target|Add-Member -NotePropertyName collectionPhase -NotePropertyValue 'AfterTrace'
                    $state.target|Add-Member -NotePropertyName scope -Force -NotePropertyValue 'Selected output and ancestors inspected after trace save. References are session salted. Correlate to the same device in the ETL; topology can have changed.'
                    $schema=Invoke-InvestigationSection {Get-InvestigationProviderSchema} $sessionDirectory
                    Save-InvestigationFile 'usb-provider-schema.json' $schema
                }
                $after=Get-InvestigationSnapshot $state.target $session.id $sessionDirectory {Save-TraceState};Save-InvestigationFile 'investigation-after.json' $after
                Save-InvestigationFile 'investigation-samples.json' ([pscustomobject]@{samples=$samples.ToArray();intervalSeconds=5;maxSamples=30;scope='Coarse samples include collection timing and overhead. ETW is required for individual DPC/ISR stalls; low samples do not prove absence.'})
                $eventSection=Get-InvestigationEvents ([DateTime]::Parse($state.started.utc).ToUniversalTime().AddSeconds(-5)) ([DateTime]::UtcNow) $sessionDirectory;Save-InvestigationFile 'investigation-events.json' $eventSection
                if(Test-Path -LiteralPath (Join-Path $traceDirectory 'usb.etl')){$state.investigation.phase='ValidateUsb';Save-TraceState;$validation=Test-InvestigationUsbEvents (Join-Path $traceDirectory 'usb.etl') $state.target $session.id {Save-TraceState};Save-InvestigationFile 'usb-validation.json' $validation;$state.investigation.usbValidation=[pscustomobject]@{status=$validation.status;usbEventsInSample=$validation.usbEventsInSample;targetSelectionStatus=$validation.targetSelection.status;scanCapped=$validation.scanCapped}}
                Save-InvestigationFile 'investigation-hypotheses.json' ([pscustomobject]@{recordingEvidence=Invoke-InvestigationSection {$latest=Read-Session $SessionPath;$probe=@($latest.audioProbes|Where-Object {$_.id -eq $state.link.probeId});[pscustomobject]@{testId=$state.link.testId;probe=$probe|Select-Object id,testId,status,capture,selectedOutputFormat,referenceComparison,verification;physicalIds=@($latest.physicalRecordings|Where-Object {$_.testId -eq $state.link.testId}|ForEach-Object {$_.id})}} $sessionDirectory;hypotheses=@(Get-InvestigationHypotheses $state $before $after $validation);scope='Evidence availability at trace finalization, not support/refutation or diagnosis. Physical media may be imported later. Use session test/probe/media IDs and align the reference waveform.'})
                $state.investigation.coverage=Get-InvestigationCoverage $before $after $samples.ToArray() $validation $state.target
                if($schema.status -ne 'collected'){$state.investigation.coverage.unavailableSections+=@('usbProviderSchema')}
                if($eventSection.status -ne 'collected'){$state.investigation.coverage.unavailableSections+=@('systemEvents')}
                $state.investigation.phase='Completed'
            }catch{$state.investigation.phase='Partial';$state.investigation.failure=[pscustomobject]@{type=$_.Exception.GetType().Name;hresult=$_.Exception.HResult;message=Protect-InvestigationText $_.Exception.Message $sessionDirectory}}
            finally{$state.status=$terminalStatus;Save-TraceState}
        }else{Save-TraceState}
    }
    return $state

}
