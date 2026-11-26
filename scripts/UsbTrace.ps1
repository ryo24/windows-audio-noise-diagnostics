function Get-UsbTraceProviders {
    $names=@('Microsoft-Windows-USB-USBXHCI','Microsoft-Windows-USB-UCX','Microsoft-Windows-USB-USBHUB3')
    @(foreach($name in $names){
        $provider=Get-WinEvent -ListProvider $name -ErrorAction Stop
        [long]$mask=0
        foreach($keyword in @('Default','USBError','HeadersBusTrace','Rundown','StateMachine')){
            $entry=@($provider.Keywords|Where-Object {$_.Name -eq $keyword})
            if($entry.Count -ne 1){throw 'Required USB header keyword is unavailable'}
            $mask=$mask -bor [long]$entry[0].Value
        }
        [pscustomobject]@{name=$name;id=$provider.Id.ToString();keywords=('0x'+$mask.ToString('X'));level=5}
    })
}
function Start-UsbTrace {
    param($UsbState,[string]$Directory,[scriptblock]$Runner,[scriptblock]$Heartbeat)
    $UsbState.providers=@(Get-UsbTraceProviders)
    $providerFile=Join-Path $Directory 'usb-providers.txt'
    [IO.File]::WriteAllLines($providerFile,[string[]]@($UsbState.providers|ForEach-Object {'{'+([guid]$_.id).ToString()+'} '+$_.keywords+' 5'}),[Text.Encoding]::ASCII)
    $path=Join-Path $Directory 'usb.etl'
    if(Test-Path -LiteralPath $path){throw 'Existing USB trace will not be overwritten'}
    $arguments=@('create','trace',$UsbState.instanceName,'-ets','-pf',$providerFile,'-o',$path,'--v','-f','bincirc','-max','256','-nb','16','128','-bs','64','-ct','perf')
    $UsbState.startExitCode=if($Runner){& $Runner $arguments}else{Invoke-DiagnosticProcess -Executable (Join-Path $env:SystemRoot 'System32/logman.exe') -Arguments $arguments -Heartbeat $Heartbeat}
    if($UsbState.startExitCode -ne 0){$UsbState.status='Failed';throw 'USB trace start failed'}
    $UsbState.status='Recording';$UsbState.started=Get-ClockPoint
}
function Stop-UsbTrace {
    param($UsbState,[string]$Directory,[scriptblock]$Runner,[scriptblock]$Heartbeat)
    $UsbState.status='Stopping'
    $arguments=@('stop',$UsbState.instanceName,'-ets')
    try{
        $UsbState.stopExitCode=if($Runner){& $Runner $arguments}else{Invoke-DiagnosticProcess -Executable (Join-Path $env:SystemRoot 'System32/logman.exe') -Arguments $arguments -Heartbeat $Heartbeat}
        $path=Join-Path $Directory 'usb.etl'
        if($UsbState.stopExitCode -ne 0 -or -not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0){throw 'USB trace save failed'}
        $UsbState.bytes=(Get-Item -LiteralPath $path).Length;$UsbState.sha256=(Get-FileHash -LiteralPath $path).Hash;$UsbState.status='Completed'
    }catch{$UsbState.status='StopFailed';$UsbState.errorType=$_.Exception.GetType().Name}
    finally{$UsbState.ended=Get-ClockPoint}
}
