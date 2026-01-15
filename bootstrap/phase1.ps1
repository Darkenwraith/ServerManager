# LF-DAT Phase 1 Bootstrap
# Creates ServerManager base app safely (net8 + Avalonia)

Write-Host "== LF-DAT Phase 1 Bootstrap =="
$ErrorActionPreference = "Stop"

# ---- CONFIG ----
$Base = "C:\ServerManager"
$App  = Join-Path $Base "ServerManager"

# ---- CHECK DOTNET ----
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: .NET SDK not found. Install .NET 8 from:"
    Write-Host "https://dotnet.microsoft.com/download"
    exit 1
}

$ver = dotnet --version
Write-Host "✔ .NET detected: $ver"

# ---- CREATE PROJECT ----
if (-not (Test-Path $App)) {
    Write-Host "Creating base project..."
    New-Item -ItemType Directory -Path $Base -Force | Out-Null
    Set-Location $Base
    dotnet new avalonia.app -o ServerManager --framework net8.0
} else {
    Write-Host "Project already exists: $App"
}

Set-Location $App

# ---- BACKUP ----
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# ---- FIRST BUILD ----
Write-Host "Building..."
dotnet build

Write-Host "✔ Phase 1 complete"
Write-Host "You can now run Phase 2 when ready."
