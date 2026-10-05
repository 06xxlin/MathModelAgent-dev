# mma-dev — MathModel 桌面版「开发版」补丁包

把 Windows 上安装的**官方版 MathModel Desktop** 就地改造成一个本地开发版：
免登录、不扣平台积分、不受权益门槛限制、**彻底不连后台服务器**，
并且把「检查更新」和「局域网协作」这两个原本依赖后台的功能改成本地自给。

当前适配：**v0.0.23 win-x64**（安装目录 `%LOCALAPPDATA%\Programs\@mathmodeldesktop`）
官方发新版本后，本包可以自动重制并重新应用 —— 详见 [官方更新后重制](#官方更新后重制)。

> 仅用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。

---

## 它把什么改掉了

补丁全部打在 `resources\app.asar`（主进程 / preload / 渲染层）和 `resources\app-update.yml` 上，
每次重制都会在日志里逐条报告命中情况：

| # | 改动 | 原因 |
| --- | --- | --- |
| 1 | **免登录**：内置本地身份「开发者」 | 官方启动要 MathModel 账号，走 better-auth 远程登录 |
| 2 | **不扣积分**：`chargeDesktopConversation` 置空 | 每条消息都要调云端计费接口，没积分就发不出去 |
| 3 | **解锁权益**：权益/积分桥接改为本地应答 | 官方要查权益到期、余额、充值、兑换码 |
| 4 | **断后台**：后台基址 `https://mathmodel.top` → `http://127.0.0.1:9` | 所有 `/api/*` 都由这个基址拼出来，换掉即整体断链 |
| 5 | **停遥测**：批量上报函数直接返回成功 | 否则一直往外发事件、本地发件箱还会堆积重试 |
| 6 | **更新走自己仓库**：`app-update.yml` 指向你的 GitHub Release | 官方更新会把开发版覆盖回官方版 |
| 7 | **放行未签名更新包** | 官方 hook 了签名校验且白名单是空的，等于**任何更新都被拒** |
| 8 | **局域网协作本地化**：access pass 改为本机签发 + 本机校验 | 官方开房/加入都要后台签发和验签，后台一断功能直接废掉 |
| 9 | **界面清理**：官网链接改成哨兵地址、文案「桌面终生版」→「开发版」 | 点一下就会带着后台域名出网 |

## 特性

- **免登录**：启动即为本地身份，右上角显示「开发者」、徽章「开发版」。
- **不扣积分 / 不限权益**：不充值、不兑换、不会过期。
- **自带模型**：对话用你在「设置 → 供应商」里填的 API Key，直连服务商。
- **不连后台**：程序里**不存在** `mathmodel.top` 这个字符串，DNS 也被打到 `0.0.0.0`（双保险）。
- **自动更新跟自己的仓库走**：发 Release 即可推送新版本给所有客户端。
- **局域网协作可用**：同一 WiFi / 手机热点下多人协作，已改为纯本地授权。
- **跟随官方版本**：官方更新后一键重制，可注册计划任务全自动。
- **可回退**：官方原件有留存，重装官方安装包即可完全还原。

---

## 快速开始（使用）

### 1. 安装

**方式 A：直接装打包好的开发版（推荐，给别的机器用）**

下载 `MathModel-<版本>-开发版-Setup.exe` 双击即可。单文件、离线、**免管理员**（per-user 安装），
自带桌面/开始菜单快捷方式、卸载入口，以及 `安装目录\dev-tools\` 里的一组维护脚本。

**方式 B：在已装官方版的机器上打补丁**

先完全退出 MathModel（托盘里也退出），然后双击：

```
一键应用开发版.bat
```

补丁包不在默认位置时，把安装目录拖到这个 bat 上，或按提示输入路径。

### 2. 配模型

右上角「设置 → 供应商」填入自己的 API Key（Anthropic / DeepSeek / Kimi / 通义等）。
不填也能打开界面，但发消息会提示缺少认证信息。

### 3. 局域网协作（同一 WiFi / 手机热点）

左边栏「局域网协作」→ 选一个项目 → **开房** → 把 6 位数字口令发给队友 →
队友在同一 WiFi 下打开「局域网协作」会自动看到房间，输口令加入 → 你点同意。

房主机器建议跑一次（只需一次，需要管理员）：

```powershell
powershell -ExecutionPolicy Bypass -File "dev-tools\allow-lan-collab.ps1"
```

连不上时的排查顺序见 [局域网协作](#局域网协作同一-wifi--手机热点) 一节。

---

## 官方更新后重制

三个一键 bat（也可以用 `tools\` 下对应的 ps1）：

| 场景 | 双击 | 说明 |
| --- | --- | --- |
| 手动重制并应用 | `检查官方更新并重制.bat` | 已是开发版且版本没变就什么都不做；检测到官方版则自动重制 + 应用 |
| 全自动跟随 | `安装自动更新任务.bat` | 注册「登录时 + 每 60 分钟」的检查任务，官方更新完自动变回开发版 |
| 首次/强制应用 | `一键应用开发版.bat` | 把当前 `prebuilt\app.asar` 应用到安装目录 |

> ⚠️ **补丁包必须放在安装目录之外**：官方更新会整体重写安装目录，放在里面的补丁包会被一并删除。

## 封装安装包 & 发版

```
封装安装包.bat              → dist\MathModel-<版本>-开发版-Setup.exe
发布新版本到GitHub.bat       → 生成 latest.yml 并创建/覆盖 GitHub Release
```

对应命令：

```powershell
# 1) 重制开发版并应用（会带上新的 app-update.yml 与安装位置记录）
.\tools\auto-pipeline.ps1 -Force -NoLaunch

# 2) 封装成单文件 setup（约 285 MB）
.\installer\make-setup.ps1

# 3) 生成 latest.yml + SHA256SUMS，并上传到 GitHub Release
.\installer\publish-release.ps1 -Upload
```

`publish-release.ps1` 产出 `dist\release\`：

| 文件 | 作用 |
| --- | --- |
| `mathmodel-<版本>-dev-x64-setup.exe` | 安装包（已改名成 release 里的资产名） |
| `latest.yml` | **必须有**：版本号 / 文件名 / sha512 / 字节数，客户端靠它比对版本 |
| `SHA256SUMS.txt` | 校验和 |

`gh` 没登录时会自动回退到本机 Git 凭据管理器里已保存的 GitHub 凭据（只在本次进程内使用，不落盘）。

> **关键**：客户端版本号**必须低于** `latest.yml` 里的版本才会看到更新。
> 现在装的是 0.0.23，就要发 0.0.24；只传 setup.exe、不传 latest.yml 是识别不到的。

---

## 内置自动更新（指向自己的 GitHub Release）

程序自带的「检查更新」由 electron-updater 驱动，配置在 `resources\app-update.yml`。
打补丁时会把它从官方仓库改成你的仓库（默认 `06xxlin/MathModelAgent-dev`）：

```yaml
owner: 06xxlin
repo: MathModelAgent-dev
provider: github
releaseType: release
channel: latest
```

> 这个文件**必须用 LF 换行**。主进程那个简陋的 YAML 解析器按 `\n` 切行再用
> `/^(\w+):\s*(.+)$/` 匹配，CRLF 行尾的 `\r` 会让 `.` 匹配失败 → 解析结果为空 →
> 程序判定「没有配置更新源」→ 自动更新把自己关掉。脚本已经处理好了。

完整链路：

```
启动 → 检查更新 → 比对 latest.yml → 下载 → 校验 sha512 → 放行签名 → quitAndInstall
     → setup.exe --updated --force-run → 覆盖安装 → 自动重启
```

安装包会处理 electron-updater 传来的 `--updated`（跳过向导页）和 `--force-run`（装完自动拉起）。

**换仓库**：给 `auto-pipeline.ps1` / `apply-dev.ps1` 传 `-UpdateRepo owner/repo`
（`-UpdateRepo -` 表示保留官方更新源）。

**关掉自动更新**：

```powershell
powershell -ExecutionPolicy Bypass -File "dev-tools\switch-auto-update.ps1" -Disable
# 恢复：把 -Disable 换成 -Enable；改完要完全退出再启动程序
```

---

## 局域网协作（同一 WiFi / 手机热点）

官方的「局域网协作」是**服务器授权**的：

| 环节 | 官方做法 |
| --- | --- |
| 房主开房 `authorizeHost()` | `POST mathmodel.top/api/collab/access-pass` 换通行证 |
| 队友加入 `verifyJoinAccessPass()` | 房主把通行证拿回 `/api/collab/access-pass/verify` **验签** |
| 队友取通行证 | preload → IPC → 后台 |

后台一断，两边都是 `access_pass_unavailable`，功能等于废掉。补丁把它改成了**纯本地**：

| 环节 | 现在 |
| --- | --- |
| 开房 | 本机签发同结构通行证 |
| 加入 | 本机直接放行，并回填房间号做一致性校验 |
| 队友取通行证 | 本地生成同结构通行证 |

> 之所以行得通：通行证就是 `base64url({version:1,subject:"<43位base64url>"}).<签名>`，
> 而程序内部的解码函数 `ug()` **只校验结构、不验签** —— 验签本来就是后台干的活。
> 签发/校验都搬到本地之后，整条链路不再有任何外发请求。

协作数据走局域网：房主在 `0.0.0.0:47820~47829` 上开一个 HTTP/WebSocket 服务，
队友用 mDNS（服务类型 `mathmodel`）发现房间后直连房主机器。**数据不经过任何服务器。**

**队友连不上时按顺序排查**

1. 三台设备必须在**同一个** WiFi/热点，且该网络没有开「AP 隔离 / 客户端隔离」。
   校园网、酒店网络、部分路由器默认隔离同网段设备 —— 这种网络下谁也连不上谁，换手机热点试最快。
2. 房主机器放行防火墙（只需房主做一次，需要管理员）：
   `powershell -ExecutionPolicy Bypass -File "dev-tools\allow-lan-collab.ps1"`
   家里 WiFi 常被判成「专用」、手机热点常是「公用」，只加一种会出现「家里行、热点不行」；
   这个脚本三个网络配置文件都加。
3. 端口占用：程序会自动在 47820~47829 里挑空闲端口，一般不用管。

> 所有设备必须都是**开发版**。队友装的是官方版的话，协作照样会被后台门槛挡住。

---

## 隐私：断开后台服务器

### 补丁层面切断了什么

| 目标 | 做法 |
| --- | --- |
| 后台基址 `https://mathmodel.top` | 主进程里改成 `http://127.0.0.1:9`（本机未监听的 discard 端口），`/api/*` 全部随之失效 |
| 该地址被藏进混淆字符串表（0.0.22 起） | 补丁器先解字符串表拿到索引，再把所有解码调用点换成哨兵地址（不依赖明文锚点） |
| 遥测上报 `/api/desktop/telemetry/batch` | 对应函数整体替换为「直接返回成功」，事件不再外发、发件箱不再堆积 |
| 界面里的官网链接（website / home / changelog / 分享卡片） | 文本级清除为哨兵地址，点不出去 |
| 更新包签名白名单 | 改写成恒通过（否则未签名的开发版更新包装不上） |
| 协作 access pass | 本机签发 + 本机校验（详见上一节） |
| 域名解析 | hosts 把 `mathmodel.top` / `www.mathmodel.top` 指向 `0.0.0.0`（汇点） |

### 还会出网的请求（都不是后台服务器）

| 目标 | 用途 | 怎么关 |
| --- | --- | --- |
| `api.github.com` / `github.com` / `*.githubusercontent.com` | **你自己的更新检查**：查 Release、下载新版安装包 | `dev-tools\switch-auto-update.ps1 -Disable` |
| `models.dev` | 第三方模型目录（供应商/模型列表校准） | — |
| 你配置的模型服务商 API | 对话本身要用的（Anthropic / DeepSeek / …） | — |

### 额外的隔离手段（可选）

| 目的 | 命令 |
| --- | --- |
| 写入 hosts 拦截（需管理员，会弹 UAC） | `.\tools\block-backend.ps1` |
| 撤销 hosts 拦截 | `.\tools\block-backend.ps1 -Remove` |
| 预演清理（不动文件） | `.\tools\purge-local-identity.ps1 -WhatIf` |
| 备份并清理登录态 / 遥测残留 | `.\tools\purge-local-identity.ps1` |

清理只处理 App 自己的状态文件，**不动** `workspace\`、`version-history\`、`sdk-config\`、`codex-home\`、`mathmodel.db`
等你的论文、对话与设置；移除前一律备份到 `%APPDATA%\@mathmodel\_purge-backup-<时间戳>\`。

想恢复后台连接：重制时给补丁器加 `--no-isolation`，并执行 `.\tools\block-backend.ps1 -Remove`。

---

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 启动即崩，报 `Integrity check failed for asar archive entry` | 改了 `app.asar` 但没同步 exe 内嵌哈希。`apply-dev.ps1` 会自动改；手改的话跑 `tools\patch-exe-hash.ps1 -Exe <exe> -Asar <asar>` |
| 界面显示「检查更新失败，请稍后重试」 | 看 `%APPDATA%\@mathmodel\desktop\logs\mathmodel-main.log` 里的原始报错。常见是仓库变私有（未登录客户端一律 404）或 Release 里没有 `latest.yml` |
| 更新一直显示「已是最新」 | 客户端版本号 >= `latest.yml` 里的版本。要发**更高**的版本号 |
| 自动更新下载完装不上 | 签名白名单没放行。确认日志里有「更新包签名校验已放行」 |
| 协作房间看不到 / 连不上 | 见 [局域网协作](#局域网协作同一-wifi--手机热点) 的排查顺序（AP 隔离 → 防火墙 → 端口） |
| 队友加入报 `invalid_access_pass` | 通行证结构不对（`subject` 必须正好 43 位 base64url）。用本包重制即可 |
| 补丁包不见了 | 放在安装目录里，被官方更新一起删了。挪到安装目录之外 |

日志：`%APPDATA%\@mathmodel\desktop\logs\mathmodel-main.log`
补丁器报告：`.auto-report.txt`（每次重制的命中明细）

---

## 目录结构

```
├─ 一键应用开发版.bat            把 prebuilt\app.asar 应用到安装目录
├─ 检查官方更新并重制.bat        官方更新后重制 + 应用
├─ 安装自动更新任务.bat          注册「登录时 + 每 60 分钟」自动重制
├─ 封装安装包.bat                生成单文件 setup
├─ 发布新版本到GitHub.bat        生成 latest.yml 并上传 Release
├─ tools\                        补丁与维护脚本
│   ├─ patch-asar.js             ★ 通用补丁器：官方 app.asar → 开发版 app.asar
│   ├─ patch-exe-hash.ps1 / .js  改写 exe 内嵌的 asar 完整性哈希
│   ├─ apply-dev.ps1             应用补丁到安装目录（含 app-update.yml / 安装位置记录）
│   ├─ auto-pipeline.ps1         检测 → 重制 → 应用 → 记录状态
│   ├─ install-auto-task.ps1     注册/移除计划任务
│   ├─ block-backend.ps1         hosts 汇点（管理员）
│   ├─ purge-local-identity.ps1  清理登录态 / 遥测残留（先备份）
│   ├─ switch-auto-update.ps1    开关官方自动更新（环境变量）
│   ├─ allow-lan-collab.ps1      放行局域网协作入站端口（管理员）
│   └─ rebuild-asar.js           由 patched\ 手工重打包的辅助脚本
├─ installer\
│   ├─ make-setup.ps1            把打好补丁的安装目录封装成 NSIS setup
│   └─ publish-release.ps1       生成 latest.yml + SHA256SUMS，可一键发布
├─ official\                     留存的官方 app.asar（按版本，供溯源与强制重制）
├─ patched\                      最近一次改动过的文件（供人工核对）
├─ prebuilt\app.asar             最近一次生成的开发版归档
└─ dist\                         安装包与 release 产物（不入库）
```

## 常用命令

| 目的 | 命令 |
| --- | --- |
| 应用开发版 | `.\tools\apply-dev.ps1 -AppRoot "<安装目录>"` |
| 重制并应用 | `.\tools\auto-pipeline.ps1` |
| 强制重制 | `.\tools\auto-pipeline.ps1 -Force` |
| 重制后不自动启动 | `.\tools\auto-pipeline.ps1 -NoLaunch` |
| 用官方安装包制作 | `.\tools\auto-pipeline.ps1 -Mode installer -Installer "D:\下载\mathmodel-setup-0.0.23.exe"` |
| 用已解包的官方目录制作 | `.\tools\auto-pipeline.ps1 -Mode installer -SourceDir "D:\已解包的官方目录"` |
| 封装安装包 | `.\installer\make-setup.ps1` |
| 发布到 GitHub Release | `.\installer\publish-release.ps1 -Upload` |
| 注册 / 移除自动任务 | `.\tools\install-auto-task.ps1 -IntervalMinutes 60` / `-Remove` |
| 查看自动任务 | `Get-ScheduledTask -TaskName MathModelAgentDev-AutoPatch` |

## 影响范围

- **可用**：本地建模、写论文、绘图、Python / LaTeX 环境、自定义模型 API Key、GitHub 插件、
   自动更新（走自己仓库）、**局域网协作（同 WiFi）**。
- **不可用**：账号中心、权益与积分、数模广场分享 / 阅读、**跨网/云端**协作、云同步、
   后台模型代理、飞书 / 微信的后台通道。
- 数据目录不变：`%APPDATA%\@mathmodel\desktop`。

## 版本适配记录

| 官方版本 | 安装目录 | 补丁器适配要点 |
| --- | --- | --- |
| 0.0.17 ~ 0.0.19 | `Programs\@mathmodeldesktop` | 初版，锚点写死在混淆标识符上 |
| 0.0.20 ~ 0.0.21 | 同上 | 改为「解字符串表 → 按字符串值定位锚点」 |
| 0.0.22 | `Programs\mathmodel` | 后台基址被搬进混淆字符串表 → 「解表拿索引 → 替换所有解码调用点」；识别新安装目录 |
| 0.0.23 | `Programs\@mathmodeldesktop`（改回来了） | 三处锚点从字符串表改回**明文字面量**（遥测端点、签名钩子、计费赋值）→ 两种写法都认；`app-update.yml` 必须 LF；新增局域网协作本地化 |

补丁器是**按字符串值定位**而不是写死偏移/标识符的，官方换版本重新混淆也能自动适配；
真的对不上时会在 `.auto-report.txt` 里明确报出「未找到 XXX 锚点」，不会默默打错。

## 恢复官方版

1. 先执行 `.\tools\install-auto-task.ps1 -Remove`（否则任务会把补丁打回来）；
2. 重新运行官方安装包即可完全还原。

---

本包仅用于**你自己拥有合法副本**的软件改造与本地开发，请勿用于规避他人软件的付费授权。

## 欢迎加入
<img width="130" height="230" alt="bd7c2d58d1cc3a5c2f98f3c44f4ac701" src="https://github.com/user-attachments/assets/ba21454b-c830-4da0-918c-5a2fa0f36ea1" />
