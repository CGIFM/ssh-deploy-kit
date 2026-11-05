# ============================================================
# SSHD Bridge Kit - Windows 一键部署
# 适用：Windows 10 / 11 / Server 2016+，管理员权限
# 特点：幂等；离线 MSI 优先；托管配置段；失败自动回滚；真握手验证
# 用法：双击 install.cmd，或
#       powershell -ExecutionPolicy Bypass -File .\setup-sshd.ps1
# 只体检不改动：.\setup-sshd.ps1 -CheckOnly
# ============================================================
[CmdletBinding()]
param(
    [string[]]$PubKeyFile = @(),
    [string[]]$PubKey = @(),
    [string]$AllowedUser = '',
    [int]$Port = 22,
    [switch]$KeepPassword,
    [switch]$NoFirewall,
    [switch]$NoTailscale,
    [switch]$SkipInstall,
    [switch]$CheckOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$script:KitVersion     = 'v1.0.0'
$script:Here           = $PSScriptRoot
$script:ManagedBegin   = '# === managed by sshd-bridge-kit ==='
$script:ManagedEnd     = '# === end managed by sshd-bridge-kit ==='
$script:CurStep        = ''
$script:T0             = Get-Date
$script:LogPath        = Join-Path $script:Here '安装日志.txt'
$script:Failures       = New-Object System.Collections.ArrayList

function Write-Ok   { param($t) Write-Host "      [OK] $t" -ForegroundColor Green }
function Write-Warn { param($t) Write-Host "      [!]  $t" -ForegroundColor Yellow }
function Write-Dim  { param($t) Write-Host "      $t" -ForegroundColor Gray }
function Write-Step {
    param([int]$n, [int]$total, [string]$text)
    $script:CurStep = "第 $n/$total 步：$text"
    $elapsed = [int]((Get-Date) - $script:T0).TotalSeconds
    $w = 20
    $fill = [int][math]::Round($w * $n / $total)
    if ($fill -gt $w) { $fill = $w }
    if ($fill -lt 0) { $fill = 0 }
    $bar = '[' + ('#' * $fill) + ('.' * ($w - $fill)) + ']'
    Write-Host ''
    Write-Host "  $bar  $n/$total   已用 ${elapsed}s" -ForegroundColor DarkGray
    Write-Host "  >> $text" -ForegroundColor Cyan
}
function Test-Interactive {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}
function Pause-IfInteractive {
    if ($NoPause -or $env:SSHD_BRIDGE_NO_PAUSE -eq '1') { return }
    if (-not (Test-Interactive)) { return }
    try { Read-Host '按回车关闭' | Out-Null } catch { }
}

# 原生命令写 stderr 在 PS 5.1 + EAP Stop 下会抛 NativeCommandError。
# 统一封装：只返回退出码和合并输出，不污染调用方。
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Argv = @(),
        [int]$TimeoutMs = 30000
    )
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $quoted = foreach ($a in $Argv) {
            if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Exe
        $psi.Arguments              = ($quoted -join ' ')
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = -2; Output = ($out + $err + "`n[timeout ${TimeoutMs}ms]") }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out + $err) }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-ShortPath([string]$Path) {
    if ($Path -notmatch '\s') { return $Path }
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        return $fso.GetFile($Path).ShortPath
    } catch { return $Path }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-Sshd {
    $candidates = New-Object System.Collections.ArrayList
    $svc = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.PathName -match '^\s*"?([^"]+\.exe)"?') {
        [void]$candidates.Add((Split-Path $Matches[1] -Parent))
    }
    [void]$candidates.Add((Join-Path $env:ProgramFiles 'OpenSSH'))
    [void]$candidates.Add((Join-Path $env:SystemRoot 'System32\OpenSSH'))
    foreach ($d in $candidates) {
        if ($d -and (Test-Path -LiteralPath (Join-Path $d 'sshd.exe'))) {
            return [pscustomobject]@{
                Dir       = $d
                Sshd      = (Join-Path $d 'sshd.exe')
                Keygen    = (Join-Path $d 'ssh-keygen.exe')
                Sftp      = (Join-Path $d 'sftp-server.exe')
                Session   = (Join-Path $d 'sshd-session.exe')
                HasSession= (Test-Path -LiteralPath (Join-Path $d 'sshd-session.exe'))
            }
        }
    }
    return $null
}

