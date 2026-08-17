[CmdletBinding()]
param(
    [string]$RootPath = (Join-Path $env:ProgramData 'IFMS\LabMonitor'),
    [int]$PollSeconds = 0,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'ForegroundProvider.ps1')
. (Join-Path $PSScriptRoot 'Inventory.ps1')
. (Join-Path $PSScriptRoot 'NetworkClient.ps1')

$paths = @{
    Policy = Join-Path $RootPath 'config\policy.json'
    Inbox = Join-Path $RootPath 'data\inbox'
    State = Join-Path $RootPath 'data\state\agent-state.json'
    Events = Join-Path $RootPath 'data\logs\events.jsonl'
    Sessions = Join-Path $RootPath 'data\logs\sessions.jsonl'
    Agent = Join-Path $RootPath 'data\logs\agent.jsonl'
    Network = Join-Path $RootPath 'config\network.json'
    Inventory = Join-Path $RootPath 'data\state\inventory.json'
    Version = Join-Path $RootPath 'VERSION'
}

function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) { $table[$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-HashtableDeep $property.Value
        }
        return $table
    }
    if (($InputObject -is [Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += ,(ConvertTo-HashtableDeep $item) }
        return $items
    }
    return $InputObject
}

function Write-AgentDiagnostic {
    param([string]$Level, [string]$Message, $Data = $null)
    $entry = [ordered]@{ timestampUtc = Get-LmUtcNow; level = $Level; component = 'agent'; message = $Message }
    if ($null -ne $Data) { $entry.data = $Data }
    Write-LmJsonLine -Path $paths.Agent -Value $entry
}

function Write-MonitorEvent {
    param([string]$Type, [hashtable]$Session, $Data = $null, [string]$TimestampUtc = $null)
    if (-not $TimestampUtc) { $TimestampUtc = Get-LmUtcNow }
    $entry = [ordered]@{
        schemaVersion = 1
        eventId = [Guid]::NewGuid().ToString()
        timestampUtc = $TimestampUtc
        type = $Type
        hostname = $env:COMPUTERNAME
        sessionKey = $Session.sessionKey
        sessionId = $Session.sessionId
        user = $Session.user
    }
    if ($null -ne $Data) { $entry.data = $Data }
    Write-LmJsonLine -Path $paths.Events -Value $entry
    if ($null -ne $script:networkConfig -and [bool]$script:networkConfig.enabled) {
        Add-LmOutboxItem -RootPath $RootPath -Kind 'event' -Payload $entry
        $script:syncRequested = $true
    }
}

function Test-ReportableEventType {
    param([string]$Type)
    return $Type -in @('ProhibitedApplicationDetected', 'ProhibitedApplicationStopped', 'SuspiciousApplicationDetected', 'SuspiciousApplicationStopped')
}

function New-AgentState {
    return @{
        schemaVersion = 2; savedAtUtc = Get-LmUtcNow; sessions = @{}; observed = @{}
        lastInventoryAtUtc = $null; lastInventoryHash = $null; lastSyncAtUtc = $null
        handledJobIds = @{}; networkBackfillCompleted = $false
    }
}

function Import-AgentState {
    $raw = Read-LmJsonFile -Path $paths.State
    if ($null -eq $raw) { return New-AgentState }
    try {
        $converted = ConvertTo-HashtableDeep $raw
        if (-not $converted.ContainsKey('sessions')) { $converted.sessions = @{} }
        if (-not $converted.ContainsKey('observed')) { $converted.observed = @{} }
        if (-not $converted.ContainsKey('handledJobIds')) { $converted.handledJobIds = @{} }
        if (-not $converted.ContainsKey('lastInventoryAtUtc')) { $converted.lastInventoryAtUtc = $null }
        if (-not $converted.ContainsKey('lastInventoryHash')) { $converted.lastInventoryHash = $null }
        if (-not $converted.ContainsKey('lastSyncAtUtc')) { $converted.lastSyncAtUtc = $null }
        if (-not $converted.ContainsKey('networkBackfillCompleted')) { $converted.networkBackfillCompleted = $false }
        $converted.schemaVersion = 2
        return $converted
    }
    catch {
        Write-AgentDiagnostic 'warning' 'Estado anterior inválido; um novo estado foi iniciado.' @{ error = $_.Exception.Message }
        return New-AgentState
    }
}

