<#
.SYNOPSIS
    Builds PixCap for Windows on ARM64, x64, or both.

.DESCRIPTION
    Builds the shared Rust core for each requested architecture, then publishes
    the WinUI app against it. The Rust DLL must match the app architecture -
    mixing them throws BadImageFormatException at the first P/Invoke.

.PARAMETER Architecture
    arm64, x64, or both. Defaults to both.

.PARAMETER Configuration
    Release (default) or Debug.

.PARAMETER Installer
    Also build a setup.exe for each architecture. Requires Inno Setup 6:
    winget install JRSoftware.InnoSetup

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Architecture x64
    .\build.ps1 -Architecture both -Configuration Debug
#>

[CmdletBinding()]
param(
    [ValidateSet('arm64', 'x64', 'both')]
    [string]$Architecture = 'both',

    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [switch]$Installer,

    # Explicit path to ISCC.exe, when it is somewhere unusual.
    [string]$InnoSetupPath
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = '2.0.0' 
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..\..')
$projectDir = Join-Path $scriptRoot 'PixCapWin'

# RID -> Rust target triple
$targets = @{
    'arm64' = @{ Rid = 'win-arm64'; RustTarget = 'aarch64-pc-windows-msvc' }
    'x64'   = @{ Rid = 'win-x64';   RustTarget = 'x86_64-pc-windows-msvc' }
}

$selected = if ($Architecture -eq 'both') { @('arm64', 'x64') } else { @($Architecture) }


function Find-InnoSetup {
    <#
        Locates ISCC.exe. winget installs Inno Setup without adding it to PATH,
        so several known locations are probed, then the uninstall registry key.

        Note the ${env:ProgramFiles(x86)} syntax: inside a double-quoted string
        PowerShell ends the variable name at the parenthesis, so
        "$env:ProgramFiles(x86)" silently yields "C:\Program Files(x86)" - a
        path that does not exist. The braces are required.
    #>
    if ($InnoSetupPath) {
        if (Test-Path $InnoSetupPath) { return $InnoSetupPath }
        throw "InnoSetupPath does not exist: $InnoSetupPath"
    }

    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $roots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles,
        (Join-Path $env:LOCALAPPDATA 'Programs')
    ) | Where-Object { $_ }

    foreach ($root in $roots) {
        foreach ($version in @('Inno Setup 6', 'Inno Setup 5')) {
            $candidate = Join-Path $root (Join-Path $version 'ISCC.exe')
            if (Test-Path $candidate) { return $candidate }
        }
    }

    # winget records an uninstall entry that carries the install location.
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
    )

    foreach ($key in $keys) {
        $location = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallLocation
        if ($location) {
            $candidate = Join-Path $location 'ISCC.exe'
            if (Test-Path $candidate) { return $candidate }
        }
    }

    return $null
}

Write-Host "Building PixCap for: $($selected -join ', ')" -ForegroundColor Cyan
Write-Host ""

foreach ($arch in $selected) {
    $rid = $targets[$arch].Rid
    $rustTarget = $targets[$arch].RustTarget

    Write-Host "=== $arch ($rid) ===" -ForegroundColor Cyan

    # 1. Rust core for this architecture.
    Write-Host "  Installing Rust target $rustTarget..."
    & rustup target add $rustTarget | Out-Null

    Write-Host "  Building the shared core..."
    Push-Location $repoRoot
    try {
        & cargo build --release --target $rustTarget
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed for $rustTarget" }
    }
    finally {
        Pop-Location
    }

    $dll = Join-Path $repoRoot "target\$rustTarget\release\pixcap_ffi.dll"
    if (-not (Test-Path $dll)) { throw "pixcap_ffi.dll missing at $dll" }
    Write-Host "  Core: $dll" -ForegroundColor DarkGray

    # 2. The app.
    #
    # The previous output is removed first. dotnet publish copies the build
    # folder forward, so anything a previous configuration left there travels
    # with it - a self-contained build's private coreclr, hostfxr and
    # hostpolicy rode along into a framework-dependent publish and stopped the
    # installed app from starting at all.
    $ridOutput = Join-Path $projectDir "bin\$Configuration\net8.0-windows10.0.22621.0\$rid"
    if (Test-Path $ridOutput) {
        Remove-Item $ridOutput -Recurse -Force
    }

    Write-Host "  Publishing the app..."
    Push-Location $projectDir
    try {
        # No --self-contained here: the project decides, and it chooses
        # framework-dependent. Passing it on the command line overrides the
        # project and silently produced a 52 MB installer carrying a private
        # copy of .NET that would never see a security patch.
        & dotnet publish -c $Configuration -r $rid
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $rid" }
    }
    finally {
        Pop-Location
    }

    $output = Join-Path $projectDir "bin\$Configuration\net8.0-windows10.0.22621.0\$rid\publish"
    Write-Host "  Output: $output" -ForegroundColor Green

    # Confirm the DLL travelled with the app; a missing one only shows up as a
    # runtime DllNotFoundException otherwise.
    $shipped = Join-Path $output 'pixcap_ffi.dll'
    if (Test-Path $shipped) {
        Write-Host "  pixcap_ffi.dll present" -ForegroundColor Green
    }
    else {
        Write-Warning "  pixcap_ffi.dll is NOT in the publish folder - the app will fail at startup."
    }

    # 3. Optional installer.
    if ($Installer) {
        $isccPath = Find-InnoSetup

        if (-not $isccPath) {
            Write-Warning "  Inno Setup not found - skipping the installer."
            Write-Warning "  Install it with: winget install JRSoftware.InnoSetup"
            Write-Warning "  If it is installed, pass the path: -InnoSetupPath 'C:\path\to\ISCC.exe'"
        }
        else {
            Write-Host "  Building the installer with $isccPath"
            $issFile = Join-Path $scriptRoot 'installer\PixCap.iss'

            & $isccPath `
                "/DAppVersion=$Version" `
                "/DArch=$arch" `
                "/DSourceDir=$output" `
                $issFile

            if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed for $arch" }

            $setup = Join-Path $repoRoot "dist\PixCap-$Version-$arch-setup.exe"
            if (Test-Path $setup) {
                $size = [math]::Round((Get-Item $setup).Length / 1MB, 1)
                Write-Host "  Installer: $setup ($size MB)" -ForegroundColor Green
            }
            else {
                Write-Warning "  Inno Setup reported success but $setup is missing."
            }
        }
    }

    Write-Host ""
}

Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Run the build matching this machine:" -ForegroundColor Cyan
Write-Host "  `$env:PROCESSOR_ARCHITECTURE  tells you which (ARM64 or AMD64)"
