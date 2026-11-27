# データの書き出し・受け取り・エージェント解析

## 対象PCでZIPを書き出す

1. 比較テスト・録音・スマートフォン受付・詳細トレースを終了します。必要な録音は聞き直して結果を保存してください。
2. **5 書き出す**の**ZIPを書き出して場所を開く**を押します。現在開いているセッションのJSON、HTML、CSV、参照されるテスト音声・録音・スマートフォン音声／動画をまとめます。他のセッションや無関係のファイルは入りません。
3. `data/exports/`にZIPができ、エクスプローラーでそのZIPを選択します。自動送信はしません。必要なPCへこのZIPをコピーします。

命名規則は `audio-noise_<セッション作成UTC>_<セッションID先頭8桁>_export<書き出しUTC>_<ランダム6桁>.zip` です。例：`audio-noise_20261123T010203Z_a1b2c3d4_export20261123T020304Z_e5f6a7.zip`。同じセッションを再出力しても上書きしません。エクスプローラーで開く対象はフォルダーだけではなく、生成したZIPです。

```text
bundle.json                  # 書き出し版・セッションID・ファイル一覧・サイズ・SHA-256
session/
  session.json               # 正式なログ
  report.html
  tests.csv
  bluetooth.csv
  timeline.csv               # UTC・QPC・テスト／録音IDつきの操作時刻
  network-diagnostics.json   # 接続診断を明示的に保存した場合だけ（選択LAN内IPを含む）
  audio/<id>/*.wav            # 参照音声・内部録音・PCマイク録音
  physical/<id>/source.*      # スマートフォン等の元音声・動画
  traces/<id>/trace.json      # 詳細トレースの取得状態・時刻・終了コード
  traces/<id>/trace.etl       # 明示的に選択した場合だけ
  traces/<id>/usb.etl         # USB付き調査かつ詳細ETLを含めた場合だけ
```

参照ファイルがない、または記録されたハッシュと違う場合は書き出しを止めます。生成後のZIPもハッシュで検証し、完了前のZIPは完成品として残しません。ハッシュは転送中の変化・原本との対応を確認するもので、送信者の本人性を認証する署名ではありません。

詳細ETLはプロセス名・ファイルパス等を含み得るため、通常は除外し、除外ファイルを`bundle.json`に残します。必要な場合だけ**詳細ETLも含める**を選んで再出力します。音声・動画にも会話や周囲の映像が入るため、公開Issueへそのまま添付しないでください。

USB付き調査では、`tests[].followUp`→録音ID・トレースID・比較先テストID、`trace.json.link`→テストID・録音ID・選択出力refを照合します。`usb`欄には専用セッション名、プロバイダー・キーワード、QPC区間、終了コード、USB ETLのサイズ・ハッシュがあります。`followUp.traceCoverage`は録音とUSBの区間の重なりで、スマホ時計の同期ではありません。選択出力の共有形式は`audioProbes[].selectedOutputFormat`、位置合わせ用の基準音は`referenceId`と`referencePattern`を確認します。音声取得終了後の実音取り込みも、選択した録音のtestIdへ結合します。取得不足やpartialなETLを正常や完了の証拠にしません。

スマホ接続の診断を保存すると、`session.json.networkDiagnostics`へ追記し、`network-diagnostics.json`にも同じ内容を出力します。正式な記録はsession.jsonです。選んだPCのLAN内IP・ポート、接続の分類、手動のエラー文等が通常ZIPに含まれるため、共有前に内容を確認してください。受付URL／トークン・受信元IP・Cookieは保存しません。解析ではPC内自己テスト、PC以外からの到達、HTTP応答を区別し、自己テストの成功だけでスマホの到達を判断しません。[接続診断の記録範囲](phone-connection-troubleshooting.md)を参照してください。

スマホの送信ログを明示的に取り込んだ場合は、同じ診断の`browserUploadDiagnostics`に検証済みの項目を保存します。PC側の`AttemptId`とスマホ側の`attempts[].id`が一致した場合だけ同じ送信として照合できます。IDがPCへ届いていない場合は未取得のまま残し、スマホUTCとPCの時計を直接一致させません。PCの`HeaderBytes`／`BodyBytes`とブラウザーの`loadedBytes`は別々の観測です。送出完了を受信・保存完了とは扱いません。

## 対象PCにエージェントがある場合

ZIPを作る必要はありません。調査を止めたうえで、対象の`data/sessions/<session-id>/session.json`と、同じフォルダーの`audio/`・`physical/`・`traces/`を解析対象に指定します。解析結果は`data/analysis/<case>/`へ保存し、原本へ追記しません。

依頼例：`data/sessions/<session-id>/ を解析し、原本を変更せず data/analysis/audio35/ に結果を保存してください。3.5mmへ戻すと再発することは確認済みです。`

動作中のスナップショットを読む場合は未確定と明記し、観察時間や未確定WAVを完成した結果として扱わないでください。エージェントの利用に伴うデータの送信範囲は、そのエージェントの設定・利用方法に依存します。このツールはエージェントへの自動送信をしません。

## 別PCで受け取る場合