function Initialize-NetworkBackfill {
    if ([bool]$state.networkBackfillCompleted) { return }
    $queued = 0
    if (Test-Path -LiteralPath $paths.Events) {
        foreach ($line in @(Get-Content -LiteralPath $paths.Events -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $historicalEvent = $line | ConvertFrom-Json
                if (-not (Test-ReportableEventType -Type ([string]$historicalEvent.type))) { continue }
                Add-LmOutboxItem -RootPath $RootPath -Kind 'event' -Payload $historicalEvent
                $queued++
            } catch { }
        }
    }
    $state.networkBackfillCompleted = $true
    Write-AgentDiagnostic 'information' 'Histórico local preparado para sincronização inicial.' @{ queuedEvents = $queued }
}

function Remove-NonReportableOutboxEvents {
    $outboxPath = Join-Path $RootPath 'data\outbox'
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $outboxPath -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $item = Read-LmJsonFile -Path $file.FullName
            if ($null -ne $item -and [string]$item.kind -eq 'event' -and
                -not (Test-ReportableEventType -Type ([string]$item.payload.type))) {
                Remove-Item -LiteralPath $file.FullName -Force
                $removed++
            }
        } catch { }
    }
    if ($removed -gt 0) {
        Write-AgentDiagnostic 'information' 'Eventos comuns de sessão removidos da fila de envio.' @{ removedEvents = $removed }
    }
}

function Get-AgentVersion {
    if (Test-Path -LiteralPath $paths.Version) { return (Get-Content -LiteralPath $paths.Version -Raw).Trim() }
    return '2.3.0'
}

function Collect-SoftwareInventoryOnRequest {
    $snapshot = Save-LmInventorySnapshot -Path $paths.Inventory
    $state.lastInventoryAtUtc = $snapshot.collectedAtUtc
    $state.lastInventoryHash = [string]$snapshot.inventoryHash
    [IO.File]::WriteAllText((Join-Path $RootPath 'data\state\inventory-pending.flag'), 'pending')
    Write-AgentDiagnostic 'information' 'Inventário coletado por solicitação administrativa.' @{ count = @($snapshot.software).Count; hash = $snapshot.inventoryHash }
    return $snapshot
}

function Queue-PendingUpdateResults {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'data\state') -Filter 'update-result-*.json' -File -ErrorAction SilentlyContinue)) {
        $result = Read-LmJsonFile $file.FullName
        if ($null -ne $result) {
            Add-LmOutboxItem -RootPath $RootPath -Kind 'job_result' -Payload $result
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Start-LmRemoteUpdate {
    param($Job, $NetworkConfig, [string]$AgentVersion)
    if (-not [bool]$NetworkConfig.updates.enabled) { throw 'Atualizações remotas estão desabilitadas nesta estação.' }
    $payload = $Job.payload
    if (-not $payload.downloadUrl -or -not $payload.sha256 -or -not $payload.version) { throw 'Tarefa de atualização incompleta.' }
    if ([version]$payload.version -le [version]$AgentVersion) { throw 'A versão solicitada não é superior à instalada.' }
    $updatesPath = Join-Path $RootPath 'data\updates'
    New-LmDirectory $updatesPath
    $packagePath = Join-Path $updatesPath ('agent-{0}-{1}.zip' -f $payload.version, $Job.id)
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source ([string]$payload.downloadUrl) -Destination $packagePath -ErrorAction Stop
    }
    catch {
        Invoke-WebRequest -Uri ([string]$payload.downloadUrl) -OutFile $packagePath -UseBasicParsing -TimeoutSec 300
    }
    if ((Get-LmSha256File $packagePath) -ne ([string]$payload.sha256).ToLowerInvariant()) {
        Remove-Item -LiteralPath $packagePath -Force
        throw 'O pacote baixado não corresponde ao SHA-256 publicado.'
    }
    $worker = Join-Path $RootPath 'src\UpdateWorker.ps1'
    $arguments = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $worker + '"'),
        '-RootPath',('"' + $RootPath + '"'),'-PackagePath',('"' + $packagePath + '"'),
        '-ExpectedSha256',([string]$payload.sha256),'-TargetVersion',([string]$payload.version),
        '-JobId',([string]$Job.id),'-ParentProcessId',([string]$PID)
    )
    if ([bool]$NetworkConfig.updates.requireAuthenticode) { $arguments += '-RequireAuthenticode' }
    $thumbprints = @($NetworkConfig.updates.trustedSignerThumbprints | ForEach-Object { ([string]$_).Replace(' ', '') })
    if ($thumbprints.Count -gt 0) {
        $arguments += @('-TrustedSignerThumbprints', ($thumbprints -join ','))
    }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList ($arguments -join ' ') -WindowStyle Hidden
    $script:exitRequested = $true
}

