# GitHub 发布要点（实战验证）

## 1. 认证类型（最关键的坑）

| token 类型 | 前缀 | 创建新仓库 | 推送已存在仓库 |
|-----------|------|-----------|---------------|
| **Classic PAT** | `ghp_...` | ✅（需 `repo` scope） | ✅ |
| **Fine-grained PAT** | `github_pat_...` | ❌ 403 Forbidden | ✅（需授权仓库 `Contents: read/write`） |

**结论**：
- **创建新仓库必须用 Classic PAT（`ghp_`）**，且生成时勾选 `repo` scope。
- fine-grained PAT（`github_pat_`）**无法通过 API 创建新仓库**——这是 GitHub 平台移除的权限，无论 token 内容如何都 403，**不要反复试，直接换 Classic**。
- fine-grained PAT 只能用于管理/推送**已存在**的仓库（前提：token 授权了目标仓库）。

生成位置：GitHub → Settings → Developer settings → Personal access tokens → Generate new token。
- Classic 勾 `repo`；或 Fine-grained 授权指定仓库 + `Contents: Read and write`。

## 2. 创建仓库 API

```
POST https://api.github.com/user/repos
Authorization: Bearer <token>
Accept: application/vnd.github+json
User-Agent: <任意>

{ "name": "<REPO_NAME>", "private": false, "description": "..." }
```
- `private: false` = 公开；`true` = 私有
- `422` = repo 已存在或 name 非法
- `403` = token 权限不足（多为 fine-grained 不能建仓库，或未授权）

## 3. 检查仓库是否存在

```
GET https://api.github.com/repos/<USERNAME>/<REPO>
```
- `200` = 存在；`404` = 不存在（可安全创建）

## 4. 验证远程内容

```
GET https://api.github.com/repos/<USERNAME>/<REPO>/contents/
```
返回根目录文件/目录列表。

## 5. git 推送要点

- 工作目录用 `git -C <repo>`（PowerShell 每次调用独立进程，`cd` 不跨越）
- 认证（免交互）：`git remote add origin "https://<token>@github.com/<USERNAME>/<REPO>.git"`
- push 后**必须** `git remote set-url origin "https://github.com/<USERNAME>/<REPO>.git"` 移除 token
- `git push` 进度走 stderr，PowerShell 显示 `NativeCommandError` 是**假错误**，看 `* [new branch] main -> main` 即成功
- **⚠️ PS 5.1 + `$ErrorActionPreference = "Stop"`**：原生 git 写 stderr（`remote get-url` 无此 remote 的报错、push 进度、CRLF 警告）会被升级为终止错误直接退出脚本（实测踩到）。
  **解法**：判断 remote 是否存在用 `git remote` 列表输出（空输出不产生错误）；push 前后临时 `$ErrorActionPreference = "Continue"` 再恢复，并检查 `$LASTEXITCODE`。
- 免认证持久化：`"protocol=https`nhost=github.com`nusername=<USERNAME>`npassword=<TOKEN>`n" | git credential approve`

## 6. token 安全存储与复用（v2.1）

- 存储位置：`%APPDATA%\DSH\github\token.bin`，**DPAPI（ProtectedData）加密**，仅当前 Windows 用户可解密
- 元数据：同目录 `meta.json`（用户名 / 保存时间 / token 掩码）
- 命令（`scripts/gh-token.ps1`）：
  - **安全录入通道（推荐，v2.1）**：`-Action Store -Prompt`（Read-Host 不回显、不进 PSReadLine 历史）、
    `-Action Store -TokenFile <路径>`（临时文件，用后删除）、设置环境变量 `GH_PUBLISH_TOKEN` 后 `-Action Store`
  - `-Action Store -Token <ghp_...> [-Username u] [-Force]`：直接传参（**仅限本机终端**；会明文进终端历史/进程命令行，脚本会告警建议轮换）
  - `-Action Get [-Raw]`：查看掩码 / 取原始值（脚本管道用，勿展示）
  - `-Action Validate`：API 校验有效性；`-Action Check`：状态；`-Action Remove`：删除
- publish.ps1 不传 `-Token` 时自动读取该存储；`-SaveToken` 可把新 token 一并保存（**内联 DPAPI 写入，不经子进程/命令行透传**）
- DPAPI 要点：`Add-Type -AssemblyName System.Security` 后调用
  `[System.Security.Cryptography.ProtectedData]::Protect/Unprotect($bytes, $null, CurrentUser)`

### 🔴 v2.1 安全红线（实测教训）

- token 一旦以 `-Token` 参数或对话粘贴形式出现，会明文留在：DSH 会话日志、pwsh 命令记录、进程命令行
  （`Get-CimInstance Win32_Process` 可见）、PSReadLine 历史（`ConsoleHost_history.txt`）。
- **流程规定**：DSH 会话内一律不要求/不出现原始 token——让用户在本机终端跑 `-Prompt` 保存，只回报掩码；
  若历史中已残留，删除历史文件或整行，并到 GitHub 撤销该 token 后重新 Store。
- 进程命令行泄露示例（避免）：`powershell -File gh-token.ps1 -Action Store -Token ghp_xxx`（明文可见）。
  正确做法：`-Prompt` / `-TokenFile` / 环境变量。

## 7. 脱敏要点

- 真实密钥 / appId / clientSecret / openid 用占位符（`<...>`）
- 机器专属路径（`C:\Users\<用户名>\`）改为基于 `os.homedir()` / `%USERPROFILE%` / 脚本自身目录推导
- `.gitignore` 排除运行时产物（log/pid/config.json）
- 发布前用 `scripts/sanitize.ps1 -Path <repo>` 扫描（内置常见密钥模式，`-Patterns` 追加自定义）
- 文档中的示例占位符（如 `ghp_` 示例）可人工确认后忽略

## 8. 沙箱（DSH 会话内）

- `git`、`node`、`curl`、`Invoke-RestMethod`、`cmdkey` 可能被拦（`Access is denied` / `EPERM`）
- 一律 `sandbox_permissions: danger-full-access` 单次重试 + justification
- 敏感操作（安装、git 写入、网络调用、写 %APPDATA% 凭据）全程提权

## 9. 实例参数（qq-remote-bridge）

- 账号：CoverSkyBlueUp（id 86450286）
- 仓库：https://github.com/CoverSkyBlueUp/qq-remote-bridge
- 首次 commit：`f2c2437`，13 文件
- Classic PAT（`ghp_`）创建成功；两个 fine-grained PAT（`github_pat_`）创建均 403

## 10. 发布记录（github-publish 技能仓库）

- 仓库：https://github.com/CoverSkyBlueUp/github-publish-skill（v2.1 结构：SKILL.md + scripts/{gh-token,sanitize,publish}.ps1 + references + README 部署说明）
- 实操流程：`gh-token.ps1 -Action Store`（保存一次）→ `sanitize.ps1`（脱敏扫描）→ `publish.ps1`（自动复用 token 发布）
- v2.1：消除明文 token 进出对话/命令行（-Prompt/-TokenFile/环境变量通道 + publish 内联保存）
