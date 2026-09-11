# mma-dev — MathModel 桌面版「开发版」补丁包（0.0.19，支持自动更新）

> 适用：Windows 上安装的**官方版 MathModel Desktop**（当前基线 v0.0.19 win-x64）。
> 效果：去掉 MathModel 账号登录 / 平台积分 / 权益到期门槛，保留本地 Agent 全部核心能力，
> 对话使用你自己配置的模型 API Key（本地直连），不再依赖 `mathmodel.top` 计费服务。
> 官方发布新版本时，本包可**自动重制并重新应用**（见第三节）。

---

## 一、一键应用（第一次装补丁）

1. 先完全退出 MathModel（托盘里也退出）。
2. 双击补丁包根目录的：

```
一键应用开发版.bat
```

自动完成：结束残留进程 → 备份官方 `app.asar`（`app.asar.official-backup`）→ 覆盖为开发版 →
改写 `mathmodel.exe` 内嵌完整性哈希 → 启动程序。

- 默认位置 `<安装目录>\补丁包\MathModelAgent-dev` 会自动识别安装目录；
- 放在别处时：把**安装目录拖到 bat 上**，或按提示输入路径；
- 等价 PowerShell：`.\tools\apply-dev.ps1 -AppRoot "C:\...\@mathmodeldesktop"`

启动后右上角显示「开发者」、徽章「开发版」即为成功（无需登录）；随后在
**设置 → 供应商** 填自己的 API Key 即可对话。

---

## 二、手动「检查官方更新并重制」

双击 `检查官方更新并重制.bat`（或 `.\tools\auto-pipeline.ps1`）：

- 如果安装目录已是开发版且版本未变 → 什么都不做；
- 如果检测到官方版（官方自动更新完成 / 你重装了官方版）→ 自动重制补丁包并重新应用。

常用参数：

```powershell
.\tools\auto-pipeline.ps1 -Force                  # 强制重制（即使已是开发版）
.\tools\auto-pipeline.ps1 -Push                   # 重制后自动 git commit + push
.\tools\auto-pipeline.ps1 -NoLaunch               # 应用后不自动启动程序
.\tools\auto-pipeline.ps1 -Mode installer -Installer "D:\下载\mathmodel-setup-0.0.20.exe"
.\tools\auto-pipeline.ps1 -Mode installer -SourceDir "D:\已解包的官方目录"   # 手动解包后制作
```

---

## 三、自动更新（推荐，已可一键安装）

原理：官方 App 自带 electron-updater，会自动下载安装官方新版本（此时安装目录变回官方版），
本包的计划任务**每 N 分钟 / 每次登录**检查一次：

```
检查安装目录 app.asar 是否含开发版标记 /*dev*/
   ├─ 是开发版且与记录一致  → 什么都不做
   └─ 是官方版（刚更新完）  → 自动重制补丁包（patched/ + prebuilt/）
                            → 自动应用回开发版（含 exe 哈希修正）
                            → 自动重启程序
                            → 可选: git commit + push
```

安装计划任务（普通权限即可）：

- 双击 `安装自动更新任务.bat`，或
- `.\tools\install-auto-task.ps1 -IntervalMinutes 60`（也可加 `-Push` 自动提交到仓库）

其它：

```powershell
.\tools\install-auto-task.ps1 -Remove      # 移除自动任务
Get-ScheduledTask -TaskName MathModelAgentDev-AutoPatch   # 查看任务
```

日志：`logs\auto-YYYYMMDD.log`；状态：`.auto-state.json`；
官方原件留存：`official\app.asar-<版本>`（用于溯源/回退对照）。

依赖：**Node.js 18+**（补丁器要用；脚本首次运行会自动 `npm i @electron/asar`）。
`installer` 模式解包官方安装包还需要 **7-Zip**（没有则用 `-SourceDir` 手动解包）。

---

## 四、原理（为什么必须同时改 2 处）

