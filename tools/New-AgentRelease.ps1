[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'outputs'),
    [switch]$RequireAuthenticode,
    [string[]]$TrustedSignerThumbprints = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'src\Common.ps1')
$expectedVersion = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
if ($Version -ne $expectedVersion) { throw "A versão solicitada ($Version) difere do arquivo VERSION ($expectedVersion)." }
$files = @('Agent.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1','SessionWatcher.ps1')
$trusted = @($TrustedSignerThumbprints | ForEach-Object { ([string]$_).Replace(' ','').ToUpperInvariant() })
$stage = Join-Path ([IO.Path]::GetTempPath()) ('labmonitor-release-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $stage 'src') -Force | Out-Null
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
        $manifestFiles += [ordered]@{ path = $name; sha256 = Get-LmSha256File $source }
    }
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

