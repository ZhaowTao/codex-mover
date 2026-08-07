@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo Starting Codex Mover GUI...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexMover-GUI.ps1" %*
if errorlevel 1 pause
