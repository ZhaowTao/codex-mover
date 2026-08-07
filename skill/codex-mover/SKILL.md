---
name: codex-mover
description: "Migrate Codex data and workspace folders (config, sessions, logs, skills, plugin caches, auth, Documents\\Codex projects) off a full C: drive to another Windows drive using directory junctions, with backup, verification, and rollback. Use when a user reports low disk space caused by Codex, asks to move or relocate Codex data or ~/.codex to another drive, or wants Codex storage outside C:. Windows only; on macOS/Linux use the CODEX_HOME environment variable instead."
---

# Codex Mover

## Overview

Relocate Codex's data folders and the desktop workspace (default: `~/.codex`,
`~/.cache/codex-runtimes`, `%LOCALAPPDATA%\OpenAI\Codex`, `%APPDATA%\Codex`,
`%USERPROFILE%\Documents\Codex`) to another drive. The original C: paths stay valid as
directory junctions, so Codex keeps working without any configuration change.

## Prerequisites

- Windows only. On macOS/Linux, set `CODEX_HOME` instead; do not use junctions there.
- Codex must be fully closed, including the tray icon. The script aborts if Codex
  processes are running; use `-AutoClose` only after telling the user the app will close.
- The target drive must be a fixed NTFS drive with enough free space (the script
  requires about 2.2x the total data size for copy + backup).

## Workflow

1. Inspect the user's Codex data and disk state (folder sizes, free space). Default sources:
   - `%USERPROFILE%\.codex`
   - `%USERPROFILE%\.cache\codex-runtimes`
   - `%LOCALAPPDATA%\OpenAI\Codex`
   - `%APPDATA%\Codex`
   - `%USERPROFILE%\Documents\Codex` (desktop app project workspace; skip if the user
     does not use the desktop app or does not want their documents moved)
2. Confirm the target drive with the user.
3. Run a dry run first:

   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/codex-mover.ps1 -TargetRoot <G:\CodexData> -DryRun`
4. Run the migration:

   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/codex-mover.ps1 -TargetRoot <G:\CodexData>`
5. Verify the junctions:

   `Get-Item <source> | Format-List LinkType,Target` - expect `LinkType : Junction`
   and a `Target` on the destination drive.
6. Keep the `_backup-*` folders under the target root until the user confirms Codex
   works normally for a few days.

## Safety rules

- Never delete a source folder before a verified copy exists. The script renames the
  original first and only releases it after the backup copy is verified.
- On any failure, roll back: remove the junction and restore the original folder.
- If a source folder has fewer files than the most recent backup (interrupted run),
  repair it from the backup before migrating (copy-only, never delete).
- A leftover `*.pre-migration-*` folder after a successful migration is harmless
  (Codex uses the junction). Clean it up later or on a later run.
- The desktop app ignores `CODEX_HOME`; directory junctions are the Windows workaround.
  See [references/troubleshooting.md](references/troubleshooting.md) for details.

## Troubleshooting

See [references/troubleshooting.md](references/troubleshooting.md) for failure modes:
locked files, delete-pending handles, process detection, restore, and verification.
