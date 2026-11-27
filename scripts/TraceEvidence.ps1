function Get-TraceStatusLabel {
    param([string]$Status)
    $labels=@{Saved='保存確認済み';NotSelected='未選択';NotStarted='開始なし';AdminCancelled='管理者確認キャンセル';MissingTraceId='取得IDなし';MissingState='状態記録なし';InvalidState='対応不一致';MissingOrMismatched='実ファイル不足・不一致';StartFailed='開始失敗';SaveFailed='保存失敗';Failed='取得失敗';Completed='完了';Cancelled='開始前に中止';LaunchFailed='起動失敗';Recording='取得中';Starting='開始中';Stopping='保存中'}
    if($labels.ContainsKey($Status)){return $labels[$Status]+' ['+$Status+']'}
    return $Status
}
function Get-TraceArtifactEvidence {
    param([string]$Directory,[string]$Name,$Recorded,[bool]$Requested)
    $path=Join-Path $Directory ($Name+'.etl');$exists=Test-Path -LiteralPath $path -PathType Leaf
    $bytes=if($exists){(Get-Item -LiteralPath $path).Length}else{0}
    $status=if(-not $Requested){'NotSelected'}elseif($Recorded.status -eq 'Completed' -and $bytes -gt 0 -and $Recorded.bytes -eq $bytes -and $Recorded.sha256 -match '^[a-fA-F0-9]{64}$'){'Saved'}elseif($Recorded.errorType -eq 'AdminApprovalCancelled'){'AdminCancelled'}elseif($Recorded.status -eq 'Completed'){'MissingOrMismatched'}elseif($Recorded.status -eq 'StopFailed'){'SaveFailed'}elseif($Recorded.status -eq 'StartFailed' -or ($null -ne $Recorded.startExitCode -and $Recorded.startExitCode -ne 0)){'StartFailed'}elseif($Recorded.status -eq 'Failed'){'Failed'}elseif($Recorded.status){$Recorded.status}else{'NotStarted'}
    [pscustomobject]@{status=$status;exists=[bool]$exists;bytes=$bytes;recordedBytes=$Recorded.bytes;startExitCode=$Recorded.startExitCode;stopExitCode=$Recorded.stopExitCode;errorType=$Recorded.errorType;sha256=$Recorded.sha256;validation='Existence, size and recorded hash format. Bundle export verifies file hashes.'}
}
function Get-SessionTraceEvidence {
    param($Session,[string]$Directory)
    @(foreach($test in @($Session.tests)){
        $requested=$test.followUp.kind -eq 'UsbTransfer';$id=[string]$test.followUp.traceId;$state=$null;$problem=$null
        $traceDirectory=Join-Path $Directory 'traces'
        if($id -match '^[a-fA-F0-9]{32}$'){
            $traceDirectory=Join-Path $traceDirectory $id;$path=Join-Path $traceDirectory 'trace.json'
            if(Test-Path -LiteralPath $path){
                try{
                    Assert-RegularBundleFile $Directory $path
                    if((Get-Item $path).Length -gt 16MB){throw 'Oversize trace state'}
                    $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
                    if($state.id -ne $id -or $state.sessionId -ne $Session.id -or $state.link.testId -ne $test.id -or $state.link.probeId -ne $test.followUp.probeId){throw 'Trace/test identity mismatch'}
                }catch{$state=$null;$problem='InvalidState'}
            }else{$problem='MissingState'}
        }elseif($requested){$problem='MissingTraceId'}
        $usb=Get-TraceArtifactEvidence $traceDirectory 'usb' $state.usb $requested
        $audioState=if($state){[pscustomobject]@{status=if($state.audioStatus){$state.audioStatus}else{$state.status};bytes=$state.bytes;sha256=$state.sha256;startExitCode=$state.startExitCode;stopExitCode=$state.stopExitCode;errorType=$state.errorType}}else{$null}
        $audio=Get-TraceArtifactEvidence $traceDirectory 'trace' $audioState $requested
        if($state.errorType -eq 'AdminApprovalCancelled'){$usb.status='AdminCancelled';$audio.status='AdminCancelled'}
        if($problem){$usb.status=$problem;$audio.status=$problem}
        $probe=@($Session.audioProbes|Where-Object {$_.testId -eq $test.id}|Select-Object -Last 1)
        $coverage=if($state -and $probe.Count){Get-FollowUpCoverage $state $probe[0] $test}else{[pscustomobject]@{status='unavailable'}}
        [pscustomobject]@{testId=$test.id;traceId=$id;probeId=$test.followUp.probeId;usbRequested=$requested;state=if($state){$state.status}elseif($requested){$problem}else{'NotSelected'};usb=$usb;audioTrace=$audio;captureHandshake=$state.captureHandshake;stopReason=$state.stopReason;recordingStatus=if($probe.Count){$probe[0].status}else{'NotStarted'};coverage=$coverage;targetStatus=$state.target.status;endpointRef=$state.link.endpointRef;targetMissing=@($state.target.missing);investigationPhase=$state.investigation.phase;investigationCoverage=$state.investigation.coverage;usbValidation=$state.investigation.usbValidation;nativeFailures=@($state.commands|Where-Object {$_ -and $_.exitCode -ne 0});scope='Saved means a matching file exists, not that events prove correct operation. ETL inclusion is a separate export choice.'}
    })
}
function Get-TraceEvidenceText {
    param($Rows)
    (@(foreach($row in @($Rows|Where-Object {$_})){
        '試験 '+$row.testId.Substring(0,[Math]::Min(8,$row.testId.Length))+' / USB取得：'+$(if($row.usbRequested){'選択済み'}else{'未選択'})+' / traceId：'+$(if($row.traceId){$row.traceId}else{'なし'})
        'USB：'+(Get-TraceStatusLabel $row.usb.status)+' / usb.etl '+$row.usb.bytes+' bytes ／ Audioトレース：'+(Get-TraceStatusLabel $row.audioTrace.status)+' / trace.etl '+$row.audioTrace.bytes+' bytes ／ 内部録音：'+$row.recordingStatus
        if($row.captureHandshake -and $row.captureHandshake.status -ne 'NotRequired'){
            'トレースと録音の開始確認：'+$row.captureHandshake.status+' ／ 終了理由：'+$row.stopReason
        }
        '追加調査：'+$(if($row.investigationCoverage){$row.investigationPhase+' / 未取得項目 '+@($row.investigationCoverage.unavailableSections|Where-Object {$_}).Count+' / 定期取得 '+$row.investigationCoverage.sampleCount+'回、CPU失敗 '+$row.investigationCoverage.cpuSampleFailures+'回・音声失敗 '+$row.investigationCoverage.audioSampleFailures+'回'}elseif($row.investigationPhase){$row.investigationPhase+'（充足確認は未完了）'}else{'未実施・旧版では対象外'})+' ／ USBイベント検査：'+$(if($row.usbValidation){$row.usbValidation.status+' / '+$row.usbValidation.usbEventsInSample+'件（走査範囲内） / 対象対応 '+$row.usbValidation.targetSelectionStatus}else{'未実施'})
        if(@($row.nativeFailures|Where-Object {$_}).Count){$nativeError=@($row.nativeFailures)[0];'取得エラー：'+$nativeError.executable+' '+$nativeError.exitHex+' '+(Protect-InvestigationText ($nativeError.stdout+' '+$nativeError.stderr) '' 600)}
        '重複時間：'+$(if($row.coverage.status -eq 'calculated'){[string]$row.coverage.overlapSeconds+'秒（USB×内部録音）、Audio×内部録音 '+$row.coverage.audioTraceOverlapSeconds+'秒、三者 '+$row.coverage.usbAudioRecordingOverlapSeconds+'秒、試験×USB '+$row.coverage.testUsbOverlapSeconds+'秒'}else{'未確定・未取得'})+' ／ 出力との関連：'+$(if($row.targetStatus){$row.targetStatus}else{'未取得'})
    })) -join "`r`n"
}
