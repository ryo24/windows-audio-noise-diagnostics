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
$exercise=($ExerciseWorkflow -or $ExerciseAudioWorkflow -or $ExercisePhoneWorkflow -or $ExerciseExportWorkflow -or $ExerciseUxWorkflow)
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
        Save-UiProof 'review';$audioReplay.PerformClick();Wait-Ui {-not $script:audioPlayback} 20
        Assert-Ui ($script:session.audioProbes[0].verification.reviewPlaybackCompleted) 'Saved WAV replay did not complete.'
        $audioLive.SelectedIndex=1;$audioRecorded.SelectedIndex=2;$audioResemblance.SelectedIndex=2;$audioSaveReview.PerformClick()
        $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
        Assert-Ui ($saved.audioProbes[0].verification.replayNoise -eq 'No') 'Listening verification was not saved.'
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
