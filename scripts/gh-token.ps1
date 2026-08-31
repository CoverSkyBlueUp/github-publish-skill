<#
.SYNOPSIS
  GitHub token 安全存储 / 读取 / 校验 / 删除（Windows DPAPI 加密，仅当前用户可解密）。

.DESCRIPTION
  github-publish skill 的凭据管理脚本。token 以 DPAPI 加密存于
  %APPDATA%\DSH\github\token.bin，元数据（用户名/保存时间/掩码）存 meta.json。
  之后 publish.ps1 无需再手动传 token，自动读取本存储 —— 只需保存一次。

.EXAMPLE
  # 保存（校验 token 并写入 DPAPI 加密存储，只需做一次）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store -Token ghp_xxxxx
  # 保存并显式指定用户名（不指定则从 GitHub API 自动获取）
  powershell -NoProfile -ExecutionPolicy Bypass -File gh-token.ps1 -Action Store -Token ghp_xxxxx -Username CoverSkyBlueUp
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
  [switch]$Raw,     # Get 时只输出原始 token，不打印任何其他内容
  [switch]$Force     # Store 时覆盖已保存的 token
)

$ErrorActionPreference = "Stop"

$storeDir  = Join-Path $env:APPDATA "DSH\github"
$tokenFile = Join-Path $storeDir "token.bin"
$metaFile  = Join-Path $storeDir "meta.json"

Add-Type -AssemblyName System.Security | Out-Null

function Read-TokenFile {
  if (-not (Test-Path $tokenFile)) { return $null }
  $bytes = [System.IO.File]::ReadAllBytes($tokenFile)
  $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Write-TokenFile([string]$t) {
  if (-not (Test-Path $storeDir)) { New-Item -ItemType Directory -Path $storeDir -Force | Out-Null }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($t)
  $enc = [System.Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  [System.IO.File]::WriteAllBytes($tokenFile, $enc)
}

function Read-Meta {
  if (Test-Path $metaFile) {
    try { return (Get-Content $metaFile -Raw | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Write-Meta($obj) { $obj | ConvertTo-Json | Set-Content $metaFile -Encoding UTF8 }

function Mask-Token([string]$t) {
  if ([string]::IsNullOrEmpty($t)) { return "(空)" }
  if ($t.Length -le 8) { return "***" }
  return $t.Substring(0, 4) + "..." + $t.Substring($t.Length - 4)
}

function Test-GithubToken([string]$t) {
  $headers = @{ "Authorization" = "Bearer $t"; "Accept" = "application/vnd.github+json"; "User-Agent" = "dsh-gh-token" }
  return (Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $headers -Method Get)
}

switch ($Action) {
  "Store" {
    if ([string]::IsNullOrEmpty($Token)) { throw "[gh-token] Store 需要 -Token <ghp_...>" }
    if (-not ($Token -match '^(gh[pous]_|ghr_|github_pat_|github_)')) {
      Write-Warning "[gh-token] token 前缀不是 GitHub 常规格式（ghp_/github_pat_/gho_/ghs_/ghu_/ghr_），请确认无误；Ctrl+C 可取消。"
    }
    if ((Test-Path $tokenFile) -and -not $Force) {
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
    Write-Host "[gh-token] 已保存 GitHub token -> $tokenFile" -ForegroundColor Green
    Write-Host "[gh-token] 用户名: $login | token: $(Mask-Token $Token)" -ForegroundColor Green
    Write-Host "[gh-token] 下次发布无需再传 token；删除用 -Action Remove；若 token 泄露请到 GitHub 撤销后重新 Store。"
  }

  "Get" {
    $token = Read-TokenFile
    if ([string]::IsNullOrEmpty($token)) { throw "[gh-token] 尚未保存 token，请先运行: gh-token.ps1 -Action Store -Token <ghp_...>" }
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
    Write-Host "[gh-token] 存储位置: $tokenFile（DPAPI 加密，仅当前 Windows 用户可解密）"
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
    if (Test-Path $tokenFile) { Remove-Item $tokenFile -Force; Write-Host "[gh-token] 已删除 token 文件" -ForegroundColor Yellow }
    if (Test-Path $metaFile)  { Remove-Item $metaFile  -Force; Write-Host "[gh-token] 已删除元数据"   -ForegroundColor Yellow }
    if (-not (Test-Path $tokenFile) -and -not (Test-Path $metaFile)) { Write-Host "[gh-token] 无已保存的 token" }
  }
}
