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

foreach ($scriptName in @('Agent.ps1','SessionWatcher.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot ('src\' + $scriptName)) -Destination (Join-Path $InstallPath ('src\' + $scriptName)) -Force
}
Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination (Join-Path $InstallPath 'VERSION') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\policy.json') -Destination (Join-Path $InstallPath 'config\policy.default.json') -Force
if (-not (Test-Path -LiteralPath (Join-Path $InstallPath 'config\policy.json'))) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\policy.json') -Destination (Join-Path $InstallPath 'config\policy.json') -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $InstallPath 'config\network.json'))) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'config\network.example.json') -Destination (Join-Path $InstallPath 'config\network.json') -Force
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
Register-ScheduledTask -TaskName $watcherTaskName -Action $watcherAction -Trigger $watcherTrigger -Principal $watcherPrincipal -Settings $watcherSettings -Description 'Registra login, bloqueio, desbloqueio e logoff da sessão interativa.' -Force | Out-Null

Start-ScheduledTask -TaskName $agentTaskName
Write-Host "IFMS LabMonitor instalado em $InstallPath"
Write-Host "Agente iniciado. O observador de sessão inicia no próximo logon."
