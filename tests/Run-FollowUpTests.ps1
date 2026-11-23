$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1')
. (Join-Path $root 'scripts/Inventory.ps1')
$checks=0
function Assert-FollowUp {param([bool]$Value,[string]$Message);if(-not $Value){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
$directory=Join-Path (Join-Path $root 'test-output') ('follow-up-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory)|Out-Null
try{
    Initialize-AudioInterop
    $v1=Join-Path $directory 'v1.wav';$v2=Join-Path $directory 'v2.wav';$v2b=Join-Path $directory 'v2b.wav'
    [AudioNoiseDiagnostics.AudioFiles]::GenerateReference($v1)
    [AudioNoiseDiagnostics.AudioFiles]::GenerateFollowUpReference($v2,30)
    [AudioNoiseDiagnostics.AudioFiles]::GenerateFollowUpReference($v2b,30)
    Assert-FollowUp ((Get-FileHash $v2).Hash -eq (Get-FileHash $v2b).Hash) 'Indexed reference is reproducible across independent generations'
    $old=[AudioNoiseDiagnostics.WaveData]::Load($v1);$wave=[AudioNoiseDiagnostics.WaveData]::Load($v2)
    Assert-FollowUp ($wave.Format.Rate -eq 48000 -and $wave.Format.Channels -eq 2 -and $wave.Frames -eq 1440000) 'Follow-up reference has the declared duration and canonical format'
    $equal=$true;$distinct=$false;$peak=0.0
    for($i=0;$i -lt $wave.Frames;$i+=13){
        $sample=$wave.Sample($i,0);$peak=[Math]::Max($peak,[Math]::Abs($sample))
        if($i%480000 -ge 48000 -and $sample -ne $old.Sample(($i%480000),0)){$equal=$false}
        if($i -lt 48000 -and $sample -ne $wave.Sample(($i+480000),0)){$distinct=$true}
    }
    Assert-FollowUp ($equal -and $distinct -and $peak -le 0.0801) 'Numbered blocks are distinguishable, preserve existing steady tones and keep the bounded level'
    $blocked=$false;try{[AudioNoiseDiagnostics.AudioFiles]::GenerateFollowUpReference((Join-Path $directory 'invalid.wav'),301)}catch{$blocked=$true}
    Assert-FollowUp $blocked 'Indexed generation rejects out-of-range duration'
    $coverage=Get-FollowUpCoverage ([pscustomobject]@{usb=[pscustomobject]@{started=[pscustomobject]@{qpc=1300;frequency=100};ended=[pscustomobject]@{qpc=2800;frequency=100}}}) ([pscustomobject]@{capture=[pscustomobject]@{startedQpc=1000;endedQpc=3000;qpcFrequency=100}})
    Assert-FollowUp ($coverage.overlapSeconds -eq 15 -and $coverage.recordingSeconds -eq 20 -and $coverage.usbStartAfterRecordingSeconds -eq 3) 'Partial USB coverage is measured separately from recording duration'
    & {
        . (Join-Path $root 'scripts/UsbTrace.ps1')
        function Get-WinEvent {param($ListProvider,$ErrorAction);[pscustomobject]@{Id=[guid]::Empty;Keywords=@([pscustomobject]@{Name='Default';Value=1},[pscustomobject]@{Name='USBError';Value=2},[pscustomobject]@{Name='HeadersBusTrace';Value=64},[pscustomobject]@{Name='Rundown';Value=32768},[pscustomobject]@{Name='PartialDataBusTrace';Value=128},[pscustomobject]@{Name='FullDataBusTrace';Value=256})}}
        $providers=Get-UsbTraceProviders
        Assert-FollowUp ($providers.Count -eq 3 -and @($providers|Where-Object {$_.keywords -ne '0x8043'}).Count -eq 0) 'Provider masks are resolved from published metadata and exclude packet payload keywords'
        function Get-WinEvent {param($ListProvider,$ErrorAction);[pscustomobject]@{Id=[guid]::Empty;Keywords=@()}}
        $blocked=$false;try{Get-UsbTraceProviders|Out-Null}catch{$blocked=$true}
        Assert-FollowUp $blocked 'Missing header-only keywords fail explicitly instead of enabling unrestricted USB data'
    }
    function Get-UsbTraceProviders {@([pscustomobject]@{name='Microsoft-Windows-USB-USBXHCI';id=[guid]::Empty.ToString();keywords='0x8043';level=5})}
    $session=New-DiagnosticSession ([pscustomobject]@{speakerModel='fixture';cStates='Unknown'})
    $sessionRoot=Join-Path $directory 'session';Save-Session $session $sessionRoot
    $script:usbCommands=New-Object 'System.Collections.Generic.List[object]';$script:wprCommands=0;$script:failUsbStart=$false;$script:failUsbStop=$false;$script:usbPath=$null
    $usbRunner={param($a);$script:usbCommands.Add([string[]]$a);if($a[0] -eq 'create'){$script:usbPath=$a[[Array]::IndexOf($a,'-o')+1];if($script:failUsbStart){return 9}};if($a[0] -eq 'stop'){if($script:failUsbStop){return 12};[IO.File]::WriteAllText($script:usbPath,'synthetic USB ETL')};return 0}
    $wprRunner={param($a);$script:wprCommands++;if($a[0] -eq '-stop'){[IO.File]::WriteAllText($a[1],'synthetic WPR ETL')};return 0}
    $link=[pscustomobject]@{testId='fixture-test';probeId='fixture-probe';endpointRef='anonymous-ref'}
    $run=New-TraceRun $sessionRoot $session.id -IncludeUsb -Link $link
    $state=Invoke-DetailedTrace -SessionPath (Join-Path $sessionRoot 'session.json') -TraceId $run.id -Seconds 1 -IncludeUsb -UsbRunner $usbRunner -WprRunner $wprRunner
    Assert-FollowUp ($state.status -eq 'Completed' -and $state.usb.status -eq 'Completed' -and $state.link.testId -eq $link.testId) 'Linked USB and WPR traces finish and retain the planned comparison'
    Assert-FollowUp ($state.usb.started.qpc -and $state.usb.ended.qpc -and $state.usb.started.frequency -eq $state.usb.ended.frequency) 'USB capture exposes its own QPC interval instead of claiming simultaneous recording start'
    Assert-FollowUp ($state.usb.sha256 -eq (Get-FileHash (Join-Path $run.directory 'usb.etl')).Hash -and $state.sha256 -eq (Get-FileHash (Join-Path $run.directory 'trace.etl')).Hash) 'Both saved ETLs have independent hashes'
    $create=$script:usbCommands[0];$stop=$script:usbCommands[1]
    Assert-FollowUp ($create -contains '-ets' -and $create -contains 'bincirc' -and $create -contains '256' -and $create -contains 'perf' -and $stop[1] -eq ('AudioNoise-USB-'+$run.id) -and $stop -notcontains 'delete') 'USB capture is bounded, uses QPC, is ephemeral and stops only its owned instance'
    $ordinary=Export-DiagnosticBundle $sessionRoot (Join-Path $directory 'exports')
    Assert-FollowUp ((Test-DiagnosticBundle $ordinary).manifest.excludedFiles -contains ('session/traces/'+$run.id+'/usb.etl')) 'USB ETL remains excluded from the ordinary ZIP'
    $full=Export-DiagnosticBundle $sessionRoot (Join-Path $directory 'exports') -IncludeTraces
    Assert-FollowUp ((Test-DiagnosticBundle $full).manifest.files.path -contains ('session/traces/'+$run.id+'/usb.etl')) 'Explicit detailed export includes the independently hashed USB ETL'
    $copy=Join-Path $directory 'resumed';Import-SessionTraces $sessionRoot $copy
    Assert-FollowUp ((Get-FileHash (Join-Path $copy ('traces/'+$run.id+'/usb.etl'))).Hash -eq $state.usb.sha256) 'Resuming a session retains the USB artifact'
    $script:failUsbStop=$true
    $failed=Invoke-DetailedTrace -SessionPath (Join-Path $sessionRoot 'session.json') -Seconds 1 -IncludeUsb -UsbRunner $usbRunner -WprRunner $wprRunner
    Assert-FollowUp ($failed.status -eq 'StopFailed' -and $failed.usb.stopExitCode -eq 12) 'USB save failure cannot become a completed combined trace'
    $script:failUsbStop=$false;$script:failUsbStart=$true;$script:wprCommands=0
    $failed=Invoke-DetailedTrace -SessionPath (Join-Path $sessionRoot 'session.json') -Seconds 1 -IncludeUsb -UsbRunner $usbRunner -WprRunner $wprRunner
    Assert-FollowUp ($failed.status -eq 'Failed' -and $script:wprCommands -eq 0) 'USB start failure is retained and does not silently fall back to ordinary WPR'
    $script:failUsbStart=$false
    & {
        $script:heartbeatIdentityValid=$true;$script:nativeUsbFixtureRunner=$usbRunner
        function Invoke-DiagnosticProcess {
            param($Executable,$Arguments,$Heartbeat)
            & $Heartbeat
            $stateFile=Get-ChildItem (Join-Path $sessionRoot 'traces') -Filter trace.json -Recurse|Sort-Object LastWriteTime -Descending|Select-Object -First 1
            $heartbeatState=Get-Content $stateFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json
            if($heartbeatState.sessionId -ne $session.id -or -not $heartbeatState.usb.requested){$script:heartbeatIdentityValid=$false}
            & $script:nativeUsbFixtureRunner $Arguments
        }
        $heartbeatTrace=Invoke-DetailedTrace -SessionPath (Join-Path $sessionRoot 'session.json') -Seconds 1 -IncludeUsb -WprRunner $wprRunner
        Assert-FollowUp ($heartbeatTrace.status -eq 'Completed' -and $script:heartbeatIdentityValid) 'Native USB command heartbeats retain the outer trace identity and complete state'
    }
    Write-Host ('All '+$checks+' follow-up checks passed.')
}finally{
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($directory).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
}
