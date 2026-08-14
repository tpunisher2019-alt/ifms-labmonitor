function Get-LmInstalledSoftware {
    [CmdletBinding()]
    param()

    $results = @{}
    function Get-OptionalProperty {
        param($Object, [string]$Name)
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }
    $locations = @(
        @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'machine'; Architecture = 'x64' },
        @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'machine'; Architecture = 'x86' },
        @{ Path = 'Registry::HKEY_USERS\S-1-5-21-*\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'user'; Architecture = 'user' }
    )

    foreach ($location in $locations) {
        foreach ($item in @(Get-ItemProperty -Path $location.Path -ErrorAction SilentlyContinue)) {
            $name = [string](Get-OptionalProperty $item 'DisplayName')
            if ([string]::IsNullOrWhiteSpace($name) -or [int](Get-OptionalProperty $item 'SystemComponent') -eq 1) { continue }
            $version = [string](Get-OptionalProperty $item 'DisplayVersion')
            $publisher = [string](Get-OptionalProperty $item 'Publisher')
            $childName = [string](Get-OptionalProperty $item 'PSChildName')
            $productCode = if ($childName -match '^\{[0-9A-Fa-f-]+\}$') { $childName } else { $null }
            $identity = '{0}|{1}|{2}|{3}|{4}' -f $location.Scope, $name.Trim().ToLowerInvariant(),
                $version.Trim().ToLowerInvariant(), $publisher.Trim().ToLowerInvariant(), ([string]$productCode).ToLowerInvariant()
            $key = Get-LmSha256Text -Text $identity
            $results[$key] = [ordered]@{
                inventoryKey = $key
                name = $name.Trim()
                version = $version
                publisher = $publisher
                installDate = [string](Get-OptionalProperty $item 'InstallDate')
                scope = $location.Scope
                architecture = $location.Architecture
                productCode = $productCode
                estimatedSizeKb = if ($null -ne (Get-OptionalProperty $item 'EstimatedSize')) { [long](Get-OptionalProperty $item 'EstimatedSize') } else { $null }
            }
        }
    }
    return @($results.Values | Sort-Object name, version)
}

function Save-LmInventorySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $software = @(Get-LmInstalledSoftware)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osCaption = if ($null -ne $os -and $null -ne $os.PSObject.Properties['Caption']) { [string]$os.Caption } else { $null }
    $canonical = $software | ConvertTo-Json -Depth 8 -Compress
    $snapshot = [ordered]@{
        schemaVersion = 1
        collectedAtUtc = Get-LmUtcNow
        hostname = $env:COMPUTERNAME
        operatingSystem = [ordered]@{
            caption = $osCaption
            version = [Environment]::OSVersion.Version.ToString()
            architecture = $env:PROCESSOR_ARCHITECTURE
        }
        software = $software
        inventoryHash = Get-LmSha256Text -Text $canonical
    }
    Write-LmAtomicJson -Path $Path -Value $snapshot
    return $snapshot
}
