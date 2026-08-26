Set-StrictMode -Version 2.0

function Get-LmWallpaperFingerprint {
    param(
        [AllowEmptyString()][string]$WallpaperPath,
        [long]$TranscodedLength = 0,
        [long]$TranscodedLastWriteTicks = 0
    )
    $normalizedPath = ([string]$WallpaperPath).Trim().ToLowerInvariant()
    return Get-LmSha256Text ('{0}|{1}|{2}' -f $normalizedPath, $TranscodedLength, $TranscodedLastWriteTicks)
}

function Get-LmAccountSid {
    param([Parameter(Mandatory = $true)][string]$Account)
    try {
        return (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch { return $null }
}

function Get-LmWallpaperSnapshots {
    $snapshots = @()
    $seenSessions = @{}
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -Property ProcessId,SessionId -ErrorAction SilentlyContinue)) {
        $sessionId = [int]$process.SessionId
        if ($sessionId -le 0 -or $seenSessions.ContainsKey($sessionId)) { continue }
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
            if ($owner.ReturnValue -ne 0 -or -not $owner.User) { continue }
            $account = if ($owner.Domain) { '{0}\{1}' -f $owner.Domain, $owner.User } else { [string]$owner.User }
            $sid = Get-LmAccountSid -Account $account
            if (-not $sid) { continue }

            $desktopKey = "Registry::HKEY_USERS\$sid\Control Panel\Desktop"
            if (-not (Test-Path -LiteralPath $desktopKey)) { continue }
            $wallpaperPath = [string](Get-ItemProperty -LiteralPath $desktopKey -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

            $profileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
            $profilePath = [string](Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            $transcodedLength = 0L
            $transcodedTicks = 0L
            if ($profilePath) {
                $profilePath = [Environment]::ExpandEnvironmentVariables($profilePath)
                $transcoded = Join-Path $profilePath 'AppData\Roaming\Microsoft\Windows\Themes\TranscodedWallpaper'
                if (Test-Path -LiteralPath $transcoded) {
                    $file = Get-Item -LiteralPath $transcoded -ErrorAction SilentlyContinue
                    if ($null -ne $file) {
                        $transcodedLength = [long]$file.Length
                        $transcodedTicks = [long]$file.LastWriteTimeUtc.Ticks
                    }
                }
            }

            $seenSessions[$sessionId] = $true
            $snapshots += ,[ordered]@{
                sessionId = $sessionId
                user = $account
                sid = $sid
                fingerprint = Get-LmWallpaperFingerprint -WallpaperPath $wallpaperPath -TranscodedLength $transcodedLength -TranscodedLastWriteTicks $transcodedTicks
            }
        }
        catch { }
    }
    return $snapshots
}
