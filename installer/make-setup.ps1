# make-setup.ps1 — 把「已打好开发版的安装目录」封装成一个单文件 setup 安装包（NSIS）
#
# 用法:
#   .\installer\make-setup.ps1                       # 自动找安装目录 + 版本
#   .\installer\make-setup.ps1 -AppRoot "D:\xx\mathmodel"
#   .\installer\make-setup.ps1 -Version 0.0.22 -OutFile "D:\发布\MathModel-Setup.exe"
#   .\installer\make-setup.ps1 -KeepStage            # 保留暂存目录，便于排查
#
# 产物默认: <包根>\dist\MathModel-<版本>-开发版-Setup.exe
#
# 依赖: electron-builder 缓存的 NSIS( makensis.exe ) —— 本机已有则自动定位；
#       也可 -Makensis <路径> 指定。
param(
  [string]$AppRoot = "",
  [string]$Version = "",
  [string]$OutFile = "",
  [string]$PackageRoot = "",
  [string]$Makensis = "",
  [switch]$KeepStage,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
function Say([string]$m, [string]$color = "Gray") { if (-not $Quiet) { Write-Host $m -ForegroundColor $color } }

if ($PackageRoot -eq "") { $PackageRoot = Split-Path $PSScriptRoot -Parent }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$dist = Join-Path $PackageRoot "dist"
$stage = Join-Path $dist "_stage"
$payload = Join-Path $stage "payload"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# ---------- 找安装目录 ----------
function Resolve-AppRoot([string]$given) {
  $cands = @()
  if ($given -ne "") { $cands += $given }
  $cands += (Join-Path $env:LOCALAPPDATA "Programs\mathmodel")
  $cands += (Join-Path $env:LOCALAPPDATA "Programs\@mathmodeldesktop")
  try {
    foreach ($k in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
      foreach ($p in (Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
        if ($p.DisplayName -notlike '*mathmodel*') { continue }
        if ($p.InstallLocation) { $cands += $p.InstallLocation }
        if ($p.UninstallString) {
          $u = ($p.UninstallString -replace '^"', '') -replace '".*$', ''
          if ($u) { $cands += (Split-Path -Parent $u) }
        }
      }
    }
  } catch { }
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c "mathmodel.exe"))) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

# ---------- 找 makensis ----------
function Resolve-Makensis([string]$given) {
  $cands = @()
  if ($given -ne "") { $cands += $given }
  $eb = Join-Path $env:LOCALAPPDATA "electron-builder\Cache"
  if (Test-Path $eb) {
    $cands += (Get-ChildItem $eb -Recurse -Filter "makensis.exe" -File -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
  }
  $cands += "$env:LOCALAPPDATA\Programs\Mrite-Dev\_devtools\nsis\Bin\makensis.exe"
  $cands += "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
  $cands += "$env:ProgramFiles\NSIS\makensis.exe"
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path } }
  return $null
}

# ================= 主流程 =================
$app = Resolve-AppRoot $AppRoot
if (-not $app) { throw "找不到已安装的 MathModel（用 -AppRoot 指定含 mathmodel.exe 的目录）" }
Say "安装目录: $app" Cyan

if ($Version -eq "") {
  $Version = (Get-Item (Join-Path $app "mathmodel.exe")).VersionInfo.FileVersion
  if (-not $Version) { throw "无法读取版本号，请用 -Version 指定" }
}
Say "版本号  : $Version" Cyan

# 必须是开发版，否则打出来的 setup 就是官方版
$asarPath = Join-Path $app "resources\app.asar"
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$needle = '/*dev*/'
$isDev = $false
$fs = [System.IO.File]::OpenRead($asarPath)
try {
  $buf = New-Object byte[] (4MB + 16)
  $carry = 0
  while ($true) {
    $read = $fs.Read($buf, $carry, 4MB)
    if ($read -le 0) { break }
    $total = $carry + $read
    if ($latin1.GetString($buf, 0, $total).Contains($needle)) { $isDev = $true; break }
    $carry = [Math]::Min(16, $total)
    [Array]::Copy($buf, $total - $carry, $buf, 0, $carry)
  }
} finally { $fs.Close() }
if (-not $isDev) { throw "安装目录里的 app.asar 不是开发版（没有 /*dev*/ 标记）。请先 tools\apply-dev.ps1 应用开发版补丁。" }
Say "校验    : app.asar 是开发版 ✓" Green

$makensis = Resolve-Makensis $Makensis
if (-not $makensis) { throw "找不到 makensis.exe，请安装 NSIS 或用 -Makensis 指定" }
Say "makensis: $makensis" Cyan

