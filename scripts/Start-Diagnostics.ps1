param([switch]$SmokeTest, [string]$ScreenshotPath, [switch]$ExerciseWorkflow)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
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
    $combo.Items.AddRange([object[]]$Values); $combo.SelectedIndex=0
    return $combo
}
function Show-UiError {
    param($Failure)
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
    $busy=$null -ne $script:worker
    $running=$null -ne $script:activeTest
    $collect.Enabled=(-not $busy -and -not $running)
    $resume.Enabled=(-not $busy -and -not $running)
    $start.Enabled=($null -ne $script:session -and -not $busy -and -not $running)
    $skip.Enabled=$start.Enabled
    $mark.Enabled=$running
    $finish.Enabled=$running
    foreach ($control in @($testChoice,$outputChoice,$powerChoice,$appName,$changeText,$notes,$reference,$speaker,$profilePower,$cStates,$observations)) { $control.Enabled=(-not $busy -and -not $running) }
    $report.Enabled=($null -ne $script:session)
    $folder.Enabled=($null -ne $script:session)
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
    $guide.Text=$definition.guide + "`r`n`r`n標準は10分。同じ素材と音量で比較し、一度に変える条件は一つにします。改善しない設定は元に戻します。機材や設定項目がなければ「未実施」を記録できます。"
    $notes.Text=''; $reference.Text=''
}

$form=New-Object Windows.Forms.Form
$form.Text='G3 Plus 音声ノイズ調査'
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
$header=New-UiLabel ('G3 Plus  音声ノイズ調査  /  v' + (Get-ToolIdentity).version)
$header.Font=New-Object Drawing.Font('Yu Gothic UI',20,[Drawing.FontStyle]::Bold)
$header.ForeColor=[Drawing.Color]::FromArgb(10,100,109)
$layout.Controls.Add($header,0,0)
$intro=New-UiLabel 'まずPC情報を収集 → 条件を一つ変えて比較 → ノイズ時刻を記録。設定変更・録音・外部送信は行いません。'
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
$actions.Controls.AddRange([Windows.Forms.Control[]]@($collect,$resume,$report,$folder)); $layout.Controls.Add($actions,0,3)

