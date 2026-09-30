[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'WorkBuddy2API'),
    [string]$Version = 'latest',
    [string]$Repo = 'ccmaoxiong/workbuddy2api-panel',
    [string]$DownloadBase,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) {
    Write-Host "[wb2api] $Message" -ForegroundColor Cyan
}

function New-DownloadUrl([string]$BaseUrl, [string]$Name) {
    return "$($BaseUrl.TrimEnd('/'))/$Name"
}

function Get-RemoteFile([string]$Url, [string]$Destination) {
    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add('User-Agent', 'WorkBuddy2API-Windows-Installer')
        $client.DownloadFile($Url, $Destination)
    }
    finally {
        $client.Dispose()
    }
}

function Assert-Sha256([string]$FilePath, [string]$ExpectedHash) {
    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedHash.Trim().ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for $(Split-Path -Leaf $FilePath): expected=$expected actual=$actual"
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
    # Some newer PowerShell versions ignore the global TLS switch.
}

if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "Invalid repository: $Repo"
}

$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -notin @('AMD64', 'ARM64')) {
    throw "Unsupported Windows architecture: $arch (amd64 package requires x64 or ARM64 Windows)"
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw 'Install directory cannot be empty.'
}

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$asset = 'wb2api_windows_amd64.zip'

if ([string]::IsNullOrWhiteSpace($DownloadBase)) {
    if ($Version -eq 'latest') {
        $DownloadBase = "https://github.com/$Repo/releases/latest/download"
    }
    else {
        $DownloadBase = "https://github.com/$Repo/releases/download/$Version"
    }
}

$archiveUrl = New-DownloadUrl $DownloadBase $asset
$hashUrl = "$archiveUrl.sha256"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("wb2api-install-" + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $tempDir $asset
$hashPath = "$archivePath.sha256"
$exePath = Join-Path $InstallDir 'wb2api.exe'
$configPath = Join-Path $InstallDir 'config.json'

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    Write-Step "Downloading $asset"
    Get-RemoteFile $archiveUrl $archivePath

    Write-Step 'Verifying SHA-256'
    Get-RemoteFile $hashUrl $hashPath
    $hashText = (Get-Content -LiteralPath $hashPath -Raw).Trim()
    $expectedHash = ($hashText -split '\s+')[0]
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid SHA-256 file: $hashUrl"
    }
    Assert-Sha256 -FilePath $archivePath -ExpectedHash $expectedHash

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    if (Test-Path -LiteralPath $exePath) {
        Get-CimInstance Win32_Process -Filter "Name = 'wb2api.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                [StringComparer]::OrdinalIgnoreCase.Equals($_.ExecutablePath, $exePath)
            } |
            ForEach-Object {
                Write-Step "Stopping running instance (PID $($_.ProcessId))"
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        Start-Sleep -Milliseconds 500
    }

    Write-Step "Installing to $InstallDir"
    Expand-Archive -LiteralPath $archivePath -DestinationPath $InstallDir -Force
    New-Item -ItemType Directory -Path (Join-Path $InstallDir 'auths') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $InstallDir 'data') -Force | Out-Null

    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "wb2api.exe was not found after extraction: $exePath"
    }

    Write-Host ''
    Write-Host 'WorkBuddy2API Windows installation complete.' -ForegroundColor Green
    Write-Host "Executable : $exePath"
    Write-Host "Working dir: $InstallDir"
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Write-Host "Config     : $configPath (preserved)"
    }
    else {
        Write-Host "Config     : will be created on first launch"
    }

    if ($NoLaunch) {
        Write-Host ''
        Write-Host "Start later: & '$exePath' -config '$configPath'"
    }
    else {
        Write-Step 'Starting WorkBuddy2API'
        Start-Process -FilePath $exePath `
            -ArgumentList "-config `"$configPath`"" `
            -WorkingDirectory $InstallDir | Out-Null
        Write-Host 'Panel      : http://127.0.0.1:7863/panel/'
    }
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        $resolved = [IO.Path]::GetFullPath($tempDir)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
