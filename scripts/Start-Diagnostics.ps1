param([switch]$SmokeTest, [string]$ScreenshotPath, [switch]$ExerciseWorkflow, [switch]$ExerciseAudioWorkflow, [switch]$ExercisePhoneWorkflow, [switch]$ExerciseExportWorkflow, [ValidateSet('Tests','Bluetooth','Audio','Phone','Evidence')][string]$ScreenshotTab='Tests')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'AudioUi.ps1')
. (Join-Path $PSScriptRoot 'EvidenceUi.ps1')
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
        $recordCount.Text=('保存済みテスト: ' + @($script:session.tests).Count + ' 件　／　記録は data フォルダー内（非公開）')
        $history.Text=($script:session.tests | ForEach-Object { $_.id + "`r`n" + $_.kind + ' / ' + (Get-ResultLabel $_.result) + ' / ' + $_.durationSeconds + '秒 / ノイズ ' + @($_.noiseUtc).Count + "回`r`n" + $_.change + "`r`n" }) -join "`r`n"
    }
}
function Update-UiState {
    $busy=($null -ne $script:worker -or $null -ne $script:bluetoothMonitor -or $script:audioRecorder -or $script:audioPlayback)
    $running=$null -ne $script:activeTest
    $collect.Enabled=(-not $busy -and -not $running -and -not $script:traceProcess)
    $resume.Enabled=$collect.Enabled
    $start.Enabled=($null -ne $script:session -and -not $busy -and -not $running)
    $skip.Enabled=$start.Enabled
    $mark.Enabled=($running -or [bool]$script:audioRecorder)
    $finish.Enabled=($running -and -not $script:audioRecorder -and -not $script:audioPlayback -and -not $script:worker)
    foreach ($control in @($testChoice,$outputChoice,$powerChoice,$appName,$changeText,$notes,$reference,$speaker,$profilePower,$cStates,$observations,$btCondition,$inputActivity,$btSampling)) { $control.Enabled=(-not $busy -and -not $running) }
    $report.Enabled=($null -ne $script:session)
    $folder.Enabled=($null -ne $script:session)
    $export.Enabled=($script:session -and -not $busy -and -not $running -and -not $script:phoneReceiver -and -not $script:traceProcess)
    $includeTraces.Enabled=$export.Enabled
    foreach($control in @($material,$applicationOutput,$volume,$enhancements,$recentActions)){$control.Enabled=(-not $running -and -not $busy)}
    $traceStart.Enabled=($script:session -and $traceConsent.Checked -and -not $script:traceProcess -and -not $script:worker)
    $traceStop.Enabled=[bool]$script:traceProcess
    Update-AudioUi
    Update-PhoneUi
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
    $guide.Text=$definition.guide + "`r`n`r`n標準は10分。同じ素材と音量で比較し、一度に変える条件は一つにします。改善しない設定は元に戻します。機材や設定項目がなければ「未実施」を記録できます。"
    if ($definition.id -like 'bt*') { $guide.Text += ' Bluetoothの手動条件と取得状態は隣のタブで確認できます。' }
    $notes.Text=''; $reference.Text=''
}

$form=New-Object Windows.Forms.Form
$form.Text='Windows Audio Noise Diagnostics'
$form.Size=New-Object Drawing.Size(1120,940)
$form.MinimumSize=New-Object Drawing.Size(960,800)
$workArea=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size=New-Object Drawing.Size([Math]::Min(1120,$workArea.Width-32),[Math]::Min(940,$workArea.Height-32))
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Yu Gothic UI',10)
$form.BackColor=[Drawing.Color]::FromArgb(243,246,248)
$form.AutoScaleMode='Dpi'
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill'; $layout.Padding=New-Object Windows.Forms.Padding(16); $layout.ColumnCount=1; $layout.RowCount=7
foreach ($height in @(56,42,158,48,0,42,48)) {
    $style=New-Object Windows.Forms.RowStyle
    if ($height -eq 0) { $style.SizeType='Percent'; $style.Height=100 } else { $style.SizeType='Absolute'; $style.Height=$height }
    [void]$layout.RowStyles.Add($style)
}
$form.Controls.Add($layout)
$header=New-UiLabel ('Windows 音声ノイズ調査  /  v' + (Get-ToolIdentity).version)
$header.Font=New-Object Drawing.Font('Yu Gothic UI',20,[Drawing.FontStyle]::Bold)
$header.ForeColor=[Drawing.Color]::FromArgb(10,100,109)
$layout.Controls.Add($header,0,0)
$intro=New-UiLabel 'まずPC情報を収集 → 条件を比較 → 必要なら音声を録音・聞き直し。設定変更・外部送信は行いません。'
$layout.Controls.Add($intro,0,1)

