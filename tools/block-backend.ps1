# block-backend.ps1 — 开发版网络隔离「第二层」：在 hosts 里把后台域名解析到 0.0.0.0
#
# 第一层是 tools\patch-asar.js 的代码层封堵（后台基址改成不可达的本地地址），
# 本脚本只做兜底：万一某条代码路径绕过基址常量、直接按域名出网，DNS 也解析不出来。
#
# 用法:
#   .\tools\block-backend.ps1              # 写入 hosts 拦截（需要管理员，会自动请求提权）
#   .\tools\block-backend.ps1 -Remove      # 移除拦截，恢复原状
#   .\tools\block-backend.ps1 -Hosts mathmodel.top,api.mathmodel.top
#
# 说明: 只改 hosts 里本脚本自己的标记块，不动其它任何行；改动前自动备份 hosts。
param(
  [string[]]$Hosts = @('mathmodel.top', 'www.mathmodel.top'),
  [switch]$Remove,
  [string]$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
)

$ErrorActionPreference = 'Stop'
# 允许 -Hosts "a,b" / "a;b" / a,b 三种写法（提权重跑时用 ';' 传参）
$Hosts = @($Hosts | ForEach-Object { $_ -split '[,;]' } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
$beginMarker = '# >>> mathmodel-dev: block backend >>>'
$endMarker = '# <<< mathmodel-dev: block backend <<<'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 未提权时自动请求提权重跑（UAC 弹窗需要你点一下「是」）
if (-not (Test-Admin)) {
  Write-Host '需要管理员权限修改 hosts，正在请求提权 …' -ForegroundColor Yellow
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
  if ($Remove) { $argList += '-Remove' }
  if ($Hosts.Count -gt 0) { $argList += @('-Hosts', "`"$($Hosts -join ';')`"") }
  Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
  Write-Host '已弹出 UAC，请在弹窗中点「是」；完成后本窗口不会显示结果。' -ForegroundColor Cyan
  exit 0
}

if (-not (Test-Path -LiteralPath $HostsFile)) { throw "找不到 hosts: $HostsFile" }

# 备份 hosts
$bak = "$HostsFile.bak-mma-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $HostsFile -Destination $bak -Force
Write-Host "已备份 hosts -> $bak"

# 读入并剥掉旧标记块
$lines = Get-Content -LiteralPath $HostsFile -Encoding UTF8
$kept = New-Object System.Collections.Generic.List[string]
$inside = $false
foreach ($l in $lines) {
  if ($l.Trim() -eq $beginMarker) { $inside = $true; continue }
  if ($l.Trim() -eq $endMarker) { $inside = $false; continue }
  if (-not $inside) { $kept.Add($l) }
}

if (-not $Remove) {
  $kept.Add($beginMarker)
  $kept.Add('# written by MathModelAgent-dev patch pack: point backend domain to 0.0.0.0 (sinkhole)')
  foreach ($h in $Hosts) { $kept.Add("0.0.0.0`t$h") }
  $kept.Add($endMarker)
}

# 写回（hosts 通常无 BOM；用 ASCII 避免 BOM 引发解析问题）
$out = ($kept -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($HostsFile, $out, [System.Text.Encoding]::ASCII)

if ($Remove) {
  Write-Host '已移除 hosts 拦截块。' -ForegroundColor Green
} else {
  Write-Host ("已写入 hosts 拦截: " + ($Hosts -join ', ') + ' -> 0.0.0.0') -ForegroundColor Green
}

try { ipconfig /flushdns | Out-Null; Write-Host 'DNS 缓存已刷新。' } catch { }

Write-Host ''
Write-Host '当前拦截块内容:'
Get-Content -LiteralPath $HostsFile -Encoding UTF8 | Select-String -Pattern 'mathmodel' -SimpleMatch
