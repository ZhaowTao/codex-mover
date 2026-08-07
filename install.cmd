@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
set "SKILLSRC=%~dp0skill\codex-mover"
set "SKILLDEST=%USERPROFILE%\.codex\skills\codex-mover"

echo ================================================
echo   Codex Mover v1.1.0 - installer
echo ================================================
echo.
echo Installing codex-mover skill to %SKILLDEST% ...
if not exist "%USERPROFILE%\.codex\skills" mkdir "%USERPROFILE%\.codex\skills"
robocopy "%SKILLSRC%" "%SKILLDEST%" /E /NFL /NDL /NP /NJH /NJS
if %ERRORLEVEL% GEQ 8 (echo [ERROR] skill copy reported errors) else (echo [OK] skill installed)
echo.
echo The portable app already lives in: %~dp0
echo   GUI    : CodexMover-GUI.cmd
echo   Console: CodexMover.cmd
echo.
echo Restart Codex to pick up the new skill.
echo.
pause