$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'
$testTab=New-Object Windows.Forms.TabPage; $testTab.Text='比較テスト'; $testTab.Padding=New-Object Windows.Forms.Padding(8)
$historyTab=New-Object Windows.Forms.TabPage; $historyTab.Text='記録とテストID'
$history=New-Object Windows.Forms.TextBox; $history.Multiline=$true; $history.ReadOnly=$true; $history.ScrollBars='Vertical'; $history.Dock='Fill'; $historyTab.Controls.Add($history)
$tabs.TabPages.AddRange([Windows.Forms.TabPage[]]@($testTab,$historyTab)); $layout.Controls.Add($tabs,0,4)
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
$status=New-Object Windows.Forms.ToolStripStatusLabel; $status.Text='オフラインで利用できます。更新はツールを閉じて「更新.cmd」から。'
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
            $script:session=$loaded
            Set-ProfileControls $loaded.profile
            Save-CurrentSession
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
        $script:session.tests=@($script:session.tests) + @($test)
        $script:activeTest=$test
        Save-CurrentSession
        $status.Text='再生してノイズを確認してください。10分を目安に観察し、ノイズが聞こえたらボタンを押します。'
        Update-UiState
    } catch { Show-UiError $_.Exception.Message }
})
$mark.Add_Click({
    if ($script:activeTest) {
        try {
            $script:activeTest.noiseUtc=@($script:activeTest.noiseUtc) + @([DateTime]::UtcNow.ToString('o'))
            $script:activeTest.durationSeconds=[int]([DateTime]::UtcNow - [DateTime]::Parse($script:activeTest.startedUtc).ToUniversalTime()).TotalSeconds
            Save-CurrentSession
        } catch { Show-UiError $_.Exception.Message }
    }
})
$finish.Add_Click({
    try {
        $test=$script:activeTest
        $test.endedUtc=[DateTime]::UtcNow.ToString('o')
        $test.durationSeconds=[int]([DateTime]::UtcNow - [DateTime]::Parse($test.startedUtc).ToUniversalTime()).TotalSeconds
        # Result selection is enabled at finish; it describes the whole completed observation.
        $answerForm=New-Object Windows.Forms.Form; $answerForm.Text='テスト結果'; $answerForm.Size=New-Object Drawing.Size(600,380); $answerForm.StartPosition='CenterParent'; $answerForm.Font=$form.Font
        $answer=New-UiCombo @('再現せず','改善','変化なし','悪化'); $answer.Dock='Top'
        $answer.SelectedIndex=if (@($test.noiseUtc).Count -gt 0) { 2 } else { 0 }
        $explain=New-UiLabel ('ノイズ記録 ' + @($test.noiseUtc).Count + ' 回。結果と、気づいた点・押し忘れを記録してください。'); $explain.Dock='Top'
        $endNotes=New-Object Windows.Forms.TextBox; $endNotes.Multiline=$true; $endNotes.ScrollBars='Vertical'; $endNotes.Dock='Fill'; $endNotes.Text=$test.notes
        $accept=New-UiButton '保存'; $accept.Dock='Bottom'; $accept.DialogResult='OK'
        $answerForm.Controls.Add($endNotes); $answerForm.Controls.Add($answer); $answerForm.Controls.Add($explain); $answerForm.Controls.Add($accept); $answerForm.AcceptButton=$accept
        if ($SmokeTest -and $ExerciseWorkflow) {
            $answerForm.Add_Shown({ $endNotes.Text += ' / UI test completion'; $answer.SelectedIndex=2; $answerForm.DialogResult='OK'; $answerForm.Close() })
        }
        if ($answerForm.ShowDialog($form) -eq 'OK') {
            $test.result=@('NoRepro','Improved','Unchanged','Worse')[$answer.SelectedIndex]
            $test.notes=$endNotes.Text
            $script:activeTest=$null
            Save-CurrentSession
            $script:eventsTest=$test
            Start-CollectionWorker 'events' ([DateTime]::Parse($test.startedUtc).ToUniversalTime()) ([DateTime]::Parse($test.endedUtc).ToUniversalTime())
        } else { $test.endedUtc=$null }
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

$timer=New-Object Windows.Forms.Timer; $timer.Interval=500
$timer.Add_Tick({
    if ($script:activeTest) {
        $seconds=[int]([DateTime]::UtcNow - [DateTime]::Parse($script:activeTest.startedUtc).ToUniversalTime()).TotalSeconds
        $elapsed.Text=('{0:00}:{1:00} / ノイズ {2} 回' -f [int][Math]::Floor($seconds/60),($seconds%60),@($script:activeTest.noiseUtc).Count)
        if ($seconds -ge 600) { $status.Text='10分経過しました。観察を続けるか「テスト終了」で結果を記録してください。' }
    }
    if ($script:worker -and $script:workerHandle.IsCompleted) {
        try {
            $value=@($script:worker.EndInvoke($script:workerHandle))
            if ($script:worker.HadErrors -or $value.Count -ne 1) { throw '情報取得の一部を完了できませんでした。すでに保存した記録は保持しています。' }
            if ($script:workerMode -eq 'inventory') { $script:session.inventory=$value[0] }
            else {
                $script:eventsTest | Add-Member -NotePropertyName relatedEvents -NotePropertyValue $value[0].relatedEvents -Force
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
    if ($script:worker) { $eventArgs.Cancel=$true; [Windows.Forms.MessageBox]::Show('情報の取得中です。取得が終わってから閉じてください。','取得中') | Out-Null; return }
    if ($script:activeTest) {
        try {
            $script:activeTest.result='Interrupted'; $script:activeTest.endedUtc=[DateTime]::UtcNow.ToString('o')
            $script:activeTest.durationSeconds=[int]([DateTime]::UtcNow - [DateTime]::Parse($script:activeTest.startedUtc).ToUniversalTime()).TotalSeconds
            Save-CurrentSession
        } catch { $eventArgs.Cancel=$true; Show-UiError $_.Exception.Message }
    }
})
try {
    Set-TestPreset
    Update-UiState
    if ($SmokeTest) {
        $form.Show(); $form.PerformLayout(); [Windows.Forms.Application]::DoEvents()
        if ($ExerciseWorkflow) {
            $speaker.Text='Local UI verification'; $cStates.SelectedIndex=1
            $collect.PerformClick()
            $timer.Start()
            $deadline=[DateTime]::UtcNow.AddSeconds(120)
            while ($script:worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:worker -or -not $script:session.inventory -or -not $start.Enabled) { throw 'The UI inventory workflow did not complete.' }
            $testChoice.SelectedIndex=7
            $start.PerformClick(); $mark.PerformClick()
            if (@($script:activeTest.noiseUtc).Count -ne 1) { throw 'The UI did not save the marker.' }
            $finish.PerformClick()
            $deadline=[DateTime]::UtcNow.AddSeconds(45)
            while ($script:worker -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            if ($script:worker -or $script:session.tests[0].result -ne 'Unchanged' -or -not $script:session.tests[0].relatedEvents -or -not $script:session.tests[0].driverSnapshot) { throw 'The UI did not complete the test and collect events/drivers.' }
            $start.PerformClick(); $mark.PerformClick()
            $form.Close()
            $saved=Read-Session (Join-Path $script:sessionDirectory 'session.json')
            if ($saved.tests.Count -ne 2 -or $saved.tests[1].result -ne 'Interrupted' -or $saved.profile.cStates -ne 'Disabled') { throw 'The UI did not preserve the interrupted test/profile.' }
            Write-Output 'UI inventory, test completion, events, marker and interruption workflow OK'
        }
        if ($ScreenshotPath -and -not $ExerciseWorkflow) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($ScreenshotPath)))) | Out-Null
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
            $bitmap.Save($ScreenshotPath,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
        }
        Write-Output 'UI smoke test OK'
    } else { $timer.Start(); [Windows.Forms.Application]::Run($form) }
} finally {
    $timer.Stop(); $timer.Dispose(); $form.Dispose()
    if ($script:toolLock) { $script:toolLock.Dispose() }
}
