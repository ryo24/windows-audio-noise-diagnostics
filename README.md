# Windows Audio Noise Diagnostics

Windows PCで、再生中の音声ノイズを接続・給電・Bluetooth入力機器・再生アプリ・音声設定・ドライバーから切り分けるツールです。特定メーカーや機種には依存しません。日本語の操作画面、HTML報告書、JSONログ、Excelで読めるCSVを備えます。

**調査して結果を持ち帰る → ツールを改善 → update.cmdで最新版へ → 再調査**を想定しています。原因を断定する自動修復ツールではありません。

現在の比較手順は、3.5mmアナログ出力とUSB給電スピーカーのノイズを中心にしています。USB音声やBluetoothなども出力先として記録できますが、それぞれに特化した詳細診断は今後の拡張対象です。

音声の録音・聞き直し機能は、[テスト音声とループバック録音の手順](docs/loopback-capture.md)を参照してください。録音を使った調査では、WAVを含むセッションフォルダー一式を持ち帰ってください。

PCに挿したマイクや、QRで接続したスマートフォンから実音を取り込む場合は、[マイク・スマートフォンで記録する手順](docs/physical-capture.md)を参照してください。Cloudflareや外部の受信サーバーを使わず、同じLAN内で受け取れます。

PCが有線LAN・スマホがWi-Fiでも利用できます。QRのページを開けない場合は、[Android／Firefoxの接続診断](docs/phone-connection-troubleshooting.md)を参照してください。アプリから接続診断を保存してZIPに含められます。接続せず、スマホで撮った動画をUSBでPCへコピーして取り込む方法も使えます。