function Test-SshBanner {
    param([string]$TargetHost = '127.0.0.1', [int]$TargetPort = 22, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) { return '' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $buf = New-Object byte[] 256
        $n = $stream.Read($buf, 0, 256)
        if ($n -le 0) { return '' }
        $text = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
        $line = ($text -split "`n")[0].Trim()
        if ($line -match '^SSH-') { return $line }
        return ''
    } catch {
        return ''
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-KeyBodies {
    param([string[]]$Specs)
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $Specs) {
        $parts = ($s.Trim() -split '\s+')
        if ($parts.Count -ge 2) { [void]$out.Add($parts[1]) }
    }
    return $out
}

function Get-KeySpecs {
    $files = New-Object System.Collections.ArrayList
    foreach ($f in $PubKeyFile) { [void]$files.Add($f) }
    if ($files.Count -eq 0) {
        foreach ($d in @((Join-Path $script:Here 'keys'), (Join-Path (Split-Path $script:Here -Parent) 'keys'))) {
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Filter '*.pub' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { [void]$files.Add($_.FullName) }
            }
        }
    }
    $specs = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { throw "找不到公钥文件：$f" }
        foreach ($line in (Get-Content -LiteralPath $f -ErrorAction Stop)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { [void]$specs.Add($t) }
        }
    }
    foreach ($k in $PubKey) {
        $t = $k.Trim()
        if ($t) { [void]$specs.Add($t) }
    }

    $valid = New-Object System.Collections.ArrayList
    foreach ($s in $specs) {
        if ($s -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+[A-Za-z0-9+/=]{32,}(\s+.*)?$') {
            throw "公钥格式不合法（拒绝写入）：$($s.Substring(0, [Math]::Min(40, $s.Length)))..."
        }
        [void]$valid.Add($s)
    }
    return ($valid | Select-Object -Unique)
}

function Resolve-UserHome([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $env:USERPROFILE }
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($Name)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        $reg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        $p = (Get-ItemProperty -Path $reg -ErrorAction Stop).ProfileImagePath
        if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
    } catch { }
    return ''
}

function Add-KeysToFile {
    param([string]$Path, [string[]]$Specs)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }
    $existing = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    $bodies = @()
    foreach ($line in $existing) {
        $p = ($line.Trim() -split '\s+')
        if ($p.Count -ge 2) { $bodies += $p[1] }
    }
    $added = 0
    foreach ($s in $Specs) {
        $body = ($s -split '\s+')[1]
        if ($bodies -notcontains $body) {
            Add-Content -LiteralPath $Path -Value $s -Encoding ASCII
            $bodies += $body
            $added++
        }
    }
    # 回读校验：不信任"命令没报错"
    $after = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    foreach ($s in $Specs) {
        $body = ($s -split '\s+')[1]
        if ($after -notmatch [regex]::Escape($body)) {
            throw "公钥写入后回读失败：$Path"
        }
    }
    return $added
}

function Get-SshdMajorVersion {
    param([string]$SshdPath)
    $r = Invoke-Native -Exe $SshdPath -Argv @('-V') -TimeoutMs 10000
    if ($r.Output -match 'OpenSSH(?:_for_Windows)?[_-](\d+)\.') { return [int]$Matches[1] }
    return 0
}

