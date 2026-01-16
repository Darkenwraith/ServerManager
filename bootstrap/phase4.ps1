# LF-DAT Phase 4
# SteamCMD Installer + Install/Update UI + Presets (stable binding mode)
# - Uses Avalonia StorageProvider (no obsolete OpenFileDialog)
# - Lets user choose servers folder (default C:\Servers)
# - Anonymous steam login by default; optional account login warning
# - Keeps Phase 3 stability (no compiled bindings)
# Safe to re-run (backs up project)

Write-Host "== LF-DAT Phase 4 =="
$ErrorActionPreference = "Stop"

$App = "C:\ServerManager\ServerManager"
if (-not (Test-Path $App)) { throw "Project not found: $App" }

Set-Location $App

# Backup
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_phase4_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# Ensure folders
$Folders = @(
  (Join-Path $App "Models"),
  (Join-Path $App "Services"),
  (Join-Path $App "Runtime"),
  (Join-Path $App "ViewModels"),
  (Join-Path $App "Views")
)
foreach($f in $Folders){ New-Item -ItemType Directory -Path $f -Force | Out-Null }

# ----------------------------
# Models: ServerDefinition.cs (ensure ToString shows name)
# ----------------------------
$ServerDef = Join-Path $App "Models\ServerDefinition.cs"
if (-not (Test-Path $ServerDef)) {
@"
using System;
using System.Diagnostics;

namespace ServerManager.Models
{
    public class ServerDefinition
    {
        public string Name { get; set; } = "";
        public string InstallPath { get; set; } = "";
        public string ExecutablePath { get; set; } = "";
        public string Arguments { get; set; } = "";
        public bool DebugMode { get; set; } = false;

        // Runtime
        public int? Pid { get; set; } = null;
        public string Status { get; set; } = "Stopped";
        public string LogFile { get; set; } = "";

        public bool IsValid =>
            !string.IsNullOrWhiteSpace(Name) &&
            !string.IsNullOrWhiteSpace(ExecutablePath);

        public override string ToString() => Name;
    }
}
"@ | Set-Content $ServerDef -Encoding UTF8
  Write-Host "✔ Created Models\ServerDefinition.cs"
} else {
  # Ensure ToString exists
  $txt = Get-Content $ServerDef -Raw
  if ($txt -notmatch "override string ToString") {
    $txt = $txt -replace "\}\s*\z", @"
        public override string ToString() => Name;
    }
}
"@
    $txt | Set-Content $ServerDef -Encoding UTF8
    Write-Host "✔ Patched ServerDefinition.ToString()"
  }
}

# ----------------------------
# Services: AppSettings + Steam settings
# ----------------------------
$Settings = Join-Path $App "Services\AppSettings.cs"
@"
using System;
using System.IO;
using System.Text.Json;

namespace ServerManager.Services
{
    public class AppSettings
    {
        public string ServersRoot { get; set; } = @"C:\Servers";
        public string SteamCmdRoot { get; set; } = @"C:\Servers\SteamCMD";
        public string SteamMode { get; set; } = "anonymous"; // anonymous | account
        public string SteamUser { get; set; } = "";
        public string SteamPass { get; set; } = "";

        public static string SettingsPath()
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "LF-DAT",
                "ServerManager"
            );
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "settings.json");
        }

        public static AppSettings Load()
        {
            var p = SettingsPath();
            if (!File.Exists(p)) return new AppSettings();
            try
            {
                var json = File.ReadAllText(p);
                return JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
            }
            catch { return new AppSettings(); }
        }

        public void Save()
        {
            var p = SettingsPath();
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions{ WriteIndented = true });
            File.WriteAllText(p, json);
        }
    }
}
"@ | Set-Content $Settings -Encoding UTF8
Write-Host "✔ Services\AppSettings.cs"

# ----------------------------
# Services: SteamCmdService.cs
# ----------------------------
$SteamSvc = Join-Path $App "Services\SteamCmdService.cs"
@"
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Threading.Tasks;

namespace ServerManager.Services
{
    public class SteamCmdService
    {
        // Official zip from Valve wiki
        private const string SteamCmdZipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip";

        public string SteamCmdExe(string steamCmdRoot) =>
            Path.Combine(steamCmdRoot, "steamcmd.exe");

        public bool IsInstalled(string steamCmdRoot) =>
            File.Exists(SteamCmdExe(steamCmdRoot));

