# SSH 部署踩坑手册

> 来源：在 Windows 10/11、macOS、Linux 与多台远程主机上的真实部署记录。
> 用法：部署前按平台扫一遍；出问题时按"现象"定位。

图例：**现象** → 你看到什么；**根因** → 为什么；**对策** → 本套件怎么处理。

---

## A. Windows 安装

### A1. DISM 在线安装 OpenSSH.Server 失败（0x800F0954 / 找不到源）
**现象**：`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` 报错或长时间卡住。
**根因**：目标机无外网，或 WSUS/组策略把 Windows 更新源指到了不可达地址。
**对策**：用微软官方签名 MSI 离线安装（`windows/offline/OpenSSH-Win64.msi`）。本套件先找本地 MSI，再尝试在线能力安装。

### A2. 安全软件终止安装脚本
**现象**：PowerShell 进程被 EDR 杀掉，提示"发现漏洞利用企图"；脚本执行到一半消失。
**根因**：EDR 对 `Invoke-Expression`、下载后执行、脚本内嵌二进制敏感。
**对策**：不要用 PowerShell 下载并执行安装器；改用签名 MSI，或预先编译好的单文件离线安装器 EXE。安装动作以 `msiexec /qn` 完成。

### A3. sshd 服务启动后立刻停止，错误 1067
**现象**：`Start-Service sshd` 报 1067，事件日志里进程退出。
**根因**：两种情况最常见——① OpenSSH 10.x 需要同目录的 `sshd-session.exe`，缺失就 1067；② `sshd_config` 语法错误。
**对策**：先跑 `sshd -t` 看具体行号；再检查 `sshd-session.exe` 是否存在。本套件两步都做，配置不通过直接回滚。

### A4. `C:\Program Files\OpenSSH` 不存在，但服务其实能跑
**现象**：脚本判断"未安装"，准备重装，实际 `C:\Windows\System32\OpenSSH\sshd.exe` 已经存在。
**根因**：Windows 可选功能版把二进制放在 `System32\OpenSSH`，不是 Program Files。
**对策**：以服务的 `PathName` 为准解析安装目录，依次回退到 `ProgramFiles\OpenSSH`、`System32\OpenSSH`。

### A5. 装完服务仍是 Manual，重启后连不上
**根因**：MSI/能力安装不会自动把启动类型设为 Automatic。
**对策**：显式 `Set-Service sshd -StartupType Automatic`，并配置 `sc failure` 自动重启。

### A6. 22 端口被别的程序占用
**现象**：sshd 启动失败或起来后握手是别的服务。
**根因**：第三方 SSH、证书工具、备份软件先占了 22。
**对策**：启动前用 `Get-NetTCPConnection -LocalPort 22` 查占用进程并明确告警，而不是等失败后猜。

### A7. 防火墙规则名不统一
**现象**：想收窄规则却找不到，或者收窄了旧的、新规则仍全开。
**根因**：不同 Windows 版本/安装方式生成的规则名不同：`OpenSSH-Server-In-TCP`、`OpenSSH-SSH-Server-In-TCP`、`OpenSSH-Server-In-TCP-Preview`。
**对策**：三个名字都尝试收窄，再新建一条带统一名字的规则（`sshd-bridge-kit-22`）。防火墙失败只警告，不阻断 SSH 安装。

### A8. 只放行 RFC1918，Tailscale 连不上
**现象**：内网能连，Tailscale 地址 `100.x.y.z` 超时。
**根因**：Tailscale 用 `100.64.0.0/10`（CGNAT 段），不属于 `10/8`、`172.16/12`、`192.168/16`。
**对策**：默认把 `100.64.0.0/10` 也放进 RemoteAddress；不需要 Tailscale 时用 `-NoTailscale` 关掉。

---

## B. Windows 配置与认证

