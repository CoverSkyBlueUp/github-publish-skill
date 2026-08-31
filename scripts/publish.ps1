<#
.SYNOPSIS
  github-publish 一键发布脚本 v2：自动读取已保存的 token，创建远程仓库并推送。

.DESCRIPTION
  - 不传 -Token 时自动读取 gh-token.ps1 保存的 token（%APPDATA%\DSH\github\token.bin，DPAPI 加密）
  - 自动用 git credential store 保存凭据，后续 git clone/push 免认证
  - 发布前做轻量脱敏预检（仅告警不阻断，可用 -SkipPreCheck 跳过）
  - 推完自动从 remote URL 移除 token

.EXAMPLE
  # 完整发布（token 已保存过，无需 -Token）
  powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1 -RepoPath "D:\my-repo" -RepoName "my-repo" -Private
  # 首次：传 token 并顺带保存
  powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1 -RepoPath "D:\my-repo" -RepoName "my-repo" -Token <ghp_...> -SaveToken
  # 指定描述/公开
  powershell -NoProfile -ExecutionPolicy Bypass -File publish.ps1 -RepoPath "D:\my-repo" -RepoName "my-repo" -Description "demo"
#>
param(
  [Parameter(Mandatory = $true)][string]$RepoPath,
  [Parameter(Mandatory = $true)][string]$RepoName,
  [string]$Username,
  [string]$Token,
  [string]$Description = "",
  [switch]$Private,
  [switch]$SaveToken,     # 用 -Token 传入时同时保存到本地安全存储
  [switch]$SkipPreCheck    # 跳过发布前脱敏预检
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$git = "C:\Program Files\Git\cmd\git.exe"
if (-not (Test-Path $git)) {
  $c = Get-Command git -ErrorAction SilentlyContinue
  if ($c) { $git = $c.Source } else { Write-Host "[publish] git 未安装: winget install --id Git.Git -e"; exit 1 }
}

function Step($m) { Write-Host "[publish] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[publish] 失败: $m" -ForegroundColor Red; exit 1 }

function Get-StoredToken {
  $tf = Join-Path $env:APPDATA "DSH\github\token.bin"
  if (-not (Test-Path $tf)) { return $null }
  Add-Type -AssemblyName System.Security | Out-Null
  $bytes = [System.IO.File]::ReadAllBytes($tf)
  $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  return [System.Text.Encoding]::UTF8.GetString($plain)
}

# ---- 0) 解析 token / username ---------------------------------------------
if ([string]::IsNullOrEmpty($Token)) {
  Step "未提供 -Token，读取已保存的 token ..."
  $Token = Get-StoredToken
  if ([string]::IsNullOrEmpty($Token)) {
    Fail "没有已保存的 token。请先执行一次: gh-token.ps1 -Action Store -Token <ghp_...>`n或本命令加 -Token <ghp_...> -SaveToken 保存。"
  }
  Step "已读取本地保存的 token（不显示原文）"
}
if ([string]::IsNullOrEmpty($Username)) {
  $metaFile = Join-Path $env:APPDATA "DSH\github\meta.json"
  if (Test-Path $metaFile) {
    try { $meta = Get-Content $metaFile -Raw | ConvertFrom-Json; $Username = $meta.username } catch {}
  }
}
if ([string]::IsNullOrEmpty($Username)) {
  Step "未提供 -Username 且无保存的用户名，从 GitHub API 获取 ..."
  $h0 = @{ "Authorization" = "Bearer $Token"; "Accept" = "application/vnd.github+json"; "User-Agent" = "dsh-publish" }
  $me = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $h0 -Method Get
  $Username = $me.login
}
if ([string]::IsNullOrEmpty($Username)) { Fail "无法确定 GitHub 用户名（-Username 或已保存的 meta.json）" }
Step "将以 $Username 身份发布"

# ---- 0.5) 可选：保存 token --------------------------------------------------
if ($SaveToken -and -not [string]::IsNullOrEmpty($Token)) {
  Step "保存 token 到本地安全存储（DPAPI）..."
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "gh-token.ps1") -Action Store -Token $Token -Username $Username -Force | Out-Host
}

# ---- 1) 本地仓库准备 ---------------------------------------------------------
if (-not (Test-Path $RepoPath)) { Fail "目录不存在: $RepoPath" }
$hasGit = Test-Path (Join-Path $RepoPath ".git")
if (-not $hasGit) {
  Step "初始化 git 仓库"
  & $git -C $RepoPath init -b main
  & $git -C $RepoPath config user.name $Username
  & $git -C $RepoPath config user.email "${Username}@users.noreply.github.com"
  & $git -C $RepoPath add -A
  & $git -C $RepoPath commit -m "feat: initial publish"
} else {
  Step "git 仓库已存在，确保身份配置"
  & $git -C $RepoPath config user.name $Username
  & $git -C $RepoPath config user.email "${Username}@users.noreply.github.com"
}

