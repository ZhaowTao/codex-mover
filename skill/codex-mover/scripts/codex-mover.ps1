#Requires -Version 5.0
<#
.SYNOPSIS
  Codex Mover - migrate Codex data and workspace folders off a full drive to another
  drive using directory junctions, with backup, verification, and rollback.

.DESCRIPTION
  For each source folder this script:
    1. Copies it to <TargetRoot>\<name> using robocopy.
    2. Verifies the copy (item count, total bytes, reverse robocopy diff).
    3. Renames the original folder (safe and recoverable) instead of deleting it.
    4. Creates a directory junction at the original C: path pointing to the new location.
    5. Verifies the junction and that data is readable through it.
    6. Copies the renamed original into <TargetRoot>\_backup-<timestamp>\<name> as a backup,
       verifies that backup, and only then releases the C: copy.

  The Codex app keeps working because the original C: paths stay valid - they now
  transparently point to the destination drive.

  The script REFUSES to run while any Codex process is running. Fully quit the app
  (check the system tray too) before running it.

.PARAMETER TargetRoot
  Root folder on the destination drive, e.g. G:\CodexData. Empty by default;
  use -Interactive to pick a drive interactively.

.PARAMETER Sources
  Hashtable mapping source path -> destination folder name. Defaults to the Codex
  data folders plus the Codex workspace folder on C:.

.PARAMETER Backup
  Keep a verified backup of the original data on the target drive. Default: on.

.PARAMETER DryRun
  Print the plan without changing anything.

.PARAMETER Restore
  Undo a previous migration: remove the junctions and move data back from the most
  recent backup under TargetRoot.

.PARAMETER SkipProcessCheck
  Testing only. Skips the check that Codex is not running.

.PARAMETER AutoClose
  When Codex is still running, ask for confirmation and close the Codex processes
  automatically before migrating.

.PARAMETER AutoCloseYes
  Like -AutoClose but without the confirmation prompt (used by the GUI, where the
  user already consented).

.PARAMETER SourcesFile
  Path to a JSON file mapping source paths to destination folder names, e.g.
  {"C:\\Users\\me\\.codex": ".codex"}. Overrides -Sources.

.PARAMETER Interactive
  Ask for the target drive and folder interactively when -TargetRoot is not given.

.PARAMETER Version
  Print the version and exit.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\codex-mover.ps1 -Interactive

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\codex-mover.ps1 -TargetRoot G:\CodexData -DryRun

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\codex-mover.ps1 -TargetRoot G:\CodexData -Restore
#>
[CmdletBinding()]
param(
    [string]$TargetRoot = '',
    [hashtable]$Sources = @{},
    [switch]$Backup = $true,
    [switch]$DryRun,
    [switch]$Restore,
    [switch]$AutoClose,
    [switch]$AutoCloseYes,
    [switch]$Interactive,
    [switch]$Version,
    [string]$SourcesFile = '',
    [switch]$SkipProcessCheck
)

$ErrorActionPreference = 'Stop'
$script:CodexMoverVersion = '1.1.0'
$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogPath = $null
$script:Ok = @()
$script:Fail = @()

if ($Version) {
    Write-Host ('Codex Mover v{0}' -f $script:CodexMoverVersion)
    Write-Host 'Migrate Codex data (config, sessions, logs, skills, plugin caches) off a full drive.'
    exit 0
}

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($script:LogPath) {
        $logDir = Split-Path $script:LogPath -Parent
        if (Test-Path -LiteralPath $logDir) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
    }
}

function Get-FolderItemCount {
    param([string]$Path)
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Get-FolderSizeBytes {
    param([string]$Path)
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
}

function Copy-Folder {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $argList = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
    & robocopy @argList | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit code $LASTEXITCODE)" }
}

function Test-FoldersIdentical {
    param([string]$Source, [string]$Destination)
    $srcCount = Get-FolderItemCount $Source
    $dstCount = Get-FolderItemCount $Destination
    if ($srcCount -ne $dstCount) {
        Write-Log "  count mismatch: source=$srcCount target=$dstCount"
        return $false
    }
    $srcBytes = Get-FolderSizeBytes $Source
    $dstBytes = Get-FolderSizeBytes $Destination
    if ($srcBytes -ne $dstBytes) {
        Write-Log "  byte mismatch: source=$srcBytes target=$dstBytes"
        return $false
    }
    $argList = @($Destination, $Source, '/L', '/E', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
    & robocopy @argList | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "verification robocopy failed (exit code $LASTEXITCODE)" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  robocopy reverse diff reports differences (exit code $LASTEXITCODE)"
        return $false
    }
    return $true
}

