#!/usr/bin/env node
/**
 * rebuild-asar.js — 基于「官方 app.asar + 本包 patched 覆盖层」重新制作开发版 asar。
 * 官方发布新版本（>= 0.0.20）后，用这个脚本重新生成 prebuilt/app.asar。
 *
 * 用法:
 *   npm i @electron/asar
 *   node tools/rebuild-asar.js "<官方目录>\resources\app.asar" [-o <输出 asar 路径>]
 *
 * 步骤: 解包官方 asar → 覆盖 patched\ 下的同名文件 → 复制官方 app.asar.unpacked
 *       (native 模块) 回树 → 用与官方相同的 unpack 规则重打包 → 打印头部哈希。
 * 之后用 tools\patch-exe-hash.ps1 (或 .js) 改写 exe 内嵌哈希。
 *
 * 注意: 官方若改动了 out/ 下的文件名（例如 renderer 分包哈希变化），
 *       需要同步更新 patched\ 目录里的文件与 build019.js 中的替换点。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const srcAsar = process.argv[2];
let outAsar = null;
{
  const oi = process.argv.indexOf('-o');
  if (oi >= 0 && process.argv[oi + 1]) outAsar = path.resolve(process.argv[oi + 1]);
}
if (!srcAsar || !fs.existsSync(srcAsar)) {
  console.error('用法: node rebuild-asar.js <官方 app.asar> [-o <输出路径>]');
  process.exit(2);
}
if (!outAsar) outAsar = path.join(root, 'prebuilt', 'app.asar');

let asarPkg;
try {
  asarPkg = require('@electron/asar');
} catch (e) {
  console.error('缺少 @electron/asar，请先执行: npm i @electron/asar');
  process.exit(1);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mma-dev-'));
const exDir = path.join(tmp, 'app');

console.log('[1/5] 解包官方 asar → ' + exDir);
try {
  asarPkg.extractAll(srcAsar, exDir);
} catch (e) {
  console.log('  (忽略 unpacked 条目告警: ' + e.message.split('\n')[0] + ')');
}

console.log('[2/5] 覆盖 patched 文件 …');
const patchedRoot = path.join(root, 'patched');
for (const rel of walk(patchedRoot)) {
  const target = path.join(exDir, rel);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(path.join(patchedRoot, rel), target);
  console.log('      patched/' + rel);
}

console.log('[3/5] 复制官方 native(unpacked) 目录 …');
const officialUnpacked = path.join(path.dirname(srcAsar), 'app.asar.unpacked');
if (fs.existsSync(officialUnpacked)) {
  for (const rel of ['node_modules/better-sqlite3', 'node_modules/node-pty']) {
    const s = path.join(officialUnpacked, rel);
    const d = path.join(exDir, rel);
    if (fs.existsSync(s)) {
      fs.rmSync(d, { recursive: true, force: true });
      fs.cpSync(s, d, { recursive: true });
      console.log('      copy ' + rel);
    }
  }
}

console.log('[4/5] 重打包(与官方相同的 unpack 规则) …');
fs.mkdirSync(path.dirname(outAsar), { recursive: true });
fs.rmSync(outAsar, { force: true });
const cli = path.join(path.dirname(require.resolve('@electron/asar')), '..', 'bin', 'asar.mjs');
execFileSync(process.execPath, [cli, 'pack', exDir, outAsar,
  '--unpack-dir', '{node_modules/better-sqlite3,node_modules/node-pty}'], { stdio: 'inherit' });

console.log('[5/5] 计算头部哈希 …');
const b = fs.readFileSync(outAsar);
const start = b.indexOf(0x7b); // '{'
let depth = 0, end = -1, inStr = false, esc = false;
for (let i = start; i < b.length; i++) {
  const ch = b[i];
  if (inStr) {
    if (esc) esc = false;
    else if (ch === 0x5c) esc = true;
    else if (ch === 0x22) inStr = false;
    continue;
  }
  if (ch === 0x22) { inStr = true; continue; }
  if (ch === 0x7b) depth++;
  else if (ch === 0x7d) { depth--; if (depth === 0) { end = i; break; } }
}
const hash = crypto.createHash('sha256').update(b.slice(start, end + 1)).digest('hex');
console.log('  输出: ' + outAsar + ' (' + b.length + ' 字节)');
console.log('  头部哈希: ' + hash);
console.log('下一步: .\\tools\\patch-exe-hash.ps1 -Exe "<exe路径>" -Asar "' + outAsar + '"');
fs.rmSync(tmp, { recursive: true, force: true });

function walk(d, prefix = '') {
  const out = [];
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const rel = prefix ? prefix + '/' + e.name : e.name;
    if (e.isDirectory()) out.push(...walk(path.join(d, e.name), rel));
    else out.push(rel);
  }
  return out;
}