        public async Task<string> EnsureInstalledAsync(string steamCmdRoot)
        {
            Directory.CreateDirectory(steamCmdRoot);

            if (IsInstalled(steamCmdRoot))
                return "SteamCMD already installed.";

            var zipPath = Path.Combine(steamCmdRoot, "steamcmd.zip");

            using var http = new HttpClient();
            var data = await http.GetByteArrayAsync(SteamCmdZipUrl);
            await File.WriteAllBytesAsync(zipPath, data);

            ZipFile.ExtractToDirectory(zipPath, steamCmdRoot, true);
            try { File.Delete(zipPath); } catch { }

            if (!IsInstalled(steamCmdRoot))
                return "SteamCMD download completed, but steamcmd.exe not found after extract.";

            return "SteamCMD installed.";
        }

        public async Task<(int code, string output)> RunSteamCmdAsync(
            string steamCmdRoot,
            string arguments,
            bool showWindow = false)
        {
            var exe = SteamCmdExe(steamCmdRoot);
            if (!File.Exists(exe))
                return (-1, "steamcmd.exe not found. Install SteamCMD first.");

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = arguments,
                WorkingDirectory = steamCmdRoot,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = !showWindow
            };

            try
            {
                var p = Process.Start(psi)!;
                var stdout = await p.StandardOutput.ReadToEndAsync();
                var stderr = await p.StandardError.ReadToEndAsync();
                await p.WaitForExitAsync();
                return (p.ExitCode, (stdout + "\n" + stderr).Trim());
            }
            catch (Exception ex)
            {
                return (-2, ex.Message);
            }
        }

        public string BuildLoginArgs(string mode, string user, string pass)
        {
            if (string.Equals(mode, "account", StringComparison.OrdinalIgnoreCase) &&
                !string.IsNullOrWhiteSpace(user))
            {
                // Note: password may trigger Steam Guard prompts depending on account
                return $"+login {user} {pass}";
            }

            return "+login anonymous";
        }

        public string InstallOrUpdateArgs(string loginArgs, int appId, string installDir)
        {
            // Force platform windows for most windows DS builds; safe default
            return $"{loginArgs} +force_install_dir \"{installDir}\" +app_update {appId} validate +quit";
        }
    }
}
"@ | Set-Content $SteamSvc -Encoding UTF8
Write-Host "✔ Services\SteamCmdService.cs"

# ----------------------------
# Runtime: ServerRuntime.cs (ensure exists)
# ----------------------------
$RuntimeFile = Join-Path $App "Runtime\ServerRuntime.cs"
if (-not (Test-Path $RuntimeFile)) {
@"
using System;
using System.Diagnostics;
using System.IO;

namespace ServerManager.Runtime
{
    public static class ServerRuntime
    {
        public static Process? Start(string exe, string args, string logFile, bool debugWindow)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(logFile)!);

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = args ?? "",
                WorkingDirectory = Path.GetDirectoryName(exe) ?? Environment.CurrentDirectory,
                RedirectStandardOutput = !debugWindow,
                RedirectStandardError  = !debugWindow,
                UseShellExecute = debugWindow,       // debug: allow console window if exe spawns one
                CreateNoWindow  = !debugWindow
            };

            try
            {
                var p = Process.Start(psi);
                if (p == null) return null;

                if (!debugWindow)
                {
                    var writer = new StreamWriter(logFile, true) { AutoFlush = true };
                    p.OutputDataReceived += (_, e) => { if (e.Data != null) writer.WriteLine(e.Data); };
                    p.ErrorDataReceived  += (_, e) => { if (e.Data != null) writer.WriteLine(e.Data); };
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                }

                return p;
            }
            catch { return null; }
        }

        public static void Stop(Process p)
        {
            if (!p.HasExited)
                p.Kill(true);
        }
    }
}
"@ | Set-Content $RuntimeFile -Encoding UTF8
  Write-Host "✔ Runtime\ServerRuntime.cs"
}

# ----------------------------
# ViewModels: MainViewModel.cs (servers + steam install/update)
# ----------------------------
$VM = Join-Path $App "ViewModels\MainViewModel.cs"
@"
using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using ServerManager.Models;
using ServerManager.Runtime;
using ServerManager.Services;

namespace ServerManager.ViewModels
{
    public class MainViewModel
    {
        public ObservableCollection<ServerDefinition> Servers { get; } =
            new ObservableCollection<ServerDefinition>();

        public ServerDefinition? SelectedServer { get; set; }

        public AppSettings Settings { get; private set; } = AppSettings.Load();
        public SteamCmdService Steam { get; } = new SteamCmdService();

