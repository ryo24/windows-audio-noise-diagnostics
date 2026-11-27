param([Parameter(Mandatory=$true)][string]$SessionPath,[Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{32}$')][string]$TraceId,[Parameter(Mandatory=$true)][string]$OutputDirectory,[ValidateRange(1,1000000)][int]$MaxEvents=250000)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1');. (Join-Path $PSScriptRoot 'Inventory.ps1');. (Join-Path $PSScriptRoot 'UsbEvents.ps1')
$session=Read-Session $SessionPath;$directory=Split-Path -Parent ([IO.Path]::GetFullPath($SessionPath));$traceDirectory=Join-Path $directory ('traces/'+$TraceId)
$record=Read-TraceStateRecord $traceDirectory -SessionDirectory $directory -TraceId $TraceId -SessionId $session.id
if(-not $record){throw 'Trace state is missing'}
$state=$record.state
$test=@($session.tests|Where-Object {$_.id -eq $state.link.testId -and $_.followUp.traceId -eq $TraceId -and $_.followUp.probeId -eq $state.link.probeId})
if($test.Count -ne 1){throw 'Trace/test/probe linkage is missing or ambiguous'}
$probe=@($session.audioProbes|Where-Object {$_.id -eq $state.link.probeId -and $_.testId -eq $state.link.testId})
$etl=Join-Path $traceDirectory 'usb.etl';Assert-RegularBundleFile $directory $etl
if($state.usb.status -ne 'Completed' -or (Get-FileHash -LiteralPath $etl).Hash -ne $state.usb.sha256){throw 'USB trace was not saved or its hash does not match'}
if(-not $state.target.physicalRef){throw 'Selected USB target was not resolved; retain the ETL for manual analysis'}
if($state.target.endpointRef -ne $state.link.endpointRef -or $state.target.chain[0].ref -ne $state.link.endpointRef -or @($state.target.chain.ref) -notcontains $state.target.physicalRef){throw 'USB target is not linked to the selected endpoint ancestor chain'}
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\','/')
if($output.StartsWith($directory.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Choose a separate analysis directory; the source session will not be modified'}
if(Test-Path -LiteralPath $output){throw 'Use a new output directory to preserve earlier analyses'}
[IO.Directory]::CreateDirectory($output)|Out-Null
$script:usbScanCount=0
$read={
    $count=0
    Get-WinEvent -Path $etl -Oldest -MaxEvents ($MaxEvents+1) -ErrorAction Stop|ForEach-Object {
        $count++;if($count -le $MaxEvents){ConvertTo-UsbEvent $_.ToXml() $session.id};$_.Dispose()
    }
    $script:usbScanCount=$count
}
$selection=$null;$analysisError=$null;$csv=Join-Path $output 'usb-target-events.csv';$script:matchedEvents=0
try {
    $selection=Find-UsbTargetKeys $read $state.target
    Select-UsbTargetEvents $read $selection $(if($probe.Count -eq 1){$probe[0]}else{$null})|ForEach-Object {$script:matchedEvents++;$_}|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
}catch{$analysisError=$_.Exception.GetType().Name}
$summary=[pscustomobject]@{analysisStatus=if($analysisError){'ReadFailed'}else{'Completed'};errorType=$analysisError;sessionId=$session.id;testId=$state.link.testId;probeId=$state.link.probeId;traceId=$TraceId;tool=Get-ToolIdentity;sourceSessionSha256=(Get-FileHash $SessionPath).Hash;sourceTraceSha256=(Get-FileHash -LiteralPath $record.path).Hash;sourceEtlSha256=$state.usb.sha256;selectedEndpointRef=$state.link.endpointRef;target=$state.target;selection=$selection;scannedEvents=$script:usbScanCount;truncated=($script:usbScanCount -gt $MaxEvents);matchedEvents=$script:matchedEvents;coverage=if($probe.Count -eq 1){Get-FollowUpCoverage $state $probe[0] $test[0]}else{$null};scope='Derived local analysis only. CSV times are ETL UTC and UTC-based recording/reference offsets, not raw QPC or synchronized phone time. Align indexed reference sound with phone waveform. Zero matches, truncation or missing fields never prove correct operation. All endpoints of the matched composite USB device may be included.'}
Write-AtomicText (Join-Path $output 'usb-analysis.json') ($summary|ConvertTo-Json -Depth 14)
Write-Output ('USB selection: '+$selection.status+'; events: '+$script:matchedEvents+'; truncated: '+$summary.truncated+'; output: '+$output)

if($analysisError){throw ('USB event reading failed; see '+(Join-Path $output 'usb-analysis.json'))}
