# ============================================================
# SSHD Bridge Kit - Windows 回滚
# - 恢复 sshd_config 备份（或只移除托管段）
# - 删除本套件创建的防火墙规则
# - 停止 sshd 并改回 Manual
# - 可选：移除本套件写入的公钥
# 用法：powershell -ExecutionPolicy Bypass -File .\uninstall-sshd.ps1
# ============================================================
[CmdletBinding()]
param(
    [switch]$RemoveKeys,
    [switch]$KeepService,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$script:Here = $PSScriptRoot
$script:ManagedBegin = '# === managed by sshd-bridge-kit ==='
$script:ManagedEnd = '# === end managed by sshd-bridge-kit ==='
$fwRule = 'sshd-bridge-kit-22'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Pause-IfInteractive {
    if ($NoPause -or $env:SSHD_BRIDGE_NO_PAUSE -eq '1') { return }
    try { if (-not [Console]::IsInputRedirected) { Read-Host '按回车关闭' | Out-Null } } catch { }
}
function Invoke-Native {
    param([string]$Exe, [string[]]$Argv = @(), [int]$TimeoutMs = 20000)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $quoted = foreach ($a in $Argv) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ ExitCode = -2; Output = $out + $err } }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out + $err) }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $old
    }
}

if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求 UAC 授权...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($RemoveKeys) { $argList += '-RemoveKeys' }
    if ($KeepService) { $argList += '-KeepService' }
    $argList += '-NoPause'
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Host '提权失败，请右键以管理员身份运行。' -ForegroundColor Red
        exit 1
    }
}

Write-Host ''
Write-Host '=== SSHD Bridge Kit 回滚 ===' -ForegroundColor Cyan

# 1. 配置
$config = Join-Path $env:ProgramData 'ssh\sshd_config'
$backup = "$config.bak-sshd-bridge"
if (Test-Path -LiteralPath $backup) {
    Copy-Item -LiteralPath $backup -Destination $config -Force
    Write-Host "  已恢复配置备份：$backup" -ForegroundColor Green
} elseif (Test-Path -LiteralPath $config) {
    $text = Get-Content -LiteralPath $config -Raw
    $text = [regex]::Replace($text,
        '(?ms)^' + [regex]::Escape($script:ManagedBegin) + '.*?^' + [regex]::Escape($script:ManagedEnd) + '[ \t]*\r?\n?', '')
    Set-Content -LiteralPath $config -Value $text -Encoding ASCII
    Write-Host '  已移除托管配置段（没有备份文件）' -ForegroundColor Green
} else {
    Write-Host '  找不到 sshd_config，跳过' -ForegroundColor Yellow
}

# 2. 防火墙
try {
    $r = Get-NetFirewallRule -Name $fwRule -ErrorAction SilentlyContinue
    if ($r) {
        Remove-NetFirewallRule -Name $fwRule
        Write-Host "  已删除防火墙规则：$fwRule" -ForegroundColor Green
    } else {
        Write-Host '  没有找到本套件的防火墙规则' -ForegroundColor Gray
    }
} catch {
    Write-Host "  删除防火墙规则失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

# 3. 服务
if (-not $KeepService) {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Running') { Stop-Service sshd -Force -ErrorAction SilentlyContinue }
        Set-Service sshd -StartupType Manual -ErrorAction SilentlyContinue
        Write-Host '  sshd 已停止，启动类型改为 Manual' -ForegroundColor Green
    }
} else {
    Write-Host '  按 -KeepService 保留服务运行' -ForegroundColor Gray
}

# 4. 公钥
if ($RemoveKeys) {
    $bodies = New-Object System.Collections.ArrayList
    foreach ($d in @((Join-Path $script:Here 'keys'), (Join-Path (Split-Path $script:Here -Parent) 'keys'))) {
        if (Test-Path -LiteralPath $d) {
            Get-ChildItem -LiteralPath $d -Filter '*.pub' -File -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($line in (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue)) {
                    $p = ($line.Trim() -split '\s+')
                    if ($p.Count -ge 2) { [void]$bodies.Add($p[1]) }
                }
            }
        }
    }
    if ($bodies.Count -eq 0) {
        Write-Host '  keys\ 下没有 .pub，无法判断要移除哪些公钥' -ForegroundColor Yellow
    } else {
        $targets = @(
            (Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'),
            (Join-Path $env:USERPROFILE '.ssh\authorized_keys')
        )
        foreach ($t in $targets) {
            if (-not (Test-Path -LiteralPath $t)) { continue }
            $kept = @(Get-Content -LiteralPath $t | Where-Object {
                $p = ($_.Trim() -split '\s+')
                -not ($p.Count -ge 2 -and $bodies -contains $p[1])
            })
            Set-Content -LiteralPath $t -Value $kept -Encoding ASCII
            Write-Host "  已清理公钥：$t（剩 $($kept.Count) 行）" -ForegroundColor Green
        }
    }
}

# 5. 校验剩余配置
$ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
if (-not (Test-Path -LiteralPath $ssh)) { $ssh = Join-Path $env:ProgramFiles 'OpenSSH\sshd.exe' }
if (Test-Path -LiteralPath $ssh) {
    $t = Invoke-Native -Exe $ssh -Argv @('-t')
    if ($t.ExitCode -eq 0) { Write-Host '  sshd -t 通过' -ForegroundColor Green }
    else { Write-Host "  [!] sshd -t 未通过：$($t.Output.Trim())" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host '回滚完成。OpenSSH Server 本身没有卸载。' -ForegroundColor Cyan
Write-Host '如需彻底卸载：设置 → 应用 → 可选功能 → 删除 OpenSSH 服务器。' -ForegroundColor Gray
Write-Host ''
Pause-IfInteractive
