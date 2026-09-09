# 一键应用开发版补丁（Windows PowerShell）
# 用法:  .\tools\apply-dev.ps1 -AppRoot "官方安装根目录(含 mathmodel.exe)"
param(
  [Parameter(Mandatory = $true)][string]$AppRoot,
  [string]$Asar = (Join-Path (Split-Path $PSScriptRoot -Parent) "prebuilt\app.asar")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path -LiteralPath $AppRoot)) { throw "找不到安装目录: $AppRoot" }
if (-not (Test-Path -LiteralPath $Asar))  { throw "找不到开发版 asar: $Asar" }

$exe = Get-ChildItem -LiteralPath $AppRoot -Filter *.exe -File |
       Where-Object { $_.Name -notlike "Uninstall*" } | Select-Object -First 1
if (-not $exe) { throw "在 $AppRoot 下找不到主程序 exe" }
$res = Join-Path $AppRoot "resources"
$cur = Join-Path $res "app.asar"

Write-Host "==> 结束正在运行的 mathmodel …" -ForegroundColor Cyan
Get-Process -Name mathmodel -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

Write-Host "==> 首次备份官方 app.asar …" -ForegroundColor Cyan
$bak = Join-Path $res "app.asar.official-backup"
if (-not (Test-Path -LiteralPath $bak)) {
  Copy-Item -LiteralPath $cur -Destination $bak -Force
  Write-Host "    备份 -> $bak"
} else {
  Write-Host "    已存在备份，跳过"
}

Write-Host "==> 覆盖 app.asar …" -ForegroundColor Cyan
Copy-Item -LiteralPath $Asar -Destination $cur -Force
Write-Host "    $Asar -> $cur"

Write-Host "==> 改写 exe 内嵌完整性哈希 …" -ForegroundColor Cyan
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "需要 Node.js 18+，请先安装并加入 PATH" }
& node (Join-Path $PSScriptRoot "patch-exe-hash.js") $exe.FullName $cur
if ($LASTEXITCODE -ne 0) { throw "哈希改写失败" }

Write-Host "`n完成！现在可以启动 $($exe.FullName)" -ForegroundColor Green
Write-Host "说明: 恢复官方版请重装官方安装包，或还原 resources\app.asar.official-backup 后重装一次(用于恢复 exe 哈希)。"
