$script:SchemaVersion = 1
$script:ToolRoot = Split-Path -Parent $PSScriptRoot

function Get-ToolIdentity {
    param([string]$Root = $script:ToolRoot)
    $commit = 'unknown'
    $dirty = $null
    if ((Test-Path -LiteralPath (Join-Path $Root '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $previousPreference=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try {
            $value = & git -C $Root rev-parse --verify HEAD 2>$null
            if ($LASTEXITCODE -eq 0) {
                $commit = [string]$value
                $dirty = [bool](& git -C $Root status --porcelain --untracked-files=no 2>$null)
            }
        } finally { $ErrorActionPreference=$previousPreference }
    }
    [pscustomobject]@{ version = (Get-Content -LiteralPath (Join-Path $Root 'VERSION') -Raw).Trim(); commit = $commit; modified = $dirty }
}

function Write-AtomicText {
    param([string]$Path, [string]$Text, [switch]$Bom)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetRandomFileName() + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding([bool]$Bom)))
        # The trace helper can briefly read session.json without delete sharing.
        # Retry the atomic replacement, never remove/truncate the saved original.
        for($attempt=0;;$attempt++){
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($temporary, $Path) }
                break
            } catch [IO.IOException] {
                if($attempt -ge 19){throw}
                Start-Sleep -Milliseconds 25
            }
        }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-Session {
    param([string]$Path)
    if((Get-Item -LiteralPath $Path).Length -gt 32MB){throw '調査ログが32MBを超えています。原本は変更していません。'}
    $session = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($session.schemaVersion -ne $script:SchemaVersion) { throw 'このログ形式には対応していません。原本は変更していません。対応する版のツールを利用してください。' }
    if (-not $session.id -or -not $session.tool -or $null -eq $session.tests -or -not $session.profile) { throw 'ログの必須項目が不足しています。原本は変更していません。' }
    return $session
}

function New-DiagnosticSession {
    param($Profile)
    [pscustomobject]@{
        schemaVersion = $script:SchemaVersion
        id = [guid]::NewGuid().ToString('N')
        createdUtc = [DateTime]::UtcNow.ToString('o')
        updatedUtc = [DateTime]::UtcNow.ToString('o')
        tool = Get-ToolIdentity
        profile = $Profile
        inventory = $null
        tests = @()
        audioProbes = @()
        physicalRecordings = @()
        timeline = @()
    }
}

