@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>nul
title MathModel Dev Patch (one-click)

set "HERE=%~dp0"
set "APPROOT=%~1"

if not "%APPROOT%"=="" goto :have_root
rem default: this package usually sits in <install>\PatchPackage\MathModelAgent-dev
for %%I in ("%HERE%..\..") do set "CAND=%%~fI"
if exist "%CAND%\mathmodel.exe" set "APPROOT=%CAND%"
if "%APPROOT%"=="" if exist "%LOCALAPPDATA%\Programs\@mathmodeldesktop\mathmodel.exe" set "APPROOT=%LOCALAPPDATA%\Programs\@mathmodeldesktop"

:have_root
if "%APPROOT%"=="" (
  echo.
  echo [!] Install folder not found automatically.
  echo     Drag the MathModel install folder onto this .bat, or type the path below.
  echo     Example: C:\Users\lin\AppData\Local\Programs\@mathmodeldesktop
  echo.
  set /p APPROOT=Install folder: 
)

if not exist "%APPROOT%\mathmodel.exe" (
  echo.
  echo [X] mathmodel.exe not found in: %APPROOT%
  echo     Please pass the correct install folder.
  echo.
  pause
  exit /b 1
)

echo.
echo ============================================================
echo  MathModel dev patch (remove login / credits gate)
echo  Install : %APPROOT%
echo  Package : %HERE%
echo ============================================================
echo.

set "PSEXE=powershell"
where pwsh >nul 2>nul && set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tools\apply-dev.ps1" -AppRoot "%APPROOT%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo [X] Failed, exit code %RC%. See messages above.
  pause
  exit /b %RC%
)

echo [OK] Patched. Launching now...
start "" "%APPROOT%\mathmodel.exe"
timeout /t 3 >nul
exit /b 0
