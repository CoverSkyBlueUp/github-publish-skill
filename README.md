# github-publish — DSH 技能：一键发布到 GitHub（token 安全复用）

一个可复用的 DSH（DeepSeek Harness）技能：把本地目录/仓库发布到 GitHub 的完整工作流。
**v2.0.0 核心特性：token 只需保存一次，之后所有发布自动复用，无需再次索要。**

## ✨ 特性

- 🔐 **token 安全保存与自动复用** — Windows DPAPI 加密存储（`%APPDATA%\DSH\github\token.bin`），仅当前用户可解密，不落明文；保存一次，永久复用
- 🚀 **一键发布** — `publish.ps1` 自动：读取已存 token → 检查/创建远程仓库 → 提交推送 → 清理 remote 中的 token → 写入 git 凭据
- 🕵️ **发布前脱敏扫描** — `sanitize.ps1` 内置常见密钥模式（GitHub/OpenAI/AWS/Slack token、私钥、client_secret、机器路径），可追加自定义模式
- 📚 **实战踩坑沉淀** — Classic vs Fine-grained PAT 认证差异（创建仓库 403 的根因）、`git -C` 工作目录、`NativeCommandError` 假错误、DSH 沙箱提权

## 📦 部署方式（安装到 DSH）

**环境要求**：Windows 10/11 · PowerShell 5.1+ · Git for Windows · DSH（DeepSeek Harness）

### 方式一：git clone + 复制（推荐）

```powershell
# 1) 克隆本仓库（任意目录）
git clone https://github.com/CoverSkyBlueUp/github-publish-skill.git
cd github-publish-skill

# 2) 部署到 DSH 技能目录（技能目录：C:\Users\<用户名>\.dsh\skills\）
$dst = "$env:USERPROFILE\.dsh\skills\github-publish"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item "SKILL.md"  $dst -Force
Copy-Item "scripts"   $dst -Recurse -Force
Copy-Item "references" $dst -Recurse -Force

# 3) 验证部署成功
powershell -NoProfile -ExecutionPolicy Bypass -File "$dst\scripts\gh-token.ps1" -Action Check
# 预期：提示"未保存 token"（退出码 1）——说明脚本可运行，部署完成，下一步配置 token
```

### 方式二：手动复制

只需把仓库中的 **`SKILL.md`、`scripts/`、`references/`** 三个部分复制到 DSH 技能目录下的 `github-publish/` 文件夹即可。
`README.md`、`LICENSE`、`.gitignore` 是仓库级文件，技能运行不需要。

### 部署后首次配置（只需一次）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\github-publish\scripts\gh-token.ps1" -Action Store -Token <ghp_...>
```

> ⚠️ 需要 **Classic PAT**（`ghp_` 开头，勾选 `repo` scope）；Fine-grained PAT（`github_pat_`）无法通过 API 创建新仓库（403）。
>
> 部署后重启/刷新 DSH 会话，技能目录中即出现 `github-publish`，可直接对话触发"发布到 GitHub"。

## 🚀 快速开始（使用）

```powershell
$s = "$env:USERPROFILE\.dsh\skills\github-publish\scripts"

# 1) 保存 token（只需一次，部署后必做）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\gh-token.ps1" -Action Store -Token <ghp_...>

# 2) 脱敏扫描（发布前检查）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\sanitize.ps1" -Path "D:\path\to\repo"

# 3) 一键发布（以后不再需要 token）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\publish.ps1" -RepoPath "D:\path\to\repo" -RepoName "my-repo" [-Private]
```

## 📁 目录结构

```
github-publish/
├── SKILL.md                  # 技能说明（DSH 加载入口）
├── scripts/
│   ├── gh-token.ps1          # token 安全存储/读取/校验/删除（DPAPI）
│   ├── sanitize.ps1          # 发布前脱敏扫描
│   └── publish.ps1           # 一键发布（自动读 token → 建仓库 → 推送 → 清理）
└── references/
    └── github-publish-notes.md   # 实战踩坑笔记
```

## 🔒 安全说明

- token 经 DPAPI 加密，仅当前 Windows 用户可解密；删除用 `gh-token.ps1 -Action Remove`
- push 后自动从 git remote URL 移除 token，token 永不进入仓库文件
- 对话/日志只显示掩码（`ghp_xxxx...`），不显示原始 token
- 发布前运行脱敏扫描，确认无真实密钥/机器专属路径泄露

## 📄 License

MIT © CoverSkyBlueUp
