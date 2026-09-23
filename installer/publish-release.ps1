# publish-release.ps1 — 把封装好的 setup 安装包做成「内置自动更新能识别」的 GitHub Release
#
# 为什么需要它：程序内置的更新检查走 electron-updater 的 github provider，
# 它只认 release 里的 latest.yml（里面记着版本号 / 文件名 / sha512 / 字节数）。
# 光传一个 setup.exe 是不会被识别的。
#
# 用法:
#   .\installer\publish-release.ps1                          # 生成 release 物料（不联网）
#   .\installer\publish-release.ps1 -Version 0.0.23
#   .\installer\publish-release.ps1 -Upload                  # 顺便用 gh 创建 release 并上传
#   .\installer\publish-release.ps1 -Upload -Prerelease      # 作为预发布（不会推送给正式通道）
#
# 产物目录: <包根>\dist\release\
#   mathmodel-<版本>-dev-x64-setup.exe   安装包（改名为 release 里的资产名）
#   latest.yml                           更新清单（自动更新靠它比对版本）
#   SHA256SUMS.txt                       校验和
param(
  [string]$Setup = "",
  [string]$Version = "",
  [string]$Repo = "06xxlin/MathModelAgent-dev",
  [string]$AssetName = "",
  [string]$Notes = "",
  [string]$PackageRoot = "",
  [switch]$Upload,
  [switch]$Prerelease,
  [switch]$Quiet
)

$ErrorActionPreference = "Stop"
function Say([string]$m, [string]$color = "Gray") { if (-not $Quiet) { Write-Host $m -ForegroundColor $color } }

if ($PackageRoot -eq "") { $PackageRoot = Split-Path $PSScriptRoot -Parent }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$dist = Join-Path $PackageRoot "dist"
$relDir = Join-Path $dist "release"

# ---------- 找安装包 ----------
if ($Setup -eq "") {
  $cand = Get-ChildItem -LiteralPath $dist -Filter "*-Setup.exe" -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $cand) { throw "dist 下没有 *-Setup.exe，请先跑 installer\make-setup.ps1" }
  $Setup = $cand.FullName
}
$Setup = (Resolve-Path -LiteralPath $Setup).Path
Say "安装包  : $Setup" Cyan

if ($Version -eq "") {
  $Version = (Get-Item -LiteralPath $Setup).VersionInfo.FileVersion
  if (-not $Version) { throw "读不到安装包版本号，请用 -Version 指定" }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
  throw "版本号必须是 x.y.z（当前 '$Version'）：内置更新用 semver 比对，带后缀会被当成预发布"
}
Say "版本号  : $Version" Cyan

if ($AssetName -eq "") { $AssetName = "mathmodel-$Version-dev-x64-setup.exe" }
if ($AssetName -match '[\\/\s]') { throw "资产名不能有空格或路径分隔符: $AssetName" }

if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') { throw "-Repo 需要 owner/repo 形式（当前: $Repo）" }

# ---------- 生成物料 ----------
New-Item -ItemType Directory -Force -Path $relDir | Out-Null
$assetPath = Join-Path $relDir $AssetName
if ($assetPath -ne $Setup) { Copy-Item -LiteralPath $Setup -Destination $assetPath -Force }

$fi = Get-Item -LiteralPath $assetPath
$sha512 = [System.Security.Cryptography.SHA512]::Create()
$fs = [System.IO.File]::OpenRead($assetPath)
try { $b64 = [Convert]::ToBase64String($sha512.ComputeHash($fs)) } finally { $fs.Close() }
$sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLower()
$releaseDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")

$latest = @(
  "version: $Version",
  "files:",
  "  - url: $AssetName",
  "    sha512: $b64",
  "    size: $($fi.Length)",
  "path: $AssetName",
  "sha512: $b64",
  "releaseDate: '$releaseDate'"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $relDir "latest.yml"), $latest + "`n", (New-Object System.Text.UTF8Encoding($false)))

$sums = @(
  "$sha256  $AssetName",
  "$(($([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.IO.File]::ReadAllBytes((Join-Path $relDir 'latest.yml')))) | ForEach-Object { $_.ToString('x2') }) -join '')  latest.yml"
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $relDir "SHA256SUMS.txt"), $sums + "`n", (New-Object System.Text.UTF8Encoding($false)))

Say ""
Say "release 物料已生成: $relDir" Green
Get-ChildItem -LiteralPath $relDir | ForEach-Object { Say ("  {0,10:N1} MB  {1}" -f ($_.Length / 1MB), $_.Name) Green }
Say ""
Say "latest.yml 内容:" 
$latest -split "`n" | ForEach-Object { Say ("  " + $_) }
Say ""
Say ("sha256({0}) = {1}" -f $AssetName, $sha256)

# ---------- 可选：上传到 GitHub ----------
if ($Upload) {
  $tag = "v$Version-dev"
  $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
  if (-not $gh) { throw "没找到 gh（GitHub CLI）。请先安装：winget install GitHub.cli" }
  $env:GH_PROMPT_DISABLED = '1'
  & $gh auth status *> $null
  if ($LASTEXITCODE -ne 0) { throw "gh 未登录。请先在本机执行一次: gh auth login" }

  if ($Notes -eq "") { $Notes = "MathModel 开发版 v$Version`n`n- 免登录 / 不扣积分 / 后台服务器已切断`n- 内置更新检查指向本仓库 Release" }

  $ghArgs = @('release', 'create', $tag,
    '--repo', $Repo,
    '--title', "MathModel 开发版 v$Version 完整安装包",
    '--notes', $Notes)
  if ($Prerelease) { $ghArgs += '--prerelease' }
  $ghArgs += @($assetPath, (Join-Path $relDir 'latest.yml'), (Join-Path $relDir 'SHA256SUMS.txt'))

  Say ""
  Say "上传到 $Repo ($tag) …" Cyan
  & $gh @ghArgs
  if ($LASTEXITCODE -ne 0) {
    Say "gh release create 失败（可能该 tag 已存在）。可用下面命令改为补传文件：" Yellow
    Say "  gh release upload $tag --repo $Repo --clobber `"$assetPath`" `"$(Join-Path $relDir 'latest.yml')`"" Yellow
    exit 1
  }
  Say ""
  Say "已发布: https://github.com/$Repo/releases/tag/$tag" Green
  Say "注意: 客户端版本号必须低于 $Version 才会看到更新（例如当前 0.0.22 会收到 $Version 的推送）。"
} else {
  Say ""
  Say "下一步（二选一）:" Yellow
  Say "  1) 自动上传:  .\installer\publish-release.ps1 -Upload"
  Say "  2) 手动上传:  到 https://github.com/$Repo/releases/new 建 tag v$Version-dev，"
  Say "                把 $relDir 里的 3 个文件都作为附件传上去（latest.yml 必须有）"
}
