---
name: github-publish
license: MIT
description:
  将本地目录/仓库发布到 GitHub 的可复用工作流（v2.1：token 安全保存自动复用且永不明文进出对话/命令行、一键发布脚本、发布前脱敏扫描）。
  触发场景：用户要求把某目录/项目/脚本发布/上传到 GitHub、部署到 GitHub 仓库、重装后重新发布、或分享代码到开源平台。
metadata:
  author: CoverSkyBlueUp
  version: "2.1.0"
---

# github-publish Skill

> **DSH 环境适配说明**：
> - 本 skill 记录将本地仓库发布到 GitHub 的完整流程与踩坑，基于真实发布会话（qq-remote-bridge）总结并持续演进。
> - **沙箱限制**：在 DSH 会话内，`git`、`node`、`curl`、`Invoke-RestMethod`、`cmdkey` 等可能被会话沙箱拦截（报 `Access is denied` / `EPERM`）。**一切网络/提权/git 写入操作需用 `sandbox_permissions: danger-full-access` 单次重试**，并附一句 justification。
> - **git 工作目录**：PowerShell 每次调用是独立进程，`Set-Location` 不跨调用生效。**始终用 `git -C <repo路径>` 指定仓库目录**，不要依赖 `cd`。
> - **git 进度输出到 stderr**：`git push` 的进度信息走 stderr，PowerShell 会把它当错误流显示 `NativeCommandError`，**不代表失败**——看 `* [new branch] ...` 即成功。

## 一、部署结构（本 skill 文件布局）

```
github-publish/
├── SKILL.md                  # 本说明文档（v2.0.0）
├── scripts/
│   ├── gh-token.ps1          # token 安全存储/读取/校验/删除（DPAPI 加密，保存一次长期复用）
│   ├── sanitize.ps1          # 发布前脱敏扫描（内置常见密钥模式 + 自定义模式）
│   └── publish.ps1           # 一键发布：自动读 token → 建远程仓库 → 推送 → 清理
└── references/
    └── github-publish-notes.md   # 实战踩坑笔记（认证类型、API、git 要点）
```

职责分离：**凭据管理（gh-token） / 内容检查（sanitize） / 发布执行（publish）** 三个脚本独立可测，
publish.ps1 自动调用另外两者的能力（token 读取、脱敏预检）。

## 二、快速上手（推荐路径）

```powershell
$s = "C:\Users\<用户名>\.dsh\skills\github-publish\scripts"

# 1) 保存 token（只需一次；【推荐】-Prompt 交互输入，不回显、不进历史、不进对话）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\gh-token.ps1" -Action Store -Prompt
#    备选安全通道：-TokenFile <路径>（用后删除文件）或先设环境变量 GH_PUBLISH_TOKEN

# 2) 准备仓库目录 + 脱敏扫描（可加 -Patterns 追加真实敏感串/机器路径）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\sanitize.ps1" -Path "D:\path\to\repo"

# 3) 一键发布（之后每次发布都无需再提供 token！）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\publish.ps1" -RepoPath "D:\path\to\repo" -RepoName "my-repo" [-Private] [-Description "..."]
```

## 三、token 保存与复用（v2 新特性，核心）

**目标：token 只输入一次，之后所有发布会话自动复用，无需再次向用户索要。**

> ### 🔴 token 安全红线（v2.1）
> - **绝不在 DSH 对话中要求用户粘贴原始 token**，也不把 token 写进任何命令/日志/输出——对话中只出现掩码（`ghp_xxxx...`）。
> - 需要保存/更新 token 时，让**用户在本机终端**执行 `gh-token.ps1 -Action Store -Prompt`（Read-Host 不回显、不进 PSReadLine 历史、不进进程命令行），完成后只回报掩码确认。
> - 备用通道：`-TokenFile <路径>`（token 写入临时文件，脚本读取后用后删除）；或环境变量 `GH_PUBLISH_TOKEN`（设置后 `-Action Store` 自动读取）。
> - **禁止**把 token 作为 `-Token` 参数在 DSH 会话中传递（会明文留在对话/日志/进程命令行）。`-Token` 仅限用户本机终端自用时可用，且脚本会告警提示轮换。
> - token 疑似经任何通道泄露 → GitHub 撤销 → `-Action Remove` → 用 `-Prompt` 重新 Store。

