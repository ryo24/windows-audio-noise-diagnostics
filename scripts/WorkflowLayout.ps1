function New-UiPage {
    param([string]$Title)
    $page=New-Object Windows.Forms.TabPage;$page.Text=$Title;$page.Padding=New-Object Windows.Forms.Padding(12);$page.AutoScroll=$true
    return $page
}
function New-UiGrid {
    param([int[]]$Heights,[int]$LabelWidth=185)
    $grid=New-Object Windows.Forms.TableLayoutPanel;$grid.Dock='Top';$grid.Height=($Heights|Measure-Object -Sum).Sum+8;$grid.ColumnCount=2;$grid.RowCount=$Heights.Count
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',$LabelWidth)));[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    foreach($height in $Heights){[void]$grid.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
    return $grid
}
function Add-UiField {param($Grid,[int]$Row,[string]$Title,$Control);$Grid.Controls.Add((New-UiLabel $Title),0,$Row);$Grid.Controls.Add($Control,1,$Row)}
function Add-UiGuide {
    param($Grid,[int]$Row,[string]$Text)
    $label=New-UiLabel $Text;$label.Dock='Fill';$label.AutoSize=$false;$label.ForeColor=[Drawing.Color]::FromArgb(40,85,96)
    $Grid.Controls.Add($label,0,$Row);$Grid.SetColumnSpan($label,2)
}

$form=New-Object Windows.Forms.Form;$form.Text='Windows Audio Noise Diagnostics'
$form.MinimumSize=New-Object Drawing.Size(960,740);$form.StartPosition='CenterScreen';$form.Font=New-Object Drawing.Font('Yu Gothic UI',10)
$area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size=New-Object Drawing.Size([Math]::Min(1120,$area.Width-32),[Math]::Min(880,$area.Height-32))
$form.AutoScaleMode='Dpi';$form.BackColor=[Drawing.Color]::FromArgb(243,246,248)
$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(16);$layout.ColumnCount=1;$layout.RowCount=4
foreach($height in @(58,52,0,36)){$style=New-Object Windows.Forms.RowStyle;if($height){$style.SizeType='Absolute';$style.Height=$height}else{$style.SizeType='Percent';$style.Height=100};[void]$layout.RowStyles.Add($style)}
$form.Controls.Add($layout)
$header=New-UiLabel ('Windows 音声ノイズ調査  /  v'+(Get-ToolIdentity).version);$header.Font=New-Object Drawing.Font('Yu Gothic UI',20,[Drawing.FontStyle]::Bold);$header.ForeColor=[Drawing.Color]::FromArgb(10,100,109);$layout.Controls.Add($header,0,0)
$workflowStatus=New-UiLabel '';$workflowStatus.Dock='Fill';$workflowStatus.AutoSize=$false;$layout.Controls.Add($workflowStatus,0,1)
$tabs=New-Object Windows.Forms.TabControl;$tabs.Dock='Fill';$layout.Controls.Add($tabs,0,2)
$preparePage=New-UiPage '1 準備する';$settingsPage=New-UiPage '2 条件を設定';$runPage=New-UiPage '3 調査する';$reviewPage=New-UiPage '4 聞き直し・結果';$exportPage=New-UiPage '5 書き出す'
$tabs.TabPages.AddRange([Windows.Forms.TabPage[]]@($preparePage,$settingsPage,$runPage,$reviewPage,$exportPage))
$recordCount=New-UiLabel '調査はまだ作成されていません。';$layout.Controls.Add($recordCount,0,3)
$status=New-Object Windows.Forms.ToolStripStatusLabel;$status.Text='記録はローカルに保存されます。更新はアプリを閉じて update.cmd から。'
$statusStrip=New-Object Windows.Forms.StatusStrip;[void]$statusStrip.Items.Add($status);$form.Controls.Add($statusStrip)

