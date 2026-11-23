param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Case)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
Import-ResultArchive -Path $Path -Case $Case
