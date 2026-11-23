# The launcher and elevated recorder share one ID and directory before starting.
# A stop request is not proof that WPR has stopped or that an ETL was saved.
function New-TraceRun {
    param([string]$SessionDirectory,[string]$SessionId,[switch]$IncludeUsb,$Link=$null)
    if($SessionId -notmatch '^[a-fA-F0-9]{32}$'){throw 'Invalid session ID'}
    $id=[guid]::NewGuid().ToString('N');$point=Get-ClockPoint
    $directory=Join-Path (Join-Path $SessionDirectory 'traces') $id
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $run=[pscustomobject]@{id=$id;sessionId=$SessionId;directory=$directory;requested=$point;stopRequested=$false;stopPoint=$null;state=$null;phase='Launching';busy=$true;processExitCode=$null;terminalHandled=$false}
    $state=[pscustomobject]@{id=$id;sessionId=$SessionId;instanceName=('AudioNoise-'+$id);status='Launching';includeUsb=[bool]$IncludeUsb;link=$Link;requestedSeconds=60;requested=$point;updated=$point;started=$null;stopping=$null;ended=$null;bytes=0;sha256=$null;errorType=$null}
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
function Read-TraceRunState {
    param($Run)
    $path=Join-Path $Run.directory 'trace.json'
    if(-not (Test-Path -LiteralPath $path)){return $null}
    if((Get-Item -LiteralPath $path).Length -gt 16MB){throw 'Trace state exceeds its limit'}
    $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($state.id -ne $Run.id -or $state.sessionId -ne $Run.sessionId){throw 'Trace state belongs to another run'}
    return $state
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
        'Recording' {
            $phase='Recording';$elapsed=Get-TraceAgeSeconds $State.started $Now
            $text='WPR追加取得中：'+$elapsed+'秒 / 最大'+$State.requestedSeconds+'秒。停止ボタンで早めに保存できます。'
            $indeterminate=$false
            if((Get-TraceAgeSeconds $State.updated $Now) -ge 15){$phase='NoStateUpdate';$text='WPRの状態更新が止まっています。停止・保存の完了は未確認です。保存先のtrace.jsonとインスタンス名を確認してください。';$canOpen=$true}
        }
        'Stopping' {
            $phase='Saving';$canStop=$false;$elapsed=Get-TraceAgeSeconds $State.stopping $Now
            $text='WPR側が停止処理に入り、ETLを保存しています（'+$elapsed+'秒経過）。保存完了はまだ未確認です。'
            if($elapsed -ge 120){$phase='SaveDelayed';$text='WPRの保存完了の応答がありません（'+$elapsed+'秒経過）。完了とは扱いません。保存先の状態とインスタンス名を確認してください。';$canOpen=$true}
        }
        'Completed' {
            $path=Join-Path $Run.directory 'trace.etl'
            if((Test-Path -LiteralPath $path -PathType Leaf) -and $State.bytes -gt 0 -and (Get-Item -LiteralPath $path).Length -eq $State.bytes -and $State.sha256 -match '^[a-fA-F0-9]{64}$' -and (-not $State.usb.requested -or ($State.usb.status -eq 'Completed' -and (Test-Path -LiteralPath (Join-Path $Run.directory 'usb.etl')) -and $State.usb.bytes -gt 0 -and $State.usb.sha256 -match '^[a-fA-F0-9]{64}$' -and (Get-Item -LiteralPath (Join-Path $Run.directory 'usb.etl')).Length -eq $State.usb.bytes))){
                $phase='Completed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
                $text='WPRの停止・保存が完了しました（'+[Math]::Round($State.bytes/1MB,1)+' MB）。「WPRの保存先を開く」でtrace.etlを確認できます。'
            }else{$phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false;$text='保存完了の記録とETLファイルが一致しません。保存先を開いて確認してください。'}
        }
        'Cancelled' {$phase='Cancelled';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false;$text='WPRの開始前に停止しました。ETLは作成していません。'}
        {$_ -in @('Failed','StopFailed','LaunchFailed','HelperExited')} {
            $phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
            $text='WPRの取得・停止・保存を完了できませんでした（状態：'+$status+' / 開始コード：'+$State.startExitCode+' / 保存コード：'+$State.stopExitCode+' / '+$State.errorType+'）。保存先のtrace.jsonを確認してください。'
            if($State.errorType -eq 'AdminApprovalCancelled'){$text='管理者権限の確認がキャンセルされたため、WPRは開始していません。必要なら再度開始してください。'}
        }
    }
    if($busy -and $ProcessState -eq 'Exited'){
        $phase='Failed';$busy=$false;$canStop=$false;$canOpen=$true;$indeterminate=$false
        $text='WPR用プロセスが保存完了を記録せず終了しました（終了コード：'+$Run.processExitCode+'）。停止・保存は未確認です。保存先の状態を確認してください。'
    }elseif($busy -and $Run.stopRequested -and $status -ne 'Stopping'){
        $phase='StopRequested';$elapsed=Get-TraceAgeSeconds $Run.stopPoint $Now
        $text='停止要求を送りました。WPR側の受付を待っています（'+$elapsed+'秒経過）。停止・保存の完了はまだ未確認です。';$canStop=$false
        if($elapsed -ge 15){$phase='StopUnconfirmed';$text='停止要求後もWPR側の状態が変わりません（'+$elapsed+'秒経過）。停止・保存は未確認です。保存先のtrace.jsonを確認してください。';$canOpen=$true}
    }elseif($busy -and $phase -eq 'Launching' -and $age -ge 15){
        $text='WPRの開始結果を待っています（'+$age+'秒経過）。管理者権限の確認、または保存先の状態を確認してください。';$canOpen=$true
    }
    if($State.usb.requested -or $State.includeUsb){$text='USB＋Audio：'+$text}
    if($ReadError -and $busy){$text+=' 状態ファイルを読めないため再確認中です。';$canOpen=$true}
    [pscustomobject]@{phase=$phase;busy=$busy;canStop=$canStop;canOpen=$canOpen;text=$text;indeterminate=$indeterminate}
}
