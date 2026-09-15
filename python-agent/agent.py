"""LabMonitor Python preview. Never self-updates, renames or reboots a PC."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

VERSION = '0.1.0-python-preview'
BASE = Path(__file__).resolve().parent


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def mac(value):
    result = value.upper().replace('-', ':')
    return result if re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', result) else ''


class Store:
    """Atomic durable queue. Sent records are deleted only after acknowledgement."""
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        if os.name != 'nt':
            self.root.chmod(0o700)
        self.db = sqlite3.connect(self.root / 'state.sqlite3')
        self.db.execute('create table if not exists state(key text primary key,value text not null)')
        self.db.execute('create table if not exists outbox(id integer primary key autoincrement,value text not null)')
        self.db.commit()

    def get(self, key, default=None):
        row = self.db.execute('select value from state where key=?', (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set(self, key, value):
        with self.db:
            self.db.execute('insert or replace into state values(?,?)', (key, json.dumps(value)))

    def queue(self, kind, payload):
        if self.db.execute('select count(*) from outbox').fetchone()[0] >= 10000:
            raise RuntimeError('Fila local atingiu 10.000 registros; resolva a conexão antes de continuar.')
        value = {'schemaVersion': 1, 'kind': kind, 'queuedAtUtc': now(), 'payload': payload}
        with self.db:
            self.db.execute('insert into outbox(value) values(?)', (json.dumps(value),))

    def batch(self):
        return [(row[0], json.loads(row[1])) for row in self.db.execute('select id,value from outbox order by id limit 100')]

    def acknowledge(self, ids):
        with self.db:
            self.db.executemany('delete from outbox where id=?', [(i,) for i in ids])


def windows_hardware():
    import win32com.client
    service = win32com.client.GetObject('winmgmts:root/cimv2')
    def first(query, field):
        return next((str(getattr(item, field) or '') for item in service.ExecQuery(query)), '')
    adapters = {}
    for item in service.ExecQuery('select MACAddress,Name,NetConnectionID from Win32_NetworkAdapter where PhysicalAdapter=True'):
        if item.MACAddress and not re.search(r'VMware|VirtualBox|Hyper-V|TAP|Virtual', str(item.Name), re.I):
            adapters[str(item.NetConnectionID)] = mac(str(item.MACAddress))
    return (
        first('select UUID from Win32_ComputerSystemProduct', 'UUID'),
        first('select SerialNumber from Win32_BIOS', 'SerialNumber'),
        first('select SerialNumber from Win32_BaseBoard', 'SerialNumber'), adapters,
    )


def registration():
    import psutil
    if os.name == 'nt':
        machine_uuid, bios, board, physical = windows_hardware()
    else:
        def read(name):
            try:
                return Path('/sys/class/dmi/id', name).read_text().strip()
            except OSError:
                return ''
        machine_uuid, bios, board = read('product_uuid'), read('product_serial'), read('board_serial')
        physical = {}
        for interface in Path('/sys/class/net').iterdir():
            if (interface / 'device').exists():
                physical[interface.name] = mac((interface / 'address').read_text().strip())
    macs = sorted(set(filter(None, physical.values())))
    # UDP connect selects a route but sends no packet.
    active_ip = ''
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        try:
            route.connect(('8.8.8.8', 53))
            active_ip = route.getsockname()[0]
        except OSError:
            pass
    active_name, active_mac, ips = '', '', []
    for name, addresses in psutil.net_if_addrs().items():
        if name not in physical:
            continue
        for address in addresses:
            if address.family == socket.AF_INET and not address.address.startswith(('127.', '169.254.')):
                ips.append(address.address)
                if address.address == active_ip:
                    active_name, active_mac = name, physical[name]
    parts = []
    if machine_uuid and not re.fullmatch(r'(?:0{8}-0{4}-0{4}-0{4}-0{12}|F{8}-F{4}-F{4}-F{4}-F{12})', machine_uuid, re.I):
        parts.append('uuid:' + machine_uuid.upper())
    for label, serial in [('bios', bios), ('board', board)]:
        if serial and not re.fullmatch(r'Default string|To Be Filled By O\.E\.M\.|None', serial, re.I):
            parts.append(label + ':' + serial.strip().upper())
    parts = parts or ['mac:' + m for m in macs]
    if not parts or not macs:
        raise RuntimeError('Não foi possível obter identidade física confiável; cadastro recusado.')
    fingerprint = digest('|'.join(parts))
    return dict(installationId=digest('|'.join(['hardware:' + fingerprint] + ['mac:' + m for m in macs])),
                hostname=socket.gethostname(), machineUuidHash=digest(machine_uuid), hardwareFingerprint=fingerprint,
                macAddresses=macs, activeMac=active_mac or None, activeAdapterName=active_name or None,
                localIpAddresses=sorted(set(ips)), osType='Windows' if os.name == 'nt' else 'Linux',
                osVersion=platform.platform())


def match_rule(process, rule):
    if not rule.get('enabled'):
        return False
    match = rule.get('match', {})
    if process['name'].casefold() in [name.casefold() for name in match.get('processNames', [])]:
        return True
    return bool(match.get('pathRegex') and re.search(match['pathRegex'], process.get('exe') or ''))


def scan_processes(store, policy):
    import psutil
    previous = store.get('observed', {})
    current = {}
    for process in psutil.process_iter(['pid', 'name', 'exe', 'username', 'create_time']):
        try:
            item = process.info
            user = item.get('username') or ''
            if not user or user.casefold() in ('root', 'system', 'nt authority\\system', 'nt authority\\local service', 'nt authority\\network service'):
                continue
            for rule in policy['rules']:
                if not match_rule(item, rule):
                    continue
                key = f"{rule['id']}|{item['pid']}|{item['create_time']}"
                current[key] = {'ruleId': rule['id'], 'displayName': rule['displayName'], 'processName': item['name'], 'user': user}
                if key not in previous:
                    queue_event(store, 'ProhibitedApplicationDetected', user, current[key])
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    for key, item in previous.items():
        if key not in current:
            queue_event(store, 'ProhibitedApplicationStopped', item['user'], item)
    store.set('observed', current)


def queue_event(store, event_type, user, data):
    # Session context is attached only to an occurrence; no login history stream.
    store.queue('event', {'eventId': str(uuid.uuid4()), 'timestampUtc': now(), 'type': event_type,
                          'user': user, 'sessionKey': digest(user), 'data': data})


def inventory():
    rows = []
    if os.name == 'nt':
        import winreg
        key_path = r'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        for view, arch in [(winreg.KEY_WOW64_64KEY, 'x64'), (winreg.KEY_WOW64_32KEY, 'x86')]:
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path, 0, winreg.KEY_READ | view) as parent:
                    for index in range(winreg.QueryInfoKey(parent)[0]):
                        try:
                            with winreg.OpenKey(parent, winreg.EnumKey(parent, index)) as entry:
                                def value(name):
                                    try:
                                        return str(winreg.QueryValueEx(entry, name)[0])
                                    except OSError:
                                        return ''
                                name = value('DisplayName')
                                if name:
                                    rows.append(dict(name=name, version=value('DisplayVersion'), publisher=value('Publisher'), scope='machine', architecture=arch))
                        except OSError:
                            continue
            except OSError:
                continue
    else:
        result = subprocess.run(['dpkg-query', '-W', '-f=${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\n'], capture_output=True, text=True, check=True, timeout=120)
        for line in result.stdout.splitlines():
            status, name, version, arch = line.split('\t', 3)
            if status.startswith('ii'):
                rows.append(dict(name=name, version=version, architecture=arch, scope='machine', publisher=''))
    for row in rows:
        row['inventoryKey'] = digest(json.dumps(row, sort_keys=True))
    return {'software': rows, 'inventoryHash': digest(json.dumps(rows, sort_keys=True)), 'collectedAtUtc': now()}


class Client:
    def __init__(self, config):
        self.config = config
        url = config['supabaseUrl']
        if not re.fullmatch(r'https://[a-z0-9]+\.supabase\.co', url):
            raise ValueError('Endpoint HTTPS do Supabase inválido.')
        self.url = url + '/functions/v1/' + config['edgeFunctionName']

    def post(self, body, identity):
        secret = identity.get('deviceSecret') or identity['registrationSecret']
        headers = {'Content-Type': 'application/json', 'apikey': self.config['publishableKey'], 'Authorization': 'Bearer ' + secret}
        if identity.get('deviceId'):
            headers['x-device-id'] = identity['deviceId']
        request = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def sync(self, store, metadata, allow_enrollment=False):
        identity = store.get('identity')
        if not identity:
            if not allow_enrollment:
                raise RuntimeError('Cadastro piloto exige --allow-enrollment e agente antigo parado.')
            pending = store.get('enrollment')
            if not pending or pending['installationId'] != metadata['installationId']:
                pending = {'registrationSecret': secrets.token_hex(32), 'installationId': metadata['installationId']}
                store.set('enrollment', pending)
            response = self.post(dict(metadata, action='request_enrollment', agentVersion=VERSION), pending)
            if response.get('enrollmentStatus') != 'authorized':
                raise RuntimeError('Cadastro aguardando aprovação no painel.')
            identity = {'deviceId': response['deviceId'], 'deviceSecret': pending['registrationSecret']}
            store.set('identity', identity)
        batch = store.batch()
        snapshot = store.get('pending_inventory')
        response = self.post(dict(metadata, action='sync', agentVersion=VERSION, sentAtUtc=now(), items=[item for _, item in batch], inventory=snapshot), identity)
        if response.get('reEnrollmentRequired'):
            # Never rotate or discard a credential automatically during a pilot.
            raise RuntimeError('Identidade recusada; interrompa o piloto e confira o cadastro.')
        if not response.get('accepted'):
            raise RuntimeError('Servidor não confirmou o recebimento.')
        store.acknowledge([key for key, _ in batch])
        if snapshot:
            store.set('pending_inventory', None)
        handled = store.get('handled_jobs', [])
        for job in response.get('jobs', []):
            if job['id'] in handled:
                continue
            status, message = 'failed', 'Função não habilitada no piloto Python; use o agente estável.'
            if job['type'] == 'inventory_refresh':
                try:
                    store.set('pending_inventory', inventory())
                    status, message = 'succeeded', 'Inventário de máquina coletado pelo piloto Python.'
                except Exception:
                    message = 'Não foi possível coletar o inventário.'
            store.queue('job_result', {'jobId': job['id'], 'status': status, 'message': message, 'timestampUtc': now()})
            handled = (handled + [job['id']])[-500:]
            store.set('handled_jobs', handled)


def legacy_running():
    import psutil
    for process in psutil.process_iter(['pid', 'cmdline']):
        try:
            command = ' '.join(process.info.get('cmdline') or []).casefold()
            if process.pid != os.getpid() and ('agent.ps1' in command or ('labmonitor' in command and 'agent.py' in command)):
                return True
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            continue
    return False


def run(config, root, policy, once=False, allow_enrollment=False):
    if config.get('enabled'):
        if os.name == 'nt':
            import ctypes
            privileged = bool(ctypes.windll.shell32.IsUserAnAdmin())
        else:
            privileged = os.geteuid() == 0
        if not privileged:
            raise RuntimeError('Teste conectado exige administrador/root e pasta de dados protegida.')
    if config.get('enabled') and legacy_running():
        raise RuntimeError('Outro agente LabMonitor está executando. Pare-o antes do teste conectado.')
    store = Store(root)
    client = Client(config) if config.get('enabled') else None
    next_sync = 0
    while True:
        scan_processes(store, policy)
        if client and time.monotonic() >= next_sync:
            if legacy_running():
                raise RuntimeError('Outro agente foi iniciado; piloto conectado interrompido.')
            try:
                client.sync(store, registration(), allow_enrollment)
            except Exception as error:
                # No HTTP headers, credential or server body is logged.
                print('Sincronização pendente:', type(error).__name__, flush=True)
            next_sync = time.monotonic() + max(1200, config.get('syncIntervalSeconds', 1200))
        if once:
            break
        time.sleep(max(5, config.get('pollIntervalSeconds', 5)))


def main():
    parser = argparse.ArgumentParser(description='LabMonitor Python — piloto isolado')
    parser.add_argument('--config', type=Path, default=BASE / 'config.json')
    parser.add_argument('--data', type=Path, default=BASE / 'data')
    parser.add_argument('--policy', type=Path, default=BASE / 'policy.json' if (BASE / 'policy.json').exists() else BASE.parent / 'config/policy.json')
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--diagnose', action='store_true')
    parser.add_argument('--allow-enrollment', action='store_true')
    args = parser.parse_args()
    if args.diagnose:
        print(json.dumps(registration(), indent=2))
        return
    config, policy = json.loads(args.config.read_text()), json.loads(args.policy.read_text())
    run(config, args.data, policy, args.once, args.allow_enrollment)


if __name__ == '__main__':
    main()
