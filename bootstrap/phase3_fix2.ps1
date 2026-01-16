# LF-DAT Phase 3 FINAL FIX
# Fixes MainWindow namespace reference in App.axaml.cs
# Safe to re-run

Write-Host "== LF-DAT Phase 3 FINAL FIX =="
$ErrorActionPreference = "Stop"

$App = "C:\ServerManager\ServerManager"
$AppCode = Join-Path $App "App.axaml.cs"

if (-not (Test-Path $AppCode)) {
    Write-Host "ERROR: App.axaml.cs not found"
    exit 1
}

# Backup
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_fix2_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# Fix MainWindow reference
(Get-Content $AppCode) |
    ForEach-Object {
        if ($_ -match "new MainWindow") {
            $_ -replace "new MainWindow", "new ServerManager.Views.MainWindow"
        } else {
            $_
        }
    } | Set-Content $AppCode -Encoding UTF8

Write-Host "✔ MainWindow reference fixed"

# Build + Run
Set-Location $App
dotnet build
dotnet run