# ---------- 错误处理 ----------
trap {
    $msg = "[$script:KitVersion] 错误：$($_.Exception.GetType().FullName)：$($_.Exception.Message)"
    if ($script:CurStep) { $msg += "（卡在 $script:CurStep）" }
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Red
    Write-Host '  部署中止' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  类型：$($_.Exception.GetType().FullName)" -ForegroundColor DarkRed
    if ($_.ScriptStackTrace) { Write-Host "  位置：$($_.ScriptStackTrace)" -ForegroundColor DarkRed }
    Write-Host ('=' * 62) -ForegroundColor Red
    try { Add-Content -Path $script:LogPath -Value $msg -Encoding UTF8 } catch { }
    try {
        $failPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '部署失败.txt'
        $msg | Set-Content -Path $failPath -Encoding UTF8
        Write-Host "  失败信息：$failPath" -ForegroundColor DarkGray
    } catch { }
    Pause-IfInteractive
    exit 1
}

# ---------- 0. 提权 ----------
if (-not (Test-Admin) -and -not $CheckOnly) {
    Write-Host ''
    Write-Host '  需要管理员权限，正在请求 UAC 授权...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } elseif ($v -is [array]) {
            foreach ($x in $v) { $argList += "-$k"; $argList += ('"' + [string]$x + '"') }
        } else {
            $argList += "-$k"; $argList += ('"' + [string]$v + '"')
        }
    }
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Host '  UAC 提权失败或被取消。请右键 install.cmd → 以管理员身份运行。' -ForegroundColor Red
        exit 1
    }
}

try { Start-Transcript -Path $script:LogPath -Append -ErrorAction Stop | Out-Null } catch { }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  SSHD Bridge Kit  $script:KitVersion" -ForegroundColor Green
Write-Host "  本机：$env:COMPUTERNAME    时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Green
Write-Host "  模式：$(if ($CheckOnly) { '仅体检（不修改）' } else { '安装 / 修复' })" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green

