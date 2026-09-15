param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$requiredFiles = @('agent.py','service.py','config.json','requirements.txt','policy.json','README.md')
foreach ($name in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Pacote incompleto: $name" }
}
$packageConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
if ($packageConfig.enabled) { throw 'Este instalador exige o pacote piloto offline.' }
if ($ValidateOnly) { Write-Host 'Pacote completo e offline; nenhuma instalação foi realizada.'; exit 0 }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $escapedScript = $PSCommandPath.Replace("'", "''")
    $elevatedCommand = "& '$escapedScript'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
    $elevated = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedCommand) -Wait -PassThru
    if ($elevated.ExitCode -eq 0) { Write-Host 'Piloto instalado e iniciado em modo offline.' }
    else { Write-Host 'Instalação falhou. Consulte C:\ProgramData\IFMS\LabMonitorPythonPreview\install.log, caso exista. Nenhum dado existente foi sobrescrito.' }
    exit $elevated.ExitCode
}
$target = 'C:\ProgramData\IFMS\LabMonitorPythonPreview'
if (Test-Path $target) { throw 'Piloto já instalado. Não serão sobrescritas configurações ou dados.' }
if (Get-Service -Name IFMSLabMonitorPythonPreview -ErrorAction SilentlyContinue) { throw 'Serviço já existente; instalação interrompida.' }
New-Item -ItemType Directory -Path $target -Force | Out-Null
& icacls.exe $target /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível proteger os dados do piloto.' }
Start-Transcript -Path (Join-Path $target 'install.log') -Append | Out-Null
foreach ($name in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $target $name)
}
$basePython = $null
# Only machine-wide runtimes can reliably be used by a SYSTEM service.
foreach ($candidate in @('C:\Python314\python.exe','C:\Program Files\Python314\python.exe','C:\Program Files\Python313\python.exe','C:\Program Files\Python312\python.exe','C:\Program Files\Python311\python.exe')) {
    if (Test-Path -LiteralPath $candidate) {
        & $candidate -c "import sys; assert sys.version_info >= (3,11) and sys.maxsize > 2**32"
        if ($LASTEXITCODE -eq 0) { $basePython = $candidate; break }
    }
}
if (-not $basePython) {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'O instalador automático requer Windows 64 bits.' }
    Write-Host 'Baixando Python oficial. É necessária conexão com a internet.'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $download = Join-Path $target 'python-setup.exe'
    Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.14.6/python-3.14.6-amd64.exe' -OutFile $download -UseBasicParsing
    $signature = Get-AuthenticodeSignature -LiteralPath $download
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') { throw 'Assinatura do instalador Python inválida.' }
    $pythonDirectory = Join-Path $target 'Python'
    $setup = Start-Process -FilePath $download -WindowStyle Hidden -ArgumentList @('/quiet','InstallAllUsers=1','PrependPath=0','Include_launcher=0','Include_test=0',('TargetDir="' + $pythonDirectory + '"')) -Wait -PassThru
    if ($setup.ExitCode -notin @(0,3010)) { throw "Instalação do Python falhou: $($setup.ExitCode)" }
    $basePython = Join-Path $pythonDirectory 'python.exe'
}
& $basePython -m venv (Join-Path $target '.venv')
if ($LASTEXITCODE -ne 0) { throw 'Criação do ambiente Python falhou.' }
$interpreter = Join-Path $target '.venv\Scripts\python.exe'
& $interpreter -m pip install --requirement (Join-Path $target 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Instalação de dependências falhou.' }
# The native service host lives at the venv root and needs its runtime DLLs there.
$runtimeFiles = & $interpreter -c "import json,sys,win32api,pywintypes,pythoncom; print(json.dumps([win32api.GetModuleFileName(sys.dllhandle),pywintypes.__file__,pythoncom.__file__]))"
if ($LASTEXITCODE -ne 0) { throw 'Validação do runtime do serviço falhou.' }
foreach ($runtimeFile in ($runtimeFiles | ConvertFrom-Json)) {
    Copy-Item -LiteralPath $runtimeFile -Destination (Join-Path $target '.venv') -Force
}
foreach ($runtimeFile in (Get-ChildItem -LiteralPath (Split-Path $basePython -Parent) -Filter 'vcruntime*.dll')) {
    Copy-Item -LiteralPath $runtimeFile.FullName -Destination (Join-Path $target '.venv') -Force
}
& $interpreter (Join-Path $target 'service.py') --startup auto install
if ($LASTEXITCODE -ne 0) { throw 'Registro do serviço falhou.' }
Start-Service -Name IFMSLabMonitorPythonPreview
Start-Sleep -Seconds 3
if ((Get-Service IFMSLabMonitorPythonPreview).Status -ne 'Running') { throw 'O serviço não permaneceu ativo. Consulte service.log na pasta instalada.' }
Write-Host 'Piloto instalado e iniciado. Envio ao servidor continua desabilitado.'
Write-Host 'O agente antigo não foi alterado. Leia README.md antes de conectar ao site.'
Stop-Transcript | Out-Null
