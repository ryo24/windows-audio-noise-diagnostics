function Invoke-DiagnosticProcess {
    param([string[]]$Arguments,[scriptblock]$Heartbeat,[string]$Executable=(Join-Path $env:SystemRoot 'System32\wpr.exe'))
    $process=New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName=$Executable
        $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
        $allArguments=@($Arguments)
        if(@($allArguments|Where-Object {$_ -match '"|[\r\n]'}).Count){throw 'Unsupported WPR argument'}
        $process.StartInfo.Arguments=($allArguments|ForEach-Object {'"'+$_+'"'}) -join ' '
        [void]$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        # A heartbeat signals that the helper is alive, not a percent complete.
        # Do not kill a merge merely because it takes longer than recording.
        while(-not $process.WaitForExit(1000)){if($Heartbeat){try{& $Heartbeat}catch{}}}
        [void]$output.GetAwaiter().GetResult();[void]$errors.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {$process.Dispose()}
}

function Invoke-WprProcess {
    param([string[]]$Arguments,[string]$Instance,[scriptblock]$Heartbeat,[string]$Executable=(Join-Path $env:SystemRoot 'System32\wpr.exe'))
    Invoke-DiagnosticProcess -Arguments (@($Arguments)+@('-instancename',$Instance)) -Executable $Executable -Heartbeat $Heartbeat
}