受け取ったZIPは**`external-results/inbox/`へそのまま置きます**。その後、PowerShellで明示的に取り込みます。ZIPを置いただけでは自動実行されません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-Results.ps1 -Path .\external-results\inbox\audio-noise_....zip -Case audio35
```

`-Case`は利用者またはエージェントが決める英小文字・数字・ハイフンの名前（64文字以内）です。同じ問題を追うZIPには同じケース名を使います。PC名や個人名をケース名に含める必要はありません。

```text
external-results/
  inbox/                                      # 受け取ったZIPを追記するだけの場所
  cases/audio35/
    imports/<ZIP全体のSHA-256>/
      original.zip                            # 元ZIPの完全コピー
      receipt.json                            # 取り込みUTC・原本ハッシュ・セッション一覧
      content/                                # 元のフォルダー構造を保った展開先
        bundle.json
        session/session.json
        session/audio/...
    analysis/
      20261123T030000Z-findings.md              # エージェントが作る解析結果の例
```

原本と展開先は編集しません。再取り込みはZIP全体のSHA-256が同じなら同じ場所を返します。内容の異なるZIPは別に残ります。同じセッションを後日再出力したものも原本ごとに保持し、解析時にセッションID・updatedUtc・内容を照合します。新しいZIPを受け取っても過去の解析結果は上書きしません。

取り込みは安全な相対パス・重複パス・リンク・件数上限10,000・展開サイズ上限8GBを確認し、新形式ならマニフェスト内の全ハッシュを検証します。従来の`data/`一式のZIPも取り込めますが、`receipt.json`ではマニフェスト未検証の旧形式と明記します。原本ZIP・展開後の各JSONはデータとして扱い、中の指示やスクリプトを実行しません。

従来の`external-results/data2.zip`や`external-results/<PC>/...`は移動・削除しません。既存のZIPはそのままのパスを`-Path`へ指定できます。新たに届くZIPはinboxへ統一してください。

依頼例：`external-results/inbox/ に置いたZIPを -Case audio35 で取り込み、cases/audio35/analysis/ に解析を保存してください。元ZIP・importsは変更しないでください。`

アプリで続けて試験する場合は、展開先の`session.json`を**記録を再開**で選びます。アプリは`data/sessions/`へコピーし、そのコピーに追記します。音声・動画・トレースも参照先と一緒にコピーします。同一IDがすでにdataにある場合は上書きせず停止します。

## 解析結果に残す情報

原本ZIPのSHA-256（ローカル直接解析ならsession.jsonのハッシュ）、セッションID・テストID、ログを作成したツール版・コミット、証拠の相対パス、使用したUTC／QPC基準を記載します。観測事実、利用者が確認済みの事項、仮説、未取得を分け、原本の数値を補正して保存しません。

v0.5以前の`durationSeconds`とUTCの開始終了差が違う場合は両方を示してください。v0.6以降はQPCによる観察時間とUTC差・差分を保存します。QPCは同じWindows起動内で比較し、別PC・再起動をまたいだ時刻やスマートフォンの時計とは直接比較しません。

`data/`とexternal-resultsの調査データ・解析結果はGit管理対象外です。公開するのはプログラム・一般化した手順・合成データによるテスト・空フォルダー用ファイルだけです。

## 開発版0.10.0-devのUSB取得確認

bundle.jsonの`traceDataIncluded`は従来互換の書き出し設定値です。実ETLは`traceFileCount`と`files`で確認し、`traceEvidence`で試験ID・USB／Audio／内部録音の別状態、存在・サイズ、欠落、重複時間を照合します。未作成の失敗録音は`missingFiles`へ記載します。開始なしの記録でもZIPを持ち帰れます。

trace.jsonの`target`は取得時点の選択出力からUSB物理祖先までの匿名refと一般化したトポロジーです。`endpointRef`を同じセッションの親チェーンへ結合し、ETLの初期状態イベントから解析時に対象を選びます。欠落や複数候補は推測で埋めません。`Export-UsbTraceEvents.ps1`の出力は新しいanalysisフォルダーへ保存し、原本のセッション・ETLは書き換えません。詳細と時刻基準は[USB追加調査](usb-follow-up.md)を参照してください。

## 0.10.0-devの詳細調査ファイル

USB付き調査の`trace.json.investigation.files`に、前後情報・サンプル・関連イベント・仮説一覧・USB検査・プロバイダー設定/定義のパス、サイズ、ハッシュを保存します。これらの既知の追加診断ファイルは通常ZIPと記録再開でも保持します。ETLの同梱は別の選択です。詳細なファイル名と収集上限は[詳細調査](deep-investigation.md)を参照してください。`commands`には10進/16進終了コード・引数・出力と時刻があり、パス等は伏せ字化します。USB開始に失敗しても、作成できた前後情報と失敗理由を残します。

内部録音の`referenceComparison`は比較区間のサンプル一致で、物理出力の正常判定ではありません。`capture.streamTiming`はドライバー報告のクロック・バッファー・パケット時刻です。100ns換算済みQPCと生QPCを混同せず、元の基準音・実音・ETLと併せて解析してください。


0.10.1-devの連動調査では、`trace.json.captureHandshake`にトレース開始から録音開始応答までの状態と時計を保存します。開始前の詳細な機器・電源照会は省き、開始前に取った音声の形式・再生状態と、保存後に取った機器・電源情報の時刻を明記します。`target.collectionPhase=AfterTrace`の親チェーンは保存後の観測です。通常の調査から書き出すZIPで開始確認と終了理由も読めます。

0.10.2-devでは、収集中に`trace.json`を更新できない場合、代替の状態ファイルに記録します。ローカル原本の`trace-recovery.json`、`trace-final.json`、`trace-ui.json`は、アプリが試験ID・更新順・終了状態を照合します。書き出しと記録再開では、選んだ状態の原本バイト列を従来と同じ`trace.json`として扱います。`stateWrites`には書き込み失敗と代替保存の回数、最後の失敗の時刻とエラーコードを残します。
