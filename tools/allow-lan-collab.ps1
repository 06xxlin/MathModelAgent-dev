# allow-lan-collab.ps1 — 给 MathModel 放行「局域网协作」需要的入站端口
#
# 为什么需要：局域网协作是「房主的机器当服务器」，在 0.0.0.0:47820~47829 上开一个 HTTP/WebSocket
# 服务，队友通过 mDNS 发现后直接连这台机器。Windows 防火墙默认会挡掉别人连进来的入站连接，
# 所以队友会出现「看得见房间 / 连不上」或者干脆发现不了房间。
#
# 用法:
#   .\tools\allow-lan-collab.ps1            # 放行（需要管理员，会自动请求提权）
#   .\tools\allow-lan-collab.ps1 -Status    # 只看当前规则
#   .\tools\allow-lan-collab.ps1 -Remove    # 撤销放行
#
# 放行内容（只针对 mathmodel.exe 这个程序，不开放整机端口）:
#   · TCP 入站（协作服务 47820-47829）
#   · UDP 入站（mDNS 5353，房间广播/发现）
# 三个网络配置文件都加：域 / 专用 / 公用。
# 家里 WiFi 通常是「专用」，手机热点和很多路由器默认是「公用」——只加一种就会出现
# 「家里能用、热点不能用」这类怪现象。
param(
  [string]$AppRoot = "",
  [switch]$Remove,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$rulePrefix = 'MathModel LAN Collab'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-Exe([string]$root) {
  $cands = @()
  if ($root -ne '') { $cands += (Join-Path $root 'mathmodel.exe') }
  $cands += (Join-Path $env:LOCALAPPDATA 'Programs\@mathmodeldesktop\mathmodel.exe')
  $cands += (Join-Path $env:LOCALAPPDATA 'Programs\mathmodel\mathmodel.exe')
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path } }
  return $null
}

function Show-Rules {
  $r = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "$rulePrefix*" }
  if (-not $r) { Write-Host '当前没有本脚本添加的规则。' -ForegroundColor Yellow; return }
  $rows = foreach ($x in $r) {
    $pf = $x | Get-NetFirewallPortFilter
    [pscustomobject]@{
      Name = $x.DisplayName; Dir = $x.Direction; Action = $x.Action
      Enabled = $x.Enabled; Profile = $x.Profile
      Proto = $pf.Protocol; Port = $pf.LocalPort
    }
  }
  $rows | Format-Table -AutoSize
}

if ($Status) { Show-Rules; return }

# 未提权时自动请求提权重跑（UAC 弹窗需要点一下「是」）
if (-not (Test-Admin)) {
  Write-Host '需要管理员权限改防火墙，正在请求提权 …' -ForegroundColor Yellow
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
  if ($Remove) { $argList += '-Remove' }
  if ($AppRoot -ne '') { $argList += @('-AppRoot', "`"$AppRoot`"") }
  Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
  Write-Host '已弹出 UAC，请在弹窗中点「是」；完成后本窗口不会显示结果。' -ForegroundColor Cyan
  exit 0
}

if ($Remove) {
  Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "$rulePrefix*" } |
    Remove-NetFirewallRule
  Write-Host '已移除局域网协作放行规则。' -ForegroundColor Green
  Show-Rules
  return
}

$exe = Resolve-Exe $AppRoot
if (-not $exe) { throw "找不到 mathmodel.exe，请用 -AppRoot 指定安装目录" }
Write-Host "目标程序: $exe" Cyan

# 先清掉旧的同名规则，保证可重复运行
Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -like "$rulePrefix*" } |
  Remove-NetFirewallRule

New-NetFirewallRule -DisplayName "$rulePrefix (TCP)" -Direction Inbound -Action Allow `
  -Program $exe -Protocol TCP -LocalPort 47820-47829 -Profile Any | Out-Null

New-NetFirewallRule -DisplayName "$rulePrefix (mDNS UDP)" -Direction Inbound -Action Allow `
  -Program $exe -Protocol UDP -LocalPort 5353 -Profile Any | Out-Null

# 房间/文件传输也可能走别的临时端口，这里再补一条「该程序全部端口」的兜底（仍然只限这个 exe）
New-NetFirewallRule -DisplayName "$rulePrefix (fallback)" -Direction Inbound -Action Allow `
  -Program $exe -Protocol Any -Profile Any | Out-Null

Write-Host '已放行局域网协作入站（TCP 47820-47829 / UDP 5353 / 该程序兜底），三个网络配置文件均生效。' -ForegroundColor Green
Show-Rules
Write-Host ''
Write-Host '提示: 如果队友还是连不上，检查路由器/热点的「AP 隔离 / 客户端隔离」是否开启——' -ForegroundColor Yellow
Write-Host '      开了隔离的话，同一个 WiFi 下的设备之间本来就不能互相访问。' -ForegroundColor Yellow
