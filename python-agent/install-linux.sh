#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || { echo 'Entre com su - antes de instalar.'; exit 1; }
target=/opt/ifms-labmonitor-python-preview
[ ! -e "$target" ] || { echo 'Piloto já instalado; dados não serão sobrescritos.'; exit 1; }
[ ! -e /etc/systemd/system/labmonitor-python-preview.service ] || { echo 'Serviço já existente; instalação interrompida.'; exit 1; }
python3 -c 'import sys; assert sys.version_info >= (3,11), "Requer Python 3.11+"'
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
umask 077
mkdir -p "$target"
for name in agent.py config.json requirements.txt policy.json README.md; do
    cp "$source_dir/$name" "$target/$name"
done
python3 -m venv "$target/.venv"
"$target/.venv/bin/python" -m pip install -r "$target/requirements.txt"
cp "$source_dir/labmonitor-python-preview.service" /etc/systemd/system/
systemctl daemon-reload
echo 'Piloto instalado, mas não habilitado nem iniciado. Leia README.md.'
