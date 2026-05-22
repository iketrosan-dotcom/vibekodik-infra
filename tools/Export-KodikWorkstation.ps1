# Export-KodikWorkstation.ps1
#
# Collects Kodik working environment (SSH keys, yc config, Claude memory, IaC repo)
# into one encrypted 7z archive for transfer to another machine.
#
# RUN THIS YOURSELF IN NORMAL POWERSHELL (not via Claude Code).
# Claude Code blocks automated credential gathering by design.
#
# Usage:
#   .\Export-KodikWorkstation.ps1                  # interactive, outputs to script dir
#   .\Export-KodikWorkstation.ps1 -OutDir D:\      # outputs archive to USB drive D:
#
# WireGuard configs are NOT included automatically - Windows stores them
# encrypted via DPAPI (tied to your user account, not portable).
# Export them via WireGuard UI: menu Tunnels -> Export tunnels to ZIP (Ctrl+T).

[CmdletBinding()]
param(
    [string]$OutDir = $PSScriptRoot,
    [string]$ArchiveName = "kodik-handoff-$(Get-Date -Format 'yyyyMMdd-HHmm').7z"
)

$ErrorActionPreference = 'Stop'

# --- 1. Locate 7-Zip ---
$sevenZipExe = $null
$cmd = Get-Command 7z -ErrorAction SilentlyContinue
if ($cmd) { $sevenZipExe = $cmd.Source }
if (-not $sevenZipExe) {
    foreach ($c in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $c) { $sevenZipExe = $c; break }
    }
}
if (-not $sevenZipExe) {
    Write-Host ""
    Write-Host "[!] 7-Zip not installed." -ForegroundColor Red
    Write-Host "    Install: winget install 7zip.7zip"
    Write-Host "    Or download from https://www.7-zip.org/"
    exit 1
}
Write-Host "[+] 7-Zip: $sevenZipExe" -ForegroundColor Green

# --- 2. Validate output directory ---
if (-not (Test-Path $OutDir)) {
    Write-Host "[!] OutDir not found: $OutDir" -ForegroundColor Red
    exit 1
}
$archivePath = Join-Path $OutDir $ArchiveName
if (Test-Path $archivePath) {
    Write-Host "[!] File already exists: $archivePath" -ForegroundColor Red
    exit 1
}
Write-Host "[+] Archive target: $archivePath" -ForegroundColor Green

# --- 3. Prompt for password ---
Write-Host ""
Write-Host "Enter a strong password for the archive (min 12 chars):" -ForegroundColor Yellow
Write-Host "(write it down separately - KeePass or paper)"
$pwd1 = Read-Host -AsSecureString "Password"
$pwd2 = Read-Host -AsSecureString "Confirm"
$p1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd1))
$p2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd2))
if ($p1 -ne $p2) { Write-Host "[!] Passwords do not match" -ForegroundColor Red; exit 1 }
if ($p1.Length -lt 12) { Write-Host "[!] Password too short (min 12 chars)" -ForegroundColor Red; exit 1 }
$password = $p1

# --- 4. Staging directory ---
$staging = Join-Path $env:TEMP "kodik-handoff-$(Get-Random)"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Write-Host ""
Write-Host "[+] Staging: $staging" -ForegroundColor Green
Write-Host ""
Write-Host "Collecting files..." -ForegroundColor Cyan

function Copy-Section {
    param([string]$Label, [string]$Src, [string]$DstSub, [string[]]$Exclude = @())
    $dst = Join-Path $staging $DstSub
    if (-not (Test-Path $Src)) {
        Write-Host "    [skip] $Label - $Src not found" -ForegroundColor DarkYellow
        return
    }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    if ((Get-Item $Src).PSIsContainer) {
        $items = Get-ChildItem $Src -Force | Where-Object {
            $name = $_.Name
            -not ($Exclude | Where-Object { $name -like $_ })
        }
        foreach ($i in $items) { Copy-Item $i.FullName -Destination $dst -Recurse -Force }
    } else {
        Copy-Item $Src -Destination $dst -Force
    }
    Write-Host "    [ok]   $Label" -ForegroundColor Green
}

