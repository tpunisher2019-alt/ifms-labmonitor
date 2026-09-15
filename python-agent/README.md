# IFMS LabMonitor Python 0.1.0 — piloto

Versão experimental, não substitui automaticamente o agente 2.3.4.
Não instale nos 150 PCs ainda. Primeiro valide em uma máquina de teste.

## Implementado

- Núcleo compartilhado Windows/Linux, identificação física e MAC da rede ativa.
- Detecção dos processos proibidos da política atual, com contexto do usuário.
- Ocorrências de início/fim do processo, sem registrar todos os logins.
- Fila SQLite persistente: confirmação do servidor antes de remover registros.
- Cadastro e sincronização com o protocolo existente do Supabase.
- Inventário de máquina apenas mediante solicitação do painel (HKLM/dpkg).
- Hospedagem opcional em serviço Windows ou systemd Debian/Ubuntu.

## Limitações importantes

Nesta primeira versão NÃO há monitor de papel de parede, lista de programas
desconhecidos, inventário de aplicativos por usuário, atualização remota do
próprio piloto, renomeação/reinicialização nem migração do histórico local antigo.
Atualizações remotas recebidas são recusadas; nomes remotos não são aplicados.
Não é um executável independente: requer Python 3.11+ e as dependências fixadas.
Windows foi validado localmente em modo offline; serviço como SYSTEM e Debian
precisam de validação real. GNOME não é monitorado nesta versão.

## Teste sem alterar o servidor

O config.json vem com enabled=false. Execute:

```text
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe agent.py --diagnose
.venv\Scripts\python.exe agent.py --once
```

No Linux, use .venv/bin/python. No repositório, a política vem de ../config;
o ZIP inclui policy.json. Dados ficam em data/, isolados do agente PowerShell.
O diagnóstico só consulta a máquina: não envia informações ao Supabase.

## Serviço Windows de teste

Instale Python para TODOS os usuários. Extraia o ZIP e execute
install-windows.bat como administrador. Instalador cria o serviço, mas NÃO
o inicia. Arquivos ficam em C:\ProgramData\IFMS\LabMonitorPythonPreview,
com acesso restrito a administradores e SYSTEM.
Inicie IFMSLabMonitorPythonPreview pela ferramenta Serviços quando estiver
pronto. Para parar/remover o serviço, use service.py stop/remove com o Python
do ambiente instalado. Os dados locais não são apagados automaticamente.

## Debian/Ubuntu usando su, sem sudo

```text
su -
apt-get install python3 python3-venv
cd /caminho/do/pacote
sh install-linux.sh
systemctl enable --now labmonitor-python-preview
```

O instalador não inicia o serviço automaticamente. Dados em
/opt/ifms-labmonitor-python-preview/data, acessíveis somente por root.

## Teste conectado — escolha explícita

1. Pare o agente antigo na máquina de teste. NÃO desinstale ou apague os dados.
2. Proteja a pasta de dados (use os instaladores para um teste como serviço).
3. No config.json instalado, altere enabled para true e allowEnrollment para true
   (Linux: acrescente --allow-enrollment ao ExecStart e recarregue systemd).
4. Inicie o piloto e aprove no painel se solicitado.

ATENÇÃO: numa máquina conhecida, o servidor pode liberar automaticamente e
ROTACIONAR a credencial do cadastro antigo. O piloto verifica se outro agente
está ativo, mas não use os dois conectados simultaneamente. Para voltar ao
agente estável, pare o piloto e reinstale o pacote estável conforme o fluxo
de recadastro. Não copie a pasta data para a imagem Clonezilla.

Não há senha de administrador nem chave service_role no pacote. O servidor
continua verificando a credencial própria e hardware/MAC da máquina.
Sincronização mínima de 20 minutos; fila limitada a 10.000 itens, sem descarte
silencioso ao atingir o limite. Nenhuma tela, tecla ou imagem é capturada.
