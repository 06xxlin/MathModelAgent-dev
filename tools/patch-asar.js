#!/usr/bin/env node
/**
 * patch-asar.js — 通用补丁器：从「官方 app.asar」自动生成「开发版 app.asar」。
 *
 * 与旧版不同：不再写死混淆后的标识符/十六进制索引，而是先解出字符串表，
 * 按“字符串值”定位锚点，因此官方换版本、重新混淆也能自动适配。
 *
 * 用法:
 *   node tools/patch-asar.js --official-asar <官方 app.asar> --out <输出 asar> \
 *        [--patched-dir <patched 目录>] [--report <json 路径>] [--keep-tree] [--no-isolation]
 *
 * 输出:
 *   - 开发版 app.asar（默认已做网络隔离：切断 https://mathmodel.top 后台 + 停用遥测上报）
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

// 网络隔离：后台基址（https://mathmodel.top）会被替换成这个「本机不可达」地址。
// 端口 9 是 discard 端口，本机没有监听 → 连接瞬时被拒，既不解析域名、也不产生任何外发流量。
// 想保留后台连接（例如排查问题）时加 --no-isolation；也可用 --isolation-sentinel <url> 自定义。
const noIsolation = !!opt('no-isolation', false);
const isolationSentinel = typeof opt('isolation-sentinel') === 'string' ? opt('isolation-sentinel') : 'http://127.0.0.1:9';
const backendUrl = 'https://mathmodel.top';

if (!officialAsar || !outAsar) {
  console.error('用法: node patch-asar.js --official-asar <官方 app.asar> --out <输出 asar> [--patched-dir dir] [--report json] [--no-isolation]');
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
  // 计费锚点有两种写法，先静默尝试、全都失败才报警告：
  //   A. <=0.0.21: this[_0x…(0xHEX)]=_0x…,
  //   B. >=0.0.23: 构造函数里直接用明文键 this["chargeDesktopConversation"]=_0x…,
  const tryChargeReplace = (re) => {
    const g = new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g');
    const n = (mainSrc.match(g) || []).length;
    if (n !== 1) return false;
    mainSrc = mainSrc.replace(g, (mm) => mm.replace(/=_0x[0-9a-fA-F]+,$/, '=null,'));
    return true;
  };
  if (dec) {
    const hexes = Object.keys(dec.map).filter(h => dec.map[h] === 'chargeDesktopConversation');
    report.anchors.chargePropertyHex = hexes;
    for (const h of hexes) {
      // 已是补丁状态（=null,）也算成功，保证可重复运行
      if (new RegExp('this\\[_0x[0-9a-fA-F]+\\(' + h + '\\)\\]=null,').test(mainSrc) ||
          new RegExp('this\\[["\']chargeDesktopConversation["\']\\]=null,').test(mainSrc)) {
        report.anchors['main.charge[' + h + ']'] = 'already-patched';
        patched = true;
        break;
      }
      if (tryChargeReplace(new RegExp('this\\[_0x[0-9a-fA-F]+\\(' + h + '\\)\\]=_0x[0-9a-fA-F]+,'))) {
        report.anchors['main.charge[' + h + ']'] = 'hex-assignment';
        patched = true;
        break;
      }
    }
  }
  if (!patched) {
    if (tryChargeReplace(/this\[["']chargeDesktopConversation["']\]=_0x[0-9a-fA-F]+,/)) {
      report.anchors['main.charge.literal'] = 'literal-assignment';
      patched = true;
    }
  }
  if (!patched) throw new Error('主进程计费锚点未找到（chargeDesktopConversation 赋值）');

  // ---- 网络隔离（1/2）：把后台基址换成不可达的本地地址 ----
  // 所有远端 /api/* 请求（app-config / me / user / credits / collab / telemetry / proxy …）
  // 都由这个基址拼出，换掉它 = 整体断链：请求打到本机未监听端口并立刻失败，
  // 既不解析域名、也不产生任何外发流量。
  //
  // 锚点有两种写法，都要支持（版本无关）：
  //   A. <= 0.0.21：明文出现  Xl = app.isPackaged ? 'https://mathmodel.top' : <校验函数>
  //   B. >= 0.0.22：字符串被搬进 javascript-obfuscator 字符串表，源码里只剩解码调用
  //      Xl = _0x46b75a[_0xfd3c65(0x1521)] ? _0xfd3c65(0x7bf) : function(…)
  //      → 先解表拿到 0x7bf 这种索引，再把所有 X(0x7bf) 调用点换成哨兵字面量。
  if (noIsolation) {
    report.anchors['main.backendBase'] = 'skipped(--no-isolation)';
    console.log('      ⚠ 已按 --no-isolation 跳过后台断链');
  } else {
    const sentinelLiteral = "'" + isolationSentinel + "'";
    if (mainSrc.includes(sentinelLiteral)) {
      report.anchors['main.backendBase'] = 'already-patched';
    } else {
      let blocked = 0;
      const details = [];

      // (A) 明文字面量
      const re = /(['"])https?:\/\/(?:www\.)?mathmodel\.top\1/g;
      const hits = mainSrc.match(re) || [];
      if (hits.length) {
        mainSrc = mainSrc.replace(re, sentinelLiteral);
        blocked += hits.length;
        details.push('literal x' + hits.length);
      }

      // (B) 混淆字符串表
      const baseHexes = [];
      if (dec) {
        for (const [hex, val] of Object.entries(dec.map)) {
          if (typeof val === 'string' && /^https?:\/\/(?:www\.)?mathmodel\.top$/i.test(val)) baseHexes.push(hex);
        }
      }
      for (const hex of baseHexes) {
        const callRe = new RegExp('_0x[0-9a-fA-F]+\\(' + hex + '\\)', 'g');
        const n = (mainSrc.match(callRe) || []).length;
        if (!n) continue;
        mainSrc = mainSrc.replace(callRe, sentinelLiteral);
        blocked += n;
        details.push('stringTable[' + hex + '] x' + n);
      }

      if (blocked) {
        report.anchors['main.backendBase'] = details.join(', ');
        report.backendBlocked = blocked;
        console.log('      后台基址已切断: ' + backendUrl + ' -> ' + isolationSentinel + '（' + details.join('、') + '）');
      } else {
        report.warnings.push('[main.backendBase] 未找到后台基址（明文或字符串表均未命中，断链未生效）');
      }
    }
  }

  // ---- 网络隔离（2/2）：停用遥测批量上报 ----
  // 找到向 /api/desktop/telemetry/batch POST 的那个函数，整体替换为「直接返回成功」，
  // 这样事件不再外发、本地发件箱也不会一直堆积重试。
  // 端点字符串有三种写法，都得认：
  //   A. 混淆字符串表：   await X(_0x…(0x4de), …)
  //   B. 明文单/双引号：  await X('/api/desktop/telemetry/batch', …)   （0.0.23 起）
  if (noIsolation) {
    report.anchors['main.telemetryBatch'] = 'skipped(--no-isolation)';
  } else if (mainSrc.includes('/*dev-notel*/')) {
    report.anchors['main.telemetryBatch'] = 'already-patched';
  } else {
    const TEL_PATH = '/api/desktop/telemetry/batch';
    const telHexes = new Set(['0x8e8', '0x4de']); // 已知历史版本内联索引（兜底）
    if (dec) {
      for (const [hex, val] of Object.entries(dec.map)) {
        if (val === TEL_PATH) telHexes.add(hex);
      }
    }
    // 端点参数的两种形态：<alias>(0xHEX) 或 '明文路径'
    const endpointAlts = [];
    for (const hex of telHexes) endpointAlts.push('_0x[0-9a-fA-F]+\\(' + hex + '\\)');
    endpointAlts.push("'\\/api\\/desktop\\/telemetry\\/batch'");
    endpointAlts.push('"\\/api\\/desktop\\/telemetry\\/batch"');
    const endpointPat = '(?:' + endpointAlts.join('|') + ')';

    let tm = null, telMark = null;
    {
      const strict = new RegExp(
        '(?:async\\s+)?function (\\w+)\\((\\w+)\\)\\{const (\\w+)=_0x[0-9a-fA-F]+(?:\\(\\))?;' +
        'if\\(0x0===\\2\\[\\3\\(0x[0-9a-fA-F]+\\)\\]\\)return!0x0;' +
        'const \\w+=await \\w+\\(' + endpointPat
      );
      const m = strict.exec(mainSrc);
      if (m) { tm = m; telMark = m[0].slice(-40); }
    }

    // 宽松兜底：先找到「await X(<端点>)」调用点，再回退到最近的函数声明
    if (!tm) {
      const callRe = new RegExp('await \\w+\\(' + endpointPat);
      const cm = callRe.exec(mainSrc);
      if (cm) {
        const before = mainSrc.slice(0, cm.index);
        const fm = /(?:async\s+)?function (\w+)\((\w+)\)\{/g;
        let last = null, m2;
        while ((m2 = fm.exec(before))) last = m2;
        if (last) {
          const bodyEnd = extractBalanced(mainSrc, mainSrc.indexOf('{', last.index));
          if (bodyEnd - last.index <= 4000) {
            tm = { index: last.index, 1: last[1], 2: last[2] };
            telMark = 'loose:' + mainSrc.slice(cm.index, cm.index + 40);
          }
        }
      }
    }

    if (!tm) {
      report.warnings.push('[main.telemetryBatch] 未定位到遥测批量上传函数（跳过；断链已由基址替换保证）');
    } else {
      const fnStart = tm.index;
      const fnEnd = extractBalanced(mainSrc, mainSrc.indexOf('{', fnStart));
      mainSrc = mainSrc.slice(0, fnStart) + 'async function ' + tm[1] + '(' + tm[2] + '){return!0x0;/*dev-notel*/}' + mainSrc.slice(fnEnd + 1);
      report.anchors['main.telemetryBatch'] = 'stubbed(' + telMark + ')';
      report.telemetryStubbed = true;
      console.log('      遥测上报已停用: ' + tm[1] + '() → 直接返回成功（事件不再外发）');
    }
  }

  // ---- 自动更新（3/3）：放行「没有代码签名」的开发版更新包 ----
  // 官方 hook 掉了 electron-updater 的 verifyUpdateCodeSignature：安装包内嵌的 publisher
  // 证书不在白名单里就直接拒绝更新。而且官方构建里那个白名单是空数组
  // （源码里是个空字符串占位），等于**任何更新都会被拒**。
  // 我们自制的开发版 setup 没有代码签名（签名要买证书），所以必须把这个钩子改成恒通过，
  // 否则「检查到新版本 → 下载完成 → 安装」最后一步必定失败。
  if (mainSrc.includes('/*dev-nosig*/')) {
    report.anchors['main.verifySign'] = 'already-patched';
  } else {
    const sigHexes = [];
    if (dec) {
      for (const [hex, val] of Object.entries(dec.map)) {
        if (val === 'verifyUpdateCodeSignature') sigHexes.push(hex);
      }
    }
    // 两种属性名写法：
    //   A. <=0.0.21: _0x312d5c[_0x2d97e3(0xb0c)]=(a,b)=>{ ...        （字符串表索引）
    //   B. >=0.0.23: _0x4eab97['verifyUpdateCodeSignature']=(a,b)=>{ ... }（明文，且阻断文案也变成明文）
    const sigPatterns = sigHexes.map(h => '\\[[\\w$]+\\((' + h + ')\\)\\]');
    sigPatterns.push('\\[[\'"]verifyUpdateCodeSignature[\'"]\\]');
    let sigDone = null;
    for (const propPat of sigPatterns) {
      const re = new RegExp(propPat + '=(\\([\\w$,\\s]*\\)|[\\w$]+)=>\\{');
      const m = re.exec(mainSrc);
      if (!m) continue;
      const braceIdx = m.index + m[0].length - 1;
      if (mainSrc[braceIdx] !== '{') continue;
      const end = extractBalanced(mainSrc, braceIdx);
      mainSrc = mainSrc.slice(0, braceIdx) + '{return Promise.resolve(null);/*dev-nosig*/}' + mainSrc.slice(end + 1);
      sigDone = propPat.includes('verifyUpdateCodeSignature') ? 'literal' : m[1];
      break;
    }
    if (sigDone) {
      report.anchors['main.verifySign'] = 'disabled(' + sigDone + ')';
      report.signatureGateDisabled = true;
      console.log('      更新包签名校验已放行（未签名的开发版更新包可正常安装）');
    } else {
      report.warnings.push('[main.verifySign] 未定位到 verifyUpdateCodeSignature 钩子（未签名更新包可能被拒绝）');
    }
  }

  // ---- 自动更新（4/4）：不要把原始报错堆栈丢到界面上 ----
  // 官方把更新失败的原因原样塞进 update state 的 message（是 Error.message，里面常带
  // GitHub 返回的完整 HTTP 头、.method/.url 说明、以及调用栈），渲染层直接整段显示，
  // 用户会看到一大坨英文堆栈。这里只把「给界面看的」文案换成一句人话，
  // 真正的报错依旧由 electron-updater 写进 logs\mathmodel-main.log，排查不受影响。
  if (mainSrc.includes('/*dev-errmsg*/')) {
    report.anchors['main.updateErrorText'] = 'already-patched';
  } else {
    const msgHexes = [];
    if (dec) {
      for (const [hex, val] of Object.entries(dec.map)) {
        if (val === 'message') msgHexes.push(hex);
      }
    }
    const FRIENDLY = '检查更新失败，请稍后重试（详情见日志 mathmodel-main.log）';
    let errHex = null;
    for (const hex of msgHexes) {
      // 形如: function xC(e){const a=_0x…;return e instanceof Error?e[a(0x357)]:String(e);}
      const re = new RegExp(
        'function ([\\w$]+)\\(([\\w$]+)\\)\\{const ([\\w$]+)=_0x[0-9a-fA-F]+;' +
        'return \\2 instanceof Error\\?\\2\\[\\3\\(' + hex + '\\)\\]:String\\(\\2\\);\\}'
      );
      const m = re.exec(mainSrc);
      if (!m) continue;
      const repl =
        'function ' + m[1] + '(' + m[2] + '){' +
        'try{console.error("[desktop-updater] detail: "+(' + m[2] + '&&' + m[2] + '.stack?' + m[2] + '.stack:' + m[2] + '));}catch(_e){}' +
        'return ' + JSON.stringify(FRIENDLY) + ';/*dev-errmsg*/}';
      mainSrc = mainSrc.slice(0, m.index) + repl + mainSrc.slice(m.index + m[0].length);
      errHex = hex;
      break;
    }
    if (errHex) {
      report.anchors['main.updateErrorText'] = 'sanitized(' + errHex + ')';
      console.log('      更新报错文案已简化（原始堆栈只进日志，不再显示在界面上）');
    } else {
      report.warnings.push('[main.updateErrorText] 未定位到更新错误文案函数（界面可能仍显示原始报错）');
    }
  }

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
  // 0.0.21 起该声明可能被并入同一条 const 语句，形如
  //   const{serverPort:Wt,serverToken:Dt}=Ot,Vt=process.argv.includes("--mathmodel-e2e");
  // 前置是逗号而不是 `const `，所以锚点改为「声明分隔符(, ; { 或 const) + 变量名 + 赋值」。
  if (/(?:[,;{]\s*|\bconst\s+)[A-Za-z_$][\w$]*=!0x0;\/\*dev\*\//.test(pre)) {
    report.anchors['preload.e2eFlag'] = 'already-patched';
  } else {
    const r = replaceOnce(pre, /([,;{]\s*|\bconst\s+)([A-Za-z_$][\w$]*)=process\.argv\.includes\(["']--mathmodel-e2e"\)/, '$1$2=!0x0;/*dev*/', 'preload.e2eFlag');
    if (!r.ok) throw new Error('preload 本地身份锚点未找到');
    pre = r.content;
  }

  // 4.2 本地身份显示名
  if (pre.includes('name:"开发者",email:"dev@local.mathmodel"')) {
    report.anchors['preload.identityName'] = 'already-patched';
  } else {
    const r2 = replaceOnce(pre, /name:"E2E User",email:"e2e@localhost\.invalid"/, 'name:"开发者",email:"dev@local.mathmodel"', 'preload.identityName');
    if (r2.ok) pre = r2.content;
    else report.warnings.push('本地身份显示名未替换（可能官方改了假身份字段）');
  }

  // 4.3 账户/权益/积分桥接本地化（已替换过的跳过，保证可重复运行）
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
    const label = 'preload.' + re.source.slice(0, 24);
    if (pre.includes(repl)) { report.anchors[label] = 'already-patched'; continue; }
    const r3 = replaceOnce(pre, re, repl, label);
    if (r3.ok) pre = r3.content;
  }

  // 4.4 提示可能新增的、仍真正调用主进程的 auth 通道
  const known = ['mathmodel:auth-entitlements', 'mathmodel:auth-collab-access-pass', 'mathmodel:auth-credits',
    'mathmodel:auth-cancel-reads', 'mathmodel:auth-pending-notification', 'mathmodel:auth-read-notification',
    'mathmodel:auth-open-recharge', 'mathmodel:auth-redeem', 'mathmodel:auth-credits-changed'];
  const invoked = [...pre.matchAll(/invoke\("(mathmodel:auth-[a-z-]+)"/g)].map(m => m[1]);
  const unknown = [...new Set(invoked)].filter(x => !known.includes(x));
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
if (!rendererChanged) {
  // 已经是开发版文案（「开发版」已存在）就不算问题
  const already = fs.existsSync(assetsDir) && fs.readdirSync(assetsDir).some(f => {
    if (!f.endsWith('.js')) return false;
    return fs.readFileSync(path.join(assetsDir, f), 'utf8').includes('开发版');
  });
  if (!already) report.warnings.push('renderer 文案锚点「桌面终生版」未找到');
}

// ---------------- 5b. 后台域名的文本级清除（界面/预加载/其它文本资源） ----------------
// 渲染层还留着一批指向官网的链接常量（website / home / desktopChangelog / 分享卡片 …）。
// 它们不会自己发请求，但点一下就会带着后台域名出网；这里统一清成哨兵地址，
// 配合 hosts 汇点，做到「界面里也没有任何通往后台的出口」。
if (!noIsolation) {
  const TEXT_EXT = new Set(['.js', '.mjs', '.cjs', '.jsx', '.ts', '.json', '.html', '.htm', '.css', '.txt', '.md']);
  const domainRe = /https?:\/\/(?:www\.)?mathmodel\.top/gi;
  let linkHits = 0;
  const linkFiles = [];
  (function walk(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (ent.name === 'node_modules') continue;
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) { walk(p); continue; }
      if (!TEXT_EXT.has(path.extname(ent.name).toLowerCase())) continue;
      if (fs.statSync(p).size > 32 * 1024 * 1024) continue;
      const c = fs.readFileSync(p, 'utf8');
      const hits = c.match(domainRe);
      if (!hits) continue;
      const rel = path.relative(tree, p).split(path.sep).join('/');
      fs.writeFileSync(p, c.replace(domainRe, isolationSentinel));
      linkHits += hits.length;
      linkFiles.push(rel + ' x' + hits.length);
      if (!report.touched.includes(rel)) report.touched.push(rel);
    }
  })(tree);
  report.backendLinkRewrites = linkHits;
  if (linkHits) {
    console.log('      界面后台链接已清除: ' + linkFiles.join('、'));
  } else if (!report.backendBlocked) {
    report.warnings.push('[renderer.links] 未在界面资源里找到后台域名，请人工确认');
  }
}

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
    'backendBlocked=' + (report.backendBlocked || 0),
    'backendLinkRewrites=' + (report.backendLinkRewrites || 0),
    'telemetryStubbed=' + (report.telemetryStubbed ? 1 : 0),
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
