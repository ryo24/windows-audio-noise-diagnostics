param([Parameter(Mandatory=$true)][string]$SessionPath,[ValidateRange(10,120)][int]$Seconds=60,[string]$TraceId='',[switch]$IncludeUsb)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
$state=Invoke-DetailedTrace -SessionPath $SessionPath -Seconds $Seconds -TraceId $TraceId -IncludeUsb:$IncludeUsb
if($state.status -notin @('Completed','Cancelled')){exit 1}
