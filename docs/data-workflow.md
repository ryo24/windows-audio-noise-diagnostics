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
  audio/<id>/*.wav            # 参照音声・内部録音・PCマイク録音
  physical/<id>/source.*      # スマートフォン等の元音声・動画
  traces/<id>/trace.json      # 詳細トレースの取得状態・時刻・終了コード
  traces/<id>/trace.etl       # 明示的に選択した場合だけ
```

参照ファイルがない、または記録されたハッシュと違う場合は書き出しを止めます。生成後のZIPもハッシュで検証し、完了前のZIPは完成品として残しません。ハッシュは転送中の変化・原本との対応を確認するもので、送信者の本人性を認証する署名ではありません。

詳細ETLはプロセス名・ファイルパス等を含み得るため、通常は除外し、除外ファイルを`bundle.json`に残します。必要な場合だけ**詳細ETLも含める**を選んで再出力します。音声・動画にも会話や周囲の映像が入るため、公開Issueへそのまま添付しないでください。

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
