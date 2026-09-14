# Agente Linux

## Pacote Debian disponível

A versão 1.0.1 atende Debian 11, 12 e 13 com Python 3 e `systemd`. Nos laboratórios sem `sudo`, a instalação deve ser feita entrando como root:

```sh
su -
cd /caminho/da/pasta/IFMS-LabMonitor-Debian
chmod +x install.sh uninstall.sh
./install.sh
```

O monitoramento de papel de parede consulta especificamente as configurações `picture-uri` e `picture-uri-dark` da sessão GNOME. O pacote também mantém compatibilidade com XFCE, KDE, LXQt e LXDE.

A instalação inicial e as revisões do agente Linux ainda são manuais. O painel bloqueia o envio remoto de pacotes Linux até existir um atualizador próprio para essa plataforma.

## Ubuntu

O painel e o Supabase já aceitam máquinas Windows e Ubuntu no mesmo cadastro. O agente Ubuntu deverá manter o mesmo protocolo de matrícula e sincronização do agente Windows.

## Equivalências previstas

| Windows | Ubuntu |
|---|---|
| Tarefa iniciada no boot | Serviço `systemd` |
| Eventos de sessão do Windows | `systemd-logind` e `loginctl` |
| Registro de programas | `dpkg-query`, Snap e Flatpak quando instalado |
| Processos em execução | `/proc` ou `ps` |
| `ProgramData` | `/var/lib/ifms-labmonitor` |
| Atualização Authenticode | Pacote assinado e hash SHA-256 |

O primeiro piloto deve focar Ubuntu Desktop 24.04 LTS. A detecção de sessão gráfica precisa considerar Wayland e X11; por isso, essa parte não deve reutilizar diretamente o observador PowerShell.

## Campos enviados ao servidor

Além dos campos atuais, o agente envia `osType: "Ubuntu"` e `osVersion`, sem alterar o formato dos eventos, inventário, fila local ou tarefas remotas.
