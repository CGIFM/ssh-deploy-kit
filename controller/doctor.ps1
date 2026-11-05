# ============================================================
# SSHD Bridge Kit - 控制端诊断
# 判断：同网段 / fake-ip / TCP 假通 / 真 SSH 握手 / 公钥登录 / 延迟
# 用法：
#   .\doctor.ps1 -Alias dev-box
#   .\doctor.ps1 -Target 192.0.2.50 -User alice -KeyPath ~\.ssh\id_ed25519_dev-box
# ============================================================
[CmdletBinding()]
param(
    [string]$Alias = '',
    [string]$Target = '',
    [string]$User = '',
    [int]$Port = 0,
    [string]$KeyPath = '',
    [string]$ProxyJump = '',
    [int]$TimeoutMs = 4000,
    [switch]$NoAuth
)

$ErrorActionPreference = 'Stop'

function Invoke-Raw {
    param([string]$Exe, [string]$ArgumentLine, [int]$TimeoutMs = 15000)
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
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ ExitCode = -2; Output = $out + $err } }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out + $err }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $old
    }
}
function Q([string]$s) {
    if ($null -eq $s -or $s -eq '') { return '""' }
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}
function Ip-ToUInt64([string]$Ip) {
    $b = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return ([uint64]$b[0] * 16777216) + ([uint64]$b[1] * 65536) + ([uint64]$b[2] * 256) + [uint64]$b[3]
}
function UInt64-ToIp([uint64]$V) {
    $a = [math]::Floor($V / 16777216)
    $b = [math]::Floor(($V % 16777216) / 65536)
    $c = [math]::Floor(($V % 65536) / 256)
    $d = $V % 256
    return "$a.$b.$c.$d"
}
function Network-Of([string]$Ip, [int]$Prefix) {
    $v = Ip-ToUInt64 $Ip
    if ($Prefix -le 0) { return [uint64]0 }
    $all = [uint64]4294967295
    $mask = $all -bxor ($all -shr $Prefix)
    return ($v -band $mask)
}
function Test-Banner([string]$HostName, [int]$Port, [int]$TimeoutMs = 4000) {
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) {
            return [pscustomobject]@{ Ok = $false; Banner = ''; ConnectMs = $sw.ElapsedMilliseconds; Reason = 'TCP 连接超时' }
        }
        $sw.Stop()
        $s = $client.GetStream(); $s.ReadTimeout = 5000
        $buf = New-Object byte[] 256
        $n = $s.Read($buf, 0, 256)
        if ($n -le 0) {
            return [pscustomobject]@{ Ok = $false; Banner = ''; ConnectMs = $sw.ElapsedMilliseconds; Reason = 'TCP 连上但服务端没有发任何数据' }
        }
        $line = (([Text.Encoding]::ASCII.GetString($buf, 0, $n)) -split "`n")[0].Trim()
        if ($line -match '^SSH-') {
            return [pscustomobject]@{ Ok = $true; Banner = $line; ConnectMs = $sw.ElapsedMilliseconds; Reason = '' }
        }
        return [pscustomobject]@{ Ok = $false; Banner = $line; ConnectMs = $sw.ElapsedMilliseconds; Reason = "端口回了非 SSH 内容：$line" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Banner = ''; ConnectMs = $sw.ElapsedMilliseconds; Reason = $_.Exception.Message }
    } finally {
        try { $client.Close() } catch { }
    }
}

# ---------- 解析目标 ----------
$resolvedHost = $Target
$resolvedUser = $User
$resolvedPort = if ($Port -gt 0) { $Port } else { 22 }
$resolvedKey = $KeyPath
$resolvedJump = $ProxyJump

if ($Alias) {
    $g = Invoke-Raw -Exe 'ssh.exe' -ArgumentLine "-G $(Q $Alias)"
    if ($g.ExitCode -ne 0) { throw "ssh -G $Alias 失败：$($g.Output.Trim())" }
    foreach ($line in ($g.Output -split "`r?`n")) {
        $kv = $line.Trim() -split '\s+', 2
        if ($kv.Count -lt 2) { continue }
        switch ($kv[0].ToLowerInvariant()) {
            'hostname'   { $resolvedHost = $kv[1] }
            'user'       { $resolvedUser = $kv[1] }
            'port'       { $resolvedPort = [int]$kv[1] }
            'identityfile' { if (-not $resolvedKey) { $resolvedKey = $kv[1] } }
            'proxyjump'  { if ($kv[1] -ne 'none') { $resolvedJump = $kv[1] } }
        }
    }
    if (-not $Target) { $Target = $resolvedHost }
}

if (-not $resolvedHost) { throw '必须提供 -Alias 或 -Target' }
if (-not $resolvedUser) { $resolvedUser = $env:USERNAME }

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixLength -gt 0
}

Write-Host ''
Write-Host '=== SSHD Bridge Kit 诊断 ===' -ForegroundColor Cyan
if ($Alias) { Write-Host "  别名    : $Alias" -ForegroundColor Gray }
Write-Host "  目标    : $resolvedUser@$resolvedHost`:$resolvedPort" -ForegroundColor Gray
if ($resolvedJump) { Write-Host "  跳板    : $resolvedJump" -ForegroundColor Gray }
if ($resolvedKey) { Write-Host "  私钥    : $resolvedKey" -ForegroundColor Gray }
Write-Host ''

