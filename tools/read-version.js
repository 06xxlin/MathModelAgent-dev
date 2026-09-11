#!/usr/bin/env node
// read-version.js — 读取 asar 内 package.json 的版本号
// 用法: node tools/read-version.js <app.asar>
const asar = require('@electron/asar');
try {
  const j = JSON.parse(asar.extractFile(process.argv[2], 'package.json').toString('utf8'));
  process.stdout.write(String(j.version || ''));
} catch (e) {
  process.stdout.write('');
  process.exitCode = 1;
}
