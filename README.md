# Windows Audio Noise Diagnostics

Windows PCで、再生中の音声ノイズを接続・給電・Bluetooth入力機器・再生アプリ・音声設定・ドライバーから切り分けるツールです。特定メーカーや機種には依存しません。日本語の操作画面、HTML報告書、JSONログ、Excelで読めるCSVを備えます。

**調査して結果を持ち帰る → ツールを改善 → update.cmdで最新版へ → 再調査**を想定しています。原因を断定する自動修復ツールではありません。

現在の比較手順は、3.5mmアナログ出力とUSB給電スピーカーのノイズを中心にしています。USB音声やBluetoothなども出力先として記録できますが、それぞれに特化した詳細診断は今後の拡張対象です。

## 最初の起動

対象PCに [Git for Windows](https://git-scm.com/downloads/win) がある状態で、PowerShellまたはコマンドプロンプトで実行します。

```powershell
git clone https://github.com/ryo24/windows-audio-noise-diagnostics.git
cd windows-audio-noise-diagnostics
.\start.cmd
```

2回目からはフォルダー内の **start.cmd** をダブルクリックするか、PowerShellで `./start.cmd` を実行します。Windows 11・Windows PowerShell 5.1・.NET Frameworkを使用します。Excel、Python、Node.js、管理者権限は通常不要です。取得できない情報は「未取得」になります。

起動ファイルは、このプロセスだけでPowerShellの実行ポリシーを指定します。PC全体の実行ポリシーは変更しません。組織のポリシー、AppLocker、WDACなどで禁止されている場合は管理者へ確認してください。

## 調査の進め方

1. スピーカー型番、給電先、確認済みの症状を入力。C-Statesは任意の記録で、未確認のまま利用できます。BIOS画像等でDisabledと確認できた場合は「Disabled（確認済み）」を選択します。BIOS設定は自動取得しません。
2. **PC情報を収集・新規調査**を押します。取得には数十秒かかる場合があります。
3. テストを選び、実際の出力先・給電先・アプリ・変更点・元の設定を記録。最初は現在の3.5mm出力で再現を確認します。
4. **テスト開始**を押してから再生。ノイズが聞こえるたびに **ノイズが聞こえた** を押します。
5. 各10分を目安に **テスト終了**を押し、「再現せず・改善・変化なし・悪化」を選びます。機材がなければ備考に理由を書いて **未実施を記録**。
6. **報告書を開く**で次の確認手順を読みます。過去の記録は **記録を再開**で `session.json` を選択して続行できます。

PC情報は初回収集時点の状態です。「公式ドライバー確認後の比較」ではテスト終了時に音声デバイス・ドライバー情報を再取得し、そのテストに保存します。OSや接続構成を大きく変えた場合は「新規調査」でPC情報を取り直してください。

各テストの「Bluetooth条件と取得状態」タブでは、無線状態・入力状況を手動で記録できます。これは自動取得と別の項目です。通常はテスト中に約10秒間隔でBluetooth状態を保存します。チェックを外すと開始側1回と終了後だけの取得になります。最大720回で定期記録を打ち切り、打ち切りを記録します。取得時間によって間隔は延びます。

テスト中の接続・条件は途中で変えず、変更するときは別のテストとして記録してください。ノイズを押し忘れた場合も備考に記録します。テスト途中で閉じると「中断」で保存し、異常終了後に再開した場合は最後の保存以降を観察時間に含めません。

### 比較する順番

| 比較 | 確認する点 |
| --- | --- |
| 現状の3.5mm → HDMI | 出力経路に依存するか |
| 3.5mmを維持し、USB給電だけ独立電源へ | スピーカー自体を替えても共通する給電経路が影響するか |
| 有線イヤホンを3.5mmへ直結 | スピーカーへのUSB給電を介さなくても発生するか |
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

**通信パケット数、再送回数、電波強度、打鍵内容やキーイベントは取得しません。** 接続中の機器が実際にどれだけ通信していたかは、この記録だけでは分かりません。レポートにはノイズ時刻に最も近いBluetooth取得時刻と時刻差を表示し、同時刻の通信を測定したかのようには扱いません。無線干渉・Bluetoothドライバーの処理遅延・USB系統の影響を区別するには、必要に応じて別途WPR/ETW等の詳細調査を行います。詳細トレースは自動取得しません。

## 更新する

調査ツールを閉じて **update.cmd** をダブルクリックするか、PowerShellで実行します。

```powershell
.\update.cmd
```

- `origin` の `main` を取得し、早送りできる場合だけ更新します。
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

## 結果を持ち帰る

**保存先を開く**から、対象の `session.json` をコピーして分析に渡してください。通常はこの1ファイルで足ります。報告書はオフラインで読めます。

```text
data/                         # ローカル専用・Gitには追加しない
  profile.json                # 次回入力用の設定
  sessions/<実行ID>/
    session.json              # 正式な記録。ツール版・コミット・各テストを含む
    report.html               # 読むための報告書
    tests.csv                 # Excelでも読める比較記録
    bluetooth.csv             # 各テストのBluetooth状態の時系列
```

CSVの時刻はUTCです。日本時間は9時間を加算してください。報告書とJSONにもUTCを明記しています。CSVの自由入力にはExcelの数式として評価されないための処理を行います。

データを自動送信しません。音声録音、閲覧履歴、ユーザー名、PC名、シリアル番号、IP/MACアドレスは収集対象にしません。デバイスのインスタンスIDはセッションごとに匿名化し、ドライバー照合には機種・製品を示すハードウェアIDを保存します。Bluetooth機器の名前・MACアドレス・生の機器IDは保存せず、匿名IDと接続状態を保存します。イベント本文は保存せず、関連するプロバイダー・ID・レベル・時刻だけを残します。

自由入力、デバイスの表示名には個人情報が含まれる可能性があります。共有前に内容を確認してください。**ログや画面写真をGitHubの公開Issueへそのまま貼り付けないでください。** `.gitignore` は誤追加を減らすもので、`git add -f` 等による公開を防ぐ仕組みではありません。

## わかること・限界

- 既定のWindows共有モードの形式を取得します。DACの物理ビット深度、音声拡張の状態、アプリ個別の出力先をすべて自動確認するものではありません。
- イベントはSystem / Applicationそれぞれの最新500件までの重大・警告・エラーから、関連する名前のプロバイダーを抽出します。アクセスできない場合や上限に達した場合も記録します。関連イベントなしは正常の証明ではありません。
- 普通のWindowsログだけでは、実際のアナログノイズやDPC/ISRの遅延を確定できません。未解決時は記録を分析し、必要に応じてWindows Performance Recorder等の詳細調査を選びます。
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

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Start-Diagnostics.ps1 -SmokeTest
```

テストは架空の情報と一時的なローカルGitリポジトリを使います。実機の設定を変更せず、データ・判定・保存と更新の保護動作を確認します。互換性のある項目追加ではJSONの形式番号を維持し、破壊的な変更では形式番号と旧ログの読み込み処理を更新してください。`main`への公開前にテストを通し、`VERSION`を更新してください。

## ライセンス

独自コードと説明書は [MIT License](LICENSE)。外部リンク先の資料やメーカー配布物には、それぞれの権利・利用条件が適用されます。
