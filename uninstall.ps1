[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallPath = (Join-Path $env:ProgramData 'IFMS\LabMonitor'),
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute o desinstalador como administrador.'
}

$taskNames = @('IFMS LabMonitor Agent', 'IFMS LabMonitor Session Watcher')
if ($PSCmdlet.ShouldProcess(($taskNames -join ', '), 'Parar e remover tarefas agendadas')) {
    foreach ($taskName in $taskNames) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

$escapedInstallPath = [Regex]::Escape($InstallPath)
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match $escapedInstallPath -and
    ($_.CommandLine -match 'Agent\.ps1' -or $_.CommandLine -match 'SessionWatcher\.ps1')
} | ForEach-Object {
    if ($PSCmdlet.ShouldProcess("PID $($_.ProcessId)", 'Encerrar componente do LabMonitor')) {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

if ($RemoveData) {
    $resolved = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $allowed = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'IFMS\LabMonitor')).TrimEnd('\')
    if (-not [string]::Equals($resolved, $allowed, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Por segurança, -RemoveData só remove o caminho padrão $allowed."
    }
    if ((Test-Path -LiteralPath $resolved) -and $PSCmdlet.ShouldProcess($resolved, 'Remover programa, configuração e todos os logs')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Write-Host 'LabMonitor removido, incluindo dados locais.'
} else {
    Write-Host "Tarefas removidas. Arquivos e logs foram preservados em $InstallPath"
    Write-Host 'Para apagar tudo: .\uninstall.ps1 -RemoveData'
}
