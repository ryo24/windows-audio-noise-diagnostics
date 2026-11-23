param([Parameter(Mandatory=$true)][string]$RepositoryRoot, [switch]$NoPause,[ValidateSet('main','develop')][string]$Branch='main')
$ErrorActionPreference='Stop'
$exitCode=1
$lock=$null
try {
    $root=(Resolve-Path -LiteralPath $RepositoryRoot).Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Gitが見つかりません。Git for Windowsをインストールしてください。' }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw 'Gitでクローンしたフォルダーではありません。READMEのgit clone手順を使用してください。' }
    $data=Join-Path $root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    try { $lock=[IO.File]::Open((Join-Path $data 'tool.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw '調査ツールが起動中です。ツールを閉じてから更新してください。' }
    $currentBranch=& git -C $root branch --show-current
    if ($LASTEXITCODE -ne 0 -or $currentBranch -ne $Branch) { throw ('この操作の対象は'+$Branch+'ブランチです。開発版はstart-develop.cmd／update-develop.cmdを使ってください。ブランチの自動切替や変更の削除は行いません。') }
    $dirty=@(& git -C $root status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw 'Gitの状態を取得できませんでした。' }
    if ($dirty.Count -gt 0) { throw 'コードの変更または未追跡ファイルがあります。上書きせず停止しました。変更を退避・コミットするか別フォルダーへ新規クローンしてください。data内の記録はそのまま保持してください。' }
    $before=& git -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw '現在の版を取得できません。' }
    Write-Host ('origin/'+$Branch+'の更新を確認しています。調査データは変更しません。')
    & git -C $root -c credential.interactive=false fetch --no-tags origin $Branch
    if ($LASTEXITCODE -ne 0) { throw '更新を取得できませんでした。通信・公開先を確認してください。手元の版で調査を続けられます。' }
    & git -C $root merge-base --is-ancestor HEAD FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw '履歴が分岐しているか、ローカルに未公開コミットがあります。強制変更せず停止しました。別フォルダーへ新規クローンして確認してください。' }
    & git -C $root merge --ff-only FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw '更新を適用できませんでした。強制リセットは行っていません。表示されたGitのメッセージを確認してください。' }
    $after=& git -C $root rev-parse HEAD
    if ($before -eq $after) { Write-Host 'すでに最新版です。' }
    else { Write-Host ('更新しました: ' + $before.Substring(0,8) + ' -> ' + $after.Substring(0,8)) }
    $exitCode=0
} catch {
    Write-Host ('更新を中止しました: ' + $_.Exception.Message) -ForegroundColor Yellow
} finally {
    if ($lock) { $lock.Dispose() }
    if (-not $NoPause) { Read-Host 'Enterキーで閉じます' | Out-Null }
}
exit $exitCode
