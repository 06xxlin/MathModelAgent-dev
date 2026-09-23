@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>nul
title Publish MathModel dev release

set "HERE=%~dp0"
set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

echo.
echo ============================================================
echo  Build latest.yml and publish a GitHub Release
echo  Repo   : 06xxlin/MathModelAgent-dev
echo  Assets : setup.exe + latest.yml + SHA256SUMS.txt
echo ============================================================
echo.

rem gh must be authenticated for -Upload
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%installer\publish-release.ps1" -Upload %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [X] Failed, exit code %RC%.
  echo     If it says "gh not logged in", run once:  gh auth login
  pause
  exit /b %RC%
)

echo [OK] Release published.
pause
exit /b 0