- **存储位置**：`%APPDATA%\DSH\github\token.bin`（DPAPI `ProtectedData` 加密，仅当前 Windows 用户可解密，不落明文）
- **元数据**：`meta.json`（用户名、保存时间、token 掩码），供 publish.ps1 推导 `-Username`
- **命令**（`gh-token.ps1`）：
  | Action | 作用 |
  |--------|------|
  | `Store -Prompt` | 【推荐】交互式输入并加密保存（不回显、不进历史） |
  | `Store -TokenFile <路径>` | 从文件读取并加密保存（用后删除文件） |
  | `Store`（配合 `GH_PUBLISH_TOKEN`） | 从环境变量读取并加密保存 |
  | `Store -Token <ghp_...> [-Username u] [-Force]` | 直接传参（仅限本机终端，会告警建议轮换） |
  | `Get [-Raw]` | 查看掩码信息；`-Raw` 输出原始 token（仅供脚本管道，勿展示） |
  | `Check` | 状态检查（未保存退出码 1） |
  | `Validate` | 调 GitHub API 校验已存 token 是否有效 |
  | `Remove` | 删除已存 token |
- **git 层免认证**：publish.ps1 推送后会用 `git credential approve` 写入凭据，
  之后普通 `git clone/push` 也免认证（凭据存于 Windows 凭据管理器，非明文文件）。
- **安全**：
  - 仅当前 Windows 用户可解密（DPAPI 绑定用户 + 机器）
  - 不把 token 写入任何仓库文件 / git remote URL（push 后立即清理）
  - publish.ps1 保存 token 时**内联 DPAPI 写入**，不通过子进程/命令行透传明文
  - token 疑似泄露 → GitHub 撤销 → `-Action Remove` → 重新 `Store`

## 四、完整流程（含 v1 踩坑）

### 1) 前置检查

```powershell
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { git --version } else { "git NOT found" }
"C:\Program Files\Git\cmd\git.exe" | ForEach-Object { "$_ -> $(Test-Path $_)" }
Get-Command winget,choco,scoop -ErrorAction SilentlyContinue | Select-Object Name,Source
```

### 2) 安装 git（若缺失）

```powershell
winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements
```
- 默认装到 `C:\Program Files\Git\cmd\git.exe`；安装后需提权调用（沙箱拦截）。

### 3) 准备仓库内容并脱敏

在一个**独立 repo 目录**（不污染源目录）准备：
- `README.md`（面向开源社区：功能、安装、使用、安全）
- `LICENSE`（MIT，版权人填 GitHub 用户名）
- `.gitignore`（排除运行时产物、本地配置、含密钥的文件）

**脱敏（发布前必须做，可用 sanitize.ps1 辅助）**：
```powershell
# 内置常见密钥模式扫描
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\sanitize.ps1" -Path "D:\path\to\repo"
# 追加真实敏感串（把 PATTERN 换成你的真实串，如机器路径/真实 appId）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\sanitize.ps1" -Path "D:\path\to\repo" -Patterns "<PATTERN>"
```
- 密钥用占位符（`<APPID>` / `<CLIENT_SECRET>` / `<USER_OPENID>`）
- 机器专属路径（如 `C:\Users\<用户名>\...`）改为基于 `os.homedir()` / `%USERPROFILE%` / 脚本自身目录推导
- 运行产物（log/pid/config.json）加入 `.gitignore`，且不复制进 repo

### 4) 初始化 git 仓库并提交

