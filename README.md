# mma-dev — MathModel 桌面版「开发版」轻量改造包

> 适用对象：已在 Windows 上安装 **官方版 MathModel Desktop v0.0.17 (win-x64)** 的用户。
> 效果：去掉 MathModel 账号登录 / 平台积分 / 权益到期门槛，保留本地 Agent 全部核心能力，
> 对话使用你自己配置的大模型 API Key（本地直连），不再依赖 `mathmodel.top` 计费服务。

---

## 一、原理（为什么只需要覆盖 1 个文件 + 修 1 处哈希）

MathModel 桌面版是一个 Electron 应用，业务代码全部在：

```
<安装目录>\resources\app.asar
```

本包只改了 asar 内部的 3 个文件：

| 文件 | 改动 |
| --- | --- |
| `out/main/index.js` | 置空 `chargeDesktopConversation`，取消每条对话的云端积分计费 |
| `out/preload/index.mjs` | 强制启用本地身份（不再走账号登录），entitlements/credits/充值/兑换等桥接改为本地应答 |
| `out/renderer/assets/index-BZ67Cj_J.js` | 界面文案「桌面终生版」→「开发版」等 |

⚠️ **关键坑**：该程序在 exe 末尾内嵌了 `app.asar` 的头部 SHA-256 完整性清单
（内容形如 `[{"file":"resources\\app.asar","alg":"SHA256","value":"<64位hex>"}]`）。
**只要替换了 app.asar，就必须同步改写 exe 里这串哈希**，否则启动立刻崩溃：

```
FATAL: electron\shell\common\asar\asar_util.cc Integrity check failed
```

本包提供的脚本会自动完成「算新哈希 + 原位改写 exe」。

---

## 二、快速应用（推荐，2 分钟）

前提：已安装官方版且**已完全退出**（托盘也没有 mathmodel）。

1. 下载本仓库（或只拷贝 `prebuilt\app.asar` 与 `tools\` 两个目录到本机）。
2. 在仓库目录打开 PowerShell，执行：

```powershell
# 参数一：官方版安装根目录（含 mathmodel.exe）
.\tools\apply-dev.ps1 -AppRoot "C:\Program Files\mathmodel"
```

脚本会：
- 检查并结束正在运行的 mathmodel 进程；
- 把官方 `resources\app.asar` 备份为 `resources\app.asar.official-backup`（仅首次）；
- 用 `prebuilt\app.asar`（开发版归档）覆盖；
- 计算新哈希并原位改写 `mathmodel.exe` 里的完整性清单；
- 提示可重新启动。

3. 双击 `mathmodel.exe` 启动：界面显示本地身份「开发者」+ 徽章「开发版」即成功。

> `prebuilt\app.asar` 基于官方 v0.0.17 (win-x64) 构建；如果你的官方版是**别的版本**，
> 请改用第三节的“重新制作”流程（版本变了直接覆盖会出问题）。

### 手动方式（不想用脚本）
```powershell
# 1) 退出程序后备份并覆盖
Copy-Item "<官方目录>\resources\app.asar" "<官方目录>\resources\app.asar.official-backup" -Force
Copy-Item ".\prebuilt\app.asar" "<官方目录>\resources\app.asar" -Force
# 2) 修 exe 哈希（需要 Node.js 18+）
node .\tools\patch-exe-hash.js "<官方目录>\mathmodel.exe" "<官方目录>\resources\app.asar"
```

---

## 三、官方出新版本后如何重新制作（给维护者/开发用）

前提：Node.js 18+，能联网装 npm 包。

```powershell
# 1) 装一次依赖
npm i @electron/asar
# 2) 用新的官方 app.asar + 本包的 patched 覆盖层，重新生成开发版 asar
node .\tools\rebuild-asar.js "<新官方目录>\resources\app.asar" -o .\prebuilt\app.asar
# 3) 应用：脚本会算新哈希并改写 exe
.\tools\apply-dev.ps1 -AppRoot "<新官方目录>" -Asar .\prebuilt\app.asar
```

`tools\rebuild-asar.js` 做的事：解包官方 asar → 用 `patched\` 下同名文件覆盖 → 用与官方相同的
unpack 规则重打包 → 打印新 asar 的头部哈希（供哈希改写使用）。

若启动仍报 Integrity 崩溃且打印了 `actual` 哈希，说明新版打包器几何有差异，
把日志里那串 64 位 `actual` 传给脚本覆盖：
`node .\tools\patch-exe-hash.js <exe> <asar> -ActualHash <64位hex>`

---

## 四、恢复官方版

- 若执行过 `apply-dev.ps1`：把备份覆盖回去即可
  `Copy-Item "<官方目录>\resources\app.asar.official-backup" "<官方目录>\resources\app.asar" -Force`
  （哈希会回到官方值吗？→ 不会自动回写。最干净的方式是**重装一次官方安装包**；
  exe 被改写的只是末尾一处 64 位 hex，重装即恢复原样。）
- 或直接运行官方安装程序覆盖安装（会同时还原 exe 与 asar）。

---

## 五、使用开发版

1. 启动后无需任何登录；设置里新增你自己的模型供应商 API Key
   （Anthropic / DeepSeek / Kimi / 通义…），选择后即可对话。
2. 数模广场等需要官方账号的联网功能不再可用（无账号体系），不影响本地建模/写论文/绘图等核心功能。
3. 数据目录不变：`%APPDATA%\@mathmodel\desktop`。

## 六、注意事项

- 本包只用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。
- 每次官方更新后需重新制作（见第三节），否则覆盖旧版会被还原为官方行为。