function Get-TestDefinitions {
    @(
        [pscustomobject]@{ id='baseline35'; title='1. 現状の3.5mm出力'; output='3.5mm'; power='PCのUSB'; change='普段の動画・音量で基準を記録'; guide='現在の接続で再生します。動画停止中の様子も備考に記録してください。' }
        [pscustomobject]@{ id='hdmi'; title='2. HDMI・テレビのスピーカー'; output='HDMI'; power='該当なし'; change='音声出力だけをHDMIへ変更'; guide='同じ素材・音量でテレビのスピーカーから再生します。Windowsの出力先も確認してください。' }
        [pscustomobject]@{ id='independentPower'; title='3. スピーカーのUSB給電を変更'; output='3.5mm'; power='独立したUSB電源'; change='3.5mmは維持し、電源用USBだけ変更'; guide='スピーカーの型番・必要電力を確認し、適合する独立電源を使用。テレビのUSBはその旨を記録。PC側の出力先が変わっていないことも確認します。' }
        [pscustomobject]@{ id='headphones'; title='4. 有線イヤホンで比較'; output='3.5mm'; power='該当なし'; change='PCの3.5mmへ有線イヤホンを直結'; guide='手元にあれば有線イヤホンを接続。最初は小音量で確認し、PCからスピーカーへのUSB給電を介さずに比較します。' }
        [pscustomobject]@{ id='localAudio'; title='5. ローカル音声で比較'; output='3.5mm'; power='PCのUSB'; change='接続を基準に戻し、再生素材・アプリを変更'; guide='手元のローカル音声をWindowsのプレーヤーで再生。普段の動画にだけ依存するか確認します。' }
        [pscustomobject]@{ id='enhancements'; title='6. 音声拡張を無効化'; output='3.5mm'; power='PCのUSB'; change='音声拡張だけをオフ'; guide='設定 → システム → サウンド → 対象出力の「オーディオの拡張機能」をオフ。元の値を備考に記録し、ほかの条件を基準に戻して比較。項目がなければ未実施にします。' }
        [pscustomobject]@{ id='format'; title='7. 対応する音声形式で比較'; output='3.5mm'; power='PCのUSB'; change='音声形式だけを変更'; guide='音声拡張を元に戻し、対象出力が提供する別形式だけを選びます。48kHzがあれば候補にし、元と変更後の値を記録。8kHzなどへの大幅な品質低下を解決策としません。' }
        [pscustomobject]@{ id='driver'; title='8. 公式ドライバー確認後の比較'; output='3.5mm'; power='PCのUSB'; change='適合を確認した公式ドライバーのみ比較'; guide='報告書の型番・音声デバイス・ハードウェアIDを公式配布元と照合。合致するものが確認できた場合だけ手動で再導入またはロールバック。元の版と戻し方を先に記録。合致しなければメーカーへ相談します。' }
        [pscustomobject]@{ id='recheck'; title='9. 改善条件の再確認'; output='3.5mm'; power='独立したUSB電源'; change='改善した条件を再起動後に再確認'; guide='改善したテスト名を「比較・再確認するテストID」に記入。元の条件へ戻した比較と、改善条件での再起動後の再確認を別々に記録します。' }
        [pscustomobject]@{ id='btRadioOff'; title='10. Bluetooth無線オフ'; output='3.5mm'; power='PCのUSB'; btCondition='RadioOff'; inputActivity='WiredOnly'; change='有線キーボードは接続したまま、WindowsのBluetoothだけオフ'; guide='先に有線の入力手段を確保。音声出力・スピーカー給電・素材は維持し、Windows設定でBluetoothを手動オフにします。有線キーボードは以後も接続したまま。再起動は挟まず比較します。' }
        [pscustomobject]@{ id='btRadioOn'; title='11. Bluetoothオン・キーボード電源オフ'; output='3.5mm'; power='PCのUSB'; btCondition='RadioOnKeyboardOff'; inputActivity='WiredOnly'; change='Bluetooth無線だけオン、Bluetoothキーボードは電源オフ'; guide='有線キーボードと音声条件を維持してBluetoothをオン。Bluetoothキーボードは電源オフにし、他のBluetooth機器の有無を備考へ記録。無線オンだけで再発するか調べます。' }
        [pscustomobject]@{ id='btKeyboardIdle'; title='12. Bluetoothキーボード接続・待機'; output='3.5mm'; power='PCのUSB'; btCondition='KeyboardConnected'; inputActivity='BluetoothIdle'; change='Bluetoothキーボードを接続し、入力せず待機'; guide='無線オン・有線キーボード接続を維持し、Bluetoothキーボードを接続して待機。Windows上の接続状態を確認します。特定モデルに原因を断定せず、機種名は必要なら備考へ。' }
        [pscustomobject]@{ id='btKeyboardTyping'; title='13. Bluetoothキーボード入力中'; output='3.5mm'; power='PCのUSB'; btCondition='KeyboardConnected'; inputActivity='BluetoothTyping'; change='接続・再生条件を維持してBluetoothキーボードで入力'; guide='メモ帳などに無害な文字を30秒ごとに10秒程度入力。有線キーボードも接続したまま維持します。入力中・待機中とノイズの関係を備考へ記録。ツールは入力内容やキーイベントを取得しません。' }
        [pscustomobject]@{ id='btOffRecheck'; title='14. Bluetoothオフで再確認'; output='3.5mm'; power='PCのUSB'; btCondition='RadioOff'; inputActivity='WiredOnly'; change='再びBluetooth無線だけオフに戻す'; guide='有線キーボードを残し、Bluetoothだけオフに戻して同じ素材・給電・音量で比較。比較先に接続時・入力時テストのIDを記入。オフ→オン→オフをもう一巡できれば記録し、再起動による一時改善と区別します。' }
    )
}

function New-TestRecord {
    param([string]$Kind, [string]$Output, [string]$Power, [string]$App, [string]$Change, [string]$Notes, [string]$Reference = '')
    $point=Get-ClockPoint
    [pscustomobject]@{
        id=[guid]::NewGuid().ToString('N'); kind=$Kind; startedUtc=$point.utc; endedUtc=$null
        tool=Get-ToolIdentity; output=$Output; power=$Power; app=$App; change=$Change; notes=$Notes
        referenceTestId=$Reference; result='InProgress'; noiseUtc=@(); durationSeconds=0; defaultEndpoint=$null
        bluetoothCondition='Unknown'; inputActivity='Unknown'; bluetoothSamples=@(); bluetoothSampling=$null
        timing=[pscustomobject]@{start=$point;end=$null;wallSeconds=$null;clockDifferenceSeconds=$null};conditions=$null;context=$null;playbackSnapshots=@()
    }
}

