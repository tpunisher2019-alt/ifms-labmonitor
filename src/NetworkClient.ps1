function Get-LmDeviceIdentityPath {
    param([string]$RootPath)
    return Join-Path $RootPath 'data\state\device-identity.json'
}

function Get-LmSyncUri {
    param($NetworkConfig)
    return ('{0}/functions/v1/{1}' -f ([string]$NetworkConfig.supabaseUrl).TrimEnd('/'), [string]$NetworkConfig.edgeFunctionName)
}

function Invoke-LmSyncRequest {
    param(
        [Parameter(Mandatory = $true)]$NetworkConfig,
        [Parameter(Mandatory = $true)]$Body,
        $Identity = $null
    )
    $headers = @{ apikey = [string]$NetworkConfig.publishableKey; 'Content-Type' = 'application/json' }
    if ($null -ne $Identity -and $Identity.deviceSecret) {
        $headers.Authorization = 'Bearer ' + [string]$Identity.deviceSecret
        $headers['x-device-id'] = [string]$Identity.deviceId
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
    if ([string]::IsNullOrWhiteSpace([string]$NetworkConfig.enrollmentToken) -or
        [string]$NetworkConfig.enrollmentToken -like 'SUBSTITUA*') {
        throw 'O dispositivo ainda não foi cadastrado e não há enrollmentToken válido.'
    }
    $response = Invoke-LmSyncRequest -NetworkConfig $NetworkConfig -Body ([ordered]@{
        action = 'enroll'
        enrollmentToken = [string]$NetworkConfig.enrollmentToken
        installationId = Get-LmSha256Text -Text ('{0}|{1}' -f $env:COMPUTERNAME, (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID)
        hostname = $env:COMPUTERNAME
        agentVersion = $AgentVersion
    })
    if (-not $response.deviceId -or -not $response.deviceSecret) { throw 'Resposta de cadastro de dispositivo inválida.' }
    $identity = [ordered]@{
        schemaVersion = 1; deviceId = [string]$response.deviceId; deviceSecret = [string]$response.deviceSecret
        enrolledAtUtc = Get-LmUtcNow
    }
    Write-LmAtomicJson -Path $identityPath -Value $identity
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
        action = 'sync'; agentVersion = $AgentVersion; hostname = $env:COMPUTERNAME
        sentAtUtc = Get-LmUtcNow; items = $items; inventory = $inventory
    })
    if ($response.accepted) {
        foreach ($file in $files) { Remove-Item -LiteralPath $file.FullName -Force }
        if ($null -ne $inventory -and (Test-Path -LiteralPath $pendingInventory)) { Remove-Item -LiteralPath $pendingInventory -Force }
    }
    return [ordered]@{ identity = $identity; jobs = @($response.jobs); acceptedCount = $items.Count }
}

