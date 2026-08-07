#Requires -Version 5.0
param(
    [switch]$SelfTest
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Version = '1.1.0'
$script:EnginePath = Join-Path $PSScriptRoot 'codex-mover.ps1'
$script:running = $false

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
        $obj | Add-Member -Force -MemberType ScriptMethod -Name ToString -Value { $this.Label }
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

if ($SelfTest) {
    Write-Host ('Codex Mover GUI v{0} - self test' -f $script:Version)
    Write-Host ('Engine: {0}  exists={1}' -f $script:EnginePath, (Test-Path -LiteralPath $script:EnginePath))
    Write-Host 'Sources:'
    foreach ($s in (Get-DefaultSources)) { Write-Host ('  {0}  exists={1} junction={2} size={3}' -f $s.Path, $s.Exists, $s.IsJunction, $s.SizeMB) }
    Write-Host 'Drives:'
    foreach ($d in (Get-FixedDrives)) { Write-Host ('  {0}  free {1} GB / {2} GB' -f $d.Root, $d.FreeGB, $d.TotalGB) }
    Write-Host 'Self test OK.'
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = ('Codex Mover 图形向导 v{0}' -f $script:Version)
$form.Size = New-Object System.Drawing.Size(800, 700)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false

# ---- 1. Sources ----
$grpSrc = New-Object System.Windows.Forms.GroupBox
$grpSrc.Text = '1. 选择要迁移的目录'
$grpSrc.Location = New-Object System.Drawing.Point(12, 12)
$grpSrc.Size = New-Object System.Drawing.Size(520, 250)
$form.Controls.Add($grpSrc)

$srcList = New-Object System.Windows.Forms.CheckedListBox
$srcList.Location = New-Object System.Drawing.Point(12, 24)
$srcList.Size = New-Object System.Drawing.Size(380, 160)
$grpSrc.Controls.Add($srcList)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新大小'
$btnRefresh.Location = New-Object System.Drawing.Point(400, 24)
$btnRefresh.Size = New-Object System.Drawing.Size(105, 30)
$grpSrc.Controls.Add($btnRefresh)

$txtCustom = New-Object System.Windows.Forms.TextBox
$txtCustom.Location = New-Object System.Drawing.Point(12, 192)
$txtCustom.Size = New-Object System.Drawing.Size(380, 24)
$grpSrc.Controls.Add($txtCustom)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = '添加自定义目录'
$btnAdd.Location = New-Object System.Drawing.Point(400, 190)
$btnAdd.Size = New-Object System.Drawing.Size(105, 30)
$grpSrc.Controls.Add($btnAdd)

$lblSrcHint = New-Object System.Windows.Forms.Label
$lblSrcHint.Text = '勾选要迁移的目录；已迁移的会显示"联接"，可取消勾选。'
$lblSrcHint.Location = New-Object System.Drawing.Point(12, 222)
$lblSrcHint.Size = New-Object System.Drawing.Size(496, 20)
$grpSrc.Controls.Add($lblSrcHint)

# ---- 2. Target ----
$grpTgt = New-Object System.Windows.Forms.GroupBox
$grpTgt.Text = '2. 选择目标位置'
$grpTgt.Location = New-Object System.Drawing.Point(12, 270)
$grpTgt.Size = New-Object System.Drawing.Size(520, 130)
$form.Controls.Add($grpTgt)

$lblDrive = New-Object System.Windows.Forms.Label
$lblDrive.Text = '目标盘'
$lblDrive.Location = New-Object System.Drawing.Point(12, 28)
$lblDrive.Size = New-Object System.Drawing.Size(70, 24)
$grpTgt.Controls.Add($lblDrive)

$driveCombo = New-Object System.Windows.Forms.ComboBox
$driveCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$driveCombo.Location = New-Object System.Drawing.Point(90, 25)
$driveCombo.Size = New-Object System.Drawing.Size(410, 26)
$grpTgt.Controls.Add($driveCombo)

$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = '文件夹'
$lblFolder.Location = New-Object System.Drawing.Point(12, 62)
$lblFolder.Size = New-Object System.Drawing.Size(70, 24)
$grpTgt.Controls.Add($lblFolder)

$folderBox = New-Object System.Windows.Forms.TextBox
$folderBox.Text = 'CodexData'
$folderBox.Location = New-Object System.Drawing.Point(90, 60)
$folderBox.Size = New-Object System.Drawing.Size(410, 24)
$grpTgt.Controls.Add($folderBox)

$lblRoot = New-Object System.Windows.Forms.Label
$lblRoot.Location = New-Object System.Drawing.Point(12, 96)
$lblRoot.Size = New-Object System.Drawing.Size(496, 22)
$grpTgt.Controls.Add($lblRoot)

# ---- 3. Options ----
$grpOpt = New-Object System.Windows.Forms.GroupBox
$grpOpt.Text = '3. 选项'
$grpOpt.Location = New-Object System.Drawing.Point(12, 408)
$grpOpt.Size = New-Object System.Drawing.Size(520, 110)
$form.Controls.Add($grpOpt)

$cbBackup = New-Object System.Windows.Forms.CheckBox
$cbBackup.Text = '保留完整备份（推荐）'
$cbBackup.Checked = $true
$cbBackup.Location = New-Object System.Drawing.Point(20, 30)
$cbBackup.Size = New-Object System.Drawing.Size(220, 26)
$grpOpt.Controls.Add($cbBackup)

$cbAutoClose = New-Object System.Windows.Forms.CheckBox
$cbAutoClose.Text = '自动关闭正在运行的 Codex'
$cbAutoClose.Location = New-Object System.Drawing.Point(20, 62)
$cbAutoClose.Size = New-Object System.Drawing.Size(240, 26)
$grpOpt.Controls.Add($cbAutoClose)

$cbDryRun = New-Object System.Windows.Forms.CheckBox
$cbDryRun.Text = '演练模式（不修改任何东西）'
$cbDryRun.Location = New-Object System.Drawing.Point(260, 30)
$cbDryRun.Size = New-Object System.Drawing.Size(240, 26)
$grpOpt.Controls.Add($cbDryRun)

# ---- 4. Action buttons ----
$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Text = '开始迁移'
$btnGo.Location = New-Object System.Drawing.Point(548, 20)
$btnGo.Size = New-Object System.Drawing.Size(220, 44)
$btnGo.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnGo.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnGo)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = '回滚 / 恢复'
$btnRestore.Location = New-Object System.Drawing.Point(548, 72)
$btnRestore.Size = New-Object System.Drawing.Size(220, 40)
$form.Controls.Add($btnRestore)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = '退出'
$btnExit.Location = New-Object System.Drawing.Point(548, 120)
$btnExit.Size = New-Object System.Drawing.Size(220, 40)
$form.Controls.Add($btnExit)

# ---- 5. Log ----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '运行日志'
$lblLog.Location = New-Object System.Drawing.Point(12, 528)
$lblLog.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($lblLog)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$logBox.Location = New-Object System.Drawing.Point(12, 550)
$logBox.Size = New-Object System.Drawing.Size(756, 100)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($logBox)

$statusBar = New-Object System.Windows.Forms.Label
$statusBar.Location = New-Object System.Drawing.Point(12, 655)
$statusBar.Size = New-Object System.Drawing.Size(756, 22)
$statusBar.Text = '就绪'
$form.Controls.Add($statusBar)

$script:srcList = $srcList
$script:logBox = $logBox

function Append-Log {
    param([string]$Text)
    if ($script:logBox.IsHandleCreated) {
        $script:logBox.Invoke([Action[string]]{
            param($t)
            $script:logBox.AppendText($t + [Environment]::NewLine)
            $script:logBox.SelectionStart = $script:logBox.TextLength
            $script:logBox.ScrollToCaret()
        }, $Text) | Out-Null
    }
}

function Set-Status {
    param([string]$Text)
    $statusBar.Text = $Text
}

function Update-RootPreview {
    $root = ''
    if ($driveCombo.SelectedItem) { $root = $driveCombo.SelectedItem.Root.TrimEnd('\') }
    $folder = $folderBox.Text.Trim()
    if ($root -and $folder) { $lblRoot.Text = ('迁移目标: {0}\{1}' -f $root, $folder) } else { $lblRoot.Text = '迁移目标: (请选择盘符和文件夹)' }
}

function Refresh-Sources {
    $checkedPaths = @($script:srcList.CheckedItems | ForEach-Object { $_.Path })
    $script:srcList.Items.Clear()
    foreach ($s in (Get-DefaultSources)) {
        $checked = ($checkedPaths -contains $s.Path) -or ($s.Exists -and -not $s.IsJunction)
        $script:srcList.Items.Add($s, $checked) | Out-Null
    }
}

function Invoke-Engine {
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
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Append-Log ('启动失败: ' + $_.Exception.Message)
        return 1
    }
    $outEvt = { param($s, $e) if ($e.Data) { Append-Log $e.Data } }
    $errEvt = { param($s, $e) if ($e.Data) { Append-Log ('[ERR] ' + $e.Data) } }
    $proc.add_OutputDataReceived($outEvt)
    $proc.add_ErrorDataReceived($errEvt)
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Set-ControlsEnabled {
    param([bool]$Enabled)
    $btnGo.Enabled = $Enabled
    $btnRestore.Enabled = $Enabled
    $btnRefresh.Enabled = $Enabled
    $btnAdd.Enabled = $Enabled
    $srcList.Enabled = $Enabled
    $driveCombo.Enabled = $Enabled
    $folderBox.Enabled = $Enabled
    $cbBackup.Enabled = $Enabled
    $cbAutoClose.Enabled = $Enabled
    $cbDryRun.Enabled = $Enabled
}

function Build-SourcesFile {
    $map = @{}
    foreach ($item in $script:srcList.CheckedItems) { $map[$item.Path] = $item.Name }
    if ($map.Count -eq 0) { return $null }
    $jsonPath = Join-Path $env:TEMP ('codexmover-sources-{0}.json' -f $PID)
    $map | ConvertTo-Json | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    return $jsonPath
}

function Start-Migration {
    param([bool]$AsRestore)
    if ($script:running) { return }
    if (-not (Test-Path -LiteralPath $script:EnginePath)) {
        [System.Windows.Forms.MessageBox]::Show('找不到引擎脚本 codex-mover.ps1', '错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $root = ''
    if ($driveCombo.SelectedItem) { $root = $driveCombo.SelectedItem.Root.TrimEnd('\') }
    $folder = $folderBox.Text.Trim()
    if (-not $root -or -not $folder) {
        [System.Windows.Forms.MessageBox]::Show('请先选择目标盘并填写文件夹名', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $targetRoot = '{0}\{1}' -f $root, $folder

    if (-not $AsRestore) {
        $jsonPath = Build-SourcesFile
        if (-not $jsonPath) {
            [System.Windows.Forms.MessageBox]::Show('请至少勾选一个要迁移的目录', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not $cbDryRun.Checked) {
            $answer = [System.Windows.Forms.MessageBox]::Show('确定开始迁移到 ' + $targetRoot + ' 吗？' + [Environment]::NewLine + '请确认已完全退出 Codex（或已勾选自动关闭）。', '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $args = '-TargetRoot "' + $targetRoot + '" -SourcesFile "' + $jsonPath + '"'
        if (-not $cbBackup.Checked) { $args += ' -Backup:$false' }
        if ($cbAutoClose.Checked) { $args += ' -AutoCloseYes' }
        if ($cbDryRun.Checked) { $args += ' -DryRun' }
    } else {
        $answer = [System.Windows.Forms.MessageBox]::Show('确定要从 ' + $targetRoot + ' 的最新备份恢复吗？', '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $args = '-TargetRoot "' + $targetRoot + '" -Restore'
    }

    $script:running = $true
    Set-ControlsEnabled $false
    Set-Status '运行中...'
    $code = Invoke-Engine $args
    $script:running = $false
    Set-ControlsEnabled $true
    if ($code -eq 0) {
        Set-Status '完成'
        if (-not $AsRestore -and -not $cbDryRun.Checked) {
            [System.Windows.Forms.MessageBox]::Show('迁移完成。可以重新打开 Codex 了。' + [Environment]::NewLine + '备份保留在目标盘 _backup-* 文件夹中。', '完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    } else {
        Set-Status '未完成，请查看日志'
        [System.Windows.Forms.MessageBox]::Show('迁移未完成（退出码 ' + $code + '）。' + [Environment]::NewLine + '数据没有丢失，请查看日志。', '注意', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

$btnGo.Add_Click({ Start-Migration -AsRestore $false })
$btnRestore.Add_Click({ Start-Migration -AsRestore $true })
$btnExit.Add_Click({ $form.Close() })
$btnRefresh.Add_Click({ Refresh-Sources })
$btnAdd.Add_Click({
    $p = $txtCustom.Text.Trim()
    if (-not $p) { return }
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        [System.Windows.Forms.MessageBox]::Show('路径不存在: ' + $p, '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    foreach ($existing in $script:srcList.Items) { if ($existing.Path -eq $p) { return } }
    $name = Split-Path $p -Leaf
    if (-not $name) { $name = 'custom' }
    $bytes = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $size = if ($bytes) { [math]::Round($bytes / 1MB, 1) } else { 0 }
    $obj = [PSCustomObject]@{ Path = $p; Name = $name; Exists = $true; IsJunction = $false; SizeMB = $size; Label = ('{0}   [{1} MB]' -f $p, $size) }
    $obj | Add-Member -Force -MemberType ScriptMethod -Name ToString -Value { $this.Label }
    $idx = $script:srcList.Items.Add($obj, $true)
    $txtCustom.Clear()
})
$driveCombo.Add_SelectedIndexChanged({ Update-RootPreview })
$folderBox.Add_TextChanged({ Update-RootPreview })
$form.Add_FormClosing({
    param($s, $e)
    if ($script:running) { $e.Cancel = $true }
})

$form.Add_Shown({
    Refresh-Sources
    foreach ($d in (Get-FixedDrives)) { $driveCombo.Items.Add($d) | Out-Null }
    $systemRoot = (Split-Path -Qualifier $env:SystemDrive).TrimEnd(':')
    for ($i = 0; $i -lt $driveCombo.Items.Count; $i++) {
        if ($driveCombo.Items[$i].Root.TrimEnd('\') -ne $systemRoot) { $driveCombo.SelectedIndex = $i; break }
    }
    if ($driveCombo.SelectedIndex -lt 0 -and $driveCombo.Items.Count -gt 0) { $driveCombo.SelectedIndex = 0 }
    Update-RootPreview
})

[System.Windows.Forms.Application]::Run($form)
exit 0
