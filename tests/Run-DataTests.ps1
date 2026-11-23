$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1')
. (Join-Path $root 'scripts/Inventory.ps1')
$checks=0
function Assert-Data {param([bool]$Condition,[string]$Message);if(-not $Condition){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function Assert-Rejected {param([scriptblock]$Action,[string]$Message);$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-Data $failed $Message}
$temporary=Join-Path (Join-Path $root 'test-output') ('bundle-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary)|Out-Null
try{
    $test=New-TestRecord baseline35 '3.5mm' 'PC USB' player reference note
    $test.timing.start=[pscustomobject]@{utc='2026-11-23T00:00:00Z';qpc=1000;frequency=100};$test.startedUtc=$test.timing.start.utc
    Complete-TestTiming $test ([pscustomobject]@{utc='2026-11-23T00:01:00Z';qpc=5100;frequency=100})
    Update-TestDuration $test ([pscustomobject]@{utc='2026-11-23T00:02:00Z';qpc=15100;frequency=100})
    Assert-Data ($test.durationSeconds -eq 41 -and $test.timing.clockDifferenceSeconds -eq 19 -and $test.endedUtc -eq '2026-11-23T00:01:00Z') 'Finished observation never grows during result entry or late Bluetooth saves; wall/QPC disagreement remains explicit'
    $test.result='Unchanged';$test.conditions=[pscustomobject]@{material='<script>reference</script>';volume='20';enhancements='Unknown'}
    $session=New-DiagnosticSession ([pscustomobject]@{speakerModel='fixture';cStates='Unknown';observations='return to 3.5mm already confirmed'})
    $session.tests=@($test)
    [void](Add-TimelineEvent $session NoiseHeard $test.id '' '=manual note')
    $directory=Join-Path $temporary 'source';Save-Session $session $directory
    $rows=@(Import-Csv (Join-Path $directory 'timeline.csv'))
    Assert-Data ($rows.Count -eq 1 -and [long]$rows[0].qpc -gt 0 -and $rows[0].note.StartsWith("'=")) 'Timeline exports UTC, QPC, identities and spreadsheet-safe notes'
    $conditionHtml=Get-Content (Join-Path $directory 'report.html') -Raw
    Assert-Data ($conditionHtml.Contains('reference') -and -not $conditionHtml.Contains('<script>reference')) 'Playback conditions are escaped in the report'
    Initialize-AudioInterop
    $snapshot=Get-PlaybackSnapshot $session.id
    $snapshotJson=$snapshot|ConvertTo-Json -Depth 12
    Assert-Data ($snapshot.point.frequency -gt 0 -and $snapshotJson -notmatch 'SWD\\MMDEVAPI|\{0\.0\.0\.') 'Real endpoint session query compiles and saves anonymous endpoint references'
    $probe=New-AudioProbeRecord Reference fixture $test.id 1
    $probe.status='Completed';$session.audioProbes=@($probe)
    $audio=Resolve-AudioFile $directory $probe.files.recording
    [IO.Directory]::CreateDirectory((Split-Path -Parent $audio))|Out-Null
    [AudioNoiseDiagnostics.AudioFiles]::GenerateReference($audio)
    $reference=Resolve-AudioFile $directory $probe.files.reference;Copy-Item -LiteralPath $audio -Destination $reference
    $probe.files.recordingSha256=(Get-FileHash $audio).Hash;$probe.files.referenceSha256=$probe.files.recordingSha256
    $endpoints=@([AudioNoiseDiagnostics.AudioFiles]::Endpoints())
    if($endpoints.Count -gt 0){
        $playback=[AudioNoiseDiagnostics.AudioPlayback]::Start($endpoints[0].Id,$audio)
        try{
            $deadline=[DateTime]::UtcNow.AddSeconds(5)
            while($playback.Status -eq 'Starting' -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
            $active=Get-PlaybackSnapshot $session.id $endpoints[0].Id
            $selected=@($active.outputs|Where-Object {$_.isSelectedForProbe})
            $processes=@($selected.sessions.data|Where-Object {$_.processId -eq $PID})
            Assert-Data ($selected.Count -eq 1 -and $selected[0].sessions.status -eq 'collected' -and $processes.Count -gt 0) 'Live reference playback is mapped to the selected endpoint and actual player process'
        }finally{$playback.Dispose()}
    }else{Write-Host 'SKIP: live playback session mapping requires an active render endpoint'}
    Initialize-LocalReceiver
    $media=[AudioNoiseDiagnostics.LocalReceiver]::ImportFile($audio,$directory,'FileImport')
    $session.physicalRecordings=@(ConvertTo-PhysicalRecord $media $probe.id $test.id)
    $traceId=[guid]::NewGuid().ToString('N');$traceDirectory=Join-Path (Join-Path $directory 'traces') $traceId
    [IO.Directory]::CreateDirectory($traceDirectory)|Out-Null
    $etl=Join-Path $traceDirectory 'trace.etl';[IO.File]::WriteAllText($etl,'fake private ETL fixture')
    Write-AtomicText (Join-Path $traceDirectory 'trace.json') (([pscustomobject]@{status='Completed';sha256=(Get-FileHash $etl).Hash})|ConvertTo-Json)
    Write-AtomicText (Join-Path $directory 'unrelated-private.txt') 'Never export arbitrary files'
    Save-Session $session $directory
    $exports=Join-Path $temporary 'exports'
    $zip=Export-DiagnosticBundle $directory $exports
    $verified=Test-DiagnosticBundle $zip
    Assert-Data ($verified.manifest.files.path -contains ('session/'+$probe.files.recording) -and $verified.manifest.files.path -contains ('session/'+$media.RelativePath)) 'Bundle includes referenced reference/recorded WAVs and physical media with verified hashes'
    Assert-Data ($verified.manifest.excludedFiles.Count -eq 1 -and $verified.manifest.files.path -notcontains ('session/traces/'+$traceId+'/trace.etl') -and $verified.manifest.files.path -notcontains 'session/unrelated-private.txt') 'Sensitive ETL is omitted explicitly by default and unrelated session files never leak'
    Assert-Data ([IO.Path]::GetFileName($zip) -match '^audio-noise_\d{8}T\d{6}Z_[a-f0-9]{8}_export\d{8}T\d{6}Z_[a-f0-9]{6}\.zip$') 'Export filename follows the documented UTC/session/unique-suffix rule'
    $withEtl=Export-DiagnosticBundle $directory $exports -IncludeTraces
    Assert-Data ((Test-DiagnosticBundle $withEtl).manifest.files.path -contains ('session/traces/'+$traceId+'/trace.etl')) 'Explicit trace inclusion exports the ETL with its hash'
    $external=Join-Path $temporary 'external-results';$inbox=Join-Path $external 'inbox';[IO.Directory]::CreateDirectory($inbox)|Out-Null
    $incoming=Join-Path $inbox ([IO.Path]::GetFileName($zip));Copy-Item $zip $incoming
    $originalHash=(Get-FileHash $incoming).Hash
    $imported=Import-ResultArchive $incoming fixture $external
    $receipt=Get-Content (Join-Path $imported 'receipt.json') -Raw|ConvertFrom-Json
    Assert-Data ($receipt.sessions[0].id -eq $session.id -and $receipt.format -eq 'bundle-v1' -and (Get-FileHash $incoming).Hash -eq $originalHash) 'Import preserves inbox ZIP, records archive/session provenance and separates case imports from analysis'
    Assert-Data ((Import-ResultArchive $incoming fixture $external) -eq $imported -and @(Get-ChildItem (Join-Path $external 'cases/fixture/imports') -Directory).Count -eq 1) 'Reimport is idempotent by full archive SHA-256'
    Assert-Rejected {Import-ResultArchive $incoming '../escape' $external} 'Unsafe case names cannot escape external-results'
    $legacy=Join-Path $temporary 'legacy.zip';[IO.Compression.ZipFile]::CreateFromDirectory($directory,$legacy)
    $legacyImport=Import-ResultArchive $legacy fixture $external
    Assert-Data ((Get-Content (Join-Path $legacyImport 'receipt.json') -Raw|ConvertFrom-Json).format -eq 'legacy-zip-unverified-manifest') 'Legacy data ZIPs are accepted with their weaker verification labeled explicitly'
    $tampered=Join-Path $temporary 'tampered.zip';Copy-Item $zip $tampered
    $archive=[IO.Compression.ZipFile]::Open($tampered,[IO.Compression.ZipArchiveMode]::Update)
    try{$entry=$archive.GetEntry('session/tests.csv');$entry.Delete();$entry=$archive.CreateEntry('session/tests.csv');$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write('tampered')}finally{$writer.Dispose()}}finally{$archive.Dispose()}
    Assert-Rejected {Test-DiagnosticBundle $tampered} 'Modified archive bytes cannot pass manifest verification'
    foreach($badName in @('../escape.txt','/absolute.txt','C:/drive.txt','safe/../../escape','CON.txt','trailing.')){
        $bad=Join-Path $temporary ([guid]::NewGuid().ToString('N')+'.zip');$archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Create)
        try{[void]$archive.CreateEntry($badName)}finally{$archive.Dispose()}
        Assert-Rejected {Import-ResultArchive $bad fixture $external} ('Unsafe archive entry refused: '+$badName)
    }
    $test.result='InProgress';Save-Session $session $directory
    Assert-Rejected {Export-DiagnosticBundle $directory $exports} 'Live observations cannot be exported as finalized evidence'
    $test.result='Unchanged';Save-Session $session $directory
    $savedAudio=[IO.File]::ReadAllBytes($audio);[IO.File]::WriteAllText($audio,'changed')
    Assert-Rejected {Export-DiagnosticBundle $directory $exports} 'Changed recording prevents incomplete or misleading export'
    [IO.File]::WriteAllBytes($audio,$savedAudio)
    # Mock WPR, not the recording state machine: no real system trace or elevation in tests.
    $script:wprCalls=New-Object 'System.Collections.Generic.List[object]'
    $script:traceFixtureSessionPath=Join-Path $directory 'session.json'
    $fakeWpr={param($arguments)
        $script:wprCalls.Add($arguments)
        if($arguments[0] -eq '-marker' -and $arguments[1] -like 'AudioNoiseTraceStart-*'){
            $fixture=Read-Session $script:traceFixtureSessionPath
            [void](Add-TimelineEvent $fixture NoiseHeard)
            Write-AtomicText $script:traceFixtureSessionPath ($fixture|ConvertTo-Json -Depth 20)
        }
        if($arguments[0] -eq '-stop'){[IO.File]::WriteAllText($arguments[1],'fake ETL')}
        return 0
    }
    $state=Invoke-DetailedTrace -SessionPath (Join-Path $directory 'session.json') -Seconds 1 -WprRunner $fakeWpr
    Assert-Data ($state.status -eq 'Completed' -and $state.sha256 -match '^[A-F0-9]{64}$' -and $state.mode -eq 'Memory') 'Bounded trace state machine finalizes and hashes ETL after explicit start'
    Assert-Data ($state.markers.Count -eq 1 -and $state.markers[0].submittedPoint.qpc -ge $state.markers[0].originalPoint.qpc -and $state.markers[0].exitCode -eq 0) 'ETW marker submission preserves original noise-click QPC separately from delayed submission time'
    $instances=@($script:wprCalls|ForEach-Object {$_[$_.Count-1]}|Select-Object -Unique)
    Assert-Data ($instances.Count -eq 1 -and $instances[0] -like 'AudioNoise-*' -and @($script:wprCalls|Where-Object {$_ -contains '-cancel'}).Count -eq 0) 'Every WPR command targets only its unique instance; another trace is never cancelled'
    $script:wprCalls.Clear()
    $failed=Invoke-DetailedTrace -SessionPath (Join-Path $directory 'session.json') -Seconds 1 -WprRunner {param($arguments);$script:wprCalls.Add($arguments);return 1}
    Assert-Data ($failed.status -eq 'Failed' -and $script:wprCalls.Count -eq 1) 'WPR start failure remains a failure and never stops another recording'
    $failedStop=Invoke-DetailedTrace -SessionPath (Join-Path $directory 'session.json') -Seconds 1 -WprRunner {param($arguments);if($arguments[0] -eq '-stop'){return 1};return 0}
    Assert-Data ($failedStop.status -eq 'StopFailed') 'ETL save failure cannot become a completed trace'
    Write-Host ('All '+$checks+' data/evidence checks passed.')
}finally{
    $checkedRoot=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($temporary).StartsWith($checkedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
