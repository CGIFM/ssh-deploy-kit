# ============================================================
# 生成发布包：统一编码、LF/CRLF、敏感信息扫描、zip + SHA256
# 用法：powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1
#       可选 -IncludeMsi 把离线 MSI 一起打包
# ============================================================
[CmdletBinding()]
param([switch]$IncludeMsi)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$name = "sshd-bridge-kit-v$version"
$releaseRoot = Join-Path $root 'release'
$dist = Join-Path $releaseRoot $name

Write-Host "=== 构建 $name ===" -ForegroundColor Cyan

# ---------- 1. 编码统一 ----------
$ps1 = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName -notlike '*\release\*' }
foreach ($f in $ps1) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    $t = $t -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding $true))
}
Write-Host "  PowerShell: $($ps1.Count) 个文件 -> UTF-8 BOM + CRLF" -ForegroundColor Gray

$sh = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.Extension -in @('.sh', '.command') -and $_.FullName -notlike '*\release\*'
}
foreach ($f in $sh) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    $t = $t -replace "`r`n", "`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding $false))
}
Write-Host "  Shell: $($sh.Count) 个文件 -> UTF-8 无 BOM + LF" -ForegroundColor Gray

# ---------- 2. 敏感信息扫描 ----------
$patterns = @(
    'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY',
    # 需要时在此补充自己环境的内网 IP 前缀
    'password\s*=\s*["''][^"'']+["'']'
)
$textExt = @('.ps1', '.sh', '.command', '.cmd', '.md', '.txt', '.tsv', '.example')
$hits = New-Object System.Collections.ArrayList
foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.FullName -notlike '*\release\*' -and $_.FullName -notlike '*\.git\*' -and
    $textExt -contains $_.Extension -and
    $_.Name -notlike '安装日志*' -and $_.Name -notlike '部署结果*' -and
    $_.Name -notlike '部署失败*' -and $_.Name -notlike 'msi.log'
})) {
    $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($p in $patterns) {
        if ($content -match $p) { [void]$hits.Add("$($f.FullName)  <- $p") }
    }
}
if ($hits.Count -gt 0) {
    Write-Host '  [X] 发现疑似敏感内容，已中止：' -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit 1
}
Write-Host '  敏感信息扫描：通过' -ForegroundColor Green

# ---------- 3. 复制白名单 ----------
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$items = @(
    'README.md', 'PITFALLS.md', 'CHANGELOG.md', 'VERSION', 'LICENSE', '.gitignore',
    'windows', 'mac', 'linux', 'controller', 'keys', 'tools'
)
foreach ($i in $items) {
    $src = Join-Path $root $i
    if (-not (Test-Path -LiteralPath $src)) { continue }
    Copy-Item -LiteralPath $src -Destination $dist -Recurse -Force
}

# 清掉运行产物和私钥
Get-ChildItem -LiteralPath $dist -Recurse -File | Where-Object {
    $_.Name -match '^(安装日志|部署结果|部署失败|msi\.log)' -or
    $_.Extension -in @('.zip', '.log') -or
    $_.Name -like '*.pub' -or $_.Name -like '*.key'
} | Remove-Item -Force

# 离线 MSI
$msi = Join-Path $root 'windows\offline\OpenSSH-Win64.msi'
if ($IncludeMsi -and (Test-Path -LiteralPath $msi)) {
    Copy-Item -LiteralPath $msi -Destination (Join-Path $dist 'windows\offline') -Force
    Write-Host '  已包含离线 MSI' -ForegroundColor Yellow
} else {
    Write-Host '  未包含离线 MSI（需要时加 -IncludeMsi）' -ForegroundColor Yellow
}

# ---------- 4. 打包 ----------
$zip = Join-Path $releaseRoot "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
$size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)

Write-Host ''
Write-Host '=== 完成 ===' -ForegroundColor Green
Write-Host "  目录 : $dist"
Write-Host "  压缩 : $zip  ($size MB)"
Write-Host "  SHA256: $hash"
Write-Host ''
Write-Host '提示：Windows 打的 zip 不保留 Unix 执行位，Mac 用户解压后先运行：' -ForegroundColor Yellow
Write-Host '  chmod +x mac/*.command mac/*.sh controller/*.sh' -ForegroundColor Yellow
