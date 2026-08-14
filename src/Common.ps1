Set-StrictMode -Version 2.0

function Get-LmUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}

function New-LmDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-LmJsonLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    New-LmDirectory -Path (Split-Path -Parent $Path)
    $line = $Value | ConvertTo-Json -Depth 12 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))
        $hash = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    } finally { $sha.Dispose() }
    $mutexName = 'Local\IFMS-LabMonitor-' + $hash
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    try {
        if (-not $mutex.WaitOne(10000)) { throw "Timeout ao obter trava para $Path" }
        [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

function Write-LmAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    New-LmDirectory -Path (Split-Path -Parent $Path)
    $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-LmJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Write-LmInboxEvent {
    param(
        [Parameter(Mandatory = $true)][string]$InboxPath,
        [Parameter(Mandatory = $true)]$Event
    )
    New-LmDirectory -Path $InboxPath
    $base = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff'), [Guid]::NewGuid().ToString('N')
    $temp = Join-Path $InboxPath ($base + '.tmp')
    $final = Join-Path $InboxPath ($base + '.json')
    [IO.File]::WriteAllText($temp, ($Event | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $final
}

function ConvertTo-LmSafeId {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9_.-]', '_')
}

function New-LmSessionKey {
    param([string]$Hostname, [int]$SessionId, [string]$User, [string]$LoginMarker)
    return '{0}|{1}|{2}|{3}' -f (ConvertTo-LmSafeId $Hostname), $SessionId,
        (ConvertTo-LmSafeId $User), (ConvertTo-LmSafeId $LoginMarker)
}

function Get-LmSha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-LmSha256File {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
