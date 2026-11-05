# ============================================================
# SSHD Bridge Kit - 生成"单目标离线部署包"
# 用途：把某一台待控电脑需要的所有文件打成一个文件夹/zip，
#       拷到 U 盘或内网共享，目标机上双击即可完成部署。
# 用法：
#   .\make-bundle.ps1 -Os windows -PubKeyFile ~\.ssh\id_ed25519_win-a.pub
#   .\make-bundle.ps1 -Os macos   -PubKeyFile .\keys\id_ed25519_win-a.pub -OutDir D:\部署包
#   .\make-bundle.ps1 -Os linux   -PubKey "$(Get-Content .\keys\x.pub)"
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('windows', 'macos', 'linux')][string]$Os,
    [string]$PubKeyFile = '',
    [string]$PubKey = '',
    [string]$OutDir = '',
    [switch]$IncludeMsi,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$stamp = Get-Date -Format 'yyyyMMdd'
$name = "sshd-deploy-$Os-$stamp"
if (-not $OutDir) { $OutDir = Join-Path $root 'release' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stage = Join-Path $OutDir $name

function Copy-KitFile([string]$RelPath, [string]$DestDir) {
    $src = Join-Path $root $RelPath
    if (-not (Test-Path -LiteralPath $src)) { throw "套件文件缺失：$RelPath" }
    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $DestDir -Force
}

# ---------- 公钥 ----------
$pubLine = ''
if ($PubKeyFile) {
    if (-not (Test-Path -LiteralPath $PubKeyFile)) { throw "找不到公钥文件：$PubKeyFile" }
    $pubLine = ((Get-Content -LiteralPath $PubKeyFile -Raw) -split "`r?`n" |
        Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1).Trim()
} elseif ($PubKey) {
    $pubLine = $PubKey.Trim()
}
if ($pubLine -and $pubLine -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\s+[A-Za-z0-9+/=]{32,}') {
    throw '公钥格式不合法，拒绝打包'
}
if (-not $pubLine) {
    Write-Host '  [!] 没有提供公钥：部署包会保留密码登录（仍可部署，之后再加钥匙）' -ForegroundColor Yellow
}

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# ---------- 按平台复制 ----------
switch ($Os) {
    'windows' {
        $w = Join-Path $stage 'windows'
        foreach ($f in @('install.cmd', 'setup-sshd.ps1', 'uninstall-sshd.ps1')) {
            Copy-KitFile "windows\$f" $w
        }
        Copy-KitFile 'windows\offline\README.md' (Join-Path $w 'offline')
        $msi = Join-Path $root 'windows\offline\OpenSSH-Win64.msi'
        if ($IncludeMsi) {
            if (-not (Test-Path -LiteralPath $msi)) { throw '指定了 -IncludeMsi，但 windows\offline\OpenSSH-Win64.msi 不存在' }
            Copy-Item -LiteralPath $msi -Destination (Join-Path $w 'offline') -Force
            if (Test-Path -LiteralPath "$msi.sha256") {
                Copy-Item -LiteralPath "$msi.sha256" -Destination (Join-Path $w 'offline') -Force
            }
        }
        $k = Join-Path $stage 'keys'
        New-Item -ItemType Directory -Path $k -Force | Out-Null
        if ($pubLine) { Set-Content -LiteralPath (Join-Path $k 'id_bridge.pub') -Value $pubLine -Encoding ASCII }
    }
    'macos' {
        $m = Join-Path $stage 'mac'
        foreach ($f in @('install-sshd.sh', 'install.command', 'harden-ssh.sh')) {
            Copy-KitFile "mac\$f" $m
        }
        $k = Join-Path $m 'keys'
        New-Item -ItemType Directory -Path $k -Force | Out-Null
        if ($pubLine) { Set-Content -LiteralPath (Join-Path $k 'id_bridge.pub') -Value $pubLine -Encoding ASCII }
    }
    'linux' {
        $l = Join-Path $stage 'linux'
        Copy-KitFile 'linux\install-sshd.sh' $l
        $k = Join-Path $l 'keys'
        New-Item -ItemType Directory -Path $k -Force | Out-Null
        if ($pubLine) { Set-Content -LiteralPath (Join-Path $k 'id_bridge.pub') -Value $pubLine -Encoding ASCII }
    }
}

# ---------- 部署说明（目标机机主照着做即可） ----------
$port = 22
$keyName = if ($pubLine) { 'id_bridge.pub' } else { '' }
$keyArg = if ($keyName) { "--key-file keys/$keyName" } else { '' }
switch ($Os) {
    'windows' {
        $steps = @(
            '1. 解压整个文件夹到本机任意目录（不要只copy 单个文件）',
            '2. 右键 install.cmd → 以管理员身份运行',
            '   （脚本会自己请求 UAC，双击也可以）',
            '3. 等待出现"部署完成 —— SSH 服务已启动，真实握手正常"',
            '4. 桌面上的 部署结果.txt 发回给控制端（里面有本机 IP 和登录命令）'
        )
        if (-not $IncludeMsi) { $steps += '5. 若本机不能上网：先让控制端用 -IncludeMsi 重新打包，或把 OpenSSH-Win64.msi 放进 windows\offline\ 再运行' }
        $run = 'install.cmd'
    }
    'macos' {
        $steps = @(
            '1. 解压整个文件夹（保持 mac/ 目录结构）',
            '2. 双击 mac/install.command；或在终端执行：',
            '   sudo bash mac/install-sshd.sh --key-file mac/keys/id_bridge.pub',
            '3. 看到"SSH 已就绪"且 /usr/libexec/sshd-keygen-wrapper 正常',
            '4. 桌面上的 部署结果.txt 发回给控制端',
            '5. 首次会弹"终端想控制 sshd"，选允许；防火墙提示也选允许'
        )
        $run = '双击 mac/install.command'
    }
    'linux' {
        $steps = @(
            '1. 解压后进入 linux/ 目录',
            "2. 执行：sudo bash install-sshd.sh $keyArg",
            '3. 脚本会自动装 openssh-server、写配置、放行防火墙、启动服务',
            '4. cat 部署结果.txt，把 IP 和登录命令发回给控制端',
            '5. 云主机请确认安全组只放行内网/VPN 网段，不要对 0.0.0.0/0 开 22'
        )
        $run = "sudo bash install-sshd.sh $keyArg"
    }
}
$readme = @(
    "SSHD Bridge Kit - 离线部署包（$Os / v$version）",
    "生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    '',
    '【这个包是干什么的】',
    '  在这台电脑上开启 SSH 服务，让控制端可以用公钥直接登录。',
    '  不需要联网（Windows 需包内含 MSI 或本机已有 OpenSSH）。',
    '',
    '【怎么用】'
) + $steps + @(
    '',
    '【控制端会这样连】',
    "  ssh <用户名>@<本机IP> -p $port",
    '',
    '【安全说明】',
    '  - 只放行内网 10/8、192.168/16、172.16/12 和 Tailscale 100.64/10',
    '  - 有公钥时默认关闭密码登录；没有公钥时自动保留密码，避免锁死',
    '  - 回滚：Windows 运行 uninstall-sshd.ps1；macOS/Linux 用备份的 sshd_config 覆盖后重启服务',
    '',
    "启动命令：$run"
)
Set-Content -LiteralPath (Join-Path $stage '部署说明.txt') -Value ($readme -join "`r`n") -Encoding UTF8

# ---------- 统一编码 ----------
$ps1 = Get-ChildItem -LiteralPath $stage -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue
foreach ($f in $ps1) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding $true))
}
$sh = Get-ChildItem -LiteralPath $stage -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.sh', '.command') }
foreach ($f in $sh) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding $false))
}

Write-Host ''
Write-Host '=== 部署包已生成 ===' -ForegroundColor Green
Write-Host "  目录 : $stage"
if (-not $NoZip) {
    $zip = Join-Path $OutDir "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Write-Host "  压缩 : $zip"
    Write-Host "  SHA256: $hash"
}
if ($pubLine) {
    Write-Host ''
    Write-Host '  公钥指纹：' -ForegroundColor Cyan
    try {
        $tmp = Join-Path $env:TEMP "sshd-bridge-$(Get-Random).pub"
        Set-Content -LiteralPath $tmp -Value $pubLine -Encoding ASCII
        (ssh-keygen.exe -lf $tmp) 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch { }
}
Write-Host ''
Write-Host '把这整个文件夹拷到目标机（U 盘/共享/远程桌面拖拽均可），按 部署说明.txt 操作。' -ForegroundColor Yellow
