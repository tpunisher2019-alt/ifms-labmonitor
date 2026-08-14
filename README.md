# IFMS LabMonitor — versão 2

Plataforma para monitorar sessões Windows em laboratórios, detectar aplicativos proibidos, enviar eventos a um servidor central, inventariar softwares e atualizar o agente remotamente. Não captura tela, não registra teclas e não monitora `Alt+Tab`.

## O que está implementado

- agente PowerShell iniciado como `SYSTEM` no boot;
- observador interativo para login, logoff, bloqueio e desbloqueio;
- identificação de hostname, usuário Windows/GCPW visível no Windows e Session ID;
- detecção local de Roblox, Minecraft e X-VPN;
- agrupamento por sessão com primeira/última detecção e contagem de execuções;
- logs locais JSON Lines e fila de saída persistente;
- envio em lotes para uma Edge Function do Supabase, com repetição automática quando a rede falha;
- solicitação de acesso com aprovação em lote pelo administrador e segredo próprio por computador;
- reconhecimento estável por hardware, com MAC e IP como validações auxiliares para evitar duplicidade após renomeação ou formatação;
- inventário de programas via Registro do Windows, incluindo instalações de máquina e perfis carregados;
- atualização remota do agente por tarefa criada no painel;
- verificação de SHA-256, manifesto e, por padrão, assinatura Authenticode dos scripts atualizados;
- painel web para computadores, ocorrências, inventário, versões e histórico de tarefas;
- esquema PostgreSQL, bucket privado e Edge Function do Supabase.
- retenção automática configurável de eventos, com limpeza diária pelo Supabase Cron.

O envio pela rede e as atualizações remotas vêm **desabilitados** até o Supabase ser configurado. O monitoramento local continua funcionando sem internet.

## Estrutura

```text
src/                    agente, inventário, sincronização e atualização
config/                 política local e modelo da configuração de rede
supabase/               migração SQL e Edge Function device-sync
dashboard/              painel web de gerenciamento
tools/                  criação de pacotes de atualização
tests/                  testes locais
install.ps1/.bat        instalação
uninstall.ps1/.bat      desinstalação segura
```

## Instalação local

Execute `install.bat` como administrador. O destino é calculado a partir da pasta `ProgramData` do Windows, normalmente:

```text
C:\ProgramData\IFMS\LabMonitor
```

O instalador cria as tarefas `IFMS LabMonitor Agent` e `IFMS LabMonitor Session Watcher`. Após instalar, faça logoff/login para ativar o observador na sessão atual.

## Logs e estado

```text
data\logs\events.jsonl       eventos de sessões e aplicativos
data\logs\sessions.jsonl     resumos de sessões encerradas
data\logs\agent.jsonl        diagnóstico e sincronização
data\state\inventory.json    último inventário local
data\outbox\                 eventos aguardando envio
```

Os dados não são descartados quando o servidor fica indisponível: permanecem na fila e são enviados na próxima sincronização bem-sucedida.

## Conectar ao Supabase

Consulte [docs/CONFIGURAR-SUPABASE.md](docs/CONFIGURAR-SUPABASE.md). Em resumo:

1. crie um projeto Supabase;
2. aplique `supabase/migrations/001_labmonitor_v2.sql`;
3. publique a função `supabase/functions/device-sync`;
4. edite `config\network.json` na instalação e altere `enabled` para `true`;
5. autorize as máquinas solicitantes no painel;
6. configure `SUPABASE_URL` e `SUPABASE_SECRET_KEY` somente no servidor do painel.

Nunca coloque a chave secreta ou `service_role` nas estações. Elas recebem apenas a chave publicável e um segredo individual de dispositivo.

## Inventário

O inventário é coletado a cada seis horas por padrão. Ele lê as áreas de desinstalação de 64 bits, 32 bits e dos perfis de usuário carregados, sem utilizar `Win32_Product` — que pode ser lento e disparar reparos MSI.

O servidor recebe nome, versão, fabricante, data, arquitetura, escopo e ProductCode quando existente. Programas removidos deixam de aparecer após um inventário confirmado.

## Retenção dos eventos

A migração `002_event_retention.sql` mantém ocorrências por 90 dias por padrão e executa uma limpeza diária. O período pode ser alterado no painel para 30, 60, 90, 180 ou 365 dias. A limpeza afeta somente `device_events`; cadastro das máquinas, inventário, versões e tarefas não é excluído.

## Atualização remota

O painel não envia comandos PowerShell arbitrários. Ele cria somente tarefas permitidas pelo agente: `inventory_refresh` e `agent_update`.

Crie o pacote:

```powershell
.\tools\New-AgentRelease.ps1 -Version 2.2.0 -RequireAuthenticode -TrustedSignerThumbprints SEU_THUMBPRINT
```

Depois, envie o ZIP ao bucket privado `agent-releases` e cadastre versão, caminho e SHA-256 em `agent_releases`. O painel poderá direcionar essa versão para máquinas selecionadas.

O agente baixa por BITS quando disponível, confere o hash, valida todos os arquivos do manifesto, verifica assinatura digital e mantém backup para recuperação. Política e credenciais locais não são substituídas por uma atualização do agente.

Para um piloto com scripts ainda não assinados, `requireAuthenticode` pode ser temporariamente desativado em `network.json`. Não use essa configuração em produção.

## Testes

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LabMonitor.ps1
```

Os testes validam sintaxe, política, JSON Lines, fila, inventário e um ciclo isolado do agente. O painel requer dependências Node para executar o build; veja o README dentro de `dashboard`.

## Desinstalação

`uninstall.bat` remove as tarefas e encerra somente os componentes do LabMonitor. Configuração, identidade e logs são preservados. Para apagar também os dados:

```powershell
C:\ProgramData\IFMS\LabMonitor\uninstall.ps1 -RemoveData
```

## Limitações atuais

- o e-mail GCPW ainda não é resolvido de forma garantida; a identidade vem do Windows;
- inventário de usuário alcança perfis cujas colmeias do Registro estejam carregadas;
- não instala programas de terceiros remotamente nesta versão; a atualização remota é limitada ao próprio agente;
- bloqueio com AppLocker/WDAC, comparação de administradores GCPW e notificações ainda não foram implementados;
- o painel precisa ser conectado a um projeto Supabase e publicado em ambiente privado;
- retenção dos eventos deve ser definida conforme a política institucional e a capacidade do plano escolhido.