$profileGrid=New-UiGrid @(78,44,44,110,58,54,58) 190
Add-UiGuide $profileGrid 0 "最初に新しい調査を作るか、保存した記録を再開します。`r`n下の項目は分かる範囲で記入してください。BIOSの確認や設定変更は必要ありません。`r`n作成済みの記録は「4 聞き直し・結果」「5 書き出す」からも確認できます。"
$speaker=New-Object Windows.Forms.TextBox;$speaker.Dock='Fill';$profilePower=New-UiCombo @('PCのUSB','独立したUSB電源','テレビのUSB','不明・その他')
$observations=New-Object Windows.Forms.TextBox;$observations.Multiline=$true;$observations.ScrollBars='Vertical';$observations.Dock='Fill'
$cStates=New-UiCombo @('未確認','Disabled（確認済み）','Enabled（確認済み）')
Add-UiField $profileGrid 1 'スピーカー・機器（任意）' $speaker;Add-UiField $profileGrid 2 'スピーカーの給電先' $profilePower
Add-UiField $profileGrid 3 '確認済みの症状' $observations;Add-UiField $profileGrid 4 'C-States（任意の記録）' $cStates
$collect=New-UiButton 'PC情報を収集して新規作成';$resume=New-UiButton '保存した記録を再開'
$sessionActions=New-Object Windows.Forms.FlowLayoutPanel;$sessionActions.Dock='Fill';$sessionActions.Controls.AddRange([Windows.Forms.Control[]]@($collect,$resume));$profileGrid.Controls.Add($sessionActions,1,5)
$prepareNext=New-UiButton '2 条件を設定へ';$profileGrid.Controls.Add($prepareNext,1,6);$preparePage.Controls.Add($profileGrid)
$prepareNext.Add_Click({$tabs.SelectedTab=$settingsPage})