$profileGrid=New-Object Windows.Forms.TableLayoutPanel
$profileGrid.Dock='Fill'; $profileGrid.ColumnCount=4; $profileGrid.RowCount=3
foreach ($width in @(15,35,15,35)) { [void]$profileGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width))) }
$speaker=New-Object Windows.Forms.TextBox; $speaker.Dock='Fill'; $speaker.Margin=New-Object Windows.Forms.Padding(6)
$profilePower=New-UiCombo @('PCのUSB','独立したUSB電源','テレビのUSB','不明・その他')
$cStates=New-UiCombo @('未確認','Disabled（確認済み）','Enabled（確認済み）')
$observations=New-Object Windows.Forms.TextBox; $observations.Dock='Fill'; $observations.Multiline=$true; $observations.ScrollBars='Vertical'; $observations.Margin=New-Object Windows.Forms.Padding(6)
$profileGrid.Controls.Add((New-UiLabel 'スピーカー型番'),0,0); $profileGrid.Controls.Add($speaker,1,0)
$profileGrid.Controls.Add((New-UiLabel '現在の給電先'),2,0); $profileGrid.Controls.Add($profilePower,3,0)
$profileGrid.Controls.Add((New-UiLabel 'C-States'),0,1); $profileGrid.Controls.Add($cStates,1,1)
$profileGrid.Controls.Add((New-UiLabel 'BIOS画像などで確認した状態を記録。自動取得しません。'),2,1); $profileGrid.SetColumnSpan($profileGrid.GetControlFromPosition(2,1),2)
$profileGrid.Controls.Add((New-UiLabel '確認済みの症状'),0,2); $profileGrid.Controls.Add($observations,1,2); $profileGrid.SetColumnSpan($observations,3)
$layout.Controls.Add($profileGrid,0,2)

$actions=New-Object Windows.Forms.FlowLayoutPanel; $actions.Dock='Fill'
$collect=New-UiButton 'PC情報を収集・新規調査'; $resume=New-UiButton '記録を再開'; $report=New-UiButton '報告書を開く'; $folder=New-UiButton '保存先を開く'
$export=New-UiButton 'データを書き出す'
$includeTraces=New-Object Windows.Forms.CheckBox;$includeTraces.Text='詳細ETLも含める';$includeTraces.AutoSize=$true;$includeTraces.Margin=New-Object Windows.Forms.Padding(6,13,0,0)
$actions.Controls.AddRange([Windows.Forms.Control[]]@($collect,$resume,$report,$folder,$export,$includeTraces)); $layout.Controls.Add($actions,0,3)

