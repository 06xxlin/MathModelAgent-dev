# auto-pipeline.ps1 — 官方更新后自动重制并应用「开发版」补丁
#
# 用法:
#   .\tools\auto-pipeline.ps1                                  # 本地模式：检测安装目录，必要时重制+应用
#   .\tools\auto-pipeline.ps1 -Push                            # 额外：git commit + push 补丁包
#   .\tools\auto-pipeline.ps1 -Force                           # 强制重制（即使当前已是开发版）
#   .\tools\auto-pipeline.ps1 -Mode installer -Installer "D:\下载\mathmodel-setup-0.0.20.exe"
#   .\tools\auto-pipeline.ps1 -Mode installer -SourceDir "D:\解包目录"   # 已解包的官方目录(含 resources\app.asar)
#
# 原理:
#   1) 读取安装目录里的 app.asar，判断它是否已经是开发版（内含 /*dev*/ 标记）；
#   2) 若不是（=官方刚更新完/刚重装），用通用补丁器 tools\patch-asar.js 自动重制：
#      自动解混淆定位锚点 → 打补丁 → 重打包 → 更新 prebuilt\ 与 patched\；
#   3) 自动应用回安装目录（备份官方 asar + 改写 exe 内嵌完整性哈希）并重启程序；
#   4) 记录状态到 .auto-state.json；-Push 时把补丁包改动提交到 git。
param(
  [string]$AppRoot = "",
  [string]$PackageRoot = "",
  [ValidateSet('local', 'installer')][string]$Mode = 'local',
  [string]$Installer = "",
  [string]$SourceDir = "",
  [switch]$Push,
  [switch]$NoApply,
  [switch]$NoLaunch,
  [switch]$Force,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
function Say([string]$m, [string]$color = "Gray") { if (-not $Quiet) { Write-Host $m -ForegroundColor $color } }

if ($PackageRoot -eq "") { $PackageRoot = Split-Path $PSScriptRoot -Parent }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$tools = Join-Path $PackageRoot "tools"
$stateFile = Join-Path $PackageRoot ".auto-state.json"
$reportFile = Join-Path $PackageRoot ".auto-report.json"
$logDir = Join-Path $PackageRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("auto-" + (Get-Date -Format "yyyyMMdd") + ".log")

function Log([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  Say $line
}

# ---------- 找安装目录 ----------
function Resolve-AppRoot([string]$given) {
  $cands = @()
  if ($given -ne "") { $cands += $given }
  $cands += (Join-Path $env:LOCALAPPDATA "Programs\@mathmodeldesktop")
  $cands += (Join-Path (Split-Path $PackageRoot -Parent) "")
  foreach ($c in $cands) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c "mathmodel.exe"))) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

# ---------- 判断 asar 是否已是开发版 ----------
function Test-PatchedAsar([string]$asarPath) {
  # 在 asar 字节流里找开发版标记 /*dev*/（分块 + Latin1 字符串查找，比逐字节快得多）
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $needle = '/*dev*/'
  $chunkSize = 4 * 1024 * 1024
  $fs = [System.IO.File]::OpenRead($asarPath)
  try {
    $buf = New-Object byte[] ($chunkSize + 16)
    $carry = 0
    while ($true) {
      $read = $fs.Read($buf, $carry, $chunkSize)
      if ($read -le 0) { break }
      $total = $carry + $read
      if ($latin1.GetString($buf, 0, $total).Contains($needle)) { return $true }
      $carry = [Math]::Min(16, $total)
      [Array]::Copy($buf, $total - $carry, $buf, 0, $carry)
    }
    return $false
  } finally { $fs.Close() }
}

function Read-AsarVersion([string]$asarPath) {
  # 用包内小工具（Node）读 asar 里的 package.json 版本
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return $null }
  $tool = Join-Path $PackageRoot "tools\read-version.js"
  if (-not (Test-Path -LiteralPath $tool)) { return $null }
  $out = & node $tool $asarPath 2>$null
  return ($out | Out-String).Trim()
}

function Ensure-AsarModule {
  if (-not (Test-Path (Join-Path $PackageRoot "node_modules\@electron\asar"))) {
    Log "首次运行：安装依赖 @electron/asar …"
    Push-Location $PackageRoot
    try {
      if (-not (Test-Path (Join-Path $PackageRoot "package.json"))) { npm init -y | Out-Null }
      npm install @electron/asar --no-audit --no-fund | Out-Null
    } finally { Pop-Location }
  }
}

