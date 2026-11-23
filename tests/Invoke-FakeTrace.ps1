param([string]$SessionPath,[string]$TraceId,[switch]$FailSave,[switch]$ExitWithoutFinalState,[switch]$WaitForRelease)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Core.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Inventory.ps1')
if($WaitForRelease){
    $release=Join-Path (Join-Path (Join-Path (Split-Path -Parent $SessionPath) 'traces') $TraceId) 'launch.release'
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while(-not (Test-Path -LiteralPath $release)){if([DateTime]::UtcNow -gt $deadline){exit 2};Start-Sleep -Milliseconds 50}
}
# Runs the real recorder state machine in a separate process, replacing WPR
# only. This never requests elevation or records any actual system activity.
$state=Invoke-DetailedTrace -SessionPath $SessionPath -TraceId $TraceId -Seconds 30 -WprRunner {
    param($arguments)
    if($arguments[0] -eq '-start'){Start-Sleep -Milliseconds 800}
    if($arguments[0] -eq '-marker' -and $ExitWithoutFinalState){[Environment]::Exit(9)}
    if($arguments[0] -eq '-stop'){
        Start-Sleep -Milliseconds 1800
        if($FailSave){return 25}
        [IO.File]::WriteAllText($arguments[1],'Synthetic trace fixture; not a real ETL')
    }
    return 0
}
if($state.status -notin @('Completed','Cancelled')){exit 1}
