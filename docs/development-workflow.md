# 開発と配信の運用

## ブランチの役割

| ブランチ | 内容 | 更新方法 |
| --- | --- | --- |
| `main` | 他の利用者・別PCへ配る検証済みの版。GitHubの既定ブランチ | 利用者は`update.cmd`。開発者は`develop`からの配信PRで反映 |
| `develop` | 開発中の変更・整備途中の一般的な手順 | 通常の開発コミット・push。これだけではmainへ配信されない |
| `codex/...`等 | 個別作業を分ける短期ブランチ | developから作り、developへのPRで取り込む |

個人の調査ログ・ZIP・録音・動画・ETL・ケース別解析は、**どのブランチにも追加しません**。[データ管理](data-workflow.md)に従い、Git管理対象外のdata／external-resultsに保管します。developも公開ブランチです。

## 利用するPC

```powershell
git clone --branch main --single-branch https://github.com/ryo24/windows-audio-noise-diagnostics.git
cd windows-audio-noise-diagnostics
.\start.cmd
```

更新時はアプリを閉じて`.\update.cmd`を実行します。取得先は常に`origin/main`で、早送りできるcleanなmainだけを更新します。developや別ブランチへの自動切替、強制reset、ファイルの自動削除はしません。GitHubの既定ブランチもmainを維持します。

## 開発するPC

利用用とは別のフォルダーへクローンします。

```powershell
git clone --branch develop https://github.com/ryo24/windows-audio-noise-diagnostics.git windows-audio-noise-development
cd windows-audio-noise-development
git status
git pull --ff-only origin develop
```

開発中はdevelopに留まり、必要なら`git switch -c codex/<作業名>`で作業を分けます。未コミットの変更があるときは内容を確認して保存し、無条件のpullやresetをしません。公開可能なコード・一般化した説明・合成テストだけを対象パス指定でコミットします。PRの取り込み先はdevelopです。`update.cmd`で開発コードを更新しません。

同じクローンを使う場合は、別の作業ツリーでも分けられます。

```powershell
# developの作業場所から実行。mainが他で開かれていないことを先に確認する
git fetch origin
git worktree add ..\windows-audio-noise-main main
# main側がcleanで、早送りできる場合だけ
git -C ..\windows-audio-noise-main merge --ff-only origin/main
```

今回の作業フォルダーはdevelopです。配信確認用のmainは、このクローンの`artifacts/main-distribution/`に独立したworktreeとして置いています。artifactsはGit管理対象外です。通常の利用者がこのworktreeを作る必要はありません。

## mainへ配信する

1. developの差分とCIを確認します。コード・手順・データ形式の互換性を検証し、利用者向けREADMEのリンク切れや、未完成の別件が混在していないか確認します。未完成の別件がある間は、そのままmainへ取り込みません。公開可能な範囲をdevelopで整えてから進めます。
2. アプリや更新処理の変更を配信するときにVERSIONを更新します。開発コミットのたびにはバージョンを上げません。
3. **取り込み元develop、取り込み先main**のPRを作り、公開される動作・検証・制限を説明します。Windows checksとBranch policyが成功してから、merge commitで取り込みます。継続使用するdevelopでは履歴の重複を避けるためsquash／rebase mergeを使いません。
4. mainのCI成功後、利用用クローンでupdate.cmdを実行し、版の更新と既存dataの保持を確認します。
5. 開発用developへ戻り、cleanであることを確認して`git fetch origin`、`git merge origin/main`を行い、公開履歴を取り込みます。競合は内容を確認して解決し、履歴を強制変更しません。

mainの保護設定は、PR経由、最新のmainに対する`windows`と`Branch policy`の成功、管理者への適用、force push・削除の禁止を使います。Branch policyは同じリポジトリのdevelop以外からmainへのPRを拒否します。レビュー人数は必須にせず、一人での保守でも検証後に配信できます。この保護を迂回して開発コミットを直接配信しません。

v0.8.1で運用を導入する初回だけ、共通の運用・更新案内・検証をmainへ早送りし、その後に保護設定を有効にしました。整備中だったtroubleshootingガイドとREADMEのリンクはdevelop側の別コミットへ保存し、初回の配信対象には含めていません。公開済みのv0.8.0の履歴は書き換えていません。

## 更新時に未追跡ファイルがあると言われたら

update.cmdはMarkdown等の調査ガイドを生成する処理ではありません。mainに存在する追跡ファイルはGitの更新で取得されますが、未追跡ファイルや手元の編集は上書きしないため更新を止めます。ブランチを分けても、既に別PCへ置かれたファイルは自動では消えません。

`git status --short`と`git diff`で対象を確認します。開発用の変更は開発フォルダーのdevelopへ保存し、個人の記録はdata／external-resultsへ保管します。移動元をすぐ削除せず、別のcleanなmainクローンで起動・データの再開を確認する方法が確実です。原本保持のため、`git clean -fd`や`git reset --hard`で一括消去しないでください。
