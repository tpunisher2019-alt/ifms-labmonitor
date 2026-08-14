[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256,
    [Parameter(Mandatory = $true)][string]$TargetVersion,
    [Parameter(Mandatory = $true)][string]$JobId,
    [int]$ParentProcessId = 0,
    [switch]$RequireAuthenticode,
    [string[]]$TrustedSignerThumbprints = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$stagingRoot = Join-Path $RootPath 'data\updates'
$resultPath = Join-Path $RootPath ('data\state\update-result-{0}.json' -f $JobId)
$backupPath = Join-Path $stagingRoot ('backup-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
$extractPath = Join-Path $stagingRoot ('extract-' + [Guid]::NewGuid().ToString('N'))

function Write-UpdateResult {
    param([string]$Status, [string]$Message)
    Write-LmAtomicJson -Path $resultPath -Value ([ordered]@{
        schemaVersion = 1; jobId = $JobId; status = $Status; message = $Message
        targetVersion = $TargetVersion; timestampUtc = Get-LmUtcNow
    })
}

try {
    if ($ParentProcessId -gt 0) {
        Wait-Process -Id $ParentProcessId -Timeout 60 -ErrorAction SilentlyContinue
    }
    if ((Get-LmSha256File $PackagePath) -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Hash SHA-256 do pacote não confere.' }
    New-LmDirectory $extractPath
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $extractPath -Force
    $manifest = Read-LmJsonFile (Join-Path $extractPath 'manifest.json')
    if ($null -eq $manifest -or $manifest.schemaVersion -ne 1 -or [string]$manifest.version -ne $TargetVersion) {
        throw 'Manifesto do pacote ausente, inválido ou com versão diferente.'
    }
    $allowedFiles = @('Agent.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1','SessionWatcher.ps1')
    $trustedThumbprints = @($TrustedSignerThumbprints | ForEach-Object { ([string]$_).Replace(' ', '').ToUpperInvariant() })
    foreach ($entry in @($manifest.files)) {
        if ($allowedFiles -notcontains [string]$entry.path) { throw "Arquivo não permitido no pacote: $($entry.path)" }
        $file = Join-Path $extractPath ('src\' + [string]$entry.path)
        if (-not (Test-Path -LiteralPath $file)) { throw "Arquivo ausente no pacote: $($entry.path)" }
        if ((Get-LmSha256File $file) -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Hash inválido: $($entry.path)" }
        if ($RequireAuthenticode) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file
            if ($signature.Status -ne 'Valid') { throw "Assinatura Authenticode inválida: $($entry.path)" }
            $thumbprint = $signature.SignerCertificate.Thumbprint.ToUpperInvariant()
            if ($trustedThumbprints.Count -gt 0 -and $trustedThumbprints -notcontains $thumbprint) {
                throw "Assinante não autorizado: $($entry.path)"
            }
        }
    }
    New-LmDirectory $backupPath
    Copy-Item -LiteralPath (Join-Path $RootPath 'src') -Destination (Join-Path $backupPath 'src') -Recurse -Force
    foreach ($entry in @($manifest.files)) {
        Copy-Item -LiteralPath (Join-Path $extractPath ('src\' + [string]$entry.path)) `
            -Destination (Join-Path $RootPath ('src\' + [string]$entry.path)) -Force
    }
    [IO.File]::WriteAllText((Join-Path $RootPath 'VERSION'), $TargetVersion + [Environment]::NewLine)
    Write-UpdateResult 'succeeded' 'Atualização aplicada e agente reiniciado.'
    Start-ScheduledTask -TaskName 'IFMS LabMonitor Agent' -ErrorAction SilentlyContinue
}
catch {
    try {
        if (Test-Path -LiteralPath (Join-Path $backupPath 'src')) {
            Copy-Item -Path (Join-Path $backupPath 'src\*') -Destination (Join-Path $RootPath 'src') -Recurse -Force
        }
    } catch { }
    Write-UpdateResult 'failed' $_.Exception.Message
    try { Start-ScheduledTask -TaskName 'IFMS LabMonitor Agent' -ErrorAction SilentlyContinue } catch { }
    exit 1
}
