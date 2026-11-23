param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Core.ps1')
. (Join-Path $root 'scripts\Inventory.ps1')
[IO.Directory]::CreateDirectory($Directory)|Out-Null
Initialize-LocalReceiver;Initialize-AudioInterop
[AudioNoiseDiagnostics.AudioFiles]::GenerateReference((Join-Path $Directory 'fixture.wav'))
$receiver=[AudioNoiseDiagnostics.LocalReceiver]::Start('127.0.0.1',(Join-Path $Directory 'session'),(Join-Path $root 'web'),120)
try{
    [IO.File]::WriteAllText((Join-Path $Directory 'url.txt'),$receiver.Url)
    $deadline=[DateTime]::UtcNow.AddSeconds(120);$count=0
    while([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $Directory 'stop'))){
        $media=$null
        while($receiver.Received.TryDequeue([ref]$media)){$count++;Write-AtomicText (Join-Path $Directory ('received-'+$count+'.json')) ($media|ConvertTo-Json -Depth 8)}
        Start-Sleep -Milliseconds 50
    }
}finally{$receiver.Dispose()}
