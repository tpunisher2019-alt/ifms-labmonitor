param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'outputs'))
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$stage = Join-Path ([IO.Path]::GetTempPath()) ('lm-python-package-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($name in @('agent.py','service.py','requirements.txt','config.json','README.md','install.bat','install-windows.bat','install-windows.ps1','install.sh','install-linux.sh','labmonitor-python-preview.service')) {
        Copy-Item -LiteralPath (Join-Path $project ('python-agent/' + $name)) -Destination (Join-Path $stage $name)
    }
    Copy-Item -LiteralPath (Join-Path $project 'config/policy.json') -Destination (Join-Path $stage 'policy.json')
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $zip = Join-Path $OutputDirectory 'IFMS-LabMonitor-Python-0.1.0-preview.zip'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Get-FileHash -LiteralPath $zip -Algorithm SHA256
} finally {
    if ($stage.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $stage -Leaf) -like 'lm-python-package-*') { Remove-Item -LiteralPath $stage -Recurse -Force }
}