# ---------- 1. 定位或安装 OpenSSH Server ----------
Write-Step 1 8 '定位 OpenSSH Server'
$ssh = Resolve-Sshd
if ($ssh) {
    Write-Ok "已安装：$($ssh.Dir)"
} elseif ($SkipInstall) {
    throw '指定了 -SkipInstall，但没有找到 sshd.exe'
} elseif ($CheckOnly) {
    Write-Warn '未安装 OpenSSH Server（体检模式不安装）'
    [void]$script:Failures.Add('OpenSSH Server 未安装')
} else {
    $msiCandidates = @(
        (Join-Path $script:Here 'offline\OpenSSH-Win64.msi'),
        (Join-Path $script:Here 'OpenSSH-Win64.msi'),
        (Join-Path (Split-Path $script:Here -Parent) 'offline\OpenSSH-Win64.msi'),
        (Join-Path (Split-Path $script:Here -Parent) 'OpenSSH-Win64.msi')
    )
    $msi = $msiCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($msi) {
        Write-Dim "使用离线安装包：$msi"
        $shaFile = "$msi.sha256"
        if (Test-Path -LiteralPath $shaFile) {
            $expected = ((Get-Content -LiteralPath $shaFile -Raw) -split '\s+')[0].ToUpperInvariant()
            $actual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
            if ($actual -ne $expected) { throw "MSI SHA256 不匹配，文件可能不完整：$actual" }
            Write-Ok 'SHA256 校验通过'
        } else {
            Write-Warn '没有 .sha256 旁文件，跳过哈希校验'
        }
        $sig = Get-AuthenticodeSignature -LiteralPath $msi
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "MSI 签名者不是 Microsoft：$($sig.SignerCertificate.Subject)"
        }
        if ($sig.Status -ne 'Valid') {
            Write-Warn "签名链无法验证（$($sig.Status)），依赖哈希/来源保证"
        }
        $msiLog = Join-Path $script:Here 'msi.log'
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" ADDLOCAL=Server /qn /norestart /L*v `"$msiLog`"" -PassThru
        $spin = '|/-\'; $i = 0
        while (-not $p.HasExited) {
            Write-Host ("`r      正在安装 OpenSSH Server " + $spin[($i % 4)]) -NoNewline -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds 400
            $i++
        }
        Write-Host "`r      正在安装 OpenSSH Server 完成            "
        if ($p.ExitCode -notin @(0, 3010)) { throw "MSI 安装失败，退出码 $($p.ExitCode)，详见 msi.log" }
        $ssh = Resolve-Sshd
    }

    if (-not $ssh) {
        Write-Dim '尝试在线安装 Windows 可选功能 OpenSSH.Server...'
        try {
            $cap = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
            Write-Ok "能力安装状态：$($cap.RestartNeeded)"
        } catch {
            Write-Warn "在线安装失败：$($_.Exception.Message)"
        }
        $ssh = Resolve-Sshd
    }

    if (-not $ssh) {
        throw @'
没有可用的 OpenSSH Server。
请在有网的机器下载微软官方 MSI：
  https://github.com/PowerShell/Win32-OpenSSH/releases
放到 windows\offline\OpenSSH-Win64.msi 后重跑。
如果安全软件会拦截 PowerShell 安装，改用预先编译好的单文件离线安装器 EXE。
'@
    }
    Write-Ok "安装位置：$($ssh.Dir)"
}
if (-not $ssh) {
    if ($CheckOnly) {
        Write-Host ''
        Write-Host '  体检结论：未安装 OpenSSH Server（体检模式不做任何修改）' -ForegroundColor Yellow
        Write-Host '  安装方式：把 OpenSSH-Win64.msi 放到 windows\offline\ 后双击 install.cmd' -ForegroundColor Yellow
        Pause-IfInteractive
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
    throw '无法解析 sshd.exe 所在目录'
}

# 10.x 需要 sshd-session.exe，缺失会 1067；9.x 不需要，不能误报
if (-not $ssh.HasSession) {
    $major = Get-SshdMajorVersion -SshdPath $ssh.Sshd
    if ($major -ge 10) {
        Write-Warn "检测到 OpenSSH $major.x 但缺少 sshd-session.exe（会导致服务 1067）"
        Write-Warn '请用完整的离线 MSI 重装，或把同版本 sshd-session.exe 放到安装目录'
    }
}

# ---------- 2. 主机密钥 + sshd_config ----------
Write-Step 2 8 '准备主机密钥与 sshd_config'

# 先确定公钥，再决定是否关闭密码：没有公钥却关密码 = 把自己锁在门外
$specs = @()
try { $specs = @(Get-KeySpecs) } catch { Write-Warn $_.Exception.Message }
if ($specs.Count -eq 0 -and -not $KeepPassword) {
    Write-Warn '没有可用公钥，本次强制保留密码登录（否则会锁死）'
}
$harden = (-not $KeepPassword) -and ($specs.Count -gt 0)

$dataDir = Join-Path $env:ProgramData 'ssh'
$config  = Join-Path $dataDir 'sshd_config'
$backup  = "$config.bak-sshd-bridge"

if (-not $CheckOnly) {
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'ssh_host_ed25519_key'))) {
        $r = Invoke-Native -Exe $ssh.Keygen -Argv @('-A') -TimeoutMs 20000
        if ($r.ExitCode -ne 0) { throw "生成主机密钥失败：$($r.Output)" }
        Write-Ok '已生成主机密钥'
    } else {
        Write-Ok '主机密钥已存在'
    }
}

if (-not (Test-Path -LiteralPath $config)) {
    if ($CheckOnly) {
        Write-Warn "sshd_config 不存在：$config"
        [void]$script:Failures.Add('sshd_config 不存在')
    } else {
        $defaultCfg = Join-Path $ssh.Dir 'sshd_config_default'
        if (-not (Test-Path -LiteralPath $defaultCfg)) { throw "找不到模板：$defaultCfg" }
        Copy-Item -LiteralPath $defaultCfg -Destination $config
        Write-Ok '已从默认模板创建 sshd_config'
    }
}