### B1. 公钥放进用户 `authorized_keys`，管理员登录仍要密码
**现象**：`~/.ssh/authorized_keys` 明明有公钥，`ssh Administrator@host` 还是被拒。
**根因**：管理员组默认读 `%ProgramData%\ssh\administrators_authorized_keys`，并由 `Match Group administrators` 指定。
**对策**：两处都写，或按账号判断写正确位置。本套件默认写管理员密钥文件 + 当前用户文件。

### B2. 管理员密钥文件权限过宽，sshd 静默拒绝
**现象**：密钥内容正确、路径正确，日志里却是 `Authentication refused: bad ownership or modes`。
**根因**：`administrators_authorized_keys` 必须只允许 SYSTEM 和 Administrators 访问。
**对策**：
```
icacls administrators_authorized_keys /inheritance:r /grant *S-1-5-18:F /grant *S-1-5-32-544:F
```
用 SID 而不是本地化组名。

### B3. SFTP 连上就断
**现象**：SSH 命令正常，`sftp`/`scp` 报 `subsystem request failed`。
**根因**：`Subsystem sftp sftp-server.exe` 用了裸文件名，sshd 不从同目录找。
**对策**：写绝对路径；路径带空格时用 8.3 短路径（`D:\PROGRA~2\OpenSSH\sftp-server.exe`）。

### B4. 改了配置不生效，或被旧行覆盖
**现象**：文件里明明写了 `PasswordAuthentication no`，`sshd -T` 还是 `yes`。
**根因**：sshd 对多数指令取**第一次出现**的值；前面未注释的旧行赢。
**对策**：删除所有同名旧行（含注释形式），把托管段放在文件顶部。重复执行先移除旧托管段。

### B5. `Match` 块后面的配置全部失效
**现象**：追加在 `Match Group administrators` 之后的全局配置不生效。
**根因**：`Match` 开始后，后续指令都属于该条件块，直到下一个 `Match`。
**对策**：所有全局指令必须在 `Match` 之前；`Match` 块统一追加到文件末尾。

### B6. `sshd_config` 带 BOM / UTF-16，sshd 直接报错
**现象**：`sshd -t` 报 `Bad configuration option: \ufeff...`。
**根因**：PowerShell 默认 `Set-Content` 编码因版本而异，可能写 BOM 或 UTF-16。
**对策**：配置和公钥一律用 ASCII 写入；中文只出现在输出和结果文件里。

### B7. 公钥被改坏，认证必然失败
**现象**：`AAAAC3NzaC1lZDI1NTE5` 变成了 `AAAAC3nzaC1lZDI1NTE5`（大写 N 变小写）。
**根因**：用 bash 双引号包 PowerShell，反引号被 bash 当命令替换吃掉；`-replace` 又是大小写不敏感的，`n` 把全文的 `N` 都替换了。
**对策**：永远写独立的 `.ps1` 文件再执行；导入公钥后校验 base64 前缀；本套件写入后回读比对。

### B8. PowerShell 5.1 下原生命令写 stderr 导致脚本中断
**现象**：`net use`、`sc.exe`、`icacls` 明明成功，脚本却抛 `NativeCommandError`。
**根因**：`$ErrorActionPreference='Stop'` 会把原生命令的 stderr 当终止错误。
**对策**：封装 `Invoke-Native`，内部临时 `Continue`，只返回退出码和合并输出。不能用 `2>&1` 硬顶。

### B9. `.ps1` 带中文注释，`powershell -File` 解析崩溃
**现象**：报语法错误，指向一段看起来没问题的 `Add-Type` here-string。
**根因**：Windows PowerShell 5.1 读取无 BOM 的 `.ps1` 时按系统 ANSI（GBK）解码，UTF-8 中文把后续字节吃乱。
**对策**：所有 `.ps1` 保存为 **UTF-8 with BOM + CRLF**；发布脚本统一转换。

