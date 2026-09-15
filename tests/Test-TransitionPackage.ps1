param([Parameter(Mandatory=$true)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $PackagePath))
function Read-EntryText($name) {
    $entry = $zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $name }
    if (-not $entry) { throw "Missing ZIP entry: $name" }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
try {
    $manifest = (Read-EntryText 'manifest.json') | ConvertFrom-Json
    $legacyAllowed = @('Agent.ps1','Common.ps1','ForegroundProvider.ps1','Inventory.ps1','NetworkClient.ps1','UpdateWorker.ps1','SessionWatcher.ps1')
    foreach ($entry in $manifest.files) {
        if ($legacyAllowed -notcontains $entry.path) { throw "Legacy updater rejects: $($entry.path)" }
        $file = $zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq ('src/' + $entry.path) }
        $stream = $file.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
        if ($hash -ne $entry.sha256) { throw "Invalid manifest hash: $($entry.path)" }
    }
    foreach ($name in @('install.bat','install.ps1','uninstall.ps1','config/policy.json','src/WallpaperMonitor.ps1','VERSION')) { $null = Read-EntryText $name }
    $network = (Read-EntryText 'config/network.json') | ConvertFrom-Json
    if (-not $network.enabled -or $network.supabaseUrl -notmatch 'ntuxzpivjzdtsahaqahw') { throw 'Package not connected to the correct project.' }
    foreach ($property in $network.PSObject.Properties.Name) { if ($property -match 'secret|password|token') { throw 'Private credential in distributable config.' } }
    if ((Read-EntryText 'src/UpdateWorker.ps1') -notmatch "'WallpaperMonitor.ps1'") { throw 'New updater missing wallpaper whitelist fix.' }
    Write-Host 'Transition package passed: installer, project config, hashes, legacy whitelist.'
} finally { $zip.Dispose() }