if (Test-Path -LiteralPath $config) {
    $originalText = Get-Content -LiteralPath $config -Raw
    if (-not $CheckOnly) {
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $config -Destination $backup
            Write-Ok "原配置已备份：$backup"
        }
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $config -Destination $backup }

        $text = $originalText

        # 移除旧托管段
        $text = [regex]::Replace($text,
            '(?ms)^' + [regex]::Escape($script:ManagedBegin) + '.*?^' + [regex]::Escape($script:ManagedEnd) + '[ \t]*\r?\n?', '')

        # 移除会与托管段冲突的旧指令（sshd 取首次出现的值）
        $text = [regex]::Replace($text,
            '(?m)^[ \t]*#?[ \t]*(Port|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|AuthenticationMethods)[ \t]+\S.*\r?\n?', '')

        $harden = (-not $KeepPassword) -and ($specs.Count -gt 0)
        $managed = New-Object System.Collections.ArrayList
        [void]$managed.Add($script:ManagedBegin)
        [void]$managed.Add("Port $Port")
        [void]$managed.Add('PubkeyAuthentication yes')
        [void]$managed.Add("PasswordAuthentication $(if ($harden) { 'no' } else { 'yes' })")
        [void]$managed.Add('KbdInteractiveAuthentication no')
        if ($harden) { [void]$managed.Add('AuthenticationMethods publickey') }
        [void]$managed.Add($script:ManagedEnd)
        $text = (($managed -join "`r`n") + "`r`n" + $text)

        # SFTP 子系统：裸文件名在 Windows 下常解析不到
        if ($ssh.Sftp -and (Test-Path -LiteralPath $ssh.Sftp)) {
            $sftpPath = Get-ShortPath $ssh.Sftp
            if ($text -match '(?m)^[ \t]*Subsystem[ \t]+sftp\b.*$') {
                $text = [regex]::Replace($text, '(?m)^[ \t]*Subsystem[ \t]+sftp\b.*$', "Subsystem sftp $sftpPath")
            } else {
                $text += "`r`nSubsystem sftp $sftpPath`r`n"
            }
        }

        # 管理员组公钥路径
        if ($text -notmatch 'administrators_authorized_keys') {
            $text += "`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"
        }

        Set-Content -LiteralPath $config -Value $text -Encoding ASCII
        Write-Ok "已写入托管段（端口 $Port，密码登录：$(if ($harden) { '关闭' } else { '保留' })）"

        # 先校验，失败回滚到本次修改前的内容
        $t = Invoke-Native -Exe $ssh.Sshd -Argv @('-t') -TimeoutMs 15000
        if ($t.ExitCode -ne 0) {
            Set-Content -LiteralPath $config -Value $originalText -Encoding ASCII
            throw "sshd_config 校验未通过，已回滚：$($t.Output.Trim())"
        }
        Write-Ok 'sshd_config 校验通过'
    }
}

