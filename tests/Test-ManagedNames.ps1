$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src/Common.ps1')
. (Join-Path $projectRoot 'src/NetworkClient.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('lm-names-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert-NameTest($condition, $message) { if (-not $condition) { throw $message } }
function Get-CimInstance { param($ClassName, $ErrorAction)
    switch ($ClassName) {
        'Win32_ComputerSystemProduct' { return @{ UUID = '11111111-1111-1111-1111-111111111111' } }
        'Win32_BIOS' { return @{ SerialNumber = 'BIOS-TEST' } }
        'Win32_BaseBoard' { return @{ SerialNumber = 'BOARD-TEST' } }
        'Win32_OperatingSystem' { return @{ Caption = 'Windows'; Version = '10' } }
        'Win32_NetworkAdapterConfiguration' { return @{ IPEnabled = $true; IPAddress = @('10.8.35.86'); MACAddress = '18:A5:9C:B0:87:B7' } }
        'Win32_NetworkAdapter' { return @(@{PhysicalAdapter=$true;Name='Ethernet';MACAddress='18:A5:9C:B0:87:B7'},@{PhysicalAdapter=$true;Name='VMware Virtual Adapter';MACAddress='00:50:56:C0:00:01'}) }
    }
}
function Get-NetAdapter { param([switch]$Physical, $ErrorAction) return @(@{ifIndex=2;Status='Up';MacAddress='18-A5-9C-B0-87-B7';Name='Ethernet'},@{ifIndex=3;Status='Up';MacAddress='AA-BB-CC-DD-EE-FF';Name='Wi-Fi'}) }
function Get-NetRoute { param($AddressFamily, $DestinationPrefix, $ErrorAction) return @(@{InterfaceIndex=99;RouteMetric=1;InterfaceMetric=1},@{InterfaceIndex=3;RouteMetric=25;InterfaceMetric=10},@{InterfaceIndex=2;RouteMetric=5;InterfaceMetric=10}) }
$registration = Get-LmDeviceRegistrationInfo
Assert-NameTest ($registration.activeMac -eq '18:A5:9C:B0:87:B7') 'Active physical default-route adapter not selected.'
Assert-NameTest ($registration.macAddresses -notcontains '00:50:56:C0:00:01') 'Virtual MAC must not identify the PC.'
Assert-NameTest ($registration.activeAdapterName -eq 'Ethernet') 'Active adapter name missing.'
# All machine APIs below are mocked: this test never renames or reboots a PC.
function Get-LmDeviceRegistrationInfo { return @{ activeMac = '18:A5:9C:B0:87:B7'; macAddresses = @('18:A5:9C:B0:87:B7','AA:BB:CC:DD:EE:FF') } }
function Get-CimInstance { return @{ PartOfDomain = $script:domain } }
function Rename-Computer { param($NewName, [switch]$Force, $ErrorAction) $script:renames++ }
function Start-LmNameRestart { $script:reboots++ }
$script:domain = $false; $script:renames = 0; $script:reboots = 0
$assignment = [pscustomobject]@{ mac = '18:A5:9C:B0:87:B7'; desired_hostname = 'LM-TEST-01'; revision = [Guid]::NewGuid().ToString() }
try {
    Invoke-LmNameAssignment $testRoot $assignment
    Assert-NameTest ($script:renames -eq 1 -and $script:reboots -eq 1) 'Assignment did not apply exactly once.'
    Invoke-LmNameAssignment $testRoot $assignment
    Assert-NameTest ($script:renames -eq 1 -and $script:reboots -eq 1) 'Revision retried and could cause reboot loop.'
    $assignment.mac = 'AA:BB:CC:DD:EE:FF'; $assignment.revision = [Guid]::NewGuid().ToString()
    Invoke-LmNameAssignment $testRoot $assignment
    Assert-NameTest ($script:renames -eq 1) 'Wrong active MAC applied.'
    $assignment.mac = '18:A5:9C:B0:87:B7'; $assignment.desired_hostname = $env:COMPUTERNAME
    Invoke-LmNameAssignment $testRoot $assignment
    Assert-NameTest ($script:renames -eq 1) 'Matching current name should be a no-op.'
    $assignment.desired_hostname = 'LM-TEST-02'; $script:domain = $true
    Invoke-LmNameAssignment $testRoot $assignment
    Assert-NameTest ($script:renames -eq 1 -and $script:reboots -eq 1) 'Domain machine should not rename or reboot.'
    $result = Read-LmJsonFile (Join-Path $testRoot 'data/state/name-assignment.json')
    Assert-NameTest ($result.status -eq 'failed') 'Domain restriction must be recorded.'
    $assignment.desired_hostname = 'NAME;BAD'; $rejected = $false
    try { Invoke-LmNameAssignment $testRoot $assignment } catch { $rejected = $true }
    Assert-NameTest $rejected 'Invalid hostname accepted.'
    function Get-LmDeviceRegistrationInfo { return @{installationId='test';machineUuidHash='test';hardwareFingerprint='test';macAddresses=@('18:A5:9C:B0:87:B7');activeMac='18:A5:9C:B0:87:B7';activeAdapterName='Ethernet';localIpAddresses=@('10.8.35.86');osType='Windows';osVersion='10'} }
    function Initialize-LmDeviceIdentity { return [pscustomobject]@{deviceId='test';deviceSecret='test'} }
    function Invoke-LmSyncRequest { return [pscustomobject]@{accepted=$true;jobs=@()} }
    $sync = Invoke-LmNetworkSync -RootPath $testRoot -NetworkConfig @{batchSize=100} -AgentVersion '2.3.4' -InventoryPath (Join-Path $testRoot 'absent.json')
    Assert-NameTest ($null -eq $sync.nameAssignment) 'Optional server fields must be compatible with strict mode.'
    Write-Host 'Managed name tests passed (mocked rename/reboot).'
} finally {
    # Explicit generated test-only child of TEMP, never the workspace.
    if ($testRoot.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $testRoot -Leaf) -like 'lm-names-test-*') { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
