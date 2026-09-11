#!/usr/bin/env node
/**
 * patch-exe-hash.js — 修正 mathmodel.exe 内嵌的 app.asar 完整性哈希。
 *
 * 用法:
 *   node patch-exe-hash.js <mathmodel.exe 路径> <app.asar 路径> [-ActualHash <64位hex>]
 *
 * 原理: electron-builder 在 exe 中内嵌 JSON 清单:
 *   [{"file":"resources\\app.asar","alg":"SHA256","value":"<64位hex>"}]
 * 该值 = app.asar 头部 JSON 文本（从文件偏移 16 开始、长度等于 JSON 字符串本身）的 SHA-256。
 * 不匹配时启动即崩: "Integrity check failed for asar archive entry '<header>'"
 * 已在 v0.0.17 / v0.0.19 win-x64 上实测通过。
 *
 * 注: 早期版本用 "u32@4 - 10" 推测长度, 仅在 JSON 长度为偶数时成立; 现已改为精确 JSON 配对。
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
const start = asar.indexOf(0x7b /* { */, 0);
if (start < 0 || start > 64) {
  console.error('未找到 asar 头部 JSON 起点');
  process.exit(1);
}
let depth = 0, end = -1, inStr = false, esc = false;
for (let i = start; i < asar.length; i++) {
  const ch = asar[i];
  if (inStr) {
    if (esc) esc = false;
    else if (ch === 0x5c /* \ */) esc = true;
    else if (ch === 0x22 /* " */) inStr = false;
    continue;
  }
  if (ch === 0x22) { inStr = true; continue; }
  if (ch === 0x7b) depth++;
  else if (ch === 0x7d) { depth--; if (depth === 0) { end = i; break; } }
}
if (end < 0) {
  console.error('asar 头部 JSON 不完整');
  process.exit(1);
}
const jsonLen = end - start + 1;
let hash = crypto.createHash('sha256').update(asar.slice(start, end + 1)).digest('hex');
console.log(`头部 JSON 区间: [${start}, ${end}]，长度 ${jsonLen}`);
if (argActual) {
  console.warn('使用外部提供的 actual 哈希: ' + argActual);
  hash = argActual;
}

let exe = fs.readFileSync(exePath);
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
  console.log('哈希已一致，无需修改: ' + hash);
} else {
  Buffer.from(hash, 'ascii').copy(exe, vi + valKey.length);
  fs.writeFileSync(exePath, exe);
  console.log('已改写 exe 内嵌哈希:');
  console.log('  旧: ' + oldHex);
  console.log('  新: ' + hash);
}
console.log('完成。现在可以启动 mathmodel.exe。');
