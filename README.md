# github-publish — DSH 技能：一键发布到 GitHub（token 安全复用）

一个可复用的 DSH（DeepSeek Harness）技能：把本地目录/仓库发布到 GitHub 的完整工作流。
**v2.0.0 核心特性：token 只需保存一次，之后所有发布自动复用，无需再次索要。**

## ✨ 特性

- 🔐 **token 安全保存与自动复用** — Windows DPAPI 加密存储（`%APPDATA%\DSH\github\token.bin`），仅当前用户可解密，不落明文；保存一次，永久复用
- 🚀 **一键发布** — `publish.ps1` 自动：读取已存 token → 检查/创建远程仓库 → 提交推送 → 清理 remote 中的 token → 写入 git 凭据
- 🕵️ **发布前脱敏扫描** — `sanitize.ps1` 内置常见密钥模式（GitHub/OpenAI/AWS/Slack token、私钥、client_secret、机器路径），可追加自定义模式
- 📚 **实战踩坑沉淀** — Classic vs Fine-grained PAT 认证差异（创建仓库 403 的根因）、`git -C` 工作目录、`NativeCommandError` 假错误、DSH 沙箱提权

## 🚀 快速开始

```powershell
$s = "scripts"

# 1) 保存 token（只需一次）
powershell -NoProfile -ExecutionPolicy Bypass -File "$s\gh-token.ps1" -Action Store -Token <ghp_...>

# 2) 脱敏扫描
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