# ---------- 从安装包/目录取官方 asar ----------
function Get-SourceFromInstaller([string]$installerPath, [string]$srcDir) {
  $staging = Join-Path $env:TEMP ("mma-installer-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  if ($srcDir -ne "") {
    Log "使用已解包目录: $srcDir"
    return @{ Asar = (Join-Path $srcDir "resources\app.asar"); Unpacked = (Join-Path $srcDir "resources\app.asar.unpacked"); Staging = $null }
  }
  if ($installerPath -eq "" -or -not (Test-Path -LiteralPath $installerPath)) { throw "installer 模式需要 -Installer <安装包路径> 或 -SourceDir <已解包目录>" }
  $seven = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe", "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $seven) { throw "需要 7-Zip 解包官方安装包（未找到 7z.exe）。可安装 7-Zip，或先用 7-Zip 手工解包后传 -SourceDir。" }
  Log "用 7-Zip 解包安装包: $installerPath"
  & $seven x $installerPath "-o$staging" -y | Out-Null
  $inner = Get-ChildItem -LiteralPath $staging -Recurse -File -Filter "app-*.7z" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($inner) {
    Log "解出内层负载: $($inner.Name)"
    $payload = Join-Path $staging "payload"
    & $seven x $inner.FullName "-o$payload" -y | Out-Null
    $asar = Get-ChildItem -LiteralPath $payload -Recurse -File -Filter "app.asar" | Select-Object -First 1
  } else {
    $asar = Get-ChildItem -LiteralPath $staging -Recurse -File -Filter "app.asar" | Select-Object -First 1
  }
  if (-not $asar) { throw "安装包里没找到 app.asar（结构可能变了，请用 -SourceDir 手工解包后指定）" }
  $unp = Join-Path $asar.Directory.FullName "app.asar.unpacked"
  return @{ Asar = $asar.FullName; Unpacked = $unp; Staging = $staging }
}

# ================= 主流程 =================
Log "===== auto-pipeline 开始 (Mode=$Mode) ====="

$appRoot = Resolve-AppRoot $AppRoot
if ($appRoot) { Log "安装目录: $appRoot" } else { Log "未找到安装目录（本地模式需要先安装官方版）" -color Yellow }

$sourceAsar = $null; $sourceUnpacked = $null; $staging = $null

if ($Mode -eq 'local') {
  if (-not $AppRoot) { throw "本地模式找不到安装目录，请用 -AppRoot 指定" }
  $sourceAsar = Join-Path $appRoot "resources\app.asar"
  $sourceUnpacked = Join-Path $appRoot "resources\app.asar.unpacked"
  if (-not (Test-Path -LiteralPath $sourceAsar)) { throw "找不到 $sourceAsar" }

  Ensure-AsarModule
  $version = Read-AsarVersion $sourceAsar
  Log "安装目录版本: $version"

  $isPatched = Test-PatchedAsar $sourceAsar
  $state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } else { $null }
  $installedHash = (Get-FileHash -LiteralPath $sourceAsar -Algorithm SHA256).Hash.ToLower()

  if ($isPatched -and -not $Force) {
    Log "当前已是开发版。"
    if (-not $state -or $state.patchedAsarSha256 -ne $installedHash) {
      $state = [ordered]@{ version = $version; patchedAsarSha256 = $installedHash; appliedAt = (Get-Date).ToString('s'); lastRunAt = (Get-Date).ToString('s'); note = "首次记录（已是开发版）" }
      ($state | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8
      Log "已记录状态到 .auto-state.json"
    } else {
      Log "状态一致，无需处理。"
    }
    Log "===== 结束（无操作） ====="
    exit 0
  }
  if ($isPatched -and $state -and $state.patchedAsarSha256 -eq $installedHash -and -not $Force) {
    Log "开发版且状态一致，结束。"
    exit 0
  }
  Log "检测到官方版（或强制重制），开始重制补丁包 …" -color Cyan

  # 强制重制时，若安装目录已是开发版，优先用留存的官方 asar 作为源（避免拿补丁包再打补丁）
  if ($isPatched) {
    $keepOfficial = Join-Path $PackageRoot ("official\app.asar-" + $version)
    if (Test-Path -LiteralPath $keepOfficial) {
      Log "安装目录已是开发版；改用留存的官方 asar 作为源: official\app.asar-$version"
      $sourceAsar = $keepOfficial
    } else {
      Log "⚠ 未找到留存的官方 asar，将直接对当前（已打补丁的）asar 重跑补丁器（幂等）" -color Yellow
    }
  }
} else {
  $src = Get-SourceFromInstaller $Installer $SourceDir
  $sourceAsar = $src.Asar; $sourceUnpacked = $src.Unpacked; $staging = $src.Staging
  Ensure-AsarModule
  Log "源 asar: $sourceAsar"
}

# ---------- 用通用补丁器重制 ----------
$prebuilt = Join-Path $PackageRoot "prebuilt\app.asar"
$patchedDir = Join-Path $PackageRoot "patched"
Log "运行通用补丁器（自动定位锚点）…"
$args = @(
  (Join-Path $tools "patch-asar.js"),
  "--official-asar", $sourceAsar,
  "--out", $prebuilt,
  "--patched-dir", $patchedDir,
  "--report", $reportFile
)
if (Test-Path -LiteralPath $sourceUnpacked) { $args += @("--unpacked-dir", $sourceUnpacked) }
& node @args
if ($LASTEXITCODE -ne 0) { throw "补丁器执行失败（退出码 $LASTEXITCODE）" }

