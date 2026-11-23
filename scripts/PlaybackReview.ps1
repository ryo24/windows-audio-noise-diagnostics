function Get-PlaybackReviewNotice {
    param($Probe,[string]$OutputName,[string]$OutputRef='')
    $captured=@($Probe.playbackSnapshot.data.outputs|Where-Object {$_.isSelectedForProbe})
    $relation=if($captured.Count -eq 1 -and $OutputRef){if($captured[0].endpointRef -eq $OutputRef){'SameEndpoint'}else{'DifferentEndpoint'}}elseif($Probe.endpointName -and $Probe.endpointName -eq $OutputName){'SameName'}else{'Unknown'}
    $text='ノイズが出ないことを確認済みの出力（HDMIや別の機器など）へ切り替えてから聞き直してください。'+"`r`n`r`n"
    $text+='録音時の出力：'+$Probe.endpointName+"`r`n"+'聞き直す出力：'+$OutputName+"`r`n`r`n"
    if($relation -in @('SameEndpoint','SameName')){$text+='録音時と同じ出力が選ばれています。この出力が再生時に加えるノイズと、ファイルに入ったノイズを区別できない可能性があります。'}
    else{$text+='選んだ出力が正常かどうかをアプリは自動判定していません。再生時に加わるノイズが、ファイル内の音と混ざる可能性があります。'}
    $text+="`r`n`r`n"+'出力を変更する場合は「出力を変更するため戻る」、この出力で聞く場合は「この出力で再生する」を選んでください。'
    [pscustomobject]@{relation=$relation;text=$text;outputName=$OutputName;outputRef=$OutputRef}
}
function Confirm-PlaybackReview {
    param($Notice)
    if($SmokeTest){return ($script:reviewPromptChoice -ne 'ChangeOutput')}
    $dialog=New-Object Windows.Forms.Form;$dialog.Text='聞き直す出力を確認してください';$dialog.Size=New-Object Drawing.Size(720,440);$dialog.StartPosition='CenterParent';$dialog.Font=$form.Font
    $message=New-Object Windows.Forms.TextBox;$message.Multiline=$true;$message.ReadOnly=$true;$message.ScrollBars='Vertical';$message.Dock='Fill';$message.Text=$Notice.text
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Bottom';$actions.Height=58
    $back=New-UiButton '出力を変更するため戻る';$back.DialogResult='Cancel';$play=New-UiButton 'この出力で再生する';$play.DialogResult='OK'
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($back,$play));$dialog.Controls.Add($message);$dialog.Controls.Add($actions);$dialog.AcceptButton=$back;$dialog.CancelButton=$back
    try{return ($dialog.ShowDialog($form) -eq 'OK')}finally{$dialog.Dispose()}
}