# ---------- 暂存 payload ----------
Say "暂存安装内容（排除官方 asar 备份与旧卸载器）…" Cyan
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload | Out-Null
$null = robocopy $app $payload /MIR /XF "Uninstall mathmodel.exe" "app.asar.official-backup" /NFL /NDL /NJH /NP /R:1 /W:1
if ($LASTEXITCODE -gt 7) { throw "robocopy 失败（退出码 $LASTEXITCODE）" }

# 随包附带的后台拦截 / 痕迹清理脚本
$devTools = Join-Path $payload "dev-tools"
New-Item -ItemType Directory -Force -Path $devTools | Out-Null
foreach ($n in @("block-backend.ps1", "purge-local-identity.ps1", "switch-auto-update.ps1")) {
  $src = Join-Path $PackageRoot "tools\$n"
  if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $devTools $n) -Force }
}

$readme = @"
MathModel $Version 开发版 —— 说明
================================================

1. 免登录 / 不扣积分
   启动即为本地身份（右上角显示「开发者」，徽章「开发版」），不需要 MathModel 账号。

2. 对话用你自己的模型
   右上角「设置 → 供应商」填入自己的 API Key（Anthropic / DeepSeek / Kimi / 通义等）。
   不填 Key 也能打开界面，但发消息会提示缺少认证信息。

3. 后台服务器已切断
   程序内部的服务器地址被改为 http://127.0.0.1:9（本机不可达），遥测上报已停用，
   界面里的官网链接也已清除。程序不会向 mathmodel.top 发起任何请求。
   想再加一层系统级 DNS 拦截（需要管理员）：
       右键以管理员身份运行 PowerShell，执行：
       powershell -ExecutionPolicy Bypass -File "dev-tools\block-backend.ps1"

4. 内置自动更新（指向本项目自己的 GitHub Release）
   启动后会自动检查更新，发现新版本会后台下载；界面提示后点一下即可重启升级。
   更新源就写在本程序 resources\app-update.yml 里（默认 06xxlin/MathModelAgent-dev），
   下载完会校验 sha512，装完自动重启，仍然是开发版（不会变成官方版）。
   想临时关掉自动更新：

       powershell -ExecutionPolicy Bypass -File "dev-tools\switch-auto-update.ps1" -Disable
       （恢复：把 -Disable 换成 -Enable；改完要完全退出再启动程序）

   仍然会出网的其他请求：
   - github.com / api.github.com：上面这条更新检查（不访问 mathmodel.top）
   - models.dev：第三方模型目录
   - 你自己配置的模型服务商 API

5. 数据目录
   %APPDATA%\@mathmodel\desktop   —— 工作区、会话、设置都在这里，卸载时默认保留。

6. 卸载
   「设置 → 应用 → 已安装的应用」里找 mathmodel $Version 开发版，
   或直接运行安装目录下的 Uninstall.exe。
"@
[System.IO.File]::WriteAllText((Join-Path $devTools "使用说明.txt"), $readme, (New-Object System.Text.UTF8Encoding($true)))

# ---------- 图标 ----------
$ico = Join-Path $stage "app.ico"
try {
  Add-Type -AssemblyName System.Drawing
  $i = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $payload "mathmodel.exe"))
  $fsi = [System.IO.File]::Create($ico); $i.Save($fsi); $fsi.Close()
} catch { Say "⚠ 图标提取失败，将用默认图标" Yellow; $ico = "" }

# ---------- 生成 nsi ----------
if ($OutFile -eq "") { $OutFile = Join-Path $dist "MathModel-$Version-开发版-Setup.exe" }
$OutFile = [System.IO.Path]::GetFullPath($OutFile)
$nsiPath = Join-Path $stage "setup.nsi"

$tpl = @'
Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"

!define APP_VER     "@@VERSION@@"
!define APP_EXE     "mathmodel.exe"
!define APP_DISPLAY "mathmodel @@VERSION@@ 开发版"
!define SHORTCUT    "MathModel 开发版"
!define UNINST_KEY  "Software\Microsoft\Windows\CurrentVersion\Uninstall\mathmodel-desktop-dev"
!define STAGE       "@@STAGE@@"

Name "MathModel @@VERSION@@ 开发版"
OutFile "@@OUTFILE@@"
InstallDir "$LOCALAPPDATA\Programs\mathmodel"
InstallDirRegKey HKCU "Software\MathModel\DesktopDev" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64

