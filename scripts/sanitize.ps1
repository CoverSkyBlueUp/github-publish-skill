<#
.SYNOPSIS
  发布前脱敏扫描：递归扫描目录中的文本文件，查找疑似密钥 / 敏感串 / 机器专属信息。

.DESCRIPTION
  内置常见敏感模式（GitHub / OpenAI / AWS / Slack token、私钥、client_secret 等），
  可用 -Patterns 追加自定义正则（如机器路径、真实 appId）。命中输出
  "文件:行号: 行内容 [pattern: 正则]"。有命中时退出码 1（可用 -ExitOnFound 控制）。

.EXAMPLE
  # 默认常见模式扫描
  powershell -NoProfile -ExecutionPolicy Bypass -File sanitize.ps1 -Path "D:\repo"
  # 追加自定义模式（正则语法，如真实用户名路径）
  powershell -NoProfile -ExecutionPolicy Bypass -File sanitize.ps1 -Path "D:\repo" -Patterns "C:\\Users\\10037"
  # 只扫自定义模式
  powershell -NoProfile -ExecutionPolicy Bypass -File sanitize.ps1 -Path "D:\repo" -NoCommon -Patterns "qq_appid_xxx"
  # 命中即返回退出码 1（供 CI 使用）
  powershell -NoProfile -ExecutionPolicy Bypass -File sanitize.ps1 -Path "D:\repo" -ExitOnFound
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string[]]$Patterns = @(),
  [switch]$NoCommon,     # 不加载内置常见模式
  [switch]$ExitOnFound   # 有命中时退出码 1
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Path)) { throw "[sanitize] 路径不存在: $Path" }

$common = @(
  'ghp_[A-Za-z0-9]{20,}',                                   # GitHub classic PAT
  'github_pat_[A-Za-z0-9_]{20,}',                           # GitHub fine-grained PAT
  'gh[ousr]_[A-Za-z0-9]{20,}',                              # GitHub OAuth/用户/服务器 token
  'sk-[A-Za-z0-9]{20,}',                                    # OpenAI 等 sk- 密钥
  'AKIA[0-9A-Z]{16}',                                       # AWS Access Key
  'xox[baprs]-[A-Za-z0-9-]{10,}',                           # Slack token
  '-----BEGIN [A-Z ]*PRIVATE KEY-----',                     # 私钥块
  'client_secret["'']?\s*[:=]\s*["'']?[A-Za-z0-9_\-]{12,}', # client secret
  'app_secret["'']?\s*[:=]\s*["'']?[A-Za-z0-9_\-]{12,}',    # app secret
  'C:\\Users\\[^\\"]+',                                     # 机器专属路径
  '(?i)password\s*["'']?\s*[:=]\s*["'']?[^\s"''",}]{6,}'    # password 赋值
)

$patterns = @()
if (-not $NoCommon) { $patterns += $common }
$patterns += $Patterns
if ($patterns.Count -eq 0) { Write-Host "[sanitize] 未指定任何模式（-NoCommon 且无 -Patterns）"; exit 0 }

Write-Host "[sanitize] 扫描目录: $Path"
Write-Host "[sanitize] 使用模式数: $($patterns.Count)"

$files = Get-ChildItem -Path $Path -Recurse -File -Force | Where-Object {
  $rel = $_.FullName.Substring((Resolve-Path $Path).Path.Length)
  $rel -notmatch '\\.git\\' -and
  $rel -notmatch '\\node_modules\\' -and
  $_.Extension -notin @('.png','.jpg','.jpeg','.gif','.ico','.webp','.exe','.dll','.bin','.zip','.7z','.cer','.pfx','.p12','.db','.dat','.lock','.pid','.log','.tmp')
}
Write-Host "[sanitize] 待扫描文件数: $($files.Count)"

$hits = @()
foreach ($f in $files) {
  try { $lines = Get-Content $f.FullName -ErrorAction Stop } catch { continue }
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    foreach ($p in $patterns) {
      if ($line -match $p) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 160) { $trimmed = $trimmed.Substring(0, 160) + " ..." }
        $hits += ("{0}:{1}: {2}  [pattern: {3}]" -f $f.FullName, ($i + 1), $trimmed, $p)
        break
      }
    }
  }
}

if ($hits.Count -eq 0) {
  Write-Host "[sanitize] 未发现敏感串，可以发布。" -ForegroundColor Green
  exit 0
} else {
  Write-Host "[sanitize] 发现 $($hits.Count) 处疑似敏感内容：" -ForegroundColor Yellow
  $hits | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
  Write-Host "[sanitize] 请处理后再发布（替换为占位符 / 加入 .gitignore / 删除文件）。文档中的示例占位符可人工确认后忽略。"
  if ($ExitOnFound) { exit 1 }
}