function Test-GmktecSession {
    param($Session)
    return ([string]$Session.inventory.computer.data.manufacturer -match '(?i)GMKtec')
}

function Get-Assessment {
    param($Session)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $items.Add([pscustomobject]@{ title='判定の前提'; text='ノイズ時刻は耳で確認して押した時刻です。通常ログや短時間の無発生だけでは、アナログ回路・給電・ドライバーの原因や解決を確定できません。テストは同じ素材・音量で一条件ずつ比較してください。' })
    if ($Session.profile.cStates -eq 'Disabled') {
        $items.Add([pscustomobject]@{ title='C-Statesは確認済み'; text='利用者の確認ではDisabledです。再変更を案内しません。SpeedStep、Speed Shiftなど、ほかのBIOS項目をまとめて変更する根拠もありません。' })
    } elseif (Test-GmktecSession $Session) {
        $items.Add([pscustomobject]@{ title='GMKtec機種向けの参考情報'; text='GMKtec公式FAQにC-States無効化の案内がありますが、今回の原因を示すものではありません。実機に適用する案内かを確認し、すでにDisabledなら変更不要です。BIOS更新や他項目の一括変更は行いません。' })
    } else {
        $items.Add([pscustomobject]@{ title='BIOS設定は任意の記録'; text='C-Statesの確認・変更を調査の必須条件にはしません。実機メーカーが対象機種向けに案内している場合だけ確認してください。他社のBIOS手順をそのまま適用しません。' })
    }
    $complete = @($Session.tests | Where-Object { $_.result -notin @('InProgress','Interrupted','NotRun') })
    $baseline = @($complete | Where-Object { $_.kind -eq 'baseline35' -and @($_.noiseUtc).Count -gt 0 })
    if ($baseline.Count -eq 0) {
        $items.Add([pscustomobject]@{ title='基準条件の再現記録が必要'; text='現在の3.5mm接続でノイズが出ることを記録してください。再起動直後だけ出ない場合もあるため、無発生は「再現せず」と記録し、改善の証明にはしません。' })
    }
    foreach ($group in @(
        @{ kind='independentPower'; title='USB給電の影響が候補'; text='給電変更で改善したとの記録があります。PCの3.5mmを維持し、PC給電へ戻す比較と、独立電源での再起動後の比較を記録してください。改善が再現すれば、その給電方法を回避策として使えます。' },
        @{ kind='headphones'; title='スピーカー・給電経路の比較'; text='イヤホンではノイズが出ていません。スピーカーと給電経路の影響が候補ですが、音量・再生時間の差もあるため断定せず、独立給電と比較してください。' },
        @{ kind='localAudio'; title='再生アプリ・動画処理の影響が候補'; text='ローカル音声では改善したとの記録があります。同じ接続に戻し、普段の動画と別アプリを比較してください。ネットワークや映像処理を含む違いは、まだ切り分けられていません。' },
        @{ kind='enhancements'; title='音声拡張設定の影響が候補'; text='音声拡張の無効化で改善したとの記録があります。元の設定との比較と、無効化した状態での再起動後の再確認を行ってください。' },
        @{ kind='format'; title='音声形式・ドライバーの組み合わせが候補'; text='音声形式変更で改善したとの記録があります。対応形式の範囲で元の設定と比較し、再起動後も確認してください。' },
        @{ kind='driver'; title='ドライバー変更後の再確認'; text='ドライバー変更で改善したとの記録があります。変更前後の版を確認し、同じ素材で再起動後にも比較してください。' }
    )) {
        $match = @($complete | Where-Object { $_.kind -eq $group.kind -and ($_.result -eq 'Improved' -or ($_.result -eq 'NoRepro' -and @($_.noiseUtc).Count -eq 0 -and $baseline.Count -gt 0)) })
        if ($match.Count -gt 0) { $items.Add([pscustomobject]@{ title=$group.title; text=$group.text }) }
    }
    $hdmiNoise = @($complete | Where-Object { $_.kind -eq 'hdmi' -and @($_.noiseUtc).Count -gt 0 })
    if ($hdmiNoise.Count -gt 0) {
        $items.Add([pscustomobject]@{ title='HDMIにも発生する記録あり'; text='今回の記録では3.5mm限定ではありません。出力先を確認し、同一素材で比較してください。アプリやシステム共通の処理も候補になります。' })
    }
    $unrun = @((Get-TestDefinitions) | Where-Object { $_.id -ne 'recheck' -and $_.id -notin @($Session.tests | Where-Object { $_.result -notin @('InProgress','Interrupted','NotRun') } | ForEach-Object { $_.kind }) })
    if ($unrun.Count -gt 0) { $items.Add([pscustomobject]@{ title='次の未確認項目'; text=($unrun | ForEach-Object { $_.title }) -join ' ／ ' }) }
    $short = @($complete | Where-Object { $_.durationSeconds -lt 600 })
    if ($short.Count -gt 0) { $items.Add([pscustomobject]@{ title='観察時間が短い記録あり'; text='標準は各10分です。短い記録も保存しますが、無発生や改善の判断材料としては不足する場合があります。' }) }
    $conflict=@($complete | Where-Object { $_.result -eq 'NoRepro' -and @($_.noiseUtc).Count -gt 0 })
    if ($conflict.Count -gt 0) { $items.Add([pscustomobject]@{ title='結果とノイズ記録の食い違い'; text='「再現せず」を選んだテストにノイズボタンの記録があります。誤操作か結果の選択間違いかを確認し、備考を添えて再テストしてください。この記録を無発生の比較としては使いません。' }) }
    foreach ($assessment in @(Get-BluetoothAssessment $Session)) { $items.Add($assessment) }
    $items.Add([pscustomobject]@{ title='未解決の場合'; text='PC・音声機器メーカーの公式配布元で、機種・ハードウェアIDと合致するドライバーを確認します。合致する配布物がなければメーカーへ相談してください。通常ログだけでドライバー処理の遅延（DPC/ISR）を確定できないため、JSONを持ち帰って必要ならWindows Performance Recorder等の詳細調査を判断します。機種全体の設計不良とは断定できません。' })
    return $items.ToArray()
}