$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'
$testTab=New-Object Windows.Forms.TabPage; $testTab.Text='比較テスト'; $testTab.Padding=New-Object Windows.Forms.Padding(8)
$historyTab=New-Object Windows.Forms.TabPage; $historyTab.Text='記録とテストID'
$history=New-Object Windows.Forms.TextBox; $history.Multiline=$true; $history.ReadOnly=$true; $history.ScrollBars='Vertical'; $history.Dock='Fill'; $historyTab.Controls.Add($history)
$btTab=New-Object Windows.Forms.TabPage; $btTab.Text='Bluetooth条件と取得状態'; $btTab.Padding=New-Object Windows.Forms.Padding(12)
$btGrid=New-Object Windows.Forms.TableLayoutPanel; $btGrid.Dock='Fill'; $btGrid.ColumnCount=2; $btGrid.RowCount=5
[void]$btGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',190))); [void]$btGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
foreach ($height in @(40,40,42,130,0)) { $s=New-Object Windows.Forms.RowStyle; if ($height -eq 0) { $s.SizeType='Percent'; $s.Height=100 } else { $s.SizeType='Absolute'; $s.Height=$height }; [void]$btGrid.RowStyles.Add($s) }
$btCondition=New-UiCombo @('未確認','Bluetooth無線オフ','無線オン・BTキーボード電源オフ','BTキーボード接続')
$inputActivity=New-UiCombo @('未確認','有線のみ使用','Bluetooth接続・待機','Bluetoothで入力中（手動申告）')
$btSampling=New-Object Windows.Forms.CheckBox; $btSampling.Text='テスト中にBluetooth状態を約10秒間隔で記録（最大720回）'; $btSampling.Checked=$true; $btSampling.AutoSize=$true
$btHelp=New-UiLabel "有線キーボードは全条件で接続したまま比較してください。音声出力・給電・素材・音量も維持します。`r`nBluetoothの切替はWindows設定で手動実施。ツールは切断や設定変更を行いません。`r`n上の条件は手動の記録です。Bluetooth状態の自動取得と区別します。`r`nキー内容・入力イベント・パケット・電波強度は取得しません。定期記録を外しても開始側の1回と終了後の状態は取得します。"
$btHelp.Dock='Fill'; $btHelp.AutoSize=$false
$btStatus=New-UiLabel 'テストを開始すると、取得できた無線と接続状態をここへ表示します。'; $btStatus.Dock='Fill'; $btStatus.AutoSize=$false
$btGrid.Controls.Add((New-UiLabel 'Bluetooth条件（手動）'),0,0); $btGrid.Controls.Add($btCondition,1,0)
$btGrid.Controls.Add((New-UiLabel '入力状況（手動）'),0,1); $btGrid.Controls.Add($inputActivity,1,1)
$btGrid.Controls.Add($btSampling,0,2); $btGrid.SetColumnSpan($btSampling,2)
$btGrid.Controls.Add($btHelp,0,3); $btGrid.SetColumnSpan($btHelp,2)
$btGrid.Controls.Add($btStatus,0,4); $btGrid.SetColumnSpan($btStatus,2); $btTab.Controls.Add($btGrid)
$tabs.TabPages.AddRange([Windows.Forms.TabPage[]]@($testTab,$btTab,$historyTab)); $layout.Controls.Add($tabs,0,4)
$audioTab=New-AudioCaptureTab;[void]$tabs.TabPages.Add($audioTab)
$phoneTab=New-PhoneCaptureTab;[void]$tabs.TabPages.Add($phoneTab)
$evidenceTab=New-EvidenceTab;[void]$tabs.TabPages.Add($evidenceTab)
$tabs.Add_SelectedIndexChanged({if($tabs.SelectedTab -eq $audioTab -and $audioOutput.Items.Count -eq 0){Refresh-AudioOutputs}})
$testGrid=New-Object Windows.Forms.TableLayoutPanel; $testGrid.Dock='Fill'; $testGrid.ColumnCount=2; $testGrid.RowCount=7
[void]$testGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',175)))
[void]$testGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
foreach ($height in @(36,100,36,36,36,0,36)) { $s=New-Object Windows.Forms.RowStyle; if ($height -eq 0) { $s.SizeType='Percent'; $s.Height=100 } else { $s.SizeType='Absolute'; $s.Height=$height }; [void]$testGrid.RowStyles.Add($s) }
$testTab.Controls.Add($testGrid)
$testChoice=New-UiCombo @($script:definitions | ForEach-Object { $_.title })
$guide=New-UiLabel ''; $guide.Dock='Fill'; $guide.AutoSize=$false; $guide.ForeColor=[Drawing.Color]::FromArgb(40,85,96)
$outputChoice=New-UiCombo @('3.5mm','HDMI','USB音声','Bluetooth','その他')
$powerChoice=New-UiCombo @('PCのUSB','独立したUSB電源','テレビのUSB','該当なし','不明・その他')
$connections=New-Object Windows.Forms.TableLayoutPanel; $connections.Dock='Fill'; $connections.ColumnCount=3
foreach ($width in @(40,15,45)) { [void]$connections.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width))) }
$connections.Controls.Add($outputChoice,0,0); $connections.Controls.Add((New-UiLabel '給電'),1,0); $connections.Controls.Add($powerChoice,2,0)
$appName=New-Object Windows.Forms.TextBox; $appName.Dock='Fill'; $appName.Margin=New-Object Windows.Forms.Padding(6)
$changeText=New-Object Windows.Forms.TextBox; $changeText.Dock='Fill'; $changeText.Margin=New-Object Windows.Forms.Padding(6)
$notes=New-Object Windows.Forms.TextBox; $notes.Dock='Fill'; $notes.Multiline=$true; $notes.ScrollBars='Vertical'; $notes.Margin=New-Object Windows.Forms.Padding(6)
$reference=New-Object Windows.Forms.TextBox; $reference.Dock='Fill'; $reference.Margin=New-Object Windows.Forms.Padding(6)
foreach ($entry in @(
    @('テスト',$testChoice),@('手順',$guide),@('音声出力',$connections),@('再生アプリ / 素材',$appName),@('今回変える条件',$changeText),@('備考 / 元の設定',$notes),@('比較先のテストID',$reference)
)) { $row=$testGrid.Controls.Count / 2; $testGrid.Controls.Add((New-UiLabel $entry[0]),0,[int]$row); $testGrid.Controls.Add($entry[1],1,[int]$row) }
$recordCount=New-UiLabel 'まだ記録はありません。既存の記録を再開するか、PC情報を収集してください。'; $layout.Controls.Add($recordCount,0,5)
$bottom=New-Object Windows.Forms.FlowLayoutPanel; $bottom.Dock='Fill'
$start=New-UiButton 'テスト開始'; $mark=New-UiButton 'ノイズが聞こえた'; $finish=New-UiButton 'テスト終了'; $skip=New-UiButton '未実施を記録'
$mark.BackColor=[Drawing.Color]::FromArgb(14,112,120); $mark.ForeColor=[Drawing.Color]::White
$elapsed=New-UiLabel '00:00 / ノイズ 0 回'
$bottom.Controls.AddRange([Windows.Forms.Control[]]@($start,$mark,$finish,$skip,$elapsed)); $layout.Controls.Add($bottom,0,6)
$status=New-Object Windows.Forms.ToolStripStatusLabel; $status.Text='オフラインで利用できます。更新はツールを閉じて update.cmd から。'
$statusStrip=New-Object Windows.Forms.StatusStrip; [void]$statusStrip.Items.Add($status); $form.Controls.Add($statusStrip)

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
            Update-UiState
        }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose() }
})
$start.Add_Click({
    try {
        $script:session.profile=Get-CurrentProfile
        Write-AtomicText $profilePath ($script:session.profile | ConvertTo-Json -Depth 8)
        $test=New-TestRecord $script:definitions[$testChoice.SelectedIndex].id ([string]$outputChoice.SelectedItem) ([string]$powerChoice.SelectedItem) $appName.Text $changeText.Text $notes.Text $reference.Text.Trim()
        $test.defaultEndpoint=Invoke-CollectionSection { Get-DefaultEndpoint }
        $test.conditions=Get-ManualPlaybackConditions
        $test.playbackSnapshots=@(Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id})
        $test.bluetoothCondition=$script:btConditions[$btCondition.SelectedIndex]; $test.inputActivity=$script:inputActivities[$inputActivity.SelectedIndex]
        $test.bluetoothSampling=[pscustomobject]@{ enabled=$btSampling.Checked; intervalSeconds=10; maxSamples=if ($btSampling.Checked) {720} else {1}; limitReached=$false; endedUtc=$null; errorType=$null }
        $script:session.tests=@($script:session.tests) + @($test)
        $script:activeTest=$test
        [void](Add-TimelineEvent $script:session 'TestStarted' $test.id)
        Save-CurrentSession
        $script:bluetoothTest=$test
        $script:bluetoothMonitor=Start-BluetoothMonitor -Salt $script:session.id -InventoryPath (Join-Path $PSScriptRoot 'Inventory.ps1') -MaxSamples $test.bluetoothSampling.maxSamples
        $script:contextTest=$test;Start-CollectionWorker 'context'
        $status.Text='再生してノイズを確認してください。10分を目安に観察し、ノイズが聞こえたらボタンを押します。'
        Update-UiState
    } catch { Show-UiError $_.Exception.Message }
})
$mark.Add_Click({
    if ($script:activeTest -or $script:audioRecorder) {
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
$finish.Add_Click({
    try {
        $test=$script:activeTest
        Complete-TestTiming $test
        [void](Add-TimelineEvent $script:session 'ObservationEnded' $test.id)
        $test.playbackSnapshots+=@(Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id})
        # Result selection is enabled at finish; it describes the whole completed observation.
        $answerForm=New-Object Windows.Forms.Form; $answerForm.Text='テスト結果'; $answerForm.Size=New-Object Drawing.Size(600,380); $answerForm.StartPosition='CenterParent'; $answerForm.Font=$form.Font
        $answer=New-UiCombo @('再現せず','改善','変化なし','悪化'); $answer.Dock='Top'
        $answer.SelectedIndex=if (@($test.noiseUtc).Count -gt 0) { 2 } else { 0 }
        $explain=New-UiLabel ('ノイズ記録 ' + @($test.noiseUtc).Count + ' 回。結果と、気づいた点・押し忘れを記録してください。'); $explain.Dock='Top'
        $endNotes=New-Object Windows.Forms.TextBox; $endNotes.Multiline=$true; $endNotes.ScrollBars='Vertical'; $endNotes.Dock='Fill'; $endNotes.Text=$test.notes
        $accept=New-UiButton '保存'; $accept.Dock='Bottom'; $accept.DialogResult='OK'
        $answerForm.Controls.Add($endNotes); $answerForm.Controls.Add($answer); $answerForm.Controls.Add($explain); $answerForm.Controls.Add($accept); $answerForm.AcceptButton=$accept
        if ($SmokeTest -and ($ExerciseWorkflow -or $ExerciseAudioWorkflow)) {
            $answerForm.Add_Shown({ $endNotes.Text += ' / UI test completion'; $answer.SelectedIndex=2; $answerForm.DialogResult='OK'; $answerForm.Close() })
        }
        if ($answerForm.ShowDialog($form) -eq 'OK') {
            $test.result=@('NoRepro','Improved','Unchanged','Worse')[$answer.SelectedIndex]
            $test.notes=$endNotes.Text
            if ($script:bluetoothMonitor) { [void]$script:bluetoothMonitor.cancel.Set() }
            $script:activeTest=$null
            Save-CurrentSession
            $script:eventsTest=$test
            Start-CollectionWorker 'events' ([DateTime]::Parse($test.startedUtc).ToUniversalTime()) ([DateTime]::Parse($test.endedUtc).ToUniversalTime())
        } else { $test.endedUtc=$null;$test.timing.end=$null;$test.timing.wallSeconds=$null;$test.timing.clockDifferenceSeconds=$null;[void](Add-TimelineEvent $script:session 'ObservationResumedAfterDialog' $test.id) }
        $answerForm.Dispose()
    } catch { Show-UiError $_.Exception.Message; Update-UiState }
})
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
        if ($seconds -ge 600) { $status.Text='10分経過しました。観察を続けるか「テスト終了」で結果を記録してください。' }
    }
    if ($script:worker -and $script:workerHandle.IsCompleted) {
        try {
            $value=@($script:worker.EndInvoke($script:workerHandle))
            if ($script:worker.HadErrors -or $value.Count -ne 1) { throw '情報取得の一部を完了できませんでした。すでに保存した記録は保持しています。' }
            if ($script:workerMode -eq 'inventory') { $script:session.inventory=$value[0] }
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
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if($script:traceProcess){Request-TraceStop;$eventArgs.Cancel=$true;$status.Text='詳細トレースを保存しています。終了してから閉じてください。';return}
    if($script:phoneReceiver){try{Stop-PhoneReceiver}catch{Show-UiError $_.Exception.Message;$eventArgs.Cancel=$true;return}}
    if($script:audioRecorder -or $script:audioPlayback){if($script:audioRecorder){$script:audioRecorder.Stop()};if($script:audioPlayback){$script:audioPlayback.Stop()};if($script:bluetoothMonitor){[void]$script:bluetoothMonitor.cancel.Set()};$script:closing=$true;$eventArgs.Cancel=$true;$status.Text='音声ファイルを確定してから閉じます。';return}
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
    if ($SmokeTest) {
        $form.Show(); $form.PerformLayout(); [Windows.Forms.Application]::DoEvents()
        if ($ExerciseWorkflow -or $ExerciseAudioWorkflow -or $ExercisePhoneWorkflow -or $ExerciseExportWorkflow) {
            $speaker.Text='Local UI verification'; $cStates.SelectedIndex=1
            $collect.PerformClick()
            $timer.Start()
            $deadline=[DateTime]::UtcNow.AddSeconds(120)
            while (($script:worker -or $script:bluetoothMonitor) -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:worker -or -not $script:session.inventory -or -not $start.Enabled) { throw 'The UI inventory workflow did not complete.' }
            if($ExerciseExportWorkflow){
                $export.PerformClick()
                if(-not $script:lastExport -or -not (Test-Path -LiteralPath $script:lastExport)){throw 'The UI did not export a ZIP.'}
                $verified=Test-DiagnosticBundle $script:lastExport
                if($verified.manifest.sessionId -ne $script:session.id){throw 'The ZIP does not match the selected session.'}
                Write-Output 'UI export creates and verifies a complete session bundle OK'
            }elseif($ExercisePhoneWorkflow){
                $tabs.SelectedTab=$phoneTab
                [void]$phoneAddress.Items.Add('127.0.0.1');$phoneAddress.SelectedIndex=0;Update-UiState;$phoneStart.PerformClick()
                if(-not $script:phoneReceiver){throw 'The UI did not start the local receiver.'}
                $ownedReceiver=$script:phoneReceiver
                Initialize-AudioInterop
                $fixture=Join-Path $script:dataRoot 'phone-fixture.wav';[AudioNoiseDiagnostics.AudioFiles]::GenerateReference($fixture)
                $client=New-Object Net.WebClient
                try{[void]$client.UploadData($script:phoneReceiver.Url+'upload','POST',[IO.File]::ReadAllBytes($fixture))}finally{$client.Dispose()}
                $deadline=[DateTime]::UtcNow.AddSeconds(10)
                while(@($script:session.physicalRecordings).Count -eq 0 -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                if(@($script:session.physicalRecordings).Count -ne 1 -or $collect.Enabled -or $resume.Enabled){throw 'Receiver import or session locking failed.'}
                $physicalReviewed.Checked=$true;$physicalHeard.SelectedIndex=1;$physicalRoute.Text='Synthetic UI test';$physicalSave.PerformClick()
                $form.Close()
                $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
                if(-not $ownedReceiver.Finished -or $saved.physicalRecordings[0].verification.heardNoise -ne 'Yes'){throw 'Receiver close or physical review was not saved.'}
                Write-Output 'UI phone reception, session lock, media import, manual review and listener cleanup OK'
            }elseif($ExerciseAudioWorkflow){
                $tabs.SelectedTab=$audioTab;Refresh-AudioOutputs
                if($audioOutput.Items.Count -eq 0){throw 'Audio workflow validation requires an active render endpoint.'}
                $audioConsent.Checked=$true;[void]$audioLength.Items.Add('3');$audioLength.SelectedItem='3'
                $start.PerformClick()
                $audioStart.PerformClick()
                $deadline=[DateTime]::UtcNow.AddSeconds(15)
                while($script:audioRecorder -and $script:audioRecorder.Status -eq 'Starting' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                $audioNoise.PerformClick()
                while($script:audioRecorder -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                if($script:audioRecorder -or $script:session.audioProbes[0].status -ne 'Completed'){throw 'UI loopback recording failed.'}
                $deadline=[DateTime]::UtcNow.AddSeconds(60)
                while($script:worker -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                $finish.PerformClick()
                $deadline=[DateTime]::UtcNow.AddSeconds(45)
                while(($script:worker -or $script:bluetoothMonitor) -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                if($script:worker -or $script:bluetoothMonitor){throw 'Comparison evidence did not finish after the audio recording.'}
                $audioReplay.PerformClick()
                $deadline=[DateTime]::UtcNow.AddSeconds(15)
                while($script:audioPlayback -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                if($script:audioPlayback -or -not $script:session.audioProbes[0].verification.reviewPlaybackCompleted){throw 'UI WAV replay did not complete.'}
                $audioLive.SelectedIndex=1;$audioRecorded.SelectedIndex=2;$audioResemblance.SelectedIndex=2;$audioSaveReview.PerformClick()
                $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
                if($saved.audioProbes[0].verification.replayNoise -ne 'No' -or $saved.audioProbes[0].noiseMarkersUtc.Count -ne 1){throw 'UI audio verification was not saved.'}
                $start.PerformClick();$audioMode.SelectedIndex=1;$audioStart.PerformClick();$form.Close()
                $deadline=[DateTime]::UtcNow.AddSeconds(90)
                while(($script:audioRecorder -or $script:bluetoothMonitor -or $script:worker -or -not $form.IsDisposed) -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
                $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
                if($script:audioRecorder -or $script:bluetoothMonitor -or $saved.audioProbes.Count -ne 2 -or $saved.audioProbes[1].status -in @('Starting','Recording') -or $saved.tests[1].result -ne 'Interrupted'){throw ('Closing during recording did not finalize the WAV and comparison. recording='+[bool]$script:audioRecorder+' monitoring='+[bool]$script:bluetoothMonitor+' worker='+[bool]$script:worker+' closing='+$script:closing+' disposed='+$form.IsDisposed+' result='+$saved.tests[1].result)}
                Write-Output 'UI reference playback, loopback recording, marker, WAV replay, verification and close/finalization OK'
            }else{
            $testChoice.SelectedIndex=7
            $start.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            while (@($script:activeTest.bluetoothSamples).Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if (@($script:activeTest.bluetoothSamples).Count -eq 0) { throw 'No Bluetooth sample arrived in the UI.' }
            $mark.PerformClick()
            if (@($script:activeTest.noiseUtc).Count -ne 1) { throw 'The UI did not save the marker.' }
            $deadline=[DateTime]::UtcNow.AddSeconds(60)
            while($script:worker -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $finish.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(45)
            while (($script:worker -or $script:bluetoothMonitor) -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:worker -or $script:session.tests[0].result -ne 'Unchanged' -or -not $script:session.tests[0].relatedEvents -or -not $script:session.tests[0].driverSnapshot -or -not $script:session.tests[0].bluetoothEndState) { throw 'The UI did not complete the test and collect events/drivers/Bluetooth.' }
            $start.PerformClick(); $mark.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(60)
            while($script:worker -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
            $form.Close()
            $deadline=[DateTime]::UtcNow.AddSeconds(30)
            while ($script:bluetoothMonitor -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
            if ($saved.tests.Count -ne 2 -or $saved.tests[1].result -ne 'Interrupted' -or $saved.profile.cStates -ne 'Disabled') { throw 'The UI did not preserve the interrupted test/profile.' }
            Write-Output 'UI inventory, test completion, events, marker and interruption workflow OK'
            }
        }
        if ($ScreenshotPath -and -not $ExerciseWorkflow -and -not $ExerciseAudioWorkflow -and -not $ExercisePhoneWorkflow) {
            if ($ScreenshotTab -eq 'Bluetooth') { $tabs.SelectedTab=$btTab; [Windows.Forms.Application]::DoEvents() }
            if ($ScreenshotTab -eq 'Audio') { $tabs.SelectedTab=$audioTab; [Windows.Forms.Application]::DoEvents() }
            if ($ScreenshotTab -eq 'Phone') { $tabs.SelectedTab=$phoneTab; [Windows.Forms.Application]::DoEvents() }
            if ($ScreenshotTab -eq 'Evidence') { $tabs.SelectedTab=$evidenceTab; [Windows.Forms.Application]::DoEvents() }
            [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($ScreenshotPath)))) | Out-Null
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
            $bitmap.Save($ScreenshotPath,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
        }
        Write-Output 'UI smoke test OK'
    } else { $timer.Start(); [Windows.Forms.Application]::Run($form) }
} finally {
    $timer.Stop(); $timer.Dispose(); $form.Dispose()
    if ($script:bluetoothMonitor) { [void]$script:bluetoothMonitor.cancel.Set(); $script:bluetoothMonitor.worker.Stop(); $script:bluetoothMonitor.worker.Dispose(); $script:bluetoothMonitor.cancel.Dispose() }
    if($script:audioRecorder){$script:audioRecorder.Dispose();Complete-AudioProbeRecord $script:recordingProbe $script:audioRecorder $script:sessionDirectory;Save-CurrentSession}
    if($script:audioPlayback){$script:audioPlayback.Dispose()}
    if($script:phoneReceiver){$script:phoneReceiver.Dispose();$received=$null;while($script:phoneReceiver.Received.TryDequeue([ref]$received)){Add-PhysicalMedia $received}}
    if ($script:toolLock) { $script:toolLock.Dispose() }
}
