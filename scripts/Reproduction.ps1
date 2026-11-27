function Get-ClockPoint {
    [pscustomobject]@{ utc=[DateTime]::UtcNow.ToString('o'); qpc=[Diagnostics.Stopwatch]::GetTimestamp(); frequency=[Diagnostics.Stopwatch]::Frequency }
}
function Add-TimelineEvent {
    param($Session,[string]$Kind,[string]$TestId='',[string]$ProbeId='',[string]$Note='')
    if(-not $Session.PSObject.Properties['timeline']){$Session|Add-Member -NotePropertyName timeline -NotePropertyValue @()}
    $point=Get-ClockPoint
    $entry=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');kind=$Kind;testId=$TestId;probeId=$ProbeId;utc=$point.utc;qpc=$point.qpc;frequency=$point.frequency;note=$Note}
    $Session.timeline=@($Session.timeline)+@($entry)
    return $entry
}
function Update-TestDuration {
    param($Test,$Point=(Get-ClockPoint))
    if($Test.endedUtc){return}
    if($Test.timing -and $Test.timing.start){
        $seconds=([double]$Point.qpc-[double]$Test.timing.start.qpc)/$Point.frequency
        $Test.durationSeconds=[Math]::Round([Math]::Max(0,$seconds),3)
    }
}
function Complete-TestTiming {
    param($Test,$Point=(Get-ClockPoint))
    Update-TestDuration $Test $Point
    $Test.endedUtc=$Point.utc
    if($Test.timing){
        $Test.timing.end=$Point
        $wall=([DateTime]::Parse($Point.utc)-[DateTime]::Parse($Test.startedUtc)).TotalSeconds
        $Test.timing.wallSeconds=[Math]::Round($wall,3)
        $Test.timing.clockDifferenceSeconds=[Math]::Round($wall-$Test.durationSeconds,3)
    }
}
function Get-PlaybackSnapshot {
    param([string]$Salt,[string]$SelectedEndpointId='')
    Initialize-AudioInterop
    $point=Get-ClockPoint
    $defaultId=$null;try{$defaultId=[AudioNoiseDiagnostics.Endpoint]::Read().Id}catch{}
    $outputs=@(foreach($endpoint in [AudioNoiseDiagnostics.AudioFiles]::Endpoints()){
        $ref=Get-AnonymousDeviceRef ('SWD\MMDEVAPI\'+$endpoint.Id) $Salt
        [pscustomobject]@{endpointRef=$ref;name=$endpoint.Name;isDefaultMultimedia=($endpoint.Id -eq $defaultId);isSelectedForProbe=($endpoint.Id -eq $SelectedEndpointId);sessions=Invoke-CollectionSection {
            @([AudioNoiseDiagnostics.PlaybackEvidence]::Read($endpoint.Id)|ForEach-Object{[pscustomobject]@{processId=$_.ProcessId;processName=$_.ProcessName;multipleProcesses=$_.MultipleProcesses;state=$_.Status}})
        }}
    })
    [pscustomobject]@{point=$point;outputs=$outputs;scope='全アクティブ出力のWindows共有セッションを取得。Activeは可聴音・独占モード・アプリ内の素材を保証しません。endpointRefは同じセッションのaudioDevices.devices.refと照合します。'}
}
function Get-ReproductionContext {
    param([string]$Salt)
    [pscustomobject]@{
        point=Get-ClockPoint
        playback=Invoke-CollectionSection {Get-PlaybackSnapshot $Salt}
        audioDevices=Invoke-CollectionSection {Get-AudioDeviceInventory $Salt}
        boot=Invoke-CollectionSection {
            $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop
            [pscustomobject]@{lastBootUtc=$os.LastBootUpTime.ToUniversalTime().ToString('o');uptimeSeconds=[Math]::Round([AudioNoiseDiagnostics.PlaybackEvidence]::GetTickCount64()/1000.0,3)}
        }
        lastResume=Invoke-CollectionSection {
            try{$event=Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Power-Troubleshooter';Id=1} -MaxEvents 1 -ErrorAction Stop
                [pscustomobject]@{status='found';timeUtc=$event.TimeCreated.ToUniversalTime().ToString('o');note='復帰イベントの記録時刻。復帰の厳密な開始時刻とは限りません。'}
            }catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){[pscustomobject]@{status='noMatchingEvent';timeUtc=$null}}else{throw}}
        }
        cpuLoad=Invoke-CollectionSection {@(Get-CimInstance Win32_Processor -OperationTimeoutSec 10 -ErrorAction Stop|ForEach-Object{[pscustomobject]@{loadPercentage=$_.LoadPercentage}})}
        scope='この取得区間の構成。開始瞬間と同時とは限りません。CPU負荷は粗いスナップショットでDPC/ISR測定ではありません。'
    }
}
function Get-ReproductionReportHtml {
    param($Session)
    $content=@(foreach($test in @($Session.tests)){
        if($test.context -or $test.playbackSnapshots -or $test.conditions -or $test.timing){
            $value=[pscustomobject]@{testId=$test.id;capturePlan=$test.capturePlan;conditions=$test.conditions;timing=$test.timing;context=$test.context;playbackSnapshots=$test.playbackSnapshots}
            '<details><summary>再現時の再生経路・ドライバー・時刻: '+(ConvertTo-HtmlText $test.id)+'</summary><pre>'+(ConvertTo-HtmlText ($value|ConvertTo-Json -Depth 18))+'</pre></details>'
        }
    }) -join "`n"
    if(-not $content){return ''}
    '<h2>再現区間の構成と時間軸</h2><p>durationSecondsはv0.6以降、同一起動中のQPCによる経過時間。UTCの差との不一致も保存します。音声WAVの開始・スマートフォンの時計との自動同期ではありません。既定出力とアクティブセッション、手動申告、選択した録音出力を区別します。</p>'+$content
}
function Get-TraceReportHtml {
    param([string]$SessionDirectory)
    $root=Join-Path $SessionDirectory 'traces'
    if(-not (Test-Path -LiteralPath $root)){return ''}
    $rows=@(foreach($directory in Get-ChildItem -LiteralPath $root -Directory){
        if($directory.Name -notmatch '^[a-fA-F0-9]{32}$'){continue}
        try{$record=Read-TraceStateRecord $directory.FullName -SessionDirectory $SessionDirectory}
        catch{$record=$null}
        if($record){
            $summary=$record.state|ConvertTo-Json -Depth 12
            '<details><summary>詳細トレース '+$directory.Name+'</summary><pre>'+(ConvertTo-HtmlText $summary)+'</pre></details>'
        }
    }) -join "`n"
    '<h2>詳細トレースの取得結果</h2><p>ETLはtraces配下です。WPA等で解析してください。取得失敗・イベント欠落は正常の証明にはなりません。</p>'+$rows
}
