# LF-DAT Phase 2 Bootstrap
# Adds runtime engine, silent launch, per-server logging, and debug toggle
# Safe to re-run (creates backups automatically)

Write-Host "== LF-DAT Phase 2 =="
$ErrorActionPreference = "Stop"

# ---- PATHS ----
$Base = "C:\ServerManager"
$App  = Join-Path $Base "ServerManager"

if (-not (Test-Path $App)) {
    Write-Host "ERROR: Project not found. Run Phase 1 first."
    exit 1
}

Set-Location $App

# ---- BACKUP ----
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_phase2_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# ---- ENSURE FOLDERS ----
$RuntimeDir = Join-Path $App "Runtime"
$ModelsDir  = Join-Path $App "Models"
$VMDir      = Join-Path $App "ViewModels"

New-Item -ItemType Directory -Path $RuntimeDir,$ModelsDir,$VMDir -Force | Out-Null

# ---- SERVER RUNTIME ENGINE ----
$RuntimeFile = Join-Path $RuntimeDir "ServerRuntime.cs"

@"
using System;
using System.Diagnostics;
using System.IO;

namespace ServerManager.Runtime
{
    public static class ServerRuntime
    {
        public static Process Start(
            string exe,
            string args,
            string logFile,
            bool debugMode
        )
        {
            if (string.IsNullOrWhiteSpace(exe))
                throw new ArgumentException("Executable path is empty.");

            if (string.IsNullOrWhiteSpace(logFile))
                throw new ArgumentException("Log file path is empty.");

            Directory.CreateDirectory(Path.GetDirectoryName(logFile)!);

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = args ?? "",
                WorkingDirectory = Path.GetDirectoryName(exe) ?? Environment.CurrentDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = !debugMode
            };

            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };

            var writer = new StreamWriter(logFile, append: true)
            {
                AutoFlush = true
            };

            void WriteLine(string? text)
            {
                if (!string.IsNullOrWhiteSpace(text))
                    writer.WriteLine(text);
            }

            p.OutputDataReceived += (_, e) => WriteLine(e.Data);
            p.ErrorDataReceived  += (_, e) => WriteLine(e.Data);

            p.Exited += (_, __) =>
            {
                try { writer.WriteLine($"[LF-DAT] Process exited at {DateTime.Now}"); }
                catch { }
                try { writer.Dispose(); }
                catch { }
            };

            if (!p.Start())
                throw new InvalidOperationException("Failed to start server process.");

            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            return p;
        }

        public static void Stop(Process p)
        {
            if (p == null) return;
            if (!p.HasExited)
                p.Kill(entireProcessTree: true);
        }
    }
}
"@ | Set-Content -Path $RuntimeFile -Encoding UTF8 -Force

# ---- SERVER MODEL (SAFE EXTENSION) ----
$ModelFile = Join-Path $ModelsDir "ServerDefinition.cs"

@"
using System;

namespace ServerManager.Models
{
    public class ServerDefinition
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        public string Name { get; set; } = "";
        public string InstallPath { get; set; } = "";
        public string ExecutablePath { get; set; } = "";
        public string Arguments { get; set; } = "";

        public bool DebugMode { get; set; } = false;

        public string LogFile { get; set; } = "";
        public string Status { get; set; } = "Stopped";
        public string LastError { get; set; } = "";

        public bool IsValid =>
            !string.IsNullOrWhiteSpace(Name) &&
            !string.IsNullOrWhiteSpace(ExecutablePath);
    }
}
"@ | Set-Content -Path $ModelFile -Encoding UTF8 -Force

# ---- VIEWMODEL EXTENSION ----
$VMFile = Join-Path $VMDir "MainViewModel.cs"

@"
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using ServerManager.Models;
using ServerManager.Runtime;

namespace ServerManager.ViewModels
{
    public class MainViewModel
    {
        public ObservableCollection<ServerDefinition> Servers { get; } = new();

        public ServerDefinition? SelectedServer { get; set; }

        private readonly Dictionary<string, Process> _procs = new();

        public void AddServer(ServerDefinition s)
        {
            if (s == null || !s.IsValid)
                return;

            if (string.IsNullOrWhiteSpace(s.LogFile))
            {
                var safeName = string.Join("_", (s.Name ?? "server")
                    .Split(Path.GetInvalidFileNameChars()));
                s.LogFile = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "LF-DAT",
                    "ServerManager",
                    "logs",
                    $"{safeName}_{s.Id}.log"
                );
            }

            Servers.Add(s);
            SelectedServer = s;
        }

        public void StartSelected()
        {
            if (SelectedServer != null)
                Start(SelectedServer);
        }

        public void StopSelected()
        {
            if (SelectedServer != null)
                Stop(SelectedServer);
        }

        public void RestartSelected()
        {
            if (SelectedServer == null) return;
            Stop(SelectedServer);
            Start(SelectedServer);
        }

        public void Start(ServerDefinition s)
        {
            try
            {
                if (!s.IsValid)
                {
                    s.LastError = "Server definition is invalid.";
                    s.Status = "Error";
                    return;
                }

                if (_procs.ContainsKey(s.Id) && !_procs[s.Id].HasExited)
                {
                    s.Status = "Running";
                    return;
                }

                var p = ServerRuntime.Start(
                    s.ExecutablePath,
                    s.Arguments ?? "",
                    s.LogFile,
                    s.DebugMode
                );

                _procs[s.Id] = p;
                s.Status = "Running";
                s.LastError = "";
            }
            catch (Exception ex)
            {
                s.Status = "Error";
                s.LastError = ex.Message;
            }
        }

        public void Stop(ServerDefinition s)
        {
            try
            {
                if (_procs.TryGetValue(s.Id, out var p))
                {
                    ServerRuntime.Stop(p);
                    _procs.Remove(s.Id);
                }
                s.Status = "Stopped";
            }
            catch (Exception ex)
            {
                s.Status = "Error";
                s.LastError = ex.Message;
            }
        }

        public string Diagnostics(ServerDefinition? s)
        {
            if (s == null)
                return "No server selected.";

            var exeOk = File.Exists(s.ExecutablePath);
            var logOk = !string.IsNullOrWhiteSpace(s.LogFile);

            return
                $"Name: {s.Name}\n" +
                $"Status: {s.Status}\n" +
                $"Exe Exists: {exeOk}\n" +
                $"Log Path Set: {logOk}\n" +
                $"Debug Mode: {s.DebugMode}\n" +
                $"Last Error: {s.LastError}\n";
        }
    }
}
"@ | Set-Content -Path $VMFile -Encoding UTF8 -Force

# ---- BUILD + RUN ----
dotnet build
Write-Host "✔ Phase 2 build successful"

dotnet run
