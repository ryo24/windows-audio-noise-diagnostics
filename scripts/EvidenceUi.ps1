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
    $traceStatus.Text=$presentation.text+"`r`n"+'保存先：traces/'+$script:traceRun.id+' / インスタンス：AudioNoise-'+$script:traceRun.id
    $traceStop.Enabled=($presentation.busy -and $presentation.canStop)
    $traceStop.Text=if($presentation.phase -in @('Saving','SaveDelayed')){'WPRの停止・保存中'}elseif($script:traceRun.stopRequested -and $presentation.busy){'WPRの停止要求済み'}else{'WPRを停止して保存'}
    $traceOpen.Enabled=(Test-Path -LiteralPath $script:traceRun.directory)
    $traceProgress.Visible=$presentation.busy
    $traceProgress.Style=if($presentation.indeterminate){'Marquee'}else{'Continuous'}
    if($presentation.phase -eq 'Recording'){$traceProgress.Value=[int][Math]::Min(60,(Get-TraceAgeSeconds $script:traceRun.state.started))}else{$traceProgress.Value=0}
}
function Poll-DetailedTrace {
    if(-not $script:traceRun -or $script:traceRun.terminalHandled){return}
    $run=$script:traceRun;$processState='Unknown';$readError=''
    if($script:traceProcess){
        try {
            $script:traceProcess.Refresh()
            if($script:traceProcess.HasExited){$processState='Exited';$run.processExitCode=$script:traceProcess.ExitCode}else{$processState='Running'}
        }catch{$processState='Unknown'}
    }
    try {$state=Read-TraceRunState $run;if($state){$run.state=$state}}catch{$readError=$_.Exception.GetType().Name}
    $script:tracePresentation=Get-TracePresentation $run $run.state $processState -ReadError $readError
    $run.phase=$script:tracePresentation.phase;$run.busy=$script:tracePresentation.busy
    if(-not $run.busy){
        if($script:tracePresentation.phase -eq 'Failed' -and $run.state.status -eq 'Completed'){
            $run.state|Add-Member -NotePropertyName lastWorkerStatus -NotePropertyValue 'Completed' -Force
            $run.state.status='Failed';$run.state|Add-Member -NotePropertyName errorType -NotePropertyValue 'SavedArtifactMismatch' -Force
            Write-AtomicText (Join-Path $run.directory 'trace.json') ($run.state|ConvertTo-Json -Depth 12)
        }
        if($processState -eq 'Exited' -and $run.state.status -in @('Launching','Starting','Recording','Stopping')){
            $run.state|Add-Member -NotePropertyName lastWorkerStatus -NotePropertyValue $run.state.status -Force
            $run.state.status='HelperExited'
            $run.state|Add-Member -NotePropertyName errorType -NotePropertyValue 'NoFinalState' -Force
            $run.state|Add-Member -NotePropertyName helperExitCode -NotePropertyValue $run.processExitCode -Force
            Write-AtomicText (Join-Path $run.directory 'trace.json') ($run.state|ConvertTo-Json -Depth 12)
        }
        $run.terminalHandled=$true
        if($script:traceProcess){$script:traceProcess.Dispose();$script:traceProcess=$null}
        Save-CurrentSession
    }
    Update-UiState
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
        $script:traceRun=New-TraceRun $script:sessionDirectory $script:session.id -IncludeUsb:$IncludeUsb -Link $Link
        $script:tracePresentation=Get-TracePresentation $script:traceRun $script:traceRun.state
        Update-UiState;[Windows.Forms.Application]::DoEvents()
        if($script:traceRun.stopRequested){$script:traceRun.state.status='Cancelled';Write-AtomicText (Join-Path $script:traceRun.directory 'trace.json') ($script:traceRun.state|ConvertTo-Json -Depth 8);Poll-DetailedTrace;return}
        $script:traceProcess=Start-TraceHelper $script:traceRun
        Poll-DetailedTrace
    }catch{
        if($script:traceRun){
            $state=$script:traceRun.state;$state.status='LaunchFailed';$state.errorType=if($_.Exception.NativeErrorCode -eq 1223){'AdminApprovalCancelled'}else{$_.Exception.GetType().Name}
            Write-AtomicText (Join-Path $script:traceRun.directory 'trace.json') ($state|ConvertTo-Json -Depth 8);Poll-DetailedTrace
        }else{Show-UiError $_.Exception.Message}
    }
}
