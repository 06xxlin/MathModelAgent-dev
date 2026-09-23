# apply-dev.ps1 — 把「开发版」补丁应用到官方 MathModel 桌面版
#
# 用法:
#   .\tools\apply-dev.ps1 -AppRoot "官方安装根目录(含 mathmodel.exe)"
#   可选: -Asar <开发版 app.asar 路径>   默认用 prebuilt\app.asar
#   可选: -NoKill                        不自动结束正在运行的 mathmodel
#   可选: -UpdateRepo "owner/repo"        内置更新检查指向的 GitHub 仓库
#                                         （默认 06xxlin/MathModelAgent-dev；传 - 表示不改）
#   可选: -UpdateChannel latest|beta      更新通道，默认 latest
#
# 做的事: 结束进程 → 备份官方 app.asar → 覆盖为开发版 → 改写 exe 内嵌完整性哈希
#         → 把 resources\app-update.yml 的更新源指向你自己的 GitHub Release
param(
  [Parameter(Mandatory = $true)][string]$AppRoot,
  [string]$Asar = "",
  [string]$UpdateRepo = "06xxlin/MathModelAgent-dev",
  [string]$UpdateChannel = "latest",
  [switch]$NoKill
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
if ($Asar -eq "") { $Asar = Join-Path $repo "prebuilt\app.asar" }

if (-not (Test-Path -LiteralPath $AppRoot)) { throw "找不到安装目录: $AppRoot" }
if (-not (Test-Path -LiteralPath $Asar)) { throw "找不到开发版 app.asar: $Asar" }

$res = Join-Path $AppRoot "resources"
if (-not (Test-Path -LiteralPath $res)) { throw "安装目录里没有 resources 子目录，路径是否正确? $AppRoot" }

$exe = Get-ChildItem -LiteralPath $AppRoot -Filter *.exe -File |
  Where-Object { $_.Name -notlike "Uninstall*" } | Select-Object -First 1
if (-not $exe) { throw "在 $AppRoot 下找不到主程序 exe" }

$cur = Join-Path $res "app.asar"
if (-not (Test-Path -LiteralPath $cur)) { throw "找不到 $cur" }

if (-not $NoKill) {
  Write-Host "==> 结束正在运行的 mathmodel …" -ForegroundColor Cyan
  Get-Process -Name mathmodel -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 800
}

Write-Host "==> 备份官方 app.asar（仅首次）…" -ForegroundColor Cyan
$bak = Join-Path $res "app.asar.official-backup"
if (-not (Test-Path -LiteralPath $bak)) {
  Copy-Item -LiteralPath $cur -Destination $bak -Force
  Write-Host "    $bak"
} else {
  Write-Host "    已存在备份，跳过"
}

Write-Host "==> 覆盖为开发版 app.asar …" -ForegroundColor Cyan
Copy-Item -LiteralPath $Asar -Destination $cur -Force
Write-Host "    $Asar  ->  $cur"

Write-Host "==> 改写 exe 内嵌完整性哈希 …" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "patch-exe-hash.ps1") -Exe $exe.FullName -Asar $cur

# ---------- 内置更新检查：改指向自己的 GitHub Release ----------
# 程序启动时会读 resources\app-update.yml 决定去哪儿查更新（electron-updater 的 github provider）。
# 这个文件在 asar 外面，所以单独改写；官方安装包/官方更新会把它重置回 jihe520/MathModelAgent。
if ($UpdateRepo -ne "-") {
  $yml = Join-Path $res "app-update.yml"
  $ymlBak = Join-Path $res "app-update.yml.official-backup"
  if ((Test-Path -LiteralPath $yml) -and -not (Test-Path -LiteralPath $ymlBak)) {
    Copy-Item -LiteralPath $yml -Destination $ymlBak -Force
    Write-Host "    已备份官方 app-update.yml" -ForegroundColor Gray
  }
  if ($UpdateRepo -notmatch '^[^/\s]+/[^/\s]+$') {
    throw "-UpdateRepo 需要 owner/repo 形式，例如 06xxlin/MathModelAgent-dev（当前: $UpdateRepo）"
  }
  $parts = $UpdateRepo.Split('/')
  # updaterCacheDirName 沿用官方值，别动（改了会换缓存目录）
  $cache = "'@mathmodeldesktop-updater'"
  if (Test-Path -LiteralPath $yml) {
    $m = [regex]::Match((Get-Content -LiteralPath $yml -Raw), "updaterCacheDirName:\s*(.+)")
    if ($m.Success) { $cache = $m.Groups[1].Value.Trim() }
  }
  $yaml = @(
    "owner: $($parts[0])",
    "repo: $($parts[1])",
    "provider: github",
    "releaseType: release",
    "channel: $UpdateChannel",
    "updaterCacheDirName: $cache"
  ) -join "`r`n"
  [System.IO.File]::WriteAllText($yml, $yaml + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "    更新源已改为 GitHub Release: $UpdateRepo (channel=$UpdateChannel)"
}

Write-Host ""
Write-Host "全部完成！双击启动: $($exe.FullName)" -ForegroundColor Green
Write-Host "提示: 首启无需登录，界面显示「开发者 / 开发版」即为成功。" -ForegroundColor Green