function Test-ObservedBluetoothRadio {
    param($Test,[string]$Expected)
    $states=@($Test.bluetoothSamples | Where-Object { $null -ne $_ } | ForEach-Object { (Get-BluetoothStateSummary $_).radioState })
    return ($Expected -in $states -and @($states | Where-Object { $_ -ne 'Unknown' -and $_ -ne $Expected }).Count -eq 0)
}

function Get-BluetoothAssessment {
    param($Session)
    $items=New-Object 'System.Collections.Generic.List[object]'
    $items.Add([pscustomobject]@{ title='Bluetoothの調査範囲'; text='無線オン・オフ、ペアリング済み機器の接続状態、関連ドライバー・イベントを調べます。「接続中」やPnPの正常表示から通信量・電波干渉・DPC遅延は判定できません。入力中かは手動の申告で、キー内容は取得しません。' })
    $complete=@($Session.tests | Where-Object { $_.kind -like 'bt*' -and $_.result -notin @('NotRun','InProgress','Interrupted') })
    if ($complete.Count -eq 0) { $items.Add([pscustomobject]@{ title='Bluetooth比較は未実施'; text='有線キーボードを全条件で接続したまま、Bluetoothオフ→オン・キーボード電源オフ→接続待機→入力中→オフ再確認を比較できます。新しいログ取得前にキーボードを再接続する必要はありません。登録情報が取得できても、今接続中とは限りません。' }); return $items.ToArray() }
    $off=@($complete | Where-Object { $_.kind -in @('btRadioOff','btOffRecheck') -and $_.result -eq 'NoRepro' -and @($_.noiseUtc).Count -eq 0 -and $_.durationSeconds -ge 600 -and (Test-ObservedBluetoothRadio $_ 'Off') })
    $on=@($complete | Where-Object { $_.kind -in @('btRadioOn','btKeyboardIdle','btKeyboardTyping') -and @($_.noiseUtc).Count -gt 0 -and (Test-ObservedBluetoothRadio $_ 'On') })
    $paired=$false
    foreach ($a in $off) {
        foreach ($b in $on) {
            if ($a.output -eq '3.5mm' -and $a.output -eq $b.output -and $a.power -eq $b.power -and -not [string]::IsNullOrWhiteSpace($a.app) -and $a.app -eq $b.app) { $paired=$true }
        }
    }
    if ($paired) { $items.Add([pscustomobject]@{ title='Bluetooth状態に伴う差が候補'; text='同じ出力・給電・アプリの記録で、Bluetoothオフは10分以上無発生、オン側にはノイズ記録があります。実測の無線状態と手動条件を確認し、オフ→オン→オフを再確認してください。無線干渉、ドライバー処理、USB系統などの区別や、特定メーカー・型番の原因確定はまだできません。' }) }
    else { $items.Add([pscustomobject]@{ title='Bluetooth比較の追加確認'; text='現状の比較だけではBluetoothの影響を判定できません。同じ3.5mm出力・給電先・アプリ名を記録し、オフとオンの条件を十分な時間観察してください。' }) }
    foreach ($test in $complete) {
        $samples=@($test.bluetoothSamples | Where-Object { $null -ne $_ })
        $expected=if ($test.bluetoothCondition -eq 'RadioOff') { 'Off' } elseif ($test.bluetoothCondition -in @('RadioOnKeyboardOff','KeyboardConnected')) { 'On' } else { $null }
        $states=@($samples | ForEach-Object { (Get-BluetoothStateSummary $_).radioState } | Where-Object { $_ -ne 'Unknown' } | Select-Object -Unique)
        if ($expected -and @($states | Where-Object { $_ -ne $expected }).Count -gt 0) { $items.Add([pscustomobject]@{ title='Bluetooth条件と取得状態の食い違い'; text=('テスト ' + $test.id + ' の手動条件と無線状態が一致しない記録があります。状態遷移中や設定・取得の差を確認し、この比較だけで原因を決めないでください。') }) }
        if ($samples.Count -eq 0 -or $states.Count -eq 0) { $items.Add([pscustomobject]@{ title='Bluetoothの実測状態が不足'; text=('テスト ' + $test.id + ' の無線状態は未取得または不明です。手動条件は実測確認済みとして扱いません。') }) }
    }
    return $items.ToArray()
}