VIProductVersion "@@VERSION@@.0"
VIAddVersionKey /LANG=2052 "ProductName"     "MathModel 开发版"
VIAddVersionKey /LANG=2052 "FileDescription" "MathModel @@VERSION@@ 开发版 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion"     "@@VERSION@@"
VIAddVersionKey /LANG=2052 "LegalCopyright"  "Community dev build"

@@ICON_DEFINES@@

!define MUI_ABORTWARNING

; 由内置更新程序（electron-updater）拉起时命令行为 "--updated [--force-run]"：
; 这时跳过欢迎/目录/完成页，只留安装进度，装完按需自动重启程序。
Var IsUpdate
Var ForceRun

Function SkipIfUpdate
  StrCmp $IsUpdate "1" 0 +2
  Abort
FunctionEnd

!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfUpdate
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfUpdate
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 MathModel 开发版"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\dev-tools\使用说明.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "查看开发版说明（强烈建议先看）"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfUpdate
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  ; 已有实例在跑就先结束，避免 exe/asar 被占用导致写入失败
  nsExec::ExecToLog 'taskkill /IM ${APP_EXE} /F'
  Pop $0
  Sleep 1200

  StrCpy $IsUpdate "0"
  StrCpy $ForceRun "0"
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "--updated" $R1
  IfErrors updDone
    StrCpy $IsUpdate "1"
  updDone:
  ClearErrors
  ${GetOptions} $R0 "--force-run" $R1
  IfErrors runDone
    StrCpy $ForceRun "1"
  runDone:
FunctionEnd

Section "MathModel 开发版" SEC_MAIN
  SetShellVarContext current

  ; 清掉官方安装器残留，避免出现两个卸载入口
  Delete "$INSTDIR\Uninstall mathmodel.exe"
  Delete "$INSTDIR\resources\app.asar.official-backup"

  SetOutPath "$INSTDIR"
  File /r "${STAGE}\payload\*.*"

  CreateShortCut "$DESKTOP\${SHORTCUT}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateDirectory "$SMPROGRAMS"
  CreateShortCut "$SMPROGRAMS\${SHORTCUT}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\MathModel\DesktopDev" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName"     "${APP_DISPLAY}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion"  "${APP_VER}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher"       "Community dev build"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"

  ; 内置更新（electron-updater）会带 --force-run，装完自动把程序拉起来
  StrCmp $ForceRun "1" 0 +2
    Exec '"$INSTDIR\${APP_EXE}"'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  nsExec::ExecToLog 'taskkill /IM ${APP_EXE} /F'
  Pop $0
  Sleep 1200

  Delete "$DESKTOP\${SHORTCUT}.lnk"
  Delete "$SMPROGRAMS\${SHORTCUT}.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\MathModel\DesktopDev"

  Delete "$INSTDIR\Uninstall.exe"
  RMDir /r "$INSTDIR"

  ; 静默卸载(/S) 时不要弹窗，否则无人值守会卡住；默认保留用户数据
  IfSilent unDone
  MessageBox MB_YESNO|MB_ICONQUESTION "是否同时删除用户数据（工作区 / 会话 / 供应商设置）？$\r$\n$\r$\n位置：$APPDATA\@mathmodel$\r$\n$\r$\n选「否」将保留，重装后可以继续用。" IDNO unDone
    RMDir /r "$APPDATA\@mathmodel"
  unDone:
SectionEnd
'@

$iconDefines = if ($ico -ne "") {
  "Icon `"$ico`"`r`nUninstallIcon `"$ico`"`r`n!define MUI_ICON `"$ico`"`r`n!define MUI_UNICON `"$ico`""
} else { "" }

$nsi = $tpl.Replace("@@VERSION@@", $Version).Replace("@@STAGE@@", $stage).Replace("@@OUTFILE@@", $OutFile).Replace("@@ICON_DEFINES@@", $iconDefines)
[System.IO.File]::WriteAllText($nsiPath, $nsi, (New-Object System.Text.UTF8Encoding($true)))
Say "nsi     : $nsiPath" Cyan

# ---------- 编译 ----------
Say "开始编译安装包（solid LZMA，约 1GB 内容，需要几分钟）…" Cyan
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
& $makensis /V3 $nsiPath
if ($LASTEXITCODE -ne 0) { throw "makensis 编译失败（退出码 $LASTEXITCODE）" }

if (-not $KeepStage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }

$fi = Get-Item -LiteralPath $OutFile
Say ""
Say ("安装包已生成: " + $fi.FullName) Green
Say ("大小: {0:N1} MB" -f ($fi.Length / 1MB)) Green