# 4a. SSH (without known_hosts.old)
Copy-Section -Label "SSH keys + config" `
    -Src "$env:USERPROFILE\.ssh" `
    -DstSub "ssh" `
    -Exclude @('known_hosts.old', 'environment')

# 4b. Yandex Cloud (only config.yaml, no logs)
$ycSrc = "$env:USERPROFILE\.config\yandex-cloud\config.yaml"
if (Test-Path $ycSrc) {
    $ycDst = Join-Path $staging "yandex-cloud"
    New-Item -ItemType Directory -Path $ycDst -Force | Out-Null
    Copy-Item $ycSrc -Destination $ycDst -Force
    Write-Host "    [ok]   yc CLI config" -ForegroundColor Green
} else {
    Write-Host "    [skip] yc config not found" -ForegroundColor DarkYellow
}

# 4c. Claude - memory + settings + credentials
$claudeDst = Join-Path $staging "claude"
New-Item -ItemType Directory -Path $claudeDst -Force | Out-Null
foreach ($f in @('settings.json', 'settings.local.json', '.credentials.json')) {
    $src = "$env:USERPROFILE\.claude\$f"
    if (Test-Path $src) { Copy-Item $src -Destination $claudeDst -Force }
}
$memSrc = "$env:USERPROFILE\.claude\projects\c--src-kodik"
if (Test-Path $memSrc) {
    $projDst = Join-Path $claudeDst "projects\c--src-kodik"
    New-Item -ItemType Directory -Path $projDst -Force | Out-Null
    foreach ($sub in @('memory', 'todos')) {
        $sp = Join-Path $memSrc $sub
        if (Test-Path $sp) { Copy-Item $sp -Destination $projDst -Recurse -Force }
    }
}
Write-Host "    [ok]   Claude memory + settings" -ForegroundColor Green

# 4d. IaC repo c:\src\kodik
Copy-Section -Label "c:\src\kodik (IaC)" -Src "c:\src\kodik" -DstSub "src\kodik" `
    -Exclude @('node_modules', '.venv')

# 4e. Placeholder for WireGuard
$wgDst = Join-Path $staging "wireguard"
New-Item -ItemType Directory -Path $wgDst -Force | Out-Null
$wgReadme = "WireGuard configs on Windows are DPAPI-encrypted per user account.`r`n"
$wgReadme += "They CANNOT be copied as files - must be exported via UI.`r`n`r`n"
$wgReadme += "STEPS:`r`n"
$wgReadme += "  1. Open WireGuard app on the source machine`r`n"
$wgReadme += "  2. Menu: Tunnels -> Export tunnels to ZIP (Ctrl+T)`r`n"
$wgReadme += "  3. Save the ZIP to your USB drive (next to the .7z archive)`r`n"
$wgReadme += "  4. On the new machine: WireGuard UI -> Import tunnel(s) from file`r`n"
$wgReadme | Out-File -FilePath (Join-Path $wgDst "README.txt") -Encoding ascii

