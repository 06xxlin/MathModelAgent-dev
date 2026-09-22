# mma-dev — MathModel 桌面版「开发版」补丁包

给 Windows 上已安装的**官方版 MathModel Desktop**（当前适配 v0.0.21 win-x64）打一个本地开发版：
免登录、不扣平台积分、不受权益到期限制，并**彻底断开与后台服务器 `mathmodel.top` 的联系**。
官方发布新版本后，本包可以自动重制并重新应用。

---

## 特性

- **免登录**：启动即为本地身份，右上角显示「开发者」、徽章「开发版」，无需账号。
- **不扣积分**：单条对话不再走云端计费，也用不着充值 / 兑换。
- **不限权益**：桌面权益、有效期之类的门槛全部本地解锁。
- **断开后台**：不再向后台服务器发送任何请求，遥测上报一并停用。
- **自带模型**：对话使用你在「设置 → 供应商」里自己填的 API Key，直连服务商。
- **跟随官方版本**：官方更新后自动重制补丁并重新应用（可注册计划任务）。
- **可回退**：官方原件有留存，重装官方安装包即可完全还原。

## 运行前提

- Windows + 官方版 MathModel Desktop（当前适配 0.0.21 win-x64）。
- 依赖 **Node.js 18+**；直接用官方安装包制作时还需要 **7-Zip**。
- ⚠️ **补丁包必须放在安装目录之外**：官方更新会整体重写安装目录，放在里面的补丁包会被一并删除。

## 快速开始

**1. 首次应用**

先完全退出 MathModel（托盘里也退出），然后双击：

```
一键应用开发版.bat
```

补丁包不在默认位置时，把安装目录拖到这个 bat 上，或按提示输入路径。

**2. 官方更新后重制**

双击 `检查官方更新并重制.bat`：已是开发版且版本未变就什么都不做；检测到官方版则自动重制并应用。

**3. 让它自动跟着官方走（推荐）**

双击 `安装自动更新任务.bat`，注册「登录时 + 每 60 分钟」的检查任务，之后官方更新完会自动变回开发版。

## 常用命令

| 目的 | 命令 |
| --- | --- |
| 应用开发版 | `.\tools\apply-dev.ps1 -AppRoot "<安装目录>"` |
| 检查官方更新 → 重制 → 应用 | `.\tools\auto-pipeline.ps1` |
| 强制重制（即使已是开发版） | `.\tools\auto-pipeline.ps1 -Force` |
| 重制后不自动启动程序 | `.\tools\auto-pipeline.ps1 -NoLaunch` |
| 用官方安装包制作 | `.\tools\auto-pipeline.ps1 -Mode installer -Installer "D:\下载\mathmodel-setup-0.0.21.exe"` |
| 用已解包的官方目录制作 | `.\tools\auto-pipeline.ps1 -Mode installer -SourceDir "D:\已解包的官方目录"` |
| 注册自动任务 | `.\tools\install-auto-task.ps1 -IntervalMinutes 60` |
| 查看自动任务 | `Get-ScheduledTask -TaskName MathModelAgentDev-AutoPatch` |
| 移除自动任务 | `.\tools\install-auto-task.ps1 -Remove` |

## 隐私：断开后台服务器

开发版默认不再与后台服务器往来：不发请求、不上报遥测。想更彻底时，可以再加一层 DNS 拦截，并清掉本地已经存下的身份痕迹：

| 目的 | 命令 |
| --- | --- |
| 写入 hosts 拦截（需管理员，会弹 UAC） | `.\tools\block-backend.ps1` |
| 撤销 hosts 拦截 | `.\tools\block-backend.ps1 -Remove` |
| 预演清理（不动文件） | `.\tools\purge-local-identity.ps1 -WhatIf` |
| 备份并清理登录态 / 遥测残留 | `.\tools\purge-local-identity.ps1` |

清理只处理 App 自己的状态文件，**不动** `workspace\`、`version-history\`、`sdk-config\`、`codex-home\`、`mathmodel.db`
等你的论文、对话与设置；移除前一律备份到 `%APPDATA%\@mathmodel\_purge-backup-<时间戳>\`。

想恢复后台连接：重制时给补丁器加 `--no-isolation`，并执行 `.\tools\block-backend.ps1 -Remove`。

## 影响范围

- **可用**：本地建模、写论文、绘图、Python / LaTeX 环境、自定义模型 API Key、GitHub 插件、官方自动更新。
- **不可用**：账号中心、权益与积分、数模广场分享 / 阅读、云同步、协作、后台模型代理、飞书 / 微信的后台通道。
- 数据目录不变：`%APPDATA%\@mathmodel\desktop`。

## 恢复官方版

1. 先执行 `.\tools\install-auto-task.ps1 -Remove`（否则任务会把补丁打回来）；
2. 重新运行官方安装包即可完全还原。

---

本包仅用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。

## 欢迎加入
<img width="130" height="230" alt="bd7c2d58d1cc3a5c2f98f3c44f4ac701" src="https://github.com/user-attachments/assets/ba21454b-c830-4da0-918c-5a2fa0f36ea1" />

