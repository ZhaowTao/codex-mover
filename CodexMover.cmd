@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ================================================
echo   Codex Mover v1.1.0 - portable edition
echo   Move Codex data off a full drive to another disk
echo ================================================
echo.
echo  IMPORTANT: fully quit the Codex app first
echo  (including the system tray icon).
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-mover.ps1" -Interactive %*
set EXITCODE=%ERRORLEVEL%
echo.
if "%EXITCODE%"=="0" (
  echo [OK] Done. You can start Codex again.
) else (
  echo [NOT OK] See the messages above. Your data was NOT deleted;
  echo backups and logs are kept on the target drive.
)
echo.
pause
exit /b %EXITCODE%
