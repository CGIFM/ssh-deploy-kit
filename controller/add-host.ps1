# ============================================================
# SSHD Bridge Kit - 控制端：生成密钥 + 写入 ssh 别名 + 自动验证
# 用法：
#   .\add-host.ps1 -Alias win-a -HostName 192.0.2.10 -User Administrator
#   .\add-host.ps1 -Alias target-b -HostName 10.0.0.20 -User alice -ProxyJump target-a
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Alias,
    [Parameter(Mandatory)][string]$HostName,
    [string]$User = 'Administrator',
    [int]$Port = 22,
    [string]$KeyPath = '',
    [string]$ProxyJump = '',
    [switch]$Force,
    [switch]$NoTest
)

$ErrorActionPreference = 'Stop'
$script:SshDir = Join-Path $env:USERPROFILE '.ssh'
$script:ConfigPath = Join-Path $script:SshDir 'config'

function Q([string]$s) {
    if ($null -eq $s) { return '""' }
    if ($s -eq '') { return '""' }
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

function Invoke-Raw {
    param([string]$Exe, [string]$ArgumentLine, [int]$TimeoutMs = 30000)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $ArgumentLine
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -2; Output = $out + $err + "`n[timeout]" }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out + $err }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Test-SshBanner {
    param([string]$TargetHost, [int]$TargetPort = 22, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) { return '' }
        $s = $client.GetStream(); $s.ReadTimeout = 5000
        $buf = New-Object byte[] 256
        $n = $s.Read($buf, 0, 256)
        if ($n -le 0) { return '' }
        $line = (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`n")[0].Trim()
        if ($line -match '^SSH-') { return $line }
        return ''
    } catch { return '' } finally { try { $client.Close() } catch { } }
}

function Pause-Exit([int]$Code) {
    try {
        if (-not [Console]::IsInputRedirected) { Read-Host '按回车退出' | Out-Null }
    } catch { }
    exit $Code
}

if ($Alias -notmatch '^[A-Za-z0-9._-]+$') { throw "别名不合法：$Alias（只允许字母、数字、点、下划线、连字符）" }
if (-not (Test-Path -LiteralPath $script:SshDir)) { New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null }
if (-not $KeyPath) { $KeyPath = Join-Path $script:SshDir "id_ed25519_$Alias" }

$KeyPath = [IO.Path]::GetFullPath($KeyPath)
$createdKey = $false

if ((Test-Path -LiteralPath $KeyPath) -and -not $Force) {
    Write-Host "  密钥已存在：$KeyPath" -ForegroundColor Gray
} else {
    if ((Test-Path -LiteralPath $KeyPath) -and $Force) {
        $bak = "$KeyPath.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Move-Item -LiteralPath $KeyPath -Destination $bak
        if (Test-Path -LiteralPath "$KeyPath.pub") { Move-Item -LiteralPath "$KeyPath.pub" -Destination "$bak.pub" }
        Write-Host "  旧密钥已备份：$bak" -ForegroundColor Yellow
    }
    $comment = "$env:USERNAME@$env:COMPUTERNAME-$(Get-Date -Format yyyyMMdd)"
    $keygenArgs = "-t ed25519 -f $(Q $KeyPath) -N `"`" -C $(Q $comment)"
    $r = Invoke-Raw -Exe 'ssh-keygen.exe' -ArgumentLine $keygenArgs
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$KeyPath.pub")) {
        throw "生成密钥失败：$($r.Output.Trim())"
    }
    $createdKey = $true
    Write-Host "  已生成密钥：$KeyPath" -ForegroundColor Green
}

$pubPath = "$KeyPath.pub"
if (-not (Test-Path -LiteralPath $pubPath)) { throw "找不到公钥：$pubPath" }
$pubLine = (Get-Content -LiteralPath $pubPath -Raw).Trim()
$fingerprint = (Invoke-Raw -Exe 'ssh-keygen.exe' -ArgumentLine "-lf $(Q $pubPath)").Output.Trim()

# ---------- 写入 ssh config ----------
$configText = if (Test-Path -LiteralPath $script:ConfigPath) { Get-Content -LiteralPath $script:ConfigPath } else { @() }
$out = New-Object System.Collections.ArrayList
$skip = $false
$found = $false
foreach ($line in $configText) {
    if ($line -match '^\s*Host\s+(.+)$') {
        $names = $Matches[1].Trim() -split '\s+'
        if ($names -contains $Alias) { $skip = $true; $found = $true; continue }
        else { $skip = $false }
    } elseif ($line -match '^\s*(Match|Include)\s+') {
        $skip = $false
    }
    if (-not $skip) { [void]$out.Add($line) }
}

