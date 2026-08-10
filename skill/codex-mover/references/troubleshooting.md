# Codex Mover - Troubleshooting

## "Codex is still running" and the script aborts

The Codex desktop app stays in the background (system tray) after the window closes.

- Ask the user to right-click the tray icon -> Quit/Exit, or end the Codex processes in
  Task Manager.
- Or run with `-AutoClose`; the script asks for confirmation, then closes every process
  whose name contains "codex" or whose executable lives under a source folder.
- Verify nothing remains: `Get-Process | Where-Object { $_.ProcessName -match 'codex' }`

## Migration "succeeded" but C: still has a `*.pre-migration-*` folder

A file was left in a "delete-pending" state by a process that was force-closed (example
error: `Could not find a part of the path 'filter_policy.h'`). The file is already gone;
Windows keeps the handle until the owning process exits or the machine reboots.

- It is harmless: Codex uses the junction, not the leftover.
- After a reboot, delete it:
  `Remove-Item -LiteralPath "C:\Users\...\Codex.pre-migration-*" -Recurse -Force`
- A later script run also attempts this cleanup automatically.

## Interrupted run left the source folder incomplete

If cleanup failed mid-way and rollback restored a partially deleted folder, the next run
detects that the source has fewer items than the latest `_backup-*` snapshot and repairs
it automatically (copies the missing files from the backup; never deletes anything).

## "destination already exists" refusal

The script refuses to overwrite an existing destination folder. If a previous partial
copy exists at the destination, remove it manually (the data is safe in the source or in
a verified backup), then re-run.

## Not enough free space

The script needs about 2.2x the total data size (live copy + backup). Free space on the
target drive first, or run without `-Backup` only if the user accepts the risk.

## Restore / roll back

`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/codex-mover.ps1 -TargetRoot <G:\CodexData> -Restore`

This removes the junctions and moves the data back from the most recent `_backup-*` folder.

## Why junctions and not CODEX_HOME

The Windows desktop app stores user data at a hardcoded `%USERPROFILE%\.codex` and ignores
`CODEX_HOME`/`CODEX_DIR` (openai/codex issue #34070). Directory junctions keep the original
paths valid while the data physically lives on another drive. This is the community-verified
workaround; the app does not officially support relocation.

## The desktop workspace (Documents\Codex) is still on C:

The desktop app creates a new project folder under `%USERPROFILE%\Documents\Codex` for
each conversation by default. Migrating that folder with the same junction approach
moves all current and future project files to the destination drive.

- Codex must be fully closed (including tray) before migrating this folder.
- The folder is small, but it grows with every conversation that saves files there.
- If the user opens an explicit folder as their project, that folder can live anywhere;
  only the default `Documents\Codex` workspace is moved by the default source list.

## Verification checklist

- All source paths show `LinkType : Junction` with targets on the destination drive.
- The app launches and reads skills/sessions normally.
- Item counts match between the live destination folder and the `_backup-*` snapshot.

## The WPF GUI (CodexMover-GUI.cmd) does not start

The GUI requires Windows PowerShell 5.1 and .NET Framework 4.x, both present on Windows 10/11.

- Make sure `CodexMover-GUI.xaml` sits next to `CodexMover-GUI.ps1` (they ship in the same folder).
- Launch `CodexMover-GUI.cmd` from Explorer or a console and read the error dialog/console output.
- Do not modify the engine: the GUI only invokes `codex-mover.ps1` in a child process, so a GUI problem
  never affects migration safety.
