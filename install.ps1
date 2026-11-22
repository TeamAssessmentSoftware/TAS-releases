param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'TeamAssessmentSoftware/TAS-releases'
$base = if ($env:TAS_BASE_URL) { $env:TAS_BASE_URL } else { "https://github.com/$repo/releases/latest/download" }
$uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'

function Remove-Install([string]$name) {
    $key = Join-Path $uninstallRoot $name
    if (-not (Test-Path $key)) { return $false }
    $entry = Get-ItemProperty $key
    $location = $entry.InstallLocation
    $uninstaller = if ($location) { Join-Path $location "Uninstall $name.exe" } else { $null }
    if ($uninstaller -and (Test-Path $uninstaller)) {
        Write-Host "Removing $name from $location"
        Start-Process -FilePath $uninstaller -ArgumentList "/S _?=$location" -Wait
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $location
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $key
    return $true
}

if ($Uninstall -or $env:TAS_UNINSTALL) {
    $removed = Remove-Install 'TAS'
    if (Remove-Install 'WinTAS') { $removed = $true }
    if ($removed) {
        Write-Host 'TAS removed. Your settings and data stay in %APPDATA%\Team Assessment Software.'
    } else {
        Write-Host 'TAS is not installed for this user. An all-users MSI install is removed from Settings, Apps.'
    }
    return
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'TAS needs 64-bit Windows.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("tas-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $sums = Join-Path $tmp 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sums
    $line = Get-Content $sums | Where-Object { $_ -match '[\s*]tas-[0-9.]+-win-x64-setup\.exe$' } | Select-Object -First 1
    if (-not $line) { throw 'This release has no Windows installer.' }
    $parts = $line -split '\s+', 2
    $want = $parts[0].ToLowerInvariant()
    $asset = $parts[1].TrimStart('*')

    $setup = Join-Path $tmp $asset
    Write-Host "Downloading $asset"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile $setup
    $got = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
    if ($want -ne $got) { throw "Checksum mismatch for $asset" }
    Unblock-File $setup

    Write-Host 'Installing TAS. Windows asks once for permission to add the firewall rule TAK networking needs.'
    $process = Start-Process -FilePath $setup -ArgumentList '/S' -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "The installer stopped with code $($process.ExitCode)." }

    $key = Join-Path $uninstallRoot 'TAS'
    if (-not (Test-Path $key)) { throw 'The installer finished but TAS is not registered as installed.' }
    $entry = Get-ItemProperty $key
    Write-Host "TAS $($entry.DisplayVersion) installed in $($entry.InstallLocation). Open it from the Start menu or the desktop shortcut."
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}
