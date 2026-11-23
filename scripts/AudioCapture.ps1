function Initialize-AudioInterop {
    if (-not ('AudioNoiseDiagnostics.AudioProbe' -as [type])) {
        Add-Type -Path @((Join-Path $PSScriptRoot 'AudioEndpoint.cs'),(Join-Path $PSScriptRoot 'AudioProbe.cs')) -ErrorAction Stop
    }
}

function Resolve-AudioFile {
    param([string]$SessionDirectory,[string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or [IO.Path]::GetExtension($RelativePath) -ne '.wav') { throw '音声ファイルの相対パスが正しくありません。' }
    $root=[IO.Path]::GetFullPath($SessionDirectory).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'セッション外の音声ファイルにはアクセスしません。' }
    return $path
}

function New-AudioProbeRecord {
    param([string]$Mode,[string]$EndpointName,[string]$TestId,[int]$MaximumSeconds)
    $id=[guid]::NewGuid().ToString('N')
    [pscustomobject]@{
        id=$id;testId=$TestId;mode=$Mode;endpointName=$EndpointName;tool=Get-ToolIdentity;createdUtc=[DateTime]::UtcNow.ToString('o')
        status='Starting';maximumSeconds=$MaximumSeconds;capture=$null;noiseMarkersUtc=@()
        files=[pscustomobject]@{recording=('audio/'+$id+'/loopback.wav');reference=if($Mode -eq 'Reference'){'audio/'+$id+'/reference.wav'}else{$null};recordingSha256=$null;referenceSha256=$null}
        verification=[pscustomobject]@{liveNoise='Unknown';replayNoise='Unreviewed';resemblance='Unreviewed';reviewEndpointName=$null;reviewPlaybackCompleted=$false;reviewPlayedSeconds=0;reviewStartedUtc=$null;referencePlayed=$false;notes=''}
        referenceId=if($Mode -eq 'Reference'){'audio-noise-reference-v1-10s-48000hz-stereo-pcm16-peak0.08'}else{$null}
        scope='選択したWindows出力全体のWASAPIループバック。アナログ回路以降の混入音を保証して収録するものではありません。'
    }
}

function Complete-AudioProbeRecord {
    param($Record,$Recorder,[string]$SessionDirectory)
    $Record.status=$Recorder.Status
    $Record.capture=[pscustomobject]@{
        startedUtc=$Recorder.StartedUtc;endedUtc=$Recorder.EndedUtc;elapsedSeconds=$Recorder.ElapsedSeconds
        sampleRate=$Recorder.SampleRate;channels=$Recorder.Channels;containerBits=$Recorder.Bits
        capturedFrames=$Recorder.CapturedFrames;writtenFrames=$Recorder.WrittenFrames;insertedSilenceFrames=$Recorder.InsertedSilenceFrames
        packetCount=$Recorder.PacketCount;discontinuities=$Recorder.Discontinuities;timestampErrors=$Recorder.TimestampErrors;packetFlags=@($Recorder.FlagEvents)
        flagEventsTruncated=($Recorder.Discontinuities+$Recorder.TimestampErrors -gt 1000);sizeLimitReached=$Recorder.SizeLimitReached
        referenceStartOffsetSeconds=$Recorder.ReferenceStartOffsetSeconds;errorCode=$Recorder.ErrorCode
        note='取得できない間隔には時刻合わせの無音を補います。補った無音と不連続フラグは可聴ノイズの自動判定ではありません。最初のパケットの不連続には開始遷移も含まれます。'
    }
    foreach ($kind in @('recording','reference')) {
        $relative=$Record.files.$kind
        if ($relative) {
            $path=Resolve-AudioFile $SessionDirectory $relative
            if (Test-Path -LiteralPath $path) { $Record.files.($kind+'Sha256')=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
    }
}

function Import-SessionAudio {
    param($Session,[string]$SourceDirectory,[string]$TargetDirectory)
    foreach ($record in @($Session.audioProbes)) {
        foreach ($kind in @('recording','reference')) {
            $relative=$record.files.$kind
            if (-not $relative) { continue }
            $source=Resolve-AudioFile $SourceDirectory $relative
            $target=Resolve-AudioFile $TargetDirectory $relative
            if ($source -eq $target -or -not (Test-Path -LiteralPath $source)) { continue }
            $expected=$record.files.($kind+'Sha256')
            if ($expected -and (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $expected) { throw '音声ファイルが記録されたハッシュと一致しません。原本を確認してください。' }
            if (Test-Path -LiteralPath $target) {
                if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $source).Hash) { throw 'コピー先に異なる音声ファイルがあります。上書きせず停止しました。' }
            } else { [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null;Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop }
        }
    }
}

function Get-AudioReportHtml {
    param($Session)
    if(@($Session.audioProbes | Where-Object {$null -ne $_}).Count -eq 0){return ''}
    $sections=New-Object 'System.Collections.Generic.List[string]'
    foreach($record in @($Session.audioProbes)){
        $review=$record.verification
        $finding='録音の聞き直し・実際の出力との照合は未完了です。'
        if($record.status -in @('Failed','Interrupted','NoAudioData')){$finding='録音失敗・中断または取得データ不足です。この録音を使ってノイズなしとは判定できません。'}
        elseif($review.reviewPlaybackCompleted){
            if($review.liveNoise -eq 'Yes' -and $review.replayNoise -eq 'No'){$finding='実際の出力ではノイズあり、録音の再生ではなしとの観察です。アナログ回路以降の混入、録音経路の違い、取得の限界などを確認します。PCが正常という判定にはしません。'}
            elseif($review.replayNoise -eq 'Yes'){$finding='保存音声の再生でもノイズありとの観察です。再生する出力側が新たにノイズを加える可能性もあります。元のテスト音との比較や、HDMI・別PCなど既知の正常な経路で再確認してください。'}
            else{$finding='聞き直しは完了していますが、無発生だけで故障や間欠ノイズを否定するものではありません。'}
        }
        $links=New-Object 'System.Collections.Generic.List[string]'
        foreach($kind in @('recording','reference')){$relative=$record.files.$kind;if($relative -match '^audio/[a-fA-F0-9]{32}/(loopback|reference)\.wav$'){$links.Add('<a href="'+$relative+'">'+$kind+' WAV</a>')}}
        $summary=[pscustomobject]@{status=$record.status;mode=$record.mode;captureOutput=$record.endpointName;verification=$record.verification;capture=$record.capture;noiseMarkersUtc=$record.noiseMarkersUtc;files=$record.files;tool=$record.tool}
        $sections.Add('<article><h3>録音 '+(ConvertTo-HtmlText $record.id)+'</h3><p>'+(ConvertTo-HtmlText $finding)+'</p><p>'+($links -join ' ／ ')+'</p><details><summary>録音・照合の詳細</summary><pre>'+(ConvertTo-HtmlText ($summary | ConvertTo-Json -Depth 12))+'</pre></details></article>')
    }
    return '<h2>テスト音声・ループバック録音・聞き直し</h2><p>選択したWindows出力のデジタル音声を取得します。3.5mmのアナログ回路以降で混入したノイズを収録できる保証はありません。音声欠落フラグは可聴ノイズの自動検出ではありません。無音の時間合わせ、再生時の形式変換や出力経路の影響も考慮してください。</p>'+($sections -join "`n")
}
