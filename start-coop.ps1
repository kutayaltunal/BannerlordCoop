# start-coop.ps1
# Mount & Blade II: Bannerlord Co-op One-Click Launcher (Steam & Epic Games Compatible)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConnectAddress,

    [Parameter(Mandatory = $false)]
    [switch]$AutoConnect,

    [Parameter(Mandatory = $false)]
    [switch]$Rebuild,

    [Parameter(Mandatory = $false)]
    [switch]$CreateShortcuts,

    [Parameter(Mandatory = $false)]
    [switch]$NoMenu
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = $PSScriptRoot
$Mb2Junction = Join-Path $RepoRoot "mb2"
$CoopModuleDir = Join-Path $RepoRoot "mb2\Modules\Coop"
$SupportedModules = "_MODULES_*Native*SandBoxCore*CustomBattle*SandBox*StoryMode*Coop*_MODULES_"

function Write-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "      Mount & Blade II: Bannerlord Co-op Başlatıcı          " -ForegroundColor Yellow
    Write-Host "              (Steam & Epic Games Uyumlu)                   " -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# 1. Game Path Detection
function Find-BannerlordInstallation {
    # Check existing mb2 junction
    if (Test-Path $Mb2Junction) {
        $target = (Get-Item $Mb2Junction).Target
        if (-not $target) { $target = (Get-Item $Mb2Junction).LinkTarget }
        if (-not $target) { $target = $Mb2Junction }
        $exe = Join-Path $target "bin\Win64_Shipping_Client\Bannerlord.exe"
        if (Test-Path $exe) {
            return (Get-Item $target).FullName
        }
    }

    # 1.1 Check running process
    $proc = Get-Process -Name Bannerlord, TaleWorlds.MountAndBlade.Launcher -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try {
            $path = Split-Path -Path (Split-Path -Path (Split-Path -Path $proc.MainModule.FileName -Parent) -Parent) -Parent
            if (Test-Path (Join-Path $path "bin\Win64_Shipping_Client\Bannerlord.exe")) {
                return $path
            }
        } catch {}
    }

    # 1.2 Check Epic Games Manifests
    $epicManifestDir = "C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path $epicManifestDir) {
        $items = Get-ChildItem (Join-Path $epicManifestDir "*.item") -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                $json = Get-Content $item.FullName -Raw | ConvertFrom-Json
                if ($json.AppName -eq 'Chickadee' -or $json.DisplayName -like '*Bannerlord*') {
                    if (Test-Path (Join-Path $json.InstallLocation "bin\Win64_Shipping_Client\Bannerlord.exe")) {
                        return $json.InstallLocation
                    }
                }
            } catch {}
        }
    }

    # 1.3 Check Standard Epic Paths
    $defaultEpicPaths = @(
        "C:\Program Files\Epic Games\MountAndBlade2",
        "C:\Program Files (x86)\Epic Games\MountAndBlade2",
        "D:\Epic Games\MountAndBlade2",
        "E:\Epic Games\MountAndBlade2"
    )
    foreach ($p in $defaultEpicPaths) {
        if (Test-Path (Join-Path $p "bin\Win64_Shipping_Client\Bannerlord.exe")) {
            return $p
        }
    }

    # 1.4 Check Steam Registry and Library Folders
    $steamKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 261550',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 261550'
    )
    foreach ($sk in $steamKeys) {
        if (Test-Path $sk) {
            $prop = Get-ItemProperty $sk -ErrorAction SilentlyContinue
            if ($prop -and $prop.InstallLocation -and (Test-Path (Join-Path $prop.InstallLocation "bin\Win64_Shipping_Client\Bannerlord.exe"))) {
                return $prop.InstallLocation
            }
        }
    }

    if (Test-Path 'HKCU:\Software\Valve\Steam') {
        $steamProp = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        if ($steamProp -and $steamProp.SteamPath) {
            $steamRoot = ($steamProp.SteamPath -replace '/', '\')
            $defaultSteam = Join-Path $steamRoot "steamapps\common\Mount & Blade II Bannerlord"
            if (Test-Path (Join-Path $defaultSteam "bin\Win64_Shipping_Client\Bannerlord.exe")) {
                return $defaultSteam
            }
            $vdf = Join-Path $steamRoot "steamapps\libraryfolders.vdf"
            if (Test-Path $vdf) {
                $content = Get-Content $vdf -Raw
                $matches = [regex]::Matches($content, '"path"\s+"([^"]+)"')
                foreach ($m in $matches) {
                    $libPath = ($m.Groups[1].Value -replace '\\\\', '\')
                    $cand = Join-Path $libPath "steamapps\common\Mount & Blade II Bannerlord"
                    if (Test-Path (Join-Path $cand "bin\Win64_Shipping_Client\Bannerlord.exe")) {
                        return $cand
                    }
                }
            }
        }
    }

    return $null
}

# 2. Setup Junction
function Ensure-GameJunction {
    if (Test-Path $Mb2Junction) {
        $exe = Join-Path $Mb2Junction "bin\Win64_Shipping_Client\Bannerlord.exe"
        if (Test-Path $exe) { return }
        Remove-Item $Mb2Junction -Force -Recurse -ErrorAction SilentlyContinue
    }

    Write-Host "[1/5] Bannerlord kurulum dizini aranıyor..." -ForegroundColor Cyan
    $gamePath = Find-BannerlordInstallation

    while (-not $gamePath -or -not (Test-Path (Join-Path $gamePath "bin\Win64_Shipping_Client\Bannerlord.exe"))) {
        Write-Host "Bannerlord kurulum dizini otomatik tespit edilemedi." -ForegroundColor Yellow
        $gamePath = Read-Host "Lütfen 'Mount & Blade II Bannerlord' ana klasör yolunu girin"
        if ([string]::IsNullOrWhiteSpace($gamePath)) {
            throw "Oyun dizini belirtilmedi. İşlem iptal edildi."
        }
        $gamePath = $gamePath.Trim('"')
    }

    Write-Host "Bulunan Oyun Dizini: $gamePath" -ForegroundColor Green
    New-Item -ItemType Junction -Path $Mb2Junction -Target $gamePath | Out-Null
    Write-Host "Oyun bağlantısı ('mb2') başarıyla oluşturuldu." -ForegroundColor Green
}

# 3. Detect Platform (Steam vs Epic)
function Get-GamePlatform {
    $nativeDir = Join-Path $Mb2Junction "Modules\Native"
    if (Test-Path (Join-Path $nativeDir "epic.target")) { return "Epic" }
    if (Test-Path (Join-Path $nativeDir "steam.target")) { return "Steam" }
    if (Test-Path (Join-Path $nativeDir "gog.target")) { return "GOG" }
    return "Steam"
}

# 4. Build Mod
function Ensure-ModBuilt([switch]$Force) {
    $coopDll = Join-Path $CoopModuleDir "bin\Win64_Shipping_Client\Coop.dll"
    if (-not $Force -and (Test-Path $coopDll)) {
        return
    }

    Write-Host "[2/5] BannerlordCoop modu Release modunda derleniyor..." -ForegroundColor Cyan
    $proj = Join-Path $RepoRoot "source\Coop\Coop.csproj"
    
    $proc = Start-Process -FilePath "dotnet" `
        -ArgumentList "build `"$proj`" -c Release -p:NuGetAudit=false -p:IncludeSourceRevisionInInformationalVersion=false" `
        -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -Wait

    if ($proc.ExitCode -ne 0) {
        throw "Mod derleme işlemi başarısız oldu (Hata Kodu: $($proc.ExitCode))."
    }

    Get-ChildItem -Path $CoopModuleDir -Recurse -File -ErrorAction SilentlyContinue | Unblock-File
    Write-Host "Mod başarıyla derlendi ve oyuna kuruldu." -ForegroundColor Green
}

# 5. Patch engine_config.txt safe exit
function Ensure-SafeExitConfig {
    try {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $cfg = Join-Path $docs "Mount and Blade II Bannerlord\Configs\engine_config.txt"
        if (Test-Path $cfg) {
            (Get-Item $cfg).Attributes = 'Normal'
            $lines = Get-Content $cfg
            $found = $false
            for ($i = 0; $i -lt $lines.Length; $i++) {
                if ($lines[$i].TrimStart().StartsWith("safely_exited", [StringComparison]::OrdinalIgnoreCase)) {
                    $lines[$i] = "safely_exited  = 1"
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $lines = $lines + "safely_exited  = 1"
            }
            Set-Content -Path $cfg -Value $lines
            (Get-Item $cfg).Attributes = 'ReadOnly'
        }
    } catch {}
}

# 6. Setup Epic Launcher Wrapper
function Ensure-EpicWrapper {
    $binDir = Join-Path $Mb2Junction "bin\Win64_Shipping_Client"
    $launcherExe = Join-Path $binDir "TaleWorlds.MountAndBlade.Launcher.exe"
    $origExe = Join-Path $binDir "TaleWorlds.MountAndBlade.Launcher.orig.exe"

    if (-not (Test-Path $origExe)) {
        Copy-Item -Path $launcherExe -Destination $origExe -Force
        Write-Host "Orijinal başlatıcı yedeklendi ($origExe)." -ForegroundColor DarkGray
    }

    $wrapperProj = Join-Path $RepoRoot "tools\LauncherWrapper\LauncherWrapper.csproj"
    if (Test-Path $wrapperProj) {
        Start-Process -FilePath "dotnet" `
            -ArgumentList "build `"$wrapperProj`" -c Release -o `"$binDir`"" `
            -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -Wait | Out-Null
    }
}

# 7. Create Desktop Shortcuts
function Create-DesktopShortcuts {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $wsh = New-Object -ComObject WScript.Shell
    $binDir = Join-Path $Mb2Junction "bin\Win64_Shipping_Client"
    $iconPath = Join-Path $binDir "Bannerlord.exe,0"
    $cmdPath = Join-Path $RepoRoot "start-coop.cmd"

    # Otomatik Baglan kisayolu
    $lnkAuto = $wsh.CreateShortcut((Join-Path $desktop "Bannerlord Co-op (Otomatik Baglan).lnk"))
    $lnkAuto.TargetPath = $cmdPath
    $lnkAuto.Arguments = "-AutoConnect"
    $lnkAuto.WorkingDirectory = $RepoRoot
    $lnkAuto.IconLocation = $iconPath
    $lnkAuto.Description = "Bannerlord Co-op modunu baslatir ve son sunucuya otomatik baglanir."
    $lnkAuto.Save()

    # Ana Menu kisayolu
    $lnkMenu = $wsh.CreateShortcut((Join-Path $desktop "Bannerlord Co-op (Ana Menu).lnk"))
    $lnkMenu.TargetPath = $cmdPath
    $lnkMenu.Arguments = "-NoMenu"
    $lnkMenu.WorkingDirectory = $RepoRoot
    $lnkMenu.IconLocation = $iconPath
    $lnkMenu.Description = "Bannerlord Co-op modunu desteklenen modullerle dogrudan Ana Menuye acar."
    $lnkMenu.Save()

    Write-Host "Masaüstüne kısayollar başarıyla eklendi!" -ForegroundColor Green
}

# 8. Launch Game
function Launch-Game([string]$Address) {
    Ensure-SafeExitConfig
    $platform = Get-GamePlatform
    Write-Host "[3/5] Platform Tespit Edildi: $platform" -ForegroundColor Cyan

    $binDir = Join-Path $Mb2Junction "bin\Win64_Shipping_Client"

    # Format address if given
    $autoConnectArg = ""
    if (-not [string]::IsNullOrWhiteSpace($Address)) {
        $addr = $Address.Trim()
        if ($addr -match ':' -and -not $addr.StartsWith('[')) {
            $endpoint = "[$addr]:4200"
        } elseif (-not ($addr -match ':\d+$')) {
            $endpoint = "${addr}:4200"
        } else {
            $endpoint = $addr
        }
        $autoConnectArg = "/autoconnect $endpoint"
    }

    if ($platform -eq "Epic") {
        Ensure-EpicWrapper
        $autoConnectFile = Join-Path $binDir "autoconnect.args"
        $argsLine = if ($autoConnectArg) { "/singleplayer /client $autoConnectArg $SupportedModules" } else { "/singleplayer /client $SupportedModules" }
        [System.IO.File]::WriteAllText($autoConnectFile, $argsLine, (New-Object System.Text.UTF8Encoding($false)))

        Write-Host "[4/5] Epic Games Launcher üzerinden başlatılıyor..." -ForegroundColor Cyan
        Start-Process "com.epicgames.launcher://apps/Chickadee?action=launch"
    } else {
        # Steam / Native direct launch
        $bannerlordExe = Join-Path $binDir "Bannerlord.exe"
        $argsLine = if ($autoConnectArg) { "/singleplayer /client $autoConnectArg $SupportedModules" } else { "/singleplayer /client $SupportedModules" }

        Write-Host "[4/5] Steam / Bannerlord.exe başlatılıyor..." -ForegroundColor Cyan
        Start-Process -FilePath $bannerlordExe -WorkingDirectory $binDir -ArgumentList $argsLine
    }

    Write-Host "[5/5] Oyun başlatıldı! İyi oyunlar." -ForegroundColor Green
}

# ==================== MAIN EXECUTION ====================
Ensure-GameJunction

if ($Rebuild) {
    Ensure-ModBuilt -Force
} else {
    Ensure-ModBuilt
}

if ($CreateShortcuts) {
    Create-DesktopShortcuts
    return
}

# Auto-connect address resolution if -AutoConnect flag is set
if ($AutoConnect -and [string]::IsNullOrWhiteSpace($ConnectAddress)) {
    $optionsFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Mount and Blade II Bannerlord\Configs\BannerlordCoop\coop_options.json'
    if (Test-Path $optionsFile) {
        try {
            $json = Get-Content $optionsFile -Raw | ConvertFrom-Json
            $ConnectAddress = $json.Connection.DirectConnection.lastServerAddress
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($ConnectAddress)) {
        $ConnectAddress = "2a02:ff0:332a:f896:7dbc:9f87:bd9f:ce7c"
    }
}

if ($ConnectAddress -or $NoMenu -or $AutoConnect) {
    Launch-Game -Address $ConnectAddress
    return
}

# Interactive Menu
Write-Banner
Write-Host "Lütfen bir seçenek seçin:" -ForegroundColor White
Write-Host "  [1] Oyunu Başlat (Ana Menü - Release)" -ForegroundColor Green
Write-Host "  [2] Sunucuya Otomatik Bağlan (IPv4 / IPv6)" -ForegroundColor Cyan
Write-Host "  [3] Modu Sıfırdan Derle ve Kur (Rebuild Release)" -ForegroundColor Yellow
Write-Host "  [4] Masaüstüne Kısayol Oluştur" -ForegroundColor Magenta
Write-Host "  [5] Çıkış" -ForegroundColor DarkGray
Write-Host ""

$choice = Read-Host "Seçiminiz [Varsayılan: 1]"
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

switch ($choice.Trim()) {
    "1" {
        Launch-Game
    }
    "2" {
        $defaultAddr = "2a02:ff0:332a:f896:7dbc:9f87:bd9f:ce7c"
        $optionsFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Mount and Blade II Bannerlord\Configs\BannerlordCoop\coop_options.json'
        if (Test-Path $optionsFile) {
            try {
                $json = Get-Content $optionsFile -Raw | ConvertFrom-Json
                $saved = $json.Connection.DirectConnection.lastServerAddress
                if (-not [string]::IsNullOrWhiteSpace($saved)) { $defaultAddr = $saved }
            } catch {}
        }
        $ip = Read-Host "Bağlanılacak IP/Adres [Varsayılan: $defaultAddr]"
        if ([string]::IsNullOrWhiteSpace($ip)) { $ip = $defaultAddr }
        Launch-Game -Address $ip
    }
    "3" {
        Ensure-ModBuilt -Force
        Write-Host "Derleme tamamlandı. Oyunu başlatmak için bu betiği tekrar çalıştırabilirsiniz." -ForegroundColor Green
    }
    "4" {
        Create-DesktopShortcuts
    }
    "5" {
        Write-Host "Çıkılıyor..." -ForegroundColor DarkGray
    }
    default {
        Launch-Game
    }
}
