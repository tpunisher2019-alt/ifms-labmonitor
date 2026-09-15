#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for name in agent.py config.json requirements.txt policy.json README.md labmonitor-python-preview.service; do
    [ -f "$source_dir/$name" ] || { echo "Pacote incompleto: $name"; exit 1; }
done
if [ "${1:-}" = --validate-only ]; then
    echo 'Arquivos presentes; nenhuma instalação foi realizada.'
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo 'Entre com su - e execute sh install.sh novamente.'; exit 1; }
target=/opt/ifms-labmonitor-python-preview
[ ! -e "$target" ] || { echo 'Piloto já instalado; dados não serão sobrescritos.'; exit 1; }
[ ! -e /etc/systemd/system/labmonitor-python-preview.service ] || { echo 'Serviço já existente; instalação interrompida.'; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo 'Instalador destinado a Debian/Ubuntu com apt-get.'; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo 'Este instalador requer systemd.'; exit 1; }
[ -d /run/systemd/system ] || { echo 'Execute num sistema iniciado com systemd.'; exit 1; }
echo 'Instalando Python e dependências pelos repositórios do sistema. Requer internet.'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv ca-certificates
python3 -c 'import sys; assert sys.version_info >= (3,11), "Requer Python 3.11+"'
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c.get("enabled") is False, "Pacote deve estar offline"' "$source_dir/config.json"
umask 077
mkdir -p "$target"
trap 'echo "Instalação interrompida. Consulte a saída acima; nenhum dado existente foi sobrescrito." >&2' 0
for name in agent.py config.json requirements.txt policy.json README.md; do
    cp "$source_dir/$name" "$target/$name"
done
python3 -m venv "$target/.venv"
"$target/.venv/bin/python" -m pip install -r "$target/requirements.txt"
cp "$source_dir/labmonitor-python-preview.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now labmonitor-python-preview.service
sleep 3
systemctl is-active --quiet labmonitor-python-preview.service || { echo 'Serviço não ficou ativo; consulte journalctl -u labmonitor-python-preview.service.'; exit 1; }
trap - 0
echo 'Piloto instalado e iniciado, inclusive na inicialização do PC.'
echo 'Envio ao site DESABILITADO. O agente antigo não foi alterado. Leia README.md.'