function ConvertTo-SafeCsvCell {
    param($Value)
    $text = [string]$Value
    if ($text -match '^\s*[=+@-]') { $text = "'" + $text }
    return '"' + $text.Replace('"','""') + '"'
}

function Get-ResultLabel {
    param([string]$Result)
    $labels = @{ InProgress='調査中'; Interrupted='中断'; NotRun='未実施'; NoRepro='再現せず'; Improved='改善'; Unchanged='変化なし'; Worse='悪化' }
    if ($labels.ContainsKey($Result)) { return $labels[$Result] }
    return '不明'
}

function ConvertTo-HtmlText { param($Value) [Net.WebUtility]::HtmlEncode([string]$Value) }

function Get-NearestBluetoothObservation {
    param($Test,[string]$NoiseUtc)
    $observations=@($Test.bluetoothSamples | Where-Object { $null -ne $_ })
    if ($Test.bluetoothEndState) { $observations+=@($Test.bluetoothEndState) }
    $nearest=$null; $distance=[double]::PositiveInfinity
    foreach ($observation in $observations) {
        try {
            $delta=([DateTime]::Parse($observation.capturedUtc).ToUniversalTime() - [DateTime]::Parse($NoiseUtc).ToUniversalTime()).TotalSeconds
            if ([Math]::Abs($delta) -lt $distance) { $nearest=[pscustomobject]@{ snapshot=$observation; offsetSeconds=[Math]::Round($delta,1) }; $distance=[Math]::Abs($delta) }
        } catch { }
    }
    return $nearest
}