# ---------- 3. 写入公钥 ----------
Write-Step 3 8 '写入登录公钥'
if ($specs.Count -gt 0) {
    if (-not $KeepPassword) {
        Write-Dim '已提供公钥，默认关闭密码登录（-KeepPassword 可保留）'
    }
    $adminKeys = Join-Path $dataDir 'administrators_authorized_keys'
    $targetHome = Resolve-UserHome $AllowedUser
    $userKeys = ''
    if ($targetHome) { $userKeys = Join-Path (Join-Path $targetHome '.ssh') 'authorized_keys' }

    if ($CheckOnly) {
        foreach ($p in @($adminKeys, $userKeys)) {
            if (-not $p) { continue }
            if (Test-Path -LiteralPath $p) {
                $c = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
                $missing = 0
                foreach ($b in (Get-KeyBodies $specs)) { if ($c -notmatch [regex]::Escape($b)) { $missing++ } }
                if ($missing -eq 0) { Write-Ok "公钥齐全：$p" }
                else { Write-Warn "缺少 $missing 把公钥：$p"; [void]$script:Failures.Add("公钥缺失：$p") }
            } else {
                Write-Warn "公钥文件不存在：$p"
                [void]$script:Failures.Add("公钥文件不存在：$p")
            }
        }
    } else {
        New-Item -ItemType Directory -Path (Split-Path $adminKeys -Parent) -Force | Out-Null
        $n1 = Add-KeysToFile -Path $adminKeys -Specs $specs
        $r = Invoke-Native -Exe 'icacls.exe' -Argv @($adminKeys, '/inheritance:r', '/grant', '*S-1-5-18:F', '/grant', '*S-1-5-32-544:F')
        if ($r.ExitCode -ne 0) { Write-Warn "administrators_authorized_keys ACL 设置失败：$($r.Output.Trim())" }
        Write-Ok "管理员公钥：$adminKeys（新增 $n1 条）"

        if ($userKeys) {
            New-Item -ItemType Directory -Path (Split-Path $userKeys -Parent) -Force | Out-Null
            $n2 = Add-KeysToFile -Path $userKeys -Specs $specs
            $sid = try {
                if ($AllowedUser) {
                    (New-Object System.Security.Principal.NTAccount($AllowedUser)).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                } else {
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                }
            } catch { '' }
            if ($sid) {
                $r2 = Invoke-Native -Exe 'icacls.exe' -Argv @($userKeys, '/inheritance:r', '/grant', "*$sid`:F", '/grant', '*S-1-5-18:F')
                if ($r2.ExitCode -ne 0) { Write-Warn "用户公钥 ACL 设置失败：$($r2.Output.Trim())" }
            }
            Write-Ok "用户公钥：$userKeys（新增 $n2 条）"
        } elseif ($AllowedUser) {
            Write-Warn "找不到账号 $AllowedUser 的用户目录，只写了管理员公钥"
        }
    }
} else {
    Write-Warn '没有提供公钥，保留密码登录'
    if (-not $KeepPassword) {
        Write-Warn '（原本会关闭密码，但没有公钥会被锁死，已自动保留）'
    }
}

# ---------- 4. 防火墙 ----------
Write-Step 4 8 '配置防火墙'
$fwRule = 'sshd-bridge-kit-22'
$ranges = @('10.0.0.0/8', '192.168.0.0/16', '172.16.0.0/12')
if (-not $NoTailscale) { $ranges += '100.64.0.0/10' }

if ($NoFirewall) {
    Write-Ok '已指定 -NoFirewall，跳过'
} elseif ($CheckOnly) {
    try {
        $rule = Get-NetFirewallRule -Name $fwRule -ErrorAction SilentlyContinue
        if ($rule) {
            $filter = $rule | Get-NetFirewallPortFilter
            $addr = ($rule | Get-NetFirewallAddressFilter).RemoteAddress -join ', '
            Write-Ok "规则存在：$fwRule（端口 $($filter.LocalPort)，来源 $addr）"
        } else {
            Write-Warn "防火墙规则不存在：$fwRule"
            [void]$script:Failures.Add("防火墙规则缺失：$fwRule")
        }
    } catch {
        Write-Warn "无法读取防火墙规则：$($_.Exception.Message)"
    }
} else {
    try {
        foreach ($n in @('OpenSSH-Server-In-TCP', 'OpenSSH-SSH-Server-In-TCP', 'OpenSSH-Server-In-TCP-Preview')) {
            $r = Get-NetFirewallRule -Name $n -ErrorAction SilentlyContinue
            if ($r) {
                Set-NetFirewallRule -Name $n -Enabled True -Action Allow -RemoteAddress $ranges -Profile Any | Out-Null
                Write-Ok "已收窄内置规则：$n"
            }
        }
        Get-NetFirewallRule -Name $fwRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $fwRule -DisplayName 'SSHD Bridge Kit (LAN + Tailscale)' `
            -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow `
            -RemoteAddress $ranges -Profile Any | Out-Null
        Write-Ok "已建规则：$fwRule（$($ranges -join ', ')）"
    } catch {
        Write-Warn "防火墙配置失败：$($_.Exception.Message)"
        Write-Warn '（SSH 服务本身不受影响，可稍后手动放行）'
    }
}

