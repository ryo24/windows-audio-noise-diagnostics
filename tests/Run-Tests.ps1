$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Core.ps1')
. (Join-Path $root 'scripts\Inventory.ps1')
$script:checks=0
function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw ('FAIL: ' + $Message) }; $script:checks++; Write-Host ('PASS: ' + $Message) }
function Invoke-TestGit {
    param([string]$Directory,[string[]]$Arguments)
    $oldPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    $result=& git -C $Directory @Arguments 2>&1
    $code=$LASTEXITCODE
    $ErrorActionPreference=$oldPreference
    if ($code -ne 0) { throw ('Git failed: ' + ($Arguments -join ' ') + ' / ' + ($result -join ' ')) }
    return $result
}
function Invoke-Updater {
    param([string]$Directory,[string]$Script=(Join-Path $root 'scripts\Update-Tool.ps1'))
    $process=New-Object Diagnostics.Process
    $process.StartInfo.FileName='powershell.exe'
    $process.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" -NoPause'
    if ((Split-Path -Leaf $Script) -ne 'Launch-Update.ps1') { $process.StartInfo.Arguments += ' -RepositoryRoot "' + $Directory + '"' }
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    $process.StartInfo.StandardOutputEncoding=[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $process.StartInfo.StandardErrorEncoding=$process.StartInfo.StandardOutputEncoding
    [void]$process.Start()
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Updater test timed out' }
    $result=[pscustomobject]@{ code=$process.ExitCode; text=$outTask.Result + $errTask.Result }
    $process.Dispose()
    return $result
}

# All fixtures live below a known temporary workspace. Never delete outside it.
$temporary=Join-Path (Join-Path $root 'test-output') ([guid]::NewGuid().ToString('N') + " 日本語 O'Brien")
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $parseErrors=@()
    foreach ($file in @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') + @(Get-Item $PSCommandPath)) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        $parseErrors+=@($errors)
    }
    Assert-True ($parseErrors.Count -eq 0) 'All PowerShell files parse'
    Initialize-AudioInterop
    Assert-True ($null -ne ('AudioNoiseDiagnostics.Endpoint' -as [type])) 'Core Audio reader compiles'
    $profile=[pscustomobject]@{ speakerModel='Test speaker'; powerSource='PCのUSB'; cStates='Disabled'; observations='<script>alert(1)</script>' }
    $session=New-DiagnosticSession $profile
    $directory=Join-Path $temporary 'session'
    Save-Session $session $directory
    $loaded=Read-Session (Join-Path $directory 'session.json')
    Assert-True (@($loaded.tests).Count -eq 0) 'An empty session can be resumed'
    $assessment=(Get-Assessment $loaded | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('C-Statesは確認済み') -and $assessment.Contains('基準条件の再現記録が必要')) 'Disabled C-States skipped; missing baseline remains visible'
    $loaded.profile.cStates='Unknown'
    $genericAssessment=(Get-Assessment $loaded | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($genericAssessment.Contains('BIOS設定は任意の記録') -and -not $genericAssessment.Contains('GMKtec')) 'Unknown manufacturers receive generic guidance without vendor BIOS advice'
    $loaded.inventory=[pscustomobject]@{ computer=[pscustomobject]@{ status='collected'; data=[pscustomobject]@{manufacturer='Other PC Vendor'} } }
    Assert-True (-not (Get-ReportHtml $loaded).Contains('GMKtec')) 'Other vendors do not receive GMKtec-specific report sources'
    $loaded.inventory.computer.data.manufacturer='GMKtec'
    Assert-True ((Get-ReportHtml $loaded).Contains('GMKtec機種向けの参考情報')) 'Matching manufacturer exposes clearly labeled vendor references'
    $test=New-TestRecord 'baseline35' '3.5mm' 'PCのUSB' '<script>alert(1)</script>' 'baseline' '=HYPERLINK("https://example.invalid")'
    $test.result='Unchanged'; $test.durationSeconds=600; $test.endedUtc=[DateTime]::UtcNow.ToString('o'); $test.noiseUtc=@([DateTime]::UtcNow.ToString('o'))
    $session.tests=@($test)
    $powerTest=New-TestRecord 'independentPower' '3.5mm' '独立したUSB電源' 'Test player' 'USB power only' 'test'
    $powerTest.result='NotRun'; $session.tests+=@($powerTest)
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True (-not $assessment.Contains('USB給電の影響が候補')) 'Skipped power comparison never counts as improvement'
    Assert-True ($assessment.Contains('3. スピーカーのUSB給電を変更')) 'Remaining prerequisite visible after baseline completed'
    $powerTest.result='NoRepro'; $powerTest.durationSeconds=30
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('USB給電の影響が候補') -and $assessment.Contains('観察時間が短い')) 'Comparison changes guidance and exposes short observation'
    $powerTest.noiseUtc=@([DateTime]::UtcNow.ToString('o'))
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('結果とノイズ記録の食い違い') -and -not $assessment.Contains('USB給電の影響が候補')) 'Conflicting no-reproduction records cannot imply a clean comparison'
    $powerTest.noiseUtc=@()
    $test.noiseUtc=@(); $test.result='NoRepro'
    $assessment=(Get-Assessment $session | ForEach-Object { $_.title + $_.text }) -join ' '
    Assert-True ($assessment.Contains('基準条件の再現記録が必要') -and -not $assessment.Contains('USB給電の影響が候補')) 'No reproduction is not proof of improvement'
    $test.noiseUtc=@([DateTime]::UtcNow.ToString('o')); $test.result='Unchanged'
    $hdmi=New-TestRecord 'hdmi' 'HDMI' '該当なし' 'Test' 'HDMI' ''
    $hdmi.result='Unchanged'; $hdmi.noiseUtc=@([DateTime]::UtcNow.ToString('o')); $hdmi.durationSeconds=600; $session.tests+=@($hdmi)
    Assert-True (((Get-Assessment $session | ForEach-Object { $_.title }) -join ' ').Contains('HDMIにも発生')) 'New HDMI evidence supersedes the initial assumption'
    $session.inventory=[pscustomobject]@{ computer=[pscustomobject]@{status='unavailable';data=$null;errorType='TestFailure'} }
    Save-Session $session $directory
    $loaded=Read-Session (Join-Path $directory 'session.json')
    Assert-True ($loaded.tests.Count -eq 3 -and $loaded.tests[0].noiseUtc.Count -eq 1 -and $loaded.tests[0].tool.version -eq $session.tool.version) 'JSON preserves tests, markers and tool identities'
    Assert-True ($loaded.inventory.computer.status -eq 'unavailable') 'Partial collection failure stays visible'
    $html=Get-Content -LiteralPath (Join-Path $directory 'report.html') -Raw -Encoding UTF8
    Assert-True ($html.Contains('&lt;script&gt;') -and -not $html.Contains('<script>')) 'HTML escapes untrusted notes'
    $csv=Import-Csv -LiteralPath (Join-Path $directory 'tests.csv') -Encoding UTF8
    Assert-True ($csv.Count -eq 3 -and $csv[0].notes.StartsWith("'=")) 'CSV protects against formula injection and preserves rows'
    Assert-True ([int]$csv[0].noise_count -eq $loaded.tests[0].noiseUtc.Count) 'CSV and JSON agree on markers'
    # Mock the external reads so the test checks orchestration and persistence, not this PC.
    function Get-RelatedEvents { param($Start,$End); [pscustomobject]@{ events=@(); marker='fixture-events' } }
    function Get-AudioDeviceInventory { param($Salt); [pscustomobject]@{ devices=@([pscustomobject]@{ name='fixture-audio'; driver=[pscustomobject]@{version='2.0'} }) } }
    $evidence=Get-TestEvidence -Start ([DateTime]::UtcNow.AddMinutes(-10)) -End ([DateTime]::UtcNow) -Salt 'fixture' -IncludeDrivers
    $powerTest | Add-Member -NotePropertyName driverSnapshot -NotePropertyValue $evidence.driverSnapshot
    Save-Session $session $directory
    $withSnapshot=Read-Session (Join-Path $directory 'session.json')
    Assert-True ($withSnapshot.tests[1].driverSnapshot.audioDevices.data.devices[0].driver.version -eq '2.0') 'A changed driver snapshot survives session serialization'
    $withoutDrivers=Get-TestEvidence -Start ([DateTime]::UtcNow) -End ([DateTime]::UtcNow) -Salt 'fixture'
    Assert-True ($null -eq $withoutDrivers.driverSnapshot -and $withoutDrivers.relatedEvents.marker -eq 'fixture-events') 'Regular tests collect events without relabeling initial drivers as current'
    $source=Join-Path $temporary 'future.json'
    $future=$session | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $future.schemaVersion=999
    Write-AtomicText $source ($future | ConvertTo-Json -Depth 20)
    $before=[IO.File]::ReadAllText($source); $rejected=$false
    try { Read-Session $source | Out-Null } catch { $rejected=$true }
    Assert-True ($rejected -and [IO.File]::ReadAllText($source) -eq $before) 'Unsupported schemas reject without altering the source'
    $partial=Invoke-CollectionSection { throw 'fixture' }
    Assert-True ($partial.status -eq 'unavailable' -and $null -eq $partial.data) 'Collection errors never look like successful empty data'
    $deviceRef=Get-AnonymousDeviceRef 'USB\VID_1234&PID_5678\PRIVATE_SERIAL' 'a'
    Assert-True ($deviceRef -notmatch 'PRIVATE' -and $deviceRef -ne (Get-AnonymousDeviceRef 'USB\VID_1234&PID_5678\PRIVATE_SERIAL' 'b')) 'Device references are anonymized per session'

    $audioRoot=Join-Path $temporary 'audio-source'
    [IO.Directory]::CreateDirectory($audioRoot) | Out-Null
    $probeRecord=New-AudioProbeRecord 'Reference' 'Speakers <unsafe>' '' 60
    $reference=Resolve-AudioFile $audioRoot $probeRecord.files.reference
    [IO.Directory]::CreateDirectory((Split-Path -Parent $reference)) | Out-Null
    [AudioNoiseDiagnostics.AudioFiles]::GenerateReference($reference)
    $secondReference=Join-Path $temporary 'reference-copy.wav'
    [AudioNoiseDiagnostics.AudioFiles]::GenerateReference($secondReference)
    $referenceWave=[AudioNoiseDiagnostics.WaveData]::Load($reference)
    Assert-True ($referenceWave.Frames -eq 480000 -and $referenceWave.Format.Rate -eq 48000 -and $referenceWave.Format.Channels -eq 2 -and $referenceWave.Format.Bits -eq 16) 'Reference audio is a fixed ten-second 48 kHz stereo PCM WAV'
    Assert-True ((Get-FileHash -LiteralPath $reference).Hash -eq (Get-FileHash -LiteralPath $secondReference).Hash) 'Generated reference audio is byte-identical across runs'
    $peak=0.0
    for($frame=0;$frame -lt $referenceWave.Frames;$frame+=113){$peak=[Math]::Max($peak,[Math]::Abs($referenceWave.Sample($frame,0)))}
    Assert-True ($peak -gt 0.07 -and $peak -le 0.0801 -and $referenceWave.Sample(1000,0) -eq 0 -and $referenceWave.Sample(470000,1) -eq 0) 'Reference level is bounded and includes deliberate silent intervals'
    $recordingPath=Resolve-AudioFile $audioRoot $probeRecord.files.recording
    Copy-Item -LiteralPath $reference -Destination $recordingPath
    $fixtureRecorder=[pscustomobject]@{Status='Completed';StartedUtc=[DateTime]::UtcNow.ToString('o');EndedUtc=[DateTime]::UtcNow.ToString('o');ElapsedSeconds=10;SampleRate=48000;Channels=2;Bits=16;CapturedFrames=480000;WrittenFrames=480000;InsertedSilenceFrames=0;PacketCount=100;Discontinuities=1;TimestampErrors=0;FlagEvents=@();SizeLimitReached=$false;ReferenceStartOffsetSeconds=0.1;ErrorCode=$null}
    Complete-AudioProbeRecord $probeRecord $fixtureRecorder $audioRoot
    Assert-True ($probeRecord.files.recordingSha256 -eq (Get-FileHash -LiteralPath $recordingPath).Hash -and $probeRecord.capture.discontinuities -eq 1) 'Recording metadata preserves hashes and stream flags without calling them audible noise'
    $probeSession=New-DiagnosticSession $profile;$probeSession.audioProbes=@($probeRecord)
    $probeRecord.verification.liveNoise='Yes';$probeRecord.verification.replayNoise='No'
    $probeRecord.verification.reviewPlaybackCompleted=$false
    Assert-True ((Get-AudioReportHtml $probeSession).Contains('照合は未完了')) 'Incomplete WAV replay cannot count as completed listening verification'
    $probeRecord.verification.reviewPlaybackCompleted=$true
    $audioHtml=Get-AudioReportHtml $probeSession
    Assert-True ($audioHtml.Contains('PCが正常という判定にはしません') -and -not $audioHtml.Contains('<unsafe>')) 'Live noise absent from replay stays an unresolved finding and untrusted metadata is escaped'
    $probeRecord.verification.replayNoise='Yes'
    Assert-True ((Get-AudioReportHtml $probeSession).Contains('再生する出力側が新たにノイズ')) 'Noisy replay does not exclude noise added by the playback path'
    $destination=Join-Path $temporary 'audio-import'
    Import-SessionAudio $probeSession $audioRoot $destination
    $imported=Resolve-AudioFile $destination $probeRecord.files.recording
    Assert-True ((Get-FileHash -LiteralPath $imported).Hash -eq $probeRecord.files.recordingSha256) 'Session import copies referenced WAV files with their recorded hashes'
    [IO.File]::WriteAllText($imported,'different local file')
    $blocked=$false;try{Import-SessionAudio $probeSession $audioRoot $destination}catch{$blocked=$true}
    Assert-True ($blocked -and [IO.File]::ReadAllText($imported) -eq 'different local file') 'Session import never overwrites a different local WAV'
    $blocked=$false;try{Resolve-AudioFile $audioRoot '..\outside.wav' | Out-Null}catch{$blocked=$true}
    Assert-True ($blocked) 'Audio paths cannot escape their session directory'
    $probeRecord.status='NoAudioData'
    Assert-True ((Get-AudioReportHtml $probeSession).Contains('ノイズなしとは判定できません')) 'No loopback packets cannot be interpreted as clean output'
    $externalRecord=New-AudioProbeRecord 'ExternalApp' 'Fixture' '' 60
    Assert-True ($null -eq $externalRecord.files.reference -and $null -eq $externalRecord.referenceId) 'External application recording does not schedule a reference tone'
    Save-Session $probeSession $audioRoot
    $savedProbe=Read-Session (Join-Path $audioRoot 'session.json')
    Assert-True ($savedProbe.audioProbes[0].verification.liveNoise -eq 'Yes' -and $savedProbe.audioProbes[0].files.recordingSha256 -eq $probeRecord.files.recordingSha256) 'Audio capture and independent listening results round-trip in a compatible session log'

    & {
        function Read-WinRtBluetoothRadios { [pscustomobject]@{state='On';radioStates=@('On')} }
        function Read-WinRtPairedEndpoints {
            param($Protocol)
            @([pscustomobject]@{rawId=($Protocol + '\AA:BB:CC:DD:EE:FF');connected=$true},[pscustomobject]@{rawId=($Protocol+'\private-id');connected=$false})
        }
        $bt=Get-BluetoothState 'fixture-salt'
        Assert-True ((Get-BluetoothStateSummary $bt).connectedEndpointCount -eq 2) 'Classic and LE connected flags are counted as endpoints, not device identities'
        $serialized=$bt | ConvertTo-Json -Depth 15
        Assert-True (-not $serialized.Contains('AA:BB:CC:DD:EE:FF') -and -not $serialized.Contains('private-id')) 'Bluetooth identifiers and MAC addresses never enter serialized endpoint data'
        function Read-WinRtPairedEndpoints { param($Protocol); if ($Protocol -eq 'LE') { throw 'unavailable' }; [pscustomobject]@{rawId='fixture';connected=$null} }
        $partialBt=Get-BluetoothState 'fixture-salt'
        Assert-True ($partialBt.lowEnergy.status -eq 'unavailable' -and $null -eq (Get-BluetoothStateSummary $partialBt).connectedEndpointCount) 'Unavailable and unknown connection state never becomes zero connections'
        $nullRadio=[pscustomobject]@{radio=[pscustomobject]@{status='collected';data=[pscustomobject]@{state='Unknown'}}}
        Assert-True ((Get-BluetoothStateSummary $nullRadio).radioState -eq 'Unknown') 'An unexposed radio is not reported as off'
    }
    & {
        function Get-WinEvent {
            param($FilterHashtable,$MaxEvents,$ErrorAction)
            @([pscustomobject]@{ProviderName='BTHUSB';Id=17;Level=3;TimeCreated=[DateTime]::UtcNow},[pscustomobject]@{ProviderName='Microsoft-Windows-Bluetooth-Policy';Id=18;Level=2;TimeCreated=[DateTime]::UtcNow},[pscustomobject]@{ProviderName='Unrelated';Id=99;Level=2;TimeCreated=[DateTime]::UtcNow})
        }
        # Restore the real reader locally, after an earlier fixture overrode it.
        . (Join-Path $root 'scripts\Inventory.ps1')
        $events=Get-RelatedEvents
        Assert-True ($events.events.Count -eq 4 -and @($events.events | Where-Object { $_.provider -eq 'Unrelated' }).Count -eq 0) 'Bluetooth provider events are retained without unrelated events or raw messages'
    }
    & {
        function Get-PnpDevice {
            param([switch]$PresentOnly,$ErrorAction)
            @([pscustomobject]@{InstanceId='USB\VID_1234&PID_ABCD\ADAPTER_SERIAL';Class='Bluetooth';FriendlyName='Private radio name';Status='OK'},[pscustomobject]@{InstanceId='BTHENUM\DEV_AABBCCDDEEFF\PRIVATE';Class='Bluetooth';FriendlyName='Private device AA:BB:CC:DD:EE:FF';Status='OK'},[pscustomobject]@{InstanceId='HID\private-bt-input';Class='Keyboard';FriendlyName='Private keyboard';Status='OK'},[pscustomobject]@{InstanceId='USB\private-wired';Class='Keyboard';FriendlyName='Wired keyboard';Status='OK'})
        }
        function Get-CimInstance {
            param($ClassName,$OperationTimeoutSec,$ErrorAction)
            [pscustomobject]@{DeviceID='USB\VID_1234&PID_ABCD\ADAPTER_SERIAL';DriverProviderName='Fixture vendor';DriverVersion='1.2.3';DriverDate=[DateTime]'2026-01-01';InfName='fixture.inf'}
        }
        function Get-PnpDeviceProperty {
            param($InstanceId,$KeyName,$ErrorAction)
            $parent=switch ($InstanceId) { 'HID\private-bt-input' {'BTHENUM\DEV_AABBCCDDEEFF\PRIVATE'}; 'BTHENUM\DEV_AABBCCDDEEFF\PRIVATE' {'USB\VID_1234&PID_ABCD\ADAPTER_SERIAL'}; default {$null} }
            [pscustomobject]@{Data=$parent}
        }
        $pnpBt=Get-BluetoothDeviceInventory 'fixture'
        $pnpJson=$pnpBt | ConvertTo-Json -Depth 12
        Assert-True (@($pnpBt.devices | Where-Object { $_.role -eq 'adapter' -and $_.driver.version -eq '1.2.3' }).Count -eq 1 -and @($pnpBt.devices | Where-Object { $_.class -eq 'Keyboard' }).Count -eq 1) 'Bluetooth adapter drivers and related HID nodes are collected without unrelated wired keyboards'
        Assert-True (-not $pnpJson.Contains('PRIVATE') -and -not $pnpJson.Contains('AA:BB:CC:DD:EE:FF') -and -not $pnpJson.Contains('ADAPTER_SERIAL')) 'Bluetooth PnP inventory excludes names, addresses and serials'
    }
    $btSession=New-DiagnosticSession $profile
    $btOff=New-TestRecord 'btRadioOff' '3.5mm' 'PCのUSB' 'same player' 'off' ''
    $btOff.result='NoRepro';$btOff.durationSeconds=600;$btOff.bluetoothCondition='RadioOff'
    $offSnapshot=[pscustomobject]@{capturedUtc='2026-11-19T00:00:00.0000000Z';radio=[pscustomobject]@{status='collected';data=[pscustomobject]@{state='Off'}};classic=[pscustomobject]@{status='collected';data=[pscustomobject]@{knownConnectedCount=0;unknownConnectionCount=0}};lowEnergy=[pscustomobject]@{status='collected';data=[pscustomobject]@{knownConnectedCount=0;unknownConnectionCount=0}};durationMilliseconds=10}
    $btOff.bluetoothSamples=@($offSnapshot)
    $btOn=New-TestRecord 'btKeyboardTyping' '3.5mm' 'PCのUSB' 'same player' 'typing' ''
    $btOn.result='Unchanged';$btOn.durationSeconds=600;$btOn.noiseUtc=@('2026-11-19T00:00:05.0000000Z');$btOn.bluetoothCondition='KeyboardConnected';$btOn.inputActivity='BluetoothTyping'
    $onSnapshot=$offSnapshot | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $onSnapshot.radio.data.state='On';$btOn.bluetoothSamples=@($onSnapshot)
    $btSession.tests=@($btOff,$btOn)
    $btAdvice=(Get-BluetoothAssessment $btSession | ForEach-Object { $_.title }) -join ' '
    Assert-True ($btAdvice.Contains('Bluetooth状態に伴う差が候補')) 'Matched off/on reproduction produces a hypothesis, not a model-specific diagnosis'
    $btOn.power='独立したUSB電源'
    Assert-True (-not ((Get-BluetoothAssessment $btSession | ForEach-Object { $_.title }) -join ' ').Contains('Bluetooth状態に伴う差が候補')) 'Changed power conditions do not qualify as a controlled Bluetooth comparison'
    $btOn.power='PCのUSB';$btOff.bluetoothSamples=@($onSnapshot)
    $conflictAdvice=(Get-BluetoothAssessment $btSession | ForEach-Object { $_.title }) -join ' '
    Assert-True ($conflictAdvice.Contains('Bluetooth条件と取得状態の食い違い') -and -not $conflictAdvice.Contains('Bluetooth状態に伴う差が候補')) 'Declared off versus observed on is exposed and cannot imply a controlled comparison'
    $btOff.bluetoothSamples=@($offSnapshot)
    $nearest=Get-NearestBluetoothObservation $btOn $btOn.noiseUtc[0]
    Assert-True ($nearest.offsetSeconds -eq -5) 'Noise correlation reports the signed time gap instead of claiming simultaneous traffic'
    Save-Session $btSession $directory
    $btLoaded=Read-Session (Join-Path $directory 'session.json')
    $btCsv=Import-Csv (Join-Path $directory 'bluetooth.csv') -Encoding UTF8
    Assert-True ($btLoaded.tests[1].inputActivity -eq 'BluetoothTyping' -and $btCsv.Count -eq 2 -and $btCsv[0].radio_state -eq 'Off') 'Bluetooth conditions, samples and CSV round-trip without changing the schema'
    Assert-True ((Get-ReportHtml $btLoaded).Contains('ノイズ発生瞬間の通信を測った値ではありません')) 'Reports disclose the limits of sampled connection state'
    $fixtureInventory=Join-Path $temporary 'monitor-fixture.ps1'
    Write-AtomicText $fixtureInventory 'function Get-BluetoothState { param($Salt); [pscustomobject]@{capturedUtc=[DateTime]::UtcNow.ToString("o");fixture=$true} }'
    $monitor=Start-BluetoothMonitor -Salt 'fixture' -InventoryPath $fixtureInventory -IntervalSeconds 0 -MaxSamples 2
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while (-not $monitor.handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        [void]$monitor.worker.EndInvoke($monitor.handle)
        Assert-True ($monitor.queue.Count -eq 2) 'Background sampling enforces its cap and retains the final queued sample'
    } finally { $monitor.worker.Dispose();$monitor.cancel.Dispose() }
    $monitor=Start-BluetoothMonitor -Salt 'fixture' -InventoryPath $fixtureInventory -IntervalSeconds 10 -MaxSamples 720
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while ($monitor.queue.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        [void]$monitor.cancel.Set()
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while (-not $monitor.handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        Assert-True ($monitor.handle.IsCompleted -and $monitor.queue.Count -eq 1) 'Stopping a test cancels the sampling wait without losing its first observation'
        [void]$monitor.worker.EndInvoke($monitor.handle)
    } finally { $monitor.worker.Dispose();$monitor.cancel.Dispose() }

    $remote=Join-Path $temporary 'remote.git'; $author=Join-Path $temporary 'author'; $client=Join-Path $temporary 'client'
    [IO.Directory]::CreateDirectory($remote) | Out-Null
    Invoke-TestGit $remote @('init','--bare','--initial-branch=main') | Out-Null
    Invoke-TestGit $temporary @('clone',$remote,$author) | Out-Null
    foreach ($repo in @($author)) {
        Invoke-TestGit $repo @('config','user.name','Test Author') | Out-Null
        Invoke-TestGit $repo @('config','user.email','test@example.invalid') | Out-Null
        Invoke-TestGit $repo @('config','commit.gpgsign','false') | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $author '.gitignore'),"/data/`n")
    [IO.File]::WriteAllText((Join-Path $author 'version.txt'),'one')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Update-Tool.ps1') -Destination (Join-Path $author 'Update-Tool.ps1')
    [IO.Directory]::CreateDirectory((Join-Path $author 'scripts')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Update-Tool.ps1') -Destination (Join-Path $author 'scripts\Update-Tool.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'scripts\Launch-Update.ps1') -Destination (Join-Path $author 'scripts\Launch-Update.ps1')
    Invoke-TestGit $author @('add','.') | Out-Null
    Invoke-TestGit $author @('commit','-m','initial') | Out-Null
    Invoke-TestGit $author @('push','origin','main') | Out-Null
    Invoke-TestGit $temporary @('clone',$remote,$client) | Out-Null
    Invoke-TestGit $client @('config','user.name','Test Author') | Out-Null
    Invoke-TestGit $client @('config','user.email','test@example.invalid') | Out-Null
    Invoke-TestGit $client @('config','commit.gpgsign','false') | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $client 'data')) | Out-Null
    $privateLog=Join-Path $client 'data\session.json'
    [IO.File]::WriteAllText($privateLog,'private fixture')
    $lock=[IO.File]::Open((Join-Path $client 'data\tool.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $update=Invoke-Updater $client; Assert-True ($update.code -ne 0) 'Updater refuses while a diagnostic session holds the lock' } finally { $lock.Dispose() }
    [IO.File]::WriteAllText((Join-Path $author 'version.txt'),'two')
    Add-Content -LiteralPath (Join-Path $author 'Update-Tool.ps1') -Value '# Updated runner fixture' -Encoding UTF8
    Invoke-TestGit $author @('add','.') | Out-Null; Invoke-TestGit $author @('commit','-m','update') | Out-Null; Invoke-TestGit $author @('push','origin','main') | Out-Null
    $runner=Join-Path $temporary 'detached-runner.ps1'; Copy-Item (Join-Path $client 'Update-Tool.ps1') $runner
    $update=Invoke-Updater $client $runner
    Assert-True ($update.code -eq 0) 'Fast-forward succeeds'
    Assert-True ([IO.File]::ReadAllText((Join-Path $client 'version.txt')) -eq 'two') 'The requested update was applied'
    Assert-True ((Get-Content (Join-Path $client 'Update-Tool.ps1') -Raw).Contains('# Updated runner fixture')) 'An updater can update itself from a detached copy'
    Assert-True ([IO.File]::ReadAllText($privateLog) -eq 'private fixture') 'Past diagnostic logs survive an update'
    $update=Invoke-Updater $client
    Assert-True ($update.code -eq 0) 'Already-current updates succeed'
    $update=Invoke-Updater $client (Join-Path $client 'scripts\Launch-Update.ps1')
    Assert-True ($update.code -eq 0) 'Detached bootstrap launches from a Japanese path with an apostrophe'
    [IO.File]::WriteAllText((Join-Path $client 'version.txt'),'local edit')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and [IO.File]::ReadAllText((Join-Path $client 'version.txt')) -eq 'local edit') 'Tracked local changes are never overwritten'
    $update=Invoke-Updater $client (Join-Path $client 'scripts\Launch-Update.ps1')
    Assert-True ($update.code -ne 0) 'Bootstrap propagates update failures to its caller'
    Invoke-TestGit $client @('restore','version.txt') | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'untracked.txt'),'keep')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Test-Path (Join-Path $client 'untracked.txt'))) 'Untracked files are preserved and stop updates'
    Remove-Item -LiteralPath (Join-Path $client 'untracked.txt')
    Invoke-TestGit $client @('remote','set-url','origin',(Join-Path $temporary 'missing-remote.git')) | Out-Null
    $head=Invoke-TestGit $client @('rev-parse','HEAD')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Fetch failure preserves the installed revision'
    Invoke-TestGit $client @('remote','set-url','origin',$remote) | Out-Null
    [IO.File]::WriteAllText((Join-Path $client 'local.txt'),'local commit')
    Invoke-TestGit $client @('add','local.txt') | Out-Null; Invoke-TestGit $client @('commit','-m','local-only') | Out-Null
    $head=Invoke-TestGit $client @('rev-parse','HEAD')
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Local-only commits are not reset or silently published'
    [IO.File]::WriteAllText((Join-Path $author 'remote.txt'),'remote commit')
    Invoke-TestGit $author @('add','remote.txt') | Out-Null; Invoke-TestGit $author @('commit','-m','remote-only') | Out-Null; Invoke-TestGit $author @('push','origin','main') | Out-Null
    $update=Invoke-Updater $client
    Assert-True ($update.code -ne 0 -and (Invoke-TestGit $client @('rev-parse','HEAD')) -eq $head) 'Diverged histories stop without a reset'
    Assert-True ([IO.File]::ReadAllText($privateLog) -eq 'private fixture') 'Logs survive every failure path'
    Write-Host ('All ' + $script:checks + ' checks passed.') -ForegroundColor Green
} finally {
    $expectedRoot=[IO.Path]::GetFullPath((Join-Path $root 'test-output')) + [IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($temporary)
    if ($resolved.StartsWith($expectedRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
