<#
.SYNOPSIS
  GitHub token 安全存储 / 读取 / 校验 / 删除（Windows DPAPI 加密，仅当前用户可解密）。

.DESCRIPTION
  github-publish skill 的凭据管理脚本。token 以 DPAPI 加密存于
  %APPDATA%\DSH\github\token.bin，元数据（用户名/保存时间/掩码）存 meta.json。
  之后 publish.ps1 无需再手动传 token，自动读取本存储 —— 只需保存一次。

.EXAMPLE
  # 【推荐】安全保存：交互式输入（不回显、不进终端历史、不进命令行/对话）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store -Prompt
  # 【推荐】安全保存：从文件读取（把 token 写入临时文件后运行，用后删除文件）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store -TokenFile "C:\tmp\gh_token.txt"
  # 【推荐】安全保存：环境变量通道（设置 GH_PUBLISH_TOKEN 后运行）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store
  # 直接传参保存（⚠️ 仅限本机终端；token 会出现在该终端的历史记录/进程命令行中）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store -Token ghp_xxxxx
  # 查看（只显示掩码）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Get
  # 取原始 token（仅输出 token 本身，供脚本管道使用，勿在日志中展示）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Get -Raw
  # 调 GitHub API 校验已保存 token 是否有效
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Validate
  # 删除已保存的 token
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Remove
  # 状态检查（未保存时退出码 1）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Check
#>
param(
  [ValidateSet("Store","Get","Remove","Check","Validate")]
  [string]$Action = "Get",
  [string]$Token,
  [string]$Username,
  [string]$TokenFile,  # Store: 从文件读取 token（避免命令行/历史暴露）
  [switch]$Prompt,     # Store: 交互式输入（Read-Host 不回显、不进历史）
  [switch]$Raw,        # Get 时只输出原始 token，不打印任何其他内容
  [switch]$Force       # Store 时覆盖已保存的 token
)

$ErrorActionPreference = "Stop"

$credDir       = Join-Path $env:APPDATA "DSH\github"
$credTokenFile = Join-Path $credDir "token.bin"
$credMetaFile  = Join-Path $credDir "meta.json"

Add-Type -AssemblyName System.Security | Out-Null

