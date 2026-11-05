# ssh-deploy-kit

> 一套可复用的 SSH 部署工具：在 Windows / macOS / Linux 上一条命令开启 SSH 服务，
> 在控制端一条命令生成密钥、写好别名并验证连通。

## 它解决什么问题

给一台电脑开 SSH，看起来只是"装个服务"，实际会连续踩到这些坑：

- 端口能连上，其实根本没握手（VPN / 零信任网关会对任意端口回 SYN-ACK）
- 公钥写进去了，但权限不对 / 路径不对，登录仍然失败
- 改了配置，系统另一个文件优先级更高，改动被静默忽略
- 关掉密码登录后才发现公钥没生效，把自己锁在门外
- 防火墙规则建了，但只放行了错误网段
- macOS / Linux 的配置文件被包管理器或 cloud-init 覆盖

`ssh-deploy-kit` 把这些判断固化进脚本：**只认真实的 SSH banner**，
配置先备份、再校验、失败自动回滚，没有可用公钥时绝不关闭密码登录。

## 快速开始

### 目标机：开启 SSH

**Windows**（管理员）

```powershell
# 解压后
.\windows\install.cmd
```

**macOS**

```bash
sudo bash mac/install-sshd.sh --key-file mac/keys/your.pub
# 或双击 mac/install.command
```

**Linux**

```bash
sudo bash linux/install-sshd.sh --key-file linux/keys/your.pub
```

### 控制端：加一台机器

```powershell
# Windows
.\controller\add-host.ps1 -Alias dev-box -HostName 192.0.2.10 -User alice
.\controller\doctor.ps1 -Alias dev-box
```

```bash
# macOS / Linux
./controller/add-host.sh dev-box 192.0.2.10 alice
./controller/doctor.sh dev-box
```

`add-host` 会生成专用的 ed25519 密钥、幂等写入 `~/.ssh/config`，
然后真的连一次确认能登录。之后直接 `ssh dev-box`。

## 生成"单机离线部署包"

把某台机器需要的东西打成一个包，拷到 U 盘或共享目录，目标机照着说明点两下即可：

```powershell
.\tools\make-bundle.ps1 -Os windows -PubKeyFile ~\.ssh\id_ed25519_dev-box.pub -IncludeMsi
.\tools\make-bundle.ps1 -Os linux   -PubKeyFile ~\.ssh\id_ed25519_srv.pub
```

```bash
./tools/make-bundle.sh macos ~/.ssh/id_ed25519_mac.pub
```

产物：

```
sshd-deploy-linux-20260101/
├── 部署说明.txt          # 目标机机主照着做即可
├── linux/
│   ├── install-sshd.sh
│   └── keys/id_bridge.pub
└── ...
```

公钥在打包时就已放进包里，目标机装完即可直接登录，不需要再手工抄公钥。

## 诊断工具

`doctor` 会按顺序回答：

1. 目标是否和本机同网段？
2. 目标看起来像不像 Clash / Mihomo 的 fake-ip（`198.18.0.0/15`）？
3. 端口返回的是真的 `SSH-2.0-...` banner，还是假通？
4. 公钥登录到底成没成？

退出码：`0` 全通，`1` 服务正常但公钥失败，`2` 网络/服务层未通。方便接进脚本。

## 安全默认值

- 私钥永不进入仓库、压缩包或部署包；只分发 `.pub`。
- Windows 在提供公钥后默认关闭密码登录；没有公钥时强制保留密码，避免锁死。
- 防火墙默认只放行 RFC1918 内网段与 Tailscale `100.64.0.0/10`。
- 任何配置修改前都有备份，校验失败自动回滚。
- 仓库不含任何真实主机名、内网 IP、账号或口令；发布脚本会扫描并中止。

## 回滚

- Windows：`.\windows\uninstall-sshd.ps1`
- macOS / Linux：用备份的 `sshd_config` 覆盖后重启服务（安装输出会打印备份路径）

## 文档

- [`PITFALLS.md`](PITFALLS.md) —— 40+ 条真实踩坑，按平台分类，含"一分钟排查顺序"
- [`CHANGELOG.md`](CHANGELOG.md)

## 验证状态

| 部分 | 状态 |
|---|---|
| Windows 安装 | 在 Windows 10/11 多台机器上实际跑通 |
| Windows 离线安装 | 在无外网、EDR 拦截 PowerShell 的环境验证过 |
| macOS 安装 | 逻辑完整，尚未在真机逐项验证，首次请保留密码登录 |
| Linux 安装 | 逻辑完整，尚未在真机逐项验证，首次请先在测试机执行 |
| 控制端诊断 | 网段 / banner / 公钥判定逻辑已验证 |

> 未实测的部分不会写成"已支持"。首次上生产前，先跑 `-CheckOnly` /
> `--check`，或保留密码模式，确认公钥能登录后再收紧。

## 许可

MIT
