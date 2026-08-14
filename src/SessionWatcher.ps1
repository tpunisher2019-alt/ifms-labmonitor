[CmdletBinding()]
param([string]$RootPath = (Join-Path $env:ProgramData 'IFMS\LabMonitor'))

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$sessionId = (Get-Process -Id $PID).SessionId
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$hostname = $env:COMPUTERNAME
$inbox = Join-Path $RootPath 'data\inbox'
$userStateDirectory = Join-Path $env:LOCALAPPDATA 'IFMS\LabMonitor'
$userStatePath = Join-Path $userStateDirectory 'watcher-state.json'
New-LmDirectory -Path $userStateDirectory

$mutex = New-Object Threading.Mutex($false, "Local\IFMS-LabMonitor-SessionWatcher-$sessionId")
if (-not $mutex.WaitOne(0)) { exit 0 }

function Get-LoginMarker {
    $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId } |
        Sort-Object StartTime | Select-Object -First 1)
    if ($explorer.Count -gt 0) {
        try { return $explorer[0].StartTime.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') } catch { }
    }
    return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
}

$loginMarker = Get-LoginMarker
$previous = Read-LmJsonFile -Path $userStatePath
$isNewLogin = $true
if ($null -ne $previous -and [int]$previous.sessionId -eq $sessionId -and
    [string]$previous.loginMarker -eq $loginMarker -and -not [bool]$previous.closed) {
    $isNewLogin = $false
    $sessionKey = [string]$previous.sessionKey
} else {
    $sessionKey = New-LmSessionKey -Hostname $hostname -SessionId $sessionId -User $user -LoginMarker $loginMarker
}

$watcherState = [ordered]@{
    schemaVersion = 1; sessionId = $sessionId; user = $user; loginMarker = $loginMarker
    sessionKey = $sessionKey; closed = $false; updatedAtUtc = Get-LmUtcNow
}
Write-LmAtomicJson -Path $userStatePath -Value $watcherState

function Send-SessionEvent {
    param([string]$Type)
    $timestamp = Get-LmUtcNow
    $event = [ordered]@{
        schemaVersion = 1; eventId = [Guid]::NewGuid().ToString(); timestampUtc = $timestamp
        type = $Type; hostname = $hostname; user = $user; sessionId = $sessionId
        sessionKey = $sessionKey; component = 'session-watcher'
    }
    Write-LmInboxEvent -InboxPath $inbox -Event $event
    $watcherState.updatedAtUtc = $timestamp
    if ($Type -eq 'Logoff') { $watcherState.closed = $true }
    Write-LmAtomicJson -Path $userStatePath -Value $watcherState
}

if ($isNewLogin) { Send-SessionEvent 'Login' } else { Send-SessionEvent 'WatcherStarted' }

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace IFMS.LabMonitor {
    public sealed class WtsSessionEventArgs : EventArgs {
        public int Change { get; private set; }
        public int SessionId { get; private set; }
        public WtsSessionEventArgs(int change, int sessionId) { Change = change; SessionId = sessionId; }
    }

    public sealed class SessionWindow : Form {
        private const int WM_WTSSESSION_CHANGE = 0x02B1;
        private const int NOTIFY_FOR_THIS_SESSION = 0;
        [DllImport("wtsapi32.dll", SetLastError = true)]
        private static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int dwFlags);
        [DllImport("wtsapi32.dll")]
        private static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);

        public event EventHandler<WtsSessionEventArgs> SessionChanged;
        public SessionWindow() {
            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            Opacity = 0;
        }
        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            WTSRegisterSessionNotification(Handle, NOTIFY_FOR_THIS_SESSION);
        }
        protected override void OnHandleDestroyed(EventArgs e) {
            WTSUnRegisterSessionNotification(Handle);
            base.OnHandleDestroyed(e);
        }
        protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_WTSSESSION_CHANGE && SessionChanged != null) {
                SessionChanged(this, new WtsSessionEventArgs(m.WParam.ToInt32(), m.LParam.ToInt32()));
            }
            base.WndProc(ref m);
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop
    $window = New-Object IFMS.LabMonitor.SessionWindow
    $window.add_SessionChanged({
        param($sender, $eventArgs)
        if ($eventArgs.SessionId -ne $sessionId) { return }
        switch ($eventArgs.Change) {
            1 { Send-SessionEvent 'ConsoleConnect' }
            2 { Send-SessionEvent 'ConsoleDisconnect' }
            6 { Send-SessionEvent 'Logoff'; $sender.Close() }
            7 { Send-SessionEvent 'Lock' }
            8 { Send-SessionEvent 'Unlock' }
        }
    })
    [Windows.Forms.Application]::Run($window)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