$settingsLayout=New-Object Windows.Forms.TableLayoutPanel;$settingsLayout.Dock='Fill';$settingsLayout.ColumnCount=1;$settingsLayout.RowCount=2
[void]$settingsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)));[void]$settingsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',52)))
$settingsTabs=New-Object Windows.Forms.TabControl;$settingsTabs.Dock='Fill';$settingsLayout.Controls.Add($settingsTabs,0,0);$settingsPage.Controls.Add($settingsLayout)
$audioTab=New-AudioSettingsTab;$testTab=New-UiPage '比較する条件';$btTab=New-UiPage 'Bluetooth（任意）'
$evidenceTab=New-PlaybackConditionsTab
$settingsTabs.TabPages.AddRange([Windows.Forms.TabPage[]]@($audioTab,$testTab,$btTab,$evidenceTab))
$settingsNext=New-UiButton '3 調査画面へ';$settingsLayout.Controls.Add($settingsNext,0,1);$settingsNext.Add_Click({$tabs.SelectedTab=$runPage})
$testGrid=New-UiGrid @(44,140,44,44,44,100,44,52) 180
$testChoice=New-UiCombo @($script:definitions|ForEach-Object {$_.title});$guide=New-UiLabel '';$guide.Dock='Fill';$guide.AutoSize=$false
$outputChoice=New-UiCombo @('3.5mm','HDMI','USB音声','Bluetooth','その他');$powerChoice=New-UiCombo @('PCのUSB','独立したUSB電源','テレビのUSB','該当なし','不明・その他')
$connections=New-Object Windows.Forms.TableLayoutPanel;$connections.Dock='Fill';$connections.ColumnCount=3
foreach($width in @(40,15,45)){[void]$connections.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',$width)))}
$connections.Controls.Add($outputChoice,0,0);$connections.Controls.Add((New-UiLabel '給電'),1,0);$connections.Controls.Add($powerChoice,2,0)
$appName=New-Object Windows.Forms.TextBox;$appName.Dock='Fill';$changeText=New-Object Windows.Forms.TextBox;$changeText.Dock='Fill'
$notes=New-Object Windows.Forms.TextBox;$notes.Dock='Fill';$notes.Multiline=$true;$notes.ScrollBars='Vertical'
$reference=New-Object Windows.Forms.TextBox;$reference.Dock='Fill'
$row=0;foreach($entry in @(@('今回の比較',$testChoice),@('比較の手順',$guide),@('接続と給電',$connections),@('再生アプリ / 素材',$appName),@('今回変える条件',$changeText),@('備考 / 元の設定',$notes),@('比較先のテストID',$reference))){Add-UiField $testGrid $row $entry[0] $entry[1];$row++}
$skip=New-UiButton 'この比較を未実施として記録';$testGrid.Controls.Add($skip,1,7);$testTab.Controls.Add($testGrid)
$btGrid=New-UiGrid @(44,44,52,120,100) 190
$btCondition=New-UiCombo @('未確認','Bluetooth無線オフ','無線オン・BTキーボード電源オフ','BTキーボード接続');$inputActivity=New-UiCombo @('未確認','有線のみ使用','Bluetooth接続・待機','Bluetoothで入力中（手動申告）')
$btSampling=New-Object Windows.Forms.CheckBox;$btSampling.Text='調査中に約10秒間隔で状態を取得（最大720回）';$btSampling.Checked=$true;$btSampling.Dock='Fill'
Add-UiField $btGrid 0 '無線・接続（手動申告）' $btCondition;Add-UiField $btGrid 1 '入力状況（手動申告）' $inputActivity;$btGrid.Controls.Add($btSampling,1,2)
Add-UiGuide $btGrid 3 "開始ボタンは「3 調査する」に一つだけです。Bluetoothの記録も同時に始まります。`r`n切り替えはWindowsの設定で手動実施。有線キーボード・音声出力・給電・素材・音量を維持してください。`r`n打鍵内容や通信パケット・電波強度は取得しません。接続数と通信量は別です。"
$btStatus=New-UiLabel '取得した状態は、調査中にここへ表示します。';$btStatus.Dock='Fill';$btStatus.AutoSize=$false;$btGrid.Controls.Add($btStatus,0,4);$btGrid.SetColumnSpan($btStatus,2);$btTab.Controls.Add($btGrid)

$runLayout=New-Object Windows.Forms.TableLayoutPanel;$runLayout.Dock='Fill';$runLayout.ColumnCount=1;$runLayout.RowCount=5
foreach($height in @(90,84,64,58,0)){$style=New-Object Windows.Forms.RowStyle;if($height){$style.SizeType='Absolute';$style.Height=$height}else{$style.SizeType='Percent';$style.Height=100};[void]$runLayout.RowStyles.Add($style)}
$runSummary=New-UiLabel '';$runSummary.Dock='Fill';$runSummary.AutoSize=$false;$runLayout.Controls.Add($runSummary,0,0)
$runInstruction=New-UiLabel '';$runInstruction.Dock='Fill';$runInstruction.AutoSize=$false;$runInstruction.Font=New-Object Drawing.Font('Yu Gothic UI',11,[Drawing.FontStyle]::Bold);$runLayout.Controls.Add($runInstruction,0,1)
$runButtons=New-Object Windows.Forms.FlowLayoutPanel;$runButtons.Dock='Fill'
$start=New-UiButton '調査を開始';$mark=New-UiButton 'ノイズが聞こえた';$finish=New-UiButton '終了して結果を記録'
$start.BackColor=[Drawing.Color]::FromArgb(10,100,109);$start.ForeColor=[Drawing.Color]::White;$mark.BackColor=[Drawing.Color]::FromArgb(255,232,170)
$runButtons.Controls.AddRange([Windows.Forms.Control[]]@($start,$mark,$finish));$runLayout.Controls.Add($runButtons,0,2)
$runAudioStatus=New-UiLabel '';$runAudioStatus.Dock='Fill';$runAudioStatus.AutoSize=$false;$runLayout.Controls.Add($runAudioStatus,0,3)
$elapsed=New-UiLabel '00:00 / ノイズ 0 回';$runButtons.Controls.Add($elapsed)
$runTools=New-Object Windows.Forms.TabControl;$runTools.Dock='Fill';$runLayout.Controls.Add($runTools,0,4)
$runHelp=New-UiPage '調査の流れ'
$runHelpText=New-UiLabel "① 上の開始ボタンを1回押します。設定した録音と状態の記録が一緒に始まります。`r`n② ノイズが聞こえたときだけ「ノイズが聞こえた」を押します。`r`n③ 「終了して結果を記録」を押します。録音ありでは指定した秒数でも自動終了します。`r`n④ 結果を保存すると「4 聞き直し・結果」へ進みます。`r`n`r`nスマートフォンの追加記録と詳細トレースは、必要なときだけ隣のタブを使います。";$runHelpText.Dock='Fill';$runHelpText.AutoSize=$false;$runHelp.Controls.Add($runHelpText)
$phoneTab=New-PhoneCaptureTab;$traceTab=New-TraceTab;$runTools.TabPages.AddRange([Windows.Forms.TabPage[]]@($runHelp,$phoneTab,$traceTab));$runPage.Controls.Add($runLayout)

$reviewLayout=New-Object Windows.Forms.TableLayoutPanel;$reviewLayout.Dock='Fill';$reviewLayout.ColumnCount=1;$reviewLayout.RowCount=2
[void]$reviewLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)));[void]$reviewLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',52)))
$reviewTabs=New-Object Windows.Forms.TabControl;$reviewTabs.Dock='Fill';$reviewLayout.Controls.Add($reviewTabs,0,0)
$audioReviewTab=New-AudioReviewTab;$physicalTab=New-UiPage 'スマホなどの実音';$historyTab=New-UiPage '比較の結果・テストID'
# Keep receiver and playback functions, but put reception and listening in their own steps.
$receiveGrid=$phoneTab.Controls[0];$physicalGrid=New-UiGrid @(78,44,52,44,100) 175
Add-UiGuide $physicalGrid 0 "「3 調査する」のスマホタブで受信した記録、または手元のファイルを確認します。`r`n一覧から再生し、調査中と同じノイズが入っているか記録してください。`r`nここでの再生確認は手動の申告として保存します。"
$moves=@($receiveGrid.Controls|Where-Object {$receiveGrid.GetRow($_) -ge 4})
foreach($control in $moves){$row=$receiveGrid.GetRow($control)-3;$column=$receiveGrid.GetColumn($control);$span=$receiveGrid.GetColumnSpan($control);$physicalGrid.Controls.Add($control,$column,$row);$physicalGrid.SetColumnSpan($control,$span)}
$receiveGrid.RowStyles[3].Height=94
$receiveGrid.Height=306;$receiveGrid.MinimumSize=New-Object Drawing.Size(0,306);$receiveGrid.RowCount=4
while($receiveGrid.RowStyles.Count -gt 4){$receiveGrid.RowStyles.RemoveAt(4)}
$phoneTab.Text='スマホをつなぐ（任意）';$phoneStart.Text='スマホからの受信を開く';$phoneStatus.Text='先に「1 準備する」で記録を作成してください。';$physicalPlay.Text='取り込んだ実音を再生'
$physicalTab.Controls.Add($physicalGrid)
$history=New-Object Windows.Forms.TextBox;$history.Multiline=$true;$history.ReadOnly=$true;$history.ScrollBars='Vertical';$history.Dock='Fill';$historyTab.Controls.Add($history)
$reviewTabs.TabPages.AddRange([Windows.Forms.TabPage[]]@($audioReviewTab,$physicalTab,$historyTab))
$reviewNext=New-UiButton '5 書き出すへ';$reviewLayout.Controls.Add($reviewNext,0,1);$reviewNext.Add_Click({$tabs.SelectedTab=$exportPage});$reviewPage.Controls.Add($reviewLayout)

