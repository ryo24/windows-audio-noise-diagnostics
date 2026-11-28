# NucBox G3 Plusの内蔵3.5 mm出力ノイズの引き継ぎ

2026年11月28日（日本時間）時点。対象PCでWindowsの機能更新を開始したと利用者から報告があった。更新の完了、適用されたビルド、症状への効果は未確認。**次は対象PCで更新結果を確認し、内蔵3.5 mm出力のノイズが普段の使い方でも再発しないかを確かめる。**

利用者の目標は、内蔵3.5 mm出力を安定して使うこと。PC全体の再起動、一時的なデバイスの再初期化、HDMIへの切り替えは従来の回復・回避手段。修正できたかは、以前と同じ経路で、時間が経っても周期ノイズが戻らないかで判断する。

## ミニPC側での開始手順

1. 利用版のフォルダーにいる場合は `update-develop.cmd` を実行し、取得された `data/develop-tool/` をCodexで開く。すでに `develop` のクローンを使っている場合は、そのフォルダーで更新して開く。文書は `docs/handoffs/nucbox-g3-plus-audio.md`。
2. Windowsの更新完了後に `winver` とWindows Updateの更新履歴を確認する。報告時点では26H2への機能更新を案内した。USB音声修正を含む累積更新を適用した目安は、26H2ならビルド `26300.9974` 以降、25H2なら `26200.9974` 以降。更新が途中・失敗・24H2のままなら、画面の状態やエラーコードを確認する。
3. 下の読み取りコマンドで、現在のドライバーとWindowsにあるドライバーファイルの版を控える。ミニPC本人であることも確認する。録音時の出力は **Speakers (USB Audio and HID)**。表示名は言語設定等で変わるため、機器IDと選択した出力の親子関係で照合する。
4. 同じ内蔵3.5 mm、同じ48 kHz設定で、まず Windows の `mmsys.cpl` にある再生デバイスのテスト音を確認する。次に、普段の再生アプリを以前症状が出た条件や稼働時間で使う。**更新直後だけ正常な場合は「経過観察」**とする。

### 更新後に控える情報

```powershell
$bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
[pscustomobject]@{
    Manufacturer = $bios.SystemManufacturer
    Model = $bios.SystemProductName
    Edition = $os.EditionID
    Release = $os.DisplayVersion
    Build = "$($os.CurrentBuildNumber).$($os.UBR)"
}

Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='MEDIA'" |
    Where-Object { $_.DeviceID -like 'USB\VID_0573&PID_1573&MI_00\*' } |
    Select-Object DeviceName, DeviceID, DriverProviderName, InfName, DriverVersion, IsSigned

Get-Item -LiteralPath "$env:SystemRoot\System32\drivers\usbaudio.sys" |
    Select-Object Name, @{Name='FileVersion'; Expression={$_.VersionInfo.FileVersion}}
```

この確認は読み取りのみ。ドライバーパッケージの版、システム上のファイルバージョン、Windowsのビルドはそれぞれ別の値。結果を共有するときは、実機の完全なインスタンスIDなど個体を識別できる項目を公開Gitへ転記しない。

## 症状と試したこと

| 項目 | これまでの確認 |
| --- | --- |
| 機器・出力 | GMKtec NucBox G3 Plus、内蔵3.5 mm端子、Windowsの共有モードは48 kHz。実際に選択した再生出力の親を辿ると、USB音声機能 `USB\VID_0573&PID_1573&MI_00`、リビジョン付きIDは `USB\VID_0573&PID_1573&REV_8007&MI_00`。その親は同じVID/PIDのUSB複合デバイス。 |
| 症状 | 音声再生中に周期的なノイズや音量の落ち込み。動画を止めている間は聞こえなかったとの申告。Windowsの48 kHzテスト音でも再現した。44.1 kHzは選択できなかった。 |
| 出力経路 | 利用者はHDMI出力では症状を回避でき、3.5 mmへ戻すと再発することを確認済み。スピーカー交換、給電条件変更、有線イヤホンの3.5 mm直結でも同様の症状を確認した。 |
| Bluetooth | Bluetoothキーボードが接続されていない状態でも再発した。キーボード接続は再現に必須ではない。 |
| ソフト側の回復操作 | Windows Audioサービスの再起動後も、テスト音にノイズが残ったとの申告。デバイス マネージャーの音声機能を無効・有効にした前後の試験も症状が続いた。 |
| PC再起動 | 再起動後は正常に戻ったことを利用者が確認。同じ内蔵出力の正常実音も残っている。再起動直後だけで改善判定はできない。 |
| 親USB機器の再初期化 | `49786eb`（PR #7）で[復旧コマンドと手順](../troubleshooting/usb-audio-recovery.md)をdevelopへ追加した。手元の記録では対象PCでの実行結果は未確認。一時復旧を調べる操作のため、今回の更新後の判定に先立って実行する必要はない。 |