# ---------- 5. 服务 ----------
Write-Step 5 8 '启动 sshd 并设置自动恢复'
if ($CheckOnly) {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Ok "服务：$($svc.Status) / $($svc.StartType)"
        if ($svc.Status -ne 'Running') { [void]$script:Failures.Add('sshd 服务未运行') }
    } else {
        Write-Warn 'sshd 服务不存在'
        [void]$script:Failures.Add('sshd 服务不存在')
    }
} else {
    $busy = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        $pid22 = $busy[0].OwningProcess
        $owner = ''
        try { $owner = (Get-Process -Id $pid22 -ErrorAction Stop).ProcessName } catch { }
        if ($owner -and $owner -ne 'sshd') {
            Write-Warn "端口 $Port 已被 $owner (PID $pid22) 占用，sshd 可能无法启动"
        }
    }
    Set-Service -Name sshd -StartupType Automatic
    $null = Invoke-Native -Exe 'sc.exe' -Argv @('failure', 'sshd', 'reset=', '86400', 'actions=', 'restart/5000/restart/10000/restart/30000')
    $svc = Get-Service sshd
    try {
        if ($svc.Status -eq 'Running') { Restart-Service sshd -Force }
        else { Start-Service sshd }
    } catch {
        $t = Invoke-Native -Exe $ssh.Sshd -Argv @('-t') -TimeoutMs 15000
        throw "sshd 启动失败：$($_.Exception.Message)`nsshd -t：$($t.Output.Trim())"
    }
    Start-Sleep -Seconds 2
    Write-Ok "服务：$((Get-Service sshd).Status) / Automatic / 异常自动重启"
    $agent = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($agent) {
        Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
        if ($agent.Status -ne 'Running') { Start-Service ssh-agent -ErrorAction SilentlyContinue }
        Write-Ok "ssh-agent：$((Get-Service ssh-agent).Status) / Automatic"
    }
}

# ---------- 6. 配置自检 ----------
Write-Step 6 8 '配置自检'
$cfgOk = $false
$t = Invoke-Native -Exe $ssh.Sshd -Argv @('-t') -TimeoutMs 15000
if ($t.ExitCode -eq 0) { $cfgOk = $true; Write-Ok 'sshd -t 通过' }
else { Write-Warn "sshd -t 未通过：$($t.Output.Trim())"; [void]$script:Failures.Add('sshd -t 未通过') }

$effective = ''
$te = Invoke-Native -Exe $ssh.Sshd -Argv @('-T') -TimeoutMs 15000
if ($te.ExitCode -eq 0) {
    $effective = (($te.Output -split "`r?`n") | Where-Object {
        $_ -match '^(port|passwordauthentication|pubkeyauthentication|authenticationmethods|kbdinteractiveauthentication|permitrootlogin) '
    }) -join "`n"
    if ($effective) { Write-Dim ($effective -replace "`n", ' | ') }
} else {
    Write-Warn "sshd -T 读取失败：$($te.Output.Trim())"
}

$listen = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count
if ($listen -gt 0) { Write-Ok "端口 $Port 正在监听（$listen 个 socket）" }
else { Write-Warn "端口 $Port 没有监听"; [void]$script:Failures.Add("端口 $Port 未监听") }

# ---------- 7. 真握手 ----------
Write-Step 7 8 '连通性验证（必须读到 SSH- banner）'
$banner = ''
$bannerAttempts = 10
if ($CheckOnly) {
    $svcNow = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svcNow -or $svcNow.Status -ne 'Running') { $bannerAttempts = 1 }
}
for ($i = 0; $i -lt $bannerAttempts; $i++) {
    $banner = Test-SshBanner -TargetPort $Port
    if ($banner) { break }
    Start-Sleep -Seconds 2
}
if ($banner) { Write-Ok "握手成功：$banner" }
else {
    Write-Warn "端口 $Port 没有返回 SSH- banner（TCP 通也不算通）"
    [void]$script:Failures.Add('未读到 SSH banner')
}

# ---------- 8. 汇总 ----------
Write-Step 8 8 '汇总'
$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object InterfaceMetric | Select-Object -ExpandProperty IPAddress)
$firstIp = if ($ips.Count -gt 0) { $ips[0] } else { '<本机IP>' }
$loginUser = if ($AllowedUser) { $AllowedUser } else { $env:USERNAME }
$okAll = ($script:Failures.Count -eq 0) -and [bool]$banner -and ($listen -gt 0)