$exportGrid=New-UiGrid @(100,66,54,60,64,80) 185
Add-UiGuide $exportGrid 0 "調査を終えたら、必要なログ・録音・動画をZIPにまとめます。`r`n「ZIPを書き出す」を押すと、保存後にエクスプローラーでそのZIPを選択します。`r`n別のPCへ渡す場合は、このZIPをコピーしてください。自動送信はしません。"
$exportReady=New-UiLabel '';$exportReady.Dock='Fill';$exportReady.AutoSize=$false;$exportGrid.Controls.Add($exportReady,0,1);$exportGrid.SetColumnSpan($exportReady,2)
$report=New-UiButton '報告書を開く';$folder=New-UiButton '記録フォルダーを開く'
$fileActions=New-Object Windows.Forms.FlowLayoutPanel;$fileActions.Dock='Fill';$fileActions.Controls.AddRange([Windows.Forms.Control[]]@($report,$folder));$exportGrid.Controls.Add($fileActions,1,2)
$includeTraces=New-Object Windows.Forms.CheckBox;$includeTraces.Text='詳細ETLも含める（プロセス名・パスなどの情報を含む場合があります）';$includeTraces.Dock='Fill';$exportGrid.Controls.Add($includeTraces,0,3);$exportGrid.SetColumnSpan($includeTraces,2)
$export=New-UiButton 'ZIPを書き出して場所を開く';$exportGrid.Controls.Add($export,1,4)
Add-UiGuide $exportGrid 5 "保存先は data/exports/ です。音声・動画も含むため、共有する相手と内容を確認してください。`r`nエージェントが同じPCにある場合は data/sessions/ を直接解析することもできます。"
$exportPage.Controls.Add($exportGrid)
$tabs.Add_SelectedIndexChanged({if($script:uiReady -and $tabs.SelectedTab -in @($settingsPage,$reviewPage) -and -not $script:activeTest -and -not $script:audioPlayback -and $audioOutput.Items.Count -eq 0){Refresh-AudioOutputs};Update-UiState})
