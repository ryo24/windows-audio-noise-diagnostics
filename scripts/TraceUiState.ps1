# The launcher and elevated recorder share one ID and directory before starting.
# A stop request is not proof that WPR has stopped or that an ETL was saved.
function New-TraceRun {
    param([string]$SessionDirectory,[string]$SessionId,[switch]$IncludeUsb,$Link=$null,[switch]$RequireCaptureAck,[int]$CaptureSeconds=60)
    if($SessionId -notmatch '^[a-fA-F0-9]{32}$'){throw 'Invalid session ID'}
    $id=[guid]::NewGuid().ToString('N');$point=Get-ClockPoint
    $directory=Join-Path (Join-Path $SessionDirectory 'traces') $id
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $run=[pscustomobject]@{id=$id;sessionId=$SessionId;directory=$directory;requested=$point;stopRequested=$false;stopPoint=$null;state=$null;phase='Launching';busy=$true;processExitCode=$null;terminalHandled=$false}
    $state=[pscustomobject]@{id=$id;sessionId=$SessionId;instanceName=('AudioNoise-'+$id);status='Launching';includeUsb=[bool]$IncludeUsb;requireCaptureAck=[bool]$RequireCaptureAck;link=$Link;requestedSeconds=$CaptureSeconds;requested=$point;updated=$point;started=$null;stopping=$null;ended=$null;bytes=0;sha256=$null;errorType=$null}
    Write-AtomicText (Join-Path $directory 'trace.json') ($state|ConvertTo-Json -Depth 8)
    $run.state=$state
    return $run
}
function Send-TraceStopRequest {
    param($Run)
    if(-not $Run -or -not $Run.busy -or $Run.stopRequested){return}
    [IO.Directory]::CreateDirectory($Run.directory)|Out-Null
    $point=Get-ClockPoint
    Write-AtomicText (Join-Path $Run.directory 'stop.request') (([pscustomobject]@{traceId=$Run.id;requested=$point})|ConvertTo-Json -Depth 4)
    $Run.stopRequested=$true;$Run.stopPoint=$point
}
function Confirm-TraceCaptureStarted {
    param($Run,$Test,$Probe,$Point)
    if(-not $Run.state.requireCaptureAck){return}
    $ready=$Run.state.captureHandshake
    if($ready.status -ne 'Waiting' -or $Run.stopRequested -or
        $Run.state.link.testId -ne $Test.id -or $Run.state.link.probeId -ne $Probe.id){
        throw 'USB＋Audioの録音開始を確認できませんでした。'
    }
    $ack=[pscustomobject]@{traceId=$Run.id;testId=$Test.id;probeId=$Probe.id;readyQpc=$ready.ready.qpc;point=$Point}
    Write-AtomicText (Join-Path $Run.directory 'capture-started.json') ($ack|ConvertTo-Json -Depth 4)
}
function Read-TraceCaptureAck {
    param([string]$Path,$State,$Now)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return}
    if((Get-Item -LiteralPath $Path).Length -gt 4096){throw 'Oversize capture acknowledgement'}
    $ack=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not $Now){$Now=Get-ClockPoint}
    $ready=$State.captureHandshake.ready
    if($ack.traceId -ne $State.id -or $ack.testId -ne $State.link.testId -or
        $ack.probeId -ne $State.link.probeId -or $ack.readyQpc -ne $ready.qpc -or
        $ack.point.frequency -ne $ready.frequency -or $ack.point.qpc -lt $ready.qpc -or
        $ack.point.qpc -gt $Now.qpc -or
        $ack.point.qpc -gt ($ready.qpc+$State.captureHandshake.timeoutSeconds*$ready.frequency)){
        throw 'Invalid capture acknowledgement'
    }
    return $ack.point
}
function Read-TraceRunState {
    param($Run)
    $record=Read-TraceStateRecord $Run.directory -TraceId $Run.id -SessionId $Run.sessionId
    return $record.state
}
function Get-TraceAgeSeconds {
    param($Point,$Now=(Get-ClockPoint))
    if(-not $Point -or -not $Point.frequency){return 0}
    [Math]::Max(0,[Math]::Floor(([double]$Now.qpc-[double]$Point.qpc)/$Point.frequency))
}
function Get-TracePresentation {
    param($Run,$State,[ValidateSet('Running','Exited','Unknown')][string]$ProcessState='Unknown',$Now=(Get-ClockPoint),[string]$ReadError='')
    $phase='Launching';$busy=$true;$canStop=(-not $Run.stopRequested);$canOpen=$false
    $text='WPRを開始しています。管理者権限の確認・開始結果を待っています。';$indeterminate=$true
    $age=Get-TraceAgeSeconds $Run.requested $Now
    $status=if($State){$State.status}else{''}
    switch($status){
        'Starting' {
            $phase='Starting'
            $stage=switch($State.startupStage){
                'Usb' {'USBトレースを開始しています。'}
                'Audio' {'Audioトレースを開始しています。'}
                default {'管理者側の準備を確認しています。'}
            }
            $elapsed=Get-TraceAgeSeconds $State.started $Now
            $text=$stage+' テスト音はまだ鳴りません（'+$elapsed+'秒）。'
            if((Get-TraceAgeSeconds $State.updated $Now) -ge 15){$text+=' 開始状況の更新を待っています。';$canOpen=$true}
        }
        'AwaitingCapture' {
            $phase='AwaitingCapture'
            $elapsed=Get-TraceAgeSeconds $State.captureHandshake.ready $Now
            $text='USBとAudioを開始しました。テスト音と内部録音の開始を確認しています（'+$elapsed+'秒）。'
        }
        'Recording' {
            $phase='Recording';$recordingPoint=if($State.captureHandshake.acknowledged){$State.captureHandshake.acknowledged}else{$State.started};$elapsed=Get-TraceAgeSeconds $recordingPoint $Now
            $text='WPR追加取得中：'+$elapsed+'秒 / 最大'+$State.requestedSeconds+'秒。停止ボタンで早めに保存できます。'
            $indeterminate=$false
            if((Get-TraceAgeSeconds $State.updated $Now) -ge 15){$phase='NoStateUpdate';$text='WPRの状態更新が止まっています。停止・保存の完了は未確認です。保存先のtrace.jsonとインスタンス名を確認してください。';$canOpen=$true}
        }
        'Stopping' {
            $phase='Saving';$canStop=$false;$elapsed=Get-TraceAgeSeconds $State.stopping $Now
            $text='WPR側が停止処理に入り、ETLを保存しています（'+$elapsed+'秒経過）。保存完了はまだ未確認です。'
            if($elapsed -ge 120){$phase='SaveDelayed';$text='WPRの保存完了の応答がありません（'+$elapsed+'秒経過）。完了とは扱いません。保存先の状態とインスタンス名を確認してください。';$canOpen=$true}
        }
        'Inspecting' {
            $phase='Inspecting';$canStop=$false;$canOpen=$true
            $elapsed=Get-TraceAgeSeconds $State.inspectionStarted $Now
            $stage=if($State.investigation.phase -eq 'ValidateUsb'){'保存済みETLのUSBイベントを検査しています。'}else{'ETLを保存しました。機器・設定などの追加情報を取得しています。'}
            $text=$stage+'（'+$elapsed+'秒）'
        }
        'Completed' {
            $path=Join-Path $Run.directory 'trace.etl'
            if((Test-Path -LiteralPath $path -PathType Leaf) -and $State.bytes -gt 0 -and (Get-Item -LiteralPath $path).Length -eq $State.bytes -and $State.sha256 -match '^[a-fA-F0-9]{64}$' -and (-not $State.usb.requested -or ($State.usb.status -eq 'Completed' -and (Test-Path -LiteralPath (Join-Path $Run.directory 'usb.etl')) -and $State.usb.bytes -gt 0 -and $State.usb.sha256 -match '^[a-fA-F0-9]{64}$' -and (Get-Item -LiteralPath (Join-Path $Run.directory 'usb.etl')).Length -eq $State.usb.bytes))){
                $phase='Completed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
                $text='WPRの停止・保存が完了しました（'+[Math]::Round($State.bytes/1MB,1)+' MB）。「WPRの保存先を開く」でtrace.etlを確認できます。'
            }else{$phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false;$text='保存完了の記録とETLファイルが一致しません。保存先を開いて確認してください。'}
        }
        'Cancelled' {$phase='Cancelled';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false;$text='トレース準備中に終了しました。保存結果は「USB・Audio取得結果」で確認できます。'}
        {$_ -in @('Failed','StopFailed','LaunchFailed','HelperExited')} {
            $phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
            $text='WPRの取得・停止・保存を完了できませんでした（状態：'+$status+' / 開始コード：'+$State.startExitCode+' / 保存コード：'+$State.stopExitCode+' / '+$State.errorType+'）。保存先のtrace.jsonを確認してください。'
            if($State.stopReason -eq 'CaptureAckTimeout'){$text='USBとAudioは開始しましたが、内部録音の開始確認が届かなかったため終了しました。保存できたETLは取得結果で確認できます。'}
            if($State.errorType -eq 'AdminApprovalCancelled'){$text='管理者権限の確認がキャンセルされたため、WPRは開始していません。必要なら再度開始してください。'}
        }
    }
    if($busy -and $ProcessState -eq 'Exited'){
        $phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
        $text='WPR用プロセスが保存完了を記録せず終了しました（終了コード：'+$Run.processExitCode+'）。停止・保存は未確認です。保存先の状態を確認してください。'
    }elseif($busy -and $Run.stopRequested -and $status -notin @('Stopping','Inspecting')){
        $phase='StopRequested';$elapsed=Get-TraceAgeSeconds $Run.stopPoint $Now
        $text='停止要求を送りました。WPR側の受付を待っています（'+$elapsed+'秒経過）。停止・保存の完了はまだ未確認です。';$canStop=$false
        if($elapsed -ge 15){$phase='StopUnconfirmed';$text='停止要求後もWPR側の状態が変わりません（'+$elapsed+'秒経過）。停止・保存は未確認です。保存先のtrace.jsonを確認してください。';$canOpen=$true}
    }elseif($busy -and $phase -eq 'Launching' -and $age -ge 15){
        $text='WPRの開始結果を待っています（'+$age+'秒経過）。管理者権限の確認、または保存先の状態を確認してください。';$canOpen=$true
    }
    if($State.usb.requested -or $State.includeUsb){$text='USB＋Audio：'+$text}
    if($State.stateWrites.recoveryWrites -and $State.stateWrites.writeFailures){
        $text+=if($busy){' 状態ファイルの競合を検出し、代替ファイルへ記録しています。'}else{' 状態ファイルが使用中だったため、代替保存を使いました。'}
    }
    if($ReadError -and $busy){$text+=' 状態ファイルを読めないため再確認中です。';$canOpen=$true}
    [pscustomobject]@{phase=$phase;busy=$busy;canStop=$canStop;canOpen=$canOpen;text=$text;indeterminate=$indeterminate}
}
