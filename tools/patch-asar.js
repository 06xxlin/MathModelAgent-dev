#!/usr/bin/env node
/**
 * patch-asar.js — 通用补丁器：从「官方 app.asar」自动生成「开发版 app.asar」。
 *
 * 与旧版不同：不再写死混淆后的标识符/十六进制索引，而是先解出字符串表，
 * 按“字符串值”定位锚点，因此官方换版本、重新混淆也能自动适配。
 *
 * 用法:
 *   node tools/patch-asar.js --official-asar <官方 app.asar> --out <输出 asar> \
 *        [--patched-dir <patched 目录>] [--report <json 路径>] [--keep-tree]
 *
 * 输出:
 *   - 开发版 app.asar
 *   - patched/ 下被改动的文件（供 rebuild-asar.js / 人工核对）
 *   - report.json：版本、锚点、改动文件、头部哈希、unpack 目录等
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const vm = require('vm');
const { execFileSync } = require('child_process');

// ---------------- 参数 ----------------
const argv = process.argv.slice(2);
function opt(name, def = null) {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : (argv.includes('--' + name) ? true : def);
}
const officialAsar = opt('official-asar');
const outAsar = opt('out');
const patchedDir = opt('patched-dir');
const reportPath = opt('report');
const keepTree = !!opt('keep-tree', false);
const debug = !!opt('debug', false);
const unpackedDirOpt = typeof opt('unpacked-dir') === 'string' ? opt('unpacked-dir') : null;
const allowMissingNatives = !!opt('allow-missing-natives', false);
if (!officialAsar || !outAsar) {
  console.error('用法: node patch-asar.js --official-asar <官方 app.asar> --out <输出 asar> [--patched-dir dir] [--report json]');
  process.exit(2);
}
if (!fs.existsSync(officialAsar)) { console.error('找不到官方 asar: ' + officialAsar); process.exit(2); }

const asar = require('@electron/asar');
const report = { builtAt: new Date().toISOString(), officialAsar, outAsar, anchors: {}, touched: [], warnings: [] };

// ---------------- 工具 ----------------
function extractBalanced(src, openIdx) {
  let depth = 0, i = openIdx, inStr = null;
  for (; i < src.length; i++) {
    const ch = src[i];
    if (inStr) {
      if (ch === '\\') { i++; continue; }
      if (ch === inStr) inStr = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inStr = ch; continue; }
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) return i; }
  }
  throw new Error('括号不配对');
}

/** 解出 javascript-obfuscator 字符串表: 返回 { map: {hex: string}, decodeName } */
function decodeStringTable(src) {
  const am = /function (_0x[0-9a-fA-F]+)\(\)\{const (_0x[0-9a-fA-F]+)=\[/.exec(src);
  if (!am) return null;
  const arrFnStart = am.index;
  const arrFnEnd = extractBalanced(src, src.indexOf('{', arrFnStart));
  const arrFnSrc = src.slice(arrFnStart, arrFnEnd + 1);

  const fnRe = /function (_0x[0-9a-fA-F]+)\((_0x[0-9a-fA-F]+),(_0x[0-9a-fA-F]+)\)\{/g;
  let decSrc = null, decName = null, fm;
  while ((fm = fnRe.exec(src))) {
    const s = fm.index;
    const e = extractBalanced(src, src.indexOf('{', s));
    const body = src.slice(s, e + 1);
    if (body.includes(am[1] + '()')) { decSrc = body; decName = fm[1]; break; }
  }
  if (!decSrc) return null;

  const rotRe = new RegExp('\\(_0x' + am[1].slice(3) + ',(0x[0-9a-fA-F]+)\\)\\);');
  const rc = rotRe.exec(src);
  if (!rc) return null;
  const callEnd = rc.index + rc[0].length;
  const rotStart = src.lastIndexOf('(function(_0x', rc.index);
  const rotSrc = src.slice(rotStart, callEnd);

  const snippet = arrFnSrc + '\n' + decSrc + '\n' + rotSrc;
  const ctx = { console };
  vm.createContext(ctx);
  vm.runInContext(snippet, ctx);
  const dec = ctx[decName];
  if (typeof dec !== 'function') return null;

  const map = {};
  const re = /_0x[0-9a-fA-F]+\((0x[0-9a-fA-F]{2,6})\)/g;
  let m;
  while ((m = re.exec(src))) {
    if (map[m[1]] !== undefined) continue;
    try { map[m[1]] = dec(parseInt(m[1], 16)); } catch { map[m[1]] = null; }
  }
  return { map };
}

function replaceOnce(content, regex, replacement, label) {
  const g = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : regex.flags + 'g');
  const n = (content.match(g) || []).length;
  if (n !== 1) {
    report.warnings.push(`[${label}] 命中 ${n} 处（期望 1）`);
    return { content, ok: false, count: n };
  }
  report.anchors[label] = regex.source;
  return { content: content.replace(regex, replacement), ok: true, count: n };
}

function sha256(buf) { return crypto.createHash('sha256').update(buf).digest('hex'); }

// ---------------- 1. 解包 ----------------
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mma-patch-'));
const tree = path.join(tmp, 'app');
console.log('[1/6] 解包官方 asar …');
try { asar.extractAll(officialAsar, tree); }
catch (e) { console.log('      (忽略 unpacked 条目告警)'); }

const officialUnpacked = unpackedDirOpt || path.join(path.dirname(officialAsar), 'app.asar.unpacked');
const unpackDirs = [];

// --- 从 asar 头部读出「哪些目录被标记为 unpacked」 ---
function readAsarHeader(buf) {
  const start = buf.indexOf(0x7b);
  let depth = 0, end = -1, inStr = false, esc = false;
  for (let i = start; i < buf.length; i++) {
    const ch = buf[i];
    if (inStr) { if (esc) esc = false; else if (ch === 0x5c) esc = true; else if (ch === 0x22) inStr = false; continue; }
    if (ch === 0x22) { inStr = true; continue; }
    if (ch === 0x7b) depth++;
    else if (ch === 0x7d) { depth--; if (depth === 0) { end = i; break; } }
  }
  if (end < 0) throw new Error('asar 头部 JSON 不完整');
  return JSON.parse(buf.slice(start, end + 1).toString('utf8'));
}
function collectUnpackedDirs(header) {
  const dirs = new Set();
  (function walk(node, prefix) {
    if (!node || typeof node !== 'object' || !node.files) return;
    for (const [name, child] of Object.entries(node.files)) {
      const p = prefix ? prefix + '/' + name : name;
      if (child && child.unpacked === true) {
        const segs = p.split('/').filter(Boolean);
        if (segs[0] === 'node_modules' && segs[1]) {
          const pkg = segs[1].startsWith('@') ? segs.slice(0, 3).join('/') : segs.slice(0, 2).join('/');
          dirs.add(pkg);
        }
      }
      walk(child, p);
    }
  })(header, '');
  return [...dirs];
}

{
  const hdr = readAsarHeader(fs.readFileSync(officialAsar));
  const fromHeader = collectUnpackedDirs(hdr);
  for (const d of fromHeader) unpackDirs.push(d);
  if (!unpackDirs.length) {
    // 头部没标 unpacked，则按磁盘目录兜底
    const nm = path.join(officialUnpacked, 'node_modules');
    if (fs.existsSync(nm)) {
      for (const d of fs.readdirSync(nm, { withFileTypes: true })) if (d.isDirectory()) unpackDirs.push('node_modules/' + d.name);
    }
  }
}

if (unpackDirs.length) {
  const have = fs.existsSync(officialUnpacked);
  console.log('[2/6] unpack 目录: ' + unpackDirs.join(', '));
  console.log('      unpacked 源: ' + officialUnpacked + (have ? '' : '  (缺失!)'));
  if (!have && !allowMissingNatives) {
    console.error('\n[错误] 找不到 app.asar.unpacked（native 模块源）。');
    console.error('       用 --unpacked-dir "<安装目录>\\resources\\app.asar.unpacked" 指定，');
    console.error('       或加 --allow-missing-natives 强制继续（会生成缺 native 的不可用包）。');
    process.exit(1);
  }
  for (const rel of unpackDirs) {
    const s = path.join(officialUnpacked, rel);
    const d = path.join(tree, rel);
    if (!fs.existsSync(s)) { console.log('      跳过(源不存在): ' + rel); continue; }
    fs.rmSync(d, { recursive: true, force: true });
    fs.cpSync(s, d, { recursive: true });
  }
} else {
  console.log('[2/6] 该 asar 没有 unpacked 目录');
}
report.unpackDirs = unpackDirs;

// ---------------- 3. 主进程补丁 ----------------
console.log('[3/6] 打主进程补丁 …');
const mainRel = JSON.parse(fs.readFileSync(path.join(tree, 'package.json'), 'utf8')).main.replace(/\\/g, '/');
report.version = JSON.parse(fs.readFileSync(path.join(tree, 'package.json'), 'utf8')).version;
const mainPath = path.join(tree, mainRel);
let mainSrc = fs.readFileSync(mainPath, 'utf8');
{
  const dec = decodeStringTable(mainSrc);
  if (debug) {
    console.log('      debug: 字符串表解码 ' + (dec ? '成功（' + Object.keys(dec.map).length + ' 项）' : '失败'));
    if (dec) {
      const hits = Object.keys(dec.map).filter(h => String(dec.map[h]).includes('chargeDesktop'));
      console.log('      debug: chargeDesktop* 索引 = ' + JSON.stringify(hits.map(h => [h, dec.map[h]])));
    }
    console.log('      debug: 原文是否含字面量 chargeDesktopConversation = ' + mainSrc.includes('chargeDesktopConversation'));
    const m = /this\[_0x[0-9a-fA-F]+\(0x[0-9a-fA-F]+\)\]=_0x[0-9a-fA-F]+,/.exec(mainSrc);
    console.log('      debug: 首个 this[_0x..(0x..)]=_0x.., 片段 = ' + (m ? m[0] : '(无)'));
  }
  let patched = false;
  if (dec) {
    const hexes = Object.keys(dec.map).filter(h => dec.map[h] === 'chargeDesktopConversation');
    report.anchors.chargePropertyHex = hexes;
    for (const h of hexes) {
      // 已是补丁状态（=null,）也算成功，保证可重复运行
      if (new RegExp('this\\[_0x[0-9a-fA-F]+\\(' + h + '\\)\\]=null,').test(mainSrc)) {
        report.anchors['main.charge[' + h + ']'] = 'already-patched';
        patched = true;
        break;
      }
      const re = new RegExp('this\\[_0x[0-9a-fA-F]+\\(' + h + '\\)\\]=_0x[0-9a-fA-F]+,');
      const r = replaceOnce(mainSrc, re, (mm) => mm.replace(/=_0x[0-9a-fA-F]+,$/, '=null,'), `main.charge[${h}]`);
      if (r.ok) { mainSrc = r.content; patched = true; break; }
    }
  }
  if (!patched) {
    const re = /this\[["']chargeDesktopConversation["']\]=_0x[0-9a-fA-F]+,/;
    const r = replaceOnce(mainSrc, re, (mm) => mm.replace(/=_0x[0-9a-fA-F]+,$/, '=null,'), 'main.charge.literal');
    if (r.ok) { mainSrc = r.content; patched = true; }
  }
  if (!patched) throw new Error('主进程计费锚点未找到（chargeDesktopConversation 赋值）');
  fs.writeFileSync(mainPath, mainSrc);
  report.touched.push(mainRel);
}

// ---------------- 4. preload 补丁 ----------------
console.log('[4/6] 打 preload 补丁（本地身份 + 账户桥接本地化）…');
let preRel = null;
for (const cand of ['out/preload/index.mjs', 'out/preload/index.js']) {
  if (fs.existsSync(path.join(tree, cand))) { preRel = cand; break; }
}
if (!preRel) throw new Error('找不到 preload 文件');
const prePath = path.join(tree, preRel);
let pre = fs.readFileSync(prePath, 'utf8');
{
  // 4.1 强制本地身份（免登录）：把 --mathmodel-e2e 判定改为恒真
  const r = replaceOnce(pre, /const (\w+)=process\.argv\.includes\("--mathmodel-e2e"\);/, 'const $1=!0x0;/*dev*/', 'preload.e2eFlag');
  if (!r.ok) throw new Error('preload 本地身份锚点未找到');
  pre = r.content;

  // 4.2 本地身份显示名
  const r2 = replaceOnce(pre, /name:"E2E User",email:"e2e@localhost\.invalid"/, 'name:"开发者",email:"dev@local.mathmodel"', 'preload.identityName');
  if (!r2.ok) report.warnings.push('本地身份显示名未替换（可能官方改了假身份字段）');
  else pre = r2.content;

  // 4.3 账户/权益/积分桥接本地化
  const stubs = [
    [/getEntitlements:\(\)=>\w+\.invoke\("mathmodel:auth-entitlements"\)/,
      'getEntitlements:async()=>({ok:!0x0,active:!0x0,lifetime:!0x0,source:"purchase",plan:"pro",expiresAt:null,error:null})'],
    [/getCollabAccessPass:\w+=>\w+\.invoke\("mathmodel:auth-collab-access-pass",\w+\)/,
      'getCollabAccessPass:async()=>({ok:!0x1,error:"dev_mode"})'],
    [/getCredits:\(\)=>\w+\.invoke\("mathmodel:auth-credits"\)/,
      'getCredits:async()=>({summary:{balanceCredits:0x5f5e0ff,usedCredits:0x0,coveredByEntitlement:!0x0}})'],
    [/getPendingNotification:\(\)=>\w+\.invoke\("mathmodel:auth-pending-notification"\)/,
      'getPendingNotification:async()=>({ok:!0x0,acknowledged:!0x0,notification:null})'],
    [/openRecharge:\(\)=>\w+\.invoke\("mathmodel:auth-open-recharge"\)/,
      'openRecharge:async()=>null'],
    [/redeem:\w+=>\w+\.invoke\("mathmodel:auth-redeem",\w+\)/,
      'redeem:async()=>({ok:!0x1,error:"disabled_in_dev_mode"})'],
    [/cancelPendingReads:\(\)=>\w+\.invoke\(\w+\)/,
      'cancelPendingReads:async()=>null'],
  ];
  for (const [re, repl] of stubs) {
    const r3 = replaceOnce(pre, re, repl, 'preload.' + re.source.slice(0, 24));
    if (r3.ok) pre = r3.content;
  }

  // 4.4 提示可能新增的、仍走主进程的 auth 通道
  const left = [...pre.matchAll(/mathmodel:auth-[a-z-]+/g)].map(m => m[0]);
  const known = ['mathmodel:auth-entitlements', 'mathmodel:auth-collab-access-pass', 'mathmodel:auth-credits',
    'mathmodel:auth-cancel-reads', 'mathmodel:auth-pending-notification', 'mathmodel:auth-read-notification',
    'mathmodel:auth-open-recharge', 'mathmodel:auth-redeem', 'mathmodel:auth-credits-changed'];
  const unknown = [...new Set(left)].filter(x => !known.includes(x));
  if (unknown.length) report.warnings.push('preload 中仍存在未本地化的 auth 通道（请人工确认）: ' + unknown.join(', '));

  fs.writeFileSync(prePath, pre);
  report.touched.push(preRel);
}

// ---------------- 5. renderer 文案 ----------------
console.log('[5/6] 打 renderer 文案补丁 …');
const assetsDir = path.join(tree, 'out/renderer/assets');
let rendererChanged = 0;
if (fs.existsSync(assetsDir)) {
  for (const f of fs.readdirSync(assetsDir)) {
    if (!f.endsWith('.js')) continue;
    const fp = path.join(assetsDir, f);
    let c = fs.readFileSync(fp, 'utf8');
    if (c.includes('桌面终生版')) {
      c = c.split('桌面终生版').join('开发版');
      fs.writeFileSync(fp, c);
      report.touched.push('out/renderer/assets/' + f);
      rendererChanged++;
    }
  }
}
if (!rendererChanged) report.warnings.push('renderer 文案锚点「桌面终生版」未找到');

// ---------------- 6. 重新打包 ----------------
console.log('[6/6] 重新打包 …');
fs.mkdirSync(path.dirname(outAsar), { recursive: true });
fs.rmSync(outAsar, { force: true });
const cli = path.join(path.dirname(require.resolve('@electron/asar')), '..', 'bin', 'asar.mjs');
const packArgs = [cli, 'pack', tree, outAsar];
if (unpackDirs.length) packArgs.push('--unpack-dir', '{' + unpackDirs.join(',') + '}');
execFileSync(process.execPath, packArgs, { stdio: 'inherit' });

// 头部哈希（Electron 完整性校验用）
const b = fs.readFileSync(outAsar);
const start = b.indexOf(0x7b);
let depth = 0, end = -1, inStr = false, esc = false;
for (let i = start; i < b.length; i++) {
  const ch = b[i];
  if (inStr) { if (esc) esc = false; else if (ch === 0x5c) esc = true; else if (ch === 0x22) inStr = false; continue; }
  if (ch === 0x22) { inStr = true; continue; }
  if (ch === 0x7b) depth++;
  else if (ch === 0x7d) { depth--; if (depth === 0) { end = i; break; } }
}
report.headerHash = sha256(b.slice(start, end + 1));
report.patchedAsarBytes = b.length;
report.patchedAsarSha256 = sha256(b);
report.officialAsarSha256 = sha256(fs.readFileSync(officialAsar));
console.log('  输出: ' + outAsar + ' (' + b.length + ' 字节)');
console.log('  头部哈希: ' + report.headerHash);

// 导出被改动文件
if (patchedDir) {
  fs.rmSync(patchedDir, { recursive: true, force: true });
  for (const rel of report.touched) {
    const s = path.join(tree, rel);
    const d = path.join(patchedDir, rel);
    fs.mkdirSync(path.dirname(d), { recursive: true });
    fs.copyFileSync(s, d);
  }
  console.log('  已导出改动文件到 ' + patchedDir + '（' + report.touched.length + ' 个）');
}

if (reportPath) {
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
  // 同时写 key=value 旁路文件：供 PowerShell / bat 简单读取（避免 JSON 转义与编码问题）
  const txt = reportPath.replace(/\.json$/i, '') + '.txt';
  const lines = [
    'version=' + (report.version || ''),
    'headerHash=' + (report.headerHash || ''),
    'patchedAsarBytes=' + (report.patchedAsarBytes || ''),
    'patchedAsarSha256=' + (report.patchedAsarSha256 || ''),
    'officialAsarSha256=' + (report.officialAsarSha256 || ''),
    'unpackDirs=' + (report.unpackDirs || []).join(','),
    'touched=' + (report.touched || []).join(','),
    'warnings=' + (report.warnings || []).join(' | '),
  ];
  fs.writeFileSync(txt, lines.join('\r\n') + '\r\n');
  console.log('  报告: ' + reportPath);
  console.log('  摘要: ' + txt);
}
if (!keepTree) fs.rmSync(tmp, { recursive: true, force: true });
else console.log('  工作树保留: ' + tree);

if (report.warnings.length) {
  console.log('\n⚠ 警告:');
  for (const w of report.warnings) console.log('  - ' + w);
}
console.log('\n完成。');