経路の判定には録音時に実際に選択した出力を使う。Windowsの既定出力や記録の手入力欄と異なる試験があった。

## 録音とトレースで分かったこと

### 11月23日 — 発生時の実音と再起動後の正常音

- 発生時のスマホ実音で、440 Hzが約431 Hzに下がり、約0.56～0.58秒ごとに音が弱まった。同時に録ったPC内部ループバックは基準音と一致した。PCのマイク入力を使わずに行った試験でもこの差が出た。
- 正常対照は同じ3.5 mm出力で、再起動から約7分後。440 Hzは約440 Hz、660 Hzは約660 Hz、1,000 Hzは約1,000 Hzで、周期的な落ち込みなし。発生時と正常時の48 kHz設定、ドライバー版、基準音は一致した。**正常実音は取得済み**。この正常試験のUSB ETLはない。
- 発生時の従来WPRでは開始時のAudioグリッチが1件あった。音量低下に繰り返し対応するグリッチや長いDPC/ISRは確認できなかった。このWPRにはUSB転送専用イベントがなく、そこからUSB転送の正常・異常は判定できない。

### 11月27日 — 音声機能だけの無効・有効と、収録の改善

- リセット前後の内部録音が2本。後の試験だけにスマホ実音があり、約432.4 Hz、約0.65秒間隔の落ち込みを確認した。内部録音は両方とも基準音と一致した。この書き出しはUSBモードが未選択で、詳細ETLを含める指定があっても実ETLは入っていなかった。
- `0.9.1-dev` でUSB＋Audioの開始を確認してからテスト音を流し、取得状態と実ETLの有無を表示するよう改善した。その後、トレース状態書き込み・重複開始・録音開始の問題を修正し、`0.10.2-dev`（`f5d6221`）で次の同時取得に成功した。

### 11月28日 — ノイズ発生中のUSB、Audio、内部録音、スマホ実音の同時取得

- USB・AudioトレースとPC内部録音の重なりは約30.009秒。同じ試験にスマホ録音が紐づいている。実音では440 Hz→約432.1 Hz、660 Hz→約648.1 Hz、1,000 Hz→約981.9 Hz。約1.8%の音程低下と約0.62秒間隔の落ち込みが再現した。
- 自動USB抽出は対象未解決と表示した。USBHUB3の初期状態イベントに出たVID/PID・ポート・コントローラーのPCI位置を照合し、UCXの対象デバイスとパイプを手動で特定した。対象の等時性転送開始・完了は各3,036件。完了のIRP NTSTATUSは全件0。完了間隔は中央値約10.000 ms、最大約10.072 ms。**リクエスト完了の周期的な穴は見えなかった**。個々のパケットのステータス・実転送長・同期フィードバックはこの記録から分からない。
- 今回の内部WAVには開始時以外にも約9.780・11.192・12.715秒に不連続があり、付近でバッファパディング0を記録した。時刻合わせの無音も補われた。安定した区間では、Windowsが報告する再生クロックは公称値付近で、内部録音には基準波形に一致する窓が多い。スマホの音程低下は、これらの安定区間に対応する音の並びにも続いた。
- 最新試験のAudio ETL自体は保存済み。解析PCではKernelStreamingEndpointを名前で解決できず、上記の内部所見はWASAPI計測とWAVによる。ETLとスマホ時刻のサブ秒単位の直接照合は未確定。

**現時点の仮説**は、USB音声経路上のサンプル数と再生タイミングの不整合。標準ドライバーの動作、転送中のフレーム数や同期、機器側のクロックやファームウェア、アナログ経路の影響を区別しきれていない。USBのリクエスト成功やクリーンなループバックだけでは根本原因は確定しない。

## なぜWindowsを更新しているか