### B10. `.cmd` 中文乱码或直接不执行
**根因**：cmd 按 OEM 代码页读批处理，UTF-8 中文会破坏解析。
**对策**：入口 `.cmd` 保持纯 ASCII，只负责提权和调用 `.ps1`；需要中文提示时用 `chcp 936` 后再 `echo`，或全部交给 PowerShell 输出。

### B11. 远程调用卡在"按回车关闭"
**现象**：无人值守部署永远不返回，调用方（剪贴板桥、CI）被堵死。
**对策**：`-NoPause` / 环境变量 `SSHD_BRIDGE_NO_PAUSE=1`；并用 `[Console]::IsInputRedirected` 判断是否真的有交互终端。

---

## C. macOS

### C1. `systemsetup -setremotelogin on` 失败
**现象**：命令返回非 0，远程登录没开。
**根因**：macOS 13+ 需要给终端"完全磁盘访问权限"，否则 systemsetup 无法改。
**对策**：提示用户到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」勾选终端；脚本同时尝试 `launchctl bootstrap` 兜底。

### C2. `sshd_config.d` 不存在，Include 无效
**根因**：旧版 macOS 没有 drop-in 目录，主配置也没有 `Include`。
**对策**：先 `mkdir -p /etc/ssh/sshd_config.d`，再检查主配置是否有 `Include /etc/ssh/sshd_config.d/*`，没有就插到顶部。

### C3. 先关密码后验证，直接锁死
**现象**：`--harden` 之后控制端公钥其实没生效，再也连不上。
**根因**：公钥写入失败（权限、路径、CRLF）被忽略，却已经把密码关了。
**对策**：`--harden` 必须同时满足"公钥写入成功"；否则拒绝执行。更稳的流程是先普通安装 → 控制端实测登录 → 再 `harden-ssh.sh`。

### C4. `authorized_keys` 权限/属主不对，StrictModes 拒绝
**根因**：`~/.ssh` 不是 700、`authorized_keys` 不是 600、属主不是目标账号，或主目录对 group/other 可写。
**对策**：`chmod 700 ~/.ssh`、`chmod 600 authorized_keys`、`chown` 到目标用户；脚本额外检查主目录是否 group/other 可写并告警。

### C5. Windows 生成的 `.pub` 带 CRLF
**现象**：公钥行尾多一个 `\r`，sshd 认为 key 格式非法。
**根因**：跨平台拷贝没有转换换行。
**对策**：写入前 `tr -d '\r'`；本套件 Mac/Linux 脚本都会清洗。

### C6. 应用防火墙拦截 sshd
**根因**：macOS 自带 `socketfilterfw` 对未签名/未放行的二进制默认拦截。
**对策**：`socketfilterfw --add /usr/sbin/sshd` + `--unblockapp /usr/sbin/sshd`；同时检查 `pf` 是否有自定义规则。

### C7. 想改 SSH 端口
**根因**：macOS 的 sshd 由 launchd socket 激活，端口写在 `ssh.plist` 里，不是只改 `sshd_config`。
**对策**：本套件固定 22；确实要改端口，需改 plist 并 `launchctl bootout/bootstrap`，不建议远程操作。

### C8. 只看配置文件，不看生效值
**对策**：用 `sshd -T` 读取最终生效配置，确认 `passwordauthentication`、`pubkeyauthentication`、`authenticationmethods` 与预期一致。

---

## D. Linux

### D1. cloud-init 覆盖了你的加固配置
**现象**：写了 `/etc/ssh/sshd_config.d/100-hardening.conf`，`sshd -T` 仍是 `PasswordAuthentication yes`。
**根因**：Ubuntu 云镜像有 `/etc/ssh/sshd_config.d/50-cloud-init.conf`，文件名排序在前，sshd 取第一次出现的值。
**对策**：drop-in 用 `00-` 前缀（本套件用 `00-sshd-bridge.conf`），或直接修改/删除 cloud-init 的那份。