# ---------- 1. 本机网段 ----------
Write-Host '[1] 本机网段' -ForegroundColor Cyan
$targetIsIp = $resolvedHost -match '^\d{1,3}(\.\d{1,3}){3}$'
if (-not $targetIsIp) {
    try {
        $resolvedIp = [System.Net.Dns]::GetHostAddresses($resolvedHost) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($resolvedIp) { $targetIp = $resolvedIp.IPAddressToString }
        else { $targetIp = '' }
    } catch { $targetIp = '' }
} else {
    $targetIp = $resolvedHost
}
if (-not $targetIp) { $targetIp = $resolvedHost }

foreach ($a in $ips) {
    $net = Network-Of $a.IPAddress $a.PrefixLength
    Write-Host ("    {0,-28} {1}/{2}  网络 {3}/{2}" -f $a.InterfaceAlias, $a.IPAddress, $a.PrefixLength, (UInt64-ToIp $net)) -ForegroundColor Gray
}

$sameSubnet = $false
if ($targetIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
    $tv = Ip-ToUInt64 $targetIp
    foreach ($a in $ips) {
        if ((Network-Of $a.IPAddress $a.PrefixLength) -eq (Network-Of $targetIp $a.PrefixLength)) {
            $sameSubnet = $true
            Write-Host "    [OK] 目标 $targetIp 与本机 $($a.IPAddress)/$($a.PrefixLength) 同网段" -ForegroundColor Green
            break
        }
    }
    if (-not $sameSubnet) {
        Write-Host "    [!]  目标 $targetIp 不在本机任何直连网段（可能走 VPN/跳板/路由）" -ForegroundColor Yellow
    }
} else {
    Write-Host "    [!]  目标不是 IP，跳过同网段判断" -ForegroundColor Yellow
}

$fake = $false
if ($targetIp -like '198.18.*' -or $targetIp -like '198.19.*') {
    $fake = $true
    Write-Host '    [X] 目标是 198.18/15（Clash/Mihomo fake-ip），不能作为连通证据' -ForegroundColor Red
}

# ---------- 2. TCP + banner ----------
Write-Host ''
Write-Host '[2] 端口与握手' -ForegroundColor Cyan
$directHost = if ($resolvedJump) { $resolvedHost } else { $resolvedHost }
$tcp = Test-Banner -HostName $directHost -Port $resolvedPort -TimeoutMs $TimeoutMs
if ($tcp.Ok) {
    Write-Host "    [OK] 真实 SSH 握手（$($tcp.ConnectMs) ms）：$($tcp.Banner)" -ForegroundColor Green
} else {
    Write-Host "    [X] 没有 SSH 握手：$($tcp.Reason)" -ForegroundColor Red
    if ($tcp.ConnectMs -gt 0) { Write-Host "        TCP 连接耗时：$($tcp.ConnectMs) ms" -ForegroundColor Gray }
    Write-Host '        注意：TCP 能连 != SSH 能连；部分 VPN / 零信任网关 会对任意端口回 SYN-ACK。' -ForegroundColor Yellow
}

# ---------- 3. 公钥登录 ----------
$authOk = $null
if (-not $NoAuth -and $tcp.Ok) {
    Write-Host ''
    Write-Host '[3] 公钥登录' -ForegroundColor Cyan
    $sshArgs = '-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new'
    if ($resolvedJump) { $sshArgs += " -J $(Q $resolvedJump)" }
    if ($resolvedKey) {
        $expanded = $resolvedKey -replace '^~', $env:USERPROFILE
        $sshArgs += " -i $(Q $expanded)"
    }
    $sshArgs += " -p $resolvedPort $(Q "$resolvedUser@$resolvedHost") $(Q 'echo SSHD_BRIDGE_OK')"
    $r = Invoke-Raw -Exe 'ssh.exe' -ArgumentLine $sshArgs -TimeoutMs 20000
    if ($r.ExitCode -eq 0 -and $r.Output -match 'SSHD_BRIDGE_OK') {
        $authOk = $true
        Write-Host '    [OK] 公钥登录成功' -ForegroundColor Green
    } else {
        $authOk = $false
        Write-Host '    [X] 公钥登录失败' -ForegroundColor Red
        $lines = @($r.Output.Trim() -split "`r?`n" | Where-Object { $_ } | Select-Object -First 5)
        foreach ($l in $lines) { Write-Host "        $l" -ForegroundColor DarkGray }
        Write-Host '        检查：公钥是否写入正确账号、authorized_keys 权限、账号是否允许登录。' -ForegroundColor Yellow
    }
}

# ---------- 结论 ----------
Write-Host ''
Write-Host '=== 结论 ===' -ForegroundColor Cyan
if ($fake) {
    Write-Host '  诊断：fake-ip 干扰，先用真实 IP 复测，不要相信 TCP 结果。' -ForegroundColor Red
    $code = 2
} elseif (-not $tcp.Ok) {
    Write-Host '  诊断：网络/服务层未通过。按顺序查：目标机 sshd 是否运行 → 防火墙 → 端口 → 是否有假通设备。' -ForegroundColor Red
    $code = 2
} elseif ($authOk -eq $false) {
    Write-Host '  诊断：SSH 服务正常，但公钥登录失败。问题在账号/密钥/权限，不在网络。' -ForegroundColor Yellow
    $code = 1
} elseif ($authOk -eq $true) {
    Write-Host '  诊断：全链路正常。' -ForegroundColor Green
    $code = 0
} else {
    Write-Host '  诊断：SSH 握手正常（未测公钥登录）。' -ForegroundColor Green
    $code = 0
}
Write-Host ''

try {
    if (-not [Console]::IsInputRedirected) { Read-Host '按回车退出' | Out-Null }
} catch { }
exit $code