MathModel 桌面版是 Electron 应用，业务代码在 `<安装目录>\resources\app.asar`。
补丁只改 asar 内 3 个文件（由 `tools/patch-asar.js` 自动定位锚点）：

| 文件 | 改动 |
| --- | --- |
| `out/main/index.js` | `chargeDesktopConversation` 置空 → 取消每条对话的云端积分计费 |
| `out/preload/index.mjs` | 强制启用本地身份（免登录）；`entitlements / credits / 充值 / 兑换 / 通知 / cancelPendingReads` 等桥接改为本地应答 |
| `out/renderer/assets/index-*.js` | 文案「桌面终生版」→「开发版」 |

⚠️ **关键坑**：exe 内嵌 `app.asar` 头部完整性清单：

```
[{"file":"resources\\app.asar","alg":"SHA256","value":"<64位hex>"}]
```

**只替换 app.asar 而不改这串哈希，启动会立刻崩溃**：

```
FATAL: electron\shell\common\asar\asar_util.cc Integrity check failed
```

哈希算法：`SHA256(app.asar 头部 JSON 文本)`（偏移 16 起、长度等于 JSON 本身）。
`tools/patch-exe-hash.ps1`（纯 PowerShell，无需 Node）与 `patch-exe-hash.js`（Node 版）已实现。

### 锚点自动识别（版本升级无需手改）

`patch-asar.js` 先解出 javascript-obfuscator 的字符串表，再按**字符串值**（如
`chargeDesktopConversation`）反查十六进制索引定位锚点；preload 用正则匹配
`--mathmodel-e2e` 判定与 `mathmodel:auth-*` 桥接；renderer 按文案匹配。因此官方重新混淆、
换版本也能自动适配；若官方新增了未本地化的 `auth-*` 通道，脚本会在报告里给出 ⚠ 警告。

---

## 五、恢复官方版

- 重新运行官方安装包即可（同时还原 `app.asar` 与 exe 哈希）；
- 或把 `resources\app.asar.official-backup` 覆盖回 `resources\app.asar` 后重装一次官方版
  （exe 里被改写的只是一处 64 位 hex，重装最省事）；
- 别忘了 `.\tools\install-auto-task.ps1 -Remove` 先移除自动任务，否则它会把补丁再打回来。

---

## 六、目录结构

```
MathModelAgent-dev/
├─ 一键应用开发版.bat          # 首次应用补丁
├─ 检查官方更新并重制.bat      # 手动检查官方更新 → 自动重制+应用
├─ 安装自动更新任务.bat        # 注册计划任务（登录时 + 每 N 分钟）
├─ prebuilt/app.asar           # 开发版 asar（当前基线版本）
├─ patched/                    # 相对官方被改动的文件（供审阅/重建）
├─ official/                   # 官方 asar 留存（自动生成，不入库）
├─ tools/
│  ├─ apply-dev.ps1            # 应用补丁（备份 + 覆盖 + 修哈希）
│  ├─ patch-exe-hash.ps1/.js   # 修正 exe 内嵌完整性哈希
│  ├─ patch-asar.js            # 通用补丁器：官方 asar → 开发版 asar（自动锚点）
│  ├─ rebuild-asar.js          # 用 patched/ 覆盖层重建（等价流程，兼容旧用法）
│  ├─ auto-pipeline.ps1        # 自动流水线（检测→重制→应用→可选提交）
│  ├─ install-auto-task.ps1    # 注册/移除计划任务（schtasks + XML，无需管理员）
│  └─ read-version.js          # 读取 asar 内版本号
└─ logs/, .auto-state.json     # 运行日志与状态（自动生成，不入库）
```

---

## 七、注意事项

- 需要官方账号的联网功能（数模广场分享/阅读额度、账号中心、云同步等）在开发版中不可用，
  不影响本地建模、写论文、绘图、运行 Python/LaTeX 等核心能力。
- 本包仅用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。
- 数据目录不变：`%APPDATA%\@mathmodel\desktop`。