function Get-BluetoothReportHtml {
    param($Session)
    $sections=New-Object 'System.Collections.Generic.List[string]'
    foreach ($test in @($Session.tests)) {
        $samples=@($test.bluetoothSamples | Where-Object { $null -ne $_ })
        $hasEnd=$null -ne $test.bluetoothEndState
        if ($samples.Count -eq 0 -and -not $hasEnd -and $test.kind -notlike 'bt*') { continue }
        $rows=New-Object 'System.Collections.Generic.List[string]'
        $all=@($samples); if ($hasEnd) { $all+=@($test.bluetoothEndState) }
        foreach ($sample in $all) {
            $summary=Get-BluetoothStateSummary $sample
            $count=if ($null -eq $summary.connectedEndpointCount) {'不明・一部未取得'} else {[string]$summary.connectedEndpointCount}
            $rows.Add('<tr><td>' + (ConvertTo-HtmlText $sample.capturedUtc) + '</td><td>' + (ConvertTo-HtmlText $summary.radioState) + '</td><td>' + $count + '</td><td>' + (ConvertTo-HtmlText $sample.classic.status) + ' / ' + (ConvertTo-HtmlText $sample.lowEnergy.status) + '</td></tr>')
        }
        $noiseRows=New-Object 'System.Collections.Generic.List[string]'
        foreach ($noise in @($test.noiseUtc)) {
            $nearest=Get-NearestBluetoothObservation $test $noise
            $observation='Bluetooth記録なし'
            if ($nearest) {
                $summary=Get-BluetoothStateSummary $nearest.snapshot
                $observation=('最も近い取得: ' + $nearest.snapshot.capturedUtc + ' ／ ノイズ時刻との差 ' + $nearest.offsetSeconds + ' 秒 ／ 無線 ' + $summary.radioState)
            }
            $noiseRows.Add('<li>' + (ConvertTo-HtmlText $noise) + ' — ' + (ConvertTo-HtmlText $observation) + '</li>')
        }
        $limitNote=if ($test.bluetoothSampling.limitReached) { '記録上限に到達。以後の定期状態は未記録。' } else { '' }
        $sections.Add('<details><summary>テスト ' + (ConvertTo-HtmlText $test.id) + ' / ' + (ConvertTo-HtmlText $test.kind) + ' のBluetooth記録</summary><p>手動条件: ' + (ConvertTo-HtmlText $test.bluetoothCondition) + ' ／ 入力状況（手動）: ' + (ConvertTo-HtmlText $test.inputActivity) + '<br>' + $limitNote + '</p><div class="scroll"><table><tr><th>取得時刻（UTC）</th><th>無線</th><th>接続エンドポイント数</th><th>Classic / LE取得</th></tr>' + ($rows -join '') + '</table></div><ul>' + ($noiseRows -join '') + '</ul></details>')
    }
    $body=if ($sections.Count -eq 0) { '<p>Bluetoothのテスト時状態は未記録です。旧ログでは項目がない場合もあります。</p>' } else { $sections -join "`n" }
    return '<h2>Bluetooth条件とノイズ時刻</h2><p>定期記録は約10秒間隔（取得時間により延びます）。最も近い状態は参考で、ノイズ発生瞬間の通信を測った値ではありません。最後に終了後の状態を追加表示します。エンドポイント数は物理機器数と一致するとは限りません。</p>' + $body
}

