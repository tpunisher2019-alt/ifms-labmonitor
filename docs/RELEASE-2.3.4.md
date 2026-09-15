# Windows agent 2.3.4 / dashboard 2.4.6

The agent package includes manual installers and project configuration (only
the public publishable key, never an administrator or device secret).

SHA-256: `078d68f113f3b4f2e859eb3d0d034d59b95d6c0a777b23f16e88de8e89505057`
Storage: `agent-releases/windows/2.3.4/IFMS-LabMonitor-Agent-2.3.4.zip`

## Update compatibility

The 2.3.2/2.3.3 updater rejects WallpaperMonitor.ps1 in a manifest. This
transition ZIP includes that file for fresh installs but retains the already
installed copy during remote upgrades. The new updater includes the proper
whitelist for future releases. Remote upgrade from versions older than 2.3.2
is rejected: use the complete manual installer.

The device-sync gateway now accepts custom device secrets; the function still
authenticates each device and checks hardware/MAC consistency. Optional server
response fields no longer cause StrictMode exceptions.

## Managed hostname

An active physical IPv4 default-route adapter supplies the Ethernet/Wi-Fi MAC
and interface name. Virtual adapters are excluded from machine identification.
The administrator explicitly saves the current or desired name in Computers.
Only one enabled name per computer is kept; another computer cannot bind the
same MAC or desired hostname. Updating the binding creates a new revision.

A matching authenticated device receives the desired name. Switching Ethernet
and Wi-Fi still works when the saved physical MAC remains present. Reinstalling
the same hardware can recover the existing device and assignment, subject to
the configured known-device authorization policy. IP is not an identity key.

This release supports managed names on Windows outside an AD domain. A changed
name schedules a reboot in 60 seconds: save work before applying. Domain PCs
report a failure rather than collecting domain credentials. Failed revisions
are not retried indefinitely; save again to retry. Disable stops future
assignment delivery, including when the PC is offline, but cannot cancel an
already scheduled reboot or recall a command already received.

## Verification

- Existing PowerShell syntax, local integration and packaging suite passed.
- Mocked active-adapter and rename/reboot tests passed; no real PC was renamed
  or rebooted by the development tests.
- Frontend rendering, escaping and authorization-source tests passed.
- Live RLS check: anonymous SELECT denied, authenticated INSERT/UPDATE denied.
- Live isolated device sync accepted custom authentication, delivered the
  transition update and name assignment, and provided a downloadable 25,757-byte
  ZIP with the expected SHA-256. All isolated fixture rows were removed.
- GitHub Pages deployment succeeded and serves the managed-name panel.
- The previously pending TL-LAB04-09 update was redirected to 2.3.4; delivery
  was leased by the real agent. Installation confirmation must come from its
  subsequent synchronization, not from task creation or leasing alone.

The pre-existing database advisor notices concern privileged helper functions
with internal role checks and disabled leaked-password protection. This release
does not widen their privileges or change the password policy.
