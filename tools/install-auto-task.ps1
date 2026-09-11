# install-auto-task.ps1 — 注册/移除「官方更新后自动重制开发版补丁」计划任务
#
# 用法:
#   .\tools\install-auto-task.ps1                      # 登录时 + 每 60 分钟 检查一次（无需管理员）
#   .\tools\install-auto-task.ps1 -IntervalMinutes 30
#   .\tools\install-auto-task.ps1 -Push                # 重制后自动 git commit + push
#   .\tools\install-auto-task.ps1 -AppRoot "C:\...\@mathmodeldesktop"
#   .\tools\install-auto-task.ps1 -Remove              # 移除任务
#
# 说明: 用 schtasks.exe + 任务 XML 注册（普通用户权限即可）；
#       PowerShell 的 Register-ScheduledTask 在非管理员会话可能报 Access denied。
param(
  [string]$PackageRoot = "",
  [string]$AppRoot = "",
  [int]$IntervalMinutes = 60,
  [switch]$Push,
  [switch]$Remove,
  [string]$TaskName = "MathModelAgentDev-AutoPatch"
)

$ErrorActionPreference = "Stop"
if ($PackageRoot -eq "") { $PackageRoot = (Resolve-Path (Split-Path $PSScriptRoot -Parent)).Path }
$pipeline = Join-Path $PackageRoot "tools\auto-pipeline.ps1"
if (-not (Test-Path -LiteralPath $pipeline)) { throw "找不到 auto-pipeline.ps1: $pipeline" }

if ($Remove) {
  schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
  Write-Host "已移除计划任务: $TaskName" -ForegroundColor Green
  exit 0
}

$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = "powershell.exe" }

$pipelineArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$pipeline`" -Mode local -Quiet"
if ($AppRoot -ne "") { $pipelineArgs += " -AppRoot `"$AppRoot`"" }
if ($Push) { $pipelineArgs += " -Push" }

$user = "$env:USERDOMAIN\$env:USERNAME"
$start = (Get-Date).AddMinutes(3).ToString("yyyy-MM-dd'T'HH:mm:ss")
$interval = "PT${IntervalMinutes}M"

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>MathModel dev patch auto rebuild: detect new official version, rebuild patch package and apply.</Description>
    <Author>$user</Author>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$interval</Interval>
        <Duration>P3650D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>$pipelineArgs</Arguments>
      <WorkingDirectory>$PackageRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlFile = Join-Path $env:TEMP ("mma-task-" + [guid]::NewGuid().ToString('N') + ".xml")
[System.IO.File]::WriteAllText($xmlFile, $xml, [System.Text.UnicodeEncoding]::new($false, $true))

try {
  $out = schtasks /create /tn $TaskName /xml $xmlFile /f 2>&1
  if ($LASTEXITCODE -ne 0) { throw ("schtasks 创建任务失败: " + ($out -join ' ')) }
} finally {
  Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue
}

Write-Host "已注册计划任务: $TaskName" -ForegroundColor Green
Write-Host "  触发: 登录时 + 每 $IntervalMinutes 分钟"
Write-Host "  命令: $psExe $pipelineArgs"
try {
  $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
  Write-Host ("  下次运行: " + $info.NextRunTime)
} catch { }
Write-Host ""
Write-Host "手动立刻跑一次:  .\tools\auto-pipeline.ps1" -ForegroundColor Cyan
Write-Host "移除任务:        .\tools\install-auto-task.ps1 -Remove" -ForegroundColor Cyan
Write-Host "日志目录:        $PackageRoot\logs\"