        // Steam installer UI state
        public string SteamStatus { get; set; } = "";
        public string InstallStatus { get; set; } = "";

        // Presets / install
        public int InstallAppId { get; set; } = 0;
        public string InstallFolder { get; set; } = ""; // per-install override (optional)

        public void SaveSettings() => Settings.Save();

        public void AddServer(ServerDefinition s)
        {
            if (s == null || !s.IsValid) return;

            if (string.IsNullOrWhiteSpace(s.LogFile))
            {
                var logs = Path.Combine(Settings.ServersRoot, "_logs");
                Directory.CreateDirectory(logs);
                s.LogFile = Path.Combine(logs, s.Name + ".log");
            }

            Servers.Add(s);
        }

        public void StartSelected()
        {
            if (SelectedServer == null) return;
            var s = SelectedServer;

            if (s.Pid != null) return;

            if (!File.Exists(s.ExecutablePath))
            {
                s.Status = "Missing EXE";
                return;
            }

            var p = ServerRuntime.Start(s.ExecutablePath, s.Arguments, s.LogFile, s.DebugMode);
            if (p == null)
            {
                s.Status = "Start failed";
                return;
            }

            s.Pid = p.Id;
            s.Status = "Running";
        }

        public void StopSelected()
        {
            if (SelectedServer == null) return;
            var s = SelectedServer;

            if (s.Pid == null)
            {
                s.Status = "Stopped";
                return;
            }

            try
            {
                var p = Process.GetProcessById(s.Pid.Value);
                ServerRuntime.Stop(p);
            }
            catch { }

            s.Pid = null;
            s.Status = "Stopped";
        }

        public void RestartSelected()
        {
            StopSelected();
            StartSelected();
        }

        public string Diagnostics(ServerDefinition? s)
        {
            if (s == null) return "";
            return
$@"Name: {s.Name}
Status: {s.Status}
Exe: {s.ExecutablePath}
Args: {s.Arguments}
Log: {s.LogFile}
PID: {(s.Pid?.ToString() ?? "n/a")}
Debug: {s.DebugMode}
";
        }

        // ---------------- Steam ----------------
        public async Task SteamEnsureAsync()
        {
            SteamStatus = "Installing SteamCMD...";
            var msg = await Steam.EnsureInstalledAsync(Settings.SteamCmdRoot);
            SteamStatus = msg;
        }

        public async Task SteamInstallOrUpdateAsync()
        {
            if (InstallAppId <= 0)
            {
                InstallStatus = "Enter a valid AppID.";
                return;
            }

            var target = string.IsNullOrWhiteSpace(InstallFolder)
                ? Path.Combine(Settings.ServersRoot, InstallAppId.ToString())
                : InstallFolder;

            Directory.CreateDirectory(target);

            var login = Steam.BuildLoginArgs(Settings.SteamMode, Settings.SteamUser, Settings.SteamPass);
            var args = Steam.InstallOrUpdateArgs(login, InstallAppId, target);

            InstallStatus = "Running SteamCMD...";
            var (code, output) = await Steam.RunSteamCmdAsync(Settings.SteamCmdRoot, args, showWindow:false);
            InstallStatus = $"Exit {code}. " + (output.Length > 300 ? output.Substring(0, 300) + "..." : output);
        }
    }
}
"@ | Set-Content $VM -Encoding UTF8
Write-Host "✔ ViewModels\MainViewModel.cs"

# ----------------------------
# App.axaml.cs ensure using Views + create MainWindow correctly
# ----------------------------
$AppCode = Join-Path $App "App.axaml.cs"
$ac = Get-Content $AppCode -Raw
if ($ac -notmatch "using ServerManager\.Views") {
  $ac = $ac -replace "using Avalonia\.Controls;", "using Avalonia.Controls;`nusing ServerManager.Views;"
}
# Ensure MainWindow instantiation is qualified
$ac = $ac -replace "new ServerManager\.Views\.MainWindow\(\)", "new ServerManager.Views.MainWindow()"
$ac = $ac -replace "new MainWindow\(\)", "new ServerManager.Views.MainWindow()"
$ac | Set-Content $AppCode -Encoding UTF8
Write-Host "✔ App.axaml.cs checked"