function Get-ReportHtml {
    param($Session)
    $assessments = (Get-Assessment $Session | ForEach-Object { '<article><h3>' + (ConvertTo-HtmlText $_.title) + '</h3><p>' + (ConvertTo-HtmlText $_.text) + '</p></article>' }) -join "`n"
    $tests = @($Session.tests | ForEach-Object {
        '<tr><td>' + (ConvertTo-HtmlText $_.id) + '<br>' + (ConvertTo-HtmlText $_.kind) + '</td><td>' + (ConvertTo-HtmlText $_.output) + '<br>' + (ConvertTo-HtmlText $_.power) + '<br>' + (ConvertTo-HtmlText $_.app) + '</td><td>' + (ConvertTo-HtmlText $_.change) + '<br>' + (ConvertTo-HtmlText $_.notes) + '<br>比較先: ' + (ConvertTo-HtmlText $_.referenceTestId) + '</td><td>' + (ConvertTo-HtmlText (Get-ResultLabel $_.result)) + '<br>' + [int]$_.durationSeconds + ' 秒<br>ノイズ ' + @($_.noiseUtc).Count + ' 回</td><td>' + (ConvertTo-HtmlText $_.startedUtc) + '<br>' + (ConvertTo-HtmlText $_.endedUtc) + '<br>' + (ConvertTo-HtmlText (@($_.noiseUtc) -join "`n")) + '</td><td>' + (ConvertTo-HtmlText $_.tool.version) + '<br>' + (ConvertTo-HtmlText $_.tool.commit) + '</td></tr>'
    }) -join "`n"
    $profileJson = ConvertTo-HtmlText ($Session.profile | ConvertTo-Json -Depth 8)
    $inventoryJson = ConvertTo-HtmlText ($Session.inventory | ConvertTo-Json -Depth 14)
    $bluetoothHtml=Get-BluetoothReportHtml $Session
    $audioHtml=Get-AudioReportHtml $Session
    $physicalHtml=Get-PhysicalReportHtml $Session
    $networkHtml=Get-PhoneNetworkReportHtml $Session
    $reproductionHtml=(Get-ReproductionReportHtml $Session)+(Get-FollowUpReportHtml $Session)
    $driverEvidenceHtml=(@($Session.tests | Where-Object { $null -ne $_.driverSnapshot } | ForEach-Object {
        '<details><summary>ドライバー変更テストの再取得情報: ' + (ConvertTo-HtmlText $_.id) + '</summary><pre>' + (ConvertTo-HtmlText ($_.driverSnapshot | ConvertTo-Json -Depth 14)) + '</pre></details>'
    })) -join "`n"
    $stamp = ConvertTo-HtmlText $Session.updatedUtc
    $identity = ConvertTo-HtmlText ($Session.tool.version + ' / ' + $Session.tool.commit)
    $manufacturerSources=''
    if (Test-GmktecSession $Session) {
        $manufacturerSources=@'
<details><summary>GMKtec機種向けの参考情報</summary><ul>
<li><a href="https://www.gmktec.com/pages/guides-how-to-tutorial">GMKtec公式FAQ</a>：C-States無効化の案内。実機への適用可否を確認してください。</li>
<li><a href="https://www.gmktec.com/pages/drivers-and-software">GMKtec公式配布元</a>：G3 / G3 Plus / G3 Proを取り違えず、型番とハードウェアIDを照合してください。</li>
<li><a href="https://learn.microsoft.com/en-us/answers/questions/3926875/windows-11-usb-audio-and-hid-audio-cracking">Microsoft Q&amp;Aの利用者報告</a>：GMKtecの近縁機種の体験談。メーカーが検証した修正情報ではありません。</li>
</ul></details>
'@
    }
    return @"
<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows 音声ノイズ調査報告書</title>
<style>body{font:16px/1.7 "Yu Gothic UI",sans-serif;color:#172c3c;background:#f3f6f8;margin:0}main{max-width:1200px;margin:auto;padding:32px}header{border-top:6px solid #137c80}h1{font-size:28px}h2{margin-top:36px}h3{font-size:18px;margin:0 0 8px}article,details{background:white;padding:20px;margin:12px 0;border:1px solid #d5e0e5;border-radius:8px}p{margin:0;white-space:pre-wrap}a{color:#086b74}table{border-collapse:collapse;background:white;width:100%;font-size:14px}th,td{border:1px solid #cbd9df;padding:12px;text-align:left;vertical-align:top;white-space:pre-wrap;overflow-wrap:anywhere}th{background:#e4eff1}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}.scroll{overflow:auto}.muted{color:#4c6473}.tag{color:#087277;font-weight:bold}@media print{main{padding:0}details{break-inside:avoid}table{font-size:11px}}</style></head><body><main>
<header><p class="tag">WINDOWS AUDIO NOISE DIAGNOSTICS</p><h1>音声ノイズ 調査報告書</h1><p class="muted">更新時刻（UTC）: $stamp<br>セッション作成時のツール: $identity<br>各テストの実行版は記録表を参照してください。</p></header>
<h2>確認結果と次の手順</h2>$assessments
<h2>比較テストの記録</h2><p>時刻はUTC。ノイズ回数は手動ボタンの回数で、波形やノイズの自動検出ではありません。</p><div class="scroll"><table><thead><tr><th>ID / テスト</th><th>接続 / 電源 / アプリ</th><th>変更 / 備考 / 比較先</th><th>結果 / 観察時間</th><th>開始 / 終了 / ノイズ時刻</th><th>実行版</th></tr></thead><tbody>$tests</tbody></table></div>
$bluetoothHtml
$audioHtml
$physicalHtml
$networkHtml
$reproductionHtml
<h2>利用者が確認した情報</h2><pre>$profileJson</pre>
<h2>自動取得した情報</h2><p>最初の情報はcapturedUtc時点の状態です。v0.6以降は各テスト開始後にも構成を取得します。ドライバー変更テストでは終了後にも再取得します。</p><details><summary>初回取得のPC・ドライバー・関連イベントを開く</summary><pre>$inventoryJson</pre></details>$driverEvidenceHtml
<h2>情報源と適用範囲</h2><article><ul>
<li><a href="https://support.microsoft.com/en-us/windows/hardware/audio/fix-distorted-or-crackling-audio-in-windows">Microsoft公式の音声対処手順</a>：音声拡張、形式、ドライバーの確認。</li>
<li><a href="https://learn.microsoft.com/en-us/windows-hardware/test/assessments/results-for-the-streaming-media-performance-assessment">Microsoftの音声グリッチ解析資料</a>：DPC/ISRなどの詳細解析が必要になる場合の参考。</li>
<li><a href="https://learn.microsoft.com/en-us/windows/win32/properties/props-system-devices-aep-isconnected">Microsoftの接続状態プロパティ</a>：Windowsが示す接続状態。通信量や電波干渉を示す値ではありません。</li>
<li><a href="https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/testing-bluetooth-main">MicrosoftのBluetooth調査資料</a>：通常の状態取得で不明な場合のWPR/ETW詳細調査。</li>
</ul><p>基本情報の確認日：2026-11-16。Bluetooth情報の追加確認日：2026-11-19。公式ページの更新やBIOS・OSの違いにより、項目名や配布状況は変わります。</p></article>$manufacturerSources
<p class="muted">この報告書はローカルで生成されています。GitHubへ自動送信しません。録音には選択した出力の他アプリ・通知、またはマイク・スマートフォンが拾う周囲の音も含まれます。共有前に内容を確認してください。</p>
</main></body></html>
"@
}

function Save-Session {
    param($Session, [string]$Directory)
    $Session.updatedUtc = [DateTime]::UtcNow.ToString('o')
    # JSON is the authoritative record; derived reports may be regenerated after a failure.
    Write-AtomicText (Join-Path $Directory 'session.json') ($Session | ConvertTo-Json -Depth 20)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('test_id,kind,started_utc,ended_utc,output,power,app,change,notes,reference_test_id,result,duration_seconds,noise_count,noise_utc,tool_version,tool_commit,bluetooth_condition_manual,input_activity_manual')
    foreach ($test in @($Session.tests)) {
        $values = @($test.id,$test.kind,$test.startedUtc,$test.endedUtc,$test.output,$test.power,$test.app,$test.change,$test.notes,$test.referenceTestId,(Get-ResultLabel $test.result),$test.durationSeconds,@($test.noiseUtc).Count,(@($test.noiseUtc) -join ' | '),$test.tool.version,$test.tool.commit,$test.bluetoothCondition,$test.inputActivity)
        $lines.Add(($values | ForEach-Object { ConvertTo-SafeCsvCell $_ }) -join ',')
    }
    Write-AtomicText (Join-Path $Directory 'tests.csv') ($lines -join "`r`n") -Bom
    $bluetoothLines=New-Object 'System.Collections.Generic.List[string]'
    $bluetoothLines.Add('test_id,phase,captured_utc,radio_state,connected_endpoints,classic_status,le_status,read_duration_ms')
    foreach ($test in @($Session.tests)) {
        foreach ($phase in @('periodic','after_test')) {
            $samples=if ($phase -eq 'periodic') { @($test.bluetoothSamples | Where-Object { $null -ne $_ }) } else { @($test.bluetoothEndState | Where-Object { $null -ne $_ }) }
            foreach ($sample in $samples) {
                $summary=Get-BluetoothStateSummary $sample
                $values=@($test.id,$phase,$sample.capturedUtc,$summary.radioState,$summary.connectedEndpointCount,$sample.classic.status,$sample.lowEnergy.status,$sample.durationMilliseconds)
                $bluetoothLines.Add(($values | ForEach-Object { ConvertTo-SafeCsvCell $_ }) -join ',')
            }
        }
    }
    Write-AtomicText (Join-Path $Directory 'bluetooth.csv') ($bluetoothLines -join "`r`n") -Bom
    $timelineLines=New-Object 'System.Collections.Generic.List[string]'
    $timelineLines.Add('event_id,kind,test_id,probe_id,utc,qpc,qpc_frequency,note')
    foreach($entry in @($Session.timeline)){
        if($null -eq $entry){continue}
        $timelineLines.Add((@($entry.id,$entry.kind,$entry.testId,$entry.probeId,$entry.utc,$entry.qpc,$entry.frequency,$entry.note)|ForEach-Object{ConvertTo-SafeCsvCell $_}) -join ',')
    }
    Write-AtomicText (Join-Path $Directory 'timeline.csv') ($timelineLines -join "`r`n") -Bom
    if(@($Session.networkDiagnostics|Where-Object {$null -ne $_}).Count){Write-AtomicText (Join-Path $Directory 'network-diagnostics.json') (ConvertTo-Json -InputObject @($Session.networkDiagnostics) -Depth 20)}
    $html=Get-ReportHtml $Session
    $traceOverview='<h2>試験ごとのUSB・Audio取得確認</h2><pre>'+(ConvertTo-HtmlText (Get-TraceEvidenceText @(Get-SessionTraceEvidence $Session $Directory)))+'</pre>'
    $html=$html.Replace('</main>',($traceOverview+(Get-TraceReportHtml $Directory)+'</main>'))
    Write-AtomicText (Join-Path $Directory 'report.html') $html
}
