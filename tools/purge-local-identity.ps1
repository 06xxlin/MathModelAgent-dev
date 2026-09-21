# purge-local-identity.ps1 — 清掉本地残留的「厂商身份/遥测」痕迹（只动 App 自己的状态文件）
#
# 会处理（先备份，再删除）：
#   auth-store.json        后台登录态（better-auth 的加密 cookie / local cache）—— 后台靠它把机器和账号对上
#   telemetry-outbox.json  遥测发件箱（含固定 installId + 待上报事件）
#   Network\Cookies        如果里面确实含有后台域名的 cookie（没有就跳过）
#
# 绝不触碰：workspace\、version-history\、sdk-config\、codex-home\、mathmodel.db 等用户内容与设置。
#
# 用法:
#   .\tools\purge-local-identity.ps1              # 结束程序 → 备份 → 清理
#   .\tools\purge-local-identity.ps1 -NoKill      # 不自动结束程序（自己先退出 MathModel）
#   .\tools\purge-local-identity.ps1 -WhatIf      # 只列出会做什么，不动文件
param(
  [switch]$NoKill,
  [switch]$WhatIf,
  [string]$DataDir = "$env:APPDATA\@mathmodel\desktop"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $DataDir)) { throw "找不到 App 数据目录: $DataDir" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Split-Path $DataDir -Parent) "_purge-backup-$stamp"

function Move-Aside([string]$rel) {
  $src = Join-Path $DataDir $rel
  if (-not (Test-Path -LiteralPath $src)) { Write-Host ("  跳过(不存在): " + $rel); return }
  if ($WhatIf) { Write-Host ("  [WhatIf] 会移除: " + $src); return }
  $dst = Join-Path $backupDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
  Move-Item -LiteralPath $src -Destination $dst -Force
  Write-Host ("  已移除: " + $rel + "  (备份在 " + $dst + ")") -ForegroundColor Green
}

Write-Host '==> 清理本地身份/遥测痕迹' -ForegroundColor Cyan
Write-Host "数据目录: $DataDir"
Write-Host "备份目录: $backupDir"
Write-Host ''

if (-not $NoKill -and -not $WhatIf) {
  $p = Get-Process -Name mathmodel -ErrorAction SilentlyContinue
  if ($p) {
    Write-Host '==> 结束正在运行的 mathmodel …'
    $p | Stop-Process -Force
    Start-Sleep -Milliseconds 1200
  }
}

Move-Aside 'auth-store.json'
Move-Aside 'telemetry-outbox.json'

# Cookies：仅在确实含后台域名时才动
$cookieFile = Join-Path $DataDir 'Network\Cookies'
if (Test-Path -LiteralPath $cookieFile) {
  $bytes = [System.IO.File]::ReadAllBytes($cookieFile)
  $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
  if ($ascii.Contains('mathmodel')) {
    Move-Aside 'Network\Cookies'
    Move-Aside 'Network\Cookies-journal'
  } else {
    Write-Host '  跳过(无后台域名 cookie): Network\Cookies'
  }
  Remove-Variable bytes, ascii
} else {
  Write-Host '  跳过(不存在): Network\Cookies'
}

Write-Host ''
if ($WhatIf) {
  Write-Host '（WhatIf 模式：未改动任何文件）' -ForegroundColor Yellow
} else {
  Write-Host '完成。下次启动：无需登录（开发版显示「开发者」），后台也在代码层被切断。' -ForegroundColor Green
  Write-Host '如需还原，把备份目录里的文件拷回原位置即可。'
}
