@echo off
setlocal EnableExtensions
chcp 65001 >nul 2>nul
title Install auto-patch scheduled task

set "HERE=%~dp0"
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

echo.
echo ============================================================
echo  Install scheduled task: auto rebuild dev patch on update
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\install-auto-task.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [X] Failed, exit code %RC%.
  echo     If it says Access denied, right-click this .bat and choose "Run as administrator".
) else (
  echo [OK] Scheduled task installed.
)
echo.
pause
exit /b %RC%
