function Assert-Ui {param([bool]$Value,[string]$Message);if(-not $Value){throw $Message}}
function Wait-Ui {
    param([scriptblock]$Until,[int]$Seconds=120)
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    while(-not (& $Until)){
        if([DateTime]::UtcNow -ge $deadline){throw 'The UI workflow timed out.'}
        [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 30
    }
}
function Save-UiProof {
    param([string]$Suffix='')
    if(-not $ScreenshotPath){return}
    $path=[IO.Path]::GetFullPath($ScreenshotPath)
    if($Suffix){$path=Join-Path (Split-Path -Parent $path) ([IO.Path]::GetFileNameWithoutExtension($path)+'-'+$Suffix+'.png')}
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path))|Out-Null
    $form.PerformLayout();[Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}
function Get-UiButtons {
    param($Parent)
    foreach($control in $Parent.Controls){if($control -is [Windows.Forms.Button]){$control};Get-UiButtons $control}
}
$form.Show();$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
$exercise=($ExerciseWorkflow -or $ExerciseAudioWorkflow -or $ExercisePhoneWorkflow -or $ExerciseExportWorkflow -or $ExerciseUxWorkflow -or $ExerciseTraceWorkflow -or $ExerciseFollowUpWorkflow)
Assert-Ui (-not $start.Enabled -and $tabs.SelectedTab -eq $preparePage) 'Startup must show preparation and refuse an unprepared start.'
$buttons=@(Get-UiButtons $form)
Assert-Ui (@($buttons|Where-Object {$_.Text -like '*調査を開始*'}).Count -eq 1) 'There must be exactly one observation/capture start button.'
Assert-Ui (@($buttons|Where-Object {$_.Text -eq 'ノイズが聞こえた'}).Count -eq 1) 'There must be exactly one noise marker button.'
Assert-Ui ($start.Parent.Parent -eq $runLayout -and $mark.Parent -eq $start.Parent) 'Primary actions must belong to the run step, not a persistent footer.'
if($exercise){
    $speaker.Text='Synthetic UI verification';$cStates.SelectedIndex=1
    $collect.PerformClick();$timer.Start()
    Wait-Ui {-not $script:worker -and $script:session.inventory}
    Assert-Ui ($tabs.SelectedTab -eq $settingsPage -and -not $start.Enabled -and -not $audioConsent.Checked) 'After preparation, capture requires consent in settings and never starts on its own.'
    if($ExerciseExportWorkflow){
        $tabs.SelectedTab=$exportPage;$export.PerformClick()
        Assert-Ui ($script:lastExport -and (Test-Path -LiteralPath $script:lastExport)) 'The export step did not produce a ZIP.'
        Assert-Ui ((Test-DiagnosticBundle $script:lastExport).manifest.sessionId -eq $script:session.id) 'Exported ZIP has the wrong session.'
        Write-Output 'UI export step creates and verifies a complete session ZIP OK'
    }elseif($ExerciseFollowUpWorkflow){
        if($audioOutput.Items.Count -eq 0){Write-Output 'SKIP: follow-up capture UI requires an active audio endpoint; state/storage are covered by Run-FollowUpTests.';$form.Close();return}
        function Start-TraceHelper {
            param($Run)
            if($script:cancelUsbAdmin){throw (New-Object ComponentModel.Win32Exception(1223))}
            $fixture=Join-Path $script:ToolRoot 'tests/Invoke-FakeTrace.ps1'
            $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$fixture+'" -SessionPath "'+(Join-Path $script:sessionDirectory 'session.json')+'" -TraceId '+$Run.id+' -IncludeUsb'
            if($script:failUsbStart){$arguments+=' -FailUsbStart'}
            if($script:failUsbSave){$arguments+=' -FailUsbSave'}
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList $arguments -PassThru
        }
        $usbPreset.PerformClick()
        Assert-Ui ($followUpChoice.SelectedIndex -eq 1 -and $settingsTabs.SelectedTab -eq $followUpTab -and -not $script:audioRecorder -and $includeTraces.Checked) 'The visible USB preset must configure USB capture without starting sound or consenting.'
        $followUpRoute.Text='Synthetic smartphone position';$audioConsent.Checked=$true
        Assert-Ui (-not $start.Enabled) 'USB follow-up must require its own trace scope acknowledgement.'
        $followUpConsent.Checked=$true;$audioLength.SelectedItem='30';Update-UiState
        Assert-Ui $start.Enabled 'Acknowledged follow-up must use the common start.'
        Save-UiProof 'follow-up-settings';$settingsNext.PerformClick();$start.PerformClick()
        Assert-Ui ($script:activeTest -and -not $script:audioRecorder -and (Test-DetailedTraceBusy) -and -not $mark.Enabled) 'One common start must wait for USB/Audio readiness before sound, recording and markers.'
        Save-UiProof 'usb-awaiting'
        # Keep Windows message dispatch alive but deliberately delay consumption
        # of trace readiness beyond the normal 500 ms polling interval.
        $timer.Stop()
        try{
            Wait-Ui {try{(Read-TraceRunState $script:traceRun).status -eq 'AwaitingCapture'}catch{$false}} 20
            Start-Sleep -Milliseconds 1600
            $waiting=Read-TraceRunState $script:traceRun
            Assert-Ui ($waiting.status -eq 'AwaitingCapture' -and $waiting.captureHandshake.status -eq 'Waiting' -and
                $waiting.usb.status -eq 'Recording' -and $waiting.audioStatus -eq 'Recording' -and
                -not $script:audioRecorder -and -not $mark.Enabled) 'The helper must hold readiness independently of the trace duration until delayed UI polling begins audio.'
        }finally{$timer.Start()}
        Wait-Ui {$script:traceRun.phase -eq 'Recording' -and $script:activeTest.followUp.captureStage -eq 'Started'} 25
        $linkedTest=$script:activeTest;$linkedProbe=$script:recordingProbe
        Assert-Ui ($linkedTest.followUp.traceId -eq $script:traceRun.id -and $script:traceRun.state.link.testId -eq $linkedTest.id -and $script:traceRun.state.link.probeId -eq $linkedProbe.id) 'Trace, probe and comparison must be linked by IDs.'
        Assert-Ui ($script:traceRun.state.captureHandshake.status -eq 'Acknowledged' -and $script:traceRun.state.requestedSeconds -eq 30 -and
            $script:traceRun.state.captureHandshake.acknowledged.qpc -eq $linkedTest.followUp.simultaneousConfirmed.qpc) 'The independent helper must accept the matching QPC handshake before starting the configured capture timer.'
        Assert-Ui ($linkedProbe.referenceId -like '*v2-indexed*' -and $linkedProbe.selectedOutputFormat.status -eq 'collected') 'Follow-up must use indexed sound and the actual selected output format.'
        Assert-Ui (@($script:session.timeline|Where-Object kind -eq 'UsbAudioReady').Count -eq 1 -and @($script:session.timeline|Where-Object kind -eq 'SimultaneousCaptureConfirmed').Count -eq 1 -and $mark.Enabled) 'Readiness and simultaneous confirmation must be distinct recorded points.'
        Save-UiProof 'follow-up-recording';$mark.PerformClick();$finish.PerformClick()
        Assert-Ui ($script:traceRun.stopRequested -and $script:finishRequested) 'The common finish must request trace and recording stop together.'
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor -and -not (Test-DetailedTraceBusy)}
        Assert-Ui ($script:traceRun.phase -eq 'Completed' -and (Test-Path (Join-Path $script:traceRun.directory 'usb.etl'))) 'Linked USB trace must finalize before export.'
        Assert-Ui (@($linkedProbe.capture.streamTiming.renderClockSamples).Count -gt 0 -or [bool]$linkedProbe.capture.streamTiming.renderClockError) 'Deep capture must retain driver clock samples or an explicit clock API error.'
        Assert-Ui (@($linkedProbe.capture.streamTiming.capturePackets).Count -gt 0 -or $linkedProbe.status -eq 'NoAudioData') 'Deep capture must retain capture-packet QPC timing when audio packets exist.'
        Assert-Ui ($traceResults.Text.Contains('保存確認済み') -and $traceResults.Text.Contains('bytes')) 'Results must show separate USB and Audio artifact states and actual sizes.'
        Initialize-LocalReceiver
        $media=[AudioNoiseDiagnostics.LocalReceiver]::ImportFile((Resolve-AudioFile $script:sessionDirectory $linkedProbe.files.reference),$script:sessionDirectory,'FileImport');Add-PhysicalMedia $media
        Assert-Ui ($script:session.physicalRecordings[0].testId -eq $linkedTest.id -and $script:session.physicalRecordings[0].audioProbeId -eq $linkedProbe.id) 'Physical media imported after finishing must retain the selected comparison linkage.'
        $tabs.SelectedTab=$settingsPage;$settingsTabs.SelectedTab=$followUpTab;$followUpChoice.SelectedIndex=2;$followUpReference.SelectedIndex=$followUpReference.Items.Count-1
        Assert-Ui ($followUpGuide.Text.Contains('同じスマホ') -and -not $followUpConsent.Enabled) 'Clean physical control must explain matching the phone method without requiring USB consent.'
        Save-UiProof 'physical-control'
        $comparison=New-DiagnosticSession ([pscustomobject]@{speakerModel='synthetic recovery control';cStates='Unknown'})
        $comparisonTest=New-TestRecord 'Recovery' 'same output' '' '' '' ''
        Complete-TestTiming $comparisonTest (Get-ClockPoint);$comparisonTest.result='NoRepro';$comparison.tests=@($comparisonTest)
        $comparisonDirectory=Join-Path $script:dataRoot 'synthetic-comparison';Save-Session $comparison $comparisonDirectory
        $comparisonPath=Join-Path $comparisonDirectory 'session.json';$beforeHash=(Get-FileHash $comparisonPath).Hash
        Add-FollowUpReferenceFile $comparisonPath
        $followUpChoice.SelectedIndex=4;$followUpOperation.SelectedIndex=5;$followUpState.SelectedIndex=2
        $recoveryPlan=Get-FollowUpPlan
        Assert-Ui ($recoveryPlan.comparisonSessionId -eq $comparison.id -and $recoveryPlan.comparisonTestId -eq $comparisonTest.id -and $recoveryPlan.comparisonSourceHash -eq $beforeHash -and (Get-FileHash $comparisonPath).Hash -eq $beforeHash) 'Cross-session comparison must retain source identity and hash without modifying its JSON.'
        Assert-Ui ($recoveryPlan.priorOperation -eq 'MultipleChanges' -and $recoveryPlan.stateAtStart -eq 'NoNoiseConfirmed') 'Recovery comparison must distinguish combined operations and the reported starting state.'
        Save-UiProof 'recovery-control';$tabs.SelectedTab=$exportPage;$includeTraces.Checked=$false;Update-UiState
        Assert-Ui ($exportReady.Text.Contains('既定ではETLを除外')) 'USB follow-up export must explain the opt-in ETL checkbox.'
        $includeTraces.Checked=$true;$export.PerformClick()
        Assert-Ui ((Test-DiagnosticBundle $script:lastExport).manifest.files.path -contains ('session/traces/'+$script:traceRun.id+'/usb.etl')) 'Explicit ETL export must include the linked USB trace.'
        $tabs.SelectedTab=$settingsPage;$followUpChoice.SelectedIndex=1;$audioLength.SelectedItem='30';$followUpConsent.Checked=$true;$audioConsent.Checked=$true
        $script:failUsbStart=$true;$tabs.SelectedTab=$runPage;$start.PerformClick()
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor -and -not (Test-DetailedTraceBusy)}
        $failed=@(Get-SessionTraceEvidence $script:session $script:sessionDirectory)[-1]
        Assert-Ui ($script:session.tests[-1].result -eq 'Inconclusive' -and $failed.usb.status -eq 'StartFailed' -and $failed.audioTrace.status -eq 'NotStarted' -and $script:recordingProbe.status -eq 'NotStarted') 'USB start failure must end the attempt without playing the test sound or starting Audio.'
        $script:failUsbStart=$false;$script:cancelUsbAdmin=$true;$tabs.SelectedTab=$runPage;$start.PerformClick()
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor -and -not (Test-DetailedTraceBusy)}
        $cancelled=@(Get-SessionTraceEvidence $script:session $script:sessionDirectory)[-1]
        Assert-Ui ($cancelled.usb.status -eq 'AdminCancelled' -and $script:recordingProbe.status -eq 'NotStarted') 'Admin cancellation must be visible without playing or recording audio.'
        $script:cancelUsbAdmin=$false;$script:failUsbSave=$true;$tabs.SelectedTab=$runPage;$start.PerformClick()
        Wait-Ui {$script:activeTest.followUp.captureStage -eq 'Started'} 25
        $finish.PerformClick()
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor -and -not (Test-DetailedTraceBusy)}
        $saveFailed=@(Get-SessionTraceEvidence $script:session $script:sessionDirectory)[-1]
        Assert-Ui ($saveFailed.usb.status -eq 'SaveFailed' -and $saveFailed.audioTrace.status -eq 'Saved') 'USB save failure must remain distinct from saved Audio and internal recording.'
        $script:failUsbSave=$false;$tabs.SelectedTab=$runPage;$start.PerformClick()
        $timer.Stop()
        try{
            Wait-Ui {try{(Read-TraceRunState $script:traceRun).status -eq 'AwaitingCapture'}catch{$false}} 20
            $finish.PerformClick()
            Assert-Ui (-not $script:audioRecorder -and $script:recordingProbe.status -eq 'NotStarted') 'Finishing before consuming readiness must never start late playback.'
        }finally{$timer.Start()}
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor -and -not (Test-DetailedTraceBusy)}
        $stopped=@(Get-SessionTraceEvidence $script:session $script:sessionDirectory)[-1]
        Assert-Ui ($stopped.usb.status -eq 'Saved' -and $stopped.audioTrace.status -eq 'Saved' -and
            $stopped.stopReason -eq 'RequestedDuringStartup' -and $stopped.captureHandshake.status -eq 'Stopped' -and
            $script:session.tests[-1].result -eq 'Inconclusive') 'Early finish must preserve both started ETLs with an explicit stopped handshake and inconclusive audio.'
        $tabs.SelectedTab=$reviewPage;$reviewTabs.SelectedTab=$traceResultsTab;Save-UiProof 'usb-results'
        $tabs.SelectedTab=$exportPage;$includeTraces.Checked=$true;$export.PerformClick()
        $bundle=(Test-DiagnosticBundle $script:lastExport).manifest
        Assert-Ui ($bundle.traceEvidence.Count -eq 5 -and $bundle.traceFileCount -eq 5 -and $bundle.missingFiles.Count -eq 6) 'A ZIP must retain all success/failure test links, only real ETLs and explicit missing files.'
        $form.Close();Write-Output 'UI USB readiness, shared lifecycle, cancellation, start/save failures, physical linkage and honest ZIP contents OK'
    }elseif($ExerciseTraceWorkflow){
        function Start-TraceHelper {
            param($Run)
            $fixture=Join-Path $script:ToolRoot 'tests/Invoke-FakeTrace.ps1'
            $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$fixture+'" -SessionPath "'+(Join-Path $script:sessionDirectory 'session.json')+'" -TraceId '+$Run.id
            if($script:fakeTraceFailSave){$arguments+=' -FailSave'}
            if($script:fakeTraceExit){$arguments+=' -ExitWithoutFinalState'}
            if($script:fakeTraceHoldStart){$arguments+=' -WaitForRelease'}
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList $arguments -PassThru
        }
        $tabs.SelectedTab=$runPage;$runTools.SelectedTab=$traceTab;$traceConsent.Checked=$true
        $prior=Join-Path (Join-Path $script:sessionDirectory 'traces') ([guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($prior)|Out-Null
        $script:fakeTraceHoldStart=$true;$traceStart.PerformClick()
        Assert-Ui ((Test-DetailedTraceBusy) -and -not $traceStart.Enabled -and $script:traceRun.id) 'WPR launch must reserve the run directory before a helper is ready.'
        $traceStop.PerformClick()
        Assert-Ui ($script:traceRun.stopRequested -and -not $traceStop.Enabled -and (Test-Path -LiteralPath (Join-Path $script:traceRun.directory 'stop.request'))) 'An immediate stop must persist and disable duplicate stop requests.'
        Assert-Ui (-not (Test-Path -LiteralPath (Join-Path $prior 'stop.request'))) 'Stopping must not alter historical trace directories.'
        Write-AtomicText (Join-Path $script:traceRun.directory 'launch.release') 'release';$script:fakeTraceHoldStart=$false
        Wait-Ui {-not (Test-DetailedTraceBusy)} 30
        Assert-Ui ($script:traceRun.phase -eq 'Cancelled' -and -not (Test-Path -LiteralPath (Join-Path $script:traceRun.directory 'trace.etl'))) 'A stop before WPR startup must be cancelled explicitly, never reported as saved.'
        $traceStart.PerformClick();Wait-Ui {$script:traceRun.phase -eq 'Recording'} 20;Save-UiProof 'wpr-recording'
        $traceStop.PerformClick();Wait-Ui {$script:traceRun.phase -eq 'Saving'} 20
        Assert-Ui (-not $traceStop.Enabled -and $traceStatus.Text.Contains('ETLを保存しています') -and $traceProgress.Visible) 'Acknowledged stop must show ETL saving separately from a request.'
        Save-UiProof 'wpr-saving';Wait-Ui {-not (Test-DetailedTraceBusy)} 20
        Assert-Ui ($script:traceRun.phase -eq 'Completed' -and $traceOpen.Enabled -and -not $traceStop.Enabled -and -not $traceProgress.Visible -and $traceStatus.Text.Contains('完了')) 'Completed manifest and ETL must update the UI even before process-exit polling.'
        Save-UiProof 'wpr-completed'
        $script:fakeTraceFailSave=$true;$traceStart.PerformClick();Wait-Ui {$script:traceRun.phase -eq 'Recording'} 20
        $traceStop.PerformClick();Wait-Ui {-not (Test-DetailedTraceBusy)} 20
        Assert-Ui ($script:traceRun.phase -eq 'Failed' -and $traceStatus.Text.Contains('StopFailed') -and $traceStatus.Text.Contains('25') -and $traceOpen.Enabled) 'WPR save failure must leave a visible result and exit code, not an endless stop request.'
        Save-UiProof 'wpr-failed';$script:fakeTraceFailSave=$false;$script:fakeTraceExit=$true
        $traceStart.PerformClick();Wait-Ui {-not (Test-DetailedTraceBusy)} 20
        $state=Read-TraceRunState $script:traceRun
        Assert-Ui ($script:traceRun.phase -eq 'Failed' -and $state.status -eq 'HelperExited' -and $state.helperExitCode -eq 9) 'Unexpected helper exit must release the UI and retain unconfirmed-stop metadata.'
        Write-Output 'UI WPR early stop, cross-process state updates, saving/completion, save failure and helper crash OK'
    }elseif($ExercisePhoneWorkflow){
        $tabs.SelectedTab=$runPage;$runTools.SelectedTab=$phoneTab
        [void]$phoneAddress.Items.Add('127.0.0.1');$phoneAddress.SelectedIndex=0;Update-UiState;$phoneStart.PerformClick()
        Assert-Ui ([bool]$script:phoneReceiver) 'Phone reception did not open.'
        $ownedReceiver=$script:phoneReceiver;Initialize-AudioInterop
        $fixture=Join-Path $script:dataRoot 'phone-fixture.wav';[AudioNoiseDiagnostics.AudioFiles]::GenerateReference($fixture)
        $client=New-Object Net.WebClient
        try{[void]$client.UploadData($script:phoneReceiver.Url+'upload','POST',[IO.File]::ReadAllBytes($fixture))}finally{$client.Dispose()}
        Wait-Ui {@($script:session.physicalRecordings).Count -eq 1} 15
        Assert-Ui (-not $collect.Enabled -and -not $resume.Enabled -and -not $export.Enabled) 'Reception must prevent changing sessions or exporting unfinished data.'
        Save-UiProof 'phone-receiving'
        $script:phoneLogFixture=Join-Path $script:ToolRoot 'tests/fixtures/browser-upload-log.json'
        $phoneDiagnose.PerformClick()
        Assert-Ui (@($script:session.networkDiagnostics).Count -eq 1 -and $script:session.networkDiagnostics[0].localHttpSelfTest.httpStatus -eq 200) 'Phone connection diagnosis must persist a local self-test and receiver events without requiring a smartphone connection.'
        Assert-Ui ($script:session.networkDiagnostics[0].browserUploadDiagnostics.attempts[0].outcome -eq 'NetworkError') 'Imported browser upload diagnostics must be saved with the PC diagnosis.'
        $tabs.SelectedTab=$reviewPage;$reviewTabs.SelectedTab=$physicalTab
        $physicalReviewed.Checked=$true;$physicalHeard.SelectedIndex=1;$physicalRoute.Text='Synthetic UI test';$physicalSave.PerformClick()
        $form.Close()
        $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
        Assert-Ui ($ownedReceiver.Finished -and $saved.physicalRecordings[0].verification.heardNoise -eq 'Yes') 'Phone review or close was not saved.'
        Write-Output 'UI phone reception and physical listening are in separate steps; import/review/cleanup OK'
    }elseif($ExerciseAudioWorkflow){
        Refresh-AudioOutputs
        Assert-Ui ($audioOutput.Items.Count -gt 0) 'The audio integration test requires an active output.'
        $audioConsent.Checked=$true;[void]$audioLength.Items.Add('3');$audioLength.SelectedItem='3'
        $settingsNext.PerformClick();Save-UiProof 'ready'
        $start.PerformClick()
        Assert-Ui ($script:activeTest -and $script:audioRecorder -and $script:session.audioProbes[0].testId -eq $script:activeTest.id) 'One click must create a linked observation and recording.'
        Assert-Ui ($script:activeTest.capturePlan.method -eq 'Reference' -and $script:activeTest.capturePlan.recordingConsent) 'The chosen capture plan and explicit consent must be recorded.'
        Wait-Ui {$script:audioRecorder.Status -ne 'Starting'} 15
        $mark.PerformClick();Save-UiProof 'recording'
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor}
        Assert-Ui ($script:session.audioProbes[0].status -eq 'Completed' -and $tabs.SelectedTab -eq $reviewPage) 'Recording limit must end observation and advance to review automatically.'
        Assert-Ui ($script:session.tests[0].noiseUtc.Count -eq 1 -and $script:session.audioProbes[0].noiseMarkersUtc.Count -eq 1) 'The single marker must be associated with both records.'
        Save-UiProof 'review'
        $script:reviewPromptChoice='ChangeOutput';$audioReplay.PerformClick()
        Assert-Ui (-not $script:audioPlayback -and -not $script:session.audioProbes[0].verification.reviewPlaybackCompleted) 'Returning from the playback warning must not start playback or mark the recording reviewed.'
        $script:reviewPromptChoice='Proceed';$audioReplay.PerformClick();Wait-Ui {-not $script:audioPlayback} 20
        Assert-Ui ($script:session.audioProbes[0].verification.reviewPlaybackCompleted) 'Saved WAV replay did not complete.'
        Assert-Ui ([bool]$script:session.audioProbes[0].verification.playbackWarning.acceptedUtc) 'Continuing playback must retain acknowledgement without declaring the route clean.'
        $audioLive.SelectedIndex=1;$audioRecorded.SelectedIndex=2;$audioResemblance.SelectedIndex=2;$audioSaveReview.PerformClick()
        $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
        Assert-Ui ($saved.audioProbes[0].verification.replayNoise -eq 'No') 'Listening verification was not saved.'
        $previousReview=$script:session.audioProbes[0].verification|ConvertTo-Json -Depth 8
        $script:reviewPromptChoice='ChangeOutput';$audioReplay.PerformClick()
        Assert-Ui (-not $script:audioPlayback -and ($script:session.audioProbes[0].verification|ConvertTo-Json -Depth 8) -eq $previousReview) 'Returning from the warning must preserve an earlier saved listening result.'
        $audioMode.SelectedIndex=1
        Assert-Ui (-not $audioConsent.Checked -and -not $start.Enabled) 'Changing the recording method must require confirming its scope again.'
        $audioConsent.Checked=$true;$tabs.SelectedTab=$runPage;$start.PerformClick()
        Assert-Ui ($script:activeTest -and $script:audioRecorder) 'External-app mode must start observation and recording with one click too.'
        $finish.PerformClick()
        Assert-Ui ($script:finishRequested -and -not $mark.Enabled) 'The common finish button must stop an active recording and freeze markers.'
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor}
        Assert-Ui ($script:session.tests[1].endedUtc -and $script:session.audioProbes[1].status -notin @('Starting','Recording')) 'Manual finish did not finalize external audio and observation together.'
        $tabs.SelectedTab=$runPage;$start.PerformClick();$form.Close()
        Wait-Ui {$form.IsDisposed}
        $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
        Assert-Ui ($saved.tests[2].result -eq 'Interrupted' -and $saved.audioProbes[2].status -notin @('Starting','Recording')) 'Closing must finalize both recording and observation without a result dialog.'
        Write-Output 'UI single-start recording, shared marker, automatic observation finish, independent replay and safe close OK'
    }else{
        $audioMode.SelectedIndex=2
        Assert-Ui ($start.Enabled -and -not $audioConsent.Enabled -and -not $audioOutput.Enabled) 'Observation-only mode must work without recording consent or audio devices.'
        if($ExerciseWorkflow){$testChoice.SelectedIndex=7}
        $settingsNext.PerformClick();Save-UiProof 'ready';$start.PerformClick()
        Assert-Ui ($script:activeTest -and -not $script:audioRecorder -and -not $audioMode.Enabled -and $tabs.SelectedTab -eq $runPage) 'Observation-only mode must lock settings and open the run step.'
        Assert-Ui ($script:activeTest.capturePlan.method -eq 'ObservationOnly' -and -not $script:activeTest.capturePlan.recordingConsent) 'Observation-only logs must not imply audio recording consent.'
        $mark.PerformClick();Save-UiProof 'observing'
        $finish.PerformClick()
        Assert-Ui (-not $mark.Enabled -and -not $finish.Enabled -and $script:activeTest.endedUtc) 'Ending must freeze observation and disable duplicate actions, even during context collection.'
        Wait-Ui {-not $script:activeTest -and -not $script:worker -and -not $script:bluetoothMonitor}
        $test=$script:session.tests[0]
        Assert-Ui ($test.result -eq 'Unchanged' -and $test.noiseUtc.Count -eq 1 -and $test.context -and $test.relatedEvents -and $test.bluetoothEndState) 'Observation/evidence/marker did not save together.'
        Assert-Ui ($tabs.SelectedTab -eq $reviewPage -and $reviewTabs.SelectedTab -eq $historyTab) 'Observation without audio must advance to comparison results, not an empty WAV player.'
        if($ExerciseWorkflow){Assert-Ui ([bool]$test.driverSnapshot) 'Driver comparison must preserve its end snapshot.'}
        Save-UiProof 'results'
        $tabs.SelectedTab=$exportPage;Save-UiProof 'export'
        $tabs.SelectedTab=$runPage;$start.PerformClick();$mark.PerformClick()
        Wait-Ui {-not $script:worker}
        $form.Close();Wait-Ui {$form.IsDisposed}
        $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
        Assert-Ui ($saved.tests.Count -eq 2 -and $saved.tests[1].result -eq 'Interrupted') 'Safe close must preserve an unfinished observation.'
        Write-Output 'UI five-step navigation, one start/marker, observation-only mode, stopping while collecting and result routing OK'
    }
}
if(-not $exercise){
    switch($ScreenshotTab){
        'Tests' {$tabs.SelectedTab=$settingsPage;$settingsTabs.SelectedTab=$testTab}
        'Bluetooth' {$tabs.SelectedTab=$settingsPage;$settingsTabs.SelectedTab=$btTab}
        'Audio' {$tabs.SelectedTab=$settingsPage;$settingsTabs.SelectedTab=$audioTab}
        'Phone' {$tabs.SelectedTab=$runPage;$runTools.SelectedTab=$phoneTab}
        'Evidence' {$tabs.SelectedTab=$settingsPage;$settingsTabs.SelectedTab=$evidenceTab}
        'Run' {$tabs.SelectedTab=$runPage}
        'Review' {$tabs.SelectedTab=$reviewPage}
        'Export' {$tabs.SelectedTab=$exportPage}
    }
    Save-UiProof
}
Write-Output 'UI smoke test OK'