# ----------------------------
# Views: MainWindow.axaml (add Steam tab + buttons)
# ----------------------------
$MainXaml = Join-Path $App "Views\MainWindow.axaml"
@"
<Window xmlns='https://github.com/avaloniaui'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        x:Class='ServerManager.Views.MainWindow'
        Width='1100' Height='700'
        Background='#1E1E1E'
        Title='Server Control Center'>

  <Grid ColumnDefinitions='300,*' RowDefinitions='Auto,*'>

    <StackPanel Grid.ColumnSpan='2' Orientation='Horizontal' Margin='12'>
      <TextBlock Text='LF-DAT Server Control Center'
                 FontSize='22'
                 FontWeight='Bold'
                 Foreground='White'/>
    </StackPanel>

    <Border Grid.Row='1' Background='#252526' Padding='8'>
      <StackPanel>
        <TextBlock Text='Servers' Foreground='White' Margin='4'/>

        <ListBox Name='ServerList' Height='520'>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <StackPanel Orientation='Horizontal' Margin='4'>
                <Ellipse Width='10' Height='10' Fill='Gray' Margin='0,0,6,0'/>
                <TextBlock Text='{Binding}' Foreground='White'/>
              </StackPanel>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>

        <Button Name='AddBtn' Content='Add Server' Margin='2'/>
        <Button Name='RemoveBtn' Content='Remove Server' Margin='2'/>
      </StackPanel>
    </Border>

    <TabControl Grid.Row='1' Grid.Column='1' Margin='12'>

      <TabItem Header='Overview'>
        <StackPanel>
          <TextBlock Name='SelName'
                     Foreground='White'
                     FontSize='16'
                     Margin='0,0,0,10'/>

          <TextBlock Name='SelStatus'
                     Foreground='Gray'
                     Margin='0,0,0,10'/>

          <StackPanel Orientation='Horizontal'>
            <Button Name='StartBtn' Content='Start' Width='90' Margin='4'/>
            <Button Name='StopBtn' Content='Stop' Width='90' Margin='4'/>
            <Button Name='RestartBtn' Content='Restart' Width='90' Margin='4'/>
          </StackPanel>

          <CheckBox Name='DebugToggle'
                    Content='Debug Mode (show console)'
                    Foreground='White'
                    Margin='4'/>
        </StackPanel>
      </TabItem>

      <TabItem Header='Live Log'>
        <TextBox Name='LogBox'
                 AcceptsReturn='True'
                 IsReadOnly='True'
                 Background='#1E1E1E'
                 Foreground='LightGray'/>
      </TabItem>

      <TabItem Header='Diagnostics'>
        <TextBox Name='DiagBox'
                 AcceptsReturn='True'
                 IsReadOnly='True'
                 Background='#1E1E1E'
                 Foreground='LightGray'/>
      </TabItem>

      <TabItem Header='Steam'>
        <ScrollViewer>
          <StackPanel Margin='6' Spacing='8'>

            <TextBlock Text='Servers Folder (default)'
                       Foreground='White'
                       FontSize='14'
                       Margin='0,0,0,4'/>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <TextBox Name='ServersRootBox' Width='520'/>
              <Button Name='ChooseServersRootBtn' Content='Choose...' Width='100'/>
              <Button Name='SaveSettingsBtn' Content='Save' Width='80'/>
            </StackPanel>

            <Separator/>

            <TextBlock Text='Steam Login'
                       Foreground='White'
                       FontSize='14'/>

            <StackPanel Orientation='Horizontal' Spacing='10'>
              <RadioButton Name='SteamAnonRadio' Content='Anonymous (recommended)' IsChecked='True' Foreground='White'/>
              <RadioButton Name='SteamAcctRadio' Content='Account (some downloads require it)' Foreground='White'/>
            </StackPanel>

            <TextBlock Name='SteamWarningText'
                       Foreground='Orange'
                       TextWrapping='Wrap'/>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <TextBox Name='SteamUserBox' Width='240' Watermark='Steam username'/>
              <TextBox Name='SteamPassBox' Width='240' PasswordChar='*' Watermark='Steam password'/>
            </StackPanel>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <Button Name='InstallSteamCmdBtn' Content='Install/Repair SteamCMD' Width='220'/>
              <TextBlock Name='SteamStatusText' Foreground='LightGray' VerticalAlignment='Center'/>
            </StackPanel>

            <Separator/>

            <TextBlock Text='Install / Update Steam Dedicated Server'
                       Foreground='White'
                       FontSize='14'/>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <ComboBox Name='PresetCombo' Width='260'/>
              <Button Name='ApplyPresetBtn' Content='Apply Preset' Width='140'/>
            </StackPanel>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <TextBox Name='AppIdBox' Width='140' Watermark='AppID'/>
              <TextBox Name='InstallFolderBox' Width='520' Watermark='Optional install folder override'/>
              <Button Name='ChooseInstallFolderBtn' Content='Choose...' Width='100'/>
            </StackPanel>

            <StackPanel Orientation='Horizontal' Spacing='8'>
              <Button Name='RunInstallBtn' Content='Install / Update' Width='160'/>
              <TextBlock Name='InstallStatusText' Foreground='LightGray' TextWrapping='Wrap' Width='600'/>
            </StackPanel>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

    </TabControl>
  </Grid>
