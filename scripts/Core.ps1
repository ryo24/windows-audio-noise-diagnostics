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
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-Session {
    param([string]$Path)
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
    )
}

function New-TestRecord {
    param([string]$Kind, [string]$Output, [string]$Power, [string]$App, [string]$Change, [string]$Notes, [string]$Reference = '')
    [pscustomobject]@{
        id=[guid]::NewGuid().ToString('N'); kind=$Kind; startedUtc=[DateTime]::UtcNow.ToString('o'); endedUtc=$null
        tool=Get-ToolIdentity; output=$Output; power=$Power; app=$App; change=$Change; notes=$Notes
        referenceTestId=$Reference; result='InProgress'; noiseUtc=@(); durationSeconds=0; defaultEndpoint=$null
    }
}

function Get-Assessment {
    param($Session)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $items.Add([pscustomobject]@{ title='判定の前提'; text='ノイズ時刻は耳で確認して押した時刻です。通常ログや短時間の無発生だけでは、アナログ回路・給電・ドライバーの原因や解決を確定できません。テストは同じ素材・音量で一条件ずつ比較してください。' })
    if ($Session.profile.cStates -eq 'Disabled') {
        $items.Add([pscustomobject]@{ title='C-Statesは確認済み'; text='利用者の確認ではDisabledです。再変更を案内しません。SpeedStep、Speed Shiftなど、ほかのBIOS項目をまとめて変更する根拠もありません。' })
    } else {
        $items.Add([pscustomobject]@{ title='C-Statesの記録'; text='GMKtec公式FAQに無効化の案内がありますが、今回の原因を示すものではありません。簡単な比較で未解決の場合に現状を確認し、すでにDisabledなら変更不要です。BIOS更新や他項目の一括変更は行いません。' })
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
    $items.Add([pscustomobject]@{ title='未解決の場合'; text='機種・ハードウェアIDと合致するGMKtec公式ドライバーを確認します。合致する配布物がなければメーカーへ相談してください。通常ログだけでドライバー処理の遅延（DPC/ISR）を確定できないため、JSONを持ち帰って必要ならWindows Performance Recorder等の詳細調査を判断します。機種全体の設計不良とは断定できません。' })
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

function Get-ReportHtml {
    param($Session)
    $assessments = (Get-Assessment $Session | ForEach-Object { '<article><h3>' + (ConvertTo-HtmlText $_.title) + '</h3><p>' + (ConvertTo-HtmlText $_.text) + '</p></article>' }) -join "`n"
    $tests = @($Session.tests | ForEach-Object {
        '<tr><td>' + (ConvertTo-HtmlText $_.id) + '<br>' + (ConvertTo-HtmlText $_.kind) + '</td><td>' + (ConvertTo-HtmlText $_.output) + '<br>' + (ConvertTo-HtmlText $_.power) + '<br>' + (ConvertTo-HtmlText $_.app) + '</td><td>' + (ConvertTo-HtmlText $_.change) + '<br>' + (ConvertTo-HtmlText $_.notes) + '<br>比較先: ' + (ConvertTo-HtmlText $_.referenceTestId) + '</td><td>' + (ConvertTo-HtmlText (Get-ResultLabel $_.result)) + '<br>' + [int]$_.durationSeconds + ' 秒<br>ノイズ ' + @($_.noiseUtc).Count + ' 回</td><td>' + (ConvertTo-HtmlText $_.startedUtc) + '<br>' + (ConvertTo-HtmlText $_.endedUtc) + '<br>' + (ConvertTo-HtmlText (@($_.noiseUtc) -join "`n")) + '</td><td>' + (ConvertTo-HtmlText $_.tool.version) + '<br>' + (ConvertTo-HtmlText $_.tool.commit) + '</td></tr>'
    }) -join "`n"
    $profileJson = ConvertTo-HtmlText ($Session.profile | ConvertTo-Json -Depth 8)
    $inventoryJson = ConvertTo-HtmlText ($Session.inventory | ConvertTo-Json -Depth 14)
    $driverEvidenceHtml=(@($Session.tests | Where-Object { $null -ne $_.driverSnapshot } | ForEach-Object {
        '<details><summary>ドライバー変更テストの再取得情報: ' + (ConvertTo-HtmlText $_.id) + '</summary><pre>' + (ConvertTo-HtmlText ($_.driverSnapshot | ConvertTo-Json -Depth 14)) + '</pre></details>'
    })) -join "`n"
    $stamp = ConvertTo-HtmlText $Session.updatedUtc
    $identity = ConvertTo-HtmlText ($Session.tool.version + ' / ' + $Session.tool.commit)
    return @"
<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>G3 Plus 音声調査報告書</title>
<style>body{font:16px/1.7 "Yu Gothic UI",sans-serif;color:#172c3c;background:#f3f6f8;margin:0}main{max-width:1200px;margin:auto;padding:32px}header{border-top:6px solid #137c80}h1{font-size:28px}h2{margin-top:36px}h3{font-size:18px;margin:0 0 8px}article,details{background:white;padding:20px;margin:12px 0;border:1px solid #d5e0e5;border-radius:8px}p{margin:0;white-space:pre-wrap}a{color:#086b74}table{border-collapse:collapse;background:white;width:100%;font-size:14px}th,td{border:1px solid #cbd9df;padding:12px;text-align:left;vertical-align:top;white-space:pre-wrap;overflow-wrap:anywhere}th{background:#e4eff1}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}.scroll{overflow:auto}.muted{color:#4c6473}.tag{color:#087277;font-weight:bold}@media print{main{padding:0}details{break-inside:avoid}table{font-size:11px}}</style></head><body><main>
<header><p class="tag">G3 PLUS AUDIO DIAGNOSTICS</p><h1>音声ノイズ 調査報告書</h1><p class="muted">更新時刻（UTC）: $stamp<br>セッション作成時のツール: $identity<br>各テストの実行版は記録表を参照してください。</p></header>
<h2>確認結果と次の手順</h2>$assessments
<h2>比較テストの記録</h2><p>時刻はUTC。ノイズ回数は手動ボタンの回数で、波形やノイズの自動検出ではありません。</p><div class="scroll"><table><thead><tr><th>ID / テスト</th><th>接続 / 電源 / アプリ</th><th>変更 / 備考 / 比較先</th><th>結果 / 観察時間</th><th>開始 / 終了 / ノイズ時刻</th><th>実行版</th></tr></thead><tbody>$tests</tbody></table></div>
<h2>利用者が確認した情報</h2><pre>$profileJson</pre>
<h2>自動取得した情報</h2><p>最初の情報はcapturedUtc時点の状態です。ドライバー変更テストでは終了時に音声デバイス情報を再取得し、別に保存します。</p><details><summary>初回取得のPC・ドライバー・関連イベントを開く</summary><pre>$inventoryJson</pre></details>$driverEvidenceHtml
<h2>情報源と適用範囲</h2><article><ul>
<li><a href="https://www.gmktec.com/pages/guides-how-to-tutorial">GMKtec公式FAQ</a>：再生時ノイズへのC-States無効化案内。今回の原因を確定する情報ではありません。</li>
<li><a href="https://www.gmktec.com/pages/drivers-and-software">GMKtec公式配布元</a>：G3 / G3 Plus / G3 Proを取り違えず、実機の型番とハードウェアIDを照合してください。</li>
<li><a href="https://support.microsoft.com/en-us/windows/hardware/audio/fix-distorted-or-crackling-audio-in-windows">Microsoft公式の音声対処手順</a>：音声拡張、形式、ドライバーの確認。</li>
<li><a href="https://learn.microsoft.com/en-us/answers/questions/3926875/windows-11-usb-audio-and-hid-audio-cracking">Microsoft Q&amp;Aの利用者報告</a>：近縁機種の体験談。メーカーが検証したG3 Plusの修正情報ではありません。</li>
<li><a href="https://learn.microsoft.com/en-us/windows-hardware/test/assessments/results-for-the-streaming-media-performance-assessment">Microsoftの音声グリッチ解析資料</a>：DPC/ISRなどの詳細解析が必要になる場合の参考。</li>
</ul><p>調査情報の確認日：2026-11-16。公式ページの更新やBIOS・OSの違いにより、項目名や配布状況は変わります。</p></article>
<p class="muted">この報告書はローカルで生成されています。GitHubへの送信や音声録音は行いません。ログを他者へ渡す前に、自由入力欄やデバイス名に個人情報がないか確認してください。</p>
</main></body></html>
"@
}

function Save-Session {
    param($Session, [string]$Directory)
    $Session.updatedUtc = [DateTime]::UtcNow.ToString('o')
    # JSON is the authoritative record; derived reports may be regenerated after a failure.
    Write-AtomicText (Join-Path $Directory 'session.json') ($Session | ConvertTo-Json -Depth 20)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('test_id,kind,started_utc,ended_utc,output,power,app,change,notes,reference_test_id,result,duration_seconds,noise_count,noise_utc,tool_version,tool_commit')
    foreach ($test in @($Session.tests)) {
        $values = @($test.id,$test.kind,$test.startedUtc,$test.endedUtc,$test.output,$test.power,$test.app,$test.change,$test.notes,$test.referenceTestId,(Get-ResultLabel $test.result),$test.durationSeconds,@($test.noiseUtc).Count,(@($test.noiseUtc) -join ' | '),$test.tool.version,$test.tool.commit)
        $lines.Add(($values | ForEach-Object { ConvertTo-SafeCsvCell $_ }) -join ',')
    }
    Write-AtomicText (Join-Path $Directory 'tests.csv') ($lines -join "`r`n") -Bom
    Write-AtomicText (Join-Path $Directory 'report.html') (Get-ReportHtml $Session)
}
