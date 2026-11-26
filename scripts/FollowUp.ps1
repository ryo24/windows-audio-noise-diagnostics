function Get-FollowUpPlan {
    $ids=@('None','UsbTransfer','CleanPhysicalControl','FormatComparison','RecoveryComparison')
    [pscustomobject]@{kind=$ids[$followUpChoice.SelectedIndex];probeId=$null;traceId=$null;comparisonTestId=if($followUpReference.SelectedItem){$followUpReference.SelectedItem.id}else{''};comparisonSessionId=if($followUpReference.SelectedItem){$followUpReference.SelectedItem.sessionId}else{''};comparisonSourceHash=if($followUpReference.SelectedItem){$followUpReference.SelectedItem.sourceHash}else{''};physicalRoute=$followUpRoute.Text;requestedFormat=$followUpFormat.Text;priorOperation=@('Unknown','NoChange','RestartOnly','AudioDeviceDisableEnableOnly','SleepResumeOnly','MultipleChanges')[$followUpOperation.SelectedIndex];stateAtStart=@('Unknown','NoisePresent','NoNoiseConfirmed')[$followUpState.SelectedIndex];usbConsent=$followUpConsent.Checked;reference=if($followUpChoice.SelectedIndex -gt 0){'IndexedV2'}else{'Default'};scope='利用者が選んだ追加調査。良好出力・接続・手動形式・直前の操作・状態は申告であり正常や原因の自動判定ではない。操作時刻は自動計測していない。'}
}
function Get-FollowUpGuide {
    param([int]$Index)
    switch($Index){
        1 {'問題が出る実際のWindows出力を「音の調べ方」で選びます。同じ区間をスマホで記録してください。共通の開始でUSB＋Audioを先に開始し、開始確認後にテスト音と内部録音が自動で始まります。画面が同時記録中になった区間をスマホでも録ってください。共通の終了で保存します。USB取得は管理者権限、全xHCI配下の識別情報を含むETL、256MB循環記録です。バスデータ本文の取得は指定しません。USB転送が必ず記録される保証や、正常の自動判定はありません。'}
        2 {'HDMI等、または同じ出力が回復した状態を選び、同じスマホ・位置・録音方式で実音を記録します。同じ出力の正常音が既にあれば、その記録を対照として使えます。目的はスマホ側の録音処理も比較することです。HDMIから戻す再現試験や、正常録音の撮り直しを強制するものではありません。'}
        3 {'対応するWindows形式を手動で1つだけ変更し、元の値と変更後の値を記入します。提供されない形式を無理に選ぶ必要はありません。アプリは形式やドライバーを変更しません。出力・音量・音源・スマホの位置は揃えます。選択出力の実際の共有形式を録音ごとに取得し、基準WAVの48kHzとは区別します。'}
        4 {'再発したら、まず操作前の音と必要なUSB取得を保存します。その後は再起動だけ、または対象音声デバイスの無効・有効だけ等、一度に1種類を手動で行い、同じ出力で操作後を記録します。複数の操作をした場合はその通り選び、効果を一つの操作に帰属しません。アプリは再起動や機器の無効化を実行しません。別の記録から比較先を選べます。'}
        default {'追加調査を選ぶと手順を表示します。既知の再現確認をやり直す必要はありません。USB転送の取得と良好な実音対照は、ループバックの後段を調べるための別の証拠です。'}
    }
}
function New-FollowUpTab {
    $tab=New-UiPage '次の切り分け'
    $grid=New-UiGrid @(66,44,100,84,52,44,44,44,50,64) 180
    Add-UiGuide $grid 0 "内部録音に現れない変化を、USB転送・実音対照・形式変更から調べます。開始と終了は共通ボタンです。`r`n追加調査の基準音は、10秒区間の先頭に番号を示す短い音が入ります。録音の位置合わせ用です。"
    $script:followUpChoice=New-UiCombo @('通常の調査（追加なし）','USB転送＋Audioを同時取得','良好な出力を同じスマホで記録','Windows形式を1つ変えて比較','状態変化・回復条件を比較')
    Add-UiField $grid 1 '追加する調査' $followUpChoice
    $script:followUpGuide=New-UiLabel ''; $followUpGuide.Dock='Fill';$followUpGuide.AutoSize=$false;$grid.Controls.Add($followUpGuide,0,2);$grid.SetColumnSpan($followUpGuide,2)
    $script:followUpReference=New-UiCombo @();$followUpReference.DisplayMember='label'
    $selectReference=New-Object Windows.Forms.TableLayoutPanel;$selectReference.Dock='Fill';$selectReference.ColumnCount=2;[void]$selectReference.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$selectReference.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',175)))
    $script:followUpExternal=New-UiButton '別の記録から選ぶ';$external=$followUpExternal;$selectReference.Controls.Add($followUpReference,0,0);$selectReference.Controls.Add($external,1,0);Add-UiField $grid 7 '比較先の調査を選ぶ' $selectReference
    $external.Add_Click({Select-FollowUpReferenceFile})
    $script:followUpRoute=New-Object Windows.Forms.TextBox;$followUpRoute.Dock='Fill';Add-UiField $grid 8 'スマホで録る接続・位置' $followUpRoute
    $script:followUpFormat=New-Object Windows.Forms.TextBox;$followUpFormat.Dock='Fill';Add-UiField $grid 9 '形式の元の値 → 変更後' $followUpFormat
    $script:followUpConsent=New-Object Windows.Forms.CheckBox;$followUpConsent.Dock='Fill';$followUpConsent.Text="USB＋Audioの取得負荷・全USB機器の識別情報を含む可能性を確認し、`r`n共通の開始時に管理者権限で取得することを了承する。`r`nETLは書き出し画面で「詳細ETLも含める」を選んだ場合だけZIPへ含める。"
    $grid.Controls.Add($followUpConsent,0,3);$grid.SetColumnSpan($followUpConsent,2)
    $script:followUpApply=New-UiButton '共通テスト音声・30秒に設定';$script:followUpSound=New-UiButton 'Windowsのサウンド設定';$apply=$followUpApply;$sound=$followUpSound
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Controls.AddRange([Windows.Forms.Control[]]@($apply,$sound));$grid.Controls.Add($buttons,0,4);$grid.SetColumnSpan($buttons,2)
    $sound.Add_Click({Start-Process 'ms-settings:sound'})
    $script:followUpOperation=New-UiCombo @('未確認','操作なし','再起動のみ','音声デバイスの無効・有効のみ','スリープ・復帰のみ','複数の操作（再起動＋機器入れ直し等）')
    $script:followUpState=New-UiCombo @('未確認','ノイズ発生中（申告）','ノイズなしを確認（申告）')
    Add-UiField $grid 5 '直前に行った操作' $followUpOperation;Add-UiField $grid 6 '開始時の状態' $followUpState
    $apply.Add_Click({$audioMode.SelectedIndex=0;$audioSource.SelectedIndex=0;$audioLength.SelectedItem='30';$settingsTabs.SelectedTab=$audioTab})
    $followUpChoice.Add_SelectedIndexChanged({$followUpConsent.Checked=$false;$followUpGuide.Text=Get-FollowUpGuide $followUpChoice.SelectedIndex;Update-UiState})
    $followUpConsent.Add_CheckedChanged({Update-UiState});$followUpGuide.Text=Get-FollowUpGuide 0
    $tab.Controls.Add($grid);return $tab
}
function Get-FollowUpReportHtml {
    param($Session)
    $rows=@(foreach($test in @($Session.tests|Where-Object {$_.followUp -and $_.followUp.kind -ne 'None'})){
        [pscustomobject]@{testId=$test.id;plan=$test.followUp;probeId=$test.followUp.probeId;traceId=$test.followUp.traceId;physicalRecordIds=@($Session.physicalRecordings|Where-Object {$_.testId -eq $test.id}|ForEach-Object {$_.id})}
    })
    if(-not $rows.Count){return ''}
    '<h2>追加調査と記録の対応</h2><p>実音の比較は同じ録音方式・位置等を揃えて行います。PCとスマホの時計は同期済みと仮定しません。USBは対象だけに絞った取得ではなく、イベント不足は正常の証拠ではありません。</p><pre>'+(ConvertTo-HtmlText (ConvertTo-Json -InputObject $rows -Depth 12))+'</pre>'
}