function New-Junction {
    param([string]$Path, [string]$Target)
    $normPath = $Path.TrimEnd('\')
    $normTarget = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
    try {
        New-Item -ItemType Junction -Path $Path -Target $Target -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "  New-Item junction failed, trying mklink: $($_.Exception.Message)"
        & $env:ComSpec /c "mklink /J `"$normPath`" `"$normTarget`"" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "failed to create junction at $Path" }
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'junction verification failed: not a reparse point' }
    $actual = ([string]$item.Target).TrimEnd('\')
    if ($actual -ne $normTarget) { throw "junction target mismatch: expected $normTarget got $actual" }
}

function Remove-Junction {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return }
    $targetBefore = ([string]$item.Target).TrimEnd('\')
    # Use rmdir, not Remove-Item: PowerShell 5.1 Remove-Item has a known bug
    # (NullReferenceException) on reparse points. rmdir removes only the link.
    & $env:ComSpec /c "rmdir `"$Path`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "failed to remove junction at $Path (rmdir exit code $LASTEXITCODE)" }
    if (Test-Path -LiteralPath $Path) { throw "failed to remove junction at $Path" }
    if ($targetBefore -and -not (Test-Path -LiteralPath $targetBefore)) {
        throw "WARNING: junction target $targetBefore is missing after removing the link"
    }
}

function Get-SourceMap {
    if ($Sources.Count -gt 0) { return $Sources }
    return @{
        (Join-Path $env:USERPROFILE '.codex')                       = '.codex'
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes')        = 'codex-runtimes'
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex')                = 'OpenAI-Codex-Local'
        (Join-Path $env:APPDATA 'Codex')                            = 'Codex-Roaming'
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex') = 'Documents-Codex'
    }
}

function Get-CodexProcesses {
    $result = New-Object System.Collections.Generic.List[object]
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    foreach ($p in $all) {
        $match = $false
        if ($p.ProcessName -match 'codex') { $match = $true }
        if (-not $match) {
            $path = $null
            try { $path = $p.Path } catch { $path = $null }
            if ($path) {
                foreach ($s in $sourceMap.Keys) {
                    $prefix = $s.TrimEnd('\') + '\'
                    if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $match = $true; break }
                }
            }
        }
        if ($match) { $result.Add($p) }
    }
    return @($result | Sort-Object Id -Unique)
}

function Repair-SourceFromBackup {
    param([string]$Source, [string]$Name, [string]$BackupRoot)
    $bak = Join-Path $BackupRoot $Name
    if (-not (Test-Path -LiteralPath $bak)) { return $false }
    $srcProbe = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    $srcCount = if ($srcProbe) { Get-FolderItemCount $Source } else { 0 }
    $bakCount = Get-FolderItemCount $bak
    if ($srcCount -ge $bakCount) { return $false }
    if ($DryRun) {
        Write-Log ("  [DRY RUN] would repair {0}: copy missing files from {1} ({2} vs {3} items)" -f $Source, $bak, $srcCount, $bakCount)
        return $true
    }
    if (-not $srcProbe) { New-Item -ItemType Directory -Path $Source -Force | Out-Null }
    Write-Log ("  REPAIR: source has {0} items, backup has {1} - restoring missing files from {2}" -f $srcCount, $bakCount, $bak)
    $argList = @($bak, $Source, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
    & robocopy @argList | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "repair robocopy failed (exit code $LASTEXITCODE)" }
    Write-Log ("  REPAIR: source now has {0} items" -f (Get-FolderItemCount $Source))
    return $true
}

function Show-Summary {
    Write-Log ''
    Write-Log '===== SUMMARY ====='
    Write-Log ("OK / migrated: {0}" -f $script:Ok.Count)
    foreach ($s in $script:Ok) { Write-Log ("  [OK] {0}" -f $s) }
    if ($script:Fail.Count -gt 0) {
        Write-Log ("FAILED: {0}" -f $script:Fail.Count)
        foreach ($s in $script:Fail) { Write-Log ("  [FAIL] {0}" -f $s) }
        Write-Log 'Some items failed. Nothing was deleted; backups and logs are kept.'
        if ($script:LogPath) { Write-Log ("Log: {0}" -f $script:LogPath) }
        exit 1
    }
    if ($DryRun) {
        Write-Log 'Dry run - no changes were made.'
    } else {
        Write-Log 'All done. You can now start Codex again.'
        if ($script:LogPath) { Write-Log ("Log: {0}" -f $script:LogPath) }
    }
    exit 0
}

Write-Log '=============================================================='
Write-Log (" Codex Mover v{0} - migrate Codex data to another drive" -f $script:CodexMoverVersion)
Write-Log (" Run stamp : {0}" -f $script:RunStamp)
Write-Log '=============================================================='

# Interactive mode: pick the target drive/folder when no -TargetRoot is given.
if ($Interactive -and -not $TargetRoot) {
    $candidates = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq [System.IO.DriveType]::Fixed })
    Write-Log 'Available fixed drives:'
    foreach ($d in $candidates) {
        Write-Log ("  {0}  free {1:N1} GB / {2:N1} GB" -f $d.Name, ($d.AvailableFreeSpace / 1GB), ($d.TotalSize / 1GB))
    }
    $letter = (Read-Host 'Target drive letter (e.g. G)').Trim().TrimEnd(':').ToUpperInvariant()
    if ($letter -notmatch '^[A-Z]$') { Write-Log 'ABORT: invalid drive letter.'; exit 2 }
    $folder = (Read-Host 'Folder name on the target drive (default: CodexData)').Trim()
    if (-not $folder) { $folder = 'CodexData' }
    $TargetRoot = '{0}:\{1}' -f $letter, $folder
}
if (-not $TargetRoot) { Write-Log 'ABORT: no target root. Pass -TargetRoot or use -Interactive.'; exit 2 }
Write-Log (" Target root: {0}" -f $TargetRoot)

# Compute the source map first (the process check below also uses it).
if ($SourcesFile) {
    try {
        $json = Get-Content -Raw -LiteralPath $SourcesFile -ErrorAction Stop | ConvertFrom-Json
        $loadedSources = @{}
        foreach ($prop in $json.PSObject.Properties) { $loadedSources[$prop.Name] = [string]$prop.Value }
        $Sources = $loadedSources
        Write-Log ("Loaded {0} sources from {1}" -f $loadedSources.Count, $SourcesFile)
    } catch {
        Write-Log ("ABORT: cannot read sources file {0}: {1}" -f $SourcesFile, $_.Exception.Message)
        exit 2
    }
}
$sourceMap = Get-SourceMap
if ($sourceMap.Count -eq 0) { Write-Log 'ABORT: no sources to migrate.'; exit 2 }

# 0) Refuse to run while Codex is running (unless -AutoClose is given).
if (-not $SkipProcessCheck) {
    if ($AutoCloseYes) { $AutoClose = $true }
    $codexProcs = @(Get-CodexProcesses)
    if ($codexProcs.Count -gt 0) {
        $names = ($codexProcs | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '
        Write-Log ("Codex is still running: {0}" -f $names)
        Write-Log 'The app often stays in the background (tray icon) even after the window is closed.'
        Write-Log 'Close it in one of these ways:'
        Write-Log '  1) Right-click the Codex icon in the system tray -> Quit/Exit, then run this again.'
        Write-Log '  2) Task Manager (Ctrl+Shift+Esc) -> end the Codex processes, then run this again.'
        Write-Log '  3) Run this script again with -AutoClose to close the processes now (after confirmation).'
        if ($AutoClose) {
            $confirmed = $AutoCloseYes
            if (-not $confirmed) {
                Write-Host ''
                $answer = Read-Host 'Close the running Codex processes now? Type Y to continue, anything else to abort'
                $confirmed = ($answer -match '^[Yy]')
            }
            if ($confirmed) {
                foreach ($proc in $codexProcs) {
                    Write-Log ("  closing process {0} (PID {1})" -f $proc.ProcessName, $proc.Id)
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Seconds 4
                $still = @(Get-CodexProcesses)
                if ($still.Count -gt 0) {
                    Write-Log ("ABORT: some processes could not be closed: {0}" -f (($still | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '))
                    exit 2
                }
                Write-Log 'All Codex processes closed. Continuing with the migration.'
            } else {
                Write-Log 'ABORT: you chose not to close Codex. Run again after closing the app.'
                exit 2
            }
        } else {
            Write-Log 'ABORT: not closing anything automatically. Quit the app, then run this again.'
            exit 2
        }
    }
}

# 1) Target drive checks.
$driveName = (Split-Path -Qualifier $TargetRoot).TrimEnd(':')
if (-not $driveName) { Write-Log 'ABORT: cannot determine the target drive.'; exit 2 }
try {
    $drive = [System.IO.DriveInfo]::new($driveName)
} catch {
    Write-Log ("ABORT: cannot read drive {0}: {1}" -f $driveName, $_.Exception.Message)
    exit 2
}
if (-not $drive.IsReady) { Write-Log ("ABORT: drive {0}: is not ready." -f $driveName); exit 2 }
if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
    Write-Log ("WARNING: drive {0}: is {1} (not a fixed disk). Junctions break when the drive is unavailable." -f $driveName, $drive.DriveType)
}

$totalBytes = 0L
foreach ($s in $sourceMap.Keys) {
    $probe = Get-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue
    if ($probe) { $totalBytes += [long](Get-FolderSizeBytes $s) }
}
$required = [long]($totalBytes * 2.2)
if ($drive.AvailableFreeSpace -lt $required) {
    Write-Log ("ABORT: not enough free space on {0}: need ~{1:N1} GB, available {2:N1} GB." -f $driveName, ($required / 1GB), ($drive.AvailableFreeSpace / 1GB))
    exit 2
}
Write-Log ("Drive {0}: free {1:N1} GB, required ~{2:N1} GB - OK" -f $driveName, ($drive.AvailableFreeSpace / 1GB), ($required / 1GB))
Write-Log ("Total data to migrate: {0:N1} MB" -f ($totalBytes / 1MB))

# 2) Create the target root (not in dry-run mode).
if (-not (Test-Path -LiteralPath $TargetRoot)) {
    if ($DryRun) {
        Write-Log "[DRY RUN] would create $TargetRoot"
    } else {
        New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
        Write-Log "Created $TargetRoot"
    }
}
$script:LogPath = Join-Path $TargetRoot ("migration-{0}.log" -f $script:RunStamp)
if ($DryRun) {
    $script:LogPath = $null
} elseif (Test-Path -LiteralPath $TargetRoot) {
    Add-Content -LiteralPath $script:LogPath -Value ("Run started: {0}" -f $script:RunStamp) -Encoding UTF8
}

# 3) Restore mode: undo a previous migration from the most recent backup.
if ($Restore) {
    $backupDirs = Get-ChildItem -LiteralPath $TargetRoot -Directory -Filter '_backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $backupDirs) { Write-Log 'No backup found under the target root - nothing to restore.'; exit 0 }
    $restoreRoot = $backupDirs[0].FullName
    Write-Log ("Restoring from most recent backup: {0}" -f $restoreRoot)
    foreach ($src in $sourceMap.Keys) {
        $name = $sourceMap[$src]
        $bak = Join-Path $restoreRoot $name
        try {
            if (-not (Test-Path -LiteralPath $bak)) { Write-Log ("SKIP (no backup for): {0}" -f $src); continue }
            if ($DryRun) {
                Write-Log ("[DRY RUN] would restore {0} from {1}" -f $src, $bak)
                continue
            }
            if (Test-ReparsePoint $src) {
                Remove-Junction $src
                Write-Log ("  junction removed: {0}" -f $src)
            }
            $restoreProbe = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            if ($restoreProbe) { throw ("source path still occupied: {0}" -f $src) }
            $argList = @($bak, $src, '/MOVE', '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
            & robocopy @argList | Out-Null
            if ($LASTEXITCODE -ge 8) { throw ("robocopy restore failed (exit code {0})" -f $LASTEXITCODE) }
            if (-not (Test-Path -LiteralPath $src)) { throw 'restore did not produce the source folder' }
            Write-Log ("  restored: {0}" -f $src)
            $script:Ok += $src
        } catch {
            Write-Log ("  FAILED: {0}" -f $_.Exception.Message)
            $script:Fail += $src
        }
    }
    Show-Summary
}

# 4) Migration mode.
$backupRoot = Join-Path $TargetRoot ("_backup-{0}" -f $script:RunStamp)
foreach ($src in $sourceMap.Keys) {
    $name = $sourceMap[$src]
    $target = Join-Path $TargetRoot $name
    $leaf = Split-Path $src -Leaf
    $renamed = Join-Path (Split-Path $src -Parent) ("{0}.pre-migration-{1}" -f $leaf, $script:RunStamp)
    $partialTargetCreated = $false
    try {
        $srcItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        if (-not $srcItem) {
            Write-Log ("SKIP (source missing or not accessible): {0}" -f $src)
            continue
        }
        if ($srcItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Log ("SKIP (already a junction): {0} -> {1}" -f $src, ($srcItem.Target -join '; '))
            $leftovers = @(Get-ChildItem -LiteralPath (Split-Path $src -Parent) -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($leaf + '.pre-migration-*') })
            foreach ($l in $leftovers) {
                if ($DryRun) {
                    Write-Log ("  [DRY RUN] would delete leftover: {0}" -f $l.FullName)
                    continue
                }
                try {
                    Remove-Item -LiteralPath $l.FullName -Recurse -Force
                    Write-Log ("  cleaned leftover from interrupted run: {0}" -f $l.FullName)
                } catch {
                    Write-Log ("  WARNING: could not clean leftover {0}: {1}" -f $l.FullName, $_.Exception.Message)
                }
            }
            continue
        }

        # If this folder was partially damaged by an interrupted run, restore the
        # missing files from the most recent verified backup before migrating.
        $latestBackup = Get-ChildItem -LiteralPath $TargetRoot -Directory -Filter '_backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($latestBackup) {
            try {
                Repair-SourceFromBackup -Source $src -Name $name -BackupRoot $latestBackup.FullName | Out-Null
            } catch {
                Write-Log ("  WARNING: repair step failed: {0}" -f $_.Exception.Message)
            }
        }

        if (Test-Path -LiteralPath $target) { throw ("destination already exists: {0} (refusing to overwrite)" -f $target) }

        $sizeMB = [math]::Round((Get-FolderSizeBytes $src) / 1MB, 1)
        Write-Log ("Migrating {0} ({1} MB) -> {2}" -f $src, $sizeMB, $target)
        if ($DryRun) {
            Write-Log '  [DRY RUN] would: copy -> verify -> rename original -> junction -> backup original'
            continue
        }

        Copy-Folder -Source $src -Destination $target
        $partialTargetCreated = $true
        Write-Log '  copy finished, verifying...'
        if (-not (Test-FoldersIdentical -Source $src -Destination $target)) { throw 'copy verification failed (content mismatch)' }
        Write-Log '  copy verified (identical)'

        Rename-Item -LiteralPath $src -NewName ("{0}.pre-migration-{1}" -f $leaf, $script:RunStamp)
        Write-Log ("  original renamed to: {0}" -f $renamed)

        New-Junction -Path $src -Target $target
        Write-Log ("  junction created: {0} -> {1}" -f $src, $target)

        $sample = Get-ChildItem -LiteralPath $target -Recurse -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sample) {
            $rel = $sample.FullName.Substring($target.Length)
            $through = Join-Path $src $rel
            if (-not (Test-Path -LiteralPath $through)) { throw 'data is not readable through the junction' }
        }

        if ($Backup) {
            $backupDest = Join-Path $backupRoot $name
            Write-Log ("  backing up original to: {0}" -f $backupDest)
            $argList = @($renamed, $backupDest, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
            & robocopy @argList | Out-Null
            if ($LASTEXITCODE -ge 8) { throw ("backup robocopy failed (exit code {0})" -f $LASTEXITCODE) }
            if (-not (Test-FoldersIdentical -Source $renamed -Destination $backupDest)) { throw 'backup verification failed (content mismatch)' }
            Write-Log '  backup verified'
            $released = $false
            for ($try = 1; $try -le 3; $try++) {
                try {
                    Remove-Item -LiteralPath $renamed -Recurse -Force -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $renamed)) { $released = $true; break }
                } catch {
                    Write-Log ("  warning: C: copy cleanup attempt {0}/3 failed: {1}" -f $try, $_.Exception.Message)
                    Start-Sleep -Seconds 3
                }
            }
            if ($released) {
                Write-Log '  backup complete, C: copy released'
            } else {
                Write-Log ("  WARNING: migration is complete, but the C: copy could not be fully released: {0}" -f $renamed)
                Write-Log '  This leftover does not affect Codex (the junction points to G:). It will be cleaned on a later run.'
            }
        } else {
            Remove-Item -LiteralPath $renamed -Recurse -Force
            Write-Log ('  original removed (no backup requested): {0}' -f $renamed)
        }
        $script:Ok += $src
    } catch {
        Write-Log ("  FAILED for {0}: {1}" -f $src, $_.Exception.Message)
        try {
            if (Test-ReparsePoint $src) {
                Remove-Junction $src
                Write-Log '  rollback: junction removed'
            }
            if (Test-Path -LiteralPath $renamed) {
                Rename-Item -LiteralPath $renamed -NewName $leaf
                Write-Log '  rollback: original folder restored'
            }
            if ($partialTargetCreated -and (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $renamed)) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-Log '  rollback: partial target copy removed'
            }
        } catch {
            Write-Log ("  ROLLBACK FAILED: {0}. Manual restore may be needed (see README)." -f $_.Exception.Message)
        }
        $script:Fail += $src
    }
}

Show-Summary