```powershell
$git = "C:\Program Files\Git\cmd\git.exe"
$repo = "D:\path\to\repo"
& $git -C $repo init -b main
& $git -C $repo config user.name "<GITHUB_USERNAME>"
& $git -C $repo config user.email "<GITHUB_USERNAME>@users.noreply.github.com"
& $git -C $repo add -A
& $git -C $repo commit -m "feat: ..."
& $git -C $repo log --oneline -1
```
> 身份 email 若不暴露真实邮箱，用 GitHub 隐藏邮箱 `<用户名>@users.noreply.github.com`。

### 5) 创建远程仓库（关键坑：认证类型）

**用 GitHub REST API 创建**：
```powershell
$headers = @{ "Authorization" = "Bearer $token"; "Accept" = "application/vnd.github+json"; "User-Agent" = "dsh-publish" }
$body = @{ name = "<REPO_NAME>"; private = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Headers $headers -Method Post -Body $body -ContentType "application/json"
```

### ⚠️ 认证类型（最重要的坑，实测踩过）
| token 类型 | 前缀 | 能否「创建新仓库」 |
|-----------|------|------------------|
| **Classic PAT** | `ghp_...` | ✅ 能（需勾 `repo` scope） |
| Fine-grained PAT | `github_pat_...` | ❌ **不能通过 API 创建新仓库**（GitHub 已移除该权限，只能管理已存在的仓库） |

- fine-grained PAT 创建仓库会返回 **403 Forbidden**（响应体为空）——**换 Classic PAT 即可**，不用反复试。
- Classic PAT 生成：GitHub → Settings → Developer settings → Personal access tokens → 生成时勾 `repo`（classic）或授权目标仓库 `Contents: read/write`（fine-grained，仅用于 push 已存在仓库）。
- 403 也可能来自网络/沙箱环境偶发抖动，重试一次再换 token。

### 6) 配置 remote 并 push

```powershell
# 把 token 嵌入 remote URL 实现免交互认证（push 后必须移除）
& $git -C $repo remote add origin "https://$token@github.com/<GITHUB_USERNAME>/<REPO>.git"
& $git -C $repo push -u origin main
# 输出含 "* [new branch] main -> main" 即成功（NativeCommandError 是 stderr 粉饰）
```

### 7) 安全清理 token（必须）

```powershell
& $git -C $repo remote set-url origin "https://github.com/<GITHUB_USERNAME>/<REPO>.git"
& $git -C $repo remote -v   # 确认 remote 不再含 token
```
推送后**立即**移除 remote 里的 token。建议事后在 GitHub 撤销对话中暴露过的 token。

### 8) 验证远程内容

```powershell
Invoke-RestMethod -Uri "https://api.github.com/repos/<GITHUB_USERNAME>/<REPO>/contents/" -Headers $headers -Method Get
```

## 五、发布前安全清单

- [ ] 无真实密钥 / 密码 / token 进仓库（用 sanitize.ps1 扫描）
- [ ] 无机器专属用户名 / 路径硬编码
- [ ] token 不写入任何仓库文件、不 commit、不留存在 remote URL
- [ ] push 后清理 remote 里的 token
- [ ] token 保存于 DPAPI 存储（`gh-token.ps1 -Action Store`），对话中只显示掩码
- [ ] 敏感操作全程 `danger-full-access` 提权 + justification

## 版本记录

- v2.1.0：**token 安全红线**——对话/命令行/日志永不明文；新增 `-Prompt`（交互不回显）与 `-TokenFile`/`GH_PUBLISH_TOKEN` 安全录入通道；publish.ps1 保存 token 改为内联 DPAPI（消除子进程命令行透传明文）。
- v2.0.0：token DPAPI 安全保存与自动复用（gh-token.ps1）、发布前脱敏扫描（sanitize.ps1）、
  一键发布脚本重写（publish.ps1 自动读 token / 建仓库 / 推送 / 清理 / 写 git 凭据）、部署结构重组。
- v1.0.0：初次封装基于实际发布会话（qq-remote-bridge 上传 GitHub）——认证类型坑、脱敏、沙箱提权、`git -C`、token 清理。