</Window>
"@ | Set-Content $MainXaml -Encoding UTF8
Write-Host "✔ Views\MainWindow.axaml (Steam tab added)"

# ----------------------------
# Views: MainWindow.axaml.cs (use StorageProvider file/folder pickers + wiring)
# ----------------------------
$MainCode = Join-Path $App "Views\MainWindow.axaml.cs"
@"
using Avalonia;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using ServerManager.Models;
using ServerManager.ViewModels;
using System;
using System.IO;
using System.Linq;
using System.Timers;
using System.Threading.Tasks;

namespace ServerManager.Views
{
    public partial class MainWindow : Window
    {
        private readonly MainViewModel _vm = new();
        private readonly Timer _logTimer = new(1000);

        // Simple presets (can expand later)
        private readonly (string Name, int AppId)[] _presets = new[]
        {
            ("Palworld Dedicated Server", 2394010),
            // NOTE: SCUM DS AppID can differ based on distribution; user can still type it manually
            ("SCUM (enter AppID)", 0),
            ("Project Zomboid (enter AppID)", 0),
            ("Conan Exiles (enter AppID)", 0),
            ("Atlas (enter AppID)", 0),
            ("StarRupture (enter AppID)", 0),
        };

        public MainWindow()
        {
            InitializeComponent();

            // Phase 3 stability binding: ItemsSource
            ServerList.ItemsSource = _vm.Servers;

            // Defaults in UI
            ServersRootBox.Text = _vm.Settings.ServersRoot;
            InstallFolderBox.Text = "";

            SteamWarningText.Text =
                "Tip: Anonymous is safest. If you use Account login, Steam may block playing on that account while SteamCMD is active.";

            PresetCombo.ItemsSource = _presets.Select(p => p.Name).ToArray();
            PresetCombo.SelectedIndex = 0;

            // Disable account fields until selected
            SteamUserBox.IsEnabled = false;
            SteamPassBox.IsEnabled = false;

            // Timers
            _logTimer.Elapsed += (_, __) => RefreshLog();
            _logTimer.Start();

            // Server actions
            AddBtn.Click += AddServer;
            RemoveBtn.Click += RemoveServer;
            StartBtn.Click += (_, __) => { _vm.StartSelected(); RefreshInfo(); };
            StopBtn.Click += (_, __) => { _vm.StopSelected(); RefreshInfo(); };
            RestartBtn.Click += (_, __) => { _vm.RestartSelected(); RefreshInfo(); };
            ServerList.SelectionChanged += (_, __) => { _vm.SelectedServer = ServerList.SelectedItem as ServerDefinition; RefreshInfo(); };
            DebugToggle.Click += (_, __) => { if (_vm.SelectedServer != null) _vm.SelectedServer.DebugMode = DebugToggle.IsChecked ?? false; };

            // Steam settings + actions
            SteamAnonRadio.Checked += (_, __) => SetSteamModeAnonymous();
            SteamAcctRadio.Checked += (_, __) => SetSteamModeAccount();

            SaveSettingsBtn.Click += (_, __) => SaveSettings();
            InstallSteamCmdBtn.Click += async (_, __) => await InstallSteamCmd();

            ChooseServersRootBtn.Click += async (_, __) => await ChooseServersRoot();
            ChooseInstallFolderBtn.Click += async (_, __) => await ChooseInstallFolder();

            ApplyPresetBtn.Click += (_, __) => ApplyPreset();
            RunInstallBtn.Click += async (_, __) => await RunInstallOrUpdate();
        }

        // ---------- Server Add (exe picker) ----------
        private async void AddServer(object? sender, RoutedEventArgs e)
        {
            var files = await this.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Select Server Executable",
                AllowMultiple = false
            });

            var f = files.FirstOrDefault();
            if (f == null) return;

            var exe = f.Path.LocalPath;

            var s = new ServerDefinition
            {
                Name = Path.GetFileNameWithoutExtension(exe),
                ExecutablePath = exe,
                InstallPath = Path.GetDirectoryName(exe) ?? "",
                Arguments = "",
            };