$reportTxt = [System.IO.Path]::ChangeExtension($reportFile, '.txt')
if (-not (Test-Path -LiteralPath $reportTxt)) { throw "补丁器没有生成摘要文件: $reportTxt" }
$summary = @{}
foreach ($line in (Get-Content -LiteralPath $reportTxt -Encoding UTF8)) {
  $i = $line.IndexOf('=')
  if ($i -gt 0) { $summary[$line.Substring(0, $i)] = $line.Substring($i + 1) }
}
$report = [pscustomobject]@{
  version            = $summary['version']
  headerHash         = $summary['headerHash']
  patchedAsarBytes   = $summary['patchedAsarBytes']
  patchedAsarSha256  = $summary['patchedAsarSha256']
  officialAsarSha256 = $summary['officialAsarSha256']
  unpackDirs         = $summary['unpackDirs']
  touched            = $summary['touched']
  warnings           = $summary['warnings']
}
Log ("重制完成: v{0}  头部哈希 {1}" -f $report.version, $report.headerHash)
if ($report.warnings) { Log ("⚠ " + $report.warnings) -color Yellow }

# 保留一份官方 asar 作为溯源
$officialDir = Join-Path $PackageRoot "official"
New-Item -ItemType Directory -Force -Path $officialDir | Out-Null
$keep = Join-Path $officialDir ("app.asar-" + $report.version)
if (-not (Test-Path -LiteralPath $keep)) {
  Copy-Item -LiteralPath $sourceAsar -Destination $keep -Force
  Log "已留存官方 asar: official\$(Split-Path $keep -Leaf)"
}

# ---------- 应用（本地模式默认应用） ----------
$shouldApply = ($Mode -eq 'local') -and (-not $NoApply)
if ($shouldApply) {
  Log "应用到安装目录 …" -color Cyan
  & (Join-Path $tools "apply-dev.ps1") -AppRoot $appRoot -Asar $prebuilt
  if ($LASTEXITCODE -ne 0) { throw "应用失败（退出码 $LASTEXITCODE）" }
  $installedHash = (Get-FileHash -LiteralPath (Join-Path $appRoot "resources\app.asar") -Algorithm SHA256).Hash.ToLower()
  if (-not $NoLaunch) {
    Log "启动程序 …"
    Start-Process -FilePath (Join-Path $appRoot "mathmodel.exe") | Out-Null
  }
}

# ---------- 状态 & 提交 ----------
$stateObj = [ordered]@{
  version            = $report.version
  patchedAsarSha256  = if ($shouldApply) { $installedHash } else { $report.patchedAsarSha256 }
  headerHash         = $report.headerHash
  officialAsarSha256 = $report.officialAsarSha256
  appliedAt          = (Get-Date).ToString('s')
  lastRunAt          = (Get-Date).ToString('s')
  mode               = $Mode
}
($stateObj | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8
Log "状态已写入 .auto-state.json"

# 记录当前补丁包版本信息（也是给仓库留一个可提交的变化）
$versionFile = Join-Path $PackageRoot "VERSION"
@(
  "patchFor=$($report.version)",
  "headerHash=$($report.headerHash)",
  "officialAsarSha256=$($report.officialAsarSha256)",
  "builtAt=$((Get-Date).ToString('s'))",
  "touched=$($report.touched)"
) | Set-Content -LiteralPath $versionFile -Encoding UTF8

if ($Push) {
  Log "提交并推送补丁包 …" -color Cyan
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # git 的 stderr 警告不应被当成异常
  Push-Location $PackageRoot
  try {
    git add -A 2>&1 | Out-Null
    $changes = @(git status --porcelain 2>$null)
    if ($changes.Count -eq 0) {
      Log "无文件变化，跳过提交。"
    } else {
      $msg = "auto: 重制开发版补丁包 v$($report.version)"
      $uname = (git config user.name); $umail = (git config user.email)
      if (-not $uname) { $uname = $env:USERNAME }
      if (-not $umail) { $umail = "$env:USERNAME@localhost" }
      git -c "user.name=$uname" -c "user.email=$umail" commit -m $msg 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Log "git commit 失败（退出码 $LASTEXITCODE），跳过推送。" -color Yellow
      } else {
        Log ("已提交: " + $msg)
        git push 2>&1 | ForEach-Object { Log ("git: " + $_) }
        if ($LASTEXITCODE -eq 0) { Log "推送完成。" } else { Log "git push 失败（退出码 $LASTEXITCODE）" -color Yellow }
      }
    }
  } catch { Log ("git 提交/推送异常: " + $_.Exception.Message) -color Yellow }
  finally { Pop-Location; $ErrorActionPreference = $prevEap }
}

if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
Log "===== 结束（成功） =====" 
