$script:audioRecorder=$null
$script:audioPlayback=$null
$script:recordingProbe=$null
$script:playbackProbe=$null
function Get-SelectedAudioProbe {
    if($audioRecords.SelectedIndex -ge 0){return @($script:session.audioProbes)[$audioRecords.SelectedIndex]}
    return $null
}
function Refresh-AudioOutputs {
    try {
        Initialize-AudioInterop
        $selected=$audioOutput.SelectedItem.Id;$reviewSelected=$reviewOutput.SelectedItem.Id
        $audioOutput.Items.Clear();$reviewOutput.Items.Clear();$audioInput.Items.Clear()
        foreach($endpoint in [AudioNoiseDiagnostics.AudioFiles]::Endpoints()){[void]$audioOutput.Items.Add($endpoint);[void]$reviewOutput.Items.Add($endpoint)}
        foreach($endpoint in [AudioNoiseDiagnostics.AudioFiles]::InputEndpoints()){[void]$audioInput.Items.Add($endpoint)}
        $default=$null;try{$default=[AudioNoiseDiagnostics.Endpoint]::Read().Id}catch{}
        foreach($combo in @($audioOutput,$reviewOutput)){
            if($combo.Items.Count){$combo.SelectedIndex=0}
            $preferred=if($combo -eq $audioOutput -and $selected){$selected}elseif($combo -eq $reviewOutput -and $reviewSelected){$reviewSelected}else{$default}
            for($i=0;$i -lt $combo.Items.Count;$i++){if($combo.Items[$i].Id -eq $preferred){$combo.SelectedIndex=$i}}
        }
        if($audioInput.Items.Count){$audioInput.SelectedIndex=0}
        $audioSetupStatus.Text=if($audioOutput.Items.Count){'出力を確認してください。開始は「3 調査する」のボタンだけです。'}else{'音声出力がありません。接続後に一覧を更新するか、録音なしを選んでください。'}
    }catch{$audioSetupStatus.Text='音声デバイスを取得できません。接続を確認して一覧を更新してください。録音なしの調査は利用できます。'}
    Update-UiState
}
function Refresh-AudioRecords {
    $audioRecords.Items.Clear()
    foreach($record in @($script:session.audioProbes)){
        $method=if($record.mode -eq 'Reference'){'テスト音声'}else{'アプリの音'}
        [void]$audioRecords.Items.Add(($record.createdUtc+' / '+$method+' / '+$record.status))
    }
    if($audioRecords.Items.Count){$audioRecords.SelectedIndex=$audioRecords.Items.Count-1}
    Update-AudioUi
}
function Test-CaptureReady {
    if($audioMode.SelectedIndex -eq 2){return $true}
    $needsOutput=($audioSource.SelectedIndex -eq 0 -or $audioMode.SelectedIndex -eq 0)
    return ($audioConsent.Checked -and (-not $needsOutput -or $audioOutput.SelectedIndex -ge 0) -and ($audioSource.SelectedIndex -eq 0 -or $audioInput.SelectedIndex -ge 0))
}
function Update-AudioUi {
    if(-not $script:uiReady){return}
    $occupied=($script:audioRecorder -or $script:audioPlayback)
    $locked=($occupied -or $script:activeTest -or $script:worker)
    $recording=$audioMode.SelectedIndex -ne 2
    $audioMode.Enabled=(-not $locked)
    foreach($control in @($audioOutput,$audioSource,$audioLength,$audioConsent)){$control.Enabled=(-not $locked -and $recording)}
    $audioInput.Enabled=(-not $locked -and $recording -and $audioSource.SelectedIndex -eq 1)
    $audioRefresh.Enabled=(-not $locked);$reviewRefresh.Enabled=(-not $locked)
    $audioConsent.Text=if($recording){'この範囲の音を録音してよい（左の四角をクリック）'}else{'録音なしではチェック不要'}
    $audioConsentHelp.Text=if(-not $recording){'音声は録音しません。この確認は不要です。「3 調査する」で開始してください。'}elseif($audioSource.SelectedIndex -eq 1){"録音対象：選んだマイクが拾うスピーカー音・会話・周囲の音です。`r`n録音に入れたくない会話などを避け、問題なければ下の四角をクリックしてください。`r`n事前に録音テストをする必要はありません。チェック後は「3 調査する」で開始します。"}else{"録音対象：選んだ出力から流れる音すべてです（テスト音声・動画・通知など）。`r`n入れたくない音の再生を止め、問題なければ下の四角をクリックしてください。`r`n事前に録音テストをする必要はありません。チェック後は「3 調査する」で開始します。"}
    $probe=Get-SelectedAudioProbe
    $audioRecords.Enabled=(-not $occupied)
    $reviewOutput.Enabled=(-not $occupied -and -not $script:activeTest)
    $canPlay=($probe -and -not $occupied -and -not $script:worker -and -not $script:activeTest -and $reviewOutput.SelectedIndex -ge 0 -and $probe.status -in @('Completed','NoAudioData'))
    $audioReplay.Enabled=[bool]$canPlay;$audioReference.Enabled=($canPlay -and [bool]$probe.files.reference)
    $reviewStop.Enabled=[bool]$script:audioPlayback
    $audioSaveReview.Enabled=($probe -and -not $occupied -and -not $script:activeTest -and $probe.verification.reviewPlaybackCompleted)
    foreach($control in @($audioLive,$audioRecorded,$audioResemblance)){$control.Enabled=($probe -and -not $occupied -and -not $script:activeTest)}
    if(-not $probe){$audioStatus.Text='保存した録音はまだありません。「2 条件を設定」で録音する方法を選び、「3 調査する」で開始してください。'}
    elseif(-not $occupied -and -not $probe.verification.reviewPlaybackCompleted){$audioStatus.Text=if($probe.status -in @('Failed','Interrupted')){'この録音は失敗・中断しています。報告書で状態を確認してください。'}else{'① 出力を選ぶ → ② 録音を最後まで再生 → ③ 聞こえ方を選び、照合結果を保存します。'}}
}
function Start-ObservationCapture {
    param([string]$TestId,[switch]$PrepareOnly,[switch]$Prepared)
    if($audioMode.SelectedIndex -eq 2){return}
    if(-not (Test-CaptureReady)){throw '「2 条件を設定」で録音先と録音範囲を確認してください。'}
    Initialize-AudioInterop
    $mode=if($audioMode.SelectedIndex -eq 0){'Reference'}else{'ExternalApp'}
    $name=if($audioOutput.SelectedItem){$audioOutput.SelectedItem.Name}else{'出力未選択'}
    $probe=if($Prepared){$script:recordingProbe}else{New-AudioProbeRecord $mode $name $TestId ([int]$audioLength.SelectedItem)}
    if($Prepared -and $probe.testId -ne $TestId){throw 'Prepared recording belongs to another test'}
    if(-not $Prepared){
        $probe|Add-Member -NotePropertyName selectedOutputFormat -NotePropertyValue (Invoke-CollectionSection {[AudioNoiseDiagnostics.Endpoint]::Read($audioOutput.SelectedItem.Id)|Select-Object SampleRate,Channels,ContainerBits,FormatNote})
        if($script:activeTest.followUp){$script:activeTest.followUp.probeId=$probe.id}
        $probe|Add-Member -NotePropertyName playbackSnapshot -NotePropertyValue (Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id $audioOutput.SelectedItem.Id})
        if($audioSource.SelectedIndex -eq 1){$probe.sourceKind='Microphone';$probe.inputEndpointName=$audioInput.SelectedItem.Name;$probe.files.recording='audio/'+$probe.id+'/microphone.wav';$probe.scope='マイク入力。周囲音・距離・マイクの処理も含みます。'}
        if(-not $script:session.PSObject.Properties['audioProbes']){$script:session|Add-Member -NotePropertyName audioProbes -NotePropertyValue @()}
        $script:session.audioProbes=@($script:session.audioProbes)+@($probe);$script:recordingProbe=$probe
        [void](Add-TimelineEvent $script:session 'CaptureRequested' $TestId $probe.id);Save-CurrentSession
    }
    if($PrepareOnly){$probe.status='AwaitingTrace';Save-CurrentSession;return}
    if($Prepared){$probe.selectedOutputFormat=Invoke-CollectionSection {[AudioNoiseDiagnostics.Endpoint]::Read($audioOutput.SelectedItem.Id)|Select-Object SampleRate,Channels,ContainerBits,FormatNote}}
    $probe.status='Starting'
    try {
        $path=Resolve-AudioFile $script:sessionDirectory $probe.files.recording
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path))|Out-Null
        $referencePath=$null
        if($mode -eq 'Reference'){
            $referencePath=Resolve-AudioFile $script:sessionDirectory $probe.files.reference
            if($script:activeTest.followUp -and $script:activeTest.followUp.kind -ne 'None'){
                $seconds=[int]([Math]::Ceiling($probe.maximumSeconds/10.0)*10)
                [AudioNoiseDiagnostics.AudioFiles]::GenerateFollowUpReference($referencePath,$seconds)
                $probe.referenceId='audio-noise-reference-v2-indexed-'+$seconds+'s-48000hz-stereo-pcm16'
                $probe|Add-Member -NotePropertyName referencePattern -NotePropertyValue ([pscustomobject]@{blockSeconds=10;markerBits=6;leastSignificantBitFirst=$true;firstMarkerSeconds=0.08;bitPeriodSeconds=0.12;toneSeconds=0.06;zeroHz=700;oneHz=1400;blockIndexStartsAt=1;scope='各10秒区間の先頭1秒内に番号を符号化。共通音で位置を合わせるための識別子で、スマホ時計の同期ではない。'})
            }else{[AudioNoiseDiagnostics.AudioFiles]::GenerateReference($referencePath)}
        }
        if($probe.sourceKind -eq 'Microphone'){$script:audioRecorder=[AudioNoiseDiagnostics.AudioProbe]::StartMicrophone($audioInput.SelectedItem.Id,$audioOutput.SelectedItem.Id,$path,$referencePath,$probe.maximumSeconds)}
        else{$script:audioRecorder=[AudioNoiseDiagnostics.AudioProbe]::Start($audioOutput.SelectedItem.Id,$path,$referencePath,$probe.maximumSeconds,($script:activeTest.followUp.kind -eq 'UsbTransfer'))}
    }catch{$probe.status='Failed';Save-CurrentSession;Refresh-AudioRecords;throw}
}
function Poll-AudioJobs {
    if($script:audioRecorder){
        if($script:activeTest.followUp.captureStage -eq 'StartingAudio' -and $script:audioRecorder.Status -eq 'Recording'){
            $script:activeTest.followUp.captureStage='Started'
            $script:activeTest.followUp|Add-Member -NotePropertyName simultaneousConfirmed -NotePropertyValue (Get-ClockPoint) -Force
            [void](Add-TimelineEvent $script:session 'SimultaneousCaptureConfirmed' $script:activeTest.id $script:recordingProbe.id)
            Save-CurrentSession;Update-UiState
        }
        $runAudioStatus.Text=('録音中：'+[Math]::Round($script:audioRecorder.ElapsedSeconds,1)+' / '+$script:recordingProbe.maximumSeconds+'秒。聞こえたノイズをボタンで記録してください。')
        if($script:audioRecorder.Finished){
            if($script:activeTest.followUp.captureStage -eq 'StartingAudio'){$script:activeTest.followUp.captureStage='AudioFailed'}
            Complete-AudioProbeRecord $script:recordingProbe $script:audioRecorder $script:sessionDirectory
            $script:audioRecorder.Dispose();$script:audioRecorder=$null
            Save-CurrentSession;Refresh-AudioRecords
            $runAudioStatus.Text='録音を保存しました：'+$script:recordingProbe.status
            if($script:activeTest -and -not $script:closing){
                $capture=$script:recordingProbe.capture
                $point=if($capture.endedQpc){[pscustomobject]@{utc=$capture.endedUtc;qpc=$capture.endedQpc;frequency=$capture.qpcFrequency}}else{Get-ClockPoint}
                Request-ObservationFinish $point
            }
            Update-UiState
        }
    }
    if($script:audioPlayback){
        $audioStatus.Text=('聞き直し中：'+[Math]::Round($script:audioPlayback.PlayedSeconds,1)+'秒。新しい調査は開始しません。')
        if($script:audioPlayback.Finished){
            if($script:playbackKind -eq 'Recording'){$script:playbackProbe.verification.reviewPlaybackCompleted=$script:audioPlayback.Completed;$script:playbackProbe.verification.reviewPlayedSeconds=$script:audioPlayback.PlayedSeconds}
            elseif($script:audioPlayback.Completed){$script:playbackProbe.verification.referencePlayed=$true}
            $completed=$script:audioPlayback.Completed;$script:audioPlayback.Dispose();$script:audioPlayback=$null
            Save-CurrentSession;Update-UiState
            $audioStatus.Text=if($completed){'再生が終わりました。聞こえ方を選び、「照合結果を保存」を押してください。'}else{'途中で停止しました。録音全体の確認済みにはしていません。'}
        }
    }
}
function Start-AudioReview {
    param([string]$Kind)
    try {
        $probe=Get-SelectedAudioProbe
        $relative=if($Kind -eq 'Reference'){$probe.files.reference}else{$probe.files.recording}
        $path=Resolve-AudioFile $script:sessionDirectory $relative
        if(-not (Test-Path -LiteralPath $path)){throw '録音ファイルがありません。音声を含むZIPまたはセッション一式を確認してください。'}
        $expected=if($Kind -eq 'Reference'){$probe.files.referenceSha256}else{$probe.files.recordingSha256}
        if($expected -and (Get-FileHash -LiteralPath $path).Hash -ne $expected){throw '録音のハッシュが一致しません。'}
        $outputRef=Get-AnonymousDeviceRef ('SWD\MMDEVAPI\'+$reviewOutput.SelectedItem.Id) $script:session.id
        $notice=Get-PlaybackReviewNotice $probe $reviewOutput.SelectedItem.Name $outputRef
        if(-not (Confirm-PlaybackReview $notice)){$audioStatus.Text='再生を開始していません。ノイズの出ない出力を「② 聞き直す出力」で選び直してください。';return}
        $probe.verification|Add-Member -NotePropertyName playbackWarning -NotePropertyValue ([pscustomobject]@{acceptedUtc=[DateTime]::UtcNow.ToString('o');relation=$notice.relation;outputRef=$outputRef;scope='再生経路の影響を了承した操作。正常な出力と確認済みであることは意味しません。'}) -Force
        $script:playbackProbe=$probe;$script:playbackKind=$Kind
        if($Kind -eq 'Recording'){$probe.verification.reviewPlaybackCompleted=$false;$probe.verification.reviewEndpointName=$reviewOutput.SelectedItem.Name;$probe.verification.reviewStartedUtc=[DateTime]::UtcNow.ToString('o');$probe.verification.replayNoise='Unreviewed';$probe.verification.resemblance='Unreviewed'}
        $script:audioPlayback=[AudioNoiseDiagnostics.AudioPlayback]::Start($reviewOutput.SelectedItem.Id,$path);Update-UiState
    }catch{Show-UiError $_.Exception.Message}
}
function New-AudioSettingsTab {
    $tab=New-UiPage '音の調べ方'
    $grid=New-UiGrid @(82,46,46,46,46,56,108,52) 190
    Add-UiGuide $grid 0 "ここでは条件を選ぶだけです。開始ボタンは「3 調査する」に一つだけあります。`r`nテスト音声：PCが共通の音を流して録音。アプリの音：自分でアプリを再生。`r`n録音なし：耳で確認し、ノイズ時刻・構成・Bluetooth状態を記録します。"
    $script:audioMode=New-UiCombo @('テスト音声で調べる（再生＋録音）','普段のアプリの音を調べる（録音）','録音せず、耳で確認する')
    $script:audioSource=New-UiCombo @('Windows内部の音（ループバック）','接続したマイクで拾う実音')
    $script:audioOutput=New-UiCombo @();$audioOutput.DisplayMember='Name'
    $script:audioInput=New-UiCombo @();$audioInput.DisplayMember='Name'
    $script:audioLength=New-UiCombo @('30','60','120','300');$audioLength.SelectedIndex=1
    Add-UiField $grid 1 '調べ方' $audioMode;Add-UiField $grid 2 '録音する音' $audioSource
    Add-UiField $grid 3 '調査・録音の出力' $audioOutput;Add-UiField $grid 4 '使用するマイク' $audioInput
    $options=New-Object Windows.Forms.FlowLayoutPanel;$options.Dock='Fill'
    $audioLength.Dock='None';$audioLength.Width=85;$options.Controls.Add($audioLength);$options.Controls.Add((New-UiLabel '秒で録音と観察を終了'))
    $script:audioRefresh=New-UiButton '音声デバイスを再取得';$options.Controls.Add($audioRefresh);Add-UiField $grid 5 '録音の長さ' $options
    $script:audioConsentHelp=New-UiLabel '';$audioConsentHelp.Dock='Fill';$audioConsentHelp.AutoSize=$false;$grid.Controls.Add($audioConsentHelp,0,6);$grid.SetColumnSpan($audioConsentHelp,2)
    $script:audioConsent=New-Object Windows.Forms.CheckBox;$audioConsent.Dock='Fill';$audioConsent.Padding=New-Object Windows.Forms.Padding(8);$grid.Controls.Add($audioConsent,0,7);$grid.SetColumnSpan($audioConsent,2)
    $script:audioSetupStatus=New-UiLabel '音声デバイスを読み込みます。';$audioSetupStatus.Dock='Top';$audioSetupStatus.Height=54;$audioSetupStatus.AutoSize=$false
    $tab.Controls.Add($audioSetupStatus);$tab.Controls.Add($grid)
    $audioRefresh.Add_Click({Refresh-AudioOutputs})
    foreach($combo in @($audioMode,$audioSource,$audioOutput,$audioInput)){$combo.Add_SelectedIndexChanged({$audioConsent.Checked=$false;Update-UiState})}
    $audioLength.Add_SelectedIndexChanged({Update-UiState})
    $audioConsent.Add_CheckedChanged({Update-UiState})
    return $tab
}
function New-AudioReviewTab {
    $tab=New-UiPage 'PCで録音した音'
    $grid=New-UiGrid @(78,44,44,52,44,44,44,52,64) 190
    Add-UiGuide $grid 0 "保存した録音と、調査中に聞いたノイズを比べます。`r`n聞き直す出力は調査時と別に選べます。可能ならHDMIなど正常な経路も使ってください。`r`nここで再生しても新しい調査は始まりません。録音がきれいでも故障は否定できません。"
    $script:audioRecords=New-UiCombo @();Add-UiField $grid 1 '① 保存した録音' $audioRecords
    $script:reviewOutput=New-UiCombo @();$reviewOutput.DisplayMember='Name';$script:reviewRefresh=New-UiButton '出力一覧を更新'
    $outputs=New-Object Windows.Forms.TableLayoutPanel;$outputs.Dock='Fill';$outputs.ColumnCount=2
    [void]$outputs.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$outputs.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',150)))
    $outputs.Controls.Add($reviewOutput,0,0);$outputs.Controls.Add($reviewRefresh,1,0);Add-UiField $grid 2 '② 聞き直す出力' $outputs
    $script:audioReplay=New-UiButton '保存した録音を再生';$script:audioReference=New-UiButton '元のテスト音を再生';$script:reviewStop=New-UiButton '聞き直しを停止'
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Controls.AddRange([Windows.Forms.Control[]]@($audioReplay,$audioReference,$reviewStop));$grid.Controls.Add($buttons,1,3)
    $script:audioLive=New-UiCombo @('未確認','ノイズあり','ノイズなし')
    $script:audioRecorded=New-UiCombo @('未確認','ノイズあり','ノイズなし','判断できない')
    $script:audioResemblance=New-UiCombo @('未確認','同じ','異なる','判断できない')
    Add-UiField $grid 4 '③ 調査中に聞いた実音' $audioLive;Add-UiField $grid 5 '録音を聞き直した音' $audioRecorded;Add-UiField $grid 6 '実音と録音の聞こえ方' $audioResemblance
    $script:audioSaveReview=New-UiButton '照合結果を保存';$grid.Controls.Add($audioSaveReview,1,7)
    $script:audioStatus=New-UiLabel '';$audioStatus.Dock='Fill';$audioStatus.AutoSize=$false;$grid.Controls.Add($audioStatus,0,8);$grid.SetColumnSpan($audioStatus,2);$tab.Controls.Add($grid)
    $reviewRefresh.Add_Click({Refresh-AudioOutputs});$reviewStop.Add_Click({if($script:audioPlayback){$script:audioPlayback.Stop()}})
    $audioReplay.Add_Click({Start-AudioReview 'Recording'});$audioReference.Add_Click({Start-AudioReview 'Reference'})
    $audioRecords.Add_SelectedIndexChanged({$record=Get-SelectedAudioProbe;if($record){$audioLive.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unknown','Yes','No'),$record.verification.liveNoise));$audioRecorded.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unreviewed','Yes','No','Unknown'),$record.verification.replayNoise));$audioResemblance.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unreviewed','Same','Different','Uncertain'),$record.verification.resemblance))};Update-AudioUi})
    $audioSaveReview.Add_Click({try {
        $record=Get-SelectedAudioProbe
        if(-not $record.verification.reviewPlaybackCompleted){throw '保存した録音を最後まで再生してから保存してください。'}
        $record.verification.liveNoise=@('Unknown','Yes','No')[$audioLive.SelectedIndex];$record.verification.replayNoise=@('Unreviewed','Yes','No','Unknown')[$audioRecorded.SelectedIndex];$record.verification.resemblance=@('Unreviewed','Same','Different','Uncertain')[$audioResemblance.SelectedIndex]
        Save-CurrentSession;$audioStatus.Text='保存しました。「5 書き出す」へ進むか、条件を変えて次の調査ができます。'
    }catch{Show-UiError $_.Exception.Message}})
    return $tab
}
