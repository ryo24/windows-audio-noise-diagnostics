param([switch]$SmokeTest, [string]$ScreenshotPath, [switch]$ExerciseWorkflow, [switch]$ExerciseAudioWorkflow, [switch]$ExercisePhoneWorkflow, [switch]$ExerciseExportWorkflow, [switch]$ExerciseUxWorkflow, [ValidateSet('Prepare','Tests','Bluetooth','Audio','Phone','Evidence','Run','Review','Export')][string]$ScreenshotTab='Prepare')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'AudioUi.ps1')
. (Join-Path $PSScriptRoot 'EvidenceUi.ps1')
. (Join-Path $PSScriptRoot 'WorkflowControl.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:dataRoot=Join-Path $script:ToolRoot 'data'
if ($SmokeTest) { $script:dataRoot=Join-Path (Join-Path $script:ToolRoot 'artifacts\ui-data') ([guid]::NewGuid().ToString('N')) }
[IO.Directory]::CreateDirectory($script:dataRoot) | Out-Null
$script:toolLock=$null
try { $script:toolLock=[IO.File]::Open((Join-Path $script:dataRoot 'tool.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
catch { [Windows.Forms.MessageBox]::Show('別の調査ツールまたは更新処理が動いています。閉じてから再実行してください。','起動できません') | Out-Null; exit 1 }

$script:session=$null
$script:sessionDirectory=$null
$script:activeTest=$null
$script:worker=$null
$script:workerHandle=$null
$script:workerMode=$null
$script:closing=$false
$script:traceProcess=$null
$script:uiReady=$false
$script:finishRequested=$false
$script:finishDialogOpen=$false
$script:bluetoothMonitor=$null
$script:bluetoothTest=$null
$script:btConditions=@('Unknown','RadioOff','RadioOnKeyboardOff','KeyboardConnected')
$script:inputActivities=@('Unknown','WiredOnly','BluetoothIdle','BluetoothTyping')
$script:definitions=@(Get-TestDefinitions)

function New-UiLabel {
    param([string]$Text)
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text; $label.AutoSize=$true; $label.Margin=New-Object Windows.Forms.Padding(6,8,6,6)
    return $label
}
function New-UiButton {
    param([string]$Text)
    $button=New-Object Windows.Forms.Button
    $button.Text=$Text; $button.AutoSize=$true; $button.MinimumSize=New-Object Drawing.Size(120,36)
    $button.Margin=New-Object Windows.Forms.Padding(5)
    return $button
}
function New-UiCombo {
    param([string[]]$Values)
    $combo=New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle='DropDownList'; $combo.Dock='Fill'; $combo.Margin=New-Object Windows.Forms.Padding(6)
    $combo.Items.AddRange([object[]]$Values); if($combo.Items.Count -gt 0){$combo.SelectedIndex=0}
    return $combo
}
function Show-UiError {
    param($Failure)
    if($SmokeTest){throw ('UI validation error: '+$Failure+"`n"+$global:Error[0].ScriptStackTrace)}
    [Windows.Forms.MessageBox]::Show([string]$Failure,'処理を完了できません',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}
function Get-CurrentProfile {
    [pscustomobject]@{ speakerModel=$speaker.Text.Trim(); powerSource=[string]$profilePower.SelectedItem; cStates=@('Unknown','Disabled','Enabled')[$cStates.SelectedIndex]; observations=$observations.Text.Trim(); verification='利用者の手動入力。BIOS設定を自動取得したものではありません。' }
}
function Set-ProfileControls {
    param($Profile)
    $speaker.Text=$Profile.speakerModel
    if ($profilePower.Items.Contains($Profile.powerSource)) { $profilePower.SelectedItem=$Profile.powerSource }
    $cStates.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unknown','Disabled','Enabled'),$Profile.cStates))
    $observations.Text=$Profile.observations
}
function Save-CurrentSession {
    if ($script:session) {
        Save-Session $script:session $script:sessionDirectory
        $recordCount.Text=('保存済みの比較: ' + @($script:session.tests).Count + ' 件　／　記録は data フォルダー内（非公開）')
        $history.Text=($script:session.tests | ForEach-Object { $_.id + "`r`n" + $_.kind + ' / ' + (Get-ResultLabel $_.result) + ' / ' + $_.durationSeconds + '秒 / ノイズ ' + @($_.noiseUtc).Count + "回`r`n" + $_.change + "`r`n" }) -join "`r`n"
    }
}
function Receive-BluetoothSamples {
    if (-not $script:bluetoothMonitor) { return }
    $completed=$script:bluetoothMonitor.handle.IsCompleted
    $sample=$null; $changed=$false
    while ($script:bluetoothMonitor.queue.TryDequeue([ref]$sample)) {
        $script:bluetoothTest.bluetoothSamples=@($script:bluetoothTest.bluetoothSamples) + @($sample)
        $summary=Get-BluetoothStateSummary $sample
        $connections=if ($null -eq $summary.connectedEndpointCount) { '不明・一部未取得' } else { [string]$summary.connectedEndpointCount }
        $btStatus.Text=('取得時刻（UTC）: ' + $sample.capturedUtc + "`r`n無線: " + $summary.radioState + ' ／ 接続エンドポイント数: ' + $connections + "`r`n接続中と入力中・通信量は別です。Classic/LEで同じ機器が重複する場合があります。")
        $changed=$true
    }
    if ($completed) {
        try { [void]$script:bluetoothMonitor.worker.EndInvoke($script:bluetoothMonitor.handle) }
        catch { $script:bluetoothTest.bluetoothSampling.errorType=$_.Exception.GetType().Name }
        $script:bluetoothTest.bluetoothSampling.endedUtc=[DateTime]::UtcNow.ToString('o')
        $script:bluetoothTest.bluetoothSampling.limitReached=($btSampling.Checked -and @($script:bluetoothTest.bluetoothSamples).Count -ge $script:bluetoothMonitor.limit)
        $script:bluetoothMonitor.worker.Dispose(); $script:bluetoothMonitor.cancel.Dispose(); $script:bluetoothMonitor=$null
        $changed=$true; Update-UiState
    }
    if ($changed) {
        if ($script:activeTest) { Update-TestDuration $script:activeTest }
        Save-CurrentSession
    }
    if ($script:closing -and -not $script:bluetoothMonitor -and -not $script:worker) { $form.Close() }
}
function Start-CollectionWorker {
    param([string]$Mode, [DateTime]$StartUtc=([DateTime]::UtcNow.AddHours(-24)), [DateTime]$EndUtc=([DateTime]::UtcNow))
    $script:worker=[PowerShell]::Create()
    $script:workerMode=$Mode
    [void]$script:worker.AddScript({
        param($CorePath,$InventoryPath,$Mode,$Salt,$StartUtc,$EndUtc,$CaptureDrivers)
        $ErrorActionPreference='Stop'
        . $CorePath
        . $InventoryPath
        if ($Mode -eq 'inventory') { Get-DiagnosticInventory $Salt }
        elseif($Mode -eq 'context'){Get-ReproductionContext $Salt}
        else { Get-TestEvidence -Start $StartUtc -End $EndUtc -Salt $Salt -IncludeDrivers:$CaptureDrivers }
    }).AddArgument((Join-Path $PSScriptRoot 'Core.ps1')).AddArgument((Join-Path $PSScriptRoot 'Inventory.ps1')).AddArgument($Mode).AddArgument($script:session.id).AddArgument($StartUtc).AddArgument($EndUtc).AddArgument(($Mode -eq 'events' -and $script:eventsTest.kind -eq 'driver'))
    $script:workerHandle=$script:worker.BeginInvoke()
    $status.Text='PC情報・関連イベントを取得しています。画面はそのままお待ちください。'
    Update-UiState
}
function Set-TestPreset {
    $definition=$script:definitions[$testChoice.SelectedIndex]
    $outputChoice.SelectedItem=$definition.output
    $powerChoice.SelectedItem=$definition.power
    $changeText.Text=$definition.change
    $btCondition.SelectedIndex=[Math]::Max(0,[Array]::IndexOf($script:btConditions,$definition.btCondition))
    $inputActivity.SelectedIndex=[Math]::Max(0,[Array]::IndexOf($script:inputActivities,$definition.inputActivity))
    $guide.Text=$definition.guide + "`r`n`r`n録音ありでは指定した秒数で終了。録音なしは10分が目安です。同じ素材と音量で比較し、一度に変える条件は一つにします。改善しない設定は元に戻します。機材や設定項目がなければ「未実施」を記録できます。"
    if ($definition.id -like 'bt*') { $guide.Text += ' Bluetoothの手動条件と取得状態は隣のタブで確認できます。' }
    $notes.Text=''; $reference.Text=''
    Update-UiState
}

. (Join-Path $PSScriptRoot 'WorkflowLayout.ps1')
$script:uiReady=$true

$profilePath=Join-Path $script:dataRoot 'profile.json'
if (Test-Path -LiteralPath $profilePath) {
    try {
        $savedProfile=Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Set-ProfileControls $savedProfile
    } catch { $status.Text='保存したプロフィールを読めませんでした。元のファイルは保持しています。' }
}

$testChoice.Add_SelectedIndexChanged({ Set-TestPreset })
$collect.Add_Click({
    try {
        $profile=Get-CurrentProfile
        Write-AtomicText $profilePath ($profile | ConvertTo-Json -Depth 8)
        $script:session=New-DiagnosticSession $profile
        $script:sessionDirectory=Join-Path (Join-Path $script:dataRoot 'sessions') $script:session.id
        Refresh-AudioRecords
        Refresh-PhysicalRecords
        Save-CurrentSession
        Start-CollectionWorker 'inventory'
    } catch { Show-UiError $_.Exception.Message; Update-UiState }
})
$resume.Add_Click({
    $dialog=New-Object Windows.Forms.OpenFileDialog
    $dialog.Title='再開する session.json を選択'; $dialog.Filter='調査ログ (session.json)|session.json'; $dialog.InitialDirectory=Join-Path $script:dataRoot 'sessions'
    try {
        if ($dialog.ShowDialog() -eq 'OK') {
            $loaded=Read-Session $dialog.FileName
            # Preserve the imported original, even for a compatible schema.
            if ($loaded.id -notmatch '^[a-fA-F0-9]{32}$') { throw '調査ログのIDが正しくありません。' }
            $script:sessionDirectory=Join-Path (Join-Path $script:dataRoot 'sessions') $loaded.id
            $target=Join-Path $script:sessionDirectory 'session.json'
            if ([IO.Path]::GetFullPath($target) -ne [IO.Path]::GetFullPath($dialog.FileName) -and (Test-Path -LiteralPath $target)) { throw '同じIDの記録がすでにあります。保存先のsession.jsonを選択してください。' }
            foreach ($test in @($loaded.tests | Where-Object { $_.result -eq 'InProgress' })) { $test.result='Interrupted'; $test.endedUtc=$loaded.updatedUtc; $test.notes += ' / 前回の保存以降は観察時間不明のため中断として再開。' }
            Import-SessionAudio $loaded (Split-Path -Parent $dialog.FileName) $script:sessionDirectory
            Import-PhysicalFiles $loaded (Split-Path -Parent $dialog.FileName) $script:sessionDirectory
            Import-SessionTraces (Split-Path -Parent $dialog.FileName) $script:sessionDirectory
            foreach($probe in @($loaded.audioProbes | Where-Object {$_.status -in @('Starting','Recording')})){$probe.status='Interrupted';$probe.verification.reviewPlaybackCompleted=$false;$probe.verification.notes+=' 録音が中断され、WAVが未確定の可能性があります。'}
            $script:session=$loaded
            Set-ProfileControls $loaded.profile
            Save-CurrentSession
            Refresh-AudioRecords
            Refresh-PhysicalRecords
            $status.Text='記録を再開しました。前のテストは保持し、新しいテストを追加できます。'
            $tabs.SelectedTab=$settingsPage
            Update-UiState
        }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose() }
})
$start.Add_Click({
    try {
        $script:session.profile=Get-CurrentProfile
        Write-AtomicText $profilePath ($script:session.profile | ConvertTo-Json -Depth 8)
        $test=New-TestRecord $script:definitions[$testChoice.SelectedIndex].id ([string]$outputChoice.SelectedItem) ([string]$powerChoice.SelectedItem) $appName.Text $changeText.Text $notes.Text $reference.Text.Trim()
        if(-not (Test-CaptureReady)){throw '録音先と録音範囲を確認してください。'}
        $test.defaultEndpoint=Invoke-CollectionSection { Get-DefaultEndpoint }
        $test.conditions=Get-ManualPlaybackConditions
        $test|Add-Member -NotePropertyName capturePlan -NotePropertyValue ([pscustomobject]@{method=@('Reference','ExternalApp','ObservationOnly')[$audioMode.SelectedIndex];source=if($audioMode.SelectedIndex -eq 2){$null}elseif($audioSource.SelectedIndex -eq 1){'Microphone'}else{'Loopback'};maximumSeconds=if($audioMode.SelectedIndex -eq 2){$null}else{[int]$audioLength.SelectedItem};recordingConsent=($audioMode.SelectedIndex -ne 2 -and $audioConsent.Checked)})
        $test.playbackSnapshots=@(Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id})
        $test.bluetoothCondition=$script:btConditions[$btCondition.SelectedIndex]; $test.inputActivity=$script:inputActivities[$inputActivity.SelectedIndex]
        $test.bluetoothSampling=[pscustomobject]@{ enabled=$btSampling.Checked; intervalSeconds=10; maxSamples=if ($btSampling.Checked) {720} else {1}; limitReached=$false; endedUtc=$null; errorType=$null }
        $script:session.tests=@($script:session.tests) + @($test)
        $script:activeTest=$test
        [void](Add-TimelineEvent $script:session 'TestStarted' $test.id)
        Save-CurrentSession
        $script:bluetoothTest=$test
        $script:bluetoothMonitor=Start-BluetoothMonitor -Salt $script:session.id -InventoryPath (Join-Path $PSScriptRoot 'Inventory.ps1') -MaxSamples $test.bluetoothSampling.maxSamples
        $script:finishRequested=$false
        Start-ObservationCapture $test.id
        $script:contextTest=$test;Start-CollectionWorker 'context'
        $tabs.SelectedTab=$runPage
        $runAudioStatus.Text=if($audioMode.SelectedIndex -eq 2){'音声録音は行いません。ノイズ時刻と状態の記録を開始しました。'}else{'録音を開始しています。設定した秒数で録音と観察が自動終了します。'}
        $status.Text='調査を開始しました。ノイズは共通ボタンで記録してください。'
        Update-UiState
    } catch { if($script:activeTest){$script:activeTest.notes+=' / 調査開始中に取得・録音エラー。';Request-ObservationFinish};Show-UiError $_.Exception.Message }
})
$mark.Add_Click({
    if ($script:activeTest -and -not $script:finishRequested) {
        try {
            $noiseProbeId=if($script:audioRecorder -and -not $script:audioRecorder.Finished){$script:recordingProbe.id}else{''}
            $event=Add-TimelineEvent $script:session 'NoiseHeard' $script:activeTest.id $noiseProbeId
            $timestamp=$event.utc
            if($script:activeTest){$script:activeTest.noiseUtc=@($script:activeTest.noiseUtc)+@($timestamp);Update-TestDuration $script:activeTest
                if(@($script:activeTest.noiseUtc).Count -eq 1){$script:activeTest.playbackSnapshots+=@(Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id})}
            }
            if($script:audioRecorder -and -not $script:audioRecorder.Finished){$script:recordingProbe.noiseMarkersUtc=@($script:recordingProbe.noiseMarkersUtc)+@($timestamp);$script:recordingProbe.verification.liveNoise='Yes'}
            Save-CurrentSession
        } catch { Show-UiError $_.Exception.Message }
    }
})
$finish.Add_Click({try{Request-ObservationFinish}catch{Show-UiError $_.Exception.Message}})
$skip.Add_Click({
    try {
        $test=New-TestRecord $script:definitions[$testChoice.SelectedIndex].id ([string]$outputChoice.SelectedItem) ([string]$powerChoice.SelectedItem) $appName.Text $changeText.Text $notes.Text $reference.Text.Trim()
        $test.result='NotRun'; $test.endedUtc=$test.startedUtc
        $script:session.tests=@($script:session.tests) + @($test)
        Save-CurrentSession
        $status.Text='未実施として保存しました。必要な機材がある項目から比較してください。'
    } catch { Show-UiError $_.Exception.Message }
})
$report.Add_Click({ try { Save-CurrentSession; Start-Process -FilePath (Join-Path $script:sessionDirectory 'report.html') } catch { Show-UiError $_.Exception.Message } })
$folder.Add_Click({ try { Start-Process explorer.exe -ArgumentList ('"' + $script:sessionDirectory + '"') } catch { Show-UiError $_.Exception.Message } })
$export.Add_Click({try{
    Save-CurrentSession
    $archive=Export-DiagnosticBundle $script:sessionDirectory (Join-Path $script:dataRoot 'exports') -IncludeTraces:$includeTraces.Checked
    $status.Text='ZIPを書き出しました: '+[IO.Path]::GetFileName($archive)
    if(-not $SmokeTest){Start-Process explorer.exe -ArgumentList ('/select,"'+$archive+'"')}
    $script:lastExport=$archive
}catch{Show-UiError $_.Exception.Message}})

$timer=New-Object Windows.Forms.Timer; $timer.Interval=500
$timer.Add_Tick({
    Poll-DetailedTrace
    try{Poll-PhoneReceiver}catch{$status.Text='スマートフォン記録の保存に失敗しました。';Show-UiError $_.Exception.Message}
    try{Poll-AudioJobs}catch{$status.Text='音声記録の保存に失敗しました。';Show-UiError $_.Exception.Message}
    if($script:closing -and -not $script:audioRecorder -and -not $script:audioPlayback -and -not $script:worker -and -not $script:bluetoothMonitor){$form.Close();return}
    try { Receive-BluetoothSamples } catch { $status.Text='Bluetooth記録の保存に失敗しました。'; Show-UiError $_.Exception.Message }
    if ($script:activeTest) {
        Update-TestDuration $script:activeTest
        $seconds=[int]$script:activeTest.durationSeconds
        $elapsed.Text=('{0:00}:{1:00} / ノイズ {2} 回' -f [int][Math]::Floor($seconds/60),($seconds%60),@($script:activeTest.noiseUtc).Count)
        if ($seconds -ge 600) { $status.Text='10分経過しました。「終了して結果を記録」で終了できます。' }
    }
    if ($script:worker -and $script:workerHandle.IsCompleted) {
        try {
            $value=@($script:worker.EndInvoke($script:workerHandle))
            if ($script:worker.HadErrors -or $value.Count -ne 1) { throw '情報取得の一部を完了できませんでした。すでに保存した記録は保持しています。' }
            if ($script:workerMode -eq 'inventory') { $script:session.inventory=$value[0];$tabs.SelectedTab=$settingsPage }
            elseif($script:workerMode -eq 'context'){$script:contextTest.context=$value[0]}
            else {
                $script:eventsTest | Add-Member -NotePropertyName relatedEvents -NotePropertyValue $value[0].relatedEvents -Force
                $script:eventsTest | Add-Member -NotePropertyName bluetoothEndState -NotePropertyValue $value[0].bluetoothEndState -Force
                if ($value[0].driverSnapshot) { $script:eventsTest | Add-Member -NotePropertyName driverSnapshot -NotePropertyValue $value[0].driverSnapshot -Force }
            }
            Save-CurrentSession
            $status.Text='保存しました。報告書で取得結果と次の手順を確認できます。'
        } catch { $status.Text='取得を完了できませんでした。保存済みの記録は保持しています。'; Show-UiError $_.Exception.Message }
        finally { $script:worker.Dispose(); $script:worker=$null; $script:workerHandle=$null; Update-UiState }
    }
    Complete-ObservationFinish
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if($script:traceProcess){Request-TraceStop;$eventArgs.Cancel=$true;$status.Text='詳細トレースを保存しています。終了してから閉じてください。';return}
    if($script:phoneReceiver){try{Stop-PhoneReceiver}catch{Show-UiError $_.Exception.Message;$eventArgs.Cancel=$true;return}}
    if($script:audioRecorder -or $script:audioPlayback){$script:finishRequested=$false;if($script:audioRecorder){$script:audioRecorder.Stop()};if($script:audioPlayback){$script:audioPlayback.Stop()};if($script:bluetoothMonitor){[void]$script:bluetoothMonitor.cancel.Set()};$script:closing=$true;$eventArgs.Cancel=$true;$status.Text='音声ファイルを確定してから閉じます。';return}
    if ($script:worker) { $eventArgs.Cancel=$true; if(-not $SmokeTest){[Windows.Forms.MessageBox]::Show('情報の取得中です。取得が終わってから閉じてください。','取得中') | Out-Null}; return }
    if ($script:activeTest) {
        try {
            $script:activeTest.result='Interrupted';Complete-TestTiming $script:activeTest
            [void](Add-TimelineEvent $script:session 'TestInterrupted' $script:activeTest.id)
            Save-CurrentSession
            $script:activeTest=$null
        } catch { $eventArgs.Cancel=$true; Show-UiError $_.Exception.Message }
    }
    if ($script:bluetoothMonitor) {
        [void]$script:bluetoothMonitor.cancel.Set(); $script:closing=$true; $eventArgs.Cancel=$true
        $status.Text='Bluetoothの記録を保存してから閉じます。'
    }
})
try {
    Set-TestPreset
    Update-UiState
    if($SmokeTest){. (Join-Path $PSScriptRoot 'UiSmoke.ps1')}else{$timer.Start();[Windows.Forms.Application]::Run($form)}
} finally {
    $timer.Stop(); $timer.Dispose(); $form.Dispose()
    if ($script:bluetoothMonitor) { [void]$script:bluetoothMonitor.cancel.Set(); $script:bluetoothMonitor.worker.Stop(); $script:bluetoothMonitor.worker.Dispose(); $script:bluetoothMonitor.cancel.Dispose() }
    if($script:audioRecorder){$script:audioRecorder.Dispose();Complete-AudioProbeRecord $script:recordingProbe $script:audioRecorder $script:sessionDirectory;Save-CurrentSession}
    if($script:audioPlayback){$script:audioPlayback.Dispose()}
    if($script:phoneReceiver){$script:phoneReceiver.Dispose();$received=$null;while($script:phoneReceiver.Received.TryDequeue([ref]$received)){Add-PhysicalMedia $received}}
    if ($script:toolLock) { $script:toolLock.Dispose() }
}
