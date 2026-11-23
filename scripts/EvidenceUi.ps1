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
    $grid=New-UiGrid @(76,64,52,100) 190
    Add-UiGuide $grid 0 "通常の記録で原因を絞れない場合だけ使います。調査自体は上の開始ボタンで始めます。`r`nこの操作は追加のWPR記録を60秒取得するものです。管理者権限の確認が出ます。"
    $script:traceConsent=New-Object Windows.Forms.CheckBox;$traceConsent.Text="プロセス名・パス等の情報を含む可能性と取得負荷を確認し、`r`n管理者権限で60秒間の詳細トレースを取得することを了承しました。";$traceConsent.Dock='Fill';$grid.Controls.Add($traceConsent,0,1);$grid.SetColumnSpan($traceConsent,2)
    $script:traceStart=New-UiButton 'WPRを60秒間追加取得';$script:traceStop=New-UiButton 'WPRを停止して保存';$soundSettings=New-UiButton 'Windowsのサウンド設定'
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$actions.Controls.AddRange([Windows.Forms.Control[]]@($traceStart,$traceStop,$soundSettings));$grid.Controls.Add($actions,0,2);$grid.SetColumnSpan($actions,2)
    $script:traceStatus=New-UiLabel 'Audio＋GeneralProfileのETLを保存します。USB転送の詳細や自動原因判定は保証しません。';$traceStatus.Dock='Fill';$traceStatus.AutoSize=$false;$grid.Controls.Add($traceStatus,0,3);$grid.SetColumnSpan($traceStatus,2);$tab.Controls.Add($grid)
    $traceConsent.Add_CheckedChanged({Update-UiState})
    $traceStart.Add_Click({try {
        Save-CurrentSession
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Trace-Control.ps1')+'" -SessionPath "'+(Join-Path $script:sessionDirectory 'session.json')+'"'
        $script:traceProcess=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru
        $traceStatus.Text='WPRの追加取得中です。ノイズは上の共通ボタンで記録します。60秒で自動保存します。';Update-UiState
    }catch{Show-UiError $_.Exception.Message}})
    $traceStop.Add_Click({Request-TraceStop;$traceStatus.Text='WPRの停止・保存を要求しました。'})
    $soundSettings.Add_Click({Start-Process 'ms-settings:sound'})
    return $tab
}