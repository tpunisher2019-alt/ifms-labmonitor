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
    $adapters = @(Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })
    $macs = @($adapters | ForEach-Object { [string]$_.MACAddress } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
    $ips = @($adapters | ForEach-Object { @($_.IPAddress) } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^(127\.|169\.254\.)' } | Sort-Object -Unique)
    $machineUuid = if ($computer.UUID) { [string]$computer.UUID } else { $env:COMPUTERNAME }
    return [ordered]@{
        installationId = Get-LmSha256Text -Text ('{0}|{1}' -f $env:COMPUTERNAME, $machineUuid)
        hostname = $env:COMPUTERNAME
        machineUuidHash = Get-LmSha256Text -Text $machineUuid
        macAddresses = $macs
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
    if ($null -eq $pending -or -not $pending.registrationSecret) {
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
        macAddresses = $registration.macAddresses
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
        [string]$InventoryPath
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
        macAddresses = $registration.macAddresses
        localIpAddresses = $registration.localIpAddresses
        osType = $registration.osType
        osVersion = $registration.osVersion
        sentAtUtc = Get-LmUtcNow
        items = $items
        inventory = $inventory
    })
    if ($response.accepted) {
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName -Force }
        if ($null -ne $inventory -and (Test-Path -LiteralPath $pendingInventory)) { Remove-Item -LiteralPath $pendingInventory -Force }
    }
    return [ordered]@{ identity = $identity; jobs = @($response.jobs); acceptedCount = $items.Count }
}