# ---- 1.5) 发布前脱敏预检（仅告警）-------------------------------------------
if (-not $SkipPreCheck) {
  Step "发布前脱敏预检（-SkipPreCheck 跳过）"
  $prePatterns = @(
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'gh[ousr]_[A-Za-z0-9]{20,}',
    'sk-[A-Za-z0-9]{20,}',
    'AKIA[0-9A-Z]{16}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  )
  $warn = Get-ChildItem -Path $RepoPath -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\.git\\' } |
    Select-String -Pattern $prePatterns -ErrorAction SilentlyContinue
  if ($warn) {
    Write-Host "[publish] 预检发现疑似敏感内容（发布继续，请人工确认）：" -ForegroundColor Yellow
    $warn | Select-Object -First 10 | ForEach-Object {
      $ln = $_.Line.Trim(); if ($ln.Length -gt 140) { $ln = $ln.Substring(0, 140) + " ..." }
      Write-Host "[publish]   $($_.Path):$($_.LineNumber): $ln" -ForegroundColor Yellow
    }
  } else {
    Write-Host "[publish] 预检通过：未发现常见密钥模式" -ForegroundColor Green
  }
}

# ---- 2) 检查远程仓库，不存在则创建 --------------------------------------------
$headers = @{ "Authorization" = "Bearer $Token"; "Accept" = "application/vnd.github+json"; "User-Agent" = "dsh-publish" }
$exists = $false
try {
  Invoke-RestMethod -Uri "https://api.github.com/repos/$Username/$RepoName" -Headers $headers -Method Get | Out-Null
  $exists = $true
  Step "远程仓库已存在: $Username/$RepoName（直接推送）"
} catch {
  $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch {}
  if ($st -eq 403) {
    Fail "403：token 无权访问该仓库（fine-grained token 可能未授权目标仓库）。创建新仓库必须用 Classic PAT (ghp_) + repo scope。"
  }
  $exists = $false
}

if (-not $exists) {
  Step "创建远程仓库 $Username/$RepoName (private=$([bool]$Private))"
  $body = @{ name = $RepoName; private = [bool]$Private }
  if ($Description) { $body.description = $Description }
  try {
    $repo = Invoke-RestMethod -Uri "https://api.github.com/user/repos" -Headers $headers -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json"
    Step "创建成功: $($repo.full_name)"
  } catch {
    $st = 0; try { $st = [int]$_.Exception.Response.StatusCode } catch {}
    if ($st -eq 403) {
      Fail "403：token 不能创建仓库。请用 Classic PAT（ghp_...）+ repo scope；fine-grained PAT 无法通过 API 创建新仓库。"
    } elseif ($st -eq 422) {
      Step "422：仓库名已存在或非法，继续尝试推送 ..."
    } else {
      Step "创建失败 HTTP $st，继续尝试推送（仓库可能已存在）..."
      try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); Step "响应体: $($sr.ReadToEnd())" } catch {}
    }
  }
}

# ---- 3) push + 写 git 凭据 + 清理 remote token --------------------------------
Step "配置 remote 并推送"
$tokenUrl = "https://$Token@github.com/$Username/$RepoName.git"
$origin = (& $git -C $RepoPath remote) 2>$null
if ($origin -match '(?m)^origin\s*$') { & $git -C $RepoPath remote set-url origin $tokenUrl }
else { & $git -C $RepoPath remote add origin $tokenUrl }

# push：git 进度走 stderr，PS 5.1 + EAP=Stop 会误判为终止错误，需临时降级 EAP
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $git -C $RepoPath push -u origin main 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.ToString() } else { Write-Host $_ } }
$pushCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($pushCode -ne 0) { Fail "git push 失败（exit $pushCode）" }

# push 成功后立即移除 remote 里的 token
& $git -C $RepoPath remote set-url origin "https://github.com/$Username/$RepoName.git"
Step "已从 remote URL 移除 token"

# 写入 git credential store，后续 git 操作免认证（失败不影响发布）
try {
  $prevEap2 = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  "protocol=https`nhost=github.com`nusername=$Username`npassword=$Token`n" | & $git credential approve 2>$null
  $ErrorActionPreference = $prevEap2
  Step "已写入 git credential store（后续 git clone/push 免认证）"
} catch {
  $ErrorActionPreference = $prevEap2
  Write-Host "[publish] 提示: 未写入 git 凭据（可忽略，发布功能不受影响）" -ForegroundColor DarkYellow
}

Step "完成: https://github.com/$Username/$RepoName"
