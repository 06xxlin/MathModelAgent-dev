# mma-dev — MathModel 桌面版「开发版」补丁包

给 Windows 上已安装的**官方版 MathModel Desktop**（当前适配 v0.0.22 win-x64）打一个本地开发版：
免登录、不扣平台积分、不受权益到期限制，并**彻底断开与后台服务器 `mathmodel.top` 的联系**。
官方发布新版本后，本包可以自动重制并重新应用。

---

## 特性

- **免登录**：启动即为本地身份，右上角显示「开发者」、徽章「开发版」，无需账号。
- **不扣积分**：单条对话不再走云端计费，也用不着充值 / 兑换。
- **不限权益**：桌面权益、有效期之类的门槛全部本地解锁。
- **断开后台**：不再向后台服务器发送任何请求，遥测上报一并停用。
- **自带模型**：对话使用你在「设置 → 供应商」里自己填的 API Key，直连服务商。
- **更新走自己的仓库**：内置的「检查更新」已从官方仓库改成你自己的 GitHub Release，
  发布新版本后客户端能自己发现并升级（见下节）。
- **跟随官方版本**：官方更新后自动重制补丁并重新应用（可注册计划任务）。
- **可回退**：官方原件有留存，重装官方安装包即可完全还原。

## 运行前提

- Windows + 官方版 MathModel Desktop（当前适配 0.0.22 win-x64）。
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

**4. 封装成一个 setup 安装包（分发给别的机器）**

双击 `封装安装包.bat`，或用：

| 目的 | 命令 |
| --- | --- |
| 默认（自动找安装目录与版本） | `.\installer\make-setup.ps1` |
| 指定安装目录 / 版本 / 输出 | `.\installer\make-setup.ps1 -AppRoot "D:\xx\mathmodel" -Version 0.0.22 -OutFile "D:\发布\MathModel-Setup.exe"` |
| 保留暂存目录（排查用） | `.\installer\make-setup.ps1 -KeepStage` |

产物默认落在 `dist\MathModel-<版本>-开发版-Setup.exe`（约 350 MB，单文件、离线、免管理员）。

它做的事：把**当前已打好补丁的安装目录**整体打包成 NSIS 安装包 ——
装完即开发版（免登录 / 不扣积分 / 后台已切断），带桌面与开始菜单快捷方式、
「应用和功能」卸载入口、以及 `dev-tools\`（后台拦截脚本 + 使用说明）。

> 分发前请确认源安装目录已经是开发版：脚本会校验 `app.asar` 里的 `/*dev*/` 标记，不是开发版会直接报错退出。

## 内置自动更新（指向你自己的 GitHub Release）

程序自带的「检查更新」由 electron-updater 驱动，配置在 `resources\app-update.yml`。
打补丁时会把它从官方仓库改成你的仓库（默认 `06xxlin/MathModelAgent-dev`）：

```yaml
owner: 06xxlin
repo: MathModelAgent-dev
provider: github
releaseType: release
channel: latest
```

补丁器同时会**放行未签名的更新包**。官方 hook 掉了 electron-updater 的
`verifyUpdateCodeSignature`：安装包内嵌的 publisher 证书不在白名单里就直接拒绝更新，
而官方构建里那个白名单甚至是空数组（源码里是个空字符串占位），等于**任何更新都会被拒**。
我们自制的安装包没有代码签名，不放行的话「检查到新版本 → 下载完成 → 安装」最后一步必定失败。

**发布一个新版本（客户端才能收到更新）**

```powershell
# 1) 重制开发版并应用（会带上新的 app-update.yml）
.\tools\auto-pipeline.ps1 -Force -NoLaunch
# 2) 封装安装包
.\installer\make-setup.ps1
# 3) 生成 latest.yml 并发布到 GitHub Release（需先 gh auth login）
.\installer\publish-release.ps1 -Upload
```

`publish-release.ps1` 产出 `dist\release\`：

| 文件 | 作用 |
| --- | --- |
| `mathmodel-<版本>-dev-x64-setup.exe` | 安装包（已改名成 release 里的资产名） |
| `latest.yml` | **必须有**：版本号 / 文件名 / sha512 / 字节数，客户端靠它比对版本 |
| `SHA256SUMS.txt` | 校验和 |

> 关键：**客户端版本号必须低于 latest.yml 里的版本**才会看到更新。
> 例如现在装的是 0.0.22，就发 0.0.23；只传 setup.exe、不传 latest.yml 是识别不到的。

装好之后的更新链路（安装包会处理 electron-updater 传的 `--updated` / `--force-run`：
跳过向导页、装完自动重启）：

```
启动 → 检查更新 → 比对 latest.yml → 下载 → 校验 sha512 → 放行签名 → quitAndInstall
     → setup.exe --updated --force-run → 覆盖安装 → 自动重启
