# mma-dev — MathModel 桌面版「开发版」轻量改造包

> 适用对象：已在 Windows 上安装 **官方版 MathModel Desktop v0.0.17 (win-x64)** 的用户。
> 效果：去掉 MathModel 账号登录 / 平台积分 / 权益到期门槛，保留本地 Agent 全部核心能力，
> 对话使用你自己配置的大模型 API Key（本地直连），不再依赖 `mathmodel.top` 计费服务。

---

## 一、快速应用（推荐，2 分钟）

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

## 二、恢复官方版

- 若执行过 `apply-dev.ps1`：把备份覆盖回去即可
  `Copy-Item "<官方目录>\resources\app.asar.official-backup" "<官方目录>\resources\app.asar" -Force`
  （哈希会回到官方值吗？→ 不会自动回写。最干净的方式是**重装一次官方安装包**；
  exe 被改写的只是末尾一处 64 位 hex，重装即恢复原样。）
- 或直接运行官方安装程序覆盖安装（会同时还原 exe 与 asar）。

---

## 三、使用开发版

1. 启动后无需任何登录；设置里新增你自己的模型供应商 API Key
   （Anthropic / DeepSeek / Kimi / 通义…），选择后即可对话。
2. 数模广场等需要官方账号的联网功能不再可用（无账号体系），不影响本地建模/写论文/绘图等核心功能。
3. 数据目录不变：`%APPDATA%\@mathmodel\desktop`。

## 四、注意事项

- 本包只用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。
