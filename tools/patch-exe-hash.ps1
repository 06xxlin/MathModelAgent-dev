# patch-exe-hash.ps1 — 纯 PowerShell 修正 mathmodel.exe 内嵌的 app.asar 完整性哈希
#
# 用法:
#   .\patch-exe-hash.ps1 -Exe "<安装目录>\mathmodel.exe" -Asar "<安装目录>\resources\app.asar"
#   可选: -ActualHash <64位hex>  (当自动算法不适用时，用崩溃日志里打印的 actual 值覆盖)
#
# 原理: electron-builder 在 exe 内嵌 JSON 清单:
#   [{"file":"resources\\app.asar","alg":"SHA256","value":"<64位hex>"}]
# 该值 = app.asar 头部 JSON 文本（偏移 16 起、长度等于 JSON 本身）的 SHA-256。
# 不匹配时启动即崩: "Integrity check failed for asar archive entry '<header>'"
# 已在 v0.0.17 / v0.0.19 win-x64 实测通过。
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Asar,
  [string]$ActualHash = ""
)

$ErrorActionPreference = "Stop"

function Get-AsarHeaderHash([string]$path) {
  $b = [System.IO.File]::ReadAllBytes($path)
  $start = -1
  $lim = [Math]::Min(64, $b.Length)
  for ($i = 0; $i -lt $lim; $i++) { if ($b[$i] -eq 0x7B) { $start = $i; break } }
  if ($start -lt 0) { throw "未找到 asar 头部 JSON 起点" }
  $depth = 0; $inStr = $false; $esc = $false; $end = -1
  for ($i = $start; $i -lt $b.Length; $i++) {
    $ch = $b[$i]
    if ($inStr) {
      if ($esc) { $esc = $false }
      elseif ($ch -eq 0x5C) { $esc = $true }
      elseif ($ch -eq 0x22) { $inStr = $false }
      continue
    }
    if ($ch -eq 0x22) { $inStr = $true; continue }
    if ($ch -eq 0x7B) { $depth++ }
    elseif ($ch -eq 0x7D) { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { throw "asar 头部 JSON 不完整" }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = $sha.ComputeHash($b, $start, ($end - $start + 1))
  $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
  Write-Host ("  头部 JSON 区间: [{0}, {1}]，长度 {2}" -f $start, $end, ($end - $start + 1))
  return $hex
}

function Find-Bytes([byte[]]$hay, [byte[]]$needle, [int]$from) {
  $limit = $hay.Length - $needle.Length
  for ($i = $from; $i -le $limit; $i++) {
    if ($hay[$i] -ne $needle[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt $needle.Length; $j++) {
      if ($hay[$i + $j] -ne $needle[$j]) { $ok = $false; break }
    }
    if ($ok) { return $i }
  }
  return -1
}

Write-Host "==> 计算 app.asar 头部哈希 …"
$hash = Get-AsarHeaderHash $Asar
if ($ActualHash -ne "") {
  Write-Host "  使用外部提供的 actual 哈希: $ActualHash"
  $hash = $ActualHash
}
if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw "哈希格式不对: $hash" }
Write-Host "  新哈希: $hash"

Write-Host "==> 定位 exe 内嵌完整性清单 …"
$fs = [System.IO.File]::Open($Exe, 'Open', 'ReadWrite')
try {
  $len = $fs.Length
  # 清单在 exe 尾部（约最后 1~2MB），只读尾部窗口即可
  $win = [Math]::Min(8 * 1024 * 1024, $len)
  $base = $len - $win
  $buf = New-Object byte[] $win
  $fs.Position = $base
  $read = 0
  while ($read -lt $win) {
    $n = $fs.Read($buf, $read, $win - $read)
    if ($n -le 0) { break }
    $read += $n
  }
  $marker = [System.Text.Encoding]::ASCII.GetBytes('"file":"resources\\app.asar"')
  $mi = Find-Bytes $buf $marker 0
  if ($mi -lt 0) { throw "exe 中未找到 app.asar 完整性清单（可能版本/打包方式不同）" }
  $vk = [System.Text.Encoding]::ASCII.GetBytes('"value":"')
  $vi = Find-Bytes $buf $vk ($mi + $marker.Length)
  if ($vi -lt 0) { throw "清单中未找到 value 字段" }
  $hexStart = $vi + $vk.Length
  $oldHex = [System.Text.Encoding]::ASCII.GetString($buf, $hexStart, 64)
  if ($oldHex -notmatch '^[0-9a-fA-F]{64}$') { throw "value 不是合法 64 位 hex: $oldHex" }
  if ($oldHex.ToLower() -eq $hash.ToLower()) {
    Write-Host "  哈希已一致，无需修改"
  } else {
    $newBytes = [System.Text.Encoding]::ASCII.GetBytes($hash)
    $fs.Position = $base + $hexStart
    $fs.Write($newBytes, 0, 64)
    $fs.Flush()
    Write-Host "  已改写: $oldHex -> $hash"
  }
} finally { $fs.Close() }

Write-Host "完成，可以启动程序。" -ForegroundColor Green