function Process-RemoteJobs {
    param($Jobs, $NetworkConfig, [string]$AgentVersion)
    foreach ($job in @($Jobs)) {
        $id = [string]$job.id
        if (-not $id -or $state.handledJobIds.ContainsKey($id)) { continue }
        $state.handledJobIds[$id] = Get-LmUtcNow
        try {
            switch ([string]$job.type) {
                'agent_update' { Start-LmRemoteUpdate -Job $job -NetworkConfig $NetworkConfig -AgentVersion $AgentVersion }
                'inventory_refresh' {
                    $snapshot = Collect-SoftwareInventoryOnRequest
                    Add-LmOutboxItem -RootPath $RootPath -Kind 'job_result' -Payload @{
                        jobId = $id; status = 'succeeded'; message = ('Inventário coletado: {0} programas.' -f @($snapshot.software).Count); timestampUtc = Get-LmUtcNow
                    }
                    $script:syncRequested = $true
                }
                default { throw "Tipo de tarefa não permitido pelo agente: $($job.type)" }
            }
        }
        catch {
            Add-LmOutboxItem -RootPath $RootPath -Kind 'job_result' -Payload @{
                jobId = $id; status = 'failed'; message = $_.Exception.Message; timestampUtc = Get-LmUtcNow
            }
            Write-AgentDiagnostic 'error' 'Tarefa remota recusada ou malsucedida.' @{ jobId = $id; error = $_.Exception.Message }
        }
    }
    if ($state.handledJobIds.Count -gt 500) {
        $keep = @($state.handledJobIds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 250)
        $state.handledJobIds = @{}
        foreach ($item in $keep) { $state.handledJobIds[$item.Key] = $item.Value }
    }
}

function Save-AgentState {
    $script:state.savedAtUtc = Get-LmUtcNow
    Write-LmAtomicJson -Path $paths.State -Value $script:state
}

function New-SessionRecord {
    param([string]$Key, [int]$SessionId, [string]$User, [string]$StartedAtUtc, [string]$Source)
    if (-not $StartedAtUtc) { $StartedAtUtc = Get-LmUtcNow }
    $record = @{
        sessionKey = $Key
        hostname = $env:COMPUTERNAME
        sessionId = $SessionId
        user = $User
        startedAtUtc = $StartedAtUtc
        endedAtUtc = $null
        state = 'active'
        source = $Source
        lastEventAtUtc = $StartedAtUtc
        occurrences = @{}
    }
    $script:state.sessions[$Key] = $record
    return $record
}

function Find-ActiveSession {
    param([int]$SessionId, [string]$User)
    $matches = @($script:state.sessions.Values | Where-Object {
        $_.sessionId -eq $SessionId -and $_.state -ne 'loggedOff' -and
        ([string]::IsNullOrWhiteSpace($User) -or $_.user -eq $User)
    } | Sort-Object startedAtUtc -Descending)
    if ($matches.Count -gt 0) { return $matches[0] }
    return $null
}

