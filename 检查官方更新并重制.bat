@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>nul
title MathModel Dev Patch - check official update and rebuild

set "HERE=%~dp0"
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

echo.
echo ============================================================
echo  Check official version, rebuild dev patch if needed
echo  Package : %HERE%
echo ============================================================
echo.

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\auto-pipeline.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [X] Failed, exit code %RC%. See messages above.
) else (
  echo [OK] Done. See logs\auto-*.log for details.
)
echo.
pause
exit /b %RC%
