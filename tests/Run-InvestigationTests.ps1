$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1');. (Join-Path $root 'scripts/Inventory.ps1')
$checks=0
function Assert-Investigation {param([bool]$Value,[string]$Message);if(-not $Value){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
$directory=Join-Path (Join-Path $root 'test-output') ('investigation-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($directory)|Out-Null
try {
    $redacted=Protect-InvestigationText 'C:\Users\PrivateName\x USB\VID_ABCD&PID_1001\PRIVATE_SERIAL USB#VID_ABCD&PID_1001#OTHER_SERIAL#{guid}' ''
    Assert-Investigation ($redacted -notmatch 'PrivateName|PRIVATE_SERIAL|OTHER_SERIAL' -and $redacted.Contains('VID_ABCD')) 'Command/event text retains hardware identity without user folders or instance suffixes'
    $failure=Invoke-InvestigationSection {throw 'fixture section failed'} $directory
    Assert-Investigation ($failure.status -eq 'unavailable' -and $failure.error.message -eq 'fixture section failed' -and $failure.started.qpc -le $failure.ended.qpc) 'Collection failures retain explicit messages, timing and status'
    Initialize-AudioInterop
    $reference=Join-Path $directory 'reference.wav';$delayed=Join-Path $directory 'delayed.wav';$changed=Join-Path $directory 'changed.wav';$silent=Join-Path $directory 'silent.wav'
    [AudioNoiseDiagnostics.AudioFiles]::GenerateReference($reference);$wave=[AudioNoiseDiagnostics.WaveData]::Load($reference)
    $sink=New-Object AudioNoiseDiagnostics.WaveSink($delayed,$wave.Format)
    try{$sink.Silence(4800);$sink.Write($wave.Data,$wave.Data.Length)}finally{$sink.Dispose()}
    $comparison=[AudioNoiseDiagnostics.AudioFiles]::CompareReference($delayed,$reference)
    Assert-Investigation ($comparison.Status -eq 'SampleExactInComparedRegion' -and $comparison.OffsetFrames -eq 4800 -and $comparison.ComparedFrames -eq 480000 -and $comparison.DifferentSamples -eq 0) 'Automatic reference comparison aligns delayed audio and verifies all subsequent samples'
    $bytes=$wave.Data.Clone();$bytes[48000*6*4]=$bytes[48000*6*4] -bxor 1
    $sink=New-Object AudioNoiseDiagnostics.WaveSink($changed,$wave.Format);try{$sink.Write($bytes,$bytes.Length)}finally{$sink.Dispose()}
    $comparison=[AudioNoiseDiagnostics.AudioFiles]::CompareReference($changed,$reference)
    Assert-Investigation ($comparison.Status -eq 'DifferentOrUnaligned' -and $comparison.DifferentSamples -eq 1) 'A sample difference is retained without labeling its cause as audible noise'
    $sink=New-Object AudioNoiseDiagnostics.WaveSink($silent,$wave.Format);try{$sink.Silence(480000)}finally{$sink.Dispose()}
    Assert-Investigation ([AudioNoiseDiagnostics.AudioFiles]::CompareReference($silent,$reference).Status -eq 'NoReferenceOnset') 'Silent/missing reference audio cannot become a clean comparison'
    & {
        # Exercise the full real-helper control path using synthetic native/OS adapters.
        # No elevation, services/settings changes or actual ETW sessions are requested.
        function Test-TraceAdministrator {return $true}
        function Get-UsbTraceProviders {@([pscustomobject]@{name='fixture';id=[guid]::Empty.ToString();keywords='0x8243';level=5})}
        function Get-UsbTargetSnapshot {param($EndpointRef,$Salt);[pscustomobject]@{status='collected';endpointRef=$EndpointRef;physicalRef='PHY';vid='ABCD';pid='1001';portPath=@(4);sameVidPidDevices=1;chain=@([pscustomobject]@{ref=$EndpointRef},[pscustomobject]@{ref='PHY'});missing=@()}}
        function Get-InvestigationSnapshot {param($Target,$Salt,$SessionDirectory,$Heartbeat);if($Heartbeat){& $Heartbeat};[pscustomobject]@{point=Get-ClockPoint;audio=[pscustomobject]@{status='collected'};devices=[pscustomobject]@{status='collected';data=@([pscustomobject]@{ref='PHY'})};powerPlan=[pscustomobject]@{status='collected';data=[pscustomobject]@{exitCode=0;stdout='fixture power plan'}}}}
        function Get-InvestigationSample {param($SessionDirectory,$Target,$Salt);[pscustomobject]@{point=Get-ClockPoint;cpu=[pscustomobject]@{status='collected';data=@()}}}
        function Get-InvestigationEvents {param($Start,$End,$SessionDirectory);[pscustomobject]@{status='collected';data=[pscustomobject]@{events=@();scanned=0}}}
        function Get-WinEvent {
            param($Path,[switch]$Oldest,$MaxEvents,$ErrorAction)
            if($script:failEventRead){throw 'Synthetic ETL read error'}
            $obj=[pscustomobject]@{ProviderName='Microsoft-Windows-USB-UCX';Id=4;TimeCreated=[DateTime]::UtcNow;Xml='<Event><System><Provider Name="Microsoft-Windows-USB-UCX"/><EventID>4</EventID><TimeCreated SystemTime="2026-01-01T00:00:01Z"/></System><EventData><Data Name="fid_UsbDevice">0x201</Data><Data Name="fid_idVendor">0xABCD</Data><Data Name="fid_idProduct">0x1001</Data><Data Name="PortPath">4,0,0,0,0,0</Data></EventData></Event>'}
            $obj|Add-Member -MemberType ScriptMethod -Name ToXml -Value {$this.Xml};$obj|Add-Member -MemberType ScriptMethod -Name Dispose -Value {};return $obj
        }
        function Invoke-DiagnosticProcess {
            param($Executable,$Arguments,$Heartbeat,$OnResult)
            $begin=Get-ClockPoint;$code=0;$stdout='Synthetic success'
            if($Arguments[0] -eq 'create'){$script:fixtureUsbFile=$Arguments[[Array]::IndexOf($Arguments,'-o')+1];if($script:failNativeStart){$code=-2147024809;$stdout="Argument 'fixture' is not allowed. C:\Users\PrivateName\output"}}
            if($Arguments[0] -eq 'stop'){[IO.File]::WriteAllText($script:fixtureUsbFile,'Synthetic USB trace')}
            if($Arguments[0] -eq '-stop'){[IO.File]::WriteAllText($Arguments[1],'Synthetic Audio trace')}
            if($Heartbeat){& $Heartbeat}
            if($OnResult){& $OnResult ([pscustomobject]@{executable=[IO.Path]::GetFileName($Executable);arguments=$Arguments;started=$begin;ended=Get-ClockPoint;exitCode=$code;stdout=$stdout;stderr=''})}
            return $code
        }
        $session=New-DiagnosticSession ([pscustomobject]@{speakerModel='fixture';cStates='Unknown'});$sessionDir=Join-Path $directory 'session';Save-Session $session $sessionDir
        $test=New-TestRecord baseline35 fixture '' '' '' '';Complete-TestTiming $test;$test.result='Unchanged'
        $test|Add-Member followUp ([pscustomobject]@{kind='UsbTransfer';probeId='probe-fixture';traceId=$null});$session.tests=@($test)
        $run=New-TraceRun $sessionDir $session.id -IncludeUsb -Link ([pscustomobject]@{testId=$test.id;probeId='probe-fixture';endpointRef='1234567890ABCDEF'});$test.followUp.traceId=$run.id;Save-Session $session $sessionDir
        $script:failNativeStart=$false;$script:failEventRead=$false
        $trace=Invoke-DetailedTrace -SessionPath (Join-Path $sessionDir 'session.json') -TraceId $run.id -Seconds 1 -IncludeUsb
        Assert-Investigation ($trace.status -eq 'Completed' -and $trace.investigation.phase -eq 'Completed' -and $trace.investigation.files.Count -eq 8) 'Full helper saves before/after, samples, events, USB validation and hypothesis artifacts'
        Assert-Investigation ($trace.investigation.coverage.unavailableSections.Count -gt 0) 'Missing snapshot sections stay visible even after collection attempts complete'
        Assert-Investigation ($trace.investigation.usbValidation.status -eq 'ReadableUsbEvents' -and $trace.investigation.usbValidation.targetSelectionStatus -eq 'matched') 'Saved USB file is read and target rundown is actually correlated by the validation stage'
        Assert-Investigation ($trace.commands.Count -ge 4 -and $trace.commands[0].executable -eq 'logman.exe' -and $trace.commands[0].arguments -notcontains '--v' -and $trace.commands[0].exitHex -eq '0x00000000') 'Native command evidence retains exact operation, timestamps, exit code and output'
        $zip=Export-DiagnosticBundle $sessionDir (Join-Path $directory 'exports');$manifest=(Test-DiagnosticBundle $zip).manifest
        Assert-Investigation (@($manifest.files.path|Where-Object {$_ -like '*/investigation-*.json' -or $_ -like '*/usb-validation.json'}).Count -eq 6 -and @($manifest.files.path|Where-Object {$_ -like '*/usb-provider-schema.json' -or $_ -like '*/usb-providers.txt'}).Count -eq 2 -and $manifest.traceFileCount -eq 0) 'Ordinary ZIP includes diagnostic JSON with verified hashes while ETLs stay opt-in'
        $resume=Join-Path $directory 'resumed';Import-SessionTraces $sessionDir $resume
        Assert-Investigation ((Get-FileHash (Join-Path $resume ('traces/'+$run.id+'/investigation-before.json'))).Hash -eq ($trace.investigation.files|Where-Object name -eq 'investigation-before.json').sha256) 'Resuming preserves diagnostic sidecars with their exact original bytes'
        $script:failNativeStart=$true
        $failed=Invoke-DetailedTrace -SessionPath (Join-Path $sessionDir 'session.json') -Seconds 1 -IncludeUsb
        Assert-Investigation ($failed.status -eq 'Failed' -and $failed.commands[0].exitHex -eq '0x80070057' -and $failed.commands[0].stdout -notmatch 'PrivateName' -and $failed.commands[0].stdout.Contains('not allowed') -and $failed.investigation.files.Count -ge 5) 'Failed start still preserves native error wording and before/after diagnostics without private user paths'
        $script:failNativeStart=$false;$script:failEventRead=$true
        $readFailed=Invoke-DetailedTrace -SessionPath (Join-Path $sessionDir 'session.json') -Seconds 1 -IncludeUsb
        Assert-Investigation ($readFailed.usb.status -eq 'Completed' -and $readFailed.investigation.usbValidation.status -eq 'ReadFailed') 'Saved file and failed event inspection remain separate findings'
        $run.state.status='Inspecting';$run.stopRequested=$true
        $view=Get-TracePresentation $run $run.state Running
        Assert-Investigation ($view.phase -eq 'Inspecting' -and $view.busy -and -not $view.canStop) 'Post-save inspection is a visible busy phase, separate from stop acknowledgement'
        $test.result='NoRepro';$test.followUp|Add-Member captureStage NotStarted -Force
        Assert-Investigation (@(Get-Assessment $session|Where-Object title -eq '音声テスト未開始の試行があります').Count -eq 1 -and @(Get-Assessment $session|Where-Object title -eq '基準条件の再現記録が必要').Count -eq 0) 'Older failed/unstarted trials cannot become no-noise evidence or repeat-baseline guidance'
    }
    Write-Host ('All '+$checks+' investigation checks passed.')
}finally{
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($directory).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
    if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
}
