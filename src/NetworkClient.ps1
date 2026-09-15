function Get-LmDeviceIdentityPath {
    param([string]$RootPath)
    return Join-Path $RootPath 'data\state\device-identity.json'
}

function Get-LmEnrollmentRequestPath {
    param([string]$RootPath)
    return Join-Path $RootPath 'data\state\enrollment-request.json'
}

function Get-LmSyncUri {
    param($NetworkConfig)
    return ('{0}/functions/v1/{1}' -f ([string]$NetworkConfig.supabaseUrl).TrimEnd('/'), [string]$NetworkConfig.edgeFunctionName)
}

function New-LmRandomSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Get-LmDeviceRegistrationInfo {
    $computer = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $baseBoard = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $activeConfigurations = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })
    $physicalAdapters = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalAdapter -eq $true -and $_.MACAddress })
    $netAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MacAddress })
    $physicalAdapters = @($physicalAdapters | Where-Object { $_.Name -notmatch 'VMware|VirtualBox|Hyper-V|TAP|Virtual' })
    $macs = @($physicalAdapters | ForEach-Object { [string]$_.MACAddress } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant().Replace('-', ':') } | Sort-Object -Unique)
    if ($netAdapters.Count) { $macs = @($netAdapters | ForEach-Object { ([string]$_.MacAddress).ToUpperInvariant().Replace('-', ':') } | Sort-Object -Unique) }
    $activeAdapter = $null
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object @{ Expression = { [int]$_.RouteMetric + [int]$_.InterfaceMetric } }, InterfaceIndex)
    foreach ($route in $routes) {
        $activeAdapter = $netAdapters | Where-Object { $_.ifIndex -eq $route.InterfaceIndex -and $_.Status -eq 'Up' } | Select-Object -First 1
        if ($null -ne $activeAdapter) { break }
    }
    $activeMac = if ($null -ne $activeAdapter) { ([string]$activeAdapter.MacAddress).ToUpperInvariant().Replace('-', ':') } else { $null }
    if (-not $macs.Count) {
        $macs = @($activeConfigurations | ForEach-Object { [string]$_.MACAddress } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
    }
    $ips = @($activeConfigurations | ForEach-Object { @($_.IPAddress) } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^(127\.|169\.254\.)' } | Sort-Object -Unique)
    $machineUuid = if ($null -ne $computer -and $computer.UUID) { [string]$computer.UUID } else { $env:COMPUTERNAME }
    $biosSerial = if ($null -ne $bios) { [string]$bios.SerialNumber } else { '' }
    $baseBoardSerial = if ($null -ne $baseBoard) { [string]$baseBoard.SerialNumber } else { '' }
    $hardwareParts = @()
    if ($machineUuid -and $machineUuid -notmatch '^(0{8}-0{4}-0{4}-0{4}-0{12}|F{8}-F{4}-F{4}-F{4}-F{12})$') { $hardwareParts += 'uuid:' + $machineUuid.ToUpperInvariant() }
    if ($biosSerial -and $biosSerial -notmatch '^(Default string|To Be Filled By O\.E\.M\.|None)$') { $hardwareParts += 'bios:' + $biosSerial.Trim().ToUpperInvariant() }
    if ($baseBoardSerial -and $baseBoardSerial -notmatch '^(Default string|To Be Filled By O\.E\.M\.|None)$') { $hardwareParts += 'board:' + $baseBoardSerial.Trim().ToUpperInvariant() }
    if (-not $hardwareParts.Count) { $hardwareParts += @($macs | ForEach-Object { 'mac:' + $_ }) }
    if (-not $hardwareParts.Count) { $hardwareParts += 'host:' + $env:COMPUTERNAME.ToUpperInvariant() }
    $hardwareFingerprint = Get-LmSha256Text -Text ($hardwareParts -join '|')
    # A instalacao precisa distinguir computadores cujo firmware informa o
    # mesmo UUID/serial (comum em algumas placas e imagens clonadas). O MAC
    # fisico complementa a impressao do hardware sem depender do nome do PC.
    $installationParts = @('hardware:' + $hardwareFingerprint)
    $installationParts += @($macs | ForEach-Object { 'mac:' + $_ })
    $installationId = Get-LmSha256Text -Text ($installationParts -join '|')
    return [ordered]@{
        installationId = $installationId
        hostname = $env:COMPUTERNAME
        machineUuidHash = Get-LmSha256Text -Text $machineUuid
        hardwareFingerprint = $hardwareFingerprint
        macAddresses = $macs
        activeMac = $activeMac
        activeAdapterName = if ($activeAdapter) { [string]$activeAdapter.Name } else { $null }
        localIpAddresses = $ips
        osType = 'Windows'
        osVersion = if ($operatingSystem.Caption) { ('{0} {1}' -f $operatingSystem.Caption, $operatingSystem.Version).Trim() } else { [Environment]::OSVersion.VersionString }
    }
}

function Invoke-LmSyncRequest {
    param(
        [Parameter(Mandatory = $true)]$NetworkConfig,
        [Parameter(Mandatory = $true)]$Body,
        $Identity = $null
    )
    $headers = @{ apikey = [string]$NetworkConfig.publishableKey; 'Content-Type' = 'application/json' }
    $deviceSecret = if ($null -ne $Identity -and $Identity.PSObject.Properties['deviceSecret']) { [string]$Identity.deviceSecret } else { '' }
    $registrationSecret = if ($null -ne $Identity -and $Identity.PSObject.Properties['registrationSecret']) { [string]$Identity.registrationSecret } else { '' }
    if ($deviceSecret -or $registrationSecret) {
        $secret = if ($deviceSecret) { $deviceSecret } else { $registrationSecret }
        $headers.Authorization = 'Bearer ' + $secret
        if ($Identity.PSObject.Properties['deviceId'] -and $Identity.deviceId) { $headers['x-device-id'] = [string]$Identity.deviceId }
    }
    $timeout = if ($NetworkConfig.requestTimeoutSeconds) { [int]$NetworkConfig.requestTimeoutSeconds } else { 30 }
    return Invoke-RestMethod -Method Post -Uri (Get-LmSyncUri $NetworkConfig) -Headers $headers `
        -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec $timeout -UseBasicParsing
}

function Initialize-LmDeviceIdentity {
    param([string]$RootPath, $NetworkConfig, [string]$AgentVersion)
    $identityPath = Get-LmDeviceIdentityPath $RootPath
    $identity = Read-LmJsonFile -Path $identityPath
    if ($null -ne $identity -and $identity.deviceId -and $identity.deviceSecret) { return $identity }

    $registration = Get-LmDeviceRegistrationInfo
    $requestPath = Get-LmEnrollmentRequestPath $RootPath
    $pending = Read-LmJsonFile -Path $requestPath
    if ($null -eq $pending -or -not $pending.registrationSecret -or $pending.installationId -ne $registration.installationId) {
        $pending = [ordered]@{
            schemaVersion = 1
            installationId = $registration.installationId
            registrationSecret = New-LmRandomSecret
            createdAtUtc = Get-LmUtcNow
        }
        Write-LmAtomicJson -Path $requestPath -Value $pending
    }

    $response = Invoke-LmSyncRequest -NetworkConfig $NetworkConfig -Identity $pending -Body ([ordered]@{
        action = 'request_enrollment'
        installationId = $registration.installationId
        hostname = $registration.hostname
        machineUuidHash = $registration.machineUuidHash
        hardwareFingerprint = $registration.hardwareFingerprint
        macAddresses = $registration.macAddresses
        activeMac = $registration.activeMac
        activeAdapterName = $registration.activeAdapterName
        localIpAddresses = $registration.localIpAddresses
        osType = $registration.osType
        osVersion = $registration.osVersion
        agentVersion = $AgentVersion
    })
    if ($response.enrollmentStatus -eq 'pending') { throw 'Cadastro aguardando autorização do administrador.' }
    if ($response.enrollmentStatus -eq 'rejected') { throw 'Cadastro recusado pelo administrador.' }
    if ($response.enrollmentStatus -ne 'authorized' -or -not $response.deviceId) { throw 'Resposta de cadastro de dispositivo inválida.' }

    $identity = [ordered]@{
        schemaVersion = 1
        deviceId = [string]$response.deviceId
        deviceSecret = [string]$pending.registrationSecret
        enrolledAtUtc = Get-LmUtcNow
    }
    Write-LmAtomicJson -Path $identityPath -Value $identity
    if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
    return $identity
}

function Add-LmOutboxItem {
    param([string]$RootPath, [string]$Kind, $Payload)
    $outbox = Join-Path $RootPath 'data\outbox'
    New-LmDirectory -Path $outbox
    $item = [ordered]@{ schemaVersion = 1; kind = $Kind; queuedAtUtc = Get-LmUtcNow; payload = $Payload }
    $name = '{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff'), [Guid]::NewGuid().ToString('N')
    Write-LmAtomicJson -Path (Join-Path $outbox $name) -Value $item
}

function Invoke-LmNetworkSync {
    param(
        [string]$RootPath,
        $NetworkConfig,
        [string]$AgentVersion,
        [string]$InventoryPath,
        [switch]$ReEnrollmentAttempted
    )
    $identity = Initialize-LmDeviceIdentity -RootPath $RootPath -NetworkConfig $NetworkConfig -AgentVersion $AgentVersion
    $registration = Get-LmDeviceRegistrationInfo
    $outbox = Join-Path $RootPath 'data\outbox'
    New-LmDirectory -Path $outbox
    $batchSize = if ($NetworkConfig.batchSize) { [Math]::Min(500, [Math]::Max(1, [int]$NetworkConfig.batchSize)) } else { 100 }
    $files = @(Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File | Sort-Object Name | Select-Object -First $batchSize)
    $items = @()
    foreach ($file in $files) {
        $item = Read-LmJsonFile -Path $file.FullName
        if ($null -ne $item) { $items += ,$item }
    }
    $inventory = $null
    $pendingInventory = Join-Path $RootPath 'data\state\inventory-pending.flag'
    if ((Test-Path -LiteralPath $pendingInventory) -and (Test-Path -LiteralPath $InventoryPath)) {
        $inventory = Read-LmJsonFile -Path $InventoryPath
    }
    $response = Invoke-LmSyncRequest -NetworkConfig $NetworkConfig -Identity $identity -Body ([ordered]@{
        action = 'sync'
        agentVersion = $AgentVersion
        hostname = $env:COMPUTERNAME
        installationId = $registration.installationId
        machineUuidHash = $registration.machineUuidHash
        hardwareFingerprint = $registration.hardwareFingerprint
        macAddresses = $registration.macAddresses
        activeMac = $registration.activeMac
        activeAdapterName = $registration.activeAdapterName
        localIpAddresses = $registration.localIpAddresses
        osType = $registration.osType
        osVersion = $registration.osVersion
        sentAtUtc = Get-LmUtcNow
        items = $items
        inventory = $inventory
    })
    if ($response.PSObject.Properties['reEnrollmentRequired'] -and $response.reEnrollmentRequired -eq $true) {
        if ($ReEnrollmentAttempted) { throw 'O computador precisa ser autorizado novamente no painel.' }
        $identityPath = Get-LmDeviceIdentityPath $RootPath
        if (Test-Path -LiteralPath $identityPath) { Remove-Item -LiteralPath $identityPath -Force }
        return Invoke-LmNetworkSync -RootPath $RootPath -NetworkConfig $NetworkConfig `
            -AgentVersion $AgentVersion -InventoryPath $InventoryPath -ReEnrollmentAttempted
    }
    if ($response.accepted) {
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName -Force }
        if ($null -ne $inventory -and (Test-Path -LiteralPath $pendingInventory)) { Remove-Item -LiteralPath $pendingInventory -Force }
    }
    return [ordered]@{ identity = $identity; jobs = @($response.jobs); nameAssignment = if ($response.PSObject.Properties['nameAssignment']) { $response.nameAssignment } else { $null }; acceptedCount = $items.Count }
}

