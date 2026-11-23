$script:phoneReceiver=$null

function Initialize-LocalReceiver {
    if(-not ('AudioNoiseDiagnostics.LocalReceiver' -as [type])){Add-Type -Path @((Join-Path $PSScriptRoot 'LocalReceiver.cs'),(Join-Path $PSScriptRoot 'ReceiverNetwork.cs')) -ErrorAction Stop}
}
function Resolve-PhysicalMediaFile {
    param([string]$SessionDirectory,[string]$RelativePath)
    if($RelativePath -notmatch '^physical/[a-fA-F0-9]{32}/source\.(wav|m4a|mp4|mov|webm|ogg|mp3|aac)$'){throw '取り込み音声・動画のパスが正しくありません。'}
    $root=[IO.Path]::GetFullPath($SessionDirectory).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $target=[IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if(-not $target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'セッション外のファイルにはアクセスしません。'}
    return $target
}
function ConvertTo-PhysicalRecord {
    param($Media,[string]$AudioProbeId,[string]$TestId)
    [pscustomobject]@{
        id=$Media.Id;sourceKind=$Media.Source;receivedUtc=$Media.ReceivedUtc;tool=Get-ToolIdentity
        file=[pscustomobject]@{path=$Media.RelativePath;sha256=$Media.Sha256;bytes=$Media.Bytes;mimeType=$Media.MimeType;kind=$Media.Kind;validation='ContainerSignatureOnly'}
        audioProbeId=$AudioProbeId;testId=$TestId
        phoneObservation=[pscustomobject]@{previewConfirmed=$Media.PreviewConfirmed;heardNoise=$Media.HeardNoise;note=$Media.Note;clientSentUtc=$Media.ClientSentUtc;captureStartedUtc=$Media.CaptureStartedUtc;captureEndedUtc=$Media.CaptureEndedUtc}
        verification=[pscustomobject]@{replayedManually=$false;heardNoise='Unknown';playbackRoute='';savedUtc=$null}
        scope='マイク・スマートフォンで記録した実音。部屋の音、距離、録音側の自動音声処理も含まれます。端末時計はPCと同期済みと仮定しません。'
    }
}
function Add-PhysicalMedia {
    param($Media)
    if(-not $script:session.PSObject.Properties['physicalRecordings']){$script:session|Add-Member -NotePropertyName physicalRecordings -NotePropertyValue @()}
    $probe=Get-SelectedAudioProbe
    $probeId=if($script:recordingProbe -and $script:audioRecorder){$script:recordingProbe.id}elseif($probe){$probe.id}else{''}
    $testId=if($script:activeTest){$script:activeTest.id}elseif($probe){$probe.testId}else{''}
    $record=ConvertTo-PhysicalRecord $Media $probeId $testId
    $script:session.physicalRecordings=@($script:session.physicalRecordings)+@($record)
    [void](Add-TimelineEvent $script:session 'PhysicalFileImported' $testId $probeId ('physicalId='+$record.id+'; not a recording-start time'))
    Save-CurrentSession;Refresh-PhysicalRecords
}
function Get-LocalCaptureAddresses {
    return @(Get-LocalCaptureAddressChoices|ForEach-Object {$_.Address})
}
function Get-LocalCaptureAddressChoices {
    Initialize-LocalReceiver
    $rows=@(foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
        if($adapter.OperationalStatus -ne 'Up'){continue}
        $hasGateway=@($adapter.GetIPProperties().GatewayAddresses|Where-Object {$_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0'}).Count -gt 0
        foreach($unicast in $adapter.GetIPProperties().UnicastAddresses){$address=$unicast.Address.ToString();if([AudioNoiseDiagnostics.LocalReceiver]::IsLocalAddress($address)-and -not [Net.IPAddress]::IsLoopback($unicast.Address)){
            $choice=New-Object AudioNoiseDiagnostics.CaptureAddressChoice;$choice.Address=$address
            $choice.Label=$address+' / '+$adapter.Name+' / '+$adapter.NetworkInterfaceType+$(if($hasGateway){'（ゲートウェイあり）'}else{'（ゲートウェイなし）'})
            [pscustomobject]@{choice=$choice;priority=if($hasGateway){0}else{1}}
        }}
    })
    return @($rows|Sort-Object priority|ForEach-Object {$_.choice})
}
function Get-SelectedPhysicalRecord {
    if($physicalRecords.SelectedIndex -ge 0){return @($script:session.physicalRecordings)[$physicalRecords.SelectedIndex]}
    return $null
}
function Refresh-PhysicalRecords {
    $physicalRecords.Items.Clear()
    foreach($entry in @($script:session.physicalRecordings)){[void]$physicalRecords.Items.Add(($entry.receivedUtc+' / '+$entry.sourceKind+' / '+[Math]::Round($entry.file.bytes/1MB,1)+' MB'))}
    if($physicalRecords.Items.Count -gt 0){$physicalRecords.SelectedIndex=$physicalRecords.Items.Count-1}
    Update-PhoneUi
}
function Update-PhoneUi {
    if(-not $phoneStart){return}
    $receiving=$null -ne $script:phoneReceiver
    $phoneStart.Enabled=($script:session -and -not $receiving -and $phoneAddress.SelectedIndex -ge 0 -and -not $script:worker)
    $phoneStop.Enabled=$receiving;$phoneQr.Enabled=$receiving;$phoneAddress.Enabled=(-not $receiving);$phoneRefresh.Enabled=(-not $receiving)
    $physicalImport.Enabled=($script:session -and -not $script:worker)
    $phoneDiagnose.Enabled=($script:session -and -not $script:worker)
    $entry=Get-SelectedPhysicalRecord
    $physicalPlay.Enabled=($null -ne $entry)
    $physicalSave.Enabled=($entry -and $physicalReviewed.Checked)
    foreach($control in @($physicalReviewed,$physicalHeard,$physicalRoute)){$control.Enabled=($null -ne $entry)}
    if($script:session -and $phoneStatus.Text -like '先に*'){$phoneStatus.Text='スマホからの受信を開いてQRを表示するか、保存済みファイルを取り込めます。確認は「4 聞き直し・結果」で行います。'}
    if($receiving){$collect.Enabled=$false;$resume.Enabled=$false}
}
function Poll-PhoneReceiver {
    if(-not $script:phoneReceiver){return}
    $received=$null
    while($script:phoneReceiver.Received.TryDequeue([ref]$received)){Add-PhysicalMedia $received;$phoneStatus.Text='受信しました。「4 聞き直し・結果 → スマホなどの実音」で再生確認できます。'}
    $snapshot=$script:phoneReceiver.NetworkSnapshot()
    $digest=([string]$snapshot.TcpConnections+'/'+$snapshot.HttpResponses+'/'+$snapshot.AcceptedFiles)
    if($script:lastPhoneNetworkDigest -ne $digest){
        $script:lastPhoneNetworkDigest=$digest
        $phoneStatus.Text='受付中：PC以外のTCP接続 '+$snapshot.OtherDeviceConnections+'件 / HTTP応答 '+$snapshot.HttpResponses+'件（PC内通信含む） / 受信 '+$snapshot.AcceptedFiles+'件。'+"`r`n"+'つながらない場合は「接続診断を保存」を押してください。受信した音の確認は「4 聞き直し・結果」です。'
        if($snapshot.TlsConnections){$phoneStatus.Text+="`r`n"+'HTTPSらしい接続を受信しました。この受付のURLはhttp://です。'}
    }
    if($script:phoneReceiver.Finished){Stop-PhoneReceiver;$phoneStatus.Text='受付は停止・期限切れになりました。再開すると新しいQRになります。'}
}
function Stop-PhoneReceiver {
    if($script:phoneReceiver){
        $receiverSnapshotSource=$script:phoneReceiver
        $script:phoneReceiver.Dispose()
        $received=$null;while($script:phoneReceiver.Received.TryDequeue([ref]$received)){Add-PhysicalMedia $received}
        $script:phoneReceiver=$null
        $script:lastPhoneReceiver=$receiverSnapshotSource
    }
    Update-UiState
}
function Import-PhysicalFiles {
    param($Session,[string]$SourceDirectory,[string]$TargetDirectory)
    foreach($entry in @($Session.physicalRecordings)){
        $source=Resolve-PhysicalMediaFile $SourceDirectory $entry.file.path;$target=Resolve-PhysicalMediaFile $TargetDirectory $entry.file.path
        if($source -eq $target -or -not (Test-Path -LiteralPath $source)){continue}
        if((Get-FileHash -LiteralPath $source).Hash -ne $entry.file.sha256){throw '取り込み元の音声・動画のハッシュが一致しません。'}
        if(Test-Path -LiteralPath $target){if((Get-FileHash -LiteralPath $target).Hash -ne $entry.file.sha256){throw '別の音声・動画があるため上書きせず停止しました。'}}
        else{[IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null;Copy-Item -LiteralPath $source -Destination $target}
    }
}
function Open-PhysicalRecord {
    try{
        $entry=Get-SelectedPhysicalRecord;$path=Resolve-PhysicalMediaFile $script:sessionDirectory $entry.file.path
        if(-not (Test-Path -LiteralPath $path)){throw '元の記録がありません。physicalフォルダーも一緒に持ち帰ってください。'}
        if((Get-FileHash -LiteralPath $path).Hash -ne $entry.file.sha256){throw '取り込み記録のハッシュが一致しません。'}
        $notice=Get-PlaybackReviewNotice ([pscustomobject]@{endpointName='スマートフォン等で記録した実音'}) 'ブラウザーで使用する出力（Windows・ブラウザー側で確認してください）'
        if(-not (Confirm-PlaybackReview $notice)){return}
        $name=[IO.Path]::GetFileName($path)
        $html='<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>実音の再生確認</title><body style="font:18px/1.7 system-ui;max-width:800px;margin:30px auto;padding:20px"><h1>取り込んだ実音を確認</h1><p><strong>再生前に、ノイズが出ないと確認済みの出力へ切り替えてください。</strong>再生時に加わるノイズは、ファイルに含まれる音とは別です。</p><video controls playsinline preload="metadata" style="width:100%;max-height:500px" src="'+$name+'"></video><p>再生できない形式は元ファイルを対応するプレーヤーで開いてください。確認後、アプリで「再生確認した」とノイズの聞こえ方・再生経路を記録します。</p><p>マイク側の処理・周囲の音・再生経路のノイズも影響します。デジタル録音との時刻を自動同期した記録ではありません。</p></body></html>'
        $review=Join-Path (Split-Path -Parent $path) 'review.html';Write-AtomicText $review $html;Start-Process -FilePath $review
    }catch{Show-UiError $_.Exception.Message}
}
function Get-PhysicalReportHtml {
    param($Session)
    $sections=New-Object 'System.Collections.Generic.List[string]'
    foreach($entry in @($Session.physicalRecordings)){
        $relative=$entry.file.path
        if($relative -notmatch '^physical/[a-fA-F0-9]{32}/source\.(wav|m4a|mp4|mov|webm|ogg|mp3|aac)$'){continue}
        $sections.Add('<article><h3>実音の記録 '+(ConvertTo-HtmlText $entry.id)+'</h3><video controls preload="none" style="max-width:100%;max-height:400px" src="'+$relative+'"></video><p><a href="'+$relative+'">元の音声・動画</a></p><details><summary>受信・手動確認の記録</summary><pre>'+(ConvertTo-HtmlText ($entry|ConvertTo-Json -Depth 12))+'</pre></details></article>')
    }
    if($sections.Count -eq 0){return ''}
    return '<h2>スマートフォン等で記録した実音</h2><p><strong>再生前に、ノイズが出ないと確認済みの出力へ切り替えてください。</strong>再生時に加わるノイズとファイル内の音を区別します。</p><p>元ファイルを変換せず保存しています。入力の音声処理・周囲音・位置・再生経路の影響も含まれます。再生確認は手動の申告です。スマートフォンの時計とPCの時計は自動同期していません。無発生だけで正常とは判定しません。</p>'+($sections -join "`n")
}
function New-PhoneCaptureTab {
    $tab=New-Object Windows.Forms.TabPage;$tab.Text='スマホ・実音取り込み';$tab.Padding=New-Object Windows.Forms.Padding(10);$tab.AutoScroll=$true
    $grid=New-Object Windows.Forms.TableLayoutPanel;$grid.Dock='Top';$grid.Height=430;$grid.MinimumSize=New-Object Drawing.Size(0,430);$grid.ColumnCount=2;$grid.RowCount=8
    [void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',160)));[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    foreach($height in @(106,38,44,56,38,44,36,0)){$s=New-Object Windows.Forms.RowStyle;if($height -eq 0){$s.SizeType='Percent';$s.Height=100}else{$s.SizeType='Absolute';$s.Height=$height};[void]$grid.RowStyles.Add($s)}
    $help=New-UiLabel "同じLAN内でQRから録音・動画をPCへ送れます（PCは有線LAN、スマホはWi-Fiでも利用可能）。`r`nスマホで「付近のデバイス」「ローカルネットワーク」の許可が出たら、このPCへの接続を許可してください。`r`n拒否した場合はAndroidの設定 → アプリ → Chrome → 権限や、サイトの権限を確認します（項目がある場合）。`r`nマイク許可とは別です。端末の録音・カメラ／ファイル選択を使用。信頼するLANで利用してください（HTTPは暗号化なし）。";$help.Dock='Fill';$help.AutoSize=$false;$grid.Controls.Add($help,0,0);$grid.SetColumnSpan($help,2)
    $script:phoneAddress=New-UiCombo @();$phoneAddress.DisplayMember='Label';$script:phoneRefresh=New-UiButton 'LANアドレスを取得'
    $addresses=New-Object Windows.Forms.TableLayoutPanel;$addresses.Dock='Fill';$addresses.ColumnCount=2;[void]$addresses.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)));[void]$addresses.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',180)))
    $addresses.Controls.Add($phoneAddress,0,0);$addresses.Controls.Add($phoneRefresh,1,0);$grid.Controls.Add((New-UiLabel 'スマホと同じLAN'),0,1);$grid.Controls.Add($addresses,1,1)
    $script:phoneStart=New-UiButton '受付を開始';$script:phoneQr=New-UiButton 'QRコードを表示';$script:phoneStop=New-UiButton '受付停止';$script:physicalImport=New-UiButton 'ファイルを取り込む'
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$actions.Controls.AddRange([Windows.Forms.Control[]]@($phoneStart,$phoneQr,$phoneStop,$physicalImport));$grid.Controls.Add($actions,0,2);$grid.SetColumnSpan($actions,2)
    $script:phoneDiagnose=New-UiButton '接続診断を保存';$actions.Controls.Add($phoneDiagnose)
    $phoneDiagnose.Add_Click({Show-PhoneConnectionDiagnostics})
    $script:phoneStatus=New-UiLabel '先にPC情報を収集してください。スマホで撮った記録は、受信後も元の形式のまま保存します。';$phoneStatus.Dock='Fill';$phoneStatus.AutoSize=$false;$grid.Controls.Add($phoneStatus,0,3);$grid.SetColumnSpan($phoneStatus,2)
    $script:physicalRecords=New-UiCombo @();$grid.Controls.Add((New-UiLabel '受信・取り込み記録'),0,4);$grid.Controls.Add($physicalRecords,1,4)
    $script:physicalPlay=New-UiButton 'ブラウザーで再生';$script:physicalSave=New-UiButton '手動の確認結果を保存';$script:physicalReviewed=New-Object Windows.Forms.CheckBox;$physicalReviewed.Text='元の記録を再生確認した';$physicalReviewed.AutoSize=$true
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Controls.AddRange([Windows.Forms.Control[]]@($physicalPlay,$physicalReviewed,$physicalSave));$grid.Controls.Add($buttons,0,5);$grid.SetColumnSpan($buttons,2)
    $script:physicalHeard=New-UiCombo @('ノイズ：未確認・判断できない','ノイズが聞こえる','ノイズは聞こえない');$grid.Controls.Add((New-UiLabel '再生後の聞こえ方'),0,6);$grid.Controls.Add($physicalHeard,1,6)
    $script:physicalRoute=New-Object Windows.Forms.TextBox;$physicalRoute.Dock='Fill';$physicalRoute.Multiline=$true;$grid.Controls.Add((New-UiLabel '再生経路・備考'),0,7);$grid.Controls.Add($physicalRoute,1,7);$tab.Controls.Add($grid)
    $phoneRefresh.Add_Click({try{$phoneAddress.Items.Clear();foreach($address in @(Get-LocalCaptureAddressChoices)){[void]$phoneAddress.Items.Add($address)};if($phoneAddress.Items.Count -gt 0){$phoneAddress.SelectedIndex=0};Update-PhoneUi}catch{Show-UiError $_.Exception.Message}})
    $phoneStart.Add_Click({try{Initialize-LocalReceiver;$script:phoneReceiver=[AudioNoiseDiagnostics.LocalReceiver]::Start([string]$phoneAddress.SelectedItem,$script:sessionDirectory,(Join-Path $script:ToolRoot 'web'),900);$phoneStatus.Text='受付中です。「QRコードを表示」を押し、スマホで開いてください。';Update-UiState}catch{Show-UiError $_.Exception.Message}})
    $phoneQr.Add_Click({if($script:phoneReceiver){Start-Process -FilePath ($script:phoneReceiver.Url+'pc')}})
    $phoneStop.Add_Click({try{Stop-PhoneReceiver;$phoneStatus.Text='受付を停止しました。'}catch{Show-UiError $_.Exception.Message}})
    $physicalImport.Add_Click({$dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='音声・動画|*.wav;*.m4a;*.mp4;*.mov;*.webm;*.ogg;*.mp3;*.aac';try{if($dialog.ShowDialog() -eq 'OK'){Initialize-LocalReceiver;$media=[AudioNoiseDiagnostics.LocalReceiver]::ImportFile($dialog.FileName,$script:sessionDirectory,'FileImport');Add-PhysicalMedia $media;$phoneStatus.Text='取り込みました。元ファイルは変更していません。'}}catch{Show-UiError $_.Exception.Message}finally{$dialog.Dispose()}})
    $physicalPlay.Add_Click({Open-PhysicalRecord});$physicalReviewed.Add_CheckedChanged({Update-PhoneUi})
    $physicalRecords.Add_SelectedIndexChanged({$entry=Get-SelectedPhysicalRecord;if($entry){$physicalReviewed.Checked=$entry.verification.replayedManually;$physicalHeard.SelectedIndex=[Math]::Max(0,[Array]::IndexOf(@('Unknown','Yes','No'),$entry.verification.heardNoise));$physicalRoute.Text=$entry.verification.playbackRoute};Update-PhoneUi})
    $physicalSave.Add_Click({try{$entry=Get-SelectedPhysicalRecord;$entry.verification.replayedManually=$physicalReviewed.Checked;$entry.verification.heardNoise=@('Unknown','Yes','No')[$physicalHeard.SelectedIndex];$entry.verification.playbackRoute=$physicalRoute.Text;$entry.verification.savedUtc=[DateTime]::UtcNow.ToString('o');Save-CurrentSession;$phoneStatus.Text='手動での再生確認結果を保存しました。'}catch{Show-UiError $_.Exception.Message}})
    return $tab
}
