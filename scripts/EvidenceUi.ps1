function Get-ManualPlaybackConditions {
    [pscustomobject]@{material=$material.Text;applicationOutput=$applicationOutput.Text;volume=$volume.Text;enhancements=[string]$enhancements.SelectedItem;recentActions=$recentActions.Text;scope='利用者の手動申告。アプリの設定・音量・音声拡張を自動取得した値ではありません。'}
}
function Poll-DetailedTrace {
    if(-not $script:traceProcess){return}
    if($script:traceProcess.HasExited){
        $exitCode=$script:traceProcess.ExitCode;$script:traceProcess.Dispose();$script:traceProcess=$null
        $traceStatus.Text=if($exitCode -eq 0){'詳細トレースを保存しました。報告書のtraces情報を確認してください。'}else{'詳細トレースの取得または保存に失敗しました。報告書のtrace.jsonの状態と終了コードを確認してください。'}
        Save-CurrentSession;Update-UiState
    }
}
function Request-TraceStop {
    if(-not $script:sessionDirectory){return}
    foreach($directory in @(Get-ChildItem -LiteralPath (Join-Path $script:sessionDirectory 'traces') -Directory -ErrorAction SilentlyContinue)){
        if($directory.Name -match '^[a-fA-F0-9]{32}$'){Write-AtomicText (Join-Path $directory.FullName 'stop.request') 'stop'}
    }
}
function New-EvidenceTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='再生条件・詳細トレース';$tab.Padding=New-Object Windows.Forms.Padding(10);$tab.AutoScroll=$true
    $grid=New-Object Windows.Forms.TableLayoutPanel;$grid.Dock='Top';$grid.Height=480;$grid.ColumnCount=2;$grid.RowCount=9
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',190)));[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    foreach($height in @(76,36,36,36,36,64,64,44,0)){$s=New-Object Windows.Forms.RowStyle;if($height){$s.SizeType='Absolute';$s.Height=$height}else{$s.SizeType='Percent';$s.Height=100};[void]$grid.RowStyles.Add($s)}
    $help=New-UiLabel "テスト開始前に再生条件を記入します。出力別の設定と、自動取得した再生セッションは区別して記録します。`r`n各テストの構成・起動／復帰情報をバックグラウンド取得。ノイズ時刻はUTCとQPCで記録します。`r`nHDMIから戻した際の再発が確認済みなら、確認済みの症状へ記入し、同じ比較を繰り返す必要はありません。";$help.Dock='Fill';$help.AutoSize=$false;$grid.Controls.Add($help,0,0);$grid.SetColumnSpan($help,2)
    $script:material=New-Object Windows.Forms.TextBox;$material.Dock='Fill'
    $script:applicationOutput=New-Object Windows.Forms.TextBox;$applicationOutput.Dock='Fill'
    $script:volume=New-Object Windows.Forms.TextBox;$volume.Dock='Fill'
    $script:enhancements=New-UiCombo @('未確認','オフ','オン','項目なし')
    $script:recentActions=New-Object Windows.Forms.TextBox;$recentActions.Dock='Fill';$recentActions.Multiline=$true
    $row=1;foreach($entry in @(@('素材・再生箇所',$material),@('アプリの出力先（手動）',$applicationOutput),@('音量（PC・アプリ・機器）',$volume),@('音声拡張（手動）',$enhancements),@('直前の操作・復帰・負荷',$recentActions))){$grid.Controls.Add((New-UiLabel $entry[0]),0,$row);$grid.Controls.Add($entry[1],1,$row);$row++}
    $script:traceConsent=New-Object Windows.Forms.CheckBox;$traceConsent.Text="詳細トレースにはプロセス名・パス等の情報が含まれ、取得負荷もあります。`r`n60秒のWPR取得と、管理者権限の確認が出ることを了承しました。";$traceConsent.Dock='Fill';$grid.Controls.Add($traceConsent,0,6);$grid.SetColumnSpan($traceConsent,2)
    $script:traceStart=New-UiButton '詳細トレースを60秒取得';$script:traceStop=New-UiButton 'トレース停止・保存';$soundSettings=New-UiButton 'Windowsのサウンド設定'
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$actions.Controls.AddRange([Windows.Forms.Control[]]@($traceStart,$traceStop,$soundSettings));$grid.Controls.Add($actions,0,7);$grid.SetColumnSpan($actions,2)
    $script:traceStatus=New-UiLabel '通常の録音で絞れない場合に使います。Audio＋GeneralProfileのETLをローカル保存します。USBの詳細転送記録や自動原因判定は保証しません。';$traceStatus.Dock='Fill';$traceStatus.AutoSize=$false;$grid.Controls.Add($traceStatus,0,8);$grid.SetColumnSpan($traceStatus,2);$tab.Controls.Add($grid)
    $traceConsent.Add_CheckedChanged({Update-UiState})
    $traceStart.Add_Click({try{
        Save-CurrentSession
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Trace-Control.ps1')+'" -SessionPath "'+(Join-Path $script:sessionDirectory 'session.json')+'"'
        $script:traceProcess=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru
        $traceStatus.Text='WPR取得中です。音を再生し、聞こえたノイズをボタンで記録してください。60秒で自動保存します。';Update-UiState
    }catch{Show-UiError $_.Exception.Message}})
    $traceStop.Add_Click({Request-TraceStop;$traceStatus.Text='停止・ETL保存を要求しました。保存完了までお待ちください。'})
    $soundSettings.Add_Click({Start-Process 'ms-settings:sound'})
    return $tab
}