```

**换仓库**：给 `auto-pipeline.ps1` / `apply-dev.ps1` 传 `-UpdateRepo owner/repo`
（`-UpdateRepo -` 表示保留官方更新源）。

## 隐私：断开后台服务器

开发版默认不再与后台服务器往来：不发请求、不上报遥测。想更彻底时，可以再加一层 DNS 拦截，并清掉本地已经存下的身份痕迹：

**补丁层面切断了什么**（重制时自动完成，日志里有逐条记录）：

| 目标 | 做法 |
| --- | --- |
| 后台基址 `https://mathmodel.top` | 主进程里改成 `http://127.0.0.1:9`（本机未监听的 discard 端口），`/api/*` 全部随之失效 |
| 官方 0.0.22 起把该地址藏进混淆字符串表 | 补丁器先解字符串表拿到索引，再把所有解码调用点换成哨兵地址（不再依赖明文锚点） |
| 遥测批量上报 `/api/desktop/telemetry/batch` | 对应函数整体替换为「直接返回成功」，事件不再外发、本地发件箱不再堆积 |
| 界面里的官网链接（website / home / changelog / 分享卡片） | 文本级清除为哨兵地址，点不出去 |
| 更新包签名白名单 | 改写成恒通过，否则未签名的开发版更新包装不上（详见上一节） |
| 域名解析 | hosts 把 `mathmodel.top` / `www.mathmodel.top` 指向 `0.0.0.0`（汇点） |

**仍然会出网、但与本项目无关的请求**（如需一并封掉请告知）：

- `github.com` / `api.github.com` / `objects.githubusercontent.com` —— **你自己的更新检查**：
  查 `06xxlin/MathModelAgent-dev` 的 Release、下载新版安装包。这是自动更新的载体本身；
  想关掉可在环境变量里设 `MATHMODEL_DISABLE_AUTO_UPDATE=1`，或用
  `dev-tools\switch-auto-update.ps1 -Disable`。**它不会访问 `mathmodel.top`。**
- `models.dev` —— 第三方模型目录（供应商/模型列表校准）。
- 你自己在「设置 → 供应商」里配置的模型服务商 API（Anthropic / DeepSeek / …），这是对话本身要用的。

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

## 版本适配记录

| 官方版本 | 安装目录 | 备注 |
| --- | --- | --- |
| 0.0.17 ~ 0.0.19 | `%LOCALAPPDATA%\Programs\@mathmodeldesktop` | 初版补丁，锚点写死在混淆标识符上 |
| 0.0.20 ~ 0.0.21 | 同上 | 改为「解字符串表 → 按字符串值定位锚点」 |
| 0.0.22 | `%LOCALAPPDATA%\Programs\mathmodel`（目录名变了） | 后台基址被搬进混淆字符串表，补丁器改为「解表拿索引 → 替换所有解码调用点」；`Resolve-AppRoot` 增加注册表探测，自动兼容两种目录名 |

## 恢复官方版

1. 先执行 `.\tools\install-auto-task.ps1 -Remove`（否则任务会把补丁打回来）；
2. 重新运行官方安装包即可完全还原。

---

本包仅用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。

## 欢迎加入
<img width="130" height="230" alt="bd7c2d58d1cc3a5c2f98f3c44f4ac701" src="https://github.com/user-attachments/assets/ba21454b-c830-4da0-918c-5a2fa0f36ea1" />

