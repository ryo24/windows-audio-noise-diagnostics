function Read-TraceStateFile {
    param([string]$Path)
    # Read a complete snapshot without blocking atomic replacement by the writer.
    $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    try{$file=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)}
    catch [IO.FileNotFoundException]{return $null}
    catch [IO.DirectoryNotFoundException]{return $null}
    try {
        if($file.Length -gt 16MB){throw 'Trace state exceeds its limit'}
        $reader=[IO.StreamReader]::new($file,[Text.Encoding]::UTF8)
        try{return ($reader.ReadToEnd()|ConvertFrom-Json)}finally{$reader.Dispose()}
    }finally{$file.Dispose()}
}

function Read-TraceStateRecord {
    param([string]$Directory,[string]$SessionDirectory,[string]$TraceId,[string]$SessionId)
    $newest=$null;$ui=$null;$readError=$null
    foreach($name in @('trace.json','trace-recovery.json','trace-final.json','trace-ui.json')){
        $path=Join-Path $Directory $name
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try {
            if($SessionDirectory){Assert-RegularBundleFile $SessionDirectory $path}
            $state=Read-TraceStateFile $path
            if(-not $state){continue}
            if(($TraceId -and $state.id -ne $TraceId) -or ($SessionId -and $state.sessionId -ne $SessionId)){
                throw 'Trace/session identity mismatch'
            }
            $record=[pscustomobject]@{name=$name;path=$path;state=$state}
            if($name -eq 'trace-ui.json'){
                if($state.status -notin @('Cancelled','LaunchFailed','HelperExited')){throw 'Invalid UI trace outcome'}
                $ui=$record
            }elseif(-not $newest -or [long]$state.stateWrites.sequence -gt [long]$newest.state.stateWrites.sequence){
                $newest=$record
            }
        }catch{$readError=$_}
    }
    if($newest.state.status -in @('Completed','Failed','StopFailed','Cancelled')){return $newest}
    if($ui){return $ui}
    if($newest){return $newest}
    if($readError){throw $readError}
}

function Write-TraceWorkerState {
    param([string]$Directory,$State,[switch]$Final)
    $stats=$State.stateWrites
    $stats.sequence++
    $State.updated=Get-ClockPoint
    if($stats.recoveryWrites){$names=@('trace-recovery.json','trace.json')}
    else{$names=@('trace.json','trace-recovery.json')}
    if($Final){$names+=@('trace-final.json')}
    foreach($name in $names){
        $recovery=$name -ne 'trace.json'
        if($recovery){$stats.recoveryWrites++}
        try {
            Write-AtomicText (Join-Path $Directory $name) ($State|ConvertTo-Json -Depth 12) -Attempts 3
            return $true
        }catch [IO.IOException], [UnauthorizedAccessException] {
            if($recovery){$stats.recoveryWrites--}
            $stats.writeFailures++
            $stats.lastError=[pscustomobject]@{
                file=$name
                type=$_.Exception.GetBaseException().GetType().Name
                hresult=$_.Exception.GetBaseException().HResult
                point=Get-ClockPoint
            }
        }
    }
    return $false
}

function Set-TraceUiOutcome {
    param($Run,[string]$Status,[string]$ErrorType)
    # Report only the launch/exit observation; never modify a helper snapshot.
    $outcome=$Run.state.PSObject.Copy()
    $outcome|Add-Member -NotePropertyName lastWorkerStatus -NotePropertyValue $Run.state.status -Force
    $outcome.status=$Status
    $outcome.errorType=$ErrorType
    $outcome|Add-Member -NotePropertyName helperExitCode -NotePropertyValue $Run.processExitCode -Force
    $Run.state=$outcome
    Write-AtomicText (Join-Path $Run.directory 'trace-ui.json') ($outcome|ConvertTo-Json -Depth 12)
}