# 4f. README for the archive
$archiveReadme = "kodik-handoff - what's inside and how to restore`r`n"
$archiveReadme += "================================================`r`n`r`n"
$archiveReadme += "This is the Kodik working environment exported from the desktop.`r`n"
$archiveReadme += "Encrypted with 7-Zip AES-256, filenames also encrypted.`r`n`r`n"
$archiveReadme += "Contents:`r`n"
$archiveReadme += "  ssh\                        -> %USERPROFILE%\.ssh\`r`n"
$archiveReadme += "  yandex-cloud\config.yaml    -> %USERPROFILE%\.config\yandex-cloud\`r`n"
$archiveReadme += "  claude\settings.json        -> %USERPROFILE%\.claude\`r`n"
$archiveReadme += "  claude\.credentials.json    -> %USERPROFILE%\.claude\`r`n"
$archiveReadme += "  claude\projects\            -> %USERPROFILE%\.claude\projects\`r`n"
$archiveReadme += "  src\kodik\                  -> c:\src\kodik\`r`n"
$archiveReadme += "  wireguard\                  -> import via WireGuard UI`r`n`r`n"
$archiveReadme += "On the laptop:`r`n"
$archiveReadme += "  1. Install 7-Zip (winget install 7zip.7zip OR https://www.7-zip.org/)`r`n"
$archiveReadme += "  2. Extract: 7z x kodik-handoff-*.7z -o`"%TEMP%\kodik-handoff`"`r`n"
$archiveReadme += "  3. Run: %TEMP%\kodik-handoff\Import-KodikWorkstation.ps1`r`n`r`n"
$archiveReadme += "After SSH keys are restored, fix ACL (otherwise OpenSSH rejects them):`r`n"
$archiveReadme += "  icacls `"`$env:USERPROFILE\.ssh\id_ed25519`" /inheritance:r /grant:r `"`$(`$env:USERNAME):(R)`"`r`n"
$archiveReadme += "  (Import script does this automatically.)`r`n`r`n"
$archiveReadme += "Software to install on the laptop:`r`n"
$archiveReadme += "  winget install Git.Git GitHub.cli WireGuard.WireGuard Microsoft.VisualStudioCode 7zip.7zip`r`n"
$archiveReadme += "  yc CLI: iex (New-Object System.Net.WebClient).DownloadString('https://storage.yandexcloud.net/yandexcloud-yc/install.ps1')`r`n"
$archiveReadme | Out-File -FilePath (Join-Path $staging "README.txt") -Encoding ascii

# 4g. Import script - embedded
$importScript = @'
# Import-KodikWorkstation.ps1
# Restores the Kodik working environment from the extracted archive.
# Run from the extracted kodik-handoff directory on the new machine.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Restore-Tree {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path $Src)) { Write-Host "  [skip] $Src not found"; return }
    if (-not (Test-Path $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    Get-ChildItem $Src -Force | ForEach-Object {
        Copy-Item $_.FullName -Destination $Dst -Recurse -Force
        Write-Host "  [ok] $($_.Name) -> $Dst"
    }
}

Write-Host "Restoring SSH..."
Restore-Tree "$here\ssh" "$env:USERPROFILE\.ssh"

Write-Host "Restoring yc config..."
Restore-Tree "$here\yandex-cloud" "$env:USERPROFILE\.config\yandex-cloud"

Write-Host "Restoring Claude config + memory..."
Restore-Tree "$here\claude" "$env:USERPROFILE\.claude"

Write-Host "Restoring c:\src\kodik..."
if (-not (Test-Path "c:\src")) { New-Item -ItemType Directory -Path "c:\src" -Force | Out-Null }
Restore-Tree "$here\src" "c:\src"

Write-Host ""
Write-Host "Fixing SSH key permissions..."
foreach ($k in @('id_ed25519','id_ed25519_github','id_rsa_kodik')) {
    $p = "$env:USERPROFILE\.ssh\$k"
    if (Test-Path $p) {
        icacls $p /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
        Write-Host "  [ok] $k"
    }
}

Write-Host ""
Write-Host "Done. Next:"
Write-Host "  1. Import WireGuard tunnels via UI (Import tunnel(s) from file -> wireguard\)"
Write-Host "  2. Install software listed in README.txt"
Write-Host "  3. Open c:\src\kodik in VSCode + Claude Code"
'@
$importScript | Out-File -FilePath (Join-Path $staging "Import-KodikWorkstation.ps1") -Encoding ascii

# --- 5. Build archive ---
Write-Host ""
Write-Host "Packing to 7z (AES-256, filenames also encrypted)..." -ForegroundColor Cyan
$arguments = @(
    'a',
    '-t7z',
    "-p$password",
    '-mhe=on',
    '-mx=5',
    '-r',
    $archivePath,
    "$staging\*"
)
& $sevenZipExe @arguments
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] 7-Zip exited with code $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

# --- 6. Verify ---
Write-Host ""
Write-Host "Verifying archive..." -ForegroundColor Cyan
& $sevenZipExe t "-p$password" $archivePath | Select-Object -Last 5
$size = (Get-Item $archivePath).Length / 1MB

# --- 7. Cleanup ---
Remove-Item $staging -Recurse -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "Done." -ForegroundColor Green
Write-Host "  Archive: $archivePath"
Write-Host "  Size:    $([math]::Round($size,2)) MB"
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Open WireGuard -> Ctrl+T -> export tunnels to ZIP on USB"
Write-Host "     (place it next to the .7z archive)"
Write-Host "  2. Eject the USB drive"
Write-Host "  3. Write the archive password down separately (not on the USB)"
Write-Host "  4. On the laptop: 7z x kodik-handoff-*.7z -o`"%TEMP%\kodik-handoff`""
Write-Host "     then run Import-KodikWorkstation.ps1 from the extracted folder"
Write-Host "============================================================" -ForegroundColor Green
