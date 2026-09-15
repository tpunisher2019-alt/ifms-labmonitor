[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'outputs'),
    [string]$NetworkConfigPath,
    [switch]$Legacy232Compatible,
    [switch]$RequireAuthenticode,
    [string[]]$TrustedSignerThumbprints = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\Common.ps1')
$expectedVersion = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
if ($Version -ne $expectedVersion) { throw "A versão solicitada ($Version) difere do arquivo VERSION ($expectedVersion)." }
$files = @('Agent.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1','SessionWatcher.ps1','WallpaperMonitor.ps1')
$trusted = @($TrustedSignerThumbprints | ForEach-Object { ([string]$_).Replace(' ','').ToUpperInvariant() })
$stage = Join-Path ([IO.Path]::GetTempPath()) ('labmonitor-release-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $stage 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stage 'config') -Force | Out-Null
    $manifestFiles = @()
    foreach ($name in $files) {
        $source = Join-Path $projectRoot ('src\' + $name)
        if ($RequireAuthenticode) {
            $signature = Get-AuthenticodeSignature -LiteralPath $source
            if ($signature.Status -ne 'Valid') { throw "Assinatura inválida ou ausente: $name" }
            if ($trusted.Count -gt 0 -and $trusted -notcontains $signature.SignerCertificate.Thumbprint.ToUpperInvariant()) {
                throw "Assinante não autorizado: $name"
            }
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage ('src\' + $name))
        # 2.3.2 already installed WallpaperMonitor, but its updater whitelist
        # cannot replace it. Keep it in the ZIP for fresh installs.
        if (-not ($Legacy232Compatible -and $name -eq 'WallpaperMonitor.ps1')) {
            $manifestFiles += [ordered]@{ path = $name; sha256 = Get-LmSha256File $source }
        }
    }
    foreach ($name in @('install.ps1','install.bat','uninstall.ps1','uninstall.bat','VERSION')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $stage $name)
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'config\policy.json') -Destination (Join-Path $stage 'config\policy.json')
    if ($NetworkConfigPath) {
        Copy-Item -LiteralPath $NetworkConfigPath -Destination (Join-Path $stage 'config\network.json')
    } else {
        Copy-Item -LiteralPath (Join-Path $projectRoot 'config\network.example.json') -Destination (Join-Path $stage 'config\network.example.json')
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\LEIA-ME-AGENTE-WINDOWS.txt') -Destination (Join-Path $stage 'LEIA-ME - Agente Windows.txt')
    Write-LmAtomicJson -Path (Join-Path $stage 'manifest.json') -Value ([ordered]@{
        schemaVersion = 1; product = 'IFMS LabMonitor Agent'; version = $Version
        createdAtUtc = Get-LmUtcNow; files = $manifestFiles
    })
    New-LmDirectory $OutputDirectory
    $zip = Join-Path $OutputDirectory ('IFMS-LabMonitor-Agent-' + $Version + '.zip')
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    [pscustomobject]@{ Path = $zip; Version = $Version; Sha256 = Get-LmSha256File $zip }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
