function Get-ManualPlaybackConditions {
    [pscustomobject]@{material=$material.Text;applicationOutput=$applicationOutput.Text;volume=$volume.Text;enhancements=[string]$enhancements.SelectedItem;recentActions=$recentActions.Text;scope='利用者の手動申告。アプリの設定・音量・音声拡張を自動取得した値ではありません。'}
}
function Test-DetailedTraceBusy {
    return [bool]($script:traceRun -and $script:traceRun.busy)
}
function Reset-EvidenceUiForSession {
    $script:lastPhoneReceiver=$null;$script:lastPhoneNetworkDigest=$null
    $script:traceRun=$null;$script:tracePresentation=$null
    if($followUpChoice){$followUpChoice.SelectedIndex=0;$followUpConsent.Checked=$false;$followUpOperation.SelectedIndex=0;$followUpState.SelectedIndex=0;$script:followUpExternalChoices=@()}
    $traceStatus.Text='Audio＋GeneralProfileのETLを保存します。USB転送の詳細や自動原因判定は保証しません。'
    $phoneStatus.Text='スマホからの受信を開いてQRを表示するか、保存済みファイルを取り込めます。'
}
function Start-TraceHelper {
    param($Run)
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Trace-Control.ps1')+'" -SessionPath "'+(Join-Path $script:sessionDirectory 'session.json')+'" -TraceId '+$Run.id
    if($Run.state.includeUsb){$arguments+=' -IncludeUsb'}
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru
}
function Update-TraceUi {
    if(-not $script:uiReady){return}
    if(-not $script:traceRun){$traceOpen.Enabled=$false;$traceProgress.Visible=$false;return}
    $presentation=$script:tracePresentation
    if(-not $presentation){return}
    $newStatus=$presentation.text+"`r`n"+'保存先：traces/'+$script:traceRun.id+' / インスタンス：AudioNoise-'+$script:traceRun.id
    if($traceStatus.Text -ne $newStatus){$traceStatus.Text=$newStatus}
    $traceStop.Enabled=($presentation.busy -and $presentation.canStop)
    $traceStop.Text=if($presentation.phase -eq 'Inspecting'){'追加情報の取得・検査中'}elseif($presentation.phase -in @('Saving','SaveDelayed')){'WPRの停止・保存中'}elseif($script:traceRun.stopRequested -and $presentation.busy){'WPRの停止要求済み'}else{'WPRを停止して保存'}
    $traceOpen.Enabled=(Test-Path -LiteralPath $script:traceRun.directory)
    $traceProgress.Visible=$presentation.busy
    $style=if($presentation.indeterminate){'Marquee'}else{'Continuous'}
    if($traceProgress.Style -ne $style){$traceProgress.Style=$style}
    if($presentation.phase -eq 'Recording'){$traceProgress.Value=[int][Math]::Min(60,(Get-TraceAgeSeconds $(if($script:traceRun.state.captureHandshake.acknowledged){$script:traceRun.state.captureHandshake.acknowledged}else{$script:traceRun.state.started})))}else{$traceProgress.Value=0}
}
function Poll-DetailedTrace {
    if(-not $script:traceRun -or $script:traceRun.terminalHandled){return}
    $run=$script:traceRun;$previousPhase=$run.phase;$processState='Unknown';$readError=''
    if($script:traceProcess){
        try {
            $script:traceProcess.Refresh()
            if($script:traceProcess.HasExited){$processState='Exited';$run.processExitCode=$script:traceProcess.ExitCode}else{$processState='Running'}
        }catch{$processState='Unknown'}
    }
    try {$state=Read-TraceRunState $run;if($state -and -not ($state.status -eq 'Launching' -and $run.state.status -in @('LaunchFailed','Cancelled'))){$run.state=$state}}catch{$readError=$_.Exception.GetType().Name}
    $script:tracePresentation=Get-TracePresentation $run $run.state $processState -ReadError $readError
    $run.phase=$script:tracePresentation.phase;$run.busy=$script:tracePresentation.busy
    if($script:activeTest.followUp.captureStage -eq 'AwaitingTrace' -and $run.state.link.testId -eq $script:activeTest.id -and -not $script:finishRequested){
        $readyPhase=if($run.state.requireCaptureAck){'AwaitingCapture'}else{'Recording'}
        $readyExpired=$run.state.requireCaptureAck -and $run.state.captureHandshake.ready -and
            (Get-TraceAgeSeconds $run.state.captureHandshake.ready) -ge $run.state.captureHandshake.timeoutSeconds
        if(-not $readyExpired -and $run.phase -eq $readyPhase -and $run.state.usb.status -eq 'Recording' -and
            $run.state.audioStatus -eq 'Recording' -and $run.state.link.probeId -eq $script:recordingProbe.id){
            $script:activeTest.followUp.captureStage='StartingAudio'
            [void](Add-TimelineEvent $script:session 'UsbAudioReady' $script:activeTest.id $script:recordingProbe.id)
            try{Start-ObservationCapture $script:activeTest.id -Prepared;Save-CurrentSession}
            catch{$script:activeTest.followUp.captureStage='AudioFailed';Request-ObservationFinish;Show-UiError $_.Exception.Message}
        }elseif(-not $run.busy -or $run.phase -in @('Saving','Inspecting')){
            $script:activeTest.followUp.captureStage='NotStarted';$script:recordingProbe.status='NotStarted'
            $script:activeTest.notes+=' / USB＋Audioの開始を確認できず、テスト音と録音は開始しなかった。'
            Request-ObservationFinish
        }
    }
    if(-not $run.busy -or $run.phase -in @('Saving','Inspecting')){
        if($script:activeTest.followUp.captureStage -in @('StartingAudio','Started') -and $run.state.link.testId -eq $script:activeTest.id -and -not $script:finishRequested){$script:activeTest.followUp.captureStage='TraceEnded';Request-ObservationFinish}
    }
    if(-not $run.busy){
        if($processState -eq 'Exited' -and $run.state.status -in @('Launching','Starting','AwaitingCapture','Recording','Stopping','Inspecting')){
            $errorType=if($run.processExitCode -eq 3){'TraceStateWriteFailed'}else{'NoFinalState'}
            try{Set-TraceUiOutcome $run 'HelperExited' $errorType}
            catch{$script:tracePresentation.text+=' 終了の状態もファイルに記録できませんでした。'}
        }
        $run.terminalHandled=$true
        if($script:traceProcess){$script:traceProcess.Dispose();$script:traceProcess=$null}
        Save-CurrentSession
    }
    # Polling refreshes the live status only. Rebuilding the form repeatedly
    # resets selection and repaints unrelated controls while awaiting the helper.
    if($previousPhase -ne $run.phase -or -not $run.busy){Update-UiState}
    else{Update-TraceUi;Update-LinkedTraceStatus}
}
function Request-TraceStop {
    if(-not (Test-DetailedTraceBusy)){return}
    Send-TraceStopRequest $script:traceRun
    Poll-DetailedTrace
}
function New-PlaybackConditionsTab {
    $tab=New-UiPage '再生条件のメモ'
    $grid=New-UiGrid @(90,44,44,44,44,110) 200
    Add-UiGuide $grid 0 "分かる範囲で、調査を開始する前に記入してください。下の値は手動の申告として保存します。`r`n未確認のままでも調査できます。起動・復帰情報やドライバーは開始後に別途取得します。`r`nHDMIから3.5mmへ戻した際の再発が確認済みなら、同じ比較を繰り返す必要はありません。"
    $script:material=New-Object Windows.Forms.TextBox;$material.Dock='Fill'
    $script:applicationOutput=New-Object Windows.Forms.TextBox;$applicationOutput.Dock='Fill'
    $script:volume=New-Object Windows.Forms.TextBox;$volume.Dock='Fill'
    $script:enhancements=New-UiCombo @('未確認','オフ','オン','項目なし')
    $script:recentActions=New-Object Windows.Forms.TextBox;$recentActions.Dock='Fill';$recentActions.Multiline=$true
    $row=1;foreach($entry in @(@('素材・再生箇所',$material),@('アプリの出力先（手動）',$applicationOutput),@('音量（PC・アプリ・機器）',$volume),@('音声拡張（手動）',$enhancements),@('直前の操作・復帰・負荷',$recentActions))){Add-UiField $grid $row $entry[0] $entry[1];$row++}
    $tab.Controls.Add($grid);return $tab
}
function New-TraceTab {
    $tab=New-UiPage '詳細トレース（任意）'
    $grid=New-UiGrid @(108,64,52,18,76) 190
    Add-UiGuide $grid 4 "通常の記録で原因を絞れない場合だけ使います。調査自体は上の開始ボタンで始めます。`r`nこの操作は追加のWPR記録を60秒取得するものです。管理者権限の確認が出ます。"
    $script:traceConsent=New-Object Windows.Forms.CheckBox;$traceConsent.Text="プロセス名・パス等の情報を含む可能性と取得負荷を確認し、`r`n管理者権限で60秒間の詳細トレースを取得することを了承しました。";$traceConsent.Dock='Fill';$grid.Controls.Add($traceConsent,0,1);$grid.SetColumnSpan($traceConsent,2)
    $script:traceStart=New-UiButton 'WPRを60秒間追加取得';$script:traceStop=New-UiButton 'WPRを停止して保存';$soundSettings=New-UiButton 'Windowsのサウンド設定'
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$script:traceOpen=New-UiButton 'WPRの保存先を開く'
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($traceStart,$traceStop,$traceOpen,$soundSettings));$grid.Controls.Add($actions,0,2);$grid.SetColumnSpan($actions,2)
    $script:traceStatus=New-UiLabel 'Audio＋GeneralProfileのETLを保存します。USB転送の詳細や自動原因判定は保証しません。';$traceStatus.Dock='Fill';$traceStatus.AutoSize=$false;$script:traceProgress=New-Object Windows.Forms.ProgressBar;$traceProgress.Dock='Fill';$traceProgress.Maximum=60;$traceProgress.Visible=$false;$grid.Controls.Add($traceProgress,0,3);$grid.SetColumnSpan($traceProgress,2)
    $grid.Controls.Add($traceStatus,0,0);$grid.SetColumnSpan($traceStatus,2);$tab.Controls.Add($grid)
    $traceConsent.Add_CheckedChanged({Update-UiState})
    $traceStart.Add_Click({Start-LinkedTrace})
    $traceStop.Add_Click({try{Request-TraceStop}catch{Show-UiError $_.Exception.Message}})
    $traceOpen.Add_Click({if($script:traceRun){Start-Process explorer.exe -ArgumentList ('"'+$script:traceRun.directory+'"')}})
    $soundSettings.Add_Click({Start-Process 'ms-settings:sound'})
    return $tab
}

