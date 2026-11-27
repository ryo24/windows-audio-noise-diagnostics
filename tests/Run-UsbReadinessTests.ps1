$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/Core.ps1');. (Join-Path $root 'scripts/Inventory.ps1');. (Join-Path $root 'scripts/UsbEvents.ps1')
$checks=0
function Assert-UsbReady {param([bool]$Value,[string]$Message);if(-not $Value){throw ('FAIL: '+$Message)};$script:checks++;Write-Host ('PASS: '+$Message)}
$directory=Join-Path (Join-Path $root 'test-output') ('usb-ready-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($directory)|Out-Null
function New-UsbEventFixture {
 param([string]$Provider,[hashtable]$Fields,[int]$Id=6)
 $data=(@(foreach($key in $Fields.Keys){'<Data Name="'+[Security.SecurityElement]::Escape($key)+'">'+[Security.SecurityElement]::Escape([string]$Fields[$key])+'</Data>'})) -join ''
 ConvertTo-UsbEvent ('<Event><System><Provider Name="Microsoft-Windows-USB-'+$Provider+'"/><EventID>'+$Id+'</EventID><TimeCreated SystemTime="2026-01-01T00:00:01Z"/></System><EventData>'+$data+'</EventData></Event>') 'fixture-salt'
}
try {
 $session=New-DiagnosticSession ([pscustomobject]@{speakerModel='fixture';cStates='Unknown'});$test=New-TestRecord baseline35 'fixture' '' '' '' '';Complete-TestTiming $test;$test.result='Unchanged'
 $test|Add-Member followUp ([pscustomobject]@{kind='None';probeId=$null;traceId=$null});$session.tests=@($test);Save-Session $session $directory
 $rows=@(Get-SessionTraceEvidence $session $directory)
 Assert-UsbReady ($rows.Count -eq 1 -and $rows[0].usb.status -eq 'NotSelected' -and (Get-TraceEvidenceText $rows).Contains('未選択')) 'An ordinary trial explicitly reports USB not selected'
 $zip=Export-DiagnosticBundle $directory (Join-Path $directory 'exports') -IncludeTraces;$manifest=(Test-DiagnosticBundle $zip).manifest
 Assert-UsbReady ($manifest.traceDataIncluded -and $manifest.traceFileCount -eq 0 -and $manifest.traceEvidence[0].usb.status -eq 'NotSelected') 'Requested ETL inclusion with no capture reports zero actual files in a valid ZIP'
 $test.followUp.kind='UsbTransfer';$rows=@(Get-SessionTraceEvidence $session $directory)
 Assert-UsbReady ($rows[0].usb.status -eq 'MissingTraceId') 'A requested capture with no trace ID is missing, never a Logman execution failure'
 $probe=New-AudioProbeRecord Reference fixture $test.id 30;$probe.status='NotStarted';$session.audioProbes=@($probe);$test.followUp.probeId=$probe.id
 $run=New-TraceRun $directory $session.id -IncludeUsb -Link ([pscustomobject]@{testId=$test.id;probeId=$probe.id;endpointRef='1234567890ABCDEF'});$test.followUp.traceId=$run.id
 $run.state.status='LaunchFailed';$run.state.errorType='AdminApprovalCancelled';Write-AtomicText (Join-Path $run.directory 'trace.json') ($run.state|ConvertTo-Json -Depth 8)
 $rows=@(Get-SessionTraceEvidence $session $directory)
 Assert-UsbReady ($rows[0].usb.status -eq 'AdminCancelled' -and $rows[0].audioTrace.status -eq 'AdminCancelled' -and $rows[0].recordingStatus -eq 'NotStarted') 'Admin cancellation and unstarted recording remain distinct from saved traces'
 Assert-UsbReady ((Get-TraceEvidenceText $rows) -notmatch '取得エラー：|未取得項目 0') 'Unattempted diagnostics cannot invent a native error or a zero-missing coverage check'
 Save-Session $session $directory;$zip=Export-DiagnosticBundle $directory (Join-Path $directory 'exports') -IncludeTraces;$manifest=(Test-DiagnosticBundle $zip).manifest
 Assert-UsbReady ($manifest.traceFileCount -eq 0 -and $manifest.missingFiles.Count -eq 2 -and $manifest.traceEvidence[0].testId -eq $test.id) 'A cancelled trial exports existing data with missing audio files and the correct test identity'
 $state=$run.state;$state.errorType=$null;$state.status='StopFailed';$state.bytes=7;$state.sha256=$null
 $etl=Join-Path $run.directory 'trace.etl';[IO.File]::WriteAllText($etl,'fixture');$state.sha256=(Get-FileHash $etl).Hash
 $state|Add-Member audioStatus Completed;$state|Add-Member usb ([pscustomobject]@{status='StopFailed';requested=$true;bytes=0;startExitCode=0;stopExitCode=12;sha256=$null})
 Write-AtomicText (Join-Path $run.directory 'trace.json') ($state|ConvertTo-Json -Depth 8)
 $rows=@(Get-SessionTraceEvidence $session $directory)
 Assert-UsbReady ($rows[0].usb.status -eq 'SaveFailed' -and $rows[0].audioTrace.status -eq 'Saved' -and $rows[0].audioTrace.bytes -eq 7) 'USB save failure does not erase a successfully saved Audio ETL'
 $state.usb.status='Completed';$state.usb.bytes=7;$state.usb.sha256=$state.sha256;Write-AtomicText (Join-Path $run.directory 'trace.json') ($state|ConvertTo-Json -Depth 8)
 Assert-UsbReady (@(Get-SessionTraceEvidence $session $directory)[0].usb.status -eq 'MissingOrMismatched') 'A completed manifest without usb.etl is explicitly missing'
 $state.link.testId=[guid]::NewGuid().ToString('N');Write-AtomicText (Join-Path $run.directory 'trace.json') ($state|ConvertTo-Json -Depth 8)
 Assert-UsbReady (@(Get-SessionTraceEvidence $session $directory)[0].usb.status -eq 'InvalidState') 'A trace belonging to another test never counts as this test capture'
 $target=[pscustomobject]@{chain=@([pscustomobject]@{ref=(Get-AnonymousDeviceRef 'USB\VID_ABCD&PID_1001\SYNTHETIC' 'fixture-salt')});vid='ABCD';pid='1001';portPath=@(4);sameVidPidDevices=1}
 $script:events=@(
  (New-UsbEventFixture USBHUB3 @{fid_UsbDevice='0x101';fid_DeviceInterfacePath='\\?\USB#VID_ABCD&PID_1001#SYNTHETIC#{a5dcbf10-6530-11d2-901f-00c04fb951ed}';UntrustedPayload='PRIVATE_PAYLOAD'}),
  (New-UsbEventFixture UCX @{fid_UsbDevice='0x201';fid_idVendor='0xABCD';fid_idProduct='0x1001';PortPath='4,0,0,0,0,0';fid_Endpoint='0x301'}),
  (New-UsbEventFixture UCX @{fid_UsbDevice='0x201';fid_Endpoint='0x301';fid_TransferLength='192';fid_Status='0xC0000001'} 100),
  (New-UsbEventFixture UCX @{fid_Endpoint='0x301';fid_TransferLength='192'} 101),
  (New-UsbEventFixture UCX @{fid_UsbDevice='0x202';fid_Endpoint='0x302';fid_UcxController='0x999';fid_TransferLength='384'} 100),
  (New-UsbEventFixture UCX @{fid_UcxController='0x999';fid_Status='1'} 102)
 )
 $reader={$script:events};$selection=Find-UsbTargetKeys $reader $target
 Assert-UsbReady ($selection.providers.Count -eq 2 -and $selection.providers['Microsoft-Windows-USB-USBHUB3'].method -eq 'ExactInstanceRef') 'Rundown interface identity maps exactly to a salted ancestor without keeping serials'
 $p=[pscustomobject]@{capture=[pscustomobject]@{startedUtc='2026-01-01T00:00:00Z';referenceStartOffsetSeconds=0.25}}
 $matched=@(Select-UsbTargetEvents $reader $selection $p)
 Assert-UsbReady ($matched.Count -eq 4 -and @($matched|Where-Object {$_.usbDevice -eq '514' -or $_.eventId -eq 102}).Count -eq 0) 'Target transfer/device/endpoint events are retained without widening to a shared controller'
 $json=$matched|ConvertTo-Json -Depth 8
 Assert-UsbReady ($json -notmatch 'SYNTHETIC|PRIVATE_PAYLOAD' -and $matched[0].recordingOffsetSecondsUtc -eq 1 -and $matched[0].referenceOffsetSecondsUtc -eq 0.75) 'Derived event rows omit arbitrary data and expose explicit UTC recording/reference offsets'
 $target.sameVidPidDevices=2;$selection=Find-UsbTargetKeys $reader $target
 Assert-UsbReady ($selection.providers.Count -eq 1 -and -not $selection.providers.ContainsKey('Microsoft-Windows-USB-UCX')) 'Duplicate VID/PID devices prevent topology fallback instead of guessing'
 $target.sameVidPidDevices=1;$script:events+=@(New-UsbEventFixture UCX @{fid_UsbDevice='0x204';fid_idVendor='0xABCD';fid_idProduct='0x1001';PortPath='4,0,0,0,0,0'})
 $selection=Find-UsbTargetKeys $reader $target
 Assert-UsbReady ($selection.ambiguousProviders -contains 'Microsoft-Windows-USB-UCX' -and -not $selection.providers.ContainsKey('Microsoft-Windows-USB-UCX')) 'Multiple ETL devices with matching descriptors and port path remain unresolved'
 $script:events=@($script:events|Where-Object {$_.fields.UsbDevice -ne '516'})
 $script:events+=@(New-UsbEventFixture UCX @{fid_UsbDevice='0x299';fid_Endpoint='0x301'})
 $selection=Find-UsbTargetKeys $reader $target;$matched=@(Select-UsbTargetEvents $reader $selection $p)
 Assert-UsbReady (@($matched|Where-Object eventId -eq 101).Count -eq 0) 'Reused endpoint handles cannot attribute endpoint-only events to the target'
 $script:events+=@(New-UsbEventFixture UCX @{fid_UsbDevice='0x201';fid_idVendor='0xFFFF';fid_idProduct='0x0001';PortPath='4,0,0,0,0,0'})
 $selection=Find-UsbTargetKeys $reader $target
 Assert-UsbReady (-not $selection.providers.ContainsKey('Microsoft-Windows-USB-UCX')) 'Reused device handles with conflicting descriptors prevent target attribution'
 & {
  $script:targetEndpoint='SWD\MMDEVAPI\{fixture}';$script:targetPhysical='USB\VID_ABCD&PID_1001\PRIVATE_SERIAL'
  function Get-PnpDevice {param([switch]$PresentOnly,$ErrorAction);@([pscustomobject]@{InstanceId=$script:targetEndpoint;Class='AudioEndpoint'},[pscustomobject]@{InstanceId=$script:targetPhysical;Class='USB'})}
  function Get-PnpDeviceProperty {param($InstanceId,$ErrorAction);if($InstanceId -eq $script:targetEndpoint){@([pscustomobject]@{KeyName='DEVPKEY_Device_Parent';Data=$script:targetPhysical})}else{@([pscustomobject]@{KeyName='DEVPKEY_Device_HardwareIds';Data=@('USB\VID_ABCD&PID_1001')},[pscustomobject]@{KeyName='DEVPKEY_Device_LocationPaths';Data=@('PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(4)')})}}
  function Get-CimInstance {param($ClassName,$OperationTimeoutSec,$ErrorAction);[pscustomobject]@{LastBootUpTime=[DateTime]::Parse('2026-01-01T00:00:00Z')}}
  $snapshot=Get-UsbTargetSnapshot (Get-AnonymousDeviceRef $script:targetEndpoint 'fixture-salt') 'fixture-salt';$json=$snapshot|ConvertTo-Json -Depth 8
  Assert-UsbReady ($snapshot.status -eq 'collected' -and $snapshot.chain.Count -eq 2 -and $snapshot.portPath[0] -eq 4 -and $snapshot.sameVidPidDevices -eq 1 -and $json -notmatch 'PRIVATE_SERIAL|SWD\\MMDEVAPI') 'Trace-start target collection preserves salted topology, USB ports and boot data without raw instance IDs'
 }
 Assert-UsbReady ((Get-TraceEvidenceText @()) -eq '') 'Empty sessions can display capture status before any tests exist'
 $mismatchTrace=[pscustomobject]@{target=[pscustomobject]@{boot=[pscustomobject]@{status='collected';data=[pscustomobject]@{lastBootUtc='2026-01-02T00:00:00Z'}}}}
 $mismatchTest=[pscustomobject]@{context=[pscustomobject]@{boot=[pscustomobject]@{status='collected';data=[pscustomobject]@{lastBootUtc='2026-01-01T00:00:00Z'}}}}
 Assert-UsbReady ((Get-FollowUpCoverage $mismatchTrace $null $mismatchTest).scope -like 'BootIdentityMismatch*') 'Conflicting boot records prevent a QPC interval comparison'
 & {
  $state.link.testId=$test.id;$state.usb.status='Completed'
  $target|Add-Member physicalRef $target.chain[0].ref -Force;$target|Add-Member endpointRef $state.link.endpointRef -Force
  $target.chain=@([pscustomobject]@{ref=$state.link.endpointRef})+$target.chain
  $usbFile=Join-Path $run.directory 'usb.etl';[IO.File]::WriteAllText($usbFile,'synthetic ETL bytes; native reader is mocked')
  $state.usb.bytes=(Get-Item $usbFile).Length;$state.usb.sha256=(Get-FileHash $usbFile).Hash;$state|Add-Member target $target -Force
  Write-AtomicText (Join-Path $run.directory 'trace.json') ($state|ConvertTo-Json -Depth 10);Save-Session $session $directory
  $sourceHash=(Get-FileHash (Join-Path $directory 'session.json')).Hash
  function Get-WinEvent {
   param($Path,[switch]$Oldest,$MaxEvents,$ErrorAction)
   $obj=[pscustomobject]@{Xml='<Event><System><Provider Name="Microsoft-Windows-USB-UCX"/><EventID>4</EventID><TimeCreated SystemTime="2026-01-01T00:00:01Z"/></System><EventData><Data Name="fid_UsbDevice">0x201</Data><Data Name="fid_idVendor">0xABCD</Data><Data Name="fid_idProduct">0x1001</Data><Data Name="PortPath">4,0,0,0,0,0</Data></EventData></Event>'}
   $obj|Add-Member -MemberType ScriptMethod -Name ToXml -Value {$this.Xml};$obj|Add-Member -MemberType ScriptMethod -Name Dispose -Value {};return $obj
  }
  $script:analysisDirectory=$directory+'-analysis'
  & (Join-Path $root 'scripts/Export-UsbTraceEvents.ps1') -SessionPath (Join-Path $directory 'session.json') -TraceId $run.id -OutputDirectory $script:analysisDirectory
  $summary=Get-Content (Join-Path $script:analysisDirectory 'usb-analysis.json') -Raw -Encoding UTF8|ConvertFrom-Json
  $csv=@(Import-Csv (Join-Path $script:analysisDirectory 'usb-target-events.csv'))
  Assert-UsbReady ($summary.testId -eq $test.id -and $summary.matchedEvents -eq 1 -and $csv.Count -eq 1 -and (Get-FileHash (Join-Path $directory 'session.json')).Hash -eq $sourceHash) 'The offline export command validates links and hashes, writes derived CSV/JSON and preserves its source session'
  function Get-WinEvent {param($Path,[switch]$Oldest,$MaxEvents,$ErrorAction);throw 'Synthetic ETL reader failure'}
  $script:failedAnalysisDirectory=$directory+'-failed-analysis';$failed=$false
  try{& (Join-Path $root 'scripts/Export-UsbTraceEvents.ps1') -SessionPath (Join-Path $directory 'session.json') -TraceId $run.id -OutputDirectory $script:failedAnalysisDirectory}catch{$failed=$true}
  $summary=Get-Content (Join-Path $script:failedAnalysisDirectory 'usb-analysis.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Assert-UsbReady ($failed -and $summary.analysisStatus -eq 'ReadFailed' -and $summary.errorType -and $summary.testId -eq $test.id) 'An ETL read failure produces an explicit failed analysis with provenance, never a clean zero-event result'
 }
 Write-Host ('All '+$checks+' USB readiness checks passed.')
}finally{
 $allowed=[IO.Path]::GetFullPath((Join-Path $root 'test-output')).TrimEnd('\')+'\'
 if(-not [IO.Path]::GetFullPath($directory).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
 foreach($path in @($directory,$script:analysisDirectory,$script:failedAnalysisDirectory)|Where-Object {$_}){
  if(-not [IO.Path]::GetFullPath($path).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe analysis cleanup'}
  if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
 }
}
