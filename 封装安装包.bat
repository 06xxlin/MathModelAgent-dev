@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>nul
title MathModel Dev Setup Builder

set "HERE=%~dp0"
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

echo.
echo ============================================================
echo  Package the patched MathModel install into a setup .exe
echo  Package : %HERE%
echo  Output  : %HERE%dist\MathModel-^<version^>-dev-Setup.exe
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%installer\make-setup.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [X] Failed, exit code %RC%. See messages above.
  pause
  exit /b %RC%
)

echo [OK] Setup package built. Opening the dist folder...
start "" "%HERE%dist"
pause
exit /b 0