function Read-TokenFile {
  if (-not (Test-Path $credTokenFile)) { return $null }
  $bytes = [System.IO.File]::ReadAllBytes($credTokenFile)
  $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Write-TokenFile([string]$t) {
  if (-not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($t)
  $enc = [System.Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  [System.IO.File]::WriteAllBytes($credTokenFile, $enc)
}

function Read-Meta {
  if (Test-Path $credMetaFile) {
    try { return (Get-Content $credMetaFile -Raw | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Write-Meta($obj) { $obj | ConvertTo-Json | Set-Content $credMetaFile -Encoding UTF8 }

function Mask-Token([string]$t) {
  if ([string]::IsNullOrEmpty($t)) { return "(空)" }
  if ($t.Length -le 8) { return "***" }
  return $t.Substring(0, 4) + "..." + $t.Substring($t.Length - 4)
}

function ConvertFrom-SecureStringPlain([System.Security.SecureString]$ss) {
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
  try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-GithubToken([string]$t) {
  $headers = @{ "Authorization" = "Bearer $t"; "Accept" = "application/vnd.github+json"; "User-Agent" = "dsh-gh-token" }
  return (Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $headers -Method Get)
}

switch ($Action) {
  "Store" {
    # token 来源优先级：-Token > -TokenFile > -Prompt > 环境变量 GH_PUBLISH_TOKEN
    if ([string]::IsNullOrEmpty($Token) -and -not [string]::IsNullOrEmpty($TokenFile)) {
      if (-not (Test-Path $TokenFile)) { throw "[gh-token] TokenFile 不存在: $TokenFile" }
      $Token = (Get-Content $TokenFile -Raw).Trim()
      Write-Host "[gh-token] 已从 TokenFile 读取 token" -ForegroundColor Cyan
    }
    if ([string]::IsNullOrEmpty($Token) -and $Prompt) {
      $ss = Read-Host "[gh-token] 请输入 GitHub token（输入不回显、不进终端历史）" -AsSecureString
      if ($null -eq $ss -or $ss.Length -eq 0) { throw "[gh-token] 未输入 token" }
      $Token = ConvertFrom-SecureStringPlain $ss
    }
    if ([string]::IsNullOrEmpty($Token) -and -not [string]::IsNullOrEmpty($env:GH_PUBLISH_TOKEN)) {
      $Token = $env:GH_PUBLISH_TOKEN
    }
    if ([string]::IsNullOrEmpty($Token)) {
      throw "[gh-token] 未获取到 token。安全方式任选其一（避免明文进对话/命令行/终端历史）：`n  a) -Prompt 交互输入  `n  b) -TokenFile <路径>  `n  c) 先设置环境变量 GH_PUBLISH_TOKEN 再运行"
    }
    if (-not ($Token -match '^(gh[pous]_|ghr_|github_pat_|github_)')) {
      Write-Warning "[gh-token] token 前缀不是 GitHub 常规格式（ghp_/github_pat_/gho_/ghs_/ghu_/ghr_），请确认无误；Ctrl+C 可取消。"
    }
    if ((Test-Path $credTokenFile) -and -not $Force) {
      throw "[gh-token] 已保存过 token（覆盖请加 -Force；删除用 -Action Remove）"
    }
    Write-Host "[gh-token] 正在通过 GitHub API 校验 token 并获取用户名 ..." -ForegroundColor Cyan
    try {
      $me = Test-GithubToken $Token
    } catch {
      throw "[gh-token] token 校验失败：$($_.Exception.Message)（确认 token 有效、网络可达；DSH 沙箱内需提权运行）"
    }
    $login = if (-not [string]::IsNullOrEmpty($Username)) { $Username } else { $me.login }
    Write-TokenFile $Token
    Write-Meta @{
      username   = $login
      storedAt   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
      tokenMask  = (Mask-Token $Token)
      valid      = $true
    }
    Write-Host "[gh-token] 已保存 GitHub token -> $credTokenFile" -ForegroundColor Green
    Write-Host "[gh-token] 用户名: $login | token: $(Mask-Token $Token)" -ForegroundColor Green
    if ($PSBoundParameters.ContainsKey('Token')) {
      Write-Warning "[gh-token] 提示：本次通过 -Token 传参，token 可能已留在终端历史/进程命令行中。建议改用 -Prompt 或 -TokenFile 重新保存，并到 GitHub 撤销泄露的 token。"
    }
    Write-Host "[gh-token] 下次发布无需再传 token；删除用 -Action Remove；若 token 泄露请到 GitHub 撤销后重新 Store。"
  }

  "Get" {
    $token = Read-TokenFile
    if ([string]::IsNullOrEmpty($token)) { throw "[gh-token] 尚未保存 token。请在本机终端运行（勿在对话/命令行传明文）：gh-token.ps1 -Action Store -Prompt" }
    if ($Raw) { Write-Output $token; exit 0 }
    $meta = Read-Meta
    Write-Host "[gh-token] 已保存 token: $(if ($meta -and $meta.tokenMask) { $meta.tokenMask } else { Mask-Token $token })" -ForegroundColor Green
    if ($meta) {
      Write-Host "[gh-token] 用户名: $($meta.username) | 保存时间: $($meta.storedAt)"
    }
    Write-Host "[gh-token] 取原始值请加 -Raw（注意勿在日志/对话中输出原始 token）"
  }

  "Check" {
    $token = Read-TokenFile
    if ([string]::IsNullOrEmpty($token)) { Write-Host "[gh-token] 未保存 token"; exit 1 }
    $meta = Read-Meta
    Write-Host "[gh-token] 状态: 已保存" -ForegroundColor Green
    Write-Host "[gh-token] token: $(if ($meta -and $meta.tokenMask) { $meta.tokenMask } else { Mask-Token $token })"
    if ($meta) { Write-Host "[gh-token] 用户名: $($meta.username) | 保存时间: $($meta.storedAt)" }
    Write-Host "[gh-token] 存储位置: $credTokenFile（DPAPI 加密，仅当前 Windows 用户可解密）"
  }

  "Validate" {
    $token = Read-TokenFile
    if ([string]::IsNullOrEmpty($token)) { throw "[gh-token] 尚未保存 token，请先 -Action Store" }
    Write-Host "[gh-token] 正在校验已保存的 token ..." -ForegroundColor Cyan
    try {
      $me = Test-GithubToken $token
      Write-Host "[gh-token] 有效: $($me.login) (id $($me.id))" -ForegroundColor Green
    } catch {
      throw "[gh-token] 校验失败：$($_.Exception.Message)（token 可能已失效，请重新 Store）"
    }
  }

  "Remove" {
    if (Test-Path $credTokenFile) { Remove-Item $credTokenFile -Force; Write-Host "[gh-token] 已删除 token 文件" -ForegroundColor Yellow }
    if (Test-Path $credMetaFile)  { Remove-Item $credMetaFile  -Force; Write-Host "[gh-token] 已删除元数据"   -ForegroundColor Yellow }
    if (-not (Test-Path $credTokenFile) -and -not (Test-Path $credMetaFile)) { Write-Host "[gh-token] 无已保存的 token" }
  }
}