$lines = @(
    "=== SSHD Bridge Kit 部署结果（$script:KitVersion） ===",
    "结论      : $(if ($okAll) { '成功，SSH 已通' } else { '未完全成功，见下' })",
    "时间      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "电脑名    : $env:COMPUTERNAME",
    "用户      : $(whoami)",
    "本机 IP   : $($ips -join ', ')",
    '',
    '--- 服务 ---',
    "sshd      : $(if (Get-Service sshd -ErrorAction SilentlyContinue) { "$((Get-Service sshd).Status) / $((Get-Service sshd).StartType)" } else { '不存在' })",
    '',
    '--- 配置 ---',
    "端口      : $Port",
    "密码登录  : $(if ($KeepPassword -or $specs.Count -eq 0) { '保留' } else { '关闭' })",
    "sshd -t   : $(if ($cfgOk) { '通过' } else { '未通过' })",
    "生效配置  : $($effective -replace "`n", ' | ')",
    '',
    '--- 连通性 ---',
    "SSH 握手  : $(if ($banner) { $banner } else { '未通过' })",
    "登录命令  : ssh $loginUser@$firstIp$(if ($Port -ne 22) { " -p $Port" } else { '' })",
    ''
)
if ($script:Failures.Count -gt 0) {
    $lines += '--- 待处理 ---'
    foreach ($f in $script:Failures) { $lines += "  - $f" }
    $lines += ''
}
$lines += '说明：本套件只把读到 SSH- banner 视为连通；配置改动前已备份 sshd_config。'

$resultText = $lines -join "`r`n"
$resultPath = Join-Path $script:Here '部署结果.txt'
try { Set-Content -LiteralPath $resultPath -Value $resultText -Encoding UTF8 } catch { }
try {
    $desk = Join-Path ([Environment]::GetFolderPath('Desktop')) '部署结果.txt'
    Set-Content -LiteralPath $desk -Value $resultText -Encoding UTF8
    Write-Dim "结果文件：$desk"
} catch { }

Write-Host ''
Write-Host ('=' * 62) -ForegroundColor Green
if ($okAll) { Write-Host '  部署完成 —— SSH 服务已启动，真实握手正常' -ForegroundColor Green }
elseif ($CheckOnly) { Write-Host '  体检完成 —— 见上面的 [!] 项' -ForegroundColor Yellow }
else { Write-Host '  部署未完全成功 —— 见上面的 [!] 项' -ForegroundColor Yellow }
Write-Host ('=' * 62) -ForegroundColor Green
Write-Host "  登录账号 : $loginUser" -ForegroundColor Cyan
Write-Host "  登录命令 : ssh $loginUser@$firstIp$(if ($Port -ne 22) { " -p $Port" } else { '' })" -ForegroundColor Cyan
Write-Host "  密码登录 : $(if ($KeepPassword -or $specs.Count -eq 0) { '保留' } else { '关闭' })" -ForegroundColor Cyan
Write-Host "  配置备份 : $(if (Test-Path -LiteralPath $backup) { $backup } else { '尚未创建（首次安装时生成）' })" -ForegroundColor Cyan
Write-Host "  结果文件 : $resultPath" -ForegroundColor Cyan
Write-Host "  耗时     : $([int]((Get-Date) - $script:T0).TotalSeconds) 秒" -ForegroundColor DarkGray
Write-Host ('=' * 62) -ForegroundColor Green
Write-Host ''

if (-not $CheckOnly -and $specs.Count -gt 0 -and $KeepPassword) {
    Write-Host '  下一步：确认公钥能登录后，重跑本脚本（不带 -KeepPassword）即可关闭密码登录。' -ForegroundColor Yellow
    Write-Host ''
}

Pause-IfInteractive
try { Stop-Transcript | Out-Null } catch { }
if ($CheckOnly -and $script:Failures.Count -gt 0) { exit 1 }
exit 0
