$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1')
. (Join-Path $root 'scripts/Inventory.ps1')
$checks=0
function Assert-Integration {param([bool]$Value,[string]$Message);if(-not $Value){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
function Wait-Integration {param([scriptblock]$Until);$limit=[DateTime]::UtcNow.AddSeconds(5);while(-not (& $Until)){if([DateTime]::UtcNow -gt $limit){throw 'Timed out'};Start-Sleep -Milliseconds 30}}
function Read-StatusLine {param($Client);$stream=$Client.GetStream();$text='';while($text.Length -lt 512){$b=$stream.ReadByte();if($b -lt 0 -or $b -eq 10){break};$text+=[char]$b};return $text}
function New-TestConnection {param($Receiver);$c=New-Object Net.Sockets.TcpClient;$c.ReceiveTimeout=2000;$c.SendTimeout=2000;$c.Connect('127.0.0.1',$Receiver.Port);return $c}
function Send-TestHeader {param($Client,$Receiver,[string]$Path,[long]$Length=0,[string]$Extra='');$method=if($Length){'POST'}else{'GET'};$header=$method+' '+$Path+" HTTP/1.1`r`nHost: 127.0.0.1:"+$Receiver.Port+"`r`n"+$Extra;if($Length){$header+='Content-Length: '+$Length+"`r`n"};$header+="`r`n";$data=[Text.Encoding]::ASCII.GetBytes($header);$Client.GetStream().Write($data,0,$data.Length)}
$temporary=Join-Path (Join-Path $root 'test-output') ('integration-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary)|Out-Null
$receiver=$null;$connections=New-Object 'System.Collections.Generic.List[object]'
try {
    Add-Type -TypeDefinition @'
public static class AtomicReaderFixture {
    public static System.Threading.Thread Hold(string path, int milliseconds) {
        var stream=System.IO.File.Open(path,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.Read);
        var thread=new System.Threading.Thread(delegate(){System.Threading.Thread.Sleep(milliseconds);stream.Dispose();});
        thread.Start();return thread;
    }
}
'@
    $atomicPath=Join-Path $temporary 'atomic.json';Write-AtomicText $atomicPath '{"saved":1}'
    $reader=[AtomicReaderFixture]::Hold($atomicPath,200)
    Write-AtomicText $atomicPath '{"saved":2}';$reader.Join()
    Assert-Integration ((Get-Content $atomicPath -Raw|ConvertFrom-Json).saved -eq 2) 'Atomic saves wait for a concurrent trace reader and retain valid JSON'
    $reader=[IO.File]::OpenRead($atomicPath);$blocked=$false
    try {Write-AtomicText $atomicPath '{"saved":3}'}catch{$blocked=$true}finally{$reader.Dispose()}
    Assert-Integration ($blocked -and (Get-Content $atomicPath -Raw|ConvertFrom-Json).saved -eq 2 -and @(Get-ChildItem $temporary -Filter '*.tmp').Count -eq 0) 'A persistent read lock fails within a bound without changing the saved original or leaving temporary files'
    $session=New-DiagnosticSession ([pscustomobject]@{speakerModel='fixture';cStates='Unknown'})
    $directory=Join-Path $temporary 'session';Save-Session $session $directory
    $run=New-TraceRun $directory $session.id;Send-TraceStopRequest $run
    $script:commands=0
    $cancelled=Invoke-DetailedTrace -SessionPath (Join-Path $directory 'session.json') -TraceId $run.id -WprRunner {param($a);$script:commands++;return 0}
    Assert-Integration ($cancelled.status -eq 'Cancelled' -and $script:commands -eq 0 -and (Read-TraceRunState $run).status -eq 'Cancelled') 'Stop requested before the helper starts is preserved and never starts WPR'
    $point=[pscustomobject]@{utc='2026-11-23T00:00:00Z';qpc=100;frequency=100}
    $later=[pscustomobject]@{utc='2026-11-23T00:03:00Z';qpc=18100;frequency=100}
    $run.requested=$point;$run.stopPoint=$point
    $state=[pscustomobject]@{status='Recording';started=$point;updated=$point;requestedSeconds=60;stopping=$point}
    $view=Get-TracePresentation $run $state Running $later
    Assert-Integration ($view.phase -eq 'StopUnconfirmed' -and $view.busy -and -not $view.canStop -and $view.canOpen) 'Missing stop acknowledgement becomes an explicit unconfirmed state, not an endless static request'
    $state.status='Stopping';$view=Get-TracePresentation $run $state Running $later
    Assert-Integration ($view.phase -eq 'SaveDelayed' -and $view.busy -and $view.text.Contains('180')) 'Long saving reports elapsed time and unconfirmed completion without inventing progress'
    $view=Get-TracePresentation $run $state Exited $later
    Assert-Integration ($view.phase -eq 'Failed' -and -not $view.busy) 'A helper exit without a terminal state cannot leave the stop UI active forever'
    $etl=Join-Path $run.directory 'trace.etl';[IO.File]::WriteAllText($etl,'fixture')
    $complete=[pscustomobject]@{status='Completed';bytes=7;sha256=(Get-FileHash $etl).Hash}
    $view=Get-TracePresentation $run $complete Unknown $later
    Assert-Integration ($view.phase -eq 'Completed' -and -not $view.busy) 'Valid saved state and ETL complete the UI without relying on an elevated process handle'
    $complete.bytes=8;$view=Get-TracePresentation $run $complete Exited $later
    Assert-Integration ($view.phase -eq 'Failed') 'Mismatching ETL cannot be reported as successfully saved'
    $native=Join-Path $temporary "Native 日本語 O'Brien";[IO.Directory]::CreateDirectory($native)|Out-Null
    $exe=Join-Path $native 'fixture.exe';$argumentFile=Join-Path $native 'arguments.txt'
    Add-Type -TypeDefinition 'public class TraceNativeFixture {public static int Main(string[] a){System.IO.File.WriteAllLines(a[0],a);System.Console.Write(new string((char)120,200000));System.Console.Error.Write(new string((char)121,200000));System.Threading.Thread.Sleep(1300);return 17;}}' -OutputAssembly $exe -OutputType ConsoleApplication
    $script:heartbeats=0
    $code=Invoke-WprProcess -Executable $exe -Arguments @($argumentFile,"description O'Brien 日本語") -Instance AudioNoiseFixture -Heartbeat {$script:heartbeats++}
    $arguments=[IO.File]::ReadAllLines($argumentFile)
    Assert-Integration ($code -eq 17 -and $script:heartbeats -gt 0 -and $arguments[1] -eq "description O'Brien 日本語" -and $arguments[2] -eq '-instancename' -and $arguments[3] -eq 'AudioNoiseFixture') 'Native process wait drains output, preserves quoted arguments, publishes heartbeat and returns the actual exit code'
    $probe=[pscustomobject]@{endpointName='USB Audio and HID';playbackSnapshot=[pscustomobject]@{data=[pscustomobject]@{outputs=@([pscustomobject]@{isSelectedForProbe=$true;endpointRef='capture-ref'})}}}
    $notice=Get-PlaybackReviewNotice $probe 'USB Audio and HID' 'capture-ref'
    Assert-Integration ($notice.relation -eq 'SameEndpoint' -and $notice.text.Contains('同じ出力') -and $notice.text.Contains('切り替え')) 'Playback notice explicitly warns when the recorded output is reused'
    Assert-Integration ((Get-PlaybackReviewNotice $probe 'HDMI' 'other-ref').relation -eq 'DifferentEndpoint') 'Different playback endpoint is recorded without claiming it is known clean'
    Assert-Integration ((Get-PlaybackReviewNotice ([pscustomobject]@{endpointName='legacy'}) 'legacy').relation -eq 'SameName') 'Older recordings still warn using the available output name'
    Initialize-LocalReceiver
    $receiver=[AudioNoiseDiagnostics.LocalReceiver]::Start('127.0.0.1',$directory,(Join-Path $root 'web'),60)
    $prefix=([Uri]$receiver.Url).AbsolutePath
    $idle=New-TestConnection $receiver;$connections.Add($idle)
    $client=New-TestConnection $receiver;try{Send-TestHeader $client $receiver ($prefix+'health');$line=Read-StatusLine $client}finally{$client.Close()}
    Assert-Integration ($line -like '*200*') 'A speculative idle browser connection does not block another device HTTP request'
    $idle.Close()
    Wait-Integration {@($receiver.NetworkSnapshot().Events|Where-Object {$_.Kind -eq 'ConnectionClosed' -and $_.Reason -eq 'BeforeHttpRequest'}).Count -gt 0}
    Assert-Integration (@($receiver.NetworkSnapshot().Events|Where-Object {$_.Kind -eq 'ConnectionClosed' -and $_.Reason -eq 'BeforeHttpRequest' -and $_.HeaderBytes -eq 0 -and $_.ConnectionId}).Count -gt 0) 'An idle connection closing before HTTP is recorded explicitly with a per-connection ID'
    $tls=New-TestConnection $receiver;try{$tls.GetStream().WriteByte(0x16);[void]$tls.GetStream().ReadByte()}finally{$tls.Close()}
    Wait-Integration {$receiver.NetworkSnapshot().TlsConnections -eq 1}
    Assert-Integration ($receiver.NetworkSnapshot().TlsConnections -eq 1) 'HTTPS-like attempts on the HTTP port are observable without a fabricated HTTP status'
    $client=New-TestConnection $receiver;try{Send-TestHeader $client $receiver ($prefix+'health') 0 "User-Agent: Firefox/154 PrivateDeviceName`r`nCookie: CookieSecret`r`n";[void](Read-StatusLine $client)}finally{$client.Close()}
    $snapshot=$receiver.NetworkSnapshot();$snapshotJson=$snapshot|ConvertTo-Json -Depth 8
    Assert-Integration ($snapshotJson -notmatch 'PrivateDeviceName|CookieSecret|127\.0\.0\.1|/s/' -and $snapshotJson.Contains('Firefox') -and $snapshotJson.Contains('154')) 'Receiver diagnostics keep response categories and browser family/version without raw URLs, IPs, headers or tokens'
    for($i=0;$i -lt 4;$i++){$c=New-TestConnection $receiver;$connections.Add($c);Send-TestHeader $c $receiver ($prefix+'upload') 134217728}
    Wait-Integration {$receiver.NetworkSnapshot().ActiveUploads -eq 4}
    $client=New-TestConnection $receiver;try{Send-TestHeader $client $receiver ($prefix+'upload') 12;$line=Read-StatusLine $client}finally{$client.Close()}
    Assert-Integration ($line -like '*429*' -and $receiver.NetworkSnapshot().ReservedUploadBytes -eq 536870912) 'Concurrent uploads reserve the aggregate limit before reading any body'
    foreach($c in $connections){$c.Close()};Wait-Integration {$receiver.NetworkSnapshot().ActiveUploads -eq 0}
    Assert-Integration ($receiver.NetworkSnapshot().ReservedUploadBytes -eq 0) 'Interrupted uploads release reservations for subsequent requests'
    $wave=[Text.Encoding]::ASCII.GetBytes('RIFF0000WAVEfixture');$uploadClient=New-Object Net.WebClient
    try{$uploadClient.Headers['X-Upload-Attempt']='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';[void]$uploadClient.UploadData($receiver.Url+'upload','POST',$wave)}finally{$uploadClient.Dispose()}
    $savedEvent=@($receiver.NetworkSnapshot().Events|Where-Object {$_.Kind -eq 'UploadSaved'})
    Assert-Integration ($savedEvent.Count -eq 1 -and $savedEvent[0].Method -eq 'POST' -and $savedEvent[0].AttemptId -eq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -and $savedEvent[0].BodyBytes -eq $wave.Length -and $savedEvent[0].ExpectedBytes -eq $wave.Length) 'Saved uploads retain method, actual received bytes and the validated browser attempt ID'
    $report=Get-PhoneConnectionDiagnostics $receiver '127.0.0.1'
    Assert-Integration ($report.localHttpSelfTest.httpStatus -eq 200 -and $report.receiverAfterSelfTest.OtherDeviceConnections -eq 0) 'PC self-test works but is never counted as a different device or phone reachability'
    $report.manualObservation=[pscustomobject]@{errorText=Protect-PhoneDiagnosticNote ('error '+$receiver.Url+' and /s/abcdefghijklmnopqrstuvwxyz/');otherBrowser='Unknown'}
    $browserLog=Read-BrowserUploadLog (Join-Path $PSScriptRoot 'fixtures/browser-upload-log.json')
    Assert-Integration ($browserLog.attempts[0].outcome -eq 'NetworkError' -and $browserLog.attempts[0].events.Count -eq 4) 'Browser upload diagnostics preserve stages and do not infer the network failure cause'
    $report|Add-Member -NotePropertyName browserUploadDiagnostics -NotePropertyValue $browserLog
    $malicious=Get-Content (Join-Path $PSScriptRoot 'fixtures/browser-upload-log.json') -Raw|ConvertFrom-Json
    $malicious|Add-Member -NotePropertyName url -NotePropertyValue $receiver.Url
    $badLog=Join-Path $temporary 'untrusted-browser.json';Write-AtomicText $badLog ($malicious|ConvertTo-Json -Depth 10)
    $blocked=$false;try{Read-BrowserUploadLog $badLog|Out-Null}catch{$blocked=$true}
    Assert-Integration $blocked 'Browser imports reject unexpected raw URL fields instead of copying arbitrary JSON into a diagnostic session'
    $malicious.PSObject.Properties.Remove('url');$malicious.attempts[0].events[0].loadedBytes=-1
    Write-AtomicText $badLog ($malicious|ConvertTo-Json -Depth 10)
    $blocked=$false;try{Read-BrowserUploadLog $badLog|Out-Null}catch{$blocked=$true}
    Assert-Integration $blocked 'Browser imports reject invalid byte counts'
    $session|Add-Member -NotePropertyName networkDiagnostics -NotePropertyValue @($report)
    Save-Session $session $directory
    $json=Get-Content (Join-Path $directory 'network-diagnostics.json') -Raw -Encoding UTF8
    Assert-Integration ($json -notmatch [regex]::Escape(([Uri]$receiver.Url).AbsolutePath) -and $json -notmatch 'abcdefghijklmnopqrstuvwxyz') 'Manually pasted connection observations redact pairing URLs and tokens'
    Assert-Integration ((Get-Content (Join-Path $directory 'session.json') -Raw -Encoding UTF8|ConvertFrom-Json).networkDiagnostics[0].browserUploadDiagnostics.attempts[0].outcome -eq 'NetworkError') 'Imported browser upload diagnostics survive normal session serialization and export'
    $bundle=Export-DiagnosticBundle $directory (Join-Path $temporary 'exports')
    Assert-Integration ((Test-DiagnosticBundle $bundle).manifest.files.path -contains 'session/network-diagnostics.json') 'Connection diagnoses and manual browser observations are included in the export ZIP'
    $pending=New-TraceRun $directory $session.id;$blocked=$false
    try{[void](Export-DiagnosticBundle $directory (Join-Path $temporary 'exports'))}catch{$blocked=$_.Exception.Message.Contains('詳細トレース')}
    Assert-Integration $blocked 'A reserved trace awaiting helper startup prevents exporting an unfinished run'
    $receiver.Dispose();$receiver=$null
    Write-Host ('All '+$checks+' integration checks passed.')
}finally{
    foreach($c in $connections){$c.Close()}
    if($receiver){$receiver.Dispose()}
    $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($temporary).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'}
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
