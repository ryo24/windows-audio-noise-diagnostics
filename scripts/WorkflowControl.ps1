function Get-StartBlockReason {
    if(-not $script:session){return '「1 準備する」で新規作成、または記録を再開してください。'}
    if($script:activeTest){return 'この調査を記録中です。'}
    if($script:worker -or $script:bluetoothMonitor){return '構成・関連情報を取得しています。完了後に開始できます。'}
    if($script:audioPlayback){return '聞き直しの再生を停止すると、次の調査を開始できます。'}
    if($audioMode.SelectedIndex -ne 2){
        if(($audioSource.SelectedIndex -eq 0 -or $audioMode.SelectedIndex -eq 0) -and $audioOutput.SelectedIndex -lt 0){return '「2 条件を設定 → 音の調べ方」で音声出力を選んでください。'}
        if($audioSource.SelectedIndex -eq 1 -and $audioInput.SelectedIndex -lt 0){return '「2 条件を設定 → 音の調べ方」でマイクを選んでください。'}
        if(-not $audioConsent.Checked){return '「2 条件を設定 → 音の調べ方」の説明を読み、録音してよければ「この範囲の音を録音してよい」にチェックしてください。'}
    }
    return ''
}
function Update-UiState {
    if(-not $script:uiReady){return}
    $traceBusy=Test-DetailedTraceBusy
    $busy=($script:worker -or $script:bluetoothMonitor -or $script:audioRecorder -or $script:audioPlayback)
    $running=$null -ne $script:activeTest
    $collect.Enabled=(-not $busy -and -not $running -and -not $traceBusy -and -not $script:phoneReceiver)
    $resume.Enabled=$collect.Enabled
    $prepareNext.Enabled=($script:session -and -not $running -and -not $script:worker)
    $settingsNext.Enabled=[bool]$script:session;$reviewNext.Enabled=[bool]$script:session
    $reason=Get-StartBlockReason
    $start.Enabled=($reason -eq '' -and -not $script:closing)
    $skip.Enabled=($script:session -and -not $busy -and -not $running)
    $mark.Enabled=($running -and -not $script:finishRequested -and -not $script:closing)
    $finish.Enabled=($running -and -not $script:finishRequested -and -not $script:closing)
    if(-not $running){$elapsed.Text='待機中（未開始）'}
    foreach($control in @($testChoice,$outputChoice,$powerChoice,$appName,$changeText,$notes,$reference,$speaker,$profilePower,$cStates,$observations,$btCondition,$inputActivity,$btSampling,$material,$applicationOutput,$volume,$enhancements,$recentActions)){$control.Enabled=(-not $busy -and -not $running)}
    $report.Enabled=[bool]$script:session;$folder.Enabled=[bool]$script:session
    $export.Enabled=($script:session -and -not $busy -and -not $running -and -not $script:phoneReceiver -and -not $traceBusy)
    $includeTraces.Enabled=$export.Enabled
    $traceStart.Enabled=($script:session -and $traceConsent.Checked -and -not $traceBusy -and -not $script:worker)
    $traceStop.Enabled=($traceBusy -and -not $script:traceRun.stopRequested)
    $start.Text=@('テスト音声で調査を開始','アプリ音声の録音・調査を開始','録音せずに調査を開始')[$audioMode.SelectedIndex]
    $outputName=if($audioOutput.SelectedItem){$audioOutput.SelectedItem.Name}else{'未選択'}
    $sourceName=if($audioSource.SelectedIndex -eq 1){'マイク：'+$audioInput.SelectedItem.Name}else{'Windows内部の音'}
    $runSummary.Text='今回の比較：'+$testChoice.SelectedItem+"`r`n調べ方："+$audioMode.SelectedItem+"`r`n接続の申告："+$outputChoice.SelectedItem+' ／ '+$(if($audioMode.SelectedIndex -eq 2){'音声録音なし'}else{'出力：'+$outputName+' ／ '+$sourceName+' ／ '+$audioLength.SelectedItem+'秒'})
    if($script:finishRequested){$runInstruction.Text='終了処理中です。録音と状態記録を保存した後、結果の入力画面が開きます。'}
    elseif($running){$runInstruction.Text=if($audioMode.SelectedIndex -eq 0){'共通テスト音声を再生・録音しています。ノイズが聞こえたらボタンを押してください。'}elseif($audioMode.SelectedIndex -eq 1){'問題のアプリを、選んだ出力で再生してください。録音と状態記録は開始済みです。'}else{'普段の音声を再生してください。音声は録音せず、ノイズ時刻と状態を記録しています。'}}
    elseif($reason){$runInstruction.Text=$reason}
    else{$runInstruction.Text=if($audioMode.SelectedIndex -eq 2){'準備できました。下の開始ボタンを1回押してください。録音なしでは10分を目安に観察します。'}else{'準備できました。下の開始ボタンを1回押すと、録音・観察・状態記録が同時に始まります。'}}
    $workflowStatus.Text=if(-not $script:session){'まず「1 準備する」で調査を作成します。'}elseif($script:finishRequested){'調査を終了しています。保存完了後に結果を入力します。'}elseif($running){'調査中です。「3 調査する」でノイズを記録し、終了してください。'}elseif($script:worker -or $script:bluetoothMonitor){'情報の保存・取得中です。完了するまで次の調査とZIP書き出しは待ちます。'}elseif($tabs.SelectedTab -in @($settingsPage,$runPage) -and $reason){'次の操作：'+$reason}else{'記録は自動保存されます。条件を変えて次の調査、録音の聞き直し、またはZIP書き出しへ進めます。'}
    if($traceBusy){$workflowStatus.Text+=' WPRの追加取得・保存中です。'}
    if($script:phoneReceiver){$workflowStatus.Text+=' スマホからの受信を受付中です。'}
    $exportReady.Text=if(-not $script:session){'先に「1 準備する」で記録を作成してください。'}elseif($running -or $script:audioRecorder){'「3 調査する」で調査を終了し、結果を保存してください。'}elseif($script:phoneReceiver){'「3 調査する → スマホをつなぐ」で受信を閉じてください。'}elseif($traceBusy){'WPRの停止・保存を待ってください。'}elseif($busy){'情報の取得・保存、または聞き直しの終了を待ってください。'}else{'書き出せます。現在の調査のJSON・報告書・CSVと、関連する録音・動画をまとめます。'}
    Update-AudioUi;Update-PhoneUi;Update-TraceUi
}
function Request-ObservationFinish {
    param($Point=(Get-ClockPoint))
    if(-not $script:activeTest -or $script:finishRequested){return}
    $script:finishRequested=$true
    Complete-TestTiming $script:activeTest $Point
    [void](Add-TimelineEvent $script:session 'ObservationEnded' $script:activeTest.id)
    if($script:audioRecorder){$script:audioRecorder.Stop()}
    if($script:bluetoothMonitor){[void]$script:bluetoothMonitor.cancel.Set()}
    Save-CurrentSession;Update-UiState
}
function Complete-ObservationFinish {
    if(-not $script:finishRequested -or $script:audioRecorder -or $script:worker -or $script:finishDialogOpen -or $script:closing){return}
    $script:finishDialogOpen=$true
    $test=$script:activeTest
    try {
        $test.playbackSnapshots+=@(Invoke-CollectionSection {Get-PlaybackSnapshot $script:session.id})
        $answerForm=New-Object Windows.Forms.Form;$answerForm.Text='調査を終了しました — 結果を記録';$answerForm.Size=New-Object Drawing.Size(640,400);$answerForm.StartPosition='CenterParent';$answerForm.Font=$form.Font
        $answer=New-UiCombo @('再現せず','改善','変化なし','悪化');$answer.Dock='Top';$answer.SelectedIndex=if(@($test.noiseUtc).Count){2}else{0}
        $recordingNote=if($script:recordingProbe -and $script:recordingProbe.testId -eq $test.id){' 録音状態：'+$script:recordingProbe.status+'（取得不足・失敗は正常の証明になりません）。'}else{''}
        $explain=New-UiLabel ('録音・観察は終了しました。ノイズ記録 '+@($test.noiseUtc).Count+' 回。'+$recordingNote+"`r`n"+'結果を保存して次へ進みます。閉じた場合は結果未確定の中断記録として保存します。');$explain.Dock='Top'
        $endNotes=New-Object Windows.Forms.TextBox;$endNotes.Multiline=$true;$endNotes.ScrollBars='Vertical';$endNotes.Dock='Fill';$endNotes.Text=$test.notes
        $accept=New-UiButton '結果を保存して次へ';$accept.Dock='Bottom';$accept.DialogResult='OK'
        $answerForm.Controls.Add($endNotes);$answerForm.Controls.Add($answer);$answerForm.Controls.Add($explain);$answerForm.Controls.Add($accept);$answerForm.AcceptButton=$accept
        if($SmokeTest){$answerForm.Add_Shown({$endNotes.Text+=' / UI test completion';$answer.SelectedIndex=2;$answerForm.DialogResult='OK';$answerForm.Close()})}
        try {
            if($answerForm.ShowDialog($form) -eq 'OK'){$test.result=@('NoRepro','Improved','Unchanged','Worse')[$answer.SelectedIndex];$test.notes=$endNotes.Text}
            else{$test.result='Interrupted';$test.notes+=' / 終了後の結果入力は未確定。'}
        }finally{$answerForm.Dispose()}
        $script:activeTest=$null;$script:finishRequested=$false;Save-CurrentSession
        $script:eventsTest=$test;Start-CollectionWorker 'events' ([DateTime]::Parse($test.startedUtc).ToUniversalTime()) ([DateTime]::Parse($test.endedUtc).ToUniversalTime())
        $tabs.SelectedTab=$reviewPage
        $reviewTabs.SelectedTab=if(@($script:session.audioProbes).Count){$audioReviewTab}else{$historyTab}
        $runAudioStatus.Text='この調査は終了しました。次の開始は、条件を確認してから押してください。'
    }finally{$script:finishDialogOpen=$false;Update-UiState}
}
