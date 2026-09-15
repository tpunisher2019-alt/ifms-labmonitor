"""Optional Windows service host; installed only by an explicit admin command."""
import json
from pathlib import Path
import subprocess
import sys
import win32event
import win32service
import win32serviceutil


class LabMonitorPreview(win32serviceutil.ServiceFramework):
    _svc_name_ = 'IFMSLabMonitorPythonPreview'
    _svc_display_name_ = 'IFMS LabMonitor Python — Piloto'
    _svc_description_ = 'Agente experimental isolado; não substitui o agente estável.'

    def __init__(self, args):
        super().__init__(args)
        self.stop_event = win32event.CreateEvent(None, 0, 0, None)
        self.child = None

    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        win32event.SetEvent(self.stop_event)
        if self.child and self.child.poll() is None:
            self.child.terminate()

    def SvcDoRun(self):
        root = Path(__file__).resolve().parent
        # Explicit enrollment is configured separately, never implied by install.
        config = json.loads((root / 'config.json').read_text())
        arguments = [str(root / '.venv/Scripts/python.exe'), str(root / 'agent.py')]
        if config.get('allowEnrollment') is True:
            arguments.append('--allow-enrollment')
        with (root / 'service.log').open('a', encoding='utf-8') as log:
            self.child = subprocess.Popen(arguments, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
            while self.child.poll() is None:
                if win32event.WaitForSingleObject(self.stop_event, 1000) == win32event.WAIT_OBJECT_0:
                    break
            if self.child.poll() is None:
                self.child.terminate()
                self.child.wait(timeout=30)
            if self.child.returncode not in (0, None) and win32event.WaitForSingleObject(self.stop_event, 0) != win32event.WAIT_OBJECT_0:
                raise RuntimeError('O piloto encerrou com falha; consulte service.log.')


if __name__ == '__main__':
    win32serviceutil.HandleCommandLine(LabMonitorPreview)
