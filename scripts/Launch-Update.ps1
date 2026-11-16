param([switch]$NoPause)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runner=Join-Path ([IO.Path]::GetTempPath()) ('audio-noise-update-' + [guid]::NewGuid().ToString('N') + '.ps1')
$code=1
try {
    [IO.File]::Copy((Join-Path $PSScriptRoot 'Update-Tool.ps1'),$runner)
    & $runner -RepositoryRoot $root -NoPause:$NoPause
    $code=$LASTEXITCODE
} catch {
    Write-Host ('更新処理を開始できませんでした: ' + $_.Exception.Message) -ForegroundColor Yellow
    if (-not $NoPause) { Read-Host 'Enterキーで閉じます' | Out-Null }
} finally {
    if (Test-Path -LiteralPath $runner) { Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue }
}
exit $code