developの **0.9.1-dev** では、USB＋Audioの開始確認後にテスト音を流す入口と、試験ごとの取得状態・実ETL確認を追加しています。[開発版での最短手順](docs/usb-follow-up.md#対象pcでの最短手順)を参照してください。mainへの配信は別段階です。

## 最初の起動

対象PCに [Git for Windows](https://git-scm.com/downloads/win) がある状態で、PowerShellまたはコマンドプロンプトで実行します。

```powershell
git clone --branch main --single-branch https://github.com/ryo24/windows-audio-noise-diagnostics.git
cd windows-audio-noise-diagnostics
.\start.cmd
```

2回目からはフォルダー内の **start.cmd** をダブルクリックするか、PowerShellで `./start.cmd` を実行します。Windows 11・Windows PowerShell 5.1・.NET Frameworkを使用します。Excel、Python、Node.js、管理者権限は通常不要です。取得できない情報は「未取得」になります。

起動ファイルは、このプロセスだけでPowerShellの実行ポリシーを指定します。PC全体の実行ポリシーは変更しません。組織のポリシー、AppLocker、WDACなどで禁止されている場合は管理者へ確認してください。

再現時の構成、共通時間軸、詳細トレースについては[経路・ドライバー・時刻の手順](docs/reproduction-evidence.md)を参照してください。HDMIから3.5mmへ戻すと再発することが確認済みなら、症状欄へ記録し、同じ往復比較を必須にする必要はありません。

内部録音に現れない周期的な変化を追加調査する場合は、**2 条件を設定 → 次の切り分け**を使います。USB＋Audioの同時取得、同じスマホでの良好出力の実音対照、形式変更の比較を準備できます。取得・録音の開始と終了は共通ボタンです。[USB転送と実音対照の手順](docs/usb-follow-up.md)を参照してください。

## 調査の進め方

v0.7以降は、**「1 準備する → 2 条件を設定 → 3 調査する → 4 聞き直し・結果 → 5 書き出す」**の順で操作します。[画面ごとの使い方](docs/user-guide.md)を参照してください。

1. **1 準備する**で、分かる範囲の機器・給電・確認済みの症状を記入し、**PC情報を収集して新規作成**。以前の記録は**保存した記録を再開**から開けます。BIOS確認は任意です。
2. **2 条件を設定**で「テスト音声」「普段のアプリの音」「録音なし」を選びます。録音ありなら出力・マイク・秒数と録音範囲を確認します。比較・Bluetooth・再生条件も必要に応じて入力します。
3. **3 調査する**の開始ボタンを**1回**押します。録音する方式では録音・観察・状態記録を一緒に開始します。別の録音開始ボタンはありません。ノイズが聞こえたら同じ画面の**ノイズが聞こえた**を押します。
4. **終了して結果を記録**で録音と観察を一緒に終了します。録音ありなら指定秒数でも自動終了し、結果入力へ進みます。録音なしでは10分を目安に観察します。
5. 結果を保存すると**4 聞き直し・結果**へ進みます。録音は調査時と別の出力でも聞き直せます。録音なしなら比較結果を確認します。
6. **5 書き出す**で報告書を確認し、**ZIPを書き出して場所を開く**からログ・録音・動画をまとめて持ち帰れます。

各比較の開始後に、再生セッション・音声デバイスとドライバー・起動／復帰情報・粗いCPU負荷を取得します。公式ドライバー比較では終了後にも構成を取り直します。テスト途中で閉じると中断として保存します。

Bluetoothの条件・入力状況は2の「Bluetooth（任意）」で記入します。状態は通常約10秒間隔、最大720回で記録します。通信量やキー内容は取得しません。条件を変えるときは一度調査を終了し、2へ戻って別の比較として開始してください。

### 比較する順番

機種を問わず使える手順と、プルリクエストでの追加方法は[音声ノイズの切り分けガイド](docs/troubleshooting/README.md)にまとめています。

| 比較 | 確認する点 |
| --- | --- |
| 現状の3.5mm → HDMI | 出力経路に依存するか |
| 3.5mmを維持し、USB給電だけ独立電源へ | スピーカー自体を替えても共通する給電経路が影響するか |
| [有線イヤホンを3.5mmへ直結](docs/troubleshooting/wired-headphones.md) | スピーカーへのUSB給電を介さなくても発生するか |
| 有線キーボードを維持し、Bluetoothの状態を比較 | 無線オン・オフ、キーボード接続・入力に伴う違い |
| 動画 → ローカル音声 | アプリ・通信・動画処理に依存するか |
| 音声拡張オフ、対応する別形式 | Windows音声設定の影響。別々に試す |
| 適合する公式ドライバー | 型番・ハードウェアIDと合致する版だけを手動で比較 |

スピーカーの電源は型番ごとの仕様に合うものを使ってください。Creative Pebbleは世代によって給電条件やUSB音声対応が違います。テレビのUSBは独立した電源とは条件が異なるため、区別して記録します。

**再起動直後だけ正常な場合、短時間の無発生は解決の証拠になりません。** 改善条件と元の条件を比較し、改善条件で再起動した後にも確認します。「記録とテストID」のIDを「比較先のテストID」に入力すると、その関連を残せます。

音声拡張を無効化して改善しなければ元へ戻し、形式変更を別テストにします。形式はデバイスが提供する選択肢のみを使い、48kHzがあれば候補にします。ドライバーの一括更新、BIOS更新、SpeedStep等の一括無効化は行いません。

### Bluetoothキーボードの影響を調べる

Bluetoothキーボードから有線へ替えてノイズが止まった場合でも、再起動やUSB接続構成の変更が同時に起きていれば、Bluetoothだけが原因とは決められません。**有線キーボードは全条件で接続したまま**、音声出力・スピーカー給電・素材・アプリ・音量を維持して、テスト10〜14を比較します。各条件の適用はテスト開始前に手動で行い、間に再起動を挟まないでください。

| テスト | 比較する条件 |
| --- | --- |
| 10. Bluetooth無線オフ | WindowsのBluetoothをオフ。有線のみ使用 |
| 11. 無線オン・キーボード電源オフ | Bluetoothをオン。対象のBTキーボードは電源オフ |
| 12. 接続・待機 | BTキーボードを接続し、入力せず待機 |
| 13. 入力中 | 同じ接続のまま、メモ帳などで30秒ごとに10秒程度入力 |
| 14. オフ再確認 | Bluetooth無線だけオフに戻し、再び比較 |

他のBluetooth機器の有無、Wi-Fi接続なども途中で変えず、変更した場合は備考に記録してください。改善が見えたらオフ→オン→オフをもう一巡します。Bluetooth無線を切る前に有線などの入力手段を確保してください。ツール自身は接続・切断・無線設定を変更しません。

対象のキーボードが今つながっていなくても「PC情報を収集」で始められます。Windowsに登録が残っている機器はペアリング済みとして取得できる場合がありますが、登録済みと接続中は区別します。ELECOMなどの特定メーカー・型番に判定を固定していません。必要ならモデル名を備考へ記録してください。

取得するのは、Windowsが公開するBluetooth無線のOn/Off/Unknown、Classic/LEのペアリング済みエンドポイントの接続フラグ、関連するアダプター・入力ノードとドライバー、System/Applicationに出たBluetooth関連の警告・エラーです。WinRTの無線列挙がプロセスのビット数や権限・機種により空になる場合も「オフ」と断定しません。PnPのStatus=OKも接続中の証拠にはしません。

**通信パケット数、再送回数、電波強度、打鍵内容やキーイベントは取得しません。** 接続中の機器が実際にどれだけ通信していたかは、この記録だけでは分かりません。レポートにはノイズ時刻に最も近いBluetooth取得時刻と時刻差を表示し、同時刻の通信を測定したかのようには扱いません。無線干渉・Bluetoothドライバーの処理遅延・USB系統の影響を区別するには、必要に応じて別途WPR/ETW等の詳細調査を行います。詳細トレースは明示的に開始した場合だけ取得します。[再現時の経路・ドライバー・時間軸とWPRの手順](docs/reproduction-evidence.md)を参照してください。

## 更新する

| コマンド | 動作 |
| --- | --- |
| `start.cmd` | 現在のフォルダーの版を起動 |
| `update.cmd` | mainの配信版だけを更新 |
| `start-develop.cmd` | developを取得・更新して起動 |
| `update-develop.cmd` | developを取得・更新（起動しない） |

開発版を試すときは **start-develop.cmd** をダブルクリックするか、PowerShellで`.\start-develop.cmd`を実行します。mainからは`data/develop-tool/`に別の開発版を自動で用意するため、手動のcloneやブランチ切替は不要です。以降も同じコマンドで最新developへ更新して起動できます。開発版の調査記録はそのフォルダー内の`data/`へ保存します。以前の記録は「保存した記録を再開」で元のsession.jsonを選べます。すでにdevelopを使っている場合は、そのフォルダーを更新します。変更・未追跡ファイル・履歴分岐・通信失敗があれば上書きせず停止し、更新に失敗した場合は起動しません。

調査ツールを閉じて **update.cmd** をダブルクリックするか、PowerShellで実行します。

```powershell
.\update.cmd
```

- `origin` の `main` を取得し、早送りできる場合だけ更新します。
- `develop`や作業用ブランチでは更新せず停止します。開発途中の変更を利用者へ配信しません。
- ローカルのコード変更、未追跡ファイル、未公開コミット、履歴分岐があれば、強制上書きせず停止します。
- 通信に失敗しても手元のコードと調査記録を保持します。通常の起動では更新確認も通信も行いません。
- 更新処理は一時コピーから実行し、更新スクリプト自身の更新にも対応します。
- `data/` はGit管理対象外で、更新しても保持します。独自ファイルもこの中へ置いてください。

変更・分岐で更新できない場合はコードの変更を確認するか、別フォルダーへ新規クローンしてください。過去の調査は旧フォルダーの `data/` を保持し、コピーした `session.json` を新しいツールから読み込めます。ログ形式に対応しない場合は、原本を書き換えずエラーを表示します。

### 旧名でクローン済みの場合

v0.2.0から、リポジトリ名と起動・更新ファイルを英数字名へ変更しました。既存フォルダーで次を実行してください。ローカルのフォルダー名や `data/` を変える必要はありません。v0.1.xのログもそのまま再開できます。

```powershell
git remote set-url origin https://github.com/ryo24/windows-audio-noise-diagnostics.git
git pull --ff-only
.\start.cmd
```

## データを書き出す・受け取る・解析する

テスト・録音・スマートフォン受付・詳細トレースを終了し、**5 書き出す**の**ZIPを書き出して場所を開く**を押します。現在のセッションのJSON・報告書・CSV・参照音声・録音・動画を`data/exports/`へZIP化し、エクスプローラーで生成したZIPを選択します。命名規則・ハッシュ検証・詳細ETLの選択・エージェントによる解析は[データ管理の手順](docs/data-workflow.md)を参照してください。

```text
data/
  sessions/<session-id>/       # このPCでの調査原本
  exports/                     # 持ち帰るZIP
  analysis/<case>/             # このPC上のエージェントが作る解析結果
external-results/
  inbox/                       # 外から届いたZIPをそのまま置く
  cases/<case>/imports/<sha>/   # スクリプトが原本コピー・展開・受領記録を保存
  cases/<case>/analysis/        # 受け取ったデータをエージェントが解析した結果
```

対象PCにエージェントがある場合は`data/sessions/<session-id>/`を直接解析できます。別PCで受け取る場合はZIPを`external-results/inbox/`へ置き、次のコマンドで取り込みます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Import-Results.ps1 -Path .\external-results\inbox\audio-noise_....zip -Case audio35
```

inboxとimportsの原本は編集せず、解析結果はanalysisへ保存します。既存の`external-results/data2.zip`や機種別フォルダーはそのまま保ち、既存ZIPのパスでも取り込めます。調査データ・ZIP・解析結果はGit管理対象外です。アプリで続行するときは、展開先の`session.json`を「記録を再開」で選び、`data/`へコピーした記録に追記します。

CSV・JSON・報告書の時刻はUTCです。日本時間は9時間を加算してください。v0.6以降は観察時間をQPCでも記録し、UTC差との食い違いを残します。CSVの自由入力はExcelの数式として評価されないよう処理します。

データを自動送信しません。音声録音・スマートフォンの取り込みは、対象の音声・映像を確認して明示的に操作した場合だけ行います。通常の音声調査ログへ閲覧履歴、ユーザー名、PC名、シリアル番号、IP/MACアドレスは保存しません。**「接続診断を保存」で保存を選んだ場合だけ、選択したPCのLAN内IPv4・ポート、接続分類、ブラウザー系統・メジャー版等を記録とZIPへ含めます。** 受信元IP・MAC・SSID・受付URL／トークン・Cookie・全User-Agentは保存しません。[記録範囲の詳細](docs/phone-connection-troubleshooting.md)を確認してください。デバイスのインスタンスIDはセッションごとに匿名化し、ドライバー照合には機種・製品を示すハードウェアIDを保存します。Bluetooth機器の名前・MACアドレス・生の機器IDは保存せず、匿名IDと接続状態を保存します。イベント本文は保存せず、関連するプロバイダー・ID・レベル・時刻だけを残します。

再生セッションにはプロセスIDと実行ファイルの名前を保存します。通常ログにウィンドウタイトル・コマンドライン・実行ファイルのフルパスは保存しません。詳細ETLはそれより広いシステム情報を含み得るため、明示的な取得と書き出しの選択を必要とします。

自由入力、デバイスの表示名には個人情報が含まれる可能性があります。共有前に内容を確認してください。**ログや画面写真をGitHubの公開Issueへそのまま貼り付けないでください。** `.gitignore` は誤追加を減らすもので、`git add -f` 等による公開を防ぐ仕組みではありません。

## わかること・限界

- 既定のWindows共有モードの形式とアクティブな共有再生セッションを取得します。DACの物理ビット深度、音声拡張の状態、アプリ個別の出力先をすべて自動確認するものではありません。
- イベントはSystem / Applicationそれぞれの最新500件までの重大・警告・エラーから、関連する名前のプロバイダーを抽出します。アクセスできない場合や上限に達した場合も記録します。関連イベントなしは正常の証明ではありません。
- 普通のWindowsログだけでは、実際のアナログノイズやDPC/ISRの遅延を確定できません。未解決時は「3 調査する → 詳細トレース（任意）」から60秒のWPR取得を選べます。USB転送レベルの詳細は追加の対象別ETWが必要です。
- 「改善」は利用者の観察です。候補と次の比較を表示し、回路不良や機種全体の設計不良を断定しません。
- 原因確定・改善の判断には、対象PCでの比較結果が必要です。機種を問わず動く構成ですが、すべてのPC・音声デバイスでの動作を保証するものではありません。

## 調査の根拠

基本情報の確認日：2026-11-16。Bluetooth API・調査情報の追加確認日：2026-11-19。ページや配布物は更新されるため、実機の型番と現行の公式情報を確認してください。

- [Microsoft公式の音声対処手順](https://support.microsoft.com/en-us/windows/hardware/audio/fix-distorted-or-crackling-audio-in-windows)：音声拡張、音声形式、ドライバー等の確認。
- [Microsoftの音声グリッチ解析資料](https://learn.microsoft.com/en-us/windows-hardware/test/assessments/results-for-the-streaming-media-performance-assessment)：DPC/ISR等の影響と詳細解析。
- [MicrosoftのRadio.GetRadiosAsync](https://learn.microsoft.com/en-us/uwp/api/windows.devices.radios.radio.getradiosasync?view=winrt-22621)：無線列挙と空の結果・プロセスアーキテクチャの制約。
- [MicrosoftのSystem.Devices.Aep.IsConnected](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-devices-aep-isconnected)：Windowsが公開する現在の接続フラグ。
- [MicrosoftのBluetooth調査資料](https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/testing-bluetooth-main)：追加のWPR/ETW解析が必要な場合の参考。

### 機種・製品別の参考情報

最初の調査対象はGMKtec NucBox G3 Plusでした。次の情報は該当製品向けの参考で、すべてのPCへ適用する手順ではありません。報告書では取得したPCメーカー名がGMKtecと判別できた場合だけGMKtec向けの情報を表示します。メーカー不明や他社PCでは、一般的な確認手順を案内します。

- [GMKtec公式FAQ](https://www.gmktec.com/pages/guides-how-to-tutorial)：再生中ノイズへのC-States無効化案内。実機への適用可否を確認し、すでにDisabledの場合は繰り返し変更しません。
- [GMKtec公式ドライバー配布元](https://www.gmktec.com/pages/drivers-and-software)：G3 / G3 Plus / G3 Proの取り違えを避けます。他社PCでは対象PC・音声機器メーカーの公式配布元を使ってください。
- [Microsoft Q&Aの利用者報告](https://learn.microsoft.com/en-us/answers/questions/3926875/windows-11-usb-audio-and-hid-audio-cracking)：GMKtecの近縁機種の体験談。メーカーが検証した修正情報ではありません。
- [Creative Pebble](https://jp.creative.com/p/speakers/creative-pebble)、[Pebble V3](https://jp.creative.com/p/speakers/creative-pebble-v3)：世代による給電・入力仕様の違い。

本プロジェクトは非公式で、PC・音声機器メーカーやMicrosoftの提供物ではありません。メーカーのドライバーやBIOSは再配布しません。

## 開発と検証

**利用・配信は`main`、開発・未公開の変更は`develop`**を使います。利用者用のフォルダーではコードを編集せず、開発は別フォルダーで行ってください。開発の保存・PR・配信・既存の未追跡ファイルの扱いは[開発と配信の運用](docs/development-workflow.md)を参照してください。`develop`へのpushだけでは`update.cmd`の配信内容は変わりません。

UIの構成・操作・状態遷移を変更する前に、[UI設計の方針](docs/ui-design-policy.md)を参照してください。設計上の判断基準と変更時の確認項目をまとめています。利用者向けの手順は[操作ガイド](docs/user-guide.md)です。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-DataTests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-IntegrationTests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Start-Diagnostics.ps1 -SmokeTest
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Start-Diagnostics.ps1 -SmokeTest -ExerciseTraceWorkflow
```

テストは架空の情報と一時的なローカルGitリポジトリを使います。実機の設定を変更せず、データ・判定・保存と更新の保護動作を確認します。Run-DataTestsは音声出力がある場合に短い小音量の合成音で再生先の対応も確認し、WPRは偽コマンドで失敗処理を検証します。互換性のある項目追加ではJSONの形式番号を維持し、破壊的な変更では形式番号と旧ログの読み込み処理を更新してください。`main`への公開前にテストを通し、`VERSION`を更新してください。

## ライセンス

独自コードと説明書は [MIT License](LICENSE)。外部リンク先の資料やメーカー配布物には、それぞれの権利・利用条件が適用されます。

QR生成には同梱した[qrcodejs（MIT）](web/vendor/qrcodejs/LICENSE)を使用します。
