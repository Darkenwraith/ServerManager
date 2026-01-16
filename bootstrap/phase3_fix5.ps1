# LF-DAT Phase 3 ULTIMATE STABILITY FIX
# Removes property binding and binds whole object instead
# This avoids Avalonia AVLN2000 errors permanently

Write-Host "== LF-DAT Phase 3 ULTIMATE STABILITY FIX =="
$ErrorActionPreference = "Stop"

$App = "C:\ServerManager\ServerManager"
$Xaml = Join-Path $App "Views\MainWindow.axaml"

if (-not (Test-Path $Xaml)) {
    Write-Host "ERROR: MainWindow.axaml not found"
    exit 1
}

# Backup
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_fix5_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# Patch binding
(Get-Content $Xaml) |
    ForEach-Object {
        $_ -replace "Text='\{Binding\s+Name\}'", "Text='{Binding}'"
    } | Set-Content $Xaml -Encoding UTF8

Write-Host "✔ Binding switched to whole-object mode"

# Build + Run
Set-Location $App
dotnet build
dotnet run