### D2. 只改 `sshd_config` 不生效
**根因**：主配置里 `Include /etc/ssh/sshd_config.d/*.conf` 在顶部，任何一个更早的 drop-in 都会赢。
**对策**：同 D1；并用 `sshd -T` 验证，而不是 `grep` 文件。

### D3. 改非 22 端口后 SELinux 拦截
**现象**：sshd 起来但连不上，`ausearch` 显示 `avc: denied name_bind ... ssh_port_t`。
**对策**：`semanage port -a -t ssh_port_t -p tcp <port>`（已存在则 `-m`）。

### D4. firewalld / ufw 默认拒绝
**对策**：显式放行端口，并限制来源网段。firewalld 用 rich rule / zone；ufw 用 `allow from 10.0.0.0/8 to any port 22 proto tcp`。改完 reload 并复查。

### D5. 主机密钥缺失，服务起不来
**根因**：镜像裁剪或 `/etc/ssh` 被清空。
**对策**：`ssh-keygen -A` 生成全部缺失的主机密钥，再启动。

### D6. Ubuntu 没装 openssh-server
**对策**：在线 `apt-get update && apt-get install -y openssh-server`；离线用 `.deb` + 依赖包，或在同版本机器上下载完整依赖。

### D7. 服务名不一样
**根因**：Debian/Ubuntu 是 `ssh`，RHEL 系是 `sshd`，部分发行版是 socket 激活。
**对策**：先探测存在的 unit（`ssh.service` / `sshd.service` / `ssh.socket`），再 enable/start 正确的那个。

---

## E. 网络与发现

### E1. TCP 通不等于 SSH 通（最高频误判）
**现象**：`Test-NetConnection host -Port 22` 成功，SSH 却超时或立刻断开。
**根因**：部分 VPN / 零信任网关、部分负载均衡会对任意端口回 SYN-ACK；真正的握手是服务端主动发 `SSH-2.0-...`。
**对策**：建立 TCP 后读 3 秒；只有首行以 `SSH-` 开头才算真通。本套件所有连通性判断都走这条。

### E2. Clash / Mihomo 的 fake-ip 冒充内网地址
**现象**：解析出 `198.18.x.x`，`TcpTestSucceeded=True`，但实际连的是代理的假响应。
**根因**：TUN 模式把域名映射到 `198.18.0.0/15`，TCP 层被本地接管。
**对策**：识别 `198.18.0.0/15` 并标记为"假 IP，不能作为证据"；改用 IP 直连，或加临时静态路由复测。

### E3. `.local` 主机名在 Windows 上不稳定
**现象**：Mac 上 `ssh host.local` 正常，Windows 上解析失败或被代理劫持。
**根因**：Windows 原生不带 mDNS 解析器（除非装了 Bonjour），且代理可能接管 DNS。
**对策**：`~/.ssh/config` 里写 IP，或写 hosts；不要依赖 `.local`。

### E4. 同网段但连不上
**根因**：访客 WiFi / AP 隔离、VLAN、交换机端口隔离、目标防火墙只允许特定来源。
**对策**：先算网络号确认同网段，再分别测 ICMP、TCP、banner；三者结果不同就是中间设备在拦。

### E5. 公网出口 IP 查出来不是本机
**根因**：`curl ifconfig.me` 走代理，返回的是代理出口。
**对策**：结果只作参考；判断可达性用实际握手，不用公网 IP。

### E6. 直接把 22 映射到公网
**风险**：全网扫描几分钟内就到，密码爆破和 0day 探测持续不断。
**对策**：优先 Tailscale / ZeroTier；其次 Cloudflare Tunnel（`cloudflared access tcp`）；再次才考虑跳板机 + 端口敲门。绝不裸奔。

### E7. 跨网段访问
**对策**：`ProxyJump` 一跳到位（`Host target-b` → `ProxyJump target-a`）。只有 RDP 可达、没有 SSH 时，用 File-Tunnel 把远端 22 映射到本地端口。

