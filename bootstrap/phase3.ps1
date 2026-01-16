# LF-DAT Phase 3 Bootstrap
# Pro Control Panel UI (Status, Add/Remove, Start/Stop/Restart, Logs, Diagnostics)
# Safe to re-run (backs up before changes)

Write-Host "== LF-DAT Phase 3 =="
$ErrorActionPreference = "Stop"

# ---- PATHS ----
$Base = "C:\ServerManager"
$App  = Join-Path $Base "ServerManager"

if (-not (Test-Path $App)) {
    Write-Host "ERROR: Project not found. Run Phase 1 and 2 first."
    exit 1
}

Set-Location $App

# ---- BACKUP ----
$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Backup = "$App.backup_phase3_$Stamp"
Copy-Item $App $Backup -Recurse -Force
Write-Host "✔ Backup created: $Backup"

# ---- ENSURE FOLDERS ----
$Views  = Join-Path $App "Views"
$VMs    = Join-Path $App "ViewModels"
$Models = Join-Path $App "Models"

New-Item -ItemType Directory -Path $Views,$VMs,$Models -Force | Out-Null

# ---- MAIN WINDOW XAML ----
$MainXaml = Join-Path $Views "MainWindow.axaml"

@"
<Window xmlns='https://github.com/avaloniaui'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        x:Class='ServerManager.Views.MainWindow'
        Width='1000' Height='650'
        Background='#1E1E1E'
        Title='Server Control Center'>

  <Grid ColumnDefinitions='280,*' RowDefinitions='Auto,*'>

    <!-- Header -->
    <StackPanel Grid.ColumnSpan='2' Orientation='Horizontal' Margin='10'>
      <TextBlock Text='LF-DAT Server Control Center' 
                 FontSize='20' 
                 FontWeight='Bold'
                 Foreground='White'/>
    </StackPanel>

    <!-- Server List -->
    <Border Grid.Row='1' Background='#252526' Padding='6'>
      <StackPanel>
        <TextBlock Text='Servers' Foreground='White' Margin='4'/>
        <ListBox Name='ServerList' Height='500'>
          <ListBox.ItemTemplate>
            <DataTemplate>
              <StackPanel Orientation='Horizontal' Margin='4'>
                <Ellipse Width='10' Height='10' 
                         Fill='Gray' Margin='0,0,6,0'/>
                <TextBlock Text='{Binding Name}' Foreground='White'/>
              </StackPanel>
            </DataTemplate>
          </ListBox.ItemTemplate>
        </ListBox>

        <Button Name='AddBtn' Content='Add Server' Margin='2'/>
        <Button Name='RemoveBtn' Content='Remove Server' Margin='2'/>
      </StackPanel>
    </Border>

    <!-- Right Panel -->
    <TabControl Grid.Row='1' Grid.Column='1' Margin='10'>

      <TabItem Header='Overview'>
        <StackPanel>
          <TextBlock Name='SelName' Foreground='White' FontSize='16' Margin='0,0,0,10'/>
          <TextBlock Name='SelStatus' Foreground='Gray' Margin='0,0,0,10'/>

          <StackPanel Orientation='Horizontal'>
            <Button Name='StartBtn' Content='Start' Width='80' Margin='4'/>
            <Button Name='StopBtn' Content='Stop' Width='80' Margin='4'/>
            <Button Name='RestartBtn' Content='Restart' Width='80' Margin='4'/>
          </StackPanel>

          <CheckBox Name='DebugToggle' Content='Debug Mode (show console)' 
                    Foreground='White' Margin='4'/>
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

    </TabControl>
  </Grid>
</Window>
"@ | Set-Content -Path $MainXaml -Encoding UTF8 -Force

# ---- CODE BEHIND ----
$MainCode = Join-Path $Views "MainWindow.axaml.cs"

@"
using Avalonia.Controls;
using Avalonia.Interactivity;
using ServerManager.Models;
using ServerManager.ViewModels;
using System;
using System.IO;
using System.Timers;

namespace ServerManager.Views
{
    public partial class MainWindow : Window
    {
        private readonly MainViewModel _vm = new();
        private readonly Timer _logTimer = new(1000);

        public MainWindow()
        {
            InitializeComponent();
            ServerList.Items = _vm.Servers;

            _logTimer.Elapsed += (_, __) => RefreshLog();
            _logTimer.Start();

            AddBtn.Click += AddServer;
            RemoveBtn.Click += RemoveServer;
            StartBtn.Click += (_, __) => _vm.StartSelected();
            StopBtn.Click += (_, __) => _vm.StopSelected();
            RestartBtn.Click += (_, __) => _vm.RestartSelected();
            ServerList.SelectionChanged += ServerChanged;
            DebugToggle.Click += DebugChanged;
        }

        private void AddServer(object? sender, RoutedEventArgs e)
        {
            var dlg = new OpenFileDialog();
            dlg.Title = "Select Server Executable";

            var result = dlg.ShowAsync(this).Result;
            if (result == null || result.Length == 0) return;

            var exe = result[0];
            var s = new ServerDefinition
            {
                Name = Path.GetFileNameWithoutExtension(exe),
                ExecutablePath = exe,
                InstallPath = Path.GetDirectoryName(exe) ?? "",
                Arguments = ""
            };

            _vm.AddServer(s);
        }

        private void RemoveServer(object? sender, RoutedEventArgs e)
        {
            if (_vm.SelectedServer == null) return;
            _vm.Servers.Remove(_vm.SelectedServer);
        }

        private void ServerChanged(object? sender, SelectionChangedEventArgs e)
        {
            _vm.SelectedServer = ServerList.SelectedItem as ServerDefinition;
            RefreshInfo();
        }

        private void RefreshInfo()
        {
            if (_vm.SelectedServer == null)
            {
                SelName.Text = "";
                SelStatus.Text = "";
                return;
            }

            SelName.Text = _vm.SelectedServer.Name;
            SelStatus.Text = "Status: " + _vm.SelectedServer.Status;
            DebugToggle.IsChecked = _vm.SelectedServer.DebugMode;
            DiagBox.Text = _vm.Diagnostics(_vm.SelectedServer);
        }

        private void RefreshLog()
        {
            if (_vm.SelectedServer == null) return;
            var log = _vm.SelectedServer.LogFile;
            if (File.Exists(log))
            {
                try
                {
                    LogBox.Text = File.ReadAllText(log);
                    LogBox.CaretIndex = LogBox.Text.Length;
                }
                catch { }
            }
        }

        private void DebugChanged(object? sender, RoutedEventArgs e)
        {
            if (_vm.SelectedServer != null)
                _vm.SelectedServer.DebugMode = DebugToggle.IsChecked ?? false;
        }
    }
}
"@ | Set-Content -Path $MainCode -Encoding UTF8 -Force

# ---- BUILD + RUN ----
dotnet build
Write-Host "✔ Phase 3 build successful"

dotnet run
