function Get-PhoneConnectionDiagnostics {
    param($Receiver,[string]$SelectedAddress)
    $point=Get-ClockPoint
    $address=if($Receiver){$Receiver.Address}else{$SelectedAddress}
    $adapterInfo=Invoke-CollectionSection {
        $rows=@(foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
            foreach($unicast in $adapter.GetIPProperties().UnicastAddresses){
                if($unicast.Address.ToString() -eq $address){
                    $index=$adapter.GetIPProperties().GetIPv4Properties().Index
                    $profile=Invoke-CollectionSection {Get-NetConnectionProfile -InterfaceIndex $index -ErrorAction Stop|Select-Object NetworkCategory,IPv4Connectivity}
                    [pscustomobject]@{type=$adapter.NetworkInterfaceType.ToString();operationalState=$adapter.OperationalStatus.ToString();hasIpv4Gateway=(@($adapter.GetIPProperties().GatewayAddresses|Where-Object {$_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0'}).Count -gt 0);profile=$profile}
                }
            }
        })
        if(-not $rows.Count){throw 'Selected adapter not found'}
        $rows
    }
    $firewall=Invoke-CollectionSection {Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop|Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction}
    $selfTest=[pscustomobject]@{status='notListening';httpStatus=$null;errorType=$null}
    $before=if($Receiver){$Receiver.NetworkSnapshot()}else{$null}
    if($Receiver -and -not $Receiver.Finished){
        $request=[Net.HttpWebRequest]::Create($Receiver.Url+'health');$request.Proxy=$null;$request.Timeout=3000;$request.ReadWriteTimeout=3000
        try{$response=$request.GetResponse();try{$selfTest.status='responded';$selfTest.httpStatus=[int]$response.StatusCode}finally{$response.Dispose()}}
        catch{$selfTest.status='failed';$selfTest.errorType=$_.Exception.GetType().Name}
    }
    [pscustomobject]@{
        id=[guid]::NewGuid().ToString('N');point=$point;selectedLocalIpv4=$address;port=if($Receiver){$Receiver.Port}else{$null}
        adapter=$adapterInfo;firewallProfiles=$firewall;receiverBeforeSelfTest=$before;localHttpSelfTest=$selfTest
        receiverAfterSelfTest=if($Receiver){$Receiver.NetworkSnapshot()}else{$null}
        manualObservation=$null
        scope='明示的な接続診断。選んだLAN内IPv4とポートを含む。トークン・URL・送信元IP・MAC・SSID・PC名・全User-Agentは保存しない。PC内の自己テスト成功はスマホからの到達やファイアウォール通過の証明ではない。別端末のTCP到達はスマホやページ表示を特定しない。'
    }
}
function Get-PhoneConnectionSummary {
    param($Report)
    $snapshot=$Report.receiverAfterSelfTest
    $text='PCの選択先：'+$Report.selectedLocalIpv4+':'+$Report.port+"`r`n"+'PC内のHTTP自己テスト：'+$Report.localHttpSelfTest.status+' / '+$Report.localHttpSelfTest.httpStatus+"`r`n"
    if(-not $snapshot){$text+='受付は開始されていません。受信を開き、最新のQRで試してください。'}
    else{
        $text+='別端末からのTCP接続：'+$snapshot.OtherDeviceConnections+' / HTTP応答：'+$snapshot.HttpResponses+' / HTTPSらしい接続：'+$snapshot.TlsConnections+"`r`n"
        if($snapshot.TlsConnections -gt 0){$text+='HTTP専用の受付へTLSらしい通信が届きました。スマホのURLがhttpsへ変わっていないか確認してください。'+"`r`n"}
        if($snapshot.OtherDeviceConnections -eq 0){$text+='スマホからの到達は確認できていません。Firefox・Androidのローカル接続許可、PCのファイアウォール、ルーターの端末分離、選択IPを比較してください。'}
        else{$text+='別端末の接続は届いています。HTTP要求・応答のログとブラウザー側のエラーを照合します。TCP到達だけでページ表示の成功とは判断しません。'}
    }
    $text+="`r`n`r`n"+'PCが有線LAN、スマホがWi-Fiでも、同じルーター内で端末間通信が許可されていれば利用できます。自己テストだけではその経路を確認できません。'
    return $text
}
function Protect-PhoneDiagnosticNote {
    param([string]$Text)
    $text=$Text -replace 'https?://[^\s"<>]+/s/[a-zA-Z0-9_-]+(/[^\s"<>]*)?','[受付URLは省略]'
    $text=$text -replace '/s/[a-zA-Z0-9_-]{8,}','/s/[トークンは省略]'
    if($text.Length -gt 4000){$text=$text.Substring(0,4000)}
    return $text
}
function Show-PhoneConnectionDiagnostics {
    $receiver=if($script:phoneReceiver){$script:phoneReceiver}else{$script:lastPhoneReceiver}
    $selected=[string]$phoneAddress.SelectedItem
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='スマホ接続を診断して記録';$dialog.Size=New-Object Drawing.Size(800,650);$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $grid=New-UiGrid @(240,40,44,116,54,44) 185;$grid.Dock='Fill'
    $summary=New-Object Windows.Forms.TextBox;$summary.Multiline=$true;$summary.ReadOnly=$true;$summary.ScrollBars='Vertical';$summary.Dock='Fill';$summary.Text='PC内の接続と受付記録を調べています。設定の変更や外部サーバーへの通信は行いません。'
    $grid.Controls.Add($summary,0,0);$grid.SetColumnSpan($summary,2)
    $browser=New-Object Windows.Forms.TextBox;$browser.Dock='Fill';Add-UiField $grid 1 'スマホ・ブラウザー（任意）' $browser
    $comparison=New-UiCombo @('未比較','同じURLが別ブラウザーでは開ける','同じURLが別ブラウザーでも開けない');Add-UiField $grid 2 '別ブラウザーとの比較' $comparison
    $note=New-Object Windows.Forms.TextBox;$note.Multiline=$true;$note.ScrollBars='Vertical';$note.Dock='Fill';Add-UiField $grid 3 '画面のエラー文・備考' $note
    Add-UiGuide $grid 4 '保存するとLAN内IP・ポート・接続履歴と入力内容が調査記録／ZIPへ入ります。HTTP応答が来ていない場合、ステータスコードは空欄で構いません。'
    $save=New-UiButton '診断を記録へ保存';$save.Enabled=$false;$close=New-UiButton '閉じる';$close.DialogResult='Cancel';$actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$actions.Controls.AddRange([Windows.Forms.Control[]]@($save,$close));$grid.Controls.Add($actions,1,5);$dialog.Controls.Add($grid)
    $job=[PowerShell]::Create();[void]$job.AddScript({param($core,$inventory,$receiver,$address);$ErrorActionPreference='Stop';. $core;. $inventory;Get-PhoneConnectionDiagnostics $receiver $address}).AddArgument((Join-Path $PSScriptRoot 'Core.ps1')).AddArgument((Join-Path $PSScriptRoot 'Inventory.ps1')).AddArgument($receiver).AddArgument($selected)
    $state=[pscustomobject]@{handle=$job.BeginInvoke();report=$null};$refresh=New-Object Windows.Forms.Timer;$refresh.Interval=200
    $refresh.Add_Tick({if($state.handle.IsCompleted){$refresh.Stop();try{$value=@($job.EndInvoke($state.handle));if($job.HadErrors -or $value.Count -ne 1){throw 'Connection diagnosis failed'};$state.report=$value[0];$summary.Text=Get-PhoneConnectionSummary $state.report;$save.Enabled=$true;if($SmokeTest){$browser.Text='Android / Firefox Beta (synthetic)';$note.Text='Synthetic connection observation';$save.PerformClick()}}catch{$summary.Text='接続診断の一部を取得できませんでした。受付状態とブラウザーのエラーを確認してください。';if($SmokeTest){$dialog.Close()}}}})
    $save.Add_Click({try{
        $state.report.manualObservation=[pscustomobject]@{deviceAndBrowser=Protect-PhoneDiagnosticNote $browser.Text;otherBrowser=[string]$comparison.SelectedItem;errorText=Protect-PhoneDiagnosticNote $note.Text;scope='利用者が入力した観察。Firefoxのネットワークログを自動取得したものではありません。'}
        Add-PhoneConnectionReport $state.report
        $dialog.DialogResult='OK';$dialog.Close()
    }catch{Show-UiError $_.Exception.Message}})
    try{$refresh.Start();[void]$dialog.ShowDialog($form)}finally{$refresh.Stop();$refresh.Dispose();if(-not $state.handle.IsCompleted){$job.Stop()};$job.Dispose();$dialog.Dispose()}
}
function Add-PhoneConnectionReport {
    param($Report)
    if(-not $script:session.PSObject.Properties['networkDiagnostics']){$script:session|Add-Member -NotePropertyName networkDiagnostics -NotePropertyValue @()}
    $script:session.networkDiagnostics=@($script:session.networkDiagnostics)+@($Report)
    Save-CurrentSession
    $phoneStatus.Text='接続診断を保存しました。「5 書き出す」でZIPに含めて持ち帰れます。'
}
function Get-PhoneNetworkReportHtml {
    param($Session)
    $entries=@($Session.networkDiagnostics|Where-Object {$null -ne $_})
    if(-not $entries.Count){return ''}
    '<h2>スマホ接続の診断</h2><p>選択したLAN内IPとポートを含みます。PC内自己テストと別端末からの到達は区別します。通常の音声ノイズの正常判定には使用しません。</p><pre>'+(ConvertTo-HtmlText ($entries|ConvertTo-Json -Depth 16))+'</pre>'
}