### E8. 重装后主机密钥变了
**现象**：`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`。
**对策**：确认是本人重装后 `ssh-keygen -R <host>`；不要长期用 `StrictHostKeyChecking=no`。

### E9. Windows 控制端没有 ControlMaster
**根因**：Win32-OpenSSH 不支持连接复用。
**对策**：Windows 每次都重新握手，批量命令尽量合并成一次 SSH 会话；Mac/Linux 控制端可开 `ControlMaster auto` + `ControlPersist`。

---

## F. 控制端与运维

### F1. 私钥被打进压缩包或仓库
**风险**：一次转发就等于把钥匙交给所有拿到包的人。
**对策**：仓库和发布包只放 `.pub`；私钥只在控制端 `~/.ssh`，权限 600。

### F2. 所有机器共用一把钥匙
**风险**：一台机器泄露，全部要换；也无法从日志判断是谁。
**对策**：每台机器一把 `id_ed25519_<alias>`，注释写 `user@host-yyyyMMdd`。

### F3. 明文凭据写进部署脚本
**风险**：脚本会被转发、截图、进仓库。
**对策**：共享/账号密码放本地 `config.local.ps1` 或 Windows 凭据管理器，`.gitignore` 排除；公开仓库零凭据。

### F4. 部署成功只看"端口在监听"
**根因**：sshd 可能在崩溃循环，或 22 上是别的服务。
**对策**：三层验证——`sshd -t` 语法、本机回环 `SSH-` banner、控制端实际公钥登录。

### F5. 失败后没有任何可回传的信息
**对策**：`Start-Transcript` 写日志，错误落 `部署失败.txt`，成功落 `部署结果.txt`（脚本目录 + 桌面），机主截图即可。

### F6. 非核心步骤失败导致整体中断
**根因**：`$ErrorActionPreference='Stop'` 下，防火墙/共享映射的异常把 SSH 安装也带走了。
**对策**：核心步骤失败即停；防火墙、共享、公网 IP 查询放独立 try/catch，只警告。

### F7. 重复执行把配置堆成一团
**对策**：用托管段标记，每次先删旧段再写；公钥按 key body 去重；服务已运行则重启而不是重复创建。

### F8. 用 `scp` 在 Windows 上传路径踩坑
**根因**：Windows OpenSSH 的远端路径是 `/C:/Users/...`，不是 `C:\Users\...`。
**对策**：统一用正斜杠 + 盘符前缀；或改用 `sftp` 的 `put/get`。

---

## G. 一分钟排障顺序

```text
1. 目标机本机：sshd -t                  → 配置有没有语法错
2. 目标机本机：Get-Service sshd / systemctl status → 服务在不在跑
3. 目标机本机：sshd -T | grep -Ei 'password|pubkey|port|authorizedkeys'
4. 目标机本机：回环读 banner             → 服务真的会说话吗
5. 控制端：TCP 能连吗                    → 网络层
6. 控制端：读到 SSH- banner 吗           → 是不是假通
7. 控制端：ssh -vvv 看卡在哪个认证阶段    → 密钥/权限/账号
8. 看目标机日志：
   Windows  Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 30
   Linux    journalctl -u ssh -n 50
   macOS    log show --predicate 'process == "sshd"' --last 10m
```

---

## H. 本套件固化的规则

1. 只认 `SSH-` banner，不认 ping、不认 TCP、不认端口监听。
2. 配置先备份 → 改托管段 → `sshd -t` → 失败回滚。
3. 公钥写入后回读校验，不信任"命令没报错"。
4. Windows 默认仅公钥；Mac/Linux 验证后再收紧。
5. 防火墙只放内网 + Tailscale，不开 `0.0.0.0/0`。
6. 私钥、凭据、内网地址一律不入库。
7. 所有脚本幂等；重复跑只会修正，不会叠加。
