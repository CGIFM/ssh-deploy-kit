# 版本记录

## v1.0.0 — 2026-11-06

首个整合版。把四套分散实现合并成一个可复用套件：

- **Windows**：吸收早期 Windows 实机版的离线安装、托管配置段、ACL、防火墙收窄、回环握手验证；新增 `-CheckOnly`、`-Port`、`-AllowedUser`、`-KeepPassword`、`-NoTailscale`、回滚脚本。
- **macOS**：吸收早期 macOS 版的 launchd 处理、drop-in 配置、防火墙放行、回滚；新增公钥 CRLF 清洗、`authorized_keys` 严格校验、`harden-ssh.sh`。
- **Linux**：新增 apt/dnf/yum/apk 适配、`00-` 前缀 drop-in 防 cloud-init 覆盖、SELinux 端口标签、ufw/firewalld。
- **控制端**：新增 `add-host`（密钥生成 + ssh config 幂等写入 + 自动验证）和 `doctor`（网段、fake-ip、假通、banner、公钥登录、延迟）。
- **通用离线包**：新增 `tools/make-bundle.ps1` / `make-bundle.sh`，按目标平台生成单机部署包（含公钥、说明、可选离线 MSI），拷到目标机即可一键部署。
- **文档**：新增 `PITFALLS.md`，按平台整理 40+ 条真实踩坑。
- **安全**：仓库内无内网 IP、机器名、账号密码、私钥；共享凭据走本地 `config.local.*`。

### 已知限制

- macOS / Linux 安装脚本尚未在真机执行，首次部署请保留密码登录。
- Windows 防火墙规则在组策略托管环境下可能被覆盖。
- 不支持一键修改 macOS 的 SSH 端口（launchd plist 限制）。