function Start-LinkedTrace {
    param([switch]$IncludeUsb,$Link=$null)
    try{
        if(Test-DetailedTraceBusy){throw '前の詳細トレースの保存を待ってください。'}
        Save-CurrentSession
        $script:traceRun=New-TraceRun $script:sessionDirectory $script:session.id -IncludeUsb:$IncludeUsb -Link $Link -RequireCaptureAck:$IncludeUsb -CaptureSeconds $(if($IncludeUsb){$script:recordingProbe.maximumSeconds}else{60})
        if($IncludeUsb){
            $script:activeTest.followUp.traceId=$script:traceRun.id
            Save-CurrentSession
        }
        $script:tracePresentation=Get-TracePresentation $script:traceRun $script:traceRun.state
        Update-UiState;[Windows.Forms.Application]::DoEvents()
        if($script:traceRun.stopRequested){Set-TraceUiOutcome $script:traceRun 'Cancelled' '';Poll-DetailedTrace;return}
        $script:traceProcess=Start-TraceHelper $script:traceRun
    }catch{
        if($script:traceRun){
            $errorType=if($_.Exception.NativeErrorCode -eq 1223){'AdminApprovalCancelled'}else{$_.Exception.GetType().Name}
            try{Set-TraceUiOutcome $script:traceRun 'LaunchFailed' $errorType}
            catch{$status.Text='トレースを起動できず、終了状態の書き込みにも失敗しました。'}
            Poll-DetailedTrace
        }else{Show-UiError $_.Exception.Message}
        return
    }
    Poll-DetailedTrace
}
