[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:ProgramData 'IFMS\LabMonitor'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute o instalador em um PowerShell elevado (Executar como administrador).'
}

$sourceRoot = $PSScriptRoot
$agentTaskName = 'IFMS LabMonitor Agent'
$watcherTaskName = 'IFMS LabMonitor Session Watcher'

if ((Test-Path -LiteralPath $InstallPath) -and -not $Force) {
    $existing = Get-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
    if ($existing) { throw "O LabMonitor já parece instalado. Use -Force para atualizar mantendo os dados." }
}

# Durante uma atualização, encerra o agente antigo antes de substituir os
# scripts. O observador de sessão pode continuar ativo porque somente grava na
# caixa de entrada; o novo agente processará esses eventos com a política atual.
$existingAgentTask = Get-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
if ($existingAgentTask) {
    Stop-ScheduledTask -TaskName $agentTaskName -ErrorAction SilentlyContinue
}
$escapedInstallPath = [Regex]::Escape([IO.Path]::GetFullPath($InstallPath))
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match $escapedInstallPath -and $_.CommandLine -match 'Agent\.ps1'
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

$directories = @(
    $InstallPath,
    (Join-Path $InstallPath 'src'),
    (Join-Path $InstallPath 'config'),
    (Join-Path $InstallPath 'data\inbox'),
    (Join-Path $InstallPath 'data\outbox'),
    (Join-Path $InstallPath 'data\logs'),
    (Join-Path $InstallPath 'data\state'),
    (Join-Path $InstallPath 'data\updates')
)
foreach ($directory in $directories) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

foreach ($scriptName in @('Agent.ps1','SessionWatcher.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1','WallpaperMonitor.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot ('src\' + $scriptName)) -Destination (Join-Path $InstallPath ('src\' + $scriptName)) -Force
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $InstallPath 'VERSION') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\policy.json') -Destination (Join-Path $InstallPath 'config\policy.default.json') -Force
if (-not (Test-Path -LiteralPath (Join-Path $InstallPath 'config\policy.json'))) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\policy.json') -Destination (Join-Path $InstallPath 'config\policy.json') -Force
}
$packagedNetworkConfig = Join-Path $sourceRoot 'config\network.json'
$networkConfigSource = if (Test-Path -LiteralPath $packagedNetworkConfig) {
    $packagedNetworkConfig
} else {
    Join-Path $sourceRoot 'config\network.example.json'
}
$installedNetworkConfig = Join-Path $InstallPath 'config\network.json'
if (-not (Test-Path -LiteralPath $installedNetworkConfig)) {
    Copy-Item -LiteralPath $networkConfigSource -Destination (Join-Path $InstallPath 'config\network.json') -Force
} elseif (Test-Path -LiteralPath $networkConfigSource) {
    $currentNetwork = Get-Content -LiteralPath $installedNetworkConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    $newDefaults = Get-Content -LiteralPath $networkConfigSource -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($currentNetwork.PSObject.Properties['syncIntervalSeconds']) {
        $currentNetwork.syncIntervalSeconds = [int]$newDefaults.syncIntervalSeconds
    } else {
        $currentNetwork | Add-Member -NotePropertyName syncIntervalSeconds -NotePropertyValue ([int]$newDefaults.syncIntervalSeconds)
    }
    if ($currentNetwork.PSObject.Properties['inventoryIntervalHours']) {
        $currentNetwork.PSObject.Properties.Remove('inventoryIntervalHours')
    }
    if (-not $currentNetwork.PSObject.Properties['updates']) {
        $currentNetwork | Add-Member -NotePropertyName updates -NotePropertyValue ([pscustomobject]@{})
    }
    if ($currentNetwork.updates.PSObject.Properties['enabled']) {
        $currentNetwork.updates.enabled = [bool]$newDefaults.updates.enabled
    } else {
        $currentNetwork.updates | Add-Member -NotePropertyName enabled -NotePropertyValue ([bool]$newDefaults.updates.enabled)
    }
    if ($currentNetwork.updates.PSObject.Properties['requireAuthenticode']) {
        $currentNetwork.updates.requireAuthenticode = [bool]$newDefaults.updates.requireAuthenticode
    } else {
        $currentNetwork.updates | Add-Member -NotePropertyName requireAuthenticode -NotePropertyValue ([bool]$newDefaults.updates.requireAuthenticode)
    }
    $temporaryNetwork = $installedNetworkConfig + '.new'
    [IO.File]::WriteAllText($temporaryNetwork, ($currentNetwork | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporaryNetwork -Destination $installedNetworkConfig -Force
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'uninstall.ps1') -Destination (Join-Path $InstallPath 'uninstall.ps1') -Force

# A pasta do programa é somente leitura para usuários comuns. A caixa de entrada
# recebe Modify porque o observador roda no contexto do usuário interativo.
& icacls.exe $InstallPath /inheritance:r | Out-Null
& icacls.exe $InstallPath /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(RX)' | Out-Null
foreach ($protected in @('data\logs', 'data\state', 'data\outbox', 'data\updates')) {
    $path = Join-Path $InstallPath $protected
    & icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
}
$inboxPath = Join-Path $InstallPath 'data\inbox'
& icacls.exe $inboxPath /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' '*S-1-5-32-545:(OI)(CI)(M)' | Out-Null

$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$agentScript = Join-Path $InstallPath 'src\Agent.ps1'
$watcherScript = Join-Path $InstallPath 'src\SessionWatcher.ps1'
$agentAction = New-ScheduledTaskAction -Execute $powerShell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agentScript`" -RootPath `"$InstallPath`""
$agentTrigger = New-ScheduledTaskTrigger -AtStartup
$agentPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$agentSettings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $agentTaskName -Action $agentAction -Trigger $agentTrigger -Principal $agentPrincipal -Settings $agentSettings -Description 'Agrega sessões e detecta aplicativos proibidos no laboratório.' -Force | Out-Null

$watcherAction = New-ScheduledTaskAction -Execute $powerShell -Argument "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherScript`" -RootPath `"$InstallPath`""
$watcherTrigger = New-ScheduledTaskTrigger -AtLogOn
$watcherPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-4' -RunLevel Limited
$watcherSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel -StartWhenAvailable
Register-ScheduledTask -TaskName $watcherTaskName -Action $watcherAction -Trigger $watcherTrigger -Principal $watcherPrincipal -Settings $watcherSettings -Description 'Mantém o contexto local da sessão para associar ocorrências suspeitas ao usuário.' -Force | Out-Null

Start-ScheduledTask -TaskName $agentTaskName
Write-Host "IFMS LabMonitor instalado em $InstallPath"
Write-Host "Agente iniciado. O observador de sessão inicia no próximo logon."
