function Read-BrowserUploadLog {
    param([string]$Path)
    if((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 65536){throw '送信ログが64KBを超えています。'}
    $log=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    function Assert-LogFields {param($Value,[string[]]$Names)
        if(-not $Value -or $Value -is [array] -or @($Value.PSObject.Properties|Where-Object {$_.Name -notin $Names}).Count -or @($Names|Where-Object {-not $Value.PSObject.Properties[$_]}).Count){throw '対応する送信ログの形式ではありません。'}
    }
    function Assert-LogNumber {param($Value,[double]$Maximum)
        if($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double]){throw '送信ログの数値が正しくありません。'}
        if([double]::IsNaN($Value) -or $Value -lt 0 -or $Value -gt $Maximum -or [Math]::Floor($Value) -ne $Value){throw '送信ログの数値が範囲外です。'}
    }
    Assert-LogFields $log @('schemaVersion','kind','browser','secureContext','transportProtocol','online','attempts')
    if($log.schemaVersion -ne 1 -or $log.kind -ne 'BrowserUploadDiagnostics' -or $log.secureContext -isnot [bool] -or $log.online -isnot [bool] -or $log.transportProtocol -notin @('HTTP','HTTPS')){throw '対応する送信ログではありません。'}
    Assert-LogFields $log.browser @('family','major')
    if($log.browser.family -notin @('Firefox','Edge','Chrome','Safari','Unknown')){throw 'ブラウザー分類が正しくありません。'}
    Assert-LogNumber $log.browser.major 10000
    if($log.attempts -isnot [array] -or $log.attempts.Count -gt 10){throw '送信ログの件数が正しくありません。'}
    $stages=@('Selected','FileReadable','FileReadError','RequestStarted','UploadProgress','UploadBodySent','ResponseReceived','Completed','HttpError','NetworkError','Timeout','Aborted','InvalidResponse','SecurityPolicyBlocked')
    $attempts=@(foreach($attempt in $log.attempts){
        Assert-LogFields $attempt @('id','kind','startedUtc','outcome','fileBytes','mediaKind','events')
        $parsedDate=[DateTime]::MinValue
        if($attempt.id -notmatch '^[a-f0-9]{32}$' -or $attempt.kind -notin @('Upload','Health') -or $attempt.outcome -notin @('Pending','Completed','FileReadError','HttpError','NetworkError','Timeout','Aborted','InvalidResponse') -or $attempt.mediaKind -notin @('Audio','Video','Other','None') -or $attempt.startedUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,7}Z$' -or -not [DateTime]::TryParse($attempt.startedUtc,[ref]$parsedDate)){throw '送信試行の項目が正しくありません。'}
        Assert-LogNumber $attempt.fileBytes 134217728
        if($attempt.events -isnot [array] -or $attempt.events.Count -gt 32){throw '送信イベントの件数が正しくありません。'}
        $events=@(foreach($entry in $attempt.events){
            Assert-LogFields $entry @('stage','elapsedMs','loadedBytes','status')
            if($entry.stage -notin $stages){throw '対応しない送信段階です。'}
            Assert-LogNumber $entry.elapsedMs 86400000;Assert-LogNumber $entry.loadedBytes 134217728;Assert-LogNumber $entry.status 599
            if($entry.status -ne 0 -and $entry.status -lt 100){throw 'HTTPコードが正しくありません。'}
            [pscustomobject]@{stage=$entry.stage;elapsedMs=$entry.elapsedMs;loadedBytes=$entry.loadedBytes;status=$entry.status}
        })
        [pscustomobject]@{id=$attempt.id;kind=$attempt.kind;startedUtc=$attempt.startedUtc;outcome=$attempt.outcome;fileBytes=$attempt.fileBytes;mediaKind=$attempt.mediaKind;events=$events}
    })
    [pscustomobject]@{schemaVersion=1;kind='BrowserUploadDiagnostics';browser=[pscustomobject]@{family=$log.browser.family;major=$log.browser.major};secureContext=$log.secureContext;transportProtocol=$log.transportProtocol;online=$log.online;attempts=$attempts;scope='スマホから明示的に取り込んだ送信ログ。端末時刻はPCと同期済みと仮定しない。NetworkErrorは権限・ファイアウォール等の原因を特定しない。'}
}