function Start-LmNameRestart {
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 60 /c 'IFMS LabMonitor: aplicando o nome da máquina definido pelo administrador. Salve seu trabalho.'
    if ($LASTEXITCODE -ne 0) { throw 'Nome aplicado, mas não foi possível agendar a reinicialização.' }
}

function Invoke-LmNameAssignment {
    param([string]$RootPath, $Assignment)
    if ($null -eq $Assignment) { return }
    $name = ([string]$Assignment.desired_hostname).ToUpperInvariant()
    if ($name -notmatch '^(?=.{1,15}$)(?![0-9]+$)[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$') { throw 'Nome remoto inválido.' }
    $registration = Get-LmDeviceRegistrationInfo
    if (-not $registration.activeMac -or $registration.activeMac -ne [string]$Assignment.mac) { return }
    $boundMac = if ($Assignment.PSObject.Properties['bound_mac'] -and $Assignment.bound_mac) { [string]$Assignment.bound_mac } else { [string]$Assignment.mac }
    if (@($registration.macAddresses) -notcontains $boundMac) { return }
    $resultPath = Join-Path $RootPath 'data\state\name-assignment.json'
    $previous = Read-LmJsonFile $resultPath
    if ($env:COMPUTERNAME.ToUpperInvariant() -eq $name) { return }
    # A failed revision is not retried endlessly. Administrator can save again.
    if ($previous -and $previous.revision -eq $Assignment.revision) { return }
    $result = [ordered]@{ revision = $Assignment.revision; mac = $boundMac; desiredHostname = $name; status = 'failed'; message = ''; timestampUtc = Get-LmUtcNow }
    try {
        $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.PartOfDomain) { throw 'Máquina no domínio: renomeação exige autorização do domínio; não foram armazenadas credenciais.' }
        Rename-Computer -NewName $name -Force -ErrorAction Stop
        $result.status = 'reboot_pending'; $result.message = 'Nome aplicado; reinicialização em 60 segundos.'
        Write-LmAtomicJson -Path $resultPath -Value $result
        Start-LmNameRestart
    } catch { $result.status = 'failed'; $result.message = $_.Exception.Message; Write-LmAtomicJson -Path $resultPath -Value $result }
    Add-LmOutboxItem -RootPath $RootPath -Kind 'name_result' -Payload $result
}