            _vm.AddServer(s);
        }

        private void RemoveServer(object? sender, RoutedEventArgs e)
        {
            if (_vm.SelectedServer == null) return;
            _vm.Servers.Remove(_vm.SelectedServer);
            _vm.SelectedServer = null;
            RefreshInfo();
        }

        // ---------- UI Refresh ----------
        private void RefreshInfo()
        {
            if (_vm.SelectedServer == null)
            {
                SelName.Text = "";
                SelStatus.Text = "";
                DiagBox.Text = "";
                DebugToggle.IsChecked = false;
                return;
            }

            SelName.Text = _vm.SelectedServer.Name;
            SelStatus.Text = "Status: " + _vm.SelectedServer.Status;
            DebugToggle.IsChecked = _vm.SelectedServer.DebugMode;
            DiagBox.Text = _vm.Diagnostics(_vm.SelectedServer);
        }

        private void RefreshLog()
        {
            var s = _vm.SelectedServer;
            if (s == null) return;

            var log = s.LogFile;
            if (string.IsNullOrWhiteSpace(log) || !File.Exists(log)) return;

            try
            {
                var txt = File.ReadAllText(log);
                Dispatcher.UIThread.Post(() =>
                {
                    LogBox.Text = txt;
                    LogBox.CaretIndex = LogBox.Text.Length;
                });
            }
            catch { }
        }

        // ---------- Steam Settings ----------
        private void SetSteamModeAnonymous()
        {
            _vm.Settings.SteamMode = "anonymous";
            SteamUserBox.IsEnabled = false;
            SteamPassBox.IsEnabled = false;
        }

        private void SetSteamModeAccount()
        {
            _vm.Settings.SteamMode = "account";
            SteamUserBox.IsEnabled = true;
            SteamPassBox.IsEnabled = true;
        }

        private void SaveSettings()
        {
            _vm.Settings.ServersRoot = ServersRootBox.Text ?? @"C:\Servers";
            _vm.Settings.SteamCmdRoot = Path.Combine(_vm.Settings.ServersRoot, "SteamCMD");
            _vm.Settings.SteamUser = SteamUserBox.Text ?? "";
            _vm.Settings.SteamPass = SteamPassBox.Text ?? "";
            _vm.SaveSettings();

            SteamStatusText.Text = "Settings saved.";
        }

        private async Task ChooseServersRoot()
        {
            var folders = await this.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "Choose servers folder",
                AllowMultiple = false
            });

            var f = folders.FirstOrDefault();
            if (f == null) return;

            ServersRootBox.Text = f.Path.LocalPath;
            // also update steamcmd default path right away (still requires Save)
            _vm.Settings.ServersRoot = ServersRootBox.Text;
            _vm.Settings.SteamCmdRoot = Path.Combine(_vm.Settings.ServersRoot, "SteamCMD");
        }

        private async Task ChooseInstallFolder()
        {
            var folders = await this.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "Choose install folder (optional override)",
                AllowMultiple = false
            });

            var f = folders.FirstOrDefault();
            if (f == null) return;

            InstallFolderBox.Text = f.Path.LocalPath;
        }

        private async Task InstallSteamCmd()
        {
            SaveSettingsBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

            SteamStatusText.Text = "Installing SteamCMD...";
            await _vm.SteamEnsureAsync();
            SteamStatusText.Text = _vm.SteamStatus;
        }

        private void ApplyPreset()
        {
            var idx = PresetCombo.SelectedIndex;
            if (idx < 0 || idx >= _presets.Length) return;

            var preset = _presets[idx];
            if (preset.AppId > 0)
                AppIdBox.Text = preset.AppId.ToString();
        }

        private async Task RunInstallOrUpdate()
        {
            SaveSettings();

            if (!int.TryParse(AppIdBox.Text, out var appId) || appId <= 0)
            {
                InstallStatusText.Text = "Enter a valid AppID.";
                return;
            }

            _vm.InstallAppId = appId;
            _vm.InstallFolder = InstallFolderBox.Text ?? "";

            InstallStatusText.Text = "Running SteamCMD...";
            await _vm.SteamInstallOrUpdateAsync();
            InstallStatusText.Text = _vm.InstallStatus;
        }
    }
}
"@ | Set-Content $MainCode -Encoding UTF8
Write-Host "✔ Views\MainWindow.axaml.cs (SteamCMD UI wired)"

# ----------------------------
# Build + Run
# ----------------------------
dotnet build
Write-Host "✔ Phase 4 build OK"
dotnet run