ログでは **Windows 11 Pro 24H2、OSビルド `26100.9711`**。内蔵3.5 mm側のUSB音声機能はMicrosoft標準の `usbaudio` サービス、INFは `wdma_usb.inf`、ドライバー版は `10.0.26100.9457`。24H2 Home/Proの更新提供終了後、Microsoftは11月10日の **KB5132061** でUSB Audio Class 1.0の既知問題を修正した。公式x64ファイル一覧に更新された `USBAUDIO.sys`（`10.0.26100.9974`）と `wdma_usb.inf` が載っている。既知問題の公表症状は起動失敗・無音などで、今回の周期ノイズへの効果は未確認。24H2向けKBの対象はEnterprise/Education。Proの対象PCではサポート対象のWindowsへ機能更新して、その版の累積更新を適用する。Windows Updateで機能更新が表示されず、公式インストール アシスタントから開始する方法を案内した。利用者は更新開始を報告済み。[24H2の更新終了](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/10/kb5127648-windows-11-24h2-25h2-26h2-security-update) [KB5132061と適用対象](https://support.microsoft.com/en-us/servicing/os/windows-11/2026/11/kb5132061-windows-11-24h2-25h2-26h2-security-update) [Microsoft公式ファイル一覧](https://download.microsoft.com/download/d2b8ce92-7b1b-413d-83e3-f6c5cef48d05/5132061.csv) [Windows 11公式ダウンロード](https://www.microsoft.com/ja-jp/software-download/windows11)

## 更新後の判断

| 観察結果 | 次に行うこと |
| --- | --- |
| 更新直後は正常 | ビルドとドライバー版を控え、以前発生していた稼働時間やスリープ復帰など、実際の発生条件まで観察する。 |
| 以前の発生条件でも再発しない | 条件と観察時間を残す。既存の正常録音を使い、追加録音やアプリ変更は必要に応じて判断する。 |
| ドライバー更新後も再発する | 更新後のビルド・音声機能のドライバー・発生時刻を記録する。必要なら対象の完全なインスタンスIDを使い、管理者端末で `pnputil /enum-devices /instanceid "<対象のインスタンスID>" /deviceids /drivers` を実行して、適合する候補と順位を確認する。 |
| 適合するメーカー修正が見つかる | 正確な機種、対象のUSB音声機能のハードウェアID、Windows版、署名、変更内容、戻し方を確認してから、その音声機能だけを比較する。GMKtecの配布ページにある機種用ドライバー一式から、症状に対応する個別パッケージはまだ特定していない。 |
| 適合する修正がなく再発する | メーカーへ内蔵音声機器の修正または点検を確認する。追跡を続ける場合、追加取得は更新後の再現を1回保存するか、パケットの実転送長・フレーム数・同期情報など、判断に必要な情報を取れる場合に絞る。 |

[MicrosoftのPnPUtil構文](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax#enum-devices) [GMKtecのドライバー配布ページ](https://www.gmktec.com/pages/drivers-and-software)

## 元データの探し方と取り扱い

- ミニPCの保存元はアプリの `data/sessions/`。利用版から取得した開発版で保存していれば、利用版フォルダーから見て `data/develop-tool/data/sessions/`。既存セッションを継続するときはアプリの「記録を再開」で選ぶ。
- 別PCに移したZIPは解析側の `external-results/inbox/`、検証済みの展開データは `external-results/cases/audio35/imports/`、波形・ETLの解析メモは同ケースの `analysis/` にある。11月23日の正常時、11月27日の無効・有効、11月28日の `0.10.2-dev` 同時取得を対照として選べる。代表メモのファイル名は `20261123-normal-after-restart.md`、`20261127-audio-device-reset.md`、`20261128-usb-audio-physical.md`。ミニPC側にコピーがないときは必要なものだけをローカルで移す。
- 原本ZIP、録音、ETL、セッションJSON、詳細なケース解析メモは公開Gitの対象外。この文書だけで当面の確認は開始できる。解析で原本を扱う場合、ハッシュ・試験ID・ツール版を控え、同じWindows起動内のみでQPCを比較する。スマホの時計はPCと同期済みとみなさず、番号付き基準音で対応を探す。[データの扱い](../data-workflow.md) [USB＋Audioの収録手順](../usb-follow-up.md)

この文書は開発版での引き継ぎ用。利用者が引き継ぎ完了を確認した後に削除できる。
