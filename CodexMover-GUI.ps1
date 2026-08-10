#Requires -Version 5.0
<#
.SYNOPSIS
  Codex Mover GUI (WPF, Dawn theme) - graphical wizard host.

.DESCRIPTION
  Loads CodexMover-GUI.xaml via XamlReader and drives the UI. All migration
  logic stays in codex-mover.ps1 (the engine), which is invoked as a child
  powershell.exe process; stdout/stderr are streamed back to the log box
  asynchronously so the UI never freezes.

  Behaviour is 1:1 with the v1.1.0 WinForms wizard:
    - 5 default source folders + custom source paths
    - target drive/folder with live preview
    - backup / auto-close / dry-run options
    - start / restore / exit actions
    - controls disabled while running, window close blocked while running
    - -SelfTest prints control/source/drive checks and exits

.PARAMETER SelfTest
  Print a baseline check (XAML load, controls, sources, drives) and exit.

.PARAMETER TestMode
  Testing/screenshot helper only: passes -SkipProcessCheck to the engine so
  dry-run / migration tests can run while Codex is open. Never used by end users.
#>
param(
    [switch]$SelfTest,
    [switch]$TestMode
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$script:Version = '1.2.0'
$script:EnginePath = Join-Path $PSScriptRoot 'codex-mover.ps1'
$script:XamlPath = Join-Path $PSScriptRoot 'CodexMover-GUI.xaml'
$script:Window = $null
$script:running = $false
$script:IsRestore = $false
$script:IsDryRun = $false
$script:EngineProcess = $null
$script:ControlNames = @(
    'SrcList','TxtCustom','BtnRefresh','BtnAdd',
    'DriveCombo','FolderBox','LblRoot',
    'CbBackup','CbAutoClose','CbDryRun',
    'BtnGo','BtnRestore','BtnExit',
    'LogBox','StatusText','StatusChip','ProgressBar'
)

function Get-DefaultSources {
    $specs = @(
        @{ Path = Join-Path $env:USERPROFILE '.codex'; Name = '.codex' }
        @{ Path = Join-Path $env:USERPROFILE '.cache\codex-runtimes'; Name = 'codex-runtimes' }
        @{ Path = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'; Name = 'OpenAI-Codex-Local' }
        @{ Path = Join-Path $env:APPDATA 'Codex'; Name = 'Codex-Roaming' }
        @{ Path = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex'; Name = 'Documents-Codex' }
    )
    $result = @()
    foreach ($s in $specs) {
        $sizeMB = $null
        $exists = $false
        $isJunction = $false
        $item = Get-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue
        if ($item) {
            $exists = $true
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $isJunction = $true }
            $bytes = (Get-ChildItem -LiteralPath $s.Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($bytes) { $sizeMB = [math]::Round($bytes / 1MB, 1) }
        }
        $state = if (-not $exists) { '不存在' } elseif ($isJunction) { '已迁移(联接)' } else { ('{0} MB' -f $sizeMB) }
        $obj = [PSCustomObject]@{
            Path = $s.Path
            Name = $s.Name
            Exists = $exists
            IsJunction = $isJunction
            SizeMB = $sizeMB
            Label = ('{0}   [{1}]' -f $s.Path, $state)
        }
        $result += $obj
    }
    return $result
}

function Get-FixedDrives {
    return @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed } | ForEach-Object {
        [PSCustomObject]@{
            Root = $_.Name
            FreeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1)
            TotalGB = [math]::Round($_.TotalSize / 1GB, 1)
            Label = ('{0}  (free {1} GB / {2} GB)' -f $_.Name, [math]::Round($_.AvailableFreeSpace / 1GB, 1), [math]::Round($_.TotalSize / 1GB, 1))
        }
    })
}

function Load-Window {
    if (-not (Test-Path -LiteralPath $script:XamlPath)) {
        throw "找不到界面文件: $($script:XamlPath)"
    }
    $stream = [System.IO.File]::OpenRead($script:XamlPath)
    try {
        $script:Window = [System.Windows.Markup.XamlReader]::Load($stream)
    } finally {
        $stream.Close()
    }
    if (-not $script:Window) { throw 'XAML 加载失败: XamlReader 返回空对象' }
    foreach ($n in $script:ControlNames) {
        $ctl = $script:Window.FindName($n)
        if (-not $ctl) { throw "XAML 缺少控件: $n" }
        Set-Variable -Name $n -Value $ctl -Scope Script
    }
    $iconPath = Join-Path $PSScriptRoot 'assets\app-icon.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try {
            $uri = New-Object System.Uri($iconPath, [System.UriKind]::Absolute)
            $bi = New-Object System.Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = $uri
            $bi.EndInit()
            $script:Window.Icon = $bi
        } catch {
            # icon is cosmetic; ignore failures
        }
    }
}