function Refresh-FollowUpReferences {
    if(-not $followUpReference){return}
    $selected=if($followUpReference.SelectedItem){$followUpReference.SelectedItem.sessionId+'/'+$followUpReference.SelectedItem.id}else{''}
    $followUpReference.Items.Clear()
    [void]$followUpReference.Items.Add([pscustomobject]@{id='';sessionId='';sourceHash='';label='比較先を指定しない'})
    foreach($entry in @($script:session.tests|Where-Object {$_.result -notin @('InProgress','NotRun')})){
        $probe=@($script:session.audioProbes|Where-Object {$_.testId -eq $entry.id}|Select-Object -Last 1)
        $name=if($probe.Count){$probe[0].endpointName}else{$entry.output}
        [void]$followUpReference.Items.Add([pscustomobject]@{id=$entry.id;sessionId=$script:session.id;sourceHash='';label=($entry.startedUtc+' / '+$name+' / '+$entry.id.Substring(0,[Math]::Min(8,$entry.id.Length)))})
    }
    foreach($entry in @($script:followUpExternalChoices)){[void]$followUpReference.Items.Add($entry)}
    $followUpReference.SelectedIndex=0
    for($i=0;$i -lt $followUpReference.Items.Count;$i++){if(($followUpReference.Items[$i].sessionId+'/'+$followUpReference.Items[$i].id) -eq $selected){$followUpReference.SelectedIndex=$i;break}}
}
function Add-FollowUpReferenceFile {
    param([string]$Path)
    $source=Read-Session $Path
    if($source.id -notmatch '^[a-fA-F0-9]{32}$'){throw '比較元のセッションIDが正しくありません。'}
    $hash=(Get-FileHash -LiteralPath $Path).Hash
    $choices=@(foreach($entry in @($source.tests|Where-Object {$_.result -notin @('InProgress','NotRun') -and $_.id -match '^[a-fA-F0-9]{32}$'})){
        [pscustomobject]@{id=$entry.id;sessionId=$source.id;sourceHash=$hash;label=('別記録 / '+$entry.startedUtc+' / '+$entry.output+' / '+$entry.id.Substring(0,8))}
    })
    if(-not $choices.Count){throw 'この記録には比較できる終了済みの調査がありません。'}
    $script:followUpExternalChoices=$choices
    Refresh-FollowUpReferences;$followUpReference.SelectedIndex=$followUpReference.Items.Count-$choices.Count
}
function Select-FollowUpReferenceFile {
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='調査記録 (session.json)|session.json'
    try{if($dialog.ShowDialog($form) -eq 'OK'){Add-FollowUpReferenceFile $dialog.FileName}}catch{Show-UiError $_.Exception.Message}finally{$dialog.Dispose()}
}
function Get-FollowUpCoverage {
    param($TraceState,$Probe,$Test=$null)
    $capture=$Probe.capture;$usb=$TraceState.usb
    if($Test.context.boot.status -eq 'collected' -and $TraceState.target.boot.status -eq 'collected'){
        $difference=[Math]::Abs(([DateTime]::Parse($Test.context.boot.data.lastBootUtc).ToUniversalTime()-[DateTime]::Parse($TraceState.target.boot.data.lastBootUtc).ToUniversalTime()).TotalSeconds)
        if($difference -gt 5){return [pscustomobject]@{status='unavailable';scope='BootIdentityMismatch: 起動情報が一致せず、QPC区間を比較しない。'}}
    }
    if(-not $capture.endedQpc -or -not $usb.started.qpc -or -not $usb.ended.qpc -or $capture.qpcFrequency -ne $usb.started.frequency -or $capture.qpcFrequency -ne $usb.ended.frequency){return [pscustomobject]@{status='unavailable';scope='録音とUSBの取得区間が未確定、または時計が一致しない。'}}
    $start=[Math]::Max([double]$capture.startedQpc,[double]$usb.started.qpc);$end=[Math]::Min([double]$capture.endedQpc,[double]$usb.ended.qpc)
    $audioOverlap=$null;$joint=$null;$testOverlap=$null
    if($TraceState.started.frequency -eq $capture.qpcFrequency -and $TraceState.ended.frequency -eq $capture.qpcFrequency){
        $audioOverlap=[Math]::Round([Math]::Max(0,[Math]::Min($capture.endedQpc,$TraceState.ended.qpc)-[Math]::Max($capture.startedQpc,$TraceState.started.qpc))/$capture.qpcFrequency,3)
        $joint=[Math]::Round([Math]::Max(0,[Math]::Min($end,$TraceState.ended.qpc)-[Math]::Max($start,$TraceState.started.qpc))/$capture.qpcFrequency,3)
    }
    if($Test.timing.end -and $Test.timing.start.frequency -eq $capture.qpcFrequency -and $Test.timing.end.frequency -eq $capture.qpcFrequency){$testOverlap=[Math]::Round([Math]::Max(0,[Math]::Min($usb.ended.qpc,$Test.timing.end.qpc)-[Math]::Max($usb.started.qpc,$Test.timing.start.qpc))/$capture.qpcFrequency,3)}
    [pscustomobject]@{status='calculated';overlapSeconds=[Math]::Round([Math]::Max(0,$end-$start)/$capture.qpcFrequency,3);recordingSeconds=[Math]::Round(($capture.endedQpc-$capture.startedQpc)/$capture.qpcFrequency,3);usbStartAfterRecordingSeconds=[Math]::Round(($usb.started.qpc-$capture.startedQpc)/$capture.qpcFrequency,3);audioTraceOverlapSeconds=$audioOverlap;usbAudioRecordingOverlapSeconds=$joint;testUsbOverlapSeconds=$testOverlap;scope='同じ起動内のQPCで照合。トレース区間はコマンド成功の確認点から保存確認点までで、ETLヘッダーの厳密な開始・終了時刻そのものではない。スマホの時刻・波形との同期ではない。'}
}
