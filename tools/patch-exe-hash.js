#!/usr/bin/env node
/**
 * patch-exe-hash.js — 修正 mathmodel.exe 内嵌的 app.asar 完整性哈希。
 *
 * 用法:
 *   node patch-exe-hash.js <mathmodel.exe 路径> <app.asar 路径> [-ActualHash <64位hex>]
 *
 * 原理: electron-builder 在 exe 末尾内嵌 JSON 清单:
 *   [{"file":"resources\\app.asar","alg":"SHA256","value":"<64位hex>"}]
 * 清单值必须等于 app.asar 头部区间的 SHA-256。头部区间算法(已在 v0.0.17 win-x64 上验证):
 *   SHA256( app.asar 字节[16, 16 + (readUInt32LE(4) - 10)) )
 * 若不匹配, 启动即崩: "Integrity check failed for asar archive entry '<header>'".
 */
const fs = require('fs');
const crypto = require('crypto');

const [exePath, asarPath] = process.argv.slice(2);
let argActual = null;
{
  const ai = process.argv.indexOf('-ActualHash');
  if (ai >= 0 && process.argv[ai + 1]) argActual = process.argv[ai + 1];
}
if (!exePath || !asarPath) {
  console.error('用法: node patch-exe-hash.js <exe路径> <asar路径> [-ActualHash <hex>]');
  process.exit(2);
}
const asar = fs.readFileSync(asarPath);
const headerLenField = asar.readUInt32LE(4);
const regionLen = headerLenField - 10;
const start = 16;
if (regionLen <= 0 || start + regionLen > asar.length) {
  console.error('无法解析 asar 头部长度字段 (u32@4=' + headerLenField + ')');
  process.exit(1);
}
let hash = crypto.createHash('sha256').update(asar.slice(start, start + regionLen)).digest('hex');
if (argActual) {
  console.warn('使用外部提供的 actual 哈希覆盖计算值: ' + argActual);
  hash = argActual;
}

let exe = fs.readFileSync(exePath);
// 定位内嵌清单中 app.asar 条目(JSON 里反斜杠是转义后的两个字符)
const marker = Buffer.from('"file":"resources\\\\app.asar"', 'ascii');
const mi = exe.indexOf(marker);
if (mi < 0) {
  console.error('exe 中未找到 app.asar 完整性清单(可能版本/打包方式不同)');
  process.exit(1);
}
const valKey = Buffer.from('"value":"', 'ascii');
const vi = exe.indexOf(valKey, mi);
if (vi < 0) {
  console.error('清单中未找到 value 字段');
  process.exit(1);
}
const oldHex = exe.toString('ascii', vi + valKey.length, vi + valKey.length + 64);
if (!/^[0-9a-f]{64}$/i.test(oldHex)) {
  console.error('value 字段不是合法 64 位 hex: ' + oldHex);
  process.exit(1);
}
if (oldHex.toLowerCase() === hash.toLowerCase()) {
  console.log('哈希已一致(' + hash + ')，无需修改');
} else {
  Buffer.from(hash, 'ascii').copy(exe, vi + valKey.length);
  fs.writeFileSync(exePath, exe);
  console.log('已改写 exe 内嵌哈希:');
  console.log('  旧: ' + oldHex);
  console.log('  新: ' + hash);
}
console.log('完成。现在可以启动 mathmodel.exe。');
