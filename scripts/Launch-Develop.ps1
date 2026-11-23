param([ValidateSet('Start','Update')][string]$Mode='Start',[switch]$NoPause,[switch]$SmokeTest)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$temporary=[IO.Path]::GetTempPath();$id=[guid]::NewGuid().ToString('N')
$runner=Join-Path $temporary ('audio-noise-develop-'+$id+'.ps1')
$updater=Join-Path $temporary ('audio-noise-develop-update-'+$id+'.ps1')
$code=1
try {
    # Run detached copies so a develop checkout can update these scripts too.
    [IO.File]::Copy((Join-Path $PSScriptRoot 'Develop-Tool.ps1'),$runner)
    [IO.File]::Copy((Join-Path $PSScriptRoot 'Update-Tool.ps1'),$updater)
    & $runner -RepositoryRoot $root -UpdaterPath $updater -Mode $Mode -NoPause:$NoPause -SmokeTest:$SmokeTest
    $code=$LASTEXITCODE
}catch{
    Write-Host ('開発版の起動・更新を中止しました: '+$_.Exception.Message) -ForegroundColor Yellow
    if(-not $NoPause){Read-Host 'Enterキーで閉じます'|Out-Null}
}finally{
    foreach($path in @($runner,$updater)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
}
exit $code
