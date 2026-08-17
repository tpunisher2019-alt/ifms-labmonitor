[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$failures = New-Object Collections.Generic.List[string]
function Assert-True { param([bool]$Condition,[string]$Message) if(-not $Condition){$script:failures.Add($Message)} }

Write-Host '1/6 Validando sintaxe PowerShell...'
foreach($file in @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.ps1' -Recurse -File)){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null
    Assert-True ($errors.Count -eq 0) "Erro de sintaxe em $($file.FullName): $($errors.Message -join '; ')"
}

Write-Host '2/6 Validando políticas e configuração segura...'
$policy=Get-Content -LiteralPath (Join-Path $projectRoot 'config\policy.json') -Raw -Encoding UTF8|ConvertFrom-Json
$network=Get-Content -LiteralPath (Join-Path $projectRoot 'config\network.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
Assert-True ($policy.schemaVersion -eq 1) 'schemaVersion da política deve ser 1.'
$ids=@($policy.rules|ForEach-Object{$_.id})
foreach($expected in @('roblox','minecraft','x-vpn')){Assert-True ($ids -contains $expected) "Regra obrigatória ausente: $expected"}
Assert-True (-not [bool]$policy.foreground.enabled) 'Foreground deve vir desabilitado.'
Assert-True (-not [bool]$network.enabled) 'Rede deve vir desabilitada até receber credenciais.'
Assert-True (-not $network.PSObject.Properties['secretKey']) 'A configuração da estação não pode conter chave secreta do Supabase.'
Assert-True (-not $network.PSObject.Properties['enrollmentToken']) 'O agente não deve depender de token de matrícula compartilhado.'
Assert-True ([int]$network.syncIntervalSeconds -ge 1200) 'Intervalo padrão deve suportar 150 máquinas no orçamento do plano gratuito.'
Assert-True (-not $network.PSObject.Properties['inventoryIntervalHours']) 'Inventário não pode ser coletado periodicamente.'

Write-Host '3/6 Testando JSON Lines e fila persistente...'
. (Join-Path $projectRoot 'src\Common.ps1')
. (Join-Path $projectRoot 'src\NetworkClient.ps1')
. (Join-Path $projectRoot 'src\Inventory.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ifms-labmonitor-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
try{
    $jsonl=Join-Path $testRoot 'test.jsonl';Write-LmJsonLine $jsonl @{ok=$true;value=42}
    $line=Get-Content -LiteralPath $jsonl -First 1|ConvertFrom-Json
    Assert-True ($line.ok -and $line.value -eq 42) 'Falha na gravação JSON Lines.'
    Add-LmOutboxItem -RootPath $testRoot -Kind 'event' -Payload @{eventId=[Guid]::NewGuid();type='Test'}
    Assert-True (@(Get-ChildItem (Join-Path $testRoot 'data\outbox') -Filter '*.json').Count -eq 1) 'Fila de saída não persistiu o evento.'
    $registration=Get-LmDeviceRegistrationInfo
    Assert-True ($registration.installationId -match '^[a-f0-9]{64}$') 'Identificador da instalação inválido.'
    Assert-True ($registration.machineUuidHash -match '^[a-f0-9]{64}$') 'Hash do identificador físico inválido.'
    Assert-True ($registration.hardwareFingerprint -match '^[a-f0-9]{64}$') 'Impressão digital do hardware inválida.'
    Assert-True ($registration.installationId -eq $registration.hardwareFingerprint) 'A identidade estável não pode depender do nome do Windows.'
    Assert-True ((New-LmRandomSecret) -match '^[a-f0-9]{64}$') 'Segredo local de autorização inválido.'

    Write-Host '4/6 Coletando inventário real do Windows...'
    $inventory=Save-LmInventorySnapshot -Path (Join-Path $testRoot 'inventory.json')
    Assert-True ($inventory.inventoryHash -match '^[a-f0-9]{64}$') 'Inventário não produziu SHA-256 válido.'
    Assert-True (@($inventory.software).Count -gt 0) 'Inventário não encontrou softwares nesta estação de teste.'

    Write-Host '5/6 Executando um ciclo integrado do agente...'
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'agent\config') -Force|Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'agent\data\inbox') -Force|Out-Null
    Copy-Item (Join-Path $projectRoot 'config\policy.json') (Join-Path $testRoot 'agent\config\policy.json')
    Copy-Item (Join-Path $projectRoot 'VERSION') (Join-Path $testRoot 'agent\VERSION')
    $testPolicy=Get-Content -LiteralPath (Join-Path $testRoot 'agent\config\policy.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $testPolicy.rules+=@([pscustomobject]@{id='test-powershell';displayName='PowerShell de teste';enabled=$true;severity='test';match=[pscustomobject]@{processNames=@('powershell.exe');pathRegex=$null}})
    [IO.File]::WriteAllText((Join-Path $testRoot 'agent\config\policy.json'),($testPolicy|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    $sessionKey=New-LmSessionKey $env:COMPUTERNAME 999 'IFMS\aluno.teste' 'test-login'
    Write-LmInboxEvent (Join-Path $testRoot 'agent\data\inbox') ([ordered]@{schemaVersion=1;eventId=[Guid]::NewGuid();timestampUtc=Get-LmUtcNow;type='Login';hostname=$env:COMPUTERNAME;user='IFMS\aluno.teste';sessionId=999;sessionKey=$sessionKey;component='test'})
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'src\Agent.ps1') -RootPath (Join-Path $testRoot 'agent') -Once
    Assert-True ($LASTEXITCODE -eq 0) "O agente terminou com código $LASTEXITCODE."
    $events=@(Get-Content (Join-Path $testRoot 'agent\data\logs\events.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert-True (@($events|Where-Object{$_.type -match '^Session|^Watcher|^Console'}).Count -eq 0) 'Eventos comuns de sessão não podem ser enviados ou registrados como ocorrência.'
    Assert-True (@($events|Where-Object{$_.type -eq 'ProhibitedApplicationDetected'}).Count -ge 1) 'Processo proibido não gerou ocorrência.'
    $agentSource=Get-Content -LiteralPath (Join-Path $projectRoot 'src\Agent.ps1') -Raw -Encoding UTF8
    Assert-True ($agentSource -notmatch 'Update-SoftwareInventoryIfDue') 'Inventário periódico ainda está presente no agente.'
    Assert-True ($agentSource -match "'inventory_refresh'\s*\{[\s\S]*Collect-SoftwareInventoryOnRequest") 'Inventário sob demanda não está ligado à tarefa remota.'

    Write-Host '6/6 Criando e validando um pacote de atualização...'
    $releaseDirectory=Join-Path $testRoot 'releases'
    $releaseVersion=(Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
    $release=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'tools\New-AgentRelease.ps1') -Version $releaseVersion -OutputDirectory $releaseDirectory
    Assert-True ($LASTEXITCODE -eq 0) 'A criação do pacote de atualização falhou.'
    $zip=Get-ChildItem $releaseDirectory -Filter '*.zip'|Select-Object -First 1
    Assert-True ($null -ne $zip -and (Get-LmSha256File $zip.FullName) -match '^[a-f0-9]{64}$') 'Pacote remoto ou hash inválido.'
}
finally{if(Test-Path $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}}

if($failures.Count){Write-Host '';Write-Host 'FALHAS:' -ForegroundColor Red;foreach($failure in $failures){Write-Host "- $failure" -ForegroundColor Red};exit 1}
Write-Host 'Todos os testes passaram.' -ForegroundColor Green
