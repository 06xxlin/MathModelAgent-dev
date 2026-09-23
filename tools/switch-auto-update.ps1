# switch-auto-update.ps1 — 开关 MathModel 的官方自动更新
#
# 为什么需要它：开发版的 asar/exe 是改造过的，官方一推送新版本，
# electron-updater 会把整个程序覆盖回官方版（登录 / 积分门槛又回来了）。
# 这个脚本通过用户级环境变量 MATHMODEL_DISABLE_AUTO_UPDATE 把更新检查关掉。
#
# 用法:
#   .\tools\switch-auto-update.ps1 -Status     # 看当前状态
#   .\tools\switch-auto-update.ps1 -Disable    # 关闭自动更新（保住开发版）
#   .\tools\switch-auto-update.ps1 -Enable     # 打开自动更新（跟随官方）
#
# 注意: 环境变量对已经在运行的程序不生效，改完请完全退出并重新启动 MathModel。
param(
  [switch]$Disable,
  [switch]$Enable,
  [switch]$Status
)
$ErrorActionPreference = 'Stop'
$name = 'MATHMODEL_DISABLE_AUTO_UPDATE'

function Get-Current {
  $v = [Environment]::GetEnvironmentVariable($name, 'User')
  if ($null -eq $v) { $v = [Environment]::GetEnvironmentVariable($name, 'Machine') }
  return $v
}

function Broadcast-Change {
  # 通知资源管理器刷新环境变量，避免必须注销才生效
  try {
    if (-not ('Win32.NativeMethods' -as [type])) {
      Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $r = [UIntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
  } catch { }
}

$cur = Get-Current
if (-not $Disable -and -not $Enable) { $Status = $true }

if ($Status) {
  Write-Host ("当前 {0} = {1}" -f $name, ($(if ($null -eq $cur) { '(未设置 → 自动更新开启)' } else { $cur })))
  if ($cur -eq '1') { Write-Host '自动更新：已关闭（开发版不会被官方覆盖）' -ForegroundColor Green }
  else { Write-Host '自动更新：开启（官方出新版会覆盖开发版）' -ForegroundColor Yellow }
  return
}

if ($Disable) {
  [Environment]::SetEnvironmentVariable($name, '1', 'User')
  Broadcast-Change
  Write-Host "已关闭自动更新：$name = 1" -ForegroundColor Green
  Write-Host '请完全退出并重新启动 MathModel 使其生效。'
} else {
  [Environment]::SetEnvironmentVariable($name, $null, 'User')
  Broadcast-Change
  Write-Host "已恢复自动更新：已移除 $name" -ForegroundColor Green
  Write-Host '请完全退出并重新启动 MathModel 使其生效。'
}
