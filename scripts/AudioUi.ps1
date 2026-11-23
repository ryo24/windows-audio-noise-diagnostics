$script:audioRecorder=$null
$script:audioPlayback=$null
$script:recordingProbe=$null
$script:playbackProbe=$null

function Get-SelectedAudioProbe {
    if ($audioRecords.SelectedIndex -ge 0) { return @($script:session.audioProbes)[$audioRecords.SelectedIndex] }
    return $null
}
function Refresh-AudioOutputs {
    try {
        Initialize-AudioInterop
        $audioOutput.Items.Clear()
        foreach ($endpoint in [AudioNoiseDiagnostics.AudioFiles]::Endpoints()) { [void]$audioOutput.Items.Add($endpoint) }
        if ($audioOutput.Items.Count -gt 0) {
            $audioOutput.SelectedIndex=0
            try { $default=[AudioNoiseDiagnostics.Endpoint]::Read().Id;for($i=0;$i -lt $audioOutput.Items.Count;$i++){if($audioOutput.Items[$i].Id -eq $default){$audioOutput.SelectedIndex=$i}} } catch { }
            $audioStatus.Text='録音する出力を確認してください。最初は小音量で再生してください。'
        } else { $audioStatus.Text='利用できる音声出力がありません。接続を確認し、一覧を再取得してください。' }
    } catch { $audioStatus.Text='音声出力の一覧を取得できませんでした。接続とWindows Audioを確認してください。' }
    Update-AudioUi
}
function Refresh-AudioRecords {
    $index=$audioRecords.SelectedIndex
    $audioRecords.Items.Clear()
    foreach($record in @($script:session.audioProbes)){[void]$audioRecords.Items.Add(($record.createdUtc+' / '+$record.mode+' / '+$record.status))}
    if($audioRecords.Items.Count -gt 0){$audioRecords.SelectedIndex=if($index -ge 0 -and $index -lt $audioRecords.Items.Count){$index}else{$audioRecords.Items.Count-1}}
    Update-AudioUi
}
function Update-AudioUi {
    if(-not $audioStart){return}
    $occupied=($script:audioRecorder -or $script:audioPlayback)
    $probe=Get-SelectedAudioProbe
    $audioStart.Enabled=($script:session -and -not $script:worker -and -not $occupied -and $audioConsent.Checked -and $audioOutput.SelectedIndex -ge 0)
    $audioStop.Enabled=[bool]$occupied
    $audioNoise.Enabled=[bool]$script:audioRecorder
    foreach($control in @($audioOutput,$audioRefresh,$audioMode,$audioLength,$audioConsent,$audioRecords)){$control.Enabled=(-not $occupied)}
    $canPlay=($probe -and -not $occupied -and -not $script:worker -and -not $script:activeTest -and $audioOutput.SelectedIndex -ge 0 -and $probe.status -in @('Completed','NoAudioData'))
    $audioReplay.Enabled=[bool]$canPlay
    $audioReference.Enabled=($canPlay -and [bool]$probe.files.reference)
    $audioSaveReview.Enabled=($probe -and -not $occupied -and $probe.verification.reviewPlaybackCompleted)
}
function Poll-AudioJobs {
    if($script:audioRecorder){
        $audioStatus.Text=('録音 '+[Math]::Round($script:audioRecorder.ElapsedSeconds,1)+'秒 / '+$script:audioRecorder.Status+'。聞こえたノイズはボタンで記録してください。')
        if($script:audioRecorder.Finished){
            Complete-AudioProbeRecord $script:recordingProbe $script:audioRecorder $script:sessionDirectory
            $script:audioRecorder.Dispose();$script:audioRecorder=$null
            Save-CurrentSession;Refresh-AudioRecords
            $audioRecords.SelectedIndex=$audioRecords.Items.Count-1
            $audioStatus.Text=('録音を保存しました: '+$script:recordingProbe.status+'。通常テスト中なら先に終了し、録音を再生して照合してください。')
            Update-UiState
        }
    }
    if($script:audioPlayback){
        $audioStatus.Text=('再生確認 '+[Math]::Round($script:audioPlayback.PlayedSeconds,1)+'秒 / '+$script:audioPlayback.Status)
        if($script:audioPlayback.Finished){
            if($script:playbackKind -eq 'Recording'){
                $script:playbackProbe.verification.reviewPlaybackCompleted=$script:audioPlayback.Completed
                $script:playbackProbe.verification.reviewPlayedSeconds=$script:audioPlayback.PlayedSeconds
            } elseif($script:audioPlayback.Completed){$script:playbackProbe.verification.referencePlayed=$true}
            $completed=$script:audioPlayback.Completed
            $script:audioPlayback.Dispose();$script:audioPlayback=$null
            Save-CurrentSession;Update-UiState
            $audioStatus.Text=if($completed){'再生完了。実際の出力と録音の聞こえ方を選び「照合結果を保存」を押してください。'}else{'再生を停止したか、再生できませんでした。途中再生を全体の確認済みにはしません。'}
        }
    }
}
function Start-AudioReview {
    param([string]$Kind)
    try{
        $probe=Get-SelectedAudioProbe
        $relative=if($Kind -eq 'Reference'){$probe.files.reference}else{$probe.files.recording}
        $path=Resolve-AudioFile $script:sessionDirectory $relative
        if(-not (Test-Path -LiteralPath $path)){throw 'WAVがありません。session.jsonだけでなくaudioフォルダーを含むセッション一式をコピーしてください。'}
        $expected=if($Kind -eq 'Reference'){$probe.files.referenceSha256}else{$probe.files.recordingSha256}
        if($expected -and (Get-FileHash -LiteralPath $path).Hash -ne $expected){throw '保存したWAVのハッシュが一致しません。ファイルを確認してください。'}
        $script:playbackProbe=$probe;$script:playbackKind=$Kind
        if($Kind -eq 'Recording'){
            $probe.verification.reviewPlaybackCompleted=$false
            $probe.verification.reviewEndpointName=$audioOutput.SelectedItem.Name
            $probe.verification.reviewStartedUtc=[DateTime]::UtcNow.ToString('o')
            $probe.verification.replayNoise='Unreviewed';$probe.verification.resemblance='Unreviewed'
        }
        $script:audioPlayback=[AudioNoiseDiagnostics.AudioPlayback]::Start($audioOutput.SelectedItem.Id,$path)
        Update-UiState
    }catch{Show-UiError $_.Exception.Message}
}
function New-AudioCaptureTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='テスト音声・録音・聞き直し';$tab.Padding=New-Object Windows.Forms.Padding(10);$tab.AutoScroll=$true
    $grid=New-Object Windows.Forms.TableLayoutPanel;$grid.Dock='Fill';$grid.MinimumSize=New-Object Drawing.Size(0,420);$grid.ColumnCount=2;$grid.RowCount=9
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',160)));[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    foreach($height in @(74,44,36,32,44,44,36,56,0)){$style=New-Object Windows.Forms.RowStyle;if($height -eq 0){$style.SizeType='Percent';$style.Height=100}else{$style.SizeType='Absolute';$style.Height=$height};[void]$grid.RowStyles.Add($style)}
    $help=New-UiLabel "マイクなしで選択した出力全体を録音します。対象アプリも同じ出力へ設定してください。`r`n3.5mmのアナログ回路で後から混入するノイズは録れない場合があります。録音にないことだけで正常とは判定しません。`r`nまず小音量で開始。録音の聞き直しは、可能ならHDMIなど別の出力でも行ってください。"
    $help.Dock='Fill';$help.AutoSize=$false;$grid.Controls.Add($help,0,0);$grid.SetColumnSpan($help,2)
    $script:audioOutput=New-UiCombo @();$audioOutput.DisplayMember='Name'
    $script:audioRefresh=New-UiButton '出力一覧を取得'
    $outputs=New-Object Windows.Forms.TableLayoutPanel;$outputs.ColumnCount=2;$outputs.Dock='Fill';[void]$outputs.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$outputs.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',155)))
    $outputs.Controls.Add($audioOutput,0,0);$outputs.Controls.Add($audioRefresh,1,0);$grid.Controls.Add((New-UiLabel '録音・再生する出力'),0,1);$grid.Controls.Add($outputs,1,1)
    $script:audioMode=New-UiCombo @('共通テスト音声を再生して録音','他アプリの音を録音（テスト音なし）')
    $script:audioLength=New-UiCombo @('30','60','120','300');$audioLength.SelectedIndex=1
    $options=New-Object Windows.Forms.TableLayoutPanel;$options.ColumnCount=3;$options.Dock='Fill'
    foreach($width in @(75,10,15)){[void]$options.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width)))}
    $options.Controls.Add($audioMode,0,0);$options.Controls.Add((New-UiLabel '秒数'),1,0);$options.Controls.Add($audioLength,2,0);$grid.Controls.Add((New-UiLabel '録音モード・上限'),0,2);$grid.Controls.Add($options,1,2)
    $script:audioConsent=New-Object Windows.Forms.CheckBox;$audioConsent.Text='この出力に流れる他アプリ・通知も録音されることを確認しました';$audioConsent.AutoSize=$true
    $grid.Controls.Add($audioConsent,0,3);$grid.SetColumnSpan($audioConsent,2)
    $script:audioStart=New-UiButton '再生・録音を開始';$script:audioStop=New-UiButton '録音・再生を停止';$script:audioNoise=New-UiButton 'いまノイズが聞こえた'
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Controls.AddRange([Windows.Forms.Control[]]@($audioStart,$audioStop,$audioNoise));$grid.Controls.Add($buttons,0,4);$grid.SetColumnSpan($buttons,2)
    $script:audioStatus=New-UiLabel '最大5分／音声データ256MBで停止します。音声ファイルはdata内だけに保存します。';$audioStatus.Dock='Fill';$audioStatus.AutoSize=$false
    $grid.Controls.Add($audioStatus,0,5);$grid.SetColumnSpan($audioStatus,2)
    $script:audioRecords=New-UiCombo @();$grid.Controls.Add((New-UiLabel '保存した録音'),0,6);$grid.Controls.Add($audioRecords,1,6)
    $script:audioReplay=New-UiButton '録音を再生';$script:audioReference=New-UiButton '元のテスト音を再生';$script:audioSaveReview=New-UiButton '照合結果を保存'
    $reviewButtons=New-Object Windows.Forms.FlowLayoutPanel;$reviewButtons.Dock='Fill';$reviewButtons.Controls.AddRange([Windows.Forms.Control[]]@($audioReplay,$audioReference,$audioSaveReview));$grid.Controls.Add($reviewButtons,0,7);$grid.SetColumnSpan($reviewButtons,2)
    $reviewGrid=New-Object Windows.Forms.TableLayoutPanel;$reviewGrid.Dock='Fill';$reviewGrid.ColumnCount=3
    foreach($width in @(33,33,34)){[void]$reviewGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width)))}
    $script:audioLive=New-UiCombo @('実際の出力：未確認','実際の出力：ノイズあり','実際の出力：ノイズなし')
    $script:audioRecorded=New-UiCombo @('録音：未確認','録音：ノイズあり','録音：ノイズなし','録音：判断できない')
    $script:audioResemblance=New-UiCombo @('聞こえ方：未確認','実際の出力と同じ','実際の出力と異なる','同じか判断できない')
    $reviewGrid.Controls.Add($audioLive,0,0);$reviewGrid.Controls.Add($audioRecorded,1,0);$reviewGrid.Controls.Add($audioResemblance,2,0)
    $grid.Controls.Add($reviewGrid,0,8);$grid.SetColumnSpan($reviewGrid,2);$tab.Controls.Add($grid)
    $audioRefresh.Add_Click({Refresh-AudioOutputs});$audioConsent.Add_CheckedChanged({Update-AudioUi})
    $audioRecords.Add_SelectedIndexChanged({$record=Get-SelectedAudioProbe;if($record){$audioLive.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unknown','Yes','No'),$record.verification.liveNoise));$audioRecorded.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unreviewed','Yes','No','Unknown'),$record.verification.replayNoise));$audioResemblance.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unreviewed','Same','Different','Uncertain'),$record.verification.resemblance))};Update-AudioUi})
    $audioStart.Add_Click({
        try{
            Initialize-AudioInterop
            $mode=if($audioMode.SelectedIndex -eq 0){'Reference'}else{'ExternalApp'}
            $testId=if($script:activeTest){$script:activeTest.id}else{$null}
            $probe=New-AudioProbeRecord $mode $audioOutput.SelectedItem.Name $testId ([int]$audioLength.SelectedItem)
            if(-not $script:session.PSObject.Properties['audioProbes']){$script:session | Add-Member -NotePropertyName audioProbes -NotePropertyValue @()}
            $script:session.audioProbes=@($script:session.audioProbes)+@($probe)
            $audioCapturePath=Resolve-AudioFile $script:sessionDirectory $probe.files.recording
            [IO.Directory]::CreateDirectory((Split-Path -Parent $audioCapturePath)) | Out-Null
            $audioReferencePath=$null
            if($mode -eq 'Reference'){$audioReferencePath=Resolve-AudioFile $script:sessionDirectory $probe.files.reference;[AudioNoiseDiagnostics.AudioFiles]::GenerateReference($audioReferencePath)}
            $script:recordingProbe=$probe;Save-CurrentSession
            $script:audioRecorder=[AudioNoiseDiagnostics.AudioProbe]::Start($audioOutput.SelectedItem.Id,$audioCapturePath,$audioReferencePath,$probe.maximumSeconds)
            Update-UiState
        }catch{if($probe -and $probe.status -eq 'Starting'){$probe.status='Failed';Save-CurrentSession;Refresh-AudioRecords};Show-UiError $_.Exception.Message}
    })
    $audioStop.Add_Click({if($script:audioRecorder){$script:audioRecorder.Stop()};if($script:audioPlayback){$script:audioPlayback.Stop()}})
    $audioNoise.Add_Click({$mark.PerformClick()})
    $audioReplay.Add_Click({Start-AudioReview 'Recording'});$audioReference.Add_Click({Start-AudioReview 'Reference'})
    $audioSaveReview.Add_Click({
        try{$record=Get-SelectedAudioProbe;if(-not $record.verification.reviewPlaybackCompleted){throw '録音の再生を最後まで確認してから照合結果を保存してください。'}
            $record.verification.liveNoise=@('Unknown','Yes','No')[$audioLive.SelectedIndex];$record.verification.replayNoise=@('Unreviewed','Yes','No','Unknown')[$audioRecorded.SelectedIndex];$record.verification.resemblance=@('Unreviewed','Same','Different','Uncertain')[$audioResemblance.SelectedIndex]
            Save-CurrentSession;$audioStatus.Text='照合結果を保存しました。録音にノイズがなくても、実際の出力の異常を否定するものではありません。'
        }catch{Show-UiError $_.Exception.Message}
    })
    return $tab
}
