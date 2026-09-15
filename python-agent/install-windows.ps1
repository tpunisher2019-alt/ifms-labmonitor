$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Execute como administrador.' }
$target = 'C:\ProgramData\IFMS\LabMonitorPythonPreview'
if (Test-Path $target) { throw 'Piloto já instalado. Não serão sobrescritas configurações ou dados.' }
if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) { throw 'Instale Python 3.11 ou superior para todos os usuários primeiro.' }
& python.exe -c "import sys; assert sys.version_info >= (3,11), 'Requer Python 3.11+'"
if ($LASTEXITCODE -ne 0) { throw 'Python incompatível.' }
New-Item -ItemType Directory -Path $target -Force | Out-Null
& icacls.exe $target /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger os dados do piloto.' }
foreach ($name in @('agent.py','service.py','config.json','requirements.txt','policy.json','README.md')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $target $name)
}
& python.exe -m venv (Join-Path $target '.venv')
if ($LASTEXITCODE -ne 0) { throw 'Criação do ambiente Python falhou.' }
$interpreter = Join-Path $target '.venv\Scripts\python.exe'
& $interpreter -m pip install --requirement (Join-Path $target 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Instalação de dependências falhou.' }
& $interpreter (Join-Path $target 'service.py') --startup auto install
if ($LASTEXITCODE -ne 0) { throw 'Registro do serviço falhou.' }
Write-Host 'Piloto instalado, mas não iniciado. Envio ao servidor está desabilitado.'
Write-Host 'Leia README.md antes de habilitar e iniciar IFMSLabMonitorPythonPreview.'
