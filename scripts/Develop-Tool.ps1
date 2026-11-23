param([Parameter(Mandatory=$true)][string]$RepositoryRoot,[Parameter(Mandatory=$true)][string]$UpdaterPath,[ValidateSet('Start','Update')][string]$Mode='Start',[switch]$NoPause,[switch]$SmokeTest)
$ErrorActionPreference='Stop';$code=1;$controlLock=$null;$staging=$null
function Invoke-DevelopGit {
    param([string]$Directory,[string[]]$Arguments)
    $encoding=[Console]::OutputEncoding
    try{
        [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
        $value=& git -C $Directory @Arguments
        if($LASTEXITCODE -ne 0){throw 'Gitの処理を完了できませんでした。既存のコードと調査記録は保持しています。'}
        return $value
    }finally{[Console]::OutputEncoding=$encoding}
}
try{
    $root=(Resolve-Path -LiteralPath $RepositoryRoot).Path
    if(-not (Get-Command git -ErrorAction SilentlyContinue)){throw 'Git for Windowsが必要です。'}
    if(-not (Test-Path -LiteralPath (Join-Path $root '.git'))){throw 'Gitでクローンしたフォルダーで実行してください。'}
    $branch=Invoke-DevelopGit $root @('branch','--show-current')
    $origin=Invoke-DevelopGit $root @('remote','get-url','origin')
    $data=Join-Path $root 'data'
    if((Test-Path -LiteralPath $data) -and ((Get-Item -LiteralPath $data -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'リンクされたdataフォルダーには開発版を配置しません。'}
    [IO.Directory]::CreateDirectory($data)|Out-Null
    try{$controlLock=[IO.File]::Open((Join-Path $data 'develop-launch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw '別の開発版の起動・更新が実行中です。完了してから再実行してください。'}
    $target=if($branch -eq 'develop'){$root}else{Join-Path $data 'develop-tool'}
    if(Test-Path -LiteralPath $target){
        if((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'リンクされた保存先は使用しません。'}
        if(-not (Test-Path -LiteralPath (Join-Path $target '.git'))){throw '開発版の保存先に既存ファイルがあります。上書きせず停止しました。'}
        $actualRoot=Invoke-DevelopGit $target @('rev-parse','--show-toplevel')
        if([IO.Path]::GetFullPath($actualRoot) -ne [IO.Path]::GetFullPath($target)){throw '別のリポジトリを指す保存先は使用しません。'}
        $targetOrigin=Invoke-DevelopGit $target @('remote','get-url','origin')
        if($targetOrigin -ne $origin){throw '開発版のoriginが元フォルダーと異なるため停止しました。'}
    }else{
        $staging=Join-Path $data ('.develop-tool-download-'+[guid]::NewGuid().ToString('N'))
        Write-Host '開発版developを別フォルダーへ取得しています。mainと既存の調査記録は変更しません。'
        & git -c credential.interactive=false clone -c core.longpaths=true --branch develop --single-branch -- $origin $staging
        if($LASTEXITCODE -ne 0){throw 'developを取得できませんでした。通信・公開先を確認してください。'}
        if(Test-Path -LiteralPath $target){throw '保存先が作成されたため、上書きせず停止しました。'}
        Move-Item -LiteralPath $staging -Destination $target;$staging=$null
    }
    & $UpdaterPath -RepositoryRoot $target -Branch develop -NoPause
    if($LASTEXITCODE -ne 0){throw '開発版を更新できなかったため起動しません。変更・通信・起動中のアプリを確認してください。'}
    Write-Host ('開発版フォルダー: '+$target)
    Write-Host ('開発版の調査記録: '+(Join-Path $target 'data'))
    if($target -ne $root){Write-Host '以前の調査を使う場合は「保存した記録を再開」で元のmainのsession.jsonを選択できます。原本は保持します。'}
    if($Mode -eq 'Start'){
        $start=Join-Path $target 'scripts\Start-Diagnostics.ps1'
        if(-not (Test-Path -LiteralPath $start)){throw '開発版の起動スクリプトが見つかりません。'}
        if($SmokeTest){& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $start -SmokeTest}
        else{& powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $start}
        if($LASTEXITCODE -ne 0){throw '開発版がエラーで終了しました。'}
    }
    $code=0
}catch{
    Write-Host ('開発版の起動・更新を中止しました: '+$_.Exception.Message) -ForegroundColor Yellow
}finally{
    if($controlLock){$controlLock.Dispose()}
    if($staging -and (Test-Path -LiteralPath $staging)){
        $allowed=[IO.Path]::GetFullPath($data).TrimEnd('\')+'\'
        $resolved=[IO.Path]::GetFullPath($staging)
        if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -match '^\.develop-tool-download-[a-f0-9]{32}$'){
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    if(-not $NoPause -and ($code -ne 0 -or $Mode -eq 'Update')){Read-Host 'Enterキーで閉じます'|Out-Null}
}
exit $code