function Append-Log {
    param([string]$Text)
    if (-not $script:LogBox) { return }
    if ($script:LogBox.Dispatcher.CheckAccess()) {
        $script:LogBox.AppendText($Text + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
    } else {
        $script:LogBox.Dispatcher.Invoke([Action[string]]{
            param($t)
            $script:LogBox.AppendText($t + [Environment]::NewLine)
            $script:LogBox.ScrollToEnd()
        }, $Text) | Out-Null
    }
}

function Set-Status {
    param([string]$Text, [string]$Kind = 'ok')
    $map = @{ ok = 'SuccessBrush'; run = 'AccentBrush'; err = 'DangerBrush'; warn = 'WarnBrush' }
    $key = if ($map.ContainsKey($Kind)) { $map[$Kind] } else { 'TextSecondaryBrush' }
    $brush = $script:Window.TryFindResource($key)
    if (-not $brush) { $brush = $script:Window.TryFindResource('TextSecondaryBrush') }
    $chipBg = $brush.Clone()
    $chipBg.Opacity = 0.18
    $script:StatusText.Text = $Text
    $script:StatusText.Foreground = $brush
    $script:StatusChip.Background = $chipBg
}

function Set-ProgressState {
    param([bool]$Visible)
    $script:ProgressBar.Visibility = if ($Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function Update-RootPreview {
    $root = ''
    if ($script:DriveCombo.SelectedItem) { $root = $script:DriveCombo.SelectedItem.Root.TrimEnd('\') }
    $folder = $script:FolderBox.Text.Trim()
    if ($root -and $folder) { $script:LblRoot.Text = ('迁移目标: {0}\{1}' -f $root, $folder) } else { $script:LblRoot.Text = '迁移目标: (请选择盘符和文件夹)' }
}

function New-SourceCheckBox {
    param($Source, [bool]$Checked)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Source.Label
    $cb.Tag = $Source
    $cb.IsChecked = $Checked
    $cb.FontSize = 13
    $cb.Foreground = $script:Window.TryFindResource('TextPrimaryBrush')
    $cb.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
    $cb.Cursor = [System.Windows.Input.Cursors]::Hand
    return $cb
}

function Refresh-Sources {
    $checkedPaths = @($script:SrcList.Items | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { $_.Tag.Path })
    $script:SrcList.Items.Clear()
    foreach ($s in (Get-DefaultSources)) {
        $checked = ($checkedPaths -contains $s.Path) -or ($s.Exists -and -not $s.IsJunction)
        [void]$script:SrcList.Items.Add((New-SourceCheckBox -Source $s -Checked $checked))
    }
}

function Set-ControlsEnabled {
    param([bool]$Enabled)
    $script:BtnGo.IsEnabled = $Enabled
    $script:BtnRestore.IsEnabled = $Enabled
    $script:BtnRefresh.IsEnabled = $Enabled
    $script:BtnAdd.IsEnabled = $Enabled
    $script:SrcList.IsEnabled = $Enabled
    $script:DriveCombo.IsEnabled = $Enabled
    $script:FolderBox.IsEnabled = $Enabled
    $script:CbBackup.IsEnabled = $Enabled
    $script:CbAutoClose.IsEnabled = $Enabled
    $script:CbDryRun.IsEnabled = $Enabled
}

function Build-SourcesFile {
    $map = @{}
    foreach ($item in $script:SrcList.Items) {
        if ($item.IsChecked -eq $true) { $map[$item.Tag.Path] = $item.Tag.Name }
    }
    if ($map.Count -eq 0) { return $null }
    $jsonPath = Join-Path $env:TEMP ('codexmover-sources-{0}.json' -f $PID)
    $map | ConvertTo-Json | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    return $jsonPath
}

function Complete-Run {
    param([int]$ExitCode)
    $script:running = $false
    Set-ControlsEnabled $true
    Set-ProgressState $false
    if ($ExitCode -eq 0) {
        Set-Status '完成' 'ok'
        if (-not $script:IsRestore -and -not $script:IsDryRun) {
            [System.Windows.MessageBox]::Show('迁移完成。可以重新打开 Codex 了。' + [Environment]::NewLine + '备份保留在目标盘 _backup-* 文件夹中。', '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    } else {
        Set-Status '未完成，请查看日志' 'err'
        [System.Windows.MessageBox]::Show('迁移未完成（退出码 ' + $ExitCode + '）。' + [Environment]::NewLine + '数据没有丢失，请查看日志。', '注意', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
}

function Invoke-EngineAsync {
    param([string]$ArgumentList)
    Append-Log ''
    Append-Log ('> codex-mover.ps1 ' + $ArgumentList)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:EnginePath + '" ' + $ArgumentList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    $outEvt = {
        param($s, $e)
        try {
            if ($e.Data) { Append-Log $e.Data }
        } catch { }
    }
    $errEvt = {
        param($s, $e)
        try {
            if ($e.Data) { Append-Log ('[ERR] ' + $e.Data) }
        } catch { }
    }
    $exitEvt = {
        try {
            $code = -1
            try {
                $proc.WaitForExit()
                $code = $proc.ExitCode
            } catch {
                $code = -1
            }
            if ($script:Window) {
                $script:Window.Dispatcher.Invoke([Action[int]]{
                    param($c)
                    Complete-Run -ExitCode $c
                }, $code) | Out-Null
            }
        } catch { }
    }
    $proc.add_OutputDataReceived($outEvt)
    $proc.add_ErrorDataReceived($errEvt)
    $proc.add_Exited($exitEvt)
    try {
        $script:EngineProcess = $proc
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
    } catch {
        Append-Log ('启动失败: ' + $_.Exception.Message)
        Set-Status '未完成，请查看日志' 'err'
        Set-ControlsEnabled $true
        Set-ProgressState $false
        $script:running = $false
    }
}

function Start-Migration {
    param([bool]$AsRestore)
    try {
        if ($script:running) { return }
        if (-not (Test-Path -LiteralPath $script:EnginePath)) {
            [System.Windows.MessageBox]::Show('找不到引擎脚本 codex-mover.ps1', '错误', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            return
        }
        $root = ''
        if ($script:DriveCombo.SelectedItem) { $root = $script:DriveCombo.SelectedItem.Root.TrimEnd('\') }
        $folder = $script:FolderBox.Text.Trim()
        if (-not $root -or -not $folder) {
            [System.Windows.MessageBox]::Show('请先选择目标盘并填写文件夹名', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
        $targetRoot = '{0}\{1}' -f $root, $folder

        if (-not $AsRestore) {
            $jsonPath = Build-SourcesFile
            if (-not $jsonPath) {
                [System.Windows.MessageBox]::Show('请至少勾选一个要迁移的目录', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
            if (-not $script:CbDryRun.IsChecked) {
                $answer = [System.Windows.MessageBox]::Show('确定开始迁移到 ' + $targetRoot + ' 吗？' + [Environment]::NewLine + '请确认已完全退出 Codex（或已勾选自动关闭）。', '确认', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
                if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            $args = '-TargetRoot "' + $targetRoot + '" -SourcesFile "' + $jsonPath + '"'
            if (-not $script:CbBackup.IsChecked) { $args += ' -Backup:$false' }
            if ($script:CbAutoClose.IsChecked) { $args += ' -AutoCloseYes' }
            if ($script:CbDryRun.IsChecked) { $args += ' -DryRun -SkipProcessCheck' }
        } else {
            $answer = [System.Windows.MessageBox]::Show('确定要从 ' + $targetRoot + ' 的最新备份恢复吗？', '确认', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
            $args = '-TargetRoot "' + $targetRoot + '" -Restore'
        }

        if ($TestMode) { $args += ' -SkipProcessCheck' }

        $script:IsRestore = $AsRestore
        $script:IsDryRun = [bool]$script:CbDryRun.IsChecked
        $script:running = $true
        Set-ControlsEnabled $false
        Set-ProgressState $true
        Set-Status '运行中…' 'run'
        Invoke-EngineAsync -ArgumentList $args
    } catch {
        $script:running = $false
        try { Set-ControlsEnabled $true } catch { }
        try { Set-ProgressState $false } catch { }
        [System.Windows.MessageBox]::Show('操作失败: ' + $_.Exception.Message, '错误', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
}

function Init-UI {
    Refresh-Sources
    $script:DriveCombo.Items.Clear()
    foreach ($d in (Get-FixedDrives)) { [void]$script:DriveCombo.Items.Add($d) }
    $systemRoot = (Split-Path -Qualifier $env:SystemDrive).TrimEnd(':')
    for ($i = 0; $i -lt $script:DriveCombo.Items.Count; $i++) {
        if ($script:DriveCombo.Items[$i].Root.TrimEnd('\') -ne $systemRoot) { $script:DriveCombo.SelectedIndex = $i; break }
    }
    if ($script:DriveCombo.SelectedIndex -lt 0 -and $script:DriveCombo.Items.Count -gt 0) { $script:DriveCombo.SelectedIndex = 0 }
    Update-RootPreview
    Set-Status '就绪' 'ok'
}

# ---- SelfTest ----
if ($SelfTest) {
    Write-Host ('Codex Mover GUI v{0} - self test' -f $script:Version)
    try {
        Load-Window
    } catch {
        Write-Host ('FAIL: ' + $_.Exception.Message)
        exit 1
    }
    Write-Host ('XAML    : {0}' -f $script:XamlPath)
    Write-Host ('Engine  : {0}  exists={1}' -f $script:EnginePath, (Test-Path -LiteralPath $script:EnginePath))
    Write-Host 'Controls:'
    foreach ($n in $script:ControlNames) {
        Write-Host ('  {0} = {1}' -f $n, ($null -ne $script:Window.FindName($n)))
    }
    Write-Host 'Sources:'
    foreach ($s in (Get-DefaultSources)) { Write-Host ('  {0}  exists={1} junction={2} size={3}' -f $s.Path, $s.Exists, $s.IsJunction, $s.SizeMB) }
    Write-Host 'Drives:'
    foreach ($d in (Get-FixedDrives)) { Write-Host ('  {0}  free {1} GB / {2} GB' -f $d.Root, $d.FreeGB, $d.TotalGB) }
    Write-Host 'Self test OK.'
    exit 0
}

# ---- main ----
try {
    Load-Window
} catch {
    [System.Windows.MessageBox]::Show('GUI 初始化失败: ' + $_.Exception.Message, '错误', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    exit 1
}

# Global safety net: never let an unhandled exception silently kill the window.
try {
    [System.Windows.Application]::Current.add_DispatcherUnhandledException({
        param($s, $e)
        try {
            $log = Join-Path $env:TEMP ('codexmover-crash-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Add-Content -LiteralPath $log -Value ('UI EXCEPTION: ' + $e.Exception.ToString()) -Encoding UTF8
            [System.Windows.MessageBox]::Show('界面遇到错误，详情已保存到: ' + $log, 'Codex Mover', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        } catch { }
        $e.Handled = $true
    })
} catch { }
try {
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($s, $e)
        try {
            $log = Join-Path $env:TEMP ('codexmover-crash-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Add-Content -LiteralPath $log -Value ('FATAL: ' + $e.ExceptionObject.ToString()) -Encoding UTF8
        } catch { }
    })
} catch { }

$script:BtnGo.Add_Click({ Start-Migration -AsRestore $false })
$script:BtnRestore.Add_Click({ Start-Migration -AsRestore $true })
$script:BtnExit.Add_Click({ $script:Window.Close() })
$script:BtnRefresh.Add_Click({ Refresh-Sources })
$script:BtnAdd.Add_Click({
    $p = $script:TxtCustom.Text.Trim()
    if (-not $p) { return }
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        [System.Windows.MessageBox]::Show('路径不存在: ' + $p, '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    foreach ($existing in $script:SrcList.Items) { if ($existing.Tag.Path -eq $p) { return } }
    $name = Split-Path $p -Leaf
    if (-not $name) { $name = 'custom' }
    $bytes = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $size = if ($bytes) { [math]::Round($bytes / 1MB, 1) } else { 0 }
    $obj = [PSCustomObject]@{ Path = $p; Name = $name; Exists = $true; IsJunction = $false; SizeMB = $size; Label = ('{0}   [{1} MB]' -f $p, $size) }
    [void]$script:SrcList.Items.Add((New-SourceCheckBox -Source $obj -Checked $true))
    $script:TxtCustom.Clear()
})
$script:DriveCombo.Add_SelectionChanged({ Update-RootPreview })
$script:FolderBox.Add_TextChanged({ Update-RootPreview })
$script:Window.Add_Closing({
    param($s, $e)
    if ($script:running) { $e.Cancel = $true }
})
$script:Window.Add_Loaded({ Init-UI })

[void]$script:Window.ShowDialog()
exit 0