if ($found -and -not $Force) {
    Write-Host "  ssh config 已有 Host $Alias，未改动（-Force 可覆盖）" -ForegroundColor Yellow
} else {
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($out.Count -gt 0) { [void]$out.Add('') }
    [void]$out.Add("Host $Alias")
    [void]$out.Add("    HostName $HostName")
    [void]$out.Add("    Port $Port")
    [void]$out.Add("    User $User")
    [void]$out.Add("    IdentityFile $($KeyPath -replace '\\', '/')")
    [void]$out.Add('    IdentitiesOnly yes')
    [void]$out.Add('    StrictHostKeyChecking accept-new')
    [void]$out.Add('    ServerAliveInterval 30')
    [void]$out.Add('    ServerAliveCountMax 3')
    if ($ProxyJump) { [void]$out.Add("    ProxyJump $ProxyJump") }
    Set-Content -LiteralPath $script:ConfigPath -Value ($out -join "`r`n") -Encoding ASCII
    Write-Host "  已写入 ssh 别名：$Alias -> $User@${HostName}:$Port" -ForegroundColor Green
}

Write-Host ''
Write-Host '  公钥：' -ForegroundColor Cyan
Write-Host "    $pubLine"
Write-Host "  指纹：$fingerprint" -ForegroundColor Gray
Write-Host "  私钥：$KeyPath" -ForegroundColor Gray

# ---------- 验证 ----------
if (-not $NoTest) {
    Write-Host ''
    Write-Host '  验证连通性...' -ForegroundColor Cyan
    $banner = Test-SshBanner -TargetHost $HostName -TargetPort $Port
    if (-not $banner) {
        Write-Host '  [X] 没有读到 SSH- banner。' -ForegroundColor Red
        Write-Host '      目标机可能未装/未启动 sshd，或被防火墙拦截。' -ForegroundColor Yellow
        Write-Host '      把本套件 windows/ 或 mac/、linux/ 和 keys/ 拷到目标机先部署。' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "  部署时要带上这把公钥：$pubPath" -ForegroundColor Cyan
        Pause-Exit 2
    }
    Write-Host "  [OK] 握手正常：$banner" -ForegroundColor Green

    $sshArgs = "-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
    if ($ProxyJump) { $sshArgs += " -J $(Q $ProxyJump)" }
    $sshArgs += " -i $(Q $KeyPath) -p $Port $(Q "$User@$HostName") $(Q 'echo SSHD_BRIDGE_OK')"
    $r = Invoke-Raw -Exe 'ssh.exe' -ArgumentLine $sshArgs -TimeoutMs 20000
    if ($r.ExitCode -eq 0 -and $r.Output -match 'SSHD_BRIDGE_OK') {
        Write-Host '  [OK] 公钥登录成功' -ForegroundColor Green
        Write-Host ''
        Write-Host "  以后直接用：ssh $Alias" -ForegroundColor Cyan
    } else {
        Write-Host '  [!] 握手正常，但公钥登录未通过。' -ForegroundColor Yellow
        Write-Host "      把公钥放到目标机并重跑安装脚本：" -ForegroundColor Yellow
        Write-Host "        $pubPath" -ForegroundColor Cyan
        Write-Host "      Windows:  copy 到 keys\\ 后双击 install.cmd" -ForegroundColor Gray
        Write-Host "      macOS :  放到 mac/keys/ 后运行 install-sshd.sh" -ForegroundColor Gray
        Write-Host "      Linux :  --key-file 指向该公钥" -ForegroundColor Gray
        if ($r.Output.Trim()) {
            Write-Host ''
            Write-Host '      ssh 输出：' -ForegroundColor Gray
            Write-Host ($r.Output.Trim() -split "`n" | Select-Object -First 6 | ForEach-Object { "        $_" }) -ForegroundColor DarkGray
        }
        Pause-Exit 3
    }
}

Write-Host ''
if ($createdKey) { Write-Host '  下一步：把上面的公钥文件分发给目标机，再运行目标机安装脚本。' -ForegroundColor Yellow }