function Get-OrCreateSession {
    param([int]$SessionId, [string]$User)
    $session = Find-ActiveSession -SessionId $SessionId -User $User
    if ($null -ne $session) { return $session }
    $marker = 'agent-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $key = New-LmSessionKey -Hostname $env:COMPUTERNAME -SessionId $SessionId -User $User -LoginMarker $marker
    return New-SessionRecord -Key $key -SessionId $SessionId -User $User -StartedAtUtc (Get-LmUtcNow) -Source 'agent-fallback'
}

function Close-Session {
    param([hashtable]$Session, [string]$TimestampUtc, [string]$Reason)
    if ($Session.state -eq 'loggedOff') { return }
    $Session.state = 'loggedOff'
    $Session.endedAtUtc = $TimestampUtc
    $Session.lastEventAtUtc = $TimestampUtc
    Write-LmJsonLine -Path $paths.Sessions -Value ([ordered]@{
        schemaVersion = 1
        sessionKey = $Session.sessionKey
        hostname = $Session.hostname
        sessionId = $Session.sessionId
        user = $Session.user
        startedAtUtc = $Session.startedAtUtc
        endedAtUtc = $Session.endedAtUtc
        occurrences = @($Session.occurrences.Values)
    })
}

function Process-Inbox {
    New-LmDirectory -Path $paths.Inbox
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.Inbox -Filter '*.json' -File | Sort-Object Name)) {
        try {
            $event = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($event.schemaVersion -ne 1 -or -not $event.type -or -not $event.sessionKey) {
                throw 'Evento de sessão fora do esquema esperado.'
            }
            $key = [string]$event.sessionKey
            $session = $null
            if ($script:state.sessions.ContainsKey($key)) { $session = $script:state.sessions[$key] }
            if ($null -eq $session) {
                $session = New-SessionRecord -Key $key -SessionId ([int]$event.sessionId) -User ([string]$event.user) `
                    -StartedAtUtc ([string]$event.timestampUtc) -Source 'session-watcher'
            }
            $session.lastEventAtUtc = [string]$event.timestampUtc
            switch ([string]$event.type) {
                'Login' { $session.state = 'active' }
                'WatcherStarted' { $session.state = 'active' }
                'Lock' { $session.state = 'locked' }
                'Unlock' { $session.state = 'active' }
                'Logoff' { Close-Session $session ([string]$event.timestampUtc) 'interactive-logoff' }
                'ConsoleConnect' { $session.state = 'active' }
                'ConsoleDisconnect' { $session.state = 'disconnected' }
                default { Write-AgentDiagnostic 'warning' 'Tipo de evento de sessão desconhecido.' @{ type = $event.type } }
            }
            Remove-Item -LiteralPath $file.FullName -Force
        }
        catch {
            Write-AgentDiagnostic 'error' 'Falha ao processar evento da caixa de entrada.' @{ file = $file.Name; error = $_.Exception.Message }
            $badPath = $file.FullName + '.bad'
            Move-Item -LiteralPath $file.FullName -Destination $badPath -Force
        }
    }
}

function Get-ProcessUser {
    param($CimProcess)
    try {
        $owner = Invoke-CimMethod -InputObject $CimProcess -MethodName GetOwner -ErrorAction Stop
        if ($owner.ReturnValue -eq 0) {
            if ($owner.Domain) { return '{0}\{1}' -f $owner.Domain, $owner.User }
            return [string]$owner.User
        }
    } catch { }
    return 'unknown'
}

function Test-RuleMatch {
    param($Process, $Rule)
    if (-not $Rule.enabled) { return $false }
    $names = @($Rule.match.processNames)
    foreach ($name in $names) {
        if ([string]::Equals([string]$Process.Name, [string]$name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($Rule.match.pathRegex -and $Process.ExecutablePath) {
        try { if ([string]$Process.ExecutablePath -match [string]$Rule.match.pathRegex) { return $true } }
        catch { Write-AgentDiagnostic 'warning' 'Expressão regular inválida na política.' @{ ruleId = $Rule.id } }
    }
    return $false
}

function Poll-ProhibitedProcesses {
    param($Policy)
    $now = Get-LmUtcNow
    $seen = @{}
    $processes = @(Get-CimInstance Win32_Process -Property Name, ProcessId, SessionId, ExecutablePath, CreationDate -ErrorAction Stop)
    foreach ($process in $processes) {
        if ([int]$process.SessionId -le 0) { continue }
        foreach ($rule in @($Policy.rules)) {
            if (-not (Test-RuleMatch -Process $process -Rule $rule)) { continue }
            $created = if ($process.CreationDate) { ([DateTime]$process.CreationDate).ToUniversalTime().ToString('o') } else { 'unknown' }
            $instanceKey = '{0}|{1}|{2}' -f $rule.id, $process.ProcessId, $created
            $seen[$instanceKey] = $true
            if ($script:state.observed.ContainsKey($instanceKey)) {
                $observed = $script:state.observed[$instanceKey]
                $observed.lastSeenAtUtc = $now
                if ($script:state.sessions.ContainsKey($observed.sessionKey)) {
                    $occ = $script:state.sessions[$observed.sessionKey].occurrences[[string]$rule.id]
                    if ($null -ne $occ) { $occ.lastDetectionAtUtc = $now }
                }
                continue
            }
            $user = Get-ProcessUser -CimProcess $process
            $session = Get-OrCreateSession -SessionId ([int]$process.SessionId) -User $user
            $ruleId = [string]$rule.id
            if (-not $session.occurrences.ContainsKey($ruleId)) {
                $session.occurrences[$ruleId] = @{
                    ruleId = $ruleId; displayName = [string]$rule.displayName; severity = [string]$rule.severity
                    firstDetectionAtUtc = $now; lastDetectionAtUtc = $now; executionCount = 0; activeInstances = 0
                }
            }
            $occurrence = $session.occurrences[$ruleId]
            $occurrence.executionCount = [int]$occurrence.executionCount + 1
            $occurrence.activeInstances = [int]$occurrence.activeInstances + 1
            $occurrence.lastDetectionAtUtc = $now
            $session.lastEventAtUtc = $now
            $script:state.observed[$instanceKey] = @{
                sessionKey = $session.sessionKey; ruleId = $ruleId; processId = [int]$process.ProcessId
                processName = [string]$process.Name; createdAtUtc = $created; firstSeenAtUtc = $now; lastSeenAtUtc = $now
            }
            Write-MonitorEvent -Type 'ProhibitedApplicationDetected' -Session $session -TimestampUtc $now -Data @{
                ruleId = $ruleId; displayName = $rule.displayName; severity = $rule.severity
                processName = $process.Name; processId = [int]$process.ProcessId
                firstDetectionAtUtc = $occurrence.firstDetectionAtUtc
                lastDetectionAtUtc = $occurrence.lastDetectionAtUtc
                executionCount = $occurrence.executionCount
            }
        }
    }
    foreach ($instanceKey in @($script:state.observed.Keys)) {
        if ($seen.ContainsKey($instanceKey)) { continue }
        $observed = $script:state.observed[$instanceKey]
        if ($script:state.sessions.ContainsKey($observed.sessionKey)) {
            $session = $script:state.sessions[$observed.sessionKey]
            if ($session.occurrences.ContainsKey($observed.ruleId)) {
                $occurrence = $session.occurrences[$observed.ruleId]
                $occurrence.activeInstances = [Math]::Max(0, [int]$occurrence.activeInstances - 1)
                Write-MonitorEvent -Type 'ProhibitedApplicationStopped' -Session $session -TimestampUtc $now -Data @{
                    ruleId = $observed.ruleId; processName = $observed.processName; processId = $observed.processId
                    firstSeenAtUtc = $observed.firstSeenAtUtc; lastSeenAtUtc = $observed.lastSeenAtUtc
                    executionCount = $occurrence.executionCount
                }
            }
        }
        $script:state.observed.Remove($instanceKey)
    }
}

foreach ($directory in @($paths.Inbox, (Split-Path $paths.State -Parent), (Split-Path $paths.Events -Parent))) {
    New-LmDirectory -Path $directory
}
$script:state = Import-AgentState
$script:networkConfig = $null
$script:exitRequested = $false
$script:syncRequested = $false
$script:privacyCleanupCompleted = $false
$agentVersion = Get-AgentVersion
$lastHeartbeat = [DateTime]::MinValue
Write-AgentDiagnostic 'information' 'Agente iniciado.' @{ version = $agentVersion; pid = $PID; rootPath = $RootPath }

do {
    try {
        $policy = Read-LmJsonFile -Path $paths.Policy
        if ($null -eq $policy -or $policy.schemaVersion -ne 1) { throw "Política ausente ou inválida: $($paths.Policy)" }
        $effectivePoll = if ($PollSeconds -gt 0) { $PollSeconds } else { [Math]::Max(2, [int]$policy.pollIntervalSeconds) }
        $script:networkConfig = Read-LmJsonFile -Path $paths.Network
        if ($null -ne $networkConfig -and [bool]$networkConfig.enabled) {
            if (-not $script:privacyCleanupCompleted) {
                Remove-NonReportableOutboxEvents
                $script:privacyCleanupCompleted = $true
            }
            Initialize-NetworkBackfill
        }
        Process-Inbox
        Poll-ProhibitedProcesses -Policy $policy
        if ($null -ne $networkConfig -and [bool]$networkConfig.enabled) {
            Queue-PendingUpdateResults
            $syncSeconds = if ($networkConfig.syncIntervalSeconds) { [Math]::Max(1200, [int]$networkConfig.syncIntervalSeconds) } else { 1200 }
            $syncDue = $script:syncRequested -or -not $state.lastSyncAtUtc
            if (-not $syncDue) {
                try { $syncDue = ([DateTime]::UtcNow - [DateTime]::Parse([string]$state.lastSyncAtUtc).ToUniversalTime()).TotalSeconds -ge $syncSeconds }
                catch { $syncDue = $true }
            }
            if ($syncDue) {
                try {
                    $sync = Invoke-LmNetworkSync -RootPath $RootPath -NetworkConfig $networkConfig -AgentVersion $agentVersion -InventoryPath $paths.Inventory
                    $state.lastSyncAtUtc = Get-LmUtcNow
                    $script:syncRequested = $false
                    Process-RemoteJobs -Jobs $sync.jobs -NetworkConfig $networkConfig -AgentVersion $agentVersion
                    if ($script:syncRequested -and -not $script:exitRequested) {
                        $null = Invoke-LmNetworkSync -RootPath $RootPath -NetworkConfig $networkConfig -AgentVersion $agentVersion -InventoryPath $paths.Inventory
                        $state.lastSyncAtUtc = Get-LmUtcNow
                        $script:syncRequested = $false
                    }
                }
                catch {
                    Write-AgentDiagnostic 'warning' 'Sincronização com o servidor indisponível; os dados permanecerão na fila local.' @{ error = $_.Exception.Message }
                    $state.lastSyncAtUtc = [DateTime]::UtcNow.AddSeconds(-[Math]::Max(15, $syncSeconds - 15)).ToString('o')
                }
            }
        }
        Save-AgentState
        if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 60) {
            Write-AgentDiagnostic 'information' 'Heartbeat.' @{ sessions = $state.sessions.Count; observedProcesses = $state.observed.Count }
            $lastHeartbeat = [DateTime]::UtcNow
        }
    }
    catch {
        Write-AgentDiagnostic 'error' 'Falha no ciclo de monitoramento.' @{ error = $_.Exception.Message; stack = $_.ScriptStackTrace }
        $effectivePoll = if ($PollSeconds -gt 0) { $PollSeconds } else { 5 }
    }
    if (-not $Once -and -not $exitRequested) { Start-Sleep -Seconds $effectivePoll }
} while (-not $Once -and -not $exitRequested)
