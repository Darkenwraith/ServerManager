# LF-DAT Phase 3 FINAL FINAL FIX
# Replaces Items with ItemsSource for Avalonia compatibility
# Safe to re-run

Write-Host "== LF-DAT Phase 3 FINAL FINAL FIX =="
$ErrorActionPreference = "Stop"

$App = "C:\ServerManager\ServerManager"
$File = Join-Path $App "Views\MainWindow.axaml.cs"

if (-not (Test-Path $File)) {
    Write-Host "ERROR: MainWindow.axaml.cs not found"
    exit 1
}

# Backup
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_fix4_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# Patch line
(Get-Content $File) |
    ForEach-Object {
        $_ -replace "ServerList\.Items\s*=\s*", "ServerList.ItemsSource = "
    } | Set-Content $File -Encoding UTF8

Write-Host "✔ Items → ItemsSource patched"

# Build + Run
Set-Location $App
dotnet build
dotnet run

